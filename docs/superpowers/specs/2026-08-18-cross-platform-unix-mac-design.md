# Cross-Platform (Unix/macOS) Gauntlet — Container-Sandbox Port Design

**Date:** 2026-08-18
**Status:** Draft for review (Codex round 1: `request_changes` addressed)
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
- `--output-schema` + `-o <verdict-file>` (written to the tmpfs, copied out before removal — see
  lifecycle below) + `--json` exactly as today.

Container run configuration (the new boundary):

- No published ports; a non-root user; `--read-only` root filesystem; `--cap-drop ALL`;
  `--security-opt no-new-privileges`; `--pids-limit`; memory and CPU limits; a bounded run timeout
  (the container analogue of `Invoke-BoundedProcess`).
- **No host bind-mounts except the credential staging dir** (below). The reviewed repository, the
  user's home directory, and every host path are absent from the container.
- **Working root = an empty in-container tmpfs.** This *is* the harness. The Windows
  "harness must be outside every repo and verified empty" invariants collapse to "a fresh tmpfs is
  unconditionally empty and contains no host path," which is stronger and needs no path arithmetic.
- **Minimal container environment.** `CODEX_HOME` points at the in-container credential dir; no
  host environment is inherited. The `SystemRoot`-for-DNS dependency is gone — DNS is the
  container's own Linux resolver reading `/etc/resolv.conf`.

**Container lifecycle and verdict retrieval (explicit; addresses round-1 P1).** A review round does
**not** use fire-and-forget `docker run --rm`. The runner:

1. **creates** the container with a retained id (`create`, or `run -d --cidfile`) — never `--rm` —
   with the non-root user and tmpfs working root;
2. starts it and captures `stdout`/`stderr` with a bounded reader (the `--json` JSONL feeds the
   usage gate);
3. enforces the round timeout by issuing an explicit `kill` against the retained id — killing the
   client process alone does **not** stop a daemon-managed container;
4. retrieves the verdict by copying the `-o` output file out of the exited container
   (`docker cp <cid>:<path>`) **before** removal, so the verdict source is byte-identical to the
   Windows stack (the captured stdout stream is the fallback if `-o` is unavailable);
5. **removes** the container in a guaranteed cleanup path that runs on success, failure, and
   timeout alike.

This makes the bounded-run and verdict-capture guarantees concrete rather than implied by `--rm`.

**Confidentiality argument (stated precisely).** The reviewer has no shell and no file-read tool
(default-deny), so it cannot read the one secret staged into the container (`auth.json`), and there
are no host files to reach regardless of any Codex flag. Even under open egress there is therefore
nothing host-side to exfiltrate. The container contributes filesystem and process isolation; the
flag discipline contributes tool denial. The honest limit: the staged `auth.json` lives *inside*
the boundary, so the container does not isolate the reviewer from that one credential — tool denial
protects it, which is why the battery audits every output channel for it (§ battery) and why the
battery's capability controls use a dummy credential (below).

## The credential (auth + AGENTS.md)

The Windows stack uses the real `~/.codex` as `CODEX_HOME` (read-write), so `auth.json` and
`~/.codex/AGENTS.md` resolve and token refresh persists. In the container the requirement is:

1. `auth.json` and `AGENTS.md` are available in the container's `CODEX_HOME` so auth and the
   trusted account-level `AGENTS.md` resolve exactly as today (`config.toml` stays ignored via
   `--ignore-user-config`).
2. **The host credential is never mutated by the sandbox.**
3. **In-session token refresh does not hard-fail a round.**
4. **Only these two files are exposed — nothing else from `~/.codex`.**

**Mechanism (host-side staging; never mount `~/.codex`) — addresses round-1 P1.** The host
`~/.codex` directory is **never** mounted: a read-only bind of the whole directory still *discloses*
every file in it (read-only prevents mutation, not reads). Instead the runner creates a fresh,
host-side, minimally scoped **staging directory** and copies into it **only** `auth.json` and
`AGENTS.md`, after validating each is a **regular file** (not a symlink, socket, or device) with
expected ownership and permissions. That staging directory is mounted at the container's
`CODEX_HOME`; nothing else from the host is bound. This makes "only these two files are exposed"
literally true, and defines UID/permission/symlink handling explicitly.

**Refresh, and never expose the live credential to controls.** The container may refresh the access
token in-session; whether that write persists to the host is governed by the refresh-token
semantics established in § Risks and mitigations. Critically, the **capability-enabled positive
controls** in the security battery (which force-enable shell/file-read to prove the detector works)
must use a **synthetic dummy credential**, never the live `auth.json` — otherwise a control run
under the Codex UID could read the real secret. If auth cannot resolve or refresh, the round
**fails closed** with guidance to re-authenticate on the host.

## The Codex image

- Ship a `Dockerfile` (under `gauntlet-review/`) that installs a **pinned** Codex CLI version on a
  minimal Linux base as a non-root user. The install mechanism (pinned npm global or pinned release
  artifact) is a plan decision; the pin is the contract.
- **A precise, architecture-qualified OCI identity is the binary pin** — stronger than today's exe
  SHA-256, because it pins the whole Codex stack (binary + interpreter + libraries). Because a
  multi-arch image index selects a *different* per-architecture manifest (arm64 vs x86_64), and a
  local image ID is a third identity again, the pin is **unambiguous**: the runner mandates
  `--platform` and records the **selected child-manifest digest, the image config/ID, and the
  `os/arch`** — not merely an index digest. That tuple is recorded at calibration and
  **re-verified before every round**; live evidence is keyed to the *actually executed* platform
  image, so x86_64 evidence never authorizes an arm64 run or vice-versa. A mismatch (image rebuilt,
  re-pulled, or wrong arch) refuses the round — the container analogue of exit `13` — until the
  caller re-pins with an explicit `--accept-new-image` acknowledgement that re-probes and
  re-enumerates features.
- The **default-deny feature enumeration** (`codex features list`) runs against the CLI *inside the
  pinned image*, so the `--disable` set is deterministic per image identity and pinned alongside it.

## Python module layout

Most of `lib.ps1` is OS-agnostic logic that ports directly; only the boundary is replaced.

| Module | Ported from | Notes |
|---|---|---|
| `verdict.py` | `Test-Verdict`, size bounds, severity invariant | Direct port; identical normalization + canonical serialization (§ equivalence) |
| `usage.py` | `Get-RunUsage` acceptance-time usage gate | Direct port; same invariants (exactly one `turn.completed`, positive `input_tokens`, headroom gate) |
| `features.py` | default-deny `--disable` computation | Enumerates inside the image; pinned to the image identity |
| `sandbox.py` | `Invoke-CodexProcess` + harness (`New-HarnessDir`, `Assert-HarnessSafe`) | **New**: creates/starts/kills/cleans the container, manages the image-identity pin and credential staging, streams stdin, captures JSONL, `cp`s the verdict out. Replaces env-minimization + harness path arithmetic (tmpfs replaces it) |
| `publish.py` | `publish-review.ps1` + `Publish-CodexReview` | Direct port; still shells to `gh`; provenance binding, idempotency (`--paginate --slurp`), drift, dismissal all preserved |
| `premises.py` | `Test-PremiseManifest`, calibration, live-evidence | Re-keyed to the container fingerprints (below) |
| `state.py` | `Get-StateDir`, carry-over ledger, create-only artifacts | Direct port; **identical on-disk layout** to the PS stack |
| `invoke_codex.py` | `invoke-codex.ps1` entry point | One review round: pin check → run → usage gate → verdict validate |

## Premises / live-evidence, re-keyed

Same fail-closed structure as the Windows manifest, with container-appropriate fingerprint inputs:

```
{ platform_manifest_digest, image_config_id, os_arch, codex_version_in_image,
  schema_sha256, agents_md_sha256, container_invocation_profile_hash,
  live_evidence { schema_gate, security_battery } }
```

- `container_invocation_profile_hash` covers the container runtime identity **and the full `run`
  argv** (image pinned by platform-manifest digest, `--platform`, mounts, caps, network mode, and
  the composed codex args), so a changed runtime, architecture, or run configuration hashes
  differently and is rejected — the analogue of the Windows invocation-profile hash. `os_arch` is
  fingerprinted separately so evidence is never portable across architectures.
- The two independently-fingerprinted `live_evidence` sub-records (`schema_gate`,
  `security_battery`) and the "recalibration drops evidence, forcing a live re-run" semantics are
  preserved unchanged.

## The security battery, re-conceived

The battery cannot be a 1:1 port because it verifies **container** properties, not **environment**
properties. It asserts, each with a positive control that proves the detector can see what it rules
out:

1. **Tool denial holds inside the container** — the existing control-verified classes (shell, web,
   apps, MCP, plugins) are re-exercised *inside the pinned image*: each fires when isolated (one
   capability force-enabled), is absent under the real default-deny set, and does not collide with
   another class's signature.
2. **The mount/device/socket table matches an exact allowlist** — the runner inspects the
   container's actual runtime configuration *and* the in-container `mountinfo`, and asserts it
   contains **only** the expected credential staging mount and tmpfs working root. It explicitly
   asserts **no container-runtime socket** (`docker.sock`/`podman.sock`) and no other host path,
   device, or socket is present — a mounted runtime socket would be a full host escape. A single
   invisible canary is *not* sufficient; a control run that deliberately adds a host bind-mount must
   surface it, proving the detector works.
3. **Egress posture is exactly what is claimed** (§ Network egress).
4. **A synthetic secret never appears in ANY captured output channel** — a canary placed where the
   reviewer might reach it must not appear in the verdict, the JSONL event stream, stderr, or any
   diagnostic output. The ported injection battery's three hard requirements are preserved:
   non-compliance (never coerced into approving), identification of an independent planted defect,
   and no environment/credential disclosure. Positive controls use a **synthetic dummy credential**,
   never the live `auth.json`.
5. **Image-pin mismatch refuses** — a round run against an image whose platform-manifest digest /
   config ID / `os_arch` does not match the pin is rejected.

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

- **`install.sh`** (thin bootstrap) → **`install.py`** — fail-closed. It must **generate** evidence
  before it **verifies** it, so a fresh machine is never refused for lacking evidence it has had no
  chance to produce (the Windows flow avoids this by running the gates as separate documented
  commands *before* `install.ps1`; the Unix installer does the whole sequence transactionally in
  one run). Ordered:
  1. verify a supported container runtime is present and usable (**Docker primary; Podman used if
     it is a drop-in** for the run/inspect surface the stack needs), and verify the host
     architecture is supported;
  2. build or pull the image and **pin** it (record platform-manifest digest, config ID, `os/arch`),
     then run the **offline pytest suite** (a failure stops before any live call);
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

These are hard requirements, because doc-mode review state is committed beside project docs and
must be identical regardless of which stack produced it:

- Both stacks emit a **single defined canonical serialization** — sorted keys, UTF-8 without
  ASCII-escaping unless required, `\n` line endings, and fixed number formatting — so "equivalent"
  is a precise, testable byte contract rather than an accident of two serializers (PowerShell
  `ConvertTo-Json` and Python `json.dumps` differ on Unicode escaping, key order, and spacing). For
  the same reviewer output, both stacks produce byte-identical verdict and state files under this
  canonical form. (Recommendation ids already derive from parsed fields via `Get-RecommendationId`,
  not raw bytes, but the committed files must still match.)
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
4. **Equivalence golden corpus** — not a single fixture but a shared corpus exercising the canonical
   serializer across edge cases: multi-byte and escape-requiring Unicode, key ordering, newline
   conventions, size-bound and numeric boundaries, malformed/normalized values, the
   severity-downgrade path, and carry-over-ledger transitions. Both stacks run the corpus and their
   outputs are **byte-compared in cross-platform CI**; a divergence fails the build.

## Risks and mitigations

- **Container runtime dependency.** Heavier prerequisite than Python alone; the installer verifies
  it up front and fails closed with guidance.
- **Refresh-token rotation could invalidate the host credential.** Discarding a container-refreshed
  `auth.json` is only safe if the provider's refresh tokens are **reusable**. If the pinned
  CLI/provider **rotates** refresh tokens, the first in-container refresh can invalidate the
  unchanged host credential (breaking later rounds and possibly host auth), and concurrent rounds
  worsen the race. **Required before v1 ships:** establish the pinned CLI/provider's refresh-token
  semantics empirically. If rotation is possible, either (a) serialize rounds and persist the
  rotated credential back atomically through a **host-side broker** that owns `~/.codex`, or
  (b) mint a **short-lived per-round credential** before launching the sandbox so the container
  never holds the durable refresh token. The chosen approach is validated by a test that runs two
  sequential rounds and asserts host auth still works.
- **Podman divergence.** Only drop-in compatibility is promised; the invocation-profile hash pins
  the exact runtime so a substitution is never silent.
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
