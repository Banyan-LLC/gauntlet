# Fixture cleanup preservation v1: primary and independent cleanup errors.
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
$library=Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1'
. $library

Assert-True ($null -eq ([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type) 'dormant source load does not compile native type'
Initialize-LiveGateNative
$firstNativeType=([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type
Initialize-LiveGateNative
Assert-True ([object]::ReferenceEquals($firstNativeType,([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type)) 'identical source initializer reuses exact native type'
Add-Type -TypeDefinition @'
using System;
using System.Threading;
using System.Threading.Tasks;
public static class FacadeCauseFixture {
 public static readonly ManualResetEventSlim Entered=new(false),Release=new(false);
 public static void Reset(){Entered.Reset();Release.Reset();}
 public static Task DisposeAfterRelease(Action dispose){return Task.Run(()=>{Entered.Set();Release.Wait();dispose();});}
}
'@
$savedDispose=(Get-Command Start-ReviewPipelineDisposal).ScriptBlock
function Settle-OriginalFixtureOwner($Registry){
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while($Registry.Count -gt 0 -and $watch.ElapsedMilliseconds -lt 5000){$null=Complete-ReviewOwnedWork -OwnerRegistry $Registry;Start-Sleep -Milliseconds 10}
 if($Registry.Count -ne 0){throw 'Original fixture owner did not physically settle'}
}
# Diagnostic-storage seam only; actual native invocation and owning disposal remain unchanged.
function Test-FixtureFlatFault($Projected,$Original){
 if($null -eq $Projected -or $null -eq $Original){return $false}
 $cause=if($Original -is [Collections.IDictionary] -and $Original.Keys -ccontains 'Cause'){$Original['Cause']}else{$Original}
 $type=if($null -ne $cause){$cause.Type}else{$null};$hresult=if($null -ne $cause){$cause.HResult}else{$null};$nativeError=if($null -ne $cause){$cause.NativeError}else{$null}
 return [string]::Equals($Projected.Code,$Original.Code,[StringComparison]::Ordinal) -and [string]::Equals($Projected.Stage,$Original.Stage,[StringComparison]::Ordinal) -and [object]::Equals($Projected.Type,$type) -and [object]::Equals($Projected.HResult,$hresult) -and [object]::Equals($Projected.NativeError,$nativeError)
}
$nativeSafeFailure=[GauntletLive.Native].GetMethod('SafeFailure',[Reflection.BindingFlags]'NonPublic,Static',$null,[type[]]@([string],[string],[Exception]),$null)
if($null -eq $nativeSafeFailure -or $nativeSafeFailure.ReturnType -ne [GauntletLive.Native+NativeFailure]){throw 'Exact native diagnostic builder required'}
$script:NativeSaturationSeen=$null;$script:NativeSaturationMode=$null
function Start-ReviewPipelineDisposal {
 param($Owner,$Pipeline)
 if($Owner['Kind'] -cne 'native_process'){throw 'Native fixture refuses unrelated original owner'}
 $state=$Owner['State'];$native=$state['Result']
 if($null -eq $native -or $native.GetType() -ne [GauntletLive.Native+RunResult] -or -not $native.StartFailed -or -not $native.ProcessTreeRetired){throw 'Actual failed no-child native result required'}
 $primary=$native.Failure
 if($null -eq $primary -or $native.CleanupFailures.Count -ne 0){throw 'Actual initial native fault required before storage injection'}
 $first=$nativeSafeFailure.Invoke($null,@('fixture_first_secondary','fixture_diagnostic_storage',[IO.IOException]::new('Synthetic first diagnostic')))
 $later=$nativeSafeFailure.Invoke($null,@('fixture_later_secondary','fixture_diagnostic_storage',[IO.IOException]::new('Synthetic later diagnostic')))
 $faults=switch($script:NativeSaturationMode){'full'{@($first,$later)};'primary_duplicate'{@($primary,$first)};'secondary_duplicate'{@($first,$first)};default{throw 'Unknown native storage mode'}}
 $scalars=@{ExitCode=$native.ExitCode;StartFailed=$native.StartFailed;TimedOut=$native.TimedOut;ErrorMessage=$native.ErrorMessage;StderrText=$native.Stderr;ProcessTreeRetired=$native.ProcessTreeRetired}
 $native.CleanupFailures=[GauntletLive.Native+NativeFailure[]]$faults
 $script:NativeSaturationSeen=@{Owner=$Owner;State=$state;Native=$native;Primary=$primary;First=$first;Stored=$native.CleanupFailures;Scalars=$scalars;Pipeline=$Pipeline;Deadline=$Owner['Deadline']}
 $Owner['DisposalIntent']=$true
        $dispose=Get-ReviewOwnedPipelineDisposalAction -Owner $Owner -Pipeline $Pipeline
 $task=[FacadeCauseFixture]::DisposeAfterRelease($dispose);$Owner['DisposeTask']=$task
 return ,$task
}
$nativeMissing=Join-Path ([IO.Path]::GetTempPath()) ('native-saturation-'+[guid]::NewGuid().ToString('n')+'/absent/never.exe')
if([IO.Directory]::Exists([IO.Path]::GetDirectoryName($nativeMissing)) -or [IO.File]::Exists($nativeMissing)){throw 'Native fixture requires absent nonlaunchable path'}
$fixturePrimary0=$null
try {
try{
 foreach($mode in @('full','primary_duplicate','secondary_duplicate')){
  [FacadeCauseFixture]::Reset();$script:NativeSaturationMode=$mode;$script:NativeSaturationSeen=$null
  $registry=Get-ReviewOwnerRegistry ReviewProcessOwners
  if($registry.Count -ne 0){throw 'Native fixture refuses prior original owner'}
  $fixturePrimary1=$null
try {
try{
   $result=Invoke-BoundedProcess -FileName $nativeMissing -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutSec 2 -ClearEnvironment -EnvironmentMap @{}
   $seen=$script:NativeSaturationSeen
   Assert-True ([FacadeCauseFixture]::Entered.IsSet -and $null -ne $seen) "native $mode real original disposal entered"
   if($null -eq $seen){continue}
   $ownerFault=$seen.Owner['Failure'];$secondary=@($result.CleanupFailures)
   Assert-True ($seen.Native.GetType() -eq [GauntletLive.Native+RunResult] -and $seen.Native.StartFailed -and $seen.Native.ProcessTreeRetired -and -not $seen.Native.TimedOut) "native $mode actual no-child CSharp result"
   Assert-True ([object]::ReferenceEquals($seen.Owner['State'],$seen.State) -and [object]::ReferenceEquals($seen.Owner['Pipeline'],$seen.Pipeline) -and $seen.Owner['Deadline'] -eq $seen.Deadline -and $registry.Count -eq 1) "native $mode same original authority"
   Assert-True ([object]::ReferenceEquals($seen.Native.Failure,$seen.Primary) -and [object]::ReferenceEquals($seen.Native.CleanupFailures,$seen.Stored) -and $seen.Stored.Count -eq 2) "native $mode only diagnostic storage injected"
   Assert-True ($result.ExitCode -eq -1 -and $result.TimedOut -and -not $result.ProcessTreeRetired -and -not $seen.Owner['RetirementConfirmed']) "native $mode rejected pending original owner"
   $receipt=$result.NativeProcessResult;$same=$null -ne $receipt -and $receipt.Keys.Count -eq 6
   foreach($name in $seen.Scalars.Keys){$same=$same -and $receipt.ContainsKey($name) -and [object]::Equals($receipt[$name],$seen.Scalars[$name])}
   Assert-True $same "native $mode all six actual scalars unchanged"
   Assert-True (Test-FixtureFlatFault $result.Failure $seen.Primary) "native $mode actual primary five scalars"
   Assert-Eq $secondary.Count 2 "native $mode max two secondary faults"
   Assert-True (Test-FixtureFlatFault $secondary[0] $seen.First) "native $mode earliest distinct secondary"
   Assert-True ($seen.Owner['TimedOut'] -is [bool] -and $seen.Owner['TimedOut'] -and $ownerFault.Code -ceq 'owned_deadline' -and (Test-FixtureFlatFault $secondary[1] $ownerFault)) "native $mode actual owning deadline five scalars"
   $safe=$true
   foreach($fault in @($result.Failure)+$secondary){$safe=$safe -and $fault.Keys.Count -eq 5;foreach($key in @('Code','Stage','Type','HResult','NativeError')){$safe=$safe -and $fault.ContainsKey($key)}}
   Assert-True $safe "native $mode fixed flat safe schema"
   [ordered]@{case='native_'+$mode;owner_code=$ownerFault.Code;owner_stage=$ownerFault.Stage;owner_timed_out=$seen.Owner['TimedOut'];secondary=@($secondary|ForEach-Object Code);original_deadline=$seen.Owner['Deadline'] -eq $seen.Deadline}|ConvertTo-Json -Compress|Write-Output
  }
catch{throw}
}catch{$fixturePrimary1=$_;throw}finally{
$fixtureCleanup1=[Collections.Generic.List[Exception]]::new()
try{
[FacadeCauseFixture]::Release.Set()
}catch{$fixtureCleanup1.Add($_.Exception)}
try{
Settle-OriginalFixtureOwner $registry
}catch{$fixtureCleanup1.Add($_.Exception)}
if($fixtureCleanup1.Count -gt 0){
 if($null -ne $fixturePrimary1){
  $previous=@();if($fixturePrimary1.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary1.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary1.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup1.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup1.ToArray())}
}
}
 }
}
catch{throw}
}catch{$fixturePrimary0=$_;throw}finally{
$fixtureCleanup0=[Collections.Generic.List[Exception]]::new()
try{
Set-Item Function:Start-ReviewPipelineDisposal $savedDispose
}catch{$fixtureCleanup0.Add($_.Exception)}
if($fixtureCleanup0.Count -gt 0){
 if($null -ne $fixturePrimary0){
  $previous=@();if($fixturePrimary0.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary0.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary0.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup0.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup0.ToArray())}
}
}

Write-TestResult
