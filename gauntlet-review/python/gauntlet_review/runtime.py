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


def parse_image_identity(inspect_json: str, expected_repo: str | None = None,
                         expected_digest: str | None = None) -> ImageIdentity:
    """Parse `image inspect` output into the pinned identity. The manifest digest is tied to
    the requested repository rather than blindly taking the first RepoDigests entry: with
    multiple repo digests (or a multi-platform index) the first entry can be the wrong image.
    Pass `expected_repo` (e.g. "ghcr.io/x/codex") to select its digest and reject ambiguity;
    without it, a digest is recorded only when every RepoDigests entry agrees. Pass
    `expected_digest` (e.g. "sha256:...") to REQUIRE that the selected manifest digest matches
    exactly -- a mismatch or absence raises, so a pinned reference is genuinely enforced rather
    than accepted with a different or empty digest."""
    doc = json.loads(inspect_json)
    if isinstance(doc, list):  # `image inspect` returns a JSON array
        doc = doc[0]
    repo_digests = [rd for rd in (doc.get("RepoDigests") or []) if "@" in rd]
    manifest = None
    if expected_repo is not None:
        matches = {rd.split("@", 1)[1] for rd in repo_digests if rd.split("@", 1)[0] == expected_repo}
        if len(matches) > 1:
            raise ValueError(f"ambiguous manifest digests for repo {expected_repo}: {sorted(matches)}")
        if not matches and repo_digests:
            # Repo digests exist but none is the requested repo: a pulled image whose identity
            # does NOT match what was requested. Fail rather than silently look like a local build
            # (which is the only legitimate no-digest case).
            have = sorted({rd.split("@", 1)[0] for rd in repo_digests})
            raise ValueError(f"no manifest digest for requested repo {expected_repo}; image carries {have}")
        manifest = next(iter(matches)) if matches else None
    else:
        digests = {rd.split("@", 1)[1] for rd in repo_digests}
        # Only pin a digest when it is unambiguous; never guess by taking the first of several.
        manifest = next(iter(digests)) if len(digests) == 1 else None
    if expected_digest is not None:
        # Enforce the pinned reference exactly: a missing or differing manifest digest is a
        # hard identity failure, not something to accept silently.
        if manifest is None:
            raise ValueError(f"expected manifest digest {expected_digest} but image carries none matching")
        if manifest != expected_digest:
            raise ValueError(f"image manifest digest {manifest} does not match expected {expected_digest}")
    return ImageIdentity(
        config_digest=doc["Id"],
        os=doc["Os"],
        arch=doc["Architecture"],
        manifest_digest=manifest,
    )


def parse_userns_mapping(info_json: str) -> dict:
    doc = json.loads(info_json)
    rootless = False
    userns_remap = False
    host = doc.get("host")
    if isinstance(host, dict):  # podman shape
        rootless = bool(host.get("security", {}).get("rootless", False))
    for opt in doc.get("SecurityOptions", []) or []:  # docker shape: "name=rootless" / "name=userns"
        if "rootless" in opt:
            rootless = True
        if "name=userns" in opt or opt.strip() == "userns":
            userns_remap = True  # rootful daemon with --userns-remap still remaps uids
    # A UID mapping exists under rootless mode OR rootful userns-remap; conflating it with
    # rootless alone misses a rootful-remap daemon.
    return {"rootless": rootless, "userns_remap": userns_remap,
            "uid_map_present": rootless or userns_remap}


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
        try:
            with os.fdopen(fd, "wb") as out:
                while True:
                    chunk = src.read(65536)
                    if not chunk:
                        break
                    written += len(chunk)
                    if written > max_bytes:
                        raise ValueError("copied file exceeds cap during read")
                    out.write(chunk)
        except BaseException:
            # Never leave a partial (credential- or verdict-bearing) file behind.
            try:
                os.unlink(dest_path)
            except OSError:
                pass
            raise
        return written
