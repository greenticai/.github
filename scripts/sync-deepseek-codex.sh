#!/usr/bin/env bash
# sync-deepseek-codex.sh — Deploy DeepSeek remediation callers to enrolled repos.
#
# Reads `nightly-codex-enabled = true && !archived` from REPO_MANIFEST.toml
# and writes two caller workflows in each matched repo:
#
#   .github/workflows/codex-security-fix.yml  (rendered from
#       .github/scripts/templates/deepseek-codex-security.yml.tmpl)
#   .github/workflows/codex-semver-fix.yml    (rendered from
#       .github/scripts/templates/deepseek-codex-semver.yml.tmpl)
#
# Each caller invokes the central reusable in greenticai/.github at @main.
# File names stay `codex-*-fix.yml` through Phase G of
# plans/migrate-codex-deepseek.md to preserve caller compatibility and the
# Slack-mute guard in notify-failure.yml.
#
# Cron staggering: a SHA-256 hash of the repo name picks a deterministic
# minute within the 03:00–03:33 UTC window for the security workflow; the
# semver workflow runs 20 minutes later (matches the pre-migration shape).
# No fleet-wide concurrency — OpenRouter has no parallel-session cap.
#
# Usage (run from the workspace root, one level above the .github checkout):
#   bash .github/scripts/sync-deepseek-codex.sh             # PR per repo
#   bash .github/scripts/sync-deepseek-codex.sh --dry-run   # show plan, no writes
#   bash .github/scripts/sync-deepseek-codex.sh --check     # CI gate: exit 1 on drift
#   bash .github/scripts/sync-deepseek-codex.sh --repo NAME # single repo
#   bash .github/scripts/sync-deepseek-codex.sh --target develop  # PR to develop
#
# Requires: gh, git, python3.
#
# Idempotent. Re-running on an in-sync repo counts as `up_to_date`; re-running
# on a repo with an open sync PR force-pushes the branch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
BIZ_DIR="${BIZ_DIR:-$WORKSPACE/GREENTIC-BIZ}"
CANONICAL_DIR="$WORKSPACE/.github/toolchain"
MANIFEST="$CANONICAL_DIR/REPO_MANIFEST.toml"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
SECURITY_TEMPLATE="$TEMPLATE_DIR/deepseek-codex-security.yml.tmpl"
SEMVER_TEMPLATE="$TEMPLATE_DIR/deepseek-codex-semver.yml.tmpl"

declare -A ORG_DIRS=(
  [greenticai]="$WORKSPACE"
  [greentic-biz]="$BIZ_DIR"
)

MODE="pr"            # pr | dry-run | check
SINGLE_REPO=""
TARGET_BRANCH="main"
SYNC_BRANCH="chore/sync-deepseek-codex-callers"
COMMIT_MSG="chore(ci): regenerate codex remediation callers (deepseek/openrouter)"

# Workflow file paths in each target repo. Stay `codex-*-fix.yml` through
# Phase G of plans/migrate-codex-deepseek.md.
SECURITY_WORKFLOW=".github/workflows/codex-security-fix.yml"
SEMVER_WORKFLOW=".github/workflows/codex-semver-fix.yml"

shift_next=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE="dry-run" ;;
    --check)   MODE="check" ;;
    --repo)    shift_next="repo"; continue ;;
    --target)  shift_next="target"; continue ;;
    --help|-h)
      sed -n '2,32p' "$0"
      exit 0
      ;;
    *)
      if [[ "${shift_next:-}" == "repo" ]]; then
        SINGLE_REPO="$arg"; shift_next=""
      elif [[ "${shift_next:-}" == "target" ]]; then
        TARGET_BRANCH="$arg"; shift_next=""
      else
        echo "Unknown argument: $arg" >&2; exit 1
      fi
      ;;
  esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

synced=0
up_to_date=0
skipped=0
drifted=0
failed=0
declare -a failed_repos=()
declare -a drifted_repos=()

log_ok()    { echo -e "  ${GREEN}✓${RESET} $1"; }
log_skip()  { echo -e "  ${YELLOW}⊘${RESET} $1"; }
log_fail()  { echo -e "  ${RED}✗${RESET} $1"; }
log_info()  { echo -e "  ${BLUE}→${RESET} $1"; }
log_drift() { echo -e "  ${YELLOW}⚠${RESET} $1"; }

# Deterministic minute-within-hour for a given repo name. Security gets the
# raw hash mod 33 (range 0–32); semver runs 20 minutes later (range 20–52).
# Both stay within the 03:00–03:53 UTC window, matching the pre-migration
# stagger shape.
cron_minute() {
  local repo_name="$1"
  python3 -c "
import hashlib
print(int(hashlib.sha256(b'$repo_name').hexdigest(), 16) % 33)
"
}

# Render a template, substituting {{CRON_SECURITY}} / {{CRON_SEMVER}}.
render_template() {
  local template="$1"
  local cron_sec="$2"
  local cron_sem="$3"
  sed -e "s/{{CRON_SECURITY}}/$cron_sec/g" \
      -e "s/{{CRON_SEMVER}}/$cron_sem/g" \
      "$template"
}

# Emit "org\trepo_name" for non-archived repos with nightly-codex-enabled=true.
parse_manifest() {
  python3 -c "
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
for name, e in m.get('repos', {}).items():
    if e.get('archived', False):
        continue
    if not e.get('nightly-codex-enabled', False):
        continue
    print(f\"{e['org']}\t{name}\")
" | sort -t$'\t' -k2,2
}

# Sync a single workflow file in a repo. Returns 0 on any outcome (failures
# are tallied via global counters); the caller never branches on the exit
# status. Increments counters in place.
sync_workflow() {
  local org="$1"
  local repo_name="$2"
  local repo_path="$3"
  local workflow_path="$4"
  local expected="$5"
  local label="$6"  # "security" | "semver" — only for logging

  local current
  current=$(git -C "$repo_path" show "origin/$TARGET_BRANCH:$workflow_path" 2>/dev/null || echo "")

  if [[ "$current" == "$expected" ]]; then
    log_ok "[$label] Up to date"
    ((up_to_date++)) || true
    return 0
  fi

  local action="create"
  [[ -n "$current" ]] && action="update"

  if [[ "$MODE" == "check" ]]; then
    log_drift "[$label] Drift ($action $workflow_path)"
    drifted_repos+=("$org/$repo_name:$label")
    ((drifted++)) || true
    return 0
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    log_info "[$label] Would $action $workflow_path"
    ((synced++)) || true
    return 0
  fi

  # Write the file in-repo (current branch already prepared by sync_repo).
  mkdir -p "$(dirname "$repo_path/$workflow_path")"
  printf '%s\n' "$expected" > "$repo_path/$workflow_path"

  if ! git -C "$repo_path" diff --quiet -- "$workflow_path" 2>/dev/null; then
    git -C "$repo_path" add "$workflow_path"
  fi
}

# Per-repo orchestration: fetch, branch, render both workflows, commit, PR.
sync_repo() {
  local org="$1"
  local repo_name="$2"
  local local_dir="${ORG_DIRS[$org]:-}"

  if [[ -z "$local_dir" ]]; then
    log_skip "Unknown org: $org"
    ((skipped++)) || true
    return 0
  fi

  local repo_path="$local_dir/$repo_name"
  if [[ ! -d "$repo_path/.git" ]]; then
    log_skip "Not cloned locally"
    ((skipped++)) || true
    return 0
  fi

  if ! git -C "$repo_path" fetch origin --quiet 2>/dev/null; then
    log_fail "Failed to fetch origin"
    failed_repos+=("$repo_name (fetch)")
    ((failed++)) || true
    return 0
  fi

  if ! git -C "$repo_path" rev-parse --verify "refs/remotes/origin/$TARGET_BRANCH" >/dev/null 2>&1; then
    log_skip "No '$TARGET_BRANCH' on remote"
    ((skipped++)) || true
    return 0
  fi

  local cron_sec
  cron_sec=$(cron_minute "$repo_name")
  local cron_sem=$((cron_sec + 20))

  local expected_sec
  expected_sec=$(render_template "$SECURITY_TEMPLATE" "$cron_sec" "$cron_sem")
  local expected_sem
  expected_sem=$(render_template "$SEMVER_TEMPLATE" "$cron_sec" "$cron_sem")

  # check + dry-run don't touch the working tree — compare against
  # origin/$TARGET_BRANCH directly via `git show`, no checkout required.
  if [[ "$MODE" == "check" || "$MODE" == "dry-run" ]]; then
    sync_workflow "$org" "$repo_name" "$repo_path" "$SECURITY_WORKFLOW" "$expected_sec" "security"
    sync_workflow "$org" "$repo_name" "$repo_path" "$SEMVER_WORKFLOW"   "$expected_sem" "semver"
    return 0
  fi

  # Real write path: refuse dirty trees, prepare a fresh branch off origin.
  if ! git -C "$repo_path" diff --quiet 2>/dev/null || ! git -C "$repo_path" diff --cached --quiet 2>/dev/null; then
    log_fail "Dirty working tree — skipping"
    failed_repos+=("$repo_name (dirty)")
    ((failed++)) || true
    return 0
  fi

  local original_branch
  original_branch=$(git -C "$repo_path" branch --show-current 2>/dev/null || echo "")

  git -C "$repo_path" branch -D "$SYNC_BRANCH" 2>/dev/null || true

  if ! git -C "$repo_path" checkout -b "$SYNC_BRANCH" "origin/$TARGET_BRANCH" --quiet 2>/dev/null; then
    log_fail "Cannot create branch from origin/$TARGET_BRANCH"
    failed_repos+=("$repo_name (branch)")
    ((failed++)) || true
    [[ -n "$original_branch" ]] && git -C "$repo_path" checkout "$original_branch" --quiet 2>/dev/null || true
    return 0
  fi

  sync_workflow "$org" "$repo_name" "$repo_path" "$SECURITY_WORKFLOW" "$expected_sec" "security"
  sync_workflow "$org" "$repo_name" "$repo_path" "$SEMVER_WORKFLOW"   "$expected_sem" "semver"

  if git -C "$repo_path" diff --cached --quiet 2>/dev/null; then
    log_ok "Both workflows up to date (no diff after write)"
    [[ -n "$original_branch" ]] && git -C "$repo_path" checkout "$original_branch" --quiet 2>/dev/null || true
    return 0
  fi

  if ! git -C "$repo_path" commit -m "$COMMIT_MSG" --quiet 2>/dev/null; then
    log_fail "Commit failed"
    failed_repos+=("$repo_name (commit)")
    ((failed++)) || true
    [[ -n "$original_branch" ]] && git -C "$repo_path" checkout "$original_branch" --quiet 2>/dev/null || true
    return 0
  fi

  if ! git -C "$repo_path" push origin "$SYNC_BRANCH" --force-with-lease --quiet 2>/dev/null; then
    log_fail "Push failed"
    failed_repos+=("$repo_name (push)")
    ((failed++)) || true
    [[ -n "$original_branch" ]] && git -C "$repo_path" checkout "$original_branch" --quiet 2>/dev/null || true
    return 0
  fi

  local pr_body
  pr_body=$(cat <<EOF
Regenerates the codex remediation callers in this repo against the new
DeepSeek/OpenRouter reusables (greenticai/.github#183 / Phase B of
\`plans/migrate-codex-deepseek.md\`).

The file names stay \`codex-*-fix.yml\` through Phase G so existing
\`uses:\` references and the \`notify-failure.yml\` Slack-mute guard
(\`startsWith(workflow-name, 'Codex ')\`) both keep working during the
silent pilot. The reusables they point at now run Goose + DeepSeek
through OpenRouter; nothing in this caller file references the LLM
directly.

**Cron stagger (deterministic, derived from repo name):**
- security: \`$cron_sec 3 * * *\` (window 03:00–03:32 UTC)
- semver:   \`$cron_sem 3 * * *\` (security + 20 min)

This repo's \`nightly-codex-enabled\` flag is \`true\` in
\`REPO_MANIFEST.toml\`. Flip it back to \`false\` (in the central
manifest) to opt out of regeneration — the existing caller would then
go stale on its own and any future runs of this sync script will skip
this repo.

Source: [sync-deepseek-codex.sh](https://github.com/greenticai/.github/blob/main/scripts/sync-deepseek-codex.sh)
EOF
)

  local pr_url
  pr_url=$(gh pr create \
    --repo "$org/$repo_name" \
    --base "$TARGET_BRANCH" \
    --head "$SYNC_BRANCH" \
    --title "$COMMIT_MSG" \
    --body "$pr_body" 2>/dev/null || echo "")

  if [[ -n "$pr_url" ]]; then
    log_ok "Synced → PR: $pr_url"
  else
    local existing
    existing=$(gh pr list --repo "$org/$repo_name" --head "$SYNC_BRANCH" --base "$TARGET_BRANCH" --json url --jq '.[0].url' 2>/dev/null || echo "")
    if [[ -n "$existing" ]]; then
      log_ok "Synced → PR (updated): $existing"
    else
      log_ok "Synced & pushed (PR creation failed — open manually)"
    fi
  fi

  ((synced++)) || true
  [[ -n "$original_branch" ]] && git -C "$repo_path" checkout "$original_branch" --quiet 2>/dev/null || true
}

# ── Main ─────────────────────────────────────────────────────────────

if [[ ! -f "$MANIFEST" ]]; then
  echo "Manifest not found: $MANIFEST" >&2
  exit 1
fi

for tmpl in "$SECURITY_TEMPLATE" "$SEMVER_TEMPLATE"; do
  if [[ ! -f "$tmpl" ]]; then
    echo "Template not found: $tmpl" >&2
    exit 1
  fi
done

echo -e "${BOLD}${CYAN}sync-deepseek-codex${RESET} — mode: ${BOLD}$MODE${RESET}  target: ${BOLD}$TARGET_BRANCH${RESET}"
echo ""

while IFS=$'\t' read -r org repo_name; do
  [[ -n "${SINGLE_REPO:-}" && "$repo_name" != "$SINGLE_REPO" ]] && continue
  echo -e "${BOLD}$org/$repo_name${RESET}"
  sync_repo "$org" "$repo_name"
done < <(parse_manifest)

echo ""
echo -e "${BOLD}Summary${RESET}"
echo "  synced:     $synced"
echo "  up-to-date: $up_to_date"
echo "  drifted:    $drifted"
echo "  skipped:    $skipped"
echo "  failed:     $failed"

if (( ${#drifted_repos[@]} > 0 )); then
  echo ""
  echo -e "${YELLOW}Drifted:${RESET}"
  for r in "${drifted_repos[@]}"; do echo "  - $r"; done
fi
if (( ${#failed_repos[@]} > 0 )); then
  echo ""
  echo -e "${RED}Failed:${RESET}"
  for r in "${failed_repos[@]}"; do echo "  - $r"; done
fi

if [[ "$MODE" == "check" && $drifted -gt 0 ]]; then
  exit 1
fi
if (( failed > 0 )); then
  exit 1
fi
