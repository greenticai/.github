#!/usr/bin/env python3
"""Self-contained tests for stamp-inner-crates.py.

Run directly: ``python3 .github/scripts/test_stamp_inner_crates.py``
Exits 0 on success, 1 on the first failed assertion.

Covers the cases that motivate the script (see the script's module docstring):

  * Divergent inner crate gets stamped (greentic-deployer + greentic-deploy-spec
    layout — the bug class).
  * Inner crate sharing top-level base (already stamped by workflow's main
    find/sed pass) is a no-op.
  * Workspace-inherited version (`version.workspace = true`) is a no-op.
  * Pre-release base (`M.m.p-dev.N`) → stamped to `M.m.p-dev.{RUN_ID}`.
  * Regular base (`M.m.p`) → stamped to `M.m.{RUN_ID}`.
  * Missing crate → script exits 1.
  * Unsupported version form → script exits 1.
  * Format preservation: tomlkit keeps comments, ordering, indentation.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "stamp-inner-crates.py"

RUN_ID = "26081289707"
DEV_VERSION = "1.1.0-dev.26081289707"


def _run(root: Path, crates: str, *, dev_version: str = DEV_VERSION, run_id: str = RUN_ID) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "python3",
            str(SCRIPT),
            "--crates",
            crates,
            "--dev-version",
            dev_version,
            "--run-id",
            run_id,
            "--root",
            str(root),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def _read_version(manifest: Path) -> str | dict:
    data = tomllib.loads(manifest.read_text())
    return data["package"]["version"]


def _write(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------


def _deployer_layout(root: Path, *, top_version: str, inner_version: str) -> tuple[Path, Path]:
    """greentic-deployer-style layout: top-level + crates/greentic-deploy-spec."""
    top = root / "Cargo.toml"
    inner = root / "crates" / "greentic-deploy-spec" / "Cargo.toml"
    _write(
        top,
        f"""[workspace]
members = [".", "crates/greentic-deploy-spec"]
resolver = "2"

[package]
name = "greentic-deployer"
version = "{top_version}"
edition = "2024"

[dependencies]
greentic-deploy-spec = {{ path = "crates/greentic-deploy-spec", version = "0.1" }}
""",
    )
    _write(
        inner,
        f"""[package]
name = "greentic-deploy-spec"
version = "{inner_version}"
edition = "2024"

# Keep this comment to verify tomlkit preserves it.
[lib]
path = "src/lib.rs"
""",
    )
    return top, inner


def _shared_workspace_layout(root: Path, *, version: str) -> tuple[Path, Path, Path]:
    """Multi-crate workspace with shared [workspace.package].version."""
    top = root / "Cargo.toml"
    inner_a = root / "crates" / "foo" / "Cargo.toml"
    inner_b = root / "crates" / "bar" / "Cargo.toml"
    _write(
        top,
        f"""[workspace]
members = ["crates/*"]
resolver = "2"

[workspace.package]
version = "{version}"
edition = "2024"
""",
    )
    _write(
        inner_a,
        """[package]
name = "foo"
version.workspace = true
edition.workspace = true
""",
    )
    _write(
        inner_b,
        """[package]
name = "bar"
version = { workspace = true }
edition.workspace = true
""",
    )
    return top, inner_a, inner_b


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_divergent_inner_crate_gets_stamped() -> None:
    """The bug class: deploy-spec at 0.1.0 while deployer is 1.1.0-dev.0."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        top, inner = _deployer_layout(root, top_version=DEV_VERSION, inner_version="0.1.0")
        # Top-level already stamped by workflow's find/sed pass; we exercise
        # the script over both crates and check only deploy-spec moves.
        result = _run(root, "greentic-deploy-spec greentic-deployer")
        assert result.returncode == 0, result.stderr
        assert _read_version(top) == DEV_VERSION
        assert _read_version(inner) == f"0.1.{RUN_ID}"


def test_inner_crate_already_at_dev_version_is_noop() -> None:
    """Inner crate that shares top-level BASE was already stamped — skip."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        # Both stamped to DEV_VERSION already (workflow's find/sed pass did it).
        top, inner = _deployer_layout(root, top_version=DEV_VERSION, inner_version=DEV_VERSION)
        result = _run(root, "greentic-deploy-spec")
        assert result.returncode == 0, result.stderr
        assert _read_version(inner) == DEV_VERSION
        assert "no stamp needed" in result.stdout


def test_workspace_inheritance_is_noop() -> None:
    """Shared [workspace.package].version: inner members inherit, nothing to stamp here."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        top, inner_a, inner_b = _shared_workspace_layout(root, version="0.5.10")
        # Both inner crates listed — both should be reported as "inherits via workspace".
        result = _run(root, "foo bar")
        assert result.returncode == 0, result.stderr
        # tomllib resolves `version.workspace = true` to {"workspace": True}.
        v_a = tomllib.loads(inner_a.read_text())["package"]["version"]
        v_b = tomllib.loads(inner_b.read_text())["package"]["version"]
        assert v_a == {"workspace": True}, v_a
        assert v_b == {"workspace": True}, v_b
        assert result.stdout.count("inherits via workspace") == 2


def test_pre_release_base_preserves_form() -> None:
    """Inner crate at M.m.p-dev.N gets re-stamped to M.m.p-dev.{RUN_ID}."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        top, inner = _deployer_layout(
            root, top_version=DEV_VERSION, inner_version="0.3.0-dev.0"
        )
        result = _run(root, "greentic-deploy-spec")
        assert result.returncode == 0, result.stderr
        assert _read_version(inner) == f"0.3.0-dev.{RUN_ID}"


def test_regular_base_uses_mm_run_id() -> None:
    """Inner crate at M.m.p gets stamped to M.m.{RUN_ID} (regular release)."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        top, inner = _deployer_layout(root, top_version=DEV_VERSION, inner_version="0.1.0")
        result = _run(root, "greentic-deploy-spec")
        assert result.returncode == 0, result.stderr
        assert _read_version(inner) == f"0.1.{RUN_ID}"


def test_missing_crate_errors() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _deployer_layout(root, top_version=DEV_VERSION, inner_version="0.1.0")
        result = _run(root, "no-such-crate")
        assert result.returncode == 1, result.stdout + result.stderr
        assert "no Cargo.toml with" in result.stderr


def test_unsupported_version_form_errors() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        # `1.0` is not a complete semver triple — neither pre-release nor regular form.
        _deployer_layout(root, top_version=DEV_VERSION, inner_version="1.0")
        result = _run(root, "greentic-deploy-spec")
        assert result.returncode == 1, result.stdout + result.stderr
        assert "not on supported form" in result.stderr


def test_format_preserved_under_stamp() -> None:
    """Comments and table ordering survive the tomlkit round-trip."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        top, inner = _deployer_layout(root, top_version=DEV_VERSION, inner_version="0.1.0")
        original = inner.read_text()
        result = _run(root, "greentic-deploy-spec")
        assert result.returncode == 0, result.stderr
        stamped = inner.read_text()
        # The only diff should be the version line.
        original_lines = original.splitlines()
        stamped_lines = stamped.splitlines()
        diffs = [
            (i, o, s)
            for i, (o, s) in enumerate(zip(original_lines, stamped_lines))
            if o != s
        ]
        assert len(original_lines) == len(stamped_lines), (
            f"line count changed: {len(original_lines)} → {len(stamped_lines)}\n"
            f"original:\n{original}\nstamped:\n{stamped}"
        )
        assert len(diffs) == 1, f"expected exactly 1 changed line, got: {diffs}"
        idx, old_line, new_line = diffs[0]
        assert old_line == 'version = "0.1.0"'
        assert new_line == f'version = "0.1.{RUN_ID}"'
        assert "# Keep this comment" in stamped


def test_empty_crates_input_is_noop() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _deployer_layout(root, top_version=DEV_VERSION, inner_version="0.1.0")
        result = _run(root, "")
        assert result.returncode == 0, result.stderr
        assert "nothing to do" in result.stdout


def test_packc_generated_shadow_is_excluded() -> None:
    """Generator dumps under `.packc/` must not shadow real publishable crates.

    greentic-pack ships `pack_component` at `crates/pack_component/` and
    `packc build` emits a copy under `examples/<demo>/.packc/pack_component/`.
    The `.packc/` directory is gitignored; if a copy ever lands in the tree
    (committed by mistake or left behind by a local build), the walker must
    skip it. Otherwise the script bails with "expected exactly one Cargo.toml".

    This was the failure mode in
    https://github.com/greenticai/.github/actions/runs/26144643272.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        real = root / "crates" / "pack_component" / "Cargo.toml"
        shadow = root / "examples" / "qa-demo" / ".packc" / "pack_component" / "Cargo.toml"
        _write(
            real,
            """[package]
name = "pack_component"
version = "0.1.0"
edition = "2024"
""",
        )
        _write(
            shadow,
            f"""[package]
name = "pack_component"
version = "{DEV_VERSION}"
edition = "2024"
""",
        )
        result = _run(root, "pack_component")
        assert result.returncode == 0, result.stdout + result.stderr
        # Only the real manifest should have been touched.
        assert _read_version(real) == f"0.1.{RUN_ID}"
        # Shadow must be left untouched (still on the pre-walk value).
        assert _read_version(shadow) == DEV_VERSION


# ---------------------------------------------------------------------------


def main() -> None:
    tests = [
        test_divergent_inner_crate_gets_stamped,
        test_inner_crate_already_at_dev_version_is_noop,
        test_workspace_inheritance_is_noop,
        test_pre_release_base_preserves_form,
        test_regular_base_uses_mm_run_id,
        test_missing_crate_errors,
        test_unsupported_version_form_errors,
        test_format_preserved_under_stamp,
        test_empty_crates_input_is_noop,
        test_packc_generated_shadow_is_excluded,
    ]
    failed = 0
    for test in tests:
        try:
            test()
            print(f"  ok    {test.__name__}")
        except AssertionError as exc:
            print(f"  FAIL  {test.__name__}: {exc}", file=sys.stderr)
            failed += 1
        except Exception as exc:  # noqa: BLE001 — surface any unexpected error
            print(f"  ERROR {test.__name__}: {exc!r}", file=sys.stderr)
            failed += 1
    if failed:
        print(f"\n{failed}/{len(tests)} tests failed", file=sys.stderr)
        sys.exit(1)
    print(f"\nall {len(tests)} tests passed")


if __name__ == "__main__":
    main()
