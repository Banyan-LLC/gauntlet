import io
import os
import tarfile

import pytest

from gauntlet_review.runtime import extract_single_file_from_tar


def _tar_with(name: str, data: bytes) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        info = tarfile.TarInfo(name=name)
        info.size = len(data)
        tf.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def test_extracts_regular_member_within_cap(tmp_path):
    tar = _tar_with("verdict.json", b'{"verdict":"approve"}')
    dest = tmp_path / "out.json"
    n = extract_single_file_from_tar(tar, str(dest), max_bytes=1_000_000)
    assert n == len(b'{"verdict":"approve"}')
    assert dest.read_bytes() == b'{"verdict":"approve"}'
    if os.name == "posix":  # mode bits are POSIX-specific
        assert (dest.stat().st_mode & 0o777) == 0o600


def test_oversized_member_aborts(tmp_path):
    tar = _tar_with("verdict.json", b"x" * 5000)
    with pytest.raises(ValueError):
        extract_single_file_from_tar(tar, str(tmp_path / "out.json"), max_bytes=1000)


def test_non_regular_member_rejected(tmp_path):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        tf.addfile(tarfile.TarInfo(name="d"))  # a directory-ish/zero entry via type default is regular; use a symlink
        link = tarfile.TarInfo(name="link")
        link.type = tarfile.SYMTYPE
        link.linkname = "/etc/passwd"
        tf.addfile(link)
    with pytest.raises(ValueError):
        extract_single_file_from_tar(buf.getvalue(), str(tmp_path / "out.json"), max_bytes=1000)
