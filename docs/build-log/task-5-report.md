# Task 5 Report: Process execution layer + premise manifest gate

## Summary

Read `lib.ps1` first, as instructed. Confirmed `Invoke-BoundedProcess` and `Test-BinaryUnchanged`
were already present (pulled forward for Task 2) and left them byte-for-byte untouched. Appended
the six genuinely-missing pieces — `$script:RequiredChildEnv`, `Test-EmbedBudget`,
`Write-NewFileExclusive`, `Get-InvocationProfileHash`, `Test-PremiseManifest`,
`Invoke-CodexProcess` — to `tools/claude-skills/codex-review/scripts/lib.ps1`, and wrote
`tools/claude-skills/tests/test-invoke.ps1`. During implementation I found and fixed a real
crash-vs-fail-closed bug in `Test-PremiseManifest` (details below). All 68 assertions in the new
test file pass; the full suite (138 assertions across 5 files) is green.

**Commit:** `5056a2475550648e8000b5f83cc8307c0238452c` — "feat(codex-review): premise manifest
gate and hermetic Codex process wrapper".

## Process

### Step 0: Read lib.ps1 first

Confirmed present and unmodified-by-me: `Invoke-BoundedProcess`, `Resolve-CliInvocation`,
`Get-CodexCandidates`, `Invoke-Candidate`, `Get-FeatureNames`, `Test-CodexCandidate`,
`Select-CodexCli`, `Test-BinaryUnchanged`, `Get-DisableSet`, `New-CodexArgs`,
`Get-InvocationAudit`, `Test-Verdict`. Confirmed genuinely absent (grepped, zero hits anywhere in
the file before my edit): `Invoke-CodexProcess`, `Test-EmbedBudget`, `Write-NewFileExclusive`,
`Get-InvocationProfileHash`, `Test-PremiseManifest`, `$script:RequiredChildEnv`. No other
function from the brief was already present — nothing else to skip.

### Step 1: Write the failing test — what I kept, skipped, and added

I checked `tests/test-discovery.ps1` (and, for thoroughness, the other three existing test
files) for prior coverage of `Invoke-BoundedProcess`/`Test-BinaryUnchanged` before transcribing
the brief's test:

- **`Invoke-BoundedProcess`**: zero direct references anywhere outside its own definition and
  Task 5's brief. `test-discovery.ps1` only exercises it indirectly through
  `Invoke-Candidate`/`Test-CodexCandidate` on fast, successful fake shims — never a timeout,
  missing-executable, or hung-process path. **Nothing skipped**; every `Invoke-BoundedProcess`-
  and `Invoke-CodexProcess`-related assertion in the brief's Step 1 script exercises genuinely
  new ground and was kept.
- **`Test-BinaryUnchanged`**: exactly one prior assertion, in `test-discovery.ps1`: `"version
  '0.147' does NOT match '0.147.0' (exact equality)"` (correct hash, `Version='0.147'` — a
  *prefix* of the real `'0.147.0'`). The brief's Step 1 script has three `Test-BinaryUnchanged`
  assertions:
  - `"unchanged pin passes"` — the true/pass case; not covered anywhere else. **Kept.**
  - `"version drift alone detected"` (correct hash, `Version='0.148.0'` — an unrelated wrong
    string, not a prefix) — same branch and same outcome as `test-discovery.ps1`'s existing
    assertion (hash check passes, then `$Matches[1] -ceq $PinnedCli.Version` returns false); the
    "prefix vs. exact string" distinction was already the discovery test's own point. **Skipped**,
    noted inline in `test-invoke.ps1` at the skip site.
  - `"content replacement detected"` (tampers the binary's bytes, hash changes) — a different
    code branch (the `Get-FileHash` mismatch `if`, not the version-equality `if`); not covered
    anywhere else. **Kept.**

- **`invoke-codex.ps1`**: grepped the brief's Step 1 test content specifically — zero
  references. Nothing to leave out on that front for this task.

- **Added tests the brief itself never writes.** The brief's own Step 1 script (lines 19-88 of
  `task-5-brief.md`) never once calls `Write-NewFileExclusive`, `Get-InvocationProfileHash`, or
  `Test-PremiseManifest` — despite Step 3 defining all three and the properties list singling
  them out as the parts that matter most. Given `Test-PremiseManifest` is explicitly "a
  fail-closed gate" and the most safety-critical piece of this task, I wrote dedicated coverage
  for all three rather than shipping them untested:
  - `Write-NewFileExclusive`: round-trip + a sequential second-write-throws check, **plus a
    genuine concurrency test** — a sequential check alone cannot distinguish a truly atomic
    `FileMode.CreateNew` implementation from a broken `Test-Path`-then-`Set-Content` one (by the
    second *sequential* call the file already exists on disk either way, so both implementations
    "pass" a sequential test identically). I raced 8 real OS threads (`Start-ThreadJob`, an inbox
    PS7 module) through a shared `ManualResetEventSlim` gate at the same path and asserted
    exactly one survives with uncorrupted content. Verified this has real discriminating power:
    against a deliberately broken TOCTOU implementation in a scratch probe, the same race
    produced 5 "winners" and corrupted, interleaved file content (`writer-1writer-2`); against
    the real `FileMode.CreateNew` implementation, always exactly 1 winner, clean content.
  - `Get-InvocationProfileHash`: determinism, sensitivity to `DisableSet`/`Model`/`Effort`
    changes, and — to directly prove "derived from the FULL canonical array, not a hand-picked
    subset" — shadowed `New-CodexArgs` (same technique `test-composer.ps1` already uses) to
    return a fixed known array and confirmed the hash is exactly SHA-256 of that array joined by
    the unit separator.
  - `Test-PremiseManifest`: ~26 scenarios — golden pass, absent file, malformed JSON, wrong
    version, tokenizer_evidence model mismatch, numeric type/range violations (non-integer,
    zero max-output, negative context window, negative overhead, max-output exceeding context
    window), model mismatch, wrong tokenizer family, staleness (schema/invocation-profile/
    AGENTS.md), **the headline binary-substitution property** (manifest for path A does not
    authorize a round on path B — plus same-path-wrong-version and same-path-wrong-hash
    variants), the budget inequality itself with otherwise-valid fields, and the `-BudgetBytes`
    parameter's effect. Plus 5 crash-regression tests, see below.

### Step 2: Run test to verify it fails

```
pwsh -NoProfile -File tools/claude-skills/tests/test-invoke.ps1
```
Failed as expected: `Invoke-CodexProcess: ... The term 'Invoke-CodexProcess' is not recognized
...`, cascading into a long chain of "variable has not been set" / `PropertyNotFoundException`
errors from `Set-StrictMode -Version Latest` (dot-sourced from `lib.ps1` into the caller's
scope) as soon as later lines touched never-assigned variables. This is also the first live
confirmation, inside the real harness, that strict mode is active throughout the test script —
directly relevant to the bug described next.

### Step 3: Implement — and a bug found via self-review before first commit

Appended the brief's given code for `$script:RequiredChildEnv`, `Test-EmbedBudget`,
`Write-NewFileExclusive`, `Get-InvocationProfileHash`, and `Invoke-CodexProcess` verbatim.

**Before** writing `Test-PremiseManifest`, I verified empirically (scratch probes, not
committed) how `ConvertFrom-Json` output behaves under this file's own `Set-StrictMode -Version
Latest`, because the function's presence checks are hand-written rather than schema-validated:

- JSON whole numbers parse as `[long]`/`Int64` in this pwsh (7.6.3) — confirms the brief's
  `-isnot [int] -and -isnot [long]` type check is correct against real `ConvertFrom-Json` output
  (a naive `-isnot [int]` alone would have rejected every legitimate value).
- **Dotting into a JSON property that is entirely absent from the source (not merely
  present-with-`null`) throws `PropertyNotFoundException`** under strict mode — for both static
  (`$o.c`) and dynamic (`$o.$f`) member access, and the throw propagates straight out of a
  function call rather than being caught by the enclosing `if`. Confirmed with a minimal
  repro before touching `Test-PremiseManifest`'s code at all.
- `ConvertFrom-Json -AsHashtable` does **not** avoid this — dot-notation strict-mode interception
  applies to hashtables too (bracket notation `$h['missing']` would be safe, but that requires
  rewriting virtually every line of the given implementation to bracket syntax).

This means the brief's given field-presence loop (`if ($null -eq $m.$f -or "$($m.$f)" -eq '')
{...}`) **crashes with an uncaught exception instead of returning `Valid=$false`** whenever
`premises.json` is missing a key entirely — which is the single most realistic way a hand-edited
or drifted manifest would actually be malformed (omitting a key, not writing it out as an
explicit `null`). This directly undermines the function's own stated purpose: every other
failure mode in the function is a clean `Reason`-carrying `Valid=$false`, and an uncaught
exception is an inconsistent, undocumented failure mode that can crash whatever script calls the
gate. I found four distinct unguarded access sites (`$m.version`, the 11-field loop, `$m.
tokenizer_evidence` → `$ev`, and `$ev.model` read outside its own sub-field loop), confirmed each
one empirically, then fixed all four with a minimal, well-commented change: backfill every
top-level/evidence-subobject key the function will ever dot into as an explicit `$null` (only
when the key is genuinely absent) immediately after parsing, before any validation runs — so a
wholly-missing key now takes the exact same `"...is missing '$f'"` `Reason` path as a
present-but-empty one, rather than throwing past the caller. Zero lines of the brief's original
validation logic were changed; the fix is purely additive (two small backfill loops).

While verifying that fix I found one more instance of the same theme: `tokenizer_evidence`
provided as a bare scalar (e.g. a JSON string instead of an object) is truthy, so it survives
the `if (-not $ev)` check, but has no real properties to backfill or read — and both before and
after my primary fix, dotting into it throws the same way. Added a one-line type guard
(`$ev -isnot [System.Management.Automation.PSCustomObject]` → clean `Reason`) immediately after
the truthiness check to close this out too, since it's directly adjacent to the bug I'd already
found and the fix is trivial and low-risk.

Both fixes are marked with `# lib.ps1 runs under Set-StrictMode...` comments at their exact
sites in `lib.ps1` so a future reader doesn't mistake the backfill loops for dead code and
"simplify" them back into the bug.

### Step 4: Run test to verify it passes

```
pwsh -NoProfile -File tools/claude-skills/tests/test-invoke.ps1
→ 68 passed, 0 failed
```
Includes all 5 crash-regression assertions (wholly-absent `version`, `cli_path`,
`tokenizer_evidence`, `tokenizer_evidence.statement`, `tokenizer_evidence.model`, plus the
scalar-`tokenizer_evidence` case) passing — each confirms both "does not throw" and "reports
`Valid=$false` with the correct `Reason`", not just one or the other.

Ran the full file 4 times total (once post-implementation, 3 more afterward) to check for
flakiness in the timing-sensitive parts (the timeout tests, the thread-race test) — consistently
`68 passed, 0 failed` every time.

### Step 5: Empirical minimal-environment procedure — intentionally not run

The brief's Step 5 asks for a **live** `codex exec` round (real network I/O, real account) under
the CODEX_HOME-only environment, then recording the result in a new `tools/claude-skills/
README.md`. This is outside the process list I was given for this task (write test → fail →
implement → pass → full suite → commit → self-review → fix), requires a live authenticated
Codex session I wasn't asked to invoke, and the task properties already state the CODEX_HOME-only
contract is "Verified on this machine" as an established premise I could rely on. I did not
perform it and did not create a README.md (would be inventing an undocumented file). No spec
amendment was needed either way, since `$script:RequiredChildEnv` stays `@{}` exactly as given —
nothing was added to it, so the "Failure → add a variable, amend the spec" branch of Step 5
doesn't apply.

### Step 6: Full suite

```
pwsh -NoProfile -File tools/claude-skills/tests/run-tests.ps1
== test-composer.ps1 ==   26 passed, 0 failed
== test-discovery.ps1 ==  22 passed, 0 failed
== test-invoke.ps1 ==     68 passed, 0 failed
== test-policy.ps1 ==     13 passed, 0 failed
== test-schema.ps1 ==      9 passed, 0 failed
ALL TEST FILES PASSED
```
138 total assertions, all green. Tasks 1-4 unaffected.

### Commit

`git rev-parse --show-toplevel` confirmed the worktree root
(`.../worktrees/reusable-spec-plan-review-8fcff9`) before committing; branch
`claude/reusable-spec-plan-review-8fcff9`.

```
git add tools/claude-skills/codex-review/scripts/lib.ps1 tools/claude-skills/tests/test-invoke.ps1
git commit -m "feat(codex-review): premise manifest gate and hermetic Codex process wrapper" ...
```
Result: 2 files changed, 500 insertions(+) — **SHA
`5056a2475550648e8000b5f83cc8307c0238452c`**. `git diff --stat` against the parent commit shows
`lib.ps1` as pure addition (144 insertions, 0 deletions) — confirms `Invoke-BoundedProcess` and
`Test-BinaryUnchanged` are untouched.

## Self-review findings

1. **[Fixed, pre-commit] `Test-PremiseManifest` crashed instead of failing closed on a wholly-
   missing JSON key**, due to `Set-StrictMode -Version Latest` + `PropertyNotFoundException` on
   absent (not merely null) PSCustomObject properties. Described in full under Step 3. Five
   regression tests lock this in; verified each throws under the original brief code (via
   isolated scratch probes reproducing the exact mechanics) and passes cleanly after the fix (via
   the real test file, 3 repeated green runs).
2. **[Fixed, pre-commit] Same theme, one more spot**: `tokenizer_evidence` as a non-object JSON
   scalar. Closed with a one-line type guard; locked in with one more regression test.
3. **Verified, no fix needed**: JSON whole numbers parse as `[long]` in this pwsh version, so the
   brief's `-isnot [int] -and -isnot [long]` numeric check is correct as given — a narrower
   `-isnot [int]` alone would have been a real bug (rejecting every legitimate value), but that's
   not what's in the file.
4. **Verified, no fix needed**: `[pscustomobject]$hashtable` casts are shallow (nested hashtable
   values stay hashtables, not recursively converted), and both dot-notation `get`/`set` and
   `.Remove()` on nested hashtables behave as expected and round-trip correctly through
   `ConvertTo-Json`/`ConvertFrom-Json` — confirmed empirically before relying on this pattern
   across ~15 `Test-PremiseManifest` test scenarios.
5. **Considered, not fixed**: top-level `premises.json` being valid JSON but not an object at all
   (e.g. a bare array or scalar) would still misbehave somewhere in `Test-PremiseManifest`. This
   was equally true of the brief's original code (not a regression), is not a plausible
   real-world shape for a hand-authored config against a documented schema, and isn't called out
   by any task requirement — left as a known, accepted limitation rather than chased further.
6. **No changes needed** to `Invoke-BoundedProcess`, `Test-BinaryUnchanged`,
   `Resolve-CliInvocation`, `New-CodexArgs`, or any other pre-existing function — none were
   touched, confirmed via `git diff --stat` (pure insertions).

## What was skipped and why (summary)

- **Test-BinaryUnchanged "version drift alone detected"** (brief line 83) — skipped from
  `test-invoke.ps1`; same branch/outcome as `test-discovery.ps1`'s existing exact-equality
  assertion. Noted inline in the test file and above.
- **Brief's Step 5 live empirical procedure + `tools/claude-skills/README.md`** — not performed;
  outside the given process list, requires a live authenticated session, and the CODEX_HOME-only
  contract is already given as an established premise for this task.
- **No `invoke-codex.ps1` references found** in the brief's Step 1 test content for this task —
  nothing to leave out on that front.

## Verification checklist

- Worktree root confirmed before commit: `reusable-spec-plan-review-8fcff9` ✓
- `Invoke-BoundedProcess` / `Test-BinaryUnchanged` left byte-identical (pure-insertion diff) ✓
- New test file: 68/68 passing, 4 consecutive full runs with no flakiness ✓
- Full suite: 138/138 passing post-commit ✓
- Working tree clean after commit, on branch `claude/reusable-spec-plan-review-8fcff9` ✓
- Concurrency test verified to have real discriminating power (fails against a deliberately
  broken TOCTOU implementation in a scratch probe; passes against the real one) ✓

## Post-review fix: Int32 overflow in the budget inequality (follow-up task)

**Defect (found in code review).** In `Test-PremiseManifest`, the numeric type check on
`context_window_tokens`, `max_output_tokens`, and `base_overhead_tokens` accepts `[int]` OR
`[long]` — but the final budget inequality then narrowed all three back down with bare `[int]`
casts:
```powershell
$need = $BudgetBytes + [int]$m.base_overhead_tokens + [int]$m.max_output_tokens
$allow = [math]::Floor(0.75 * [int]$m.context_window_tokens)
```
A manifest value that legitimately passes the type check but exceeds Int32 range (e.g.
`context_window_tokens: 3000000000`, which `ConvertFrom-Json` parses as `[long]`) threw an
uncaught `RuntimeException` ("... too large ... for an Int32") instead of returning the
documented `{Valid=$false; Reason=...}` — the same bug class as the missing-key crash fixed
earlier in this same function, and a violation of its fail-CLOSED contract (crash still blocks
the round, so not a security bypass, but an unactionable error for the operator).

**Fix.** `tools/claude-skills/codex-review/scripts/lib.ps1` — widened `$need`/`$allow` to
`[long]` (the multiplicand feeding `[math]::Floor` also cast to `[long]`, so the product is an
exact `[double]`), so the comparison is exact for every value the type check accepts. No other
function touched; no validation decision changed — every manifest that passed or failed before
still does, with the same `Reason`. The only behavior change is crash to clean rejection.

**Tests added** (`tools/claude-skills/tests/test-invoke.ps1`, appended after the existing budget-
inequality tests): three cases, each driving exactly one numeric field past `Int32.MaxValue`
(2147483647) while it remains a valid `[long]`, with companion fields chosen so the manifest
still legitimately fails the 0.75×C inequality afterward (not a synthetic new rejection):
- oversized `context_window_tokens` (2200000000), paired with `max_output_tokens` = 2000000000
  (in-range) so only the context-window cast is exercised.
- oversized `base_overhead_tokens` (3000000000) alone.
- oversized `max_output_tokens` (3000000000), necessarily paired with an oversized
  `context_window_tokens` (3500000000) because the pre-existing "exceeds the context window"
  invariant requires `max_output_tokens <= context_window_tokens` — but in the pre-fix code
  `base_overhead_tokens` casts first in the `$need` statement (small, succeeds) and
  `max_output_tokens` casts second and throws there, one full statement before
  `context_window_tokens`'s cast (in `$allow`, the next line) would ever be attempted, so this
  case still isolates and proves the `max_output_tokens` cast specifically.

Each case asserts both "did not throw" (wrapped in try/catch) and "`Reason` is non-empty".

**Verification evidence.**
```
pwsh -NoProfile -File tools/claude-skills/tests/test-invoke.ps1
74 passed, 0 failed

pwsh -NoProfile -File tools/claude-skills/tests/run-tests.ps1
== test-composer.ps1 ==   26 passed, 0 failed
== test-discovery.ps1 ==  22 passed, 0 failed
== test-invoke.ps1 ==     74 passed, 0 failed
== test-policy.ps1 ==     13 passed, 0 failed
== test-schema.ps1 ==      9 passed, 0 failed
ALL TEST FILES PASSED
```
Test counts: **68 → 74** in `test-invoke.ps1` (+6 = 3 new cases × 2 assertions each); full suite
**138 → 144**, 0 failed both before and after.

**Discrimination proof.** Used `git stash push --keep-index -- .../lib.ps1` to revert only the
fix while keeping the new tests staged, restoring the pre-fix bare-`[int]` casts. Re-ran
`test-invoke.ps1` against that pre-fix code:
```
FAIL: oversized context_window_tokens (valid [long] beyond Int32 range) fails closed rather than throwing
FAIL: oversized context_window_tokens reports Valid=false with a non-empty Reason
FAIL: oversized base_overhead_tokens (valid [long] beyond Int32 range) fails closed rather than throwing
FAIL: oversized base_overhead_tokens reports Valid=false with a non-empty Reason
FAIL: oversized max_output_tokens (valid [long] beyond Int32 range) fails closed rather than throwing
FAIL: oversized max_output_tokens reports Valid=false with a non-empty Reason
68 passed, 6 failed
```
Exactly the 6 new assertions failed (the try/catch in the test itself absorbed the
`RuntimeException`, so the failure surfaced as `Assert-True` failures, not a hard crash of the
test runner) — all 68 pre-existing assertions were unaffected. Then `git stash pop` restored the
fix; `git diff --stat` after popping showed the same two-file, pure-intended diff as before the
stash detour (confirmed via `git diff -- .../lib.ps1`, a 13-line hunk touching only the
`$need`/`$allow` lines and their comment). Re-ran both verification commands post-restore: full
pass as shown above.

**Verification checklist (this fix).**
- Worktree root confirmed before commit: `reusable-spec-plan-review-8fcff9` ✓
- Only `Test-PremiseManifest`'s final inequality touched; no other function in `lib.ps1` modified
  (confirmed via `git diff -- tools/claude-skills/codex-review/scripts/lib.ps1`, single hunk) ✓
- Every pre-existing `Test-PremiseManifest` test (golden path, absent/malformed JSON, strict-mode
  missing-key regressions, numeric type/range, staleness, wrong-binary, original budget-inequality
  cases) still passes unchanged — no validation decision changed ✓
- New tests fail against the pre-fix cast (6/6 fail) and pass against the fix (6/6 pass);
  discriminating power verified via `git stash` round-trip, not asserted ✓
- `test-invoke.ps1`: 74/74 passing. Full suite: 144/144 passing ✓
- Committed as `fae42234a7a6fec27387a99b70c0e3e462e235c7` on
  `claude/reusable-spec-plan-review-8fcff9`; working tree clean after commit ✓
