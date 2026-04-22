# Runbook — Minor Version Bump (Pre-Release Lane)

Use this when a foundation crate has (or is about to have) a breaking change
and the ecosystem needs to absorb it without a single-weekend cascade.

**Core idea:** develop publishes `X.(Y+1).0-dev.N` to CodeArtifact while
main keeps shipping `X.Y.*` patches to crates.io. Consumers opt into the
new minor at their own pace by updating their own dep req strings. Cargo's
pre-release matching is the adoption firewall — `^X.Y` never resolves
`X.(Y+1).0-dev.N`.

**Time budget:** 10 minutes to kick off one repo. Tier-ordered cascade
completes over 1–2 weeks across 30+ repos via ordinary weekly-stable-prepare
cuts, not a weekend sprint.

---

## Prerequisites

- Workstation with sibling checkout of all Greentic repos under `/home/USER/greenticai/`
- `gh` CLI authenticated with org-wide access
- `.github` repo checked out and up to date on `main`
- `REPO_MANIFEST.toml` entry exists for the target repo

---

## Kickoff — one repo, one minor cut

1. Identify the foundation/leaf repo to start with. **Order matters:** promote
   tier 0 first (`greentic-types`, `greentic-interfaces`, `greentic-telemetry`,
   `greentic-i18n`), then tier 1, etc. Do not promote two crates in the same
   tier on the same day — the Cargo.lock sync races (Tuesday nightly fans out
   dep updates, and two simultaneous upstream minors collide).

2. Run from the workspace root:
   ```bash
   ./.github/scripts/start-next-minor.sh <repo>            # auto-compute X.(Y+1).0-dev.0
   ./.github/scripts/start-next-minor.sh <repo> 0.8.0-dev.0  # explicit target
   ```
   The script:
   - Validates the repo is on `develop`, working tree is clean, version is
     stable (no existing pre-release suffix), and the target matches the
     adjacent minor.
   - Creates branch `chore/start-minor-X.Y` and rewrites `Cargo.toml`:
     - Package version → `X.Y.0-dev.0`
     - Greentic-ecosystem dep reqs → `">=X.Y.0-dev, <X.(Y+1).0-0"`
   - Commits, pushes, opens a PR to develop.
   - Emits a cascade plan at `.github/cascade-plans/<repo>-<target>.md`
     listing every tier-ordered consumer with its current dep spec.

3. Review the PR diff. If the dep-range form or version bump is wrong,
   close the PR and delete the remote branch — no state was touched on
   develop yet. If correct, merge.

4. On merge, `dev-publish.yml` auto-triggers and publishes the first
   pre-release artifact to AWS CodeArtifact. The artifact version uses the
   `${BASE%.*}.${GITHUB_RUN_ID}` stamping convention, which for a
   `X.Y.Z-dev.N` base produces `X.Y.Z-dev.<run_id>` — matches the consumer
   range from step 2. See `plans/pre-release-minor-bump-lane.md` discovery
   note; this match is load-bearing on a coincidence, guarded by a test.

---

## Cascade — adopting the new minor in downstream repos

Consumers are **not** auto-cascaded. Each consumer adopts on its own
timeline when it's ready to absorb the breaking change.

For each consumer in the cascade plan (tier order, one at a time):

1. On the consumer's `develop`, edit `Cargo.toml` dep req:
   ```diff
   - <upstream-crate> = "X.Y"
   + <upstream-crate> = ">=X.Y.0-dev, <X.(Y+1).0-0"
   ```
   Or for already-range-form specs, replace the lower bound with `-dev`.

2. Run `cargo update -p <upstream-crate>` to refresh `Cargo.lock` —
   requires CodeArtifact auth on the workstation (only CI has it by
   default; if stuck, let the consumer's dev-publish on develop regenerate
   the lock).

3. Address any breaking-change friction (compile errors, renamed APIs,
   changed trait signatures). Land all fixes in the same PR as the dep
   bump — a half-bumped consumer breaks its own CI.

4. If the consumer itself has downstream consumers (tier > 0), **also**
   kick off its own minor lane:
   ```bash
   ./.github/scripts/start-next-minor.sh <consumer>
   ```
   Stagger these by ~1 nightly cycle each — don't run four tier-1 promotions
   in the same hour.

5. Merge. The consumer's `dev-publish.yml` re-publishes under the new minor
   pre-release form. Subsequent-tier consumers pick up from there on their
   own schedule.

---

## Closing a lane — stable cut

Weekly-stable-prepare (Monday 06:00 UTC) handles this automatically when
develop is on a pre-release:

- Detects the `-dev.*` suffix.
- Branches from **develop** (not main), strips the suffix, opens a release
  PR to main titled `release: v<X.Y.Z> (minor cut)`.
- PR merge triggers `tag-on-version-bump.yml` → `crates-publish.yml` →
  crates.io ships `X.Y.0` as the new stable.
- Forward-port on Tuesday brings the new main state back into develop.

Manual trigger when you can't wait for Monday:
```bash
gh workflow run weekly-stable-prepare.yml \
  --repo greenticai/.github \
  -f repo=<target> -f dry-run=false
```

Dry-run first to preview:
```bash
gh workflow run weekly-stable-prepare.yml \
  --repo greenticai/.github \
  -f repo=<target> -f dry-run=true
```

---

## Abort — revert develop to stable before cut

If the pre-release lane was started in error:

1. On the target repo:
   ```bash
   git checkout develop
   git reset --hard HEAD~1   # if only the kickoff commit is on develop
   # OR
   git revert <kickoff-commit-sha>
   git push --force-with-lease origin develop    # only if no consumer
                                                  # PRs reference this lane yet
   ```
2. Delete any pre-release artifacts already published to CodeArtifact.
   See `runbooks/rollback-bad-publish.md` → CodeArtifact scenario.
3. If consumers already flipped their dep ranges to the pre-release form,
   either (a) wait for them to revert their own dep bumps, or (b) leave
   a `0.Y.0` stable published and let consumers migrate forward anyway.
4. Update `REPO_MANIFEST.toml` if the `version-track` entry was advanced.

---

## Known hazards

| Hazard | Mitigation |
|---|---|
| Two tier-0 crates promoted on the same day | Stagger by ≥1 nightly cycle; Tuesday forward-port prefers a single upstream minor at a time. Symptoms: Cargo.lock resolves mixed-minor deps, mid-tier repos fail to build. |
| Consumer sets dep to pre-release range, then forgets to flip back at stable cut | Weekly-stable-prepare rewrites consumer dep ranges back to stable form via `bump_cargo_versions.py --deps-only` when it minor-cuts. Verify in release-PR diff. |
| Develop behind main due to missing forward-port → weekly-stable cuts from stale develop state | Phase 3 guard aborts with `develop is BEHIND main`. Run `forward-port.sh` first. |
| `-dev.N` accidentally lands on main via direct PR | Phase 4a `main-pre-release-guard` CI job fails the PR. |
| Pre-release lane stalls for weeks without a minor cut | Phase 4b `train-stall-monitor.yml` posts to Slack after 30 days. |
| Dev-publish stamping logic "fixed" to always strip -dev → consumers no longer resolve pre-release artifacts | Regression test `test_dev_publish_stamping_coincidence.py` asserts the stamp output matches the dep range form. |

---

## Expected timeline

| Tier | From kickoff to stable cut |
|---|---|
| 0 (foundation) | Same day or 1–2 days — verify CodeArtifact publish, then first downstream adopter |
| 1–3 | 1 week — tier-by-tier adoption, nightly Cargo.lock propagation |
| 4–8 | 1–2 weeks — leaf/business consumers, usually batched |

Total: roughly one weekly-stable cycle per minor bump, end-to-end. Not a
weekend sprint, not a quarterly migration.

---

## Related

- Plan: `plans/pre-release-minor-bump-lane.md`
- Parent plan: `plans/binary-bifurcation.md` Phase B
- Scripts: `start-next-minor.sh`, `bump-dev-version.sh`, `weekly-stable-prepare.sh`, `train-stall-monitor.sh`
- CI guards: `pr-ci.yml` (`main-pre-release-guard` job), `train-stall-monitor.yml`
- Rollback: `runbooks/rollback-bad-publish.md`
