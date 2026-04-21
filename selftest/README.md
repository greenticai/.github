# greentic-reusable-selftest

Fixture Rust crate consumed exclusively by `.github/workflows/self-test.yml`.

## Purpose

Exercise every reusable CI workflow in this repo against a tiny, known-good
fixture so a typo or logic regression in a reusable fails here first, before
it ships to ~60 per-repo callers.

See `plans/binary-bifurcation.md` Phase A.3 in the greenticai workspace.

## Which reusables are covered

The self-test workflow invokes these reusables:

- `pr-ci.yml` (both `host` and `wasm` variants)
- `host-crate-ci.yml`
- `wasm-component-ci.yml`
- `nightly-semver-advisory.yml`
- `nightly-coverage.yml`
- `nightly-audit.yml`
- `perf-smoke.yml`
- `nightly-perf.yml`
- `dependency-review.yml`
- `codeql.yml` (schedule-only — skipped on PRs for runtime cost)

See the header of `.github/workflows/self-test.yml` for the list of
intentionally excluded reusables (publishers, notifiers, tag-creators,
Codex remediators, dependabot-automerge) and the rationale.

## Mechanics

Each reusable checks out this repo at its root, which does *not* contain a
Rust crate by itself. The self-test workflow passes a `setup-script` to each
reusable that stages this fixture at repo root before cargo commands run:

```bash
cp -a selftest/. ./
```

After the overlay, root has `Cargo.toml`, `src/`, `tests/`, `benches/`. The
root already carries canonical `rust-toolchain.toml` and `rustfmt.toml` so
the `toolchain-check` job (which runs without `setup-script`) emits no drift
warning.

## Not for external use

This crate is never published and is not imported by any other repo.
`publish = false` and version `0.0.0` are enforced. If you're reading this
outside CI, you're in the wrong place.
