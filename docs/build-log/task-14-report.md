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
