# register-greentic-release

Best-effort push of a just-published GitHub release's archives to
greentic-admin's release catalogue (`POST /api/v1/releases`).

## Purpose

`dev-release-binaries.yml` and `release-binaries.yml` already attach the
built `*.tgz`/`*.zip` archives (with `*.sha256` sidecars) to the GitHub
Release. This action additionally *pushes* that same release to
greentic-admin so it appears in the release catalogue sooner than the
admin's own GitHub-release scanner would otherwise pick it up.

**It is an accelerator, never the source of truth.** The admin registers the
same release independently from the GitHub release itself, so this action
is allowed to fail (network error, admin down, admin predates the route,
`409`/`422` from the admin, anything) without ever failing the calling
workflow. `register.py` always exits `0` and prints a `::warning::` instead
of an error on any non-success outcome.

## Inputs

| input | required | description |
|---|---|---|
| `admin-url` | yes | Base URL of the greentic-admin instance. Pass `''` (empty) to skip. |
| `repo` | yes | `owner/repo` the release was published from — normally `${{ github.repository }}`. |
| `name` | yes | Binary/package name as it appears in the archive filename (no `-dev` infix — matched with or without it). |
| `version` | yes | Released version string, matching the release tag's `v<version>`. |
| `dist-dir` | yes | Directory holding the built archives and their `.sha256` sidecars. |
| `key` | yes | `gts_` bearer key with scope `release_publisher`. Pass `''` (empty) to skip. |

## The secret

This action needs a `gts_` bearer key with scope `release_publisher`,
minted by an admin operator, stored as the **`GREENTIC_RELEASE_PUBLISHER_KEY`**
organization secret. It also needs the **`GREENTIC_ADMIN_URL`**
repository/organization variable naming the admin instance to register
against.

**It is safe to leave both unconfigured.** Neither `dev-release-binaries.yml`
nor `release-binaries.yml` calls this action unless
`secrets.GREENTIC_RELEASE_PUBLISHER_KEY` is non-empty (checked via a
job-level `env` mapping, since a reusable workflow's step `if:` cannot read
the `secrets` context directly), and the action itself no-ops when either
`admin-url` or `key` is empty. Until both exist, this is a pure no-op —
releases keep working exactly as before, and the admin still picks them up
through its own scanner.

**Reusable-workflow callers must opt in.** Because GitHub Actions does not
forward organization secrets into a *called* reusable workflow unless the
calling job passes them explicitly (`secrets: inherit`, or the secret named
individually), a per-repo caller of `dev-release-binaries.yml` /
`release-binaries.yml` needs `secrets: inherit` on that job before this
feature activates for that repo — the reusable workflow declares the secret
as optional (`required: false`) so this is additive and never breaks an
existing caller that does not pass it.
