#!/usr/bin/env python3
"""Self-contained smoke tests for assert-branch-invariants.py.

Run directly: ``python3 .github/scripts/test_assert_branch_invariants.py``
Exits 0 on success, 1 on the first failed assertion.

Covers:
  * main lane FAIL on `*-dev.*` package version
  * main lane FAIL on `*-dev.*` workspace.package version
  * main lane FAIL on `<base>-dev` package name (binary repo)
  * main lane PASS on a clean tree
  * main lane PASS when `version.workspace = true` (must not crash on dict version)
  * develop lane WARN when manifest declares basename but tree only has alias
  * develop lane WARN on dev-alias leaking into committed Cargo.toml
  * develop lane PASS on a clean binary repo
  * develop lane no-op (PASS) for non-binary repo
  * skip rules: target/ and node_modules/ are not scanned
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "assert-branch-invariants.py"


def _write(root: Path, rel: str, body: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)


def _write_manifest(root: Path, repo_name: str, binary_crates: list[str]) -> Path:
    """Write a minimal REPO_MANIFEST.toml. Returns its path."""
    crates_toml = "[]" if not binary_crates else (
        "[" + ", ".join(f'"{c}"' for c in binary_crates) + "]"
    )
    manifest = root / "REPO_MANIFEST.toml"
    manifest.write_text(
        f'[repos.{repo_name}]\n'
        f'org = "greenticai"\n'
        f'binary-crates = {crates_toml}\n'
    )
    return manifest


def _run(
    tree: Path,
    manifest: Path,
    *,
    lane: str,
    repo_name: str,
) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "python3",
            str(SCRIPT),
            "--lane", lane,
            "--repo-name", repo_name,
            "--root", str(tree),
            "--manifest", str(manifest),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def _assert(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


# ── main-lane tests ──────────────────────────────────────────────────


def test_main_fails_on_dev_suffix_in_package_version(root: Path) -> None:
    tree = root / "tree"
    _write(tree, "Cargo.toml",
        '[package]\nname = "greentic-types"\nversion = "0.6.25148999000-dev.7"\nedition = "2024"\n')
    manifest = _write_manifest(root, "greentic-types", [])
    proc = _run(tree, manifest, lane="main", repo_name="greentic-types")
    _assert(proc.returncode == 1, f"expected exit 1, got {proc.returncode}; stderr={proc.stderr!r}")
    _assert("'-dev.'" in proc.stdout or "-dev." in proc.stdout,
            f"expected dev-suffix mention in stdout; got: {proc.stdout!r}")


def test_main_fails_on_dev_suffix_in_workspace_package_version(root: Path) -> None:
    tree = root / "tree"
    _write(tree, "Cargo.toml",
        '[workspace]\nmembers = ["a"]\n\n'
        '[workspace.package]\nversion = "0.5.0-dev.42"\nedition = "2024"\n')
    _write(tree, "a/Cargo.toml",
        '[package]\nname = "a"\nversion.workspace = true\nedition.workspace = true\n')
    manifest = _write_manifest(root, "demo", [])
    proc = _run(tree, manifest, lane="main", repo_name="demo")
    _assert(proc.returncode == 1, f"expected exit 1, got {proc.returncode}")
    _assert("workspace.package" in proc.stdout,
            f"expected workspace.package mention; got: {proc.stdout!r}")


def test_main_fails_on_dev_alias_package_name(root: Path) -> None:
    tree = root / "tree"
    _write(tree, "Cargo.toml",
        '[package]\nname = "dwbase-cli-dev"\nversion = "0.6.0"\nedition = "2024"\n')
    manifest = _write_manifest(root, "greentic-dw", ["dwbase-cli"])
    proc = _run(tree, manifest, lane="main", repo_name="greentic-dw")
    _assert(proc.returncode == 1, f"expected exit 1, got {proc.returncode}")
    _assert("dev-lane alias" in proc.stdout,
            f"expected dev-lane-alias mention; got: {proc.stdout!r}")


def test_main_passes_on_clean_tree(root: Path) -> None:
    tree = root / "tree"
    _write(tree, "Cargo.toml",
        '[workspace]\nmembers = ["dwbase-cli"]\n\n'
        '[workspace.package]\nversion = "0.6.0"\nedition = "2024"\n')
    _write(tree, "dwbase-cli/Cargo.toml",
        '[package]\nname = "dwbase-cli"\nversion.workspace = true\nedition.workspace = true\n')
    manifest = _write_manifest(root, "greentic-dw", ["dwbase-cli"])
    proc = _run(tree, manifest, lane="main", repo_name="greentic-dw")
    _assert(proc.returncode == 0,
            f"expected exit 0, got {proc.returncode}; stdout={proc.stdout!r}; stderr={proc.stderr!r}")
    _assert("OK main-lane" in proc.stdout,
            f"expected OK marker; got: {proc.stdout!r}")


def test_main_handles_workspace_inherited_version_dict(root: Path) -> None:
    """`version.workspace = true` parses as a dict — must not crash on that."""
    tree = root / "tree"
    _write(tree, "Cargo.toml",
        '[workspace]\nmembers = ["a"]\n\n'
        '[workspace.package]\nversion = "0.6.0"\n')
    _write(tree, "a/Cargo.toml",
        '[package]\nname = "a"\nversion = { workspace = true }\n')
    manifest = _write_manifest(root, "demo", [])
    proc = _run(tree, manifest, lane="main", repo_name="demo")
    _assert(proc.returncode == 0,
            f"expected exit 0, got {proc.returncode}; stderr={proc.stderr!r}")


# ── develop-lane tests ───────────────────────────────────────────────


def test_develop_warns_on_missing_basename(root: Path) -> None:
    tree = root / "tree"
    # Manifest declares dwbase-cli but the tree only has dwbase-node.
    _write(tree, "Cargo.toml",
        '[workspace]\nmembers = ["dwbase-node"]\n\n'
        '[workspace.package]\nversion = "0.6.0-dev.0"\n')
    _write(tree, "dwbase-node/Cargo.toml",
        '[package]\nname = "dwbase-node"\nversion.workspace = true\n')
    manifest = _write_manifest(root, "greentic-dw", ["dwbase-cli", "dwbase-node"])
    proc = _run(tree, manifest, lane="develop", repo_name="greentic-dw")
    _assert(proc.returncode == 0,
            f"develop is non-fatal; expected exit 0, got {proc.returncode}; stderr={proc.stderr!r}")
    _assert("::warning::" in proc.stdout and "dwbase-cli" in proc.stdout,
            f"expected warning mentioning dwbase-cli; got: {proc.stdout!r}")


def test_develop_warns_on_dev_alias_leak(root: Path) -> None:
    tree = root / "tree"
    # Develop accidentally has the rewritten alias name committed.
    _write(tree, "Cargo.toml",
        '[package]\nname = "greentic-gui-dev"\nversion = "0.5.0-dev.1"\nedition = "2024"\n')
    manifest = _write_manifest(root, "greentic-gui", ["greentic-gui"])
    proc = _run(tree, manifest, lane="develop", repo_name="greentic-gui")
    _assert(proc.returncode == 0,
            f"develop is non-fatal; expected exit 0, got {proc.returncode}")
    _assert("::warning::" in proc.stdout and "dev-lane alias" in proc.stdout,
            f"expected dev-alias warning; got: {proc.stdout!r}")


def test_develop_passes_on_clean_binary_repo(root: Path) -> None:
    tree = root / "tree"
    _write(tree, "Cargo.toml",
        '[package]\nname = "greentic-gui"\nversion = "0.5.0-dev.0"\nedition = "2024"\n')
    manifest = _write_manifest(root, "greentic-gui", ["greentic-gui"])
    proc = _run(tree, manifest, lane="develop", repo_name="greentic-gui")
    _assert(proc.returncode == 0,
            f"expected exit 0, got {proc.returncode}; stderr={proc.stderr!r}")
    _assert("::warning::" not in proc.stdout,
            f"expected no warnings; got: {proc.stdout!r}")
    _assert("OK develop-lane" in proc.stdout,
            f"expected OK marker; got: {proc.stdout!r}")


def test_develop_noop_for_non_binary_repo(root: Path) -> None:
    tree = root / "tree"
    _write(tree, "Cargo.toml",
        '[package]\nname = "greentic-types"\nversion = "0.6.0-dev.0"\nedition = "2024"\n')
    manifest = _write_manifest(root, "greentic-types", [])
    proc = _run(tree, manifest, lane="develop", repo_name="greentic-types")
    _assert(proc.returncode == 0,
            f"expected exit 0, got {proc.returncode}; stderr={proc.stderr!r}")
    _assert("not binary-bifurcated" in proc.stdout,
            f"expected non-binary message; got: {proc.stdout!r}")


# ── skip-rules test ─────────────────────────────────────────────────


def test_skips_target_and_node_modules(root: Path) -> None:
    """A poisoned Cargo.toml under target/ or node_modules/ must NOT trip the
    main-lane guard — those dirs are build artifacts / vendored deps."""
    tree = root / "tree"
    _write(tree, "Cargo.toml",
        '[package]\nname = "greentic-runner"\nversion = "0.6.0"\nedition = "2024"\n')
    _write(tree, "target/bifurcate/greentic-runner-dev/Cargo.toml",
        '[package]\nname = "greentic-runner-dev"\nversion = "0.6.123-dev.0"\nedition = "2024"\n')
    _write(tree, "node_modules/some-pkg/Cargo.toml",
        '[package]\nname = "anything"\nversion = "0.1.0-dev.0"\n')
    manifest = _write_manifest(root, "greentic-runner", ["greentic-runner"])
    proc = _run(tree, manifest, lane="main", repo_name="greentic-runner")
    _assert(proc.returncode == 0,
            f"expected exit 0 (target/ and node_modules/ skipped); got {proc.returncode}; stdout={proc.stdout!r}")


# ── runner ──────────────────────────────────────────────────────────


def main() -> int:
    tests = [
        test_main_fails_on_dev_suffix_in_package_version,
        test_main_fails_on_dev_suffix_in_workspace_package_version,
        test_main_fails_on_dev_alias_package_name,
        test_main_passes_on_clean_tree,
        test_main_handles_workspace_inherited_version_dict,
        test_develop_warns_on_missing_basename,
        test_develop_warns_on_dev_alias_leak,
        test_develop_passes_on_clean_binary_repo,
        test_develop_noop_for_non_binary_repo,
        test_skips_target_and_node_modules,
    ]
    failed = 0
    for fn in tests:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            try:
                fn(root)
            except AssertionError as exc:
                print(f"FAIL {fn.__name__}: {exc}")
                failed += 1
                continue
            except Exception as exc:
                print(f"ERROR {fn.__name__}: {exc!r}")
                failed += 1
                continue
            finally:
                shutil.rmtree(root, ignore_errors=True)
            print(f"ok   {fn.__name__}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
