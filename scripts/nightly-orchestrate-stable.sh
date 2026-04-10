#!/usr/bin/env bash
# nightly-orchestrate-stable.sh — Tier-ordered stable release orchestration
#
# Coordinates the full weekly-stable pipeline across tiers:
# 1. (Optional) Run weekly-stable-prepare to create release PRs
# 2. For each tier (0→8):
#    a. Wait for all release PRs in this tier to be merged
#    b. Wait for all weekly-stable-publish.yml runs to complete
#    c. Verify crates.io propagation for downstream resolution
#    d. Proceed to next tier
#
# Environment:
#   GH_TOKEN             — GitHub PAT with repo + actions:write scope
#   INPUT_TIER           — (optional) Process a specific tier only
#   INPUT_SKIP_PREPARE   — (optional) "true" to skip the prepare phase
#   INPUT_MERGE_TIMEOUT  — Minutes to wait for PR merges per tier (default 60)

set -euo pipefail

MANIFEST="toolchain/REPO_MANIFEST.toml"
RELEASE_LABEL="release"
PUBLISH_WORKFLOW="weekly-stable-publish.yml"

TIER_FILTER="${INPUT_TIER:-}"
SKIP_PREPARE="${INPUT_SKIP_PREPARE:-false}"
MERGE_TIMEOUT_MIN="${INPUT_MERGE_TIMEOUT:-60}"
MERGE_TIMEOUT=$((MERGE_TIMEOUT_MIN * 60))  # convert to seconds
POLL_INTERVAL=30

# Counters
tiers_completed=0
repos_published=0
repos_skipped=0
failed=0
published_details=""

# ── Helpers ──────────────────────────────────────────────────────

log()  { echo "$1"; }
err()  { echo "::error::$1"; }
warn() { echo "::warning::$1"; }

# ── Parse manifest ───────────────────────────────────────────────
# Output: tab-separated "tier\torg\tname\tcrates" lines.
get_repos() {
  python3 -c "
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
entries = []
for name, entry in m.get('repos', {}).items():
    if entry.get('archived', False):
        continue
    if not entry.get('weekly-stable-enabled', False):
        continue
    if not entry.get('publishes', []):
        continue
    tier = entry.get('tier', 99)
    crates = ' '.join(entry['publishes'])
    entries.append((tier, entry['org'], name, crates))
entries.sort()
for tier, org, name, crates in entries:
    print(f'{tier}\t{org}\t{name}\t{crates}')
"
}

# ── Find open release PRs for a repo ────────────────────────────
# Returns PR number or empty.
get_release_pr() {
  local repo="$1"
  gh pr list --repo "$repo" --base main --label "$RELEASE_LABEL" \
    --state open --json number --jq '.[0].number // empty' 2>/dev/null || true
}

# ── Check if a release PR was merged ────────────────────────────
# Returns "merged", "open", "closed", or "none".
get_pr_state() {
  local repo="$1" pr_num="$2"
  local state merged
  state=$(gh pr view "$pr_num" --repo "$repo" --json state --jq '.state' 2>/dev/null) || {
    echo "none"; return
  }
  if [[ "$state" == "MERGED" ]]; then
    echo "merged"
  elif [[ "$state" == "OPEN" ]]; then
    echo "open"
  else
    echo "closed"
  fi
}

# ── Get merge SHA from a merged PR ──────────────────────────────
get_merge_sha() {
  local repo="$1" pr_num="$2"
  gh pr view "$pr_num" --repo "$repo" --json mergeCommit --jq '.mergeCommit.oid // empty' 2>/dev/null || true
}

# ── Wait for publish workflow to complete on a merge commit ──────
# Returns 0 on success, 1 on failure/timeout.
wait_for_publish() {
  local repo="$1" merge_sha="$2"
  local elapsed=0
  local max_wait=1800  # 30 minutes

  while [[ "$elapsed" -lt "$max_wait" ]]; do
    # Find publish workflow run triggered by this merge
    local run_info
    run_info=$(gh run list --repo "$repo" --workflow "$PUBLISH_WORKFLOW" \
      --branch main --limit 5 \
      --json databaseId,headSha,status,conclusion \
      --jq ".[] | select(.headSha == \"$merge_sha\") | \"\(.databaseId)\t\(.status)\t\(.conclusion // \"\")\"" \
      2>/dev/null | head -1) || true

    if [[ -n "$run_info" ]]; then
      local run_id status conclusion
      IFS=$'\t' read -r run_id status conclusion <<< "$run_info"

      if [[ "$status" == "completed" ]]; then
        if [[ "$conclusion" == "success" ]]; then
          log "      ✓ publish run $run_id succeeded"
          return 0
        else
          err "publish run $run_id: $conclusion — https://github.com/$repo/actions/runs/$run_id"
          return 1
        fi
      fi
      log "      ⏳ publish run $run_id: $status (${elapsed}s)"
    else
      if [[ "$elapsed" -gt 120 ]]; then
        # After 2 min, the publish workflow should have been triggered
        warn "No publish run found for $repo at $merge_sha after ${elapsed}s"
      fi
    fi

    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  err "Timed out waiting for publish in $repo (${max_wait}s)"
  return 1
}

# ── Verify crate is available on crates.io ───────────────────────
verify_crate_published() {
  local crate="$1" repo="$2"

  # Read version from the repo's main branch Cargo.toml
  local version
  version=$(gh api "repos/$repo/contents/Cargo.toml" --jq '.content' 2>/dev/null \
    | base64 -d \
    | python3 -c "
import sys, tomllib
data = tomllib.load(sys.stdin.buffer)
ws = data.get('workspace', {}).get('package', {})
pkg = data.get('package', {})
ver = ws.get('version') or pkg.get('version')
if ver: print(ver)
else: sys.exit(1)
" 2>/dev/null) || return 1

  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "User-Agent: greentic-orchestrate-stable" \
    "https://crates.io/api/v1/crates/${crate}/${version}")
  [[ "$status" == "200" ]]
}

# ── Phase 1: Prepare ────────────────────────────────────────────

if [[ "$SKIP_PREPARE" != "true" ]]; then
  log "━━━ Phase 1: Prepare release PRs ━━━"
  log ""

  # Dispatch weekly-stable-prepare.yml and wait
  local_args=""
  [[ -n "$TIER_FILTER" ]] && local_args="-f tier=$TIER_FILTER"

  log "Dispatching weekly-stable-prepare.yml..."

  # Record latest run ID before dispatch
  before_id=$(gh run list --workflow weekly-stable-prepare.yml \
    --limit 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null) || before_id=0

  if ! gh workflow run weekly-stable-prepare.yml $local_args 2>/dev/null; then
    err "Failed to dispatch weekly-stable-prepare.yml"
    exit 1
  fi

  # Detect new run
  prepare_run_id=""
  for _ in $(seq 1 24); do
    sleep 5
    prepare_run_id=$(gh run list --workflow weekly-stable-prepare.yml \
      --limit 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null) || continue
    [[ "$prepare_run_id" -gt "$before_id" ]] && break
    prepare_run_id=""
  done

  if [[ -z "$prepare_run_id" ]]; then
    err "Could not detect prepare workflow run"
    exit 1
  fi

  log "Prepare run: $prepare_run_id — waiting for completion..."

  # Wait for prepare to complete
  elapsed=0
  while [[ "$elapsed" -lt 1800 ]]; do
    result=$(gh run view "$prepare_run_id" \
      --json status,conclusion \
      --jq '[.status, .conclusion // ""] | @tsv' 2>/dev/null) || true

    status=$(echo "$result" | cut -f1)
    conclusion=$(echo "$result" | cut -f2)

    if [[ "$status" == "completed" ]]; then
      if [[ "$conclusion" == "success" ]]; then
        log "✓ Prepare completed successfully"
        break
      else
        err "Prepare workflow $conclusion (run $prepare_run_id)"
        exit 1
      fi
    fi

    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  if [[ "$elapsed" -ge 1800 ]]; then
    err "Prepare workflow timed out (run $prepare_run_id)"
    exit 1
  fi

  log ""
fi

# ── Phase 2: Tier-ordered merge → publish → verify ──────────────

log "━━━ Phase 2: Tier-ordered publish ━━━"
log "Merge timeout: ${MERGE_TIMEOUT_MIN} min per tier"
log ""

# Group repos by tier
declare -A tier_repos  # tier -> "org/name:crates|org/name:crates|..."
declare -a tier_order  # ordered unique tier numbers

while IFS=$'\t' read -r tier org name crates; do
  [[ -n "$TIER_FILTER" && "$tier" != "$TIER_FILTER" ]] && continue

  full="$org/$name"
  entry="$full:$crates"

  if [[ -z "${tier_repos[$tier]:-}" ]]; then
    tier_repos[$tier]="$entry"
    tier_order+=("$tier")
  else
    tier_repos[$tier]="${tier_repos[$tier]}|$entry"
  fi
done < <(get_repos)

for tier in "${tier_order[@]}"; do
  echo "::group::Tier $tier"
  log "── Tier $tier ──"

  IFS='|' read -ra entries <<< "${tier_repos[$tier]}"

  # ── Step A: Wait for all release PRs in this tier to be merged ──

  declare -A pr_map     # repo -> pr_number
  declare -A merge_map  # repo -> merge_sha
  tier_failed=false

  # Find release PRs for each repo in this tier
  for entry in "${entries[@]}"; do
    repo="${entry%%:*}"
    name="${repo##*/}"

    # Check for merged release PRs first (recently merged)
    local merged_pr
    merged_pr=$(gh pr list --repo "$repo" --base main --label "$RELEASE_LABEL" \
      --state merged --json number,mergedAt \
      --jq '[.[] | select(.mergedAt > "'"$(date -u -d '-2 hours' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-2H '+%Y-%m-%dT%H:%M:%SZ')"'")] | sort_by(.mergedAt) | last | .number // empty' \
      2>/dev/null) || merged_pr=""

    if [[ -n "$merged_pr" ]]; then
      log "  ✓ $name — PR #$merged_pr already merged"
      local sha
      sha=$(get_merge_sha "$repo" "$merged_pr")
      merge_map[$repo]="$sha"
      continue
    fi

    # Check for open release PR
    local pr_num
    pr_num=$(get_release_pr "$repo")
    if [[ -z "$pr_num" ]]; then
      log "  ⊘ $name — no release PR found, skipping"
      ((repos_skipped++)) || true
      continue
    fi

    pr_map[$repo]="$pr_num"
    log "  ⏳ $name — PR #$pr_num open, waiting for merge..."
  done

  # Wait for remaining open PRs to be merged
  if [[ ${#pr_map[@]} -gt 0 ]]; then
    elapsed=0
    while [[ "$elapsed" -lt "$MERGE_TIMEOUT" && ${#pr_map[@]} -gt 0 ]]; do
      for repo in "${!pr_map[@]}"; do
        pr_num="${pr_map[$repo]}"
        name="${repo##*/}"
        state=$(get_pr_state "$repo" "$pr_num")

        if [[ "$state" == "merged" ]]; then
          local sha
          sha=$(get_merge_sha "$repo" "$pr_num")
          merge_map[$repo]="$sha"
          unset 'pr_map[$repo]'
          log "  ✓ $name — PR #$pr_num merged"
        elif [[ "$state" == "closed" ]]; then
          unset 'pr_map[$repo]'
          warn "$name — PR #$pr_num closed without merging"
          ((repos_skipped++)) || true
        fi
      done

      [[ ${#pr_map[@]} -eq 0 ]] && break

      remaining=$(printf '%s ' "${!pr_map[@]}" | sed 's|[^ ]*/||g')
      log "  ⏳ Waiting for merge: $remaining (${elapsed}s/${MERGE_TIMEOUT}s)"
      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
    done

    # Timeout — remaining PRs not merged
    for repo in "${!pr_map[@]}"; do
      name="${repo##*/}"
      err "$name — PR #${pr_map[$repo]} not merged within ${MERGE_TIMEOUT_MIN}min"
      tier_failed=true
      ((failed++)) || true
    done
  fi

  # ── Step B: Wait for publish workflows to complete ──

  if [[ ${#merge_map[@]} -gt 0 ]]; then
    log ""
    log "  Waiting for publish workflows..."

    for repo in "${!merge_map[@]}"; do
      name="${repo##*/}"
      merge_sha="${merge_map[$repo]}"

      if wait_for_publish "$repo" "$merge_sha"; then
        ((repos_published++)) || true
        local ver
        ver=$(get_current_version "$repo" 2>/dev/null) || ver="?"
        published_details="${published_details:+$published_details, }${name} v${ver}"
      else
        tier_failed=true
        ((failed++)) || true
      fi
    done
  fi

  # Clean up associative arrays for next tier
  unset pr_map merge_map
  declare -A pr_map merge_map

  echo "::endgroup::"

  if [[ "$tier_failed" == true ]]; then
    err "Tier $tier had failures — halting before next tier"
    break
  fi

  ((tiers_completed++)) || true
  log ""
done

# ── Summary ──────────────────────────────────────────────────────

log ""
log "━━━ Summary ━━━"
log "  Tiers completed:  $tiers_completed"
log "  Repos published:  $repos_published"
log "  Repos skipped:    $repos_skipped"
log "  Failed:           $failed"

cat >> "${GITHUB_STEP_SUMMARY:-/dev/null}" <<EOF
## Orchestrate Stable — $(date -u '+%Y-%m-%d')

| Metric | Count |
|--------|-------|
| Tiers completed | $tiers_completed |
| Repos published | $repos_published |
| Repos skipped | $repos_skipped |
| Failed | $failed |
EOF

# Output summary for downstream notification
if [[ "$repos_published" -gt 0 ]]; then
  echo "summary=Published ${repos_published} repo(s) to crates.io: ${published_details}" >> "${GITHUB_OUTPUT:-/dev/null}"
else
  echo "summary=No repos published (${repos_skipped} skipped)" >> "${GITHUB_OUTPUT:-/dev/null}"
fi

[[ "$failed" -eq 0 ]]
