# Optional source word dictionaries

## Frozen baseline and intent

Continue the approved lossless local/PR renderer plan. SID source stays at
4771576ab7ddcc9c6dc332ce64dfe089ba8bbe59 against the original
97bae6f4bd8d4657b181e1335055844fc914f7fb base. All 217 source/test files,
1789 passing verification cases, 14 CLI checks, and 76 saved review/history
files stay fixed. The round-9 ledger has exactly 46 canonical addressed entries.
No round-9 attempt has run.

Installed tooling 673bd63 produces the complete 214-section round-9 payload:
1109862 UTF-8 bytes / 1109413 scalars, SHA-256
e9de874936e0e715e238a9ac6a8e9a0cc24310a11bdaec1eb0b179534b13f2aa.
The unchanged 1048576 caps correctly refuse it. It contains 175 complete added
sections, 39 literal sections, 156 F/FL frames and 32 historical metadata sections.
The failed measurement and all earlier evidence remain preserved.
All 154 positive feasibility rows are actually F/FL: two F sections save an
estimated 228 bytes with 24 words, and 152 FL sections save 137276 bytes with
6013 words. Both kinds are required; other compact kinds remain unchanged.

A read-only exact-body feasibility calculation found 137504 bytes of potential
savings in 154 source frames, using 6037 local dictionary entries / 57004 UTF-16
units. Existing source-line state is 705 entries / 36594 units. With an explicitly
assumed 2048-byte protocol, the estimate is 974406 bytes / 973957 scalars. This is
an estimate, not a new producer, reader proof, certification or installation.

## Scope and ordering

Add optional -CompactSourceWords, requiring -CompactAddedFiles,
-CompactIndentation and -CompactSourceFrames, in local and PR modes only.
Source-line framing remains independently optional. No dependency, account,
permission, global policy, CLI/model/profile/catalog, budget or lifecycle change.
Defaults and all existing protocol text and manifests stay byte-identical.

The word adapter runs AFTER the existing source-line and F/FL passes and BEFORE
historical metadata framing. It may wrap only already verified, complete added
src/*.kt, *.java and *.asm sections whose actual inner encoding is source-frame
or source-frame-lines (F or FL), preserving their existing header verbatim.
Unverified/literal sections are never newly admitted. Current ledger text remains
literal. Historical JSON encoding and controlling-document references are unchanged.

Restore metadata first, then word envelopes, then the prior F/FL, source-line,
indentation and added-file layers. A word dictionary is LOCAL to one file.
An existing source-line dictionary still spans files in original section order.
Words in a line declaration are expanded BEFORE that declaration enters the legacy
line dictionary. Later cross-file line references resolve the original full core,
never the later file's local word table.

## Wire format

One header line is the canonical JSON array:

    ["WORDS",["assertEquals","failure"],"<exact previous header JSON text>"]

It is followed by exactly the previous frame's count of LF-terminated body rows.
The final field is a JSON string containing the exact legacy header, not a path
alias, a synthesized index or a new source identity. Its old mode/index/count and
source-line start/end, where present, remain exact.

Within a WORDS body, @0, @1, etc. reference the closed local table. IDs are canonical
ASCII decimal 0..65535 with no leading zeroes. The run of digits ends the reference;
an ASCII letter, digit or underscore directly beside a reference would violate the
whole-word boundary. Unknown, malformed and noncanonical references fail closed.
References expand once; table entries cannot contain references. Every chosen word
must have at least two references, each strictly shorter than its word. Leaving
an occurrence of a selected whole word literal is noncanonical. The closed table
itself gives ID order; deterministic optimal selection is a producer property,
not a requirement for a reader to rerun the frequency optimizer.

Words are maximal ASCII runs [A-Za-z_][A-Za-z0-9_]* with at least three characters.
Both boundaries use that exact ASCII alphabet, not locale/Unicode word categories.
This is text substitution everywhere in the counted body, including comments and
quoted/raw strings, not a language parser or semantic rename. All other text,
Unicode, indentation, interior TABs, trailing spaces and blank rows remain literal.
Any prior rendered F/FL body containing @ followed by an ASCII digit falls back
as a whole file to its unchanged prior frame. Check that body before global line
expansion: a global reference may legitimately reconstruct an earlier unwrapped
core containing literal @0, which is never processed by the local word decoder. Near markers without a digit remain literal.
Unwrapped old frames do not interpret word references.

Choose repeated words deterministically by descending estimated saving, with
ordinal word tie-breaking. Evaluate actual decimal-ID and JSON-table costs before
admission. Each chosen reference must shorten its word, and each wrapped section
must strictly shorten the previous frame in both UTF-16 and UTF-8 including its
closed table/header. Otherwise retain the exact legacy frame/manifest section.

## Bounds and provenance

No existing bound increases. Source words and source-line entries share the SAME
aggregate 65536 entries / 4194304 retained dictionary UTF-16 units. Frequency
staging is charged against remaining shared space before admitting a new key;
when staging cannot fit, the entire file falls back unchanged. Clear staging
before whole-result reconstruction. No hidden independent extra dictionary budget.

Decoder checks typed versions/counts/header/digests and aggregate charges before
expansion. It charges actual word tables, not just declared summaries. Internal
reserved-entry/character arguments carry actual word charges through F/FL restore
to the existing source-line state, reducing its available capacity. Zero reservations
retain old behavior/state shape. Dishonest legacy counters cannot admit an excessive
live line dictionary before a final mismatch is noticed.

Derived legacy appends are precharged against the stored previous section length,
1048576 decoded UTF-16 units per source body and 4194304 aggregate reconstructed
diff. Table/name/header parsing remains bounded by the input frame and dictionary
caps. No repeated regex replacement over progressively expanded data and no
recursive token expansion. Expansion is a single forward bounded scan.

Only actual WORDS use adds root source_word_version=1 plus exact dictionary count
and UTF-16 summaries. A wrapped section retains its original identity fields,
stores the previous section in word_legacy and its closed word_dictionary, and
updates only encoding/rendered size/hash for this outer layer. Restore rebuilds
a derived legacy manifest and calls the unchanged legacy semantics with the
shared reservations. Full source reconstruction, ordered coverage and full Git
blob/mode/base identities remain mandatory. Immutable attempt metadata records
Get-CompactSourceWordProtocol in compact_source_word_protocol_sha256.

Both prompt caps stay 1048576. Effective context stays 828400, reserve 128000,
25 percent headroom / input <=493300, round cap 10 and attempt cap 2.

## Verification and installation sequence

1. Scoped design/controller admission review of this actual-baseline design.
2. Focused red/green codec, local/PR input/privacy/provenance/refusal tests and
   independent manual reader-vector tests. Test different local tables around a
   global line declaration/reference, marker/near-marker literals and legacy fallback.
3. Complete source-only SID preflight and exact reconstruction with all 214 sections,
   all 46 findings and all old Git identities; no model attempt or installation.
4. Scoped source acceptance, then freeze source and run every offline suite.
5. Actual old source-line reader, old F/FL reader and new word reader positive/negative
   cases. Preserve standard verdict schema and every process retirement/usage check.
6. Fresh runtime capacity proof, copy proof, calibrate acceptance, then schema and
   security gates, then strict source premise validation in that order.
7. Clean verified commit as geoffroth, preserved rollback backup, one installation,
   exact installed/source inventory and installed premise check, unchanged policy.
8. Complete installed SID input must match certified source preflight, including
   shared bounds, all source/history and counters, before original round-9 dispatch.

Preserve every failed probe/test/gate and prior install receipt. No source editing
for size, trimming, partitioning, model/cap changes, reset or auto approval/merge.
Certification and installation of this extension are pending.
## Source certification completion — 2026-10-15

The final candidate passed 3430 assertions in 32 offline suites. All 28 prior
suite counts remain unchanged (2869 assertions); the four new suites add
314, 84, 3 and 160 assertions. The first complete test run passed its tests but
was rejected by its source-freeze check after the manual fixture gained explicit
near-marker coverage. That run and both earlier freezes remain preserved.
The final rerun held all 111 frozen source files unchanged throughout execution.

All nine actual reader cases passed: three legacy source-line, three F/FL and
three WORDS cases. Every case had valid usage and confirmed process-tree
retirement. The independent manual fixture reconstructs five complete bodies
and original indices in a 787-unit response, below the unchanged 800-unit schema
limit. Different local tables, cross-file full-core references, literal @0 and
literal @near are covered. The five older protocol hashes remain unchanged.

Fresh runtime proof confirmed effective context 828400 with the existing
493300 input-token ceiling, 128000 output reserve and pinned CLI/model/profile/
catalog. Calibration, the 14-assertion schema gate, the 142-assertion security
gate and strict source premise validation passed in order. All producer and
test bytes stayed frozen through these gates. This completion section is appended
without altering the original document. A subsequent precommit whitespace check
removed exactly one trailing ASCII space from the independent host test; its
token stream is unchanged and its 84 assertions passed again. No runtime or live
fixture bytes changed after certification.

The complete source-only SID round-9 input is 974712 UTF-8 bytes / 974263 scalars,
SHA-256 add1ba90945398dc97df36155dc35a2dabf0fde6851258c818d855af2026c341.
All 214 sections and all 46 canonical addressed findings reconstruct exactly.
Actual local dictionaries use 6035 entries / 56991 UTF-16 units in 154 sections.
An independent reader expanded all 40042 references and recovered the exact
pre-word diff and ordered coverage. The SID head remains 4771576; all 217 files
still match its compiled snapshot and all 76 protected history files are intact.
No round-9 model attempt has run during certification.

Certification receipts, both failed/superseded runs, the complete frozen candidate
and the prior 43-file installed rollback inventory remain in local diagnostics.
Installation is the next step: it requires the clean certified commit, a checked
backup, exact installed/source equality, unchanged global policy and valid
installed premises, followed by a complete installed-input equality preflight.
