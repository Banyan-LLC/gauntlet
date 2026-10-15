# Production review process retirement

## Correction

The main review invocation now passes `RequireProcessTreeRetirement` to the existing
owned process runner. The acceptance gate requires `ProcessTreeRetired` to be the
Boolean value `true`, a successful exit, and no runner error before writing a
canonical verdict. The process receipt is still written first, including on failure.
An unconfirmed retirement produces an explicit failed-attempt reason.

The former default runner initialized the retirement flag to `false` and did not
update it after a successful exit. Such a historical receipt neither proves a leak
nor certifies retirement. This change cannot establish retrospective ownership or
change an earlier canonical verdict, attempt, usage record, ledger or round limit.

## Regression coverage

`test-review-retirement.ps1` extracts and executes the actual production call and
acceptance condition with controlled results. It rejects false, null, numeric and
string substitutes for retirement proof, and rejects runner errors even with true
retirement. A harmless local script exercises the existing owned runner without a
model call. Its evidence directory is retained.

The complete fake-review invocation test also requires the accepted review's
immutable process receipt to report actual Boolean retirement and a clean exit.

## Certification and installation

Changes to this invocation invalidate the prior wrapper fingerprint. Calibration,
the live schema gate and the live security battery must pass against the repaired
source in that order before installation. Preserve the prior source and installed
inventories, premises, runtime proofs and failed controls. The renderer protocols,
context profile, output reserve, content limits and review counters are unchanged.

No historical SID review is rerun or reclassified by this correction. Publication,
approval and merge remain separate actions.
