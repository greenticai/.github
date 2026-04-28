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


def test_inline_bin_array_at_root() -> None:
    """Manifest using inline ``bin = [{name = "<crate>", ...}]`` at the root
    must rewrite the inline name, not append a [[bin]] block.

    Reproduces the greentic Cargo.toml layout where target arrays are inline
    at the top of the file. Appending [[bin]] in this case produced an invalid
    TOML manifest ("Cannot mutate immutable namespace ('bin',)") because the
    array was already defined as inline.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
bin = [
    { name = "gtc", path = "src/bin/gtc.rs" },
]
bench = [
    { name = "perf", harness = false },
]

[package]
name = "gtc"
version = "1.1.0-dev.0"
edition = "2024"
repository = "https://github.com/greenticai/greentic"

[package.metadata.binstall]
pkg-url = "{ repo }/releases/download/v{ version }/{ name }-{ target }.{ archive-format }"
bin-dir = "gtc-{ target }/{ bin }{ binary-ext }"
pkg-fmt = "tgz"

[dependencies]
anyhow = "1"
""",
        )
        _write(root, "src/bin/gtc.rs", "fn main() {}\n")

        _run(root, "gtc")

        data = _load(root / "Cargo.toml")
        _assert(
            data["package"]["name"] == "gtc-dev",
            f"expected package.name='gtc-dev', got {data['package']['name']!r}",
        )
        bin_names = sorted(b["name"] for b in data["bin"])
        _assert(
            bin_names == ["gtc-dev"],
            f"expected single inline bin renamed to 'gtc-dev', got {bin_names}",
        )
        # Existing binstall metadata is the author's; must stay intact.
        binstall = data["package"]["metadata"]["binstall"]
        _assert(
            binstall["bin-dir"] == "gtc-{ target }/{ bin }{ binary-ext }",
            f"author-supplied binstall must not be overwritten, got {binstall!r}",
        )
    print("OK  test_inline_bin_array_at_root")


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


def test_dual_role_resolves_workspace_package_inherit() -> None:
    """Dual-role copy must inline [workspace.package.*] values over `.workspace = true`."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[workspace]
members = ["crates/mycrate"]

[workspace.package]
version = "0.4.2"
edition = "2024"
license = "MIT"
repository = "https://example.com/repo"
""",
        )
        _write(
            root,
            "crates/mycrate/Cargo.toml",
            """\
[package]
name = "mycrate"
version.workspace = true
edition.workspace = true
license.workspace = true
repository.workspace = true

[[bin]]
name = "mycrate"
path = "src/main.rs"
""",
        )
        _write(root, "crates/mycrate/src/main.rs", "fn main() {}\n")

        _run(root, "mycrate", "--dual-role")

        copy = _load(
            root / "target" / "bifurcate" / "mycrate-dev" / "Cargo.toml"
        )
        pkg = copy["package"]
        _assert(pkg["version"] == "0.4.2", f"version resolved, got {pkg['version']!r}")
        _assert(pkg["edition"] == "2024", f"edition resolved, got {pkg['edition']!r}")
        _assert(pkg["license"] == "MIT", "license resolved")
        _assert(
            pkg["repository"] == "https://example.com/repo", "repository resolved"
        )
        # Copy should declare itself a workspace root so cargo doesn't hunt for
        # an ancestor workspace (which no longer exists under target/bifurcate).
        _assert("workspace" in copy, "copy must declare [workspace]")
    print("OK  test_dual_role_resolves_workspace_package_inherit")


def test_dual_role_resolves_workspace_dependencies_inherit() -> None:
    """Dual-role copy must inline [workspace.dependencies.*] values over `.workspace = true`."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[workspace]
members = ["crates/mycrate"]

[workspace.package]
version = "0.5.0"

[workspace.dependencies]
anyhow = "1"
clap = { version = "4.5", features = ["derive"] }
""",
        )
        _write(
            root,
            "crates/mycrate/Cargo.toml",
            """\
[package]
name = "mycrate"
version.workspace = true
edition = "2024"

[dependencies]
anyhow.workspace = true
clap = { workspace = true, features = ["env"] }

[[bin]]
name = "mycrate"
path = "src/main.rs"
""",
        )
        _write(root, "crates/mycrate/src/main.rs", "fn main() {}\n")

        _run(root, "mycrate", "--dual-role")

        copy = _load(
            root / "target" / "bifurcate" / "mycrate-dev" / "Cargo.toml"
        )
        deps = copy["dependencies"]
        _assert(
            deps["anyhow"] == "1" or (isinstance(deps["anyhow"], dict) and deps["anyhow"].get("version") == "1"),
            f"anyhow resolved to workspace value, got {deps['anyhow']!r}",
        )
        clap = deps["clap"]
        _assert(
            isinstance(clap, dict) and clap["version"] == "4.5",
            f"clap version resolved, got {clap!r}",
        )
        # Merged features: local "env" + workspace "derive"
        feats = clap.get("features")
        _assert(
            "env" in (feats or []),
            f"local features must merge into resolved spec, got {feats!r}",
        )
    print("OK  test_dual_role_resolves_workspace_dependencies_inherit")


def test_dual_role_strips_path_from_inherited_dep() -> None:
    """Workspace deps with both `version` and `path` must have `path` stripped post-copy."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[workspace]
members = ["crates/mycrate", "crates/sibling"]

[workspace.package]
version = "0.1.0"

[workspace.dependencies]
sibling = { version = "0.1", path = "crates/sibling" }
""",
        )
        _write(
            root,
            "crates/mycrate/Cargo.toml",
            """\
[package]
name = "mycrate"
version.workspace = true
edition = "2024"

[dependencies]
sibling.workspace = true
""",
        )
        _write(
            root,
            "crates/sibling/Cargo.toml",
            """\
[package]
name = "sibling"
version = "0.1.0"
edition = "2024"
""",
        )

        _run(root, "mycrate", "--dual-role")

        copy = _load(
            root / "target" / "bifurcate" / "mycrate-dev" / "Cargo.toml"
        )
        sibling = copy["dependencies"]["sibling"]
        _assert(
            isinstance(sibling, dict) and sibling.get("version") == "0.1",
            f"sibling keeps version, got {sibling!r}",
        )
        _assert(
            "path" not in sibling,
            f"sibling must have `path` stripped for standalone publish, got {sibling!r}",
        )
    print("OK  test_dual_role_strips_path_from_inherited_dep")


def test_dual_role_workspace_root_excludes_sibling_members() -> None:
    """When the crate is AT the workspace root (greentic-bundle style), the copy
    brings sibling member dirs along. They must land in [workspace].exclude so
    cargo doesn't try to parse their dangling inheritance."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[workspace]
members = ["crates/reader"]

[workspace.package]
version = "0.5.2"

[package]
name = "mybundle"
version.workspace = true
edition = "2024"
""",
        )
        _write(
            root,
            "crates/reader/Cargo.toml",
            """\
[package]
name = "reader"
version.workspace = true
edition = "2024"
""",
        )

        _run(root, "mybundle", "--dual-role")

        copy = _load(root / "target" / "bifurcate" / "mybundle-dev" / "Cargo.toml")
        ws = copy["workspace"]
        _assert(
            "crates/reader" in ws.get("exclude", []),
            f"sibling crate must be in workspace.exclude, got {ws!r}",
        )
    print("OK  test_dual_role_workspace_root_excludes_sibling_members")


def test_dual_role_fixup_escaping_readme() -> None:
    """A sub-crate whose [package].readme points at `../../README.md` must have
    that file pulled into the copy root and the manifest rewritten to reference
    just the basename. Without this, cargo publish errors out because the copy
    lives at target/bifurcate/... where the relative path no longer resolves."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[workspace]
members = ["crates/mycrate"]

[workspace.package]
version = "0.1.0"
""",
        )
        _write(root, "README.md", "# Project README\n")
        _write(
            root,
            "crates/mycrate/Cargo.toml",
            """\
[package]
name = "mycrate"
version.workspace = true
edition = "2024"
readme = "../../README.md"
""",
        )

        _run(root, "mycrate", "--dual-role")

        copy_dir = root / "target" / "bifurcate" / "mycrate-dev"
        _assert(
            (copy_dir / "README.md").is_file(),
            "escaping readme must be pulled into the copy root",
        )
        copy_text = (copy_dir / "Cargo.toml").read_text()
        _assert(
            'readme = "README.md"' in copy_text,
            f"readme path must be rewritten to basename, got:\n{copy_text}",
        )
    print("OK  test_dual_role_fixup_escaping_readme")


def test_dual_role_inherit_missing_key_errors() -> None:
    """Inheriting a key that doesn't exist in [workspace.package] must error out."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[workspace]
members = ["crates/mycrate"]

[workspace.package]
version = "0.1.0"
""",
        )
        _write(
            root,
            "crates/mycrate/Cargo.toml",
            """\
[package]
name = "mycrate"
version.workspace = true
edition.workspace = true

[[bin]]
name = "mycrate"
path = "src/main.rs"
""",
        )

        proc = _run(root, "mycrate", "--dual-role", expect_fail=True)
        _assert(
            "edition" in proc.stderr and "not defined" in proc.stderr,
            f"expected clear error about missing edition, got: {proc.stderr!r}",
        )
    print("OK  test_dual_role_inherit_missing_key_errors")


def test_binstall_metadata_injected_when_absent() -> None:
    """Crate without [package.metadata.binstall] gets a default block pointing
    at the dev-release-binaries.yml archive layout."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "greentic-setup"
version = "0.5.0"
edition = "2024"
repository = "https://github.com/greenticai/greentic-setup"

[[bin]]
name = "greentic-setup"
path = "src/main.rs"
""",
        )
        _run(root, "greentic-setup")
        data = _load(root / "Cargo.toml")
        binstall = data.get("package", {}).get("metadata", {}).get("binstall")
        _assert(binstall is not None, "expected binstall block injected")
        _assert(
            binstall["pkg-url"]
            == "{ repo }/releases/download/v{ version }/"
            "{ name }-v{ version }-{ target }{ archive-suffix }",
            f"wrong pkg-url template: {binstall.get('pkg-url')!r}",
        )
        _assert(
            binstall["bin-dir"]
            == "{ name }-v{ version }-{ target }/{ bin }{ binary-ext }",
            f"wrong bin-dir template: {binstall.get('bin-dir')!r}",
        )
        _assert(binstall["pkg-fmt"] == "tgz", f"wrong pkg-fmt: {binstall!r}")
    print("OK  test_binstall_metadata_injected_when_absent")


def test_binstall_injection_idempotent() -> None:
    """Re-running after binstall injection must not duplicate or alter the block."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "greentic-provision"
version = "0.5.0"
edition = "2024"
repository = "https://github.com/greenticai/greentic-provision"

[[bin]]
name = "greentic-provision"
path = "src/main.rs"
""",
        )
        _run(root, "greentic-provision")
        first = (root / "Cargo.toml").read_text()
        _run(root, "greentic-provision")
        second = (root / "Cargo.toml").read_text()
        _assert(first == second, "re-run after injection must be a no-op")
        # Also ensure the binstall block appears exactly once.
        _assert(
            first.count("[package.metadata.binstall]") == 1,
            "binstall block must appear exactly once",
        )
    print("OK  test_binstall_injection_idempotent")


def test_binstall_existing_not_overwritten() -> None:
    """Crate with custom [package.metadata.binstall] keeps its metadata untouched.

    Verifies author-supplied archive URLs survive the rewrite. Distinct from
    test_binstall_literals_not_rewritten which asserts pkg-url strings
    containing the crate name aren't textually rewritten.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "gtc"
version = "1.0.0"
edition = "2024"

[package.metadata.binstall]
pkg-url = "https://custom.example.com/{ name }-{ version }-{ target }.tar.gz"
pkg-fmt = "tgz"

[[bin]]
name = "gtc"
path = "src/main.rs"
""",
        )
        _run(root, "gtc")
        data = _load(root / "Cargo.toml")
        binstall = data["package"]["metadata"]["binstall"]
        _assert(
            binstall["pkg-url"]
            == "https://custom.example.com/{ name }-{ version }-{ target }.tar.gz",
            f"author-supplied pkg-url was overwritten: {binstall.get('pkg-url')!r}",
        )
        _assert(
            "bin-dir" not in binstall,
            "must not inject bin-dir when author already set binstall metadata",
        )
    print("OK  test_binstall_existing_not_overwritten")


def test_dual_role_copy_has_binstall_metadata() -> None:
    """Staged dual-role copy must carry the injected binstall block.

    This is what makes `cargo binstall <crate>-dev --registry …` resolve
    the correct archive URL on the dev lane.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "greentic-setup"
version = "0.5.0"
edition = "2024"
repository = "https://github.com/greenticai/greentic-setup"

[lib]
path = "src/lib.rs"

[[bin]]
name = "greentic-setup"
path = "src/main.rs"
""",
        )
        _write(root, "src/lib.rs", "")
        _write(root, "src/main.rs", "fn main() {}\n")

        _run(root, "greentic-setup", "--dual-role")

        # Original stays clean — library consumers don't want dev-only binstall
        # metadata leaking into their crates.io publishes.
        orig = _load(root / "Cargo.toml")
        _assert(
            "binstall" not in orig.get("package", {}).get("metadata", {}),
            "original library manifest must not gain binstall metadata",
        )

        copy_manifest = root / "target" / "bifurcate" / "greentic-setup-dev" / "Cargo.toml"
        copy = _load(copy_manifest)
        binstall = copy["package"]["metadata"]["binstall"]
        _assert(
            binstall["pkg-url"].endswith("-{ target }{ archive-suffix }"),
            f"copy pkg-url missing archive-suffix template: {binstall.get('pkg-url')!r}",
        )
        _assert(binstall["pkg-fmt"] == "tgz", f"wrong pkg-fmt: {binstall!r}")
    print("OK  test_dual_role_copy_has_binstall_metadata")


def test_lib_name_pinned_when_lib_rs_exists() -> None:
    """Crate with src/lib.rs but no [lib] table gains an explicit [lib] name pin.

    Without the pin, cargo derives the lib name from [package].name. Once we
    rename the package to <crate>-dev, the auto-derived lib name silently
    becomes <crate>_dev — breaking every `use <crate>::...` import in the
    same crate's bin source. Reproduces the gtc-dev source-build failure.
    """
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

[[bin]]
name = "greentic-flow"
path = "src/bin/greentic-flow.rs"
""",
        )
        _write(root, "src/lib.rs", "pub fn hello() {}\n")
        _write(root, "src/bin/greentic-flow.rs", "fn main() {}\n")

        _run(root, "greentic-flow")

        data = _load(root / "Cargo.toml")
        _assert(
            data["package"]["name"] == "greentic-flow-dev",
            f"expected package renamed, got {data['package']['name']!r}",
        )
        _assert("lib" in data, "expected [lib] section injected")
        _assert(
            data["lib"].get("name") == "greentic_flow",
            f"expected [lib].name='greentic_flow' (dash-to-underscore), got {data['lib'].get('name')!r}",
        )
    print("OK  test_lib_name_pinned_when_lib_rs_exists")


def test_lib_no_inject_when_no_lib_rs() -> None:
    """Pure binary crate (no src/lib.rs) must not gain a [lib] section.

    Injecting [lib] when there's no lib source would make cargo error with
    'can't find crate root for `lib`'.
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

[[bin]]
name = "greentic-mcp"
path = "src/bin/greentic-mcp.rs"
""",
        )
        _write(root, "src/bin/greentic-mcp.rs", "fn main() {}\n")

        _run(root, "greentic-mcp")

        data = _load(root / "Cargo.toml")
        _assert(
            "lib" not in data,
            f"binary-only crate must not gain [lib], got {data.get('lib')!r}",
        )
    print("OK  test_lib_no_inject_when_no_lib_rs")


def test_lib_existing_not_overwritten() -> None:
    """Crate with explicit [lib] is left alone — author opted out of auto-discovery."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "greentic-pack"
version = "0.5.0"
edition = "2024"

[lib]
name = "packlib"
path = "src/packlib.rs"

[[bin]]
name = "greentic-pack"
path = "src/bin/greentic-pack.rs"
""",
        )
        _write(root, "src/lib.rs", "pub fn hello() {}\n")
        _write(root, "src/packlib.rs", "pub fn hello() {}\n")
        _write(root, "src/bin/greentic-pack.rs", "fn main() {}\n")

        _run(root, "greentic-pack")

        data = _load(root / "Cargo.toml")
        lib = data.get("lib", {})
        _assert(
            lib.get("name") == "packlib",
            f"author-supplied [lib].name must survive, got {lib.get('name')!r}",
        )
        _assert(
            lib.get("path") == "src/packlib.rs",
            f"author-supplied [lib].path must survive, got {lib.get('path')!r}",
        )
    print("OK  test_lib_existing_not_overwritten")


def test_dual_role_overrides_author_binstall() -> None:
    """Dual-role mode replaces any author-supplied [package.metadata.binstall].

    The author block is configured for the stable release tag/archive layout
    and won't match dev-release-binaries.yml output. The staged copy is
    ephemeral (one publish, then discarded), so we override unconditionally.
    The original Cargo.toml on develop stays untouched — verified separately.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "gtc"
version = "1.1.0"
edition = "2024"
repository = "https://github.com/greenticai/greentic"

[package.metadata.binstall]
pkg-url = "{ repo }/releases/download/v{ version }/{ name }-{ target }.{ archive-format }"
bin-dir = "gtc-{ target }/{ bin }{ binary-ext }"
pkg-fmt = "tgz"

[package.metadata.binstall.overrides.x86_64-pc-windows-msvc]
pkg-fmt = "zip"

[[bin]]
name = "gtc"
path = "src/bin/gtc.rs"
""",
        )
        _write(root, "src/bin/gtc.rs", "fn main() {}\n")

        _run(root, "gtc", "--dual-role")

        # Original stays as the author wrote it.
        orig = _load(root / "Cargo.toml")
        orig_binstall = orig["package"]["metadata"]["binstall"]
        _assert(
            orig_binstall["bin-dir"] == "gtc-{ target }/{ bin }{ binary-ext }",
            "original Cargo.toml must keep author binstall intact",
        )
        _assert(
            "overrides" in orig_binstall,
            "original Cargo.toml must keep [...binstall.overrides.*] sub-tables",
        )

        # Staged copy gets the dev-pipeline-compatible layout, no overrides.
        copy = _load(root / "target" / "bifurcate" / "gtc-dev" / "Cargo.toml")
        copy_binstall = copy["package"]["metadata"]["binstall"]
        _assert(
            copy_binstall["pkg-url"]
            == "{ repo }/releases/download/v{ version }/"
            "{ name }-v{ version }-{ target }{ archive-suffix }",
            f"copy pkg-url not the dev layout: {copy_binstall.get('pkg-url')!r}",
        )
        _assert(
            copy_binstall["bin-dir"]
            == "{ name }-v{ version }-{ target }/{ bin }{ binary-ext }",
            f"copy bin-dir not the dev layout: {copy_binstall.get('bin-dir')!r}",
        )
        _assert(
            "overrides" not in copy_binstall,
            f"author overrides must be dropped on the dev copy, got {copy_binstall!r}",
        )
    print("OK  test_dual_role_overrides_author_binstall")


def test_default_run_rewritten_when_matches_crate() -> None:
    """`default-run = "<crate>"` in [package] must be rewritten to "<crate>-dev".

    Reproduces the greentic-component layout: the package has both a
    matching [[bin]] (auto-discovered from src/bin/<crate>.rs) AND a
    `default-run = "<crate>"` selector. After the bin gets renamed to
    <crate>-dev, default-run must follow or cargo errors with
    `default-run target '<crate>' not found`.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "greentic-component"
version = "0.6.0-dev.0"
edition = "2024"
default-run = "greentic-component"

[lib]
name = "greentic_component"
path = "src/lib.rs"
""",
        )
        _write(root, "src/lib.rs", "pub fn hello() {}\n")
        _write(root, "src/bin/greentic-component.rs", "fn main() {}\n")
        _write(root, "src/bin/component-doctor.rs", "fn main() {}\n")

        _run(root, "greentic-component")

        data = _load(root / "Cargo.toml")
        _assert(
            data["package"]["name"] == "greentic-component-dev",
            f"expected package renamed, got {data['package']['name']!r}",
        )
        _assert(
            data["package"].get("default-run") == "greentic-component-dev",
            f"expected default-run rewritten, got {data['package'].get('default-run')!r}",
        )
    print("OK  test_default_run_rewritten_when_matches_crate")


def test_default_run_unrelated_left_alone() -> None:
    """`default-run` pointing at a bin OTHER than the crate name must not be touched."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "greentic-component"
version = "0.6.0-dev.0"
edition = "2024"
default-run = "component-doctor"

[[bin]]
name = "greentic-component"
path = "src/bin/greentic-component.rs"

[[bin]]
name = "component-doctor"
path = "src/bin/component-doctor.rs"
""",
        )

        _run(root, "greentic-component")

        data = _load(root / "Cargo.toml")
        _assert(
            data["package"].get("default-run") == "component-doctor",
            f"unrelated default-run must survive, got {data['package'].get('default-run')!r}",
        )
        # And the matching bin must still be renamed.
        names = sorted(b["name"] for b in data["bin"])
        _assert(
            names == ["component-doctor", "greentic-component-dev"],
            f"expected bins ['component-doctor', 'greentic-component-dev'], got {names}",
        )
    print("OK  test_default_run_unrelated_left_alone")


def test_default_run_in_workspace_not_touched() -> None:
    """`default-run` in [workspace.package] (or other non-[package] tables) must be ignored.

    `default-run` is package-level only — cargo doesn't honor it on workspace
    tables — but the script's state machine must still skip it to avoid
    false-positive rewrites.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
[package]
name = "mycrate"
version = "0.1.0"
edition = "2024"

[package.metadata.custom]
default-run = "mycrate"
""",
        )

        _run(root, "mycrate")

        text = (root / "Cargo.toml").read_text()
        _assert(
            'default-run = "mycrate"' in text,
            "default-run inside [package.metadata.custom] must not be rewritten",
        )
        data = _load(root / "Cargo.toml")
        _assert(data["package"]["name"] == "mycrate-dev", "package.name still rewritten")
    print("OK  test_default_run_in_workspace_not_touched")


def test_dual_role_gtc_shape_end_to_end() -> None:
    """End-to-end: gtc's exact layout (inline bin array at root + src/lib.rs +
    author binstall + bin uses `use <crate>::...`) must produce a staged copy
    where (a) [package].name='gtc-dev', (b) inline bin renamed to 'gtc-dev',
    (c) [lib].name pinned to 'gtc' so internal imports resolve, and
    (d) binstall metadata is the dev-pipeline layout, not the author's.

    Reproduces the failure mode of run 25052566037 / gtc-dev v1.1.25053490868.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write(
            root,
            "Cargo.toml",
            """\
bin = [
    { name = "gtc", path = "src/bin/gtc.rs" },
]
bench = [
    { name = "perf", harness = false },
]

[package]
name = "gtc"
version = "1.1.0-dev.0"
edition = "2024"
repository = "https://github.com/greenticai/greentic"

[package.metadata.binstall]
pkg-url = "{ repo }/releases/download/v{ version }/{ name }-{ target }.{ archive-format }"
bin-dir = "gtc-{ target }/{ bin }{ binary-ext }"
pkg-fmt = "tgz"

[dependencies]
anyhow = "1"
""",
        )
        _write(root, "src/lib.rs", "pub mod error { pub struct GtcError; }\n")
        _write(
            root,
            "src/bin/gtc.rs",
            "use gtc::error::GtcError;\nfn main() { let _ = GtcError; }\n",
        )

        _run(root, "gtc", "--dual-role")

        copy = _load(root / "target" / "bifurcate" / "gtc-dev" / "Cargo.toml")
        _assert(
            copy["package"]["name"] == "gtc-dev",
            f"package renamed, got {copy['package']['name']!r}",
        )
        bin_names = sorted(b["name"] for b in copy.get("bin", []))
        _assert(
            bin_names == ["gtc-dev"],
            f"inline bin renamed, got {bin_names}",
        )
        _assert(
            copy.get("lib", {}).get("name") == "gtc",
            f"lib name pinned to original, got {copy.get('lib')!r}",
        )
        binstall = copy["package"]["metadata"]["binstall"]
        _assert(
            binstall["pkg-url"].endswith("-{ target }{ archive-suffix }"),
            f"binstall forced to dev layout, got {binstall.get('pkg-url')!r}",
        )
        _assert(
            binstall["bin-dir"]
            == "{ name }-v{ version }-{ target }/{ bin }{ binary-ext }",
            f"binstall bin-dir forced to dev layout, got {binstall.get('bin-dir')!r}",
        )
    print("OK  test_dual_role_gtc_shape_end_to_end")


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
    test_inline_bin_array_at_root()
    test_main_rs_does_not_get_bin_override()
    test_workspace_inherit_keys_preserved()
    test_dual_role_resolves_workspace_package_inherit()
    test_dual_role_resolves_workspace_dependencies_inherit()
    test_dual_role_strips_path_from_inherited_dep()
    test_dual_role_workspace_root_excludes_sibling_members()
    test_dual_role_fixup_escaping_readme()
    test_dual_role_inherit_missing_key_errors()
    test_binstall_metadata_injected_when_absent()
    test_binstall_injection_idempotent()
    test_binstall_existing_not_overwritten()
    test_dual_role_copy_has_binstall_metadata()
    test_lib_name_pinned_when_lib_rs_exists()
    test_lib_no_inject_when_no_lib_rs()
    test_lib_existing_not_overwritten()
    test_dual_role_overrides_author_binstall()
    test_default_run_rewritten_when_matches_crate()
    test_default_run_unrelated_left_alone()
    test_default_run_in_workspace_not_touched()
    test_dual_role_gtc_shape_end_to_end()
    print()
    print("all tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
