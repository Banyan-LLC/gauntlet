# Fixture cleanup preservation v1: primary and independent cleanup errors.
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. "$PSScriptRoot/dormant-scratch-helper.ps1"
. (Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1')
Assert-True ($null -eq ([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type) 'real test starts with cold native type'
Initialize-LiveGateNative
$scratchOwner=New-DormantScratchOwner -Prefix dormant-native-real -TimeoutSec 150
$root=$scratchOwner.Path
$scriptPath=Join-Path $root 'child.ps1'
$descendantPath=Join-Path $root 'descendant.ps1'
$exe=[Environment]::ProcessPath
$child=@'
param([string]$Mode,[string]$ChildPath,[string]$Executable)
function Get-OriginalPipeHandles {
 Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class DormantInheritedPipeStd { [DllImport("kernel32.dll")]public static extern IntPtr GetStdHandle(int kind);[DllImport("kernel32.dll")]public static extern uint GetFileType(IntPtr handle); }'
 $record=@{}
 foreach($pair in @(@{name='stdin';kind=-10},@{name='stdout';kind=-11},@{name='stderr';kind=-12})){$handle=[DormantInheritedPipeStd]::GetStdHandle($pair.kind);$record[$pair.name+'_handle']=$handle.ToInt64();$record[$pair.name+'_type']=[DormantInheritedPipeStd]::GetFileType($handle)}
 return $record
}
switch($Mode){
 'echo' {[Console]::Out.Write([Console]::In.ReadToEnd());[Console]::Error.Write('fixture-stderr');exit 0}
 'exit23' {[Console]::In.ReadToEnd()|Out-Null;exit 23}
 'stderr' {[Console]::Error.Write(('e'*200000));[Console]::Out.Write('stderr-drained');[Console]::In.ReadToEnd()|Out-Null;exit 0}
 'overflow' {[Console]::Out.Write(('x'*4194305));exit 0}
 'exact-cap' {[Console]::Out.Write(('x'*2097152));[Console]::Error.Write(('e'*2097152));exit 0}
 'split-overflow' {[Console]::Out.Write(('x'*2097152));[Console]::Error.Write(('e'*2097153));exit 0}
 'blocked' {Start-Sleep -Seconds 120}
 {$_ -cin @('tree','tree-exit')} {
  $pipes=Get-OriginalPipeHandles
  $readyName='Local\DormantNativeReady-'+[guid]::NewGuid().ToString('n');$created=$false
  $ready=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$readyName,[ref]$created)
  $process=$null;$primary=$null
  try{
   if(-not $created){throw 'Fixture readiness event was not exclusively created'}
   $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$Executable;$start.UseShellExecute=$false
   $start.RedirectStandardInput=$false;$start.RedirectStandardOutput=$false;$start.RedirectStandardError=$false
   foreach($arg in @('-NoProfile','-File',$ChildPath,'-ReadyName',$readyName)){$start.ArgumentList.Add($arg)}
   $process=[Diagnostics.Process]::Start($start)
   if(-not $ready.WaitOne(5000)){throw 'Original descendant readiness was not observed'}
   [Console]::Out.WriteLine((@{kind='parent';pid=$process.Id;started_utc=$process.StartTime.ToUniversalTime().ToString('o');observed_alive=(-not $process.HasExited);pipes=$pipes;redirect_stdin=$start.RedirectStandardInput;redirect_stdout=$start.RedirectStandardOutput;redirect_stderr=$start.RedirectStandardError;ready_name=$readyName}|ConvertTo-Json -Depth 4 -Compress))
   if($Mode -ceq 'tree'){Start-Sleep -Seconds 120}else{exit 0}
  }catch{$primary=$_;throw}finally{
   $errors=[Collections.Generic.List[Exception]]::new()
   try{$ready.Dispose()}catch{$errors.Add($_.Exception)}
   try{if($null -ne $process){$process.Dispose()}}catch{$errors.Add($_.Exception)}
   if($errors.Count){if($null -ne $primary){$primary.Exception.Data['DormantFixtureCleanupFailures']=$errors.ToArray()}else{throw [AggregateException]::new('Fixture readiness cleanup failed',[Exception[]]$errors.ToArray())}}
  }
 }
 default {throw 'Unknown harmless native fixture mode'}
}
'@
$descendant=@'
param([string]$ReadyName)
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class DormantInheritedPipeStd { [DllImport("kernel32.dll")]public static extern IntPtr GetStdHandle(int kind);[DllImport("kernel32.dll")]public static extern uint GetFileType(IntPtr handle); }'
$pipes=@{}
foreach($pair in @(@{name='stdin';kind=-10},@{name='stdout';kind=-11},@{name='stderr';kind=-12})){$handle=[DormantInheritedPipeStd]::GetStdHandle($pair.kind);$pipes[$pair.name+'_handle']=$handle.ToInt64();$pipes[$pair.name+'_type']=[DormantInheritedPipeStd]::GetFileType($handle)}
$self=[Diagnostics.Process]::GetCurrentProcess()
[Console]::Out.WriteLine((@{kind='descendant';pid=$PID;started_utc=$self.StartTime.ToUniversalTime().ToString('o');pipes=$pipes;ready_name=$ReadyName}|ConvertTo-Json -Depth 4 -Compress))
[Console]::Error.WriteLine('original-descendant-stderr '+$ReadyName)
$ready=[Threading.EventWaitHandle]::OpenExisting($ReadyName)
try{$ready.Set()|Out-Null}finally{$ready.Dispose()}
Start-Sleep -Seconds 120
'@
function Read-RealReceipt($Result,[string]$Case){
 $parent=$null;$descendant=$null;$documents=[Collections.Generic.List[object]]::new()
 try{
  foreach($line in ($Result.Stdout -split "`r?`n")){
   if([string]::IsNullOrWhiteSpace($line)){continue}
   $document=[Text.Json.JsonDocument]::Parse($line);$documents.Add($document)
   switch -CaseSensitive ($document.RootElement.GetProperty('kind').GetString()){'parent'{$parent=$document.RootElement};'descendant'{$descendant=$document.RootElement};default{throw 'Unexpected descendant receipt kind'}}
  }
  if($null -eq $parent -or $null -eq $descendant){throw 'Actual parent and descendant stdout receipts required'}
  $pidValue=$parent.GetProperty('pid').GetInt32();$started=$parent.GetProperty('started_utc').GetString();$readyName=$parent.GetProperty('ready_name').GetString()
  Assert-True ($pidValue -eq $descendant.GetProperty('pid').GetInt32() -and [string]::Equals($started,$descendant.GetProperty('started_utc').GetString(),[StringComparison]::Ordinal) -and [string]::Equals($readyName,$descendant.GetProperty('ready_name').GetString(),[StringComparison]::Ordinal)) "$Case actual Process object and descendant agree on exact original identity"
  foreach($channel in @('stdin','stdout','stderr')){
   $original=$parent.GetProperty('pipes').GetProperty($channel+'_handle').GetInt64();$inherited=$descendant.GetProperty('pipes').GetProperty($channel+'_handle').GetInt64()
   Assert-True (-not $parent.GetProperty('redirect_'+$channel).GetBoolean() -and $original -gt 0 -and $original -eq $inherited -and $parent.GetProperty('pipes').GetProperty($channel+'_type').GetInt32() -eq 3 -and $descendant.GetProperty('pipes').GetProperty($channel+'_type').GetInt32() -eq 3) "$Case exact original native $channel pipe is inherited without redirection"
  }
  Assert-True ($Result.Stderr.Contains('original-descendant-stderr '+$readyName)) "$Case descendant marker arrives on same original captured stderr"
  [Console]::Out.WriteLine((@{case=('original_inherited_pipes_'+$Case);parent_json=$parent.GetRawText();descendant_json=$descendant.GetRawText();captured_stderr=$Result.Stderr;native=$Result.NativeProcessResult}|ConvertTo-Json -Depth 5 -Compress))
  [pscustomobject]@{pid=$pidValue;started_utc=$started;observed_alive=$parent.GetProperty('observed_alive').GetBoolean()}
 }finally{foreach($document in $documents){$document.Dispose()}}
}
function Run-RealFixture([string]$Mode,[string]$InputText,[int]$Timeout=15){
    Invoke-BoundedProcess -FileName $exe -ArgList @('-NoProfile','-File',$scriptPath,'-Mode',$Mode,'-ChildPath',$descendantPath,'-Executable',$exe) -StdinText $InputText -WorkingDirectory $root -TimeoutSec $Timeout -RequireProcessTreeRetirement
}
function Assert-NativeSix($Result,[string]$Case){
    $native=$Result.NativeProcessResult
    Assert-True ($null -ne $native -and $native.IsReadOnly) "$Case actual native snapshot is immutable"
    if($null -eq $native){return}
    Assert-Eq $native.Keys.Count 6 "$Case exact native six-field schema"
    foreach($name in @('ExitCode','StartFailed','TimedOut','ErrorMessage','StderrText','ProcessTreeRetired')){Assert-True ($native.ContainsKey($name)) "$Case retains native $name"}
    Assert-True ($native.ExitCode -is [int] -and $native.StartFailed -is [bool] -and $native.TimedOut -is [bool] -and $native.ProcessTreeRetired -is [bool] -and $native.StderrText -is [string] -and ($null -eq $native.ErrorMessage -or $native.ErrorMessage -is [string])) "$Case native fields retain exact scalar types"
}
$cleanupAllowed=$false
$fixturePrimary0=$null
try {
try{
    $scratchOwner.Initialize()
    $scratchOwner.WriteText('child.ps1',$child)
    $scratchOwner.WriteText('descendant.ps1',$descendant)
    $text=('fixture input '*30000)
    $echo=Run-RealFixture 'echo' $text
    Assert-True (-not $echo.StartFailed -and -not $echo.TimedOut -and $echo.ExitCode -eq 0 -and $null -eq $echo.ErrorMessage -and $echo.ProcessTreeRetired -and $null -eq $echo.Failure -and $echo.CleanupFailures.Count -eq 0) 'actual native echo succeeds and retires original job'
    Assert-Eq $echo.Stdout $text 'real runner writes stdin and drains complete stdout before acceptance'
    Assert-Eq $echo.Stderr 'fixture-stderr' 'real runner drains stderr before acceptance'
    Assert-NativeSix $echo echo
    $exit=Run-RealFixture 'exit23' ''
    Assert-True ($exit.ExitCode -eq 23 -and -not $exit.StartFailed -and -not $exit.TimedOut -and $exit.ProcessTreeRetired) 'actual nonzero native exit stays truthful with retirement'
    Assert-NativeSix $exit exit23
    $stderr=Run-RealFixture 'stderr' $text
    Assert-True ($stderr.ExitCode -eq 0 -and -not $stderr.TimedOut -and $stderr.ProcessTreeRetired -and $stderr.Stdout -ceq 'stderr-drained' -and $stderr.Stderr.Length -eq 200000) 'concurrent stderr and large stdin cannot deadlock the original clock'
    $overflow=Run-RealFixture 'overflow' ''
    Assert-True ($overflow.ExitCode -eq -1 -and $overflow.ProcessTreeRetired -and $null -ne $overflow.Failure -and $overflow.Failure.Code -ceq 'capture_limit') 'actual 4194305-byte native output crosses retention cap and fails closed with retirement'
    Assert-True ($overflow.Stdout.Length+$overflow.Stderr.Length -le 4194304) 'aggregate capture retains no bytes beyond the native four-MiB budget'
    Assert-NativeSix $overflow overflow
    $exact=Run-RealFixture 'exact-cap' ''
    Assert-True ($exact.ExitCode -eq 0 -and $exact.ProcessTreeRetired -and $null -eq $exact.Failure -and $exact.Stdout.Length -eq 2097152 -and $exact.Stderr.Length -eq 2097152) 'combined stdout and stderr exactly at four-MiB cap succeed and retire'
    $split=Run-RealFixture 'split-overflow' ''
    Assert-True ($split.ExitCode -eq -1 -and $split.ProcessTreeRetired -and $split.Failure.Code -ceq 'capture_limit' -and $split.Stdout.Length+$split.Stderr.Length -le 4194304) 'aggregate overflow fails closed even when both independent streams stay below four-MiB'
    $failed=Invoke-BoundedProcess -FileName (Join-Path $root 'absent/never.exe') -WorkingDirectory $root -TimeoutSec 5 -ClearEnvironment -EnvironmentMap @{} -RequireProcessTreeRetirement
    Assert-True ($failed.StartFailed -and -not $failed.TimedOut -and $failed.ProcessTreeRetired -and $null -ne $failed.Failure -and $failed.Failure.Code -ceq 'native_failure' -and $failed.Failure.Stage -ceq 'process_creation' -and $failed.Failure.Type -ceq 'System.ComponentModel.Win32Exception' -and $failed.Failure.NativeError -is [int] -and $failed.Failure.NativeError -ne 0) 'actual absent executable preserves Win32 cause and known no-child retirement'
    Assert-NativeSix $failed absent
    Assert-Eq $failed.Failure.Keys.Count 5 'actual native structural failure uses exact flat five-field schema'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $blocked=Run-RealFixture 'blocked' ('x'*600000) 2
    $watch.Stop()
    Assert-True ($blocked.TimedOut -and $blocked.ExitCode -eq -1 -and $blocked.ProcessTreeRetired -and $watch.Elapsed.TotalSeconds -lt 6) 'blocked stdin returns at original deadline and retires the actual process tree'
    Assert-NativeSix $blocked blocked
    $watch.Restart()
    $tree=Run-RealFixture 'tree' '' 4
    $watch.Stop()
    [pscustomobject]@{case='actual_tree_stdout_receipt';result=$tree;elapsed_ms=$watch.ElapsedMilliseconds}|ConvertTo-Json -Depth 8 -Compress|Write-Output
    Assert-True ($tree.TimedOut -and $tree.ProcessTreeRetired -and $watch.Elapsed.TotalSeconds -lt 8) 'native timeout physically retires spawned descendants inside original bound'
    Assert-True (-not [string]::IsNullOrWhiteSpace($tree.Stdout)) 'descendant executed and delivered actual stdout identity before retirement check'
    $receipt=Read-RealReceipt $tree tree_timeout
    Assert-True ($receipt.observed_alive -is [bool] -and $receipt.observed_alive) 'timeout parent confirmed its exact descendant alive before sleep'
    $sameAlive=$false
    try{$process=[Diagnostics.Process]::GetProcessById([int]$receipt.pid);$sameAlive=$process.StartTime.ToUniversalTime().ToString('o') -ceq $receipt.started_utc -and -not $process.HasExited;$process.Dispose()}catch [ArgumentException]{}
    Assert-True (-not $sameAlive) 'the exact original descendant has exited after native retirement proof'
    $parentExit=Run-RealFixture 'tree-exit' ''
    Assert-True ($parentExit.ExitCode -eq 0 -and -not $parentExit.TimedOut -and $parentExit.ProcessTreeRetired -and $null -eq $parentExit.Failure) 'successful original parent exit also retires remaining job descendants and IO'
    $receipt=Read-RealReceipt $parentExit parent_exit
    Assert-True ($receipt.observed_alive -is [bool] -and $receipt.observed_alive) 'original successful parent confirms descendant alive before parent exit'
    $sameAlive=$false
    try{$process=[Diagnostics.Process]::GetProcessById([int]$receipt.pid);$sameAlive=$process.StartTime.ToUniversalTime().ToString('o') -ceq $receipt.started_utc -and -not $process.HasExited;$process.Dispose()}catch [ArgumentException]{}
    Assert-True (-not $sameAlive) 'exact PID and start-time descendant from successful parent is dead after actual native job retirement'
    Assert-NativeSix $parentExit parent_exit_descendant
    $cancel=[Threading.CancellationTokenSource]::new()
    $fixturePrimary1=$null
try {
try{
        $cancel.CancelAfter(1000)
        $watch.Restart()
        $cancelled=Invoke-BoundedProcess -FileName $exe -ArgList @('-NoProfile','-File',$scriptPath,'-Mode','blocked') -WorkingDirectory $root -TimeoutSec 15 -FailureCancellationToken $cancel.Token -RequireProcessTreeRetirement
        $watch.Stop()
        Assert-True ($cancelled.ExitCode -eq -1 -and $cancelled.ProcessTreeRetired -and $watch.Elapsed.TotalSeconds -lt 6 -and $null -ne $cancelled.Failure) 'actual cancellation refuses success and retires native ownership before longer deadline'
    }
catch{throw}
}catch{$fixturePrimary1=$_;throw}finally{
$fixtureCleanup1=[Collections.Generic.List[Exception]]::new()
try{
$cancel.Dispose()
}catch{$fixtureCleanup1.Add($_.Exception)}
if($fixtureCleanup1.Count -gt 0){
 if($null -ne $fixturePrimary1){
  $previous=@();if($fixturePrimary1.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary1.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary1.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup1.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup1.ToArray())}
}
}
    Assert-Eq (Get-ReviewOwnerRegistry ReviewProcessOwners).Count 0 'all real native pipelines physically settle'
}
catch{throw}
}catch{$fixturePrimary0=$_;throw}finally{
$fixtureCleanup0=[Collections.Generic.List[Exception]]::new()
try{
$cleanupAllowed=(Get-ReviewOwnerRegistry ReviewProcessOwners).Count -eq 0
}catch{$fixtureCleanup0.Add($_.Exception)}
try{
if(-not $cleanupAllowed){throw [InvalidOperationException]::new('Original native fixture ownership remains unresolved; retain root')}
}catch{$fixtureCleanup0.Add($_.Exception)}
try{
if($cleanupAllowed){$scratchOwner.Cleanup()}
}catch{$fixtureCleanup0.Add($_.Exception)}
if($fixtureCleanup0.Count -gt 0){
 if($null -ne $fixturePrimary0){
  $previous=@();if($fixturePrimary0.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary0.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary0.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup0.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup0.ToArray())}
}
}
Write-TestResult
