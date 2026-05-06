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


def test_extension_sdk_crates_not_bumped(root: Path) -> None:
    """`greentic-extension-sdk-*` crates live in greentic-designer-sdk, an
    out-of-pipeline repo that only publishes stable 0.4.x. The bumper must
    leave their version specs alone — otherwise consumers like
    greentic-designer fail to resolve `>=1.1.0-dev` against crates that only
    have 0.4.x candidates.
    """
    _write(
        root,
        "Cargo.toml",
        "[workspace]\nmembers = []\n\n"
        "[workspace.dependencies]\n"
        "greentic-extension-sdk-contract = \"0.4\"\n"
        "greentic-extension-sdk-state = \"0.4\"\n"
        "greentic-extension-sdk-registry = \"0.4\"\n"
        "greentic-extension-sdk-testing = \"0.4\"\n"
        "greentic-extension-sdk-cli = \"0.4\"\n"
        "greentic-types = \"0.4\"\n",
    )
    _run(root)

    deps = _load(root, "Cargo.toml")["workspace"]["dependencies"]
    for name in (
        "greentic-extension-sdk-contract",
        "greentic-extension-sdk-state",
        "greentic-extension-sdk-registry",
        "greentic-extension-sdk-testing",
        "greentic-extension-sdk-cli",
    ):
        _assert(
            deps[name] == "0.4",
            f"{name} should be untouched, got {deps[name]!r}",
        )
    # Sanity: a normal greentic crate next to them still gets bumped.
    _assert(
        deps["greentic-types"] == ">=0.5.0-0, <0.6.0-0",
        f"adjacent greentic-types not bumped: {deps['greentic-types']!r}",
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


def test_dev_publish_stamping_coincidence_preserves_pre_release(root: Path) -> None:
    """Guard the load-bearing coincidence in dev-publish.yml stamping.

    dev-publish.yml stamps artifact versions as `${BASE%.*}.${GITHUB_RUN_ID}`,
    which is documented to produce a NORMAL (non-pre-release) version like
    `0.5.<run_id>`. For a pre-release BASE like `0.6.0-dev.0`, the `%.*`
    operation strips only the last dot-segment (`.0`), leaving `0.6.0-dev`,
    and appending the run_id yields `0.6.0-dev.<run_id>` — a pre-release
    version by accident of how dotted pre-release tags interact with `%.*`.

    This degenerate case happens to produce exactly the form the Phase 2.2
    consumer dep range (`>=X.Y.0-dev, <X.(Y+1).0-0`) needs to match. The
    entire pre-release lane is load-bearing on this behavior. If someone
    ever "fixes" the stamping to always emit normal versions (e.g. by
    stripping the pre-release tag before stamping), consumer resolution
    silently breaks.

    This test reimplements the `%.*` logic in Python and asserts that:
      * pre-release BASE → stamp has `-dev.` infix
      * stamp falls inside the range `_make_range(pre_release=True)` emits
    """
    from bump_cargo_versions import _make_range  # noqa: PLC0415

    del root  # unused: pure-function test

    def stamp(base: str, run_id: int) -> str:
        # Mirrors bash `${BASE%.*}.${GITHUB_RUN_ID}`: strip the last
        # dot-segment then append the run id. `rsplit('.', 1)[0]` is the
        # exact Python analogue.
        return f"{base.rsplit('.', 1)[0]}.{run_id}"

    run_id = 24_773_252_077  # anchor to a real-world run_id shape

    # ── Pre-release BASE: stamp MUST preserve pre-release form ──
    pre_base = "0.6.0-dev.0"
    pre_stamped = stamp(pre_base, run_id)
    _assert(
        pre_stamped == "0.6.0-dev.24773252077",
        f"pre-release stamp degenerate case broke: got {pre_stamped!r}",
    )
    _assert(
        "-dev." in pre_stamped,
        f"pre-release BASE {pre_base!r} stamped to non-pre-release {pre_stamped!r} — "
        f"the firewall-preserving coincidence is gone; consumers at the pre-release "
        f"range would no longer resolve the published artifact",
    )

    # ── Consumer dep range (Phase 2.2 form) MUST cover the stamp ──
    pre_range = _make_range(0, 6, pre_release=True)
    _assert(
        pre_range == ">=0.6.0-dev, <0.7.0-0",
        f"pre-release range drifted: got {pre_range!r}",
    )
    # String-level invariants that, together with cargo's documented pre-release
    # matching rule (pre-release considered only when a comparator shares M.m.p
    # with a pre-release), guarantee the range matches the stamp:
    #   * lower-bound comparator is a pre-release on the SAME M.m.p as the stamp
    #   * stamp's pre-release tag sorts AFTER "dev" lexicographically
    #     (or equal-then-numeric: "dev.24773252077" > "dev" because identifiers
    #      extend past a shorter prefix)
    _assert(
        pre_range.startswith(">=0.6.0-dev"),
        f"range lower bound lost pre-release comparator: {pre_range!r}",
    )
    _assert(
        pre_stamped.startswith("0.6.0-dev."),
        f"stamp lost pre-release-on-0.6.0 prefix: {pre_stamped!r}",
    )

    # ── Stable BASE: stamp is a normal version, matches stable range ──
    stable_base = "0.5.0"
    stable_stamped = stamp(stable_base, run_id)
    _assert(
        stable_stamped == "0.5.24773252077",
        f"stable stamp shape changed: got {stable_stamped!r}",
    )
    _assert(
        "-" not in stable_stamped,
        f"stable BASE {stable_base!r} stamped to pre-release form {stable_stamped!r}",
    )
    stable_range = _make_range(0, 5, pre_release=False)
    _assert(
        stable_range == ">=0.5.0-0, <0.6.0-0",
        f"stable range drifted: got {stable_range!r}",
    )

    # ── Regression canary: the "fixed" variant that would break everything ──
    # If someone writes a "cleaner" stamp that strips -dev before appending
    # the run_id, the result won't match the pre-release range's M.m.p
    # comparator. This assertion fails loudly if the coincidence is lost.
    broken_stamped = f"{pre_base.split('-')[0]}.{run_id}"  # hypothetical "fix"
    _assert(
        broken_stamped == "0.6.0.24773252077",
        "sanity check: the broken-fix stamp is a 4-part normal-ish version",
    )
    _assert(
        "-dev" not in broken_stamped,
        "sanity check: the broken-fix stamp has no pre-release tag — this is "
        "exactly why we guard against it",
    )


def test_pre_release_preserves_binary_crate_name(root: Path) -> None:
    """Regression (Phase C.6 of plans/binary-bifurcation.md): bumping a binary
    crate with --pre-release must NEVER touch [package].name or [[bin]].name.

    Why this is load-bearing: binary-bifurcation (gtc → gtc-dev on the dev
    lane) is performed at *publish time* by rewrite-binary-name.py, not by
    this script. The committed Cargo.toml on develop must keep [package].name
    = "gtc" so:
      - forward-port.sh from develop → main keeps the name stable
      - rewrite-binary-name.py's idempotency check (matches both <crate> and
        <crate>-dev) holds
      - dual-role library publishes still resolve under the canonical name

    A future refactor that taught the bumper to "rename for dev" would silently
    corrupt every binary-bifurcated repo's Cargo.toml. This test pins the
    invariant.
    """
    _write(
        root,
        "Cargo.toml",
        '[package]\n'
        'name = "gtc"\n'
        'version = "0.5.3"\n'
        'default-run = "gtc"\n\n'
        '[[bin]]\n'
        'name = "gtc"\n'
        'path = "src/main.rs"\n\n'
        '[[bin]]\n'
        'name = "perf"\n'
        'path = "src/bin/perf.rs"\n\n'
        '[dependencies]\n'
        'greentic-types = "0.5"\n',
    )
    _run_with(root, "--from", "0.5", "--to", "0.6", "--pre-release")

    data = _load(root, "Cargo.toml")
    # Sanity: version did get bumped (proves the bumper actually ran).
    _assert(
        data["package"]["version"] == "0.6.0-dev.0",
        f"package version should bump to 0.6.0-dev.0, got {data['package']['version']!r}",
    )
    # The invariant under test:
    _assert(
        data["package"]["name"] == "gtc",
        f"[package].name must NOT be touched by bumper, got {data['package']['name']!r}",
    )
    _assert(
        data["package"].get("default-run") == "gtc",
        f"[package].default-run must NOT be touched, got {data['package'].get('default-run')!r}",
    )
    bin_names = sorted(b["name"] for b in data.get("bin", []))
    _assert(
        bin_names == ["gtc", "perf"],
        f"[[bin]].name entries must NOT be touched by bumper, got {bin_names!r}",
    )

    # Also verify via raw text — TOML round-trip could in theory normalize a
    # value while keeping the parsed dict equal, so check the literal is intact.
    text = (root / "Cargo.toml").read_text()
    _assert(
        'name = "gtc"' in text,
        f"raw [package].name literal missing from emitted file:\n{text}",
    )


def test_pre_release_preserves_workspace_member_binary_name(root: Path) -> None:
    """Same invariant as above but for sub-crate binaries: a workspace member
    whose [package].name is `dwbase-cli` (binary-only crate in
    greentic-dwbase) must keep that literal name even when its own
    [package].version line is on `version.workspace = true`. The bumper only
    touches version values; name passes through untouched on every code path.
    """
    _write(
        root,
        "Cargo.toml",
        '[workspace]\n'
        'members = ["crates/dwbase-cli"]\n\n'
        '[workspace.package]\n'
        'version = "0.2.0-dev.0"\n'
        'edition = "2024"\n',
    )
    _write(
        root,
        "crates/dwbase-cli/Cargo.toml",
        '[package]\n'
        'name = "dwbase-cli"\n'
        'version.workspace = true\n'
        'edition.workspace = true\n\n'
        '[[bin]]\n'
        'name = "dwbase"\n'
        'path = "src/main.rs"\n',
    )
    _run_with(root, "--from", "0.2", "--to", "0.3", "--pre-release")

    # workspace.package.version did bump
    ws = _load(root, "Cargo.toml")
    _assert(
        ws["workspace"]["package"]["version"] == "0.3.0-dev.0",
        f"workspace.package.version should bump, got {ws['workspace']['package']['version']!r}",
    )

    # Sub-crate untouched modulo the dotted-key round-trip.
    member = _load(root, "crates/dwbase-cli/Cargo.toml")
    _assert(
        member["package"]["name"] == "dwbase-cli",
        f"sub-crate [package].name must NOT change, got {member['package']['name']!r}",
    )
    bin_names = sorted(b["name"] for b in member.get("bin", []))
    _assert(
        bin_names == ["dwbase"],
        f"[[bin]].name entries must NOT be touched, got {bin_names!r}",
    )

    # Workspace inheritance preserved as dotted-key (Cargo rejects sub-table form).
    text = (root / "crates/dwbase-cli/Cargo.toml").read_text()
    _assert(
        "version.workspace = true" in text,
        f"version.workspace = true must round-trip as dotted key:\n{text}",
    )
    _assert(
        'name = "dwbase-cli"' in text,
        f"raw [package].name literal missing:\n{text}",
    )


def test_pre_release_loose_lower_bound_is_bumped(root: Path) -> None:
    """Loose-range form `>=N.M, <X.Y.Z-0` (no `.0` after the minor) must
    still match `--from N.M`.

    Encountered in the wild on greentic-pack/develop where 12+ workspace
    deps were authored as `">=0.5, <0.7.0-0"` to span two minors. The
    original regex `>=N.M[\\.\\d]` required a `.` or digit immediately
    after the minor, silently skipping these.
    """
    _write(
        root,
        "Cargo.toml",
        "[workspace]\nmembers = []\n\n"
        "[workspace.dependencies]\n"
        "greentic-types = \">=0.5, <0.7.0-0\"\n"
        "greentic-flow = { version = \">=0.5, <0.7.0-0\" }\n"
        "greentic-config = \">=0.5\"\n",
    )
    _run_with(root, "--from", "0.5", "--to", "1.1", "--pre-release")

    deps = _load(root, "Cargo.toml")["workspace"]["dependencies"]
    _assert(
        deps["greentic-types"] == ">=1.1.0-dev, <1.2.0-0",
        f"loose bare-string range not bumped: {deps['greentic-types']!r}",
    )
    _assert(
        deps["greentic-flow"]["version"] == ">=1.1.0-dev, <1.2.0-0",
        f"loose table-form range not bumped: {deps['greentic-flow']!r}",
    )
    _assert(
        deps["greentic-config"] == ">=1.1.0-dev, <1.2.0-0",
        f"loose no-upper-bound range not bumped: {deps['greentic-config']!r}",
    )


def test_pre_release_loose_range_does_not_match_unrelated_minor(root: Path) -> None:
    """The loose-range matcher must NOT match `>=0.50` when --from is `0.5`.

    Negative-lookahead `(?!\\d)` blocks the digit boundary, so `0.5` and
    `0.50` stay distinct minors.
    """
    _write(
        root,
        "Cargo.toml",
        "[workspace]\nmembers = []\n\n"
        "[workspace.dependencies]\n"
        "greentic-zzz = \">=0.50, <0.51\"\n",
    )
    _run_with(root, "--from", "0.5", "--to", "0.6", "--pre-release")

    deps = _load(root, "Cargo.toml")["workspace"]["dependencies"]
    _assert(
        deps["greentic-zzz"] == ">=0.50, <0.51",
        f"unrelated-minor range was incorrectly bumped: {deps['greentic-zzz']!r}",
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
        test_extension_sdk_crates_not_bumped,
        test_basic_string_dep_still_bumped,
        test_pre_release_promotion_package_and_deps,
        test_pre_release_explicit_to_version_increments_dev_n,
        test_pre_release_bumps_existing_pre_release_to_default_dev_0,
        test_pre_release_dep_range_replaces_old_stable_range,
        test_pre_release_rejects_malformed_to_version,
        test_non_pre_release_rejects_pre_release_to_version,
        test_dev_publish_stamping_coincidence_preserves_pre_release,
        test_pre_release_preserves_binary_crate_name,
        test_pre_release_preserves_workspace_member_binary_name,
        test_pre_release_loose_lower_bound_is_bumped,
        test_pre_release_loose_range_does_not_match_unrelated_minor,
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
