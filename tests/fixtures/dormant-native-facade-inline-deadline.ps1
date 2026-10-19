param([Parameter(Mandatory)][string]$RepoRoot,[string]$Source=(Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1'))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. $Source
. "$PSScriptRoot/dormant-native-facade-helper.ps1"
Initialize-LiveGateNative
Initialize-ReviewOwnedStreams
function Invoke-FacadeInlineWorker {
 param($State,$Arguments)
 $script:FacadeInlineOuter=$State
 $script:FacadeInlineOriginalWorker=(Get-Command Invoke-ReviewProcessWorker).ScriptBlock
 $script:FacadeInlineOriginalRecord=(Get-Command New-ReviewReadOnlyRecord).ScriptBlock
 $capture={
  param($State,$Arguments)
  $script:FacadeInlineOuter['InnerState']=$State
  & $script:FacadeInlineOriginalWorker -State $State -Arguments $Arguments
 }
 $record={
  param([Collections.IDictionary]$Values)
  if($Values.Contains('NativeProcessResult') -and -not $script:FacadeInlineOuter.ContainsKey('GateEntered')){
   $outer=$script:FacadeInlineOuter;$inner=$outer['InnerState'];$actual=$inner['Result']
   if($null -eq $actual -or $actual.GetType() -ne [GauntletLive.Native+RunResult] -or $actual.ExitCode -ne 0 -or -not $actual.ProcessTreeRetired -or $actual.TimedOut){throw [InvalidOperationException]::new('Actual successful inline native job required before final aggregate gate')}
   $outer['ActualNative']=$actual;$outer['Receipt']=$Values['NativeProcessResult'];$outer['NativeScalars']=Get-FacadeNativeScalars $actual
   $outer['GateEntered']=[Diagnostics.Stopwatch]::GetTimestamp()
   while([Diagnostics.Stopwatch]::GetTimestamp() -le [long]$outer['InnerDeadline']){[Threading.Thread]::Sleep(5)}
   [Threading.Thread]::Sleep(10)
   $outer['GateExited']=[Diagnostics.Stopwatch]::GetTimestamp()
  }
  & $script:FacadeInlineOriginalRecord -Values $Values
 }
 try{
  Set-Item Function:script:Invoke-ReviewProcessWorker $capture
  Set-Item Function:script:New-ReviewReadOnlyRecord $record
  $innerDeadline=if($Arguments.Mode -ceq 'healthy_parent'){[Diagnostics.Stopwatch]::GetTimestamp()+4L*[Diagnostics.Stopwatch]::Frequency}else{[long]$State['Deadline']}
  $State['InnerDeadline']=$innerDeadline
  $State['InnerResult']=Invoke-BoundedProcess -FileName $Arguments.Executable -ArgList @('/d','/c','exit','0') -WorkingDirectory $Arguments.WorkingDirectory -DeadlineTimestamp $innerDeadline -RequireProcessTreeRetirement
 }finally{
  Set-Item Function:script:Invoke-ReviewProcessWorker $script:FacadeInlineOriginalWorker
  Set-Item Function:script:New-ReviewReadOnlyRecord $script:FacadeInlineOriginalRecord
  $State['CoreRetired']=$true
 }
}
$records=[Collections.Generic.List[object]]::new()
foreach($mode in @('healthy_parent','expired_parent')){
 $definitions=Get-ReviewWorkerDefinitions -LibraryDefinition (Get-Command Invoke-BoundedProcess).ScriptBlock
 $definitions['Invoke-FacadeInlineWorker']=(Get-Command Invoke-FacadeInlineWorker).ScriptBlock
 $definitions['Get-FacadeNativeScalars']=(Get-Command Get-FacadeNativeScalars).ScriptBlock
 $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
 $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal)
 $seconds=if($mode -ceq 'healthy_parent'){20L}else{6L}
 $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+$seconds*[Diagnostics.Stopwatch]::Frequency
 $arguments=@{Mode=$mode;Executable=(Join-Path $env:SystemRoot 'System32/cmd.exe');WorkingDirectory=$PSScriptRoot}
 $outcome=Invoke-ReviewOwnedWork -Kind 'facade_inline' -OwnerRegistry $registry -DeadlineTimestamp $deadline -WorkerName Invoke-FacadeInlineWorker -Definitions $definitions -Arguments $arguments -State $state
 $owner=$state['OwnedWorkOwner']
 # Physical late settlement is observed against the same retained original tasks.
 # It cannot rescue acceptance or replace either original absolute deadline.
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while(-not $owner['RetirementConfirmed'] -and $watch.ElapsedMilliseconds -lt 3000){$null=Complete-ReviewOwnedWork -OwnerRegistry $registry -Token $owner['Token'];[Threading.Thread]::Sleep(5)}
 $inner=$state['InnerState'];$result=$state['InnerResult'];$actual=$state['ActualNative'];$receipt=$state['Receipt']
 Assert-True ($state['GateEntered'] -lt $state['InnerDeadline'] -and $state['GateExited'] -gt $state['InnerDeadline']) ($mode+': final inline aggregate crosses exact original child deadline')
 Assert-True ([object]::ReferenceEquals($inner['Result'],$actual) -and $inner['Deadline'] -eq $state['InnerDeadline'] -and $owner['Deadline'] -eq $deadline -and $state['Deadline'] -eq $deadline) ($mode+': local native result and both original deadline authorities remain unchanged')
 Assert-True ($result.ExitCode -eq -1 -and $result.TimedOut -and $result.ProcessTreeRetired -and $inner['Abandoned'] -and $owner['RetirementConfirmed'] -and $registry.Count -eq 0) ($mode+': inline aggregate refuses late success while exact physical resources settle')
 Assert-True ($null -ne $result.Failure -and $result.Failure.Code -ceq 'owned_deadline' -and (Test-FacadeFlatLedger $result) -and $result.CleanupFailures.Count -eq 0) ($mode+': inline deadline refusal preserves exact flat immutable primary')
 Assert-True ([object]::ReferenceEquals($result.NativeProcessResult,$receipt) -and (Test-FacadeNativeSix $receipt $state['NativeScalars']) -and $receipt.ExitCode -eq 0 -and -not $receipt.StartFailed -and -not $receipt.TimedOut -and $receipt.ProcessTreeRetired -and $actual.ExitCode -eq 0 -and $actual.ProcessTreeRetired) ($mode+': actual successful native six-scalar receipt remains original')
 if($mode -ceq 'healthy_parent'){
  Assert-True ($state['InnerDeadline'] -lt $deadline -and -not $owner['TimedOut'] -and -not $owner['Abandoned'] -and -not $state['Abandoned'] -and $null -eq $owner['DeadlineFailure'] -and $outcome.Completed -and $outcome.Retired -and -not $outcome.TimedOut) 'healthy_parent: shorter child expiry cannot manufacture parent expiry or abandonment'
 }else{
  Assert-True ($state['InnerDeadline'] -eq $deadline -and $owner['TimedOut'] -and $owner['Abandoned'] -and $state['Abandoned'] -and $null -ne $owner['DeadlineFailure'] -and $owner['DeadlineFailure'].Code -ceq 'owned_deadline' -and $outcome.TimedOut -and -not $outcome.Completed) 'expired_parent: actual inherited parent deadline latches original parent failure independently of physical settlement'
 }
 $records.Add(@{case=$mode;child_deadline=$state['InnerDeadline'];parent_deadline=$deadline;aggregate_timeout=$result.TimedOut;native_timeout=$receipt.TimedOut;parent_timeout=$owner['TimedOut'];parent_abandoned=$owner['Abandoned'];parent_code=$(if($null -ne $owner['DeadlineFailure']){$owner['DeadlineFailure'].Code}else{$null});retired=$owner['RetirementConfirmed'];registry_count=$registry.Count})
}
Write-Output ('INLINE_FACADE_PUBLICATION_CONTROL='+($records|ConvertTo-Json -Compress))
Write-TestResult
