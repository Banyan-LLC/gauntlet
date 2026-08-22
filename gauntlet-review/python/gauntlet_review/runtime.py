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


import io
import os
import tarfile


def extract_single_file_from_tar(tar_bytes: bytes, dest_path: str, max_bytes: int) -> int:
    """Extract the single regular-file member of a `docker cp SRC -` tar stream into
    dest_path (0o600), enforcing max_bytes. Rejects oversized, absent, or non-regular
    members. Returns bytes written."""
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r") as tf:
        members = [m for m in tf.getmembers() if m.name not in (".", "")]
        if len(members) != 1:
            raise ValueError(f"expected exactly one member in the cp stream, got {len(members)}")
        m = members[0]
        if not m.isreg():
            raise ValueError(f"member {m.name} is not a regular file")
        if m.size > max_bytes:
            raise ValueError(f"copied file {m.name} is {m.size} bytes, exceeds cap {max_bytes}")
        src = tf.extractfile(m)
        if src is None:
            raise ValueError(f"member {m.name} is not extractable as a regular file")
        fd = os.open(dest_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        written = 0
        with os.fdopen(fd, "wb") as out:
            while True:
                chunk = src.read(65536)
                if not chunk:
                    break
                written += len(chunk)
                if written > max_bytes:
                    raise ValueError("copied file exceeds cap during read")
                out.write(chunk)
        return written
