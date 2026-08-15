# Task 7 Report

Status: complete, all green.
Commit: 5d3c355c7c5e2b17408721fbea8ea745f70e2da2, branch claude/reusable-spec-plan-review-8fcff9.
Tests: test-invoke.ps1 141/141 (74 prior + 50 brief + 17 self-review); full suite 272/272
(26+22+141+13+9+61); stable over 3 reruns. lib.ps1 unmodified (git status confirms).

Defects found in the brief's own script (all in invoke-codex.ps1, not lib.ps1), each confirmed
by reverting in isolation and observing the predicted failure, then restoring:
1. Hard ParserError: a bare `$attempt:` inside a double-quoted string parses as a scope-qualified
   variable reference (like `$env:`), failing the ENTIRE script's parse. A sibling line two rows
   above already used the correct `${attempt}:` form. Every test in the file failed until fixed.
2. `(Get-PriorRecommendations ...).Count` with no `@()` around the call site throws
   PropertyNotFoundException under strict mode whenever the result has 0 or 1 items (PowerShell
   unwraps single/empty pipeline results before `.Count` runs) -- the common case (every round 1),
   not an edge case. Broke nearly every scenario in the suite.
3. `harness_dir` was written to state.json only by the final SUCCESS patch, so a round whose first
   attempt failed left nothing to reuse: a retry would silently mint a second harness, and reading
   `harness_dir` back after two failed attempts (the brief's own ATTEMPT CAP test) threw under
   strict mode. Fixed by persisting harness_dir immediately after creation/validation.

Self-review additions (17 tests): the brief's given script never exercises replaying an
already-completed round, or the carry-over ledger gate (every fake shim defaults to zero
recommendations). Added coverage for both, plus a same-round-retry harness-identity check;
each new assertion discrimination-tested by temporarily disabling its guard.

Concerns: none blocking. Corrected the header docstring's stale "15 session-continuity error"
(unused in code) to the actually-implemented "16 carry-over ledger" while transcribing --
doc-only, no behavior change.

---

## Follow-up: pr-mode test coverage (2026-08-10)

Status: complete, all green.
Commit: 78c16cd1f1309c696968a298182387e5491e13bf, branch claude/reusable-spec-plan-review-8fcff9.
Gap (found in code review): invoke-codex.ps1 supports -Mode doc and -Mode pr, but every
entry-level test above exercised doc mode only -- the pr branch (its own required-provenance
gate at line 36, its own attempt-meta field set at lines 201-202) was entirely unverified.
Added a "PR-MODE COVERAGE" section to test-invoke.ps1 (27 new assertions): (1) a golden-path
pr round proving canonical verdict, state, and attempt-meta pr_number/base_oid/head_sha are
recorded while doc mode's artifact_path/artifact_commit are absent (checked via
PSObject.Properties, since Set-StrictMode throws on a direct dot-access to a truly-missing
property); (2) the provenance gate refusing each of -PrNumber/-BaseOid/-HeadSha independently
when the other two are supplied, exit 12, before any pin or process work; (3) the
already-completed-round replay bound (exit 14, nothing mutated) applying identically in pr
mode, reusing the golden-path round's state dir.
Tests: test-invoke.ps1 168/168 (141 prior + 27 new); full suite 299/299 (26+22+168+13+9+61),
up from 272/272. Both `pwsh -NoProfile -File tools/claude-skills/tests/test-invoke.ps1` and
`.../run-tests.ps1` pass.
Implementation defect in pr mode: none. The pr path passed all 27 new assertions on the first
run; invoke-codex.ps1 and lib.ps1 are unmodified (git status confirms only test-invoke.ps1
changed).
Concerns: none. premises.json restored to its pre-run absent state (as found); git status
clean apart from the intended test-invoke.ps1 change.

---

## Follow-up: dual-schema collapse + acceptance-time usage gate (2026-08-15)

Status: complete, all green.
Commit: 9d8ca67, branch claude/reusable-spec-plan-review-8fcff9.

### Change 1 — collapse the dual schema
Evidence: the real API rejects our output schema with `invalid_json_schema: In context=(),
'if' is not permitted` (HTTP 400, before inference); probing established 'if'/'then' is the
ONLY offending keyword. Removed the top-level if/then from verdict.schema.json; confirmed by
`diff` that it is now byte-identical to verdict.structural.schema.json, then deleted the
latter. Renamed Test-Verdict's `-StructuralSchemaPath` to `-SchemaPath` and repointed every
call site (lib.ps1, invoke-codex.ps1, publish-review.ps1, calibrate-premises.ps1,
test-composer.ps1, test-schema.ps1) at the single remaining file. test-schema.ps1 was
rewritten: the old "codex schema REJECTS approve+important" assertion is replaced with
"schema ACCEPTS it structurally" plus a new permanent regression pinning the schema's `if`/
`then` keys absent (guards against the exact defect this change fixes ever silently
regressing). test-composer.ps1 gained a parallel approve+blocking normalization case
alongside the existing approve+important one, both asserting the downgrade in the returned
object AND the returned JSON.

### Change 2 — acceptance-time usage gate
Evidence: the real terminal event is exactly one `{"type":"turn.completed","usage":
{"input_tokens":N,...}}`; real event taxonomy is thread.started, turn.started, item.completed,
turn.completed, error. Added `Get-RunUsage` to lib.ps1 and wired it into invoke-codex.ps1
immediately after the process-success check and before Test-Verdict: requires no top-level
error event, exactly one turn.completed, and a genuine positive-integer usage.input_tokens
(exit 11 on any failure), then separately checks `input_tokens + 128000 <= 787500` (exit 10,
human flag — retrying the identical prompt cannot change its own token count). The usage
result is persisted to a new create-only `round-N-attempt-M-usage.json` (raw event line +
parsed integer), written with `Write-NewFileExclusive`, never folded into the pre-execution
attempt meta. The 50,000-byte preflight (`Test-EmbedBudget`) is now explicitly commented as an
operational input bound only; the formal guarantee is the post-hoc gate.

Updated `New-FakeCodexShim` (helpers.ps1) to emit the real event shape instead of the old
invented `session_created`/`turn_complete` lines, plus `-UsageBehavior`
(no-usage-field/malformed-usage/duplicate-turn-completed/error-event) and `-InputTokens`
fixture controls so every failure mode is genuinely exercised, not merely asserted
unreachable.

**A real bug caught by verification, not by inspection**: after wiring the gate in but before
touching helpers.ps1, the full existing test-invoke.ps1 suite still reported "172 passed, 0
failed" — suspicious, since the OLD shim's `turn_complete` (no dot, no usage) should have
failed every round. Root cause, confirmed by direct repro: `Get-RunUsage`'s `-EventLines` was
declared `[Parameter(Mandatory)][string[]]`, and PowerShell's parameter binder applies an
implicit "no element may be null or an empty string" check to Mandatory string/string[]
parameters specifically. A real process's stdout, once split on newline, always ends in a
trailing empty-string element — so the bind ALWAYS failed, as a NON-terminating error. That
left `$usage` unassigned; the caller's `if (-not $usage.Ok)` then ALSO threw a non-terminating
"variable has not been set" error while evaluating the condition — and PowerShell's response
to an erroring `if`-condition is to skip the entire if-statement (neither branch) and fall
through to the next line, with no exception ever escaping to the caller. The whole gate was a
silent no-op. Fixed by dropping `Mandatory` (verified via `/tmp` probes reproducing each step
before touching the real files). The same latent pattern (Mandatory `[string[]]` parameters)
exists elsewhere in lib.ps1 — `Get-InvocationAudit -CodexArgs`, `Get-DisableSet
-FeatureNames`, `New-CodexArgs -DisableSet` — currently unreachable there since none of those
arrays can legitimately contain an empty-string element today, but worth knowing about if that
ever changes.

**Regression discrimination** (temporarily reverted each guard, ran the real suite, observed
the predicted failure, restored — see the "TEMP REVERT" edits made and undone during this
session; none remain in the diff):
1. Normalization (lib.ps1 `if ($obj.verdict -eq 'approve')` -> `if ($false -and ...)`):
   test-composer.ps1 6/30 failed, exactly the approve+important and approve+blocking
   Downgraded/Normalized-object/Normalized-JSON assertions; structural-validity assertions
   unaffected. Restored, 30/30.
2-4. Usage-gate decision bypassed at the call site (`$usage.Ok = $true; $usage.InputTokens =
   1` right after the `Get-RunUsage` call): test-invoke.ps1 dropped from 206/206 to 179 passed
   / 24 failed — every missing-usage, all three malformed-usage (non-integer/negative/zero),
   duplicate-turn-completed, error-event, AND over-limit/boundary assertions failed cleanly
   (each now got exit 0 instead of 11/10, verdicts wrongly written), plus the two happy-path
   artifact-content assertions caught the forced `InputTokens=1` substitution. Restored,
   206/206.
5. Isolated the budget arithmetic alone (`if (($usage.InputTokens + 128000) -gt 787500)` ->
   `if ($false)`, leaving Get-RunUsage itself untouched): exactly the 4 over-limit/boundary
   assertions failed (199/203), zero collateral on 2-4's assertions — proves the arithmetic
   check is independently load-bearing, not merely riding on Get-RunUsage's Ok flag. Restored,
   206/206.
6. Usage-artifact write disabled (wrapped the `Write-NewFileExclusive` call in `if ($false)`):
   "happy path: usage artifact created" failed immediately, then the script crashed on the
   next line reading the now-nonexistent file (PropertyNotFoundException) — a stronger signal
   than a clean assertion failure, not a weaker one. Restored, 206/206.
7. Swapped the usage-artifact write from `Write-NewFileExclusive` to `Set-Content`: added an
   end-to-end race test first (pre-seed `round-1-attempt-1-usage.json` with sentinel content
   before invoking round 1 — attempt numbering is derived from `-meta.json` files, so this
   doesn't change which attempt number the run computes, and it collides exactly where the
   real write happens). With `Set-Content`, all 3 new assertions failed: exit 0 instead of 14,
   sentinel content silently overwritten, and a canonical verdict wrongly written. Note: the
   simpler direct-second-call assertion added alongside the happy path does NOT discriminate
   this regression (`Write-NewFileExclusive` refuses an existing path regardless of which
   mechanism created it first) — kept as a cheap sanity check, but the race test above is the
   real proof for regression 7. Restored, 206/206.

Tests, run individually per instructions (`pwsh -NoProfile -File tools/claude-skills/tests/
test-<name>.ps1`), before -> after:
composer 26->30 (+4: approve+blocking normalization, object+JSON)
discovery 27->27 (unchanged)
invoke 172->206 (+34: 7 happy-path usage-artifact assertions, 24 failure-mode assertions
  across missing/malformed x3/duplicate/error-event/over-limit+boundary, 3 create-only race
  assertions)
policy 13->13 (unchanged)
publish 51->51 (unchanged)
schema 9->9 (net-same count, but rewritten: dropped 2 now-redundant dual-schema comparisons,
  added 2 permanent if/then-absence regressions, replaced the impossible
  "approve+important REJECTED" assertion)
state 61->61 (unchanged)
Total 359->397, all green, each file run standalone in a fresh pwsh process.

Found wrong in the brief: the opening paragraph says "355 tests green," but the brief's own
itemized baseline (composer 26 + discovery 27 + invoke 172 + policy 13 + publish 51 + schema 9
+ state 61) sums to 359 — which is also what actually measuring the pre-change suite produced.
355 appears to be stale.

Concerns: docs/superpowers/plans/2026-08-09-codex-review-loop.md (the original historical
plan) still describes the old dual-schema design and the old invented
session_created/turn_complete fake event shape verbatim. Left it unedited, consistent with
this codebase's established convention of layering amendments in task reports rather than
rewriting the historical plan doc (mirrors the many pre-existing "self-review fix, see
task-7-report.md" divergences from "the brief's own given script" already in lib.ps1/
invoke-codex.ps1). No GitHub calls made; the real `codex` CLI was never invoked; no
premises.json was created or left behind (confirmed absent both before and after).
