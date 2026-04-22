#!/usr/bin/env bash
# bump-dev-version.sh — Bump patch versions on the develop branch
#
# For ongoing development after initial branch creation. Reads current
# version from a repo's Cargo.toml and increments the patch component.
# No need to specify version numbers manually.
#
# Usage:
#   ./bump-dev-version.sh --repo NAME         # bump one repo
#   ./bump-dev-version.sh --tier N            # bump all repos in tier N
#   ./bump-dev-version.sh --cascade NAME      # bump repo + cargo update in downstream
#   ./bump-dev-version.sh --all               # bump all repos
#   ./bump-dev-version.sh --dry-run --all     # preview all
#
# Requires: git, python3

set -euo pipefail

WORKSPACE="/home/vampik/greenticai"
BIZ_DIR="$WORKSPACE/GREENTIC-BIZ"
CANONICAL_DIR="$WORKSPACE/.github/toolchain"
MANIFEST="$CANONICAL_DIR/REPO_MANIFEST.toml"
BUMP_SCRIPT="$WORKSPACE/.github/scripts/bump_cargo_versions.py"

declare -A ORG_DIRS=(
  [greenticai]="$WORKSPACE"
  [greentic-biz]="$BIZ_DIR"
)

# Options
DRY_RUN=false
SINGLE_REPO=""
SINGLE_TIER=""
CASCADE_REPO=""
ALL=false
BRANCH="develop"
MINOR_TARGET=""

shift_next=""
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=true ;;
    --all)       ALL=true ;;
    --repo)      shift_next="repo"; continue ;;
    --tier)      shift_next="tier"; continue ;;
    --cascade)   shift_next="cascade"; continue ;;
    --branch)    shift_next="branch"; continue ;;
    --minor)     shift_next="minor"; continue ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [--repo NAME | --tier N | --cascade NAME | --all] [--minor X.Y]"
      echo ""
      echo "Modes:"
      echo "  --repo NAME      Bump patch version in one repo"
      echo "  --tier N         Bump all repos in tier N"
      echo "  --cascade NAME   Bump repo + cargo update in all downstream repos"
      echo "  --all            Bump all repos"
      echo ""
      echo "Options:"
      echo "  --dry-run        Preview changes without modifying files"
      echo "  --branch NAME    Target branch (default: develop)"
      echo "  --minor X.Y      Cross-minor bump to X.Y.0 (e.g. 0.5). Default is patch bump."
      exit 0
      ;;
    *)
      if [[ "${shift_next:-}" == "repo" ]]; then
        SINGLE_REPO="$arg"; shift_next=""
      elif [[ "${shift_next:-}" == "tier" ]]; then
        SINGLE_TIER="$arg"; shift_next=""
      elif [[ "${shift_next:-}" == "cascade" ]]; then
        CASCADE_REPO="$arg"; shift_next=""
      elif [[ "${shift_next:-}" == "branch" ]]; then
        BRANCH="$arg"; shift_next=""
      elif [[ "${shift_next:-}" == "minor" ]]; then
        MINOR_TARGET="$arg"; shift_next=""
      else
        echo "Unknown argument: $arg" >&2; exit 1
      fi
      ;;
  esac
done

# Validate --minor format (must be major.minor)
if [[ -n "$MINOR_TARGET" && ! "$MINOR_TARGET" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "Error: --minor must be major.minor (e.g. 0.5), got: $MINOR_TARGET" >&2
  exit 1
fi

# Validate: exactly one mode
modes=0
[[ -n "$SINGLE_REPO" ]] && ((modes++)) || true
[[ -n "$SINGLE_TIER" ]] && ((modes++)) || true
[[ -n "$CASCADE_REPO" ]] && ((modes++)) || true
[[ "$ALL" == true ]] && ((modes++)) || true

if [[ "$modes" -eq 0 ]]; then
  echo "Error: specify --repo, --tier, --cascade, or --all" >&2
  exit 1
fi
if [[ "$modes" -gt 1 ]]; then
  echo "Error: specify only one of --repo, --tier, --cascade, --all" >&2
  exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Counters
bumped=0
cascade_updated=0
skipped=0
failed=0

# ── Parse manifest ───────────────────────────────────────────────
# Output: tier\torg\tname
# All non-archived repos with version-track (skip repos without it).
get_all_repos() {
  python3 -c "
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
entries = []
for name, entry in m.get('repos', {}).items():
    if entry.get('archived', False):
        continue
    if 'version-track' not in entry:
        continue
    tier = entry.get('tier', 99)
    entries.append((tier, entry['org'], name))
entries.sort()
for tier, org, name in entries:
    print(f'{tier}\t{org}\t{name}')
"
}

# Get tier for a specific repo
get_repo_tier() {
  local target="$1"
  python3 -c "
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
entry = m.get('repos', {}).get('$target')
if entry:
    print(entry.get('tier', 99))
"
}

# ── Read current version from Cargo.toml ─────────────────────────
get_version() {
  local repo_path="$1"
  python3 -c "
import tomllib, sys
with open('$repo_path/Cargo.toml', 'rb') as f:
    data = tomllib.load(f)
ws = data.get('workspace', {}).get('package', {})
pkg = data.get('package', {})
ver = ws.get('version') or pkg.get('version')
if ver:
    print(ver)
else:
    sys.exit(1)
" 2>/dev/null
}

# ── Bump patch version ───────────────────────────────────────────
bump_patch() {
  local ver="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$ver"
  echo "$major.$minor.$((patch + 1))"
}

# ── Detect pre-release suffix ────────────────────────────────────
# Returns 0 if version has -dev/-alpha/-beta/-rc suffix, non-zero otherwise.
is_pre_release() {
  [[ "$1" == *-dev.* || "$1" == *-alpha.* || "$1" == *-beta.* || "$1" == *-rc.* ]]
}

# ── Bump pre-release counter: X.Y.Z-dev.N → X.Y.Z-dev.(N+1) ──────
# Only handles -dev.N rolling form. Other pre-release forms fail —
# use --to-version explicitly (or start-next-minor.sh to kick off a lane).
# Also emits "major minor" to stdout on the second line for caller parsing.
bump_pre_release() {
  local ver="$1"
  python3 <<PY
import re, sys
m = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)-dev\.(\d+)', '$ver')
if not m:
    sys.exit(1)
n = int(m.group(4)) + 1
print(f"{m.group(1)}.{m.group(2)}.{m.group(3)}-dev.{n}")
print(f"{m.group(1)} {m.group(2)}")
PY
}

# ── Bump one repo ───────────────────────────────────────────────
bump_repo() {
  local org="$1"
  local repo_name="$2"
  local local_dir="${ORG_DIRS[$org]}"
  local repo_path="$local_dir/$repo_name"

  if [[ ! -d "$repo_path/.git" ]]; then
    echo -e "  ${YELLOW}⊘${RESET} Not cloned locally"
    ((skipped++)) || true
    return 0
  fi

  # Ensure we're on the target branch
  local current_branch
  current_branch=$(git -C "$repo_path" branch --show-current 2>/dev/null || echo "")
  if [[ "$current_branch" != "$BRANCH" ]]; then
    echo -e "  ${YELLOW}⊘${RESET} Not on $BRANCH (on: $current_branch)"
    ((skipped++)) || true
    return 0
  fi

  # Read current version
  local current_ver
  current_ver=$(get_version "$repo_path") || {
    echo -e "  ${RED}✗${RESET} Could not read version"
    ((failed++)) || true
    return 0
  }

  # Compute next version. Three modes:
  #   - pre-release (auto-detected from -dev.N suffix): bump counter (0.6.0-dev.3 → 0.6.0-dev.4)
  #   - patch (default stable): bump trailing component (0.5.7 → 0.5.8)
  #   - minor (--minor X.Y): jump to X.Y.0 (0.4.150 → 0.5.0)
  local next_ver cur_major cur_minor _cur_patch
  local pre_release=false
  if is_pre_release "$current_ver"; then
    pre_release=true
    if [[ -n "$MINOR_TARGET" ]]; then
      echo -e "  ${RED}✗${RESET} --minor cannot be combined with pre-release version ($current_ver); use start-next-minor.sh for cross-minor promotion"
      ((failed++)) || true
      return 0
    fi
    local pr_out
    if ! pr_out=$(bump_pre_release "$current_ver" 2>/dev/null); then
      echo -e "  ${RED}✗${RESET} Unsupported pre-release form '$current_ver' (only -dev.N increments here; pass --to-version explicitly for others)"
      ((failed++)) || true
      return 0
    fi
    next_ver=$(sed -n '1p' <<< "$pr_out")
    IFS=' ' read -r cur_major cur_minor <<< "$(sed -n '2p' <<< "$pr_out")"
  else
    IFS='.' read -r cur_major cur_minor _cur_patch <<< "$current_ver"
    if [[ -n "$MINOR_TARGET" ]]; then
      if [[ "$cur_major.$cur_minor" == "$MINOR_TARGET" ]]; then
        echo -e "  ${YELLOW}⊘${RESET} Already at minor $MINOR_TARGET (current: $current_ver)"
        ((skipped++)) || true
        return 0
      fi
      next_ver="$MINOR_TARGET.0"
    else
      next_ver=$(bump_patch "$current_ver")
    fi
  fi

  # Delegate the actual TOML rewrite to bump_cargo_versions.py.
  # It is structure-aware (handles workspace.dependencies, target-specific
  # deps, and dep aliases) and emits the canonical range spec for greentic
  # deps — fixing the silent bug where the in-place sed only matched the
  # exact 3-part package version and left dep specs on the old minor.
  #
  # In pre-release mode (--pre-release), the bumper emits the pre-release
  # range form ">=X.Y.0-dev, <X.(Y+1).0-0" for greentic deps, and the
  # package version is pinned to next_ver via --to-version.
  local from_arg to_arg next_major next_minor _next_patch
  if [[ "$pre_release" == true ]]; then
    # from/to both use the stable X.Y prefix; next_ver carries the pre-release suffix
    from_arg="$cur_major.$cur_minor"
    to_arg="$cur_major.$cur_minor"
  else
    IFS='.' read -r next_major next_minor _next_patch <<< "$next_ver"
    from_arg="$cur_major.$cur_minor"
    to_arg="$next_major.$next_minor"
  fi

  local -a py_args=(--from "$from_arg" --to "$to_arg")
  [[ "$pre_release" == true ]] && py_args+=(--pre-release)
  [[ "$DRY_RUN" == true ]] && py_args+=(--dry-run)
  # When the minor doesn't change (patch bump or pre-release counter), pin
  # the exact target version so we don't downgrade e.g. 0.5.7 → 0.5.0 or
  # lose the -dev.N suffix.
  if [[ "$from_arg" == "$to_arg" ]]; then
    py_args+=(--to-version "$next_ver")
  fi
  py_args+=("$repo_path")

  # Capture both stdout+stderr and exit code without `set -e` killing us.
  local py_output py_status=0
  if ! py_output=$(python3 "$BUMP_SCRIPT" "${py_args[@]}" 2>&1); then
    py_status=$?
  fi

  if [[ "$py_status" -ne 0 ]]; then
    echo -e "  ${RED}✗${RESET} bump_cargo_versions.py failed (exit $py_status):"
    sed 's/^/      /' <<< "$py_output"
    ((failed++)) || true
    return 0
  fi

  if grep -q '^No changes needed' <<< "$py_output"; then
    echo -e "  ${YELLOW}⊘${RESET} No matching versions to bump (current: $current_ver)"
    ((skipped++)) || true
    return 0
  fi

  local file_count
  file_count=$(grep -oE '[0-9]+ files? (would be )?modified' <<< "$py_output" \
               | tail -1 | awk '{print $1}')
  local verb
  verb=$([[ "$DRY_RUN" == true ]] && echo "Would bump" || echo "Bumped")
  echo -e "  ${GREEN}✓${RESET} $verb: $current_ver → $next_ver (${file_count:-?} file(s))"
  ((bumped++)) || true
}

# ── Cascade: bump + cargo update in downstream repos ─────────────
cascade_update() {
  local target_repo="$1"
  local target_tier
  target_tier=$(get_repo_tier "$target_repo")

  if [[ -z "$target_tier" ]]; then
    echo -e "${RED}Error: repo '$target_repo' not found in manifest${RESET}" >&2
    exit 1
  fi

  echo -e "${BOLD}Cascading from $target_repo (tier $target_tier)${RESET}"
  echo ""

  # First, bump the target repo
  local target_org
  target_org=$(python3 -c "
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
print(m['repos']['$target_repo']['org'])
")

  echo -e "${CYAN}${BOLD}[$target_org/$target_repo]${RESET} (tier $target_tier) — bump"
  bump_repo "$target_org" "$target_repo"
  echo ""

  # Then cargo update in all higher-tier repos
  echo -e "${BOLD}Updating downstream repos (tier > $target_tier)${RESET}"
  echo ""

  while IFS=$'\t' read -r tier org name; do
    [[ "$tier" -le "$target_tier" ]] && continue
    [[ "$name" == "$target_repo" ]] && continue

    local local_dir="${ORG_DIRS[$org]}"
    local repo_path="$local_dir/$name"

    if [[ ! -d "$repo_path/.git" ]]; then
      continue
    fi

    local current_branch
    current_branch=$(git -C "$repo_path" branch --show-current 2>/dev/null || echo "")
    if [[ "$current_branch" != "$BRANCH" ]]; then
      continue
    fi

    echo -e "${CYAN}${BOLD}[$org/$name]${RESET} (tier $tier) — cargo update"

    if [[ "$DRY_RUN" == true ]]; then
      echo -e "  ${BLUE}→${RESET} Would run cargo update"
      ((cascade_updated++)) || true
      continue
    fi

    if (cd "$repo_path" && cargo update 2>/dev/null); then
      echo -e "  ${GREEN}✓${RESET} Cargo.lock updated"
      ((cascade_updated++)) || true
    else
      echo -e "  ${YELLOW}⊘${RESET} cargo update failed (may need CodeArtifact creds)"
      ((skipped++)) || true
    fi
  done < <(get_all_repos)
}

# ── Main ─────────────────────────────────────────────────────────

echo -e "${BOLD}Greentic Dev Version Bump${RESET}"
echo -e "Branch: $BRANCH"
echo -e "Dry run: $DRY_RUN"
echo ""

if [[ ! -f "$MANIFEST" ]]; then
  echo -e "${RED}Missing manifest: $MANIFEST${RESET}" >&2
  exit 1
fi

# ── Cascade mode ──
if [[ -n "$CASCADE_REPO" ]]; then
  cascade_update "$CASCADE_REPO"

# ── Single repo / tier / all ──
else
  current_tier=""
  while IFS=$'\t' read -r tier org name; do
    [[ -n "$SINGLE_REPO" && "$name" != "$SINGLE_REPO" ]] && continue
    [[ -n "$SINGLE_TIER" && "$tier" != "$SINGLE_TIER" ]] && continue

    if [[ "$tier" != "$current_tier" ]]; then
      current_tier="$tier"
      echo -e "${BOLD}━━━ Tier $tier ━━━${RESET}"
    fi

    echo -e "${CYAN}${BOLD}[$org/$name]${RESET} (tier $tier)"
    bump_repo "$org" "$name"
  done < <(get_all_repos)
fi

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ Summary ━━━${RESET}"
echo -e "  ${GREEN}Bumped:${RESET}          $bumped"
[[ "$cascade_updated" -gt 0 ]] && echo -e "  ${GREEN}Cargo updated:${RESET}   $cascade_updated"
[[ "$skipped" -gt 0 ]]  && echo -e "  ${YELLOW}Skipped:${RESET}         $skipped"
[[ "$failed" -gt 0 ]]   && echo -e "  ${RED}Failed:${RESET}          $failed"
echo ""

exit "$failed"
