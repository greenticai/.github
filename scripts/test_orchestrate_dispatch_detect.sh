#!/usr/bin/env bash
# test_orchestrate_dispatch_detect.sh — unit tests for find_dispatched_run in
# nightly-develop-orchestrate.sh.
#
# dispatch() used to accept the newest run whose ID was above the ID it read
# before dispatching. On 2026-09-30 (nightly 36686554786) the Actions API
# served a stale run list for greentic-mcp, and a failed run from 2026-08-24
# (32685545595) was adopted as the one just dispatched — halting tier 4 while
# the real dispatched run succeeded. These tests pin that a run created before
# the dispatch can never be adopted, whatever its ID.
#
# `gh` is stubbed as a shell function that pipes a fixture through the real jq
# with the same filter the orchestrator passes. No network.
#
# Usage: bash scripts/test_orchestrate_dispatch_detect.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCHESTRATOR="$SCRIPT_DIR/nightly-develop-orchestrate.sh"

tests_run=0
tests_failed=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  ((tests_run++)) || true
  if [[ "$expected" == "$actual" ]]; then
    echo "  ✓ $label"
  else
    echo "  ✗ $label"
    echo "      expected: $expected"
    echo "      actual:   $actual"
    ((tests_failed++)) || true
  fi
}

assert_fails() {
  local label="$1"; shift
  ((tests_run++)) || true
  if "$@" >/dev/null; then
    echo "  ✗ $label (expected non-zero exit)"
    ((tests_failed++)) || true
  else
    echo "  ✓ $label"
  fi
}

# ── Fixture ──────────────────────────────────────────────────────
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
cat > "$FIXTURE_DIR/REPO_MANIFEST.toml" <<'TOML'
[repos.lib-repo]
org = "greenticai"
tier = 4
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

use_token_for_repo() { return 0; }

STUB_RUN_LIST_PAYLOAD=""
stub_run_list() { STUB_RUN_LIST_PAYLOAD="$1"; }
gh() {
  local jq_expr=""
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "--jq" ]] && { jq_expr="$2"; break; }
    shift
  done
  echo "$STUB_RUN_LIST_PAYLOAD" | jq -r "$jq_expr"
}

REPO="greenticai/lib-repo"
# 2026-09-30T08:34:00Z, the moment of dispatch (skew already subtracted).
SINCE=$(date -u -d '2026-09-30T08:34:00Z' +%s 2>/dev/null \
  || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2026-09-30T08:34:00Z' +%s)

echo "── find_dispatched_run ──"

# The 2026-09-30 incident: a stale view whose newest run is weeks old, and a
# before_id read from the same stale view. The old ID-only rule adopted it.
stub_run_list '[
  {"databaseId": 32685545595, "createdAt": "2026-08-24T03:10:42Z", "event": "workflow_dispatch"}
]'
assert_eq "a stale run from before the dispatch is never adopted" "" \
  "$(find_dispatched_run "$REPO" 31990607155 "$SINCE")"

# The fresh view: our run is there and newer than the dispatch moment.
stub_run_list '[
  {"databaseId": 36690505647, "createdAt": "2026-09-30T08:34:05Z", "event": "workflow_dispatch"},
  {"databaseId": 36607968002, "createdAt": "2026-09-29T17:52:03Z", "event": "push"}
]'
assert_eq "the run created after the dispatch is adopted" "36690505647" \
  "$(find_dispatched_run "$REPO" 36607968002 "$SINCE")"

# A stale before_id (too low) must not matter once the fresh run is visible.
assert_eq "a stale before_id still finds the fresh run" "36690505647" \
  "$(find_dispatched_run "$REPO" 31990607155 "$SINCE")"

# A push run landing right after the dispatch is not ours — waiting on it
# would report someone else's result for our dispatch.
stub_run_list '[
  {"databaseId": 500, "createdAt": "2026-09-30T08:34:10Z", "event": "push"}
]'
assert_eq "a push run after the dispatch is not ours" "" \
  "$(find_dispatched_run "$REPO" 100 "$SINCE")"

# Two fresh dispatch runs: take the oldest above before_id, the one closest to
# our dispatch, rather than skipping ahead.
stub_run_list '[
  {"databaseId": 700, "createdAt": "2026-09-30T08:35:00Z", "event": "workflow_dispatch"},
  {"databaseId": 600, "createdAt": "2026-09-30T08:34:03Z", "event": "workflow_dispatch"}
]'
assert_eq "the oldest fresh dispatch run is adopted" "600" \
  "$(find_dispatched_run "$REPO" 100 "$SINCE")"

# Nothing yet: empty, so the caller keeps polling.
stub_run_list '[]'
assert_eq "no run yet yields empty" "" \
  "$(find_dispatched_run "$REPO" 100 "$SINCE")"

# Garbage inputs refuse rather than feeding "" into the jq comparison.
assert_fails "non-numeric before_id is refused" \
  find_dispatched_run "$REPO" "" "$SINCE"
assert_fails "non-numeric since is refused" \
  find_dispatched_run "$REPO" 100 "now"

echo ""
echo "── Summary ──"
echo "  Run:    $tests_run"
echo "  Failed: $tests_failed"
[[ "$tests_failed" -eq 0 ]] || exit 1
echo "  All dispatch-detect tests passed"
