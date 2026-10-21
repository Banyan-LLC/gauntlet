param([Parameter(Mandatory)][string]$RepoRoot,[string]$Source=(Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1'))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. $Source
. "$PSScriptRoot/dormant-native-facade-helper.ps1"
Initialize-LiveGateNative
Initialize-ReviewOwnedStreams
$script:FacadeOriginalRecord=(Get-Command New-ReviewReadOnlyRecord).ScriptBlock
$script:FacadeOriginalDefinitions=(Get-Command Get-ReviewWorkerDefinitions).ScriptBlock
$script:FacadeOriginalOwned=(Get-Command Invoke-ReviewOwnedWork).ScriptBlock
$script:FacadeSeen=$null
$script:FacadeMode=$null
$script:FacadePauseCalls=0
$script:FacadeRecordHook={
 param([Collections.IDictionary]$Values)
 if($Values.Contains('NativeProcessResult') -and $script:FacadePauseCalls -eq 0){
  $script:FacadePauseCalls++
  $seen=$script:FacadeSeen
  if($null -eq $seen -or -not $seen.Owner['RetirementConfirmed'] -or $seen.Owner['Registry'].Count -ne 0 -or -not $seen.Outcome.Completed -or -not $seen.Outcome.Retired){throw [InvalidOperationException]::new('Actual original native cohort must retire before facade projection gate')}
  $seen.Receipt=$Values['NativeProcessResult']
  $seen.GateEntered=[Diagnostics.Stopwatch]::GetTimestamp()
  while([Diagnostics.Stopwatch]::GetTimestamp() -le $seen.Deadline){[Threading.Thread]::Sleep(5)}
  [Threading.Thread]::Sleep(10)
  $seen.GateExited=[Diagnostics.Stopwatch]::GetTimestamp()
 }
 & $script:FacadeOriginalRecord -Values $Values
}
function Get-ReviewWorkerDefinitions {
 param([Parameter(Mandatory)][scriptblock]$LibraryDefinition)
 $definitions=& $script:FacadeOriginalDefinitions -LibraryDefinition $LibraryDefinition
 # Keep the complete original pack and original ScriptBlock.File metadata in the
 # actual worker. Only controller-side final DTO construction receives the gate.
 $definitions['Get-ReviewWorkerDefinitions']=$script:FacadeOriginalDefinitions
 $definitions['Invoke-ReviewOwnedWork']=$script:FacadeOriginalOwned
 $definitions['New-ReviewReadOnlyRecord']=$script:FacadeOriginalRecord
 Set-Item Function:script:New-ReviewReadOnlyRecord $script:FacadeRecordHook
 return $definitions
}
function Invoke-ReviewOwnedWork {
 param($Kind,$OwnerRegistry,$DeadlineTimestamp,$WorkerName,$Definitions,$Arguments,$State,$SharedVariables=@{})
 $outcome=& $script:FacadeOriginalOwned @PSBoundParameters
 $owner=$State['OwnedWorkOwner'];$actual=$State['Result']
 if($Kind -cne 'native_process' -or $null -eq $owner -or $null -eq $actual -or $actual.GetType() -ne [GauntletLive.Native+RunResult]){throw [InvalidOperationException]::new('Exact actual native result and original owner required')}
 if(-not $owner['RetirementConfirmed'] -or -not $owner['DisposeTask'].IsCompletedSuccessfully -or -not $outcome.Completed -or -not $outcome.Retired -or -not $actual.ProcessTreeRetired -or $actual.TimedOut){throw [InvalidOperationException]::new('Native and original generic resources must physically settle before final facade projection')}
 $primary=$actual.Failure;$first=$null
 if($script:FacadeMode -cin @('full','primary_duplicate','secondary_duplicate')){
  if($null -eq $primary -or -not $actual.StartFailed -or $actual.CleanupFailures.Count -ne 0){throw [InvalidOperationException]::new('Actual native startup cause required before diagnostic-storage injection')}
  $safe=[GauntletLive.Native].GetMethod('SafeFailure',[Reflection.BindingFlags]'NonPublic,Static',$null,[type[]]@([string],[string],[Exception]),$null)
  $first=$safe.Invoke($null,@('fixture_first_secondary','fixture_diagnostic_storage',[IO.IOException]::new('First diagnostic storage control')))
  $later=$safe.Invoke($null,@('fixture_later_secondary','fixture_diagnostic_storage',[IO.IOException]::new('Later diagnostic storage control')))
  $stored=switch($script:FacadeMode){'full'{@($first,$later)};'primary_duplicate'{@($primary,$first)};'secondary_duplicate'{@($first,$first)}}
  $actual.CleanupFailures=[GauntletLive.Native+NativeFailure[]]$stored
 }
 $scalars=Get-FacadeNativeScalars $actual
 $script:FacadeSeen=@{State=$State;Owner=$owner;Actual=$actual;Outcome=$outcome;Deadline=$DeadlineTimestamp;Scalars=$scalars;Primary=$primary;First=$first;Stored=$actual.CleanupFailures;Receipt=$null;GateEntered=0L;GateExited=0L}
 return $outcome
}
$records=[Collections.Generic.List[object]]::new()
try{
 foreach($mode in @('success','native_failure','full','primary_duplicate','secondary_duplicate')){
  $script:FacadeMode=$mode;$script:FacadeSeen=$null;$script:FacadePauseCalls=0
  $registry=Get-ReviewOwnerRegistry ReviewProcessOwners
  if($registry.Count -ne 0){throw [InvalidOperationException]::new('Fixture refuses unresolved prior original owner')}
  $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+6L*[Diagnostics.Stopwatch]::Frequency
  $executable=if($mode -ceq 'success'){Join-Path $env:SystemRoot 'System32/cmd.exe'}else{Join-Path $PSScriptRoot ('facade-never-'+[guid]::NewGuid().ToString('n')+'.exe')}
  $arguments=if($mode -ceq 'success'){@('/d','/c','exit','0')}else{@()}
  $result=Invoke-BoundedProcess -FileName $executable -ArgList $arguments -WorkingDirectory $PSScriptRoot -DeadlineTimestamp $deadline -RequireProcessTreeRetirement
  Set-Item Function:script:New-ReviewReadOnlyRecord $script:FacadeOriginalRecord
  $seen=$script:FacadeSeen;$owner=$seen.Owner;$state=$seen.State;$secondary=@($result.CleanupFailures)
  Assert-True ($script:FacadePauseCalls -eq 1 -and $seen.GateEntered -lt $deadline -and $seen.GateExited -gt $deadline) ($mode+': actual facade DTO seam crosses same original absolute deadline')
  Assert-True ([object]::ReferenceEquals($state['Result'],$seen.Actual) -and [object]::ReferenceEquals($state['OwnedWorkOwner'],$owner) -and [object]::ReferenceEquals($owner['State'],$state) -and $owner['Deadline'] -eq $deadline -and $state['Deadline'] -eq $deadline) ($mode+': exact original native result owner state and unchanged deadline retained')
  Assert-True ($result.ExitCode -eq -1 -and $result.TimedOut -and $result.ProcessTreeRetired -and $owner['RetirementConfirmed'] -and $registry.Count -eq 0 -and $owner['DisposeTask'].IsCompletedSuccessfully) ($mode+': aggregate late acceptance refuses while actual physical retirement stays true')
  Assert-True ($state['Abandoned'] -and $owner['Abandoned'] -and $owner['TimedOut'] -and $null -ne $owner['DeadlineFailure']) ($mode+': original authority irreversibly latches expiry')
  Assert-True ($result.IsReadOnly -and [object]::ReferenceEquals($result.NativeProcessResult,$seen.Receipt) -and $result.NativeProcessResult.IsReadOnly -and $result.NativeProcessResult.Keys.Count -eq 6) ($mode+': exact original immutable native six-field receipt survives aggregate rebuild')
  Assert-True (Test-FacadeNativeSix $result.NativeProcessResult $seen.Scalars) ($mode+': all six actual native scalar values remain unchanged')
  if($mode -ceq 'success'){
   Assert-True ($seen.Actual.ExitCode -eq 0 -and -not $seen.Actual.StartFailed -and -not $seen.Actual.TimedOut -and $seen.Actual.ProcessTreeRetired) 'success: actual original native job completed successfully before aggregate pause'
   Assert-True ($null -ne $result.Failure -and $result.Failure.Code -ceq 'owned_deadline' -and $secondary.Count -eq 0) 'success: final aggregate deadline is sole cause'
  }else{
   Assert-True (Test-FacadeFlatFault $result.Failure $seen.Primary) ($mode+': actual native startup primary survives final deadline refusal')
   Assert-True ($secondary.Count -ge 1 -and $secondary.Count -le 2 -and (Test-FacadeFlatFault $secondary[-1] $owner['DeadlineFailure'])) ($mode+': actual owning deadline reserved in bounded secondary ledger')
   if($null -ne $seen.First){Assert-True ($secondary.Count -eq 2 -and (Test-FacadeFlatFault $secondary[0] $seen.First) -and [object]::ReferenceEquals($seen.Actual.CleanupFailures,$seen.Stored)) ($mode+': earliest distinct secondary and original injected storage remain unchanged')}
  }
  Assert-True (Test-FacadeFlatLedger $result) ($mode+': aggregate fault ledger keeps exact immutable five-scalar schema')
  $records.Add(@{case=$mode;gate_before=$seen.GateEntered -lt $deadline;gate_after=$seen.GateExited -gt $deadline;aggregate_timeout=$result.TimedOut;native_timeout=$result.NativeProcessResult.TimedOut;retired=$result.ProcessTreeRetired;registry_count=$registry.Count;primary=$(if($null -ne $result.Failure){$result.Failure.Code}else{$null});secondary=@($secondary|ForEach-Object Code)})
 }
}finally{
 Set-Item Function:script:New-ReviewReadOnlyRecord $script:FacadeOriginalRecord
 Set-Item Function:script:Get-ReviewWorkerDefinitions $script:FacadeOriginalDefinitions
 Set-Item Function:script:Invoke-ReviewOwnedWork $script:FacadeOriginalOwned
}
Write-Output ('FACADE_PUBLICATION_CONTROL='+($records|ConvertTo-Json -Compress))
Write-TestResult
