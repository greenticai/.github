#!/usr/bin/env python3
"""rewrite-binary-name.py — Rename a binary crate for dev-lane publish.

Implements Phase C.1 of plans/binary-bifurcation.md. Used by dev-publish.yml
(Phase C.2, next PR) to publish `<crate>-dev` alongside the stable `<crate>`
without touching the committed Cargo.toml on `develop`.

Usage:
    rewrite-binary-name.py --crate <name> --suffix dev --workdir <path> [--dual-role]

Binary-only mode (no --dual-role):
    In-place rewrite of the Cargo.toml whose [package].name == <crate>. Only
    the [package].name and any [[bin]].name that equals <crate> are touched.
    Other tables (dependencies, [lib], [package.metadata.binstall], etc.) are
    left alone.

Dual-role mode (--dual-role):
    Stage a copy of the crate directory at
    <workdir>/target/bifurcate/<crate>-<suffix>/ and apply the same rewrite
    to the copy. The original tree stays intact so the library keeps
    publishing under <crate>.

Idempotent: if [package].name already equals <crate>-<suffix>, exits 0
without touching anything.

The rewrite intentionally does NOT touch:
  - [lib] name (Rust identifier; crate consumers use it via `use <lib_name>::`,
    so renaming would break internal imports)
  - [package.metadata.binstall] pkg-url / bin-dir templates — these use
    { name } placeholders that resolve at install time; literal crate-name
    references would only matter once `cargo binstall <crate>-dev` is
    supported on the dev lane (Phase C.5, deferred)
  - [dependencies.<crate>] sub-tables (would be a rename, not what we want)
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import tomllib
from pathlib import Path

EXCLUDED_PATH_PARTS = {"target", ".git", "node_modules", ".venv"}


def find_crate_manifest(workdir: Path, crate: str, new_name: str) -> Path:
    """Return the Cargo.toml whose [package].name is crate or new_name.

    Accepting either value makes the script idempotent: a second invocation on
    an already-rewritten tree still locates the right manifest and no-ops.
    """
    matches: list[Path] = []
    for manifest in workdir.rglob("Cargo.toml"):
        if any(part in EXCLUDED_PATH_PARTS for part in manifest.parts):
            continue
        try:
            with manifest.open("rb") as fh:
                data = tomllib.load(fh)
        except (tomllib.TOMLDecodeError, OSError):
            continue
        if data.get("package", {}).get("name") in (crate, new_name):
            matches.append(manifest)
    if not matches:
        sys.exit(
            f"error: no Cargo.toml with [package].name in ('{crate}', '{new_name}') found under {workdir}"
        )
    if len(matches) > 1:
        joined = "\n  ".join(str(m) for m in matches)
        sys.exit(
            f"error: multiple Cargo.toml candidates for crate '{crate}':\n  {joined}"
        )
    return matches[0]


def _rewrite_text(text: str, crate: str, new_name: str) -> str:
    """Rewrite [package].name and matching [[bin]].name in-line.

    State machine: track the current table header; only rewrite when inside
    [package] (exactly, not a sub-table) or inside any [[bin]] block where
    the block's `name` key matches <crate>.
    """
    header_table = re.compile(r"^\[([^\[\]]+)\]\s*(?:#.*)?$")
    header_aot = re.compile(r"^\[\[([^\[\]]+)\]\]\s*(?:#.*)?$")
    name_line = re.compile(
        r'^(?P<prefix>\s*name\s*=\s*)"' + re.escape(crate) + r'"(?P<suffix>.*)$'
    )

    lines = text.splitlines(keepends=True)
    current_table = ""
    current_is_aot = False
    current_aot_kind = ""

    def in_target_section() -> bool:
        if current_is_aot and current_aot_kind == "bin":
            return True
        return (not current_is_aot) and current_table == "package"

    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue
        m = header_aot.match(stripped)
        if m:
            current_is_aot = True
            current_aot_kind = m.group(1).strip()
            continue
        m = header_table.match(stripped)
        if m:
            current_is_aot = False
            current_table = m.group(1).strip()
            continue
        if not in_target_section():
            continue
        body = line.rstrip("\n")
        has_newline = line.endswith("\n")
        m = name_line.match(body)
        if not m:
            continue
        lines[i] = m.group("prefix") + f'"{new_name}"' + m.group("suffix") + (
            "\n" if has_newline else ""
        )

    return "".join(lines)


def rewrite_manifest(manifest: Path, crate: str, new_name: str) -> bool:
    """Rewrite manifest in place. Return True if changed, False if idempotent."""
    original = manifest.read_text()
    with manifest.open("rb") as fh:
        data = tomllib.load(fh)
    current_name = data.get("package", {}).get("name")
    if current_name == new_name:
        print(
            f"[rewrite-binary-name] {manifest}: [package].name already '{new_name}', no-op",
            file=sys.stderr,
        )
        return False
    if current_name != crate:
        sys.exit(
            f"error: {manifest} has [package].name == '{current_name}', "
            f"expected '{crate}' or '{new_name}'"
        )

    new_text = _rewrite_text(original, crate, new_name)
    if new_text == original:
        sys.exit(
            f"error: {manifest} parses with [package].name == '{crate}' but "
            f"text rewrite produced no change (unusual TOML layout?)"
        )

    # If the crate auto-discovers a binary from src/bin/<crate>.rs (no matching
    # [[bin]] block), cargo names the installed binary after the file stem, not
    # [package].name. We want ~/.cargo/bin/<crate>-dev, not ~/.cargo/bin/<crate>.
    # Append an explicit [[bin]] block so the renamed binary wins.
    new_text = _inject_bin_override_if_needed(new_text, manifest, crate, new_name)

    new_data = tomllib.loads(new_text)
    rewritten = new_data.get("package", {}).get("name")
    if rewritten != new_name:
        sys.exit(
            f"error: rewrite of {manifest} produced [package].name == '{rewritten}', "
            f"expected '{new_name}'"
        )

    manifest.write_text(new_text)
    return True


def _inject_bin_override_if_needed(
    text: str, manifest: Path, crate: str, new_name: str
) -> str:
    """Add `[[bin]] name = new_name, path = src/bin/<crate>.rs` if needed.

    Required for crates that auto-discover their binary from src/bin/<crate>.rs
    without a [[bin]] block (e.g. greentic-flow, greentic-mcp). Without this,
    `cargo install <crate>-dev` produces a binary literally named <crate>.
    """
    bin_file = manifest.parent / "src" / "bin" / f"{crate}.rs"
    if not bin_file.is_file():
        return text

    data = tomllib.loads(text)
    existing_bins = {b.get("name") for b in data.get("bin", []) if isinstance(b, dict)}
    if new_name in existing_bins:
        return text

    # Append as a fresh table. Keep the path relative to the manifest dir.
    separator = "" if text.endswith("\n\n") else ("\n" if text.endswith("\n") else "\n\n")
    appended = (
        f'{separator}[[bin]]\n'
        f'name = "{new_name}"\n'
        f'path = "src/bin/{crate}.rs"\n'
    )
    return text + appended


def stage_dual_role_copy(manifest: Path, new_name: str, workdir: Path) -> Path:
    """Copy the crate directory to <workdir>/target/bifurcate/<new_name>/.

    Returns the path to the copied Cargo.toml so the caller can rewrite it.
    """
    src_dir = manifest.parent
    dest_dir = workdir / "target" / "bifurcate" / new_name

    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    dest_dir.parent.mkdir(parents=True, exist_ok=True)

    def _ignore(_: str, names: list[str]) -> list[str]:
        return [n for n in names if n in EXCLUDED_PATH_PARTS]

    shutil.copytree(src_dir, dest_dir, ignore=_ignore, symlinks=True)
    return dest_dir / "Cargo.toml"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Rewrite a binary crate's [package].name + matching [[bin]].name "
            "to a -<suffix> variant for dev-lane publish."
        )
    )
    parser.add_argument("--crate", required=True, help="Base crate name, e.g. 'gtc'")
    parser.add_argument(
        "--suffix", default="dev", help="Suffix to append after a dash (default: dev)"
    )
    parser.add_argument(
        "--workdir", required=True, type=Path, help="Path to repo root or sub-crate dir"
    )
    parser.add_argument(
        "--dual-role",
        action="store_true",
        help="Stage a copy under target/bifurcate/<crate>-<suffix>/ and rewrite the copy",
    )
    args = parser.parse_args(argv)

    workdir = args.workdir.resolve()
    if not workdir.is_dir():
        sys.exit(f"error: --workdir '{workdir}' is not a directory")

    new_name = f"{args.crate}-{args.suffix}"
    manifest = find_crate_manifest(workdir, args.crate, new_name)

    if args.dual_role:
        copy_manifest = stage_dual_role_copy(manifest, new_name, workdir)
        changed = rewrite_manifest(copy_manifest, args.crate, new_name)
        print(
            f"[rewrite-binary-name] staged copy at {copy_manifest.parent} "
            f"({'rewrote' if changed else 'no-op'})"
        )
    else:
        changed = rewrite_manifest(manifest, args.crate, new_name)
        print(
            f"[rewrite-binary-name] in-place {manifest} "
            f"({'rewrote' if changed else 'no-op'})"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
