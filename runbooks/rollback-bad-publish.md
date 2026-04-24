# Runbook — Rolling Back a Bad Publish

Use this when a release has shipped something that should not be consumed
— wrong version, broken build, slipped breaking change, leaked secret, or
an artifact that differs from what the tag claims to represent.

**Time budget:** 5 minutes to triage, then proceed to the matching
scenario. If you are unsure which scenario applies, keep the bad
artifact *visible but yanked* rather than deleted — you can always
unyank; you cannot easily un-delete.

---

## Quick decision table

| Symptom | Registry | First action |
|---|---|---|
| Crate version on crates.io shouldn't be consumed (stable or dev `{M.m.RUN_ID}`) | crates.io | **Yank**, then publish forward |
| GitHub Release has wrong/corrupt binary | GitHub Releases | **Delete asset**, re-upload (keep tag + notes) |
| `v{version}` tag points at wrong SHA | Git | **Force-move** tag only if no one has consumed it; otherwise publish forward |
| Secret / credential / PII leaked in published crate | crates.io | **Yank immediately**, rotate the secret, publish forward |
| Downstream repos broken by a bad foundation crate | Any | Triage the upstream repo first; downstream fixes follow |

---

## Triage (first 5 minutes)

1. **Identify what shipped.**
   ```bash
   # crates.io: show all published versions of a crate (stable + dev)
   cargo search <crate-name> --limit 1
   curl -s https://crates.io/api/v1/crates/<crate-name> | jq '.versions[] | {num, yanked, created_at}'

   # For dev builds, the crate name has the `-dev` suffix:
   curl -s https://crates.io/api/v1/crates/<crate-name>-dev | jq '.versions[] | {num, yanked, created_at}'
   ```

2. **Quantify blast radius.** Who consumes this crate?
   ```bash
   # In the workspace root:
   grep -rln 'name-of-bad-crate' */Cargo.toml
   ```
   If it's a foundation crate (tier 0/1: `greentic-types`, `greentic-interfaces`), blast radius is the whole org.

3. **Post to `#release-alerts` on Slack before taking action.** One line:
   `Rolling back <crate> <version> — <one-sentence reason>. Owner: <you>.`
   Prevents someone else from investigating the same incident in parallel.

4. **Classify: security, correctness, or cosmetic?**
   - **Security** (leaked secret, vulnerable dep) → yank + rotate, no waiting
   - **Correctness** (broken build, wrong behavior) → yank + forward fix
   - **Cosmetic** (typo in README inside the crate) → forward fix only, no yank

---

## Scenario A — Bad crates.io stable publish

**The default tool is `cargo yank`.** Yanking marks the version as
"do not use for new resolutions" without removing the bytes —
existing consumers with that version in their `Cargo.lock` keep
working, but `cargo add` / `cargo update` will skip the yanked
version for everyone else.

**Never** try to delete a published version from crates.io. The
registry doesn't support deletion for ecosystem stability reasons,
and the Rust team will not accept support requests to do so.

### Procedure

```bash
# Need a crates.io API token with yank rights. The org secret
# CARGO_REGISTRY_TOKEN works, or use your personal token.
export CARGO_REGISTRY_TOKEN="<token>"

# In the repo root of the bad crate:
cargo yank --version 0.4.59 greentic-types

# Undo if needed within 24 hours:
cargo yank --undo --version 0.4.59 greentic-types
```

### Forward fix (required unless the yank alone is acceptable)

1. Open a PR bumping `[workspace.package].version` to the next patch
   (e.g., `0.4.59` → `0.4.60`).
2. Include the fix in the same PR.
3. Merge. `tag-on-version-bump.yml` creates `v0.4.60`. `crates-publish.yml`
   publishes the fixed version to crates.io.
4. In a follow-up PR (to each consuming repo on `develop` if needed),
   bump the consuming `version = "0.4.60"` or let the nightly Cargo.lock
   sync pick it up.

### If a secret was leaked

1. Yank within minutes of detection.
2. Rotate the leaked credential immediately (regardless of yank status —
   yanked bytes are still downloadable).
3. If the secret is in the `.crate` tarball itself, request crates.io
   deletion per their [security policy](https://foundation.rust-lang.org/policies/security-response/).
   This is the one scenario where deletion is possible — only for
   credential leakage, and only via the security response team.
4. Forward-fix with the leaked value removed.

---

## Scenario B — Bad nightly dev publish (`{M.m.RUN_ID}` on crates.io)

Dev-lane publishes (`<crate>-dev@{M.m.RUN_ID}`) go to crates.io just
like stable. Same rules apply: **yank, do not delete.** crates.io
doesn't allow deletion for any crate, stable or dev-suffixed.

### Procedure

```bash
export CARGO_REGISTRY_TOKEN="<token-with-yank>"
cargo yank --version 0.5.24827549070 greentic-setup-dev
```

Then:
- If the bad publish was caused by a bad commit on `develop`, revert or
  fix the commit. The next nightly will publish a fresh `{M.m.RUN_ID}`.
- If you need the fixed version before the next scheduled nightly, do:
  ```bash
  gh workflow run dev-publish.yml --repo <org>/<repo> --ref develop
  ```
  Do **not** re-dispatch `nightly-develop.yml` — it fans out to every
  repo and posts to Slack (see `feedback_nightly_slack_noise.md`).

### Downstream lock-sync impact

The nightly Cargo.lock sync (`scripts/nightly-cargo-lock-sync.sh`) may
already have opened PRs pinning the bad nightly. Close those PRs
manually; the next nightly will open fresh PRs against the new good
version.

---

## Scenario C — Bad GitHub Release binary

Binaries for `cargo-binstall` live on the GitHub Release for a tag,
produced by `release-binaries.yml` and `release.yml`. These are
replaceable without affecting the underlying tag or crate.

### Procedure

```bash
# List assets
gh release view v0.4.59 --repo <org>/<repo> --json assets

# Delete the bad asset(s)
gh release delete-asset v0.4.59 <asset-filename> --repo <org>/<repo>

# Re-run the workflow that builds binaries for this tag
gh workflow run release-binaries.yml --repo <org>/<repo> --ref v0.4.59
```

SLSA provenance and SBOM files uploaded alongside the binaries should
also be regenerated if the binary changed. They are tied to the
*content hash*, not the version tag.

---

## Scenario D — Bad git tag

Tags are the hardest to roll back because they have downstream
triggers — deleting `v{version}` does not un-trigger the workflows
it already fired.

### Tag hasn't been consumed yet

```bash
# Delete remote tag
git push --delete origin v0.4.59
# Delete local tag
git tag -d v0.4.59
```

Then move `Cargo.toml` version back (amend the release PR or land
a follow-up that reverts the bump), wait for `tag-on-version-bump.yml`
to create the new correct tag when you re-bump properly.

### Tag has been consumed (crates.io published, binaries built)

**Do not delete.** Leave the bad tag in place. Publish forward to
`v0.4.60` with the fix.

Moving or deleting a consumed tag breaks:
- `cargo-binstall` URL resolution (`ghcr.io/.../:{version}`)
- Reproducibility claims — SLSA/SBOM link to a specific SHA
- Git history integrity for anyone who fetched the tag

---

## Post-incident checklist

After the rollback:

- [ ] Yank/delete confirmed — `cargo search` or `curl crates.io/api/.../yanked`
      shows the expected state
- [ ] Forward-fix version shipped and published (if applicable)
- [ ] Downstream Cargo.lock-sync PRs updated or closed (see B above)
- [ ] `#release-alerts` Slack thread updated with final state
- [ ] Rotate any leaked credentials (if Scenario A security path)
- [ ] File a brief incident note at the end of this runbook
      (append to the `## Incident log` section) — one line is fine:
      `2026-04-17 — greentic-types 0.4.59 yanked (broken build, slipped CI). Forward: 0.4.60.`
- [ ] If the bad publish got through CI unnoticed, open an issue against
      the validation gap (e.g., `cargo-semver-checks` didn't catch it,
      dry-run should have rejected it, etc.) so the audit/P2 backlog
      grows with one concrete item

---

## What this runbook deliberately does not cover

- **API-level rollback** (downgrading callers): handled per-consumer,
  not by this doc.
- **Revoking an entire release across tiers**: if a foundation crate
  is actively harmful, treat the whole `v{version}` tag family as
  compromised and yank every downstream version that resolved to it.
  At that point the effort is large enough that incident management
  replaces runbook mechanics.
- **Preventing the next bad publish**: that's the audit's P2 work
  (`cargo audit` / `cargo deny` in the publish path, stricter
  `cargo-semver-checks` enforcement). Don't confuse rollback with
  prevention.

---

## Incident log

<!-- Append entries as `YYYY-MM-DD — <crate> <version> <one-line why + forward-version>`. -->

_(no incidents recorded yet)_
