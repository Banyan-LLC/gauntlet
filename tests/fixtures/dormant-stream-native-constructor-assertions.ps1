# Shared actual facade setup; only original registration failure/cancellation changes.
$unknown=$ConstructorCase -ceq 'unknown'
$poll=[Diagnostics.Stopwatch]::StartNew()
while(-not $owner['DisposeTask'] -or -not $owner['DisposeTask'].IsCompleted){
 if($poll.ElapsedMilliseconds -ge 2000 -or (Get-ReviewRemainingMilliseconds $fixtureDeadline) -le 0){break}
 $null=Complete-ReviewOwnedWork -OwnerRegistry $owner['Registry'] -Token $owner['Token'];Start-Sleep -Milliseconds 5
}
$null=Complete-ReviewOwnedWork -OwnerRegistry $owner['Registry'] -Token $owner['Token']
$link=$state['NativeFailureCancellation']
if($null -eq $link){
 foreach($key in @('CreationTask','StreamInitializationTask','InvokeTask')){
  $task=$owner[$key];if($null -ne $task -and $task.IsFaulted){Write-Output ($key+': '+$task.Exception.ToString())}
 }
 throw 'Expected actual state-published constructor link; initialization fault above is a fixture failure'
}
$signal=$link.GetType().GetField('signal',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($link)
$disposed=[Threading.CancellationTokenSource].GetField('_disposed',[Reflection.BindingFlags]'Instance,NonPublic')
Assert-True ($null -ne $link -and [object]::ReferenceEquals($owner['State'],$state)) 'constructor publishes exact original cancellation scope before registration'
Assert-True ($state['Settled'] -and $state['CoreRetired'] -and $owner['InvokeTask'].IsCompleted -and $owner['DisposeTask'].IsCompletedSuccessfully) 'actual original worker and independent owned resources settle after constructor control'
Assert-True ([StreamNativeCancellationFixture]::NativePid -eq 0 -and $null -eq [StreamNativeCancellationFixture]::Producer) 'constructor control launches no child or diagnostic producer'
Assert-True ($result.ExitCode -eq -1 -and -not $result.TimedOut -and $null -ne $result.Failure) 'constructor control returns immutable bounded refusal without deadline substitution'
if($unknown){
 Assert-True ($state['NativeNeverStarted'] -and $null -eq $state['Result']) 'unknown registration never enters native execution'
 Assert-True (-not $link.IsDisposed -and -not $state['NativeFailureCancellationDisposed'] -and -not [bool]$disposed.GetValue($signal)) 'attempt without registration receipt retains exact undisposed signal'
 Assert-True (-not (Get-ReviewProcessRetirement -State $state).Retired -and -not (Get-ReviewOwnedWorkRetirement -State $state).Retired -and -not $result.ProcessTreeRetired) 'unknown callback receipt truthfully refuses native generic and returned aggregate retirement'
 Assert-True ($owner['Registry'].Count -eq 1 -and [object]::ReferenceEquals($owner['Registry'][$owner['Token']],$owner) -and -not $owner['RetirementConfirmed']) 'unknown registration retains original owner custody without replacement authority'
 $caller.Cancel();$null=Complete-ReviewOwnedWork -OwnerRegistry $owner['Registry'] -Token $owner['Token']
 Assert-True (-not $link.IsDisposed -and $owner['Registry'].Count -eq 1) 'later caller cancellation cannot manufacture missing original registration receipt'
}else{
 Assert-True ($link.IsDisposed -and $state['NativeFailureCancellationDisposed'] -and [bool]$disposed.GetValue($signal)) 'explicit none or unregistered original entries permit actual signal disposal'
 Assert-True ((Get-ReviewProcessRetirement -State $state).Retired -and (Get-ReviewOwnedWorkRetirement -State $state).Retired -and $result.ProcessTreeRetired) 'constructor synchronous and partial-registration paths truthfully retire original native and generic scopes'
 Assert-True ($owner['Registry'].Count -eq 0 -and $owner['RetirementConfirmed']) 'constructor retirement releases only exact original registry entry'
 if($ConstructorCase -ceq 'precanceled'){
  Assert-True (-not $state['NativeNeverStarted'] -and $state['Result'].StartFailed -and $state['Result'].ProcessTreeRetired -and -not $state['Result'].TimedOut) 'already canceled caller executes synchronous link callback before actual native prelaunch refusal'
  Assert-True ($result.NativeProcessResult.IsReadOnly -and $result.NativeProcessResult.Keys.Count -eq 6) 'prelaunch native refusal preserves exact immutable native receipt shape'
 }else{
  Assert-True ($state['NativeNeverStarted'] -and $null -eq $state['Result']) 'partial registration failure never enters native execution'
 }
}
[ordered]@{runtime=$PSVersionTable.PSVersion.ToString();kind='constructor';case=$ConstructorCase;native_never_started=$state['NativeNeverStarted'];signal_disposed=$link.IsDisposed;native_retired=(Get-ReviewProcessRetirement -State $state).Retired;generic_retired=(Get-ReviewOwnedWorkRetirement -State $state).Retired;aggregate_retired=$result.ProcessTreeRetired;registry_count=$owner['Registry'].Count;owner_deadline=$owner['Deadline'];state_deadline=$state['Deadline']}|ConvertTo-Json -Compress|Write-Output
