# Cross-Platform Gauntlet — Phase 2: Container Sandbox + Broker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Unix/macOS sandbox boundary — a locked-down container that runs Codex hermetically — plus the host-side credential broker that stages a short-lived access-only token into it, on top of the Phase 1 offline core.

**Architecture:** All Docker/Podman interaction goes through one thin, fakeable `ContainerRuntime` seam, so the security-relevant *logic* (run-config/argv composition, bounded stream capture, lifecycle state machine, per-run lease + reaper, credential staging/verification) is unit-tested with **no Docker**, while real-container behavior is exercised by a single, explicitly-marked integration smoke test. The full live security battery is Phase 5, not here.

**Tech Stack:** Python 3.11+, standard library (`subprocess`, `threading`, `os`, `hashlib`, `json`, `tarfile`, `secrets`, `fcntl`/`msvcrt`), plus Docker or Podman for the integration task only. Builds on `gauntlet_review` from Phase 1.

## Position in the port (Phase 2 of 5)

Phase 1 (offline core) is implemented and merged-pending in `gauntlet-review/python/`. This phase adds the boundary. It does **not** include: the premises manifest / `container_invocation_profile_hash` / policy validator / `invoke_codex.py` entry point (Phase 3), `publish.py` (Phase 4), or the live security battery + installer (Phase 5). Where Phase 2 produces a value Phase 3 will fingerprint (the semantic run descriptor, the image identity), it exposes it as structured data; it does not hash or gate on it here.

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from `docs/superpowers/specs/2026-08-18-cross-platform-unix-mac-design.md`.

- **Python 3.11+.** POSIX is the production target; the code also imports cleanly and unit-tests pass on Windows (dev/CI), where Docker-integration tests skip.
- **Native Windows without Docker is a retained, first-class path (required).** Nothing in this phase may make a container runtime a prerequisite on Windows; Docker/Podman is required only for the Unix/macOS container path (and only at runtime, not import time).
- **Runtime:** Docker primary; Podman used if it is a drop-in for the `create`/`start`/`kill`/`rm`/`cp`/`inspect` surface used here.
- **Container run configuration (mandatory values, all present on every run):** `--user <hostuid>:<hostgid>` against an arbitrary-UID image; `--read-only` rootfs; `--cap-drop ALL`; `--security-opt no-new-privileges`; private **PID, IPC, UTS, cgroup** namespaces (never host namespaces); `Privileged=false`; no unconfined seccomp/AppArmor; no unapproved devices; `--pids-limit` + memory + CPU limits; **`--log-driver=none`**; no published ports; **the credential staging dir is the only user bind-mount**; working root is an in-container **tmpfs**; minimal env with `CODEX_HOME` → the staging mount, nothing host-inherited; `--platform` set to the pinned `os/arch`; image referenced by the pinned identity.
- **Codex exec flags (inside the container, unchanged from Windows):** `--ignore-user-config`, `--ignore-rules`, `--ephemeral`, `--skip-git-repo-check`, `-s read-only`, `-c web_search="disabled"`, `-c shell_environment_policy.inherit="none"`, `-m gpt-5.6-sol -c model_reasoning_effort="xhigh"`, the complete default-deny `--disable` set, `--output-schema <schema>`, `-o <tmpfs>/verdict.json`, `--json`, and `-` (prompt over stdin).
- **Image identity (the pin):** architecture-qualified — `image_config_digest` (image ID) + `os/arch`, plus the registry `platform_manifest_digest` when pulled by digest. Re-verified before every round; a mismatch refuses the round (exit `13` analogue) pending explicit `--accept-new-image`.
- **Credential rules:** the durable refresh credential never enters the container; `~/.codex` is never mounted; a short-lived **access-only** token is staged; `AGENTS.md` staged bytes are hash-verified against the manifest `agents_md_sha256` immediately before container creation; the staged token's remaining lifetime must exceed the max round/watchdog deadline + startup + clock-skew margins or the round fails closed before launch.
- **Confinement:** no external write; no symlink followed; a bounded run (in-container watchdog with an absolute deadline independent of the host); guaranteed cleanup on success, failure, timeout, and runner crash (lease-gated reaper).
- **Bounded streams:** stdout/stderr captured under explicit per-channel and aggregate byte caps; over-limit → immediate container termination; retained bytes bounded; `docker cp` verdict retrieval is size-bounded (streamed through a bounded tar parser).
- **Exit-code contract (shared, enforced in Phase 3's entry point):** `12` environment (runtime absent/unsupported); `13` image-pin mismatch. Phase 2 surfaces these as typed exceptions/enums; Phase 3 maps them to process exits.

## File Structure (Phase 2)

- Create `gauntlet-review/python/gauntlet_review/bounded.py` — bounded subprocess runner (Task 1).
- Create `gauntlet-review/python/gauntlet_review/runtime.py` — `ContainerRuntime` seam: detection, argv, image inspection, userns mapping (Tasks 2, 6).
- Create `gauntlet-review/python/gauntlet_review/runconfig.py` — `RunConfig` + `create`-argv composition + semantic descriptor (Task 3).
- Create `gauntlet-review/python/gauntlet_review/lease.py` — run id + per-run file lease (Task 4).
- Create `gauntlet-review/python/gauntlet_review/broker.py` — credential broker (Task 5).
- Create `gauntlet-review/python/gauntlet_review/sandbox.py` — lifecycle orchestration + reaper (Task 8).
- Create `gauntlet-review/docker/Dockerfile` and `gauntlet-review/docker/entrypoint.py` — image + wrapper (Task 7).
- Create tests under `gauntlet-review/python/tests/` — one module per source module; the Docker integration test in `tests/integration/`.

Run all commands from `gauntlet-review/python/` unless stated otherwise. The venv from Phase 1 (`.venv`) is reused; no new install-time dependencies.

---

### Task 1: Bounded subprocess runner (`bounded.py`)

Python analogue of `Invoke-BoundedProcess` (lib.ps1): every external command (runtime CLI, `docker cp`, the container run) goes through it. Async stdin, concurrently-drained stdout/stderr under byte caps, one shared deadline, kill the process group on timeout, never raises for process-level failure.

**Files:**
- Create: `gauntlet-review/python/gauntlet_review/bounded.py`
- Test: `gauntlet-review/python/tests/test_bounded.py`

**Interfaces:**
- Produces: `gauntlet_review.bounded.run_bounded(argv: list[str], *, stdin_bytes: bytes = b"", timeout_sec: float = 1800, env: dict[str,str] | None = None, clear_env: bool = False, cwd: str | None = None, max_stdout: int = 8_000_000, max_stderr: int = 1_000_000) -> ProcResult`. `ProcResult` is a dataclass: `exit_code: int | None`, `stdout: bytes`, `stderr: bytes`, `timed_out: bool`, `start_failed: bool`, `error: str | None`, `stdout_truncated: bool`, `stderr_truncated: bool`. Never raises for a failed/timed-out/oversized child; the caller inspects the result. On POSIX the child starts a new session (`start_new_session=True`) and timeout kills the whole group.

- [ ] **Step 1: Write the failing test**

Create `gauntlet-review/python/tests/test_bounded.py`:

```python
import os
import sys
import time

import pytest

from gauntlet_review.bounded import run_bounded

PY = sys.executable


def test_captures_stdout_and_exit_code():
    r = run_bounded([PY, "-c", "print('hi')"], timeout_sec=30)
    assert r.exit_code == 0 and not r.timed_out and not r.start_failed
    assert r.stdout.strip() == b"hi"


def test_stdin_is_delivered():
    r = run_bounded([PY, "-c", "import sys; sys.stdout.write(sys.stdin.read())"],
                    stdin_bytes=b"payload", timeout_sec=30)
    assert r.stdout == b"payload"


def test_nonzero_exit_is_reported_not_raised():
    r = run_bounded([PY, "-c", "import sys; sys.exit(7)"], timeout_sec=30)
    assert r.exit_code == 7 and not r.timed_out


def test_start_failure_is_reported_not_raised():
    r = run_bounded(["this-binary-does-not-exist-xyz"], timeout_sec=30)
    assert r.start_failed and r.exit_code is None and r.error


def test_timeout_kills_and_flags():
    start = time.monotonic()
    r = run_bounded([PY, "-c", "import time; time.sleep(60)"], timeout_sec=1)
    assert r.timed_out and (time.monotonic() - start) < 30


def test_stdout_is_bounded_and_flagged():
    # Emit ~1 MB but cap at 1 KB: retained bytes are capped, truncation flagged, no hang.
    r = run_bounded([PY, "-c", "import sys; sys.stdout.write('a'*1_000_000)"],
                    timeout_sec=30, max_stdout=1024)
    assert r.stdout_truncated and len(r.stdout) <= 1024


def test_huge_stdin_does_not_deadlock_against_slow_reader():
    # Child reads a little then exits; we still must not block writing a large stdin.
    r = run_bounded([PY, "-c", "import sys; sys.stdin.read(10); print('ok')"],
                    stdin_bytes=b"x" * 5_000_000, timeout_sec=30)
    assert r.stdout.strip() == b"ok"


def test_error_surfaced_when_child_stops_reading_stdin_while_alive():
    # Child reads a few bytes, then sleeps for a long time WITHOUT exiting and
    # WITHOUT closing stdin: the write blocks on a full pipe against a child
    # that is genuinely still alive. This must be detected within the timeout
    # (fast-fail with an error), not silently waited out to the full sleep.
    start = time.monotonic()
    r = run_bounded(
        [PY, "-c", "import sys, time; sys.stdin.read(5); time.sleep(30)"],
        stdin_bytes=b"x" * 5_000_000,
        timeout_sec=2,
    )
    elapsed = time.monotonic() - start
    assert elapsed < 30
    assert r.timed_out or r.error


@pytest.mark.skipif(os.name != "posix", reason="broken-pipe-while-alive is only reliably reproducible on POSIX EPIPE semantics")
def test_error_surfaced_on_write_failure_while_child_alive():
    # Child closes its stdin read end but stays alive; a large write then hits EPIPE
    # while the process is still running -> fast-fail with error, not a full-timeout wait.
    import time
    r = run_bounded([PY, "-c", "import sys,time; sys.stdin.close(); time.sleep(30)"],
                    stdin_bytes=b"x" * 5_000_000, timeout_sec=5)
    assert r.error and "stdin write failed" in r.error
    assert not r.timed_out  # it was a detected fault, not a timeout
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_bounded.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'gauntlet_review.bounded'`.

- [ ] **Step 3: Write the implementation**

Create `gauntlet-review/python/gauntlet_review/bounded.py`:

```python
"""Bounded subprocess runner. Python analogue of Invoke-BoundedProcess (lib.ps1):
async stdin, concurrently-drained stdout/stderr under byte caps, one shared deadline,
kill the process group on timeout, and NEVER raise for process-level failure."""
from __future__ import annotations

import os
import signal
import subprocess
import threading
import time
from dataclasses import dataclass


@dataclass
class ProcResult:
    exit_code: int | None
    stdout: bytes
    stderr: bytes
    timed_out: bool
    start_failed: bool
    error: str | None
    stdout_truncated: bool
    stderr_truncated: bool


def _drain(stream, cap: int, out: dict, key: str):
    # Read to EOF so the child never blocks on a full pipe, but retain only `cap` bytes.
    buf = bytearray()
    truncated = False
    while True:
        try:
            chunk = stream.read(65536)
        except (OSError, ValueError):
            # Best-effort: the main thread may close this pipe out from under us
            # while we're still blocked reading from an already-timed-out/killed
            # child. Exit quietly instead of surfacing via threading.excepthook.
            break
        if not chunk:
            break
        if len(buf) < cap:
            room = cap - len(buf)
            buf += chunk[:room]
            if len(chunk) > room:
                truncated = True
        else:
            truncated = True
    out[key] = bytes(buf)
    out[key + "_truncated"] = truncated


def _kill(proc):
    try:
        if os.name == "posix":
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        else:
            proc.kill()
    except (ProcessLookupError, PermissionError, OSError):
        pass


def run_bounded(argv, *, stdin_bytes=b"", timeout_sec=1800, env=None, clear_env=False,
                cwd=None, max_stdout=8_000_000, max_stderr=1_000_000) -> ProcResult:
    full_env = ({} if clear_env else dict(os.environ))
    if env:
        full_env.update(env)
    popen_kwargs = dict(
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        cwd=cwd, env=full_env,
    )
    if os.name == "posix":
        popen_kwargs["start_new_session"] = True  # own process group, for group-kill
    try:
        proc = subprocess.Popen(argv, **popen_kwargs)
    except OSError as exc:
        return ProcResult(None, b"", b"", False, True, str(exc), False, False)

    deadline = time.monotonic() + timeout_sec

    def remaining():
        return max(0, deadline - time.monotonic())

    captured: dict = {}
    t_out = threading.Thread(target=_drain, args=(proc.stdout, max_stdout, captured, "stdout"), daemon=True)
    t_err = threading.Thread(target=_drain, args=(proc.stderr, max_stderr, captured, "stderr"), daemon=True)
    t_out.start()
    t_err.start()

    write_err = {}

    def _write():
        try:
            if stdin_bytes:
                proc.stdin.write(stdin_bytes)
            proc.stdin.close()
        except (BrokenPipeError, OSError) as exc:  # broken pipe: child exited, or a genuine fault
            write_err["e"] = exc

    t_in = threading.Thread(target=_write, daemon=True)
    t_in.start()

    timed_out = False
    error: str | None = None

    t_in.join(timeout=remaining())
    if t_in.is_alive():
        # Write did not complete within the deadline: a child that never drains stdin.
        timed_out = True
        _kill(proc)
    elif "e" in write_err and proc.poll() is None:
        # Write failed while the child is still running: a genuine fault, not a
        # benign failure caused by an already-exited child. Surface it and kill early.
        error = f"stdin write failed: {write_err['e']}"
        _kill(proc)
    else:
        # stdin delivered, or the write failed only because the child already
        # exited (benign): proceed to collect its exit.
        try:
            proc.wait(timeout=remaining())
        except subprocess.TimeoutExpired:
            timed_out = True
            _kill(proc)

    # Single generic reap for every kill path above (timeout, stalled-stdin
    # write, or fault-while-alive): avoids a redundant double-wait.
    if (timed_out or error is not None) and proc.poll() is None:
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass

    t_in.join(timeout=5)
    t_out.join(timeout=15)
    t_err.join(timeout=15)

    # A write failure raised before reaching `proc.stdin.close()` inside `_write()`
    # (e.g. a genuine fault, or the kill-while-blocked path) leaves the stdin pipe
    # open; closing here is idempotent and guarantees no unclosed-file warnings.
    try:
        proc.stdin.close()
    except OSError:
        pass
    try:
        proc.stdout.close()
    except OSError:
        pass
    try:
        proc.stderr.close()
    except OSError:
        pass

    return ProcResult(
        exit_code=(None if (timed_out or error is not None) else proc.returncode),
        stdout=captured.get("stdout", b""),
        stderr=captured.get("stderr", b""),
        timed_out=timed_out,
        start_failed=False,
        error=error,
        stdout_truncated=captured.get("stdout_truncated", False),
        stderr_truncated=captured.get("stderr_truncated", False),
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_bounded.py -v`
Expected: PASS (9 tests; the POSIX-only fault-while-alive test skips on Windows, so 8 pass + 1 skipped there and 9 pass on Linux/macOS).

- [ ] **Step 5: Commit**

```bash
git add gauntlet-review/python/gauntlet_review/bounded.py gauntlet-review/python/tests/test_bounded.py
git commit -m "feat(py): bounded subprocess runner"
```

---

### Task 2: Container runtime seam — detection + image inspection (`runtime.py`)

The single place that shells out to `docker`/`podman`. Everything else depends on the `ContainerRuntime` **interface**, so tests inject a fake. This task delivers detection, the CLI-name resolution, and image-identity + userns-mapping inspection (pure parsing of `inspect` JSON, unit-tested against captured fixtures).

**Files:**
- Create: `gauntlet-review/python/gauntlet_review/runtime.py`
- Test: `gauntlet-review/python/tests/test_runtime.py`

**Interfaces:**
- Consumes: `gauntlet_review.bounded.run_bounded` (Task 1).
- Produces:
  - `gauntlet_review.runtime.RuntimeUnavailable(Exception)`.
  - `ImageIdentity` dataclass: `config_digest: str`, `os: str`, `arch: str`, `manifest_digest: str | None`.
  - `detect_runtime(candidates=("docker","podman"), *, _which=None, _probe=None) -> str` — returns the runtime executable name; raises `RuntimeUnavailable` if none usable. `_which`/`_probe` are injection seams for tests.
  - `parse_image_identity(inspect_json: str) -> ImageIdentity` — pure parser of `<rt> image inspect --format '{{json .}}'` output (`Id`, `Os`, `Architecture`; `manifest_digest` derived from `RepoDigests` when present).
  - `parse_userns_mapping(info_json: str) -> dict` — pure parser of `<rt> info --format '{{json .}}'`: returns `{"rootless": bool, "uid_map_present": bool}` from `host.security.rootless` / `SecurityOptions`.
  - `class ContainerRuntime` (thin, real) wrapping the resolved runtime name with methods used in later tasks: `create(argv) -> str` (returns container id from the cidfile), `start(cid, stdin_bytes, timeout_sec, caps) -> ProcResult`, `kill(cid)`, `rm(cid)`, `cp_out_bounded(cid, src, dest, max_bytes) -> bool` (Task 6), `inspect_image(ref) -> ImageIdentity`, `inspect_mounts(cid) -> list[dict]`, `info() -> dict`, `list_labeled(label) -> list[str]`. Only the pure parsers and `detect_runtime` are covered here; the shelling methods are exercised by the integration task (Task 9) and unit-tested via the fake elsewhere.

- [ ] **Step 1: Write the failing test**

Create `gauntlet-review/python/tests/test_runtime.py`:

```python
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


def test_parse_userns_mapping_rootless():
    doc = json.dumps({"host": {"security": {"rootless": True}}})
    assert parse_userns_mapping(doc)["rootless"] is True
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_runtime.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'gauntlet_review.runtime'`.

- [ ] **Step 3: Write the implementation**

Create `gauntlet-review/python/gauntlet_review/runtime.py`:

```python
"""Container runtime seam. The only module that shells out to docker/podman; all other
code depends on the ContainerRuntime interface so tests can inject a fake. Pure parsers
(image identity, userns mapping) and detection are unit-tested; the shelling methods are
exercised by the Task 9 integration smoke test."""
from __future__ import annotations

import json
import shutil
from dataclasses import dataclass

from gauntlet_review.bounded import run_bounded


class RuntimeUnavailable(Exception):
    """No usable container runtime (maps to exit 12 in Phase 3)."""


@dataclass
class ImageIdentity:
    config_digest: str
    os: str
    arch: str
    manifest_digest: str | None


def _default_probe(name: str) -> bool:
    r = run_bounded([name, "version", "--format", "{{.Server.Version}}"], timeout_sec=30)
    return (not r.start_failed) and r.exit_code == 0


def detect_runtime(candidates=("docker", "podman"), *, _which=None, _probe=None) -> str:
    which = _which or shutil.which
    probe = _probe or _default_probe
    for name in candidates:
        if which(name) and probe(name):
            return name
    raise RuntimeUnavailable(
        f"no usable container runtime found (tried: {', '.join(candidates)}); "
        f"install Docker or Podman, or run the Windows PowerShell stack"
    )


def parse_image_identity(inspect_json: str) -> ImageIdentity:
    doc = json.loads(inspect_json)
    if isinstance(doc, list):  # `image inspect` returns a JSON array
        doc = doc[0]
    manifest = None
    for rd in doc.get("RepoDigests") or []:
        if "@" in rd:
            manifest = rd.split("@", 1)[1]
            break
    return ImageIdentity(
        config_digest=doc["Id"],
        os=doc["Os"],
        arch=doc["Architecture"],
        manifest_digest=manifest,
    )


def parse_userns_mapping(info_json: str) -> dict:
    doc = json.loads(info_json)
    rootless = False
    host = doc.get("host")
    if isinstance(host, dict):  # podman shape
        rootless = bool(host.get("security", {}).get("rootless", False))
    for opt in doc.get("SecurityOptions", []) or []:  # docker shape: "name=rootless"
        if "rootless" in opt:
            rootless = True
    return {"rootless": rootless, "uid_map_present": rootless}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_runtime.py -v`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add gauntlet-review/python/gauntlet_review/runtime.py gauntlet-review/python/tests/test_runtime.py
git commit -m "feat(py): container runtime detection + image/userns inspection parsers"
```

---

### Task 3: Run config + `create`-argv composition (`runconfig.py`)

The container analogue of `New-CodexArgs`: a pure function that builds the exact `<rt> create` argv from a `RunConfig`, plus the canonical **semantic descriptor** (per-run values replaced by typed placeholders) that Phase 3 will hash. All mandatory security flags are emitted here; a test asserts the exact argv so a dropped `--cap-drop`/namespace/`--user` is caught.

**Files:**
- Create: `gauntlet-review/python/gauntlet_review/runconfig.py`
- Test: `gauntlet-review/python/tests/test_runconfig.py`

**Interfaces:**
- Consumes: `gauntlet_review.features.FEATURE_ALLOWLIST` and `disable_set` (Phase 1) via the caller (the disable set is passed in, already computed).
- Produces:
  - `RunConfig` dataclass with fields: `image_ref: str`, `platform: str` (e.g. `"linux/arm64"`), `uid: int`, `gid: int`, `cidfile: str`, `staging_dir: str`, `codex_home: str` (mount dest, e.g. `/codex-home`), `tmpfs_dir: str` (e.g. `/work`), `verdict_path: str` (e.g. `/work/verdict.json`), `schema_path: str` (mount dest of the schema, read-only), `disable_set: list[str]`, `pids_limit: int = 256`, `memory: str = "2g"`, `cpus: str = "2"`, `run_label: str`, `model: str = "gpt-5.6-sol"`, `effort: str = "xhigh"`.
  - `build_create_argv(runtime: str, cfg: RunConfig) -> list[str]` — the full `<rt> create …` argv (container config flags, then the image, then the entrypoint's codex args).
  - `semantic_profile(cfg: RunConfig) -> dict` — the canonicalizable descriptor with per-run values (`cidfile`, `staging_dir`, `run_label`, `uid`, `gid`) replaced by typed placeholders (`"<cidfile>"`, `"<staging_dir>"`, `"<run_label>"`, `"<uid>"`, `"<gid>"`), so two runs that differ only in those hash equal (verified in Phase 3).

- [ ] **Step 1: Write the failing test**

Create `gauntlet-review/python/tests/test_runconfig.py`:

```python
from gauntlet_review.runconfig import RunConfig, build_create_argv, semantic_profile


def _cfg(**over):
    base = dict(
        image_ref="codex@sha256:dead", platform="linux/arm64", uid=1000, gid=1000,
        cidfile="/run/cid-abc", staging_dir="/run/stg-abc", codex_home="/codex-home",
        tmpfs_dir="/work", verdict_path="/work/verdict.json", schema_path="/codex-home/verdict.schema.json",
        disable_set=["apps", "shell_tool"], run_label="gauntlet-run-abc",
    )
    base.update(over)
    return RunConfig(**base)


def _value_after(argv, flag):
    """Return the value immediately following `flag` in argv, or None if `flag` is absent
    (or has nothing after it). Used to assert flag->value ADJACENCY, not just membership."""
    for i, a in enumerate(argv):
        if a == flag:
            return argv[i + 1] if i + 1 < len(argv) else None
    return None


def test_argv_carries_every_mandatory_security_flag():
    argv = build_create_argv("docker", _cfg())
    assert argv[:2] == ["docker", "create"]
    for token in ["--user", "1000:1000", "--read-only", "--cap-drop", "ALL",
                  "--security-opt", "no-new-privileges", "--pids-limit",
                  "--log-driver", "none", "--platform", "linux/arm64",
                  "--cidfile", "/run/cid-abc", "--label", "gauntlet-run-abc"]:
        assert token in argv, token
    # flag -> value ADJACENCY for the security-critical flags (not just membership)
    assert _value_after(argv, "--user") == "1000:1000"
    assert _value_after(argv, "--ipc") == "private"
    assert _value_after(argv, "--cgroupns") == "private"
    # PID and UTS namespaces are private by DEFAULT on Docker/Podman; Docker rejects the
    # literal "--pid private"/"--uts private", so these flags must not appear at all.
    assert "--pid" not in argv
    assert "--uts" not in argv
    assert "--network" in argv  # egress mode is explicit (open, per spec v1)
    # exactly one user bind mount: the credential staging dir, read-only
    binds = [argv[i + 1] for i, a in enumerate(argv) if a == "-v" or a == "--mount"]
    assert any("/run/stg-abc" in b and "ro" in b for b in binds)
    assert not any("/run/stg-abc" not in b and b.startswith("/") and ":" in b and "tmpfs" not in b for b in binds)


def test_argv_carries_all_codex_hermetic_flags_and_disable_set():
    argv = build_create_argv("docker", _cfg())
    for token in ["--ignore-user-config", "--ignore-rules", "--ephemeral",
                  "--skip-git-repo-check", "-s", "read-only",
                  'web_search="disabled"', 'shell_environment_policy.inherit="none"',
                  "-m", "gpt-5.6-sol", "--output-schema", "--json"]:
        assert token in argv, token
    assert argv[-1] == "-"  # prompt over stdin
    # default-deny: every feature in the set gets a --disable
    assert argv.count("--disable") == 2


def test_never_uses_host_namespaces_or_privileged():
    argv = build_create_argv("docker", _cfg())
    # no host-namespace sharing: --ipc/--cgroupns must never carry "host"
    for flag in ("--ipc", "--cgroupns"):
        assert _value_after(argv, flag) != "host"
    # --pid and --uts must not be present with any value at all (private by default;
    # Docker rejects the literal "--pid private"/"--uts private")
    assert "--pid" not in argv
    assert "--uts" not in argv
    assert "--privileged" not in argv


def test_semantic_profile_placeholders_make_per_run_values_stable():
    a = semantic_profile(_cfg(cidfile="/run/cid-1", staging_dir="/run/stg-1", run_label="run-1", uid=1000, gid=1000))
    b = semantic_profile(_cfg(cidfile="/run/cid-2", staging_dir="/run/stg-2", run_label="run-2", uid=1000, gid=1000))
    assert a == b  # differ only in per-run values -> identical semantic profile


def test_semantic_profile_changes_when_a_security_value_changes():
    base = semantic_profile(_cfg())
    weakened = semantic_profile(_cfg(pids_limit=999999))
    assert base != weakened


def test_semantic_profile_differs_when_image_ref_changes():
    # image_ref is the pinned image digest -- the most security-critical value -- and must
    # appear verbatim in the template, not be placeholder-ized away.
    a = semantic_profile(_cfg(image_ref="codex@sha256:aaaa"))
    b = semantic_profile(_cfg(image_ref="codex@sha256:bbbb"))
    assert a != b
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_runconfig.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'gauntlet_review.runconfig'`.

- [ ] **Step 3: Write the implementation**

Create `gauntlet-review/python/gauntlet_review/runconfig.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_runconfig.py -v`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add gauntlet-review/python/gauntlet_review/runconfig.py gauntlet-review/python/tests/test_runconfig.py
git commit -m "feat(py): container create-argv composition + semantic profile descriptor"
```

---

### Task 4: Run id + per-run file lease (`lease.py`)

An unguessable run id and a file lease held from before staging creation through cleanup. The reaper (Task 8) must acquire a run's lease *non-blockingly* before touching its container/staging dir; a held lease means the run is live.

**Files:**
- Create: `gauntlet-review/python/gauntlet_review/lease.py`
- Test: `gauntlet-review/python/tests/test_lease.py`

**Interfaces:**
- Produces:
  - `new_run_id() -> str` — `"gauntlet-" + secrets.token_hex(16)` (unguessable; also the container label).
  - `class RunLease` — `RunLease.acquire(path) -> RunLease` (exclusive, creates the lock file), `try_acquire(path) -> RunLease | None` (non-blocking; `None` if held by another process), `release()`, context-manager. POSIX uses `fcntl.flock(LOCK_EX|LOCK_NB)`; Windows uses `msvcrt.locking`.

- [ ] **Step 1: Write the failing test**

Create `gauntlet-review/python/tests/test_lease.py`:

```python
from gauntlet_review.lease import new_run_id, RunLease


def test_run_id_unguessable_and_unique():
    a, b = new_run_id(), new_run_id()
    assert a != b and a.startswith("gauntlet-") and len(a) > 20


def test_lease_is_exclusive_non_blocking(tmp_path):
    p = tmp_path / "run.lease"
    held = RunLease.acquire(str(p))
    try:
        assert RunLease.try_acquire(str(p)) is None  # a second acquirer must fail non-blockingly
    finally:
        held.release()


def test_lease_reacquirable_after_release(tmp_path):
    p = tmp_path / "run.lease"
    RunLease.acquire(str(p)).release()
    second = RunLease.try_acquire(str(p))
    assert second is not None
    second.release()


def test_lease_context_manager_releases(tmp_path):
    p = tmp_path / "run.lease"
    with RunLease.acquire(str(p)):
        assert RunLease.try_acquire(str(p)) is None
    assert RunLease.try_acquire(str(p)) is not None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_lease.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'gauntlet_review.lease'`.

- [ ] **Step 3: Write the implementation**

Create `gauntlet-review/python/gauntlet_review/lease.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_lease.py -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add gauntlet-review/python/gauntlet_review/lease.py gauntlet-review/python/tests/test_lease.py
git commit -m "feat(py): run id + per-run exclusive file lease"
```

---

### Task 5: Credential broker — staging + verification (`broker.py`)

Stages an access-only `auth.json` + a hash-verified `AGENTS.md` into an owner-only 0700 dir, under an interprocess lock, with a token-lifetime margin check. The **token-exchange mechanism** (how the access-only token is produced from `~/.codex`) depends on the real Codex `auth.json` schema and is resolved by the empirical step below; everything around it (staging, no-follow copy, hash-verify, lifetime gate, lock, cleanup) is implemented and unit-tested now with the token producer injected.

**Files:**
- Create: `gauntlet-review/python/gauntlet_review/broker.py`
- Test: `gauntlet-review/python/tests/test_broker.py`

**Interfaces:**
- Consumes: `gauntlet_review.lease` (for the interprocess lock idiom), `hashlib`.
- Produces:
  - `BrokerError(Exception)` (fail-closed; maps to exit 12 in Phase 3).
  - `stage_credential(*, codex_home: str, staging_dir: str, agents_md_sha256: str, min_lifetime_sec: float, token_provider, now: float) -> None` — creates `staging_dir` (0700, owner-only), writes `auth.json` from `token_provider()` (a callable returning `{"json": str, "expires_at": float}`; injected so the real exchange is pluggable), copies `AGENTS.md` from `<codex_home>/AGENTS.md` via an **`O_NOFOLLOW`** fd, hashes the staged bytes, and raises `BrokerError` unless the hash equals `agents_md_sha256`; raises `BrokerError` if `expires_at - now < min_lifetime_sec`. `token_provider` and `now` are injected for tests; production wires the real provider (empirical step) and `time.time`.
  - `default_token_provider(codex_home: str) -> dict` — the real access-only producer, implemented per the empirical finding below.

- [ ] **Step 0 (empirical, do first): determine the access-only token mechanism**

This is a required investigation, not a code step. On a machine with an authenticated Codex CLI:

1. Record the schema of `~/.codex/auth.json` (`python -c "import json;print(list(json.load(open('...')).keys()))"`), identifying the access-token field, the refresh-token field, and the expiry.
2. Construct a candidate access-only `auth.json` containing only the access token + any non-secret required fields (no refresh token) and run one `codex exec --version`-equivalent *and* one real `exec` against it in a scratch `CODEX_HOME`. Determine whether Codex functions without the refresh token.
3. Write the finding into `docs/build-log/` and choose the producer:
   - **If access-only works:** `default_token_provider` refreshes host-side if needed (under the broker lock), then emits `{"json": <access-only auth.json>, "expires_at": <access-token expiry>}`.
   - **If Codex requires the refresh token:** fall back to the spec's narrowed path — stage the minimal working credential, document that the container holds a refresh-capable token for the round, and apply the round-2/round-9 rotation handling (host-side lock + fsync-atomic persistence; narrow the host-auth-preservation claim). Update the spec's credential section to match the finding.

The unit tests below inject `token_provider`, so Tasks 5's code lands regardless; only `default_token_provider`'s body depends on this finding.

- [ ] **Step 1: Write the failing test**

Create `gauntlet-review/python/tests/test_broker.py`:

```python
import hashlib
import json
import os
from pathlib import Path

import pytest

from gauntlet_review.broker import BrokerError, stage_credential

AGENTS = b"# account AGENTS.md\nreview presentation rules\n"
AGENTS_SHA = hashlib.sha256(AGENTS).hexdigest()


def _codex_home(tmp_path) -> str:
    home = tmp_path / "codex-home"
    home.mkdir()
    (home / "AGENTS.md").write_bytes(AGENTS)
    return str(home)


def _provider(expires_at):
    return lambda: {"json": json.dumps({"tokens": {"access_token": "AT"}}), "expires_at": expires_at}


def test_stages_auth_and_agents_when_hash_matches(tmp_path):
    home = _codex_home(tmp_path)
    stg = tmp_path / "stg"
    stage_credential(codex_home=home, staging_dir=str(stg), agents_md_sha256=AGENTS_SHA,
                     min_lifetime_sec=1800, token_provider=_provider(10_000), now=0.0)
    assert (stg / "auth.json").is_file() and (stg / "AGENTS.md").read_bytes() == AGENTS
    if os.name == "posix":  # mode bits are POSIX-specific; the offline suite also runs on Windows
        assert (stg.stat().st_mode & 0o777) == 0o700


def test_agents_hash_mismatch_fails_closed(tmp_path):
    home = _codex_home(tmp_path)
    stage = tmp_path / "stg"
    with pytest.raises(BrokerError):
        stage_credential(codex_home=home, staging_dir=str(stage), agents_md_sha256="0" * 64,
                         min_lifetime_sec=1800, token_provider=_provider(10_000), now=0.0)


def test_insufficient_token_lifetime_fails_closed(tmp_path):
    home = _codex_home(tmp_path)
    stage = tmp_path / "stg"
    with pytest.raises(BrokerError):
        stage_credential(codex_home=home, staging_dir=str(stage), agents_md_sha256=AGENTS_SHA,
                         min_lifetime_sec=1800, token_provider=_provider(100), now=0.0)  # 100s < 1800s


def test_symlinked_agents_md_rejected(tmp_path):
    home = Path(_codex_home(tmp_path))
    (home / "AGENTS.md").unlink()
    outside = tmp_path / "evil.md"
    outside.write_bytes(b"evil")
    try:
        (home / "AGENTS.md").symlink_to(outside)
    except (OSError, NotImplementedError):
        pytest.skip("symlinks not supported")
    with pytest.raises((BrokerError, OSError)):
        stage_credential(codex_home=str(home), staging_dir=str(tmp_path / "stg"),
                         agents_md_sha256=AGENTS_SHA, min_lifetime_sec=1800,
                         token_provider=_provider(10_000), now=0.0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_broker.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'gauntlet_review.broker'`.

- [ ] **Step 3: Write the implementation**

Create `gauntlet-review/python/gauntlet_review/broker.py`:

```python
"""Host-side credential broker: stage an access-only auth.json + a hash-verified AGENTS.md
into an owner-only staging dir, fail closed on any mismatch or insufficient token lifetime.
The durable refresh credential never enters the staging dir (see default_token_provider)."""
from __future__ import annotations

import hashlib
import os


class BrokerError(Exception):
    """Fail-closed credential error (maps to exit 12 in Phase 3)."""


def _read_regular_nofollow(path: str) -> bytes:
    # O_NOFOLLOW: a symlinked source is rejected (ELOOP). Confirm it is a regular file.
    fd = os.open(path, os.O_RDONLY | (os.O_NOFOLLOW if hasattr(os, "O_NOFOLLOW") else 0))
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


def default_token_provider(codex_home: str) -> dict:  # pragma: no cover - wired in Phase 3, body per Step 0
    """Produce the access-only token. Implemented per the Step-0 empirical finding.
    Must (a) hold the broker interprocess lock while reading/refreshing ~/.codex, (b) never
    place the durable refresh token in the returned json, (c) return {'json','expires_at'}."""
    raise NotImplementedError("default_token_provider: implement per Task 5 Step 0 finding")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_broker.py -v`
Expected: PASS (4 tests; the symlink test skips where symlinks are unprivileged).

- [ ] **Step 5: Commit**

```bash
git add gauntlet-review/python/gauntlet_review/broker.py gauntlet-review/python/tests/test_broker.py
git commit -m "feat(py): credential broker staging + AGENTS.md hash-verify + lifetime gate"
```

---

### Task 6: Size-bounded verdict copy-out (`runtime.py`)

`docker cp CONTAINER:src -` streams a tar to stdout; a plain `cp` to a file would materialize an oversized verdict on disk first. This adds a bounded tar extractor that reads the single-member tar stream, enforces a byte cap, and writes an owner-only temp file, aborting on over-limit.

**Files:**
- Modify: `gauntlet-review/python/gauntlet_review/runtime.py`
- Test: `gauntlet-review/python/tests/test_cp_bounded.py`

**Interfaces:**
- Consumes: `gauntlet_review.bounded.run_bounded` (Task 1).
- Produces (added to `runtime.py`): `extract_single_file_from_tar(tar_bytes: bytes, dest_path: str, max_bytes: int) -> int` — reads a one-member tar (as produced by `docker cp SRC -`), enforces `max_bytes` on the member, writes `dest_path` with `0o600`, returns bytes written; raises `ValueError` if the member exceeds `max_bytes`, is absent, or is not a regular file. (`ContainerRuntime.cp_out_bounded` composes `run_bounded([rt,"cp",f"{cid}:{src}","-"], max_stdout=max_bytes+65536)` + this extractor; that composition is covered by the Task 9 smoke test.)

- [ ] **Step 1: Write the failing test**

Create `gauntlet-review/python/tests/test_cp_bounded.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_cp_bounded.py -v`
Expected: FAIL — `ImportError: cannot import name 'extract_single_file_from_tar'`.

- [ ] **Step 3: Write the implementation**

Append to `gauntlet-review/python/gauntlet_review/runtime.py`:

```python
import io
import os
import tarfile


def extract_single_file_from_tar(tar_bytes: bytes, dest_path: str, max_bytes: int) -> int:
    """Extract the single regular-file member of a `docker cp SRC -` tar stream into
    dest_path (0o600), enforcing max_bytes. Rejects oversized, absent, or non-regular
    members. Returns bytes written."""
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r") as tf:
        # Count ALL members first: a decoy regular member must not mask a second (e.g. symlink)
        # member, so reject on total count != 1 BEFORE testing regularity.
        members = [m for m in tf.getmembers() if m.name not in (".", "")]
        if len(members) != 1:
            raise ValueError(f"expected exactly one member in the cp stream, got {len(members)}")
        m = members[0]
        if not m.isreg():
            raise ValueError(f"member {m.name} is not a regular file")
        if m.size > max_bytes:
            raise ValueError(f"copied file {m.name} is {m.size} bytes, exceeds cap {max_bytes}")
        src = tf.extractfile(m)
        if src is None:
            raise ValueError(f"member {m.name} is not extractable as a regular file")
        fd = os.open(dest_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        written = 0
        try:
            with os.fdopen(fd, "wb") as out:
                while True:
                    chunk = src.read(65536)
                    if not chunk:
                        break
                    written += len(chunk)
                    if written > max_bytes:
                        raise ValueError("copied file exceeds cap during read")
                    out.write(chunk)
        except BaseException:
            # Never leave a partial (credential- or verdict-bearing) file behind.
            try:
                os.unlink(dest_path)
            except OSError:
                pass
            raise
        return written
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_cp_bounded.py -v`
Expected: PASS (4 tests, incl. partial-file cleanup on over-cap-during-read).

- [ ] **Step 5: Commit**

```bash
git add gauntlet-review/python/gauntlet_review/runtime.py gauntlet-review/python/tests/test_cp_bounded.py
git commit -m "feat(py): size-bounded verdict copy-out from a docker cp tar stream"
```

---

### Task 7: Image + entrypoint wrapper (`Dockerfile`, `entrypoint.py`)

The pinned image (arbitrary-UID, Codex CLI installed) and the wrapper that runs Codex, records its exit status, blocks on a marker so the tmpfs survives copy-out, and enforces an in-container absolute-deadline watchdog independent of the host.

**Files:**
- Create: `gauntlet-review/docker/Dockerfile`
- Create: `gauntlet-review/docker/entrypoint.py`
- Test: `gauntlet-review/python/tests/test_entrypoint.py`

**Interfaces:**
- Produces: `gauntlet-review/docker/entrypoint.py` runnable as the container entrypoint. It reads config from env (`GAUNTLET_CODEX_ARGV_JSON`, `GAUNTLET_VERDICT_PATH`, `GAUNTLET_EXIT_STATUS_PATH`, `GAUNTLET_MARKER_PATH`, `GAUNTLET_DEADLINE_SEC`), exposes a testable pure function `compute_watchdog_deadline(start_monotonic, deadline_sec) -> float`, and a `run(...)` that the tests drive with a fake `spawn` to assert: exit-status is written, the watchdog kills after the deadline, and it blocks until the marker appears.

- [ ] **Step 1: Write the failing test**

Create `gauntlet-review/python/tests/test_entrypoint.py`:

```python
import importlib.util
import sys
import time
from pathlib import Path

# Load the entrypoint module by path (it lives outside the package).
_SPEC = importlib.util.spec_from_file_location(
    "gauntlet_entrypoint",
    str(Path(__file__).resolve().parents[2] / "docker" / "entrypoint.py"),
)
entry = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(entry)


class FakeProc:
    """Fake process handle exposing the Popen-like surface run() depends on."""

    def __init__(self, exit_code):
        self._exit_code = exit_code
        self.killed = False
        self.kill_calls = 0

    def poll(self):
        return self._exit_code

    def kill(self):
        self.killed = True
        self.kill_calls += 1

    def wait(self, timeout=None):
        return self._exit_code


class NeverExitsProc:
    """Fake process that never exits on its own; records whether kill() was called."""

    def __init__(self):
        self.killed = False
        self.kill_calls = 0
        self._exit_code = None

    def poll(self):
        return None

    def kill(self):
        self.killed = True
        self.kill_calls += 1
        # Once killed, simulate the OS reaping it so wait() can return.
        self._exit_code = -9

    def wait(self, timeout=None):
        return self._exit_code


def test_records_exit_status_and_waits_for_marker(tmp_path):
    exit_path = tmp_path / "exit-status"
    marker = tmp_path / "marker"

    def fake_spawn(argv, stdin_fd):
        return FakeProc(3)  # simulate codex exiting 3, already done when polled

    # Marker already present -> run() returns promptly after recording exit status.
    marker.write_text("go", encoding="utf-8")
    rc = entry.run(codex_argv=["codex", "exec", "-"], verdict_path=str(tmp_path / "v.json"),
                   exit_status_path=str(exit_path), marker_path=str(marker),
                   deadline_sec=30, spawn=fake_spawn, poll_interval=0.01)
    assert exit_path.read_text().strip() == "3"
    assert rc == 3


def test_watchdog_deadline_is_absolute():
    # 5s deadline from a start point -> deadline is start+5, independent of wall drift.
    assert entry.compute_watchdog_deadline(1000.0, 5) == 1005.0


def test_watchdog_kills_when_codex_overruns(tmp_path):
    fake_proc = NeverExitsProc()

    def slow_spawn(argv, stdin_fd):
        # Simulate a child that would run forever; entrypoint's watchdog must kill it.
        return fake_proc

    with_marker = tmp_path / "marker"
    with_marker.write_text("go", encoding="utf-8")

    started = time.monotonic()
    rc = entry.run(codex_argv=["codex"], verdict_path=str(tmp_path / "v.json"),
                   exit_status_path=str(tmp_path / "e"), marker_path=str(with_marker),
                   deadline_sec=0, spawn=slow_spawn, poll_interval=0.01)
    elapsed = time.monotonic() - started

    assert fake_proc.killed  # the watchdog must actually kill the overrunning child
    assert rc != 0  # a watchdog-fired run is a non-zero result
    assert elapsed < 3  # must not block forever waiting on the fake proc


def test_watchdog_kills_real_subprocess(tmp_path):
    # Exercise the real spawn path: a genuine subprocess that sleeps far longer than the
    # watchdog deadline must actually be killed, proving the real (non-fake) kill path fires.
    marker = tmp_path / "marker"
    marker.write_text("go", encoding="utf-8")

    started = time.monotonic()
    rc = entry.run(
        codex_argv=[sys.executable, "-c", "import time; time.sleep(30)"],
        verdict_path=str(tmp_path / "v.json"),
        exit_status_path=str(tmp_path / "e"),
        marker_path=str(marker),
        deadline_sec=1,
        spawn=entry._default_spawn,
        poll_interval=0.05,
    )
    elapsed = time.monotonic() - started

    assert elapsed < 10  # well under the 30s sleep -> proves the child was actually killed
    assert rc != 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_entrypoint.py -v`
Expected: FAIL — file `docker/entrypoint.py` not found (spec load error).

- [ ] **Step 3: Write the implementation**

Create `gauntlet-review/docker/entrypoint.py`:

```python
"""In-container entrypoint wrapper. Runs Codex, records its exit status to the tmpfs,
then blocks on a marker so the tmpfs verdict survives host-side copy-out. An absolute
in-container watchdog kills Codex after the deadline, independent of the host — so a
runner crash cannot leave the container running forever."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time


def compute_watchdog_deadline(start_monotonic: float, deadline_sec: float) -> float:
    return start_monotonic + deadline_sec


def _default_spawn(argv, stdin_fd):
    # Non-blocking: start the child and return the handle immediately. run() owns the
    # active deadline and polls/kills it — it must never block on an unbounded wait().
    return subprocess.Popen(argv, stdin=stdin_fd)


def _stdin_fd():
    # Under a real container invocation stdin has a real fd. Under test harnesses
    # (e.g. pytest's captured stdin) fileno() is unsupported; fall back to None since
    # fake spawns used in tests don't dereference it.
    try:
        return sys.stdin.fileno()
    except (AttributeError, OSError, ValueError):
        return None


def run(*, codex_argv, verdict_path, exit_status_path, marker_path, deadline_sec,
        spawn=_default_spawn, poll_interval=0.5) -> int:
    start = time.monotonic()
    deadline = compute_watchdog_deadline(start, deadline_sec)

    proc = spawn(codex_argv, _stdin_fd())

    # Actively enforce the absolute deadline: poll for exit rather than blocking on an
    # unbounded wait(), so a hung Codex is killed even if the host itself has crashed.
    while True:
        rc = proc.poll()
        if rc is not None:
            break
        if time.monotonic() >= deadline:
            proc.kill()
            try:
                proc.wait(timeout=10)
            except Exception:
                pass
            rc = 124  # timeout convention -- the watchdog fired
            break
        time.sleep(poll_interval)

    # Record exit status for the host to read alongside the verdict.
    with open(exit_status_path, "w", encoding="utf-8") as fh:
        fh.write(str(rc))

    # Block until the host signals it has copied the verdict out (or the deadline passes).
    # Bounded wait: reuse the same absolute deadline so this loop can never block forever.
    while not os.path.exists(marker_path):
        if time.monotonic() >= deadline:
            break
        time.sleep(poll_interval)
    return rc


if __name__ == "__main__":  # pragma: no cover - exercised by the Task 9 integration test
    run(
        codex_argv=json.loads(os.environ["GAUNTLET_CODEX_ARGV_JSON"]),
        verdict_path=os.environ["GAUNTLET_VERDICT_PATH"],
        exit_status_path=os.environ["GAUNTLET_EXIT_STATUS_PATH"],
        marker_path=os.environ["GAUNTLET_MARKER_PATH"],
        deadline_sec=float(os.environ["GAUNTLET_DEADLINE_SEC"]),
    )
```

Create `gauntlet-review/docker/Dockerfile`:

```dockerfile
# Pinned base by digest (replace with the resolved digest at build time; recorded in the manifest).
FROM debian:bookworm-slim@sha256:REPLACE_WITH_PINNED_DIGEST

# Arbitrary-UID compatible: no fixed USER; the runner passes --user <hostuid>:<hostgid>.
# World-readable/executable install locations so any UID can run.
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install the PINNED Codex CLI. Mechanism (npm global or release artifact) is finalized in
# Task 5 Step 0's sibling investigation; pin the exact version and record its provenance.
# COPY the pinned CLI in or RUN the pinned installer here.

COPY entrypoint.py /gauntlet/entrypoint.py
RUN chmod 0755 /gauntlet/entrypoint.py

ENTRYPOINT ["python3", "/gauntlet/entrypoint.py"]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_entrypoint.py -v`
Expected: PASS (4 tests) — including a real-subprocess test that actually spawns and kills a
child process to prove the watchdog's kill path fires outside of fakes. (The Dockerfile is
built in Task 9.)

- [ ] **Step 5: Commit**

```bash
git add gauntlet-review/docker/Dockerfile gauntlet-review/docker/entrypoint.py gauntlet-review/python/tests/test_entrypoint.py
git commit -m "feat(py): container entrypoint wrapper (exit-status, marker-block, watchdog) + Dockerfile"
```

---

### Task 8: Lifecycle orchestration + reaper (`sandbox.py`)

Ties it together against the `ContainerRuntime` interface, tested with a **fake runtime** (no Docker): create → start (bounded) → wait-for-exit-status → bounded copy-out → write marker → kill → guaranteed cleanup; over-limit streams kill immediately; timeout kills; the startup reaper reclaims a stale run only after acquiring its lease and confirming no live container.

**Files:**
- Create: `gauntlet-review/python/gauntlet_review/sandbox.py`
- Test: `gauntlet-review/python/tests/test_sandbox.py`

**Interfaces:**
- Consumes: `runtime` (Tasks 2, 6), `runconfig` (Task 3), `lease` (Task 4), `broker` (Task 5), `bounded` (Task 1).
- Produces:
  - `RoundResult` dataclass: `verdict_path: str | None`, `exit_status: int | None`, `stdout: bytes`, `stderr: bytes`, `timed_out: bool`, `over_limit: bool`, `error: str | None`.
  - `run_round(runtime, cfg, *, prompt_bytes, timeout_sec, marker_path, max_verdict_bytes=200_000) -> RoundResult` — the lifecycle. `runtime` is any object satisfying the `ContainerRuntime` method set; tests pass a fake. Guarantees `runtime.rm(cid)` is called on every path (success, failure, timeout).
  - `reap_stale(runtime, *, lease_dir, label_prefix) -> list[str]` — for each labeled container, `RunLease.try_acquire` its lease; **skip if the lease can't be acquired** (run is live); otherwise `kill`+`rm` and remove its staging dir. Returns the reaped run ids.

- [ ] **Step 1: Write the failing test**

Create `gauntlet-review/python/tests/test_sandbox.py`:

```python
import pytest

from gauntlet_review.sandbox import run_round, reap_stale, RoundResult
from gauntlet_review.runconfig import RunConfig
from gauntlet_review.lease import RunLease


class FakeRuntime:
    def __init__(self, *, exit_status=0, verdict=b'{"verdict":"approve"}', timed_out=False, over_limit=False):
        self.calls = []
        self._exit_status = exit_status
        self._verdict = verdict
        self._timed_out = timed_out
        self._over_limit = over_limit

    def create(self, argv):
        self.calls.append("create")
        return "cid-1"

    def start(self, cid, stdin_bytes, timeout_sec):
        self.calls.append("start")
        from gauntlet_review.bounded import ProcResult
        return ProcResult(exit_code=(None if self._timed_out else 0), stdout=b"", stderr=b"",
                          timed_out=self._timed_out, start_failed=False, error=None,
                          stdout_truncated=self._over_limit, stderr_truncated=False)

    def read_exit_status(self, cid):
        return self._exit_status

    def cp_out_bounded(self, cid, src, dest, max_bytes):
        self.calls.append("cp")
        with open(dest, "wb") as fh:
            fh.write(self._verdict)
        return True

    def kill(self, cid):
        self.calls.append("kill")

    def rm(self, cid):
        self.calls.append("rm")


def _cfg(tmp_path):
    return RunConfig(image_ref="img@sha256:x", platform="linux/amd64", uid=1000, gid=1000,
                     cidfile=str(tmp_path / "cid"), staging_dir=str(tmp_path / "stg"),
                     codex_home="/codex-home", tmpfs_dir="/work",
                     verdict_path="/work/verdict.json", schema_path="/codex-home/v.schema.json",
                     disable_set=["apps"], run_label="gauntlet-run-x")


def test_happy_path_retrieves_verdict_and_cleans_up(tmp_path):
    rt = FakeRuntime(exit_status=0)
    res = run_round(rt, _cfg(tmp_path), prompt_bytes=b"prompt", timeout_sec=30,
                    marker_path=str(tmp_path / "marker"))
    assert res.verdict_path and open(res.verdict_path, "rb").read() == b'{"verdict":"approve"}'
    assert res.exit_status == 0 and not res.error
    assert "rm" in rt.calls  # guaranteed cleanup

def test_cleanup_runs_even_on_timeout(tmp_path):
    rt = FakeRuntime(timed_out=True)
    res = run_round(rt, _cfg(tmp_path), prompt_bytes=b"p", timeout_sec=1,
                    marker_path=str(tmp_path / "marker"))
    assert res.timed_out and "kill" in rt.calls and "rm" in rt.calls


def test_over_limit_stream_terminates_and_flags(tmp_path):
    rt = FakeRuntime(over_limit=True)
    res = run_round(rt, _cfg(tmp_path), prompt_bytes=b"p", timeout_sec=30,
                    marker_path=str(tmp_path / "marker"))
    assert res.over_limit and "kill" in rt.calls and "rm" in rt.calls


def test_reaper_skips_a_live_run(tmp_path):
    lease_dir = tmp_path / "leases"
    lease_dir.mkdir()
    live = RunLease.acquire(str(lease_dir / "gauntlet-live.lease"))  # a live run holds its lease
    try:
        class RT(FakeRuntime):
            def list_labeled(self, prefix):
                return ["gauntlet-live"]
        reaped = reap_stale(RT(), lease_dir=str(lease_dir), label_prefix="gauntlet-")
        assert "gauntlet-live" not in reaped  # live run must not be reaped
    finally:
        live.release()


def test_reaper_reclaims_a_dead_run(tmp_path):
    lease_dir = tmp_path / "leases"
    lease_dir.mkdir()
    (lease_dir / "gauntlet-dead.lease").write_text("", encoding="utf-8")  # no one holds it

    class RT(FakeRuntime):
        def list_labeled(self, prefix):
            return ["gauntlet-dead"]
    reaped = reap_stale(RT(), lease_dir=str(lease_dir), label_prefix="gauntlet-")
    assert reaped == ["gauntlet-dead"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_sandbox.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'gauntlet_review.sandbox'`.

- [ ] **Step 3: Write the implementation**

Create `gauntlet-review/python/gauntlet_review/sandbox.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_sandbox.py -v`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full offline suite and commit**

Run: `python -m pytest`
Expected: PASS (all Phase-1 + Phase-2 offline tests green).

```bash
git add gauntlet-review/python/gauntlet_review/sandbox.py gauntlet-review/python/tests/test_sandbox.py
git commit -m "feat(py): container lifecycle orchestration + lease-gated reaper"
```

---

### Task 9: Real-container smoke test (integration, Docker-gated)

The one test that actually builds the image and runs a container end-to-end through `run_round`, proving the seam and lifecycle work against a real runtime. It is **skipped** unless a runtime is present and `GAUNTLET_RUN_DOCKER_TESTS=1`, so the default offline suite (and Windows CI) is unaffected. The full security battery is Phase 5.

**Files:**
- Create: `gauntlet-review/python/tests/integration/test_container_smoke.py`
- Create: `gauntlet-review/python/tests/integration/__init__.py` (empty)

**Interfaces:**
- Consumes: `runtime.detect_runtime`, `runtime.ContainerRuntime`, `sandbox.run_round`, `runconfig.RunConfig`, `broker.stage_credential`.

- [ ] **Step 1: Write the (gated) test**

Create `gauntlet-review/python/tests/integration/test_container_smoke.py`:

```python
import os
import shutil

import pytest

RUN = os.environ.get("GAUNTLET_RUN_DOCKER_TESTS") == "1"
pytestmark = pytest.mark.skipif(not RUN, reason="set GAUNTLET_RUN_DOCKER_TESTS=1 to run Docker integration")


def _runtime_or_skip():
    from gauntlet_review.runtime import detect_runtime, RuntimeUnavailable
    try:
        return detect_runtime()
    except RuntimeUnavailable:
        pytest.skip("no container runtime available")


def test_build_and_run_one_container_end_to_end(tmp_path):
    rt_name = _runtime_or_skip()
    # 1) Build the pinned image from gauntlet-review/docker/ (records the identity).
    # 2) Stage a real access-only credential via broker.stage_credential (Step-0 provider).
    # 3) run_round(...) against a trivial prompt; assert a verdict.json is retrieved,
    #    exit-status recorded, streams bounded, and the container is removed afterward
    #    (`<rt> ps -a` shows no leftover with the run label).
    # This is the deliberate, usage-consuming integration gate; see the plan for the exact
    # build + credential wiring finalized in Tasks 5 and 7.
    pytest.skip("wire the build + real credential once Tasks 5/7 land on a Docker host")
```

- [ ] **Step 2: Run to verify it skips cleanly offline**

Run: `python -m pytest tests/integration/ -v`
Expected: all skipped (no `GAUNTLET_RUN_DOCKER_TESTS`).

- [ ] **Step 3: Implement the end-to-end body on a Docker host**

On a machine with Docker/Podman and an authenticated Codex CLI, replace the final `pytest.skip` with the real build + `stage_credential` + `run_round` flow and confirm it passes with `GAUNTLET_RUN_DOCKER_TESTS=1`. Record the run (image identity, timings) in `docs/build-log/`.

- [ ] **Step 4: Commit**

```bash
git add gauntlet-review/python/tests/integration/
git commit -m "test(py): Docker-gated container smoke test (skipped offline)"
```

---

## Self-Review (Phase 2)

**Spec coverage (Phase-2 scope):** ✅ bounded process runner (Invoke-BoundedProcess analogue) — Task 1; ✅ runtime detection + image identity (config digest + os/arch + manifest digest) + userns mapping — Task 2; ✅ full mandatory container run config as exact argv (user/read-only/cap-drop/no-new-priv/private namespaces/pids+mem+cpu limits/log-driver=none/single credential bind/tmpfs/platform) + all Codex hermetic flags + default-deny disable set + semantic descriptor with placeholders — Task 3; ✅ run id + per-run lease — Task 4; ✅ credential broker: access-only staging, O_NOFOLLOW copy, AGENTS.md hash-verify vs manifest, token-lifetime margin, owner-only 0700, fail-closed — Task 5 (+ empirical token-exchange procedure); ✅ size-bounded verdict copy-out — Task 6; ✅ image + entrypoint wrapper (exit-status, marker-block, absolute-deadline watchdog) — Task 7; ✅ lifecycle (create→start→copy-out→kill→guaranteed cleanup), over-limit termination, timeout kill, lease-gated reaper — Task 8; ✅ real-container proof — Task 9. Deferred to later phases (correctly out of scope here): `container_invocation_profile_hash`/policy validator/premises manifest/`invoke_codex.py` (Phase 3), `publish.py` (Phase 4), full security battery + installer + `--accept-new-image` flow (Phase 5). The semantic descriptor (Task 3) and image identity (Task 2) are produced as data for Phase 3 to fingerprint.

**Placeholder scan:** the only non-code steps are Task 5 Step 0 (a concrete empirical procedure for the access-only token, required because the real `auth.json` schema must be observed) and Task 9 Step 3 (the real-Docker wiring), plus the Dockerfile's pinned-digest/CLI-install lines which are resolved at build time and recorded in the manifest — these are genuine external dependencies, not vague TODOs. `default_token_provider`'s body is the one function whose implementation follows the Step-0 finding; its callers and tests are complete via injection.

**Type consistency:** `run_bounded`/`ProcResult` (Task 1) are consumed with the same shape by `runtime` (Task 2/6) and the `FakeRuntime`/`run_round` (Task 8); `RunConfig`/`build_create_argv`/`semantic_profile` (Task 3) are used unchanged in Task 8; `RunLease.try_acquire`/`acquire`/`release` (Task 4) are used by `broker` and `reap_stale`; `ImageIdentity` (Task 2) is the shape Phase 3 will fingerprint. The `ContainerRuntime` method set named in Task 2's interface (`create`/`start`/`read_exit_status`/`cp_out_bounded`/`kill`/`rm`/`list_labeled`/`inspect_image`/`inspect_mounts`/`info`) is the contract `run_round`/`reap_stale` call against and that `FakeRuntime` implements for the offline suite. **Note (corrected after the Phase-2 final review):** Phase 2 delivers this only as the *interface* plus the `FakeRuntime` — no real docker/podman-shelling `ContainerRuntime` class exists yet, so `run_round`/`reap_stale` have only ever executed against the fake. The real shelling implementation, and un-stubbing the Task-9 smoke test against it, is the first Phase-3 task (see "Carried forward to Phase 3" below). The exact method signatures (e.g. whether `start` takes a `caps` argument, the presence of `read_exit_status`) are finalized when that real class and `invoke_codex.py` are written.

---

## Carried forward to Phase 3 (from the Phase-2 final whole-branch review)

The Phase-2 offline core passed the final whole-branch review (no Critical; no P0/P1;
verdict: mergeable as the offline-testable core it is scoped to be). The review surfaced
cross-module **integration seams on the deliberately-deferred real-Docker path** that are
Phase-3 entry work (they cannot be resolved without doing Phase-3 wiring), plus a few
fix-later Minors. They are recorded here so Phase-3 planning picks them up:

**Phase-3 entry tasks (must resolve before real Docker is wired):**
- **Real `ContainerRuntime` (I-3):** implement the docker/podman-shelling class satisfying the
  Task-2 interface, then un-stub `tests/integration/test_container_smoke.py` Step 3 against it
  on a Docker host. Finalize signatures the fake left loose (`start(..., caps?)`,
  `read_exit_status`). This is the first Phase-3 task.
- **create-argv ↔ entrypoint contract (I-1):** `build_create_argv` currently appends the Codex
  `exec … -` args as the container command, but the image ENTRYPOINT is `entrypoint.py`, which
  reads its config from `GAUNTLET_*` env vars (`GAUNTLET_CODEX_ARGV_JSON`, `_VERDICT_PATH`,
  `_EXIT_STATUS_PATH`, `_MARKER_PATH`, `_DEADLINE_SEC`) and ignores argv. Pick one contract in
  `invoke_codex.py` — pass the codex argv + paths as `-e GAUNTLET_*` env (preferred), or have the
  entrypoint accept argv — and make the two halves consistent.
- **marker / start / copy-out handshake (I-2):** define where the "go" marker file lives so it is
  writable by the host and visible in-container (today `run_round` writes a host path while the
  entrypoint waits on an in-container path, and the create-argv mounts only the staging dir `:ro`
  plus a private tmpfs), and define when `runtime.start` returns relative to Codex vs. the wrapper
  so `docker cp` can read the still-running container's tmpfs without stalling on the in-container
  deadline.

**Fix-later Minors (fold into the relevant Phase-3 wiring):**
- **Reaper convention (M-3 resolved):** `run_round` reclaims its own `cfg.staging_dir` and
  `reap_stale` reclaims a crashed run's dir and removes the `.lease` file after a confirmed reap,
  discovering runs from containers, leases, AND staging dirs. `invoke_codex` (Phase 3) must stage
  each run under `{staging_root}/{run_id}` and hold `{run_id}.lease` for this mapping to hold.
- **`_lock_nb` errno breadth (M-5):** treats every `OSError` as "held"; distinguish
  `EWOULDBLOCK`/`EACCES` from genuine lock errors so `acquire()` doesn't report a misleading
  "already held."
- **Grandchild-kill confirmation (T7):** `bounded._kill` now kills the process TREE (POSIX
  `killpg`; Windows `taskkill /T`); still confirm on a real Docker host that container teardown
  + `--pids-limit` reap any Codex grandchildren inside the container.
- **Platform-specific manifest digest (PR-review R1 #4, remainder):** `parse_image_identity` now
  refuses to guess among ambiguous repo digests and selects by requested repo, but resolving the
  platform-specific digest of a multi-arch index needs the real `inspect`/`manifest` wiring in the
  Phase-3 `ContainerRuntime`.
- **Online secret-scanning of streamed stdout/stderr (spec line 146):** the spec calls for
  secret-scanning as the runner reads; the bounded runner currently bounds/retains bytes but does
  not scan. Belongs with the Phase-4 publish/diagnostic-retention path.
- **Windows-only bounded-runner residuals (non-production; this Python container path executes on
  Unix/macOS, Windows uses the PowerShell stack):** (a) a fully reparse-point-resistant credential
  open would close the residual check-then-open TOCTOU that remains after the `islink` fail-closed
  guard; (b) a Windows Job Object would reap a descendant that inherits the pipes and outlives the
  direct child (POSIX handles this via the captured process group). Guarded stream closes already
  prevent any hang on Windows; only the descendant-reap and TOCTOU residuals remain, both on the
  non-production platform.

**Already fixed in Phase-2 (commit `dddae2a`):** partial-file cleanup in
`extract_single_file_from_tar` (M-1); staging-dir rollback on a post-makedirs write failure in
`stage_credential` (M-2); `auth.json`/`AGENTS.md` 0600 assertions (T5d); dead imports removed.

**Fixed in Phase-2 from PR-review round 1 (commit `d3569d1`):** bounded runner now enforces a
per-channel AND aggregate byte cap with IMMEDIATE over-limit termination (spec line 144-148) and
`read1()` prompt detection; `run_round` fails closed on start-failure / stdin fault / failed
copy-out and surfaces `rm` failures; post-kill cleanup bounded to one grace; Windows process-tree
kill; `parse_userns_mapping` detects rootful `--userns-remap` (M-4); broker Windows `islink`
fail-closed no-follow and `OSError`→`BrokerError` mapping (T5b); `reap_stale` reports reaped only
after confirmed removal.

**Fixed in Phase-2 from PR-review round 2 (commit `cffc18b`):** bounded runner tracks full
write+flush completion and surfaces INCOMPLETE prompt delivery even when the child exits cleanly;
a unified event loop observes overflow/stdin-fault/deadline/exit concurrently (immediate kill on a
flood during a stalled stdin); the process group is captured up front for a POSIX tree-kill that
survives direct-child exit and reaps lingering pipe-holding descendants; stream closes are guarded
behind thread liveness (no blocking close); the aggregate cap now bounds RETAINED bytes; broker
rollback invalidates `auth.json` first and reports residual credential material.

**Fixed in Phase-2 from PR-review round 3 (commit `974ff72`):** `run_round` reclaims its
credential-bearing `cfg.staging_dir` on every path (auth.json invalidated first) and moved
`create()` inside the lifecycle guard; `reap_stale` reclaims a crashed run's staging dir via the
`{staging_root}/{run_id}` convention; `parse_image_identity` raises on a requested-repo mismatch;
the Windows `taskkill` fallback is time-bounded.

**Fixed in Phase-2 from PR-review round 4 (commit `5fad5ee`):** `reap_stale` enumerates runs from
containers, `.lease` files, AND staging dirs (so a crash between staging and container creation is
still reclaimed), makes `staging_root` mandatory, reclaims staging even with no container, gates a
reap on confirmed container removal AND staging reclamation, and removes the lease after; the
bounded runner includes the stdin writer in post-exit liveness so a stdin-only descendant is
tree-killed; `parse_image_identity` enforces an expected digest exactly.

**Fixed in Phase-2 from PR-review rounds 5-7 (commits `c8d4a13`, `a55cdc6`, `<workdir>`):** reaper
acts only on exact generated run ids (`gauntlet-`+32hex) and tolerates a `list_labeled` outage
(invalidating credentials fail-safe while retaining the lease when container state is
unconfirmed); `bounded` uses `proc.pid` directly as the POSIX PGID and clamps aggregate retention
to the chunk size (fixing a false-overflow regression); `broker.discard_staging` distinguishes
ENOENT, refuses a symlinked staging entry, and preserves unlink/rmtree errors; `runtime` raises a
typed `ImageIdentityMismatch`; the container `--workdir` is the tmpfs root.

**PR-review terminal state (rounds reached the no-P0/P1 bar at round 5 and again at round 7):**
Two P2 hardening items are deliberately deferred as non-blocking follow-ups: (a) `discard_staging`
should operate through no-follow directory handles (openat/dir-fd) and return a TYPED cleanup
result rather than `str | None`, closing the residual intermediate-symlinked-parent TOCTOU on
POSIX; (b) `reap_stale` should return a STRUCTURED partial-cleanup result (successful reaps +
per-source errors) instead of `list[str]`. Both are correctness/robustness refinements beyond the
no-P1 bar and are good first tasks alongside the Phase-3 `invoke_codex` wiring.
