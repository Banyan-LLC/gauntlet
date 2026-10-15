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

## Continuation: explicit repeated-source-line framing

The verified SID head `6264848e9d3e71206c3e538e5b4421df1fb7a7a6` has 932 passing
required tests and 14 packaged CLI checks. Its full round-6 request is 1085198
bytes and 1084767 scalars, beyond the unchanged 1048576 caps. No attempt ran.
Preserve all 200 sections, 161 complete additions, 37 canonical findings and the
49 immutable prior state files, original base and remaining review budgets.

Add only explicit `-CompactRepeatedLines`, requiring verified compact source
composition in local and PR modes. Label first literal repeated source cores as
`~N=TEXT`; use backward `~N~` references with each row's original leading prefix.
Keep every unique literal visible. Count frames and dictionary boundaries;
fall back wholly on source marker collisions and roll back non-shortening
candidates. Enforce 65536 dictionary entries, 4194304 retained UTF-16 units,
1048576 source-body units and 4194304 aggregate reconstructed diff units before
append. Preserve all earlier protocols and output when disabled.

The throwaway explicit-label prototype restores every section exactly and
predicts 1024966 complete bytes, including a new protocol. This is not dispatch
authority. Execute focused/full offline tests, one scoped source review, live
schema/security/actual-reader/capacity certification, source equality and one
backed-up installation. Then measure the actual complete installed payload and
resume original round 6. Do not create a new SID review loop or alter its limits.

## Continuation: complete source-frame envelope

The verified d329d4809ec439965fc9e11c3e502b393579e6a5 SID candidate passed
1121 required tests and 14 packaged CLI checks. The complete round-8 request is
1067829 bytes and 1067384 scalars, exceeding the unchanged 1048576 caps. All
208 sections, 169 complete additions, 44 canonical findings and 67 prior
history/ledger files are retained; no round-8 attempt has run.

Implement only the optional CompactSourceFrames envelope described in
`docs/build-log/2026-10-15-source-frame-renderer.md`. Apply after unchanged
source-line processing. Preserve actual seven-character index spelling, full
Git blob/mode proof and every source character; no synthetic full-index diff.
Keep all existing formats/defaults/protocols and all safety/review limits.

Run revised red/green tests, one scoped acceptance pass, complete offline suite,
actual old/new hermetic reader cases, runtime capacity and schema/security
gates. Verify clean source, back up and install once, compare every installed
file, and recompose the complete actual installed SID request before resuming
original round 8. Preserve the refused over-budget baseline and all earlier
receipts. No pruning, history reset, base/head shift for size, or extra attempt.
