# Cross-Platform (Unix/macOS) Gauntlet — Container-Sandbox Port Design

**Date:** 2026-08-18
**Status:** Draft for review (Codex rounds 1–2: `request_changes` addressed)
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

- `--ignore-user-config`, `--ignore-rules`, `--ephemeral`, `-s read-only`,
  `-c web_search="disabled"`, `-c shell_environment_policy.inherit="none"`, the model pin
  (`-m gpt-5.6-sol -c model_reasoning_effort="xhigh"`), and the **complete default-deny
  `--disable` set** are all passed exactly as the Windows stack passes them.
- Prompt delivered over **redirected UTF-8 stdin** (`codex exec … -`); review material never
  enters argv and never appears in any log.
- `--output-schema` + `-o <verdict-file>` (written to the working tmpfs, copied out **while the
  container is still running** — see lifecycle below) + `--json` exactly as today.

Container run configuration (the new boundary):

- No published ports; a non-root user; `--read-only` root filesystem; `--cap-drop ALL`;
  `--security-opt no-new-privileges`; `--pids-limit`; memory and CPU limits; a bounded run timeout
  (the container analogue of `Invoke-BoundedProcess`).
- **`--log-driver=none`** so the daemon does not persist stdout/stderr to host-side container logs
  (an otherwise-un-audited disclosure channel — round-2 P2). The runner captures the attached
  streams directly instead. The effective logging configuration is part of the invocation profile
  (§ Premises) and is asserted by the battery.
- **No host bind-mounts except the credential staging mount** (below). The reviewed repository, the
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
3. the runner streams the prompt to the wrapper's stdin and captures `stdout`/`stderr` directly,
   feeding the `--json` JSONL to the usage gate;
4. once Codex has exited (observed via the marker/exit-status), the runner **`docker cp`s the
   verdict file and exit-status out while the container is still running** (tmpfs live), so the
   verdict source is the `-o` file exactly as on Windows;
5. the runner then releases the wrapper and issues an explicit `kill` against the retained id — the
   round timeout is likewise enforced by an explicit `kill`, because killing the client process
   alone does **not** stop a daemon-managed container — and a guaranteed cleanup removes the
   container on success, failure, and timeout alike.

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
control) it ensures a valid access token — refreshing host-side using the durable refresh token if
needed — and writes an **access-token-only** `auth.json` (no refresh token) plus a copy of
`AGENTS.md` into a fresh, host-created **staging directory**, after validating each source is a
**regular file** (not a symlink/socket/device) and copying with no-follow semantics. That staging
directory is the **only** host bind-mount, mounted **read-only** at the container's `CODEX_HOME`
with a defined UID/GID so the image's non-root user can read it. The container performs no in-session
refresh (the mount is read-only); the broker's launch-time freshness covers a bounded round, and an
expiry mid-round **fails closed**. This simultaneously fixes round-2 P1 ("a dummy credential cannot
authenticate real model calls"): the staged token is a *real, working* access token, so the
force-enabled battery controls authenticate and fire — while the durable refresh token stays on the
host, resolving the refresh-rotation risk (round-1 P2).

**Lifecycle & isolation of the staging directory:** created per round with owner-only permissions;
removed in a guaranteed cleanup on every outcome (success, failure, timeout, crash-recovery of
stale directories on next run); its access-only token is short-lived so even a leaked staging dir
ages out quickly.

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
  schema_sha256, agents_md_sha256, container_invocation_profile_hash,
  live_evidence { schema_gate, security_battery } }
```

- `container_invocation_profile_hash` is a **canonical *semantic* profile, not the literal run
  argv (corrects round-2 P1).** Per-run paths and identifiers (the staging directory source path,
  the cidfile, container ids) are replaced by **typed placeholders**; what is hashed is the
  security-relevant shape: each mount's **type, destination, and options** (e.g. "credential mount:
  type=bind, dest=`$CODEX_HOME`, ro; working root: type=tmpfs"), the capability drops, network mode,
  **logging driver**, the runtime identity, the platform, the image identity, and the complete
  `--disable` set. Fresh but equivalent staging paths therefore hash **equal**, while any
  security-relevant change hashes **different** — verified by an explicit test. `os_arch` is
  fingerprinted separately so evidence never crosses architectures.
- The two independently-fingerprinted `live_evidence` sub-records (`schema_gate`,
  `security_battery`) and the "recalibration drops evidence, forcing a live re-run" semantics are
  preserved unchanged.

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
2. **The mount/device/socket table matches a runtime-qualified allowlist (corrects round-2 P1).**
   A real container legitimately has the overlay root, `proc`, `sys`, `cgroup`, `/dev`, `devpts`,
   shm, and runtime-generated files (`/etc/hosts`, `/etc/hostname`, `/etc/resolv.conf`) — so the
   assertion is **not** "only two mounts." The runner inspects the container's runtime config *and*
   in-container `mountinfo` and asserts: the set matches a **runtime-qualified allowlist** of those
   expected pseudo-filesystems/devices/generated files **plus** the single credential staging bind
   and the tmpfs working root; **no bind-mount has a host source other than the credential staging
   dir**; and **no container-runtime socket** (`docker.sock`/`podman.sock`), unexpected device, or
   other host path is present. A control that deliberately adds a host bind must surface it.
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
  2. obtain the image and **pin** it to a resolvable per-arch identity — **pull by immutable
     platform child digest** (preferred), or a deterministic local build/OCI-export that retains and
     verifies the config digest + `os/arch` — recording `image_config_digest`, any
     `platform_manifest_digest`, and `os_arch`; then run the **offline pytest suite** (a failure
     stops before any live call);
  3. **invalidate** any prior live-evidence, then run **both** live gates — the schema gate and the
     container security battery — on the host's own architecture, atomically **recording** each
     gate's fingerprinted evidence on success;
  4. **revalidate** the now-complete manifest (the same check a review round enforces) and refuse if
     anything is stale or mismatched;
  5. only then copy `gauntlet-review` and `gauntlet-dev` to `~/.claude/skills/`;
  6. append the activation pointer to `~/.claude/CLAUDE.md` if absent.
  Because step 3 runs the battery inside the pinned image on the host arch, installing on an
  Apple-Silicon Mac verifies the arm64 boundary on arm64 before anything is installed.
- **`SKILL.md` platform branch.** The loop protocol is shared prose; the invocation lines branch by
  OS: Windows → `pwsh -File …/invoke-codex.ps1 …`; Linux/macOS → `python3 …/invoke_codex.py …`.
  Both accept the same arguments and honor the **same exit-code contract** (0/10/11/12/13/14/16 for
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
   semantic invocation-profile hash** (fresh equivalent staging paths hash equal; security-relevant
   changes do not), premises/live-evidence gating, state paths and the carry-over ledger, and
   publication hardening (JSON-safe bodies, `--paginate --slurp` pagination, provenance binding,
   drift, dismissal). No container, no network, no model calls.
2. **Container live battery** — the re-conceived security battery above, run inside the pinned
   image, including **control-reachability preconditions** and the **runtime-qualified mount
   allowlist**. Real model calls; consumes usage; deliberately invoked.
3. **Live schema gate** — the shipped schema is accepted by the real API through the container, with
   exactly one terminal `turn.completed` and the usage gate satisfied.
4. **Serialization + id golden corpus** — a corpus carrying **authoritative expected bytes** for the
   JCS serializer and **authoritative id vectors**, exercising multi-byte/escape-requiring Unicode,
   key ordering, size-bound and numeric boundaries, malformed/normalized values, the
   severity-downgrade path, and carry-over-ledger transitions. The Python stack is checked against
   the authoritative expectations (not merely against PowerShell).
5. **Credential/refresh test** — two sequential rounds via the broker assert host auth still works
   afterward (the durable refresh token was never exposed or invalidated).

## Risks and mitigations

- **Container runtime dependency.** Heavier prerequisite than Python alone; the installer verifies
  it up front and fails closed with guidance.
- **Access-token lifetime vs round length.** The broker guarantees freshness at launch; a bounded
  round fits inside an access token's validity, and expiry mid-round fails closed. The durable
  refresh token is refreshed host-side and never enters the container, so refresh-token rotation
  cannot invalidate the host credential.
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
