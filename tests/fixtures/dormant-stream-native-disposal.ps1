param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$Source)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. $Source
Add-Type -TypeDefinition @'
using System;
public sealed class StreamNativeDisposalResource:IDisposable {
 public int Calls;
 readonly bool fail;
 public StreamNativeDisposalResource(bool value){fail=value;}
 public void Dispose(){Calls++;if(fail)throw new System.IO.IOException("independent disposal failure");}
}
'@
# Break caught: adding guard lifetime must not omit it when a prior independently
# owned pipeline or output disposer throws, or conceal its own actual failure.
foreach($pipelineFails in @($false,$true)){
 foreach($outputFails in @($false,$true)){
  foreach($guardFails in @($false,$true)){
   $pipeline=[StreamNativeDisposalResource]::new($pipelineFails)
   $output=[StreamNativeDisposalResource]::new($outputFails)
   $guard=[StreamNativeDisposalResource]::new($guardFails)
   $owner=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
   $owner['Output']=$output;$owner['StreamGuard']=$guard
   $task=Start-ReviewPipelineDisposal -Owner $owner -Pipeline $pipeline
   try{$null=$task.Wait(3000)}catch{}
   Assert-True ($task.IsCompleted -and [object]::ReferenceEquals($owner['DisposeTask'],$task)) 'one exact retained original disposal task settles'
   Assert-True ($pipeline.Calls -eq 1 -and $output.Calls -eq 1 -and $guard.Calls -eq 1) 'all three exact independent resources get one disposal attempt despite earlier failures'
   Assert-True (($owner['PipelineDisposed'] -is [bool] -and $owner['PipelineDisposed']) -eq (-not $pipelineFails)) 'pipeline physical disposition matches actual disposer result'
   Assert-True (($owner['OutputDisposed'] -is [bool] -and $owner['OutputDisposed']) -eq (-not $outputFails)) 'output physical disposition matches actual disposer result'
   Assert-True (($owner['StreamGuardDisposed'] -is [bool] -and $owner['StreamGuardDisposed']) -eq (-not $guardFails)) 'guard physical disposition matches actual disposer result'
   Assert-True (($null -ne $owner['PipelineDisposalException']) -eq $pipelineFails -and ($null -ne $owner['OutputDisposalException']) -eq $outputFails -and ($null -ne $owner['StreamGuardDisposalException']) -eq $guardFails) 'each independent actual disposal exception remains with original owner'
   Assert-True ($task.IsCompletedSuccessfully -eq (-not ($pipelineFails -or $outputFails -or $guardFails))) 'any unresolved independent resource prevents successful original disposal'
  }
 }
}
Assert-True ($null -eq ('GauntletLive.Native' -as [type])) 'disposal controls preserve cold native type'
Write-TestResult
