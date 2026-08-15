# Task 14 Report

Status: complete, all green.
Commit 1 (plan sync + premise-gate unblock): `37aa69cba959eb1a05c4cd9424f3d3662d67cd42`
(short `37aa69c`), branch `claude/reusable-spec-plan-review-8fcff9`.
Commit 2 (parameter-contract safety): `51b2c71ded0b5ff147f74c4dc6e8f14f185dfa18`
(short `51b2c71`), same branch.
Tests: composer 34, discovery 27, invoke 183, policy 15, publish 51, schema 9, state 61 = 380,
run individually via `pwsh -NoProfile -File tools/claude-skills/tests/test-*.ps1`, all green, and
confirmed again via `run-tests.ps1` -> `ALL TEST FILES PASSED`. Baseline before this task: 397
(composer 30, discovery 27, invoke 206, policy 13, publish 51, schema 9, state 61).
Live schema gate: NOT run (costs a live model call; left for the user as instructed).

## Commit 1: plan doc sync + premise-manifest blocker

The plan (`docs/superpowers/plans/2026-08-09-codex-review-loop.md`) still described the
pre-live-evidence design throughout: dual verdict schema, four-premise budget estimate,
`session_created`/`turn_complete` event names, `CODEX_HOME`-only child env. Read the design doc's
"Live-evidence round (2026-08-12)" entry as the authoritative source and brought every task's
operational content in line with it and with the already-shipped code: single schema (`-SchemaPath`
renamed from `-StructuralSchemaPath` at every call site, including Task 4's `Test-Verdict` and
Task 8's `publish-review.ps1`), the acceptance-time usage gate and its create-only usage artifact
(added to Task 7's interfaces and Step 3's code, replacing the old exit-code header), the
50,000-byte check reframed as an operational bound not the guarantee, `live-schema-gate.ps1` added
to the file structure and Task 14's hard gates, real event taxonomy substituted for invented names
in Task 1's fake shim and Task 10/11's live-battery guidance (with the tool-event denylist patterns
reframed as best-effort, not proof, since round-6 live testing found no registered-tool roster
exists to calibrate against), and the `SystemRoot` child-env finding documented in Global
Constraints, Task 5 (Interfaces, Step 3's code, Step 5's narrative), and Task 14's gate 3. Removed
reasoning is kept under explicit "Historical (superseded)" labels in Task 5's `Test-PremiseManifest`
code sample, Task 10 section 5, and the Plan Self-Review (items 2 and 4) rather than deleted.

### The premises.json blocker

`invoke-codex.ps1` refused to run without `premises.json`, which could never be created: its
required `tokenizer_evidence` field demanded an authoritative source establishing gpt-5.6-sol's
tokenizer encoding, which was never found -- the plan's own revision-9 self-review had already
flagged this as "one deliberate and blocking" placeholder.

Decision: `Test-PremiseManifest`'s value was never only the four numeric premises -- it also binds
the selected CLI hash/version/path, the schema hash, the accepted `AGENTS.md`, and the invocation
profile, so a changed reviewer stack forces re-validation regardless of budget math. That binding
role still earns its place (it does real work no other check does) and is kept. The four numeric
premises (`tokenizer_family`, `tokenizer_evidence`, `base_overhead_tokens`, `max_output_tokens`,
`context_window_tokens`) and the `BudgetBytes + overhead + max_output <= 0.75 x context_window`
inequality are dropped along with the `-BudgetBytes` parameter, because the acceptance-time usage
gate (already shipped in `invoke-codex.ps1`/`Get-RunUsage`, from the prior live-evidence commits)
now proves the same thing on real measured usage instead of a prediction. `calibrate-premises.ps1`
is rewritten to record only the stack-identity fields via the existing compatibility probe -- it
makes **no live model call at all** now (verified: ran it against a fake shim, confirmed exit 0,
a valid manifest, and that the shim's `exec` branch never fired -- see commit message and the
ad-hoc verification described there). `install.ps1` and both `SKILL.md` files updated to match
(dropped `-BudgetBytes` from their `Test-PremiseManifest` calls / stale exit-12 guidance).

Names kept as-is (`Test-PremiseManifest`, `premises.json`, `calibrate-premises.ps1`) rather than
renamed to something like "stack manifest": renaming would have touched ~104 references across
`test-invoke.ps1` alone plus both `SKILL.md` files and `install.ps1`, for a naming preference, not
a defect -- not worth the blast radius or risk in an already-large change. Function/file
docstrings now explain the "Historical (superseded)" numeric-premise role explicitly, so the name
doesn't read as misleading to a future reader.

`test-invoke.ps1`'s `Test-PremiseManifest` battery rewritten for the reduced manifest shape:
dropped the tokenizer_evidence sub-object tests, the numeric type/range hygiene tests, the
inequality tests, and the `[long]`-overflow regression tests (that whole failure class no longer
exists, since there's no more inequality math) -- kept every stack-identity fail-closed case
(absent/malformed file, missing/blank required field, wrong model, stale schema/AGENTS.md/
invocation-profile hash, wrong-binary A/B regression). `Set-TestManifest` (used by every
`invoke-codex.ps1` entry-behavior test) updated to the same reduced shape. Net: 206 -> 183
assertions in that file.

## Commit 2: parameter-contract safety

Empirically confirmed the exact failure mode before writing anything: a `[Parameter(Mandatory)]
[string[]]` parameter given an array containing an empty-string element fails via a
NON-TERMINATING binder error. In the REAL call shape used throughout this codebase -- a bare
assignment, no try/catch, under `Set-StrictMode -Version Latest`, followed by a separate `if`
reading the result -- reproduced exactly what the brief described: the assignment never
completes, reading the unset variable next raises a second non-terminating StrictMode error, and
the `if` runs NEITHER branch. The script reaches its end and **exits 0**. (A plain `Assert-Throws`
-style single-call try/catch does NOT distinguish old from new here -- PowerShell's parameter-
binding failure IS caught by an immediately-wrapping try/catch either way; the danger is
specifically the bare-assignment-then-separate-check shape, so the regression tests reproduce
that shape in an isolated child process rather than using `Assert-Throws` directly.)

Three parameter decisions (all: changed the contract, not proved safety -- see rationale below):
- **`Get-DisableSet -FeatureNames`**: could plausibly have been proven safe (every production
  caller's array comes from a regex `\S+` capture that cannot produce an empty string), but it's a
  general library function with no enforcement stopping a future or test caller from passing one
  directly, so "currently unreachable" was not treated as "provably safe forever."
- **`New-CodexArgs -DisableSet`**: same reasoning; also directly callable in tests today with a
  hand-written array.
- **`Get-InvocationAudit -CodexArgs`**: same reasoning, plus this function's entire purpose is to
  audit a potentially-tampered/adversarial argument array -- proving its own input can't be
  malformed would undercut the function's stated job.

For all three: removed `[Parameter(Mandatory)]`, added a new `Assert-NoEmptyStringElements`
helper (in `lib.ps1`, above `Get-DisableSet`) that explicitly checks "was supplied" and "no
null/empty element" and `throw`s a clear, named, terminating error -- called as the first line of
each function body. Verified this doesn't change any passing-input behavior: full suite green
before and after, at 374 (post-commit-1) before adding tests, 380 after.

Regression tests: `Test-EmptyElementFailsClosed` (new helper in `helpers.ps1`) reproduces the bare-
assignment-then-if shape in a spawned child `pwsh -File` process and asserts the child exits
nonzero and never reaches its final `Write-Host` line. Verified each of the three fails against the
old contract by copying `lib.ps1` to a scratch file, reverting exactly the three parameters to
`[Parameter(Mandatory)][string[]]` with the `Assert-NoEmptyStringElements` calls removed, and
re-running: all three came back `exit=0`, reaching the final line -- i.e. red under the old
contract. Against the current (fixed) `lib.ps1`, all three come back `exit=1`, never reaching the
final line -- green. Wired into `test-policy.ps1` (`Get-DisableSet`, +2 assertions) and
`test-composer.ps1` (`New-CodexArgs` and `Get-InvocationAudit`, +4 assertions); net 374 -> 380.

### Concern: a fourth identically-shaped case, left unfixed

While editing `Get-InvocationAudit`, noticed its sibling parameter `-ExpectedDisable` (same
function, same `[Parameter(Mandatory)][string[]]` shape, same "currently unreachable" status) was
not in the reported list of three and left it unchanged, out of scope for this commit. A broader
grep for `[Parameter(Mandatory)][string[]]` in `lib.ps1` also turns up `Get-InvocationProfileHash
-DisableSet`, `Invoke-CodexProcess -CodexArgs`, and `Invoke-Gh -GhArgs` (in `publish-review.ps1`'s
call path) as the same shape, none of them reported. Did not expand scope to these four
unilaterally, since the task named exactly three; flagging here for a decision on whether they
warrant the same treatment.

## Verification commands (all run from the worktree root)

```
pwsh -NoProfile -File tools/claude-skills/tests/test-composer.ps1    # 34 passed, 0 failed
pwsh -NoProfile -File tools/claude-skills/tests/test-discovery.ps1   # 27 passed, 0 failed
pwsh -NoProfile -File tools/claude-skills/tests/test-invoke.ps1      # 183 passed, 0 failed
pwsh -NoProfile -File tools/claude-skills/tests/test-policy.ps1      # 15 passed, 0 failed
pwsh -NoProfile -File tools/claude-skills/tests/test-publish.ps1     # 51 passed, 0 failed
pwsh -NoProfile -File tools/claude-skills/tests/test-schema.ps1      # 9 passed, 0 failed
pwsh -NoProfile -File tools/claude-skills/tests/test-state.ps1       # 61 passed, 0 failed
pwsh -NoProfile -File tools/claude-skills/tests/run-tests.ps1        # ALL TEST FILES PASSED
```

Note: running `test-invoke.ps1` concurrently with itself (accidentally, once, during this task)
produced a spurious `182 passed, 1 failed` and a leftover untracked `premises.json`, because the
file saves/restores the REAL shared `codex-review/premises.json` around its `invoke-codex.ps1`
entry-behavior tests and two instances race on that single file. Not a product defect -- confirmed
by re-running alone, cleanly, twice: `183 passed, 0 failed` both times. Worth knowing if CI or a
future session ever parallelizes this specific test file.

## Concerns (full list)

1. The fourth-plus identically-shaped `[Parameter(Mandatory)][string[]]` cases noted above
   (`Get-InvocationAudit -ExpectedDisable`, `Get-InvocationProfileHash -DisableSet`,
   `Invoke-CodexProcess -CodexArgs`, `Invoke-Gh -GhArgs`) -- same bug shape, not in scope for this
   commit, left as-is.
2. `test-invoke.ps1` is not safe to run concurrently with itself (shared real `premises.json`
   path) -- pre-existing property of the file, not introduced here, just newly observed.
3. Doc-only: the plan's own fence-balance had one stray, unmatched closing ` ``` ` at end-of-file
   (pre-existing, unrelated to the 8 sync items); removed it while editing the adjacent
   Self-Review paragraph since it was a one-line, zero-risk cleanup directly in the text being
   touched.

---

# Task 14 follow-up: four post-relocation fixes (2026-08-15)

Status: complete, all green. Baseline 380 (composer 34, discovery 27, invoke 183, policy 15,
publish 51, schema 9, state 61) -> final 395 (composer 36, discovery 27, invoke 194, policy 15,
publish 53, schema 9, state 61). Four commits, one per section below, all on `main` in this repo
(not pushed; no GitHub calls made; the real `codex` CLI was never invoked -- see FIX 4's
end-to-end verification, which used a fake shim throughout):

- `b1b3c86` -- docs: repoint stale tools/claude-skills dev paths at the new repo root
- `dfea053` -- fix(codex-review): close the mandatory-array fail-open gap on the last four params
- `b46ab58` -- test(codex-review): stop test-invoke.ps1 from mutating the real premises.json
- `093a6eb` -- fix(codex-review): bind premise-manifest authorization to live evidence

## FIX 1: stale tools/claude-skills paths

`docs/implementation-plan.md` still described the pre-relocation layout throughout: the
Architecture sentence, the File Structure tree (rooted at `tools/claude-skills/`), and every
per-task Files/Interfaces/run/commit reference (67 occurrences total). Stripped the
`tools/claude-skills/` prefix mechanically everywhere it appeared as a file path; the tree's root
label became `.`; the 13 bare `git add tools/claude-skills[...]` commands became explicit
enumerations of the four actual top-level entries (`codex-review codex-reviewed-dev tests
install.ps1`), preserving each line's original scope (including the two that also staged
`docs/superpowers/specs`, left untouched).

`codex-review/scripts/calibrate-premises.ps1`'s docstring separately cited the pre-extraction
design spec at the old consumer-shaped path
(`docs/superpowers/specs/2026-08-09-codex-review-loop-design.md`); repointed it at this repo's own
consolidated `docs/design.md`, and mirrored the identical fix in the plan's own embedded copy of
that docstring (which explicitly claims to be "the current, shipped content" -- leaving it
unsynced would have made that claim false).

Deliberately NOT touched: every `docs/superpowers/{reviews,specs,plans}/...` path describing the
codex-review skill's own runtime state locations in a CONSUMER project (the Global Constraints
"State" bullet, Task 13's state paths, etc.) -- these describe the skill's behavior, not this
repo's own source layout, per the task's explicit carve-out.

Verified: `grep -r tools/claude-skills` afterward turns up only `docs/build-log/*.md` (9 files) --
dated historical task reports that correctly keep their as-run paths, since rewriting history
would misrepresent it. `docs/implementation-plan.md` itself: zero hits.

### Flagged, not fixed (out of scope, same shape as the calibrate-premises.ps1 fix above)

Two more places cite the same old spec path but were left alone because the task named only
`calibrate-premises.ps1`'s citation as the fix, with an explicit instruction not to touch
`docs/superpowers/{specs,plans}/...` paths otherwise:
- `docs/implementation-plan.md` lines 15 and 1161 (the Goal statement, and Task 5's
  "amend the spec" procedural instruction).
- `tests/test-discovery.ps1`'s comment above the fall-through assertion ("the plan document
  (docs/superpowers/specs/2026-08-09-codex-review-loop-design.md live battery...)").

All three are self-referential citations to this repo's own (now-consolidated) spec, not runtime
paths in a consumer project, so they are the same underlying staleness -- just not named in the
brief. Flagging for a decision rather than expanding scope unilaterally.

## FIX 2: the four remaining mandatory-array parameters

Applied the exact contract already used for the first three fixed parameters
(`Get-DisableSet -FeatureNames`, `New-CodexArgs -DisableSet`, `Get-InvocationAudit -CodexArgs`):
removed `[Parameter(Mandatory)]`, added an `Assert-NoEmptyStringElements` call as the first line
of the function body. No behavior change for any well-formed caller; every currently-empty-element
caller now gets a clean terminating throw instead of the non-terminating-bind-error/silent-exit-0
cascade documented in `Assert-NoEmptyStringElements`'s own comment.

Discrimination proof for each (temporarily reverted just that one parameter back to
`[Parameter(Mandatory)][string[]]` with no assert call, ran the owning test file, restored, ran
again):

| Parameter | Reverted (red) | Fixed (green) |
|---|---|---|
| `Get-InvocationAudit -ExpectedDisable` | `34 passed, 2 failed` | `36 passed, 0 failed` |
| `Get-InvocationProfileHash -DisableSet` | `185 passed, 2 failed` | `187 passed, 0 failed` |
| `Invoke-CodexProcess -CodexArgs` | `185 passed, 2 failed` | `187 passed, 0 failed` |
| `Invoke-Gh -GhArgs` | `51 passed, 2 failed` | `53 passed, 0 failed` |

Each reverted run failed on exactly the two assertions naming that parameter
("...fails CLOSED (nonzero exit), not silently" / "...does not silently run to completion past
the bad input") and nothing else -- confirming each new test discriminates the old contract from
the new one, isolated from the other three fixes already in place. Wired via the existing
`Test-EmptyElementFailsClosed` helper (no changes needed to it): `+2` assertions each in
`test-composer.ps1` (`Get-InvocationAudit -ExpectedDisable`), `test-invoke.ps1`
(`Get-InvocationProfileHash -DisableSet`, `Invoke-CodexProcess -CodexArgs`), and
`test-publish.ps1` (`Invoke-Gh -GhArgs`). `Assert-NoEmptyStringElements`'s own docstring updated
to enumerate all seven protected parameters instead of three.

## FIX 3: temporary skill root for test-invoke.ps1

The "invoke-codex.ps1 entry behavior" section wrote the real (gitignored)
`codex-review/premises.json` via `Set-TestManifest` and restored the operator's original content
in a `try/finally` at end-of-file. Replaced with: copy `codex-review/` (scripts + schemas +
SKILL.md) into `$tmp\entry-skillroot\codex-review` (a subdirectory of the file's existing
GUID-named `$tmp`) before this section runs; point `$entry` and `Set-TestManifest` at the copy.
`invoke-codex.ps1` always resolves its own `-SkillRoot` as `Split-Path $PSScriptRoot -Parent`, so
once `$entry` points into the copy, every read and write of `premises.json` for the rest of the
section stays inside it. The `try/finally` save-and-restore is gone -- there is nothing left to
restore.

Proof: a new assertion snapshots the real path's content (or absence) before the section runs and
asserts it is byte-identical after the entire file finishes (`Assert-Eq`, not just a visual
check). Independently verified two ways beyond the coded assertion:
- Single run: real `codex-review/premises.json` confirmed absent before, ran the file (`188
  passed, 0 failed` at that point in the sequence), confirmed still absent after.
- Concurrency (the actual originally-reported failure mode): two full runs of `test-invoke.ps1`
  launched genuinely concurrently via separate PowerShell background jobs (a first attempt via
  Git-Bash-backgrounded subshells hit an unrelated shell/path-resolution artifact in the harness
  itself, not a product issue -- redone via `Start-Job`/`Wait-Job` instead). Both completed
  cleanly (`188 passed, 0 failed` each, no interference), and the real `premises.json` remained
  absent throughout.

## FIX 4: premise-manifest semantics -- live evidence binds authorization

`Test-PremiseManifest` treated a manifest recording only stack acceptance (what
`calibrate-premises.ps1`'s compatibility probe can prove, with no live model call) as full
authorization. Split it into three pieces in `lib.ps1`:

- **`Test-StackAcceptance`** -- the original function, renamed, logic unchanged: CLI
  path/version/hash, schema hash, AGENTS.md hash, invocation-profile hash, model. This is what
  `calibrate-premises.ps1` can (re)derive from a probe alone, and now validates its OWN output
  against (it can never satisfy the fuller gate below, so checking against that would fail on
  every calibration, including correct ones).
- **`Test-PremiseManifest`** -- now the two-part gate `invoke-codex.ps1` and `install.ps1` both
  call unchanged (same signature). Calls `Test-StackAcceptance` first; if that passes, additionally
  requires a `live_evidence` sub-object on the manifest whose `gate`, `verified_utc`, and
  fingerprint (`cli_path`/`cli_version`/`cli_sha256`/`schema_sha256`/`agents_md_sha256`/
  `invocation_profile_sha256`) are all present and match the manifest's own (already-proven-current)
  top-level fields. Absent or mismatched -> refused, with a `Reason` that names
  `tests/live/live-schema-gate.ps1` as the remedy.
- **`Write-LiveEvidence`** (new) -- the only writer of `live_evidence`. Requires an existing
  stack-accepted `premises.json` (throws if absent, telling the caller to calibrate first); stamps
  the sub-object with the gate name, timestamp, and the CLI/schema/AGENTS.md/invocation-profile
  fingerprint the caller supplies. Called from exactly one place: `tests/live/live-schema-gate.ps1`,
  after every assertion in that file has passed (`$script:Failures.Count -eq 0`) -- that is what
  "live-verified" means in this codebase now.

`calibrate-premises.ps1` never gained the ability to write `live_evidence`: its output hashtable
simply has no such key, so every run of the script (a full overwrite of `premises.json`) drops
any evidence a prior live-gate run had stamped. Its docstring now states this plainly under an
"ACCEPTANCE, NOT VERIFICATION" heading, and its own self-check switched from the old
`Test-PremiseManifest` call (which would now always fail immediately after a fresh calibration)
to `Test-StackAcceptance`.

Updated every place that told an operator "run calibrate-premises.ps1" as if it alone always
clears exit 12: `invoke-codex.ps1`'s and `install.ps1`'s error messages, and both `SKILL.md`
files' exit-12 guidance now name both self-serve causes and which fixes which (stack drift ->
calibrate; missing/stale live evidence -> the live gate, run last since a later calibration drops
it again).

**End-to-end verification** (fake shim, isolated temp copy under a fresh GUID temp dir -- never
`codex-review`'s real files):
1. Ran the real `calibrate-premises.ps1` against the shim: exit 0, valid stack-only manifest
   written, shim's `exec` branch confirmed never fired (no live call).
2. `Test-PremiseManifest` right after: refused, `"...no live evidence...; run
   tests/live/live-schema-gate.ps1"`. `Test-StackAcceptance` on the same file: valid.
3. Called `Write-LiveEvidence` directly (simulating what `live-schema-gate.ps1` does on success):
   `Test-PremiseManifest` now valid.
4. Reran `calibrate-premises.ps1` (simulating a CLI update) against the same file:
   `live_evidence` confirmed absent afterward; `Test-PremiseManifest` refused again with the same
   reason as step 2.

Also smoke-tested `install.ps1` live against this machine's real environment: it refused with the
updated two-cause message and exit 1 (real `codex-review/premises.json` is absent here), confirmed
via `git status`/`ls` that nothing was mutated -- the CLI probe inside it is read-only and the
refusal lands before any `Copy-Item`/`Add-Content`.

`tests/live/live-schema-gate.ps1` was edited (added the `Write-LiveEvidence` call, guarded on zero
failures) but **never executed** -- confirmed syntactically valid via
`[System.Management.Automation.Language.Parser]::ParseFile` only, per the task's explicit
instruction not to run anything under `tests/live/`.

Offline regressions added to `tests/test-invoke.ps1`'s existing `Test-PremiseManifest` section
(reusing its established `$skillRoot = "$tmp\skillroot"` temp path, not the entry-behavior
section's copy -- that copy exists to host the entry SCRIPT for subprocess invocation, which
these direct in-process function-call tests don't need): no live evidence -> refused (plus a
same-manifest `Test-StackAcceptance` check proving the refusal is specifically the new layer, not
a regression in the pre-existing checks); live evidence fingerprinted to a different CLI hash ->
refused; matching live evidence -> accepted; `Write-LiveEvidence` stamps a record the gate then
accepts; recalibrating (writing a fresh stack-only manifest, exactly what `calibrate-premises.ps1`
does) drops a previously-stamped record and the gate refuses again. `Set-TestManifest` and the
`Test-PremiseManifest` golden-path fixture (`New-ValidPremisesHashtable`) both now also stamp
matching `live_evidence`, so the large pre-existing pin/harness/retry/budget/carry-over coverage
continues to exercise the full, now-stricter production gate unchanged -- caught one bug this way
during development: an early draft of the "recalibration drops evidence" regression reused the
now-live-evidence-carrying `New-ValidPremises` fixture as its "post-recalibration" state, which
made the assertion fail (the fixture no longer represented a stack-only manifest); fixed by
building that state from `New-ValidPremisesHashtable` with `live_evidence` explicitly removed.

## Concerns (full list, this follow-up)

1. `docs/implementation-plan.md` was NOT synced for FIX 4 (or further synced for FIX 1 beyond the
   named path/spec-citation fixes) -- it still carries a full historical code listing of the
   pre-split `Test-PremiseManifest` and the old unconditional "Run calibrate-premises.ps1"
   wording, and separately still cites the old spec path in two prose spots plus one in
   `test-discovery.ps1` (see FIX 1's flagged section above). Consistent with how the plan was left
   after the live-evidence and relocation rounds per this same file's earlier entries, but noting
   it again here since FIX 4 is a substantial behavior change. Flagging for a decision, not
   expanding scope unilaterally.
2. The `git add tools/claude-skills` -> enumerated-directory rewrite in `docs/implementation-plan.md`
   is a judgment call, not a literal substitution the brief specified: chose to list the four
   actual top-level entries (`codex-review codex-reviewed-dev tests install.ps1`) rather than
   `git add .` (which would also stage `docs/`) or `git add -A` unscoped, to preserve each
   original command's intent (stage the skill source, not the docs) as closely as possible.
3. `tests/live/live-schema-gate.ps1`'s new `Write-LiveEvidence` call is unexercised by any
   executed test in this session (by design -- no live CLI calls were made). Its correctness rests
   on: the isolated direct-call verification in FIX 4 above (which calls `Write-LiveEvidence` with
   the same argument shapes the gate script now uses) and a static parse check of the gate script
   itself. The first real run of `tests/live/live-schema-gate.ps1` will be the actual end-to-end
   proof.
