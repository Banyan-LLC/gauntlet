# run-tests starts this file in a fresh process; all definitions remain test-only.
. "$PSScriptRoot/helpers.ps1"
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source=Join-Path $repo 'gauntlet-review/scripts/dormant-native.ps1'
Assert-True ([IO.File]::Exists($source)) 'complete dormant source exists'
if(-not [IO.File]::Exists($source)){Write-TestResult}
$cold=$null -eq ([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type
Assert-True $cold 'isolated test launcher starts without a loaded native type'
if(-not $cold){Write-TestResult}
. $source
Assert-True ($null -eq ([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type) 'loading dormant definitions does not compile native source'
foreach($name in @('generic','startup','saturation','real','identity','errors','context','cleanup')){
    $fixture=Join-Path $PSScriptRoot ('fixtures/dormant-native-'+$name+'.ps1')
    Assert-True ([IO.File]::Exists($fixture)) "$name complete isolated fixture exists"
    if(-not [IO.File]::Exists($fixture)){continue}
    $result=Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList @('-NoProfile','-File',$fixture,'-RepoRoot',$repo) -WorkingDirectory $repo -TimeoutSec 180 -RequireProcessTreeRetirement
    Write-Host $result.Stdout
    if($result.Stderr){Write-Host $result.Stderr}
    Assert-True ($result.StartFailed -is [bool] -and -not $result.StartFailed -and $result.TimedOut -is [bool] -and -not $result.TimedOut -and $result.ExitCode -eq 0 -and $result.ProcessTreeRetired -is [bool] -and $result.ProcessTreeRetired -and $null -eq $result.ErrorMessage) "$name fresh child passes with actual bounded tree retirement"
}
Write-TestResult
