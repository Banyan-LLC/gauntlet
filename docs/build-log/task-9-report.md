# Task 9 Report: codex-review/SKILL.md

## Status
COMPLETE. SKILL.md created, verified, and committed.

## Frontmatter Verification
PASS: Valid YAML frontmatter with `name: codex-review` and `description` fields confirmed.

## Cross-Check Results

### invoke-codex.ps1 Parameters
All parameters match between SKILL.md and script:
- Mode, PromptFile, StateDir, Round, RepoRoot ✓
- ArtifactPath, ArtifactCommit (doc mode) ✓
- PrNumber, BaseOid, HeadSha (pr mode) ✓
- CarryOverFile (optional, rounds 2+) ✓
- AcceptNewBinary (switch) ✓

### invoke-codex.ps1 Exit Codes
All exit codes present in script and documented in SKILL.md:
- 0 (ok), 10 (budget), 11 (retry once), 12 (environment)
- 13 (pin changed), 14 (round cap/attempts), 16 (ledger) ✓

### publish-review.ps1 Parameters
All parameters match:
- OwnerRepo, Pr, Round, VerdictFile, StateDir, BaseOid, HeadSha ✓

### publish-review.ps1 Exit Codes (via Publish-CodexReview function in lib.ps1)
All codes matched and present:
- 0 (success), 2 (drift), 3 (dismissed), 4 (human flag)
- 5 (transient retry), 11 (invalid), 12 (token) ✓

### lib.ps1 Functions
Get-RecommendationId function confirmed present (line 592) ✓

### Carry-Over Ledger Handling
SKILL.md correctly specifies:
- Ledger passed via `-CarryOverFile` parameter ✓
- Script renders ledger into prompt (not caller) ✓
- Ids derived via Get-RecommendationId ✓
- Ledger validation at exit 16 before Codex runs ✓

## Commit
SHA: bc04a58
Message: "feat(codex-review): SKILL.md protocol with untrusted PR metadata and recovery paths"

## Test Suite
251 tests passed (test-invoke.ps1 has 5 pre-existing failures related to premises.json path env issue, not SKILL.md).
