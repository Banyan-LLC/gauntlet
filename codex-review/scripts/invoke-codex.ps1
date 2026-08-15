#Requires -Version 7
<# codex-review: run ONE hermetic review round (one ATTEMPT of one logical round).
   Exit codes are defined once in the plan's contracts section; this comment is the short form.
   0 ok
   | 10 budget -- EITHER the preflight byte estimate is over budget BEFORE anything runs, OR
     (acceptance-time usage gate, added: real-CLI evidence, see task-7-report.md) the CLI's OWN
     reported usage.input_tokens leaves under 25% context headroom after a round completed.
     Retrying the identical prompt cannot change its own token count, so this is a human flag,
     never a retryable failure.
   | 11 failed attempt (ONE retry allowed) -- process failure, invalid verdict, OR (acceptance-
     time usage gate) an unusable usage report: missing/malformed/duplicated usage, or a
     top-level error event in the run's event stream.
   | 12 environment (CLI/token/harness)
   | 13 pin changed or missing (re-invoke same round with -AcceptNewBinary)
   | 14 round cap OR attempts exhausted, state flagged | 16 carry-over ledger required/invalid #>
param(
    [Parameter(Mandatory)][ValidateSet('doc','pr')][string]$Mode,
    [Parameter(Mandatory)][string]$PromptFile,
    [Parameter(Mandatory)][string]$StateDir,
    [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$Round,
    [Parameter(Mandatory)][string]$RepoRoot,
    # Provenance — required so an attempt record identifies exactly WHAT was reviewed.
    [string]$ArtifactPath,          # doc mode (required)
    [string]$ArtifactCommit,        # doc mode (required)
    [int]$PrNumber,                 # pr mode (required)
    [string]$BaseOid,               # pr mode (required)
    [string]$HeadSha,               # pr mode (required)
    [string]$CarryOverFile,         # required for round > 1 (validated ledger; see Test-CarryOverLedger)
    [switch]$AcceptNewBinary,       # re-probe and re-pin after exit 13, same round number
    [ValidateRange(1, 100)][int]$RoundCap = 10,
    [ValidateRange(1024, 10000000)][int]$BudgetBytes = 50000,
    [ValidateRange(1, 86400)][int]$TimeoutSec = 1800,
    [string]$CliPathOverride        # TEST-ONLY; also the only way a wrapper may be pinned
)
# Exactly one retry. Not a parameter at any level: a public override — even one labelled
# "test-only" — is still a public override, and the bounded-loop invariant must not be
# reachable from a caller. Tests exercise the bound by invoking three times.
$MaxAttempts = 2
. "$PSScriptRoot\lib.ps1"
# Single schema now (see task-7-report.md): the codex-facing generation schema and the local
# structural-validation schema used to be two files differing only in a top-level if/then that
# the real API rejects outright. They are identical once if/then is removed, so one file now
# serves both --output-schema (below) and Test-Verdict's structural check.
$schemaPath = "$PSScriptRoot\..\schemas\verdict.schema.json"
New-Item -ItemType Directory -Force $StateDir | Out-Null

if ($Mode -eq 'doc' -and -not ($ArtifactPath -and $ArtifactCommit)) { Write-Error "doc mode requires -ArtifactPath and -ArtifactCommit"; exit 12 }
if ($Mode -eq 'pr' -and -not ($PrNumber -and $BaseOid -and $HeadSha)) { Write-Error "pr mode requires -PrNumber, -BaseOid, -HeadSha"; exit 12 }

# --- BOUNDS FIRST. Both caps are checked before any probe, pin, harness, or process work, so a
#     refused invocation launches nothing and leaves pin/harness state untouched.
if ($Round -gt $RoundCap) {
    Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="round cap $RoundCap reached at round $Round" }
    Write-Error "HUMAN FLAG: round cap $RoundCap reached."
    exit 14
}
# A completed round is FINISHED. Re-invoking it would consume an attempt and, worse, rewrite
# the canonical verdict that every later round's recommendation ids are derived from - silently
# invalidating the carry-over ledger of every subsequent round. State is deliberately left
# UNTOUCHED here (unlike the genuine bound-exhaustion cases below): the round already completed
# successfully, so state.json already correctly reflects that outcome, and stamping it 'flagged'
# would overwrite a true 'approved'/'in_review' result with a misleading one over a replay that
# is the CALLER's mistake, not a new failure of the review itself.
$canonicalVerdict = Join-Path $StateDir "round-$Round-verdict.json"
if (Test-Path $canonicalVerdict) {
    Write-Error "Round $Round already completed successfully; its canonical verdict is immutable. Advance to round $($Round + 1)."
    exit 14
}
$priorAttempts = @(Get-ChildItem $StateDir -Filter "round-$Round-attempt-*-meta.json" -ErrorAction SilentlyContinue).Count
$attempt = $priorAttempts + 1
if ($attempt -gt $MaxAttempts) {
    Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="round $Round exhausted $MaxAttempts attempts" }
    Write-Error "HUMAN FLAG: round $Round already used $priorAttempts of $MaxAttempts allowed attempts."
    exit 14
}

# --- Carry-over ledger. Fresh sessions carry no memory, so for round > 1 continuity is a
#     VALIDATED artifact, not prose: every prior recommendation exactly once, verbatim, with
#     a status and a reason where the status is not 'addressed'. Validated before any process
#     runs, and the script — not the caller — renders it into the payload.
$carryText = ''
$carrySha = $null
# @(...) around the call, NOT just around $out inside the function -- self-review fix (see
# task-7-report.md). Get-PriorRecommendations already does `return @($out)` internally, but
# PowerShell's pipeline still unwraps a 0-item result to $null and a 1-item result to a bare
# scalar when the caller captures it with plain assignment; only wrapping the CALL SITE in
# @(...) reliably forces array semantics for 0/1/many. Confirmed empirically: with the bare
# form, `(Get-PriorRecommendations ...).Count` throws PropertyNotFoundException under
# Set-StrictMode -Version Latest (inherited from dot-sourcing lib.ps1) on every round with zero
# prior recommendations -- i.e. every round 1, and most later rounds in this test file, since
# the fake shim's default verdict carries none. That is the common case, not an edge case, so
# the brief's own given line failed nearly every scenario in this suite.
$priorCount = @(Get-PriorRecommendations -StateDir $StateDir -UpToRound $Round).Count
if ($priorCount -gt 0) {
    if (-not $CarryOverFile) {
        Write-Error "Round $Round has $priorCount prior recommendation(s); -CarryOverFile is required so none can be silently dropped."
        exit 16
    }
    $ledger = Test-CarryOverLedger -StateDir $StateDir -Round $Round -LedgerPath $CarryOverFile
    if (-not $ledger.Valid) {
        Write-RoundState -StateDir $StateDir -Patch @{ status='failed_attempt'; failure_reason="carry-over: $($ledger.Reason)" }
        Write-Error "Carry-over ledger rejected: $($ledger.Reason)"
        exit 16
    }
    $carryText = ConvertTo-CarryOverText -Entries $ledger.Entries
    # Hash the RENDERED text — that is literally what the reviewer was shown. The source file is
    # caller-owned and may be edited or deleted afterwards, so a hash of it proves nothing later.
    $carrySha = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [Text.Encoding]::UTF8.GetBytes($carryText)) | ForEach-Object { $_.ToString('x2') })
}

$promptBody = Get-Content -Raw -Encoding utf8 $PromptFile
$prompt = $carryText + $promptBody
# This 50,000-byte preflight is an OPERATIONAL INPUT BOUND ONLY -- a cheap, local, BEFORE-the-
# round estimate from the prompt's own byte count. It is NOT the formal guarantee (added: real-
# CLI evidence, see task-7-report.md) and does not promise an oversized request is never
# attempted: bytes only bound tokens from above, and CLI-side overhead is not visible here. The
# formal guarantee is enforced AFTER the round runs, at the acceptance-time usage gate near the
# canonical verdict write below: a completed review is accepted and publishable only when the
# real CLI itself reported at least 25% context headroom (see Get-RunUsage in lib.ps1).
$budget = Test-EmbedBudget -PromptText $prompt -BudgetBytes $BudgetBytes
if (-not $budget.Ok) {
    Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="embed budget: $($budget.Bytes) > $BudgetBytes bytes" }
    Write-Error "HUMAN FLAG: prompt is $($budget.Bytes) bytes (budget $BudgetBytes). No round ran. Never truncate."
    exit 10
}

# --- Binary pin (see the pin transition table). Every round is a fresh session, so the only
#     cross-round continuity is the pinned binary and the harness.
$pinFile = Join-Path $StateDir 'cli-pin.json'
$pin = if (Test-Path $pinFile) { Get-Content -Raw $pinFile | ConvertFrom-Json } else { $null }
$repin = $AcceptNewBinary -or ($Round -eq 1 -and -not $pin)

if (-not $repin) {
    if (-not $pin) { Write-Error "No cli-pin.json for round $Round. Re-invoke the SAME round with -AcceptNewBinary."; exit 13 }
    if (-not (Test-BinaryUnchanged -PinnedCli $pin)) { Write-Error "Pinned CLI changed (path/hash/version). Re-invoke the SAME round with -AcceptNewBinary; history and round number are kept."; exit 13 }
    # Run the PINNED binary. Re-selecting candidates here could silently swap the reviewer
    # mid-loop whenever discovery order changes (a new hashed dir sorts newer).
    $cli = Test-CodexCandidate -Path $pin.Path -AllowWrapper:([bool]$CliPathOverride)
    if (-not $cli) { Write-Error "Pinned CLI at $($pin.Path) no longer passes the compatibility probe. Re-invoke with -AcceptNewBinary."; exit 13 }
} else {
    try {
        $candidates = if ($CliPathOverride) { @($CliPathOverride) } else { Get-CodexCandidates }
        $cli = Select-CodexCli -Candidates $candidates -AllowWrapper:([bool]$CliPathOverride)
    } catch {
        Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="CLI probe: $($_.Exception.Message)" }
        Write-Error $_.Exception.Message; exit 12
    }
    @{ Path=$cli.Path; Sha256=$cli.Sha256; Version=$cli.Version } | ConvertTo-Json | Set-Content $pinFile -Encoding utf8
}

$disable = Get-DisableSet -FeatureNames $cli.FeatureNames

# --- Premise manifest gate, AFTER selection so it binds the binary that will actually run.
#     Validating the path the manifest names would let a manifest for A authorize a review
#     executed by B. There is no bypass switch: calibration is a separate entry point
#     (calibrate-premises.ps1), not a flag on the production path.
$profileHash = Get-InvocationProfileHash -DisableSet $disable
$manifest = Test-PremiseManifest -SkillRoot (Split-Path $PSScriptRoot -Parent) -ActualCli $cli `
    -InvocationProfileHash $profileHash
if (-not $manifest.Valid) {
    Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="premise manifest: $($manifest.Reason)" }
    Write-Error "HUMAN FLAG: $($manifest.Reason). Run calibrate-premises.ps1 to record or refresh premises.json."
    exit 12
}

$prev = if (Test-Path (Join-Path $StateDir 'state.json')) { Read-RoundState -StateDir $StateDir } else { $null }

# --- Harness. Created once per loop; thereafter ONLY the recorded path is reused, always
#     verified clean. A vanished harness is an environment fault: silently provisioning another
#     would hide that the loop's working root changed under it, and the harness is the one
#     directory whose emptiness the hermeticity argument depends on.
try {
    $recorded = if ($prev -and $prev.PSObject.Properties['harness_dir']) { $prev.harness_dir } else { $null }
    if ($recorded) {
        # Reuse ONLY the recorded path, always re-validated. A vanished harness is an
        # environment fault, not something to paper over by silently provisioning another.
        if (-not (Test-Path $recorded)) { throw "recorded harness '$recorded' is missing" }
        $harness = Assert-HarnessSafe -Dir $recorded -RepoRoot $RepoRoot
    } else {
        $harness = New-HarnessDir -RepoRoot $RepoRoot
    }
} catch {
    Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="harness: $($_.Exception.Message)" }
    Write-Error "HUMAN FLAG: $($_.Exception.Message)"; exit 12
}
# Record the harness IMMEDIATELY, not only after a successful attempt. Self-review fix (see
# task-7-report.md): the brief's own script recorded harness_dir ONLY in the final success
# patch at the bottom of this file. If attempt 1 of a round fails (invalid verdict / process
# failure / timeout), that patch is never reached, so state.json never gains a 'harness_dir'
# property. Two consequences, both real: (a) attempt 2's reuse check
# ($prev.PSObject.Properties['harness_dir']) would then find nothing to reuse and silently
# mint a SECOND harness for the same round, defeating "created once per loop, thereafter
# reused"; (b) lib.ps1 runs under Set-StrictMode -Version Latest, which this script inherits
# from dot-sourcing it — a caller (or this suite's own ATTEMPT CAP test) that reads
# `(Read-RoundState -StateDir $StateDir).harness_dir` after two failed attempts and no
# success would hit PropertyNotFoundException, an uncaught crash, not a clean read. Recording
# right after the harness is created/re-validated — before Codex ever runs — closes both gaps
# while still being idempotent with the success patch below (same $harness value either way).
Write-RoundState -StateDir $StateDir -Patch @{ harness_dir=$harness }

$stem = "round-$Round-attempt-$attempt"
$rawPath = Join-Path $StateDir "$stem-verdict.raw.json"

$codexArgs = New-CodexArgs -HarnessDir $harness -SchemaPath $schemaPath -VerdictPath $rawPath -DisableSet $disable
$audit = Get-InvocationAudit -CodexArgs $codexArgs -HarnessDir $harness `
    -SchemaPath $schemaPath -VerdictPath $rawPath -ExpectedDisable $disable

$shaOf = { param($t) -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($t)) | ForEach-Object { $_.ToString('x2') }) }
$meta = @{
    round=$Round; attempt=$attempt; mode=$Mode
    # Three separate hashes: the whole payload alone would make the carry-over unauditable,
    # since a changed prompt body and a dropped finding are indistinguishable in one digest.
    prompt_sha256=(& $shaOf $prompt); prompt_body_sha256=(& $shaOf $promptBody)
    carryover_rendered_sha256=$carrySha; carryover_source_file=$CarryOverFile; carryover_entries=$priorCount
    prompt_bytes=$budget.Bytes; audit=$audit; harness_dir=$harness
    cli_path=$cli.Path; cli_sha256=$cli.Sha256; cli_version=$cli.Version
    timestamp=(Get-Date -AsUTC -Format o)
}
if ($Mode -eq 'doc') { $meta.artifact_path = $ArtifactPath; $meta.artifact_commit = $ArtifactCommit }
else { $meta.pr_number = $PrNumber; $meta.base_oid = $BaseOid; $meta.head_sha = $HeadSha }
Write-AttemptMeta -StateDir $StateDir -Round $Round -Attempt $attempt -Meta $meta
# Persist what the reviewer actually received, under our own control: the normalized ledger and
# the exact rendered carry-over. The caller's ledger file can change or vanish; these cannot.
if ($carryText) {
    [System.IO.File]::WriteAllText((Join-Path $StateDir "$stem-carryover.json"),
        ($ledger.Entries | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    # WriteAllText, NOT Set-Content: $carryText already ends in a newline and Set-Content would
    # append another, so the persisted file would not hash to carryover_rendered_sha256 or match
    # the bytes actually sent to Codex - defeating the point of persisting it.
    [System.IO.File]::WriteAllText((Join-Path $StateDir "$stem-carryover.txt"),
        $carryText, [Text.UTF8Encoding]::new($false))
}

$run = Invoke-CodexProcess -CliPath $cli.Path -CodexArgs $codexArgs -PromptText $prompt -HarnessDir $harness -TimeoutSec $TimeoutSec
$run.StdoutLines | Set-Content -Path (Join-Path $StateDir "$stem-events.jsonl") -Encoding utf8
if ($run.StartFailed -or $run.TimedOut -or $run.ExitCode -ne 0 -or -not (Test-Path $rawPath)) {
    $reason = if ($run.StartFailed) { "codex failed to start: $($run.ErrorMessage)" }
              elseif ($run.TimedOut) { "codex timed out" }
              else { "codex exit $($run.ExitCode) or no verdict file" }
    Write-RoundState -StateDir $StateDir -Patch @{ status='failed_attempt'; failure_reason="round $Round attempt ${attempt}: $reason" }
    Write-Error "$reason. Retry this round once (recorded as the next attempt); a further attempt returns 14."
    exit 11
}

# --- Acceptance-time usage gate (added: real-CLI evidence, see task-7-report.md), BEFORE the
#     canonical verdict is ever written. A completed review is accepted and publishable only
#     when the run's OWN accounting proves it: no top-level error event, exactly one
#     turn.completed event, and a genuine positive-integer usage.input_tokens (Get-RunUsage,
#     lib.ps1). The attempt meta written above is immutable and predates this process running;
#     the usage RESULT is a separate, create-only artifact, never folded back into it.
$usage = Get-RunUsage -EventLines $run.StdoutLines
if (-not $usage.Ok) {
    Write-RoundState -StateDir $StateDir -Patch @{ status='failed_attempt'; failure_reason="round $Round attempt ${attempt}: usage gate: $($usage.Reason)" }
    Write-Error "Usage gate failed: $($usage.Reason). Retry this round once, then human flag."
    exit 11
}
try {
    Write-NewFileExclusive -Path (Join-Path $StateDir "$stem-usage.json") -Text (
        [pscustomobject]@{ round=$Round; attempt=$attempt; raw_event=$usage.RawLine; input_tokens=$usage.InputTokens } |
            ConvertTo-Json -Depth 4)
} catch [System.IO.IOException] {
    Write-Error "refusing to overwrite the usage artifact for round $Round attempt ${attempt} (another invocation won the race)"
    exit 14
}
# 0.75 x the documented 1,050,000-token context window, less the 128,000-token max-output
# reserve, is 659,500: input_tokens above that leaves under 25% headroom. Retrying the SAME
# prompt cannot change its own token count, so this is a human flag (10) -- unlike every other
# usage-gate rejection above, which is a retryable failed attempt (11).
if (($usage.InputTokens + 128000) -gt 787500) {
    Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="round $Round attempt ${attempt}: usage over budget: input_tokens=$($usage.InputTokens) (max 659500 for >=25% headroom)" }
    Write-Error "HUMAN FLAG: input_tokens $($usage.InputTokens) leaves under 25% context headroom (limit 659500). Retrying the same prompt cannot help."
    exit 10
}

$verdict = Test-Verdict -Json (Get-Content -Raw $rawPath) -SchemaPath $schemaPath
if (-not $verdict.Valid) {
    # ${attempt}: (braced), NOT $attempt: -- self-review fix (see task-7-report.md). PowerShell's
    # double-quoted-string parser reads a bare "$attempt:" as an attempt at a scope-qualified
    # variable reference (the same syntax as $env:, $script:, etc.), which is a hard ParserError
    # here ("':' was not followed by a valid variable name character") -- confirmed empirically:
    # this is a literal copy of the brief's own given line, and it fails the ENTIRE script's
    # parse, so every test in this file that invokes invoke-codex.ps1 failed before this fix. The
    # sibling failure branch a few lines above already uses the correct ${attempt}: form; this one
    # didn't match it.
    Write-RoundState -StateDir $StateDir -Patch @{ status='failed_attempt'; failure_reason="round $Round attempt ${attempt}: invalid verdict — $($verdict.Reason)" }
    Write-Error "Invalid verdict: $($verdict.Reason). Retry this round once, then human flag."
    exit 11
}
# Canonical round result — written ONLY by a successful attempt, and CREATE-ONLY. Recommendation
# ids are derived from this file, so overwriting it would retroactively change every later
# round's ledger. The guard at the top of the script normally prevents reaching this twice;
# this is the belt-and-braces half of that invariant.
try { Write-NewFileExclusive -Path $canonicalVerdict -Text $verdict.NormalizedJson }
catch [System.IO.IOException] {
    Write-Error "refusing to overwrite the canonical verdict for round $Round (another invocation won the race)"
    exit 14
}
Write-RoundState -StateDir $StateDir -Patch @{
    round=$Round; attempt=$attempt
    status=$(if ($verdict.Normalized.verdict -eq 'approve') { 'approved' } else { 'in_review' })
    verdict=$verdict.Normalized.verdict; downgraded=[bool]$verdict.Downgraded
    harness_dir=$harness; failure_reason=$null
}
Write-Output $verdict.NormalizedJson
exit 0
