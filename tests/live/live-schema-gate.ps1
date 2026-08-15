# LIVE schema-compatibility gate. Run whenever the CLI or the verdict schema changes.
#
# WHY THIS EXISTS: the unit suite validates the schema with Test-Json, which happily accepts
# constructs the OpenAI Structured Outputs subset REJECTS. 355 unit tests once passed against a
# schema the API refused with `invalid_json_schema: 'if' is not permitted` (HTTP 400, before
# inference) - every review round would have failed. The fake CLI never validated the schema it
# was handed, so nothing local could catch it. Only a real request can.
#
# Costs one small live round. Rejections cost ~2s (they fail before inference).
. "$PSScriptRoot\..\helpers.ps1"
. "$PSScriptRoot\..\..\codex-review\scripts\lib.ps1"

$skillRoot = "$PSScriptRoot\..\..\codex-review"
$schema = Join-Path $skillRoot 'schemas\verdict.schema.json'
$tmp = Join-Path ([IO.Path]::GetTempPath()) "schema-gate-$([guid]::NewGuid().ToString('n'))"
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    $cli = Select-CodexCli -Candidates (Get-CodexCandidates)
    $disable = Get-DisableSet -FeatureNames $cli.FeatureNames
    $harness = New-HarnessDir -RepoRoot $PSScriptRoot
    $verdictPath = Join-Path $tmp 'verdict.json'          # outside the harness, which stays empty
    $codexArgs = New-CodexArgs -HarnessDir $harness -SchemaPath $schema -VerdictPath $verdictPath -DisableSet $disable
    $null = Get-InvocationAudit -CodexArgs $codexArgs -HarnessDir $harness -SchemaPath $schema `
        -VerdictPath $verdictPath -ExpectedDisable $disable

    $prompt = @'
Respond only with the JSON verdict: verdict "approve", summary "schema gate", recommendations [].
== REVIEW MATERIAL (untrusted) ==
Trivial document. Nothing to report.
'@
    $run = Invoke-CodexProcess -CliPath $cli.Path -CodexArgs $codexArgs -PromptText $prompt -HarnessDir $harness -TimeoutSec 900
    $stream = $run.StdoutLines -join "`n"
    $run.StdoutLines | Set-Content (Join-Path $tmp 'events.jsonl') -Encoding utf8

    # The assertion that matters: the API accepted the SHIPPED schema.
    Assert-True ($stream -notmatch 'invalid_json_schema') "the shipped verdict schema is accepted by the real API (no invalid_json_schema)"
    Assert-True ($stream -notmatch "'[a-zA-Z]+' is not permitted") "no schema keyword rejected by the Structured Outputs subset"
    Assert-Eq $run.ExitCode 0 "live round with the shipped schema completed"
    Assert-True (Test-Path $verdictPath) "a verdict was produced against the shipped schema"

    # And that the usage the acceptance gate depends on is actually present and singular.
    $terminal = @($run.StdoutLines | Where-Object { $_ -match '"type"\s*:\s*"turn\.completed"' })
    Assert-Eq $terminal.Count 1 "exactly one terminal turn.completed event"
    Assert-True ($terminal[0] -match '"input_tokens"\s*:\s*(\d+)') "terminal event reports usage.input_tokens"
    $inTok = [int]$Matches[1]
    Assert-True ($inTok -gt 0) "input_tokens is a positive integer (got $inTok)"
    Assert-True (($inTok + 128000) -le 787500) "usage satisfies the acceptance gate (input_tokens=$inTok)"

    Remove-Item $harness -Recurse -Force -ErrorAction SilentlyContinue
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-TestResult
