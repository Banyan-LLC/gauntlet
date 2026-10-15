# Optional complete source frames

## Scope and baseline

The verified SID candidate d329d4809ec439965fc9e11c3e502b393579e6a5
passed 1121 tests and 14 packaged CLI checks. Its complete round-8 input is
1067829 UTF-8 bytes and 1067384 Unicode scalars, preserving 208 sections and all
44 prior recommendations. The fixed 1048576 limits refuse it before dispatch.
No round-8 attempt has been consumed. Source, history, base and limits stay fixed.

This continues the approved lossless renderer plan. The optional
`-CompactSourceFrames` switch requires `-CompactAddedFiles` and
`-CompactIndentation`, in local and PR modes only. Existing protocols, output and
manifests remain byte-identical when disabled. No new dependencies or settings.

## Wire format

F headers are [F,path,abbreviation,count] and FL headers are
[FL,path,abbreviation,count,start,end]. The abbreviation is exactly seven
lowercase hex characters. F/FL imply mode 100644 and the original index is
exactly 0000000.. followed by that abbreviation. This is the ACTUAL immutable
baseline format: all 150 eligible source sections use seven zeroes and seven
hex characters. Other index spellings remain in old framing. No synthetic full
index is substituted. The original manifest index/mode remain unchanged; full
40-character HEAD blob identity, mode, base absence and the prefix relationship
are still independently verified by the existing host. Original six headers
and all body content reconstruct exactly.

For F bodies, a single initial symbol maps to leading groups of four ASCII
spaces by this ordered alphabet: caret, plus, backtick, percent, less-than,
greater-than, semicolon, equals. Thus ^ is four spaces, + eight, and = thirty-two.
For nine or more groups use the canonical decimal marker |N|, without leading
zeroes. Zero to three remainder spaces stay literal. Numeric markers 0..8 are
noncanonical. Literal leading TABs or original source cores beginning with any
reserved symbol or a reserved |digits| marker force whole-file fallback to the
old ADDED/INDENT format. Blank lines, raw strings, trailing spaces, interior
TABs and Unicode are unchanged. Existing INDENT uses repeated TABs and is not
modified by this extension.

FL is an outer reversible envelope for an already-valid INDENT_LINES frame.
First replace its short indentation prefix by N literal TAB characters and
restore the exact original seven-zero index and INDENT_LINES header; then apply the existing
source-line and INDENT rules. F similarly wraps INDENT. Tilde is never an
indentation symbol, so zero-indent ~N=TEXT/~N~ and eight-space +~N=TEXT/+~N~
remain unambiguous. Existing source-line processing runs BEFORE the F adapter;
its unchanged reserved-core checks already leave literal marker pairs in
INDENT, which can become F but never FL. Dictionary entries, IDs and counters
are not mutated by this envelope. Consume counted LF rows only.

Manifest encodings are source-frame and source-frame-lines, with optional root
source_frame_version=1 only when at least one such frame exists. The root
schema version remains 1. Old protocols are byte-identical. A separate
Get-CompactSourceFrameProtocol hash is recorded as
compact_source_frame_protocol_sha256 in immutable attempt metadata.

## Implementation contracts

- Get-CompactSourceFrameProtocol returns the self-contained F/FL description.
- ConvertTo-CompactSourceFrameBody(Body,Count) returns encoded string, or null
  for reserved source/leading-TAB fallback; malformed input throws.
- ConvertFrom-CompactSourceFrameBody(Body,Count,MaxDecodedLength=1048576)
  returns original source or throws before over-budget append/allocation.
- Read-CompactSourceFrameRow(Body,Position) returns Prefix, Core and Next, with
  optional Groups. Find LF before prefix work. Unwrap F/FL prefixes to
  canonical legacy TAB prefixes before calling the unchanged old decoder.
- ConvertTo-CompactReviewDiff gains CompactSourceFrames; apply the pure F pass
  after verified INDENT/source-line encoding, wrapping only INDENT or
  INDENT_LINES. Other kinds retain their original format. No new I/O.
- The section's original index and mode stay unchanged. Serialized F/FL index
  abbreviation uses the seven-character suffix of its exact original index. The original full
  HEAD blob proof remains in the manifest; all paths and counters are retained.

Every transform must shorten both complete UTF-16 and UTF-8 representations;
fallback/rollback remains exact. F body is no longer than old tab indentation
and the repeated zero index/mode are encoded by the F contract. Restore validates
F/FL header shape, canonical original index, mode/path/full HEAD blob, counted rows,
source dictionary boundaries, exact ordered section hashes and complete range.

## Bounds and verification

All prior limits remain: 1048576 prompt bytes/scalars and decoded UTF-16 units
per source body, 4194304 aggregate reconstructed diff, 65536 source dictionary
entries, 4194304 retained dictionary UTF-16 units, minimum core length 16,
round cap 10, attempt cap 2, fixed CLI/model/profile/catalog, 493300 input tokens,
128000 reserve and 25% headroom. No text or history is pruned. LF-first linear
parsing and numeric bounds precede expansion. No global policy/settings changes.

Required gates: focused red/green and legacy invariance, local and PR input
composition/refusal/privacy tests, scoped acceptance, complete offline suite,
actual old/new reader cases, runtime capacity, schema and security gates,
strict source manifest, clean commit as geoffroth, backed-up single
installation and exact installed/source equality, then complete installed SID
preflight with unchanged history before the existing round-8 attempt.
Certification and installation are pending.

## Adapter simplification after design review

The F pass runs AFTER source-line framing. F only wraps INDENT and FL only
wraps INDENT_LINES. This retains the existing frequency/declaration/refusal
logic without modification. Restore validates the outer hashes/header/types,
linearly unpacks prefixes to canonical TAB form, and builds a derived legacy
manifest with restored kinds/index and exact derived hashes/lengths. It then
calls the unchanged legacy restore path (without the outer version field).
Derived append lengths are charged against the original section and four-MiB
aggregate before allocation. Reconstructed original source must independently
pass the reserved-core/no-leading-TAB eligibility check. Canonical short prefix
roundtrip, original full blob/header/section digests and all legacy dictionary
checks remain required. Only the actual seven-zero/seven-hex index qualifies; no executable source, quoted path,
missing final LF or literal/mixed-leading-TAB body is newly admitted.

## Actual-baseline admission correction

The initial full-index proposal admitted zero of the real 150 source sections.
It was rejected before production implementation or dispatch. The corrected
four/six-field F/FL format explicitly encodes the actual seven-character index
and fixed regular-file mode. Every original index/mode remains in the coverage
manifest, and full HEAD blobs continue to be verified against Git. No Git diff
options, source head, base, history or safety limit is changed for size.

## Final certification, 2026-10-15

The frozen 104-file candidate passed 2869 assertions across 28 offline suites,
with zero failures. Both the previous source-line reader and the new F/FL
reader passed all three actual live cases each. Every fixture process tree
retired, and every usage record was valid. Runtime telemetry independently
confirmed effective capacity 828400 with the unchanged CLI/profile/catalog.
After copying that proof, stack calibration, schema (14/0), security (142/0)
and the strict source premise check passed in that order.

The source-only complete SID preflight reconstructed all 208 sections and
44 carry-over findings exactly: 1045495 UTF-8 bytes and 1045050 scalars,
both below the unchanged 1048576 limits. No SID attempt ran during this
preflight. All 67 prior history files remain byte-identical. Earlier failed
fixture/preflight logs remain preserved; production limits were not raised.

Sanitized receipts are under %LOCALAPPDATA%/gauntlet-review/diagnostics with
the source-frame-renderer prefix: offline-v1, legacy-reader,
reader-compatibility, runtime-capacity, schema, security and
strict-source-premise, all dated 20261015. Final certification and installed
inventory receipts bind the clean commit and the backed-up installation.