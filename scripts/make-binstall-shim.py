#!/usr/bin/env python3
"""make-binstall-shim.py — generate a dependency-free binstall shim crate.

Showstopper #1 of the rnd (research) publish lane (greenticai/.github#212).

The research binaries (`greentic-start`, …) get their multi-provider Agentic
Worker via **git deps + a `publish = false` crate** (`greentic-aw-runtime`).
`cargo publish` rejects git deps and cannot resolve a `publish = false` crate,
so the dev-lane bifurcation (`rewrite-binary-name.py`, which *renames* the real
crate but keeps its dependency graph) can never publish `<crate>-rnd` to
crates.io — `cargo publish` fails every time.

This script takes the opposite approach (Vlad's "Option A"): instead of
shipping the real crate, it generates a **brand-new, dependency-free shim
crate** named `<crate>-<suffix>` that carries ONLY:
  - the `[package]` identity (name/version/edition/license/…)
  - the `[package.metadata.binstall]` block pointing at the GitHub-release
    archive that `rnd-release-binaries.yml` already built
  - a trivial `src/main.rs` so `cargo publish` has something to compile

`cargo binstall <crate>-<suffix> --version <v>` then resolves the binstall
metadata from crates.io and downloads the real binary from the GH release. The
published *source* is never used — only the metadata is.

Usage:
    make-binstall-shim.py --crate <name> --suffix rnd --version <X.Y.Z-research> \\
        --workdir <repo-root> --out <out-dir> [--manifest-path <Cargo.toml>]

Writes the shim crate to `<out>/<crate>-<suffix>/` (Cargo.toml + src/main.rs)
and prints that path. Idempotent: re-running overwrites the staged shim.
"""

from __future__ import annotations

import argparse
import sys
import tomllib
from pathlib import Path

# Default binstall block, used only when the source crate declares none. Mirrors
# rewrite-binary-name.py's default and the archive layout produced by
# rnd-release-binaries.yml: `<name>-v<version>-<target>.tgz`. `{ name }` resolves
# to the shim's package name (`<crate>-<suffix>`) at binstall time, so the URL
# lines up with the renamed release archives without any extra substitution.
DEFAULT_TARGETS = [
    "x86_64-unknown-linux-gnu",
    "aarch64-unknown-linux-gnu",
    "x86_64-apple-darwin",
    "aarch64-apple-darwin",
    "x86_64-pc-windows-msvc",
    "aarch64-pc-windows-msvc",
]


def _find_manifest(workdir: Path, crate: str, explicit: str | None) -> Path:
    """Locate the Cargo.toml whose [package].name == crate."""
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise SystemExit(f"--manifest-path {path} does not exist")
        return path
    for manifest in sorted(workdir.rglob("Cargo.toml")):
        if "target" in manifest.parts:
            continue
        try:
            data = tomllib.loads(manifest.read_text())
        except (tomllib.TOMLDecodeError, OSError):
            continue
        if data.get("package", {}).get("name") == crate:
            return manifest
    raise SystemExit(
        f"no Cargo.toml with [package].name == '{crate}' found under {workdir}"
    )


def _toml_str(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _render_binstall(binstall: dict) -> list[str]:
    """Render a [package.metadata.binstall] table from a parsed dict."""
    lines = ["[package.metadata.binstall]"]
    scalars = ("pkg-url", "pkg-fmt", "bin-dir", "disabled-strategies")
    for key in scalars:
        if key in binstall and isinstance(binstall[key], str):
            lines.append(f"{key} = {_toml_str(binstall[key])}")
    targets = binstall.get("targets") or DEFAULT_TARGETS
    rendered_targets = ",\n  ".join(_toml_str(t) for t in targets)
    lines.append(f"targets = [\n  {rendered_targets},\n]")
    # Per-target overrides (e.g. windows zip), preserved verbatim where simple.
    overrides = binstall.get("overrides")
    if isinstance(overrides, dict):
        for target, table in overrides.items():
            lines.append(f"\n[package.metadata.binstall.overrides.{_toml_str(target)}]")
            for k, v in table.items():
                if isinstance(v, str):
                    lines.append(f"{k} = {_toml_str(v)}")
    return lines


def _default_binstall() -> list[str]:
    lines = [
        "[package.metadata.binstall]",
        'pkg-url = "{ repo }/releases/download/v{ version }/{ name }-v{ version }-{ target }.tgz"',
        'pkg-fmt = "tgz"',
        'bin-dir = "{ name }-v{ version }-{ target }/{ bin }{ binary-ext }"',
    ]
    rendered_targets = ",\n  ".join(_toml_str(t) for t in DEFAULT_TARGETS)
    lines.append(f"targets = [\n  {rendered_targets},\n]")
    return lines


def _is_workspace_inherit(value) -> bool:
    """True for `field = { workspace = true }` (incl. `field.workspace = true`)."""
    return isinstance(value, dict) and value.get("workspace") is True


def _find_workspace_package(manifest: Path, workdir: Path) -> dict:
    """Nearest ancestor's [workspace.package] table (bounded by workdir), or {}.

    Walks up from the source manifest to resolve `field.workspace = true`
    inheritance, the same way rewrite-binary-name.py does for the dev lane. A
    standalone crate with no [workspace] ancestor (e.g. greentic-start) yields {}.
    """
    workdir = workdir.resolve()
    start = manifest.resolve().parent
    for d in (start, *start.parents):
        candidate = d / "Cargo.toml"
        if candidate.is_file():
            try:
                data = tomllib.loads(candidate.read_text())
            except (tomllib.TOMLDecodeError, OSError):
                data = {}
            ws = data.get("workspace")
            if isinstance(ws, dict):
                pkg = ws.get("package")
                return pkg if isinstance(pkg, dict) else {}
        if d == workdir:
            break
    return {}


def _resolve_field(pkg: dict, ws_pkg: dict, field: str):
    """Resolve a [package] field that may be literal or `field.workspace = true`."""
    value = pkg.get(field)
    if isinstance(value, str):
        return value
    if _is_workspace_inherit(value):
        ws_value = ws_pkg.get(field)
        if isinstance(ws_value, str):
            return ws_value
    return None


def build_shim(crate: str, suffix: str, version: str, manifest: Path, workdir: Path) -> str:
    """Return the shim crate's Cargo.toml contents."""
    src = tomllib.loads(manifest.read_text())
    pkg = src.get("package", {})
    ws_pkg = _find_workspace_package(manifest, workdir)
    shim_name = f"{crate}-{suffix}"

    # Resolve fields that may be inherited via `field.workspace = true`. The dev
    # lane's binary crates (e.g. greentic-pack) inherit license/edition from
    # [workspace.package]; without this the shim would omit `license` and
    # crates.io rejects the publish ("missing or empty metadata fields").
    edition = _resolve_field(pkg, ws_pkg, "edition") or "2021"
    repository = _resolve_field(pkg, ws_pkg, "repository")
    homepage = _resolve_field(pkg, ws_pkg, "homepage")
    description = (
        _resolve_field(pkg, ws_pkg, "description")
        or f"binstall shim for {crate} (research channel)"
    )
    license = _resolve_field(pkg, ws_pkg, "license")
    if license is None:
        raise SystemExit(
            f"{crate}: cannot resolve a `license` (neither a literal string nor "
            f"`license.workspace = true` with a workspace value). crates.io rejects "
            f"a publish without `license`/`license-file` — set one on the source crate."
        )

    binstall = pkg.get("metadata", {}).get("binstall")
    binstall_lines = (
        _render_binstall(binstall) if isinstance(binstall, dict) else _default_binstall()
    )

    lines = [
        "# AUTO-GENERATED by make-binstall-shim.py — do not edit.",
        "# Dependency-free shim: carries only binstall metadata so",
        f"# `cargo binstall {shim_name}` fetches the GitHub-release binary.",
        "[package]",
        f"name = {_toml_str(shim_name)}",
        f"version = {_toml_str(version)}",
        f"edition = {_toml_str(edition)}",
        f"description = {_toml_str(description)}",
    ]
    lines.append(f"license = {_toml_str(license)}")
    if isinstance(repository, str):
        lines.append(f"repository = {_toml_str(repository)}")
    if isinstance(homepage, str):
        lines.append(f"homepage = {_toml_str(homepage)}")
    # publish must be allowed (the source crate may set publish=false on its
    # binary; the shim is explicitly publishable).
    lines.append("publish = true")
    lines.append("")
    lines.extend(binstall_lines)
    lines.append("")
    # Empty [workspace] so `cargo publish` treats the staged shim as a
    # standalone package even when it sits under a workspace repo's target/
    # dir. Without it, cargo errors "current package believes it's in a
    # workspace" for repos like greentic-pack/greentic-runner that have a root
    # [workspace]. Mirrors the dev-lane bifurcation precedent
    # (rewrite-binary-name.py writes an empty [workspace] into its staged copy).
    lines.append("[workspace]")
    lines.append("")
    return "\n".join(lines) + "\n"


SHIM_MAIN = """\
//! AUTO-GENERATED binstall shim — never run.
//!
//! This crate exists only to carry `[package.metadata.binstall]` on crates.io
//! so `cargo binstall` can resolve and download the real binary from the
//! GitHub release. The published source is never executed.
fn main() {
    eprintln!(
        "This is a binstall shim. Install the real binary with: \\
cargo binstall {} --version {}",
        env!("CARGO_PKG_NAME"),
        env!("CARGO_PKG_VERSION"),
    );
    std::process::exit(1);
}
"""


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a binstall shim crate.")
    parser.add_argument("--crate", required=True, help="source crate name")
    parser.add_argument("--suffix", default="rnd", help="alias suffix (default: rnd)")
    parser.add_argument("--version", required=True, help="shim version (e.g. 1.2.0-research.1)")
    parser.add_argument("--workdir", default=".", help="repo root to search for Cargo.toml")
    parser.add_argument("--out", required=True, help="output directory for the shim crate")
    parser.add_argument("--manifest-path", default=None, help="explicit source Cargo.toml")
    args = parser.parse_args()

    workdir = Path(args.workdir).resolve()
    manifest = _find_manifest(workdir, args.crate, args.manifest_path)
    shim_toml = build_shim(args.crate, args.suffix, args.version, manifest, workdir)

    shim_dir = Path(args.out).resolve() / f"{args.crate}-{args.suffix}"
    (shim_dir / "src").mkdir(parents=True, exist_ok=True)
    (shim_dir / "Cargo.toml").write_text(shim_toml)
    (shim_dir / "src" / "main.rs").write_text(SHIM_MAIN)

    print(shim_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
