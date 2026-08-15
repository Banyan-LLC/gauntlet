#Requires -Version 7
<# Exit: 0 published/recovered+verified | 2 drift | 3 dismissed, re-review | 4 HUMAN FLAG
        | 5 transient gh failure (retry once) | 11 invalid/oversized verdict | 12 token missing #>
param(
    [Parameter(Mandatory)][string]$OwnerRepo,
    [Parameter(Mandatory)][int]$Pr,
    [Parameter(Mandatory)][int]$Round,
    [Parameter(Mandatory)][string]$VerdictFile,   # the NORMALIZED round-N-verdict.json
    [Parameter(Mandatory)][string]$StateDir,
    [Parameter(Mandatory)][string]$BaseOid,
    [Parameter(Mandatory)][string]$HeadSha,
    [string]$Reviewer = 'BanyanLLC'
)
. "$PSScriptRoot\lib.ps1"
$normalizedJson = Get-Content -Raw $VerdictFile
# Single schema now (see task-7-report.md): schemas/verdict.schema.json serves both
# --output-schema (invoke-codex.ps1) and this structural re-validation.
$verdict = Test-Verdict -Json $normalizedJson -SchemaPath "$PSScriptRoot\..\schemas\verdict.schema.json"
if (-not $verdict.Valid) { Write-Error "refusing to publish: $($verdict.Reason)"; exit 11 }
# Even the token lookup is bounded — a hung `gh auth token` would otherwise stall before any
# exit-code handling could run. Resolved via Resolve-GhInvocation (Get-Command + the same
# .cmd/.ps1 wrapping Invoke-Gh uses), NOT a bare -FileName 'gh': see that function's comment —
# a bare Process.Start(FileName='gh') only ever tries the literal name or name+".exe" on
# Windows, so it would silently prefer a real system gh.exe over a PATH-prepended dev/test shim.
try {
    $ghInv = Resolve-GhInvocation
    $tokenRes = Invoke-BoundedProcess -FileName $ghInv.FileName -ArgList ($ghInv.PrefixArgs + @('auth','token','-u',$Reviewer)) -TimeoutSec 30
} catch {
    Write-Error "no gh token for '$Reviewer': $($_.Exception.Message). Run: gh auth login"
    exit 12
}
if ($tokenRes.StartFailed -or $tokenRes.TimedOut -or $tokenRes.ExitCode -ne 0) {
    Write-Error "no gh token for '$Reviewer' (start-failed=$($tokenRes.StartFailed) timed-out=$($tokenRes.TimedOut) exit=$($tokenRes.ExitCode)). Run: gh auth login"
    exit 12
}
$token = $tokenRes.Stdout.Trim()
if (-not $token) { Write-Error "empty gh token for '$Reviewer'"; exit 12 }
try {
    exit (Publish-CodexReview -Token $token -OwnerRepo $OwnerRepo -Pr $Pr -NormalizedVerdict $verdict.Normalized `
        -BaseOid $BaseOid -HeadSha $HeadSha -Round $Round -NormalizedJson $verdict.NormalizedJson -StateDir $StateDir `
        -Reviewer $Reviewer)
} catch {
    if ($_.Exception.Message -like 'OVERSIZED*') { Write-Error $_.Exception.Message; exit 11 }
    Write-Error "TRANSIENT: $($_.Exception.Message). Retry once (marker recovery makes rerun safe), then human flag."
    exit 5
}
