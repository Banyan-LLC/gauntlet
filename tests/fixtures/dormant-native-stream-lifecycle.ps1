param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$Source)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. $Source
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Management.Automation;
using System.Threading;
using System.Threading.Tasks;
public static class StreamLifecycleFactory {
 public static string Mode;
 public static int Stops,Disposals;
 public static readonly ManualResetEventSlim StopEntered=new(false),StopRelease=new(false);
 public static object Create(){return new StreamLifecyclePipeline(PowerShell.Create());}
 public static void Reset(string mode){Mode=mode;Stops=0;Disposals=0;StopEntered.Reset();StopRelease.Reset();}
 public static async Task ObserveStop(Task original){await original.ConfigureAwait(false);StopEntered.Set();if(Mode=="blocked")StopRelease.Wait(5000);if(Mode=="fault")throw new System.IO.IOException("SENSITIVE-STOP-FAILURE");}
}
public sealed class StreamLifecyclePipeline:IDisposable {
 readonly PowerShell inner;
 public StreamLifecyclePipeline(PowerShell value){inner=value;}
 public PSCommand Commands {get{return inner.Commands;}}
 public PSDataStreams Streams {get{return inner.Streams;}}
 public StreamLifecyclePipeline AddScript(string value){inner.AddScript(value);return this;}
 public StreamLifecyclePipeline AddArgument(object value){inner.AddArgument(value);return this;}
 public Collection<PSObject> Invoke(){return inner.Invoke();}
 public void Invoke<TInput,TOutput>(PSDataCollection<TInput> input,PSDataCollection<TOutput> output,PSInvocationSettings settings){inner.Invoke<TInput,TOutput>(input,output,settings);}
 public Task StopAsync(AsyncCallback callback,object state){Interlocked.Increment(ref StreamLifecycleFactory.Stops);return StreamLifecycleFactory.ObserveStop(inner.StopAsync(callback,state));}
 public void Dispose(){Interlocked.Increment(ref StreamLifecycleFactory.Disposals);inner.Dispose();}
}
public sealed class StreamDisposeFailure:IDisposable {
 public int Calls;public readonly bool Throw;
 public StreamDisposeFailure(bool fail){Throw=fail;}
 public void Dispose(){Calls++;if(Throw)throw new System.IO.IOException("SENSITIVE-INDEPENDENT-DISPOSAL");}
}
'@ -ErrorAction Stop
$original=(Get-Command Start-ReviewOwnedPipelineCreation).ScriptBlock
$body=$original.ToString();$needle='[Management.Automation.PowerShell]'
if([regex]::Matches($body,[regex]::Escape($needle)).Count -ne 1){throw 'Fixture refuses changed exact startup constructor token'}
$modified=$body.Replace($needle,'[StreamLifecycleFactory]')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($modified,$original.File,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Lifecycle instrumentation did not parse'}
Set-Item Function:Start-ReviewOwnedPipelineCreation $ast.GetScriptBlock()
function Invoke-StopFixtureWorker {param($State,$Arguments)try{Write-Output 'unexpected-worker-output';$State['LateAction']=$true}finally{$State['CoreRetired']=$true}}
try{
 foreach($mode in @('blocked','fault')){
  [StreamLifecycleFactory]::Reset($mode)
  $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
  $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
  $defs=Get-ReviewWorkerDefinitions -LibraryDefinition (Get-Command Invoke-ReviewOwnedWork).ScriptBlock
  $defs['Invoke-StopFixtureWorker']=(Get-Command Invoke-StopFixtureWorker).ScriptBlock
  $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+8L*[Diagnostics.Stopwatch]::Frequency
  $result=Invoke-ReviewOwnedWork -Kind stop_control -OwnerRegistry $registry -DeadlineTimestamp $deadline -WorkerName Invoke-StopFixtureWorker -Definitions $defs -State $state -Arguments @{}
  $owner=$state['OwnedWorkOwner']
  Assert-True ($result.Failure.Code -ceq 'owned_unexpected_output' -and -not $result.Completed -and -not $result.Retired -and $null -eq $result.Result) "$mode stop outcome refuses success and unknown physical retirement"
  Assert-True ([StreamLifecycleFactory]::Stops -eq 1 -and $owner['StopRequested'] -and $null -ne $owner['StopTask'] -and -not $state.ContainsKey('LateAction')) "$mode uses one same original stop task and never dispatches later worker action"
  Assert-True ([object]::ReferenceEquals($owner['State'],$state) -and [object]::ReferenceEquals($registry[$owner['Token']],$owner) -and $owner['Deadline'] -eq $deadline) "$mode keeps original owner state token and deadline"
  if($mode -ceq 'blocked'){
   Assert-True ([StreamLifecycleFactory]::StopEntered.IsSet -and -not $owner['StopTask'].IsCompleted -and $null -eq $owner['DisposeTask'] -and [StreamLifecycleFactory]::Disposals -eq 0) 'pending original stop prevents premature original pipeline/output disposal'
   $refused=Invoke-ReviewOwnedWork -Kind stop_control -OwnerRegistry $registry -DeadlineTimestamp $deadline -WorkerName Invoke-StopFixtureWorker -Definitions $defs -State ([Collections.Concurrent.ConcurrentDictionary[string,object]]::new()) -Arguments @{}
   Assert-Eq $refused.Failure.Code 'prior_owner_unresolved' 'pending stop fences next admission'
   [StreamLifecycleFactory]::StopRelease.Set()
   $watch=[Diagnostics.Stopwatch]::StartNew()
   while($registry.Count -gt 0 -and $watch.ElapsedMilliseconds -lt 3000){$null=Complete-ReviewOwnedWork -OwnerRegistry $registry;Start-Sleep -Milliseconds 10}
   Assert-True ($registry.Count -eq 0 -and $owner['StopTask'].IsCompletedSuccessfully -and $owner['DisposeTask'].IsCompletedSuccessfully -and $owner['OutputDisposed'] -and [StreamLifecycleFactory]::Disposals -eq 1) 'explicit original stop settlement precedes one real pipeline and output disposal'
   Assert-True (-not $result.Retired -and -not $result.Completed -and $null -eq $result.Result) 'later physical stop/disposal never rewrites returned immutable refusal'
  }else{
   $watch=[Diagnostics.Stopwatch]::StartNew()
   while($null -eq $owner['DisposeTask'] -or -not $owner['DisposeTask'].IsCompleted){$null=Complete-ReviewOwnedWork -OwnerRegistry $registry;if($watch.ElapsedMilliseconds -gt 3000){break};Start-Sleep -Milliseconds 10}
   $again=Complete-ReviewOwnedWork -OwnerRegistry $registry
   Assert-True ($owner['StopTask'].IsFaulted -and $owner['DisposeTask'].IsCompletedSuccessfully -and $owner['OutputDisposed'] -and [StreamLifecycleFactory]::Disposals -eq 1) 'failed stop still attempts independent original pipeline/output cleanup after actual stop task settles'
   Assert-True ($registry.Count -eq 1 -and -not $again.Retired -and -not $owner['RetirementConfirmed']) 'faulted original stop cannot become successful retirement after later cleanup'
   Assert-True (@($again.CleanupFailures|Where-Object Code -ceq 'owned_stop').Count -eq 1 -and ($again.CleanupFailures|ConvertTo-Json -Depth 12 -Compress) -match 'System.IO.IOException' -and ($again.CleanupFailures|ConvertTo-Json -Depth 12 -Compress) -notmatch 'SENSITIVE-STOP') 'actual stop fault survives as bounded structural independent cause'
  }
 }
}finally{[StreamLifecycleFactory]::StopRelease.Set();Set-Item Function:Start-ReviewOwnedPipelineCreation $original}
foreach($outputFails in @($false,$true)){
 $pipeline=[StreamDisposeFailure]::new($true);$output=[StreamDisposeFailure]::new($outputFails)
 $owner=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new();$owner['Output']=$output
 $task=Start-ReviewPipelineDisposal -Owner $owner -Pipeline $pipeline
 try{$null=$task.Wait(3000)}catch{}
 Assert-True ($task.IsFaulted -and $pipeline.Calls -eq 1 -and $output.Calls -eq 1) "independent output closure is attempted despite first pipeline disposer failure ($outputFails)"
 Assert-True ($null -ne $owner['PipelineDisposalException'] -and ($null -ne $owner['OutputDisposalException']) -eq $outputFails) "same disposal task preserves both actual independent exception sources ($outputFails)"
 Assert-True (($owner['OutputDisposed'] -is [bool] -and $owner['OutputDisposed']) -eq (-not $outputFails)) "explicit output disposition follows actual closure outcome ($outputFails)"
}
Assert-True ($null -eq ('GauntletLive.Native' -as [type])) 'all stop/disposal controls preserve cold native process type'
Write-TestResult
