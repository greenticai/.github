#!/usr/bin/env bash
# sync-dependency-review.sh — Deploy dependency-review caller workflow to all Greentic repos
#
# Usage:
#   ./sync-dependency-review.sh              # create branch, commit, push, open PR
#   ./sync-dependency-review.sh --dry-run    # show what would change, change nothing
#   ./sync-dependency-review.sh --direct     # commit directly to current branch, push
#   ./sync-dependency-review.sh --check      # exit non-zero if any repo is missing/drifted
#   ./sync-dependency-review.sh --repo NAME  # single repo only
#
# Requires: gh (GitHub CLI), git, python3

set -euo pipefail

WORKSPACE="/home/vampik/greenticai"
BIZ_DIR="$WORKSPACE/GREENTIC-BIZ"
MANIFEST="$WORKSPACE/.github/toolchain/REPO_MANIFEST.toml"

# Org → local directory mapping
declare -A ORG_DIRS=(
  [greenticai]="$WORKSPACE"
  [greentic-biz]="$BIZ_DIR"
)

# Options
MODE="pr"  # pr | direct | dry-run | check
SINGLE_REPO=""
BRANCH_NAME="chore/add-dependency-review"
COMMIT_MSG="ci: add dependency review workflow"

for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE="dry-run" ;;
    --direct)  MODE="direct" ;;
    --check)   MODE="check" ;;
    --repo)    shift_next=true; continue ;;
    --help|-h)
      echo "Usage: $0 [--dry-run|--direct|--check] [--repo NAME]"
      echo ""
      echo "Modes:"
      echo "  (default)   Create branch '$BRANCH_NAME', commit, push, open PR"
      echo "  --dry-run   Show what would change, change nothing"
      echo "  --direct    Commit directly to current branch, push"
      echo "  --check     Exit non-zero if any repo is missing or drifted (for CI)"
      echo ""
      echo "Options:"
      echo "  --repo NAME  Process a single repo only"
      exit 0
      ;;
    *)
      if [[ "${shift_next:-}" == true ]]; then
        SINGLE_REPO="$arg"
        shift_next=false
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

# ── Canonical caller workflow content ────────────────────────────
CALLER_WORKFLOW='name: Dependency Review
on:
  pull_request:
    branches: [main]
permissions:
  contents: write
  pull-requests: write
jobs:
  dep-review:
    uses: greenticai/.github/.github/workflows/dependency-review.yml@main
    secrets: inherit
'

# ── Parse REPO_MANIFEST.toml ────────────────────────────────────
# Outputs lines: "org variant repo_name"
parse_manifest() {
  python3 -c "
import tomllib, sys
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
for org in m:
    for variant in m[org]:
        for repo in m[org][variant]['repos']:
            print(f'{org} {variant} {repo}')
"
}

# ── Sync one repo ───────────────────────────────────────────────
sync_repo() {
  local org="$1"
  local repo_name="$2"
  local local_dir="${ORG_DIRS[$org]}"
  local repo_path="$local_dir/$repo_name"
  local workflow_file="$repo_path/.github/workflows/dependency-review.yml"

  # Check repo exists locally
  if [[ ! -d "$repo_path/.git" ]]; then
    log_skip "$repo_name — not cloned locally"
    ((skipped++)) || true
    return 0
  fi

  # Compare content
  local needs_update=false
  if [[ -f "$workflow_file" ]]; then
    local existing
    existing=$(cat "$workflow_file")
    if [[ "$existing" != "$CALLER_WORKFLOW" ]]; then
      needs_update=true
    fi
  else
    needs_update=true
  fi

  if [[ "$needs_update" == false ]]; then
    log_ok "Up to date"
    ((up_to_date++)) || true
    return 0
  fi

  # ── Mode: check ──
  if [[ "$MODE" == "check" ]]; then
    if [[ -f "$workflow_file" ]]; then
      log_drift "Content drifted from canonical"
    else
      log_drift "Missing dependency-review.yml"
    fi
    drifted_repos+=("$org/$repo_name")
    ((drifted++)) || true
    return 0
  fi

  # ── Mode: dry-run ──
  if [[ "$MODE" == "dry-run" ]]; then
    if [[ -f "$workflow_file" ]]; then
      log_info "Would update dependency-review.yml (content differs)"
    else
      log_info "Would create dependency-review.yml"
    fi
    ((synced++)) || true
    return 0
  fi

  # ── Mode: pr — create branch ──
  if [[ "$MODE" == "pr" ]]; then
    # Check for uncommitted changes
    if ! git -C "$repo_path" diff --quiet 2>/dev/null || ! git -C "$repo_path" diff --cached --quiet 2>/dev/null; then
      log_skip "Dirty working tree — skipping"
      ((skipped++)) || true
      return 0
    fi

    # Stash current branch to return later
    local original_branch
    original_branch=$(git -C "$repo_path" branch --show-current 2>/dev/null || echo "")

    # Fetch and create branch from default branch
    local default_branch
    default_branch=$(git -C "$repo_path" remote show origin 2>/dev/null | grep "HEAD branch" | sed 's/.*: //')
    if [[ -z "$default_branch" ]]; then
      default_branch="main"
    fi

    git -C "$repo_path" fetch origin "$default_branch" --quiet 2>/dev/null || true

    # Delete existing sync branch if present
    git -C "$repo_path" branch -D "$BRANCH_NAME" 2>/dev/null || true

    # Create branch from origin/default
    if ! git -C "$repo_path" checkout -b "$BRANCH_NAME" "origin/$default_branch" --quiet 2>/dev/null; then
      log_fail "Cannot create branch from origin/$default_branch"
      failed_repos+=("$repo_name (branch)")
      ((failed++)) || true
      [[ -n "$original_branch" ]] && git -C "$repo_path" checkout "$original_branch" --quiet 2>/dev/null || true
      return 0
    fi
  fi

  # ── Write workflow file ──
  mkdir -p "$repo_path/.github/workflows"
  echo -n "$CALLER_WORKFLOW" > "$workflow_file"

  # ── Commit ──
  git -C "$repo_path" add .github/workflows/dependency-review.yml
  if ! git -C "$repo_path" diff --cached --quiet 2>/dev/null; then
    git -C "$repo_path" commit -m "$COMMIT_MSG" --quiet
  fi

  # ── Push ──
  if [[ "$MODE" == "pr" ]]; then
    if ! git -C "$repo_path" push origin "$BRANCH_NAME" --force-with-lease --quiet 2>/dev/null; then
      log_fail "Push failed"
      failed_repos+=("$repo_name (push)")
      ((failed++)) || true
      return 0
    fi

    # Open PR
    local pr_url
    pr_url=$(gh pr create \
      --repo "$org/$repo_name" \
      --head "$BRANCH_NAME" \
      --title "$COMMIT_MSG" \
      --body "$(cat <<'PRBODY'
## Summary
- Adds standalone dependency review as a required PR check
- Uses the reusable two-job workflow from `greenticai/.github`
- Job 1 (`dependency-review`) always runs on PRs — no API key gate
- Job 2 (`codex-dependency-fix`) optional Codex auto-remediation when vulnerabilities found

Part of Task 2.3 — Universal Dependency Review rollout.

## Test plan
- [ ] Verify `dependency-review` job runs on this PR
- [ ] Verify `codex-dependency-fix` is skipped (no vulnerabilities in this PR)
PRBODY
)" 2>/dev/null || echo "")

    if [[ -n "$pr_url" ]]; then
      log_ok "Synced → PR: $pr_url"
    else
      # PR might already exist
      local existing
      existing=$(gh pr list --repo "$org/$repo_name" --head "$BRANCH_NAME" --json url --jq '.[0].url' 2>/dev/null || echo "")
      if [[ -n "$existing" ]]; then
        log_ok "Synced → PR (updated): $existing"
      else
        log_ok "Synced & pushed (PR creation failed — create manually)"
      fi
    fi
  elif [[ "$MODE" == "direct" ]]; then
    if ! git -C "$repo_path" push --quiet 2>/dev/null; then
      log_fail "Push failed"
      failed_repos+=("$repo_name (push)")
      ((failed++)) || true
      return 0
    fi
    log_ok "Synced & pushed directly"
  fi

  ((synced++)) || true
}

# ── Main ────────────────────────────────────────────────────────

echo -e "${BOLD}Greentic Dependency Review Sync${RESET}"
echo -e "Mode: $MODE"
[[ -n "$SINGLE_REPO" ]] && echo -e "Single repo: $SINGLE_REPO"
echo ""

# Validate manifest exists
if [[ ! -f "$MANIFEST" ]]; then
  echo -e "${RED}Missing manifest: $MANIFEST${RESET}" >&2
  exit 1
fi

# Parse manifest and process repos (deduplicate — a repo appears once per variant)
declare -A seen_repos=()

while IFS=' ' read -r org variant repo_name; do
  # Skip duplicates (repo listed in both host and wasm won't happen, but be safe)
  key="$org/$repo_name"
  if [[ -n "${seen_repos[$key]:-}" ]]; then
    continue
  fi
  seen_repos[$key]=1

  # Filter to single repo if specified
  if [[ -n "$SINGLE_REPO" && "$repo_name" != "$SINGLE_REPO" ]]; then
    continue
  fi

  echo -e "${CYAN}${BOLD}[$org/$repo_name]${RESET}"
  sync_repo "$org" "$repo_name"
done < <(parse_manifest)

# ── Summary ─────────────────────────────────────────────────────
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
