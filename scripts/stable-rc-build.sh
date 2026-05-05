#!/usr/bin/env bash
# stable-rc-build.sh — Orchestrate RC builds for the stable-e2e-gate.
#
# Discovers open release PRs in V1 binary-shipping repos, dispatches each
# repo's rc-build.yml against its release branch, polls all dispatched runs
# until completion, and emits rc-manifest.json describing the produced RC
# pre-releases.
#
# Inputs (env):
#   GH_TOKEN         — GitHub App token with repo + actions scope across orgs
#   GITHUB_RUN_ID    — Orchestrator run ID; becomes the RC suffix `rc.<run_id>`
#   INPUT_REPOS      — Optional comma-separated allowlist (default: all V1 repos)
#   INPUT_DRY_RUN    — "true" to skip dispatch (discovery + manifest only)
#
# Outputs:
#   rc-manifest.json     — Manifest of dispatched repos (uploaded as artifact)
#   GITHUB_STEP_SUMMARY  — Human-readable table for the Actions UI
#
# V1 scope: 4 hardcoded repos. V2 will read from REPO_MANIFEST.toml's
# binary-crates field directly.

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────
MANIFEST_FILE="rc-manifest.json"
V1_REPOS=("greentic" "greentic-runner" "greentic-deployer" "greentic-bundle")
TIMEOUT_SECONDS=$((90 * 60))
POLL_INTERVAL_SECONDS=60
DISPATCH_REGISTER_TIMEOUT=60

RUN_ID="${GITHUB_RUN_ID:-local-$(date +%s)}"
RC_SUFFIX="rc.${RUN_ID}"
DRY_RUN="${INPUT_DRY_RUN:-false}"
REPO_FILTER="${INPUT_REPOS:-}"

log()  { echo "$1"; }
err()  { echo "::error::$1"; }
warn() { echo "::warning::$1"; }

# ── Validate V1 repos in REPO_MANIFEST.toml, get their orgs ──────
# Output: tab-separated "org\tname" lines. Hard-fails if any V1 repo is
# missing, archived, or has no binary-crates set.
get_v1_repo_orgs() {
  python3 - <<'EOF'
import sys, tomllib
v1 = ["greentic", "greentic-runner", "greentic-deployer", "greentic-bundle"]
with open('toolchain/REPO_MANIFEST.toml', 'rb') as f:
    m = tomllib.load(f)
repos = m.get('repos', {})
errors = []
for name in v1:
    entry = repos.get(name)
    if not entry:
        errors.append(f"{name}: not in REPO_MANIFEST.toml"); continue
    if entry.get('archived', False):
        errors.append(f"{name}: archived"); continue
    if not entry.get('binary-crates'):
        errors.append(f"{name}: no binary-crates"); continue
    print(f"{entry['org']}\t{name}")
if errors:
    for e in errors: print(f"::error::{e}", file=sys.stderr)
    sys.exit(1)
EOF
}

# ── Discover open release PR for one repo ───────────────────────
# stdout: "branch\tsha\tversion" if found; empty if none.
# Matches PRs where headRefName looks like release/v{X.Y.Z}.
discover_release_pr() {
  local full_repo="$1"
  gh pr list --repo "$full_repo" --base main --label release --state open \
    --json headRefName,headRefOid \
    --jq 'first(.[] | select(.headRefName | test("^release/v[0-9]+\\.[0-9]+\\.[0-9]+$"))) | "\(.headRefName)\t\(.headRefOid)\t\(.headRefName | sub("^release/v"; ""))"'
}

# ── Dispatch rc-build.yml for one repo, capture run ID ───────────
# stdout: run ID. Returns 1 on failure.
dispatch_rc_build() {
  local full_repo="$1" branch="$2" tag="$3"

  if ! gh workflow run rc-build.yml --repo "$full_repo" \
       --ref "$branch" \
       -f "ref=$branch" \
       -f "tag=$tag" >/dev/null 2>&1; then
    return 1
  fi

  # Dispatch is async; poll until the run shows up.
  local deadline=$(($(date +%s) + DISPATCH_REGISTER_TIMEOUT))
  while [[ $(date +%s) -lt $deadline ]]; do
    sleep 3
    local run_id
    run_id=$(gh run list --repo "$full_repo" --workflow rc-build.yml \
      --branch "$branch" --event workflow_dispatch --limit 1 \
      --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null) || true
    if [[ -n "$run_id" ]]; then
      echo "$run_id"
      return 0
    fi
  done
  return 1
}

# ── Poll one run until completion or timeout ─────────────────────
# stdout: "success" | "failure" | "cancelled" | "timeout" | other conclusion
poll_run() {
  local full_repo="$1" run_id="$2"
  local deadline=$(($(date +%s) + TIMEOUT_SECONDS))

  while [[ $(date +%s) -lt $deadline ]]; do
    local out status conclusion
    if out=$(gh run view "$run_id" --repo "$full_repo" \
              --json status,conclusion \
              --jq '"\(.status):\(.conclusion // "")"' 2>/dev/null); then
      status="${out%%:*}"
      conclusion="${out#*:}"
      if [[ "$status" == "completed" ]]; then
        echo "${conclusion:-unknown}"
        return 0
      fi
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
  echo "timeout"
}

# ── Main ────────────────────────────────────────────────────────
log "Stable RC Build — $(date -u '+%Y-%m-%d %H:%M UTC')"
log "Run ID: $RUN_ID  RC suffix: $RC_SUFFIX  Dry run: $DRY_RUN"
[[ -n "$REPO_FILTER" ]] && log "Repo filter: $REPO_FILTER"

declare -A ORG BRANCH SHA VERSION TAG RUN STATUS RELEASE_URL

while IFS=$'\t' read -r org name; do
  ORG["$name"]="$org"
done < <(get_v1_repo_orgs)

# Apply repo filter
declare -A FILTER
if [[ -n "$REPO_FILTER" ]]; then
  IFS=',' read -ra _filter <<< "$REPO_FILTER"
  for r in "${_filter[@]}"; do FILTER["$r"]=1; done
fi

# ── Discovery + dispatch ──
for name in "${V1_REPOS[@]}"; do
  if [[ -n "$REPO_FILTER" && -z "${FILTER[$name]:-}" ]]; then
    continue
  fi

  full="${ORG[$name]}/$name"
  log ""
  log "── $full ──"

  if ! pr_info=$(discover_release_pr "$full") || [[ -z "$pr_info" ]]; then
    log "  (no open release PR with version branch)"
    STATUS["$name"]="no_release_pr"
    continue
  fi

  IFS=$'\t' read -r b s v <<< "$pr_info"
  BRANCH["$name"]="$b"
  SHA["$name"]="$s"
  VERSION["$name"]="$v"
  TAG["$name"]="v${v}-${RC_SUFFIX}"
  RELEASE_URL["$name"]="https://github.com/$full/releases/tag/${TAG[$name]}"

  log "  branch:  ${BRANCH[$name]}"
  log "  sha:     ${SHA[$name]}"
  log "  rc tag:  ${TAG[$name]}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "  [dry-run] would dispatch"
    STATUS["$name"]="dry_run"
    continue
  fi

  if run_id=$(dispatch_rc_build "$full" "${BRANCH[$name]}" "${TAG[$name]}"); then
    RUN["$name"]="$run_id"
    STATUS["$name"]="dispatched"
    log "  dispatched: run $run_id"
  else
    STATUS["$name"]="dispatch_failed"
    err "$full — dispatch failed"
  fi
done

# ── Poll dispatched runs ──
if [[ "$DRY_RUN" != "true" ]]; then
  log ""
  log "── Polling dispatched runs (timeout: $((TIMEOUT_SECONDS / 60))m) ──"

  for name in "${V1_REPOS[@]}"; do
    if [[ "${STATUS[$name]:-}" != "dispatched" ]]; then
      continue
    fi
    full="${ORG[$name]}/$name"
    log "  Polling $full run ${RUN[$name]}..."
    conc=$(poll_run "$full" "${RUN[$name]}")
    case "$conc" in
      success) STATUS["$name"]="passed" ;;
      timeout) STATUS["$name"]="timeout" ;;
      *)       STATUS["$name"]="failed:$conc" ;;
    esac
    log "    → ${STATUS[$name]}"
  done
fi

# ── Emit manifest ──
log ""
log "── Writing $MANIFEST_FILE ──"

dry_run_json="false"; [[ "$DRY_RUN" == "true" ]] && dry_run_json="true"

{
  for name in "${V1_REPOS[@]}"; do
    if [[ -n "$REPO_FILTER" && -z "${FILTER[$name]:-}" ]]; then
      continue
    fi
    org="${ORG[$name]:-greenticai}"
    run="${RUN[$name]:-}"
    run_url=""
    [[ -n "$run" ]] && run_url="https://github.com/$org/$name/actions/runs/$run"

    jq -n \
      --arg repo "$org/$name" \
      --arg name "$name" \
      --arg version "${VERSION[$name]:-}" \
      --arg tag "${TAG[$name]:-}" \
      --arg branch "${BRANCH[$name]:-}" \
      --arg sha "${SHA[$name]:-}" \
      --arg run_id "$run" \
      --arg run_url "$run_url" \
      --arg release_url "${RELEASE_URL[$name]:-}" \
      --arg status "${STATUS[$name]:-skipped}" \
      '{repo: $repo, name: $name, version: $version, rc_tag: $tag, branch: $branch, sha: $sha, run_id: $run_id, run_url: $run_url, release_url: $release_url, status: $status}'
  done
} | jq -s \
    --arg run_id "$RUN_ID" \
    --arg suffix "$RC_SUFFIX" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson dry "$dry_run_json" \
    '{run_id: $run_id, rc_suffix: $suffix, generated_at: $ts, dry_run: $dry, repos: .}' > "$MANIFEST_FILE"

cat "$MANIFEST_FILE"

# ── Summary + step summary ──
log ""
log "━━━ Summary ━━━"
passed=0; failed=0; skipped=0
for name in "${V1_REPOS[@]}"; do
  status="${STATUS[$name]:-skipped}"
  case "$status" in
    passed)                      ((passed++))  || true ;;
    no_release_pr|dry_run|skipped) ((skipped++)) || true ;;
    *)                           ((failed++))  || true ;;
  esac
done
log "  Passed:  $passed"
log "  Failed:  $failed"
log "  Skipped: $skipped"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Stable RC Build — RC suffix \`${RC_SUFFIX}\`"
    echo ""
    echo "Dry run: \`${DRY_RUN}\`"
    echo ""
    echo "| Repo | Status | Tag | Pre-release | Run |"
    echo "|------|--------|-----|-------------|-----|"
    for name in "${V1_REPOS[@]}"; do
      if [[ -n "$REPO_FILTER" && -z "${FILTER[$name]:-}" ]]; then
        continue
      fi
      status="${STATUS[$name]:-skipped}"
      tag="${TAG[$name]:--}"
      org="${ORG[$name]:-greenticai}"
      run="${RUN[$name]:-}"
      run_link=""
      [[ -n "$run" ]] && run_link="[run](https://github.com/$org/$name/actions/runs/$run)"
      release_link=""
      [[ -n "${TAG[$name]:-}" && "$status" == "passed" ]] && \
        release_link="[link](https://github.com/$org/$name/releases/tag/${TAG[$name]})"
      echo "| $name | $status | \`$tag\` | $release_link | $run_link |"
    done
  } >> "$GITHUB_STEP_SUMMARY"
fi

# Output summary line for downstream notification
summary="${passed} passed, ${failed} failed, ${skipped} skipped (suffix: ${RC_SUFFIX})"
echo "summary=$summary" >> "${GITHUB_OUTPUT:-/dev/null}"

# Exit non-zero if any dispatched repo failed (so notify-failure fires).
[[ $failed -eq 0 ]]
