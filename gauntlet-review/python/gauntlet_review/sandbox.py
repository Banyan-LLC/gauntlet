"""Container lifecycle orchestration against the ContainerRuntime interface (fakeable),
plus the lease-gated startup reaper. Guarantees cleanup on every path."""
from __future__ import annotations

import os
from dataclasses import dataclass

from gauntlet_review.lease import RunLease
from gauntlet_review.runconfig import RunConfig, build_create_argv


@dataclass
class RoundResult:
    verdict_path: str | None
    exit_status: int | None
    stdout: bytes
    stderr: bytes
    timed_out: bool
    over_limit: bool
    error: str | None


def run_round(runtime, cfg: RunConfig, *, prompt_bytes: bytes, timeout_sec: float,
              marker_path: str, max_verdict_bytes: int = 200_000) -> RoundResult:
    cid = runtime.create(build_create_argv(getattr(runtime, "name", "docker"), cfg))
    verdict_path = None
    exit_status = None
    timed_out = False
    over_limit = False
    error = None
    try:
        proc = runtime.start(cid, prompt_bytes, timeout_sec)
        timed_out = proc.timed_out
        over_limit = proc.stdout_truncated or proc.stderr_truncated
        if timed_out or over_limit:
            runtime.kill(cid)
        else:
            exit_status = runtime.read_exit_status(cid)
            dest = cfg.cidfile + ".verdict.json"  # owner-only host temp beside the cidfile
            if runtime.cp_out_bounded(cid, cfg.verdict_path, dest, max_verdict_bytes):
                verdict_path = dest
            # Signal the wrapper it may exit, then stop the container.
            with open(marker_path, "w", encoding="utf-8") as fh:
                fh.write("go")
            runtime.kill(cid)
        return RoundResult(verdict_path, exit_status, proc.stdout, proc.stderr,
                           timed_out, over_limit, error)
    except Exception as exc:  # never leak a container on an unexpected error
        error = str(exc)
        try:
            runtime.kill(cid)
        except Exception:
            pass
        return RoundResult(verdict_path, exit_status, b"", b"", timed_out, over_limit, error)
    finally:
        try:
            runtime.rm(cid)  # guaranteed cleanup on success, failure, and timeout alike
        except Exception:
            pass


def reap_stale(runtime, *, lease_dir: str, label_prefix: str) -> list[str]:
    reaped = []
    for run_id in runtime.list_labeled(label_prefix):
        lease_path = os.path.join(lease_dir, f"{run_id}.lease")
        lease = RunLease.try_acquire(lease_path)
        if lease is None:
            continue  # lease held -> run is live -> never reap
        try:
            try:
                runtime.kill(run_id)
            except Exception:
                pass
            try:
                runtime.rm(run_id)
            except Exception:
                pass
            reaped.append(run_id)
        finally:
            lease.release()
    return reaped
