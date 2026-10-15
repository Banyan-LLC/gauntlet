# Bound catalog and runtime capacity

Human approval on 2026-10-14: implement/test the narrow CLI/profile update,
recertify it, and resume the existing SID converter local round 2. Preserve the
one-request 1 MiB limit, model/effort, review history, two-attempt/ten-round caps,
128,000 output reserve and 25% headroom. No partitioned protocol is implemented.

## Exact stack

- Source builds on `11654b804d1802dff27e68f303c07a063b93da09` in the same clean-start
  `feat/verified-review-references` worktree.
- Replacement CLI: `0.162.0-alpha.17.2`, versioned executable
  `%LOCALAPPDATA%/OpenAI/Codex/bin/9614f1d9b40d9c4f/codex.exe`, SHA-256
  `e98c516f1c8935789aabe9122ee7e05ec4c3efd1ba6acf179242e031c495b99e`.
- Reviewer remains `gpt-6.1-sol` at `xhigh`; existing hermetic disables remain.
- An unchanged account model cache snapshot is frozen at
  `%LOCALAPPDATA%/gauntlet-review/catalogs/3cb2879f5a83beff23264f7ff3c2e170897c62cb349a084364df0492f5186901.json`.
  The filename is its complete-file SHA-256. Its real entry retains default
  500,000, maximum 872,000 and effective percentage 95.
- Machine-local ignored `capacity-profile.json` binds that path/hash and explicit
  supported `model_context_window=872000`. Both it and runtime proof are copied
  by the normal installer and bound by certification fingerprints.

## Runtime proof and protection

The exact sealed argument builder and full audit now include explicit
`model_catalog_json` and `model_context_window` overrides. The invocation hash
also binds snapshot bytes and descriptor bytes, so metadata changes cannot hide
behind an unchanged path. The existing ignore-config/rules flags, read-only
sandbox, ephemeral execution, stdin payload and complete disabled-feature set
are retained. The configured catalog is loaded directly; bundled/refreshed
disagreement is not used as an optimistic capacity estimate.

The controlled tiny fixture `tests/live/live-context-capacity.ps1` recorded
actual CLI runtime telemetry `model_context_window_effective=828400`, separately
from requested `model_context_window=872000`. It adds only Rust diagnostic
verbosity to the child environment, never modifies account settings or SID state,
and records sanitized numeric receipts plus a hash of the bounded diagnostic
stream. No raw model response or review prompt is exposed.

The final proof records CLI/catalog/profile, audited invocation, fixture/library
producer hashes, process-tree retirement and valid real usage. Profile and
producer sources are leased before use, CLI bytes are rehashed under the lease,
and loaded producer source must match held file bytes. Runtime proof acceptance
rejects changed producer, CLI/profile/catalog or effective metric. Production
invocation holds profile, snapshot and proof read leases through execution and
rehashes bound inputs before accepting usage. Existing live certification also
holds these inputs through process-tree retirement.

Sanitized proof:
`%LOCALAPPDATA%/gauntlet-review/diagnostics/capacity-bound-profile-20261014-6.json`.
Earlier controlled diagnostics 1 through 5 remain retained as calibration history;
no SID formal attempt was used for those fixtures. The final profile hash is
`e86b2e84369f711c4fbcff82741eff47f585c7eb8ecac579bfd0c7341d0636a6`.

Capacity calculation: 872,000 * .95 = 828,400 effective tokens;
floor(828,400 * .75) - 128,000 = **493,300 maximum input tokens**. This is not
inferred from the API's larger advertised context, and does not establish the
token count of a future payload. Each formal request must satisfy the original
byte/character bounds and its own real completed input-token accounting before
canonical acceptance. Single fresh-turn material stays below the default
compaction threshold when it satisfies this input-plus-reserve limit.

## Review fixes and tests

Independent review found and fixed profile leasing before argument composition,
CLI rehashing after leasing, and binding runtime proof to its protected producer
and audited diagnostic receipt. Offline bound-profile tests cover snapshot hash
changes, over-limit requests, malformed/duplicate/missing overrides, mismatched
expected catalog fields, proof CLI/profile/catalog/source changes, wrong runtime
values and attempts to rewrite leased files. Legacy fake-CLI tests explicitly use
unbound temporary fixtures; they never copy machine-local profile/proof into
synthetic stacks or bypass production checks.

The normal offline suite, calibration, schema gate and security battery must pass
before coordinated installation. Their exact results and the formal round's
normalized result are returned in the coordinator handoff; machine-generated
premises and review-state files remain the authoritative immutable records.

## SID round continuity

Retain original base `97bae6f4bd8d4657b181e1335055844fc914f7fb`, finished head
`d2db8c098fc122e40ba0f3fcf1e27004f85b592b`, existing state/preamble/harness and
canonical 17-entry carry-over. Approved spec duplicate reference preserves all
171 diff sections, 170 other sections unchanged. Preserve the root's pre-update
file inventory and every round-1 attempt/verdict byte. Only the authorized CLI
pin transition, current operational state and new round-2 records may change;
no history reset, source/test edits or SID PR publication is performed here.
