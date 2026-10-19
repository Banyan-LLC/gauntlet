param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][ValidateSet('close_cancellation','blocking_dispose','delayed_retirement')][string]$Mode)
$ErrorActionPreference='Stop'
$hash=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
$probe=switch($Mode){'close_cancellation'{'close-cancellation-probe.ps1'}'blocking_dispose'{'deadline-probe.ps1'}'delayed_retirement'{'delayed-retirement-probe.ps1'}}
$arguments=@('-NoProfile','-File',(Join-Path $PSScriptRoot $probe),'-Source',$Source)
if($Mode -eq 'blocking_dispose'){$arguments+=@('-Mode','blocking_cleanup')}
$lines=@(& ([Environment]::ProcessPath) @arguments)
if($LASTEXITCODE -ne 0){throw ('Independent resource probe process failed: '+$Mode)}
$text=$lines -join "`n"
$record=$text|ConvertFrom-Json -ErrorAction Stop
if($record.source_sha256 -cne $hash){throw 'Independent probe did not bind the exact requested source'}
$ok=switch($Mode){
 'close_cancellation' {$record.gate_entered -is [bool] -and $record.gate_entered -and $record.run_completed_800ms_past_deadline -is [bool] -and $record.run_completed_800ms_past_deadline -and $record.native_result.ExitCode -eq -1 -and $record.native_result.ProcessTreeRetired -is [bool] -and -not $record.native_result.ProcessTreeRetired -and $record.native_result.Failure.Code -ceq 'transport_abort' -and @($record.native_result.CleanupFailures.Code) -ccontains 'native_cleanup_deadline'}
 'blocking_dispose' {$record.passed -is [bool] -and $record.passed -and $record.cleanup_calls -eq 1 -and $record.cleanup_after_caller_return -eq 0 -and $record.same_owner_retained -is [bool] -and $record.same_owner_retained -and $record.native_result.ExitCode -eq -1 -and $record.native_result.ProcessTreeRetired -is [bool] -and -not $record.native_result.ProcessTreeRetired}
 'delayed_retirement' {$record.gate_entered -is [bool] -and $record.gate_entered -and $record.direct_job_terminations_after_original_deadline -eq 0 -and $record.native_result.ExitCode -eq -1 -and $record.native_result.ProcessTreeRetired -is [bool] -and -not $record.native_result.ProcessTreeRetired -and $null -ne $record.native_result.Failure}
}
@{passed=[bool]$ok;mode=$Mode;runtime=$PSVersionTable.PSVersion.ToString();dotnet=[Environment]::Version.ToString();source_sha256=$hash;probe_result=$record}|ConvertTo-Json -Depth 8
if((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash){throw 'Source changed while independent probe ran'}
if(-not $ok){exit 1}
