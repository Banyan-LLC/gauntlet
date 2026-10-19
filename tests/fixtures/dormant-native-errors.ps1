# Fixture cleanup preservation v1: primary and independent cleanup errors.
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. (Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1')
function Invoke-ErrorFixtureWorker {
    param($State,$Arguments)
    try{
        $State['Stage']='fixture_action'
        if($Arguments.Mode -ceq 'throw'){throw [IO.IOException]::new('SENSITIVE-WORKER-ERROR')}
        if($Arguments.Mode -ceq 'unauthorized'){throw [UnauthorizedAccessException]::new('SENSITIVE-WORKER-ACCESS-ERROR')}
        if($Arguments.Mode -ceq 'stream'){Write-Error -Exception ([IO.IOException]::new('SENSITIVE-STREAM-ERROR')) -ErrorAction Continue}
        $State['Result']=New-ReviewReadOnlyRecord -Values @{Value='success-before-disposal'}
    }finally{$State['CoreRetired']=$true}
}
function Invoke-ErrorFixture([string]$Mode,$Registry,$State){
    $defs=@{'Invoke-ErrorFixtureWorker'=(Get-Command Invoke-ErrorFixtureWorker).ScriptBlock}
    Invoke-ReviewOwnedWork -Kind errors -OwnerRegistry $Registry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+10L*[Diagnostics.Stopwatch]::Frequency) -WorkerName Invoke-ErrorFixtureWorker -Definitions $defs -Arguments @{Mode=$Mode} -State $State
}
foreach($mode in @('throw','stream')){
    $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $result=Invoke-ErrorFixture $mode $registry $state
    Assert-True ($result.IsReadOnly -and $result.Retired -and -not $result.TimedOut -and $null -eq $result.Result -and $null -ne $result.Failure) "$mode actual worker fault refuses result independently of physical retirement"
    Assert-Eq $result.Failure.Code $(if($mode -ceq 'throw'){'owned_worker'}else{'owned_error_stream'}) "$mode preserves actual typed worker failure category"
    Assert-Eq $registry.Count 0 "$mode actual pipeline invocation and disposal physically settle"
    Assert-True (($result.Failure|ConvertTo-Json -Depth 12 -Compress) -notmatch 'SENSITIVE-|Message|StackTrace|Pipeline|Registry') "$mode public structural failure excludes raw error and private authority"
}
$savedCreation=(Get-Command Start-ReviewOwnedPipelineCreation).ScriptBlock
$savedInvocation=(Get-Command Start-ReviewOwnedPipelineInvocation).ScriptBlock
$fixturePrimary0=$null
try {
try{
    function Start-ReviewOwnedPipelineCreation {
        param($Owner,$Bootstrap,$ArgumentList)
        [Threading.Tasks.Task[object]]::FromException([IO.IOException]::new('SENSITIVE-CREATION-ERROR'))
    }
    $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $result=Invoke-ErrorFixture clean $registry $state
    Assert-True ($null -ne $result.Failure -and -not $result.Completed -and $result.Retired -and $null -eq $result.Result -and $registry.Count -eq 0) 'faulted original creation task refuses result and proves no submitted action'
    Assert-True (-not $state.ContainsKey('ActionEntered')) 'faulted creation task cannot dispatch worker action'
    Set-Item Function:Start-ReviewOwnedPipelineCreation $savedCreation
    function Start-ReviewOwnedPipelineInvocation {
        param($Pipeline)
        [Threading.Tasks.Task[object]]::FromException([IO.IOException]::new('SENSITIVE-INVOCATION-ERROR'))
    }
    $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $result=Invoke-ErrorFixture clean $registry $state
    Assert-True ($null -ne $result.Failure -and -not $result.Completed -and $null -eq $result.Result) 'faulted original invocation task immediately refuses result'
    Assert-True (-not $state.ContainsKey('ActionEntered')) 'faulted submission task cannot execute configured worker'
    $owner=$state['OwnedWorkOwner'];$watch=[Diagnostics.Stopwatch]::StartNew()
    while($registry.Count -gt 0 -and $watch.ElapsedMilliseconds -lt 5000){$null=Complete-ReviewOwnedWork -OwnerRegistry $registry;Start-Sleep -Milliseconds 10}
    Assert-True ($registry.Count -eq 0 -and $owner['RetirementConfirmed'] -and $owner['DisposeTask'].IsCompletedSuccessfully) 'explicit observation physically retires the same created pipeline after faulted invocation'
    Assert-True (-not $result.Completed -and $null -eq $result.Result) 'later physical disposal never rewrites immutable failed invocation acceptance'
}
catch{throw}
}catch{$fixturePrimary0=$_;throw}finally{
$fixtureCleanup0=[Collections.Generic.List[Exception]]::new()
try{
Set-Item Function:Start-ReviewOwnedPipelineCreation $savedCreation
}catch{$fixtureCleanup0.Add($_.Exception)}
try{
Set-Item Function:Start-ReviewOwnedPipelineInvocation $savedInvocation
}catch{$fixtureCleanup0.Add($_.Exception)}
if($fixtureCleanup0.Count -gt 0){
 if($null -ne $fixturePrimary0){
  $previous=@();if($fixturePrimary0.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary0.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary0.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup0.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup0.ToArray())}
}
}
Add-Type -TypeDefinition @'
using System;
using System.Threading;
using System.Threading.Tasks;
public static class DormantWorkerCauseFixture {
 public static readonly ManualResetEventSlim Entered=new(false),Release=new(false);
 public static Task DisposeAfterRelease(Action dispose){return Task.Run(()=>{Entered.Set();Release.Wait();dispose();});}
}
'@
$savedCauseDisposal=(Get-Command Start-ReviewPipelineDisposal).ScriptBlock
$fixturePrimary1=$null
try {
try{
    function Start-ReviewPipelineDisposal {
        param($Owner,$Pipeline)
        $dispose=[Delegate]::CreateDelegate([Action],$Pipeline,'Dispose')
        $task=[DormantWorkerCauseFixture]::DisposeAfterRelease($dispose)
        $Owner['DisposeTask']=$task
        return ,$task
    }
    $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $defs=@{'Invoke-ErrorFixtureWorker'=(Get-Command Invoke-ErrorFixtureWorker).ScriptBlock}
    $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+2L*[Diagnostics.Stopwatch]::Frequency
    $result=Invoke-ReviewOwnedWork -Kind causal_error -OwnerRegistry $registry -DeadlineTimestamp $deadline -WorkerName Invoke-ErrorFixtureWorker -Definitions $defs -Arguments @{Mode='throw'} -State $state
    $owner=$state['OwnedWorkOwner'];$first=$state['Failure']
    Assert-True ([DormantWorkerCauseFixture]::Entered.IsSet -and $first.Code -ceq 'owned_worker' -and $state['CoreRetired'] -and -not $owner['DisposeTask'].IsCompleted) 'actual worker throws before same original disposer blocks at original deadline'
    Assert-True ([object]::ReferenceEquals($owner['State'],$state) -and $owner['Deadline'] -eq $deadline -and [object]::ReferenceEquals($registry[$owner['Token']],$owner)) 'worker cause observation retains same original state owner and deadline'
    Assert-True ([object]::ReferenceEquals($result.Failure,$first)) 'later disposal deadline preserves exact original worker failure as primary'
    $secondary=@($result.CleanupFailures)
    Assert-True ($secondary.Count -ge 1 -and $secondary.Count -le 2 -and @($secondary|Where-Object {$_.Code -ceq 'owned_deadline'}).Count -eq 1) 'actual disposal deadline remains an independent bounded secondary after worker failure'
    Assert-True ($result.TimedOut -and -not $result.Completed -and -not $result.Retired -and $null -eq $result.Result -and $registry.Count -eq 1 -and -not $owner['RetirementConfirmed']) 'causal evidence never grants retirement or acceptance to blocked original disposer'
}
catch{throw}
}catch{$fixturePrimary1=$_;throw}finally{
$fixtureCleanup1=[Collections.Generic.List[Exception]]::new()
try{
[DormantWorkerCauseFixture]::Release.Set()
}catch{$fixtureCleanup1.Add($_.Exception)}
try{
if($null -ne $registry){
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while($registry.Count -gt 0 -and $watch.ElapsedMilliseconds -lt 5000){$null=Complete-ReviewOwnedWork -OwnerRegistry $registry;Start-Sleep -Milliseconds 10}
        Assert-Eq $registry.Count 0 'causal fixture retires only through actual original disposal observation after release'
    }
}catch{$fixtureCleanup1.Add($_.Exception)}
try{
Set-Item Function:Start-ReviewPipelineDisposal $savedCauseDisposal
}catch{$fixtureCleanup1.Add($_.Exception)}
if($fixtureCleanup1.Count -gt 0){
 if($null -ne $fixturePrimary1){
  $previous=@();if($fixturePrimary1.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary1.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary1.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup1.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup1.ToArray())}
}
}
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading.Tasks;
public static class DormantDisposalFailureFixture {
 public static bool ActualDisposeCompleted;
 public static Task DisposeThenFail(Action dispose){return Task.Run(()=>{dispose();ActualDisposeCompleted=true;throw new IOException("SENSITIVE-DISPOSAL-ERROR");});}
}
'@
$savedDisposal=(Get-Command Start-ReviewPipelineDisposal).ScriptBlock
$fixturePrimary2=$null
try {
try{
    function Start-ReviewPipelineDisposal {
        param($Owner,$Pipeline)
        $dispose=[Delegate]::CreateDelegate([Action],$Pipeline,'Dispose')
        $task=[DormantDisposalFailureFixture]::DisposeThenFail($dispose)
        $Owner['DisposeTask']=$task
        return ,$task
    }
    foreach($mode in @('clean','unauthorized')){
        [DormantDisposalFailureFixture]::ActualDisposeCompleted=$false
        $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
        $result=Invoke-ErrorFixture $mode $registry $state
        $owner=$state['OwnedWorkOwner']
        Assert-True ([DormantDisposalFailureFixture]::ActualDisposeCompleted -and $owner['DisposeTask'].IsFaulted) "$mode disposal fault comes from the same task after actually disposing the original pipeline"
        Assert-True (-not $result.Retired -and $registry.Count -eq 1 -and -not $owner['RetirementConfirmed']) "$mode faulted original disposer remains fenced despite completed worker"
        $secondary=@($result.CleanupFailures)
        if($mode -ceq 'clean'){
            Assert-True ($result.Failure.Code -ceq 'owned_disposal' -and $result.Failure.Stage -ceq 'worker_dispose' -and [object]::ReferenceEquals($result.Failure,$owner['DisposalFailure'])) 'clean worker retains same original failed disposer as its first primary cause'
            Assert-True ($secondary.Count -ge 1 -and $secondary.Count -le 2 -and @($secondary|Where-Object {$_.Code -ceq 'owned_startup'}).Count -eq 1 -and @($secondary|Where-Object {[object]::ReferenceEquals($_,$result.Failure)}).Count -eq 0) 'clean worker later observer fault remains bounded independent secondary'
        }else{
            Assert-True ($secondary.Count -ge 1 -and $secondary.Count -le 2 -and @($secondary|Where-Object {$_.Code -ceq 'owned_disposal' -and $_.Stage -ceq 'worker_dispose'}).Count -eq 1) "$mode faulted actual disposer remains bounded typed secondary evidence"
        }
        if($mode -ceq 'unauthorized'){
            Assert-True ($state['Failure'].Code -ceq 'owned_worker' -and [object]::ReferenceEquals($result.Failure,$state['Failure'])) 'later actual disposer fault preserves exact original UnauthorizedAccess worker failure as primary'
            $encoded=$result.Failure|ConvertTo-Json -Depth 12 -Compress
            Assert-True ($encoded -match 'System.UnauthorizedAccessException' -and $encoded -notmatch 'SENSITIVE-|StackTrace|Message') 'original worker access failure retains structural cause without raw diagnostics'
        }
        $refused=Invoke-ErrorFixture clean $registry ([Collections.Concurrent.ConcurrentDictionary[string,object]]::new())
        Assert-True ($refused.Failure.Code -ceq 'prior_owner_unresolved' -and [object]::ReferenceEquals($registry[$owner['Token']],$owner)) "$mode failed disposal fences new admission and retains exact original owner"
        $again=Complete-ReviewOwnedWork -OwnerRegistry $registry
        Assert-True (-not $again.Retired -and $registry.Count -eq 1 -and -not $owner['RetirementConfirmed']) "$mode later observation cannot convert faulted original disposal into successful retirement"
    }
}
catch{throw}
}catch{$fixturePrimary2=$_;throw}finally{
$fixtureCleanup2=[Collections.Generic.List[Exception]]::new()
try{
Set-Item Function:Start-ReviewPipelineDisposal $savedDisposal
}catch{$fixtureCleanup2.Add($_.Exception)}
if($fixtureCleanup2.Count -gt 0){
 if($null -ne $fixturePrimary2){
  $previous=@();if($fixturePrimary2.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary2.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary2.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup2.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup2.ToArray())}
}
}
Write-TestResult
