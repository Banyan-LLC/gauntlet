#Requires -Version 7
<# Records (or refreshes) premises.json's STACK-ACCEPTANCE fields: the reviewer-stack identity
   binding that Test-PremiseManifest (lib.ps1) requires as ONE of its two conditions -- see
   "ACCEPTANCE, NOT VERIFICATION" below for the other. Run once per (CLI version, schema,
   AGENTS.md, invocation profile) -- i.e. whenever any of those four changes, most commonly
   after a Codex update.

   ACCEPTANCE, NOT VERIFICATION (added: binding authorization to live evidence, see
   task-14-report.md). This script performs a compatibility PROBE only -- `--version`, `codex
   login status`, `exec --help`, `features list` -- and makes NO live model call. It can
   therefore prove the stack is internally consistent and matches what would actually run
   (Test-StackAcceptance, lib.ps1), never that a real request against the real API was ever sent
   or accepted. Presenting a passing probe as proof of a working reviewer stack would let a
   manifest regenerated immediately after CLI or schema drift silently re-authorize every round
   with no live gate ever rerun -- exactly the gap this script used to leave open. This script
   therefore NEVER writes or refreshes a `live_evidence` record: overwriting premises.json, which
   every run of this script does, always DROPS any live-evidence record a prior run of
   tests/live/live-schema-gate.ps1 stamped. Test-PremiseManifest -- the gate the production entry
   and the installer actually call -- requires BOTH stack acceptance (this script) AND a matching
   live-evidence record, so a live gate rerun is required again after every calibration before
   either will authorize anything.

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

   Exit: 0 recorded (stack accepted; a live gate run is still required separately) | 1 could not measure #>
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
    # No `live_evidence` key here, deliberately -- see "ACCEPTANCE, NOT VERIFICATION" above. This
    # script cannot prove live verification, so it must never claim to.
} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $skillRoot 'premises.json') -Encoding utf8

# Validate what we just wrote through the NARROWER stack-acceptance check -- not the full
# Test-PremiseManifest production/installer gate, which also requires a live-evidence record
# this script can never provide (it would therefore fail here on every calibration run, even a
# perfectly good one). Test-StackAcceptance is exactly the subset of the gate this script is
# responsible for: the CLI/schema/AGENTS.md/invocation-profile binding.
$check = Test-StackAcceptance -SkillRoot $skillRoot -ActualCli $cli `
    -InvocationProfileHash (Get-InvocationProfileHash -DisableSet $disable)
if (-not $check.Valid) { Write-Error "the recorded manifest does not pass its own stack-acceptance check: $($check.Reason)"; exit 1 }
Write-Output "recorded premises.json (cli=$($cli.Version)) -- stack ACCEPTED, not live-verified."
Write-Output "Run tests/live/live-schema-gate.ps1 before this authorizes any review round or install."
exit 0
