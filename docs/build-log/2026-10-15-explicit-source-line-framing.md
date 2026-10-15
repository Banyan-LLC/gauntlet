# Explicit source-line framing continuation

## Purpose and retained evidence

The complete SID round-6 request at `6264848e9d3e71206c3e538e5b4421df1fb7a7a6`
exceeds the fixed byte limit by 36622 bytes. Its 932 required tests, 14 packaged
CLI cases, full 37-entry ledger and all prior review state are preserved. No
round-6 attempt has been allocated. This continues the authorized renderer task.

Two throwaway prototypes preserve all 200 ordered sections. The first used
implicit literal numbering; the selected format visibly labels declarations,
reducing the dictionary from 8176 to 573 entries and making references directly
readable. It predicts 1024966 complete bytes with 1847 references across 140
source frames. Prototype receipts remain explicitly uncertified, uninstalled and
undispatched. Actual source/installed composition must independently prove fit.

## Format and ownership

`-CompactRepeatedLines` requires `-CompactAddedFiles` and is available only in
local and PR modes. `LINES` and `INDENT_LINES` retain the original five fields
plus ordered dictionary start/end counts. A source row keeps its exact leading
ASCII space/tab prefix. `~N=TEXT` visibly declares literal TEXT; `~N~` reuses an
earlier declaration. Every other row stays literal. Restore lines before the
existing indentation decoder. Existing hunks and non-source formats stay exact.

Source cores with reserved literal markers force whole-file fallback. Tentative
declarations are rolled back when a frame does not strictly shorten. Lookahead
and retained dictionary state are bounded to 65536 entries and 4194304 UTF-16
units. Per-body decoded source is bounded to 1048576 units, total reconstructed
diff to 4194304; lengths are charged before append. Contiguous IDs, unique cores,
backward references, per-frame/final state counts, original lengths, full blobs,
index/mode/path identities and ordered hashes remain mandatory.

The original three protocols are unchanged. A separate source-line protocol is
included in the complete prompt and fingerprinted in immutable attempt metadata.
The output format and manifest shape are unchanged when this option is disabled.
All model, CLI, catalog, context, reserve, headroom, byte/scalar, review/attempt
and publication gates remain unchanged. Certification and installation receipts
will be added after the required checks complete.

## Final verification, 2026-10-15

The scoped follow-up review has no remaining findings. The final offline run
passed 2103 assertions across 25 suites. Live schema passed 14 checks; the live
security battery passed 142 checks. All three actual reader cases passed:
positive exact reconstruction, invalid forward reference and unknown reference.
Runtime telemetry confirmed the unchanged 828400-token effective context, with
128000 reserved tokens and a maximum 493300 input tokens. Every controlled
process was confirmed retired. The strict source premise manifest passed.

The frozen final source contains 99 files. All matched after the offline and
live gates. A bounded regression proves truncated one-MiB whitespace input
returns within the existing five-second process limit; the preserved red run
timed out before the linear row parser fix. An actual over-cap complete fixture
remains rejected even when BudgetBytes requests a larger operational budget.

The full SID round-6 source preflight retained all 200 sections and all 37
carried recommendations, reconstructing exactly at 1024973 UTF-8 bytes and
1024542 Unicode scalars. The fixed one-MiB caps remain unchanged. This preflight
is not a SID model dispatch. All 49 protected history files remain intact.

Private certification receipts are retained under the existing local diagnostics
root with the source-line-renderer prefix; earlier failures, prototypes and
installation backups remain retained. Installation is performed separately
from this source verification and compared byte for byte afterward.
