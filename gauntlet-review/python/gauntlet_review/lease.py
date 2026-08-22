"""Unguessable run id + a per-run exclusive file lease. The lease proves a run is live:
the reaper must non-blockingly acquire it before reclaiming a run's container/staging."""
from __future__ import annotations

import os
import secrets

if os.name == "posix":
    import fcntl

    def _lock_nb(fd) -> bool:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            return False

    def _unlock(fd):
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
else:
    import msvcrt

    def _lock_nb(fd) -> bool:
        try:
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            return True
        except OSError:
            return False

    def _unlock(fd):
        try:
            msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
        except OSError:
            pass


def new_run_id() -> str:
    return "gauntlet-" + secrets.token_hex(16)


class RunLease:
    def __init__(self, fd: int, path: str):
        self._fd = fd
        self._path = path

    @classmethod
    def try_acquire(cls, path: str) -> "RunLease | None":
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        if _lock_nb(fd):
            return cls(fd, path)
        os.close(fd)
        return None

    @classmethod
    def acquire(cls, path: str) -> "RunLease":
        lease = cls.try_acquire(path)
        if lease is None:
            raise RuntimeError(f"run lease already held: {path}")
        return lease

    def release(self) -> None:
        if self._fd is not None:
            _unlock(self._fd)
            os.close(self._fd)
            self._fd = None

    def __enter__(self) -> "RunLease":
        return self

    def __exit__(self, *exc) -> None:
        self.release()
