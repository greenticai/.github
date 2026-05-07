#!/usr/bin/env bash
# cleanup-dev-releases.sh — Delete old dev-lane GitHub Releases.
#
# For each binary-bifurcated repo (`binary-crates` set in REPO_MANIFEST.toml),
# lists prerelease GitHub Releases created by dev-release-binaries.yml — these
# have `isPrerelease == true` AND a name ending in `(dev build)` — and deletes
# those older than RETENTION_DAYS, keeping the KEEP_LATEST most-recent
# regardless of age.
#
# Used by .github/workflows/cleanup-dev-releases.yml on a weekly cron.
# Without periodic cleanup, ~16 binary repos × nightly publishes accumulate
# ~5800 dev tags/year per repo otherwise.
#
# Why both filters (age AND keep-latest):
#   - Age alone deletes everything if a repo went dormant for > retention
#     window, which would break `cargo binstall <name>-dev` (the live
#     crates.io max_version's binstall metadata points at an archive in one
#     of those releases).
#   - Keep-latest alone keeps every release on active repos forever.
#   - Combined: dormant repos keep N, active repos keep N + last-N-days.
#
# Inputs (env):
#   GH_TOKEN_GREENTICAI    — App token scoped to greenticai org installation
#   GH_TOKEN_GREENTIC_BIZ  — App token scoped to greentic-biz org installation
#   GH_TOKEN               — Fallback when per-org tokens aren't set (e.g. local runs)
#   DRY_RUN                — "true" to preview without deleting (default: false)
#   RETENTION_DAYS         — Age threshold in days (default: 30)
#   KEEP_LATEST            — Always keep this many most-recent releases (default: 3)
#   SINGLE_REPO            — Process only this repo (empty = all binary-bifurcated)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/../toolchain/REPO_MANIFEST.toml"

DRY_RUN="${DRY_RUN:-false}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
KEEP_LATEST="${KEEP_LATEST:-3}"
SINGLE_REPO="${SINGLE_REPO:-}"

# Per-org tokens, with single-token fallback for local invocation.
GH_TOKEN_GREENTICAI="${GH_TOKEN_GREENTICAI:-${GH_TOKEN:-}}"
GH_TOKEN_GREENTIC_BIZ="${GH_TOKEN_GREENTIC_BIZ:-${GH_TOKEN:-}}"

token_for_org() {
  case "$1" in
    greenticai)   echo "$GH_TOKEN_GREENTICAI" ;;
    greentic-biz) echo "$GH_TOKEN_GREENTIC_BIZ" ;;
    *)            echo "::error::Unknown org '$1' — no token available" >&2; return 1 ;;
  esac
}

repo_reachable() {
  local repo="$1"
  gh api "repos/$repo" --silent 2>/dev/null
}

if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
  echo "::error::RETENTION_DAYS must be a non-negative integer, got '${RETENTION_DAYS}'"
  exit 1
fi
if ! [[ "$KEEP_LATEST" =~ ^[0-9]+$ ]]; then
  echo "::error::KEEP_LATEST must be a non-negative integer, got '${KEEP_LATEST}'"
  exit 1
fi

cutoff_iso=$(date -u -d "${RETENTION_DAYS} days ago" --iso-8601=seconds)
cutoff_epoch=$(date -u -d "${RETENTION_DAYS} days ago" +%s)

echo "Cleanup parameters:"
echo "  Retention:   ${RETENTION_DAYS} days (cutoff ${cutoff_iso})"
echo "  Keep latest: ${KEEP_LATEST}"
echo "  Dry run:     ${DRY_RUN}"
[ -n "$SINGLE_REPO" ] && echo "  Single repo: ${SINGLE_REPO}"
echo ""

# ── Parse manifest — emit "org/name" for binary-bifurcated repos ─
mapfile -t repos < <(python3 -c "
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
for name, entry in m.get('repos', {}).items():
    if entry.get('archived', False):
        continue
    if not entry.get('binary-crates'):
        continue
    print(f\"{entry['org']}/{name}\")
")

if [ "${#repos[@]}" -eq 0 ]; then
  echo "::error::No binary-bifurcated repos found in $MANIFEST"
  exit 1
fi

total_deleted=0
total_kept_age=0
total_kept_recent=0
total_failed=0
total_repos=0

for repo in "${repos[@]}"; do
  if [ -n "$SINGLE_REPO" ] && [ "${repo##*/}" != "$SINGLE_REPO" ]; then
    continue
  fi

  ((total_repos++)) || true
  echo "::group::$repo"

  # Per-org App token for the `gh` calls below. Fail loud on token-scope or
  # App-installation gaps so we don't silently misclassify private repos.
  org="${repo%%/*}"
  GH_TOKEN="$(token_for_org "$org")" || { ((total_failed++)) || true; echo "::endgroup::"; continue; }
  if [ -z "$GH_TOKEN" ]; then
    echo "::warning::$repo — no token available for org '$org', skipping"
    echo "::endgroup::"
    continue
  fi
  export GH_TOKEN

  if ! repo_reachable "$repo"; then
    echo "::warning::$repo — repo unreachable (token scope or App not installed in '$org'?), skipping"
    echo "::endgroup::"
    continue
  fi

  # Sorted DESC by createdAt (gh release list default ordering is by created
  # date descending). Filter to dev-build prereleases via --jq.
  releases=$(gh release list --repo "$repo" --limit 1000 \
    --json tagName,name,isPrerelease,createdAt \
    --jq '.[] | select(.isPrerelease == true) | select(.name | endswith("(dev build)")) | "\(.tagName)\t\(.createdAt)"' \
    2>/dev/null || true)

  if [ -z "$releases" ]; then
    echo "No dev releases"
    echo "::endgroup::"
    continue
  fi

  deleted=0
  kept_recent=0
  kept_age=0
  failed=0
  index=0

  while IFS=$'\t' read -r tag created; do
    [ -z "$tag" ] && continue
    if [ "$index" -lt "$KEEP_LATEST" ]; then
      echo "  keep (recent) $tag — created $created"
      ((kept_recent++)) || true
      ((index++)) || true
      continue
    fi
    ((index++)) || true

    created_epoch=$(date -u -d "$created" +%s)
    if [ "$created_epoch" -ge "$cutoff_epoch" ]; then
      echo "  keep (age)    $tag — created $created"
      ((kept_age++)) || true
      continue
    fi

    if [ "$DRY_RUN" = "true" ]; then
      echo "  DRY-RUN delete $tag — created $created"
      ((deleted++)) || true
      continue
    fi

    if gh release delete "$tag" --repo "$repo" --cleanup-tag --yes >/dev/null 2>&1; then
      echo "  ✓ deleted     $tag — created $created"
      ((deleted++)) || true
    else
      echo "  ✗ FAILED      $tag — created $created"
      ((failed++)) || true
    fi
  done <<< "$releases"

  echo ""
  echo "  Summary: deleted=${deleted} kept_recent=${kept_recent} kept_age=${kept_age} failed=${failed}"
  total_deleted=$((total_deleted + deleted))
  total_kept_recent=$((total_kept_recent + kept_recent))
  total_kept_age=$((total_kept_age + kept_age))
  total_failed=$((total_failed + failed))

  echo "::endgroup::"
done

echo ""
echo "━━━ Total ━━━"
echo "Repos processed:  ${total_repos}"
echo "Releases deleted: ${total_deleted}"
echo "Kept (recent):    ${total_kept_recent}"
echo "Kept (within age):${total_kept_age}"
echo "Failures:         ${total_failed}"

# Job summary for the Actions UI
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Cleanup Dev Releases"
    echo ""
    echo "| Metric | Value |"
    echo "|---|---|"
    echo "| Repos processed | ${total_repos} |"
    echo "| Releases deleted | ${total_deleted} |"
    echo "| Kept (latest ${KEEP_LATEST} per repo) | ${total_kept_recent} |"
    echo "| Kept (within ${RETENTION_DAYS}-day window) | ${total_kept_age} |"
    echo "| Failures | ${total_failed} |"
    echo "| Cutoff | \`${cutoff_iso}\` |"
    [ "$DRY_RUN" = "true" ] && echo "| Mode | **DRY-RUN** (no deletions executed) |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$total_failed" -gt 0 ]; then
  exit 1
fi
