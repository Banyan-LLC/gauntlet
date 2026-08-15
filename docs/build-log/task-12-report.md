# Task 12 Report: codex-reviewed-dev/SKILL.md + install.ps1

## Status
COMPLETE. Both files created with the brief's exact content, verified, tested, and committed.

## Frontmatter Verification
`tools/claude-skills/codex-reviewed-dev/SKILL.md`: PASS. Valid `---\nname: ...\ndescription: ...\n---`
block, structurally identical in shape to the already-shipped `codex-review/SKILL.md` (same two
keys, no tabs, no ambiguous `: ` sequence inside the description's plain scalar, embedded `"..."`
quotes appear only mid-value so they don't trigger quoted-scalar parsing). No PyYAML was available
in this environment to run a real parser (no network access to install one, so none was installed);
verified by structural inspection instead, mirroring the working file's exact shape.
`install.ps1` is a PowerShell script; the brief specifies no frontmatter for it.

## Content Fidelity
Both files were diffed programmatically, line by line, against the brief's fenced code blocks
(`task-12-brief.md`): **byte-identical** (modulo the brief markdown's own CRLF-vs-LF rendering,
normalized before comparing). Both committed as LF, matching every existing file under
`tools/claude-skills/` (0 CRLF bytes in each, confirmed via `git show HEAD:<path>`).

## Cross-Check Results

| Doc claim | Script reality | Verdict |
|---|---|---|
| doc mode, phase `spec` / `plan` | `Get-StateDir -Mode doc -Phase` (`ValidateSet 'spec','plan'`) | match |
| approved spec is the only TRUSTED CONTEXT for a plan review | codex-review SKILL.md prompt template: "approved spec when reviewing a plan; NOTHING ELSE" | match |
| `invoke-codex → publish-review as BanyanLLC` | `invoke-codex.ps1` + `publish-review.ps1 -Reviewer` default `'BanyanLLC'` | match |
| "Exits 2/3 → refresh oids, re-review (a round)" | `publish-review.ps1`: 2=drift, 3=dismissed,re-review; codex-review SKILL.md says the identical "2/3 → refresh oids, re-review (counts a round)" | match |
| "Exit 4 → human flag NOW" | `publish-review.ps1` exit 4 = HUMAN FLAG | match |
| "Exit 5 → retry once" | `publish-review.ps1` exit 5 = transient gh failure, retry once | match |
| ledger status `addressed/disputed/outstanding` | `Test-CarryOverLedger`: `$e.status -notin @('addressed','disputed','outstanding')` | exact match |
| `Test-HandoffFresh` (lib.ps1) returns `Fresh` | function exists in `lib.ps1`, returns `[pscustomobject]@{Fresh=...; Reason=...}` | match |
| "APPROVED state, commit match, both oids equal reviewed pair" | `Test-HandoffFresh` also checks reviewer login, marker-in-body, and CI check-runs/commit status green | match, but abbreviated — doc's summary omits the reviewer-identity, marker, and CI-green sub-checks (not false, just partial) |
| "No `gh auth switch`, ever" | grep confirms zero occurrences of `auth switch` anywhere in shipped scripts | match |
| "BanyanLLC token inside publish-review — per-command/per-process only" | `Invoke-Gh` passes the token via a single-use `-EnvironmentMap @{GH_TOKEN=$Token}` scoped to one child process | exact match |
| "the human alone merges" / never merge | grep confirms no `gh pr merge` or merge-invoking call anywhere in shipped scripts | match |
| ledger/status enum, round cap 10, model `gpt-5.6-sol`@`xhigh`, reviewer `BanyanLLC` defaults | `invoke-codex.ps1 $RoundCap=10`; `New-CodexArgs $Model='gpt-5.6-sol' $Effort='xhigh'`; `publish-review.ps1 $Reviewer='BanyanLLC'` | exact match |
| "Human flags... Triggers: exits 4/10/12/14" | 4/10/14 are unconditional HUMAN FLAG paths in the scripts. **Exit 12 is not unconditional**: codex-review's own SKILL.md protocol carves out the premise-manifest case as self-serve (re-run `calibrate-premises.ps1`, then re-invoke) — "any *other* exit-12 message (harness, token) is a human flag." | **flagged, not changed** — see Concerns |
| install.ps1: `Select-CodexCli -Candidates (Get-CodexCandidates)` | exact param names (`-Candidates`; `Get-CodexCandidates` takes no required args) | exact match |
| install.ps1: `Get-DisableSet -FeatureNames`, `Get-InvocationProfileHash -DisableSet` | exact param names; `$instCli.FeatureNames` is a real property on `Select-CodexCli`'s return object | exact match |
| install.ps1: `Test-PremiseManifest -SkillRoot -ActualCli -InvocationProfileHash -BudgetBytes 50000` | exact param names; `-BudgetBytes 50000` matches `invoke-codex.ps1`'s own default, so install-time validation uses the same budget bound production rounds use | exact match, and this is the specific property the brief called load-bearing |
| install.ps1 reads `$pm.Valid` / `$pm.Reason` | `Test-PremiseManifest` returns exactly `{Valid; Reason; Manifest}` | exact match |

No parameter-name or exit-code mismatch required changing either file. One doc-accuracy nuance
(exit 12) is reported below rather than silently edited, per instructions — the brief mandated
this SKILL.md's content verbatim.

## Installer-Refusal Verification
Exactly what was executed, and why each step was safe:

1. **Checked for a real Codex CLI on this machine first.** Found one for real: `codex.exe` at
   `%LOCALAPPDATA%\OpenAI\Codex\bin\codex.exe`, plus `%USERPROFILE%\.codex\config.toml`. Nothing
   named `codex` is on PATH. This meant an unmodified, unisolated run of `install.ps1` could
   discover and actually invoke that real, live binary (`--version`, `login status`, `exec
   --help`, `features list`) — a real risk under the "no network calls" constraint (`login
   status` plausibly contacts an auth server). It was never invoked, by construction (next step).
2. **Ran the real, unmodified `install.ps1`** as a child `pwsh` process with `$env:USERPROFILE`
   and `$env:LOCALAPPDATA` overridden to a fresh scratch pair of directories (under this
   session's scratchpad), set only inside that one child process (never touching this shell's
   own environment or any file outside the scratch pair). With no `config.toml`, no
   `OpenAI\Codex\bin`, and nothing on PATH under that scratch environment, `Get-CodexCandidates`
   returns an empty list — `Select-CodexCli`'s loop body never executes, so **no process was
   spawned at all** for this run; the real `codex.exe` was never touched.
   Result: `refusing to install: no usable Codex CLI (No Codex CLI candidate passed the
   compatibility probe. ...)`, **exit 1**. Verified after the run: nothing created under the
   scratch `.claude\skills` or `.claude\CLAUDE.md`, and the real
   `%USERPROFILE%\.claude\skills` / `%USERPROFILE%\.claude\CLAUDE.md` remained exactly as they
   were beforehand (both absent, confirmed by `Test-Path` before and after).
3. **Directly exercised the specific gate the brief calls out** (the premise-manifest gate) by
   dot-sourcing the real `lib.ps1` and calling the real `Test-PremiseManifest` against the real
   `tools/claude-skills/codex-review` skill root — which genuinely ships no `premises.json` —
   with a placeholder `-ActualCli` object (irrelevant here: the function's first check is
   `Test-Path premises.json`, which returns before `-ActualCli`'s fields are ever read). This
   performs no external process execution at all, so it carries no risk regardless of env vars.
   Result: `Valid: False`, `Reason: premises.json is absent` — the exact refusal the brief
   anticipated.
4. **Cleanup**: removed the scratch `install-test` directory (`home`/`local`) from the session
   scratchpad after use. Nothing else was created there.

Combined, steps 2 and 3 show both gates refuse independently and safely: the CLI-selection gate
refuses when no CLI is discoverable, and the premise-manifest gate — the one the brief's "shipping
without recorded premises" warning is about — refuses on its own terms against the real, current
absence of `premises.json`, using the real shipped function. I did not attempt a single real
end-to-end run that passes gate 1 and reaches gate 2 in the same invocation: doing so would
require a genuine `.exe` (a `.cmd`/`.ps1` shim is correctly rejected by `Select-CodexCli` with no
`-AllowWrapper`, and `install.ps1`'s call passes none), and fabricating one felt like more risk
for no more evidence than the two safe checks above already give.

## Test Suite
Ran each `test-*.ps1` individually (`pwsh -NoProfile -File`) rather than the aggregate
`run-tests.ps1`, per the brief's guidance. All match the expected totals exactly, all green:

| File | Passed | Failed |
|---|---|---|
| test-composer.ps1 | 26 | 0 |
| test-discovery.ps1 | 22 | 0 |
| test-invoke.ps1 | 168 | 0 |
| test-policy.ps1 | 13 | 0 |
| test-publish.ps1 | 51 | 0 |
| test-schema.ps1 | 9 | 0 |
| test-state.ps1 | 61 | 0 |
| **Total** | **350** | **0** |

Note: `test-invoke.ps1` temporarily writes a test-fixture `premises.json` into the real
`tools/claude-skills/codex-review/` directory as part of exercising the manifest gate against a
fake pinned binary, and restores it (deletes it, since none existed before) in its own `finally`
block. Confirmed via `git status` immediately after the full run completed: only the two intended
files were untracked; no stray `premises.json` was left behind.

## Anything Written Outside the Worktree
Nothing was left outside the worktree. During testing, two scratch directories were created
under this session's scratchpad
(`...\a1b57ec0-87c6-41a8-825a-6ecc4113fefd\scratchpad\install-test\{home,local}`) to stand in for
`$env:USERPROFILE`/`$env:LOCALAPPDATA` for one isolated child-process run of `install.ps1`; both
were deleted afterward. The real `%USERPROFILE%\.claude\skills` and `%USERPROFILE%\.claude\CLAUDE.md`
were never created, modified, or touched (confirmed absent both before and after every test). No
GitHub calls, no network calls, and no invocation of the real, installed `codex.exe` were made at
any point.

## Commit
SHA: `8b3c663`
Message: `feat(codex-reviewed-dev): orchestrator skill and idempotent installer`
Staged explicitly `tools/claude-skills/codex-reviewed-dev/SKILL.md` and
`tools/claude-skills/install.ps1` by name (not `git add tools/claude-skills` as the brief's Step 4
literally suggests) — precisely because `test-invoke.ps1` is now known to transiently create a
real `premises.json` under `tools/claude-skills/codex-review/` during its own run; staging by
exact path guarantees that kind of test residue can never be swept into a commit. `git status`
was clean of it by the time of this commit (see Test Suite note above), and the working tree was
clean immediately after committing.

## Concerns / Self-Review Findings
1. **Exit 12 is listed as an unconditional "Human flags" trigger in the orchestrator doc, but it
   isn't one.** codex-review's own SKILL.md protocol (already shipped, Task 9) explicitly splits
   exit 12: a premise-manifest cause is self-serve (`calibrate-premises.ps1`, then re-invoke —
   *not* a human flag), and only "any other exit-12 message (harness, token) is a human flag."
   `progress.md` shows this exact class of gap (exit 12 documented as a bare "human flag" with no
   mention of the calibrate-premises fix) was already caught and fixed once, in the primitive's
   own doc, during Task 9's review. The orchestrator SKILL.md re-introduces the same
   simplification one level up. Per instructions I wrote the brief's exact content rather than
   editing it, and am reporting this instead — worth a look before this doc ships further, since
   the pattern of "this exact issue already bit Task 9" suggests it's a real recurring blind spot
   rather than a one-off phrasing choice.
2. `Test-HandoffFresh` does more than the Handoff bullet describes (reviewer identity, marker
   presence, CI green) — not incorrect, just an abbreviation; noted above in the cross-check table.
3. No functional defects found in either shipped file; both match the brief exactly and match
   real script signatures/behavior everywhere checked.
