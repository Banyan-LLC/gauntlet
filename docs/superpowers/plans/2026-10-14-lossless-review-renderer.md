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
# Continuation: historical review metadata token framing

The frozen SID head `44fc79d2792f8cc7c88d8d5df9c64fde7404de36` exceeds the
unchanged byte cap by 18,615 bytes after its four verified fixes. The continuation
uses only duplicated raw JSON string tokens in complete historical review
metadata additions. A read-only feasibility fixture saved 28,060 bytes before
protocol/framing overhead across 32 metadata files, with exact reconstruction.

Implement an explicit `-CompactReviewMetadata` outer layer requiring verified
compact composition in local and PR modes. Keep every literal code/test line,
the complete live carry-over ledger, all unique information, original files,
base/head identities, history and limits. Validate complete Git blobs, modes,
base absence, framing, backward ordinals, expanded resource bounds and both
ordered coverage layers. Exercise malicious markers, quoting, Unicode, no final
LF, JSONL, unsupported paths and tampered/reordered evidence before certification.
Then independently review the combined change, run the complete offline and live
gates, refresh the exact runtime proof, install with source equality and backup,
and measure the complete SID round-4 request again. A hypothetical fit is never
dispatch authority. Preserve every failed measurement and certification artifact.

## Continuation: recoverable leading-indentation metadata

After the four round-4 SID corrections and 842 passing tests, the complete
round-5 candidate is 1,071,859 bytes and 1,071,442 scalars: both exceed the
unchanged 1,048,576 limits. No attempt ran. Preserve this failed preview and the
original base, all 30 findings, history and every source/test/document character.

Add explicit `-CompactIndentation`, requiring verified compact composition in
local and PR modes. Complete added regular source files under `src/` may encode
each four initial ASCII spaces as one transport tab, with a remainder of zero
through three spaces. Reject files with any literal tab in a leading whitespace
prefix. Keep every non-indentation character directly readable and every line
in its original order. `INDENT` frames must reconstruct the complete original
diff, including whitespace inside Kotlin raw strings. Keep other frames literal.

Verify canonical framing, declared line counts, per-section and aggregate
expansion bounds before append, complete blob/mode/base-absence/index identity,
ordered coverage and exact layered reconstruction. Include protocol instructions
in both prompt limits. Run focused and complete offline tests, one scoped source
review, actual hermetic-reader compatibility cases, source-bound runtime proof
and schema/security certification. Back up and install only the verified source;
then preflight the complete committed SID payload before allocating round 5.
