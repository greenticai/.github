#!/usr/bin/env bash
# Unit tests for ensure_pr in nightly-cargo-lock-sync.sh.
#
# Run: bash scripts/test_ensure_pr.sh
#
# `gh pr create` had no retry, so ONE transient API error failed the whole
# Cargo.lock sync job — and that job is what reports the nightly. Observed
# 2026-08-10 in run 31373922024: for greentic-start, and for no other repo of
# the 31 in that same run, `gh pr create` answered
#
#   GraphQL: Could not resolve to a Repository with the name 'greenticai/greentic-start'
#
# two seconds after the SAME App token had pushed the branch to that same repo
# (commit b64a7eb0, 12:00:02, author greentic-ci[bot]), and the night before the
# same repo had opened #499 without trouble. Nothing about the repo, the branch,
# the base, or the token's access had changed — the PR was openable by hand
# minutes later (#501).
#
# The function under test is extracted from the real script with sed and
# eval'd — never retyped, so the test cannot drift from the source. Same
# approach as test_reap_ready_pr.sh; read its header for the subshell trap.
#
# The test with teeth is the LAST one: a retry that blindly re-creates would
# open a duplicate PR whenever a create succeeded but its output was lost.

set -uo pipefail

SRC="${SRC_OVERRIDE:-$(dirname "$0")/nightly-cargo-lock-sync.sh}"

eval "$(sed -n '/^ensure_pr() {/,/^}/p' "$SRC")"

BRANCH="chore/nightly-cargo-update"
PR_CREATE_TRIES=3
PR_CREATE_RETRY_SEC=0   # do not actually sleep through the backoff
log()  { :; }
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

# `gh pr create` is called inside `$(...)`, a SUBSHELL — a counter kept in a
# variable is lost when it returns. Every count here is a file, for the reason
# test_reap_ready_pr.sh's header spells out.
COUNT_DIR=$(mktemp -d)
trap 'rm -rf "$COUNT_DIR"' EXIT
reset_counts() { : >"$COUNT_DIR/create"; : >"$COUNT_DIR/list"; }
creates()      { wc -l <"$COUNT_DIR/create" | tr -d ' '; }

# Scripted stub: LIST_ANSWERS and CREATE_ANSWERS are consumed one line per call,
# so a test can say "fail, then succeed" rather than "always fail".
LIST_ANSWERS=""
CREATE_ANSWERS=""
next_answer() {
  local file="$COUNT_DIR/$1.remaining"
  local line
  line=$(head -1 "$file")
  sed -i '1d' "$file"
  echo "$line"
}
script_answers() {
  printf '%s\n' "$1" >"$COUNT_DIR/list.remaining"
  printf '%s\n' "$2" >"$COUNT_DIR/create.remaining"
}

gh() {
  case "${2:-}" in
    list)   echo x >>"$COUNT_DIR/list";   next_answer list ;;
    create) echo x >>"$COUNT_DIR/create"; next_answer create ;;
  esac
}

echo "── ensure_pr ──"

# An already-open PR is adopted, and no create is attempted at all.
reset_counts
script_answers "42" "SHOULD-NOT-BE-CALLED"
assert_eq "adopts an existing open PR" \
  "https://github.com/o/r/pull/42" "$(ensure_pr o/r body)"
assert_eq "  …and never calls create" "0" "$(creates)"

# The ordinary path: nothing open, one create, one URL.
reset_counts
script_answers "" "https://github.com/o/r/pull/7"
assert_eq "creates when no PR is open" \
  "https://github.com/o/r/pull/7" "$(ensure_pr o/r body)"
assert_eq "  …in a single attempt" "1" "$(creates)"

# The failure this whole function exists for: one transient error, then fine.
reset_counts
script_answers "$(printf '%s\n%s' "" "")" \
               "$(printf '%s\n%s' "GraphQL: Could not resolve to a Repository with the name 'o/r'. (repository)" \
                                  "https://github.com/o/r/pull/8")"
assert_eq "retries past a transient create failure" \
  "https://github.com/o/r/pull/8" "$(ensure_pr o/r body)"
assert_eq "  …taking exactly two attempts" "2" "$(creates)"

# A create that keeps failing must report failure, not a bare or partial URL.
reset_counts
script_answers "$(printf '%s\n%s\n%s' "" "" "")" \
               "$(printf '%s\n%s\n%s' "GraphQL: boom" "GraphQL: boom" "GraphQL: boom")"
out=$(ensure_pr o/r body); rc=$?
((tests_run++)) || true
if [[ "$rc" -ne 0 && -z "$out" ]]; then ok "gives up after PR_CREATE_TRIES"
else fail "gives up after PR_CREATE_TRIES" "non-zero rc, empty stdout" "rc=$rc out='$out'"; fi
assert_eq "  …having tried exactly PR_CREATE_TRIES times" "3" "$(creates)"

# The one with teeth. A create can SUCCEED and still look like a failure —
# a dropped response, a `gh` that writes the URL somewhere `tail -1` misses.
# Re-checking for an open PR BEFORE each retry adopts that PR; a retry that
# went straight back to `gh pr create` would open a second one.
reset_counts
script_answers "$(printf '%s\n%s' "" "99")" \
               "$(printf '%s\n%s' "GraphQL: boom" "SHOULD-NOT-BE-CALLED")"
assert_eq "adopts a PR the failed attempt actually created" \
  "https://github.com/o/r/pull/99" "$(ensure_pr o/r body)"
assert_eq "  …without creating a duplicate" "1" "$(creates)"

echo ""
echo "── Summary ──"
echo "  Run:    $tests_run"
echo "  Failed: $tests_failed"
[[ "$tests_failed" -eq 0 ]] || exit 1
echo "  All ensure_pr tests passed"
