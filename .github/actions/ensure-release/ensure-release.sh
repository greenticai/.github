#!/usr/bin/env bash
# Ensure a GitHub Release exists for $TAG, then attach $ASSETS to it.
#
# Both REST writes are retried with exponential backoff. They used to be
# single-shot, and a single transient failure from the Releases API failed the
# whole job. On the dev lane that halts the tier-ordered nightly train for
# every repo below the failing tier:
#
#   2026-07-24 — greentic-start, POST /releases -> HTTP 403 "Resource not
#   accessible by integration", on a token the runner reported as
#   `Contents: write`. The identical call from the identical reusable workflow
#   succeeded in greentic-operator 41 minutes earlier, in greentic-start
#   itself an hour before that, and again in greentic-start 47 minutes later.
#   No ruleset, no tag protection, no settings drift — the API just said no
#   once. Nightly halted at tier 9 and never dispatched tier 10.
#
# Idempotent by construction, so the retry can never do damage:
#   * `release_exists` is re-checked before every create attempt, so a POST
#     whose response was lost is not retried into a spurious 422.
#   * the 422 a sibling caller's concurrent create produces (multi-binary
#     repos call this once per crate, for the same tag) is the success it
#     looks like.
#   * `gh release upload --clobber` overwrites rather than duplicating.
#
# Unit-tested by scripts/test_ensure_release.sh in this repo.

set -euo pipefail

: "${TAG:?TAG is required}"
: "${ASSETS:?ASSETS is required}"

ATTEMPTS="${ATTEMPTS:-5}"
# Overridable so the unit test does not sleep its way through the backoff.
BACKOFF_BASE_SECONDS="${BACKOFF_BASE_SECONDS:-5}"

release_exists() {
  gh release view "$1" >/dev/null 2>&1
}

# with_retries <label> <cmd...>
#
# Retries any non-zero exit up to $ATTEMPTS times with exponential backoff.
# The command owns its own idempotence — see create_release below. Each
# attempt's own diagnostics are left on stderr, so a real failure is never
# hidden behind the retry.
with_retries() {
  local label="$1"; shift
  local attempt=1 delay
  while :; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$ATTEMPTS" ]; then
      echo "::error::${label} failed after ${attempt} attempt(s)" >&2
      return 1
    fi
    delay=$(( BACKOFF_BASE_SECONDS * (2 ** attempt) ))
    echo "${label} failed (attempt ${attempt}/${ATTEMPTS}) — retrying in ${delay}s" >&2
    sleep "$delay"
    attempt=$(( attempt + 1 ))
  done
}

# Reads the global CREATE_ARGS array assembled by main.
create_release() {
  if release_exists "$TAG"; then
    echo "Release $TAG already exists — reusing (idempotent)"
    return 0
  fi
  local err="${RUNNER_TEMP:-/tmp}/ensure-release-create.err"
  if gh release create "$TAG" "${CREATE_ARGS[@]}" 2>"$err"; then
    echo "Created release $TAG"
    return 0
  fi
  cat "$err" >&2
  if grep -qi 'already exists' "$err"; then
    echo "Release $TAG was created concurrently by a sibling job — reusing"
    return 0
  fi
  return 1
}

# Reads the global ASSET_FILES array assembled by main.
upload_assets() {
  gh release upload "$TAG" "${ASSET_FILES[@]}" --clobber
}

main() {
  CREATE_ARGS=()
  if [ -n "${TARGET:-}" ]; then
    CREATE_ARGS+=(--target "$TARGET")
  fi
  if [ -n "${TITLE:-}" ]; then
    CREATE_ARGS+=(--title "$TITLE")
  fi
  if [ "${GENERATE_NOTES:-false}" = "true" ]; then
    CREATE_ARGS+=(--generate-notes)
  else
    CREATE_ARGS+=(--notes "${NOTES:-}")
  fi
  if [ "${PRERELEASE:-false}" = "true" ]; then
    CREATE_ARGS+=(--prerelease)
  fi
  # Tri-state: empty leaves gh's own default alone, which is what the stable
  # lane wants. The prerelease lanes pass 'false' so a dev build never
  # displaces the stable release on the repo page.
  if [ -n "${LATEST:-}" ]; then
    CREATE_ARGS+=("--latest=${LATEST}")
  fi

  with_retries "gh release create ${TAG}" create_release

  shopt -s nullglob
  ASSET_FILES=()
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    # Deliberate glob expansion — $pattern is a caller-supplied glob.
    # shellcheck disable=SC2206
    ASSET_FILES+=( $pattern )
  done <<< "$ASSETS"

  if [ ${#ASSET_FILES[@]} -eq 0 ]; then
    echo "::error::No release assets matched:" >&2
    printf '  %s\n' "$ASSETS" >&2
    return 1
  fi

  with_retries "gh release upload ${TAG}" upload_assets
}

# Sourcing this file (the unit test does) must not run main.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
