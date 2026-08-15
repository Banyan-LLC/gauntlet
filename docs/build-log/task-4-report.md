# Task 4 Report: Composer, mode-aware exact audit, verdict normalization

## Summary
Implemented `New-CodexArgs`, `Get-InvocationAudit`, and `Test-Verdict`, appended to
`tools/claude-skills/codex-review/scripts/lib.ps1`, with
`tools/claude-skills/tests/test-composer.ps1` written exactly as the brief specifies.
All 24 assertions in the new file pass; the full suite (68 assertions across 4 files) is green.

## Process

### Step 1: Write the failing test
Created `tools/claude-skills/tests/test-composer.ps1` verbatim from the brief (54 lines,
covers the fresh-session shape, the 12-case audit bypass battery, and verdict normalization).

### Step 2: Verify it fails
```
pwsh -NoProfile -File tools/claude-skills/tests/test-composer.ps1
```
Failed as expected: `New-CodexArgs: ... The term 'New-CodexArgs' is not recognized ...` and
`Test-Verdict: ... The term 'Test-Verdict' is not recognized ...`. (Reported "12 passed, 0
failed" at the bottom — those 12 are the `Assert-Throws` cases, which trivially pass because
calling a nonexistent function throws; this is expected noise at this stage, not evidence the
audit logic works yet.)

### Step 3: Implement
Appended the three functions to `lib.ps1` exactly as given in the brief — `New-CodexArgs`,
`Get-InvocationAudit` (two layers: parsed flag/value invariants, then canonical ordinal
rebuild-and-compare via a second call to `New-CodexArgs`), and `Test-Verdict` (structural
validation against `verdict.structural.schema.json`, then in-place mutation of the verdict
object when `approve` carries a non-nit recommendation, then canonical re-serialization).

### Step 4: Verify it passes
```
pwsh -NoProfile -File tools/claude-skills/tests/test-composer.ps1
→ 24 passed, 0 failed
```
Every bypass case in the brief's battery threw as required: wrong `-s` value, wrong `-C`,
wrong `-m`, appended conflicting `-c`, appended `--enable`, appended
`--dangerously-bypass-approvals-and-sandbox`, downgraded reasoning effort, reordered args,
missing `--ignore-user-config`, disable-set mismatch, smuggled `resume` subcommand, and
missing `-s read-only`. **No defect found** — nothing needed weakening or fixing.

### Step 5: Full suite
```
pwsh -NoProfile -File tools/claude-skills/tests/run-tests.ps1
== test-composer.ps1 ==   24 passed, 0 failed
== test-discovery.ps1 ==  22 passed, 0 failed
== test-policy.ps1 ==     13 passed, 0 failed
== test-schema.ps1 ==      9 passed, 0 failed
ALL TEST FILES PASSED
```
Tasks 1-3 unaffected (68 total assertions pass).

### Step 6: Commit
```
git add tools/claude-skills
git commit -m "feat(codex-review): exact mode-aware audit and canonical verdict normalization"
```
`git rev-parse --show-toplevel` confirmed the worktree root
(`.../worktrees/reusable-spec-plan-review-8fcff9`) before committing.
Result: 2 files changed, 159 insertions(+) — **SHA `e7cf2cb9d1446acf5f59d5f37bb0c12ab0e8fb49`**.

## Self-review

Beyond re-running the given battery, I did extra (uncommitted, scratch-only) verification
that Layer 2 is pulling real weight and not redundant with Layer 1:

- Constructed a pure swap of the *values* of two `-c` pairs (same multiset, different
  position) — Layer 1's sorted-multiset comparison cannot see this by design. Layer 2's
  ordinal rebuild caught it: `audit: position 11 differs (canonical
  'model_reasoning_effort="xhigh"', actual 'web_search="disabled"')`.
- Same experiment on the three `--disable` pairs (swap first/last, same multiset) — caught by
  Layer 2: `audit: position 17 differs (canonical 'apps', actual 'shell_tool')`.

This confirms the two-layer design is load-bearing as described, not just passing the given
battery by coincidence: value-multiset checks and positional/ordinal checks each catch cases
the other misses.

I also checked:
- `Test-Verdict` mutates `$obj.verdict` in place (ConvertFrom-Json's PSCustomObject properties
  are writable) and the single-recommendation JSON case (`approve` + one `important`) exercises
  PowerShell's array-vs-scalar pipeline unwrapping — the `@(... | Where-Object ...)` wrapping
  in the brief's implementation handles this correctly regardless of how `ConvertFrom-Json`
  represents a one-element array.
- No other file in the repo yet calls these three functions (only `lib.ps1` and
  `test-composer.ps1` reference them) — this is pure library code, nothing downstream to break.
- Confirmed on this machine (pwsh 7.6.3) `Test-Json` does enforce the draft-07 `if`/`then`
  clause (per `test-schema.ps1`'s existing "approve+important REJECTED" assertion against the
  codex-facing schema), which is exactly why `Test-Verdict` validates against
  `verdict.structural.schema.json` (no `if`/`then`) rather than `verdict.schema.json` — an
  approve+important verdict must reach the mutation step, not be rejected before it can be
  downgraded.

No defects found; no test weakened.

## Notes for later tasks

- **Disable-set ordering is caller-owned.** `Get-InvocationAudit`'s Layer 2 rebuilds the
  canonical array using `-DisableSet $ExpectedDisable` in the *order given*, then requires
  ordinal equality against the actual args. If a future orchestrator (Task 5+) calls
  `Get-DisableSet` once and passes that same array to both `New-CodexArgs -DisableSet` and
  `Get-InvocationAudit -ExpectedDisable`, ordering is automatically consistent (as the test
  battery does). But if it re-derives or reorders the disable list between building the args
  and auditing them, a legitimate invocation would spuriously fail canonical equality even
  though the multiset (Layer 1) matches. Recommend threading a single `Get-DisableSet` result
  through both calls.
- **`New-CodexArgs` determinism is load-bearing for Task 5.** Task 5's
  `Get-InvocationProfileHash` hashes the exact array `New-CodexArgs` returns (joined with
  ``) to bind premises to an invocation profile. Task 4's `New-CodexArgs` is already
  fully deterministic for identical inputs (no timestamps, randomness, or ordering
  dependent on anything but its own parameters), so that binding holds.
- `Test-BinaryUnchanged` in `lib.ps1` is still the Task-3-forward copy noted in the existing
  comment above `Get-DisableSet`'s neighbor; Task 5's brief re-defines it identically. Not
  touched here.

## Verification
- Worktree root confirmed before commit: `reusable-spec-plan-review-8fcff9` ✓
- Test file matches brief exactly ✓
- All 12 audit bypass cases throw ✓ (verified, none needed fixing)
- Verdict normalization mutates the object and JSON identically, raw JSON never leaks ✓
- Full suite green post-commit (68 passed, 0 failed) ✓
- Working tree clean after commit, on branch `claude/reusable-spec-plan-review-8fcff9` ✓

---

## Addendum: layer-discriminating test-coverage fix (follow-up review task)

A code review found the battery above could not distinguish the two layers: every
shipped bypass case is caught by Layer 2 alone, so a future simplification that deleted
Layer 1, or weakened Layer 2 to a multiset comparison, would ship green. This addendum
closes that gap with exactly two new tests in `test-composer.ps1` (no implementation
changes) — essentially promoting the "extra (uncommitted, scratch-only) verification"
from the self-review above into permanent, committed coverage.

**Status:** done.
**Commit SHA:** `19ae635640cdf9cee3dcf4c43a249a6eaa74fc7e` — "Add layer-discriminating
tests for Get-InvocationAudit". Test file only; `git diff --stat` shows
`tools/claude-skills/tests/test-composer.ps1 | 55 +++...`, 1 file changed, 55 insertions(+).

**Test counts:**
- `test-composer.ps1`: 24 passed → 26 passed, 0 failed (+2, exact).
- Full suite (`run-tests.ps1`): composer 26 + discovery 22 + policy 13 + schema 9, all
  green, `ALL TEST FILES PASSED`.

**Tests added (both in `test-composer.ps1`, right after the existing bypass battery):**
- TEST A (Layer 2 discriminator): builds `$r1` via `New-CodexArgs`, transposes the
  *values* of two `-c` occurrences (multiset-identical: same count, same flags, same
  sorted contents, `-` still last), asserts `Get-InvocationAudit` throws.
- TEST B (Layer 1 discriminator): shadows `New-CodexArgs` in-scope (via
  `${function:New-CodexArgs}`) with a variant that emits `-s danger-full-access` instead
  of `-s read-only`, builds args with the shadowed builder (so Layer 2's canonical rebuild
  would agree with the compromised actual array), asserts `Get-InvocationAudit` still
  throws. Original function captured before and restored in `finally`.

**Discrimination proof (temporary weakenings, each followed by `git checkout --` and a
verified `git diff --quiet` clean restore of `lib.ps1`):**
1. Deleted Layer 1 entirely (the whole hard-invariant block, leaving only the Layer 2
   canonical rebuild) → `pwsh test-composer.ps1` → `FAIL: LAYER1: forbidden '-s
   danger-full-access' rejected even though it agrees exactly with a compromised
   canonical builder` — **25 passed, 1 failed**, and it was the only failure (all 25 other
   assertions, including every pre-existing bypass case, still passed via Layer 2 alone —
   confirming the review's premise).
2. Replaced Layer 2's ordinal `for` loop with a sorted-multiset comparison (kept the count
   check) → `pwsh test-composer.ps1` → `FAIL: LAYER2: transposed -c values
   (multiset-identical, order differs) rejected only by canonical ordinal equality` —
   **25 passed, 1 failed**, again the only failure.

Both weakenings were reverted with `git checkout -- tools/claude-skills/codex-review/scripts/lib.ps1`;
`git diff --quiet` confirmed byte-for-byte restoration each time, and the final
`git status --short` before commit showed only `test-composer.ps1` modified.

**Concerns:** none. Each new test fails in isolation for exactly the reason it was
designed to catch, and fails alone (no collateral breakage), which is the strongest
available evidence the two layers are now independently covered.
