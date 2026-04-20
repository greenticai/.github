#!/usr/bin/env python3
"""Structure-aware Cargo.toml version bumper for the Greentic ecosystem.

Walks all Cargo.toml files under a directory and bumps:
  - package / workspace.package versions matching --from prefix
  - greentic dependency version specs to a pre-release-compatible range

Uses tomllib (read) + tomli_w (write) for structure-aware TOML editing.

Examples
--------
Minor bump (writes ``X.Y.0`` for the package version)::

    bump_cargo_versions.py --from 0.4 --to 0.5 ./greentic-bundle

Patch bump within a minor (writes the exact ``--to-version``)::

    bump_cargo_versions.py --from 0.5 --to 0.5 --to-version 0.5.1 ./greentic-runner

Convert dep specs to range form without touching package versions::

    bump_cargo_versions.py --from 0.4 --to 0.5 --deps-only ./greentic-runner
"""

from __future__ import annotations

import argparse
import re
import sys
import tomllib
from pathlib import Path

import tomli_w

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Crate names that belong to the greentic ecosystem but don't use the
# "greentic-" prefix.  These get their version specs bumped too.
EXTRA_GREENTIC_CRATES: frozenset[str] = frozenset(
    {
        "qa-spec",
        "component-qa",
        "greentic-qa-lib",
        "pack_component",
        "pack_component_template",
        "greentic-pack-lib",
        "oauth-testharness",
        "runner-core",
    }
)

# Crates on a separate version track — never touch their versions.
SKIP_CRATES: frozenset[str] = frozenset(
    {
        "serde_yaml_gtc",
        "serde_yaml_bw",
    }
)

# Dependency table keys we process (top-level and inside [target.'…'.*]).
DEP_SECTIONS: tuple[str, ...] = (
    "dependencies",
    "dev-dependencies",
    "build-dependencies",
)

# Keys in [package] / [workspace.package] that Cargo's manifest parser expects
# to be either a string or an inline table — never a sub-table.  When tomli_w
# round-trips a workspace-inheritance value (`{"workspace": True}`) at one of
# these keys it emits `[package.version]\nworkspace = true` (sub-table form),
# which Cargo rejects with "expected a version string or an inline table".
# Workaround: before dumping, swap the dict for a sentinel string so tomli_w
# emits a leaf key; afterwards rewrite the sentinel back to dotted-key form.
INHERITABLE_PACKAGE_KEYS: frozenset[str] = frozenset(
    {
        "version",
        "edition",
        "rust-version",
        "license",
        "license-file",
        "authors",
        "categories",
        "description",
        "documentation",
        "homepage",
        "keywords",
        "publish",
        "readme",
        "repository",
        "exclude",
        "include",
        "links",
    }
)

WORKSPACE_INHERIT_SENTINEL: str = "__GREENTIC_WORKSPACE_INHERIT__"
_SENTINEL_LINE_RE = re.compile(
    rf'^(?P<indent>[ \t]*)(?P<key>[A-Za-z0-9_-]+)\s*=\s*"{re.escape(WORKSPACE_INHERIT_SENTINEL)}"\s*$',
    re.MULTILINE,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _parse_minor(ver: str) -> tuple[int, int]:
    """Parse a 'major.minor' string into (major, minor)."""
    parts = ver.split(".")
    if len(parts) != 2:
        raise argparse.ArgumentTypeError(
            f"Version prefix must be major.minor (e.g. 0.4), got: {ver!r}"
        )
    return int(parts[0]), int(parts[1])


def _parse_full_version(ver: str) -> tuple[int, int, int]:
    """Parse a 'major.minor.patch' string into (major, minor, patch).

    Pre-release suffixes (e.g. '-dev.3') are not accepted here — use
    --to with --to-version separately if you need them later.
    """
    parts = ver.split(".")
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        raise argparse.ArgumentTypeError(
            f"--to-version must be major.minor.patch (e.g. 0.5.1), got: {ver!r}"
        )
    return int(parts[0]), int(parts[1]), int(parts[2])


def _is_greentic(name: str) -> bool:
    """Return True if *name* is a greentic-ecosystem crate."""
    if name in SKIP_CRATES:
        return False
    return name.startswith("greentic-") or name in EXTRA_GREENTIC_CRATES


def _version_matches_prefix(version: str, prefix: str) -> bool:
    """Check if *version* starts with *prefix* followed by '.' or end-of-string.

    E.g. prefix="0.4" matches "0.4", "0.4.58", "0.4.0" but NOT "0.40".
    """
    if version == prefix:
        return True
    if version.startswith(prefix + "."):
        return True
    return False


def _range_matches_prefix(version: str, prefix: str) -> bool:
    """Check if a version range spec contains the --from prefix.

    Matches patterns like:
      ">=0.4.0-0, <0.5.0-0"
      ">=0.4.52"
      ">=0.4.31, <0.5"
    """
    return bool(re.search(rf">={re.escape(prefix)}[\.\d]", version))


def _make_range(to_major: int, to_minor: int) -> str:
    """Build the target range string."""
    next_minor = to_minor + 1
    return f">={to_major}.{to_minor}.0-0, <{to_major}.{next_minor}.0-0"


def _is_workspace_inherit(value: object) -> bool:
    """True if *value* is a `{workspace = true}` inheritance marker."""
    return isinstance(value, dict) and value == {"workspace": True}


def _substitute_workspace_inherit(pkg: dict) -> None:
    """Replace ``{workspace=true}`` dicts at inheritable keys with a sentinel
    string so tomli_w emits a leaf key.  See INHERITABLE_PACKAGE_KEYS."""
    for key in list(pkg.keys()):
        if key in INHERITABLE_PACKAGE_KEYS and _is_workspace_inherit(pkg[key]):
            pkg[key] = WORKSPACE_INHERIT_SENTINEL


def _restore_workspace_inherit(text: str) -> str:
    """Rewrite sentinel leaf keys back to ``key.workspace = true`` form."""
    return _SENTINEL_LINE_RE.sub(r"\g<indent>\g<key>.workspace = true", text)


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------


class Bumper:
    def __init__(
        self,
        from_prefix: str,
        to_major: int,
        to_minor: int,
        dry_run: bool,
        deps_only: bool = False,
        to_version: str | None = None,
    ):
        self.from_prefix = from_prefix
        self.to_version = to_version or f"{to_major}.{to_minor}.0"
        self.range_spec = _make_range(to_major, to_minor)
        self.dry_run = dry_run
        self.deps_only = deps_only
        self.files_changed = 0

    # -- public entry point ------------------------------------------------

    def process_file(self, path: Path) -> None:
        with open(path, "rb") as f:
            data = tomllib.load(f)

        changes: list[str] = []

        ws = data.get("workspace", {})

        # 1) workspace.package.version (skip in --deps-only mode)
        if not self.deps_only:
            ws_pkg = ws.get("package", {})
            self._bump_package_version(ws_pkg, changes)

            # 2) package.version  (only if it's a plain string, not workspace=true)
            pkg = data.get("package", {})
            self._bump_package_version(pkg, changes)

        # 3) workspace.dependencies
        ws_deps = ws.get("dependencies", {})
        self._bump_deps(ws_deps, changes)

        # 4) top-level dep sections
        for section in DEP_SECTIONS:
            deps = data.get(section, {})
            self._bump_deps(deps, changes, section_label=section)

        # 5) target-specific dep sections
        targets = data.get("target", {})
        for target_key, target_val in targets.items():
            if not isinstance(target_val, dict):
                continue
            for section in DEP_SECTIONS:
                deps = target_val.get(section, {})
                self._bump_deps(
                    deps, changes, section_label=f"target.{target_key}.{section}"
                )

        # -- report & write ------------------------------------------------

        if not changes:
            return

        self.files_changed += 1
        prefix = "[dry-run] " if self.dry_run else ""
        print(f"{prefix}{path}:")
        for c in changes:
            print(f"  {c}")

        if not self.dry_run:
            # Sentinel-substitute workspace-inheritance dicts so tomli_w emits
            # a leaf key instead of a sub-table; restore as dotted-key after.
            _substitute_workspace_inherit(ws.get("package", {}))
            _substitute_workspace_inherit(data.get("package", {}))

            text = tomli_w.dumps(data)
            text = _restore_workspace_inherit(text)
            with open(path, "wb") as f:
                f.write(text.encode("utf-8"))

    # -- internals ---------------------------------------------------------

    def _bump_package_version(
        self, pkg: dict, changes: list[str]
    ) -> None:
        ver = pkg.get("version")
        if not isinstance(ver, str):
            # version.workspace = true  or  absent → skip
            return
        if _version_matches_prefix(ver, self.from_prefix):
            changes.append(f"version: {ver} → {self.to_version}")
            pkg["version"] = self.to_version

    def _bump_deps(
        self,
        deps: dict,
        changes: list[str],
        section_label: str | None = None,
    ) -> None:
        for name, spec in list(deps.items()):
            # Resolve `package = "..."` alias before classifying.  Without
            # this, aliased deps like `greentic_pack = { package =
            # "greentic-pack-lib", version = "0.4" }` would be skipped because
            # the table key (`greentic_pack`) doesn't match any greentic name.
            if isinstance(spec, dict) and isinstance(spec.get("package"), str):
                actual_package = spec["package"]
            else:
                actual_package = name

            if actual_package in SKIP_CRATES:
                continue
            if not _is_greentic(actual_package):
                continue

            if isinstance(spec, str):
                new = self._bump_version_string(spec)
                if new is not None:
                    label = section_label or "workspace.dependencies"
                    changes.append(
                        f"dep {name} ({label}): {spec!r} → {new!r}"
                    )
                    deps[name] = new

            elif isinstance(spec, dict) and "version" in spec:
                ver = spec["version"]
                if not isinstance(ver, str):
                    continue
                new = self._bump_version_string(ver)
                if new is not None:
                    label = section_label or "workspace.dependencies"
                    changes.append(
                        f"dep {name} ({label}): {{version={ver!r}}} → {{version={new!r}}}"
                    )
                    spec["version"] = new

    def _bump_version_string(self, ver: str) -> str | None:
        """Return the bumped version string, or None if no change needed."""
        # Simple prefix match: "0.4", "0.4.58", etc.
        if _version_matches_prefix(ver, self.from_prefix):
            return self.range_spec
        # Range match: ">=0.4.0-0, <0.5.0-0"  or  ">=0.4.52"  etc.
        if _range_matches_prefix(ver, self.from_prefix):
            return self.range_spec
        return None


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Bump greentic crate versions in Cargo.toml files."
    )
    parser.add_argument(
        "--from",
        dest="from_ver",
        required=True,
        help="Source version prefix (e.g. 0.4)",
    )
    parser.add_argument(
        "--to",
        dest="to_ver",
        required=True,
        help="Target version prefix (e.g. 0.5)",
    )
    parser.add_argument(
        "--to-version",
        dest="to_version",
        default=None,
        help=(
            "Explicit target package version (major.minor.patch, e.g. 0.5.1). "
            "Overrides the default '<to>.0' so patch bumps don't downgrade. "
            "Must agree with --to on major.minor."
        ),
    )
    parser.add_argument(
        "--deps-only",
        action="store_true",
        help="Only convert dep specs to range format, skip version bumping",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would change without modifying files",
    )
    parser.add_argument(
        "path",
        nargs="?",
        default=".",
        help="Root directory to scan (default: current directory)",
    )
    args = parser.parse_args()

    # Validate prefixes
    _parse_minor(args.from_ver)
    to_major, to_minor = _parse_minor(args.to_ver)

    # Validate --to-version (if given) and ensure it agrees with --to on
    # major.minor — otherwise the dep range and the package version would
    # disagree, which is almost certainly a typo.
    to_version: str | None = None
    if args.to_version is not None:
        try:
            tv_major, tv_minor, _ = _parse_full_version(args.to_version)
        except argparse.ArgumentTypeError as exc:
            print(f"Error: {exc}", file=sys.stderr)
            sys.exit(2)
        if (tv_major, tv_minor) != (to_major, to_minor):
            print(
                f"Error: --to-version {args.to_version} disagrees with "
                f"--to {args.to_ver} on major.minor",
                file=sys.stderr,
            )
            sys.exit(2)
        to_version = args.to_version

    root = Path(args.path).resolve()
    if not root.is_dir():
        print(f"Error: {root} is not a directory", file=sys.stderr)
        sys.exit(1)

    bumper = Bumper(
        from_prefix=args.from_ver,
        to_major=to_major,
        to_minor=to_minor,
        dry_run=args.dry_run,
        deps_only=args.deps_only,
        to_version=to_version,
    )

    # Walk all Cargo.toml files, skip target/ directories
    cargo_files = sorted(root.rglob("Cargo.toml"))
    for path in cargo_files:
        # Skip target directories (build artifacts, semver-checks, etc.)
        parts = path.relative_to(root).parts
        if "target" in parts:
            continue
        bumper.process_file(path)

    if bumper.files_changed == 0:
        print("No changes needed.")
    else:
        noun = "file" if bumper.files_changed == 1 else "files"
        action = "would be modified" if args.dry_run else "modified"
        print(f"\n{bumper.files_changed} {noun} {action}.")


if __name__ == "__main__":
    main()
