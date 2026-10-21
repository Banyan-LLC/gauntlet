# Runs in the actual native case's scope; only the intentionally held callback
# mode changes assertions. Native/stream setup and named-pipe custody are shared.
$elapsed=([Diagnostics.Stopwatch]::GetTimestamp()-[StreamNativeCancellationFixture]::RefusedAt)*1000/[Diagnostics.Stopwatch]::Frequency
Assert-True ([StreamNativeCancellationFixture]::CallbackEntered.IsSet -and -not [StreamNativeCancellationFixture]::CallbackRelease.IsSet -and -not [StreamNativeCancellationFixture]::Producer.IsCompleted) 'original caller callback remains physically blocked after native execution returns'
Assert-True ($elapsed -lt 1500) 'original invocation returns promptly while exact original caller callback remains blocked'
Assert-True ([StreamNativeCancellationFixture]::NativeAliveAtRefusal -and $null -eq [StreamNativeCancellationFixture]::ProducerFailure) 'original caller cancellation starts while actual native child is pending'
Assert-True ([object]::ReferenceEquals($state['Result'],[StreamNativeCancellationFixture]::OriginalNativeResult) -and $state['Result'].ProcessTreeRetired -and -not $state['Result'].TimedOut) 'exact original native receipt retires independently of pending callback cohort'
$custody=[StreamNativeCancellationFixture]::OriginalNativeCustody
Assert-True ($null -ne $custody -and $custody.JobClosed -and $custody.CleanupTask.IsCompletedSuccessfully -and $custody.CleanupExpired -eq 0) 'original native registration and cleanup physically settle before callback release'
Assert-True ($state['Settled'] -and $state['CoreRetired'] -and $owner['InvokeTask'].IsCompleted) 'original worker finalization never waits on source registration Dispose'
Assert-True ($null -ne $owner['DisposeTask'] -and $owner['DisposeTask'].IsCompletedSuccessfully -and $owner['OutputDisposed'] -and $owner['StreamGuardDisposed']) 'independent original pipeline output and guard disposal settle while callback cohort remains retained'
Assert-True (-not (Get-ReviewOwnedWorkRetirement -State $rootState).Retired -and -not (Get-ReviewProcessRetirement -State $state).Retired -and $owner['Registry'].Count -eq 1 -and -not $owner['RetirementConfirmed']) 'native and generic retirement retain the same original pending callback cohort'
Assert-True (-not $result.ProcessTreeRetired -and -not $result.TimedOut -and $result.ExitCode -eq -1) 'immutable native facade refuses retirement without inventing deadline expiry'
Assert-True ([object]::ReferenceEquals($owner['Registry'][$owner['Token']],$owner) -and $state['Deadline'] -le $owner['Deadline']) 'pending callback keeps exact original owner token registry and deadline'
$link=$state['NativeFailureCancellation']
$signal=if($link -is [Threading.CancellationTokenSource]){$link}else{$link.GetType().GetField('signal',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($link)}
$disposed=[Threading.CancellationTokenSource].GetField('_disposed',[Reflection.BindingFlags]'Instance,NonPublic')
Assert-True (-not [bool]$disposed.GetValue($signal) -and -not $state['NativeFailureCancellationDisposed']) 'exact signal source remains owned and undisposed while original callback executes'
[StreamNativeCancellationFixture]::CallbackRelease.Set()
Assert-True ([StreamNativeCancellationFixture]::Producer.Wait((Get-ReviewRemainingMilliseconds $fixtureDeadline)) -and $null -eq [StreamNativeCancellationFixture]::ProducerFailure) 'explicit release physically settles original caller callback task'
$poll=[Diagnostics.Stopwatch]::StartNew()
while(-not $owner['RetirementConfirmed'] -and $poll.ElapsedMilliseconds -lt 3000 -and (Get-ReviewRemainingMilliseconds $fixtureDeadline) -gt 0){$null=Complete-ReviewOwnedWork -OwnerRegistry $owner['Registry'] -Token $owner['Token'];Start-Sleep -Milliseconds 5}
Assert-True ($state['NativeFailureCancellationDisposed'] -and [bool]$disposed.GetValue($signal)) 'same original signal source disposes only after callback completion'
Assert-True ((Get-ReviewOwnedWorkRetirement -State $rootState).Retired -and (Get-ReviewProcessRetirement -State $state).Retired -and $owner['Registry'].Count -eq 0 -and $owner['RetirementConfirmed']) 'same original callback release permits truthful native and generic owner retirement'
Assert-True (-not $result.ProcessTreeRetired -and -not $result.TimedOut -and $result.ExitCode -eq -1) 'later physical retirement never rewrites earlier immutable native refusal'
if($Inline){Assert-True (-not $rootOutcome.Retired -and [object]::ReferenceEquals($rootState['Result'],$result)) 'inline original outcome preserves its earlier immutable native refusal'}
[ordered]@{runtime=$PSVersionTable.PSVersion.ToString();kind='caller_cohort';inline=[bool]$Inline;elapsed_after_cancel_ms=[long]$elapsed;native_pid=[StreamNativeCancellationFixture]::NativePid;native_deadline=$custody.Deadline;owner_deadline=$owner['Deadline'];native_retired=$state['Result'].ProcessTreeRetired;link_disposed=$state['NativeFailureCancellationDisposed'];original_owner_retired=$owner['RetirementConfirmed'];original_owner_registry_count=$owner['Registry'].Count;returned_aggregate_retired=$result.ProcessTreeRetired;returned_timeout=$result.TimedOut}|ConvertTo-Json -Compress|Write-Output
