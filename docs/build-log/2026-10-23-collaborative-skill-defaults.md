# Collaborative skill defaults

The installed Gauntlet entrypoints still selected the hermetic PowerShell
harness even with healthy MCP tools available. This update makes collaborative
MCP the default in `gauntlet-review` and `gauntlet-dev`; explicit `legacy`,
`hermetic` or `mode=legacy` requests load the original protocols from `LEGACY.md`.
Missing MCP setup is reported rather than silently selecting another mode.

The original instruction bodies are preserved without edits. Their SHA-256
digests, including the original installed line endings, are:

| Original instruction / preserved legacy file | SHA-256 |
| --- | --- |
| `gauntlet-dev` | `b0aabd34658bd857b911a46f70f66d8cd04af202216756e5b68152dfd9f05d16` |
| `gauntlet-review` | `7b34c0415901737f3b34301ec3e8bcd4222169aabf534157511e777a91ec44e5` |

The collaborative reference records complete source/history/evidence paging,
original finding identity and carry-over, fresh local completion, explicit
restart handling and the distinction between peer status, CI and GitHub review.
Neither route automatically authorizes GitHub approval or merge. The product
runtime, dependencies, legacy scripts and fixed MCP operator configuration are
unchanged.

## Verification and installation

Before editing, a read-only behavioral baseline selected the legacy harness for
both ordinary and missing-MCP scenarios. The updated instructions were then
checked against six scenarios: ordinary MCP, explicit legacy, missing tools,
wrong source ref, adapter restart after lost reply, and local completion with
failing CI. A final review of all seven instruction/setup files found no
actionable findings. These were instruction/source checks, not model execution
or a canonical MCP peer verdict.

Both existing installed skill trees were backed up before modification. Only
five instruction/reference files per host were copied into the Claude and Codex
skill roots. All ten installed files match the new source bytes, and their
relative instruction links resolve. The original installed non-entrypoint files
remain byte-identical to the backup. The two checked collaborative database
files retain their original SHA-256 values; no review was opened, findings
reset, history migrated or database backup attempted while hosts were running.

Nine externally owned, model-free verification cases passed with original exit
status zero and observed native process-tree retirement:

- One protocol case loaded both hosts' actual configurations and initialized all
  four configured core/peer endpoints. Exact tool discovery matched the four
  author operations and two peer operations. Both cores returned successful
  status; both peer instances reported `ready` with no owned model thread.
- Four native CLI configuration checks covered `mcp get` for each server in
  Claude and Codex. Claude's direct health checks reported both servers connected.
- Four skill-schema checks validated both skills in both installed locations.

The schema validator initially lacked PyYAML. PyYAML was installed only into the
private verification archive's tool-dependency directory; the product venv was
not changed. `pip check` reported no broken product dependencies. Source
whitespace checks passed.

The fresh Claude model-assisted check discovered both Gauntlet skills but was
refused by its account's weekly quota (HTTP 429), before a model response.
Its initialization recorded core connected and peer pending; the separate
direct CLI/protocol checks above establish both endpoint connections. This
attempt is preserved as a failure, not counted as a model behavior pass.

The initial Codex model-assisted check waited for stdin and timed out before
producing a model event. Its original receipt and output are preserved. The
follow-up uses the test controller's explicit stdin-EOF option in a new archive
receipt, without changing product code or retrying an uncertain peer turn.
That fresh native Codex check passed: it loaded the installed skill entrypoints
and collaborative reference, chose the expected route for all six scenarios,
called both status endpoints successfully and reported healthy empty-state
readiness. Its original exit was zero and the external owner observed process
tree retirement. It opened no review and started no SDK peer turn. This is a
Codex model-assisted skill check; it does not fill the quota-blocked Claude
model-behavior check.

All raw host configurations used for checks, outputs, receipts, hashes,
pre-update skill trees and failed attempts remain in the private installation
verification archive `skills-default-20261023T114735Z`. Native conversation logs
and prior Gauntlet evidence/review archives remain in their existing locations.
This setup check is separate from a full Claude-to-Codex review workflow; the
previous live workflow qualification is retained unchanged.

## Operator use

Start fresh Claude/Codex sessions to refresh skill discovery. The existing
`main` versus `origin/main` profile remains an installation-check profile: a
feature review requires a matching source-ref configuration and compatible
private state. Existing bound stores must be preserved. No new environment
variables, secrets, runtime pins or database migrations are introduced.
