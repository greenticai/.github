#!/usr/bin/env python3
"""Register a published GitHub release with greentic-admin's release catalogue.

This is an accelerator only — greentic-admin also registers the same release
independently from its own GitHub-release scanner — so nothing here may ever
fail the calling workflow. The whole body is wrapped in a single try/except:
a missing/unreadable env var, an unparsable sidecar, a network error or a
non-2xx admin response all end the same way, a `::warning::` and exit 0.
"""
import hashlib, json, os, pathlib, re, sys, urllib.request


def main() -> int:
    key = os.environ.get("KEY", "")
    try:
        admin = os.environ.get("ADMIN_URL", "")
        repo = os.environ.get("REPO", "")
        name = os.environ.get("NAME", "")
        version = os.environ.get("VERSION", "")
        dist = os.environ.get("DIST_DIR", "")
        if not (admin and repo and name and version and dist and key):
            print("::warning::release catalogue registration skipped: "
                  "admin-url/repo/name/version/dist-dir/key not all set")
            return 0

        artifacts = []
        for sidecar in sorted(pathlib.Path(dist).glob("*.sha256")):
            archive = sidecar.with_suffix("")
            m = re.match(rf"^{re.escape(name)}(?:-dev)?-v{re.escape(version)}-(.+)\.(tgz|zip)$", archive.name)
            if not m:
                continue
            digest = sidecar.read_text().split()[0].lower()
            if not re.fullmatch(r"[0-9a-f]{64}", digest):
                print(f"::warning::{sidecar.name} does not hold a sha256; skipped")
                continue
            artifacts.append({"name": name, "version": version, "target": m.group(1),
                              "digest": f"sha256:{digest}",
                              "source": f"https://github.com/{repo}/releases/download/v{version}/{archive.name}"})
        if not artifacts:
            print("::warning::no release archives found; nothing registered")
            return 0

        body = json.dumps({"kind": "platform", "publisher": f"github:{repo}", "name": name,
            "version": version, "artifacts": artifacts,
            "provenance": {"builder": "github-actions", "source_repo": repo,
                           "source_revision": os.environ.get("GITHUB_SHA")},
            "rollback": {"supported": True}}).encode()
        req = urllib.request.Request(f"{admin.rstrip('/')}/api/v1/releases", data=body, method="POST",
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json",
                     "Idempotency-Key": f"gh:{repo}:{version}:{hashlib.sha256(body).hexdigest()[:16]}"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            print(f"registered {name} {version}: HTTP {resp.status}")
        return 0
    except Exception as exc:  # noqa: BLE001 — never fail a release on the catalogue
        msg = str(exc)
        if key:
            msg = msg.replace(key, "***")
        print(f"::warning::release catalogue registration failed: {type(exc).__name__}: {msg}")
        return 0


if __name__ == "__main__":
    sys.exit(main())
