#!/usr/bin/env python3
"""Self-contained tests for stamp-binary-version.py.

Run directly: ``python3 scripts/test_stamp_binary_version.py``
Exits 0 on success, 1 on the first failed assertion. Needs `cargo` on PATH
(the script asks `cargo metadata` where the package lives, and verifies the
stamp through it).

Covers:

  * `version.workspace = true` member of a workspace (greentic-pack's shape)
    → stamped, and ONLY that member: the sibling library and
    `[workspace.package].version` stay as committed.
  * `version = { workspace = true }` inline-table form.
  * Single-package repo with a literal `version = "..."`.
  * `[package]` with no version key → inserted after `name`.
  * Unknown package → exits 1.
  * Non-semver version → exits 1.
  * `version` keys in OTHER tables (`[dependencies]`, `[package.metadata]`)
    are never mistaken for the package's own.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "stamp-binary-version.py"
VERSION = "1.2.34173134336"

_spec = importlib.util.spec_from_file_location("stamp_binary_version", SCRIPT)
assert _spec and _spec.loader
stamp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(stamp)


def _run(root: Path, package: str, version: str = VERSION) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--package", package, "--version", version, "--workdir", str(root)],
        capture_output=True,
        text=True,
    )


def _versions(root: Path) -> dict[str, str]:
    out = subprocess.run(
        ["cargo", "metadata", "--no-deps", "--format-version", "1"],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return {p["name"]: p["version"] for p in json.loads(out)["packages"]}


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _lib(root: Path, rel: str) -> None:
    _write(root / rel / "src" / "lib.rs", "")


def _bin(root: Path, rel: str) -> None:
    _write(root / rel / "src" / "main.rs", "fn main() {}\n")


def test_workspace_inherited_member_only() -> None:
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        _write(
            root / "Cargo.toml",
            '[workspace]\nmembers = ["crates/lib", "crates/cli"]\nresolver = "2"\n\n'
            '[workspace.package]\nversion = "1.2.0-dev.0"\nedition = "2021"\n',
        )
        _write(
            root / "crates/lib/Cargo.toml",
            '[package]\nname = "demo-lib"\nversion.workspace = true\nedition.workspace = true\n',
        )
        _lib(root, "crates/lib")
        _write(
            root / "crates/cli/Cargo.toml",
            '[package]\nname = "demo-cli"\nversion.workspace = true\nedition.workspace = true\n\n'
            '[dependencies]\ndemo-lib = { path = "../lib", version = "1.2.0-dev.0" }\n\n'
            '[package.metadata.binstall]\nversion = "{ version }"\n',
        )
        _bin(root, "crates/cli")

        result = _run(root, "demo-cli")
        assert result.returncode == 0, result.stderr
        versions = _versions(root)
        assert versions["demo-cli"] == VERSION, versions
        assert versions["demo-lib"] == "1.2.0-dev.0", versions
        assert 'version = "1.2.0-dev.0"' in (root / "Cargo.toml").read_text()
        cli = (root / "crates/cli/Cargo.toml").read_text()
        assert 'version = "{ version }"' in cli, cli
        assert 'demo-lib = { path = "../lib", version = "1.2.0-dev.0" }' in cli, cli


def test_inline_table_workspace_form() -> None:
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        _write(
            root / "Cargo.toml",
            '[workspace]\nmembers = ["cli"]\n\n[workspace.package]\nversion = "0.5.0"\n',
        )
        _write(
            root / "cli/Cargo.toml",
            '[package]\nname = "demo-cli"\nversion = { workspace = true }\nedition = "2021"\n',
        )
        _bin(root, "cli")
        result = _run(root, "demo-cli")
        assert result.returncode == 0, result.stderr
        assert _versions(root)["demo-cli"] == VERSION


def test_single_package_literal_version() -> None:
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        _write(
            root / "Cargo.toml",
            '[package]\nname = "demo"\nversion = "1.2.0-dev.34428856459" # stale stamp\nedition = "2021"\n',
        )
        _bin(root, ".")
        result = _run(root, "demo")
        assert result.returncode == 0, result.stderr
        assert _versions(root)["demo"] == VERSION


def test_research_line_version_is_stamped_verbatim() -> None:
    """A research-line base (greentic-start#595) is replaced like any other."""
    text = '[package]\nname = "demo"\nversion = "1.3.0-research.3"\n'
    out = stamp.stamp_manifest_text(text, "1.3.0-research.35341963100")
    assert out == '[package]\nname = "demo"\nversion = "1.3.0-research.35341963100"\n', out
    assert stamp._SEMVER_RE.match("1.3.0-research.35341963100")


def test_missing_version_key_is_inserted() -> None:
    text = '[package]\nname = "demo"\nedition = "2021"\n'
    out = stamp.stamp_manifest_text(text, VERSION)
    assert out == f'[package]\nname = "demo"\nversion = "{VERSION}"\nedition = "2021"\n', out


def test_other_tables_version_keys_untouched() -> None:
    text = (
        '[dependencies]\nfoo = { version = "1" }\n\n'
        '[package]\nname = "demo"\nversion = "0.1.0"\n\n'
        '[package.metadata]\nversion = "keep"\n'
    )
    out = stamp.stamp_manifest_text(text, VERSION)
    assert f'version = "{VERSION}"' in out
    assert 'foo = { version = "1" }' in out
    assert 'version = "keep"' in out
    assert out.count("version = ") == 3, out


def test_crlf_preserved() -> None:
    text = '[package]\r\nname = "demo"\r\nversion.workspace = true\r\n'
    out = stamp.stamp_manifest_text(text, VERSION)
    assert out == f'[package]\r\nname = "demo"\r\nversion = "{VERSION}"\r\n', repr(out)


def test_unknown_package_fails() -> None:
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        _write(root / "Cargo.toml", '[package]\nname = "demo"\nversion = "0.1.0"\nedition = "2021"\n')
        _bin(root, ".")
        result = _run(root, "nope")
        assert result.returncode != 0
        assert "exactly one workspace package" in result.stderr, result.stderr


def test_non_semver_version_fails() -> None:
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        _write(root / "Cargo.toml", '[package]\nname = "demo"\nversion = "0.1.0"\nedition = "2021"\n')
        _bin(root, ".")
        result = _run(root, "demo", version="v1.2")
        assert result.returncode == 1
        assert "not a semver" in result.stderr, result.stderr
        assert _versions(root)["demo"] == "0.1.0"


def main() -> int:
    tests = [v for k, v in globals().items() if k.startswith("test_") and callable(v)]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"ok   {t.__name__}")
        except AssertionError as err:
            failed += 1
            print(f"FAIL {t.__name__}: {err}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
