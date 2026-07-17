#!/usr/bin/env bash
# Unit tests for reap_ready_pr / checks_pending / checks_failed in
# nightly-cargo-lock-sync.sh.
#
# Run: bash scripts/test_reap_ready_pr.sh
#
# Nothing in CI runs this (no workflow triggers on scripts/**) — local
# verification is the only gate this script has, which is how a reaper that
# merged nothing for 7 straight rounds shipped unnoticed. Run it by hand when
# touching the reap path.
#
# The functions under test are extracted from the real script with sed and
# eval'd — never retyped, so the test cannot drift from the source.
#
# Two traps this harness exists to avoid:
#   1. `gh pr merge` is called inside `out=$(...)`, a SUBSHELL. A stub that
#      records the attempt in a variable loses it, and every negative test
#      "passes" even when the function merges everything. The marker is a file.
#   2. Negative tests alone prove nothing — a function that always refuses
#      passes all of them. The positive case below is the one that has teeth.

set -uo pipefail

SRC="${SRC_OVERRIDE:-$(dirname "$0")/nightly-cargo-lock-sync.sh}"

eval "$(sed -n '/^checks_pending() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^checks_failed() {/,/^}/p'  "$SRC")"
eval "$(sed -n '/^reap_ready_pr() {/,/^}/p'  "$SRC")"

BRANCH="chore/nightly-cargo-update"
BOT_AUTHOR="greentic-ci[bot]"
c_reaped=0
log()  { :; }
warn() { :; }

MARK=$(mktemp)
trap 'rm -f "$MARK"' EXIT

VIEW_MAIN=""; VIEW_FILES=""; VIEW_COMMITS=""

# Stub gh. Any merge attempt lands in $MARK.
gh() {
  case "${2:-}" in
    list) echo "42" ;;
    view)
      if   [[ "$*" == *"state,mergeable,mergeStateStatus,statusCheckRollup"* ]]; then echo "$VIEW_MAIN"
      elif [[ "$*" == *"--json files"*   ]]; then jq '[.files[].path | select(endswith("Cargo.lock") | not)] | length' <<<"$VIEW_FILES"
      elif [[ "$*" == *"--json commits"* ]]; then jq "[.commits[] | select((.authors | length) == 0 or any(.authors[]; .name != \"$BOT_AUTHOR\"))] | length" <<<"$VIEW_COMMITS"
      fi ;;
    merge) echo yes > "$MARK"; return 0 ;;
  esac
}

GREEN='{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"SKIPPED"}]}'
LOCK_ONLY='{"files":[{"path":"Cargo.lock"}]}'
BOT_ONLY='{"commits":[{"authors":[{"name":"greentic-ci[bot]"}]}]}'

RC=0
run() { : > "$MARK"; VIEW_MAIN="$1"; VIEW_FILES="$2"; VIEW_COMMITS="$3"; reap_ready_pr org/repo repo; }
chk() {
  local want="$1" label="$2" got
  got=$([[ -s "$MARK" ]] && echo yes || echo no)
  if [[ "$want" == "$got" ]]; then echo "  PASS  $label"; else echo "  FAIL  $label (want merge=$want, got=$got)"; RC=1; fi
}

echo "== rollup predicates =="
[[ "$(checks_pending "$GREEN")" == "0" ]] && echo "  PASS  green rollup: 0 pending" || { echo "  FAIL  green rollup pending"; RC=1; }
[[ "$(checks_failed  "$GREEN")" == "0" ]] && echo "  PASS  green rollup: 0 failed"  || { echo "  FAIL  green rollup failed";  RC=1; }
[[ "$(checks_failed "$(jq -c '.statusCheckRollup[0].conclusion="FAILURE"' <<<"$GREEN")")" == "1" ]] \
  && echo "  PASS  red rollup: 1 failed" || { echo "  FAIL  red rollup"; RC=1; }
# A commit-status row carries .state, not .status — the other rollup shape.
[[ "$(checks_pending '{"statusCheckRollup":[{"state":"PENDING"}]}')" == "1" ]] \
  && echo "  PASS  commit-status shape: PENDING counted" || { echo "  FAIL  commit-status shape"; RC=1; }

echo "== reap_ready_pr: the positive case (the one with teeth) =="
run "$GREEN" "$LOCK_ONLY" "$BOT_ONLY"; chk yes "green bot Cargo.lock PR is merged"

echo "== reap_ready_pr: every guard refuses =="
run "$(jq -c '.statusCheckRollup[0].conclusion="FAILURE"' <<<"$GREEN")" "$LOCK_ONLY" "$BOT_ONLY"; chk no "red CI"
run "$(jq -c '.statusCheckRollup[0].status="IN_PROGRESS"' <<<"$GREEN")" "$LOCK_ONLY" "$BOT_ONLY"; chk no "CI still running"
run "$(jq -c '.mergeable="CONFLICTING"'     <<<"$GREEN")" "$LOCK_ONLY" "$BOT_ONLY";              chk no "conflicting with develop"
run "$(jq -c '.mergeStateStatus="UNSTABLE"' <<<"$GREEN")" "$LOCK_ONLY" "$BOT_ONLY";              chk no "mergeStateStatus not CLEAN"
run "$(jq -c '.state="CLOSED"'              <<<"$GREEN")" "$LOCK_ONLY" "$BOT_ONLY";              chk no "PR not open"
run "$(jq -c '.statusCheckRollup=[]'        <<<"$GREEN")" "$LOCK_ONLY" "$BOT_ONLY";              chk no "empty rollup is not evidence of green"
run "$GREEN" '{"files":[{"path":"Cargo.lock"},{"path":"src/lib.rs"}]}' "$BOT_ONLY";              chk no "carries a source fix"
run "$GREEN" "$LOCK_ONLY" '{"commits":[{"authors":[{"name":"a-human"}]}]}';                      chk no "human commit on the bot branch"
run "$GREEN" "$LOCK_ONLY" '{"commits":[{"authors":[]}]}';                                        chk no "authorless commit (any over [] is false)"

[[ $RC -eq 0 ]] && echo "All tests passed." || echo "FAILURES."
exit $RC
