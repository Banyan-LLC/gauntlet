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
            "--pid", "private", "--ipc", "private", "--uts", "private", "--cgroupns", "private",
            "--pids-limit", str(cfg.pids_limit),
            "--memory", cfg.memory, "--cpus", cfg.cpus,
            "--log-driver", "none",
            "--network", cfg.network,
            "--platform", cfg.platform,
            "--tmpfs", f"{cfg.tmpfs_dir}:rw,nosuid,nodev,noexec",
            "-v", f"{cfg.staging_dir}:{cfg.codex_home}:ro",
            "-e", f"CODEX_HOME={cfg.codex_home}",
            "-i",  # keep stdin open for the prompt
            cfg.image_ref]
    argv += _codex_args(cfg)
    return argv


def semantic_profile(cfg: RunConfig) -> dict:
    """Security-relevant shape with per-run values replaced by typed placeholders, so two
    runs differing only in cidfile/staging_dir/run_label/uid/gid hash identically (Phase 3
    hashes this). Any mandatory security value is included verbatim."""
    return {
        "runtime_argv_template": [
            "create", "--cidfile", "<cidfile>", "--label", "<run_label>",
            "--user", "<uid>:<gid>", "--read-only", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges",
            "--pid", "private", "--ipc", "private", "--uts", "private", "--cgroupns", "private",
            "--pids-limit", str(cfg.pids_limit), "--memory", cfg.memory, "--cpus", cfg.cpus,
            "--log-driver", "none", "--network", cfg.network, "--platform", cfg.platform,
            "--tmpfs", "<tmpfs_dir>:rw,nosuid,nodev,noexec",
            "-v", "<staging_dir>:<codex_home>:ro", "-e", "CODEX_HOME=<codex_home>", "-i",
            "<image_ref>",
        ],
        "codex_args": _codex_args_template(cfg),
        "disable_set": sorted(cfg.disable_set),
    }


def _codex_args_template(cfg: RunConfig) -> list[str]:
    a = _codex_args(cfg)
    # Replace the two per-run paths with placeholders; keep every flag/value verbatim.
    return ["<schema_path>" if x == cfg.schema_path else "<verdict_path>" if x == cfg.verdict_path else x for x in a]
