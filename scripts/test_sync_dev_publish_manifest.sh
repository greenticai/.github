#!/usr/bin/env bash
# test_sync_dev_publish_manifest.sh — unit tests for sync-dev-publish.sh's
# manifest parsing, specifically the main-lane / dev-lane split.
#
# REPO_MANIFEST.toml's `publishes` describes what a repo publishes on the
# MAIN lane. A repo can legitimately publish fewer crates on develop — e.g.
# greentic-runner excludes crates/aw-event-bridge and crates/greentic-aw-runtime
# from its workspace on develop ("main-only crates: not yet integrated"), so
# `cargo publish -p aw-event-bridge` cannot resolve there.
#
# Without a way to express that, --check reports a false drift, and "fixing"
# it produces a caller that publishes runner-core and then dies on the first
# main-only crate — a partial publish. That happened for real in
# greenticai/greentic-runner run 30780468850.
#
# `dev-exclude-publishes` is that expression. These tests pin its semantics.
# No network, no repo checkouts.
#
# Usage: bash scripts/test_sync_dev_publish_manifest.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync-dev-publish.sh"

tests_run=0
tests_failed=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  ((tests_run++)) || true
  if [[ "$expected" == "$actual" ]]; then
    echo "  ✓ $label"
  else
    echo "  ✗ $label"
    echo "      expected: [$expected]"
    echo "      actual:   [$actual]"
    ((tests_failed++)) || true
  fi
}

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
cat > "$FIXTURE_DIR/REPO_MANIFEST.toml" <<'TOML'
[repos.plain-repo]
org = "greenticai"
variant = "host"
tier = 1
publishes = ["alpha", "beta"]
dev-publish-enabled = true

[repos.split-lane-repo]
org = "greenticai"
variant = "wasm"
tier = 7
publishes = ["core", "main-only-a", "main-only-b", "cli"]
dev-exclude-publishes = ["main-only-a", "main-only-b"]
dev-publish-enabled = true

[repos.all-excluded-repo]
org = "greenticai"
variant = "host"
tier = 9
publishes = ["only-on-main"]
dev-exclude-publishes = ["only-on-main"]
dev-publish-enabled = true

[repos.featured-binary-repo]
org = "greenticai"
variant = "host"
tier = 2
publishes = ["gamma"]
binary-crates = ["gamma"]
binary-features = "feat-a,feat-b"
dev-publish-enabled = true
TOML

export SYNC_DEV_PUBLISH_LIB_ONLY=1
export MANIFEST="$FIXTURE_DIR/REPO_MANIFEST.toml"
# shellcheck source=/dev/null
if ! source "$SYNC_SCRIPT"; then
  echo "FATAL: could not source $SYNC_SCRIPT with SYNC_DEV_PUBLISH_LIB_ONLY=1" >&2
  exit 1
fi

# Column 4 of parse_manifest output is the crate list.
crates_for() {
  parse_manifest | awk -F'\t' -v want="$1" '$10 == want { print $4 }'
}
present() {
  parse_manifest | awk -F'\t' -v want="$1" '$10 == want' | wc -l | tr -d ' '
}

echo "── dev-exclude-publishes ──"

assert_eq "repo without the field publishes everything" \
  "alpha beta" "$(crates_for plain-repo)"

assert_eq "excluded crates are dropped, order of the rest preserved" \
  "core cli" "$(crates_for split-lane-repo)"

# A repo whose entire publish set is main-only has nothing to do on the dev
# lane. Emitting it with an empty crate list would generate a caller that
# runs `cargo publish` with no packages; it must be skipped like a repo with
# no `publishes` at all.
assert_eq "repo with every crate excluded is skipped entirely" \
  "0" "$(present all-excluded-repo)"

assert_eq "unaffected repos still emitted" \
  "1" "$(present plain-repo)"

echo ""
echo "── binary-features ──"

# Column 12 of parse_manifest output. The wire format is tab-separated and
# bash `read` collapses consecutive tabs, so an empty optional column must be
# emitted as the `_NONE_` sentinel or every column after it shifts left — a
# failure that produces a plausible-looking caller rather than an error.
binary_features_for() {
  parse_manifest | awk -F'\t' -v want="$1" '$10 == want { print $12 }'
}

assert_eq "repo with the field carries it through" \
  "feat-a,feat-b" "$(binary_features_for featured-binary-repo)"

assert_eq "repo without the field emits the sentinel, not an empty column" \
  "_NONE_" "$(binary_features_for plain-repo)"

# Every earlier column must still land where its reader expects it.
assert_eq "adding the column did not shift the repo name" \
  "1" "$(present featured-binary-repo)"

assert_eq "adding the column did not shift the crate list" \
  "gamma" "$(crates_for featured-binary-repo)"

# The features only reach the emitted caller through the per-binary job, so a
# repo with no binary-crates would drop them silently. Refuse instead.
BAD_MANIFEST="$FIXTURE_DIR/bad.toml"
cat > "$BAD_MANIFEST" <<'TOML'
[repos.no-binaries]
org = "greenticai"
variant = "host"
tier = 1
publishes = ["delta"]
binary-features = "feat-a"
TOML
((tests_run++)) || true
if MANIFEST="$BAD_MANIFEST" parse_manifest >/dev/null 2>&1; then
  echo "  ✗ binary-features without binary-crates is refused"
  ((tests_failed++)) || true
else
  echo "  ✓ binary-features without binary-crates is refused"
fi

echo ""
echo "── Summary ──"
echo "  Run:    $tests_run"
echo "  Failed: $tests_failed"
[[ "$tests_failed" -eq 0 ]] || exit 1
echo "  All manifest-parsing tests passed"
