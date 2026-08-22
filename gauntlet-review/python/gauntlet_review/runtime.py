"""Container runtime seam. The only module that shells out to docker/podman; all other
code depends on the ContainerRuntime interface so tests can inject a fake. Pure parsers
(image identity, userns mapping) and detection are unit-tested; the shelling methods are
exercised by the Task 9 integration smoke test."""
from __future__ import annotations

import json
import shutil
from dataclasses import dataclass

from gauntlet_review.bounded import run_bounded


class RuntimeUnavailable(Exception):
    """No usable container runtime (maps to exit 12 in Phase 3)."""


@dataclass
class ImageIdentity:
    config_digest: str
    os: str
    arch: str
    manifest_digest: str | None


def _default_probe(name: str) -> bool:
    r = run_bounded([name, "version", "--format", "{{.Server.Version}}"], timeout_sec=30)
    return (not r.start_failed) and r.exit_code == 0


def detect_runtime(candidates=("docker", "podman"), *, _which=None, _probe=None) -> str:
    which = _which or shutil.which
    probe = _probe or _default_probe
    for name in candidates:
        if which(name) and probe(name):
            return name
    raise RuntimeUnavailable(
        f"no usable container runtime found (tried: {', '.join(candidates)}); "
        f"install Docker or Podman, or run the Windows PowerShell stack"
    )


def parse_image_identity(inspect_json: str) -> ImageIdentity:
    doc = json.loads(inspect_json)
    if isinstance(doc, list):  # `image inspect` returns a JSON array
        doc = doc[0]
    manifest = None
    for rd in doc.get("RepoDigests") or []:
        if "@" in rd:
            manifest = rd.split("@", 1)[1]
            break
    return ImageIdentity(
        config_digest=doc["Id"],
        os=doc["Os"],
        arch=doc["Architecture"],
        manifest_digest=manifest,
    )


def parse_userns_mapping(info_json: str) -> dict:
    doc = json.loads(info_json)
    rootless = False
    host = doc.get("host")
    if isinstance(host, dict):  # podman shape
        rootless = bool(host.get("security", {}).get("rootless", False))
    for opt in doc.get("SecurityOptions", []) or []:  # docker shape: "name=rootless"
        if "rootless" in opt:
            rootless = True
    return {"rootless": rootless, "uid_map_present": rootless}
