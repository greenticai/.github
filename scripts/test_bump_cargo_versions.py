#!/usr/bin/env python3
"""Self-contained smoke tests for bump_cargo_versions.py.

Run directly: ``python3 .github/scripts/test_bump_cargo_versions.py``
Exits 0 on success, 1 on the first failed assertion.

Covers:
  * workspace inheritance (`version.workspace = true`) survives a round-trip
  * `package = "..."` dep aliases are resolved when classifying greentic-ness
  * non-greentic-prefixed ecosystem crates (`runner-core`) get bumped
  * regression: pre-existing happy paths still bump as before
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "bump_cargo_versions.py"


def _run(root: Path, *args: str) -> str:
    return _run_with(root, "--from", "0.4", "--to", "0.5", *args)


def _run_with(root: Path, *args: str) -> str:
    """Run with a caller-chosen flag set. Last positional arg is the root."""
    proc = subprocess.run(
        ["python3", str(SCRIPT), *args, str(root)],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(f"script exited {proc.returncode}")
    return proc.stdout


def _run_expecting_failure(root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["python3", str(SCRIPT), *args, str(root)],
        capture_output=True,
        text=True,
        check=False,
    )


def _write(root: Path, rel: str, body: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)


def _load(root: Path, rel: str) -> dict:
    with open(root / rel, "rb") as f:
        return tomllib.load(f)


def _assert(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_workspace_inherit_round_trip(root: Path) -> None:
    """`version.workspace = true` must survive — Cargo rejects sub-table form."""
    _write(
        root,
        "Cargo.toml",
        "[workspace]\nmembers = [\"a\"]\n\n"
        "[workspace.package]\nversion = \"0.4.5\"\nedition = \"2024\"\n",
    )
    _write(
        root,
        "a/Cargo.toml",
        "[package]\nname = \"a\"\n"
        "version.workspace = true\n"
        "edition.workspace = true\n"
        "license.workspace = true\n",
    )
    _run(root)

    text = (root / "a/Cargo.toml").read_text()
    for key in ("version", "edition", "license"):
        _assert(
            f"{key}.workspace = true" in text,
            f"expected dotted-key `{key}.workspace = true` in member crate, got:\n{text}",
        )
    _assert(
        "[package.version]" not in text and "[package.edition]" not in text,
        f"sub-table form leaked into output (Cargo would reject):\n{text}",
    )

    # Workspace package version is still bumped (it's a string, not a dict).
    ws = _load(root, "Cargo.toml")
    _assert(
        ws["workspace"]["package"]["version"] == "0.5.0",
        f"workspace.package.version = {ws['workspace']['package']['version']!r}",
    )


def test_aliased_dep_is_bumped(root: Path) -> None:
    """`greentic_pack = { package = "greentic-pack-lib", version = "0.4" }`
    must be bumped — the alias name doesn't start with `greentic-`, so the
    old logic skipped it."""
    _write(
        root,
        "Cargo.toml",
        "[workspace]\nmembers = [\"a\"]\n\n"
        "[workspace.package]\nversion = \"0.4.5\"\n\n"
        "[workspace.dependencies.greentic_pack]\n"
        "package = \"greentic-pack-lib\"\n"
        "version = \"0.4\"\n",
    )
    _write(
        root,
        "a/Cargo.toml",
        "[package]\nname = \"a\"\nversion = \"0.4.0\"\n\n"
        "[dependencies.greentic_pack]\n"
        "package = \"greentic-pack-lib\"\n"
        "version = \"0.4\"\n",
    )
    _run(root)

    ws = _load(root, "Cargo.toml")
    spec = ws["workspace"]["dependencies"]["greentic_pack"]
    _assert(
        spec["version"] == ">=0.5.0-0, <0.6.0-0",
        f"workspace dep alias not bumped: {spec}",
    )

    member = _load(root, "a/Cargo.toml")
    member_spec = member["dependencies"]["greentic_pack"]
    _assert(
        member_spec["version"] == ">=0.5.0-0, <0.6.0-0",
        f"member dep alias not bumped: {member_spec}",
    )


def test_runner_core_is_bumped(root: Path) -> None:
    """`runner-core` is in the greentic ecosystem despite the name."""
    _write(
        root,
        "Cargo.toml",
        "[workspace]\nmembers = []\n\n"
        "[workspace.dependencies]\n"
        "runner-core = { path = \"crates/runner-core\", version = \"0.4\" }\n",
    )
    _run(root)

    ws = _load(root, "Cargo.toml")
    spec = ws["workspace"]["dependencies"]["runner-core"]
    _assert(
        spec["version"] == ">=0.5.0-0, <0.6.0-0",
        f"runner-core not bumped: {spec}",
    )


def test_workspace_inherit_dep_marker_not_misclassified(root: Path) -> None:
    """`greentic-bar = { workspace = true }` must NOT be treated as a
    versioned dep (it has no `version` key)."""
    _write(
        root,
        "Cargo.toml",
        "[workspace]\nmembers = []\n\n"
        "[workspace.dependencies]\n"
        "greentic-bar = { workspace = true }\n",
    )
    _run(root)

    ws = _load(root, "Cargo.toml")
    spec = ws["workspace"]["dependencies"]["greentic-bar"]
    _assert(
        spec == {"workspace": True},
        f"workspace-inherit dep marker mutated: {spec}",
    )


def test_skip_crate_alias_not_bumped(root: Path) -> None:
    """`serde_yaml_bw = { package = "serde_yaml_gtc", ... }` must be skipped
    even though the alias key is reachable via the alias resolution path."""
    _write(
        root,
        "Cargo.toml",
        "[workspace]\nmembers = []\n\n"
        "[workspace.dependencies.serde_yaml_bw]\n"
        "package = \"serde_yaml_gtc\"\n"
        "version = \"2.5.2\"\n",
    )
    _run(root)

    ws = _load(root, "Cargo.toml")
    spec = ws["workspace"]["dependencies"]["serde_yaml_bw"]
    _assert(
        spec["version"] == "2.5.2",
        f"skip-crate alias was bumped: {spec}",
    )


def test_basic_string_dep_still_bumped(root: Path) -> None:
    """Regression: plain string deps still bump."""
    _write(
        root,
        "Cargo.toml",
        "[workspace]\nmembers = []\n\n"
        "[workspace.dependencies]\n"
        "greentic-types = \"0.4\"\n",
    )
    _run(root)

    ws = _load(root, "Cargo.toml")
    _assert(
        ws["workspace"]["dependencies"]["greentic-types"] == ">=0.5.0-0, <0.6.0-0",
        f"plain string dep not bumped: {ws['workspace']['dependencies']}",
    )


# --- Pre-release lane tests (plans/pre-release-minor-bump-lane.md Phase 2) ---


def test_pre_release_promotion_package_and_deps(root: Path) -> None:
    """--pre-release promotes package to X.Y.0-dev.0 and dep reqs to the
    pre-release range form ('>=X.Y.0-dev, <X.(Y+1).0-0')."""
    _write(
        root,
        "Cargo.toml",
        "[workspace]\nmembers = [\"a\"]\n\n"
        "[workspace.package]\nversion = \"0.5.3\"\n\n"
        "[workspace.dependencies]\n"
        "greentic-types = \"0.5\"\n",
    )
    _write(
        root,
        "a/Cargo.toml",
        "[package]\nname = \"a\"\nversion = \"0.5.3\"\n\n"
        "[dependencies]\n"
        "greentic-types = \"0.5\"\n",
    )
    _run_with(root, "--from", "0.5", "--to", "0.6", "--pre-release")

    ws = _load(root, "Cargo.toml")
    _assert(
        ws["workspace"]["package"]["version"] == "0.6.0-dev.0",
        f"workspace.package.version = {ws['workspace']['package']['version']!r}",
    )
    _assert(
        ws["workspace"]["dependencies"]["greentic-types"] == ">=0.6.0-dev, <0.7.0-0",
        f"workspace dep: {ws['workspace']['dependencies']['greentic-types']!r}",
    )

    member = _load(root, "a/Cargo.toml")
    _assert(
        member["package"]["version"] == "0.6.0-dev.0",
        f"member package version: {member['package']['version']!r}",
    )
    _assert(
        member["dependencies"]["greentic-types"] == ">=0.6.0-dev, <0.7.0-0",
        f"member dep: {member['dependencies']['greentic-types']!r}",
    )


def test_pre_release_explicit_to_version_increments_dev_n(root: Path) -> None:
    """Nightly-increment case: current is X.Y.0-dev.3, target X.Y.0-dev.4."""
    _write(
        root,
        "Cargo.toml",
        "[package]\nname = \"a\"\nversion = \"0.6.0-dev.3\"\n",
    )
    _run_with(
        root,
        "--from",
        "0.6",
        "--to",
        "0.6",
        "--pre-release",
        "--to-version",
        "0.6.0-dev.4",
    )

    pkg = _load(root, "Cargo.toml")["package"]
    _assert(
        pkg["version"] == "0.6.0-dev.4",
        f"package version: {pkg['version']!r}",
    )


def test_pre_release_bumps_existing_pre_release_to_default_dev_0(root: Path) -> None:
    """--from 0.5 --to 0.6 --pre-release on a repo already at 0.5.0-dev.7
    should still promote (prefix 0.5 matches 0.5.0-dev.7 via startswith-dot)."""
    _write(
        root,
        "Cargo.toml",
        "[package]\nname = \"a\"\nversion = \"0.5.0-dev.7\"\n",
    )
    _run_with(root, "--from", "0.5", "--to", "0.6", "--pre-release")

    pkg = _load(root, "Cargo.toml")["package"]
    _assert(
        pkg["version"] == "0.6.0-dev.0",
        f"package version: {pkg['version']!r}",
    )


def test_pre_release_dep_range_replaces_old_stable_range(root: Path) -> None:
    """Dep was on stable range '>=0.5.0-0, <0.6.0-0'; pre-release promotion
    rewrites it to the pre-release range '>=0.6.0-dev, <0.7.0-0'."""
    _write(
        root,
        "Cargo.toml",
        "[workspace]\nmembers = []\n\n"
        "[workspace.dependencies]\n"
        "greentic-types = \">=0.5.0-0, <0.6.0-0\"\n",
    )
    _run_with(root, "--from", "0.5", "--to", "0.6", "--pre-release")

    ws = _load(root, "Cargo.toml")
    _assert(
        ws["workspace"]["dependencies"]["greentic-types"] == ">=0.6.0-dev, <0.7.0-0",
        f"range dep not pre-release-bumped: {ws['workspace']['dependencies']}",
    )


def test_pre_release_rejects_malformed_to_version(root: Path) -> None:
    """--to-version must be X.Y.Z or X.Y.Z-prerelease; bare '0.6' should fail."""
    _write(root, "Cargo.toml", "[package]\nname = \"a\"\nversion = \"0.6.0\"\n")
    proc = _run_expecting_failure(
        root,
        "--from",
        "0.6",
        "--to",
        "0.6",
        "--pre-release",
        "--to-version",
        "0.6",
    )
    _assert(
        proc.returncode != 0,
        f"expected failure on malformed --to-version, got returncode={proc.returncode}",
    )


def test_non_pre_release_rejects_pre_release_to_version(root: Path) -> None:
    """Without --pre-release, --to-version 0.6.0-dev.0 should still be rejected."""
    _write(root, "Cargo.toml", "[package]\nname = \"a\"\nversion = \"0.6.0\"\n")
    proc = _run_expecting_failure(
        root,
        "--from",
        "0.6",
        "--to",
        "0.6",
        "--to-version",
        "0.6.0-dev.0",
    )
    _assert(
        proc.returncode != 0,
        f"expected failure on pre-release --to-version without --pre-release, got returncode={proc.returncode}",
    )


def test_stable_cut_from_pre_release_strips_suffix(root: Path) -> None:
    """Weekly-stable-prepare flow: package on 0.6.0-dev.7, no --pre-release,
    should cut to 0.6.0 stable."""
    _write(
        root,
        "Cargo.toml",
        "[package]\nname = \"a\"\nversion = \"0.6.0-dev.7\"\n\n"
        "[dependencies]\ngreentic-types = \">=0.6.0-dev, <0.7.0-0\"\n",
    )
    _run_with(root, "--from", "0.6", "--to", "0.6")

    data = _load(root, "Cargo.toml")
    _assert(
        data["package"]["version"] == "0.6.0",
        f"stable cut didn't strip suffix: {data['package']['version']!r}",
    )
    _assert(
        data["dependencies"]["greentic-types"] == ">=0.6.0-0, <0.7.0-0",
        f"dep range not rewritten to stable form: {data['dependencies']['greentic-types']!r}",
    )


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------


def main() -> int:
    tests = [
        test_workspace_inherit_round_trip,
        test_aliased_dep_is_bumped,
        test_runner_core_is_bumped,
        test_workspace_inherit_dep_marker_not_misclassified,
        test_skip_crate_alias_not_bumped,
        test_basic_string_dep_still_bumped,
        test_pre_release_promotion_package_and_deps,
        test_pre_release_explicit_to_version_increments_dev_n,
        test_pre_release_bumps_existing_pre_release_to_default_dev_0,
        test_pre_release_dep_range_replaces_old_stable_range,
        test_pre_release_rejects_malformed_to_version,
        test_non_pre_release_rejects_pre_release_to_version,
        test_stable_cut_from_pre_release_strips_suffix,
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
