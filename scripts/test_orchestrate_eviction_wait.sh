#!/usr/bin/env bash
# test_orchestrate_eviction_wait.sh — integration tests for the eviction
# recovery branch INSIDE wait_for_all.
#
# test_orchestrate_eviction.sh pins run_was_evicted() and find_successor_run()
# in isolation. That leaves the part that actually decides a tier's fate
# untested: the branch in wait_for_all that chooses between following the
# evicting run, re-dispatching, and failing the tier. These tests drive
# wait_for_all end to end against a scripted GitHub.
#
# `gh` is stubbed at the command level — `run view`, `run list` and `api` are
# all served from fixtures — so find_successor_run's real jq filter is
# exercised rather than mocked away. No network.
#
# Usage: bash scripts/test_orchestrate_eviction_wait.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCHESTRATOR="$SCRIPT_DIR/nightly-develop-orchestrate.sh"

tests_run=0
tests_failed=0

fail() {
  echo "  ✗ $1"
  echo "      expected: $2"
  echo "      actual:   $3"
  ((tests_failed++)) || true
}
ok() { echo "  ✓ $1"; }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  ((tests_run++)) || true
  if [[ "$expected" == "$actual" ]]; then ok "$label"; else fail "$label" "$expected" "$actual"; fi
}

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
cat > "$FIXTURE_DIR/REPO_MANIFEST.toml" <<'TOML'
[repos.slow-repo]
org = "greenticai"
tier = 8
publishes = []
dev-publish-enabled = true
TOML

export ORCHESTRATE_LIB_ONLY=1
export MANIFEST="$FIXTURE_DIR/REPO_MANIFEST.toml"
# shellcheck source=/dev/null
source "$ORCHESTRATOR"
set +e            # the orchestrator sets -e; probes returning non-zero are data
POLL_INTERVAL=0   # no real waiting

# ── Scripted GitHub ──────────────────────────────────────────────
# RUN_STATE[id]  = "status<TAB>conclusion<TAB>attempt"  (what `gh run view` returns)
# JOB_COUNT[id]  = jobs ever created for that run       (0 ⇒ evicted)
# RUN_LIST_JSON  = the repo's run list, newest first    (fed to the real jq filter)
declare -A RUN_STATE=()
declare -A JOB_COUNT=()
RUN_LIST_JSON='[]'
DISPATCH_RESULT=""

# wait_for_all is invoked via $(...), i.e. in a subshell, so a plain counter
# variable would never propagate back and every "did not re-dispatch"
# assertion would pass vacuously. Count through a file instead.
DISPATCH_LOG="$FIXTURE_DIR/dispatch.count"
dispatch_calls() { wc -l < "$DISPATCH_LOG" | tr -d ' '; }

use_token_for_repo() { return 0; }

# Stand in for the real dispatch() so no workflow_dispatch is ever issued.
dispatch() {
  echo "call" >> "$DISPATCH_LOG"
  [[ -n "$DISPATCH_RESULT" ]] || return 1
  echo "$DISPATCH_RESULT"
}

gh() {
  local sub="${1:-}" sub2="${2:-}"

  if [[ "$sub" == "api" ]]; then
    # repos/<owner>/<repo>/actions/runs/<id>/jobs?per_page=1
    local id="${2##*/runs/}"; id="${id%%/*}"
    echo "${JOB_COUNT[$id]:-0}"
    return 0
  fi

  if [[ "$sub" == "run" && "$sub2" == "view" ]]; then
    local id="$3"
    echo "${RUN_STATE[$id]:-$'completed\tsuccess\t1'}"
    return 0
  fi

  if [[ "$sub" == "run" && "$sub2" == "list" ]]; then
    local jq_expr=""
    while [[ $# -gt 0 ]]; do
      [[ "$1" == "--jq" ]] && { jq_expr="$2"; break; }
      shift
    done
    echo "$RUN_LIST_JSON" | jq -r "$jq_expr"
    return 0
  fi

  return 0
}

reset_world() {
  RUN_STATE=(); JOB_COUNT=(); RUN_LIST_JSON='[]'
  DISPATCH_RESULT=""; : > "$DISPATCH_LOG"
}

echo "── wait_for_all: eviction recovery ──"

# 1. The real incident: our run is evicted with zero jobs while the push that
#    evicted it goes on to publish. The tier must pass, not halt.
reset_world
RUN_STATE[100]=$'completed\tcancelled\t1'; JOB_COUNT[100]=0
RUN_STATE[200]=$'completed\tsuccess\t1';   JOB_COUNT[200]=7
RUN_LIST_JSON='[{"databaseId":200,"status":"completed","conclusion":"success"},
                {"databaseId":100,"status":"completed","conclusion":"cancelled"}]'
out=$(wait_for_all "greenticai/slow-repo:100" 2>&1); rc=$?
assert_eq "evicted run + successful evictor ⇒ tier passes" "0" "$rc"
assert_eq "  did not re-dispatch (followed the evictor instead)" "0" "$(dispatch_calls)"
((tests_run++)) || true
if grep -q "following run 200" <<<"$out"; then ok "  logs that it followed run 200"
else fail "  logs that it followed run 200" "mentions 'following run 200'" "$out"; fi

# 2. A human cancelling a run that was already executing must still fail the
#    tier — jobs exist, so work may have published and nothing may be assumed.
reset_world
RUN_STATE[100]=$'completed\tcancelled\t1'; JOB_COUNT[100]=5
RUN_LIST_JSON='[{"databaseId":200,"status":"completed","conclusion":"success"},
                {"databaseId":100,"status":"completed","conclusion":"cancelled"}]'
out=$(wait_for_all "greenticai/slow-repo:100" 2>&1); rc=$?
assert_eq "human-cancelled run (jobs ran) ⇒ tier fails" "1" "$rc"
assert_eq "  never re-dispatched" "0" "$(dispatch_calls)"

# 3. Evicted with no successor yet ⇒ fall back to re-dispatching.
reset_world
RUN_STATE[100]=$'completed\tcancelled\t1'; JOB_COUNT[100]=0
RUN_STATE[300]=$'completed\tsuccess\t1';   JOB_COUNT[300]=7
RUN_LIST_JSON='[{"databaseId":100,"status":"completed","conclusion":"cancelled"}]'
DISPATCH_RESULT=300
out=$(wait_for_all "greenticai/slow-repo:100" 2>&1); rc=$?
assert_eq "evicted with no successor ⇒ re-dispatch, tier passes" "0" "$rc"
assert_eq "  re-dispatched exactly once" "1" "$(dispatch_calls)"

# 4. A successor that genuinely failed must surface as a failure, not be
#    re-dispatched around — otherwise real breakage would hide behind retries.
reset_world
RUN_STATE[100]=$'completed\tcancelled\t1'; JOB_COUNT[100]=0
RUN_STATE[200]=$'completed\tfailure\t1';   JOB_COUNT[200]=7
RUN_LIST_JSON='[{"databaseId":200,"status":"completed","conclusion":"failure"},
                {"databaseId":100,"status":"completed","conclusion":"cancelled"}]'
out=$(wait_for_all "greenticai/slow-repo:100" 2>&1); rc=$?
assert_eq "failed successor ⇒ tier fails (failure is not swallowed)" "1" "$rc"
assert_eq "  did not re-dispatch around the failure" "0" "$(dispatch_calls)"

# 5. A saturated repo evicts every attempt. Recovery must stop at
#    EVICTION_RECOVERIES rather than loop forever.
reset_world
for id in 100 200 300 400 500 600; do
  RUN_STATE[$id]=$'completed\tcancelled\t1'; JOB_COUNT[$id]=0
done
RUN_LIST_JSON='[{"databaseId":600,"status":"completed","conclusion":"cancelled"},
                {"databaseId":500,"status":"completed","conclusion":"cancelled"},
                {"databaseId":100,"status":"completed","conclusion":"cancelled"}]'
DISPATCH_RESULT=200   # every re-dispatch is itself evicted
# MAX_WAIT is the backstop that would catch a runaway loop. POLL_INTERVAL must
# be non-zero for it to bind at all — `elapsed` advances by POLL_INTERVAL, so
# at 0 the budget is never reached and a regression hangs forever instead of
# failing. Shrink both so a regression fails in seconds.
MAX_WAIT=5
POLL_INTERVAL=1
out=$(wait_for_all "greenticai/slow-repo:100" 2>&1); rc=$?
MAX_WAIT=7200
POLL_INTERVAL=0
assert_eq "perpetually evicted repo ⇒ tier fails, no infinite loop" "1" "$rc"
((tests_run++)) || true
if grep -q "Timed out waiting" <<<"$out"; then
  fail "  stopped via the eviction guard, not the wait timeout" "guard stops it" "hit MAX_WAIT"
else
  ok "  stopped via the eviction guard, not the wait timeout"
fi
((tests_run++)) || true
if [[ "$(dispatch_calls)" -le "$EVICTION_RECOVERIES" ]]; then
  ok "  bounded by EVICTION_RECOVERIES ($(dispatch_calls) ≤ $EVICTION_RECOVERIES)"
else
  fail "  bounded by EVICTION_RECOVERIES" "≤ $EVICTION_RECOVERIES dispatches" "$(dispatch_calls)"
fi

# 6. Unrelated repos in the same tier must be unaffected by a neighbour's
#    eviction — the entry key stays stable while its run ID changes.
reset_world
RUN_STATE[100]=$'completed\tcancelled\t1'; JOB_COUNT[100]=0
RUN_STATE[200]=$'completed\tsuccess\t1';   JOB_COUNT[200]=7
RUN_STATE[900]=$'completed\tsuccess\t1';   JOB_COUNT[900]=7
RUN_LIST_JSON='[{"databaseId":200,"status":"completed","conclusion":"success"},
                {"databaseId":100,"status":"completed","conclusion":"cancelled"}]'
out=$(wait_for_all "greenticai/slow-repo:100" "greenticai/other-repo:900" 2>&1); rc=$?
assert_eq "sibling repo unaffected by a neighbour's eviction" "0" "$rc"

echo ""
echo "── Summary ──"
echo "  Run:    $tests_run"
echo "  Failed: $tests_failed"
[[ "$tests_failed" -eq 0 ]] || exit 1
echo "  All eviction-wait integration tests passed"
