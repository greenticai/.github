# Binary-crate dual-role audit

Phase C of `plans/binary-bifurcation.md` renames binary crates to `<name>-dev` on
the develop lane. Crates that *also* ship a library under the same `[package].name`
(**dual-role**) cannot be renamed in place without breaking downstream library
consumers or internal `use <crate>::` imports — they need a sibling publish.
Crates without `src/lib.rs` (**binary-only**) can be rewritten in place.

This file pins the classification used by `REPO_MANIFEST.toml`'s `binary-crates`
and `dual-role-binary-crates` fields. Re-run the audit after any repo's crate
layout changes:

```bash
.github/scripts/audit-binary-crates.sh
```

## Classification (last refreshed 2026-04-27)

Each row is a `[package].name` that (a) appears in the repo's `publishes` list
and (b) ships a binary (`src/main.rs`, `src/bin/*.rs`, or a `[[bin]]` block).

| Repo | SHA | Crate (in `publishes`) | Dir | lib.rs | binary | Classification |
|---|---|---|---|---|---|---|
| greentic | `9af1e44eadf2` | `gtc` | `.` | yes | yes | dual-role |
| greentic-dev | `0822919f74d0` | `greentic-dev` | `.` | yes | yes | dual-role |
| greentic-operator | `58eb215262a7` | `greentic-operator` | `.` | yes | yes | dual-role |
| greentic-flow | `663080d815ed` | `greentic-flow` | `.` | yes | yes | dual-role |
| greentic-runner | `916207d655e2` | `greentic-runner` | `crates/greentic-runner` | yes | yes | dual-role |
| greentic-start | `15b0af364ed1` | `greentic-start` | `.` | yes | yes | dual-role |
| greentic-sorla | `21d02132b7f8` | `greentic-sorla` | `crates/greentic-sorla-cli` | yes | yes | dual-role |
| greentic-setup | `9abfc2da9789` | `greentic-setup` | `.` | yes | yes | dual-role |
| greentic-provision | `71e183e9ada3` | `greentic-provision` | `crates/greentic-provision-cli` | no | yes | binary-only |
| greentic-bundle | `549f179109ec` | `greentic-bundle` | `.` | yes | yes | dual-role |
| greentic-mcp | `369782b72c4e` | `greentic-mcp-exec` | `crates/mcp-exec` | yes | yes | dual-role |
| greentic-mcp | `369782b72c4e` | `greentic-mcp` | `greentic-mcp` | yes | yes | dual-role |
| greentic-gui | `56fb7e3c6249` | `greentic-gui` | `.` | no | yes | binary-only |
| greentic-deployer | `fae09572ffbc` | `greentic-deployer` | `.` | yes | yes | dual-role |
| greentic-dwbase | `6b73949bf832` | `dwbase-cli` | `crates/dwbase-cli` | no | yes | binary-only |
| greentic-dwbase | `6b73949bf832` | `dwbase-node` | `crates/dwbase-node` | no | yes | binary-only |
| greentic-dwbase | `6b73949bf832` | `dwbase-pack-runner` | `crates/dwbase-pack-runner` | no | yes | binary-only |

**Summary:** 17 publishable binary crates across 14 repos. 12 dual-role, 5 binary-only.

## Why `gtc` is classified dual-role

`gtc` has `src/lib.rs`. An earlier draft of Phase C proposed treating `gtc` as
binary-only after `grep` showed no external Cargo deps on `gtc`. That check is
necessary but not sufficient: `gtc`'s own binary source imports
`use gtc::perf_targets`, `use gtc::error`, etc. (see
`greentic/src/bin/gtc/*.rs`, `greentic/tests/perf_scaling.rs`). Renaming
`[package].name` to `gtc-dev` in place would also rename the implicit library
target to `gtc-dev` (Rust path: `gtc_dev`), breaking those imports unless we
also sweep every `.rs` file.

Dual-role mechanism (copy + rewrite) sidesteps this: the original crate dir
stays `gtc`, imports keep working, and a separate staged copy publishes as
`gtc-dev`.

## Out of scope (binary not currently published)

Four repos ship a binary via `release-binaries.yml` builds but **do not** list
the binary crate in their manifest `publishes` field, so no `cargo publish`
currently produces a library/binary crate on crates.io under the binary's
name (on either the stable `<crate>` or the dev `<crate>-dev` lane):

| Repo | Binary crate (not in `publishes`) | Dir | lib.rs | Status |
|---|---|---|---|---|
| greentic-dw | `greentic-dw` | `greentic-dw` | no | binary-only; `greentic-dw-cli` (library) is published instead |
| greentic-x | `greentic-x` | `crates/gx` | yes | dual-role; `publishes = []` for whole repo |
| greentic-coding-agent | `greentic-coding-agent` | `crates/gca-cli` | no | binary-only; `publishes = []` for whole repo |
| greentic-qa | `greentic-qa` | `crates/qa-cli` | no | binary-only; binary not in `publishes` (libraries are) |

**Follow-up (tracked, not blocking Phase C):** if any of these binaries is
meant to be installable via `cargo binstall <name>-dev`, the repo's
`publishes` list must include the binary crate name first. That's a separate
manifest change (owner: each repo maintainer).

## Discrepancies reconciled from the original plan

The initial Phase C draft listed crate names that do not match the actual
`[package].name` values. Corrections applied here:

| Plan draft said | Actual crate name | Lives in | Notes |
|---|---|---|---|
| `greentic-provision-cli` | `greentic-provision` | `crates/greentic-provision-cli` | dir name ≠ crate name |
| `greentic-dw-cli` | `greentic-dw` | `greentic-dw` (top-level) | `greentic-dw-cli` is a *library* sibling |
| `gx` | `greentic-x` | `crates/gx` | dir name ≠ crate name |
| `gca-cli` | `greentic-coding-agent` | `crates/gca-cli` | dir name ≠ crate name |
| `qa-cli` | `greentic-qa` | `crates/qa-cli` | dir name ≠ crate name |
| `greentic` (2 `[[bin]]`) | `gtc` with 1 `[[bin]]` | `greentic/` | plan overcounted bin blocks |
| — | `greentic-mcp-exec` | `greentic-mcp/crates/mcp-exec` | second published binary crate in the same repo, missed by the draft |

## Changelog

- **2026-04-27** — Refreshed table after `greentic-deployer` and `greentic-dwbase` (cli/node/pack-runner) were classified in `REPO_MANIFEST.toml` (`greenticai/.github#129`). Total moved from 13 → 17 published binary crates (11 → 12 dual-role, 2 → 5 binary-only). `greentic-coding-agent` added to manifest as no-publish scaffold (binary not on crates.io, only via GitHub releases).
