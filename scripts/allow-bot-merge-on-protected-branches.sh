#!/usr/bin/env bash
# allow-bot-merge-on-protected-branches.sh — put the greentic-ci App on the
# branch-protection push allowlist of `develop`, fleet-wide.
#
# Why this exists:
#   18 public repos protect `develop` with a push `restrictions` allowlist that
#   holds team `developers` and `apps: []`. Merging a PR is a push, so every
#   `gh pr merge` the nightly cargo-lock-sync bot issues comes back as
#
#       Pull request ... is not mergeable: the base branch policy prohibits
#       the merge.
#
#   The PR itself is green and MERGEABLE — GitHub is refusing the *actor*, not
#   the change. `mergeable` only ever reports conflicts, so the reaper could not
#   see it, retried in a loop, and the run still exited green. Runs 29631115174
#   (2026-07-18) and 29674666358 (2026-07-19) stranded 19 lock PRs this way;
#   run 29556686456 (2026-07-17) stranded 15 before them. Each batch had to be
#   merged by hand by a human who *is* on the allowlist.
#
#   Adding the App to `restrictions.apps` is the fix. It grants exactly the
#   push right the bot already needs and nothing else — the `developers` team
#   entry, the required reviews and `enforce_admins` all stay as they are.
#
# Note: GitHub only enforces branch protection on public repos under the
# current free plan, so private repos report no protection and are skipped.
#
# Idempotent. Safe to re-run. Skips archived repos.
#
# Usage:
#   bash scripts/allow-bot-merge-on-protected-branches.sh             # apply
#   bash scripts/allow-bot-merge-on-protected-branches.sh --dry-run   # preview
#
# Requires: gh CLI authenticated with repo-admin scope on both orgs.

set -uo pipefail

MANIFEST="toolchain/REPO_MANIFEST.toml"
BRANCH="develop"
APP_SLUG="${GREENTIC_CI_APP_SLUG:-greentic-ci}"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "Error: $MANIFEST not found — run from .github repo root" >&2
  exit 1
fi

list_targets() {
  python3 -c "
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
for name, entry in m.get('repos', {}).items():
    if entry.get('archived'):
        continue
    if not entry.get('dev-publish-enabled'):
        continue
    org = entry.get('org', 'greenticai')
    print(f'{org}/{name}')
"
}

ok=0
already=0
unprotected=0
would=0
failed=0
failed_repos=()

while IFS= read -r full; do
  [[ -z "$full" ]] && continue

  # One read decides everything. An unreachable branch, an unprotected one, or
  # protection without a `restrictions` block all mean the App can already
  # merge — only a present allowlist needs the grant. `has_restrictions` keeps
  # "no allowlist" distinct from "allowlist that happens to hold no apps".
  protection=$(gh api "repos/$full/branches/$BRANCH/protection" 2>/dev/null)
  if [[ -z "$protection" ]]; then
    echo "  · $full — no protection on $BRANCH, App can already merge"
    ((unprotected++)) || true
    continue
  fi

  has_restrictions=$(jq -r 'if .restrictions then "yes" else "no" end' <<<"$protection")
  if [[ "$has_restrictions" != "yes" ]]; then
    echo "  · $full — no push restrictions on $BRANCH, App can already merge"
    ((unprotected++)) || true
    continue
  fi

  restrictions=$(jq -r '[.restrictions.apps[].slug] | join(" ")' <<<"$protection")

  # Whole-line match, not -w: a hyphen is not a word constituent, so `-w` would
  # accept "greentic-ci" inside a differently-named "greentic-ci-staging".
  if grep -qxF "$APP_SLUG" <<<"${restrictions// /$'\n'}"; then
    echo "  ✓ $full — $APP_SLUG already allowed"
    ((already++)) || true
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "  ~ $full — would add $APP_SLUG (apps now: ${restrictions:-none})"
    ((would++)) || true
    continue
  fi

  # POST appends to the app allowlist; PUT would replace it. Append, so a repo
  # that already trusts some other App keeps it.
  if gh api -X POST "repos/$full/branches/$BRANCH/protection/restrictions/apps" \
       -f "apps[]=$APP_SLUG" --silent 2>/dev/null; then
    echo "  + $full — added $APP_SLUG (apps were: ${restrictions:-none})"
    ((ok++)) || true
  else
    echo "  ✗ $full — POST failed (App installed on this repo?)"
    failed_repos+=("$full")
    ((failed++)) || true
  fi
done < <(list_targets)

echo ""
echo "━━━ Summary ━━━"
echo "  Granted:            $ok"
[[ "$DRY_RUN" == true ]] && \
  echo "  Would grant:        $would"
echo "  Already allowed:    $already"
echo "  No restrictions:    $unprotected"
echo "  Failed:             $failed"
if [[ ${#failed_repos[@]} -gt 0 ]]; then
  echo ""
  echo "  Failed repos:"
  for r in "${failed_repos[@]}"; do echo "    - $r"; done
fi

[[ "$failed" -eq 0 ]]
