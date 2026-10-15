# Lossless local and PR review renderer implementation plan

User approved the measured format and execution on 2026-10-14. This continues the existing shared tooling task on its clean isolated branch; it does not start a new SID review loop.

## Scope and constraints

Preserve all source, test bodies, controlling context, canonical findings and review history. Keep the model, frozen catalog, effective window, output reserve, headroom, round/attempt limits, one MiB byte/scalar limits and publication gates unchanged. No PR creation or posting is part of tooling certification.

## Tasks

1. Add complete-added-file compact headers and an independently checked decoder to the certified library. Test exact round trips, full Git blob/mode identity, malformed counts/fields/hashes, unsupported modes/paths/final newlines, Unicode, blank and delimiter-looking content. Preserve every unsupported section unchanged and bind ordered coverage.
2. Integrate opt-in compact composition into local and PR invocation before preflight. PR mode obtains actual metadata and check records using the author identity, verifies synchronized PR/base/live tip and required successful exact-head checks, generates the hermetic triple-dot diff and binds metadata plus ordered coverage into immutable attempt records. Keep ordinary invocation compatible.
3. Review the combined source, fix actionable findings, run affected and full offline suites, then refresh source-bound runtime capacity proof and the two live certification gates. Commit verified tooling as geoffroth with configured email.
4. Back up the installed skills, install once through the certification gate, verify file equality, manifest acceptance and unchanged capacity. Update the shared tooling contract with exact receipts.
5. Verify all old SID state fingerprints, frozen base/head and complete caller ledger; preflight the production payload; resume existing round 3 in its recorded harness. Return only normalized canonical verdict and sanitized receipts. Carry any required subsequent SID changes through the owning workflow.

## Review focus

- A literal body line can resemble a diff header or compact JSON header: decode by count, never delimiter scanning.
- A compact section must not bind only an abbreviated Git hash: verify full HEAD blob and mode.
- PR metadata is untrusted review material, never controlling context, and cannot substitute caller assertions for actual API evidence.
- Metadata and checks can drift during composition: bind snapshots and recheck before dispatch/publication.
- Exact final payload, including protocol, carryover and metadata, must pass both fixed caps before allocating an attempt.
