#!/usr/bin/env python3
"""Stamp the version a release binary is BUILT with.

`dev-release-binaries.yml` names its archives `<crate>-dev-v<version>-<target>`
and tags the GitHub Release `v<version>`, but it used to build straight from
the committed Cargo.toml — which on `develop` carries the base version
(`1.2.0-dev.0`), never the stamped one. `dev-publish.yml` stamps Cargo.toml
only inside its own job, for `cargo publish`; the binary jobs never saw that
edit. So every dev-channel binary reported `--version` = `1.2.0-dev.0` while
its archive, its release tag and the gtc dev manifest all said
`1.2.<run-id>`. Anything that gates on the version a binary REPORTS (the
designer's greentic-pack floor, gtc's "already installed" check) read the
wrong number, with nothing red anywhere.

This script rewrites `[package].version` of exactly one package — the one
being built — to `--version`, so `CARGO_PKG_VERSION` (and therefore
`--version`) agrees with the archive name. It deliberately does NOT touch
sibling crates: their versions are not part of the shipped binary's banner,
and leaving them alone keeps path-dependency requirements between siblings
exactly as committed.

Handled forms of the version key inside `[package]`:

  * ``version.workspace = true``
  * ``version = { workspace = true }``
  * ``version = "<anything>"``
  * no version key at all (inserted after ``name``)

The package's manifest is located with ``cargo metadata --no-deps``, so
workspace membership and exclusions are cargo's own answer, not a filesystem
walk. After rewriting, the same query is repeated and the script fails unless
cargo now reports the requested version — an unhandled manifest shape fails
here, loudly, rather than shipping another mislabelled binary.

Stdlib only: it runs on every build leg, Windows and macOS included, where no
pip install happens.

Usage::

    stamp-binary-version.py --package greentic-pack --version 1.2.34173134336
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

_TABLE_HEADER_RE = re.compile(r"^\s*\[\[?\s*([^\[\]]+?)\s*\]\]?\s*(#.*)?$")
_VERSION_KEY_RE = re.compile(r"^\s*version\s*(\.|=)")
_NAME_KEY_RE = re.compile(r"^\s*name\s*=")
_SEMVER_RE = re.compile(
    r"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"
)


def _cargo_metadata(workdir: Path) -> dict:
    result = subprocess.run(
        ["cargo", "metadata", "--no-deps", "--format-version", "1"],
        cwd=workdir,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(
            f"error: `cargo metadata` failed in {workdir}:\n{result.stderr}"
        )
    return json.loads(result.stdout)


def _find_package(metadata: dict, package: str) -> dict:
    matches = [p for p in metadata.get("packages", []) if p.get("name") == package]
    if len(matches) != 1:
        raise SystemExit(
            f"error: expected exactly one workspace package named {package!r}, "
            f"found {len(matches)}"
        )
    return matches[0]


def stamp_manifest_text(text: str, version: str) -> str:
    """Return `text` with `[package].version` set to `version`.

    Raises ValueError when the manifest has no `[package]` table or uses a
    shape this function does not rewrite (e.g. a `[package.version]` table).
    """
    lines = text.splitlines(keepends=True)
    current_table: str | None = None
    package_seen = False
    version_idx: int | None = None
    name_idx: int | None = None

    for idx, line in enumerate(lines):
        header = _TABLE_HEADER_RE.match(line)
        if header:
            current_table = header.group(1).strip()
            if current_table == "package":
                package_seen = True
            elif current_table == "package.version":
                raise ValueError(
                    "a `[package.version]` table is not a supported version form"
                )
            continue
        if current_table != "package":
            continue
        if _VERSION_KEY_RE.match(line):
            if version_idx is not None:
                raise ValueError("`[package]` declares `version` more than once")
            version_idx = idx
        elif _NAME_KEY_RE.match(line) and name_idx is None:
            name_idx = idx

    if not package_seen:
        raise ValueError("manifest has no `[package]` table")

    newline = "\r\n" if "\r\n" in text else "\n"
    stamped = f'version = "{version}"{newline}'
    if version_idx is not None:
        lines[version_idx] = stamped
    elif name_idx is not None:
        lines.insert(name_idx + 1, stamped)
    else:
        raise ValueError("`[package]` has neither `version` nor `name`")
    return "".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--package", required=True, help="cargo package name to stamp")
    parser.add_argument("--version", required=True, help="version to stamp it with")
    parser.add_argument(
        "--workdir", default=".", help="workspace directory (default: cwd)"
    )
    args = parser.parse_args(argv)

    if not _SEMVER_RE.match(args.version):
        print(f"error: {args.version!r} is not a semver version", file=sys.stderr)
        return 1

    workdir = Path(args.workdir).resolve()
    pkg = _find_package(_cargo_metadata(workdir), args.package)
    manifest = Path(pkg["manifest_path"])
    before = pkg.get("version")

    try:
        text = manifest.read_text(encoding="utf-8")
        manifest.write_text(stamp_manifest_text(text, args.version), encoding="utf-8")
    except ValueError as err:
        print(f"error: {manifest}: {err}", file=sys.stderr)
        return 1

    after = _find_package(_cargo_metadata(workdir), args.package).get("version")
    if after != args.version:
        print(
            f"error: {manifest}: cargo reports {args.package} {after!r} after "
            f"stamping, expected {args.version!r}",
            file=sys.stderr,
        )
        return 1

    print(f"stamped {args.package}: {before} -> {after} ({manifest})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
