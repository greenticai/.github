#!/usr/bin/env bash
# test_orchestrate_cascade.sh — unit tests for the tier-cascade decision in
# nightly-develop-orchestrate.sh.
#
# The orchestrator force-dispatches every higher tier once a lower tier
# publishes ("upstream changed"). That is only correct when the lower-tier
# repo actually produced a new artefact. Repos whose manifest `publishes`
# list is empty run a CI-only dev-publish caller and must not cascade —
# otherwise a green CI run mass-rebuilds and re-publishes unchanged crates,
# which trips crates.io's update rate limit (429).
#
# These tests source the orchestrator as a library (ORCHESTRATE_LIB_ONLY=1)
# and exercise the decision against a fixture manifest. No network.
#
# Usage: bash scripts/test_orchestrate_cascade.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCHESTRATOR="$SCRIPT_DIR/nightly-develop-orchestrate.sh"

tests_run=0
tests_failed=0

fail() {
  echo "  ✗ $1"
  echo "      expected: $2"
  echo "      actual:   $3"
  ((tests_failed++)) || true
}

ok() { echo "  ✓ $1"; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  ((tests_run++)) || true
  if [[ "$expected" == "$actual" ]]; then ok "$label"; else fail "$label" "$expected" "$actual"; fi
}

# ── Fixture ──────────────────────────────────────────────────────
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
cat > "$FIXTURE_DIR/REPO_MANIFEST.toml" <<'TOML'
[repos.lib-repo]
org = "greenticai"
tier = 5
publishes = ["lib-core", "lib-cli"]
dev-publish-enabled = true

[repos.ci-only-repo]
org = "greentic-biz"
tier = 4
publishes = []
dev-publish-enabled = true

[repos.archived-repo]
org = "greenticai"
tier = 5
publishes = ["dead-crate"]
dev-publish-enabled = true
archived = true

[repos.disabled-repo]
org = "greenticai"
tier = 5
publishes = ["off-crate"]
dev-publish-enabled = false
TOML

# ── Load the orchestrator as a library ───────────────────────────
export ORCHESTRATE_LIB_ONLY=1
export MANIFEST="$FIXTURE_DIR/REPO_MANIFEST.toml"
# shellcheck source=/dev/null
if ! source "$ORCHESTRATOR"; then
  echo "FATAL: could not source $ORCHESTRATOR with ORCHESTRATE_LIB_ONLY=1" >&2
  exit 1
fi

echo "── publishes_artifacts ──"
load_publishing_repos

((tests_run++)) || true
if publishes_artifacts "greenticai/lib-repo"; then
  ok "repo with non-empty publishes is artefact-producing"
else
  fail "repo with non-empty publishes is artefact-producing" "true" "false"
fi

((tests_run++)) || true
if publishes_artifacts "greentic-biz/ci-only-repo"; then
  fail "repo with publishes = [] is NOT artefact-producing" "false" "true"
else
  ok "repo with publishes = [] is NOT artefact-producing"
fi

((tests_run++)) || true
if publishes_artifacts "greenticai/unknown-repo"; then
  fail "repo absent from manifest is NOT artefact-producing" "false" "true"
else
  ok "repo absent from manifest is NOT artefact-producing"
fi

echo "── mark_published cascade decision ──"

# A CI-only repo succeeding must not arm the cascade.
lower_tier_published=false
published_names=""
mark_published "greentic-biz/ci-only-repo" >/dev/null
assert_eq "CI-only success does not arm cascade" "false" "$lower_tier_published"
assert_eq "CI-only success is still reported as succeeded" "ci-only-repo" "$published_names"

# A publishing repo succeeding must arm the cascade.
lower_tier_published=false
published_names=""
mark_published "greenticai/lib-repo" >/dev/null
assert_eq "publishing repo arms cascade" "true" "$lower_tier_published"
assert_eq "publishing repo is reported" "lib-repo" "$published_names"

# Once armed, a later CI-only success must not disarm it.
mark_published "greentic-biz/ci-only-repo" >/dev/null
assert_eq "CI-only success does not disarm an armed cascade" "true" "$lower_tier_published"
assert_eq "both repos reported" "lib-repo, ci-only-repo" "$published_names"

# Mixed tier, CI-only first: order must not matter.
lower_tier_published=false
published_names=""
mark_published "greentic-biz/ci-only-repo" >/dev/null
mark_published "greenticai/lib-repo" >/dev/null
assert_eq "cascade arms regardless of ordering" "true" "$lower_tier_published"

echo ""
echo "── Summary ──"
echo "  Run:    $tests_run"
echo "  Failed: $tests_failed"
[[ "$tests_failed" -eq 0 ]] || exit 1
echo "  All cascade tests passed"
