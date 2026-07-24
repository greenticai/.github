#!/usr/bin/env bash
# Unit tests for .github/actions/ensure-release/ensure-release.sh.
#
# Run: bash scripts/test_ensure_release.sh
#
# The release-binaries reusables are deliberately excluded from self-test.yml
# (they cut real GitHub Releases), so `actionlint` plus this harness are the
# only gates the retry logic has. Run it by hand when touching the action.
#
# The functions under test are sourced from the real script — never retyped,
# so the test cannot drift from the source. The script guards `main` behind a
# BASH_SOURCE check precisely so this works.
#
# Two traps this harness exists to avoid:
#   1. A retry that gives up early looks identical to one that never retried.
#      Every case asserts the exact CALL COUNT, not just the exit status.
#   2. Success-only tests prove nothing — a create_release that always returns
#      0 would pass them. The bounded-failure and no-redundant-create cases
#      are the ones with teeth.

set -uo pipefail

SRC="${SRC_OVERRIDE:-$(dirname "$0")/../.github/actions/ensure-release/ensure-release.sh}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export TAG="v1.2.30069402499"
export ASSETS=".dist-staging/*.tgz"
export RUNNER_TEMP="$TMP"
export BACKOFF_BASE_SECONDS=0   # do not actually sleep through the backoff

# shellcheck source=/dev/null
source "$SRC"
set +e   # the sourced script sets -e; the negative cases need to survive

# ── stub gh ───────────────────────────────────────────────────────────────
#
# Behaviour is driven by per-subcommand plans: a space-separated list of
# outcomes, one per call, with the last one repeating once exhausted. Counts
# live in files because `gh` runs inside command substitutions and `if`
# conditions where a variable would not survive.
VIEW_PLAN="no"
CREATE_PLAN="ok"
UPLOAD_PLAN="ok"

reset_counts() {
  echo 0 > "$TMP/view.n"; echo 0 > "$TMP/create.n"; echo 0 > "$TMP/upload.n"
}

nth() {  # nth <plan> <1-based index> — last entry repeats
  local -a plan=($1)
  local i=$(( $2 - 1 ))
  (( i >= ${#plan[@]} )) && i=$(( ${#plan[@]} - 1 ))
  echo "${plan[$i]}"
}

bump() {  # bump <counter-file> -> new value
  local n; n=$(( $(cat "$1") + 1 )); echo "$n" > "$1"; echo "$n"
}

gh() {
  local sub="${1:-} ${2:-}" n outcome
  case "$sub" in
    "release view")
      n=$(bump "$TMP/view.n"); outcome=$(nth "$VIEW_PLAN" "$n")
      [ "$outcome" = "ok" ] && return 0
      echo "release not found" >&2; return 1 ;;
    "release create")
      n=$(bump "$TMP/create.n"); outcome=$(nth "$CREATE_PLAN" "$n")
      case "$outcome" in
        ok) echo "https://github.com/o/r/releases/tag/$TAG"; return 0 ;;
        exists)
          echo "HTTP 422: Validation Failed (https://api.github.com/repos/o/r/releases)" >&2
          echo "Release.tag_name already exists" >&2; return 1 ;;
        *)  # the 2026-07-24 failure, verbatim
          echo "HTTP 403: Resource not accessible by integration (https://api.github.com/repos/o/r/releases)" >&2
          return 1 ;;
      esac ;;
    "release upload")
      n=$(bump "$TMP/upload.n"); outcome=$(nth "$UPLOAD_PLAN" "$n")
      [ "$outcome" = "ok" ] && return 0
      echo "HTTP 502: Bad gateway" >&2; return 1 ;;
    *) echo "unstubbed gh call: $*" >&2; return 127 ;;
  esac
}

# ── assertions ────────────────────────────────────────────────────────────
fails=0
check() {  # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1 — expected '$2', got '$3'"
    fails=$(( fails + 1 ))
  fi
}

CREATE_ARGS=(--title "$TAG" --notes "" --prerelease --latest=false)
ASSET_FILES=("$TMP/fake.tgz")

run_create() {  # sets rc / creates / views
  reset_counts
  with_retries "gh release create ${TAG}" create_release >/dev/null 2>&1
  rc=$?
  views=$(cat "$TMP/view.n"); creates=$(cat "$TMP/create.n")
}

echo "== a transient failure is retried, not fatal =="
ATTEMPTS=5 VIEW_PLAN="no" CREATE_PLAN="403 403 ok"; run_create
check "exit status"   0 "$rc"
check "create calls"  3 "$creates"

echo "== a persistent failure stays bounded =="
ATTEMPTS=3 VIEW_PLAN="no" CREATE_PLAN="403"; run_create
check "exit status"   1 "$rc"
check "create calls"  3 "$creates"

echo "== a lost response is absorbed by the pre-create existence check =="
# The POST landed server-side but its response never came back. The second
# attempt must see the release and stop — NOT create it again.
ATTEMPTS=5 VIEW_PLAN="no ok" CREATE_PLAN="403"; run_create
check "exit status"   0 "$rc"
check "create calls"  1 "$creates"
check "view calls"    2 "$views"

echo "== a sibling job's concurrent create is success, not a retry =="
ATTEMPTS=5 VIEW_PLAN="no" CREATE_PLAN="exists"; run_create
check "exit status"   0 "$rc"
check "create calls"  1 "$creates"

echo "== an existing release is reused without a create =="
ATTEMPTS=5 VIEW_PLAN="ok" CREATE_PLAN="403"; run_create
check "exit status"   0 "$rc"
check "create calls"  0 "$creates"

echo "== upload is retried too =="
reset_counts
ATTEMPTS=5 UPLOAD_PLAN="502 ok"
with_retries "gh release upload ${TAG}" upload_assets >/dev/null 2>&1
check "exit status"   0 "$?"
check "upload calls"  2 "$(cat "$TMP/upload.n")"

echo "== an empty asset set fails instead of silently publishing nothing =="
reset_counts
ATTEMPTS=1 VIEW_PLAN="ok" ASSETS="$TMP/nothing-matches-*.tgz"
main >/dev/null 2>&1
check "exit status"   1 "$?"
check "upload calls"  0 "$(cat "$TMP/upload.n")"

echo
if [ "$fails" -eq 0 ]; then
  echo "all ensure-release tests passed"
else
  echo "$fails assertion(s) failed"
  exit 1
fi
