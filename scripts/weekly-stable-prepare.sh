#!/usr/bin/env bash
# weekly-stable-prepare.sh — Create release PRs for weekly stable publishing
#
# For each repo with weekly-stable-enabled=true in REPO_MANIFEST.toml:
# 1. Check if main has changes since the last stable release tag
# 2. Determine next patch version (increment current patch)
# 3. Create a release branch, bump version in Cargo.toml, commit, push
# 4. Create a PR targeting main with the 'release' label
#
# The PR goes through normal CI (build, test, clippy, semver-checks).
# Once merged, weekly-stable-publish.yml picks it up and publishes to crates.io.
#
# Environment:
#   GH_TOKEN      — GitHub PAT/App token with repo scope across the orgs
#   INPUT_REPO    — (optional) Process a single repo by name
#   INPUT_TIER    — (optional) Process a specific tier only
#   INPUT_DRY_RUN — (optional) "true" to preview without creating branches/PRs
#
# Prerequisites:
#   - GH_NIGHTLY_TOKEN org secret: PAT or GitHub App with repo scope
#     on all repos. GITHUB_TOKEN cannot create cross-repo PRs.

set -euo pipefail

MANIFEST="toolchain/REPO_MANIFEST.toml"
RELEASE_LABEL="release"

DRY_RUN="${INPUT_DRY_RUN:-false}"
REPO_FILTER="${INPUT_REPO:-}"
TIER_FILTER="${INPUT_TIER:-}"

# Counters
prepared=0
skipped_no_changes=0
skipped_existing_pr=0
failed=0

# ── Helpers ──────────────────────────────────────────────────────

log()  { echo "$1"; }
err()  { echo "::error::$1"; }
warn() { echo "::warning::$1"; }

# ── Parse manifest ───────────────────────────────────────────────
# Output: tab-separated "tier\torg\tname\tcrates\tauto_merge" lines.
# Only repos with weekly-stable-enabled=true, non-empty publishes, not archived.
get_repos() {
  python3 -c "
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
entries = []
for name, entry in m.get('repos', {}).items():
    if entry.get('archived', False):
        continue
    if not entry.get('weekly-stable-enabled', False):
        continue
    if not entry.get('publishes', []):
        continue
    tier = entry.get('tier', 99)
    crates = ' '.join(entry['publishes'])
    auto_merge = 'true' if entry.get('weekly-stable-auto-merge', False) else 'false'
    entries.append((tier, entry['org'], name, crates, auto_merge))
entries.sort()
for tier, org, name, crates, auto_merge in entries:
    print(f'{tier}\t{org}\t{name}\t{crates}\t{auto_merge}')
"
}

# ── Tag detection ────────────────────────────────────────────────
# Returns the latest stable release tag (v*.*.* without pre-release suffix).
# Handles repos with no tags (returns empty string).
get_last_stable_tag() {
  local repo="$1"  # org/name format

  # Fetch tags, filter to stable v*.*.* only, sort by version, take latest.
  # Exclude pre-release tags like v0.4.56-dev.141.
  gh api "repos/$repo/tags" --paginate --jq '.[].name' 2>/dev/null \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -1 \
    || true
}

# ── Version reading ──────────────────────────────────────────────
# Reads workspace.package.version or package.version from Cargo.toml on main.
get_current_version() {
  local repo="$1"

  gh api "repos/$repo/contents/Cargo.toml" --jq '.content' 2>/dev/null \
    | base64 -d \
    | python3 -c "
import sys, tomllib
data = tomllib.load(sys.stdin.buffer)
ws = data.get('workspace', {}).get('package', {})
pkg = data.get('package', {})
ver = ws.get('version') or pkg.get('version')
if ver:
    print(ver)
else:
    sys.exit(1)
"
}

# ── Patch bump ───────────────────────────────────────────────────
# 0.4.58 → 0.4.59
bump_patch() {
  local ver="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$ver"
  echo "$major.$minor.$((patch + 1))"
}

# ── Change detection ─────────────────────────────────────────────
# Returns the number of commits on main since a tag (or empty if error).
commits_since_tag() {
  local repo="$1"
  local tag="$2"

  gh api "repos/$repo/compare/$tag...main" --jq '.total_commits' 2>/dev/null || echo ""
}

# ── Existing PR check ───────────────────────────────────────────
has_open_release_pr() {
  local repo="$1"
  local count
  count=$(gh pr list --repo "$repo" --base main --label "$RELEASE_LABEL" \
    --state open --json number --jq 'length' 2>/dev/null) || count=0
  [[ "$count" -gt 0 ]]
}

# ── Ensure release label exists ──────────────────────────────────
ensure_release_label() {
  local repo="$1"
  if ! gh label list --repo "$repo" --json name --jq '.[].name' 2>/dev/null | grep -qx "$RELEASE_LABEL"; then
    gh label create "$RELEASE_LABEL" --repo "$repo" \
      --description "Automated weekly stable release" \
      --color "0E8A16" 2>/dev/null || true
  fi
}

# ── Create release PR for one repo ───────────────────────────────
prepare_release() {
  local repo="$1"     # org/name
  local name="$2"     # short name
  local crates="$3"   # space-separated crate list
  local tier="$4"
  local auto_merge="$5"

  # 1. Check for existing open release PR
  if has_open_release_pr "$repo"; then
    log "  ⊘ $name — open release PR exists, skipping"
    ((skipped_existing_pr++)) || true
    return 0
  fi

  # 2. Read current version from main
  local current_ver
  current_ver=$(get_current_version "$repo") || {
    err "$name — could not read version from Cargo.toml"
    ((failed++)) || true
    return 1
  }

  # 3. Find latest stable release tag
  local last_tag
  last_tag=$(get_last_stable_tag "$repo")

  # 4. Change detection
  if [[ -n "$last_tag" ]]; then
    local commit_count
    commit_count=$(commits_since_tag "$repo" "$last_tag")

    if [[ "$commit_count" == "0" ]]; then
      log "  ⊘ $name — no changes since $last_tag"
      ((skipped_no_changes++)) || true
      return 0
    fi
    log "  Δ $name — $commit_count commit(s) since $last_tag"
  else
    log "  Δ $name — no previous stable tag (first release)"
  fi

  # 5. Compute next version
  local next_ver
  next_ver=$(bump_patch "$current_ver")
  local release_branch="release/v$next_ver"

  # ── Dry run stops here ──
  if [[ "$DRY_RUN" == "true" ]]; then
    log "  [dry-run] $name — would create PR: v$current_ver → v$next_ver (crates: $crates)"
    ((prepared++)) || true
    return 0
  fi

  # 6. Create release branch from main HEAD
  local main_sha
  main_sha=$(gh api "repos/$repo/git/ref/heads/main" --jq '.object.sha' 2>/dev/null) || {
    err "$name — could not get main HEAD SHA"
    ((failed++)) || true
    return 1
  }

  # Create branch via API (idempotent — reuse if exists from partial run)
  if ! gh api "repos/$repo/git/refs" -X POST \
      -f "ref=refs/heads/$release_branch" \
      -f "sha=$main_sha" --silent 2>/dev/null; then
    warn "$name — branch $release_branch already exists, reusing"
  fi

  # 7. Clone the release branch, bump version, commit, push
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  if ! git clone --depth 1 --branch "$release_branch" \
      "https://x-access-token:${GH_TOKEN}@github.com/$repo.git" \
      "$tmpdir" 2>/dev/null; then
    err "$name — failed to clone $release_branch"
    ((failed++)) || true
    return 1
  fi

  # Bump version in all Cargo.toml files (workspace + member crates)
  local bumped=0
  while IFS= read -r -d '' cargo_file; do
    if grep -q "version = \"$current_ver\"" "$cargo_file"; then
      sed -i "s/version = \"$current_ver\"/version = \"$next_ver\"/g" "$cargo_file"
      ((bumped++)) || true
    fi
  done < <(find "$tmpdir" -name Cargo.toml -not -path '*/target/*' -print0)

  if [[ "$bumped" -eq 0 ]]; then
    warn "$name — no Cargo.toml files contained version $current_ver"
    ((failed++)) || true
    return 1
  fi

  # Commit and push
  (
    cd "$tmpdir"
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git add -A

    if git diff --cached --quiet; then
      echo "::warning::$name — no changes after version bump (already bumped?)"
      exit 1
    fi

    git commit -m "chore: release v$next_ver"
    git push origin "$release_branch"
  ) || {
    err "$name — commit/push failed"
    ((failed++)) || true
    return 1
  }

  # 8. Generate changelog
  local changelog=""
  if [[ -n "$last_tag" ]]; then
    changelog=$(gh api "repos/$repo/compare/$last_tag...main" \
      --jq '[.commits[] | "- " + (.commit.message | split("\n")[0]) + " (\(.sha[0:7]))"] | join("\n")' \
      2>/dev/null) || changelog="_(could not generate changelog)_"
  else
    changelog="_(first release — no previous tag)_"
  fi

  # 9. Ensure the 'release' label exists
  ensure_release_label "$repo"

  # 10. Create PR
  local crate_list
  crate_list=$(echo "$crates" | tr ' ' '\n' | sed 's/^/- `/' | sed 's/$/`/')

  local pr_body
  pr_body=$(cat <<BODY
## Release v$next_ver

**Version:** \`$current_ver\` → \`$next_ver\`
**Tier:** $tier
**Crates:** $(echo "$crates" | wc -w | tr -d ' ')

### Crates to publish
$crate_list

### Changes since ${last_tag:-"(initial)"}
$changelog

---
_Automated by [weekly-stable-prepare](https://github.com/greenticai/.github/actions/workflows/weekly-stable-prepare.yml). Merge this PR to trigger publishing to crates.io._
BODY
)

  local pr_url
  pr_url=$(gh pr create --repo "$repo" --base main --head "$release_branch" \
    --title "release: v$next_ver" \
    --label "$RELEASE_LABEL" \
    --body "$pr_body" 2>&1) || {
    err "$name — PR creation failed: $pr_url"
    ((failed++)) || true
    return 1
  }

  log "  ✓ $name — $pr_url (v$current_ver → v$next_ver)"

  # 11. Enable auto-merge if configured
  if [[ "$auto_merge" == "true" ]]; then
    if gh pr merge --repo "$repo" --auto --squash "$pr_url" 2>/dev/null; then
      log "    ↳ auto-merge enabled"
    else
      warn "$name — could not enable auto-merge (may need branch protection 'allow auto-merge')"
    fi
  fi

  ((prepared++)) || true
}

# ── Main ─────────────────────────────────────────────────────────

log "Weekly Stable Prepare — $(date -u '+%Y-%m-%d %H:%M UTC')"
log "Dry run: $DRY_RUN"
[[ -n "$REPO_FILTER" ]] && log "Repo filter: $REPO_FILTER"
[[ -n "$TIER_FILTER" ]] && log "Tier filter: $TIER_FILTER"
log ""

current_tier=""

while IFS=$'\t' read -r tier org name crates auto_merge; do
  # Apply filters
  [[ -n "$TIER_FILTER" && "$tier" != "$TIER_FILTER" ]] && continue
  [[ -n "$REPO_FILTER" && "$name" != "$REPO_FILTER" ]] && continue

  # Tier header on boundary change
  if [[ "$tier" != "$current_tier" ]]; then
    [[ -n "$current_tier" ]] && log ""
    log "── Tier $tier ──"
    current_tier="$tier"
  fi

  full="$org/$name"
  prepare_release "$full" "$name" "$crates" "$tier" "$auto_merge"

done < <(get_repos)

# ── Summary ──────────────────────────────────────────────────────

log ""
log "━━━ Summary ━━━"
log "  Prepared:              $prepared"
log "  Skipped (no changes):  $skipped_no_changes"
log "  Skipped (existing PR): $skipped_existing_pr"
log "  Failed:                $failed"

# GitHub Actions step summary
cat >> "${GITHUB_STEP_SUMMARY:-/dev/null}" <<EOF
## Weekly Stable Prepare — $(date -u '+%Y-%m-%d')

| Metric | Count |
|--------|-------|
| Release PRs created | $prepared |
| Skipped (no changes) | $skipped_no_changes |
| Skipped (existing PR) | $skipped_existing_pr |
| Failed | $failed |

$(if [[ "$DRY_RUN" == "true" ]]; then echo "**Dry run** — no branches or PRs were created."; fi)
EOF

[[ "$failed" -eq 0 ]]
