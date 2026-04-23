#!/usr/bin/env bash
# audit-binary-crates.sh — Classify published binary crates as binary-only or dual-role
#
# Scans the 16 candidate binary repos and emits a Markdown table suitable for
# pasting into .github/audits/binary-dual-role.md. For each `publishes` entry
# that corresponds to a crate shipping a binary, it records:
#   - crate name (from [package].name)
#   - crate directory (relative to repo root)
#   - has `src/lib.rs` (library surface?)
#   - has binary (`src/main.rs`, `src/bin/*.rs`, or `[[bin]]` block)
#   - classification: dual-role | binary-only | library-only | none
#
# Output: Markdown to stdout. Commit SHAs captured to help pin "last verified".
#
# Usage:
#   .github/scripts/audit-binary-crates.sh                # all 16 repos
#   .github/scripts/audit-binary-crates.sh greentic-flow  # single repo

set -euo pipefail

WORKSPACE="${WORKSPACE:-/home/vampik/greenticai}"

BINARY_REPOS=(
    greentic
    greentic-dev
    greentic-operator
    greentic-flow
    greentic-runner
    greentic-start
    greentic-sorla
    greentic-setup
    greentic-provision
    greentic-dw
    greentic-bundle
    greentic-mcp
    greentic-gui
    greentic-x
    greentic-coding-agent
    greentic-qa
)

if [[ $# -gt 0 ]]; then
    BINARY_REPOS=("$@")
fi

extract_name() {
    local ct="$1"
    # Match first [package] block's `name = "..."`. Cheap heuristic: the first
    # `name = "X"` line before any subtable header works for all canonical layouts.
    awk '
        /^\[package\]/ { in_pkg = 1; next }
        /^\[/ && !/^\[package\]/ { in_pkg = 0 }
        in_pkg && /^[[:space:]]*name[[:space:]]*=/ {
            match($0, /"[^"]*"/)
            if (RSTART) print substr($0, RSTART + 1, RLENGTH - 2)
            exit
        }
    ' "$ct"
}

count_bin_blocks() {
    grep -c '^\[\[bin\]\]' "$1" 2>/dev/null || true
}

count_src_bin_files() {
    local dir="$1"
    if [[ -d "$dir/src/bin" ]]; then
        find "$dir/src/bin" -maxdepth 1 -name '*.rs' 2>/dev/null | wc -l
    else
        echo 0
    fi
}

classify() {
    local has_lib="$1" has_bin="$2"
    if [[ "$has_lib" == "yes" && "$has_bin" == "yes" ]]; then
        echo "dual-role"
    elif [[ "$has_lib" == "no" && "$has_bin" == "yes" ]]; then
        echo "binary-only"
    elif [[ "$has_lib" == "yes" && "$has_bin" == "no" ]]; then
        echo "library-only"
    else
        echo "none"
    fi
}

printf '| Repo | SHA | Crate (in `publishes`) | Dir | lib.rs | binary | Classification |\n'
printf '|---|---|---|---|---|---|---|\n'

for repo in "${BINARY_REPOS[@]}"; do
    repo_dir="$WORKSPACE/$repo"
    if [[ ! -d "$repo_dir" ]]; then
        printf '| %s | — | — | — | — | — | **MISSING DIR** |\n' "$repo"
        continue
    fi

    sha=$(git -C "$repo_dir" rev-parse --short=12 HEAD 2>/dev/null || echo "—")

    # Pull publishes list from manifest using tomllib. One-off inline because
    # the manifest already lives next door.
    publishes=$(python3 - "$repo" <<'PY'
import sys, tomllib
repo = sys.argv[1]
with open("/home/vampik/greenticai/.github/toolchain/REPO_MANIFEST.toml", "rb") as f:
    m = tomllib.load(f)
print("\n".join(m["repos"].get(repo, {}).get("publishes", [])))
PY
)

    # Find every Cargo.toml under the repo, match [package].name against publishes list.
    if [[ -z "$publishes" ]]; then
        printf '| %s | `%s` | — | — | — | — | **publishes = []** (binary ships without cargo publish) |\n' "$repo" "$sha"
        continue
    fi

    while IFS= read -r ct; do
        [[ "$ct" == *"/target/"* ]] && continue
        name=$(extract_name "$ct")
        [[ -z "$name" ]] && continue
        # Only record crates that are in the repo's `publishes` list.
        if ! grep -qxF "$name" <<<"$publishes"; then
            continue
        fi

        dir=$(dirname "$ct")
        rel_dir="${dir#"$repo_dir"/}"
        [[ "$rel_dir" == "$dir" ]] && rel_dir="."

        has_lib="no"
        [[ -f "$dir/src/lib.rs" ]] && has_lib="yes"

        bin_blocks=$(count_bin_blocks "$ct")
        src_bin=$(count_src_bin_files "$dir")
        has_main="no"
        [[ -f "$dir/src/main.rs" ]] && has_main="yes"

        has_bin="no"
        if [[ "$bin_blocks" -gt 0 || "$src_bin" -gt 0 || "$has_main" == "yes" ]]; then
            has_bin="yes"
        fi

        # Only rows where crate actually ships a binary.
        [[ "$has_bin" == "no" ]] && continue

        cls=$(classify "$has_lib" "$has_bin")
        printf '| %s | `%s` | `%s` | `%s` | %s | %s | %s |\n' \
            "$repo" "$sha" "$name" "$rel_dir" "$has_lib" "$has_bin" "$cls"
    done < <(find "$repo_dir" -name Cargo.toml -not -path '*/target/*' -not -path '*/tests/fixtures/*' -not -path '*/tests/assets/*' -not -path '*/examples/*' -not -path '*/fuzz/*' -not -path '*/vendor/*' 2>/dev/null)
done
