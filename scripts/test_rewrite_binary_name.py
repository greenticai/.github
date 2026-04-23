#!/usr/bin/env python3
"""Self-contained tests for rewrite-binary-name.py.

Run directly:  python3 .github/scripts/test_rewrite_binary_name.py
Exits 0 on success, 1 on the first failed assertion.

Covers the cases enumerated in Phase C.1 of plans/binary-bifurcation.md:
  * single-crate repo (flat Cargo.toml at root)
  * sub-crate in a workspace (Cargo.toml lives deeper)
  * crate with multiple [[bin]] blocks (only the one matching the crate name
    is rewritten; ancillary binaries like `perf` stay put)
  * crate with [package.metadata.binstall] literals (not rewritten in this
    phase; binstall pkg-url templates use { name } at install time)
  * idempotent re-run on an already-rewritten manifest
  * dependency entries whose key coincides with the crate name are untouched
  * --dual-role copies the crate dir to target/bifurcate/<crate>-dev/ and
    rewrites the copy, leaving the original untouched
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "rewrite-binary-name.py"


def _run(
    workdir: Path,
    crate: str,
    *extra: str,
    suffix: str = "dev",
    expect_fail: bool = False,
) -> subprocess.CompletedProcess:
    proc = subprocess.run(
        [
            "python3",
            str(SCRIPT),
            "--crate",
            crate,
            "--suffix",
            suffix,
            "--workdir",
            str(workdir),
            *extra,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if expect_fail:
        if proc.returncode == 0:
            raise SystemExit(
                f"expected failure but script exited 0\nstdout: {proc.stdout}\nstderr: {proc.stderr}"
            )
    else:
        if proc.returncode != 0:
            sys.stderr.write(proc.stderr)
            raise SystemExit(f"script exited {proc.returncode}")
    return proc


def _write(root: Path, rel: str, body: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)


def _load(path: Path) -> dict:
    with open(path, "rb") as f:
        return tomllib.load(f)


def _assert(cond: bool, msg: str) -> None:
    if not cond:
        raise SystemExit(f"FAIL: {msg}")


def test_single_crate_root() -> None:
    """Flat repo: Cargo.toml at root, single [[bin]] matching the crate name."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "greentic-setup"
version = "0.4.12"
edition = "2024"

[[bin]]
name = "greentic-setup"
path = "src/bin/greentic-setup.rs"

[dependencies]
anyhow = "1"
""",
        )

        _run(root, "greentic-setup")

        data = _load(root / "Cargo.toml")
        _assert(
            data["package"]["name"] == "greentic-setup-dev",
            f"expected package.name='greentic-setup-dev', got {data['package']['name']!r}",
        )
        _assert(
            data["bin"][0]["name"] == "greentic-setup-dev",
            f"expected bin[0].name='greentic-setup-dev', got {data['bin'][0]['name']!r}",
        )
    print("OK  test_single_crate_root")


def test_sub_crate_in_workspace() -> None:
    """Crate lives at crates/<sub>/Cargo.toml; root has only [workspace]."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[workspace]
members = ["crates/greentic-provision-cli", "crates/greentic-provision-core"]
resolver = "2"
""",
        )
        _write(
            root,
            "crates/greentic-provision-cli/Cargo.toml",
            """\
[package]
name = "greentic-provision"
version = "0.4.5"
edition = "2024"

[dependencies]
anyhow = "1"
""",
        )
        _write(
            root,
            "crates/greentic-provision-core/Cargo.toml",
            """\
[package]
name = "greentic-provision-core"
version = "0.4.5"
edition = "2024"
""",
        )

        _run(root, "greentic-provision")

        cli = _load(root / "crates/greentic-provision-cli/Cargo.toml")
        core = _load(root / "crates/greentic-provision-core/Cargo.toml")
        _assert(
            cli["package"]["name"] == "greentic-provision-dev",
            f"expected cli.name='greentic-provision-dev', got {cli['package']['name']!r}",
        )
        _assert(
            core["package"]["name"] == "greentic-provision-core",
            "sibling crate must not be rewritten",
        )
    print("OK  test_sub_crate_in_workspace")


def test_multiple_bins_only_matching_rewritten() -> None:
    """Crate with multiple [[bin]] blocks; only the one named after the crate is rewritten."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "gtc"
version = "1.0.4"
edition = "2024"

[[bin]]
name = "gtc"
path = "src/bin/gtc.rs"

[[bin]]
name = "perf"
path = "src/bin/perf.rs"

[dependencies]
anyhow = "1"
""",
        )

        _run(root, "gtc")

        data = _load(root / "Cargo.toml")
        names = sorted(b["name"] for b in data["bin"])
        _assert(
            names == ["gtc-dev", "perf"],
            f"expected bin names ['gtc-dev', 'perf'], got {names}",
        )
    print("OK  test_multiple_bins_only_matching_rewritten")


def test_binstall_literals_not_rewritten() -> None:
    """[package.metadata.binstall] pkg-url + bin-dir literals are intentionally left alone."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        manifest = root / "Cargo.toml"
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "gtc"
version = "1.0.4"
edition = "2024"

[package.metadata.binstall]
pkg-url = "{ repo }/releases/download/v{ version }/{ name }-{ target }.{ archive-format }"
bin-dir = "gtc-{ target }/{ bin }{ binary-ext }"
pkg-fmt = "tgz"

[[bin]]
name = "gtc"
path = "src/bin/gtc.rs"
""",
        )

        _run(root, "gtc")

        text = manifest.read_text()
        _assert(
            'bin-dir = "gtc-{ target }/{ bin }{ binary-ext }"' in text,
            "binstall literal 'gtc-' reference must not be rewritten in C.1",
        )
        data = _load(manifest)
        _assert(data["package"]["name"] == "gtc-dev", "package.name should still be rewritten")
    print("OK  test_binstall_literals_not_rewritten")


def test_dependency_key_with_same_name_untouched() -> None:
    """A [dependencies] entry whose key coincides with the crate name must NOT be renamed."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        # Hypothetical: a crate named 'foo' depends on another crate called 'foo'
        # via a package rename. Unusual but legal.
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "foo"
version = "0.1.0"
edition = "2024"

[dependencies]
foo = { package = "some-other-foo", version = "1" }

[[bin]]
name = "foo"
path = "src/bin/foo.rs"
""",
        )

        _run(root, "foo")

        text = (root / "Cargo.toml").read_text()
        _assert(
            'foo = { package = "some-other-foo"' in text,
            "dependency key named 'foo' must not be rewritten",
        )
        data = _load(root / "Cargo.toml")
        _assert(data["package"]["name"] == "foo-dev", "package.name rewritten")
        _assert(data["bin"][0]["name"] == "foo-dev", "[[bin]].name rewritten")
    print("OK  test_dependency_key_with_same_name_untouched")


def test_idempotent_rerun() -> None:
    """Running twice must produce the same result as running once."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "greentic-gui"
version = "0.4.1"
edition = "2024"
""",
        )

        _run(root, "greentic-gui")
        first = (root / "Cargo.toml").read_text()
        # Second run: manifest now has [package].name == 'greentic-gui-dev'.
        # Script must detect this and no-op (not produce 'greentic-gui-dev-dev').
        _run(root, "greentic-gui")
        second = (root / "Cargo.toml").read_text()
        _assert(first == second, "second run must be a no-op")
        data = _load(root / "Cargo.toml")
        _assert(
            data["package"]["name"] == "greentic-gui-dev",
            "idempotent run must not double-suffix",
        )
    print("OK  test_idempotent_rerun")


def test_dual_role_copies_and_leaves_original_alone() -> None:
    """--dual-role stages a copy under target/bifurcate/ and rewrites only the copy."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "greentic-flow"
version = "0.4.2"
edition = "2024"

[lib]
path = "src/lib.rs"

[[bin]]
name = "greentic-flow"
path = "src/bin/greentic-flow.rs"

[dependencies]
anyhow = "1"
""",
        )
        _write(root, "src/lib.rs", "pub fn hello() {}\n")
        _write(root, "src/bin/greentic-flow.rs", "fn main() {}\n")

        _run(root, "greentic-flow", "--dual-role")

        # Original is unchanged.
        original = _load(root / "Cargo.toml")
        _assert(
            original["package"]["name"] == "greentic-flow",
            "dual-role must leave original [package].name alone",
        )

        # Copy exists at the expected location.
        copy_dir = root / "target" / "bifurcate" / "greentic-flow-dev"
        _assert(copy_dir.is_dir(), f"expected copy at {copy_dir}")
        _assert(
            (copy_dir / "src" / "lib.rs").is_file(),
            "copy must include source files",
        )

        # Copy has rewritten name.
        copy_manifest = _load(copy_dir / "Cargo.toml")
        _assert(
            copy_manifest["package"]["name"] == "greentic-flow-dev",
            f"expected copy.name='greentic-flow-dev', got {copy_manifest['package']['name']!r}",
        )
        _assert(
            copy_manifest["bin"][0]["name"] == "greentic-flow-dev",
            "copy's [[bin]].name must be rewritten",
        )
    print("OK  test_dual_role_copies_and_leaves_original_alone")


def test_missing_crate_fails() -> None:
    """If no Cargo.toml has [package].name == <crate>, script must exit non-zero."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "something-else"
version = "0.1.0"
edition = "2024"
""",
        )
        proc = _run(root, "nonexistent-crate", expect_fail=True)
        _assert(
            "no Cargo.toml with [package].name" in proc.stderr,
            f"expected 'no Cargo.toml' error, got: {proc.stderr!r}",
        )
    print("OK  test_missing_crate_fails")


def test_autodiscovered_src_bin_gets_bin_override() -> None:
    """Crate with src/bin/<crate>.rs but no [[bin]] block must get one injected.

    Without the injection, `cargo install <crate>-dev` would produce a binary
    named after the file stem (<crate>), not <crate>-dev. The injected [[bin]]
    makes cargo emit ~/.cargo/bin/<crate>-dev instead.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "greentic-mcp"
version = "0.5.1"
edition = "2024"

[dependencies]
anyhow = "1"
""",
        )
        _write(root, "src/lib.rs", "pub fn hello() {}\n")
        _write(root, "src/bin/greentic-mcp.rs", "fn main() {}\n")

        _run(root, "greentic-mcp")

        data = _load(root / "Cargo.toml")
        bins = [b["name"] for b in data.get("bin", [])]
        _assert(
            "greentic-mcp-dev" in bins,
            f"expected [[bin]] name='greentic-mcp-dev' injected, got {bins}",
        )
        injected = next(b for b in data["bin"] if b["name"] == "greentic-mcp-dev")
        _assert(
            injected["path"] == "src/bin/greentic-mcp.rs",
            f"injected [[bin]].path wrong: {injected['path']!r}",
        )
    print("OK  test_autodiscovered_src_bin_gets_bin_override")


def test_autodiscovered_idempotent() -> None:
    """Injecting [[bin]] once must be a no-op on re-run."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "greentic-flow"
version = "0.4.2"
edition = "2024"
""",
        )
        _write(root, "src/bin/greentic-flow.rs", "fn main() {}\n")

        _run(root, "greentic-flow")
        first = (root / "Cargo.toml").read_text()
        _run(root, "greentic-flow")
        second = (root / "Cargo.toml").read_text()
        _assert(first == second, "autodiscovered bin injection must be idempotent")
        data = _load(root / "Cargo.toml")
        count = sum(1 for b in data.get("bin", []) if b["name"] == "greentic-flow-dev")
        _assert(count == 1, f"expected exactly 1 injected [[bin]], got {count}")
    print("OK  test_autodiscovered_idempotent")


def test_main_rs_does_not_get_bin_override() -> None:
    """Crate with src/main.rs (no src/bin/) relies on [package].name — no injection needed."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "greentic-gui"
version = "0.4.1"
edition = "2024"
""",
        )
        _write(root, "src/main.rs", "fn main() {}\n")

        _run(root, "greentic-gui")

        data = _load(root / "Cargo.toml")
        _assert(
            data.get("bin") in (None, []),
            f"src/main.rs crate must not gain a [[bin]] override, got {data.get('bin')!r}",
        )
    print("OK  test_main_rs_does_not_get_bin_override")


def test_workspace_inherit_keys_preserved() -> None:
    """Workspace-inherited keys like `version.workspace = true` must round-trip intact."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        manifest = root / "Cargo.toml"
        body = """\
[package]
name = "greentic-runner"
version.workspace = true
edition.workspace = true
rust-version.workspace = true

[[bin]]
name = "greentic-runner"
path = "src/main.rs"

[dependencies]
anyhow.workspace = true
greentic-runner-host = { workspace = true }
"""
        _write(root, "Cargo.toml", body)

        _run(root, "greentic-runner")

        new_text = manifest.read_text()
        for preserved in (
            "version.workspace = true",
            "edition.workspace = true",
            "rust-version.workspace = true",
            "anyhow.workspace = true",
            "greentic-runner-host = { workspace = true }",
        ):
            _assert(
                preserved in new_text,
                f"expected '{preserved}' preserved in rewritten manifest",
            )
        data = _load(manifest)
        _assert(
            data["package"]["name"] == "greentic-runner-dev",
            "package.name rewritten",
        )
    print("OK  test_workspace_inherit_keys_preserved")


def main() -> int:
    test_single_crate_root()
    test_sub_crate_in_workspace()
    test_multiple_bins_only_matching_rewritten()
    test_binstall_literals_not_rewritten()
    test_dependency_key_with_same_name_untouched()
    test_idempotent_rerun()
    test_dual_role_copies_and_leaves_original_alone()
    test_missing_crate_fails()
    test_autodiscovered_src_bin_gets_bin_override()
    test_autodiscovered_idempotent()
    test_main_rs_does_not_get_bin_override()
    test_workspace_inherit_keys_preserved()
    print()
    print("all tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
