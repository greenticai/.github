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
# Once merged, tag-on-version-bump.yml creates the v{version} tag, which in
# turn triggers crates-publish.yml in each repo to publish to crates.io.
#
# Environment:
#   GH_TOKEN_GREENTICAI    — App token scoped to greenticai org installation
#   GH_TOKEN_GREENTIC_BIZ  — App token scoped to greentic-biz org installation
#   GH_TOKEN               — Fallback when per-org tokens aren't set (e.g. local runs)
#   INPUT_REPO             — (optional) Process a single repo by name
#   INPUT_TIER             — (optional) Process a specific tier only
#   INPUT_DRY_RUN          — (optional) "true" to preview without creating branches/PRs

set -euo pipefail

MANIFEST="toolchain/REPO_MANIFEST.toml"
RELEASE_LABEL="release"

DRY_RUN="${INPUT_DRY_RUN:-false}"
REPO_FILTER="${INPUT_REPO:-}"
TIER_FILTER="${INPUT_TIER:-}"

# Per-org tokens, with single-token fallback for local invocation.
GH_TOKEN_GREENTICAI="${GH_TOKEN_GREENTICAI:-${GH_TOKEN:-}}"
GH_TOKEN_GREENTIC_BIZ="${GH_TOKEN_GREENTIC_BIZ:-${GH_TOKEN:-}}"

# Counters
prepared=0
skipped_no_changes=0
skipped_existing_pr=0
failed=0
prepared_details=""

# ── Helpers ──────────────────────────────────────────────────────

log()  { echo "$1"; }
err()  { echo "::error::$1"; }
warn() { echo "::warning::$1"; }

token_for_org() {
  case "$1" in
    greenticai)   echo "$GH_TOKEN_GREENTICAI" ;;
    greentic-biz) echo "$GH_TOKEN_GREENTIC_BIZ" ;;
    *)            echo "::error::Unknown org '$1' — no token available" >&2; return 1 ;;
  esac
}

# Reachability precheck. Catches token-scope or App-installation gaps so we
# fail loud instead of misclassifying private repos as "Repository not found".
repo_reachable() {
  local repo="$1"
  gh api "repos/$repo" --silent 2>/dev/null
}

# ── Parse manifest ───────────────────────────────────────────────
# Output: tab-separated "tier\torg\tname\tcrates\tauto_merge" lines.
# Only repos with weekly-stable-enabled=true, not archived.
# Repos with empty publishes are included (tag-only flow).
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
    tier = entry.get('tier', 99)
    crates = ' '.join(entry.get('publishes', []))
    auto_merge = 'true' if entry.get('weekly-stable-auto-merge', False) else 'false'
    entries.append((tier, entry['org'], name, crates, auto_merge))
entries.sort()
for tier, org, name, crates, auto_merge in entries:
    print(f'{tier}\t{org}\t{name}\t{crates}\t{auto_merge}')
"
}

# ── Tag detection ────────────────────────────────────────────────
# Returns the latest stable release tag (v*.*.* without pre-release suffix)
# that is REACHABLE from main. Tags on abandoned side-branches must be
# skipped — they can carry higher version numbers than main but are not
# ancestors of it, so comparing against them produces a nonsense changelog
# and a mis-computed next version.
#
# Reachability check uses the compare API's status field:
#   "ahead"     → main is strictly ahead of tag (tag is an ancestor)
#   "identical" → main is at the tag
#   "behind" / "diverged" → tag is NOT an ancestor of main → skip
#
# Returns empty string if the repo has no tags or no reachable stable tag.
get_last_stable_tag() {
  local repo="$1"  # org/name format
  local tag status

  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    status=$(gh api "repos/$repo/compare/$tag...main" --jq '.status' 2>/dev/null || echo "")
    if [[ "$status" == "ahead" || "$status" == "identical" ]]; then
      echo "$tag"
      return 0
    fi
  done < <(
    gh api "repos/$repo/tags" --paginate --jq '.[].name' 2>/dev/null \
      | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -Vr
  )
}

# ── Version reading ──────────────────────────────────────────────
# Reads workspace.package.version or package.version from Cargo.toml on a
# specific branch (default: main).
get_version_on_branch() {
  local repo="$1"
  local branch="${2:-main}"

  gh api "repos/$repo/contents/Cargo.toml?ref=$branch" --jq '.content' 2>/dev/null \
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

# Backwards-compat wrapper for the patch-bump path.
get_current_version() {
  get_version_on_branch "$1" "main"
}

# ── Patch bump ───────────────────────────────────────────────────
# 0.4.58 → 0.4.59
bump_patch() {
  local ver="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$ver"
  echo "$major.$minor.$((patch + 1))"
}

# ── Pre-release detection + stripping ────────────────────────────
# A pre-release version has -dev/-alpha/-beta/-rc suffix. Presence of the
# suffix on develop is the intent signal from start-next-minor.sh that this
# repo wants to cut a new minor. Weekly-stable-prepare honors that signal by
# branching from develop, stripping the suffix, and opening a release PR to
# main. Consumers at `^X.Y` will not have seen the pre-release on CodeArtifact
# (cargo firewall), so the minor cut is their first exposure to the new line.
is_pre_release_version() {
  [[ "$1" == *-dev.* || "$1" == *-alpha.* || "$1" == *-beta.* || "$1" == *-rc.* ]]
}

# Strip the pre-release suffix: 0.6.0-dev.3 → 0.6.0
strip_pre_release() {
  echo "${1%%-*}"
}

# Compare branches: returns "ahead" | "behind" | "identical" | "diverged".
# "ahead" means the first branch is strictly ahead of the second.
compare_branches() {
  local repo="$1" head="$2" base="$3"
  gh api "repos/$repo/compare/$base...$head" --jq '.status' 2>/dev/null || echo ""
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

  # Select the per-org App token. Both `gh` and any clone/push URLs below
  # pick this up via $GH_TOKEN, so set it for the duration of this call.
  local org="${repo%%/*}"
  local GH_TOKEN
  GH_TOKEN="$(token_for_org "$org")" || { ((failed++)) || true; return 1; }
  if [[ -z "$GH_TOKEN" ]]; then
    err "$name — no token available for org '$org'"
    ((failed++)) || true
    return 1
  fi
  export GH_TOKEN

  # Reachability — fail loud on auth/scope errors so we never silently
  # mis-skip a whole org's repos.
  if ! repo_reachable "$repo"; then
    err "$name — repo unreachable (token scope or App not installed in '$org'?)"
    ((failed++)) || true
    return 1
  fi

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

  # 2b. Read develop's version (if the branch exists) to detect whether the
  # repo is in a pre-release minor-bump cycle. Missing develop → patch path.
  local develop_ver=""
  develop_ver=$(get_version_on_branch "$repo" "develop" 2>/dev/null || echo "")

  # 3. Find latest stable release tag
  local last_tag
  last_tag=$(get_last_stable_tag "$repo")

  # 4. Classify release kind based on develop's version.
  #   - minor cut: develop is on X.Y.Z-dev.N (start-next-minor.sh ran).
  #                Branch from develop, strip suffix → release vX.Y.Z.
  #   - patch cut: develop is stable (or missing). Branch from main, bump patch.
  local release_kind="patch"
  local source_branch="main"
  local source_current_ver="$current_ver"
  local next_ver
  if [[ -n "$develop_ver" ]] && is_pre_release_version "$develop_ver"; then
    release_kind="minor"
    source_branch="develop"
    source_current_ver="$develop_ver"
    next_ver=$(strip_pre_release "$develop_ver")

    # Guard: develop must be a superset of main (forward-port race). If main
    # is ahead or diverged, the minor cut would drop main-only commits.
    local status
    status=$(compare_branches "$repo" "develop" "main")
    case "$status" in
      ahead|identical)
        : # develop has everything main has; safe to branch from develop
        ;;
      behind)
        err "$name — develop is BEHIND main (forward-port needed before minor cut)"
        ((failed++)) || true
        return 1
        ;;
      diverged)
        err "$name — develop has DIVERGED from main (forward-port needed before minor cut)"
        ((failed++)) || true
        return 1
        ;;
      "")
        err "$name — could not compare develop vs main (API error)"
        ((failed++)) || true
        return 1
        ;;
      *)
        err "$name — unexpected compare status '$status'"
        ((failed++)) || true
        return 1
        ;;
    esac
  else
    next_ver=$(bump_patch "$current_ver")
  fi
  local release_branch="release/v$next_ver"

  # 4b. Change detection. For patch cuts: commits on main since last tag.
  # For minor cuts: we unconditionally want to release (the pre-release
  # suffix IS the intent signal), but still log the delta for visibility.
  if [[ -n "$last_tag" ]]; then
    local commit_count
    commit_count=$(commits_since_tag "$repo" "$last_tag")

    if [[ "$release_kind" == "patch" && "$commit_count" == "0" ]]; then
      log "  ⊘ $name — no changes since $last_tag"
      ((skipped_no_changes++)) || true
      return 0
    fi
    log "  Δ $name — $commit_count commit(s) since $last_tag (release kind: $release_kind)"
  else
    log "  Δ $name — no previous stable tag (first release, kind: $release_kind)"
  fi

  # Defense-in-depth: computed next version must be strictly greater than
  # the last reachable stable tag. With the reachability filter above this
  # invariant should already hold, but a manually-reverted Cargo.toml on
  # main would otherwise produce a regressing PR — fail loudly instead.
  if [[ -n "$last_tag" ]]; then
    local last_ver="${last_tag#v}"
    local highest
    highest=$(printf '%s\n%s\n' "$last_ver" "$next_ver" | sort -V | tail -1)
    if [[ "$next_ver" == "$last_ver" || "$highest" != "$next_ver" ]]; then
      err "$name — computed next version v$next_ver is not ahead of last stable v$last_ver (Cargo.toml may be out of sync with tags)"
      ((failed++)) || true
      return 1
    fi
  fi

  # ── Dry run stops here ──
  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ "$release_kind" == "minor" ]]; then
      log "  [dry-run] $name — would create MINOR cut PR: from develop ($develop_ver → $next_ver), crates: $crates"
    else
      log "  [dry-run] $name — would create patch PR: v$current_ver → v$next_ver (crates: $crates)"
    fi
    ((prepared++)) || true
    return 0
  fi

  # 6. Create release branch from source_branch HEAD
  local source_sha
  source_sha=$(gh api "repos/$repo/git/ref/heads/$source_branch" --jq '.object.sha' 2>/dev/null) || {
    err "$name — could not get $source_branch HEAD SHA"
    ((failed++)) || true
    return 1
  }
  local main_sha="$source_sha"

  # Create branch via API. Idempotent: if the ref already exists from a
  # partial run we reuse it. But we must NOT blindly treat every failure
  # as "already exists" — e.g. a directory/file ref collision (a bare
  # `release` branch shadowing `release/vX.Y.Z`) also fails creation, and
  # swallowing that error misreports the cause and then dies later at
  # `git clone` with a generic "failed to clone" message.
  local create_out
  if ! create_out=$(gh api "repos/$repo/git/refs" -X POST \
      -f "ref=refs/heads/$release_branch" \
      -f "sha=$main_sha" 2>&1); then
    if gh api "repos/$repo/git/ref/heads/$release_branch" >/dev/null 2>&1; then
      warn "$name — branch $release_branch already exists, reusing"
    else
      err "$name — failed to create branch $release_branch: $create_out"
      ((failed++)) || true
      return 1
    fi
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

  # Bump version in all Cargo.toml files (workspace + member crates).
  # For minor cut: source Cargo.toml has $develop_ver; rewrite to $next_ver.
  # For patch cut: source Cargo.toml has $current_ver (= main's version).
  local bumped=0
  while IFS= read -r -d '' cargo_file; do
    if grep -q "version = \"$source_current_ver\"" "$cargo_file"; then
      sed -i "s/version = \"$source_current_ver\"/version = \"$next_ver\"/g" "$cargo_file"
      ((bumped++)) || true
    fi
  done < <(find "$tmpdir" -name Cargo.toml -not -path '*/target/*' -print0)

  if [[ "$bumped" -eq 0 ]]; then
    warn "$name — no Cargo.toml files contained version $source_current_ver"
    ((failed++)) || true
    return 1
  fi

  # For minor cut: also rewrite greentic-ecosystem dep reqs back to a stable
  # range form (">=X.Y.0-0, <X.(Y+1).0-0"). Develop's Cargo.toml carries the
  # pre-release range (">=X.Y.0-dev, <X.(Y+1).0-0") to resolve pre-release
  # artifacts from CodeArtifact; main must not carry that form because it
  # would (a) prefer pre-releases over stable and (b) fail `cargo publish`
  # validation against crates.io (no pre-release version of the ecosystem
  # crate exists there). Delegate the rewrite to bump_cargo_versions.py,
  # which is structure-aware.
  if [[ "$release_kind" == "minor" ]]; then
    local cut_major cut_minor _cut_patch
    IFS='.' read -r cut_major cut_minor _cut_patch <<< "$next_ver"
    local from_mm="$cut_major.$cut_minor"
    # Re-run with --from <X.Y> --to <X.Y> --deps-only to rewrite any
    # pre-release dep ranges to stable range form. bump_cargo_versions.py
    # will match both ">=X.Y.0-0" and ">=X.Y.0-dev" as the lower bound.
    python3 "$(dirname "$0")/bump_cargo_versions.py" \
      --from "$from_mm" --to "$from_mm" --deps-only \
      "$tmpdir" 2>&1 | sed 's/^/      /' || true
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

  # 8. Generate changelog. Compare against the source branch ("develop" for
  # minor cut, "main" for patch cut) so the changelog covers everything the
  # PR brings in.
  local changelog=""
  if [[ -n "$last_tag" ]]; then
    changelog=$(gh api "repos/$repo/compare/$last_tag...$source_branch" \
      --jq '[.commits[] | "- " + (.commit.message | split("\n")[0]) + " (\(.sha[0:7]))"] | join("\n")' \
      2>/dev/null) || changelog="_(could not generate changelog)_"
  else
    changelog="_(first release — no previous tag)_"
  fi

  # 9. Ensure the 'release' label exists
  ensure_release_label "$repo"

  # 10. Create PR
  local kind_line=""
  local from_ver_display="$current_ver"
  if [[ "$release_kind" == "minor" ]]; then
    kind_line="**Release kind:** minor cut (from develop@\`$develop_ver\`, suffix stripped)"
    from_ver_display="$develop_ver"
  fi

  local pr_body
  if [[ -n "$crates" ]]; then
    local crate_list
    crate_list=$(echo "$crates" | tr ' ' '\n' | sed 's/^/- `/' | sed 's/$/`/')

    pr_body=$(cat <<BODY
## Release v$next_ver

**Version:** \`$from_ver_display\` → \`$next_ver\`
**Tier:** $tier
**Crates:** $(echo "$crates" | wc -w | tr -d ' ')
$kind_line

### Crates to publish
$crate_list

### Changes since ${last_tag:-"(initial)"}
$changelog

---
_Automated by [weekly-stable-prepare](https://github.com/greenticai/.github/actions/workflows/weekly-stable-prepare.yml). Merging creates tag \`v$next_ver\` → triggers crates.io publish._
BODY
)
  else
    pr_body=$(cat <<BODY
## Release v$next_ver

**Version:** \`$from_ver_display\` → \`$next_ver\`
**Tier:** $tier
**Type:** Tag only (no crates.io publish)
$kind_line

### Changes since ${last_tag:-"(initial)"}
$changelog

---
_Automated by [weekly-stable-prepare](https://github.com/greenticai/.github/actions/workflows/weekly-stable-prepare.yml). Merging creates tag \`v$next_ver\`._
BODY
)
  fi

  local pr_title="release: v$next_ver"
  [[ "$release_kind" == "minor" ]] && pr_title="release: v$next_ver (minor cut)"

  local pr_url
  pr_url=$(gh pr create --repo "$repo" --base main --head "$release_branch" \
    --title "$pr_title" \
    --label "$RELEASE_LABEL" \
    --body "$pr_body" 2>&1) || {
    err "$name — PR creation failed: $pr_url"
    ((failed++)) || true
    return 1
  }

  log "  ✓ $name — $pr_url ($from_ver_display → v$next_ver, $release_kind)"

  # 11. Enable auto-merge if configured
  if [[ "$auto_merge" == "true" ]]; then
    if gh pr merge --repo "$repo" --auto --squash "$pr_url" 2>/dev/null; then
      log "    ↳ auto-merge enabled"
    else
      warn "$name — could not enable auto-merge (may need branch protection 'allow auto-merge')"
    fi
  fi

  prepared_details="${prepared_details:+$prepared_details, }$name v$next_ver"
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

# Output summary for downstream notification
if [[ "$prepared" -gt 0 ]]; then
  echo "summary=Created ${prepared} release PR(s): ${prepared_details}" >> "${GITHUB_OUTPUT:-/dev/null}"
else
  echo "summary=No release PRs created (${skipped_no_changes} unchanged, ${skipped_existing_pr} existing)" >> "${GITHUB_OUTPUT:-/dev/null}"
fi

[[ "$failed" -eq 0 ]]
