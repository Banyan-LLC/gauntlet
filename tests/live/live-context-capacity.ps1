# Controlled tiny fixture only. No review state, account settings or premises stamp.
param([Parameter(Mandatory)][string]$CliPath, [Parameter(Mandatory)][string]$EvidencePath)
. "$PSScriptRoot/../../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
$profilePath=Join-Path $PSScriptRoot '../../gauntlet-review/capacity-profile.json'
$profileLease=[IO.FileStream]::new([IO.Path]::GetFullPath($profilePath),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$profile=Get-BoundReviewProfile
if(-not $profile){throw 'Bound profile required'}
$cli=Select-CodexCli -Candidates @($CliPath)
$disable=Get-DisableSet -FeatureNames $cli.FeatureNames
$harness=New-HarnessDir -RepoRoot (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
$output=Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($EvidencePath))) ('capacity-verdict-'+[guid]::NewGuid().ToString('N')+'.json')
$schema=Join-Path $PSScriptRoot '../../gauntlet-review/schemas/verdict.schema.json'
$args=New-CodexArgs -HarnessDir $harness -SchemaPath ([IO.Path]::GetFullPath($schema)) -VerdictPath $output -DisableSet $disable
$audit=Get-InvocationAudit -CodexArgs $args -HarnessDir $harness -SchemaPath ([IO.Path]::GetFullPath($schema)) -VerdictPath $output -ExpectedDisable $disable
$leases=[Collections.Generic.List[IDisposable]]::new()
$leases.Add($profileLease)
$run=$null
try {
    foreach($path in @($CliPath,$profile.catalog_path,([IO.Path]::GetFullPath($schema)),$PSCommandPath,([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../gauntlet-review/scripts/lib.ps1'))))){
        $leases.Add([IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    }
    if((Get-FileHash -LiteralPath $cli.Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $cli.Sha256){throw 'Selected CLI changed before fixture lease'}
    $loadedLibrary=(Get-Command New-CodexArgs).ScriptBlock.Ast
    while($loadedLibrary.Parent){$loadedLibrary=$loadedLibrary.Parent}
    if($loadedLibrary.Extent.Text -cne [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../gauntlet-review/scripts/lib.ps1'))){throw 'Loaded library source changed before fixture lease'}
    if($MyInvocation.MyCommand.ScriptBlock.Ast.Extent.Text -cne [IO.File]::ReadAllText($PSCommandPath)){throw 'Loaded fixture source changed before fixture lease'}
    $script:RequiredChildEnv['RUST_LOG']='trace'
    $run=Invoke-CodexProcess -CliPath $CliPath -CodexArgs $args -PromptText 'Controlled capacity calibration. Return JSON verdict approve, summary capacity fixture, recommendations empty array. No artifact is under review.' -HarnessDir $harness -TimeoutSec 180 -RequireProcessTreeRetirement
    $usage=Get-RunUsage -EventLines $run.StdoutLines
    $values=@([regex]::Matches($run.StderrText,'(?i)(?:model_context_window|modelContextWindow)[^0-9\r\n]{0,32}([0-9]+)')|ForEach-Object{[long]$_.Groups[1].Value}|Sort-Object -Unique)
    $runtime=[Collections.Generic.List[object]]::new()
    foreach($line in ($run.StderrText -split "`n")) {
        $markers=@([regex]::Matches($line,'TokenCount|ThreadTokenUsageUpdated|token_count|thread/tokenUsage/updated|TaskStarted|TurnStarted|task_started')|ForEach-Object Value|Sort-Object -Unique)
        foreach($match in [regex]::Matches($line,'(?i)(?:model_context_window|modelContextWindow)[^0-9\r\n]{0,32}([0-9]+)')) {
            $runtime.Add([pscustomobject]@{value=[long]$match.Groups[1].Value;markers=$markers;metric_syntax=$match.Value})
        }
    }
    # The CLI's runtime telemetry explicitly names its resolved effective window.
    # A requested model_context_window value is not accepted as effective proof.
    $runtimeValues=@($runtime | Where-Object {$_.metric_syntax -match '^model_context_window_effective'} | ForEach-Object value | Sort-Object -Unique)
    $evidence=[ordered]@{version=1;fixture='sealed exec; Rust diagnostic logging only';cli_path=$cli.Path;cli_sha256=$cli.Sha256;cli_version=$cli.Version
        profile_sha256=(Get-InvocationProfileHash -DisableSet $disable);catalog_sha256=$profile.catalog_sha256
        invocation_audit=$audit;fixture_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
        library_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot '../../gauntlet-review/scripts/lib.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
        diagnostic_sha256=(Get-ReviewTextHash $run.StderrText)
        expected_effective_tokens=$profile.capacity.effective_tokens;runtime_context_values=$values;exit_code=$run.ExitCode
        diagnostic_bytes=[Text.Encoding]::UTF8.GetByteCount($run.StderrText)
        runtime_metric_records=$runtime.ToArray();trusted_runtime_context_values=$runtimeValues
        process_tree_retired=$run.ProcessTreeRetired;usage_valid=$usage.Ok;input_tokens=$usage.InputTokens
        actual_capacity_verified=($runtimeValues.Count -eq 1 -and $runtimeValues[0] -eq $profile.capacity.effective_tokens)
        timestamp=(Get-Date -AsUTC -Format o)}
    if((Get-BoundReviewProfile).profile_sha256 -cne $profile.profile_sha256){throw 'Profile changed during controlled fixture'}
    Write-NewFileExclusive -Path $EvidencePath -Text ($evidence|ConvertTo-Json -Depth 5)
    $evidence|ConvertTo-Json -Depth 5
    if($run.StartFailed -or $run.TimedOut -or $run.ExitCode -ne 0 -or -not $run.ProcessTreeRetired -or -not $usage.Ok -or -not $evidence.actual_capacity_verified){throw 'Runtime capacity not proven by fixture'}
}finally{
    [void]$script:RequiredChildEnv.Remove('RUST_LOG')
    foreach($lease in $leases){$lease.Dispose()}
    if($run -and $run.ProcessTreeRetired){$null=Assert-HarnessSafe -Dir $harness -RepoRoot (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent); [IO.Directory]::Delete($harness,$false)}
}
