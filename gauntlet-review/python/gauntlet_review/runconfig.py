"""Container run configuration + `create`-argv composition (analogue of New-CodexArgs)
and the canonical semantic profile descriptor (per-run values -> typed placeholders)."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class RunConfig:
    image_ref: str
    platform: str
    uid: int
    gid: int
    cidfile: str
    staging_dir: str
    codex_home: str
    tmpfs_dir: str
    verdict_path: str
    schema_path: str
    disable_set: list[str]
    run_label: str
    pids_limit: int = 256
    memory: str = "2g"
    cpus: str = "2"
    model: str = "gpt-5.6-sol"
    effort: str = "xhigh"
    network: str = "bridge"  # v1: open egress (documented); Phase-5+ may add an allowlist proxy


def _codex_args(cfg: RunConfig) -> list[str]:
    a = ["exec",
         "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check",
         "-s", "read-only",
         "-m", cfg.model, "-c", f'model_reasoning_effort="{cfg.effort}"',
         "-c", 'web_search="disabled"', "-c", 'shell_environment_policy.inherit="none"']
    for f in cfg.disable_set:
        a += ["--disable", f]
    a += ["--output-schema", cfg.schema_path, "-o", cfg.verdict_path, "--json", "-"]
    return a


def build_create_argv(runtime: str, cfg: RunConfig) -> list[str]:
    argv = [runtime, "create",
            "--cidfile", cfg.cidfile,
            "--label", cfg.run_label,
            "--user", f"{cfg.uid}:{cfg.gid}",
            "--read-only",
            "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges",
            # PID and UTS namespaces are private by DEFAULT on Docker and Podman; Docker
            # rejects the literal "--pid private"/"--uts private", so they are omitted (the
            # Phase-3 policy validator asserts private PID/UTS via container inspection).
            "--ipc", "private", "--cgroupns", "private",
            "--pids-limit", str(cfg.pids_limit),
            "--memory", cfg.memory, "--cpus", cfg.cpus,
            "--log-driver", "none",
            "--network", cfg.network,
            "--platform", cfg.platform,
            "--tmpfs", f"{cfg.tmpfs_dir}:rw,nosuid,nodev,noexec",
            "--workdir", cfg.tmpfs_dir,  # run IN the writable tmpfs, not the image default dir
            "-v", f"{cfg.staging_dir}:{cfg.codex_home}:ro",
            "-e", f"CODEX_HOME={cfg.codex_home}",
            "-i",  # keep stdin open for the prompt
            cfg.image_ref]
    argv += _codex_args(cfg)
    return argv


def semantic_profile(cfg: RunConfig) -> dict:
    """Security-relevant shape with ONLY the genuinely per-run values (cidfile, staging_dir,
    run_label, uid, gid) replaced by typed placeholders, so two runs differing only in those
    hash identically (Phase 3 hashes this). Every other value -- including image_ref, the
    pinned image digest and the most security-critical field -- appears verbatim, so a
    change to it changes the profile."""
    return {
        "runtime_argv_template": [
            "create", "--cidfile", "<cidfile>", "--label", "<run_label>",
            "--user", "<uid>:<gid>", "--read-only", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges",
            # PID and UTS namespaces are private by DEFAULT on Docker and Podman; Docker
            # rejects the literal "--pid private"/"--uts private", so they are omitted (the
            # Phase-3 policy validator asserts private PID/UTS via container inspection).
            "--ipc", "private", "--cgroupns", "private",
            "--pids-limit", str(cfg.pids_limit), "--memory", cfg.memory, "--cpus", cfg.cpus,
            "--log-driver", "none", "--network", cfg.network, "--platform", cfg.platform,
            "--tmpfs", f"{cfg.tmpfs_dir}:rw,nosuid,nodev,noexec",
            "--workdir", cfg.tmpfs_dir,
            "-v", f"<staging_dir>:{cfg.codex_home}:ro", "-e", f"CODEX_HOME={cfg.codex_home}", "-i",
            cfg.image_ref,
        ],
        "codex_args": _codex_args_template(cfg),
        "disable_set": sorted(cfg.disable_set),
    }


def _codex_args_template(cfg: RunConfig) -> list[str]:
    # schema_path and verdict_path are fixed in-container config, not per-run-random:
    # keep every value verbatim (only cidfile/staging_dir/run_label/uid/gid are placeholders).
    return _codex_args(cfg)
