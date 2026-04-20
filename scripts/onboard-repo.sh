#!/usr/bin/env bash
# onboard-repo.sh — Apply standard Greentic CI conventions to a repo
#
# Usage:
#   # Local mode — repo already cloned side-by-side with .github checkout
#   bash scripts/onboard-repo.sh REPO_NAME                    # host crate, defaults
#   bash scripts/onboard-repo.sh REPO_NAME --variant wasm     # WASM component
#   bash scripts/onboard-repo.sh REPO_NAME --dry-run          # preview only
#   bash scripts/onboard-repo.sh REPO_NAME --branch-rename    # also rename master → main
#
#   # Remote mode — no local checkout of the target repo needed
#   bash scripts/onboard-repo.sh REPO_NAME --remote
#
# Options:
#   --remote              Operate remotely: clone target to tmp dir, commit, push, open PR.
#                         Also opens a second PR against greenticai/.github to register the
#                         repo in REPO_MANIFEST.toml. Requires GH_TOKEN and `gh` CLI.
#   --local               Explicit local mode (default). Operates on a sibling checkout.
#   --variant host|wasm   Toolchain variant (auto-detected if omitted)
#   --org NAME            GitHub org: greenticai (default) or greentic-biz
#   --branch-rename       Rename default branch master → main (GitHub + local if --local)
#   --semver-checks       Enable run-semver-checks in ci.yml
#   --force               Overwrite existing workflow files
#   --skip-fmt            Skip cargo fmt --all
#   --skip-msrv           Skip adding rust-version to Cargo.toml files
#   --skip-manifest       Skip adding repo to REPO_MANIFEST.toml
#   --dry-run             Show what would change, change nothing
#
# Environment:
#   GH_TOKEN              Required in --remote mode. PAT or GitHub App token with
#                         repo-write scope across the target org and greenticai/.github.
#   GREENTIC_WORKSPACE    Override the local workspace root (default: parent of .github repo)
#   GIT_AUTHOR_NAME       Override commit author name (default: github-actions[bot])
#   GIT_AUTHOR_EMAIL      Override commit author email
#
# Requires: gh (GitHub CLI), git, python3. cargo only if `cargo fmt` should run.

set -euo pipefail

# ── Resolve paths from script location ───────────────────────────
# The script lives at <.github-repo>/scripts/onboard-repo.sh.
# All canonical files (toolchain, manifest, rustfmt) are at
# <.github-repo>/toolchain/. The "workspace" (for --local mode) is the
# parent directory of the .github repo checkout, where sibling repos live.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CANONICAL_DIR="$GITHUB_REPO_ROOT/toolchain"
MANIFEST="$CANONICAL_DIR/REPO_MANIFEST.toml"
WORKSPACE="${GREENTIC_WORKSPACE:-$(cd "$GITHUB_REPO_ROOT/.." && pwd)}"
BIZ_DIR="$WORKSPACE/GREENTIC-BIZ"
RUST_VERSION="1.95"

# Sanity check: canonical files must exist
if [[ ! -f "$MANIFEST" ]]; then
  echo "Error: REPO_MANIFEST.toml not found at $MANIFEST" >&2
  echo "  Expected layout: <.github-repo>/scripts/onboard-repo.sh" >&2
  echo "                   <.github-repo>/toolchain/REPO_MANIFEST.toml" >&2
  exit 1
fi

# Org → local directory mapping (only used in --local mode)
declare -A ORG_DIRS=(
  [greenticai]="$WORKSPACE"
  [greentic-biz]="$BIZ_DIR"
)

# ── Options ──────────────────────────────────────────────────────
REPO_NAME=""
VARIANT=""          # auto-detect if empty
ORG="greenticai"
MODE="local"        # local | remote
BRANCH_RENAME=false
SEMVER_CHECKS=false
FORCE=false
SKIP_FMT=false
SKIP_MSRV=false
SKIP_MANIFEST=false
DRY_RUN=false

# ── Argument parsing ─────────────────────────────────────────────
show_help() {
  sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
  exit 0
}

expect_value() {
  if [[ -z "${2:-}" || "$2" == --* ]]; then
    echo "Error: $1 requires a value" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)        MODE="remote"; shift ;;
    --local)         MODE="local"; shift ;;
    --variant)       expect_value "$1" "${2:-}"; VARIANT="$2"; shift 2 ;;
    --org)           expect_value "$1" "${2:-}"; ORG="$2"; shift 2 ;;
    --branch-rename) BRANCH_RENAME=true; shift ;;
    --semver-checks) SEMVER_CHECKS=true; shift ;;
    --force)         FORCE=true; shift ;;
    --skip-fmt)      SKIP_FMT=true; shift ;;
    --skip-msrv)     SKIP_MSRV=true; shift ;;
    --skip-manifest) SKIP_MANIFEST=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --help|-h)       show_help ;;
    --*)             echo "Unknown option: $1" >&2; exit 1 ;;
    *)
      if [[ -z "$REPO_NAME" ]]; then
        REPO_NAME="$1"; shift
      else
        echo "Unexpected argument: $1" >&2; exit 1
      fi
      ;;
  esac
done

if [[ -z "$REPO_NAME" ]]; then
  echo "Usage: $0 REPO_NAME [OPTIONS]" >&2
  echo "Run $0 --help for details" >&2
  exit 1
fi

# ── Colors (disabled in CI unless FORCE_COLOR is set) ────────────
if [[ -t 1 || -n "${FORCE_COLOR:-}" ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  DIM='\033[2m'
  RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

log_ok()      { echo -e "  ${GREEN}✓${RESET} $1"; }
log_skip()    { echo -e "  ${YELLOW}⊘${RESET} $1"; }
log_fail()    { echo -e "  ${RED}✗${RESET} $1"; }
log_info()    { echo -e "  ${BLUE}→${RESET} $1"; }
log_create()  { echo -e "  ${GREEN}+${RESET} $1"; }
log_update()  { echo -e "  ${BLUE}~${RESET} $1"; }
log_dry()     { echo -e "  ${DIM}(dry-run)${RESET} $1"; }
log_section() { echo -e "\n${CYAN}${BOLD}[$1]${RESET}"; }

# ── Counters ─────────────────────────────────────────────────────
created=0
updated=0
skipped=0
failed=0

declare -a changes_made=()
declare -a changes_skipped=()
declare -a pr_urls=()

track_created() { changes_made+=("+ $1"); ((created++)) || true; }
track_updated() { changes_made+=("~ $1"); ((updated++)) || true; }
track_skipped() { changes_skipped+=("$1"); ((skipped++)) || true; }

# ── Git commit identity (used in --remote mode) ──────────────────
GIT_NAME="${GIT_AUTHOR_NAME:-github-actions[bot]}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

# ── Dependency-graph probe state ─────────────────────────────────
# Cached result of check_dependency_graph_state() so we only hit the API once.
# Values: enabled | disabled | unknown | "" (not yet probed)
DEPENDENCY_GRAPH_STATE=""

# ── Resolve REPO_PATH (mode-dependent) ───────────────────────────
# REMOTE_TMPDIR is set only in --remote mode so the cleanup trap can rm it.
REMOTE_TMPDIR=""
MANIFEST_TMPDIR=""

cleanup_tmpdirs() {
  [[ -n "$REMOTE_TMPDIR" && -d "$REMOTE_TMPDIR" ]] && rm -rf "$REMOTE_TMPDIR"
  [[ -n "$MANIFEST_TMPDIR" && -d "$MANIFEST_TMPDIR" ]] && rm -rf "$MANIFEST_TMPDIR"
  return 0  # EXIT traps: never leak a non-zero from the final test
}
trap cleanup_tmpdirs EXIT

if [[ "$MODE" == "remote" ]]; then
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo -e "${RED}Error: --remote mode requires GH_TOKEN env var${RESET}" >&2
    exit 1
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo -e "${RED}Error: --remote mode requires the 'gh' CLI${RESET}" >&2
    exit 1
  fi
  REMOTE_TMPDIR="$(mktemp -d)"
  REPO_PATH="$REMOTE_TMPDIR/$REPO_NAME"
else
  LOCAL_DIR="${ORG_DIRS[$ORG]:-}"
  if [[ -z "$LOCAL_DIR" ]]; then
    echo -e "${RED}Error: unknown org '$ORG'${RESET}" >&2
    exit 1
  fi
  REPO_PATH="$LOCAL_DIR/$REPO_NAME"
  if [[ ! -d "$REPO_PATH/.git" ]]; then
    echo -e "${RED}Error: $REPO_PATH is not a git repository${RESET}" >&2
    echo -e "${DIM}Hint: pass --remote to clone and operate without a local checkout${RESET}" >&2
    exit 1
  fi
fi

# ── Header ───────────────────────────────────────────────────────
echo -e "${BOLD}Greentic Repo Onboarding${RESET}"
echo -e "Repo:    ${BOLD}$ORG/$REPO_NAME${RESET}"
echo -e "Mode:    $MODE"
[[ "$MODE" == "local" ]] && echo -e "Path:    $REPO_PATH"
[[ "$DRY_RUN" == true ]] && echo -e "Dry-run: ${YELLOW}yes${RESET}"
[[ "$FORCE" == true ]]   && echo -e "Force:   ${YELLOW}yes${RESET}"

# ══════════════════════════════════════════════════════════════════
# Remote clone (must happen before variant auto-detect, which reads files)
# ══════════════════════════════════════════════════════════════════
remote_clone() {
  [[ "$MODE" != "remote" ]] && return

  log_section "Remote setup"
  log_info "Cloning $ORG/$REPO_NAME to tmp dir"
  if ! git clone --quiet \
      "https://x-access-token:${GH_TOKEN}@github.com/$ORG/$REPO_NAME.git" \
      "$REPO_PATH" 2>&1; then
    echo -e "${RED}Error: clone failed for $ORG/$REPO_NAME${RESET}" >&2
    exit 1
  fi
  git -C "$REPO_PATH" config user.name "$GIT_NAME"
  git -C "$REPO_PATH" config user.email "$GIT_EMAIL"
  log_ok "Cloned $(git -C "$REPO_PATH" rev-parse --short HEAD) on $(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD)"
}

remote_clone

# ── Auto-detect variant (reads files in $REPO_PATH) ──────────────
if [[ -z "$VARIANT" ]]; then
  if [[ -f "$REPO_PATH/component.manifest.json" ]]; then
    VARIANT="wasm"
  elif grep -rq 'wasm32-wasip2' "$REPO_PATH/rust-toolchain.toml" 2>/dev/null; then
    VARIANT="wasm"
  elif grep -rq 'wasm32-wasip2' "$REPO_PATH/Cargo.toml" 2>/dev/null; then
    VARIANT="wasm"
  else
    VARIANT="host"
  fi
  log_info "Auto-detected variant: ${BOLD}$VARIANT${RESET}"
fi

if [[ "$VARIANT" != "host" && "$VARIANT" != "wasm" ]]; then
  echo -e "${RED}Error: --variant must be 'host' or 'wasm', got '$VARIANT'${RESET}" >&2
  exit 1
fi

echo -e "Variant: $VARIANT"

# ══════════════════════════════════════════════════════════════════
# Step 1: Branch rename (master → main)
# ══════════════════════════════════════════════════════════════════
rename_branch() {
  log_section "Step 1: Branch rename"

  if [[ "$BRANCH_RENAME" != true ]]; then
    log_skip "Skipped (use --branch-rename to enable)"
    return
  fi

  # In remote mode we don't trust the local clone's HEAD — ask the API
  # for the authoritative default branch.
  local current_default
  if [[ "$MODE" == "remote" ]]; then
    current_default=$(gh api "repos/$ORG/$REPO_NAME" --jq '.default_branch' 2>/dev/null || echo "")
  else
    current_default=$(git -C "$REPO_PATH" remote show origin 2>/dev/null \
      | grep "HEAD branch" | sed 's/.*: //')
  fi

  if [[ -z "$current_default" ]]; then
    log_fail "Could not determine current default branch"
    ((failed++)) || true
    return
  fi

  if [[ "$current_default" == "main" ]]; then
    log_ok "Default branch is already 'main'"
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would rename default branch '$current_default' → 'main' on GitHub"
    [[ "$MODE" == "local" ]] && log_dry "Would update local branch tracking"
    return
  fi

  log_info "Renaming default branch on GitHub: $current_default → main"
  if ! gh api -X PATCH "repos/$ORG/$REPO_NAME" -f default_branch=main >/dev/null 2>&1; then
    log_fail "GitHub API call failed — do you have admin access?"
    ((failed++)) || true
    return
  fi

  if [[ "$MODE" == "local" ]]; then
    git -C "$REPO_PATH" branch -m "$current_default" main 2>/dev/null || true
    git -C "$REPO_PATH" fetch origin --quiet 2>/dev/null || true
    git -C "$REPO_PATH" branch -u origin/main main 2>/dev/null || true
    git -C "$REPO_PATH" remote set-head origin -a --quiet 2>/dev/null || true
  fi

  log_ok "Default branch renamed to 'main'"
  track_updated "branch: $current_default → main"
}

# ══════════════════════════════════════════════════════════════════
# Step 2: Config files (rust-toolchain.toml, rustfmt.toml)
# ══════════════════════════════════════════════════════════════════
sync_config_files() {
  log_section "Step 2: Config files"

  local canonical_toolchain="$CANONICAL_DIR/$VARIANT/rust-toolchain.toml"
  local canonical_rustfmt="$CANONICAL_DIR/rustfmt.toml"

  # rust-toolchain.toml
  local repo_toolchain="$REPO_PATH/rust-toolchain.toml"
  if diff -q "$repo_toolchain" "$canonical_toolchain" >/dev/null 2>&1; then
    log_ok "rust-toolchain.toml — up to date"
    track_skipped "rust-toolchain.toml (up to date)"
  else
    if [[ "$DRY_RUN" == true ]]; then
      log_dry "Would copy rust-toolchain.toml ($VARIANT variant)"
      if [[ -f "$repo_toolchain" ]]; then
        diff "$repo_toolchain" "$canonical_toolchain" 2>/dev/null | sed 's/^/    /' || echo "    (new file)"
      fi
    else
      local verb="created"
      [[ -f "$repo_toolchain" ]] && verb="updated"
      cp "$canonical_toolchain" "$repo_toolchain"
      if [[ "$verb" == "created" ]]; then
        log_create "rust-toolchain.toml — created ($VARIANT variant)"
        track_created "rust-toolchain.toml"
      else
        log_update "rust-toolchain.toml — updated ($VARIANT variant)"
        track_updated "rust-toolchain.toml"
      fi
    fi
  fi

  # rustfmt.toml
  local repo_rustfmt="$REPO_PATH/rustfmt.toml"
  if diff -q "$repo_rustfmt" "$canonical_rustfmt" >/dev/null 2>&1; then
    log_ok "rustfmt.toml — up to date"
    track_skipped "rustfmt.toml (up to date)"
  else
    if [[ "$DRY_RUN" == true ]]; then
      log_dry "Would copy rustfmt.toml"
    else
      local verb="created"
      [[ -f "$repo_rustfmt" ]] && verb="updated"
      cp "$canonical_rustfmt" "$repo_rustfmt"
      if [[ "$verb" == "created" ]]; then
        log_create "rustfmt.toml — created"
        track_created "rustfmt.toml"
      else
        log_update "rustfmt.toml — updated"
        track_updated "rustfmt.toml"
      fi
    fi
  fi
}

# ══════════════════════════════════════════════════════════════════
# Step 3: Dependabot
# ══════════════════════════════════════════════════════════════════
create_dependabot() {
  log_section "Step 3: Dependabot"

  local target="$REPO_PATH/.github/dependabot.yml"

  local expected
  expected=$(cat <<'EOF'
version: 2
updates:
  - package-ecosystem: "cargo"
    directory: "/"
    schedule:
      interval: "daily"
    open-pull-requests-limit: 10
    rebase-strategy: "auto"
EOF
)

  if [[ -f "$target" ]]; then
    if echo "$expected" | diff -q "$target" - >/dev/null 2>&1; then
      log_ok "dependabot.yml — up to date"
      track_skipped "dependabot.yml (up to date)"
      return
    fi
    if [[ "$FORCE" != true ]]; then
      log_skip "dependabot.yml — exists (use --force to overwrite)"
      track_skipped "dependabot.yml (exists)"
      return
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would create .github/dependabot.yml"
    return
  fi

  mkdir -p "$REPO_PATH/.github"
  echo "$expected" > "$target"

  log_create ".github/dependabot.yml"
  track_created ".github/dependabot.yml"
}

# ══════════════════════════════════════════════════════════════════
# Step 4: MSRV (rust-version in Cargo.toml)
# ══════════════════════════════════════════════════════════════════
inject_msrv() {
  log_section "Step 4: MSRV (rust-version)"

  if [[ "$SKIP_MSRV" == true ]]; then
    log_skip "Skipped (--skip-msrv)"
    return
  fi

  local cargo_files
  cargo_files=$(find "$REPO_PATH" -name Cargo.toml -not -path "*/target/*" | sort)

  local injected=0
  local already=0

  for cargo_toml in $cargo_files; do
    local rel_path="${cargo_toml#"$REPO_PATH/"}"

    # Skip files without [package] section (virtual workspaces)
    if ! grep -q '^\[package\]' "$cargo_toml"; then
      continue
    fi

    # Check if rust-version already exists
    if grep -q '^rust-version' "$cargo_toml"; then
      ((already++)) || true
      continue
    fi

    if [[ "$DRY_RUN" == true ]]; then
      log_dry "Would add rust-version = \"$RUST_VERSION\" to $rel_path"
      ((injected++)) || true
      continue
    fi

    # Insert after edition line, or after version line
    if grep -q '^edition' "$cargo_toml"; then
      sed -i "/^edition/a rust-version = \"$RUST_VERSION\"" "$cargo_toml"
    elif grep -q '^version' "$cargo_toml"; then
      sed -i "/^version/a rust-version = \"$RUST_VERSION\"" "$cargo_toml"
    else
      log_skip "$rel_path — no edition/version line to anchor after"
      continue
    fi

    log_update "$rel_path — added rust-version = \"$RUST_VERSION\""
    ((injected++)) || true
  done

  if [[ "$injected" -gt 0 ]]; then
    track_updated "rust-version added to $injected Cargo.toml file(s)"
  fi
  if [[ "$already" -gt 0 ]]; then
    log_ok "$already Cargo.toml file(s) already have rust-version"
  fi
  if [[ "$injected" -eq 0 && "$already" -eq 0 ]]; then
    log_skip "No Cargo.toml files with [package] found"
  fi
}

# ══════════════════════════════════════════════════════════════════
# Dependency-graph probe
# ──────────────────────────────────────────────────────────────────
# dependency-review.yml only works if GitHub's dependency graph is enabled
# on the repo. Public repos have it on by default; private repos need GHAS
# with the dependency-graph feature explicitly enabled. Adding the workflow
# to a repo without dependency-graph produces a permanent red check on
# every PR ("Dependency review is not supported on this repository") — so
# we probe once and skip the workflow when it would only ever fail.
#
# Rules:
#   public repo                                       → enabled
#   private + .security_and_analysis.dependency_graph.status == "enabled"
#                                                     → enabled
#   private + anything else (null sa, missing key)    → disabled
#   probe failure / no gh / auth error                → unknown (fail open)
# ══════════════════════════════════════════════════════════════════
check_dependency_graph_state() {
  [[ -n "$DEPENDENCY_GRAPH_STATE" ]] && return 0

  if ! command -v gh >/dev/null 2>&1; then
    DEPENDENCY_GRAPH_STATE="unknown"
    return 0
  fi

  local probe
  if ! probe=$(gh api "repos/$ORG/$REPO_NAME" \
      --jq '[(.private | tostring), (.security_and_analysis.dependency_graph.status // "")] | @tsv' \
      2>/dev/null); then
    DEPENDENCY_GRAPH_STATE="unknown"
    return 0
  fi

  local is_private="${probe%$'\t'*}"
  local dep_status="${probe#*$'\t'}"

  if [[ "$is_private" == "false" ]]; then
    # Public repos always have dependency graph on; the API doesn't
    # expose an overridable key for them.
    DEPENDENCY_GRAPH_STATE="enabled"
  elif [[ "$dep_status" == "enabled" ]]; then
    DEPENDENCY_GRAPH_STATE="enabled"
  else
    DEPENDENCY_GRAPH_STATE="disabled"
  fi
  return 0
}

# ══════════════════════════════════════════════════════════════════
# Step 5: Standard workflow files
# ══════════════════════════════════════════════════════════════════
create_workflows() {
  log_section "Step 5: Workflows"

  # Probe dependency-graph state so we can skip dependency-review.yml
  # when it would only ever produce a red check.
  check_dependency_graph_state
  case "$DEPENDENCY_GRAPH_STATE" in
    enabled)  log_info "Dependency graph: ${GREEN}enabled${RESET}" ;;
    disabled) log_info "Dependency graph: ${YELLOW}disabled${RESET} — will skip dependency-review.yml" ;;
    unknown)  log_info "Dependency graph: ${DIM}unknown${RESET} (probe failed) — will attempt dependency-review.yml" ;;
  esac

  local wf_dir="$REPO_PATH/.github/workflows"
  mkdir -p "$wf_dir"

  # ── ci.yml ──
  local ci_template
  if [[ "$VARIANT" == "wasm" ]]; then
    ci_template="wasm-component-ci.yml"
  else
    ci_template="host-crate-ci.yml"
  fi

  local ci_with=""
  if [[ "$SEMVER_CHECKS" == true ]]; then
    ci_with=$'\n    with:\n      run-semver-checks: true'
  fi

  write_workflow "ci.yml" "$(cat <<EOF
name: CI
on:
  workflow_call:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read

concurrency:
  group: ci-\${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    uses: greenticai/.github/.github/workflows/${ci_template}@main${ci_with}
EOF
)"

  # ── codeql.yml ──
  write_workflow "codeql.yml" "$(cat <<'EOF'
name: CodeQL
on:
  push:
    branches: [main]
  schedule:
    - cron: "30 1 * * 1"
permissions:
  security-events: write
  contents: read
  actions: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  codeql:
    uses: greenticai/.github/.github/workflows/codeql.yml@main
EOF
)"

  # ── dependency-review.yml ──
  # Skip when the repo's dependency graph is disabled — the workflow would
  # otherwise fail on every PR with "Dependency review is not supported on
  # this repository" until GHAS is enabled.
  if [[ "$DEPENDENCY_GRAPH_STATE" == "disabled" ]]; then
    local dep_review_target="$REPO_PATH/.github/workflows/dependency-review.yml"
    if [[ -f "$dep_review_target" ]]; then
      log_skip "dependency-review.yml — present but dependency graph is disabled on $ORG/$REPO_NAME (enable GHAS or remove the file)"
    else
      log_skip "dependency-review.yml — skipped (dependency graph disabled on $ORG/$REPO_NAME)"
    fi
    track_skipped "dependency-review.yml (dependency graph disabled)"
  else
    write_workflow "dependency-review.yml" "$(cat <<'EOF'
name: Dependency Review
on:
  pull_request:
    branches: [main]
permissions:
  contents: write
  pull-requests: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  dep-review:
    uses: greenticai/.github/.github/workflows/dependency-review.yml@main
    secrets: inherit
EOF
)"
  fi

  # ── codex-security-fix.yml ──
  write_workflow "codex-security-fix.yml" "$(cat <<'EOF'
name: Codex Security Fix
on:
  pull_request:
    branches: [main]
  workflow_dispatch:
    inputs:
      branch:
        description: "Branch to scan and patch (only for manual run)"
        required: false
        default: ""
      max_alerts:
        description: "Maximum open alerts per source to include"
        required: true
        default: "20"
permissions:
  contents: write
  pull-requests: write
  security-events: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  security-fix:
    uses: greenticai/.github/.github/workflows/codex-security-fix.yml@main
    with:
      branch: ${{ github.event.inputs.branch || '' }}
      max_alerts: ${{ github.event.inputs.max_alerts || '20' }}
    secrets: inherit
EOF
)"

  # ── codex-semver-fix.yml ──
  write_workflow "codex-semver-fix.yml" "$(cat <<'EOF'
name: Codex Semver Fix
on:
  pull_request:
    branches: [main]
  workflow_dispatch:
    inputs:
      branch:
        description: "Branch to scan and patch (only for manual run)"
        required: false
        default: ""
permissions:
  contents: write
  pull-requests: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  semver-fix:
    uses: greenticai/.github/.github/workflows/codex-semver-fix.yml@main
    with:
      branch: ${{ github.event.inputs.branch || '' }}
    secrets: inherit
EOF
)"

  # ── auto-tag.yml ──
  write_workflow "auto-tag.yml" "$(cat <<'EOF'
name: Auto tag

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false

jobs:
  tag:
    uses: greenticai/.github/.github/workflows/auto-tag.yml@main
EOF
)"

  # ── dependabot-automerge.yml ──
  write_workflow "dependabot-automerge.yml" "$(cat <<'EOF'
name: Dependabot auto-merge
on:
  pull_request_target:
    types: [opened, reopened, synchronize, ready_for_review]
permissions:
  pull-requests: write
  contents: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false

jobs:
  automerge:
    uses: greenticai/.github/.github/workflows/dependabot-automerge.yml@main
    secrets: inherit
EOF
)"
}

# Helper: write a single workflow file with skip/force logic
write_workflow() {
  local name="$1"
  local content="$2"
  local target="$REPO_PATH/.github/workflows/$name"

  if [[ -f "$target" ]]; then
    if echo "$content" | diff -q "$target" - >/dev/null 2>&1; then
      log_ok "$name — up to date"
      track_skipped "$name (up to date)"
      return
    fi
    if [[ "$FORCE" != true ]]; then
      log_skip "$name — exists (use --force to overwrite)"
      track_skipped "$name (exists)"
      return
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    if [[ -f "$target" ]]; then
      log_dry "Would overwrite .github/workflows/$name"
    else
      log_dry "Would create .github/workflows/$name"
    fi
    return
  fi

  echo "$content" > "$target"

  if [[ -f "$target" ]]; then
    log_create ".github/workflows/$name"
    track_created ".github/workflows/$name"
  fi
}

# ══════════════════════════════════════════════════════════════════
# Step 6: cargo fmt (best-effort — skip if cargo unavailable)
# ══════════════════════════════════════════════════════════════════
run_fmt() {
  log_section "Step 6: Format"

  if [[ "$SKIP_FMT" == true ]]; then
    log_skip "Skipped (--skip-fmt)"
    return
  fi

  if ! command -v cargo >/dev/null 2>&1; then
    log_skip "cargo not available — skipping (CI fmt-check will catch any issues)"
    return
  fi

  if [[ ! -f "$REPO_PATH/Cargo.toml" ]]; then
    log_skip "No Cargo.toml at repo root — skipping"
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would run cargo fmt --all"
    return
  fi

  log_info "Running cargo fmt --all ..."
  if (cd "$REPO_PATH" && cargo fmt --all 2>&1); then
    log_ok "Formatting applied"
  else
    log_fail "cargo fmt failed — run manually"
    ((failed++)) || true
  fi
}

# ══════════════════════════════════════════════════════════════════
# Step 7a: REPO_MANIFEST.toml (local mode — in-place edit)
# ══════════════════════════════════════════════════════════════════
update_manifest_local() {
  log_section "Step 7: REPO_MANIFEST.toml"

  if [[ "$SKIP_MANIFEST" == true ]]; then
    log_skip "Skipped (--skip-manifest)"
    return
  fi

  local already_present
  already_present=$(python3 -c "
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
print('yes' if '$REPO_NAME' in m.get('repos', {}) else 'no')
" 2>/dev/null || echo "error")

  if [[ "$already_present" == "yes" ]]; then
    log_ok "Already listed as [repos.$REPO_NAME]"
    track_skipped "REPO_MANIFEST.toml (already listed)"
    return
  fi

  if [[ "$already_present" == "error" ]]; then
    log_fail "Failed to parse manifest"
    ((failed++)) || true
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would add [repos.$REPO_NAME] to REPO_MANIFEST.toml"
    return
  fi

  append_manifest_entry "$MANIFEST" "$ORG" "$VARIANT" "$REPO_NAME"

  if [[ $? -eq 0 ]]; then
    log_create "Added [repos.$REPO_NAME] (org=$ORG, variant=$VARIANT)"
    track_updated "REPO_MANIFEST.toml"
  else
    log_fail "Failed to update manifest"
    ((failed++)) || true
  fi
}

# ══════════════════════════════════════════════════════════════════
# Step 7b: REPO_MANIFEST.toml (remote mode — clone, edit, commit, PR)
# ══════════════════════════════════════════════════════════════════
update_manifest_remote() {
  log_section "Step 7: REPO_MANIFEST.toml"

  if [[ "$SKIP_MANIFEST" == true ]]; then
    log_skip "Skipped (--skip-manifest)"
    return
  fi

  # Read from the local canonical copy first — fast check to see if we even
  # need to open a PR. This is accurate enough because the workflow checks out
  # .github on the same run, and local invocations see the current HEAD.
  local already_present
  already_present=$(python3 -c "
import tomllib
with open('$MANIFEST', 'rb') as f:
    m = tomllib.load(f)
print('yes' if '$REPO_NAME' in m.get('repos', {}) else 'no')
" 2>/dev/null || echo "error")

  if [[ "$already_present" == "yes" ]]; then
    log_ok "Already listed as [repos.$REPO_NAME]"
    return
  fi

  if [[ "$already_present" == "error" ]]; then
    log_fail "Failed to parse manifest"
    ((failed++)) || true
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would open PR to greenticai/.github to register [repos.$REPO_NAME]"
    return
  fi

  # Clone greenticai/.github to a separate tmp dir
  MANIFEST_TMPDIR="$(mktemp -d)"
  if ! git clone --quiet --depth 1 \
      "https://x-access-token:${GH_TOKEN}@github.com/greenticai/.github.git" \
      "$MANIFEST_TMPDIR" 2>&1; then
    log_fail "Failed to clone greenticai/.github"
    ((failed++)) || true
    return
  fi

  local github_manifest="$MANIFEST_TMPDIR/toolchain/REPO_MANIFEST.toml"

  # Re-check after clone (covers race vs stale local canonical)
  local fresh_present
  fresh_present=$(python3 -c "
import tomllib
with open('$github_manifest', 'rb') as f:
    m = tomllib.load(f)
print('yes' if '$REPO_NAME' in m.get('repos', {}) else 'no')
" 2>/dev/null || echo "error")

  if [[ "$fresh_present" == "yes" ]]; then
    log_ok "Already listed in remote manifest (race or stale local canonical)"
    return
  fi

  append_manifest_entry "$github_manifest" "$ORG" "$VARIANT" "$REPO_NAME"

  local branch="chore/onboard-manifest-$REPO_NAME-$(date -u '+%Y%m%d-%H%M%S')"
  (
    cd "$MANIFEST_TMPDIR"
    git config user.name "$GIT_NAME"
    git config user.email "$GIT_EMAIL"
    git checkout -b "$branch" 2>/dev/null
    git add toolchain/REPO_MANIFEST.toml
    git commit --quiet -m "chore(manifest): register $REPO_NAME (org=$ORG, variant=$VARIANT)"
    git push --quiet origin "$branch"
  ) || {
    log_fail "Manifest commit/push failed"
    ((failed++)) || true
    return
  }

  local pr_body
  pr_body=$(cat <<PRBODY
## Register \`$REPO_NAME\` in REPO_MANIFEST.toml

Adds \`[repos.$REPO_NAME]\` with:

- \`org = "$ORG"\`
- \`variant = "$VARIANT"\`
- \`tier = $([[ "$ORG" == "greentic-biz" ]] && echo 8 || echo 7)\`
- \`publishes = []\`
- \`version-track = { from = "0.4", to = "0.5" }\`
- \`weekly-stable-enabled = false\`

Part of the onboarding run for \`$ORG/$REPO_NAME\`. Once merged, the repo will be picked up by workspace scripts (\`sync-toolchain.sh\`, \`branch-develop.sh\`, etc.) and by CI orchestrators.

---
_Automated by [onboard-repo](https://github.com/greenticai/.github/actions/workflows/onboard-repo.yml)._
PRBODY
)

  local pr_url
  pr_url=$(gh pr create --repo greenticai/.github \
    --base main --head "$branch" \
    --title "chore(manifest): register $REPO_NAME" \
    --body "$pr_body" 2>&1) || {
    log_fail "Manifest PR creation failed: $pr_url"
    ((failed++)) || true
    return
  }

  log_create "Manifest PR: $pr_url"
  track_created "REPO_MANIFEST.toml entry (PR)"
  pr_urls+=("manifest: $pr_url")
}

# Shared helper: append a new [repos.NAME] entry to a manifest file
append_manifest_entry() {
  local manifest_path="$1"
  local org="$2"
  local variant="$3"
  local repo_name="$4"

  python3 -c "
manifest_path = '$manifest_path'
org = '$org'
variant = '$variant'
repo_name = '$repo_name'

# Tier 8 for greentic-biz, tier 7 for greenticai new repos
tier = 8 if org == 'greentic-biz' else 7

entry = f'''
[repos.{repo_name}]
org = \"{org}\"
variant = \"{variant}\"
tier = {tier}
publishes = []
version-track = {{ from = \"0.4\", to = \"0.5\" }}
weekly-stable-enabled = false
'''

with open(manifest_path, 'a') as f:
    f.write(entry)
"
}

# ══════════════════════════════════════════════════════════════════
# Step 8 (remote only): commit + push + PR of target repo changes
# ══════════════════════════════════════════════════════════════════
commit_and_pr_target() {
  [[ "$MODE" != "remote" ]] && return

  log_section "Step 8: Commit & PR (target repo)"

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would commit changes and open PR on $ORG/$REPO_NAME"
    return
  fi

  # Check if there's anything to commit
  if [[ -z "$(git -C "$REPO_PATH" status --porcelain)" ]]; then
    log_ok "No changes to commit — repo already conforms"
    return
  fi

  local branch="chore/onboard-ci-conventions-$(date -u '+%Y%m%d-%H%M%S')"

  (
    cd "$REPO_PATH"
    git checkout -b "$branch" 2>/dev/null
    git add -A
    git commit --quiet -m "chore(ci): onboard standard Greentic CI conventions"
    git push --quiet origin "$branch"
  ) || {
    log_fail "Commit/push failed on target repo"
    ((failed++)) || true
    return
  }

  # Determine base branch from API (respects branch rename if it happened this run)
  local base_branch
  base_branch=$(gh api "repos/$ORG/$REPO_NAME" --jq '.default_branch' 2>/dev/null || echo "main")

  local pr_body
  pr_body=$(cat <<'PRBODY'
## Onboarding — standard Greentic CI conventions

Applies the canonical CI layout from `greenticai/.github`:

- ✅ `rust-toolchain.toml` (synced from `.github/toolchain/<variant>/`)
- ✅ `rustfmt.toml`
- ✅ `.github/dependabot.yml`
- ✅ `rust-version` in `Cargo.toml` (MSRV)
- ✅ Standard workflow callers:
  - `ci.yml`
  - `codeql.yml`
  - `dependency-review.yml`
  - `codex-security-fix.yml`
  - `codex-semver-fix.yml`
  - `auto-tag.yml`
  - `dependabot-automerge.yml`

### Next steps

1. Wait for CI to run on this PR.
2. If `cargo fmt --check` fails, run `cargo fmt --all` locally and push the fixup commit — the automation runs fmt best-effort and may skip it if `cargo` isn't available on the runner.
3. A second PR to `greenticai/.github` registers this repo in `REPO_MANIFEST.toml`. Merge that one too so downstream orchestrators pick up this repo.

---
_Automated by [onboard-repo](https://github.com/greenticai/.github/actions/workflows/onboard-repo.yml)._
PRBODY
)

  local pr_url
  pr_url=$(gh pr create --repo "$ORG/$REPO_NAME" \
    --base "$base_branch" --head "$branch" \
    --title "chore(ci): onboard standard Greentic CI conventions" \
    --body "$pr_body" 2>&1) || {
    log_fail "PR creation failed on $ORG/$REPO_NAME: $pr_url"
    ((failed++)) || true
    return
  }

  log_create "Target PR: $pr_url"
  pr_urls+=("target: $pr_url")
}

# ══════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════
rename_branch
sync_config_files
create_dependabot
inject_msrv
create_workflows
run_fmt

if [[ "$MODE" == "remote" ]]; then
  # Order matters: commit target repo first (so its PR is visible),
  # then open the manifest PR against .github as a follow-up.
  commit_and_pr_target
  update_manifest_remote
else
  update_manifest_local
fi

# ══════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}━━━ Summary ━━━${RESET}"
echo -e "  ${GREEN}Created:${RESET}  $created"
echo -e "  ${BLUE}Updated:${RESET}  $updated"
[[ "$skipped" -gt 0 ]] && echo -e "  ${YELLOW}Skipped:${RESET}  $skipped"
[[ "$failed" -gt 0 ]]  && echo -e "  ${RED}Failed:${RESET}   $failed"

if [[ ${#changes_made[@]} -gt 0 ]]; then
  echo ""
  echo -e "  ${BOLD}Changes:${RESET}"
  for c in "${changes_made[@]}"; do
    echo -e "    $c"
  done
fi

if [[ ${#changes_skipped[@]} -gt 0 && "$DRY_RUN" != true ]]; then
  echo ""
  echo -e "  ${DIM}Skipped:${RESET}"
  for c in "${changes_skipped[@]}"; do
    echo -e "    ${DIM}$c${RESET}"
  done
fi

if [[ ${#pr_urls[@]} -gt 0 ]]; then
  echo ""
  echo -e "  ${BOLD}Pull requests:${RESET}"
  for p in "${pr_urls[@]}"; do
    echo -e "    $p"
  done
fi

echo ""
if [[ "$DRY_RUN" == true ]]; then
  echo -e "${YELLOW}Dry run — no changes were made.${RESET}"
elif [[ "$failed" -gt 0 ]]; then
  echo -e "${YELLOW}Done with $failed failure(s). Review output above.${RESET}"
  exit 1
elif [[ "$MODE" == "local" ]]; then
  echo -e "${GREEN}Done.${RESET} Review changes, then commit and push."
  echo -e "${DIM}Hint: cd $REPO_PATH && git diff${RESET}"
else
  echo -e "${GREEN}Done.${RESET} PRs opened — review and merge when ready."
fi
