#!/usr/bin/env bash
# forward-port.sh — Merge main → develop across all Greentic repos
#
# For each repo in REPO_MANIFEST.toml that has a develop branch:
# 1. Clone repo, checkout develop, merge main --no-edit
# 2. If merge succeeds cleanly: push directly to develop
# 3. If merge has conflicts: create a PR with conflict markers
#
# Intended to run after each weekly-stable release to keep develop
# current with stable patches. Also available via workflow_dispatch.
#
# Environment:
#   GH_TOKEN_GREENTICAI    — App token scoped to greenticai org installation
#   GH_TOKEN_GREENTIC_BIZ  — App token scoped to greentic-biz org installation
#   GH_TOKEN               — Fallback when per-org tokens aren't set (e.g. local runs)
#   INPUT_REPO             — (optional) Process a single repo by name
#   INPUT_TIER             — (optional) Process a specific tier only
#   INPUT_DRY_RUN          — (optional) "true" to preview without pushing/PRs

set -euo pipefail

MANIFEST="toolchain/REPO_MANIFEST.toml"
FORWARD_PORT_LABEL="forward-port"

DRY_RUN="${INPUT_DRY_RUN:-false}"
REPO_FILTER="${INPUT_REPO:-}"
TIER_FILTER="${INPUT_TIER:-}"

# Per-org tokens, with single-token fallback for local invocation.
GH_TOKEN_GREENTICAI="${GH_TOKEN_GREENTICAI:-${GH_TOKEN:-}}"
GH_TOKEN_GREENTIC_BIZ="${GH_TOKEN_GREENTIC_BIZ:-${GH_TOKEN:-}}"

token_for_org() {
  case "$1" in
    greenticai)   echo "$GH_TOKEN_GREENTICAI" ;;
    greentic-biz) echo "$GH_TOKEN_GREENTIC_BIZ" ;;
    *)            echo "::error::Unknown org '$1' — no token available" >&2; return 1 ;;
  esac
}

# Counters
merged_clean=0
conflict_prs=0
skipped_no_develop=0
skipped_up_to_date=0
failed=0

# ── Helpers ──────────────────────────────────────────────────────

log()  { echo "$1"; }
err()  { echo "::error::$1"; }
warn() { echo "::warning::$1"; }

# ── Parse manifest ───────────────────────────────────────────────
# All non-archived repos (forward-port applies to all repos with develop,
# not just those with weekly-stable-enabled).
get_repos() {
  python3 -c "
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
entries = []
for name, entry in m.get('repos', {}).items():
    if entry.get('archived', False):
        continue
    tier = entry.get('tier', 99)
    entries.append((tier, entry['org'], name))
entries.sort()
for tier, org, name in entries:
    print(f'{tier}\t{org}\t{name}')
"
}

# ── Check repo is reachable with current token ──────────────────
# Catches token-scope bugs where the wrong org's token would 404 on every
# repo of the other org and the script would silently classify them all as
# "no develop branch". With reachability proven first, has_develop's miss
# below is unambiguously a missing branch.
repo_reachable() {
  local repo="$1"
  gh api "repos/$repo" --silent 2>/dev/null
}

# ── Check if develop branch exists ───────────────────────────────
has_develop() {
  local repo="$1"
  gh api "repos/$repo/git/ref/heads/develop" --silent 2>/dev/null
}

# ── Check if there are new commits on main since develop ─────────
has_new_commits() {
  local repo="$1"
  local count
  count=$(gh api "repos/$repo/compare/develop...main" --jq '.total_commits' 2>/dev/null) || count=""
  [[ -n "$count" && "$count" != "0" ]]
}

# ── Ensure forward-port label exists ─────────────────────────────
ensure_label() {
  local repo="$1"
  if ! gh label list --repo "$repo" --json name --jq '.[].name' 2>/dev/null | grep -qx "$FORWARD_PORT_LABEL"; then
    gh label create "$FORWARD_PORT_LABEL" --repo "$repo" \
      --description "Automated forward-port from main to develop" \
      --color "1D76DB" 2>/dev/null || true
  fi
}

# ── Forward-port one repo ────────────────────────────────────────
forward_port_repo() {
  local repo="$1"    # org/name
  local name="$2"    # short name
  local org="$3"     # org alone

  # Select the per-org App token. Both `gh api` and the clone URL below pick
  # this up via $GH_TOKEN, so set it for the duration of this function call.
  local GH_TOKEN
  GH_TOKEN="$(token_for_org "$org")" || { ((failed++)) || true; return 1; }
  export GH_TOKEN
  if [[ -z "$GH_TOKEN" ]]; then
    err "$name — no token available for org '$org'"
    ((failed++)) || true
    return 1
  fi

  # 1a. Reachability — fail loud on auth/scope errors so we never silently
  # mis-skip a whole org's repos as "no develop branch" again.
  if ! repo_reachable "$repo"; then
    err "$name — repo unreachable (token scope or App not installed in '$org'?)"
    ((failed++)) || true
    return 1
  fi

  # 1b. Check develop exists
  if ! has_develop "$repo"; then
    log "  ⊘ $name — no develop branch"
    ((skipped_no_develop++)) || true
    return 0
  fi

  # 2. Check if main has commits ahead of develop
  if ! has_new_commits "$repo"; then
    log "  ⊘ $name — develop is up to date with main"
    ((skipped_up_to_date++)) || true
    return 0
  fi

  # 3. Dry run stops here
  if [[ "$DRY_RUN" == "true" ]]; then
    log "  [dry-run] $name — would forward-port main → develop"
    ((merged_clean++)) || true
    return 0
  fi

  # 4. Clone and attempt merge
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  if ! git clone --no-tags \
      "https://x-access-token:${GH_TOKEN}@github.com/$repo.git" \
      "$tmpdir" 2>/dev/null; then
    err "$name — clone failed"
    ((failed++)) || true
    return 1
  fi

  # Capture subshell exit code. The "|| exit_code=$?" suppresses set -e
  # for the subshell (bash doesn't trigger errexit on commands in || chains).
  local exit_code=0
  (
    cd "$tmpdir"
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

    git checkout develop 2>/dev/null

    # 5. Attempt merge
    if git merge origin/main --no-edit 2>/dev/null; then
      # Clean merge — check if there's actually anything new
      if [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/develop)" ]]; then
        echo "  ⊘ $name — already up to date after merge (no-op)"
        exit 100  # signal: up to date
      fi

      # Try direct push first; if blocked (branch protection), fall back to PR
      if git push origin develop 2>/dev/null; then
        echo "  ✓ $name — merged cleanly and pushed"
        exit 0
      else
        echo "  ℹ $name — direct push blocked (branch protection), creating PR"
        local branch="forward-port/main-to-develop-$(date -u '+%Y%m%d')"
        git checkout -b "$branch" 2>/dev/null
        git push origin "$branch" 2>/dev/null || {
          echo "::error::$name — failed to push forward-port branch"
          exit 1
        }
        exit 201  # signal: clean merge but needs PR (protected branch)
      fi
    else
      # Merge failed — conflicts
      echo "  ⚡ $name — conflicts detected, creating PR"

      # Abort the merge, create a branch for the conflict PR
      git merge --abort 2>/dev/null || true

      local branch="forward-port/main-to-develop-$(date -u '+%Y%m%d')"
      git checkout -b "$branch" origin/main 2>/dev/null

      git push origin "$branch" 2>/dev/null || {
        echo "::error::$name — failed to push conflict branch"
        exit 1
      }

      exit 200  # signal: needs conflict PR
    fi
  ) || exit_code=$?

  case "$exit_code" in
    0)
      ((merged_clean++)) || true
      ;;
    100)
      log "  ⊘ $name — already up to date"
      ((skipped_up_to_date++)) || true
      ;;
    201)
      # Clean merge but branch is protected — create PR
      ensure_label "$repo"

      local branch="forward-port/main-to-develop-$(date -u '+%Y%m%d')"
      local pr_url
      pr_url=$(gh pr create --repo "$repo" --base develop --head "$branch" \
        --title "chore: forward-port main → develop" \
        --label "$FORWARD_PORT_LABEL" \
        --body "$(cat <<BODY
## Forward-port: main → develop

Automated forward-port of \`main\` into \`develop\`. Merge is clean (no conflicts).

---
_Automated by [forward-port](https://github.com/greenticai/.github/actions/workflows/forward-port.yml)._
BODY
)" 2>&1) || {
        err "$name — forward-port PR creation failed: $pr_url"
        ((failed++)) || true
        return 1
      }

      log "  ✓ $name — forward-port PR: $pr_url"
      ((merged_clean++)) || true
      ;;
    200)
      # Conflict PR
      ensure_label "$repo"

      local branch="forward-port/main-to-develop-$(date -u '+%Y%m%d')"
      local pr_url
      pr_url=$(gh pr create --repo "$repo" --base develop --head "$branch" \
        --title "chore: forward-port main → develop (conflicts)" \
        --label "$FORWARD_PORT_LABEL" \
        --body "$(cat <<BODY
## Forward-port: main → develop

Automated forward-port detected merge conflicts that need manual resolution.

**Action required:** Resolve the conflicts in this PR to keep \`develop\` current with \`main\`.

The longer conflicts accumulate, the harder they become to resolve. Please address this promptly.

---
_Automated by [forward-port](https://github.com/greenticai/.github/actions/workflows/forward-port.yml)._
BODY
)" 2>&1) || {
        err "$name — conflict PR creation failed: $pr_url"
        ((failed++)) || true
        return 1
      }

      log "  ⚡ $name — conflict PR: $pr_url"
      ((conflict_prs++)) || true
      ;;
    *)
      err "$name — forward-port failed (exit $exit_code)"
      ((failed++)) || true
      ;;
  esac
}

# ── Main ─────────────────────────────────────────────────────────

log "Forward Port — $(date -u '+%Y-%m-%d %H:%M UTC')"
log "Dry run: $DRY_RUN"
[[ -n "$REPO_FILTER" ]] && log "Repo filter: $REPO_FILTER"
[[ -n "$TIER_FILTER" ]] && log "Tier filter: $TIER_FILTER"
log ""

current_tier=""

while IFS=$'\t' read -r tier org name; do
  # Apply filters
  [[ -n "$TIER_FILTER" && "$tier" != "$TIER_FILTER" ]] && continue
  [[ -n "$REPO_FILTER" && "$name" != "$REPO_FILTER" ]] && continue

  # Tier header on boundary change
  if [[ "$tier" != "$current_tier" ]]; then
    [[ -n "$current_tier" ]] && log ""
    log "── Tier $tier ──"
    current_tier="$tier"
  fi

  full="$org/$name"
  forward_port_repo "$full" "$name" "$org"

done < <(get_repos)

# ── Summary ──────────────────────────────────────────────────────

log ""
log "━━━ Summary ━━━"
log "  Merged cleanly:       $merged_clean"
log "  Conflict PRs:         $conflict_prs"
log "  Skipped (no develop): $skipped_no_develop"
log "  Skipped (up to date): $skipped_up_to_date"
log "  Failed:               $failed"

cat >> "${GITHUB_STEP_SUMMARY:-/dev/null}" <<EOF
## Forward Port — $(date -u '+%Y-%m-%d')

| Metric | Count |
|--------|-------|
| Merged cleanly | $merged_clean |
| Conflict PRs created | $conflict_prs |
| Skipped (no develop) | $skipped_no_develop |
| Skipped (up to date) | $skipped_up_to_date |
| Failed | $failed |
EOF

[[ "$failed" -eq 0 ]]
