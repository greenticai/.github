# Runbook — CI Speedup: nextest + base-branch cache-warming + job split

Use this when a Rust repo's CI is slow, hits its `timeout-minutes`, or
shows the **cold-cache cancel loop** (runs cancelled at the timeout never
save their cache, so the retry is cold again — the signature is several
consecutive `cancelled` conclusions on `ci.yml` across different PRs).

**Origin:** applied to `greentic-biz/greentic-designer` in its PR #493
(2026-06-06). Measured there: cold wall 31.5m → 20m, test execution
8m36s → 43s, warm wall ~12.5m → ~5-6m expected. This runbook generalizes
that change for other repos.

**Time budget:** ~30 minutes per repo + one local full-suite run.

---

## Mental model — where the time actually goes

Measure first. Pull step timings from one warm and one cold run:

```bash
gh api repos/<org>/<repo>/actions/runs/<run-id>/jobs \
  --jq '.jobs[] | .name, (.steps[] | "\(.name)\t\(.started_at)\t\(.completed_at)")'
```

Three independent defects produce most slow-CI complaints, and they
compound:

1. **No base-branch cache.** `Swatinem/rust-cache` restores from the
   current ref scope, then the PR's *base branch* scope, then the default
   branch. If `ci.yml` only triggers on `pull_request` (and the working
   branch is not the default branch — e.g. `research`), the base branch
   never runs CI and never saves a cache. Every first run on a new branch
   is fully cold.
2. **Timeout-cancel loop.** A run cancelled at `timeout-minutes` skips its
   post steps, so the cache is never saved and the next run is cold again.
   Raising the timeout is the stopgap; warming the base-branch cache is
   the fix.
3. **Serialized tests.** `cargo test -- --test-threads=1` (usually added
   because some tests mutate process-global env vars) serializes the whole
   suite. `cargo-nextest` runs **each test in its own process**, so env
   mutations are isolated per test and the suite parallelizes — the
   original reason for serialization disappears.

## The recipe

### 1. Cache-warm the working branch

Add the repo's working branch (e.g. `research`, `develop`) to the push
trigger so every merge saves a fresh cache that PRs restore from:

```yaml
on:
  workflow_call:
  pull_request:
  push:
    branches: [main, research]   # + the repo's working branch
```

Keep `concurrency: group: ci-${{ github.ref }} / cancel-in-progress: true`
— rapid consecutive merges cancel older warm runs and the latest one
saves, which is the cache you want anyway.

### 2. Split lint and test into parallel jobs

```yaml
jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
      # (keep any free-disk step the repo already has)
      - uses: dtolnay/rust-toolchain@<version matching rust-toolchain.toml>
        with: { components: "rustfmt, clippy" }
      - uses: Swatinem/rust-cache@v2
      - run: cargo fmt --all -- --check
      - run: cargo clippy --workspace --all-targets --all-features -- -D warnings

  test:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@<same version>
      - uses: Swatinem/rust-cache@v2
      - uses: taiki-e/install-action@nextest
      - run: cargo nextest run --workspace --all-features
      - run: cargo test --doc --workspace --all-features   # nextest skips doctests
```

Wall time becomes `max(lint, test)` instead of the sum. rust-cache's
default key includes the job id, so the two jobs keep separate caches and
never race on save. Expect roughly 2× cache storage; GitHub's 10 GB repo
limit evicts LRU.

### 3. The nextest gate (do NOT skip)

Before opening the PR, run the full suite locally:

```bash
cargo nextest run --workspace --all-features   # plus any repo-specific env, e.g. GREENTIC_EXT_ALLOW_UNSIGNED=1
cargo test --doc --workspace --all-features
```

- A test that fails only under nextest has a hidden inter-test
  dependency. Fix it per-test (nextest supports per-test
  `threads-required` / filter overrides) — do not globally revert to
  serial.
- In-process serialization mutexes (`static ENV_LOCK: Mutex<()>` style)
  become no-ops across tests under nextest (each test is its own
  process). That is fine **if** the tests isolate their on-disk state
  (TempDir per test); verify the ones that mutate `HOME`-relative paths.
- `#[ignore]` semantics are unchanged; doctests need the separate
  `cargo test --doc` step.

### 4. Hygiene while you're in the file

Check `dtolnay/rust-toolchain@<x>` matches `rust-toolchain.toml` — a
mismatch silently downloads two toolchains.

## Verification (per repo)

1. The adoption PR's own run uses the new workflow — record both jobs'
   wall times in the PR body.
2. After merge, confirm the working-branch push run fires and saves
   caches:
   ```bash
   gh api "repos/<org>/<repo>/actions/caches?ref=refs/heads/<branch>" \
     --jq '.actions_caches[] | "\(.key)  \(.size_in_bytes/1048576|floor)MB"'
   ```
3. The next PR opened by anyone should show a rust-cache restore hit and
   land in the warm-time band.

## When this recipe does NOT apply

- **Build-dominated pipelines** (e.g. sequential `cargo-component` builds
  of many wasm targets): nextest does not help the build phase. The
  cache-warm trigger and a *matrix* split (one job per component) are the
  applicable parts. `greentic-messaging-providers` is in this class — its
  timeout was raised to 60m as a stopgap and still needs the matrix
  split.
- Repos whose CI is already <5m warm: leave them alone.
- sccache: considered for the designer and deliberately skipped —
  rust-cache + base-branch warming was sufficient. Revisit only if cold
  runs stay painful after this recipe.

## Reference implementation

`greentic-biz/greentic-designer` `.github/workflows/ci.yml` as of its
PR #493, with the measurement methodology in
`docs/superpowers/specs/2026-06-06-ci-speedup-design.md` in that repo.
