#!/usr/bin/env bash
# start-next-minor.sh — Kick off a new minor pre-release lane for one repo
#
# Promotes a repo from `X.Y.Z` on develop to `X.(Y+1).0-dev.0`, rewrites its
# greentic-ecosystem deps to the pre-release range form, and opens a PR.
#
# This is the *target-repo-only* step. Consumer repos are NOT auto-cascaded —
# cargo pre-release matching is the natural firewall (^X.Y never matches
# X.(Y+1).0-dev.N), so consumers opt in at their own pace. The script emits a
# cascade plan listing tier-ordered consumers + suggested dep-req diff; adopt
# them deliberately via a follow-up run of this script per repo.
#
# Usage:
#   ./start-next-minor.sh <repo>                  # auto-compute X.(Y+1).0-dev.0
#   ./start-next-minor.sh <repo> 0.6.0-dev.0      # explicit target
#   ./start-next-minor.sh <repo> --dry-run        # preview, no branch/PR/commit
#   ./start-next-minor.sh <repo> --base develop   # base branch (default: develop)
#
# Requires: git, gh, python3 (>=3.11 for tomllib)

set -euo pipefail

WORKSPACE="/home/vampik/greenticai"
BIZ_DIR="$WORKSPACE/GREENTIC-BIZ"
CANONICAL_DIR="$WORKSPACE/.github/toolchain"
MANIFEST="$CANONICAL_DIR/REPO_MANIFEST.toml"
BUMP_SCRIPT="$WORKSPACE/.github/scripts/bump_cargo_versions.py"
CASCADE_DIR="$WORKSPACE/.github/cascade-plans"

declare -A ORG_DIRS=(
  [greenticai]="$WORKSPACE"
  [greentic-biz]="$BIZ_DIR"
)

# Options
REPO=""
TARGET_VERSION=""
DRY_RUN=false
BASE_BRANCH="develop"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --base)    shift_next="base"; continue ;;
    --help|-h)
      sed -n '2,19p' "$0"
      exit 0
      ;;
    --*)
      echo "Unknown flag: $arg" >&2
      exit 1
      ;;
    *)
      if [[ "${shift_next:-}" == "base" ]]; then
        BASE_BRANCH="$arg"; shift_next=""
      elif [[ -z "$REPO" ]]; then
        REPO="$arg"
      elif [[ -z "$TARGET_VERSION" ]]; then
        TARGET_VERSION="$arg"
      else
        echo "Unexpected positional arg: $arg" >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "Usage: $0 <repo> [<target-version>] [--dry-run] [--base BRANCH]" >&2
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

log_ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
log_skip() { echo -e "  ${YELLOW}⊘${RESET} $1"; }
log_fail() { echo -e "  ${RED}✗${RESET} $1"; }
log_info() { echo -e "  ${BLUE}→${RESET} $1"; }
log_warn() { echo -e "  ${YELLOW}!${RESET} $1"; }

die() { log_fail "$1"; exit 1; }

# ── Manifest lookup ──────────────────────────────────────────────
# Outputs tab-separated: org\ttier\tversion_from
# Empty if repo missing or archived.
get_repo_info() {
  local target="$1"
  python3 <<PY
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
entry = m.get('repos', {}).get('$target')
if not entry or entry.get('archived', False):
    raise SystemExit(0)
org = entry.get('org', '')
tier = entry.get('tier', 99)
vt = entry.get('version-track', {})
vf = vt.get('from', '') if isinstance(vt, dict) else ''
vto = vt.get('to', '') if isinstance(vt, dict) else ''
print(f"{org}\t{tier}\t{vf}\t{vto}")
PY
}

# ── Read current version from Cargo.toml ─────────────────────────
get_version() {
  local repo_path="$1"
  python3 <<PY
import tomllib, sys
try:
    with open('$repo_path/Cargo.toml', 'rb') as f:
        data = tomllib.load(f)
except FileNotFoundError:
    sys.exit(1)
ws = data.get('workspace', {}).get('package', {})
pkg = data.get('package', {})
ver = ws.get('version') or pkg.get('version')
if ver:
    print(ver)
else:
    sys.exit(1)
PY
}

# ── Validate version is stable X.Y.Z (no pre-release suffix) ─────
# Echoes "major minor patch" on success; exits non-zero on fail.
parse_stable_version() {
  local ver="$1"
  python3 <<PY
import re, sys
m = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)', '$ver')
if not m:
    sys.exit(1)
print(m.group(1), m.group(2), m.group(3))
PY
}

# ── Validate target version matches X.(Y+1).0-dev.N form ─────────
parse_target_version() {
  local ver="$1"
  python3 <<PY
import re, sys
m = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)-dev\.(\d+)', '$ver')
if not m:
    sys.exit(1)
print(m.group(1), m.group(2), m.group(3), m.group(4))
PY
}

# ── Discover consumers of a package across all manifest repos ────
# Scans every non-archived manifest repo's root Cargo.toml for deps on
# any crate published by <target_repo>. Outputs tab-separated lines:
#   tier\torg\trepo_name\tdep_spec
# where dep_spec is the verbatim TOML value (e.g. `"0.5"`).
discover_consumers() {
  local target_repo="$1"
  python3 <<PY
import tomllib, os
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)

repos = m.get('repos', {})
target_entry = repos.get('$target_repo', {})
target_crates = set(target_entry.get('publishes', []))
if not target_crates:
    target_crates = {'$target_repo'}  # fallback to repo name

ORG_DIRS = {'greenticai': '$WORKSPACE', 'greentic-biz': '$BIZ_DIR'}

def find_deps_in_section(section):
    """Yield (crate_name, raw_value_repr) for matching deps."""
    if not isinstance(section, dict):
        return
    for k, v in section.items():
        if k in target_crates:
            if isinstance(v, str):
                yield k, repr(v)
            elif isinstance(v, dict):
                yield k, repr(v.get('version', '?'))

def walk_deps(doc):
    """Walk all dep-carrying sections in a Cargo.toml."""
    for sec in ('dependencies', 'dev-dependencies', 'build-dependencies'):
        yield from find_deps_in_section(doc.get(sec, {}))
    ws = doc.get('workspace', {})
    for sec in ('dependencies', 'dev-dependencies', 'build-dependencies'):
        yield from find_deps_in_section(ws.get(sec, {}))
    # target-specific deps: target."cfg(...)".dependencies
    for tk, tv in doc.get('target', {}).items():
        if isinstance(tv, dict):
            for sec in ('dependencies', 'dev-dependencies', 'build-dependencies'):
                yield from find_deps_in_section(tv.get(sec, {}))

out = []
for name, entry in repos.items():
    if entry.get('archived', False):
        continue
    if name == '$target_repo':
        continue
    org = entry.get('org', '')
    base = ORG_DIRS.get(org, '')
    cargo = os.path.join(base, name, 'Cargo.toml')
    if not os.path.exists(cargo):
        continue
    try:
        with open(cargo, 'rb') as f:
            doc = tomllib.load(f)
    except Exception:
        continue
    hits = list(walk_deps(doc))
    if hits:
        tier = entry.get('tier', 99)
        for crate, spec in hits:
            out.append((tier, org, name, crate, spec))

out.sort()
for tier, org, name, crate, spec in out:
    print(f"{tier}\t{org}\t{name}\t{crate}\t{spec}")
PY
}

# ── Main ─────────────────────────────────────────────────────────

echo -e "${BOLD}Start Next Minor Pre-Release Lane${RESET}"
echo -e "Repo: $REPO"
echo -e "Base branch: $BASE_BRANCH"
[[ "$DRY_RUN" == true ]] && echo -e "Mode: ${YELLOW}dry-run${RESET}"
echo ""

# Pre-flight: required files
for f in "$MANIFEST" "$BUMP_SCRIPT"; do
  [[ -f "$f" ]] || die "Missing required file: $f"
done
command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"

# Resolve repo in manifest
repo_info=$(get_repo_info "$REPO")
[[ -n "$repo_info" ]] || die "Repo '$REPO' not in manifest (or archived)"
IFS=$'\t' read -r ORG TIER VER_FROM VER_TO <<< "$repo_info"
REPO_PATH="${ORG_DIRS[$ORG]}/$REPO"

log_info "Org: $ORG  |  Tier: $TIER  |  version-track: ${VER_FROM:-∅} → ${VER_TO:-∅}"

# Pre-flight: repo cloned
[[ -d "$REPO_PATH/.git" ]] || die "Repo not cloned locally at $REPO_PATH"

# Fetch latest
git -C "$REPO_PATH" fetch origin --quiet || die "git fetch origin failed"

# Check base branch exists on remote
git -C "$REPO_PATH" rev-parse --verify "refs/remotes/origin/$BASE_BRANCH" \
  >/dev/null 2>&1 || die "origin/$BASE_BRANCH not found"

# Stash original branch to restore at the end
ORIGINAL_BRANCH=$(git -C "$REPO_PATH" branch --show-current 2>/dev/null || echo "")

# Working tree must be clean
if ! git -C "$REPO_PATH" diff --quiet 2>/dev/null \
   || ! git -C "$REPO_PATH" diff --cached --quiet 2>/dev/null; then
  die "Working tree dirty at $REPO_PATH"
fi

# Checkout base branch (fast-forward to origin)
git -C "$REPO_PATH" checkout "$BASE_BRANCH" --quiet 2>/dev/null \
  || die "cannot checkout $BASE_BRANCH"
git -C "$REPO_PATH" reset --hard "origin/$BASE_BRANCH" --quiet \
  || die "cannot reset to origin/$BASE_BRANCH"

# Read current version
CURRENT_VER=$(get_version "$REPO_PATH") || die "cannot read current version"
log_info "Current version: $CURRENT_VER"

# Hard guard: current version must be stable X.Y.Z (no pre-release suffix)
parsed=$(parse_stable_version "$CURRENT_VER") || die \
  "Current version '$CURRENT_VER' has a pre-release suffix — promotion already in flight"
read -r CUR_MAJOR CUR_MINOR _CUR_PATCH <<< "$parsed"

# Compute or validate target version
if [[ -z "$TARGET_VERSION" ]]; then
  TARGET_VERSION="${CUR_MAJOR}.$((CUR_MINOR + 1)).0-dev.0"
  log_info "Auto-computed target: $TARGET_VERSION"
fi
t_parsed=$(parse_target_version "$TARGET_VERSION") || die \
  "Target '$TARGET_VERSION' must match X.(Y+1).0-dev.N"
read -r T_MAJOR T_MINOR T_PATCH _T_DEV_N <<< "$t_parsed"

# Monotonic check: target major/minor must be current major + next minor
if [[ "$T_MAJOR" != "$CUR_MAJOR" || "$T_MINOR" != "$((CUR_MINOR + 1))" || "$T_PATCH" != "0" ]]; then
  die "Target $TARGET_VERSION not adjacent to current $CURRENT_VER (expected ${CUR_MAJOR}.$((CUR_MINOR + 1)).0-dev.N)"
fi

FROM_MM="${CUR_MAJOR}.${CUR_MINOR}"
TO_MM="${T_MAJOR}.${T_MINOR}"
BRANCH_NAME="chore/start-minor-${TO_MM}"

# Hard guard: pre-release kickoff branch must not already exist on remote
if git -C "$REPO_PATH" rev-parse --verify "refs/remotes/origin/$BRANCH_NAME" \
     >/dev/null 2>&1; then
  die "Branch origin/$BRANCH_NAME already exists — pre-release lane already started"
fi

# Soft warn: open PRs on main touching this repo (informational only)
open_main_prs=$(gh pr list --repo "$ORG/$REPO" --base main --state open \
                --json number --jq '. | length' 2>/dev/null || echo "?")
if [[ "$open_main_prs" != "0" && "$open_main_prs" != "?" ]]; then
  log_warn "$open_main_prs open PR(s) against $ORG/$REPO:main — patch lane is independent, FYI only"
fi

# Soft warn: open PRs on base branch (merge-conflict risk)
open_base_prs=$(gh pr list --repo "$ORG/$REPO" --base "$BASE_BRANCH" --state open \
                --json number --jq '. | length' 2>/dev/null || echo "?")
if [[ "$open_base_prs" != "0" && "$open_base_prs" != "?" ]]; then
  log_warn "$open_base_prs open PR(s) against $ORG/$REPO:$BASE_BRANCH — review for Cargo.toml conflicts"
fi

echo ""
log_info "Plan:"
log_info "  1. Create branch $BRANCH_NAME from $BASE_BRANCH"
log_info "  2. bump_cargo_versions.py --pre-release --from $FROM_MM --to $TO_MM --to-version $TARGET_VERSION"
log_info "  3. Commit, push, open PR to $BASE_BRANCH"
log_info "  4. Emit cascade plan to $CASCADE_DIR/$REPO-$TARGET_VERSION.md"
echo ""

# ── Dry-run: exit before mutating anything ───────────────────────
if [[ "$DRY_RUN" == true ]]; then
  log_info "Dry-run: showing what bump_cargo_versions.py would change"
  python3 "$BUMP_SCRIPT" \
    --pre-release \
    --from "$FROM_MM" --to "$TO_MM" \
    --to-version "$TARGET_VERSION" \
    --dry-run \
    "$REPO_PATH" | sed 's/^/    /'
  echo ""
  log_info "Dry-run: consumer discovery preview (top 20)"
  discover_consumers "$REPO" | head -20 | sed 's/^/    /'
  echo ""
  log_ok "Dry-run complete — no changes made"
  # Restore original branch
  [[ -n "$ORIGINAL_BRANCH" && "$ORIGINAL_BRANCH" != "$BASE_BRANCH" ]] \
    && git -C "$REPO_PATH" checkout "$ORIGINAL_BRANCH" --quiet 2>/dev/null || true
  exit 0
fi

# ── Execute ──────────────────────────────────────────────────────

# Create feature branch
git -C "$REPO_PATH" checkout -b "$BRANCH_NAME" --quiet \
  || die "cannot create branch $BRANCH_NAME"
log_ok "Branch $BRANCH_NAME created"

# Run bumper
bump_out=$(python3 "$BUMP_SCRIPT" \
  --pre-release \
  --from "$FROM_MM" --to "$TO_MM" \
  --to-version "$TARGET_VERSION" \
  "$REPO_PATH" 2>&1) || {
  echo "$bump_out" | sed 's/^/    /'
  die "bump_cargo_versions.py failed"
}
echo "$bump_out" | sed 's/^/    /'

# Verify something actually changed
if git -C "$REPO_PATH" diff --quiet 2>/dev/null; then
  git -C "$REPO_PATH" checkout "$BASE_BRANCH" --quiet 2>/dev/null || true
  git -C "$REPO_PATH" branch -D "$BRANCH_NAME" 2>/dev/null || true
  die "bump_cargo_versions.py produced no changes (unexpected)"
fi

# Commit
git -C "$REPO_PATH" add -A
git -C "$REPO_PATH" commit -m "chore: start ${TO_MM} pre-release lane ($TARGET_VERSION)" --quiet
log_ok "Commit created"

# Push
git -C "$REPO_PATH" push --set-upstream origin "$BRANCH_NAME" --quiet \
  || die "git push failed"
log_ok "Pushed to origin/$BRANCH_NAME"

# Open PR
pr_body=$(cat <<EOF
Kicks off the ${TO_MM} pre-release lane for \`$REPO\`.

**Changes:**
- Package version: \`$CURRENT_VER\` → \`$TARGET_VERSION\`
- Greentic-ecosystem dep reqs rewritten to pre-release range form: \`">=${TO_MM}.0-dev, <${T_MAJOR}.$((T_MINOR + 1)).0-0"\`

**Firewall note:** Cargo's pre-release matching means \`^$FROM_MM\` in consumer repos does NOT resolve \`$TARGET_VERSION\`. Consumers opt in by updating their own dep reqs. See the cascade plan at \`.github/cascade-plans/$REPO-$TARGET_VERSION.md\` for tier-ordered adoption.

**Follow-up:**
- [ ] Update \`REPO_MANIFEST.toml\` entry for \`$REPO\`: \`version-track = { from = "$FROM_MM", to = "$TO_MM" }\`
- [ ] Smoke-test dev-publish workflow picks up \`-dev.N\` version
- [ ] Begin tier-ordered consumer adoption per cascade plan

Generated by \`start-next-minor.sh\`.
EOF
)

pr_url=$(gh pr create \
  --repo "$ORG/$REPO" \
  --base "$BASE_BRANCH" \
  --head "$BRANCH_NAME" \
  --title "chore: start ${TO_MM} pre-release lane ($TARGET_VERSION)" \
  --body "$pr_body" 2>&1) || {
  log_fail "gh pr create failed:"
  echo "$pr_url" | sed 's/^/    /'
  die "PR not opened — branch pushed, run gh pr create manually"
}
log_ok "PR opened: $pr_url"

# ── Generate cascade plan ────────────────────────────────────────
mkdir -p "$CASCADE_DIR"
plan_file="$CASCADE_DIR/$REPO-$TARGET_VERSION.md"
{
  echo "# Cascade Plan: $REPO → $TARGET_VERSION"
  echo ""
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Base version: $CURRENT_VER"
  echo "Target version: $TARGET_VERSION"
  echo "Target PR: $pr_url"
  echo ""
  echo "## Manifest follow-up"
  echo ""
  echo "On \`greenticai/.github\`: update \`REPO_MANIFEST.toml\` for \`$REPO\`:"
  echo '```toml'
  echo "version-track = { from = \"$FROM_MM\", to = \"$TO_MM\" }"
  echo '```'
  echo ""
  echo "## Tier-ordered consumers"
  echo ""
  echo "Each consumer below currently depends on a crate published by \`$REPO\`."
  echo "To adopt \`$TARGET_VERSION\`, update the dep req in that consumer's Cargo.toml:"
  echo ""
  echo '```toml'
  echo "# Replace:  {crate} = \"$FROM_MM\""
  echo "# With:     {crate} = \">=${TO_MM}.0-dev, <${T_MAJOR}.$((T_MINOR + 1)).0-0\""
  echo '```'
  echo ""
  echo "Then bump the consumer itself via \`./start-next-minor.sh <consumer>\`."
  echo ""
  echo "| Tier | Org | Repo | Crate | Current spec |"
  echo "|------|-----|------|-------|--------------|"
  discover_consumers "$REPO" | while IFS=$'\t' read -r t o r c s; do
    echo "| $t | $o | $r | $c | \`$s\` |"
  done
  echo ""
  echo "## How to execute (per consumer)"
  echo ""
  echo "1. On the consumer repo's \`$BASE_BRANCH\` branch, edit \`Cargo.toml\` dep reqs per the pattern above."
  echo "2. Run \`cargo update\` to refresh \`Cargo.lock\`."
  echo "3. Address any breaking-change friction from the new version."
  echo "4. Commit + open PR."
  echo "5. When ready to also bump the consumer's own minor: \`./start-next-minor.sh <consumer>\`."
} > "$plan_file"

log_ok "Cascade plan: $plan_file"

# ── Restore original branch ──────────────────────────────────────
git -C "$REPO_PATH" checkout "$BASE_BRANCH" --quiet 2>/dev/null || true
if [[ -n "$ORIGINAL_BRANCH" && "$ORIGINAL_BRANCH" != "$BASE_BRANCH" ]]; then
  git -C "$REPO_PATH" checkout "$ORIGINAL_BRANCH" --quiet 2>/dev/null || true
fi

echo ""
echo -e "${BOLD}━━━ Done ━━━${RESET}"
echo -e "  ${GREEN}PR:${RESET}            $pr_url"
echo -e "  ${GREEN}Cascade plan:${RESET}  $plan_file"
echo ""
