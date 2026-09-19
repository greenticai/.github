#!/usr/bin/env python3
"""Tests for the dev lane's version-form handling inside the reusable workflows.

Run directly: ``python3 scripts/test_dev_lane_version_forms.py``

The stamping and validation logic lives inline in two workflow steps:

  * ``dev-prepare.yml`` → "Stamp dev version" (computes `dev` + `binary`)
  * ``dev-publish.yml`` → "Validate dev version form"

Rather than re-implementing that bash here (which would test a copy), this
extracts each step's ``run: |`` block from the committed YAML and executes it
with bash, exactly as the runner does, then checks the ``$GITHUB_OUTPUT``
lines and the exit status.

The forms covered:

  * ``M.m.p-dev.N``      → dev ``M.m.p-dev.{RUN_ID}``, binary ``M.m.{RUN_ID}``
  * ``M.m.p``            → dev = binary = ``M.m.{RUN_ID}`` (refused when
    require-pre-release is true)
  * ``M.m.p-research.N`` → dev ``M.m.p-research.{RUN_ID}``, binary
    ``M.m.{RUN_ID}`` (the research version line, greentic-start#595)
  * anything else        → refused

Stdlib only (the script-tests job installs tomlkit/tomli-w but not PyYAML).
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO / ".github" / "workflows"
RUN_ID = "35341963100"


def _step_script(workflow: str, step_name: str) -> str:
    """Return the dedented `run: |` body of the step named `step_name`."""
    lines = (WORKFLOWS / workflow).read_text(encoding="utf-8").splitlines()
    for idx, line in enumerate(lines):
        if line.strip() == f"- name: {step_name}":
            step_indent = len(line) - len(line.lstrip())
            break
    else:
        raise AssertionError(f"step {step_name!r} not found in {workflow}")
    run_idx = None
    for j in range(idx + 1, len(lines)):
        stripped = lines[j].strip()
        if stripped.startswith("- ") and len(lines[j]) - len(lines[j].lstrip()) == step_indent:
            break
        if stripped == "run: |":
            run_idx = j
            break
    if run_idx is None:
        raise AssertionError(f"step {step_name!r} in {workflow} has no `run: |` block")
    body: list[str] = []
    body_indent = None
    for line in lines[run_idx + 1 :]:
        if line.strip() == "":
            body.append("")
            continue
        indent = len(line) - len(line.lstrip())
        if body_indent is None:
            body_indent = indent
        if indent < body_indent:
            break
        body.append(line[body_indent:])
    return "\n".join(body) + "\n"


def _run(script: str, env: dict[str, str]) -> tuple[int, dict[str, str], str]:
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "github_output"
        out.write_text("")
        full_env = {**os.environ, **env, "GITHUB_OUTPUT": str(out), "GITHUB_RUN_ID": RUN_ID}
        proc = subprocess.run(
            ["bash", "-c", script], env=full_env, capture_output=True, text=True
        )
        outputs = {}
        for line in out.read_text().splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                outputs[key] = value
        return proc.returncode, outputs, proc.stdout + proc.stderr


def _stamp(base: str, require_pre_release: bool) -> tuple[int, dict[str, str], str]:
    script = _step_script("dev-prepare.yml", "Stamp dev version")
    return _run(
        script,
        {"BASE": base, "REQUIRE_PRE_RELEASE": "true" if require_pre_release else "false"},
    )


def _validate(version: str, require_pre_release: bool) -> tuple[int, str]:
    script = _step_script("dev-publish.yml", "Validate dev version form")
    code, _, log = _run(
        script,
        {"DEV_VERSION": version, "REQUIRE_PRE_RELEASE": "true" if require_pre_release else "false"},
    )
    return code, log


# --- dev-prepare: existing forms keep their exact outputs --------------------


def test_dev_pre_release_base_unchanged() -> None:
    for required in (True, False):
        code, out, log = _stamp("1.2.0-dev.0", required)
        assert code == 0, log
        assert out == {
            "base": "1.2.0-dev.0",
            "dev": f"1.2.0-dev.{RUN_ID}",
            "binary": f"1.2.{RUN_ID}",
        }, out


def test_regular_base_unchanged() -> None:
    code, out, log = _stamp("0.4.7", False)
    assert code == 0, log
    assert out == {"base": "0.4.7", "dev": f"0.4.{RUN_ID}", "binary": f"0.4.{RUN_ID}"}, out


def test_regular_base_refused_when_pre_release_required() -> None:
    code, out, log = _stamp("0.4.7", True)
    assert code == 1, log
    assert "is regular-release form, but require-pre-release=true" in log, log
    assert out == {}, out


# --- dev-prepare: the research form ------------------------------------------


def test_research_base_is_stamped_with_run_id() -> None:
    for required in (True, False):
        code, out, log = _stamp("1.3.0-research.3", required)
        assert code == 0, log
        assert out == {
            "base": "1.3.0-research.3",
            "dev": f"1.3.0-research.{RUN_ID}",
            "binary": f"1.3.{RUN_ID}",
        }, out


def test_research_patch_level_is_kept() -> None:
    code, out, log = _stamp("1.3.1-research.0", True)
    assert code == 0, log
    assert out["dev"] == f"1.3.1-research.{RUN_ID}", out
    assert out["binary"] == f"1.3.{RUN_ID}", out


def test_unsupported_forms_still_refused() -> None:
    for base in ("1.3.0-research", "1.3.0-rc.1", "1.3.0-research.x", "1.3", "v1.3.0"):
        code, out, log = _stamp(base, True)
        assert code == 1, f"{base}: {log}"
        assert "does not match supported forms" in log, f"{base}: {log}"
        assert out == {}, f"{base}: {out}"


# --- dev-publish: the matching validation ------------------------------------


def test_publish_validation_accepts_both_pre_release_forms() -> None:
    for version in (f"1.2.0-dev.{RUN_ID}", f"1.3.0-research.{RUN_ID}"):
        code, log = _validate(version, True)
        assert code == 0, f"{version}: {log}"


def test_publish_validation_refuses_other_forms_when_required() -> None:
    for version in (f"1.2.{RUN_ID}", "1.3.0-rc.1", "1.3.0-research"):
        code, log = _validate(version, True)
        assert code == 1, f"{version}: {log}"
        assert "pre-release form, but require-pre-release=true" in log, log


def test_publish_validation_is_a_no_op_when_not_required() -> None:
    code, log = _validate(f"1.2.{RUN_ID}", False)
    assert code == 0, log


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
