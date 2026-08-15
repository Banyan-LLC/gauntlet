# Task 6 Report

Status: complete, all green.
Commits: 7c82fe7 (impl), 8063992 (self-review fix), branch claude/reusable-spec-plan-review-8fcff9.
Tests: test-state.ps1 55/55; full suite 199/199 (144 prior + 55 new); stable over 3 reruns.
Already-present: none of Task 6's 10 functions pre-existed (grep-confirmed); nothing skipped.
Defect 1 (required fix to reach green): Test-CarryOverLedger dotted into caller-supplied ledger
JSON with no existence checks; under StrictMode this throws on any wholly-absent key. The
brief's OWN test crashed against the brief's OWN code (missing 'reason' on non-addressed
entries, and on the render test) -- non-terminating there, so it silently dropped rendered
output instead of crashing loudly. Fixed: backfill every dotted key to $null when absent, plus
a safe `-as [int]` round cast. 20 new regression tests, each proven to fail pre-fix.
Defect 2 (self-review, not brief-flagged): Assert-HarnessSafe's StartsWith() boundary checks
lacked a trailing separator, so sibling dir "harness-evil-X" was wrongly read as inside
"harness". Fixed with a Test-PathUnderRoot helper; 1 discrimination-proven regression test.
Concerns: none blocking.

## Follow-up: sibling-prefix migration + ordinal ledger comparison

Status: complete, all green.
Commit: e66538f (both fixes + regression tests), branch claude/reusable-spec-plan-review-8fcff9.
Tests: test-state.ps1 55/55 -> 61/61 (+6); full suite 199/199 -> 205/205 (+6). Both required
commands (`test-state.ps1`, `run-tests.ps1`) run clean.
Fix 1: `Get-StateDir`'s own escape check (near line 548) still used bare `$dir.StartsWith(...)`,
never migrated when `Test-PathUnderRoot` was introduced for `Assert-HarnessSafe`. Migrated to
`Test-PathUnderRoot`. Confirmed unreachable through `Get-StateDir`'s public parameters (topic/
date/phase regexes forbid `.`/`/`/`\`; owner-repo slash-flattening always leaves a `-` where the
regex's one required `/` was, so the flattened segment can never collapse to a literal `..`/`.`
token) -- so $dir is always a true descendant of $root today, exactly as the brief predicted. No
validator was relaxed to reach it. Regression test instead calls `Test-PathUnderRoot` directly
with root/path values shaped like `Get-StateDir`'s own doc-mode root (`docs\superpowers\reviews`
vs a sibling `reviews-evil\...` dir) -- "the helper's use", per the brief -- plus a sanity-pin
assertion that the sibling does share the root as a raw string prefix (i.e. the pre-fix bare
`StartsWith` would have wrongly accepted it).
Fix 2: `Test-CarryOverLedger`'s severity/location/issue/suggestion comparison used `-ceq`/`-cne`
(case-sensitive but culture-aware/InvariantCulture, not ordinal). Empirically confirmed:
`([string]([char]0x00E9)) -ceq ("e"+[string]([char]0x0301))` -> `True` despite different byte
lengths (1 char vs 2). Switched all four comparisons to `[string]::Equals(...,
[StringComparison]::Ordinal)`. Regression test builds a canonical verdict with a precomposed
'é' (U+00E9) in `location`, then a ledger entry claiming 'addressed' with the combining form
('e'+U+0301) substituted in that same field -- fully reachable end-to-end through
`Test-CarryOverLedger`'s public API (StateDir/Round/LedgerPath), no reachability caveat needed.
Discrimination (both performed by hand -- temporarily edit, rerun, observe, revert, rerun):
(a) Fix 2 -- restored the old `-cne` form in lib.ps1, reran `test-state.ps1`: the new unicode
test failed with "a precomposed-vs-combining-character substitution ... in 'location' is
REJECTED, not waved through as verbatim" (60/61, 1 FAIL). Restored the fix: 61/61 again.
(b) Fix 1 -- restoring `Get-StateDir`'s old bare-`StartsWith` line alone left all 61 tests
passing (empirically confirms the unreachability claim above -- the new test doesn't route
through `Get-StateDir`, so this revert alone proves nothing by itself). To get a genuine
discrimination signal, additionally swapped the TEST's own assertion from `Test-PathUnderRoot`
to the bare `.StartsWith()` pattern: that failed as expected ("Get-StateDir's escape check
(Test-PathUnderRoot) rejects a sibling directory..." , 60/61, 1 FAIL). Both lib.ps1 and the test
were restored to the committed fix; `git diff` after restoring showed exactly the two intended
hunks each time (verified before committing).
Concerns: none blocking. Fix 1's regression test necessarily exercises the shared
`Test-PathUnderRoot` helper rather than `Get-StateDir` end-to-end, because the escape it guards
against is provably unreachable through today's validators (as the brief anticipated) -- flagged
here transparently rather than relaxing any validator to force reachability.
