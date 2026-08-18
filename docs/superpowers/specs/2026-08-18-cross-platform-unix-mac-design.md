# Cross-Platform (Unix/macOS) Gauntlet — Container-Sandbox Port Design

**Date:** 2026-08-18
**Status:** Draft — Codex review reached the **10-round cap** without approval. All 41 findings
across rounds 1–10 were accepted and addressed; rounds 1–9 were re-reviewed (each round confirmed
the prior fixes held and surfaced new, deeper issues rather than re-raising old ones), and round-10's
four findings are incorporated but **not** re-reviewed. Awaiting a human decision on next steps.
**Supersedes:** the "Cross-platform scripts" future note in [`docs/design.md`](../../design.md) (§ Out of scope / future)

## Overview

Gauntlet today is Windows/PowerShell only. Its entire value is a **provably hermetic** Codex
reviewer, and that proof was established on Windows: the reviewer runs as a host subprocess with a
hand-built minimal environment (`CODEX_HOME` + `SystemRoot`), `-s read-only`, a default-deny
feature policy, and the prompt delivered over stdin, with a 112-assertion live security battery
control-verifying that shell, web, apps, MCP, and plugins are all blocked.

This project adds a **second, independent stack** that brings the same guarantee to **Linux and
macOS**, using a **container as the sandbox boundary** rather than host-environment minimization.
The Windows PowerShell stack is unchanged. The two stacks are peers; they share only the verdict
schema (`gauntlet-review/schemas/verdict.schema.json`) and the SKILL.md loop protocol.

The controlling motivation for the container model over a straight per-OS port of the
environment-minimization model:

1. **Stronger.** The container adds a kernel-enforced filesystem/process boundary *on top of* all
   the existing flag discipline. The round-8 finding — that Codex's `read-only` sandbox still lets
   a spawned command *read* host files, contained today only by denying the shell — is closed at
   the OS level, because the host filesystem is not mounted into the container at all.
2. **Uniform mechanism.** The sandbox is a Linux container on Linux and on macOS (Docker Desktop),
   so the *boundary mechanism* is identical and the Windows-specific `SystemRoot`-for-DNS problem
   and its per-OS equivalents disappear. **Caveat (architecture):** Docker Desktop on Apple Silicon
   runs an **arm64** Linux container — a different binary image than the **x86_64** one that runs
   on a typical CI Linux host. Verification is therefore **per-architecture**, not literally
   "once"; the self-verifying install below is what makes that tractable.
3. **Self-verifying install.** Because the live battery runs *inside the pinned image*, the
   fail-closed installer re-runs that exact battery **on the host's own architecture** on whatever
   machine installs it — so an Apple-Silicon macOS install re-verifies the arm64 image on arm64, an
   x86_64 install re-verifies the x86_64 image, and no install proceeds on an architecture whose
   boundary has not been battery-verified on that machine.

## Goals

- A Python 3 implementation of `gauntlet-review` that runs on Linux and macOS.
- Codex executed inside a locked-down, pinned container that is the hermetic boundary.
- **Behavioral equivalence** with the Windows stack: same verdict contract, same normalization,
  same recommendation-id derivation, same state schema and path layout, same exit-code contract,
  same SKILL.md protocol (see § Behavioral equivalence for the precise, achievable definition).
- A fail-closed installer and a re-conceived live security battery that verify the container
  boundary before anything is installed or any review is published.

## Non-goals / out of scope

- **Any change to the Windows PowerShell stack.** It remains the Windows path, untouched. (This is
  why cross-stack *byte-identical* file output is explicitly **not** a requirement — it would force
  changing the Windows writers; see § Behavioral equivalence.)
- **Native (non-container) execution on Unix/macOS.** If Codex must run directly on the host with
  no container, that is a separate future effort (the environment-minimization "Approach A").
- **Egress-allowlist network isolation.** v1 uses open egress + tool-denial (see § Network
  egress). A proxy/firewall sidecar that restricts egress to only the model endpoints is future
  hardening.
- **Rootless-Podman-specific hardening** beyond drop-in support.
- **The `gauntlet-dev` orchestrator.** Its SKILL.md is prose that dispatches to the primitive; it
  gains a platform branch (§ Skill dispatch) but no logic change.

## Platform matrix

| Platform | Runtime | Sandbox boundary | Status |
|---|---|---|---|
| Windows | PowerShell 7 | Host subprocess + env-minimization (`CODEX_HOME` + `SystemRoot`) | Verified; unchanged |
| Linux | Python 3 | Codex in a pinned, locked-down container (host arch) | New |
| macOS | Python 3 | Codex in the same Linux container via Docker Desktop (arm64 on Apple Silicon) | New — same *mechanism*; arch-specific image, battery-verified per host |

## Architecture: the container as the boundary

Each review round is one container run of a pinned image, and **all existing flag discipline still
runs inside the container** — nothing about the Codex invocation is relaxed; the container is added
*around* it:

- `--ignore-user-config`, `--ignore-rules`, `--ephemeral`, **`--skip-git-repo-check`** (the tmpfs
  working root is deliberately not a git repo, so Codex versions that require one would otherwise
  refuse before reaching the API — corrects round-9 P1), `-s read-only`,
  `-c web_search="disabled"`, `-c shell_environment_policy.inherit="none"`, the model pin
  (`-m gpt-5.6-sol -c model_reasoning_effort="xhigh"`), and the **complete default-deny
  `--disable` set** are all passed exactly as the Windows stack passes them, and all are part of the
  invocation profile and the mandatory-value policy validator.
- Prompt delivered over **redirected UTF-8 stdin** (`codex exec … -`); review material never enters
  argv and never reaches daemon-side container logs (`--log-driver=none`). It **can** legitimately
  appear in the model's own verdict/JSONL output and in bounded diagnostic retention (the model may
  quote what it reviews), so those captured channels are treated as potentially containing review
  material and are permissioned and retention-bounded accordingly (round-7 nit).
- `--output-schema` + `-o <verdict-file>` (written to the working tmpfs, copied out **while the
  container is still running** — see lifecycle below) + `--json` exactly as today.

Container run configuration (the new boundary):

- No published ports; **run as the invoking host UID/GID** (`--user <uid>:<gid>`) against an
  **arbitrary-UID-compatible image** — both non-root *and* what lets the container read the
  owner-only credential staging dir, since Linux bind mounts preserve numeric ownership (credential
  section, round-5 P2); `--read-only` root filesystem; `--cap-drop ALL`;
  `--security-opt no-new-privileges`; `--pids-limit`; memory and CPU limits; a bounded run timeout
  (the container analogue of `Invoke-BoundedProcess`).
- **Private namespaces + no privilege escalation (corrects round-10 P1).** Private **PID, IPC, UTS,
  and cgroup** namespaces (never `--pid=host`/`--ipc=host`/etc.), `Privileged=false`, no unconfined
  seccomp/AppArmor profile, and no unapproved device or device-cgroup requests — required because the
  container runs as the invoking host UID, so a host PID namespace plus a shell-denial regression
  could otherwise expose same-UID host process data through `/proc`. These are part of the semantic
  profile and the mandatory-value policy validator, with a **host-PID same-UID canary** in the
  negative live tests.
- **`--log-driver=none`** so the daemon does not persist stdout/stderr to host-side container logs
  (an otherwise-un-audited disclosure channel — round-2 P2). The runner captures the attached
  streams directly instead. The effective logging configuration is part of the invocation profile
  (§ Premises) and is asserted by the battery.
- **No *user-requested* host bind-mounts except the credential staging mount** (below). The runtime
  itself still injects its own generated binds — `/etc/hosts`, `/etc/hostname`, `/etc/resolv.conf` —
  which are expected and distinguished from user binds by the battery (item 2, round-5 P1); what is
  excluded is any *user-supplied* bind other than the credential dir. The reviewed repository, the
  user's home directory, and every other host path are absent from the container.
- **Working root = an in-container tmpfs** that also holds the `-o` verdict file. This *is* the
  harness. The Windows "harness outside every repo, verified empty" invariants collapse to "a fresh
  tmpfs is unconditionally empty and contains no host path."
- **Minimal container environment.** `CODEX_HOME` points at the credential staging mount; no host
  environment is inherited. The `SystemRoot`-for-DNS dependency is gone — DNS is the container's own
  Linux resolver.

**Container lifecycle and verdict retrieval (explicit; corrects round-1 and round-2 P1).** A tmpfs
is torn down when a container **stops**, so a verdict cannot be `docker cp`-ed out of an *exited*
container. The runner therefore copies while the container is still alive:

1. **creates** the container from the pinned image with a retained id (a cidfile), the non-root
   user, `--read-only` rootfs, the tmpfs working root, `--log-driver=none`, and the credential
   staging mount — never `--rm`;
2. the container's entrypoint is a **small wrapper**: it runs `codex exec … -o <tmpfs>/verdict.json
   -`, records Codex's **exit status** to `<tmpfs>/exit-status`, then **blocks on a marker** so the
   tmpfs stays mounted and the verdict remains retrievable after Codex itself exits;
3. the runner streams the prompt to the wrapper's stdin and captures `stdout`/`stderr` directly
   with **streaming parsing under explicit per-channel and aggregate byte bounds (corrects round-3
   P2)** — online secret-scanning as it reads, bounded diagnostic retention, and **immediate
   container termination if a limit is exceeded**, so a long or malformed run cannot exhaust host
   memory or disk; the copied verdict/exit-status artifacts are read under the same bounded-read
   discipline. The `--json` JSONL feeds the usage gate;
4. once Codex has exited (observed via the marker/exit-status), the runner copies the verdict file
   and exit-status out while the container is still running (tmpfs live), so the verdict source is
   the `-o` file exactly as on Windows — using a **size-bounded transfer (corrects round-10 P2)**:
   streaming `docker cp CONTAINER:path -` through a bounded tar parser into an owner-only temp file
   and aborting + cleaning up immediately on declared or actual over-limit data, because a plain
   `docker cp` materializes the whole file before any post-copy check and an oversized verdict would
   otherwise consume host storage first; host-side copy overflow is tested;
5. the runner then releases the wrapper and issues an explicit `kill` against the retained id — the
   round timeout is likewise enforced by an explicit `kill`, because killing the client process
   alone does **not** stop a daemon-managed container — and a guaranteed cleanup removes the
   container on success, failure, and timeout alike.

**Crash-safe bounding (corrects round-3 P1).** Host-side enforcement alone is insufficient: if the
runner is killed or loses its daemon connection, a wrapper that blocks on the host would wait
forever, leaking the container and its credential bind. The wrapper therefore also runs an
**in-container watchdog** that kills Codex and exits after an **absolute deadline, independent of
the host**, so the run is bounded even with no host present. Every container is **labeled with a
narrowly-scoped owner/run identifier** tied to the run's file lease. On startup the reaper, for each
candidate, **acquires that run's lease non-blockingly and re-inspects the exact run id *before*
classifying, killing, or removing its container or reclaiming its staging directory (corrects
round-7 P2)** — a lease it cannot acquire means the run is still live, so the container is left
alone. "No live container references it" is therefore necessary but never sufficient on its own: the
lease is what proves the run is not still active. The bounded-run and guaranteed-cleanup guarantees
thus hold across runner crashes, not only clean exits, without a concurrent startup ever reaping a
live run's container.

**Confidentiality argument (stated precisely).** The reviewer has no shell and no file-read tool
(default-deny), so it cannot read the one secret staged into the container (a short-lived,
access-only token — below), and there are no host files to reach regardless of any Codex flag. Even
under open egress there is therefore nothing host-side to exfiltrate, and the staged token is
short-lived and carries no durable refresh capability. The container contributes filesystem and
process isolation; the flag discipline contributes tool denial; the broker (below) keeps the
durable credential out of the boundary entirely. The battery audits every captured output channel
for the staged token regardless.

## The credential — host-side broker, short-lived access-only token

The Windows stack uses the real `~/.codex` as `CODEX_HOME` (read-write). In the container the
requirement is:

1. Auth and the trusted account-level `AGENTS.md` resolve exactly as today (`config.toml` stays
   ignored via `--ignore-user-config`).
2. **The durable refresh credential never enters the container**, and the host `~/.codex` is never
   mounted (a read-only bind of the whole directory still *discloses* every file in it).
3. **A round is never hard-failed by token expiry** under normal operation.

**Mechanism.** A **host-side broker** owns `~/.codex`. Before each round (and before each battery
control) it ensures a valid access token — minting/exchanging one host-side, **preferring an
exchange that does not rotate the durable refresh credential** (see § Risks and mitigations) — and
writes an **access-token-only** `auth.json` (no refresh token) plus a copy of
`AGENTS.md` into a fresh, host-created **staging directory**, after validating each source is a
**regular file** (not a symlink/socket/device) and copying with no-follow semantics. Because
`AGENTS.md` is executed by Codex as **trusted instructions**, the broker copies it from an
**`O_NOFOLLOW` file descriptor**, hashes the exact bytes written to staging, re-opens the staged
regular file, and **compares that hash to the manifest's `agents_md_sha256` immediately before
container creation (corrects round-8 P1)** — so a concurrent rewrite between premise validation and
copy cannot slip uncertified instructions into the container; any mismatch fails the round closed.
(`auth.json` legitimately changes on refresh, so it is validated as a well-formed access-only token
rather than against a fixed hash.) That staging directory is the **only** user bind-mount, mounted
**read-only** at the container's `CODEX_HOME`, owned by the invoking host user with owner-only (0700)
permissions. Because Linux bind mounts **preserve numeric ownership**, the container is **run as that
same invoking host UID/GID against an arbitrary-UID-compatible image (corrects round-5 P2)**, so it
can read the staged files without any `chown` an unprivileged installer could not perform; on Docker
Desktop (macOS) the same UID/GID-as-invoker mapping is used, and the effective mapping is recorded in
the invocation profile and re-checked by inspection. **Under rootless Docker or a userns-remap daemon
the numeric mapping differs (corrects round-8 P2):** the container UID maps to a *subordinate* host
UID, so a 0700 dir owned by the invoking host UID is not readable as-is. The runner therefore
**inspects the daemon's effective user-namespace mapping** and uses a **mapping-aware mount** (an
idmapped mount or a `keep-id`-equivalent) so the staged files remain readable; where no such
mechanism is available it **rejects the configuration at installer preflight** with actionable
guidance rather than silently producing an unreadable mount. The effective mapping is part of the
security-policy validation and the live tests. The container performs no in-session refresh (the
mount is read-only). Before creating the container the broker requires the staged
token's **verified remaining lifetime to be at least the maximum round/watchdog deadline plus
container-startup and clock-skew margins (corrects round-3 P2)**; if it is below that threshold the
broker refreshes or re-mints host-side, and if the provider cannot supply a sufficiently long-lived
access-only token the round **fails closed before launch** rather than risking a mid-round expiry.
This simultaneously fixes round-2 P1 ("a dummy credential cannot
authenticate real model calls"): the staged token is a *real, working* access token, so the
force-enabled battery controls authenticate and fire — while the durable refresh token stays on the
host, resolving the refresh-rotation risk (round-1 P2).

**Lifecycle, concurrency & isolation of the staging directory (corrects round-5 P2).** Each staging
directory is correlated with its container by an **unguessable run id**, and the runner holds a
**per-run file lease from before the staging directory is created through final cleanup**. A reaper
may delete a stale directory only after it **acquires that lease non-blockingly *and* confirms no
matching live container exists** — "no live container references it" alone is insufficient, because
a directory legitimately exists in the window before its container is created. The broker itself
serializes all credential work — read → refresh → validate → persist — under an **OS-level
interprocess lock**, and persists any rotated durable credential with an **fsync-backed atomic
replacement guarded by a generation check**, so concurrent installers, rounds, or battery controls
cannot refresh with the same rotating token and clobber each other's newly issued host credential.
The staged access-only token is short-lived, so even a leaked staging dir ages out quickly.

## The Codex image

- Ship a `Dockerfile` (under `gauntlet-review/`) that installs a **pinned** Codex CLI version on a
  minimal Linux base as a non-root user. The install mechanism (pinned npm global or pinned release
  artifact) is a plan decision; the pin is the contract.
- **The pin is an architecture-qualified image identity that exists for both built and pulled
  images (corrects round-2 P2):** the **image config digest (image ID)** plus the **`os/arch`**.
  Because a multi-arch index selects a *different* per-architecture manifest and a config ID is a
  distinct identity again, `--platform` is mandated and the tuple is recorded explicitly. When the
  image is obtained by **pulling from a registry**, the immutable **platform child-manifest digest**
  is additionally recorded and is the preferred run reference; a **locally built** image (which has
  no registry manifest digest) is pinned by config digest + `os/arch` via a deterministic
  build/OCI-export that retains and verifies the config and platform. This tuple is
  **re-verified before every round**; live evidence is keyed to the *actually executed* platform
  image, so x86_64 evidence never authorizes an arm64 run or vice-versa. A mismatch (image rebuilt,
  re-pulled, or wrong arch) refuses the round — the analogue of exit `13` — until the caller re-pins
  with an explicit `--accept-new-image` acknowledgement that re-probes and re-enumerates features.
- The **default-deny feature enumeration** (`codex features list`) runs against the CLI *inside the
  pinned image*, so the `--disable` set is deterministic per image identity and pinned alongside it.

## Python module layout

Most of `lib.ps1` is OS-agnostic logic that ports directly; only the boundary is replaced.

| Module | Ported from | Notes |
|---|---|---|
| `verdict.py` | `Test-Verdict`, size bounds, severity invariant, `Get-RecommendationId` | Direct port; **identical id derivation** and normalization semantics (§ equivalence) |
| `usage.py` | `Get-RunUsage` acceptance-time usage gate | Direct port; same invariants (exactly one `turn.completed`, positive `input_tokens`, headroom gate) |
| `features.py` | default-deny `--disable` computation | Enumerates inside the image; pinned to the image identity |
| `sandbox.py` | `Invoke-CodexProcess` + harness (`New-HarnessDir`, `Assert-HarnessSafe`) | **New**: container create/start/copy-out/kill/cleanup, image-identity pin, credential staging, stdin streaming, JSONL capture. Replaces env-minimization + harness path arithmetic |
| `broker.py` | (new) | Host-side auth broker: refresh host-side, stage an access-only token, cleanup |
| `publish.py` | `publish-review.ps1` + `Publish-CodexReview` | Direct port; still shells to `gh`; provenance binding, idempotency (`--paginate --slurp`), drift, dismissal all preserved |
| `premises.py` | `Test-PremiseManifest`, calibration, live-evidence | Re-keyed to the container fingerprints (below) |
| `state.py` | `Get-StateDir`, carry-over ledger, create-only artifacts | Direct port; **identical path layout and logical schema** to the PS stack |
| `invoke_codex.py` | `invoke-codex.ps1` entry point | One review round: pin check → stage credential → run → usage gate → verdict validate |

## Premises / live-evidence, re-keyed

Same fail-closed structure as the Windows manifest, with container-appropriate fingerprint inputs:

```
{ image_config_digest, platform_manifest_digest?, os_arch, codex_version_in_image,
  schema_sha256, agents_md_sha256, host_impl_digest, python_runtime_fingerprint,
  container_invocation_profile_hash, live_evidence { schema_gate, security_battery } }
```

- `host_impl_digest` is the container-stack analogue of the Windows `wrapper_fingerprint`
  (`docs/design.md`): a digest over a **mechanically closed file set — enumerated by an explicit
  manifest, not "roughly the code" (corrects round-9 P1)** — covering **every immutable installed
  file** that enforces the boundary, shapes a verdict, or governs gating/activation/retries/
  publication: `sandbox.py`, `broker.py`, `premises.py`, `verdict.py`, `usage.py`, `features.py`,
  `publish.py`, `state.py`, `invoke_codex.py`, the battery, **both complete `SKILL.md` files** (not
  merely the dispatch lines), **`install.py`/`install.sh`** and their helpers, the
  `Dockerfile`/entrypoint wrapper, the verdict schema, and any policy/fixture data. **Generated
  manifest and evidence artifacts are explicitly *excluded* from this set** — otherwise the digest
  would be self-referential; their integrity is bound separately by the `live_evidence` fingerprints
  plus a release digest, and **both the closed set and that separate binding are verified before
  activation**. `host_impl_digest` is **verified unconditionally, every round (corrects round-4
  P1)**, because the semantic invocation-profile values can be unchanged while the code that applies
  them is edited. The offline suite, both live gates, and every review round run against the exact
  bytes this closed set covers.

- `python_runtime_fingerprint` binds the **host Python runtime that executes the enforcement code
  (corrects round-10 P1)**. `host_impl_digest` covers source files, but dispatch would otherwise
  resolve a mutable PATH `python3`, so a changed interpreter, standard library, or dependency could
  run *different* code for no-follow copying, credential handling, stream limiting, cleanup, hashing,
  and durability while evidence still read "current." The design pins the **resolved interpreter
  path** and fingerprints its **implementation/version/build plus all runtime dependencies**
  (preferably an immutable packaged runtime or versioned environment); the Unix dispatch invokes that
  pinned interpreter, not a bare `python3`; and any change to this execution substrate invalidates
  evidence and forces all gates to rerun.

- `container_invocation_profile_hash` is a **canonical *semantic* profile, not the literal run
  argv (corrects round-2 P1).** Per-run paths and identifiers (the staging directory source path,
  the cidfile, container ids) are replaced by **typed placeholders**; what is hashed is **every
  security-relevant effective setting (corrects round-3 P1)**, not an illustrative subset:
  - the **complete Codex argv template** with typed dynamic values — every hermetic flag
    (`--ignore-user-config`, `--ignore-rules`, `--ephemeral`, `-s read-only`,
    `-c web_search="disabled"`, `-c shell_environment_policy.inherit="none"`, the model pin) **and**
    the complete `--disable` set, not merely `--disable`;
  - each **mount's type, destination, and options** (credential bind, ro, at `$CODEX_HOME`; tmpfs
    working root);
  - the container security posture: **non-root UID/GID**, **`--read-only` rootfs**,
    **`--cap-drop ALL`**, **`--security-opt no-new-privileges`**, **`--pids-limit`** and memory/CPU
    **resource limits**, **published ports (none)**, the **environment allowlist**, the
    **`--log-driver=none`** logging driver, the **stream-attachment / wrapper protocol**, the
    network mode, the runtime/backend identity, the platform, and the image identity.
  The recorded profile is **derived from, and cross-checked against, runtime inspection** of an
  actual container, so drift between "what we intend to pass" and "what the runtime actually applied"
  is caught. Fresh but equivalent staging paths hash **equal**; **changing any single field
  invalidates evidence**, verified by a per-field test. `os_arch` is fingerprinted separately so
  evidence never crosses architectures.
- The two independently-fingerprinted `live_evidence` sub-records (`schema_gate`,
  `security_battery`) and the "recalibration drops evidence, forcing a live re-run" semantics are
  preserved unchanged.

**Freshness is not compliance — a non-self-calibrating policy validator (corrects round-7 P1).** The
profile hash proves the recorded evidence matches the configuration that ran; it does **not** prove
that configuration meets the required security posture — a *weakened* config (an installer run as
root yielding `--user 0:0`, or a missing `--cap-drop ALL`) would otherwise just fingerprint
differently and self-certify. A separate **versioned security-policy validator** therefore asserts
the *inspected* container matches every **mandatory** value — **UID/GID ≠ 0**, `--cap-drop ALL`,
`--security-opt no-new-privileges`, `--read-only` rootfs, `--log-driver=none`, the expected network
mode, the complete hermetic flag set, and the full default-deny `--disable` set — and **neither live
gate may record evidence, and no round may run, unless the validator passes**. Negative live tests
prove that removing or weakening any single mandatory control makes the gate/installer **fail**, not
merely produce a new hash.

## The security battery, re-conceived

The battery cannot be a 1:1 port because it verifies **container** properties. It asserts, each with
a positive control that proves the detector can see what it rules out:

1. **Tool denial holds inside the container** — the existing control-verified classes (shell, web,
   apps, MCP, plugins) are re-exercised *inside the pinned image*: each fires when isolated (one
   capability force-enabled), is absent under the real default-deny set, and does not collide with
   another class's signature. **Control reachability is a precondition:** because controls run with
   the broker's real access token, each positive control must be confirmed to actually reach the
   real API and fire *before* its absence under the hermetic policy is accepted as evidence — a
   control that silently failed to authenticate proves nothing.
2. **The mount/device/socket table matches a runtime-qualified allowlist (corrects round-2 P1 and
   the round-5 self-contradiction).** A real container legitimately has the overlay root, `proc`,
   `sys`, `cgroup`, `/dev`, `devpts`, shm, and the runtime's own generated binds `/etc/hosts`,
   `/etc/hostname`, `/etc/resolv.conf` — so the assertion is neither "only two mounts" nor "no bind
   has a host source" (those generated files *are* host-backed binds). The check therefore
   **separates user-requested binds from runtime-generated binds**: from the runtime configuration
   (`docker inspect` Mounts / `HostConfig.Binds`) the **sole user-requested bind must be the
   credential staging dir**; the generated `/etc/*` trio is allowed **only at those enumerated
   destinations with runtime-qualified source classes and options**; the expected
   pseudo-filesystems, devices, and the tmpfs working root are allowed; and **any other host bind,
   any container-runtime socket** (`docker.sock`/`podman.sock`)**, and any unexpected device are
   rejected**. A control that deliberately adds a user bind must surface it.
3. **Egress posture is exactly what is claimed** (§ Network egress).
4. **A synthetic secret never appears in ANY captured output channel** — a canary must not appear in
   the verdict, the JSONL stream, stderr, **or any daemon-side container log** (closed by
   `--log-driver=none`, which the battery verifies is in effect). The ported injection battery's
   three hard requirements are preserved: non-compliance (never coerced into approving),
   identification of an independent planted defect, and no environment/credential disclosure.
5. **Image-pin mismatch refuses** — a round run against an image whose config digest / platform /
   `os_arch` does not match the pin is rejected.

The narrowed-class treatment from the Windows battery (computer-use, skills, subagents configured
off but not independently control-provable on the current CLI) carries over as the same documented,
deliberately narrower claim.

**Scope of the guarantee.** As with the Windows stack, the confidentiality claim is scoped to a
**trusted, pinned** Codex CLI and container runtime: the battery proves the boundary holds for the
pinned image and runtime it verified, not for an arbitrary substituted binary or a runtime with a
mediating socket. Without egress mediation (§ Network egress) the guarantee is filesystem/process
isolation plus tool denial, **not** network isolation.

## Network egress

Default: **open egress + tool-denial.** The confidentiality basis is identical to the Windows
stack — `web_search` disabled, no shell, nothing host-side to exfiltrate — and precisely
allowlisting the model endpoints is fragile (rotating IPs/CDN). This is documented honestly: the
container adds filesystem/process isolation, **not** network isolation. An egress-allowlist proxy
sidecar is an optional future hardening tier, explicitly out of scope for v1.

## Installer & skill dispatch

- **`install.sh`** (thin bootstrap) → **`install.py`** — fail-closed. It **generates** evidence
  before it **verifies** it, so a fresh machine is never refused for lacking evidence it has had no
  chance to produce. Ordered:
  1. verify a supported container runtime is present and usable (**Docker primary; Podman used if
     it is a drop-in** for the run/inspect surface the stack needs), and verify the host
     architecture is supported;
  2. **stage an immutable installation artifact** — a copy of exactly the `gauntlet-review` and
     `gauntlet-dev` trees that will be installed — and compute its **`host_impl_digest`**. Every
     subsequent check runs against *this* artifact, so what is tested and gated is byte-for-byte what
     gets installed (corrects round-4 P1);
  3. obtain the image and **pin** it to a resolvable per-arch identity — **pull by immutable
     platform child digest** (preferred), or a deterministic local build/OCI-export that retains and
     verifies the config digest + `os/arch` — recording `image_config_digest`, any
     `platform_manifest_digest`, and `os_arch`; then run the **offline pytest suite** from the staged
     artifact (a failure stops before any live call);
  4. **invalidate** any prior live-evidence, then run **both** live gates — the schema gate and the
     container security battery — from the staged artifact on the host's own architecture, atomically
     **recording** each gate's fingerprinted evidence (bound to `host_impl_digest`) on success;
  5. **revalidate** the now-complete manifest (the same check a review round enforces) and refuse if
     anything is stale or mismatched;
  6. **install as a versioned sibling + atomic symlink flip, made durable (corrects round-5 P1,
     round-6 P1, round-7 P2)** — POSIX `rename` cannot replace a non-empty directory, so instead
     populate a **new immutable, versioned sibling directory** holding **both** skill trees, and
     **re-hash the closed `host_impl_digest` file set there — generated evidence excluded and
     verified via its own release binding — and confirm it matches, before exposure**. Make it durable
     **before** exposure with a **platform-specific durability protocol (corrects round-8 P2)**:
     flush every installed regular file and evidence artifact to the storage device — `fsync` on
     Linux, **`fcntl(F_FULLFSYNC)` on macOS** (ordinary `fsync` does not flush the drive cache
     there) — then flush directories bottom-up including the version-directory's parent. Where a
     filesystem/backend cannot provide the required directory-/rename-persistence primitives, the
     installer **fails closed or narrows the durability guarantee** rather than assuming it
     (re-hashing verifies page-cache contents, not on-disk durability — after a power loss `current`
     must never survive pointing at truncated or missing files). Then repoint the `current` symlink by **creating a uniquely-named
     temporary symlink in the same directory and replacing `current` with a single atomic
     `rename`/`os.replace`** (same-filesystem-validated, `lstat`-checked) — *not* `ln -sfn`, which
     unlinks-then-symlinks and can leave `current` missing — and `fsync` the parent of `current`.
     Startup validation refuses or rolls back a `current` whose complete digest no longer matches;
  7. add the activation pointer to `~/.claude/CLAUDE.md` if absent, **crash-/concurrency-/symlink-
     safely (corrects round-10 P2)**: validate the destination with no-follow semantics, serialize
     updates and detect concurrent generations, write a complete sibling file preserving the intended
     metadata, durably flush it, and atomically replace the destination — with failure ordering such
     that an unsuccessful activation update leaves the prior configuration intact.
  Because step 3 runs the battery inside the pinned image on the host arch, installing on an
  Apple-Silicon Mac verifies the arm64 boundary on arm64 before anything is installed.
- **`SKILL.md` platform branch.** The loop protocol is shared prose; the invocation lines branch by
  OS: Windows → `pwsh -File …/invoke-codex.ps1 …`; Linux/macOS → `python3 …/invoke_codex.py …`.
  **The Unix dispatch resolves `current` to its concrete versioned directory exactly once at the
  start of an operation (`realpath`) and threads that immutable path through every skill-dispatch and
  script invocation for the whole operation (corrects round-7 P1)** — a single atomic symlink flip
  makes each lookup individually valid but does not, on its own, make two separate lookups
  (`current/gauntlet-review/…` then `current/gauntlet-dev/…`) a consistent bundle snapshot; resolving
  once and pinning the result is what delivers the "switch as one bundle" guarantee. Both entry
  points accept the same arguments and honor the **same exit-code contract** (0/10/11/12/13/14/16 for
  rounds; 2–6 for publication), so the SKILL.md protocol, human-flag rules, and retry semantics are
  identical across stacks. Container-runtime-absent maps to the existing exit `12` (environment
  invalid); image-pin mismatch maps to exit `13` (pinned stack changed).

## Behavioral equivalence requirements

The achievable, precisely-scoped contract (not cross-stack byte-identity, which would require
changing the untouched Windows writers — round-2 P2):

- **Identical recommendation-id derivation.** `Get-RecommendationId` (hash of round, index,
  severity, location, issue, suggestion) is reproduced exactly in `verdict.py`, verified against a
  corpus of **authoritative id vectors** (not against the other implementation). This is the
  property that actually matters: it makes carry-over ledgers and recommendation identity stable
  across stacks.
- **Identical normalization semantics** — the severity invariant (approve-with-non-nit → downgrade),
  the size bounds, and rendered-body bounds behave identically, verified against authoritative
  input→output vectors.
- **Identical state schema and path layout** — `round-N-verdict.json`, per-attempt records,
  carry-over ledger `.json`/`.txt`, `state.json`, `publication.json`: identical paths and identical
  *logical* JSON shape (keys, types, structure). Each stack serializes internally consistently; the
  bytes need not match the PowerShell stack's.
- **The Python stack's own output uses a named canonical JSON form — RFC 8785 (JCS)** — so its
  serialization is fully specified (key ordering by UTF-16 code units, UTF-8 output, defined string
  escaping) rather than "sorted keys, roughly." Value domains here are constrained to strings and
  small non-negative integers (no floats), so JCS's number-formatting edge cases do not arise. The
  trailing-newline policy is stated explicitly (files end without a trailing newline) and tested.
- **Identical exit-code contract** and identical PR-mode provenance fields (`base_oid`,
  `base_ref_name`, `base_tip_oid`, `head_sha`), marker format, idempotency, drift, and dismissal
  behavior (a direct port of `publish.py`).

## Testing strategy

1. **Offline pytest suite** — ports the coverage of the 602-test PowerShell suite: verdict
   normalization and severity downgrade, id derivation against authoritative vectors, the usage gate
   (malformed/duplicated/over-limit streams), default-deny feature computation, the **canonical
   semantic invocation-profile hash** (fresh equivalent staging paths hash equal; changing any
   single security-relevant field invalidates evidence — a per-field test), **bounded stream
   capture** (per-channel and aggregate over-limit behavior terminates the run),
   premises/live-evidence gating, state paths and the carry-over ledger, and
   publication hardening (JSON-safe bodies, `--paginate --slurp` pagination, provenance binding,
   drift, dismissal). No container, no network, no model calls.
2. **Container live battery** — the re-conceived security battery above, run inside the pinned
   image, including **control-reachability preconditions**, the **runtime-qualified mount
   allowlist**, and the **security-policy validator's negative tests** (weakening any single
   mandatory control — `--user 0:0`, dropped `--cap-drop ALL`, `no-new-privileges` off, a writable
   rootfs, etc. — makes the gate **fail**, never merely re-fingerprint), and **validation of the
   effective user-namespace mapping** (rootless / userns-remap must yield a readable credential mount
   or be rejected at preflight). Real model calls; consumes usage; deliberately invoked.
3. **Live schema gate** — the shipped schema is accepted by the real API through the container, with
   exactly one terminal `turn.completed` and the usage gate satisfied.
4. **Serialization + id golden corpus** — a corpus carrying **authoritative expected bytes** for the
   JCS serializer and **authoritative id vectors**, exercising multi-byte/escape-requiring Unicode,
   key ordering, size-bound and numeric boundaries, malformed/normalized values, the
   severity-downgrade path, and carry-over-ledger transitions. The Python stack is checked against
   the authoritative expectations (not merely against PowerShell).
5. **Credential/refresh test** — two sequential rounds via the broker assert host auth still works
   afterward (the durable refresh token was never exposed or invalidated); a token whose remaining
   lifetime is below the deadline-plus-margin threshold is refreshed/re-minted or fails closed before
   launch; and a **concurrent-refresh test** — including a provider response that **rotates the
   refresh token** — asserts the interprocess lock plus fsync-atomic, generation-checked persistence
   never lets two brokers clobber each other's credential. A **concurrent-rewrite test** replaces
   `AGENTS.md` between premise validation and staging and asserts the staged-byte hash check against
   `agents_md_sha256` fails the round closed. A **concurrent-host-CLI test** and a
   **crash-injection test** around the refresh/persistence boundary assert that the non-rotating
   exchange keeps host auth intact, or — under a rotating provider — the run fails closed or warns
   rather than silently invalidating host auth.
6. **Crash-safety & concurrency test** — with the host runner killed mid-round, the in-container
   watchdog still terminates the run by its absolute deadline; a subsequent reaper reclaims a stale
   run's **container and** staging directory only after acquiring that run's per-run lease
   non-blockingly and re-inspecting the exact run id; and a **concurrent-run test** asserts an active
   run's container (and its pre-container staging directory) is never reaped or deleted by a
   concurrent reaper.
7. **Install-atomicity & durability test** — an activation interrupted between staging and the
   `current` flip, and a **reader paused after its first lookup while the flip occurs**, both observe
   a **single consistent bundle** (only the old or only the new; never missing, mixed across skill
   trees, or unverified); and a **power-loss/recovery test** asserts a surviving `current` never
   points at truncated or missing files — using `F_FULLFSYNC` on macOS and failing closed on backends
   lacking the required primitives — and startup validation refuses or rolls back a `current` whose
   complete digest no longer matches.

## Risks and mitigations

- **Container runtime dependency.** Heavier prerequisite than Python alone; the installer verifies
  it up front and fails closed with guidance.
- **Access-token lifetime vs round length.** The broker requires the staged token's remaining
  lifetime to exceed the maximum round/watchdog deadline plus startup and clock-skew margins before
  launch — refreshing or re-minting otherwise, and failing closed before launch if it cannot — so a
  bounded round fits inside the token's validity by construction. The durable refresh token is
  handled host-side and never enters the container.
- **Refresh-token rotation is not transactional with the provider (corrects round-9 P2).** Local
  locking and fsync-atomic persistence cannot make a *provider-side* rotation atomic: if the
  provider invalidates `R0` and issues `R1`, a crash before `R1` is durably stored leaves only the
  invalid `R0`; and a normal host `codex` process does not honor the broker's private lock and can
  race the refresh. The design therefore **prefers a token exchange that mints a short-lived access
  token WITHOUT rotating the durable refresh credential**, which removes the race entirely. Only if
  the pinned provider offers no non-rotating exchange does the broker fall back to rotation — and
  there the host-auth-preservation guarantee is **explicitly narrowed**: the broker coordinates the
  writers it can, adds concurrent-host-CLI and crash-injection tests around the refresh/persistence
  boundary, and **fails closed or warns** when recoverability cannot be guaranteed rather than
  claiming rotation is always safe. The provider's real rotation/grace-period/recovery semantics are
  established empirically before v1.
- **Podman divergence.** Only drop-in compatibility is promised; the semantic invocation-profile
  hash pins the exact runtime identity so a substitution is never silent.
- **Image / architecture drift.** The architecture-qualified image identity is the pin, re-verified
  every round, with an explicit re-pin acknowledgement path; `os_arch` is fingerprinted so evidence
  never crosses architectures.
- **macOS integration (Docker Desktop mounts/networking).** The security *boundary* is verified by
  the container battery **on the host's own architecture**; the macOS-specific surface (mount +
  network plumbing) is exercised by the self-verifying install running the battery on the Mac.

## References

- [`docs/design.md`](../../design.md) — the controlling Windows security and workflow design.
- [`docs/implementation-plan.md`](../../implementation-plan.md) — the Windows implementation plan and contracts.
- `gauntlet-review/scripts/lib.ps1` — the source of the logic being ported.
- `gauntlet-review/scripts/invoke-codex.ps1`, `publish-review.ps1`, `calibrate-premises.ps1`.
- RFC 8785 — JSON Canonicalization Scheme (JCS), the named canonical serialization for the Python stack.
