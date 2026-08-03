#!/usr/bin/env bash
# test_orchestrate_eviction.sh — unit tests for concurrency-eviction recovery
# in nightly-develop-orchestrate.sh.
#
# Every dev-publish.yml caller declares
#   concurrency: { group: <workflow>-<ref>, cancel-in-progress: false }
# and GitHub keeps at most ONE pending run per group. When a push to develop
# lands while the orchestrator's dispatched run is still queued, GitHub evicts
# the queued run: it concludes `cancelled` with zero jobs ever created.
#
# The orchestrator used to treat that as a genuine failure and halt the tier,
# even though nothing ran and the evicting run does the exact same work on the
# same branch. These tests pin the two primitives that recover from it.
#
# The functions under test shell out to `gh`, so each test installs a stub
# `gh` function — shell functions take precedence over PATH lookups. No network.
#
# Usage: bash scripts/test_orchestrate_eviction.sh

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

assert_true() {
  local label="$1"; shift
  ((tests_run++)) || true
  if "$@"; then ok "$label"; else fail "$label" "true (exit 0)" "false (exit $?)"; fi
}

assert_false() {
  local label="$1"; shift
  ((tests_run++)) || true
  if "$@"; then fail "$label" "false (non-zero exit)" "true (exit 0)"; else ok "$label"; fi
}

# ── Fixture ──────────────────────────────────────────────────────
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
cat > "$FIXTURE_DIR/REPO_MANIFEST.toml" <<'TOML'
[repos.lib-repo]
org = "greenticai"
tier = 5
publishes = ["lib-core"]
dev-publish-enabled = true
TOML

export ORCHESTRATE_LIB_ONLY=1
export MANIFEST="$FIXTURE_DIR/REPO_MANIFEST.toml"
# shellcheck source=/dev/null
if ! source "$ORCHESTRATOR"; then
  echo "FATAL: could not source $ORCHESTRATOR with ORCHESTRATE_LIB_ONLY=1" >&2
  exit 1
fi

# Token minting is irrelevant here and would hit the network.
use_token_for_repo() { return 0; }

# ── run_was_evicted ──────────────────────────────────────────────
# Distinguishes "GitHub dropped this from the queue" (zero jobs) from a
# human cancelling a run that was already executing (jobs exist).
echo "── run_was_evicted ──"

# total_count 0 → nothing ever ran → evicted.
gh() { echo '0'; }
assert_true "cancelled run with zero jobs is an eviction" \
  run_was_evicted "greenticai/lib-repo" 111

# A human cancelled a run mid-flight; its jobs exist and may have published.
gh() { echo '4'; }
assert_false "cancelled run that created jobs is NOT an eviction" \
  run_was_evicted "greenticai/lib-repo" 222

# A failed API call must never be reported as an eviction — treating an
# unreadable run as "safe to replace" could double-publish.
gh() { return 1; }
assert_false "unreadable run is NOT an eviction" \
  run_was_evicted "greenticai/lib-repo" 333

# gh can exit 0 and still print nothing useful (auth blip, unexpected shape).
# Bash arithmetic treats "" as 0, so without an explicit numeric guard this
# path would silently read as "evicted" and license a re-dispatch.
gh() { echo ''; }
assert_false "empty-but-successful job count is NOT an eviction" \
  run_was_evicted "greenticai/lib-repo" 444

gh() { echo 'gh: not logged in'; }
assert_false "non-numeric job count is NOT an eviction" \
  run_was_evicted "greenticai/lib-repo" 555

# ── find_successor_run ───────────────────────────────────────────
# The run that evicted ours targets the same workflow and branch, so waiting
# on it is equivalent to waiting on ours. Pick the OLDEST run above our ID so
# we adopt the actual evictor rather than skipping ahead.
echo "── find_successor_run ──"

# gh run list --json databaseId,status,conclusion returns newest-first.
# The payload must be global: gh() runs long after stub_run_list has returned,
# so a `local` would already be out of scope by then.
STUB_RUN_LIST_PAYLOAD=""
stub_run_list() { STUB_RUN_LIST_PAYLOAD="$1"; }

gh() {
  # Only the --jq expression matters; emulate gh by piping the fixture
  # payload through the real jq with the same filter.
  local jq_expr=""
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "--jq" ]] && { jq_expr="$2"; break; }
    shift
  done
  echo "$STUB_RUN_LIST_PAYLOAD" | jq -r "$jq_expr"
}

# In-progress evictor sitting just above our run.
stub_run_list '[
  {"databaseId": 300, "status": "queued",      "conclusion": null},
  {"databaseId": 200, "status": "in_progress", "conclusion": null},
  {"databaseId": 100, "status": "completed",   "conclusion": "cancelled"}
]'
assert_eq "adopts the oldest live run above ours" "200" \
  "$(find_successor_run "greenticai/lib-repo" 100)"

# A successor that already succeeded still counts — the work is done.
stub_run_list '[
  {"databaseId": 250, "status": "completed", "conclusion": "success"}
]'
assert_eq "adopts an already-successful successor" "250" \
  "$(find_successor_run "greenticai/lib-repo" 100)"

# A genuinely failed successor must be adopted too, so the tier reports the
# real failure instead of silently re-dispatching around it.
stub_run_list '[
  {"databaseId": 260, "status": "completed", "conclusion": "failure"}
]'
assert_eq "adopts a failed successor so the failure surfaces" "260" \
  "$(find_successor_run "greenticai/lib-repo" 100)"

# Successors that were themselves evicted are not useful to wait on.
stub_run_list '[
  {"databaseId": 270, "status": "completed", "conclusion": "cancelled"}
]'
assert_eq "skips a successor that was itself cancelled" "" \
  "$(find_successor_run "greenticai/lib-repo" 100)"

# Nothing newer than our run — caller must fall back to re-dispatching.
stub_run_list '[
  {"databaseId": 100, "status": "completed", "conclusion": "cancelled"},
  {"databaseId": 90,  "status": "completed", "conclusion": "success"}
]'
assert_eq "no successor yields empty" "" \
  "$(find_successor_run "greenticai/lib-repo" 100)"

# Our own run must never be adopted as its own successor.
stub_run_list '[
  {"databaseId": 100, "status": "in_progress", "conclusion": null}
]'
assert_eq "own run is not its own successor" "" \
  "$(find_successor_run "greenticai/lib-repo" 100)"

echo ""
echo "── Summary ──"
echo "  Run:    $tests_run"
echo "  Failed: $tests_failed"
[[ "$tests_failed" -eq 0 ]] || exit 1
echo "  All eviction tests passed"
