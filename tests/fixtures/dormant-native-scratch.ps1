param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. "$PSScriptRoot/dormant-scratch-helper.ps1"
function New-ControlOwner([string]$Prefix){New-DormantScratchOwner -Prefix $Prefix -TimeoutSec 90}
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
$primary=$null
try{
 $owner.Initialize();$owner.BeforeSealEntered=[Threading.ManualResetEventSlim]::new($false);$owner.ContinueSeal=[Threading.ManualResetEventSlim]::new($false)
 $owner.BeginWriteText('seeded.txt','expected');$task=$owner.OriginalTask
 Assert-True ($owner.BeforeSealEntered.Wait(3000)) 'original creation task reaches exact seal-handoff barrier'
 $writer=[IO.FileStream]::new($owner.FilePath('seeded.txt'),[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
 $writerPrimary=$null
 try{$bytes=[Text.Encoding]::UTF8.GetBytes('mutated!');$writer.Write($bytes,0,$bytes.Length);$writer.Flush()}catch{$writerPrimary=$_;throw}finally{Complete-DormantScratchCleanup -Primary $writerPrimary -Actions @({$writer.Dispose()})}
 $owner.ContinueSeal.Set();$failure=$null;try{$owner.WaitWriteText()}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and $failure.GetBaseException() -is [IO.IOException] -and $task.IsFaulted -and -not $owner.Retired) 'actual write during seal handoff refuses original creation acceptance after byte verification'
}catch{$primary=$_;throw}finally{Complete-DormantScratchCleanup -Primary $primary -Actions @({if($null -ne $owner.ContinueSeal){$owner.ContinueSeal.Set()}},{$owner.Cleanup()})}
Assert-True $owner.Retired 'failed original sealed bytes retain custody until exact original root cleanup'

$owner=New-ControlOwner 'scratch-seal-binding';$replacement=$null
$primary=$null
try{
 $owner.Initialize();$owner.BeforeSealEntered=[Threading.ManualResetEventSlim]::new($false);$owner.ContinueSeal=[Threading.ManualResetEventSlim]::new($false)
 $owner.BeginWriteText('seeded.txt','expected');$task=$owner.OriginalTask
 Assert-True ($owner.BeforeSealEntered.Wait(3000)) 'original creation remains retained across name-binding handoff'
 [IO.File]::Move($owner.FilePath('seeded.txt'),$owner.FilePath('moved.txt'))
 $replacement=[IO.FileStream]::new($owner.FilePath('seeded.txt'),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
 $bytes=[Text.Encoding]::UTF8.GetBytes('expected');$replacement.Write($bytes,0,$bytes.Length);$replacement.Flush()
 $owner.ContinueSeal.Set();$failure=$null;try{$owner.WaitWriteText()}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and ($failure.GetBaseException() -is [IO.IOException] -or $failure.GetBaseException() -is [ComponentModel.Win32Exception]) -and $task.IsFaulted) 'identical replacement bytes cannot substitute for exact original creation identity'
 $failure=$null;try{$owner.Cleanup()}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and -not $owner.Retired -and $replacement.CanRead) 'creation refusal never adopts or deletes the independently owned replacement'
 Assert-True (-not $owner.ControlDeletePending($replacement)) 'creation refusal leaves replacement original handle undisposed and not delete-pending'
 Assert-True ($owner.VerifyAbsent('moved.txt')) 'creation refusal still disposes original renamed creation by original handle'
}catch{$primary=$_;throw}finally{Complete-DormantScratchCleanup -Primary $primary -Actions @({if($null -ne $owner.ContinueSeal){$owner.ContinueSeal.Set()}},{if($null -ne $replacement){$owner.RemoveControlFile('seeded.txt',$replacement)}},{$owner.Cleanup()})}
Assert-True $owner.Retired 'creation identity refusal reconciles only after separate replacement owner physically retires'

# Drop only the cleanup seal at a retained original-worker barrier, then replace
# its pathname. The adversary's create-only stream owns its own
# replacement object; explicit original-handle disposition is its cleanup authority.
$owner=New-ControlOwner 'scratch-replacement';$replacement=$null
$primary=$null
try{
 $owner.Initialize();$owner.WriteText('original.txt','original')
 $owner.BeforeDeleteEntered=[Threading.ManualResetEventSlim]::new($false)
 $owner.ContinueDelete=[Threading.ManualResetEventSlim]::new($false)
 $owner.BeginCleanup();$task=$owner.OriginalTask
 Assert-True ($owner.BeforeDeleteEntered.Wait(3000)) 'actual original cleanup worker pauses after releasing only its original leaf seal'
 $failure=$null;try{$owner.WriteText('forbidden.txt','new')}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and [object]::ReferenceEquals($task,$owner.OriginalTask)) 'pending original cleanup refuses new work without replacing its task authority'
 [IO.File]::Move($owner.FilePath('original.txt'),$owner.FilePath('moved.txt'))
 $replacement=[IO.FileStream]::new($owner.FilePath('original.txt'),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
 $bytes=[Text.Encoding]::UTF8.GetBytes('replacement');$replacement.Write($bytes,0,$bytes.Length);$replacement.Flush()
 $owner.ContinueDelete.Set();$failure=$null;try{$owner.WaitCleanup()}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and -not $owner.Retired -and $task.IsCompleted -and [object]::ReferenceEquals($task,$owner.OriginalTask)) 'actual replacement refuses cleanup acceptance while original worker physically settles'
 $replacement.Position=0;$seen=[byte[]]::new(11);$count=$replacement.Read($seen,0,$seen.Length)
 Assert-True ($count -eq 11 -and [Text.Encoding]::UTF8.GetString($seen) -ceq 'replacement') 'original-handle disposition never deletes or truncates substituted replacement object'
 Assert-True (-not $owner.ControlDeletePending($replacement)) 'cleanup does not mark substituted original control delete-pending'
 Assert-True ($owner.VerifyAbsent('moved.txt')) 'the renamed original object is disposed through its retained original handle'
}catch{$primary=$_;throw}finally{
 Complete-DormantScratchCleanup -Primary $primary -Actions @({if($null -ne $owner.ContinueDelete){$owner.ContinueDelete.Set()}},{if($null -ne $replacement){$owner.RemoveControlFile('original.txt',$replacement)}},{$owner.Cleanup()})
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
Write-TestResult
