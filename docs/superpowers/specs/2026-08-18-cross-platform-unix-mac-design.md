# Cross-Platform (Unix/macOS) Gauntlet — Container-Sandbox Port Design

**Date:** 2026-08-18
**Status:** Draft for review
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
2. **Uniform.** The sandbox is the *same Linux container* on Linux and on macOS (Docker Desktop),
   so the security boundary is verified **once**, not re-derived per OS. The Windows-specific
   `SystemRoot`-for-DNS problem and its per-OS equivalents disappear.
3. **Self-verifying install.** Because the live battery runs *inside the pinned image*, the
   fail-closed installer re-runs that exact battery on whatever machine installs it — so a macOS
   install re-verifies the same container that was verified on Linux.

## Goals

- A Python 3 implementation of `gauntlet-review` that runs on Linux and macOS.
- Codex executed inside a locked-down, pinned container that is the hermetic boundary.
- **Behavioral equivalence** with the Windows stack: same verdict contract, same normalization,
  same state-file layout, same exit-code contract, same SKILL.md protocol.
- A fail-closed installer and a re-conceived live security battery that verify the container
  boundary before anything is installed or any review is published.

## Non-goals / out of scope

- **Any change to the Windows PowerShell stack.** It remains the Windows path, untouched.
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
| Linux | Python 3 | Codex in a pinned, locked-down container | New |
| macOS | Python 3 | Codex in the **same** Linux container via Docker Desktop | New — same image ⇒ same boundary |

## Architecture: the container as the boundary

Each review round is one `docker run` (or `podman run`) of a pinned image. **All existing flag
discipline still runs inside the container** — nothing about the Codex invocation is relaxed;
the container is added *around* it:

- `--ignore-user-config`, `--ignore-rules`, `--ephemeral`, `-s read-only`,
  `-c web_search="disabled"`, `-c shell_environment_policy.inherit="none"`, the model pin
  (`-m gpt-5.6-sol -c model_reasoning_effort="xhigh"`), and the **complete default-deny
  `--disable` set** are all passed exactly as the Windows stack passes them.
- Prompt delivered over **redirected UTF-8 stdin** (`codex exec … -`); review material never
  enters argv and never appears in any log.
- `--output-schema` + `-o <verdict-file>` + `--json` exactly as today.

Container run configuration (the new boundary):

- `--rm`; no published ports; a non-root user; `--read-only` root filesystem;
  `--cap-drop ALL`; `--security-opt no-new-privileges`; `--pids-limit`; memory and CPU limits;
  a bounded run timeout (the container analogue of `Invoke-BoundedProcess`).
- **No host bind-mounts except the credential** (below). The reviewed repository, the user's home
  directory, and every host path are absent from the container.
- **Working root = an empty in-container tmpfs.** This *is* the harness. The Windows
  "harness must be outside every repo and verified empty" invariants collapse to "a fresh tmpfs is
  unconditionally empty and contains no host path," which is stronger and needs no path arithmetic.
- **Minimal container environment.** `CODEX_HOME` points at the in-container credential dir; no
  host environment is inherited. The `SystemRoot`-for-DNS dependency is gone — DNS is the
  container's own Linux resolver reading `/etc/resolv.conf`.

**Confidentiality argument (stated precisely).** The reviewer has no shell and no file-read tool
(default-deny), so it cannot read the one secret present in the container (`auth.json`), and there
are no host files to reach regardless of any Codex flag. Even under open egress there is therefore
nothing host-side to exfiltrate. The container contributes filesystem and process isolation; the
flag discipline contributes tool denial; together they are two independent boundaries.

## The credential (auth + AGENTS.md)

The Windows stack uses the real `~/.codex` as `CODEX_HOME` (read-write), so `auth.json` and
`~/.codex/AGENTS.md` resolve and token refresh persists. In the container the requirement is:

1. `auth.json` and `AGENTS.md` are available in the container's `CODEX_HOME` so auth and the
   trusted account-level `AGENTS.md` resolve exactly as they do today (`config.toml` remains
   ignored via `--ignore-user-config`).
2. **The host credential is never mutated by the sandbox.**
3. **In-session token refresh does not hard-fail a round.**

Recommended mechanism (plan finalizes the exact form): mount the host `~/.codex` **read-only** at a
staging path, and at container start copy `auth.json` + `AGENTS.md` into an **ephemeral writable
`CODEX_HOME` on tmpfs**. Refreshes then happen in-session and are discarded when the container
exits — the host credential stays immutable, and an expired access token can still be refreshed
from the (present) refresh token. Only these two files are exposed; the rest of `~/.codex` is not
mounted. If auth cannot resolve or refresh, the round **fails closed** with guidance to
re-authenticate on the host.

## The Codex image

- Ship a `Dockerfile` (under `gauntlet-review/`) that installs a **pinned** Codex CLI version on a
  minimal Linux base as a non-root user. The install mechanism (pinned npm global or pinned release
  artifact) is a plan decision; the pin is the contract.
- **The image digest is the binary pin** — stronger than today's exe SHA-256, because it pins the
  whole Codex stack (binary + interpreter + libraries). It is recorded at calibration and
  **re-verified before every round**. A mismatch (image rebuilt or re-pulled) refuses the round —
  the container analogue of exit `13` — until the caller re-pins with an explicit
  `--accept-new-image` acknowledgement that re-probes and re-enumerates features.
- The **default-deny feature enumeration** (`codex features list`) runs against the CLI *inside the
  pinned image*, so the `--disable` set is deterministic per image digest and pinned alongside it.

## Python module layout

Most of `lib.ps1` is OS-agnostic logic that ports directly; only the boundary is replaced.

| Module | Ported from | Notes |
|---|---|---|
| `verdict.py` | `Test-Verdict`, size bounds, severity invariant | Direct port; identical normalization |
| `usage.py` | `Get-RunUsage` acceptance-time usage gate | Direct port; same invariants (exactly one `turn.completed`, positive `input_tokens`, headroom gate) |
| `features.py` | default-deny `--disable` computation | Enumerates inside the image; pinned to image digest |
| `sandbox.py` | `Invoke-CodexProcess` + harness (`New-HarnessDir`, `Assert-HarnessSafe`) | **New**: builds the `run` argv, manages the image-digest pin, streams stdin, captures JSONL. Replaces env-minimization + harness path arithmetic (tmpfs replaces it) |
| `publish.py` | `publish-review.ps1` + `Publish-CodexReview` | Direct port; still shells to `gh`; provenance binding, idempotency (`--paginate --slurp`), drift, dismissal all preserved |
| `premises.py` | `Test-PremiseManifest`, calibration, live-evidence | Re-keyed to the container fingerprints (below) |
| `state.py` | `Get-StateDir`, carry-over ledger, create-only artifacts | Direct port; **identical on-disk layout** to the PS stack |
| `invoke_codex.py` | `invoke-codex.ps1` entry point | One review round: pin check → run → usage gate → verdict validate |

## Premises / live-evidence, re-keyed

Same fail-closed structure as the Windows manifest, with container-appropriate fingerprint inputs:

```
{ image_digest, codex_version_in_image, schema_sha256, agents_md_sha256,
  container_invocation_profile_hash, live_evidence { schema_gate, security_battery } }
```

- `container_invocation_profile_hash` covers the container runtime identity **and the full `run`
  argv** (image-by-digest, mounts, caps, network mode, and the composed codex args), so a changed
  runtime or run configuration hashes differently and is rejected — the analogue of the Windows
  invocation-profile hash.
- The two independently-fingerprinted `live_evidence` sub-records (`schema_gate`,
  `security_battery`) and the "recalibration drops evidence, forcing a live re-run" semantics are
  preserved unchanged.

## The security battery, re-conceived

The battery cannot be a 1:1 port because it verifies **container** properties, not **environment**
properties. It asserts, each with a positive control that proves the detector can see what it
rules out:

1. **Tool denial holds inside the container** — the existing control-verified classes (shell, web,
   apps, MCP, plugins) are re-exercised *inside the pinned image*: each fires when isolated (one
   capability force-enabled), is absent under the real default-deny set, and does not collide with
   another class's signature.
2. **No host path is reachable** — a canary file planted on the host is invisible to the reviewer;
   a control run *with* a bind-mount of that path *does* surface it (proving the detector works).
3. **Egress posture is exactly what is claimed** (§ Network egress).
4. **The mounted `auth.json` never appears in any verdict** — the ported injection battery, whose
   three hard requirements are preserved: non-compliance (never coerced into approving),
   identification of an independent planted defect, and no environment/credential disclosure.
5. **Image-digest pin mismatch refuses** — a round run against a non-pinned image is rejected.

The narrowed-class treatment from the Windows battery (computer-use, skills, subagents configured
off but not independently control-provable on the current CLI) carries over as the same documented,
deliberately narrower claim.

## Network egress

Default: **open egress + tool-denial.** The confidentiality basis is identical to the Windows
stack — `web_search` disabled, no shell, nothing host-side to exfiltrate — and precisely
allowlisting the model endpoints is fragile (rotating IPs/CDN). This is documented honestly: the
container adds filesystem/process isolation, **not** network isolation. An egress-allowlist proxy
sidecar is an optional future hardening tier, explicitly out of scope for v1.

## Installer & skill dispatch

- **`install.sh`** (thin bootstrap) → **`install.py`** — fail-closed, mirroring `install.ps1`:
  1. verify a supported container runtime is present and usable (**Docker primary; Podman used if
     it is a drop-in** for the run/inspect surface the stack needs);
  2. build or pull and **pin** the image (record its digest);
  3. refuse unless the manifest and both live-evidence records are current;
  4. run the offline pytest suite and the container security battery;
  5. copy `gauntlet-review` and `gauntlet-dev` to `~/.claude/skills/`;
  6. append the activation pointer to `~/.claude/CLAUDE.md` if absent.
  Because step 4 runs inside the pinned image, installing on macOS re-verifies the same container.
- **`SKILL.md` platform branch.** The loop protocol is shared prose; the invocation lines branch by
  OS: Windows → `pwsh -File …/invoke-codex.ps1 …`; Linux/macOS → `python3 …/invoke_codex.py …`.
  Both accept the same arguments and honor the **same exit-code contract** (0/10/11/12/13/14/16 for
  rounds; 2–6 for publication), so the SKILL.md protocol, human-flag rules, and retry semantics are
  identical across stacks. Container-runtime-absent maps to the existing exit `12` (environment
  invalid); image-digest mismatch maps to exit `13` (pinned stack changed).

## Behavioral equivalence requirements

These are hard requirements, because doc-mode review state is committed beside project docs and
must be identical regardless of which stack produced it:

- The verdict JSON, normalization, severity invariant, and size bounds are byte-for-byte equivalent
  to the Windows stack for the same reviewer output.
- The state-file layout (`round-N-verdict.json`, per-attempt records, carry-over ledger `.json` and
  `.txt`, `state.json`, `publication.json`) is identical in path and content shape.
- The exit-code contract is identical.
- The PR-mode provenance fields (`base_oid`, `base_ref_name`, `base_tip_oid`, `head_sha`), the
  marker format, idempotency, drift, and dismissal behavior are identical (a direct port of
  `publish.py`).

## Testing strategy

1. **Offline pytest suite** — ports the coverage of the 602-test PowerShell suite: verdict
   normalization and severity downgrade, the usage gate (malformed/duplicated/over-limit streams),
   default-deny feature computation, `run`-argv composition and the invocation-profile hash,
   premises/live-evidence gating, state paths and the carry-over ledger, and publication hardening
   (JSON-safe bodies, `--paginate --slurp` pagination, provenance binding, drift, dismissal). No
   container, no network, no model calls.
2. **Container live battery** — the re-conceived security battery above, run inside the pinned
   image. Real model calls; consumes usage; deliberately invoked, not part of the offline suite.
3. **Live schema gate** — the shipped schema is accepted by the real API through the container, with
   exactly one terminal `turn.completed` and the usage gate satisfied.
4. **Equivalence spot-check** — a fixture reviewer output produces identical normalized verdict and
   state files under both stacks.

## Risks and mitigations

- **Container runtime dependency.** Heavier prerequisite than Python alone; the installer verifies
  it up front and fails closed with guidance.
- **Auth/token refresh in an ephemeral `CODEX_HOME`.** Mitigated by the copy-in mechanism; a
  refresh that cannot complete fails the round closed rather than silently degrading.
- **Podman divergence.** Only drop-in compatibility is promised; the invocation-profile hash pins
  the exact runtime so a substitution is never silent.
- **Image drift.** The image digest is the pin, re-verified every round, with an explicit
  re-pin acknowledgement path.
- **macOS integration (Docker Desktop mounts/networking).** The security *boundary* is verified by
  the Linux container; the macOS-specific surface (mount + network plumbing) is exercised by the
  self-verifying install running the battery on the Mac.

## References

- [`docs/design.md`](../../design.md) — the controlling Windows security and workflow design.
- [`docs/implementation-plan.md`](../../implementation-plan.md) — the Windows implementation plan and contracts.
- `gauntlet-review/scripts/lib.ps1` — the source of the logic being ported.
- `gauntlet-review/scripts/invoke-codex.ps1`, `publish-review.ps1`, `calibrate-premises.ps1`.
