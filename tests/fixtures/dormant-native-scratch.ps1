param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. "$PSScriptRoot/dormant-scratch-helper.ps1"
function New-ControlOwner([string]$Prefix){New-DormantScratchOwner -Prefix $Prefix -TimeoutSec 90}
# Keep the exact Begin submission before any body work can fail.
function New-ScratchFixtureObservation($Owner,[ValidateSet('write','cleanup')][string]$Kind){
 @{Owner=$Owner;Kind=$Kind;BeforeTask=$null;Task=$null;SubmissionAttempted=$false;Attempted=$false;Consumed=$false;Accepted=$false;Error=$null}
}
function Start-ScratchFixtureObservation($Observation,[string]$Name,[string]$Text){
 $Observation.BeforeTask=$Observation.Owner.OriginalTask;$Observation.SubmissionAttempted=$true
 try{if($Observation.Kind -eq 'write'){$Observation.Owner.BeginWriteText($Name,$Text)}else{$Observation.Owner.BeginCleanup()}}
 finally{
  $submitted=$Observation.Owner.OriginalTask
  if(-not [object]::ReferenceEquals($submitted,$Observation.BeforeTask)){$Observation.Task=$submitted}
 }
}
function Wait-ScratchFixtureObservation($Observation){
 if($null -eq $Observation -or $Observation.Consumed -or -not $Observation.SubmissionAttempted -or $null -eq $Observation.Task){return}
 if(-not [object]::ReferenceEquals($Observation.Task,$Observation.Owner.OriginalTask)){throw [InvalidOperationException]::new('Exact fixture submission changed before observation')}
 $Observation.Attempted=$true
 try{if($Observation.Kind -eq 'write'){$Observation.Owner.WaitWriteText()}else{$Observation.Owner.WaitCleanup()}}
 catch{$Observation.Error=$_.Exception;throw}
 finally{$Observation.Consumed=$true}
}
function Accept-ScratchFixtureObservation($Observation,[int]$CaseFailureCount){
 # Assertions record failure without throwing. Expected faults are accepted only
 # after all remaining body IO and assertions have completed successfully.
 if($script:Failures.Count -eq $CaseFailureCount -and $Observation.Consumed -and $null -ne $Observation.Error){$Observation.Accepted=$true}
}
function Complete-ScratchFixtureObservation($Primary,$Observation,[scriptblock]$Release,[scriptblock[]]$AfterObservation){
 $actions=@($Release,{
  if($null -eq $Observation -or $Observation.Accepted){return}
  if(-not $Observation.Consumed){Wait-ScratchFixtureObservation $Observation}
  elseif($null -ne $Observation.Error -and ($null -eq $Primary -or -not [object]::ReferenceEquals($Primary.Exception,$Observation.Error))){
   # Current OriginalTask may be a later legitimate observation. Replay only
   # the immutable captured raw cause; never re-Wait or clear original history.
   throw $Observation.Error
  }
 })+$AfterObservation
 Complete-DormantScratchCleanup -Primary $Primary -Actions $actions
}
$owner=New-ControlOwner 'scratch-original';$firstDeadline=$owner.Deadline
$primary=$null
try{
 $owner.Initialize();$owner.WriteText('original.txt','original sealed bytes')
 $moved=Join-Path $owner.Path 'moved.txt';$failure=$null
 try{[IO.File]::Move($owner.FilePath('original.txt'),$moved)}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and $owner.ReadText('original.txt') -ceq 'original sealed bytes') 'original leaf seal refuses actual rename and preserves original content'
 $failure=$null
 try{[IO.Directory]::Move($owner.Path,$owner.Path+'-replacement')}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure) 'held original root and ancestor handles refuse parent substitution'
 $failure=$null
 try{$owner.WriteText('original.txt','overwritten')}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and [IO.File]::ReadAllText($owner.FilePath('original.txt')) -ceq 'original sealed bytes') 'create-only writer cannot truncate its original or a preexisting leaf'
}catch{$primary=$_;throw}finally{Complete-DormantScratchCleanup -Primary $primary -Actions @({$owner.Cleanup()})}
Assert-True ($owner.Retired -and $owner.Deadline -eq $firstDeadline -and $owner.OriginalTask.IsCompletedSuccessfully) 'original scratch disposal verifies root removal without resetting its deadline'

$owner=New-ControlOwner 'scratch-seal-bytes'
$observation=New-ScratchFixtureObservation $owner 'write'
$caseFailureCount=$script:Failures.Count
$primary=$null
try{
 $owner.Initialize();$owner.BeforeSealEntered=[Threading.ManualResetEventSlim]::new($false);$owner.ContinueSeal=[Threading.ManualResetEventSlim]::new($false)
 Start-ScratchFixtureObservation $observation 'seeded.txt' 'expected';$task=$observation.Task
 Assert-True ($owner.BeforeSealEntered.Wait(3000)) 'original creation task reaches exact seal-handoff barrier'
 $writer=[IO.FileStream]::new($owner.FilePath('seeded.txt'),[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
 $writerPrimary=$null
 try{$bytes=[Text.Encoding]::UTF8.GetBytes('mutated!');$writer.Write($bytes,0,$bytes.Length);$writer.Flush()}catch{$writerPrimary=$_;throw}finally{Complete-DormantScratchCleanup -Primary $writerPrimary -Actions @({$writer.Dispose()})}
 $owner.ContinueSeal.Set();$failure=$null;try{Wait-ScratchFixtureObservation $observation}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and $failure.GetBaseException() -is [IO.IOException] -and $task.IsFaulted -and -not $owner.Retired) 'actual write during seal handoff refuses original creation acceptance after byte verification'
 Accept-ScratchFixtureObservation $observation $caseFailureCount
}catch{$primary=$_;throw}finally{Complete-ScratchFixtureObservation -Primary $primary -Observation $observation -Release {if($null -ne $owner.ContinueSeal){$owner.ContinueSeal.Set()}} -AfterObservation @({$owner.Cleanup()})}
Assert-True $owner.Retired 'failed original sealed bytes retain custody until exact original root cleanup'

$owner=New-ControlOwner 'scratch-seal-binding';$replacement=$null
$observation=New-ScratchFixtureObservation $owner 'write'
$caseFailureCount=$script:Failures.Count
$primary=$null
try{
 $owner.Initialize();$owner.BeforeSealEntered=[Threading.ManualResetEventSlim]::new($false);$owner.ContinueSeal=[Threading.ManualResetEventSlim]::new($false)
 Start-ScratchFixtureObservation $observation 'seeded.txt' 'expected';$task=$observation.Task
 Assert-True ($owner.BeforeSealEntered.Wait(3000)) 'original creation remains retained across name-binding handoff'
 [IO.File]::Move($owner.FilePath('seeded.txt'),$owner.FilePath('moved.txt'))
 $replacement=[IO.FileStream]::new($owner.FilePath('seeded.txt'),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
 $bytes=[Text.Encoding]::UTF8.GetBytes('expected');$replacement.Write($bytes,0,$bytes.Length);$replacement.Flush()
 $owner.ContinueSeal.Set();$failure=$null;try{Wait-ScratchFixtureObservation $observation}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and ($failure.GetBaseException() -is [IO.IOException] -or $failure.GetBaseException() -is [ComponentModel.Win32Exception]) -and $task.IsFaulted) 'identical replacement bytes cannot substitute for exact original creation identity'
 $failure=$null;try{$owner.Cleanup()}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and -not $owner.Retired -and $replacement.CanRead) 'creation refusal never adopts or deletes the independently owned replacement'
 Assert-True (-not $owner.ControlDeletePending($replacement)) 'creation refusal leaves replacement original handle undisposed and not delete-pending'
 Assert-True ($owner.VerifyAbsent('moved.txt')) 'creation refusal still disposes original renamed creation by original handle'
 Accept-ScratchFixtureObservation $observation $caseFailureCount
}catch{$primary=$_;throw}finally{Complete-ScratchFixtureObservation -Primary $primary -Observation $observation -Release {if($null -ne $owner.ContinueSeal){$owner.ContinueSeal.Set()}} -AfterObservation @({if($null -ne $replacement){$owner.RemoveControlFile('seeded.txt',$replacement)}},{$owner.Cleanup()})}
Assert-True $owner.Retired 'creation identity refusal reconciles only after separate replacement owner physically retires'

# Drop only the cleanup seal at a retained original-worker barrier, then replace
# its pathname. The adversary's create-only stream owns its own
# replacement object; explicit original-handle disposition is its cleanup authority.
$owner=New-ControlOwner 'scratch-replacement';$replacement=$null
$observation=New-ScratchFixtureObservation $owner 'cleanup'
$caseFailureCount=$script:Failures.Count
$primary=$null
try{
 $owner.Initialize();$owner.WriteText('original.txt','original')
 $owner.BeforeDeleteEntered=[Threading.ManualResetEventSlim]::new($false)
 $owner.ContinueDelete=[Threading.ManualResetEventSlim]::new($false)
 Start-ScratchFixtureObservation $observation;$task=$observation.Task
 Assert-True ($owner.BeforeDeleteEntered.Wait(3000)) 'actual original cleanup worker pauses after releasing only its original leaf seal'
 $failure=$null;try{$owner.WriteText('forbidden.txt','new')}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and [object]::ReferenceEquals($task,$owner.OriginalTask)) 'pending original cleanup refuses new work without replacing its task authority'
 [IO.File]::Move($owner.FilePath('original.txt'),$owner.FilePath('moved.txt'))
 $replacement=[IO.FileStream]::new($owner.FilePath('original.txt'),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
 $bytes=[Text.Encoding]::UTF8.GetBytes('replacement');$replacement.Write($bytes,0,$bytes.Length);$replacement.Flush()
 $owner.ContinueDelete.Set();$failure=$null;try{Wait-ScratchFixtureObservation $observation}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and -not $owner.Retired -and $task.IsCompleted -and [object]::ReferenceEquals($task,$owner.OriginalTask)) 'actual replacement refuses cleanup acceptance while original worker physically settles'
 $replacement.Position=0;$seen=[byte[]]::new(11);$count=$replacement.Read($seen,0,$seen.Length)
 Assert-True ($count -eq 11 -and [Text.Encoding]::UTF8.GetString($seen) -ceq 'replacement') 'original-handle disposition never deletes or truncates substituted replacement object'
 Assert-True (-not $owner.ControlDeletePending($replacement)) 'cleanup does not mark substituted original control delete-pending'
 Assert-True ($owner.VerifyAbsent('moved.txt')) 'the renamed original object is disposed through its retained original handle'
 Accept-ScratchFixtureObservation $observation $caseFailureCount
}catch{$primary=$_;throw}finally{
 Complete-ScratchFixtureObservation -Primary $primary -Observation $observation -Release {if($null -ne $owner.ContinueDelete){$owner.ContinueDelete.Set()}} -AfterObservation @({if($null -ne $replacement){$owner.RemoveControlFile('original.txt',$replacement)}},{$owner.Cleanup()})
}
Assert-True $owner.Retired 'explicit later cleanup verifies original root after independent replacement owner retires'

$owner=New-ControlOwner 'scratch-lookup';$held=$null
$primary=$null
try{
 $owner.Initialize()
 $held=[IO.FileStream]::new($owner.FilePath('lookup.txt'),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Delete)
 $failure=$null;try{$owner.VerifyAbsent('lookup.txt')|Out-Null}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and $failure.GetBaseException() -is [ComponentModel.Win32Exception] -and $failure.GetBaseException().NativeErrorCode -eq 32) 'actual native lookup sharing violation cannot collapse to missing'
}catch{$primary=$_;throw}finally{Complete-DormantScratchCleanup -Primary $primary -Actions @({if($null -ne $held){$owner.RemoveControlFile('lookup.txt',$held)}},{$owner.Cleanup()})}
Assert-True $owner.Retired 'lookup-error control retains original custody until actual independent handle release'

$outside=New-ControlOwner 'scratch-outside';$parent=New-ControlOwner 'scratch-reparse';$nested=$null
$primary=$null
try{
 $outside.Initialize();$outside.WriteText('sentinel.txt','outside unchanged')
 $parent.Initialize();$junction='scratch-redirect-'+[guid]::NewGuid().ToString('n');$parent.CreateSiblingJunctionControl($junction,$outside)
 $nested=New-DormantScratchOwner -Prefix scratch-never -TimeoutSec 90 -Path (Join-Path ($parent.SiblingPath($junction)) 'never-created')
 $failure=$null;try{$nested.Initialize()}catch{$failure=$_.Exception}
 if($null -ne $failure){[pscustomobject]@{case='actual_intermediate_reparse';type=$failure.GetBaseException().GetType().FullName;native=$(if($failure.GetBaseException() -is [ComponentModel.Win32Exception]){$failure.GetBaseException().NativeErrorCode}else{$null});message=$failure.GetBaseException().Message}|ConvertTo-Json -Compress|Write-Output}
 Assert-True ($null -ne $failure -and $failure.GetBaseException() -is [IO.IOException]) 'intermediate actual directory junction refuses before creating target root'
 Assert-True ($outside.VerifyAbsent('never-created') -and $outside.ReadText('sentinel.txt') -ceq 'outside unchanged') 'reparse refusal neither creates nor modifies the redirect target'
}catch{$primary=$_;throw}finally{
 Complete-DormantScratchCleanup -Primary $primary -Actions @({if($null -ne $nested){$nested.Cleanup()}},{$parent.Cleanup()},{$outside.Cleanup()})
}
Assert-True ($nested.Retired -and $parent.Retired -and $outside.Retired) 'partial no-follow initialization closes only its original handles and verifies owned roots'
# An early body primary must not skip the exact independent worker observer.
foreach($observationPoint in @('before','after')){
foreach($controlCase in @('seal-bytes','seal-binding','replacement')){
 $owner=New-ControlOwner ('scratch-early-'+$observationPoint+'-'+$controlCase);$originalDeadline=$owner.Deadline
 $observation=New-ScratchFixtureObservation $owner $(if($controlCase -eq 'replacement'){'cleanup'}else{'write'})
 $replacement=$null;$submittedTask=$null;$primary=$null;$escaped=$null
 $bodyObservation=@{Error=$null;PostReadTask=$null;PostReadValue=$null}
 $controlObservation=@{Error=$null;Task=$null;Handle=$null;ClosedAtFailure=$false}
 $injected=[IO.IOException]::new('EARLY-PS-PRIMARY-'+$observationPoint+'-'+$controlCase)
 try{
  try{
   $owner.Initialize()
   if($controlCase -eq 'replacement'){
    $owner.WriteText('original.txt','original');$owner.BeforeDeleteEntered=[Threading.ManualResetEventSlim]::new($false);$owner.ContinueDelete=[Threading.ManualResetEventSlim]::new($false)
    Start-ScratchFixtureObservation $observation
    if(-not $owner.BeforeDeleteEntered.Wait(3000)){throw [InvalidOperationException]::new('Early cleanup control did not reach its original gate')}
    [IO.File]::Move($owner.FilePath('original.txt'),$owner.FilePath('moved.txt'));$leafName='original.txt'
   }else{
    $owner.BeforeSealEntered=[Threading.ManualResetEventSlim]::new($false);$owner.ContinueSeal=[Threading.ManualResetEventSlim]::new($false)
    Start-ScratchFixtureObservation $observation 'seeded.txt' 'expected'
    if(-not $owner.BeforeSealEntered.Wait(3000)){throw [InvalidOperationException]::new('Early seal control did not reach its original gate')}
    $leafName='seeded.txt'
    if($controlCase -eq 'seal-binding'){[IO.File]::Move($owner.FilePath($leafName),$owner.FilePath('moved.txt'))}
   }
   $submittedTask=$observation.Task
   if($controlCase -eq 'seal-bytes'){
    $writer=[IO.FileStream]::new($owner.FilePath($leafName),[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete);$writerPrimary=$null
    try{$bytes=[Text.Encoding]::UTF8.GetBytes('mutated!');$writer.Write($bytes,0,$bytes.Length);$writer.Flush()}catch{$writerPrimary=$_;throw}finally{Complete-DormantScratchCleanup -Primary $writerPrimary -Actions @({$writer.Dispose()})}
   }else{
    $replacement=[IO.FileStream]::new($owner.FilePath($leafName),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    $controlObservation.Handle=$replacement.SafeFileHandle
    $bytes=[Text.Encoding]::UTF8.GetBytes('expected');$replacement.Write($bytes,0,$bytes.Length);$replacement.Flush()
   }
   if($observationPoint -eq 'after'){
    if($null -ne $owner.ContinueSeal){$owner.ContinueSeal.Set()};if($null -ne $owner.ContinueDelete){$owner.ContinueDelete.Set()}
    try{Wait-ScratchFixtureObservation $observation}catch{$bodyObservation.Error=$_.Exception}
    if($null -eq $bodyObservation.Error -or -not [object]::ReferenceEquals($bodyObservation.Error,$observation.Error)){throw [InvalidOperationException]::new('After-read control did not consume its exact original worker failure')}
    # This real observation advances current OriginalTask without altering the
    # captured failed task, raw Error or helper-owned replacement binding hold.
    if($null -ne $replacement){$bodyObservation.PostReadValue=$owner.ControlDeletePending($replacement)}else{$bodyObservation.PostReadValue=$owner.VerifyAbsent('unrelated-never-created.txt')}
    $bodyObservation.PostReadTask=$owner.OriginalTask
   }
   # Fail either before original observation or after reading its actual fault,
   # before any expected-error acceptance or remaining body checks/finalization.
   throw $injected
  }catch{$primary=$_;throw}finally{
   Complete-ScratchFixtureObservation -Primary $primary -Observation $observation -Release {if($null -ne $owner.ContinueSeal){$owner.ContinueSeal.Set()};if($null -ne $owner.ContinueDelete){$owner.ContinueDelete.Set()}} -AfterObservation @({if($null -ne $replacement){
    try{$owner.RemoveControlFile($leafName,$replacement)}
    catch{$controlObservation.Error=$_.Exception;$controlObservation.ClosedAtFailure=($null -ne $controlObservation.Handle -and $controlObservation.Handle.IsClosed);throw}
    finally{$controlObservation.Task=$owner.OriginalTask}
   }},{$owner.Cleanup()})
  }
 }catch{$escaped=$_.Exception}
 # Independently establish the terminal stimulus without calling the missing
 # matching owner observer or granting any replacement cleanup authority.
 $terminalWaitFailure=$null;$terminalSettled=$false
 if($null -ne $submittedTask){try{$terminalSettled=$submittedTask.Wait(3000)}catch{$terminalWaitFailure=$_.Exception;$terminalSettled=$submittedTask.IsCompleted}}
 $secondary=@();if($null -ne $escaped -and $escaped.Data.Contains('DormantFixtureCleanupFailures')){$secondary=@($escaped.Data['DormantFixtureCleanupFailures'])}
 $workerCause=$null;if($null -ne $submittedTask -and $submittedTask.IsFaulted){$workerCause=$submittedTask.Exception.GetBaseException()}
 $matching=@($secondary|Where-Object {[object]::ReferenceEquals($_,$observation.Error) -and $null -ne $workerCause -and [object]::ReferenceEquals($_.GetBaseException(),$workerCause)})
 $readEvidence=if($observationPoint -eq 'after'){[object]::ReferenceEquals($bodyObservation.Error,$observation.Error) -and $null -ne $bodyObservation.PostReadTask -and $bodyObservation.PostReadTask.IsCompletedSuccessfully -and -not [object]::ReferenceEquals($bodyObservation.PostReadTask,$submittedTask) -and $(if($null -ne $replacement){$bodyObservation.PostReadValue -is [bool] -and -not $bodyObservation.PostReadValue}else{$bodyObservation.PostReadValue -is [bool] -and $bodyObservation.PostReadValue})}else{$null -eq $bodyObservation.Error}
 Assert-True ([object]::ReferenceEquals($escaped,$injected)) ($observationPoint+'-'+$controlCase+' early finalization preserves the raw original primary')
 Assert-True ($observation.Attempted -is [bool] -and $observation.Attempted -and $observation.Consumed -is [bool] -and $observation.Consumed -and -not $observation.Accepted -and $readEvidence -and $matching.Count -eq 1) ($observationPoint+'-'+$controlCase+' early finalizer independently consumes its matching original worker failure as secondary')
 Assert-True ($null -ne $submittedTask -and [object]::ReferenceEquals($submittedTask,$observation.Task) -and $terminalSettled -and $submittedTask.IsCompleted -and $submittedTask.IsFaulted -and $owner.Deadline -eq $originalDeadline) ($observationPoint+'-'+$controlCase+' early finalization retains exact original task and deadline truth')
 # The binding fault retains the helper's exact replacement BindingHandle.
 # Its independently disposed control is delete-pending until owner cleanup
 # closes that hold: preserve the actual native5 absence refusal as well.
 $expectedSecondaryCount=if($controlCase -eq 'seal-binding'){2}else{1}
 $controlMatching=@();$controlEvidence=($null -eq $controlObservation.Error)
 if($controlCase -eq 'seal-binding'){
  $controlCause=$null;if($null -ne $controlObservation.Error){$controlCause=$controlObservation.Error.GetBaseException()}
  $controlMatching=@($secondary|Where-Object {[object]::ReferenceEquals($_,$controlObservation.Error) -and $controlCause -is [ComponentModel.Win32Exception] -and $controlCause.NativeErrorCode -eq 5 -and $null -ne $controlObservation.Task -and -not [object]::ReferenceEquals($controlObservation.Task,$submittedTask) -and $controlObservation.Task.IsCompleted -and $controlObservation.Task.IsFaulted -and [object]::ReferenceEquals($controlCause,$controlObservation.Task.Exception.GetBaseException())})
  $controlEvidence=($controlMatching.Count -eq 1 -and $controlObservation.ClosedAtFailure -and $null -ne $controlObservation.Handle -and $controlObservation.Handle.IsClosed)
 }elseif($null -ne $replacement){$controlEvidence=($null -eq $controlObservation.Error -and $null -ne $controlObservation.Handle -and $controlObservation.Handle.IsClosed -and $null -ne $controlObservation.Task -and $controlObservation.Task.IsCompletedSuccessfully)}
 $readonlySecondary=($null -ne $escaped -and $escaped.Data['DormantFixtureCleanupFailures'] -is [Collections.ObjectModel.ReadOnlyCollection[object]])
 Assert-True ($owner.Retired -and $readonlySecondary -and $secondary.Count -eq $expectedSecondaryCount -and $controlEvidence) ($observationPoint+'-'+$controlCase+' early finalization preserves every expected typed cause and physically closes original controls before final owner retirement')
 $secondaryRecords=@();foreach($error in $secondary){
  $phase=if([object]::ReferenceEquals($error,$observation.Error)){'observe-exact-original-operation'}elseif([object]::ReferenceEquals($error,$controlObservation.Error)){'original-replacement-control-cleanup'}else{'unexpected-independent-finalizer'}
  $secondaryRecords+=,[ordered]@{phase=$phase;error_type=$error.GetType().FullName;error=$error.ToString();base_error_type=$error.GetBaseException().GetType().FullName;base_error=$error.GetBaseException().ToString()}
 }
 [ordered]@{control='early_powershell_primary';case=$controlCase;observation_point=$observationPoint;observation_accepted=$observation.Accepted;body_error_same=[object]::ReferenceEquals($bodyObservation.Error,$observation.Error);post_read_task_different=($null -ne $bodyObservation.PostReadTask -and -not [object]::ReferenceEquals($bodyObservation.PostReadTask,$submittedTask));post_read_task_successful=($null -ne $bodyObservation.PostReadTask -and $bodyObservation.PostReadTask.IsCompletedSuccessfully);post_read_value=$bodyObservation.PostReadValue;raw_primary_same=[object]::ReferenceEquals($escaped,$injected);observation_attempted=$observation.Attempted;observation_consumed=$observation.Consumed;matching_worker_cause=$matching.Count;secondary_count=$secondary.Count;expected_secondary_count=$expectedSecondaryCount;readonly_secondary=$readonlySecondary;matching_control_native5=$controlMatching.Count;control_closed_at_failure=$controlObservation.ClosedAtFailure;original_control_closed=($null -ne $controlObservation.Handle -and $controlObservation.Handle.IsClosed);original_control_task_completed=($null -ne $controlObservation.Task -and $controlObservation.Task.IsCompleted);original_control_task_faulted=($null -ne $controlObservation.Task -and $controlObservation.Task.IsFaulted);original_primary_error=$(if($null -ne $escaped){$escaped.ToString()}else{$null});secondary_errors=$secondaryRecords;owner_retired=$owner.Retired;original_deadline=$originalDeadline;actual_deadline=$owner.Deadline;original_task_completed=($null -ne $submittedTask -and $submittedTask.IsCompleted);original_task_faulted=($null -ne $submittedTask -and $submittedTask.IsFaulted);original_worker_error=$(if($null -ne $submittedTask -and $submittedTask.IsFaulted){$submittedTask.Exception.ToString()}else{$null});terminal_wait_error=$(if($null -ne $terminalWaitFailure){$terminalWaitFailure.ToString()}else{$null})}|ConvertTo-Json -Depth 8 -Compress|Write-Output
 if(-not $owner.Retired){Write-Output ('RETAINED_ORIGINAL_RESOURCE '+$owner.Path)}
}
}
Write-TestResult
