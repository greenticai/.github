#!/usr/bin/env python3
"""Stamp publishable inner-crate Cargo.toml versions with the dev RUN_ID.

The dev-publish workflow's main stamping step rewrites every Cargo.toml whose
`version = "<BASE>"` matches the top-level crate's base. That handles
single-package repos and multi-crate workspaces that share a single
`[workspace.package].version` (every member inherits via
`version.workspace = true`).

It misses the case where a single-package workspace contains a *separately
publishable* inner crate on an independent version cadence — e.g.
`greentic-deployer` (base `1.1.0-dev.0`) carries `crates/greentic-deploy-spec`
(base `0.1.0`). The inner crate's version doesn't match `<BASE>`, the find/sed
loop skips it, and the publish step then warns "already exists, skipping",
producing a top-level crate that references symbols missing from the inner
crate's published version.

This script bridges that gap. For each crate name in `--crates`:

  * Locate the Cargo.toml whose `[package].name` matches.
  * Read the current `[package].version`. If it's already the workflow's
    pre-computed `--dev-version`, skip (the find/sed pass already stamped it).
  * If `version.workspace = true` or `version = { workspace = true }`, the
    crate inherits — skip (workspace-package version was already stamped).
  * Otherwise rebuild a stamped version using the same rules as
    dev-prepare's compute-version step:
      - `M.m.p-dev.N`  →  `M.m.p-dev.{RUN_ID}`   (preserves pre-release)
      - `M.m.p`        →  `M.m.{RUN_ID}`         (regular release)
    Anything else is an error.
  * Rewrite the version line in place with format-preserving tomlkit.

Usage::

    stamp-inner-crates.py \\
        --crates "greentic-deploy-spec greentic-deployer" \\
        --dev-version 1.1.0-dev.26081289707 \\
        --run-id 26081289707

The `--crates` order is irrelevant; the script processes each independently.
Pass the same value as the workflow's `inputs.crates`.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import tomlkit

# Same forms accepted by dev-prepare's compute-version step.
_PRE_RELEASE_RE = re.compile(r"^(?P<mmp>\d+\.\d+\.\d+)-dev\.\d+$")
_REGULAR_RE = re.compile(r"^(?P<mm>\d+\.\d+)\.\d+$")

# Walk excludes — mirror the rest of the .github tooling.
# `.packc` holds packc's generated component crate (e.g.
# greentic-pack/examples/qa-demo/.packc/pack_component) and is gitignored
# ecosystem-wide; without the exclusion, a committed-by-mistake generator
# dump (or a local build) shadows the real publishable crate by name.
EXCLUDED_DIR_PARTS = frozenset({"target", ".git", "node_modules", ".venv", ".packc"})


def _find_crate_manifest(root: Path, crate: str) -> Path:
    """Return the unique Cargo.toml whose `[package].name == crate`.

    Raises FileNotFoundError if missing, RuntimeError if duplicated.
    """
    matches: list[Path] = []
    for p in root.rglob("Cargo.toml"):
        if any(part in EXCLUDED_DIR_PARTS for part in p.relative_to(root).parts):
            continue
        try:
            doc = tomlkit.parse(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        pkg = doc.get("package")
        if not isinstance(pkg, dict):
            continue
        name = pkg.get("name")
        if name == crate:
            matches.append(p)
    if not matches:
        raise FileNotFoundError(
            f"no Cargo.toml with [package].name == {crate!r} under {root}"
        )
    if len(matches) > 1:
        raise RuntimeError(
            f"expected exactly one Cargo.toml with [package].name == {crate!r}, "
            f"found {len(matches)}: {[str(p) for p in matches]}"
        )
    return matches[0]


def _stamp_version(current: str, run_id: str) -> str:
    """Bump *current* with *run_id* using dev-prepare's stamping rules.

    Raises ValueError on unsupported forms.
    """
    m = _PRE_RELEASE_RE.match(current)
    if m is not None:
        return f"{m.group('mmp')}-dev.{run_id}"
    m = _REGULAR_RE.match(current)
    if m is not None:
        return f"{m.group('mm')}.{run_id}"
    raise ValueError(
        f"version {current!r} is not on supported form 'M.m.p' or 'M.m.p-dev.N'"
    )


def stamp_crate(
    crate: str, root: Path, dev_version: str, run_id: str
) -> tuple[Path, str | None, str | None]:
    """Stamp *crate* under *root*. Returns (path, old_version, new_version).

    new_version is None when no rewrite happened (already stamped, or
    version inherits from workspace).
    """
    manifest = _find_crate_manifest(root, crate)
    doc = tomlkit.parse(manifest.read_text(encoding="utf-8"))
    pkg = doc.get("package")
    if not isinstance(pkg, dict):
        raise RuntimeError(f"{manifest}: no [package] table")
    current = pkg.get("version")
    if current is None:
        return (manifest, None, None)
    if isinstance(current, dict):
        # `version = { workspace = true }` form.
        if current.get("workspace"):
            return (manifest, "<workspace>", None)
        raise RuntimeError(
            f"{manifest}: unsupported version shape {current!r} (expected string or {{workspace=true}})"
        )
    if not isinstance(current, str):
        raise RuntimeError(
            f"{manifest}: unsupported version type {type(current).__name__}"
        )
    if current == dev_version:
        # Already stamped by the workflow's main find/sed pass (the inner
        # crate happened to share BASE with the top-level).
        return (manifest, current, None)
    stamped = _stamp_version(current, run_id)
    if stamped == current:
        return (manifest, current, None)
    pkg["version"] = stamped
    manifest.write_text(tomlkit.dumps(doc), encoding="utf-8")
    return (manifest, current, stamped)


def main() -> None:
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument(
        "--crates",
        required=True,
        help="Space-separated list of [package].name values to stamp (same as workflow input)",
    )
    parser.add_argument(
        "--dev-version",
        required=True,
        help="Workflow's pre-computed dev version (top-level crate's stamped form)",
    )
    parser.add_argument(
        "--run-id",
        required=True,
        help="Numeric GITHUB_RUN_ID used to stamp inner-crate versions",
    )
    parser.add_argument(
        "--root",
        default=".",
        help="Repo root to scan (default: cwd)",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    if not root.is_dir():
        print(f"error: {root} is not a directory", file=sys.stderr)
        sys.exit(2)

    crates = [c for c in args.crates.split() if c]
    if not crates:
        print("no crates supplied; nothing to do.")
        return

    any_changes = False
    for crate in crates:
        try:
            manifest, old, new = stamp_crate(crate, root, args.dev_version, args.run_id)
        except (FileNotFoundError, RuntimeError, ValueError) as exc:
            print(f"::error::{crate}: {exc}", file=sys.stderr)
            sys.exit(1)
        rel = manifest.relative_to(root)
        if new is None:
            if old == "<workspace>":
                print(f"  {crate}: inherits via workspace ({rel}) — no stamp needed")
            elif old == args.dev_version:
                print(f"  {crate}: already at {old} ({rel}) — no stamp needed")
            else:
                print(f"  {crate}: version line absent or unchanged ({rel})")
        else:
            any_changes = True
            print(f"  stamped {crate}: {old} → {new} ({rel})")

    if not any_changes:
        print("No inner-crate stamps needed.")


if __name__ == "__main__":
    main()
