#Requires -Version 7
<# Records (or refreshes) premises.json: the reviewer-stack identity manifest that
   Test-PremiseManifest (lib.ps1) gates every invocation and installation on. Run once per
   (CLI version, schema, AGENTS.md, invocation profile) -- i.e. whenever any of those four
   changes, most commonly after a Codex update.

   Historical (superseded 2026-08-12): earlier revisions of this script also measured and
   recorded four NUMERIC budget premises (tokenizer family/evidence, base overhead, max output
   tokens, context window) by sending several live sampling requests to the real CLI, then
   validated `BudgetBytes + base_overhead + max_output <= 0.75 x context_window` against them.
   That whole procedure is GONE: the live-evidence round found the real CLI's terminal
   turn.completed event reports the EXACT usage.input_tokens for the request that was just
   made, so invoke-codex.ps1's acceptance-time usage gate (Get-RunUsage in lib.ps1) checks the
   real measurement on every round instead of predicting it in advance -- see docs/design.md's
   "Live-evidence round (2026-08-12)" entry. This script therefore makes NO live model call: it
   only re-derives the
   stack-identity bindings below via the same compatibility probe every review round already
   performs, so recording or refreshing the manifest costs nothing to run.

   Exit: 0 recorded | 1 could not measure #>
param(
    [string]$CliPathOverride
)
. "$PSScriptRoot\lib.ps1"
$skillRoot = Split-Path $PSScriptRoot -Parent
$candidates = if ($CliPathOverride) { @($CliPathOverride) } else { Get-CodexCandidates }
$cli = Select-CodexCli -Candidates $candidates -AllowWrapper:([bool]$CliPathOverride)
$disable = Get-DisableSet -FeatureNames $cli.FeatureNames
# Single schema now (see task-7-report.md): schemas/verdict.schema.json serves both
# --output-schema and Test-Verdict's local re-validation.
$schemaPath = "$skillRoot\schemas\verdict.schema.json"

$agentsPath = "$env:USERPROFILE\.codex\AGENTS.md"
@{
    version = 1; model = 'gpt-5.6-sol'
    cli_path = $cli.Path; cli_sha256 = $cli.Sha256; cli_version = $cli.Version
    schema_sha256 = (Get-FileHash -Algorithm SHA256 $schemaPath).Hash.ToLowerInvariant()
    agents_md_sha256 = $(if (Test-Path $agentsPath) { (Get-FileHash -Algorithm SHA256 $agentsPath).Hash.ToLowerInvariant() } else { 'absent' })
    invocation_profile_sha256 = (Get-InvocationProfileHash -DisableSet $disable)
    recorded_utc = (Get-Date -AsUTC -Format o)
} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $skillRoot 'premises.json') -Encoding utf8

# Validate what we just wrote through the same gate production uses. Emitting a manifest that
# the gate would reject would leave every subsequent invocation failing at exit 12 with the
# calibration reporting success.
$check = Test-PremiseManifest -SkillRoot $skillRoot -ActualCli $cli `
    -InvocationProfileHash (Get-InvocationProfileHash -DisableSet $disable)
if (-not $check.Valid) { Write-Error "the recorded manifest does not pass its own gate: $($check.Reason)"; exit 1 }
Write-Output "recorded premises.json (cli=$($cli.Version))"
exit 0
