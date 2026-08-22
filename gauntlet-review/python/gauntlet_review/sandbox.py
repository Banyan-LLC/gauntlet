"""Container lifecycle orchestration against the ContainerRuntime interface (fakeable),
plus the lease-gated startup reaper. Guarantees cleanup on every path."""
from __future__ import annotations

import os
from dataclasses import dataclass

from gauntlet_review.broker import discard_staging
from gauntlet_review.lease import RunLease, is_valid_run_id
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
    result = RoundResult(None, None, b"", b"", False, False, None)
    cid = None
    try:
        # create() is INSIDE the guard so a creation failure still reaches staging cleanup below.
        cid = runtime.create(build_create_argv(getattr(runtime, "name", "docker"), cfg))
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
        if cid is not None:
            try:
                runtime.kill(cid)
            except Exception:
                pass
    finally:
        if cid is not None:
            try:
                runtime.rm(cid)  # guaranteed container cleanup on success, failure, and timeout
            except Exception as rmexc:
                result.error = (result.error + "; " if result.error else "") + f"container rm failed: {rmexc}"
        # Reclaim the credential-bearing staging dir on EVERY path (invalidates auth.json first),
        # so a short-lived access token never survives the round.
        residual = discard_staging(cfg.staging_dir)
        if residual:
            result.error = (result.error + "; " if result.error else "") + f"staging cleanup failed: {residual}"
    return result


def _safe_listdir(path: str) -> list[str]:
    try:
        return os.listdir(path)
    except OSError:
        return []


def reap_stale(runtime, *, lease_dir: str, label_prefix: str, staging_root: str) -> list[str]:
    """Reap crashed runs. Run ids are enumerated from THREE independent sources — labeled
    containers, `.lease` files, and staging dirs — so a crash BETWEEN staging the credential and
    creating the container (no labeled container yet) is still discovered and its credential
    reclaimed. `staging_root` is mandatory: the reaper's whole point is credential lifecycle, so
    every run stages under the convention path `{staging_root}/{run_id}`. For each run whose lease
    is free (i.e. not live): kill+remove its container IF one exists, then reclaim its staging dir
    (auth.json invalidated first). A run is reported reaped ONLY when its container is gone (or
    never existed) AND its staging is confirmed reclaimed; a residual leaves it for the next sweep.
    The lease file is removed after a confirmed reap."""
    try:
        labeled = set(runtime.list_labeled(label_prefix))
    except Exception:
        # A daemon outage / listing error must NOT abort the sweep: credential reclamation from
        # local lease + staging records is independent of container discovery and still runs.
        labeled = set()
    run_ids = set(labeled)
    for name in _safe_listdir(lease_dir):
        if name.endswith(".lease"):
            run_ids.add(name[: -len(".lease")])
    for name in _safe_listdir(staging_root):
        run_ids.add(name)

    reaped = []
    for run_id in sorted(run_ids):
        if not is_valid_run_id(run_id):
            continue  # only exact generated run ids -- never lease/rmtree an unrelated entry
        lease_path = os.path.join(lease_dir, f"{run_id}.lease")
        lease = RunLease.try_acquire(lease_path)
        if lease is None:
            continue  # lease held -> run is live -> never reap
        try:
            ok = True
            if run_id in labeled:  # a container exists -> it MUST be removed to count as reaped
                try:
                    runtime.kill(run_id)
                except Exception:
                    pass  # best-effort; a stale container may already be dead
                try:
                    runtime.rm(run_id)
                except Exception:
                    ok = False  # rm failed -> container remains -> retry next sweep
            # Reclaim the credential-bearing staging dir even when no container was created.
            residual = discard_staging(os.path.join(staging_root, run_id))
            if residual is not None:
                ok = False  # staging cleanup failed -> a live token may remain -> not reaped
            if ok:
                reaped.append(run_id)
        finally:
            lease.release()
        if ok:  # remove the lease file only after a fully confirmed reap
            try:
                os.unlink(lease_path)
            except OSError:
                pass
    return reaped
