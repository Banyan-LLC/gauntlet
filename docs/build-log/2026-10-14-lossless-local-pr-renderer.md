# Lossless local and PR review representation

User-authorized bounded extension, 2026-10-14, following the read-only complete-payload measurements. This extends the existing verified-reference branch without changing any review limits or resetting history.

## Representation and coverage

`-CompactAddedFiles` emits `["ADDED",path,mode,index,count]` followed by every literal file-content line. Only a recoverable addition prefix and mechanically repeated header fields are removed. It applies to safe paths, regular mode 100644, one complete added-file hunk and final LF. Unsupported sections, existing-file hunks and the separately approved complete controlling-spec reference remain literal.

The encoder verifies complete full HEAD blob and mode identities, index abbreviation, base absence, canonical original headers and body count. The decoder uses recorded section lengths and logical body counts, not scanning for delimiters in source. It checks header fields, full blob hash, ordered original/rendered section digests and exact reconstruction of the complete reference-rendered diff. The 831-byte protocol is part of the prompt, not an uncounted side channel. Coverage is part of immutable attempt metadata.

Both fixed limits remain 1,048,576: UTF-8 bytes and Unicode scalars. The compact route cannot raise the byte ceiling by passing a larger operational budget. Model gpt-6.1-sol, xhigh, frozen account catalog, 872000 requested / 828400 effective window, 128000 output reserve, 25 percent headroom and 493300 actual input-token ceiling remain unchanged. Runtime capacity is still proved independently from actual CLI telemetry.

## Authoritative PR inputs

The PR compact route accepts a preamble, independently generates the triple-dot patch, and acquires actual PR title/body/base/head/ref/live-tip and complete exact-head CI metadata using the author read identity. Every named required check must succeed; all other check and status records remain in the untrusted summary. Full API responses are retained in attempt provenance. Actual metadata and CI are rechecked immediately before allocation. Existing publication and handoff freshness checks are unchanged. This feature does not create a PR or post a review.

Git generation clears ambient override variables, disables system/global configuration and external/textconv mechanisms, uses explicit patch/prefix/context options and the immutable empty attribute tree. Higher-priority info/attributes is refused without modifying it. Genuine binary summaries remain unchanged. An independent raw changed-path inventory with full blob/mode IDs must match every patch section. This prevents an apparently reversible representation from validating an incomplete input patch.

New PR acquisitions use the existing native containment path: 4 MiB aggregate retained output, one deadline including cleanup, whole-process-job retirement, and refusal on any transport/overflow error, even when the parent exits zero. Responses are never truncated into apparently valid input.

## Review and testing

Independent source review found ambient Git/config/attribute coverage and unbounded metadata acquisition gaps; both were fixed by class. The fixed byte gate was also reviewed. Re-review reported no remaining actionable findings.

Focused suites cover complete round trips, delimiter-looking and blank/Unicode bodies, count/header/hash/blob/mode/path corruption, duplicate paths, unsupported modes/quoted paths/missing final LF, exact-head and metadata drift, partial CI pages, required checks, hostile Git settings, genuine binary summaries, quoted Unicode paths, and actual entry-point refusals before CLI probing or attempt allocation. The prior preflight tests now explicitly initialize the new opt-in parameter and scope process-receipt ordering to model dispatch, preserving their original assertions.

## SID continuity

Frozen source head: `5c9a8b0b716038affb5d5405919830c11208a87c`.
Original base: `97bae6f4bd8d4657b181e1335055844fc914f7fb`.

Production composition matches the approved measurement exactly: 1042992 UTF-8 bytes, 1042553 Unicode scalars, payload SHA256 `2418393c654fec84251f6518e849bcb8416fce7f626bc8d86f61e9dc30a715ce`. Coverage has 176 ordered sections: 137 compact and 39 unchanged. The existing 22-entry canonical carryover is complete and all entries are addressed. All 23 preexisting state files match the coordinator's authorization inventory before dispatch; the source checkout is unchanged and clean. Round 3 must reuse the recorded original state, pin, immutable preamble and external empty harness.

The final offline run passed 1642 assertions across 17 suites. Focused renderer and PR-input suites passed 67 and 54 assertions respectively. The source-bound runtime fixture verified 828400 effective tokens on the unchanged executable/profile/catalog. Live schema and security gates passed 14 and 142 assertions. The first security launch refused a missing caller diagnostics directory before model execution; its log was preserved, the owned directory was created, and the final run passed without source or policy changes. Strict source manifest validation passed before installation.

Sanitized machine-local receipts are under `%LOCALAPPDATA%/gauntlet-review/diagnostics/compact-renderer-*`. The original installed stack is preserved under `%LOCALAPPDATA%/gauntlet-review/backups/before-compact-renderer-20261014-c0e77b6af4e247beb1a7051a50fbc3ee`, with its file-hash manifest. Installation and the final canonical SID verdict are reported separately after completion; no SID source change or PR write is part of this tooling change.
