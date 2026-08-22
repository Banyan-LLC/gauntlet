"""Host-side credential broker: stage an access-only auth.json + a hash-verified AGENTS.md
into an owner-only staging dir, fail closed on any mismatch or insufficient token lifetime.
The durable refresh credential never enters the staging dir (see default_token_provider)."""
from __future__ import annotations

import hashlib
import os
import shutil


class BrokerError(Exception):
    """Fail-closed credential error (maps to exit 12 in Phase 3)."""


def _rollback_staging(staging_dir: str) -> str | None:
    """Remove a half-staged dir, invalidating auth.json FIRST so a live access token cannot
    survive a partial/failed rmtree. Returns a description of any residual that could NOT be
    removed (so the caller can surface it), or None when the dir is gone."""
    auth = os.path.join(staging_dir, "auth.json")
    try:
        if os.path.lexists(auth):
            os.unlink(auth)  # invalidate the token before removing anything else
    except OSError:
        pass
    shutil.rmtree(staging_dir, ignore_errors=True)
    if os.path.exists(staging_dir):
        return f"{staging_dir} (auth.json still present: {os.path.lexists(auth)})"
    return None


def _read_regular_nofollow(path: str) -> bytes:
    have_nofollow = hasattr(os, "O_NOFOLLOW")
    # On POSIX, O_NOFOLLOW rejects a symlinked source atomically at open (ELOOP) -- this is the
    # production path (the container stack runs on Unix/macOS). On platforms without O_NOFOLLOW
    # (Windows, dev/CI only), that atomic protection is absent, so fail closed if the path is a
    # symlink / reparse point -- otherwise a symlink whose target carries the approved hash would
    # be silently followed. This pre-open check leaves a residual check-then-open TOCTOU window on
    # Windows that a fully reparse-resistant handle open would close; acceptable because Windows is
    # not the production execution path for the container stack.
    if not have_nofollow and os.path.islink(path):
        raise BrokerError(f"credential source is a symlink; refusing to follow: {path}")
    try:
        fd = os.open(path, os.O_RDONLY | (os.O_NOFOLLOW if have_nofollow else 0))
    except OSError as exc:  # ELOOP on a symlink, or any open failure -> fail closed as a broker error
        raise BrokerError(f"cannot open credential source {path}: {exc}") from exc
    try:
        st = os.fstat(fd)
        import stat as _stat
        if not _stat.S_ISREG(st.st_mode):
            raise BrokerError(f"credential source is not a regular file: {path}")
        data = b""
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data += chunk
        return data
    finally:
        os.close(fd)


def stage_credential(*, codex_home: str, staging_dir: str, agents_md_sha256: str,
                     min_lifetime_sec: float, token_provider, now: float) -> None:
    token = token_provider()
    if token["expires_at"] - now < min_lifetime_sec:
        raise BrokerError(
            f"access token lifetime too short: {token['expires_at'] - now:.0f}s "
            f"< required {min_lifetime_sec:.0f}s; refresh Codex auth on the host"
        )
    agents = _read_regular_nofollow(os.path.join(codex_home, "AGENTS.md"))
    if hashlib.sha256(agents).hexdigest() != agents_md_sha256:
        raise BrokerError("AGENTS.md staged bytes do not match the manifest agents_md_sha256")

    os.makedirs(staging_dir, mode=0o700, exist_ok=False)
    try:
        os.chmod(staging_dir, 0o700)  # makedirs mode is umask-masked; force it
        # Write access-only auth.json and the verified AGENTS.md into the staging dir.
        auth_fd = os.open(os.path.join(staging_dir, "auth.json"),
                          os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(auth_fd, "w", encoding="utf-8") as fh:
            fh.write(token["json"])
        agents_fd = os.open(os.path.join(staging_dir, "AGENTS.md"),
                            os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(agents_fd, "wb") as fh:
            fh.write(agents)
    except BaseException as exc:
        # A partially-written staging dir would hold a live access token; invalidate it and fail
        # closed. Surface any residual credential material explicitly rather than reporting a
        # clean failure over a token that is still on disk.
        residual = _rollback_staging(staging_dir)
        detail = f"failed to stage credential into {staging_dir}: {exc}"
        if residual:
            detail += f"; residual credential material could not be removed: {residual}"
        raise BrokerError(detail) from exc


def default_token_provider(codex_home: str) -> dict:  # pragma: no cover - wired in Phase 3, body per Step 0
    """Produce the access-only token. Implemented per the Step-0 empirical finding.
    Must (a) hold the broker interprocess lock while reading/refreshing ~/.codex, (b) never
    place the durable refresh token in the returned json, (c) return {'json','expires_at'}."""
    raise NotImplementedError("default_token_provider: implement per Task 5 Step 0 finding")
