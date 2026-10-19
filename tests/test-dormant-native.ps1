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

# Each regression receives a fresh original process and the complete assembled source.
$regressions=@(
    @{Name='scratch';File='dormant-native-scratch.ps1';Arguments=@('-RepoRoot',$repo)},
    @{Name='guards';File='dormant-native-guards.ps1';Arguments=@('-RepoRoot',$repo)}
)
foreach($entry in @(
    @('stream-floods','dormant-native-stream-floods.ps1'),
    @('stream-lifecycle','dormant-native-stream-lifecycle.ps1'),
    @('stream-init-deadline','dormant-native-stream-init-deadline.ps1'),
    @('stream-native-error','dormant-native-stream-native-error.ps1')
)){
    $regressions+=@{Name=$entry[0];File=$entry[1];Arguments=@('-RepoRoot',$repo,'-Source',$source)}
}
foreach($mode in @('boolean','missing','instance','unicode','writeonly','throwing')){
    $regressions+=@{Name=('stream-identity-'+$mode);File='dormant-native-stream-identity-case.ps1';Arguments=@('-RepoRoot',$repo,'-Source',$source,'-Mode',$mode)}
}
# Complete native lifecycle regression inventory; each entry is a fresh child.
$regressions+=@{Name='native-1';File='dormant-native-runtime-regressions.ps1';Arguments=@('-Source',$source)}
$regressions+=@{Name='native-2';File='dormant-native-fragmentation-regression.ps1';Arguments=@('-Source',$source)}
$regressions+=@{Name='native-3';File='dormant-native-lifecycle-regressions.ps1';Arguments=@('-Source',$source,'-Mode','late_cancel')}
$regressions+=@{Name='native-4';File='dormant-native-lifecycle-regressions.ps1';Arguments=@('-Source',$source,'-Mode','cleanup_faults')}
$regressions+=@{Name='native-5';File='dormant-native-lifecycle-regressions.ps1';Arguments=@('-Source',$source,'-Mode','blocking_cleanup')}
$regressions+=@{Name='native-6';File='dormant-native-lifecycle-regressions.ps1';Arguments=@('-Source',$source,'-Mode','attribute_failure')}
$regressions+=@{Name='native-7';File='dormant-native-resource-admission-regressions.ps1';Arguments=@('-Source',$source,'-Mode','blocking_cleanup')}
$regressions+=@{Name='native-8';File='dormant-native-independent-resource-regressions.ps1';Arguments=@('-Source',$source,'-Mode','close_cancellation')}
$regressions+=@{Name='native-9';File='dormant-native-independent-resource-regressions.ps1';Arguments=@('-Source',$source,'-Mode','blocking_dispose')}
$regressions+=@{Name='native-10';File='dormant-native-independent-resource-regressions.ps1';Arguments=@('-Source',$source,'-Mode','delayed_retirement')}
$regressions+=@{Name='native-11';File='early-dispose-probe.ps1';Arguments=@('-Source',$source)}
foreach($projectionCase in @('ordinary','foreign','transport','metadata')){
    $regressions+=@{Name=('projection-'+$projectionCase);File='dormant-native-projection-case.ps1';Arguments=@('-RepoRoot',$repo,'-Case',$projectionCase)}
}
$regressions+=@{Name='stream-admission';File='dormant-stream-admission.ps1';Arguments=@('-RepoRoot',$repo,'-Source',$source)}
$regressions+=@{Name='completion-deadline';File='dormant-native-completion-deadline.ps1';Arguments=@('-RepoRoot',$repo,'-Source',$source)}
$regressions+=@{Name='real-observer';File='dormant-native-real-observer.ps1';Arguments=@('-RepoRoot',$repo)}
foreach($test in $regressions){
    $fixture=Join-Path $PSScriptRoot ('fixtures/'+$test.File)
    Assert-True ([IO.File]::Exists($fixture)) ($test.Name+' complete isolated regression fixture exists')
    if(-not [IO.File]::Exists($fixture)){continue}
    $result=Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList (@('-NoProfile','-File',$fixture)+$test.Arguments) -WorkingDirectory $repo -TimeoutSec 180 -RequireProcessTreeRetirement
    Write-Host $result.Stdout
    if($result.Stderr){Write-Host $result.Stderr}
    Assert-True ($result.StartFailed -is [bool] -and -not $result.StartFailed -and $result.TimedOut -is [bool] -and -not $result.TimedOut -and $result.ExitCode -eq 0 -and $result.ProcessTreeRetired -is [bool] -and $result.ProcessTreeRetired -and $null -eq $result.ErrorMessage) ($test.Name+' fresh child passes with actual bounded tree retirement')
}
Write-TestResult
