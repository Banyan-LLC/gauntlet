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


def test_parse_image_identity_ambiguous_repo_digests_records_none():
    # Multiple, differing repo digests with no requested repo must not silently pick the first.
    doc = json.dumps({
        "Id": "sha256:aaaa", "Os": "linux", "Architecture": "amd64",
        "RepoDigests": ["ghcr.io/x/codex@sha256:bbbb", "docker.io/y/codex@sha256:cccc"],
    })
    assert parse_image_identity(doc).manifest_digest is None


def test_parse_image_identity_selects_by_expected_repo():
    doc = json.dumps({
        "Id": "sha256:aaaa", "Os": "linux", "Architecture": "amd64",
        "RepoDigests": ["ghcr.io/x/codex@sha256:bbbb", "docker.io/y/codex@sha256:cccc"],
    })
    idn = parse_image_identity(doc, expected_repo="docker.io/y/codex")
    assert idn.manifest_digest == "sha256:cccc"


def test_parse_image_identity_ambiguous_within_repo_raises():
    doc = json.dumps({
        "Id": "sha256:aaaa", "Os": "linux", "Architecture": "amd64",
        "RepoDigests": ["ghcr.io/x/codex@sha256:bbbb", "ghcr.io/x/codex@sha256:dddd"],
    })
    with pytest.raises(ValueError):
        parse_image_identity(doc, expected_repo="ghcr.io/x/codex")


def test_parse_userns_mapping_rootless():
    doc = json.dumps({"host": {"security": {"rootless": True}}})
    assert parse_userns_mapping(doc)["rootless"] is True


def test_parse_userns_mapping_rootful_userns_remap():
    # A rootful Docker daemon with --userns-remap reports SecurityOptions name=userns and DOES
    # remap uids, so uid_map_present must be True even though rootless is False.
    doc = json.dumps({"SecurityOptions": ["name=seccomp,profile=builtin", "name=userns"]})
    m = parse_userns_mapping(doc)
    assert m["rootless"] is False and m["userns_remap"] is True and m["uid_map_present"] is True
