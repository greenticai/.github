#!/usr/bin/env bash
# nightly-cargo-lock-sync.sh — Refresh Cargo.lock on each repo's develop branch.
#
# Runs after the tier-ordered dev-publish finishes. For every dev-publish-enabled
# manifest repo that has a develop branch and a Cargo.lock at its root:
#
#   1. Shallow-clone develop.
#   2. `cargo update` scoped to Greentic-owned crates from the manifest that
#      (a) appear in the repo's lock and (b) are not workspace members.
#      Dev versions ({M.m.RUN_ID}) published earlier in this run resolve from
#      crates.io with no custom registry setup.
#   3. If Cargo.lock changed: force-push to a long-lived bot branch
#      (`chore/nightly-cargo-update`), create a PR if none exists, and enable
#      auto-merge.
#   4. If auto-merge cannot be enabled (conflict / failing CI): leave PR open
#      for manual resolution.
#
# Env expected from the calling workflow:
#   GH_TOKEN_GREENTICAI    — App token scoped to greenticai org installation
#   GH_TOKEN_GREENTIC_BIZ  — App token scoped to greentic-biz org installation
#   GH_TOKEN               — Fallback when per-org tokens aren't set (e.g. local runs)

set -uo pipefail

MANIFEST="toolchain/REPO_MANIFEST.toml"
BRANCH="chore/nightly-cargo-update"
WORK_DIR="$(mktemp -d -t cargo-lock-sync-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

log()  { echo "$1"; }
err()  { echo "::error::$1"; }
warn() { echo "::warning::$1"; }

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

# Reachability precheck. Catches token-scope or App-installation gaps so we
# fail loud instead of misclassifying a whole org as "Repository not found"
# (which is what GitHub returns to unauthorized tokens on private repos).
repo_reachable() {
  local repo="$1"
  gh api "repos/$repo" --silent 2>/dev/null
}

# ── Collect all Greentic-owned crate names from the manifest
collect_greentic_crates() {
  python3 -c "
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
names = set()
for entry in m.get('repos', {}).values():
    if entry.get('archived'):
        continue
    for c in entry.get('publishes', []):
        names.add(c)
print('\n'.join(sorted(names)))
"
}

# ── Enumerate target repos
list_target_repos() {
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

# ── Process one repo. Sets out_status and out_pr_url.
out_status=""
out_pr_url=""

process_repo() {
  local full="$1"       # org/name
  local org="${full%%/*}"
  local name="${full##*/}"
  out_status=""
  out_pr_url=""

  # Select the per-org App token. Both `gh` and the clone/push URLs below
  # pick this up via $GH_TOKEN, so set it for the duration of this call.
  local GH_TOKEN
  GH_TOKEN="$(token_for_org "$org")" || { out_status="failed"; return 0; }
  if [[ -z "$GH_TOKEN" ]]; then
    err "[$name] no token available for org '$org'"
    out_status="failed"
    return 0
  fi
  export GH_TOKEN

  # Reachability — fail loud on auth/scope errors so we never silently
  # mis-skip a whole org's repos as "Repository not found" again.
  if ! repo_reachable "$full"; then
    err "[$name] repo unreachable (token scope or App not installed in '$org'?)"
    out_status="failed"
    return 0
  fi

  local dir="$WORK_DIR/$name"
  local auth_url="https://x-access-token:${GH_TOKEN}@github.com/${full}.git"

  # Clone develop
  if ! git clone --branch develop --depth 1 --single-branch \
        "$auth_url" "$dir" 2>"$WORK_DIR/${name}.clone.err"; then
    if grep -qE "Remote branch develop not found|couldn't find remote ref" \
         "$WORK_DIR/${name}.clone.err"; then
      out_status="skipped"
      return 0
    fi
    err "[$name] clone failed"
    sed 's/^/    /' "$WORK_DIR/${name}.clone.err" >&2
    out_status="failed"
    return 0
  fi

  if [[ ! -f "$dir/Cargo.lock" ]]; then
    out_status="skipped"
    return 0
  fi

  # Which (name, version) pairs appear in this lock? One per line as "name<TAB>version".
  # We disambiguate by version because the lock can briefly carry multiple versions
  # of the same Greentic crate during forward-port windows (e.g. old stable 0.5.2
  # pulled in transitively + freshly-published 1.1.0-dev.{RUN_ID}). Bare `-p name`
  # would error: `specification \`<name>\` is ambiguous`.
  local lock_pkgs
  lock_pkgs=$(python3 -c "
import tomllib, pathlib
data = tomllib.loads(pathlib.Path('$dir/Cargo.lock').read_text())
for p in data.get('package', []):
    print(p['name'] + '\t' + p['version'])
" 2>/dev/null || true)

  # Which crates are workspace members? (cargo update rejects those with -p)
  local workspace_members
  workspace_members=$( (cd "$dir" && cargo metadata --no-deps --format-version 1 2>"$WORK_DIR/${name}.meta.err") \
    | python3 -c "
import json, sys
try:
    print('\n'.join(p['name'] for p in json.load(sys.stdin)['packages']))
except Exception:
    pass
" 2>/dev/null || true )

  # Build -p filter as `name@version` for every version of each Greentic crate
  # present in the lock (skipping workspace members).
  local pkg_args=()
  while IFS= read -r crate; do
    [[ -z "$crate" ]] && continue
    grep -qxF "$crate" <<<"$workspace_members" && continue
    while IFS=$'\t' read -r pkg_name pkg_version; do
      [[ "$pkg_name" == "$crate" ]] || continue
      [[ -z "$pkg_version" ]] && continue
      pkg_args+=(-p "${crate}@${pkg_version}")
    done <<<"$lock_pkgs"
  done <<<"$GREENTIC_CRATES"

  if [[ ${#pkg_args[@]} -eq 0 ]]; then
    out_status="skipped"
    return 0
  fi

  local before_hash
  before_hash=$(sha256sum "$dir/Cargo.lock" | awk '{print $1}')

  if ! ( cd "$dir" && cargo update "${pkg_args[@]}" ) 2>"$WORK_DIR/${name}.update.err"; then
    err "[$name] cargo update failed"
    sed 's/^/    /' "$WORK_DIR/${name}.update.err" >&2
    out_status="failed"
    return 0
  fi

  local after_hash
  after_hash=$(sha256sum "$dir/Cargo.lock" | awk '{print $1}')

  if [[ "$before_hash" == "$after_hash" ]]; then
    out_status="nochange"
    return 0
  fi

  # Save the updated lock; restore clean tree; drop ephemeral .cargo/
  cp "$dir/Cargo.lock" "$WORK_DIR/${name}.updated.lock"
  ( cd "$dir" && git checkout -- Cargo.lock 2>/dev/null ) || true
  rm -rf "$dir/.cargo"

  # Create/reset bot branch from develop head and apply the lock change
  (
    cd "$dir"
    git config user.name  "greentic-ci[bot]"
    git config user.email "3383573+greentic-ci[bot]@users.noreply.github.com"
    git checkout -B "$BRANCH" origin/develop --quiet
    cp "$WORK_DIR/${name}.updated.lock" Cargo.lock
    git add Cargo.lock
    git commit --quiet -m "chore(nightly): cargo update — $(date -u +%Y-%m-%d)"
  )

  # Force-with-lease push (safe against a race where a human touched the branch)
  if ! ( cd "$dir" && git push --force-with-lease "$auth_url" "$BRANCH" --quiet ) \
       2>"$WORK_DIR/${name}.push.err"; then
    err "[$name] push failed"
    sed 's/^/    /' "$WORK_DIR/${name}.push.err" >&2
    out_status="failed"
    return 0
  fi

  # Find or create the PR
  local existing
  existing=$(gh pr list --repo "$full" --head "$BRANCH" --state open \
              --json number --jq '.[0].number // empty' 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    out_pr_url="https://github.com/${full}/pull/${existing}"
  else
    local body
    body=$(cat <<EOF
Automated nightly \`cargo update\` — refreshes \`Cargo.lock\` with the latest
Greentic crate versions published to CodeArtifact earlier in this run.

If auto-merge is queued, this PR will merge once CI passes. If it sits
unmerged, a conflict or failing CI is waiting for manual attention.

Branch is long-lived — subsequent nightlies force-push to it.

— generated by \`.github/scripts/nightly-cargo-lock-sync.sh\`
EOF
)
    local create_out
    create_out=$(gh pr create --repo "$full" \
      --base develop --head "$BRANCH" \
      --title "chore(nightly): cargo update (bot)" \
      --body "$body" 2>&1 | tail -1)
    if [[ "$create_out" != https://* ]]; then
      err "[$name] PR create failed: $create_out"
      out_status="failed"
      return 0
    fi
    out_pr_url="$create_out"
  fi

  # Try auto-merge first; fall back to direct merge (UNSTABLE-but-mergeable
  # case). If neither works, leave PR open for manual resolution.
  if gh pr merge --repo "$full" "$out_pr_url" --auto --squash 2>/dev/null; then
    out_status="updated"
  elif gh pr merge --repo "$full" "$out_pr_url" --squash 2>/dev/null; then
    out_status="merged"
  else
    out_status="conflict"
  fi
  return 0
}

# ── Pre-compute shared state
GREENTIC_CRATES="$(collect_greentic_crates)"
if [[ -z "$GREENTIC_CRATES" ]]; then
  err "No Greentic crates found in manifest"
  exit 1
fi
crate_count=$(echo "$GREENTIC_CRATES" | wc -l)
log "Greentic crates in scope: $crate_count"

c_updated=0
c_merged=0
c_conflict=0
c_nochange=0
c_skipped=0
c_failed=0
conflict_urls=()
updated_urls=()
failed_repos=()

log ""
log "━━━ Cargo.lock sync ━━━"

while IFS= read -r full; do
  [[ -z "$full" ]] && continue
  name="${full##*/}"
  echo "::group::$name"
  process_repo "$full"
  case "$out_status" in
    updated)  ((c_updated++))  || true; updated_urls+=("$name: $out_pr_url") ;;
    merged)   ((c_merged++))   || true ;;
    conflict) ((c_conflict++)) || true; conflict_urls+=("$name: $out_pr_url") ;;
    nochange) ((c_nochange++)) || true ;;
    skipped)  ((c_skipped++))  || true ;;
    failed)   ((c_failed++))   || true; failed_repos+=("$name") ;;
    *)        ((c_failed++))   || true; failed_repos+=("$name (unknown status: $out_status)") ;;
  esac
  log "  → $name: $out_status${out_pr_url:+ — $out_pr_url}"
  echo "::endgroup::"
done < <(list_target_repos)

# ── Summary ──────────────────────────────────────────────────────
log ""
log "━━━ Summary ━━━"
log "  Updated (auto-merge queued): $c_updated"
log "  Merged immediately:          $c_merged"
log "  Conflict (open PR):          $c_conflict"
log "  No change:                   $c_nochange"
log "  Skipped:                     $c_skipped"
log "  Failed:                      $c_failed"

{
  echo ""
  echo "## Cargo.lock sync — $(date -u '+%Y-%m-%d')"
  echo ""
  echo "| Status | Count |"
  echo "|--------|-------|"
  echo "| Updated (PR queued) | $c_updated |"
  echo "| Merged immediately | $c_merged |"
  echo "| Conflict (open PR) | $c_conflict |"
  echo "| No change | $c_nochange |"
  echo "| Skipped | $c_skipped |"
  echo "| Failed | $c_failed |"

  if [[ ${#conflict_urls[@]} -gt 0 ]]; then
    echo ""
    echo "### Conflicts awaiting manual resolution"
    for u in "${conflict_urls[@]}"; do echo "- $u"; done
  fi
  if [[ ${#updated_urls[@]} -gt 0 ]]; then
    echo ""
    echo "### PRs with auto-merge queued"
    for u in "${updated_urls[@]}"; do echo "- $u"; done
  fi
  if [[ ${#failed_repos[@]} -gt 0 ]]; then
    echo ""
    echo "### Failed"
    for r in "${failed_repos[@]}"; do echo "- $r"; done
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

# Extension line for the Slack summary
summary_parts=()
[[ "$c_updated"  -gt 0 ]] && summary_parts+=("$c_updated lock-PR(s) queued")
[[ "$c_merged"   -gt 0 ]] && summary_parts+=("$c_merged lock-PR(s) merged")
[[ "$c_conflict" -gt 0 ]] && summary_parts+=("$c_conflict conflict(s) open")
[[ "$c_failed"   -gt 0 ]] && summary_parts+=("$c_failed failed")
joined=""
if [[ ${#summary_parts[@]} -gt 0 ]]; then
  joined="$(IFS=', '; echo "${summary_parts[*]}")"
fi
echo "cargo_lock_summary=${joined}" >> "${GITHUB_OUTPUT:-/dev/null}"

# Fail the job only on hard errors — not on conflict PRs (those are expected
# and handled via manual resolution).
[[ "$c_failed" -eq 0 ]]
