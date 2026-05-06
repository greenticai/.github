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
  - an existing [lib] table — author already opted out of auto-discovery
  - [dependencies.<crate>] sub-tables (would be a rename, not what we want)

When the crate has src/lib.rs but no [lib] table, an explicit
``[lib] name = "<crate>"`` (dash-to-underscore-normalized) is appended. Without
it, cargo derives the lib name from [package].name, so renaming the package to
``<crate>-<suffix>`` silently renames the lib too — breaking ``use <crate>::``
imports in the same crate's bin source. Pinning [lib].name keeps internal
imports resolving after the package rename.

When no [package.metadata.binstall] exists, a default block is appended
pointing at the dev-release-binaries.yml archive layout (Phase C.4). In
``--dual-role`` mode the staged copy's binstall metadata is OVERWRITTEN
unconditionally — author binstall is configured for the stable lane and won't
match dev-release archives, and the original Cargo.toml on develop is
untouched anyway, so we always force the dev-pipeline-compatible layout for
the dev publish.
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import tomllib
from pathlib import Path
from typing import Any

import tomli_w

EXCLUDED_PATH_PARTS = {"target", ".git", "node_modules", ".venv"}

DEP_TABLES = ("dependencies", "dev-dependencies", "build-dependencies")

# Default [package.metadata.binstall] block injected when a crate has no
# binstall metadata. Template variables are resolved by cargo-binstall at
# install time: { repo } from [package].repository, { version } from the
# crate version, { target }/{ bin }/{ binary-ext }/{ archive-suffix } from
# the install context. Archive filename uses { name } (the package name, so
# for the -dev alias it becomes greentic-setup-dev-…tgz) to match what
# dev-release-binaries.yml uploads.
BINSTALL_BLOCK = (
    "[package.metadata.binstall]\n"
    'pkg-url = "{ repo }/releases/download/v{ version }/'
    '{ name }-v{ version }-{ target }{ archive-suffix }"\n'
    'bin-dir = "{ name }-v{ version }-{ target }/{ bin }{ binary-ext }"\n'
    'pkg-fmt = "tgz"\n'
)


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
    """Rewrite [package].name, [package].default-run, and matching [[bin]].name in-line.

    State machine: track the current table header; only rewrite when inside
    [package] (exactly, not a sub-table) or inside any [[bin]] block where
    the block's `name` key matches <crate>.

    `default-run` is rewritten only inside [package] and only when it points
    at <crate>. Without this, renaming the matching [[bin]] from <crate> to
    <new_name> would leave default-run referencing a bin that no longer
    exists, and `cargo` errors with `default-run target '<crate>' not found`.
    """
    header_table = re.compile(r"^\[([^\[\]]+)\]\s*(?:#.*)?$")
    header_aot = re.compile(r"^\[\[([^\[\]]+)\]\]\s*(?:#.*)?$")
    name_line = re.compile(
        r'^(?P<prefix>\s*name\s*=\s*)"' + re.escape(crate) + r'"(?P<suffix>.*)$'
    )
    default_run_line = re.compile(
        r'^(?P<prefix>\s*default-run\s*=\s*)"' + re.escape(crate) + r'"(?P<suffix>.*)$'
    )

    lines = text.splitlines(keepends=True)
    current_table = ""
    current_is_aot = False
    current_aot_kind = ""

    def in_bin_section() -> bool:
        return current_is_aot and current_aot_kind == "bin"

    def in_package_section() -> bool:
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
        body = line.rstrip("\n")
        has_newline = line.endswith("\n")
        if in_bin_section() or in_package_section():
            m = name_line.match(body)
            if m:
                lines[i] = m.group("prefix") + f'"{new_name}"' + m.group("suffix") + (
                    "\n" if has_newline else ""
                )
                continue
        if in_package_section():
            m = default_run_line.match(body)
            if m:
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
    new_text = _rewrite_inline_bin_array_at_root(new_text, crate, new_name)
    if new_text == original:
        sys.exit(
            f"error: {manifest} parses with [package].name == '{crate}' but "
            f"text rewrite produced no change (unusual TOML layout?)"
        )

    # Handle the binary-bins override case: a single [[bin]] (or inline bin)
    # whose name doesn't match [package].name (e.g. crates/dwbase-cli ships
    # `[[bin]] name = "dwbase"`). The rewrites above only renamed bin entries
    # whose name == <crate>, leaving these alone — but dev-release-binaries.yml
    # renames the binary file inside the archive to <crate>-<suffix>, so the
    # published [[bin]].name must match `<crate>-<suffix>` for cargo-binstall
    # to find the file.
    new_text = _rename_single_unmatched_bin(new_text, new_name)

    # If the crate auto-discovers a binary from src/bin/<crate>.rs (no matching
    # [[bin]] block), cargo names the installed binary after the file stem, not
    # [package].name. We want ~/.cargo/bin/<crate>-dev, not ~/.cargo/bin/<crate>.
    # Append an explicit [[bin]] block so the renamed binary wins.
    new_text = _inject_bin_override_if_needed(new_text, manifest, crate, new_name)

    # Pin the auto-discovered lib name so `use <crate>::...` in the same crate's
    # bin source keeps resolving after the [package].name rename. No-op when
    # there's no src/lib.rs or [lib] is already explicit.
    new_text = _inject_lib_override_if_needed(new_text, manifest, crate)

    # Inject default [package.metadata.binstall] pointing at the archive layout
    # produced by dev-release-binaries.yml. Only runs if no binstall metadata
    # is already present — crate-owned overrides win in non-dual-role mode.
    # Dual-role callers force-override later via force_dev_binstall().
    new_text = _inject_binstall_metadata_if_needed(new_text)

    new_data = tomllib.loads(new_text)
    rewritten = new_data.get("package", {}).get("name")
    if rewritten != new_name:
        sys.exit(
            f"error: rewrite of {manifest} produced [package].name == '{rewritten}', "
            f"expected '{new_name}'"
        )

    manifest.write_text(new_text)
    return True


def _rewrite_inline_bin_array_at_root(text: str, crate: str, new_name: str) -> str:
    """Rewrite ``name = "<crate>"`` inside a root-level inline ``bin = [...]`` array.

    Cargo accepts both ``[[bin]]`` (array of tables) and ``bin = [{name = ..., path = ...}]``
    (inline array assigned to the root) for binary targets. ``_rewrite_text``
    only handles the ``[[bin]]`` form; this helper covers the inline form (used
    by the ``gtc`` crate). Without it, the matching ``name`` stays unchanged
    and ``_inject_bin_override_if_needed`` falls back to appending ``[[bin]]``,
    which TOML rejects because ``bin`` is already an inline array.

    Only matches ``bin = [...]`` appearing before the first ``[section]`` /
    ``[[section]]`` header — anything after a header belongs to that table,
    not the root, and is out of scope for binary-target rewriting.
    """
    header_match = re.search(r"^\s*\[\[?[^\[\]\n]+\]\]?\s*(?:#.*)?$", text, re.MULTILINE)
    head_end = header_match.start() if header_match else len(text)
    head = text[:head_end]
    rest = text[head_end:]

    bin_re = re.compile(r"(^\s*bin\s*=\s*\[)([^\[\]]*?)(\])", re.MULTILINE | re.DOTALL)
    name_re = re.compile(r'(name\s*=\s*)"' + re.escape(crate) + r'"')

    def _replace(match: re.Match) -> str:
        prefix, body, suffix = match.group(1), match.group(2), match.group(3)
        new_body, count = name_re.subn(rf'\1"{new_name}"', body, count=1)
        if count == 0:
            return match.group(0)
        return prefix + new_body + suffix

    return bin_re.sub(_replace, head) + rest


def _rename_single_unmatched_bin(text: str, new_name: str) -> str:
    """Rename a single [[bin]].name that wasn't already rewritten.

    Applies when the manifest contains exactly one bin entry (either ``[[bin]]``
    array-of-tables or inline ``bin = [{...}]``) whose name differs from
    ``new_name``. Used to handle the binary-bins override pattern where a crate
    ships a binary under a different name than [package].name (e.g. dwbase-cli
    has ``[[bin]] name = "dwbase"``). The earlier ``_rewrite_text`` /
    ``_rewrite_inline_bin_array_at_root`` only matched names equal to the
    original crate name, so such ``[[bin]].name`` entries pass through unchanged
    and break ``cargo binstall <crate>-dev`` because the published
    ``[[bin]].name`` no longer matches the binary file inside the dev archive
    (which dev-release-binaries.yml renames to ``<crate>-<suffix>``).

    No-op when:
      - no bin entries exist (auto-discovery uses [package].name, already
        renamed; ``_inject_bin_override_if_needed`` may add a [[bin]] block if
        ``src/bin/<crate>.rs`` exists, in which case the appended block
        already has the correct name)
      - the single bin entry already has name == new_name (rewrite handled
        upstream)
      - multiple bin entries exist (we can't safely collapse names to one
        value; multi-bin dev publishes are out of scope and would need
        per-bin handling)

    Also rewrites a matching [package].default-run pointing at the original
    bin name, so cargo doesn't error with ``default-run target not found``.
    """
    data = tomllib.loads(text)
    bins = data.get("bin", [])
    if not isinstance(bins, list) or len(bins) != 1:
        return text
    entry = bins[0]
    if not isinstance(entry, dict):
        return text
    current_name = entry.get("name")
    if not current_name or current_name == new_name:
        return text

    header_table = re.compile(r"^\[([^\[\]]+)\]\s*(?:#.*)?$")
    header_aot = re.compile(r"^\[\[([^\[\]]+)\]\]\s*(?:#.*)?$")
    name_line = re.compile(
        r'^(?P<prefix>\s*name\s*=\s*)"' + re.escape(current_name) + r'"(?P<suffix>.*)$'
    )
    default_run_line = re.compile(
        r'^(?P<prefix>\s*default-run\s*=\s*)"'
        + re.escape(current_name)
        + r'"(?P<suffix>.*)$'
    )

    lines = text.splitlines(keepends=True)
    in_aot = False
    aot_kind = ""
    table = ""
    rewrote_bin_name = False

    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue
        m = header_aot.match(stripped)
        if m:
            in_aot = True
            aot_kind = m.group(1).strip()
            continue
        m = header_table.match(stripped)
        if m:
            in_aot = False
            table = m.group(1).strip()
            continue
        body = line.rstrip("\n")
        has_newline = line.endswith("\n")
        if in_aot and aot_kind == "bin" and not rewrote_bin_name:
            m = name_line.match(body)
            if m:
                lines[i] = (
                    m.group("prefix")
                    + f'"{new_name}"'
                    + m.group("suffix")
                    + ("\n" if has_newline else "")
                )
                rewrote_bin_name = True
                continue
        if (not in_aot) and table == "package":
            m = default_run_line.match(body)
            if m:
                lines[i] = (
                    m.group("prefix")
                    + f'"{new_name}"'
                    + m.group("suffix")
                    + ("\n" if has_newline else "")
                )

    new_text = "".join(lines)

    # Inline `bin = [{name = "<orig>", path = ...}]` form: rewrite the name in
    # the head section before the first table header.
    if not rewrote_bin_name:
        header_match = re.search(
            r"^\s*\[\[?[^\[\]\n]+\]\]?\s*(?:#.*)?$", new_text, re.MULTILINE
        )
        head_end = header_match.start() if header_match else len(new_text)
        head = new_text[:head_end]
        rest = new_text[head_end:]
        bin_re = re.compile(r"(^\s*bin\s*=\s*\[)([^\[\]]*?)(\])", re.MULTILINE | re.DOTALL)
        name_re = re.compile(
            r'(name\s*=\s*)"' + re.escape(current_name) + r'"'
        )

        def _replace(match: re.Match) -> str:
            prefix, body, suffix = match.group(1), match.group(2), match.group(3)
            new_body, count = name_re.subn(rf'\1"{new_name}"', body, count=1)
            if count == 0:
                return match.group(0)
            return prefix + new_body + suffix

        new_text = bin_re.sub(_replace, head) + rest

    return new_text


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


def _inject_lib_override_if_needed(text: str, manifest: Path, crate: str) -> str:
    """Pin the auto-discovered lib name when ``src/lib.rs`` exists and no ``[lib]`` is set.

    Without an explicit ``[lib]`` table, cargo derives the lib name from
    ``[package].name``. Once the rewrite renames ``[package].name`` to
    ``<crate>-<suffix>``, the auto-derived lib name becomes ``<crate>_<suffix>``,
    which breaks every ``use <crate>::...`` in the same crate's bin source.

    This appends ``[lib] name = "<crate>"`` (dash-to-underscore-normalized to
    match cargo's lib-name rules) so the lib keeps its original identifier
    after the package rename. ``path`` is intentionally omitted — cargo
    auto-discovers ``src/lib.rs``.

    No-op when:
      - the crate has no ``src/lib.rs`` (binary-only crate, nothing to pin); or
      - ``[lib]`` already exists (author has explicit configuration; we don't
        second-guess and we can't safely append a second ``[lib]`` table).
    """
    lib_file = manifest.parent / "src" / "lib.rs"
    if not lib_file.is_file():
        return text
    data = tomllib.loads(text)
    if "lib" in data:
        return text
    lib_name = crate.replace("-", "_")
    separator = "" if text.endswith("\n\n") else ("\n" if text.endswith("\n") else "\n\n")
    return text + f'{separator}[lib]\nname = "{lib_name}"\n'


def _inject_binstall_metadata_if_needed(text: str) -> str:
    """Append BINSTALL_BLOCK when no [package.metadata.binstall] already exists.

    Idempotent and non-destructive: if the crate's manifest already defines any
    [package.metadata.binstall] keys, this is a no-op (crate authors may have
    custom archive layouts). Appending a new table header is safe even if
    [package.metadata] already exists as an open-ended table — TOML allows
    defining nested tables out of order.
    """
    data = tomllib.loads(text)
    existing = data.get("package", {}).get("metadata", {}).get("binstall")
    if existing:
        return text
    separator = "" if text.endswith("\n\n") else ("\n" if text.endswith("\n") else "\n\n")
    return text + separator + BINSTALL_BLOCK


def force_dev_binstall(copy_manifest: Path) -> None:
    """Replace any ``[package.metadata.binstall]`` in the staged copy with the dev layout.

    Author-supplied binstall is configured for the stable lane (release tag
    ``v{X.Y.Z}`` with archive ``{ name }-{ target }.tgz`` inside a ``{ name }-{ target }/``
    directory). The dev lane uses a different tag/archive layout (matching
    ``dev-release-binaries.yml``: ``{ name }-v{ version }-{ target }.tgz``), so
    we unconditionally override for ``--dual-role`` publishes. The original
    Cargo.toml on ``develop`` stays untouched — only the staged copy at
    ``target/bifurcate/<crate>-<suffix>/`` is mutated.

    Drops any ``[package.metadata.binstall.overrides.*]`` sub-tables that the
    author may have set (per-target archive-format etc.) — those are stable-
    lane specific and don't apply to dev archives.

    Uses ``tomli_w`` for the round-trip; the staged copy is ephemeral (one
    publish, then discarded) so reformat is acceptable. Same trade-off as
    ``resolve_workspace_inheritance``.
    """
    with copy_manifest.open("rb") as fh:
        data = tomllib.load(fh)
    metadata = data.setdefault("package", {}).setdefault("metadata", {})
    metadata["binstall"] = {
        "pkg-url": (
            "{ repo }/releases/download/v{ version }/"
            "{ name }-v{ version }-{ target }{ archive-suffix }"
        ),
        "bin-dir": "{ name }-v{ version }-{ target }/{ bin }{ binary-ext }",
        "pkg-fmt": "tgz",
    }
    with copy_manifest.open("wb") as fh:
        tomli_w.dump(data, fh)


def stage_dual_role_copy(manifest: Path, new_name: str, workdir: Path) -> Path:
    """Copy the crate directory to <workdir>/target/bifurcate/<new_name>/.

    Returns the path to the copied Cargo.toml so the caller can rewrite it.
    Also fixes up relative paths in [package].{readme,license-file,build} that
    escape the crate dir (e.g. greentic-runner's `readme = "../../README.md"`
    pointing at the workspace root).
    """
    src_dir = manifest.parent
    dest_dir = workdir / "target" / "bifurcate" / new_name

    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    dest_dir.parent.mkdir(parents=True, exist_ok=True)

    def _ignore(_: str, names: list[str]) -> list[str]:
        return [n for n in names if n in EXCLUDED_PATH_PARTS]

    shutil.copytree(src_dir, dest_dir, ignore=_ignore, symlinks=True)
    copy_manifest = dest_dir / "Cargo.toml"
    _fixup_escaping_paths(copy_manifest, src_dir)
    return copy_manifest


def _fixup_escaping_paths(copy_manifest: Path, original_crate_dir: Path) -> None:
    """Copy any referenced file that escapes the crate dir into the copy root.

    Sub-crate Cargo.tomls often reference workspace-level files via `../`
    (readme, license-file, build). Once copied to target/bifurcate/<new>/,
    those relative paths resolve to nonexistent locations. This helper pulls
    each such file into the copy root and rewrites the manifest value to the
    basename. Keeps the copy self-contained for cargo publish.
    """
    text = copy_manifest.read_text()
    data = tomllib.loads(text)
    pkg = data.get("package", {})
    copy_dir = copy_manifest.parent

    changed = False
    for field in ("readme", "license-file", "build"):
        value = pkg.get(field)
        if not isinstance(value, str):
            continue
        if not value.startswith("../") and "/" not in value.split("/", 1)[0].replace(
            "..", ""
        ):
            continue
        if not value.startswith(".."):
            continue
        resolved = (original_crate_dir / value).resolve()
        if not resolved.is_file():
            continue
        dest = copy_dir / resolved.name
        if not dest.exists():
            shutil.copy2(resolved, dest)
        pattern = re.compile(
            r'^(\s*' + re.escape(field) + r'\s*=\s*)"' + re.escape(value) + r'"',
            re.MULTILINE,
        )
        new_text, count = pattern.subn(rf'\1"{resolved.name}"', text, count=1)
        if count:
            text = new_text
            changed = True

    if changed:
        copy_manifest.write_text(text)


def find_workspace_root(start: Path) -> Path | None:
    """Walk up from start to find a Cargo.toml containing a [workspace] table.

    Returns None if no workspace ancestor is found. Used to resolve
    `.workspace = true` inheritance for dual-role copies.
    """
    current = start.resolve()
    for ancestor in (current, *current.parents):
        candidate = ancestor / "Cargo.toml"
        if not candidate.is_file():
            continue
        try:
            with candidate.open("rb") as fh:
                data = tomllib.load(fh)
        except (tomllib.TOMLDecodeError, OSError):
            continue
        if "workspace" in data:
            return candidate
    return None


def _is_workspace_inherit(value: Any) -> bool:
    return isinstance(value, dict) and value.get("workspace") is True


def _merge_inline_with_workspace(local: dict, resolved: Any) -> Any:
    """Merge a local dependency spec like `{ workspace = true, features = ["x"] }`
    with the resolved workspace spec. Local overrides except for the `workspace`
    sentinel itself.

    Strips `path` from the resolved spec: the copy lives at target/bifurcate/
    where intra-workspace paths like `crates/foo` don't exist, and for a
    standalone dev-lane publish the registry-resolvable `version` is what we
    want cargo to use anyway (matches cargo's own behavior of stripping `path`
    from path+version deps when publishing — we just have to do it earlier so
    the manifest-load step doesn't choke on a missing directory).
    """
    if isinstance(resolved, str):
        base: dict = {"version": resolved}
    elif isinstance(resolved, dict):
        base = dict(resolved)
        base.pop("path", None)
    else:
        base = {"spec": resolved}
    if len(local) == 1 and "workspace" in local:
        return base
    for key, val in local.items():
        if key == "workspace":
            continue
        base[key] = val
    return base


def resolve_workspace_inheritance(copy_manifest: Path, workspace_root: Path) -> None:
    """Inline-resolve `.workspace = true` keys in the copy so it's standalone-publishable.

    After resolution the copy's Cargo.toml:
      - has every `X.workspace = true` in [package] replaced with the concrete
        value from the parent's [workspace.package.X]
      - has every `X.workspace = true` in [dependencies]/[dev-dependencies]/
        [build-dependencies] replaced with the parent's [workspace.dependencies.X]
        (inline forms like `X = { workspace = true, features = [...] }` preserve
        local overrides)
      - has its own `[workspace]` table written back as-is; callers should ensure
        members/exclude lists don't reference paths outside the copy if that's
        a concern (none of the current binary crates have inner workspaces)

    Note: tomli_w reformats the output; the copy is ephemeral (published once
    and discarded), so structural correctness matters more than visual fidelity.
    """
    with workspace_root.open("rb") as fh:
        ws_data = tomllib.load(fh)
    ws_package: dict = ws_data.get("workspace", {}).get("package", {})
    ws_deps: dict = ws_data.get("workspace", {}).get("dependencies", {})

    with copy_manifest.open("rb") as fh:
        data = tomllib.load(fh)

    pkg = data.get("package", {})
    inlined_path_fields: list[str] = []  # path-bearing fields just inlined from workspace
    for key, value in list(pkg.items()):
        if _is_workspace_inherit(value):
            if key not in ws_package:
                sys.exit(
                    f"error: [{copy_manifest}] package.{key} inherits from workspace "
                    f"but [workspace.package].{key} is not defined in {workspace_root}"
                )
            pkg[key] = ws_package[key]
            if key in ("readme", "license-file", "build"):
                inlined_path_fields.append(key)

    # Cargo resolves path-bearing inherited fields (`readme`, `license-file`,
    # `build`) relative to the WORKSPACE root, not the inheriting member. Once
    # we inline the value into the bifurcate copy, cargo loses that hint and
    # resolves relative to `target/bifurcate/<crate>-<suffix>/` instead — where
    # the file doesn't exist. Copy each referenced file into the copy root
    # and rewrite the value to the basename so the copy is self-contained.
    # `_fixup_escaping_paths` (called earlier from stage_dual_role_copy) only
    # handles `..`-prefixed paths and runs BEFORE inheritance is resolved, so
    # bare-name inherited values like `readme = "README.md"` slip past it.
    workspace_dir = workspace_root.parent
    copy_dir = copy_manifest.parent
    for field in inlined_path_fields:
        value = pkg.get(field)
        if not isinstance(value, str):
            continue
        # Skip absolute paths — cargo handles those without resolution.
        if Path(value).is_absolute():
            continue
        source = (workspace_dir / value).resolve()
        if not source.is_file():
            sys.exit(
                f"error: [{copy_manifest}] package.{field} = {value!r} "
                f"(inherited from {workspace_root}) does not resolve to a file "
                f"at {source}"
            )
        dest = copy_dir / source.name
        if not dest.exists():
            shutil.copy2(source, dest)
        pkg[field] = source.name

    for deps_table in DEP_TABLES:
        deps = data.get(deps_table, {})
        for dep_name, spec in list(deps.items()):
            if _is_workspace_inherit(spec):
                if dep_name not in ws_deps:
                    sys.exit(
                        f"error: [{copy_manifest}] {deps_table}.{dep_name} inherits "
                        f"from workspace but [workspace.dependencies].{dep_name} is "
                        f"not defined in {workspace_root}"
                    )
                assert isinstance(spec, dict)
                deps[dep_name] = _merge_inline_with_workspace(spec, ws_deps[dep_name])

    # [lints] table inheritance: `lints.workspace = true` pulls the entire
    # [workspace.lints.*] tree into the member. The bifurcated copy writes
    # an empty [workspace] block (see below), so a member-level
    # `lints.workspace = true` would leave cargo looking for [workspace.lints]
    # in the empty workspace block — fails with `workspace.lints was not
    # defined`. Resolve by inlining the parent's [workspace.lints] tree.
    # No-op when the member doesn't use [lints] inheritance (other dual-role
    # binaries in the fleet don't, so this branch is dormant for them).
    lints = data.get("lints")
    if _is_workspace_inherit(lints):
        ws_lints = ws_data.get("workspace", {}).get("lints")
        if ws_lints is None:
            sys.exit(
                f"error: [{copy_manifest}] lints inherits from workspace but "
                f"[workspace.lints] is not defined in {workspace_root}"
            )
        data["lints"] = ws_lints

    # Mark the copy as its own standalone workspace root. If there are sibling
    # Cargo.toml files under the copy (as in greentic-bundle where `crates/`
    # subdirectories came along with the package-at-workspace-root copy), list
    # them in workspace.exclude so cargo doesn't try to parse their now-dangling
    # workspace inheritance.
    copy_root = copy_manifest.parent
    sibling_manifests: list[str] = []
    for p in copy_root.rglob("Cargo.toml"):
        if p == copy_manifest:
            continue
        rel_parts = p.relative_to(copy_root).parts
        if any(part in EXCLUDED_PATH_PARTS for part in rel_parts):
            continue
        sibling_manifests.append(
            str(p.parent.relative_to(copy_root)).replace("\\", "/")
        )
    workspace_block: dict[str, Any] = {}
    if sibling_manifests:
        workspace_block["exclude"] = sorted(sibling_manifests)
    data["workspace"] = workspace_block

    with copy_manifest.open("wb") as fh:
        tomli_w.dump(data, fh)


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

        # Author-supplied [package.metadata.binstall] targets the stable release
        # tag/archive layout, which doesn't match dev-release-binaries.yml
        # output. Force the dev-pipeline-compatible block on the staged copy
        # so `cargo binstall <crate>-dev` actually finds prebuilt binaries
        # instead of falling back to source.
        force_dev_binstall(copy_manifest)

        # Resolve workspace inheritance so the copy is publishable standalone.
        # Look up from the ORIGINAL manifest, not the copy, because the copy
        # lives under target/bifurcate/ where there's no parent workspace.
        ws_root = find_workspace_root(manifest.parent)
        if ws_root is not None:
            resolve_workspace_inheritance(copy_manifest, ws_root)
            print(
                f"[rewrite-binary-name] resolved workspace inheritance from {ws_root}"
            )

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
