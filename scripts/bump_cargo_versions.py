#!/usr/bin/env python3
"""Structure-aware Cargo.toml version bumper for the Greentic ecosystem.

Walks all Cargo.toml files under a directory and bumps:
  - package / workspace.package versions matching --from prefix
  - greentic dependency version specs to a pre-release-compatible range

Uses tomllib (read) + tomli_w (write) for structure-aware TOML editing.
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
    ):
        self.from_prefix = from_prefix
        self.to_version = f"{to_major}.{to_minor}.0"
        self.range_spec = _make_range(to_major, to_minor)
        self.dry_run = dry_run
        self.files_changed = 0

    # -- public entry point ------------------------------------------------

    def process_file(self, path: Path) -> None:
        with open(path, "rb") as f:
            data = tomllib.load(f)

        changes: list[str] = []

        # 1) workspace.package.version
        ws = data.get("workspace", {})
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
            with open(path, "wb") as f:
                tomli_w.dump(data, f)

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
            if not _is_greentic(name):
                continue
            # Also skip if the crate is aliased via "package" to a skip crate
            if isinstance(spec, dict):
                actual_package = spec.get("package", name)
                if actual_package in SKIP_CRATES:
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

    root = Path(args.path).resolve()
    if not root.is_dir():
        print(f"Error: {root} is not a directory", file=sys.stderr)
        sys.exit(1)

    bumper = Bumper(
        from_prefix=args.from_ver,
        to_major=to_major,
        to_minor=to_minor,
        dry_run=args.dry_run,
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
