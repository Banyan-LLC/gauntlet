import json

import pytest

from gauntlet_review.runtime import (
    ImageIdentityMismatch,
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


def test_parse_image_identity_raises_when_expected_repo_absent():
    # Repo digests exist but none matches the requested repo -> a pulled image of the wrong
    # identity, which must NOT be silently accepted as if it were a local build.
    doc = json.dumps({
        "Id": "sha256:aaaa", "Os": "linux", "Architecture": "amd64",
        "RepoDigests": ["docker.io/y/codex@sha256:cccc"],
    })
    with pytest.raises(ValueError):
        parse_image_identity(doc, expected_repo="ghcr.io/x/codex")


def test_parse_image_identity_local_build_with_expected_repo_is_none():
    # A genuine local build (no RepoDigests) is distinguishable and yields no manifest digest.
    doc = json.dumps({"Id": "sha256:aaaa", "Os": "linux", "Architecture": "amd64", "RepoDigests": []})
    assert parse_image_identity(doc, expected_repo="ghcr.io/x/codex").manifest_digest is None


def test_parse_image_identity_expected_digest_mismatch_raises():
    doc = json.dumps({
        "Id": "sha256:aaaa", "Os": "linux", "Architecture": "amd64",
        "RepoDigests": ["ghcr.io/x/codex@sha256:cccc"],
    })
    with pytest.raises(ValueError):
        parse_image_identity(doc, expected_repo="ghcr.io/x/codex", expected_digest="sha256:bbbb")


def test_parse_image_identity_expected_digest_with_no_repo_digests_raises():
    # A digest-pinned reference must not be satisfied by an image that carries no digest at all.
    doc = json.dumps({"Id": "sha256:aaaa", "Os": "linux", "Architecture": "amd64", "RepoDigests": []})
    with pytest.raises(ValueError):
        parse_image_identity(doc, expected_digest="sha256:bbbb")


def test_parse_image_identity_mismatch_is_typed():
    # Identity failures raise the typed ImageIdentityMismatch (a ValueError subclass) so Phase 3
    # can map them to exit 13, distinct from malformed-inspect parse errors.
    doc = json.dumps({
        "Id": "sha256:aaaa", "Os": "linux", "Architecture": "amd64",
        "RepoDigests": ["ghcr.io/x/codex@sha256:cccc"],
    })
    with pytest.raises(ImageIdentityMismatch):
        parse_image_identity(doc, expected_repo="ghcr.io/x/codex", expected_digest="sha256:bbbb")


def test_parse_image_identity_expected_digest_match_ok():
    doc = json.dumps({
        "Id": "sha256:aaaa", "Os": "linux", "Architecture": "amd64",
        "RepoDigests": ["ghcr.io/x/codex@sha256:bbbb"],
    })
    idn = parse_image_identity(doc, expected_repo="ghcr.io/x/codex", expected_digest="sha256:bbbb")
    assert idn.manifest_digest == "sha256:bbbb"


def test_parse_userns_mapping_rootless():
    doc = json.dumps({"host": {"security": {"rootless": True}}})
    assert parse_userns_mapping(doc)["rootless"] is True


def test_parse_userns_mapping_rootful_userns_remap():
    # A rootful Docker daemon with --userns-remap reports SecurityOptions name=userns and DOES
    # remap uids, so uid_map_present must be True even though rootless is False.
    doc = json.dumps({"SecurityOptions": ["name=seccomp,profile=builtin", "name=userns"]})
    m = parse_userns_mapping(doc)
    assert m["rootless"] is False and m["userns_remap"] is True and m["uid_map_present"] is True
