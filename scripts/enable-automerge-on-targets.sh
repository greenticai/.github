#!/usr/bin/env bash
# enable-automerge-on-targets.sh — Flip allow_auto_merge + delete_branch_on_merge
# on every dev-publish-enabled repo in REPO_MANIFEST.toml.
#
# Without these settings:
#   - `gh pr merge --auto` errors out, so the nightly cargo-lock-sync bot can't
#     queue PRs to merge once CI passes — they sit open until a human merges.
#   - Bot branches survive after merge, which causes "stale info" rejections on
#     the next nightly's --force-with-lease push when the local clone (cloned
#     with --single-branch=develop) has no remote-tracking ref for the bot
#     branch. (The script-level fetch fix is complementary — it also handles
#     the closed-without-merge edge case.)
#
# Idempotent. Safe to re-run. Skips archived repos.
#
# Usage:
#   bash scripts/enable-automerge-on-targets.sh             # apply
#   bash scripts/enable-automerge-on-targets.sh --dry-run   # preview only
#
# Requires: gh CLI authenticated with repo-admin scope on both orgs.

set -uo pipefail

MANIFEST="toolchain/REPO_MANIFEST.toml"
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
failed=0
failed_repos=()

while IFS= read -r full; do
  [[ -z "$full" ]] && continue

  current=$(gh api "repos/$full" --jq '[.allow_auto_merge,.delete_branch_on_merge] | @tsv' 2>/dev/null || echo "")
  if [[ -z "$current" ]]; then
    echo "  ✗ $full — unreachable (token scope?)"
    failed_repos+=("$full")
    ((failed++)) || true
    continue
  fi

  am="${current%$'\t'*}"
  db="${current#*$'\t'}"
  if [[ "$am" == "true" && "$db" == "true" ]]; then
    echo "  ✓ $full — already set"
    ((already++)) || true
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "  ~ $full — would patch (am=$am db=$db → true,true)"
    continue
  fi

  if gh api -X PATCH "repos/$full" \
      -f allow_auto_merge=true -f delete_branch_on_merge=true --silent 2>/dev/null; then
    echo "  + $full — patched (was am=$am db=$db)"
    ((ok++)) || true
  else
    echo "  ✗ $full — PATCH failed"
    failed_repos+=("$full")
    ((failed++)) || true
  fi
done < <(list_targets)

echo ""
echo "━━━ Summary ━━━"
echo "  Patched:        $ok"
echo "  Already set:    $already"
echo "  Failed:         $failed"
if [[ ${#failed_repos[@]} -gt 0 ]]; then
  echo ""
  echo "  Failed repos:"
  for r in "${failed_repos[@]}"; do echo "    - $r"; done
fi

[[ "$failed" -eq 0 ]]
