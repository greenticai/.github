#!/usr/bin/env bash
# Unit tests for push_bot_branch in nightly-cargo-lock-sync.sh.
#
# Run: bash scripts/test_push_bot_branch.sh
#
# The bot-branch push had no retry, so one GitHub 5xx failed the repo and the
# whole Cargo.lock sync job. Observed 2026-11-04 in run 41800545884, during a
# GitHub Git Operations incident: 8 repos answered `remote: Internal Server
# Error` or `remote: fatal error in commit_refs_rules`, and the job went red.
#
# The function under test is extracted from the real script with sed and
# eval'd, never retyped. Counters are files because git runs in a subshell;
# see test_reap_ready_pr.sh's header for the trap.
#
# The tests with teeth: (a) a 5xx whose push was actually applied server-side
# must count as success, because a blind retry would fail on a stale lease;
# (b) a non-transient rejection must NOT be retried.

set -uo pipefail

SRC="${SRC_OVERRIDE:-$(dirname "$0")/nightly-cargo-lock-sync.sh}"

eval "$(sed -n '/^push_bot_branch() {/,/^}/p' "$SRC")"

BRANCH="chore/nightly-cargo-update"
PUSH_TRIES=3
PUSH_RETRY_SEC=0
warn() { :; }
err()  { :; }

tests_run=0
tests_failed=0
ok()   { echo "  ✓ $1"; }
fail() {
  echo "  ✗ $1"
  echo "      expected: $2"
  echo "      actual:   $3"
  ((tests_failed++)) || true
}
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  ((tests_run++)) || true
  if [[ "$expected" == "$actual" ]]; then ok "$label"; else fail "$label" "$expected" "$actual"; fi
}

COUNT_DIR=$(mktemp -d)
DIR=$(mktemp -d)
trap 'rm -rf "$COUNT_DIR" "$DIR"' EXIT
ERRFILE="$COUNT_DIR/push.err"
LOCAL_SHA="aaaa1111"

# PUSH_ERRORS is consumed one line per push call; an empty line means success.
# REMOTE_SHA is what ls-remote reports after a failed push.
PUSH_ERRORS=""
REMOTE_SHA=""
reset() {
  : >"$COUNT_DIR/pushes"
  printf '%s\n' "$1" >"$COUNT_DIR/errors"
  REMOTE_SHA="$2"
}
pushes() { wc -l <"$COUNT_DIR/pushes" | tr -d ' '; }

git() {
  case "$1" in
    push)
      echo x >>"$COUNT_DIR/pushes"
      local line
      line=$(head -1 "$COUNT_DIR/errors")
      sed -i '1d' "$COUNT_DIR/errors"
      if [[ -z "$line" ]]; then return 0; fi
      echo "$line" >&2
      return 1
      ;;
    rev-parse) echo "$LOCAL_SHA" ;;
    ls-remote) [[ -n "$REMOTE_SHA" ]] && printf '%s\trefs/heads/%s\n' "$REMOTE_SHA" "$BRANCH" ;;
  esac
}

run() {
  push_bot_branch "$DIR" "https://x" "leasesha" "$ERRFILE"
  echo $?
}

echo "push_bot_branch"

reset "" ""
assert_eq "clean push: success, one attempt" "0 1" "$(run) $(pushes)"

reset "$(printf 'remote: Internal Server Error\n')
" ""
assert_eq "one 500 then success: success, two attempts" "0 2" "$(run) $(pushes)"

reset "remote: Internal Server Error
remote: fatal error in commit_refs_rules
remote: Internal Server Error" ""
assert_eq "persistent 5xx: fails after PUSH_TRIES" "1 3" "$(run) $(pushes)"

reset "remote: fatal error in commit_refs_rules" "$LOCAL_SHA"
assert_eq "5xx but ref already applied: success, no blind retry" "0 1" "$(run) $(pushes)"

reset "remote: fatal error in commit_refs_rules
" "someoneelse"
assert_eq "5xx and remote moved by someone else: still retries" "0 2" "$(run) $(pushes)"

reset " ! [remote rejected] x -> x (protected branch hook declined)" ""
assert_eq "non-transient rejection: not retried" "1 1" "$(run) $(pushes)"

reset " ! [rejected] x -> x (stale info)" ""
assert_eq "stale lease: not retried" "1 1" "$(run) $(pushes)"

echo
echo "$tests_run run, $tests_failed failed"
[[ $tests_failed -eq 0 ]]
