#!/usr/bin/env python3
"""assert-branch-invariants.py — Push-time guardrail for branch invariants.

Two lanes, two posture levels:

main lane (FAIL — exit 1):
  * No `Cargo.toml` may have `[package].version` or `[workspace.package].version`
    matching `*-dev.*`. The dev lane uses pre-release suffix `M.m.p-dev.{RUN_ID}`
    on libraries; that suffix must never reach `main`.
  * No `Cargo.toml` may have `[package].name = "<base>-dev"` where `<base>` is a
    known binary-crate basename in REPO_MANIFEST.toml. The `-dev` alias is
    applied at publish time by `rewrite-binary-name.py` against
    `target/bifurcate/<name>-dev/Cargo.toml`; the in-tree name on `main` must
    stay as `<base>`.

develop lane (WARN — non-fatal `::warning::`):
  * For binary-bifurcated repos, the *base* name (e.g., `dwbase-cli`) should
    appear in some Cargo.toml under develop. If only `<base>-dev` is present,
    the rewrite was accidentally committed to develop — `forward-port.sh` will
    flip it back to `<base>` next cycle, but the next nightly publish from
    develop will fail or land under the wrong name in the meantime.
  * Pre-release version suffix is allowed and expected on develop, so we do
    NOT check version on this lane.

Used by .github/workflows/assert-branch-invariants.yml as a push/PR guard in
each repo. The reusable workflow checks out the caller + greenticai/.github
(for manifest), then invokes this script.

Inputs (CLI):
  --lane             {main,develop}     required
  --repo-name        <name>             required (matches REPO_MANIFEST keys)
  --root             <path>             working tree to scan
  --manifest         <path>             REPO_MANIFEST.toml location
"""
from __future__ import annotations

import argparse
import sys
import tomllib
from pathlib import Path

SKIP_DIR_NAMES = {"target", "node_modules", ".git", "_meta", "_caller"}
DEV_SUFFIX_MARKER = "-dev."


def find_cargo_tomls(root: Path):
    for p in root.rglob("Cargo.toml"):
        if any(part in SKIP_DIR_NAMES for part in p.relative_to(root).parts):
            continue
        yield p


def get_binary_basenames(manifest: Path, repo_name: str) -> list[str]:
    with manifest.open("rb") as f:
        data = tomllib.load(f)
    entry = data.get("repos", {}).get(repo_name, {})
    return list(entry.get("binary-crates", []) or [])


def _load_toml(path: Path) -> dict | None:
    try:
        with path.open("rb") as f:
            return tomllib.load(f)
    except tomllib.TOMLDecodeError:
        return None


def check_main(root: Path, manifest: Path, repo_name: str) -> int:
    basenames = get_binary_basenames(manifest, repo_name)
    forbidden_names = {f"{b}-dev" for b in basenames}
    errors: list[str] = []

    for cargo in find_cargo_tomls(root):
        rel = cargo.relative_to(root)
        data = _load_toml(cargo)
        if data is None:
            errors.append(f"{rel}: failed to parse")
            continue

        pkg = data.get("package") or {}
        ws_pkg = (data.get("workspace") or {}).get("package") or {}

        version = pkg.get("version")
        if isinstance(version, str) and DEV_SUFFIX_MARKER in version:
            errors.append(
                f"{rel}: [package].version = {version!r} contains "
                f"'{DEV_SUFFIX_MARKER}' — pre-release leaked onto main"
            )

        ws_version = ws_pkg.get("version")
        if isinstance(ws_version, str) and DEV_SUFFIX_MARKER in ws_version:
            errors.append(
                f"{rel}: [workspace.package].version = {ws_version!r} contains "
                f"'{DEV_SUFFIX_MARKER}' — pre-release leaked onto main"
            )

        name = pkg.get("name")
        if isinstance(name, str) and name in forbidden_names:
            errors.append(
                f"{rel}: [package].name = {name!r} is the dev-lane alias — "
                f"main must hold the base name (likely '{name[:-4]}')"
            )

    if errors:
        for e in errors:
            file_part = e.split(":", 1)[0]
            print(f"::error file={file_part}::{e}")
        print(
            f"\n{len(errors)} main-lane invariant violation(s) in {repo_name}",
            file=sys.stderr,
        )
        return 1

    print(f"OK main-lane invariants hold for {repo_name}")
    return 0


def check_develop(root: Path, manifest: Path, repo_name: str) -> int:
    basenames = get_binary_basenames(manifest, repo_name)
    if not basenames:
        print(f"OK develop-lane: {repo_name} is not binary-bifurcated, no checks")
        return 0

    forbidden_names = {f"{b}-dev" for b in basenames}
    found_basenames: set[str] = set()
    leaked_aliases: list[str] = []

    for cargo in find_cargo_tomls(root):
        rel = cargo.relative_to(root)
        data = _load_toml(cargo)
        if data is None:
            continue
        name = (data.get("package") or {}).get("name")
        if not isinstance(name, str):
            continue
        if name in basenames:
            found_basenames.add(name)
        if name in forbidden_names:
            leaked_aliases.append(
                f"{rel}: [package].name = {name!r} on develop — this is the "
                f"dev-lane alias; the base name '{name[:-4]}' is what should "
                f"be committed (rewrite happens at publish time, not in-tree)"
            )

    warnings: list[str] = list(leaked_aliases)
    for missing in sorted(set(basenames) - found_basenames):
        warnings.append(
            f"binary-crate basename {missing!r} declared in REPO_MANIFEST.toml "
            f"but no Cargo.toml under develop exposes [package].name = "
            f"{missing!r} — manifest and tree disagree"
        )

    for w in warnings:
        print(f"::warning::{w}")
    if not warnings:
        print(f"OK develop-lane invariants hold for {repo_name}")
    return 0  # warnings are non-fatal on develop


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--lane", required=True, choices=["main", "develop"])
    ap.add_argument("--repo-name", required=True, help="Key in REPO_MANIFEST.toml")
    ap.add_argument("--root", required=True, type=Path, help="Working tree to scan")
    ap.add_argument("--manifest", required=True, type=Path, help="REPO_MANIFEST.toml path")
    args = ap.parse_args(argv)

    if not args.root.is_dir():
        print(f"::error::--root {args.root} is not a directory", file=sys.stderr)
        return 2
    if not args.manifest.is_file():
        print(f"::error::--manifest {args.manifest} not found", file=sys.stderr)
        return 2

    if args.lane == "main":
        return check_main(args.root, args.manifest, args.repo_name)
    return check_develop(args.root, args.manifest, args.repo_name)


if __name__ == "__main__":
    sys.exit(main())
