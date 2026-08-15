# Task 1 Report: Scaffolding, schemas, test harness

Status: DONE
Commit: `28f4b20f63d4e27b661be646d755b10c1738955d` — "feat(codex-review): scaffold, dual schemas, PATH-independent test harness"
Branch: `claude/reusable-spec-plan-review-8fcff9`
Worktree: `C:\Users\geoff\Documents\Projects\Banyan\cavu.photo\.claude\worktrees\reusable-spec-plan-review-8fcff9` (confirmed via `git rev-parse --show-toplevel` immediately before committing)

## What was created

Exactly the five files the brief lists, nothing else:

- `tools/claude-skills/codex-review/schemas/verdict.schema.json` — codex-facing schema, transcribed verbatim from the brief's Step 3 code block. Keeps the top-level `if`/`then` clause that downgrades `approve` verdicts to requiring `nit`-only recommendations.
- `tools/claude-skills/codex-review/schemas/verdict.structural.schema.json` — identical to the above **minus the top-level `if`/`then` keys** (and the now-unneeded trailing comma after the `properties` block). Structure and bounds only, no severity coupling.
- `tools/claude-skills/tests/helpers.ps1` — `Assert-True`/`Assert-Eq`/`Assert-Throws`/`Write-TestResult`, plus `New-FakeCodexShim` and `Set-FakeCodexBehavior`, transcribed verbatim from the brief's Step 1 code block.
- `tools/claude-skills/tests/run-tests.ps1` — aggregator that runs every `test-*.ps1` in the directory and fails if any exits non-zero. Verbatim from the brief.
- `tools/claude-skills/tests/test-schema.ps1` — the schema test suite (9 assertions), verbatim from the brief's Step 1 code block.

Confirmed no `lib.ps1` and nothing under `codex-review/scripts/` was created, per the task instructions (Task 1 is schemas + harness only). Confirmed via `git ls-tree` that no `tools/` directory exists anywhere in `main` or `origin/main`, so this is a clean new top-level addition with no collision risk.

## TDD process followed

1. **Wrote the failing test first**: `test-schema.ps1`, `helpers.ps1`, and `run-tests.ps1` were all written before either schema file existed.

2. **Ran it and watched it fail for the right reason**:
   ```
   pwsh -NoProfile -File tools/claude-skills/tests/test-schema.ps1
   ```
   Output: `Get-Content: ... Cannot find path '...\verdict.schema.json' because it does not exist.` and the same for `verdict.structural.schema.json`, followed by a cascade of `Test-Json: ... Cannot validate argument on parameter 'Schema'. The argument is null or empty.` for every assertion line, ending in `0 passed, 0 failed`. This is exactly the "FAIL — schema files missing" the brief expects (the harness's default `$ErrorActionPreference` lets each non-terminating cmdlet error print and the script continue, which is why the process itself still exits 0 with 0/0 — the failure signal here is the error text, not the exit code, and that matches what Step 2 asks to verify).

3. **Wrote both schemas** verbatim per Step 3, structural schema = codex schema minus `if`/`then`.

4. **Ran it again and watched it pass**:
   ```
   pwsh -NoProfile -File tools/claude-skills/tests/test-schema.ps1
   ```
   Output: `9 passed, 0 failed` (exit 0) — exactly the count the brief predicts.

5. **Verified the aggregator**:
   ```
   pwsh -NoProfile -File tools/claude-skills/tests/run-tests.ps1
   ```
   Output:
   ```
   == test-schema.ps1 ==
   9 passed, 0 failed
   ALL TEST FILES PASSED
   ```
   exit 0.

6. **Re-ran both commands a third time after the commit** (to rule out anything the CRLF-on-checkout normalization might disturb — `git add` printed "LF will be replaced by CRLF" warnings for all five files, expected since only `*.sh` is pinned to LF in `.gitattributes` and these are Windows PowerShell/JSON files). Same results both times: `9 passed, 0 failed` and `ALL TEST FILES PASSED`.

7. **Committed** with the exact message from the brief's Step 5: `feat(codex-review): scaffold, dual schemas, PATH-independent test harness`. 5 files changed, 164 insertions, no other files touched. No AI attribution or trailers, per this repo's commit convention in `AGENTS.md`.

## Self-review: what I checked and changed

- Did a line-by-line re-read of all five committed files against the brief's code blocks after writing them — all five matched verbatim. No changes were needed to the harness or schema content itself.
- Confirmed the structural schema really is "identical minus `if`/`then`": diffed it mentally against the codex schema line by line (see `git show HEAD -- tools/claude-skills/codex-review` in the commit) — the only removed content is the trailing `,` after the shared `properties` block and the `if`/`then` object. All five field maxima (`summary` 800, `location` 150, `issue`/`suggestion` 500, `maxItems` 20) match note 4 exactly in both files.
- `New-FakeCodexShim` is exercised by no test in Task 1 itself (only `test-schema.ps1` is required here), but it's load-bearing scaffolding for every later task, so before committing I wrote a throwaway smoke-test script in the scratchpad (not part of the repo) that dot-sources `helpers.ps1` and drives the generated shim directly: `--version`, `login status`, `features list`, `exec --help`, `exec resume --help`, `exec -o <file>` (stdin capture + receipt.json + default verdict payload), unknown-subcommand exit 64, and `Set-FakeCodexBehavior` flipping behavior without touching `shim.cmd`. All 11 assertions passed. Critically, I also drove `shim.cmd` through a `System.Diagnostics.Process` with `EnvironmentVariables.Clear()` (i.e., a genuinely PATH-less/env-less child, matching what "the production runner clears the environment" means in practice) and confirmed `--version` still returned `codex-cli 1.2.3` with exit 0 — i.e., note 5's absolute-`pwsh`-path requirement is not just present in the code, it actually works under the exact failure condition it exists to prevent. No code changes resulted from this check; it's a verification only. The smoke-test script itself was left in the scratchpad directory and was never added to the repo.
- Checked `.gitattributes` and `core.autocrlf` for anything that could mangle the new files — only `*.sh` is pinned to LF, so the `.ps1`/`.json` files fall through to normal `autocrlf=true` handling (LF in the repo, CRLF on checkout), which is correct for Windows PowerShell scripts and doesn't affect `pwsh` execution either way (tests passed identically before and after the commit).
- Checked for a `.editorconfig` or `PSScriptAnalyzer` config that might impose a different convention on this new directory — neither exists in the repo, so there was nothing else to conform to.

Nothing was found that needed fixing. The diff that landed is exactly what was staged.

## Surprises / notes for later tasks

1. **The Step 2 "expected failure" is error-text-based, not exit-code-based.** When both schema files are missing, `test-schema.ps1` itself still exits 0 with "0 passed, 0 failed" printed, because `Get-Content`/`Test-Json`'s parameter-validation errors are non-terminating by default and the script keeps running to `Write-TestResult`. If a future task's tooling (e.g., a CI step) checks `test-schema.ps1`'s exit code alone to detect "schema missing," it won't catch it that way — the missing-file case reads 0/0/exit-0, not a nonzero exit. Worth knowing if anything downstream tries to gate on exit code rather than the passed/failed counts.

2. **A `.cmd` shim invoked under a fully cleared environment prints harmless stderr noise.** Driving `shim.cmd` via `ProcessStartInfo` with `EnvironmentVariables.Clear()` (no `PATH`, no `SystemRoot`, nothing) produces a stray `'DOSKEY' is not recognized as an internal or external command...` line on stderr from `cmd.exe`'s own startup, even though stdout and the exit code are both correct. This is `cmd.exe`'s own behavior when interpreting the `.cmd` file with no environment at all, not a bug in the shim. Any later task's process runner that treats non-empty stderr as a failure signal (instead of checking exit code / parsing stdout / checking the `-o` output file) will misfire on this. Confirmed reproducible on this machine.

3. **`Test-Json`'s `if`/`then` enforcement is real on this machine (pwsh 7.6.3) and the test suite depends on it.** Confirmed both directions: `verdict.schema.json` rejects `approve` + `important`, and `verdict.structural.schema.json` accepts the same payload. This is the exact fork the brief's note 3 called for — a single merged schema would have made the `approve+important REJECTED` assertion silently pass for the wrong reason (or fail outright) since there'd be no separate lenient schema to normalize against in Task 4.

4. **`New-FakeCodexShim`'s `-ResumeHelp` parameter is genuinely inert in Task 1** — nothing in `test-schema.ps1` or the schemas touches it. Per the task instructions this is intentional (the design uses fresh sessions, no `exec resume`), so it was kept exactly as specified rather than "cleaned up." My smoke test did exercise it directly (`exec resume --help` returns `$ResumeHelp`) just to confirm the plumbing works, in case a later task does end up wiring something to it despite the current design.

## Test commands for reference

```
pwsh -NoProfile -File tools/claude-skills/tests/test-schema.ps1
# => 9 passed, 0 failed   (exit 0)

pwsh -NoProfile -File tools/claude-skills/tests/run-tests.ps1
# => == test-schema.ps1 ==
#    9 passed, 0 failed
#    ALL TEST FILES PASSED   (exit 0)
```
