#!/usr/bin/env bash
# nightly-develop-orchestrate.sh — Tier-ordered dev-publish orchestration
#
# Dispatches dev-publish.yml across repos in tier order (0→9).
# Repos within a tier are dispatched in parallel, then waited on.
# Change-aware: skips repos with no source or upstream changes.
#
# Environment:
#   GREENTIC_CI_APP_ID           — App ID for token minting (required in CI)
#   GREENTIC_CI_APP_PRIVATE_KEY  — App PEM key for token minting (required in CI)
#   GH_TOKEN                     — fallback for local invocation only; in CI
#                                  the script mints per-org tokens itself
#   INPUT_TIER                   — (optional) Process a specific tier only
#   INPUT_FORCE                  — (optional) "true" to skip change detection
#
# Why mint internally instead of accepting one upfront token:
#   App installation tokens have a 1-hour TTL. A nightly orchestrate run can
#   easily run >1h (long binary repos in tier 7 alone routinely take 15 min).
#   Once the seed token expires mid-run, every `gh run view` poll returns
#   401, wait_for_all interprets that as "still pending", and the tier
#   stalls until MAX_WAIT (3600s) before being declared a phantom timeout.
#   Re-minting on demand here means the script is robust to its own length.
#   It also lets a single script touch both greenticai and greentic-biz
#   repos (one App, two installations) without the workflow having to
#   pre-mint two tokens upfront.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MANIFEST="toolchain/REPO_MANIFEST.toml"
WORKFLOW="dev-publish.yml"
BRANCH="develop"
POLL_INTERVAL=30    # seconds between status polls
MAX_WAIT=3600       # max seconds to wait per tier (1 hour)
DISPATCH_DETECT=5   # seconds between dispatch detection polls
DISPATCH_TIMEOUT=24 # max polls to detect dispatched run (24*5s = 2min)
TOKEN_REFRESH_SEC=2700  # re-mint at 45 min — leaves 15 min headroom on 1h TTL

FORCE="${INPUT_FORCE:-false}"
TIER_FILTER="${INPUT_TIER:-}"

# ── Per-org token state ──────────────────────────────────────────
# Cached token + last-mint timestamp per org. ensure_token_for_org()
# refreshes automatically when older than TOKEN_REFRESH_SEC. Local-dev fallback:
# if APP_ID/PRIVATE_KEY are not set, treat $GH_TOKEN as both org tokens
# (caller is responsible for ensuring it covers any repos they touch).
GH_TOKEN_GREENTICAI=""
GH_TOKEN_GREENTIC_BIZ=""
GH_TOKEN_GREENTICAI_AT=0
GH_TOKEN_GREENTIC_BIZ_AT=0
HAVE_APP_CREDS=true
if [[ -z "${GREENTIC_CI_APP_ID:-}" || -z "${GREENTIC_CI_APP_PRIVATE_KEY:-}" ]]; then
  HAVE_APP_CREDS=false
  GH_TOKEN_GREENTICAI="${GH_TOKEN:-}"
  GH_TOKEN_GREENTIC_BIZ="${GH_TOKEN:-}"
fi

mint_token_for_org() {
  local org="$1"
  local now token
  now=$(date +%s)
  if ! token=$("$SCRIPT_DIR/mint-app-token.sh" "$org" 2>&1); then
    echo "::error::Failed to mint App token for $org: $token" >&2
    return 1
  fi
  case "$org" in
    greenticai)
      GH_TOKEN_GREENTICAI="$token"
      GH_TOKEN_GREENTICAI_AT=$now
      ;;
    greentic-biz)
      GH_TOKEN_GREENTIC_BIZ="$token"
      GH_TOKEN_GREENTIC_BIZ_AT=$now
      ;;
    *)
      echo "::error::Unknown org '$org' for mint" >&2
      return 1
      ;;
  esac
}

# Ensures a fresh token is cached for $org and exports GH_TOKEN to it.
# No stdout capture — the token cache lives in globals, and capturing the
# return value via $(...) would put mint_token_for_org in a subshell, losing
# the cached value the moment the subshell exits.
ensure_token_for_org() {
  local org="$1"
  local cached_at=0
  case "$org" in
    greenticai)   cached_at=$GH_TOKEN_GREENTICAI_AT ;;
    greentic-biz) cached_at=$GH_TOKEN_GREENTIC_BIZ_AT ;;
    *)            echo "::error::Unknown org '$org'" >&2; return 1 ;;
  esac

  if [[ "$HAVE_APP_CREDS" == true ]]; then
    local now age
    now=$(date +%s)
    age=$((now - cached_at))
    if [[ $cached_at -eq 0 || $age -ge $TOKEN_REFRESH_SEC ]]; then
      mint_token_for_org "$org" || return 1
    fi
  fi

  case "$org" in
    greenticai)   GH_TOKEN="$GH_TOKEN_GREENTICAI" ;;
    greentic-biz) GH_TOKEN="$GH_TOKEN_GREENTIC_BIZ" ;;
  esac
  export GH_TOKEN
}

# Convenience wrapper: ensure a fresh GH_TOKEN for the repo's org. Call at
# the top of any function block that runs gh CLI / curl against $repo.
use_token_for_repo() {
  local repo="$1"
  local org="${repo%%/*}"
  ensure_token_for_org "$org"
}

# Counters
dispatched=0
succeeded=0
skipped_no_changes=0
skipped_no_branch=0
failed=0
halted=false
lower_tier_published=false
published_names=""
first_failed_repo=""
first_failed_tier=""
first_failed_job_name=""
first_failed_job_url=""
first_failure_error=""
declare -a failure_lines=()

# ── Helpers ──────────────────────────────────────────────────────

log()  { echo "$1"; }
err()  { echo "::error::$1"; }
warn() { echo "::warning::$1"; }

record_failure() {
  local repo="$1"
  local tier="$2"
  local error="$3"
  local job_name="${4:-}"
  local job_url="${5:-}"

  [[ -n "$first_failure_error" ]] && return 0

  first_failed_repo="$repo"
  first_failed_tier="$tier"
  first_failed_job_name="$job_name"
  first_failed_job_url="$job_url"
  first_failure_error="$error"
}

append_failure_line() {
  local repo="$1"
  local tier="$2"
  local error="$3"
  local job_name="${4:-}"
  local job_url="${5:-}"

  local line="- ${repo}"
  [[ -n "$tier" ]] && line="${line} (tier ${tier})"

  if [[ -n "$job_url" ]]; then
    local label="${job_name:-failed job}"
    line="${line}: <${job_url}|${label}>"
  fi

  line="${line} — ${error}"
  failure_lines+=("$line")
}

get_failed_job_details() {
  local repo="$1"
  local run_id="$2"

  use_token_for_repo "$repo" || return 1

  gh api "repos/$repo/actions/runs/$run_id/jobs?per_page=100" \
    --jq '(
        [.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure")]
        + [.jobs[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "failure" and .conclusion != "timed_out" and .conclusion != "action_required" and .conclusion != "startup_failure")]
      )
      | .[0]?
      | [.name, (.id | tostring), .conclusion]
      | @tsv' 2>/dev/null | head -n 1
}

# ── Change detection ─────────────────────────────────────────────
# Returns 0 if repo needs publishing, 1 if no changes.
has_changes() {
  local repo="$1"  # org/name format

  use_token_for_repo "$repo" || return 0  # can't auth → assume changed

  # Last successful dev-publish run SHA on develop
  local last_sha
  last_sha=$(gh run list --repo "$repo" --workflow "$WORKFLOW" \
    --status success --branch "$BRANCH" --limit 1 \
    --json headSha --jq '.[0].headSha // empty' 2>/dev/null) || true

  # Never published → needs publish
  [[ -z "$last_sha" ]] && return 0

  # Current develop HEAD
  local current_sha
  current_sha=$(gh api "repos/$repo/git/ref/heads/$BRANCH" \
    --jq '.object.sha' 2>/dev/null) || return 0  # can't read → assume changed

  # Same SHA → no changes
  [[ "$last_sha" != "$current_sha" ]]
}

# ── Dispatch + detect ────────────────────────────────────────────
# Dispatches workflow_dispatch and returns the new run ID.
dispatch() {
  local repo="$1"

  use_token_for_repo "$repo" || return 1

  # Record latest run ID before dispatch (monotonically increasing)
  local before_id
  before_id=$(gh run list --repo "$repo" --workflow "$WORKFLOW" \
    --branch "$BRANCH" --limit 1 \
    --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null) || before_id=0

  # Dispatch (capture output to keep URL off stdout — caller reads stdout for run ID)
  local dispatch_err
  if ! dispatch_err=$(gh workflow run "$WORKFLOW" --repo "$repo" --ref "$BRANCH" 2>&1); then
    err "Failed to dispatch $WORKFLOW in $repo: $dispatch_err"
    return 1
  fi

  # Poll for new run (ID > before_id)
  local run_id
  for _ in $(seq 1 "$DISPATCH_TIMEOUT"); do
    sleep "$DISPATCH_DETECT"
    run_id=$(gh run list --repo "$repo" --workflow "$WORKFLOW" \
      --branch "$BRANCH" --limit 1 \
      --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null) || continue

    if [[ "$run_id" -gt "$before_id" ]]; then
      echo "$run_id"
      return 0
    fi
  done

  err "Timed out detecting dispatched run for $repo"
  return 1
}

# ── Wait for multiple runs ───────────────────────────────────────
# Args: "org/repo:run_id" entries. Returns 0 if all succeeded.
wait_for_all() {
  local -a entries=("$@")
  local count=${#entries[@]}
  local elapsed=0
  local -A done_map=()
  local any_failed=false

  while true; do
    local pending=0

    for entry in "${entries[@]}"; do
      [[ -n "${done_map[$entry]:-}" ]] && continue

      local repo="${entry%%:*}"
      local run_id="${entry##*:}"
      local name="${repo##*/}"

      # Refresh-aware token select per repo so long polls don't 401 on
      # an expired token mid-wait.
      use_token_for_repo "$repo" || {
        warn "could not select token for $name"
        ((pending++)) || true
        continue
      }

      local result
      if ! result=$(gh run view "$run_id" --repo "$repo" \
          --json status,conclusion \
          --jq '[.status, .conclusion // ""] | @tsv' 2>&1); then
        warn "gh run view failed for $name (run $run_id): $result"
        ((pending++)) || true
        continue
      fi

      local status conclusion
      status=$(echo "$result" | cut -f1)
      conclusion=$(echo "$result" | cut -f2)

      if [[ -z "$status" ]]; then
        warn "Empty status for $name (run $run_id), raw: '$result'"
        ((pending++)) || true
        continue
      fi

      if [[ "$status" == "completed" ]]; then
        done_map["$entry"]=1
        if [[ "$conclusion" == "success" ]]; then
          log "    ✓ $name (run $run_id)"
        else
          log "    ✗ $name — $conclusion (run $run_id)"
          err "$name dev-publish $conclusion — https://github.com/$repo/actions/runs/$run_id"
          any_failed=true
        fi
      else
        ((pending++)) || true
      fi
    done

    [[ "$pending" -eq 0 ]] && break

    if [[ "$elapsed" -ge "$MAX_WAIT" ]]; then
      err "Timed out waiting for tier runs (${elapsed}s)"
      for entry in "${entries[@]}"; do
        [[ -z "${done_map[$entry]:-}" ]] && {
          local r="${entry%%:*}"; local n="${r##*/}"
          log "    ✗ $n — timed out"
          any_failed=true
        }
      done
      break
    fi

    local done_count=${#done_map[@]}
    log "    ⏳ $done_count/$count complete (${elapsed}s)"
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  [[ "$any_failed" == false ]]
}

# ── Process one tier ─────────────────────────────────────────────
# Args: tier number, then "org/repo" entries.
process_tier() {
  local tier="$1"
  shift
  local -a repos=("$@")

  [[ ${#repos[@]} -eq 0 ]] && return 0

  echo "::group::Tier $tier — ${#repos[@]} repo(s)"

  local -a to_wait=()  # "org/repo:run_id" entries

  for full in "${repos[@]}"; do
    local name="${full##*/}"

    # Token must be valid for this repo's org before any gh call.
    if ! use_token_for_repo "$full"; then
      log "  ✗ $name — no token for org"
      record_failure "$full" "$tier" "No App token available for org"
      append_failure_line "$full" "$tier" "No App token available for org"
      ((failed++)) || true
      continue
    fi

    # Verify the repo is reachable with the current token before treating a
    # missing develop branch as authoritative — otherwise an App installation
    # gap on a private biz repo would silently masquerade as "no branch".
    if ! gh api "repos/$full" --silent 2>/dev/null; then
      err "$name — repo unreachable with current token (App installation missing on this org?)"
      record_failure "$full" "$tier" "Repo unreachable — App installation likely missing"
      append_failure_line "$full" "$tier" "Repo unreachable — App installation likely missing"
      ((failed++)) || true
      continue
    fi

    # Check develop branch exists via API
    if ! gh api "repos/$full/git/ref/heads/$BRANCH" --silent 2>/dev/null; then
      log "  ⊘ $name — no $BRANCH branch"
      ((skipped_no_branch++)) || true
      continue
    fi

    # Determine if publish is needed
    local reason=""
    if [[ "$FORCE" == "true" ]]; then
      reason="forced"
    elif [[ "$lower_tier_published" == true ]]; then
      reason="upstream changed"
    elif has_changes "$full"; then
      reason="source changes"
    else
      log "  ⊘ $name — no changes"
      ((skipped_no_changes++)) || true
      continue
    fi

    # Dispatch
    local run_id
    if run_id=$(dispatch "$full"); then
      to_wait+=("$full:$run_id")
      ((dispatched++)) || true
      log "  ▶ $name — dispatched run $run_id ($reason)"
    else
      log "  ✗ $name — dispatch failed"
      record_failure "$full" "$tier" "Failed to dispatch downstream dev-publish workflow"
      append_failure_line "$full" "$tier" "Failed to dispatch downstream dev-publish workflow"
      ((failed++)) || true
    fi
  done

  # Wait for all dispatched runs
  if [[ ${#to_wait[@]} -gt 0 ]]; then
    log ""
    log "  Waiting for ${#to_wait[@]} run(s)..."

    if wait_for_all "${to_wait[@]}"; then
      succeeded=$((succeeded + ${#to_wait[@]}))
      lower_tier_published=true
      for entry in "${to_wait[@]}"; do
        local r="${entry%%:*}"; local n="${r##*/}"
        published_names="${published_names:+$published_names, }$n"
      done
    else
      # Count individual outcomes
      for entry in "${to_wait[@]}"; do
        local repo="${entry%%:*}"
        local rid="${entry##*:}"
        local status="unknown"
        local conclusion
        local result
        use_token_for_repo "$repo" || true
        result=$(gh run view "$rid" --repo "$repo" \
          --json status,conclusion \
          --jq '[.status // "", .conclusion // ""] | @tsv' 2>/dev/null) || result=$'unknown\tfailure'
        status=$(echo "$result" | cut -f1)
        conclusion=$(echo "$result" | cut -f2)

        if [[ "$status" == "completed" && "$conclusion" == "success" ]]; then
          ((succeeded++)) || true
          lower_tier_published=true
          local n="${repo##*/}"
          published_names="${published_names:+$published_names, }$n"
        else
          local failure_error=""
          local failed_job_name=""
          local failed_job_url=""
          local job_details=""
          local run_url="https://github.com/$repo/actions/runs/$rid"

          if [[ "$status" != "completed" ]]; then
            failure_error="Timed out waiting for downstream dev-publish run"
            failed_job_name="workflow run"
            failed_job_url="$run_url"
          else
            failure_error="Downstream dev-publish run failed with conclusion: ${conclusion:-failure}"
            failed_job_name="workflow run"
            failed_job_url="$run_url"
            job_details=$(get_failed_job_details "$repo" "$rid") || true
            if [[ -n "$job_details" ]]; then
              local job_id=""
              local job_conclusion=""
              failed_job_name=$(echo "$job_details" | cut -f1)
              job_id=$(echo "$job_details" | cut -f2)
              job_conclusion=$(echo "$job_details" | cut -f3)
              failed_job_url="https://github.com/$repo/actions/runs/$rid/job/$job_id"
              failure_error="Downstream job failed with conclusion: ${job_conclusion:-failure}"
            fi
          fi

          record_failure "$repo" "$tier" "$failure_error" "$failed_job_name" "$failed_job_url"
          append_failure_line "$repo" "$tier" "$failure_error" "$failed_job_name" "$failed_job_url"
          ((failed++)) || true
        fi
      done

      echo "::endgroup::"
      err "Tier $tier had failures — halting before next tier"
      return 1
    fi
  else
    log "  (nothing to publish)"
  fi

  echo "::endgroup::"
}

# ── Parse manifest ───────────────────────────────────────────────
# Output: tab-separated "tier\torg\tname" lines, sorted by tier.
# Only repos with dev-publish-enabled=true, not archived.
get_repos() {
  python3 -c "
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
entries = []
for name, entry in m.get('repos', {}).items():
    if entry.get('archived', False):
        continue
    if not entry.get('dev-publish-enabled', False):
        continue
    tier = entry.get('tier', 99)
    entries.append((tier, entry['org'], name))
entries.sort()
for tier, org, name in entries:
    print(f'{tier}\t{org}\t{name}')
"
}

# ── Main ─────────────────────────────────────────────────────────

log "Nightly Develop — $(date -u '+%Y-%m-%d %H:%M UTC')"
log "Branch: $BRANCH | Force: $FORCE"
[[ -n "$TIER_FILTER" ]] && log "Tier filter: $TIER_FILTER"
log ""

current_tier=""
current_repos=()

while IFS=$'\t' read -r tier org name; do
  # Apply tier filter
  [[ -n "$TIER_FILTER" && "$tier" != "$TIER_FILTER" ]] && continue

  # Tier boundary → process accumulated repos
  if [[ "$tier" != "$current_tier" && -n "$current_tier" ]]; then
    if ! process_tier "$current_tier" "${current_repos[@]}"; then
      halted=true
      break
    fi
    current_repos=()
  fi

  current_tier="$tier"
  current_repos+=("$org/$name")
done < <(get_repos)

# Process final tier (unless halted)
if [[ "$halted" == false && ${#current_repos[@]} -gt 0 ]]; then
  process_tier "$current_tier" "${current_repos[@]}" || true
fi

# ── Summary ──────────────────────────────────────────────────────

log ""
log "━━━ Summary ━━━"
log "  Dispatched:          $dispatched"
log "  Succeeded:           $succeeded"
log "  Skipped (no Δ):      $skipped_no_changes"
log "  Skipped (no branch): $skipped_no_branch"
log "  Failed:              $failed"
[[ "$halted" == true ]] && log "  ⚠ Halted early due to tier failure"

# GitHub Actions step summary
cat >> "${GITHUB_STEP_SUMMARY:-/dev/null}" <<EOF
## Nightly Develop — $(date -u '+%Y-%m-%d')

| Metric | Count |
|--------|-------|
| Dispatched | $dispatched |
| Succeeded | $succeeded |
| Skipped (no changes) | $skipped_no_changes |
| Skipped (no branch) | $skipped_no_branch |
| Failed | $failed |

$(if [[ "$halted" == true ]]; then echo "**Halted early** — a tier had failures, downstream tiers were not processed."; fi)
EOF

# Cargo.lock sync runs as a separate job in nightly-develop.yml (needs
# Rust toolchain + AWS creds, which this orchestrate step doesn't carry).
# See scripts/nightly-cargo-lock-sync.sh.

# Output summary for downstream notification
if [[ "$succeeded" -gt 0 ]]; then
  echo "summary=Published ${succeeded} repo(s) to CodeArtifact: ${published_names}" >> "${GITHUB_OUTPUT:-/dev/null}"
else
  echo "summary=No repos published (${skipped_no_changes} unchanged, ${skipped_no_branch} no branch)" >> "${GITHUB_OUTPUT:-/dev/null}"
fi

{
  printf 'failed_repo=%s\n' "$first_failed_repo"
  printf 'failed_tier=%s\n' "$first_failed_tier"
  printf 'failed_job_name=%s\n' "$first_failed_job_name"
  printf 'failed_job_url=%s\n' "$first_failed_job_url"
  printf 'failure_error=%s\n' "$first_failure_error"
  echo 'failure_details<<EOF'
  if [[ ${#failure_lines[@]} -gt 0 ]]; then
    printf '%s\n' "${failure_lines[@]}"
  fi
  echo 'EOF'
} >> "${GITHUB_OUTPUT:-/dev/null}"

[[ "$failed" -eq 0 ]]
