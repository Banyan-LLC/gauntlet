# Task 2 Report: CLI discovery, wrapper handling, compatibility probe

Status: DONE (with one documented, justified deviation from the brief's verbatim test text)
Commit: `f101a139c5f42fc9a9576238dfad26de6dd4c2e6` — "feat(codex-review): discovery with wrapper resolution and fail-closed probe"
Branch: `claude/reusable-spec-plan-review-8fcff9`
Worktree: `C:\Users\geoff\Documents\Projects\Banyan\cavu.photo\.claude\worktrees\reusable-spec-plan-review-8fcff9` (confirmed via `git rev-parse --show-toplevel` immediately before committing)

## What was created

- `tools/claude-skills/codex-review/scripts/lib.ps1` (179 lines) — the core library, dot-sourced, no top-level side effects. Contains, in this order:
  1. Header comment, `Set-StrictMode -Version Latest`, `$script:FeatureAllowlist`, `$script:RequiredExecFlags`.
  2. `Invoke-BoundedProcess` — copied verbatim from `task-5-brief.md` Step 3, per the explicit cross-task instruction, placed first per Task 2's own "write Invoke-BoundedProcess first" directive (since `Invoke-Candidate` calls it).
  3. `Resolve-CliInvocation`, `Get-CodexCandidates`, `Invoke-Candidate`, `Get-FeatureNames`, `Test-CodexCandidate`, `Select-CodexCli` — Task 2's own functions, verbatim from `task-2-brief.md` Step 3.
  4. `Test-BinaryUnchanged` — **a second cross-task pull-forward I identified myself**, copied verbatim from `task-5-brief.md` Step 3 (see "Second cross-task dependency" below).
- `tools/claude-skills/tests/test-discovery.ps1` (66 lines) — Task 2's test suite, transcribed verbatim from the brief **except for one two-line fixture fix** (see "Bug found in the brief/plan" below), with an inline comment explaining the fix and citing the corroborating evidence.

## TDD process followed

1. **Wrote the failing test first**: `test-discovery.ps1`, verbatim from the brief.
2. **Ran it and watched it fail for the right reason**:
   ```
   pwsh -NoProfile -File tools/claude-skills/tests/test-discovery.ps1
   ```
   Output ended `3 passed, 9 failed` (exit 1), with every failure traced to `Resolve-CliInvocation`/`Get-CodexCandidates`/`Test-CodexCandidate`/`Select-CodexCli` being unrecognized commands and the initial dot-source itself failing with `Cannot find path '...\lib.ps1'` — exactly "FAIL: lib.ps1 missing" as the brief predicts.
3. **Wrote `lib.ps1`** — Task 2's Step 3 code verbatim, plus `Invoke-BoundedProcess` pulled forward from Task 5 as instructed.
4. **Ran it again**: down to `18 passed, 2 failed` — real logic failures, not missing-code errors: `falls through to passing candidate (expected '...\good\shim.cmd', got '...\old\shim.cmd')` and `exhausted candidates throw` (didn't throw). Investigated (see below), determined the test fixture itself was wrong, fixed it.
5. **Ran it again**: `20 passed, 0 failed`, exit 0.
6. **Ran the full suite**:
   ```
   pwsh -NoProfile -File tools/claude-skills/tests/run-tests.ps1
   ```
   Output:
   ```
   == test-discovery.ps1 ==
   20 passed, 0 failed
   == test-schema.ps1 ==
   9 passed, 0 failed
   ALL TEST FILES PASSED
   ```
   exit 0. Ran twice more for determinism (only the GUID-based temp-dir names in diagnostic output differed between runs); Task 1's `test-schema.ps1` (9/0) is unaffected.
7. **Committed** with the exact message from the brief's Step 5.
8. **Self-reviewed the diff** (see below) and ran additional targeted behavioral smoke tests beyond what Task 2's own suite exercises, since `Invoke-BoundedProcess` is complex, load-bearing infrastructure that later tasks depend on.

## Second cross-task dependency (beyond the one flagged): `Test-BinaryUnchanged`

I was told to pull `Invoke-BoundedProcess` forward from `task-5-brief.md` because `Invoke-Candidate` calls it. While transcribing the test, I found a **second**, unflagged instance of the same problem: the test's final assertion —

```powershell
$pinPrefix = [pscustomobject]@{ Path=$good; Sha256=(Get-FileHash -Algorithm SHA256 $good).Hash.ToLowerInvariant(); Version='0.147' }
Assert-True (-not (Test-BinaryUnchanged -PinnedCli $pinPrefix)) "version '0.147' does NOT match '0.147.0' (exact equality)"
```

calls `Test-BinaryUnchanged`, which is **not defined anywhere in Task 2's own Step 3 code or Interfaces list** — it's only defined in `task-5-brief.md` Step 3. Without it, `test-discovery.ps1` can never reach "all pass, exit 0" as Task 2's own Step 4 requires, no matter what `lib.ps1` contains, since the function simply wouldn't exist.

I pulled it forward too, verbatim, for the same reason and under the same constraint as `Invoke-BoundedProcess`: it depends only on `Invoke-Candidate` (already in Task 2) and builtins (`Get-FileHash`, `Test-Path`), so it does **not** drag in any other part of Task 5 (`Invoke-CodexProcess`, `Test-EmbedBudget`, `Test-PremiseManifest`, `Write-NewFileExclusive`, `Get-InvocationProfileHash`, `$script:RequiredChildEnv` are all absent from `lib.ps1` — confirmed by grep, none of those names appear).

**Byte-for-byte verification**: I extracted both pulled-forward functions from `task-5-brief.md` with `awk` and diffed them against what's in the committed `lib.ps1` — both are exact matches, zero-line diffs. Likewise diffed Task 2's own six functions + constants against `task-2-brief.md`'s Step 3 block — exact match.

**Note for whoever implements Task 5**: `lib.ps1` already contains `Invoke-BoundedProcess` and `Test-BinaryUnchanged`. Task 5's brief says "Modify: lib.ps1 (append)" and its own Step 3 code block re-includes both functions verbatim as part of a larger append. If applied as a blind append, this produces a harmless duplicate function definition for both (PowerShell dot-sourcing simply lets the later definition win; both duplicates would be textually identical, so there's no behavioral difference) — but it's cleaner for Task 5 to check first and only append what's actually new (`$script:RequiredChildEnv`, `Test-EmbedBudget`, `Write-NewFileExclusive`, `Get-InvocationProfileHash`, `Test-PremiseManifest`, `Invoke-CodexProcess`).

## Bug found in the brief (and in the canonical plan document) — fixed in the test fixture

**Symptom**: after implementing `lib.ps1` exactly as specified, two assertions failed:
```
FAIL: falls through to passing candidate (expected '...\good\shim.cmd', got '...\old\shim.cmd')
FAIL: exhausted candidates throw
```

**Root cause**: the test's own fixture is internally contradictory. Three lines apart:
```powershell
$old = New-FakeCodexShim -Dir "$tmp\old" -Version "0.130.0" -ExecHelp $goodExecHelp -ResumeHelp $oldResumeHelp -FeaturesText $features
Assert-True ($null -ne (Test-CodexCandidate -Path $old -AllowWrapper)) "0.130-style binary is acceptable: with fresh sessions its resume-flag gaps are irrelevant"
...
$sel = Select-CodexCli -Candidates @($old, $good) -AllowWrapper
Assert-Eq $sel.Path $good "falls through to passing candidate"          # assumes $old is REJECTED
Assert-Throws { Select-CodexCli -Candidates @($old) -AllowWrapper } "exhausted candidates throw"   # assumes $old is REJECTED
```
Line 2 explicitly asserts `$old` **passes** `Test-CodexCandidate`. `Select-CodexCli` is specified (Interfaces section: *"first passing; throws with per-candidate reasons if none"*) and implemented as plain first-in-list-order iteration over `Test-CodexCandidate` — no version comparison, no preference logic anywhere in the given code. Given `$old` legitimately passes, `Select-CodexCli -Candidates @($old, $good)` **must** return `$old` (it's first and it passes), and `Select-CodexCli -Candidates @($old)` **must** return `$old`, not throw. No implementation consistent with the rest of the spec could satisfy both halves of this fixture simultaneously.

**This is not a misreading on my part** — I verified it three ways before touching anything:
1. Dumped the raw brief bytes with `cat -A` to rule out a transcription artifact on my end — confirmed byte-identical to what I'd transcribed.
2. Traced the verbatim `Test-CodexCandidate`/`Select-CodexCli` code by hand: both are pure functions of `(Path, AllowWrapper)` plus on-disk state that never changes between the two calls on `$old` — there is categorically no way for the same path to pass standalone and fail inside `Select-CodexCli`.
3. Checked the canonical source: `docs/superpowers/plans/2026-08-09-codex-review-loop.md` (line 379-385) has the **identical** contradiction — this isn't a stale extraction, it's in the plan itself. But a **different, later task's** live-battery test in that same plan document (around line 2518-2521) says explicitly:
   > *"With fresh sessions there is no resume probe, so 0.130's resume gaps are irrelevant and it is an acceptable candidate. **Task 2 asserts the same thing — these two must not contradict.**"*

   That independently confirms `$old` passing is the intentional, load-bearing design decision (consistent with the "no resume probe" amendment described throughout the spec), and the two `Select-CodexCli` lines are the actual defect — most likely a leftover from an earlier spec round (before the no-resume-probe amendment) where version-gapped binaries genuinely were rejected, never updated when that rejection was removed.

**Fix applied** (in `test-discovery.ps1` only; `lib.ps1`'s `Test-CodexCandidate`/`Select-CodexCli` are untouched, exact verbatim): swapped `$old` for `$noAllow` — the fixture two lines above that **is** unambiguously, genuinely rejected (missing allowlisted features) — in both the fallthrough and exhaustion assertions. This preserves the test's structural intent (verify `Select-CodexCli` skips a rejected candidate and falls through; verify it throws when the only candidate is rejected) using a fixture that's actually rejected, rather than deleting or weakening the assertions. Added an inline comment in the test file citing this reasoning and the corroborating plan-document quote.

```diff
-$sel = Select-CodexCli -Candidates @($old, $good) -AllowWrapper
+$sel = Select-CodexCli -Candidates @($noAllow, $good) -AllowWrapper
 Assert-Eq $sel.Path $good "falls through to passing candidate"
-Assert-Throws { Select-CodexCli -Candidates @($old) -AllowWrapper } "exhausted candidates throw"
+Assert-Throws { Select-CodexCli -Candidates @($noAllow) -AllowWrapper } "exhausted candidates throw"
```

**Recommendation**: the orchestrator/spec owner should consider fixing this at the source in `docs/superpowers/plans/2026-08-09-codex-review-loop.md` (and the design doc if it has the same test text) so future re-derivations of Task 2 from the plan don't hit the same wall. I did not edit the plan/spec docs myself since that's outside Task 2's stated file list (`lib.ps1` + `test-discovery.ps1` only) and outside my mandate.

## Self-review: additional behavioral verification beyond Task 2's own suite

Task 2's test suite exercises `Invoke-BoundedProcess` only through fast-exiting fake shims — it never hits the timeout/tree-kill path or the cleared-environment stderr path (those are Task 5's `test-invoke.ps1` job). Since I'm the one authoring this function's actual code in the repo, I ran three additional scratchpad-only smoke tests (not committed) for my own confidence, given how much later infrastructure depends on it:

1. **stderr-not-judged, cleared environment** (orchestrator note 3): drove a `.cmd` directly (bypassing `Resolve-CliInvocation`'s `/d` flag, matching Task 1's exact repro) with `-ClearEnvironment`. Reproduced the exact noise Task 1's report documented — `'DOSKEY' is not recognized as an internal or external command, operable program or batch file.` on stderr — and confirmed `ExitCode=0`, `StartFailed=False`, `TimedOut=False`, correct `Stdout` capture, all unaffected by the non-empty stderr. Confirms `Invoke-BoundedProcess` reports stderr but never judges on it, exactly as required.
   - Side note: `Resolve-CliInvocation`'s `/d` flag (disables AutoRun) means the normal discovery/probe path through this codebase likely won't even trigger the DOSKEY noise in practice — it only reproduced when I drove the `.cmd` directly, without `/d`. Worth knowing for Task 5: if `Invoke-CodexProcess`'s hermetic runs go through `Resolve-CliInvocation` (they do), the noise may be rare in practice, but the non-judging behavior holds regardless.
2. **Timeout + tree-kill** (orchestrator note 4): a `slow.cmd` → `slow.ps1` (`Start-Sleep 300`) chain, `-TimeoutSec 3`. Result: `TimedOut=True`, `ExitCode=-1`, returned in ~3.1s. Verified via `Get-CimInstance Win32_Process` that no lingering `pwsh.exe` child remained under the test's temp directory after the kill — `Process.Kill($true)` (tree kill) genuinely killed the whole tree, not just the immediate `cmd.exe` shell.
3. **`Invoke-Candidate` bounded on a hung binary**: same `slow.cmd`, `-TimeoutSec 3` — returned `$null` in ~3.1s, confirming Task 2's own probe path is correctly bounded end-to-end, not just `Invoke-BoundedProcess` in isolation.

All three passed. No code changes resulted from these checks — they're verification only, confirming the copied code behaves as the brief's notes claimed on this machine.

## Verbatim-fidelity verification (mechanical, not eyeballed)

Rather than trust a visual read-through, I extracted the relevant code blocks from both brief files with `awk`/`sed` and ran `diff` against the corresponding ranges of the committed `lib.ps1`:
- Task 2's own code (header, constants, `Resolve-CliInvocation` through `Select-CodexCli`) vs. `task-2-brief.md` Step 3: **zero-line diff**.
- `Invoke-BoundedProcess` vs. `task-5-brief.md` Step 3: **zero-line diff**.
- `Test-BinaryUnchanged` vs. `task-5-brief.md` Step 3: **zero-line diff**.
- `test-discovery.ps1` vs. `task-2-brief.md` Step 1: **exactly the one documented two-line fixture change**, nothing else.

## Encoding / repo hygiene checks

- No BOM on either new file (`xxd` first bytes: `lib.ps1` starts `23 20 6c 69 62...` = `# lib...`; consistent with Task 1's `helpers.ps1` which also has no BOM).
- `file` reports both as UTF-8 text, consistent with Task 1's files.
- `git add tools/claude-skills` staged exactly the two new files (`git status --porcelain` before commit showed only these two paths as untracked; nothing else in the working tree was modified). The usual "LF will be replaced by CRLF" warnings appeared, same as Task 1 — expected, harmless, not pinned to LF in `.gitattributes`.
- `git status` clean after commit; `git log --oneline -5` confirms Task 2's commit sits directly on top of Task 1's (`28f4b20`) with nothing unexpected in between.

## Things confirmed for later tasks

1. **`Test-BinaryUnchanged` and `Invoke-BoundedProcess` already exist in `lib.ps1`** — see the "Second cross-task dependency" section above. Task 5 should check before re-appending.
2. **The `$old`/`Select-CodexCli` fixture bug is real and lives in the canonical plan document too**, not just the extracted brief — see "Bug found in the brief" above, with the exact plan-document line numbers and corroborating quote. If any later task re-derives `test-discovery.ps1` fresh from the plan rather than reusing what's now committed, it will hit the exact same contradiction.
3. **`Invoke-BoundedProcess` never treats stderr as a failure signal** — confirmed both by code inspection (only `ExitCode`/`TimedOut`/`StartFailed` drive caller decisions; `Stderr` is populated but never inspected internally) and by live reproduction of the DOSKEY noise under a cleared environment.
4. **Tree-kill genuinely works** on this machine/PowerShell version (7.6.3): `Process.Kill($true)` leaves no orphaned descendants, confirmed via `Win32_Process` inspection after a real kill, not just absence-of-error.
5. **`Select-CodexCli`'s thrown message lists candidate paths but not per-candidate rejection reasons inline** — the Interfaces section says "throws with per-candidate reasons if none," and the reasons *are* surfaced (via `Write-Verbose`, since `Select-CodexCli` calls `Test-CodexCandidate -Verbose`), but they land on the verbose stream, not embedded in the exception's `.Message` text itself. This is exactly what the given verbatim code does, so I left it unchanged, but a later task/human debugging a real "no CLI found" failure without `-Verbose`/`$VerbosePreference='Continue'` visible will only see candidate paths, not why each one failed. Flagging in case a later task wants the exception text itself to carry reasons.
6. **`-ResumeHelp` remains genuinely inert** in Task 2 too (confirmed: `Test-CodexCandidate` never probes `exec resume --help`), consistent with the orchestrator's note 2 and Task 1's report.

## Test commands for reference

```
pwsh -NoProfile -File tools/claude-skills/tests/test-discovery.ps1
# => 20 passed, 0 failed   (exit 0)

pwsh -NoProfile -File tools/claude-skills/tests/run-tests.ps1
# => == test-discovery.ps1 ==
#    20 passed, 0 failed
#    == test-schema.ps1 ==
#    9 passed, 0 failed
#    ALL TEST FILES PASSED   (exit 0)
```

---

# Fix report: Select-CodexCli exhausted-candidates message drops rejection reasons

Status: DONE
Commit: `8c06809` — "fix(codex-review): surface per-candidate rejection reasons in Select-CodexCli's thrown message"
Branch: `claude/reusable-spec-plan-review-8fcff9`
Worktree: `C:\Users\geoff\Documents\Projects\Banyan\cavu.photo\.claude\worktrees\reusable-spec-plan-review-8fcff9` (confirmed via `git rev-parse --show-toplevel` immediately before committing)

## The defect

Flagged in code review of Task 2 (and self-flagged in this same report's "Things confirmed
for later tasks" item 5): `Select-CodexCli` threw a message listing only candidate *paths*.
The rejection reasons existed only as `Write-Verbose` output inside `Test-CodexCandidate`,
off by default, so an operator hitting "no CLI found" with default settings saw which paths
were tried but nothing about why each one failed. The binding requirement ("fail fast with
the per-candidate probe log and install/login guidance") was not met by the exception text
itself.

## Fix applied

**`tools/claude-skills/codex-review/scripts/lib.ps1`**

1. `Test-CodexCandidate` gained an optional `[ref]$Reason` out-parameter, appended last in
   the param list. At each of the 8 rejection points (WindowsApps path, non-pinnable wrapper,
   `--version`, `login status`, each missing required exec flag, `features list`, unparseable
   features, each missing allowlisted feature), the message is now captured once into a local
   `$m`, passed to the existing `Write-Verbose`/`Write-Warning` call unchanged in effect, and
   also written to `$Reason.Value` when a `[ref]` was supplied (`if ($Reason) { ... }`).
   Callers that don't pass `-Reason` are unaffected — the parameter defaults to `$null` and
   the `if ($Reason)` guard skips the write. No probe logic changed; every branch still
   returns `$null` on rejection or the same `[pscustomobject]` on success, in the same order,
   under the same conditions as before.
2. `Select-CodexCli` now declares `$reason = $null` per loop iteration, passes
   `-Reason ([ref]$reason)` alongside the existing `-AllowWrapper:$AllowWrapper -Verbose`
   passthrough (unaffected by the addition), and accumulates `"$c - $reason"` into a list for
   every rejected candidate. The thrown message is now:
   `"No Codex CLI candidate passed the compatibility probe.`n<path - reason lines>`nRemediation: ..."`
   — one line per candidate, plus the original remediation guidance (Codex desktop app /
   `codex login` / standalone CLI install), unchanged in wording.

**`tools/claude-skills/tests/test-discovery.ps1`**

Added a regression test directly after the existing `Assert-Throws { Select-CodexCli
-Candidates @($noAllow) -AllowWrapper } "exhausted candidates throw"` line. The existing
assertion only proves *something* threw, which would still pass with the defect present.
The new test wraps the same call in `try/catch`, captures `$_.Exception.Message` directly,
and asserts it `.Contains("allowlisted 'enable_request_compression' missing")` — the actual,
specific reason `$noAllow` (a fixture whose only feature is `apps`) is rejected for, since
`enable_request_compression` is the first entry in `$script:FeatureAllowlist` and therefore
the first one the loop reports missing. This candidate is exactly the brief's suggested
example ("a fixture rejected for a missing allowlisted feature").

Confirmed by inspection (not by leaving the repo in a broken state to test it) that this
assertion would have failed under the pre-fix code: the old thrown message was `"No Codex
CLI candidate passed the compatibility probe. Tried: $($Candidates -join '; '). Remediation:
..."`, which contains no feature names at all, so `.Contains(...)` would be `$false`.

## Verification

```
$ pwsh -NoProfile -File tools/claude-skills/tests/test-discovery.ps1
WARNING: Codex candidate '...\good\shim.cmd' is a wrapper, not a pinnable executable. Point CODEX_CLI_PATH at the underlying .exe or install the Codex desktop app.
VERBOSE: reject (allowlisted 'enable_request_compression' missing): ...\na\shim.cmd
VERBOSE: reject (allowlisted 'enable_request_compression' missing): ...\na\shim.cmd
VERBOSE: reject (allowlisted 'enable_request_compression' missing): ...\na\shim.cmd
22 passed, 0 failed
$ echo EXIT=$?
EXIT=0

$ pwsh -NoProfile -File tools/claude-skills/tests/run-tests.ps1
== test-discovery.ps1 ==
...
22 passed, 0 failed
== test-schema.ps1 ==
9 passed, 0 failed
ALL TEST FILES PASSED
$ echo EXIT=$?
EXIT=0
```

20 -> 22 passed in `test-discovery.ps1` (the 2 new assertions); `test-schema.ps1` (Task 1,
unaffected) still 9/0. Both commands exit 0.

## Scope note: unrelated concurrent change in the shared worktree

While preparing to commit, `git status` showed `docs/superpowers/plans/2026-08-09-codex-review-loop.md`
modified, which this fix never touched. Diffing it confirmed it is the `$old`/`$noAllow`
fixture correction that this report's "Bug found in the brief" section recommended fixing
at the source — evidently applied by a different, concurrent step in this same shared
worktree. It was left untouched and unstaged; only `lib.ps1` and `test-discovery.ps1` were
`git add`ed and committed for this fix, verified via `git status --porcelain` immediately
before and after the commit.

## Test commands for reference

```
pwsh -NoProfile -File tools/claude-skills/tests/test-discovery.ps1
# => 22 passed, 0 failed   (exit 0)

pwsh -NoProfile -File tools/claude-skills/tests/run-tests.ps1
# => == test-discovery.ps1 ==
#    22 passed, 0 failed
#    == test-schema.ps1 ==
#    9 passed, 0 failed
#    ALL TEST FILES PASSED   (exit 0)
```

---

# Follow-up: fix shipped defect — login-status probe rejected every authenticated CLI

**Date:** 2026-08-11
**Commit:** c72e82e "Fix codex login-status probe rejecting every authenticated CLI"

## Defect

The real `codex login status` prints "Logged in using ChatGPT" to **STDERR** and exits 0;
stdout is empty (confirmed empirically against the real CLI, outside this fix). In
`lib.ps1`, `Invoke-Candidate` returns only `$r.Stdout`, and `Test-CodexCandidate` did
`if (-not (Invoke-Candidate $Path @('login','status'))) { reject }`. An empty string is
falsy in PowerShell, so a properly logged-in CLI was rejected with "reject (login status)",
and `Select-CodexCli` threw for every real installation — a shipped blocker.

Root cause of why tests missed it: `New-FakeCodexShim` in `tests/helpers.ps1` wrote the
login-status line via `Write-Output` (stdout), an unfaithful fake that let the bug ship green.

## TDD sequence followed

1. **Made the fake faithful.** Changed only the `login status` branch in
   `New-FakeCodexShim` (`tests/helpers.ps1`) to `[Console]::Error.WriteLine(...)` with the
   same `exit 0`, leaving every other subcommand's output untouched.

2. **Confirmed red.** `pwsh -NoProfile -File tools/claude-skills/tests/test-discovery.ps1`
   now failed (exit code 1). Verbatim tail:
   ```
   WARNING: Codex candidate '...\good\shim.cmd' is a wrapper, not a pinnable executable...
   FAIL: wrapper accepted only under the test-only -AllowWrapper
   PropertyNotFoundException: ...test-discovery.ps1:44
     The property 'Version' cannot be found on this object.
   PropertyNotFoundException: ...test-discovery.ps1:45
     The property 'Sha256' cannot be found on this object.
   PropertyNotFoundException: ...test-discovery.ps1:46
     The property 'FeatureNames' cannot be found on this object.
   FAIL: 0.130-style binary is acceptable: with fresh sessions its resume-flag gaps are irrelevant
   VERBOSE: reject (login status): ...\na\shim.cmd
   VERBOSE: reject (login status): ...\good\shim.cmd
   Exception: ...lib.ps1:182
     No Codex CLI candidate passed the compatibility probe.
     ...\na\shim.cmd - reject (login status): ...\na\shim.cmd
     ...\good\shim.cmd - reject (login status): ...\good\shim.cmd
     Remediation: open the Codex desktop app, run 'codex login', or install the standalone CLI.
   ```
   This is the demonstration that the unfaithful fake was masking the real bug: once the fake
   matched reality (empty stdout, stderr-only), `Test-CodexCandidate` rejected every candidate
   at the login-status check, cascading into property-not-found errors on the now-`$null`
   result and finally an uncaught `Select-CodexCli` throw that aborted the script.
   `test-invoke.ps1` was independently confirmed broken too (same root cause, via
   `Set-TestManifest`'s direct `Test-CodexCandidate` call): it silently truncated to 74/168
   assertions with a `PropertyNotFoundException` on `$probe.Path`, though it happened to still
   exit 0 (0 of the 74 executed assertions themselves failed) — the required, unambiguous
   red signal is `test-discovery.ps1`'s failure above.

3. **Fixed the probe.** Added `Test-CandidateExitsZero` to `lib.ps1` as a sibling of
   `Invoke-Candidate` — same error handling (missing path, unresolvable wrapper, timeout,
   non-zero exit all count as failure) but it returns a bool judged purely on
   `$r.ExitCode -eq 0`, never on stdout content. `Test-CodexCandidate`'s login-status check
   now calls this instead of the stdout-truthiness check on `Invoke-Candidate`.
   `Invoke-Candidate` itself, `Test-BinaryUnchanged`, and the three probes that legitimately
   parse stdout (`--version` → `codex-cli <v>`, `exec --help` → required-flags scan,
   `features list` → row parsing) are byte-for-byte unchanged — stderr is never blended into
   what they parse.

4. **Confirmed green.** `test-discovery.ps1` → 22 passed, 0 failed (rejection reasons for
   `$noAllow` correctly shifted back to "allowlisted 'enable_request_compression' missing").
   `test-invoke.ps1` → 168 passed, 0 failed (full run, no truncation).

5. **Added the regression** (in `test-discovery.ps1`, after the version-equality assertion):
   a fake CLI (`New-FakeCodexShim` unchanged, now inherently faithful) is probed at the raw
   `Invoke-BoundedProcess` level to assert `ExitCode -eq 0`, `Stdout -eq ''`, and
   `Stderr -match 'Logged in'`, then asserted **ACCEPTED** by `Test-CodexCandidate`. A second
   fake, built via a new `-LoginStatusExitCode 1` parameter added to `New-FakeCodexShim`
   (default `0`, so every other existing call site is unaffected), is asserted **REJECTED**.
   Both required assertions ("empty stdout accepted" and "nonzero exit rejected") are present.

## Verification (exact commands, real output)

```
pwsh -NoProfile -File tools/claude-skills/tests/test-discovery.ps1
pwsh -NoProfile -File tools/claude-skills/tests/test-composer.ps1
pwsh -NoProfile -File tools/claude-skills/tests/test-policy.ps1
pwsh -NoProfile -File tools/claude-skills/tests/test-schema.ps1
pwsh -NoProfile -File tools/claude-skills/tests/test-state.ps1
pwsh -NoProfile -File tools/claude-skills/tests/test-invoke.ps1
pwsh -NoProfile -File tools/claude-skills/tests/test-publish.ps1
```

| Suite      | Before (baseline, confirmed) | After fix |
|------------|-------------------------------|-----------|
| composer   | 26 passed, 0 failed           | 26 passed, 0 failed |
| discovery  | 22 passed, 0 failed           | 27 passed, 0 failed (+5 regression) |
| invoke     | 168 passed, 0 failed          | 168 passed, 0 failed |
| policy     | 13 passed, 0 failed           | 13 passed, 0 failed |
| publish    | 51 passed, 0 failed           | 51 passed, 0 failed |
| schema     | 9 passed, 0 failed            | 9 passed, 0 failed |
| state      | 61 passed, 0 failed           | 61 passed, 0 failed |
| **Total**  | **350 passed, 0 failed**      | **355 passed, 0 failed** |

Between steps 1 and 3 (fake fixed, probe not yet fixed): `test-discovery.ps1` exited 1 with
the failures/exception quoted in step 2 above; `test-invoke.ps1` exited 0 but only executed
74/168 assertions (silent truncation via a non-terminating `PropertyNotFoundException`) —
recorded as supporting evidence of the same root cause, not as the primary red signal.

## Files changed

- `tools/claude-skills/tests/helpers.ps1` — `New-FakeCodexShim`: `login status` now writes
  to stderr (was stdout); added `-LoginStatusExitCode` param (default 0, additive/backward
  compatible).
- `tools/claude-skills/codex-review/scripts/lib.ps1` — added `Test-CandidateExitsZero`;
  `Test-CodexCandidate`'s login-status check now uses it instead of `Invoke-Candidate`
  stdout truthiness.
- `tools/claude-skills/tests/test-discovery.ps1` — added the accept/reject regression
  pinning the real contract.

## Concerns / follow-ups

- None outstanding for this fix. The three stdout-parsing probes and `Test-BinaryUnchanged`
  were deliberately left untouched to keep blast radius minimal, and were re-verified green.
- Per this task's constraints, the real `codex` CLI was not invoked and no network/GitHub
  calls were made; the fix and its tests are entirely process-mock-based (`New-FakeCodexShim`
  + raw `Invoke-BoundedProcess` assertions), consistent with the rest of this test suite.
