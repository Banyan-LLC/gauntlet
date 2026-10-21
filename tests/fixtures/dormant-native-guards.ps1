param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. (Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1')
Assert-True ($null -eq ([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type) 'guard regression parent starts genuinely Native-cold'
$fixture=Join-Path $RepoRoot 'tests/fixtures/dormant-native-guard-case.ps1'
foreach($case in @('boolean','unicode','missing','instance','platform','production')){
 $result=Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList @('-NoProfile','-File',$fixture,'-RepoRoot',$RepoRoot,'-Case',$case) -WorkingDirectory $RepoRoot -TimeoutSec 30 -RequireProcessTreeRetirement
 Write-Host $result.Stdout
 if($result.Stderr){Write-Host $result.Stderr}
 Assert-True ($result.ExitCode -eq 0 -and -not $result.StartFailed -and -not $result.TimedOut -and $result.ProcessTreeRetired -and $null -eq $result.ErrorMessage -and $null -eq $result.Failure -and $result.CleanupFailures.Count -eq 0) "$case independent actual source-guard child succeeds and physically retires"
}
$originalType=([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type
Initialize-LiveGateNative
Assert-True ([object]::ReferenceEquals($originalType,([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type)) 'matching native source repeat initialization preserves exact original type'
Assert-True ([GauntletLive.Native]::SourceIdentity -is [string] -and [regex]::IsMatch([GauntletLive.Native]::SourceIdentity,'\A[0-9a-f]{64}\z',[Text.RegularExpressions.RegexOptions]::CultureInvariant)) 'matching native source identity has exact lowercase SHA256 shape'
Write-TestResult
