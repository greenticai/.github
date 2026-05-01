# Runbook — Dev/Stable v2 (Binary Bifurcation)

Use this when adding a new binary-shipping crate to the dev lane,
debugging a `<crate>-dev` publish, or sanity-checking a `cargo binstall`
that's not finding artifacts.

**This runbook is the operational view.** For the full pipeline anatomy
see `DEV_RELEASE.md`; for the design history see
`plans/binary-bifurcation.md`.

**Time budget:** 10 minutes to onboard a new binary; 30 minutes to
diagnose a stuck publish.

---

## Mental model — why bifurcation exists

Binary-shipping repos publish twice on the dev lane:

- **Library crate** (if it has one) — under its canonical name `<crate>`,
  on a pre-release version `M.m.p-dev.{RUN_ID}`. Pre-release sort order
  keeps stable consumers (`<crate> = "X.Y"`) from accidentally resolving
  a dev build.
- **Binary alias** — under sibling crates.io name `<crate>-dev`, on a
  *regular* release version `M.m.{RUN_ID}`. Regular form is required
  because `cargo binstall` skips pre-releases by default. The alias is
  produced at publish time by `rewrite-binary-name.py` rewriting a
  scratch copy under `target/bifurcate/<crate>-dev/`. **The committed
  Cargo.toml on develop never holds the `-dev` suffix.**

Three flavors:

| Flavor | Library publish | Binary alias publish | Manifest fields |
|---|---|---|---|
| **Library-only** | `<crate>` regular `M.m.{RUN_ID}` | (none) | `binary-crates` empty |
| **Dual-role** (lib + bin under same name) | `<crate>` pre-release `M.m.p-dev.{RUN_ID}` | `<crate>-dev` regular `M.m.{RUN_ID}` | `binary-crates` + `dual-role-binary-crates` set; caller `require-pre-release: true` |
| **Binary-only** | (none) | `<crate>-dev` regular `M.m.{RUN_ID}` | `binary-crates` set; `dual-role-binary-crates` empty; caller `require-pre-release: false` |

---

## Onboarding — add a new binary to the bifurcation

Prereqs:

- The repo's `develop` branch already publishes a library (or at least
  has `dev-publish-enabled = true` in `REPO_MANIFEST.toml`).
- You know whether the new binary is **dual-role** (same `[package].name`
  ships both lib and bin) or **binary-only**.

### 1. Update `REPO_MANIFEST.toml`

In `greenticai/.github`:

```toml
[repos.<repo>]
# ...existing fields...
binary-crates = ["<crate>"]                          # always set
dual-role-binary-crates = ["<crate>"]                # only for dual-role; omit for binary-only
binary-bins = ["<bin-name>"]                         # if [[bin]].name differs from [package].name
```

Verify with the audit script:

```bash
bash .github/scripts/audit-binary-crates.sh
```

It cross-checks the manifest against each repo's actual `[[bin]]`
declarations and flags missing `binary-bins` mappings.

### 2. Reserve the `<crate>-dev` name on crates.io (one-time)

Before the first nightly publishes, do a single manual publish to seed
the namespace. This prevents a squatter or mistaken first run from
landing under the wrong identity.

```bash
# In the repo on develop, with target/bifurcate already populated by a
# local dry-run of dev-publish.yml's bifurcate step:
cd target/bifurcate/<crate>-dev
cargo publish --token "$CARGO_REGISTRY_TOKEN" --allow-dirty
```

Or, simpler: trigger one nightly run and let it claim the name. As long
as the name is unclaimed at first run, the workflow succeeds.

### 3. Regenerate the dev-publish caller

```bash
bash .github/scripts/sync-dev-publish.sh --repo <repo>
```

The script reads the manifest and emits
`<repo>/.github/workflows/dev-publish.yml` with `binary-crates`,
`dual-role-binary-crates`, `binary-version`, and (for dual-role)
`require-pre-release: true`. Open a PR; merge once review is clean.

### 4. Bump the develop version to trigger the first nightly

The dev pipeline runs nightly at 02:00 UTC, but to confirm the
onboarding without waiting:

```bash
bash .github/scripts/bump-dev-version.sh <repo>     # patch bump on develop
gh pr create --base develop ...
```

Merge → `dev-publish.yml` fires → wait for the run to finish.

### 5. Smoke-test `cargo binstall`

In a clean container (or any environment without
`~/.cargo/bin/<bin-name>`):

```bash
cargo binstall <bin-name>-dev          # NB: binary, not crate. Same as crate name for most.
<bin-name>-dev --version
```

The version reported should match `M.m.{RUN_ID}` for the run you just
triggered. If binstall reports "no upstream binaries match", see
[Troubleshooting → binstall finds no artifacts](#binstall-finds-no-artifacts).

---

## Troubleshooting

### binstall finds no artifacts

```
$ cargo binstall greentic-foo-dev
ERROR no upstream release matches your version requirement
```

Decision tree:

1. **Does the crate exist on crates.io?**
   ```bash
   curl -s https://crates.io/api/v1/crates/<crate>-dev | jq '.versions[] | {num, yanked, created_at}'
   ```
   If the crate doesn't exist → step 2 of onboarding (reserve name).
   If all versions are yanked → publish forward (don't unyank).

2. **Is the latest version a pre-release (`*-dev.*`)?**
   ```bash
   curl -s https://crates.io/api/v1/crates/<crate>-dev | jq '.crate.max_version'
   # bad:  "0.6.0-dev.7"
   # good: "0.6.25148123"
   ```
   Pre-release means the dev-publish Re-stamp step didn't run or didn't
   match the binary alias. Symptoms historically caused by the binary-only
   re-stamp bug fixed in `greenticai/.github#141` (2026-04-30) and the
   wrong-scheme yanks of 2026-04-27 (PR #128 fixed `sync-dev-publish.sh`).
   Check that the caller has `binary-version: ${{ needs.dev-prepare.outputs.binary-version }}`
   wired into `dev-publish.yml` (look for the literal in the caller —
   missing means the caller predates #128 and needs `sync-dev-publish.sh`
   re-run).

3. **Does the matching GitHub Release exist with binaries?**
   ```bash
   gh release view "v$(curl -s https://crates.io/api/v1/crates/<crate>-dev | jq -r '.crate.max_version')" \
     --repo greenticai/<repo> --json assets --jq '.assets[].name'
   ```
   `cargo binstall`'s metadata in the published crate points at this
   release. If the release was deleted by `cleanup-dev-releases.yml`
   without the corresponding crates.io version being yanked, binstall
   will 404. **Fix:** publish forward (one nightly run) — never unyank,
   never re-create the missing release with hand-uploaded binaries.

### Name rewrite produced a broken Cargo.toml

Symptoms:
- `dev-publish.yml` fails at the `cargo publish` step on a dual-role
  crate with `error: package name cannot be empty` or
  `error: failed to verify package tarball`.
- The bifurcate step ran but produced `target/bifurcate/<crate>-dev/Cargo.toml`
  with mangled `[[bin]]` names or a missing `default-run`.

Repro locally:

```bash
cd <repo>
python3 .github/scripts/rewrite-binary-name.py \
  --crate <crate> --new-name <crate>-dev --dual-role
diff -u Cargo.toml target/bifurcate/<crate>-dev/Cargo.toml
```

Then run the regression suite:

```bash
python3 .github/scripts/test_rewrite_binary_name.py
python3 .github/scripts/test_bump_cargo_versions.py
```

Both must pass clean. If they pass but production fails, the diff
between local and CI is usually:
- A `[[bin]]` block with `name` matching `[package].name` that needs
  to be renamed to `<crate>-dev` to keep `default-run` valid — covered
  by `rewrite-binary-name.py` in `--dual-role` mode.
- Workspace inheritance (`version.workspace = true`) — the bumper must
  preserve this dotted form. See `test_bump_cargo_versions.py`'s
  `test_pre_release_preserves_workspace_member_binary_name` regression.

### Forward-port flips a binary repo's `[package].name`

Symptom: `forward-port.sh` opens a PR that changes `[package].name`
from `<crate>` to `<crate>-dev` (or vice versa).

This **must not happen.** The bifurcation only lives in
`target/bifurcate/`; the committed Cargo.toml on develop and main both
hold the base name `<crate>`. If forward-port is renaming, develop has
the rewrite committed in-tree by mistake — this is exactly the
condition `assert-branch-invariants.yml` (Phase D) WARN catches on
develop and FAILs on main.

Fix sequence:

1. On the offending repo's develop:
   ```bash
   git checkout develop
   grep -rn 'name = "<crate>-dev"' Cargo.toml */Cargo.toml
   ```
   Find the file(s).
2. Restore the base name; commit; push. The forward-port PR can then
   re-open clean (`gh pr close && gh pr reopen` after re-running
   `forward-port.sh`).
3. If the rewrite already merged to main, the WARN became an ERROR
   on the next push. Open a fix PR to main flipping the name back to
   `<crate>` and yank any wrong-named publish on crates.io.

### Wrong-scheme version on `<crate>-dev` (pre-release suffix on a binary alias)

Pre-release on a binary alias is always wrong — `cargo binstall` won't
resolve it.

```bash
cargo yank --version <bad-version> <crate>-dev
```

Trigger a fresh nightly to publish forward:

```bash
gh workflow run dev-publish.yml --repo greenticai/<repo> --ref develop
```

Or wait until 02:00 UTC. The next run produces a regular-release
`M.m.{RUN_ID}` version, becomes the new `max_version`, and binstall
resolves it.

This was the root cause of the 6 yanked versions on 2026-04-27 (fixed
by PR #128) and the binary-only scheme bug fixed by PR #141 (2026-04-30).

### `cleanup-dev-releases.yml` deleted a GitHub Release that binstall still needs

Two possibilities:

- **Live `<crate>-dev` `max_version` points at the deleted release.**
  Binstall 404s. Trigger a fresh nightly to publish forward; the new
  release supersedes the missing one. Don't try to recreate the deleted
  release manually.
- **A historical lockfile pinned an older version.** The cleanup keeps
  `KEEP_LATEST=3` per repo regardless of age, so this is rare in
  practice, but if a consumer pinned past that window: bump the consumer
  to the current `<crate>-dev` version, or pin to a different release
  that's still available. Don't rebuild artifacts for a deleted tag.

The two-level safety in `cleanup-dev-releases.sh` (keep latest N AND
> retention days) is specifically designed to prevent this — if you see
the symptom, double-check the cleanup didn't run with a wrong
`--keep-latest` override.

---

## Reference: what each file does

| File | Role |
|---|---|
| `REPO_MANIFEST.toml` | Authoritative declaration of `binary-crates`, `dual-role-binary-crates`, `binary-bins` per repo. |
| `scripts/sync-dev-publish.sh` | Generates the per-repo `dev-publish.yml` caller from the manifest. Re-run after manifest edits. |
| `scripts/rewrite-binary-name.py` | TOML-aware name rewriter producing `target/bifurcate/<crate>-dev/Cargo.toml`. Has `--dual-role` for staged copy vs in-place. |
| `scripts/bump_cargo_versions.py` | Stamps versions; never touches `[package].name` (regression-tested). |
| `scripts/audit-binary-crates.sh` | Cross-checks manifest vs each repo's actual `[[bin]]` declarations. |
| `scripts/cleanup-dev-releases.sh` | Weekly purge of dev GH Releases > 30d with `KEEP_LATEST=3` floor. |
| `scripts/assert-branch-invariants.py` | Push-time guardrail: main FAIL on `-dev.*` version or `<crate>-dev` name; develop WARN on alias leak. |
| `.github/workflows/dev-prepare.yml` | Stamps versions; outputs `version` (lib) + `binary-version` (binary alias). |
| `.github/workflows/dev-release-binaries.yml` | Builds binaries for the 6-target matrix; uploads to a per-run prerelease GH Release. |
| `.github/workflows/dev-publish.yml` | Bifurcates (rewrite + re-stamp) and publishes to crates.io. |
| `.github/workflows/cleanup-dev-releases.yml` | Centralized weekly cron, Mon 07:30 UTC, mints app token, deletes old dev releases. |
| `.github/workflows/assert-branch-invariants.yml` | Reusable workflow_call fired by per-repo callers on push/PR to main/develop. |

---

## Related runbooks

- `runbooks/minor-version-bump.md` — pre-release lane (Phase B), used
  for the library half when a foundation crate cuts a new minor.
- `runbooks/rollback-bad-publish.md` — yank vs delete mechanics for
  both stable `<crate>` and dev `<crate>-dev` artifacts.

## Related plans

- `plans/binary-bifurcation.md` — the design history. Phase C complete
  2026-05-01; Phase D reusable workflow in PR #146; Phases E (this
  runbook) + F (1.0/1.1 cutover) ongoing.
- `plans/pre-release-minor-bump-lane.md` — the library half of the
  bifurcation, completed 2026-04-22.
