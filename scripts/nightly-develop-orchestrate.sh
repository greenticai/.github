#!/usr/bin/env bash
# nightly-develop-orchestrate.sh — Tier-ordered dev-publish orchestration
#
# Dispatches dev-publish.yml across repos in tier order (0→8).
# Repos within a tier are dispatched in parallel, then waited on.
# Change-aware: skips repos with no source or upstream changes.
#
# Environment:
#   GH_TOKEN     — GitHub PAT/App token with actions:write across the org
#   INPUT_TIER   — (optional) Process a specific tier only
#   INPUT_FORCE  — (optional) "true" to skip change detection
#
# Prerequisites:
#   - GH_NIGHTLY_TOKEN org secret: PAT or GitHub App with actions:write
#     scope on all repos. GITHUB_TOKEN cannot dispatch cross-repo workflows.
#   - Each target repo must have dev-publish.yml on the develop branch
#     (deployed by sync-dev-publish.sh).

set -euo pipefail

MANIFEST="toolchain/REPO_MANIFEST.toml"
WORKFLOW="dev-publish.yml"
BRANCH="develop"
POLL_INTERVAL=30    # seconds between status polls
MAX_WAIT=3600       # max seconds to wait per tier (1 hour)
DISPATCH_DETECT=5   # seconds between dispatch detection polls
DISPATCH_TIMEOUT=24 # max polls to detect dispatched run (24*5s = 2min)

FORCE="${INPUT_FORCE:-false}"
TIER_FILTER="${INPUT_TIER:-}"

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
