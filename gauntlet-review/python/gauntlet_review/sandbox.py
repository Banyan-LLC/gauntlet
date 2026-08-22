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
    result = RoundResult(None, None, b"", b"", False, False, None)
    try:
        proc = runtime.start(cid, prompt_bytes, timeout_sec)
        result.stdout = proc.stdout
        result.stderr = proc.stderr
        result.timed_out = proc.timed_out
        result.over_limit = getattr(proc, "over_limit", False) or proc.stdout_truncated or proc.stderr_truncated
        if proc.start_failed or proc.error:
            # Fail closed: a failed start or a stdin-delivery fault means the prompt was not
            # fully delivered, so any verdict would be produced from partial input. Never
            # accept it -- kill the container and return no verdict.
            result.error = proc.error or "container process failed to start"
            runtime.kill(cid)
        elif result.timed_out or result.over_limit:
            runtime.kill(cid)
        else:
            result.exit_status = runtime.read_exit_status(cid)
            dest = cfg.cidfile + ".verdict.json"  # owner-only host temp beside the cidfile
            if runtime.cp_out_bounded(cid, cfg.verdict_path, dest, max_verdict_bytes):
                result.verdict_path = dest
            else:
                # A failed/over-limit copy-out must not masquerade as a successful round.
                result.error = "verdict copy-out failed or exceeded the size bound"
            # Signal the wrapper it may exit, then stop the container.
            with open(marker_path, "w", encoding="utf-8") as fh:
                fh.write("go")
            runtime.kill(cid)
    except Exception as exc:  # never leak a container on an unexpected error
        result.error = str(exc)
        try:
            runtime.kill(cid)
        except Exception:
            pass
    finally:
        try:
            runtime.rm(cid)  # guaranteed cleanup on success, failure, and timeout alike
        except Exception as rmexc:
            # Cleanup failure must be surfaced, not silently reported as success.
            result.error = (result.error + "; " if result.error else "") + f"container rm failed: {rmexc}"
    return result


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
                pass  # a stale run may already be dead; kill is best-effort
            try:
                runtime.rm(run_id)
                reaped.append(run_id)  # report reaped ONLY after confirmed removal
            except Exception:
                pass  # rm failed -> container remains -> retried on the next sweep
        finally:
            lease.release()
    return reaped
