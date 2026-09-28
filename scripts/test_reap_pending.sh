#!/usr/bin/env bash
# Unit tests for reap_pending's merge-error accounting in
# nightly-cargo-lock-sync.sh.
#
# Run: bash scripts/test_reap_pending.sh
#
# Regression for run 36395828744: a merge that answered 502 on one poll and
# succeeded on the next was counted as BOTH merged and merge-failed, and the
# job exited 1. A merge error must be counted once per PR, and only when the
# window closes on it unmerged.
#
# reap_pending is extracted from the real script with sed and eval'd — never
# retyped, so the test cannot drift from the source. `gh pr merge` runs in a
# subshell, so every piece of stub state lives in files, not variables.

# Globals below are read by the eval'd reap_pending, which shellcheck cannot see.
# shellcheck disable=SC2034
set -uo pipefail

SRC="${SRC_OVERRIDE:-$(dirname "$0")/nightly-cargo-lock-sync.sh}"

eval "$(sed -n '/^checks_pending() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^checks_failed() {/,/^}/p'  "$SRC")"
eval "$(sed -n '/^reap_pending() {/,/^}/p'   "$SRC")"

REAPER_POLL_SEC=0
REAPER_MAX_SEC=5
MERGE_RETRY_TRIES=2
MERGE_RETRY_SEC=0
log()  { :; }
warn() { :; }
token_for_org() { echo tok; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# $T/state      — OPEN until a merge succeeds, then MERGED
# $T/outcomes   — one merge outcome per line, consumed in order:
#                 ok | 502 | policy   (last line repeats once exhausted)
# $T/attempts   — one line per `gh pr merge` call
gh() {
  case "${2:-}" in
    view)
      printf '{"state":"%s","mergeable":"MERGEABLE","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}\n' \
        "$(cat "$T/state")" ;;
    merge)
      echo x >> "$T/attempts"
      local n out
      n=$(wc -l < "$T/attempts")
      out=$(sed -n "${n}p" "$T/outcomes"); [[ -n "$out" ]] || out=$(tail -1 "$T/outcomes")
      case "$out" in
        ok)     echo MERGED > "$T/state"; return 0 ;;
        502)    echo "HTTP 502: 502 Bad Gateway (https://api.github.com/graphql)"; return 1 ;;
        policy) echo "GraphQL: Base branch policy prohibits the merge"; return 1 ;;
      esac ;;
  esac
}

RC=0
scenario() {
  local label="$1" outcomes="$2" want_merged="$3" want_err="$4" want_pending="$5"
  echo OPEN > "$T/state"; : > "$T/attempts"; printf '%s\n' $outcomes > "$T/outcomes"
  c_merged=0; c_merge_err=0; c_conflict=0; c_ci_red=0
  conflict_urls=(); red_urls=(); merge_err_urls=()
  declare -gA merge_err_last=()
  pending_prs=("org/repo|https://github.com/org/repo/pull/1")
  reap_pending
  local got="merged=$c_merged err=$c_merge_err pending=${#pending_prs[@]} urls=${#merge_err_urls[@]}"
  local want="merged=$want_merged err=$want_err pending=$want_pending urls=$want_err"
  if [[ "$got" == "$want" ]]; then echo "ok   $label"
  else echo "FAIL $label — want [$want] got [$got]"; RC=1; fi
}

# 502 three times in a row (initial + 2 immediate retries), merged on the next poll.
scenario "502 then merged on a later poll counts only as merged" "502 502 502 ok" 1 0 0
# 502 once, the immediate retry lands it — one poll, no error.
scenario "502 retried immediately counts only as merged"          "502 ok"         1 0 0
# A policy refusal every poll until the window closes: one error, not one per poll,
# and it leaves pending_prs so it is not also "still on CI".
scenario "persistent refusal counts once and is not also pending" "policy"         0 1 0

# A policy refusal must not be retried immediately — it answers the same every time.
echo OPEN > "$T/state"; : > "$T/attempts"; printf 'policy\nok\n' > "$T/outcomes"
c_merged=0; c_merge_err=0; merge_err_urls=(); declare -gA merge_err_last=()
REAPER_MAX_SEC=5; REAPER_POLL_SEC=100   # forces a single poll
pending_prs=("org/repo|u"); reap_pending
REAPER_POLL_SEC=0
if [[ "$(wc -l < "$T/attempts")" == "1" && "$c_merge_err" == "1" ]]; then
  echo "ok   policy refusal is not retried within a poll"
else
  echo "FAIL policy refusal retried within a poll (attempts=$(wc -l < "$T/attempts") err=$c_merge_err)"; RC=1
fi

exit "$RC"
