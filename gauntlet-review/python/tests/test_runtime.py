import json

import pytest

from gauntlet_review.runtime import (
    RuntimeUnavailable,
    detect_runtime,
    parse_image_identity,
    parse_userns_mapping,
)


def test_detect_prefers_docker_when_both_usable():
    got = detect_runtime(_which=lambda n: f"/usr/bin/{n}", _probe=lambda n: True)
    assert got == "docker"


def test_detect_falls_back_to_podman():
    got = detect_runtime(_which=lambda n: "/usr/bin/podman" if n == "podman" else None,
                         _probe=lambda n: True)
    assert got == "podman"


def test_detect_raises_when_none_present():
    with pytest.raises(RuntimeUnavailable):
        detect_runtime(_which=lambda n: None, _probe=lambda n: True)


def test_detect_raises_when_present_but_unusable():
    with pytest.raises(RuntimeUnavailable):
        detect_runtime(_which=lambda n: f"/usr/bin/{n}", _probe=lambda n: False)


def test_parse_image_identity_with_repo_digest():
    doc = json.dumps({
        "Id": "sha256:aaaa", "Os": "linux", "Architecture": "arm64",
        "RepoDigests": ["ghcr.io/x/codex@sha256:bbbb"],
    })
    idn = parse_image_identity(doc)
    assert idn.config_digest == "sha256:aaaa" and idn.os == "linux" and idn.arch == "arm64"
    assert idn.manifest_digest == "sha256:bbbb"


def test_parse_image_identity_local_build_has_no_manifest_digest():
    doc = json.dumps({"Id": "sha256:cccc", "Os": "linux", "Architecture": "amd64", "RepoDigests": []})
    idn = parse_image_identity(doc)
    assert idn.manifest_digest is None and idn.config_digest == "sha256:cccc"


def test_parse_userns_mapping_rootless():
    doc = json.dumps({"host": {"security": {"rootless": True}}})
    assert parse_userns_mapping(doc)["rootless"] is True
