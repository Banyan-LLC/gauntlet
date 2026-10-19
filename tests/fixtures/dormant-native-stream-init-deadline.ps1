param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$Source)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. $Source
Add-Type -TypeDefinition @'
using System;
using System.Threading;
namespace GauntletOwnedWork {
 public sealed class StreamGuard {
  public static readonly ManualResetEventSlim Entered=new(false),Release=new(false);
  public static string SourceIdentity {get{Entered.Set();Release.Wait(5000);return new string('0',64);}}
 }
}
'@ -ErrorAction Stop
function Invoke-NeverStreamWorker {param($State,$Arguments)try{$State['ForbiddenAction']=$true}finally{$State['CoreRetired']=$true}}
$registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$defs=Get-ReviewWorkerDefinitions -LibraryDefinition (Get-Command Invoke-ReviewOwnedWork).ScriptBlock
$defs['Invoke-NeverStreamWorker']=(Get-Command Invoke-NeverStreamWorker).ScriptBlock
$deadline=[Diagnostics.Stopwatch]::GetTimestamp()+[long](0.3*[Diagnostics.Stopwatch]::Frequency)
$clock=[Diagnostics.Stopwatch]::StartNew();$result=$null
try{
 $result=Invoke-ReviewOwnedWork -Kind stream_initializer -OwnerRegistry $registry -DeadlineTimestamp $deadline -WorkerName Invoke-NeverStreamWorker -Definitions $defs -State $state -Arguments @{}
 $clock.Stop();$owner=$state['OwnedWorkOwner']
 Assert-True ([GauntletOwnedWork.StreamGuard]::Entered.IsSet -and $clock.ElapsedMilliseconds -lt 1200) 'hostile loaded-source getter executes only inside original retained creation task under entry observer deadline'
 Assert-True ($result.TimedOut -and -not $result.Completed -and -not $result.Retired -and $null -eq $result.Result -and $registry.Count -eq 1) 'blocked helper initializer cannot claim action or original physical retirement'
 Assert-True ($owner['Deadline'] -eq $deadline -and [object]::ReferenceEquals($owner['State'],$state) -and -not $owner['CreationTask'].IsCompleted -and $null -eq $owner['InvokeTask'] -and -not $state.ContainsKey('ActionEntered')) 'same original creation owner retains blocked initializer without launching worker task'
 $next=Invoke-ReviewOwnedWork -Kind stream_initializer -OwnerRegistry $registry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+[Diagnostics.Stopwatch]::Frequency) -WorkerName Invoke-NeverStreamWorker -Definitions $defs -State ([Collections.Concurrent.ConcurrentDictionary[string,object]]::new()) -Arguments @{}
 Assert-Eq $next.Failure.Code 'prior_owner_unresolved' 'blocked source-identity initializer fences subsequent work'
}finally{
 [GauntletOwnedWork.StreamGuard]::Release.Set()
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while($registry.Count -gt 0 -and $watch.ElapsedMilliseconds -lt 5000){$null=Complete-ReviewOwnedWork -OwnerRegistry $registry;Start-Sleep -Milliseconds 10}
}
Assert-True ($registry.Count -eq 0 -and $owner['CreationTask'].IsCompleted -and $owner['DisposeTask'].IsCompletedSuccessfully) 'explicit release retires exact original failed initializer pipeline through actual disposal'
Assert-True (-not $state.ContainsKey('ForbiddenAction') -and -not $result.Completed -and -not $result.Retired -and $null -eq $result.Result) 'late initializer failure cannot dispatch action or rewrite immutable returned failure'
Assert-True ($null -eq ('GauntletLive.Native' -as [type])) 'stream source-identity deadline test preserves cold native process type'
Write-TestResult
