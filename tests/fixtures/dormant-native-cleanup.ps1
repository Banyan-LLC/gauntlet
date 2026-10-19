param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. "$PSScriptRoot/dormant-scratch-helper.ps1"
function Invoke-HeldCleanupFailure {
 param($Owner,$Observation)
 $handle=$null;$primary=$null
 try{
  $handle=[IO.File]::Open($Owner.FilePath('held.txt'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  $Observation.Handle=$handle
  $Observation.SafeHandle=$handle.SafeFileHandle
  throw [IO.IOException]::new('original fixture primary')
 }catch{$primary=$_;throw}finally{
  $cleanup=[Collections.Generic.List[Exception]]::new()
  try{$Owner.RemoveFile('held.txt')}catch{$cleanup.Add($_.Exception)}
  try{if($null -ne $handle){$handle.Dispose()}}catch{$cleanup.Add($_.Exception)}
  if($cleanup.Count){if($null -ne $primary){$primary.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]$cleanup.ToArray())}else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$cleanup.ToArray())}}
 }
}
function Invoke-PartialSetupFailure {
 param($Owner)
 $primary=$null
 try{
  $Owner.WriteText('partial.txt','partial actual setup')
  $Owner.WriteText('blocked.txt','must not replace external control')
 }catch{$primary=$_;throw}finally{
  $cleanup=[Collections.Generic.List[Exception]]::new()
  try{$Owner.RemoveFile('partial.txt')}catch{$cleanup.Add($_.Exception)}
  try{$Owner.RemoveFile('held.txt')}catch{$cleanup.Add($_.Exception)}
  if($cleanup.Count){if($null -ne $primary){$primary.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]$cleanup.ToArray())}else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$cleanup.ToArray())}}
 }
}
$owner=New-DormantScratchOwner -Prefix dormant-held-cleanup -TimeoutSec 90
$primary=$null
try{
 $owner.Initialize();$owner.WriteText('held.txt','held actual fixture')
 $observation=@{Handle=$null;SafeHandle=$null};$failure=$null
 try{Invoke-HeldCleanupFailure $owner $observation}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and $failure.Message -ceq 'original fixture primary' -and $failure -is [IO.IOException]) 'actual original-handle disposition refusal cannot replace original escaping exception'
 $secondary=@($failure.Data['DormantFixtureCleanupFailures'])
 Assert-True ($secondary.Count -eq 1 -and $secondary[0].GetBaseException() -is [ComponentModel.Win32Exception] -and $secondary[0].GetBaseException().NativeErrorCode -eq 32) 'actual held deletion sharing error remains independent cleanup evidence'
 [pscustomobject]@{case='actual_file_stream_disposal';original_safehandle_closed=$observation.SafeHandle.IsClosed;stream_can_read=$observation.Handle.CanRead}|ConvertTo-Json -Compress|Write-Output
 Assert-True ($null -ne $observation.SafeHandle -and $observation.SafeHandle.IsClosed) 'later independent cleanup statement physically closes the same original held handle'
}catch{$primary=$_;throw}finally{
 $cleanup=[Collections.Generic.List[Exception]]::new()
 try{$owner.Cleanup()}catch{$cleanup.Add($_.Exception)}
 if($cleanup.Count){if($null -ne $primary){$primary.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]$cleanup.ToArray())}else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$cleanup.ToArray())}}
}
Assert-True $owner.Retired 'explicit same-owner cleanup confirms original held root physically removed'

$owner=New-DormantScratchOwner -Prefix dormant-partial-cleanup -TimeoutSec 90
$guard=$null;$blocked=$null;$primary=$null
try{
 $owner.Initialize();$owner.WriteText('held.txt','original held bytes')
 $guard=[IO.File]::Open($owner.FilePath('held.txt'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 # Root/ancestor handles remain pinned. This independent create-only control
 # stream retains its original handle authority, never pathname deletion.
 $blocked=[IO.FileStream]::new($owner.FilePath('blocked.txt'),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
 $bytes=[Text.Encoding]::UTF8.GetBytes('external original');$blocked.Write($bytes,0,$bytes.Length);$blocked.Flush()
 $failure=$null;try{Invoke-PartialSetupFailure $owner}catch{$failure=$_.Exception}
 Assert-True ($null -ne $failure -and $failure.GetBaseException() -is [ComponentModel.Win32Exception] -and $failure.GetBaseException().NativeErrorCode -eq 183) 'actual create-only collision remains primary after partial setup and independent cleanup refusal'
 Assert-True ($owner.VerifyAbsent('partial.txt')) 'partial setup removes only its same original leaf and verifies absence'
 $secondary=@($failure.Data['DormantFixtureCleanupFailures'])
 Assert-True ($secondary.Count -eq 1 -and $secondary[0].GetBaseException() -is [ComponentModel.Win32Exception] -and $secondary[0].GetBaseException().NativeErrorCode -eq 32) 'partial setup preserves separate actual held-share cleanup cause'
 $blocked.Position=0;$seen=[byte[]]::new(17);$count=$blocked.Read($seen,0,$seen.Length)
 Assert-True ($count -eq 17 -and [Text.Encoding]::UTF8.GetString($seen) -ceq 'external original') 'create-only setup never truncates the independent replacement object'
}catch{$primary=$_;throw}finally{
 $cleanup=[Collections.Generic.List[Exception]]::new()
 try{if($null -ne $guard){$guard.Dispose()}}catch{$cleanup.Add($_.Exception)}
 try{if($null -ne $blocked){$owner.RemoveControlFile('blocked.txt',$blocked)}}catch{$cleanup.Add($_.Exception)}
 try{$owner.Cleanup()}catch{$cleanup.Add($_.Exception)}
 if($cleanup.Count){if($null -ne $primary){$primary.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]$cleanup.ToArray())}else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$cleanup.ToArray())}}
}
Assert-True $owner.Retired 'partial setup custody retires only after independent original handles settle and root removal is verified'
Write-TestResult
