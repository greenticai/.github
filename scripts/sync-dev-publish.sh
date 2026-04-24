#!/usr/bin/env bash
# sync-dev-publish.sh — Deploy dev-publish caller workflows to repos
#
# For each repo with non-empty `publishes` in REPO_MANIFEST.toml, generates
# a thin dev-publish.yml caller workflow on the `develop` branch that
# delegates to the shared reusable workflow.
#
# Usage (from the workspace root, one level above the .github checkout):
#   bash .github/scripts/sync-dev-publish.sh               # create PR targeting develop
#   bash .github/scripts/sync-dev-publish.sh --dry-run     # show what would change, change nothing
#   bash .github/scripts/sync-dev-publish.sh --direct      # commit directly to develop, push
#   bash .github/scripts/sync-dev-publish.sh --check       # exit non-zero if any repo drifts
#   bash .github/scripts/sync-dev-publish.sh --repo NAME   # single repo only
#   bash .github/scripts/sync-dev-publish.sh --tier N      # single tier only
#
# The script derives WORKSPACE from its own location (parent of .github). Override
# with the $WORKSPACE env var if your layout differs.
#
# Requires: gh (GitHub CLI), git, python3

set -euo pipefail

# Derive WORKSPACE from the script's physical location: .github/scripts/X.sh →
# the workspace root is the grandparent directory. Allow override via env var
# for unusual checkouts.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
BIZ_DIR="${BIZ_DIR:-$WORKSPACE/GREENTIC-BIZ}"
CANONICAL_DIR="$WORKSPACE/.github/toolchain"
MANIFEST="$CANONICAL_DIR/REPO_MANIFEST.toml"

# Org → local directory mapping
declare -A ORG_DIRS=(
  [greenticai]="$WORKSPACE"
  [greentic-biz]="$BIZ_DIR"
)

# Options
MODE="pr"  # pr | direct | dry-run | check
SINGLE_REPO=""
SINGLE_TIER=""
TARGET_BRANCH="develop"
SYNC_BRANCH="chore/sync-dev-publish"
COMMIT_MSG="chore: sync dev-publish caller from REPO_MANIFEST.toml"

for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE="dry-run" ;;
    --direct)  MODE="direct" ;;
    --check)   MODE="check" ;;
    --repo)    shift_next="repo"; continue ;;
    --tier)    shift_next="tier"; continue ;;
    --help|-h)
      echo "Usage: $0 [--dry-run|--direct|--check] [--repo NAME] [--tier N]"
      echo ""
      echo "Modes:"
      echo "  (default)   Create branch from develop, commit, push, open PR"
      echo "  --dry-run   Show what would change, change nothing"
      echo "  --direct    Commit directly to develop, push"
      echo "  --check     Exit non-zero if any repo drifts (for CI)"
      echo ""
      echo "Options:"
      echo "  --repo NAME  Process a single repo only"
      echo "  --tier N     Process repos in tier N only"
      exit 0
      ;;
    *)
      if [[ "${shift_next:-}" == "repo" ]]; then
        SINGLE_REPO="$arg"
        shift_next=""
      elif [[ "${shift_next:-}" == "tier" ]]; then
        SINGLE_TIER="$arg"
        shift_next=""
      else
        echo "Unknown argument: $arg" >&2
        exit 1
      fi
      ;;
  esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Counters
synced=0
up_to_date=0
skipped=0
drifted=0
failed=0

declare -a failed_repos=()
declare -a drifted_repos=()

log_ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
log_skip() { echo -e "  ${YELLOW}⊘${RESET} $1"; }
log_fail() { echo -e "  ${RED}✗${RESET} $1"; }
log_info() { echo -e "  ${BLUE}→${RESET} $1"; }
log_drift(){ echo -e "  ${YELLOW}⚠${RESET} $1"; }

# ── Parse REPO_MANIFEST.toml ──────────────────────────────────────
# Outputs tab-delimited lines:
#   org \t variant \t tier \t crates \t exclude_crates \t setup_script \t binary_crates \t dual_role_binary_crates \t repo_name
# Only repos with non-empty publishes. Sorted by tier.
#
# Optional fields in the manifest:
#   exclude-crates           = ["foo", "bar"]    # skipped by build/clippy/test (native linker can't handle WASM cdylibs)
#   setup-script             = "shell command"   # run before tests. Single-line, no tabs.
#   binary-crates            = ["gtc"]           # Phase C: subset of publishes that ship a binary (get -dev rename on dev lane)
#   dual-role-binary-crates  = ["gtc"]           # Phase C: subset of binary-crates that also publish a library under the same name
#
# NOTE: Empty optional fields are emitted as the sentinel `_NONE_`. bash `read`
# with tab IFS collapses consecutive tab delimiters because tab is whitespace;
# the sentinel prevents field-shift when optional columns are blank.
# The bash reader strips `_NONE_` back to an empty string. Same pattern as sync-weekly-stable.sh.
parse_manifest() {
  python3 -c "
import tomllib, sys
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
entries = []
for name, entry in m.get('repos', {}).items():
    if entry.get('archived', False):
        continue
    publishes = entry.get('publishes', [])
    if not publishes:
        continue
    tier = entry.get('tier', 99)
    crates = ' '.join(publishes)
    exclude = ' '.join(entry.get('exclude-crates', [])) or '_NONE_'
    setup = entry.get('setup-script', '') or '_NONE_'
    binary = ' '.join(entry.get('binary-crates', [])) or '_NONE_'
    dual   = ' '.join(entry.get('dual-role-binary-crates', [])) or '_NONE_'
    if '\t' in setup or '\n' in setup:
        sys.exit(f'ERROR: setup-script for {name} must be a single line with no tabs')
    entries.append((tier, entry['org'], entry['variant'], crates, exclude, setup, binary, dual, name))
entries.sort()
for tier, org, variant, crates, exclude, setup, binary, dual, name in entries:
    print(f'{org}\t{variant}\t{tier}\t{crates}\t{exclude}\t{setup}\t{binary}\t{dual}\t{name}')
"
}

# ── Generate caller YAML ─────────────────────────────────────────
# Emits in field order: crates, exclude-crates, setup-script, wasm-target,
# binary-crates, dual-role-binary-crates.
# For repos with binary-crates, also emits a second matrix-fanned job that
# calls dev-release-binaries.yml so `cargo binstall <crate>-dev` has archives
# to download from the GitHub Release.
generate_caller() {
  local crates="$1"
  local variant="$2"
  local exclude_crates="$3"
  local setup_script="$4"
  local binary_crates="$5"
  local dual_role_binary_crates="$6"

  # contents: write is required when binary-crates is non-empty because the
  # paired dev-release-binaries.yml reusable creates a prerelease GitHub Release
  # (gh release create). GitHub Actions rejects caller→reusable permission
  # elevation at startup, so read-only callers cause startup_failure with
  # "workflow file issue".
  local top_permissions="contents: read"
  if [[ -n "$binary_crates" ]]; then
    top_permissions="contents: write"
  fi

  cat <<EOF
# Auto-generated by sync-dev-publish.sh — do not edit manually.
# Source: REPO_MANIFEST.toml in greenticai/.github
name: Dev Publish

on:
  push:
    branches: [develop]
  workflow_dispatch:

permissions:
  $top_permissions

concurrency:
  group: \${{ github.workflow }}-\${{ github.ref }}
  cancel-in-progress: false

jobs:
  # Stage 1 — tests + version stamping. Outputs the stamped dev version
  # {M.m.GITHUB_RUN_ID} consumed by binaries + publish.
  dev-prepare:
    uses: greenticai/.github/.github/workflows/dev-prepare.yml@main
EOF

  # Only emit `with:` when at least one input needs to be set, so actionlint
  # doesn't complain about an empty `with:` block (it's valid YAML but noisy).
  if [[ -n "$exclude_crates" || -n "$setup_script" || "$variant" == "wasm" ]]; then
    echo "    with:"
  fi

  if [[ -n "$exclude_crates" ]]; then
    echo "      exclude-crates: \"$exclude_crates\""
  fi

  if [[ -n "$setup_script" ]]; then
    # Escape backslashes then double quotes for a YAML double-quoted scalar.
    local escaped="${setup_script//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    echo "      setup-script: \"$escaped\""
  fi

  if [[ "$variant" == "wasm" ]]; then
    echo "      wasm-target: true"
  fi

  # Stage 2 — binaries (only if this repo ships one or more binary crates).
  # One job per binary crate so each target's failure is independent.
  local binary_job_ids=""
  if [[ -n "$binary_crates" ]]; then
    for pkg in $binary_crates; do
      local job_id="dev-binaries-${pkg}"
      binary_job_ids="${binary_job_ids}${binary_job_ids:+, }${job_id}"
      cat <<EOF

  ${job_id}:
    needs: dev-prepare
    uses: greenticai/.github/.github/workflows/dev-release-binaries.yml@main
    with:
      package: ${pkg}
      version: \${{ needs.dev-prepare.outputs.version }}
EOF
    done
  fi

  # Stage 3 — crates.io publish. Runs LAST so a failed binary build never
  # leaves an orphan crate version on crates.io without matching binaries.
  # Mirrors the stable lane's release-binaries → crates-publish ordering.
  local publish_needs="[dev-prepare${binary_job_ids:+, ${binary_job_ids}}]"
  cat <<EOF

  dev-publish:
    needs: ${publish_needs}
    uses: greenticai/.github/.github/workflows/dev-publish.yml@main
    with:
      version: \${{ needs.dev-prepare.outputs.version }}
      crates: "$crates"
EOF

  if [[ -n "$setup_script" ]]; then
    local escaped2="${setup_script//\\/\\\\}"
    escaped2="${escaped2//\"/\\\"}"
    echo "      setup-script: \"$escaped2\""
  fi

  if [[ -n "$binary_crates" ]]; then
    echo "      binary-crates: \"$binary_crates\""
  fi

  if [[ -n "$dual_role_binary_crates" ]]; then
    echo "      dual-role-binary-crates: \"$dual_role_binary_crates\""
  fi

  echo "    secrets: inherit"
}

# ── Sync one repo ─────────────────────────────────────────────────
sync_repo() {
  local org="$1"
  local variant="$2"
  local tier="$3"
  local crates="$4"
  local exclude_crates="$5"
  local setup_script="$6"
  local binary_crates="$7"
  local dual_role_binary_crates="$8"
  local repo_name="$9"
  local local_dir="${ORG_DIRS[$org]}"
  local repo_path="$local_dir/$repo_name"
  local workflow_path=".github/workflows/dev-publish.yml"

  # Check repo exists locally
  if [[ ! -d "$repo_path/.git" ]]; then
    log_skip "Not cloned locally"
    ((skipped++)) || true
    return 0
  fi

  # Fetch latest
  if ! git -C "$repo_path" fetch origin --quiet 2>/dev/null; then
    log_fail "Failed to fetch origin"
    failed_repos+=("$repo_name (fetch)")
    ((failed++)) || true
    return 0
  fi

  # Check develop branch exists on remote
  if ! git -C "$repo_path" rev-parse --verify "refs/remotes/origin/$TARGET_BRANCH" >/dev/null 2>&1; then
    log_skip "No '$TARGET_BRANCH' branch on remote"
    ((skipped++)) || true
    return 0
  fi

  # Generate expected caller content
  local expected
  expected=$(generate_caller "$crates" "$variant" "$exclude_crates" "$setup_script" "$binary_crates" "$dual_role_binary_crates")

  # Get current caller content from develop (if it exists)
  local current
  current=$(git -C "$repo_path" show "origin/$TARGET_BRANCH:$workflow_path" 2>/dev/null || echo "")

  # Compare
  if [[ "$current" == "$expected" ]]; then
    log_ok "Up to date"
    ((up_to_date++)) || true
    return 0
  fi

  # Describe the change
  local action="create"
  [[ -n "$current" ]] && action="update"

  # ── Mode: check ──
  if [[ "$MODE" == "check" ]]; then
    log_drift "Drift detected ($action $workflow_path)"
    drifted_repos+=("$org/$repo_name")
    ((drifted++)) || true
    return 0
  fi

  # ── Mode: dry-run ──
  if [[ "$MODE" == "dry-run" ]]; then
    log_info "Would $action $workflow_path (crates: $crates)"
    if [[ -n "$current" ]]; then
      echo "    --- current ---"
      echo "$current" | sed 's/^/    /'
      echo "    --- expected ---"
      echo "$expected" | sed 's/^/    /'
    fi
    ((synced++)) || true
    return 0
  fi

  # ── Check for uncommitted changes ──
  if ! git -C "$repo_path" diff --quiet 2>/dev/null || ! git -C "$repo_path" diff --cached --quiet 2>/dev/null; then
    log_fail "Dirty working tree — skipping"
    failed_repos+=("$repo_name (dirty)")
    ((failed++)) || true
    return 0
  fi

  # Stash current branch to return later
  local original_branch
  original_branch=$(git -C "$repo_path" branch --show-current 2>/dev/null || echo "")

  # ── Mode: pr — create feature branch from develop ──
  if [[ "$MODE" == "pr" ]]; then
    # Delete existing sync branch if present
    git -C "$repo_path" branch -D "$SYNC_BRANCH" 2>/dev/null || true

    if ! git -C "$repo_path" checkout -b "$SYNC_BRANCH" "origin/$TARGET_BRANCH" --quiet 2>/dev/null; then
      log_fail "Cannot create branch from origin/$TARGET_BRANCH"
      failed_repos+=("$repo_name (branch)")
      ((failed++)) || true
      [[ -n "$original_branch" ]] && git -C "$repo_path" checkout "$original_branch" --quiet 2>/dev/null || true
      return 0
    fi
  elif [[ "$MODE" == "direct" ]]; then
    if ! git -C "$repo_path" checkout "$TARGET_BRANCH" --quiet 2>/dev/null; then
      log_fail "Cannot checkout $TARGET_BRANCH"
      failed_repos+=("$repo_name (checkout)")
      ((failed++)) || true
      return 0
    fi
    git -C "$repo_path" pull origin "$TARGET_BRANCH" --quiet 2>/dev/null || true
  fi

  # ── Write caller workflow ──
  mkdir -p "$repo_path/.github/workflows"
  echo "$expected" > "$repo_path/$workflow_path"

  # ── Commit ──
  git -C "$repo_path" add "$workflow_path"
  if git -C "$repo_path" diff --cached --quiet 2>/dev/null; then
    log_ok "Up to date (no diff after write)"
    ((up_to_date++)) || true
    [[ -n "$original_branch" ]] && git -C "$repo_path" checkout "$original_branch" --quiet 2>/dev/null || true
    return 0
  fi
  git -C "$repo_path" commit -m "$COMMIT_MSG" --quiet

  # ── Push ──
  if [[ "$MODE" == "pr" ]]; then
    if ! git -C "$repo_path" push origin "$SYNC_BRANCH" --force-with-lease --quiet 2>/dev/null; then
      log_fail "Push failed"
      failed_repos+=("$repo_name (push)")
      ((failed++)) || true
      [[ -n "$original_branch" ]] && git -C "$repo_path" checkout "$original_branch" --quiet 2>/dev/null || true
      return 0
    fi

    # Open PR targeting develop
    local pr_url
    pr_url=$(gh pr create \
      --repo "$org/$repo_name" \
      --base "$TARGET_BRANCH" \
      --head "$SYNC_BRANCH" \
      --title "$COMMIT_MSG" \
      --body "Syncs \`dev-publish.yml\` caller workflow from \`REPO_MANIFEST.toml\`.

Crates: \`$crates\`
Variant: $variant (tier $tier)

Source: [REPO_MANIFEST.toml](https://github.com/greenticai/.github/blob/main/toolchain/REPO_MANIFEST.toml)" 2>/dev/null || echo "")

    if [[ -n "$pr_url" ]]; then
      log_ok "Synced → PR: $pr_url"
    else
      # PR might already exist
      local existing
      existing=$(gh pr list --repo "$org/$repo_name" --head "$SYNC_BRANCH" --base "$TARGET_BRANCH" --json url --jq '.[0].url' 2>/dev/null || echo "")
      if [[ -n "$existing" ]]; then
        log_ok "Synced → PR (updated): $existing"
      else
        log_ok "Synced & pushed (PR creation failed — create manually)"
      fi
    fi
  elif [[ "$MODE" == "direct" ]]; then
    if ! git -C "$repo_path" push origin "$TARGET_BRANCH" --quiet 2>/dev/null; then
      log_fail "Push failed"
      failed_repos+=("$repo_name (push)")
      ((failed++)) || true
      [[ -n "$original_branch" ]] && git -C "$repo_path" checkout "$original_branch" --quiet 2>/dev/null || true
      return 0
    fi
    log_ok "Synced & pushed directly ($action)"
  fi

  ((synced++)) || true

  # Return to original branch
  [[ -n "$original_branch" ]] && git -C "$repo_path" checkout "$original_branch" --quiet 2>/dev/null || true
}

# ── Main ──────────────────────────────────────────────────────────

echo -e "${BOLD}Greentic Dev-Publish Sync${RESET}"
echo -e "Target branch: $TARGET_BRANCH"
echo -e "Mode: $MODE"
[[ -n "$SINGLE_REPO" ]] && echo -e "Single repo: $SINGLE_REPO"
[[ -n "$SINGLE_TIER" ]] && echo -e "Single tier: $SINGLE_TIER"
echo ""

# Validate prerequisites
if [[ ! -f "$MANIFEST" ]]; then
  echo -e "${RED}Missing manifest: $MANIFEST${RESET}" >&2
  exit 1
fi

current_tier=""

# Parse manifest and process repos (sorted by tier)
while IFS=$'\t' read -r org variant tier crates exclude_crates setup_script binary_crates dual_role_binary_crates repo_name; do
  # Strip sentinel back to empty string (see parse_manifest note).
  [[ "$exclude_crates"          == "_NONE_" ]] && exclude_crates=""
  [[ "$setup_script"            == "_NONE_" ]] && setup_script=""
  [[ "$binary_crates"           == "_NONE_" ]] && binary_crates=""
  [[ "$dual_role_binary_crates" == "_NONE_" ]] && dual_role_binary_crates=""

  # Filter to single repo if specified
  if [[ -n "$SINGLE_REPO" && "$repo_name" != "$SINGLE_REPO" ]]; then
    continue
  fi

  # Filter to single tier if specified
  if [[ -n "$SINGLE_TIER" && "$tier" != "$SINGLE_TIER" ]]; then
    continue
  fi

  # Print tier header
  if [[ "$tier" != "$current_tier" ]]; then
    current_tier="$tier"
    echo -e "${BOLD}━━━ Tier $tier ━━━${RESET}"
  fi

  echo -e "${CYAN}${BOLD}[$org/$repo_name]${RESET} (tier $tier, $variant)"
  sync_repo "$org" "$variant" "$tier" "$crates" "$exclude_crates" "$setup_script" "$binary_crates" "$dual_role_binary_crates" "$repo_name"
done < <(parse_manifest)

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ Summary ━━━${RESET}"
echo -e "  ${GREEN}Synced:${RESET}       $synced"
echo -e "  ${GREEN}Up to date:${RESET}   $up_to_date"
[[ "$skipped" -gt 0 ]]  && echo -e "  ${YELLOW}Skipped:${RESET}      $skipped"
[[ "$drifted" -gt 0 ]]  && echo -e "  ${YELLOW}Drifted:${RESET}      $drifted"
[[ "$failed" -gt 0 ]]   && echo -e "  ${RED}Failed:${RESET}       $failed"

if [[ ${#failed_repos[@]} -gt 0 ]]; then
  echo ""
  echo -e "  ${RED}Failed repos:${RESET}"
  for r in "${failed_repos[@]}"; do
    echo -e "    ${RED}•${RESET} $r"
  done
fi

if [[ ${#drifted_repos[@]} -gt 0 ]]; then
  echo ""
  echo -e "  ${YELLOW}Drifted repos:${RESET}"
  for r in "${drifted_repos[@]}"; do
    echo -e "    ${YELLOW}•${RESET} $r"
  done
fi

echo ""

# Exit code
if [[ "$MODE" == "check" && "$drifted" -gt 0 ]]; then
  exit 1
fi
exit "$failed"
