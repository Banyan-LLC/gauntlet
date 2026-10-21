param([Parameter(Mandatory)][string]$Source)
$ErrorActionPreference='Stop'
$sourceHash=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
. $Source
Initialize-LiveGateNative
$count=0;$failed=0
function Check([bool]$Condition,[string]$Name){$script:count++;if($Condition){Write-Output ('PASS '+$Name)}else{$script:failed++;Write-Output ('FAIL '+$Name)}}
Write-Output ('runtime='+$PSVersionTable.PSVersion+' dotnet='+[Environment]::Version)
$native='GauntletLive.Native' -as [type]
$flags=[Reflection.BindingFlags]'NonPublic,Static'
$close=$native.GetMethod('Close',$flags)
$parameters=[object[]]@([IntPtr]::new(2147483647));$thrown=$false
try{$null=$close.Invoke($null,$parameters)}catch{$thrown=$_.Exception.GetBaseException() -is [ComponentModel.Win32Exception]}
Check ($thrown -and $parameters[0] -eq [IntPtr]::new(2147483647)) 'invalid native close reports cause and retains exact original reference'
function Run([string]$Command,[string]$InputText='',[Threading.CancellationToken]$Token=[Threading.CancellationToken]::None,[int]$Milliseconds=10000){
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=[Environment]::ProcessPath;$start.WorkingDirectory=[IO.Path]::GetTempPath()
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
 foreach($arg in @('-NoProfile','-EncodedCommand',$encoded)){$start.ArgumentList.Add($arg)}
 [GauntletLive.Native]::RunMilliseconds($start,$InputText,$Milliseconds,$Token)
}
$tooMuch=Run '[Console]::In.ReadToEnd()|Out-Null;exit 0' ('x'*1048577)
Check (@($tooMuch.CleanupFailures|Where-Object Code -ceq 'native_failure').Count -eq 0) 'oversized stdin refusal does not duplicate its propagation signal as an independent native failure'
Check ($tooMuch.ExitCode -eq -1 -and $tooMuch.StartFailed -and $tooMuch.ProcessTreeRetired -and $tooMuch.Failure.Code -eq 'stdin_limit') 'stdin over one MiB fails before process creation'
$utf8=Run '[Console]::In.ReadToEnd()|Out-Null;exit 0' ([string][char]0x00e9*524289)
Check (@($utf8.CleanupFailures|Where-Object Code -ceq 'native_failure').Count -eq 0) 'UTF8 stdin refusal does not duplicate its propagation signal as an independent native failure'
Check ($utf8.ExitCode -eq -1 -and $utf8.StartFailed -and $utf8.ProcessTreeRetired -and $utf8.Failure.Code -eq 'stdin_limit') 'stdin admission bounds UTF8 bytes rather than UTF16 character count'
$atLimit=Run '[Console]::Out.Write([Console]::In.ReadToEnd().Length);exit 0' ('x'*1048576)
Check ($atLimit.ExitCode -eq 0 -and $atLimit.Stdout -ceq '1048576' -and $atLimit.ProcessTreeRetired -and $null -eq $atLimit.Failure) 'one MiB stdin is completely delivered and retired'
$small=Run '[Console]::Out.Write([Console]::In.ReadToEnd());exit 0' 'small-stdin'
Check ($small.ExitCode -eq 0 -and $small.Stdout -ceq 'small-stdin' -and $small.ProcessTreeRetired -and $null -eq $small.Failure) 'checked original raw pipe EOF close preserves complete small stdin before deferred wrapper disposal'
$exact=Run '[Console]::Out.Write(("x"*2097152));[Console]::Error.Write(("e"*2097152));exit 0'
Check ($exact.ExitCode -eq 0 -and $exact.Stdout.Length -eq 2097152 -and $exact.Stderr.Length -eq 2097152 -and $exact.ProcessTreeRetired -and $null -eq $exact.Failure) 'four MiB combined raw output remains accepted within separately enforced retained payload budget'
$unicode=Run '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);[Console]::Out.Write("a"+([string][char]0x00e9*2097151)+"b");exit 0'
Check ($unicode.ExitCode -eq 0 -and $unicode.Stdout.Length -eq 2097153 -and $unicode.Stdout[0] -ceq 'a' -and $unicode.Stdout[1] -eq [char]0x00e9 -and $unicode.Stdout[2097151] -eq [char]0x00e9 -and $unicode.Stdout[2097152] -ceq 'b' -and $unicode.ProcessTreeRetired) 'UTF8 sequences split across retained chunk boundaries decode once without corruption'
$watch=[Diagnostics.Stopwatch]::StartNew()
$overflow=Run '[Console]::Out.Write(("x"*4194305));[Console]::Error.Write(("e"*200000));Start-Sleep -Seconds 120' ('x'*1048576)
$watch.Stop()
Write-Output ('overflow elapsed='+$watch.ElapsedMilliseconds+' result='+($overflow|ConvertTo-Json -Depth 5 -Compress))
Check ($overflow.ExitCode -eq -1 -and $overflow.Failure.Code -eq 'capture_limit' -and $overflow.ProcessTreeRetired -and $watch.ElapsedMilliseconds -lt 6000) 'overflow terminates original job while stdin pending and other stream active'
$cancel=[Threading.CancellationTokenSource]::new()
$preCancelled=[Threading.CancellationTokenSource]::new()
try{
 $preCancelled.Cancel()
 $beforeLaunch=Run 'exit 0' '' $preCancelled.Token
 Check ($beforeLaunch.ExitCode -eq -1 -and $beforeLaunch.StartFailed -and $beforeLaunch.ProcessTreeRetired -and $beforeLaunch.Failure.Code -ceq 'transport_abort') 'actual already-cancelled original native call refuses before process creation and retires absence truthfully'
 Check (@($beforeLaunch.CleanupFailures|Where-Object Code -ceq 'native_failure').Count -eq 0) 'already-recorded cancellation does not duplicate its propagation signal as an independent native failure'
}finally{$preCancelled.Dispose()}
try{
 $cancel.CancelAfter(1000);$watch.Restart()
 $aborted=Run 'Start-Sleep -Seconds 120' '' $cancel.Token
 $watch.Stop()
 Check ($aborted.ExitCode -eq -1 -and $aborted.Failure.Code -eq 'transport_abort' -and $aborted.ProcessTreeRetired -and $watch.ElapsedMilliseconds -lt 6000) 'original cancellation terminates original job before its longer deadline'
}finally{$cancel.Dispose()}
# Exercise production cleanup boundary with independent throwing resources. Test
# doubles are confined here; the same helper closes the three actual pipe streams.
Add-Type -TypeDefinition @'
public sealed class DormantThrowingDisposer:System.IDisposable {
 public int Calls;
 public void Dispose(){Calls++;throw new System.IO.IOException("fixture disposer failed");}
}
'@
$custodyType=$native.GetNestedType('RunCustody',[Reflection.BindingFlags]'NonPublic')
$custody=[Activator]::CreateInstance($custodyType,$true)
$result=[GauntletLive.Native+RunResult]::new()
$record=$native.GetMethod('RecordFailure',$flags)
$null=$record.Invoke($null,[object[]]@($result,'original_primary','fixture',[InvalidOperationException]::new('primary'),$false))
$original=$result.Failure
$dispose=$native.GetMethod('DisposeOwned',$flags)
$first=[DormantThrowingDisposer]::new();$second=[DormantThrowingDisposer]::new()
$null=$dispose.Invoke($null,[object[]]@($result,$custody,$first))
$null=$dispose.Invoke($null,[object[]]@($result,$custody,$second))
Check ($first.Calls -eq 1 -and $second.Calls -eq 1) 'each independent production closure runs after an earlier throwing disposer'
Check ([object]::ReferenceEquals($original,$result.Failure) -and $result.CleanupFailures.Length -eq 2 -and $result.CleanupFailures[0].Type -eq 'System.IO.IOException' -and $result.CleanupFailures[1].Type -eq 'System.IO.IOException') 'original primary remains exact and independent cleanup causes remain bounded structural records'
$unresolved=$custodyType.GetField('Unresolved').GetValue($custody)
Check ($unresolved.Count -eq 2 -and [object]::ReferenceEquals($unresolved[0],$first) -and [object]::ReferenceEquals($unresolved[1],$second)) 'failed disposers retain original resource custody'
$closeOwned=$native.GetMethod('CloseOwned',$flags)
$args=[object[]]@($result,$custody,[IntPtr]::new(2147483647))
$null=$closeOwned.Invoke($null,$args)
Check ($args[2] -eq [IntPtr]::new(2147483647) -and $unresolved.Count -eq 3 -and $unresolved[2] -eq [IntPtr]::new(2147483647)) 'checked cleanup retains failed original native handle alongside earlier resources'
$budgetType=$native.GetNestedType('CaptureBudget',[Reflection.BindingFlags]'NonPublic')
$budget=[Activator]::CreateInstance($budgetType,[object[]]@([Activator]::CreateInstance($custodyType,$true)))
$capture=$native.GetMethod('Capture',$flags)
$bytes=[Text.Encoding]::UTF8.GetBytes(('x'*4194304));$stream=[IO.MemoryStream]::new($bytes,$false)
try{
 $task=$capture.Invoke($null,[object[]]@($stream,$budget));$text=$task.GetAwaiter().GetResult()
 Check ($text.Length -eq 4194304 -and $budgetType.GetField('PeakRetained').GetValue($budget) -ge 12582912 -and $budgetType.GetField('PeakRetained').GetValue($budget) -le 16777216) 'actual capture charges raw chunk capacity overlapping final UTF16 allocation'
 $retained=$budgetType.GetField('retained',[Reflection.BindingFlags]'NonPublic,Instance').GetValue($budget)
 Check ($retained -eq 8519680) 'completed capture releases chunk capacities and retains UTF16 payload plus fixed capture metadata reserve'
}finally{$stream.Dispose()}
$boundary=[Activator]::CreateInstance($budgetType,[object[]]@([Activator]::CreateInstance($custodyType,$true)))
$reserve=$budgetType.GetMethod('Reserve')
$null=$reserve.Invoke($boundary,[object[]]@([long]16646144));$over=$false
try{$null=$reserve.Invoke($boundary,[object[]]@([long]1))}catch{$over=$_.Exception.GetBaseException() -is [InvalidOperationException]}
Check ($over -and $budgetType.GetField('Exceeded').GetValue($boundary) -eq 1) 'retained payload exactly at sixteen MiB is admitted and next byte latches failure'
Write-Output ($count.ToString()+' runtime regression checks; '+$failed+' failed')
if((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -cne $sourceHash){throw 'Candidate source changed during verification'}
Write-Output ('source_sha256='+$sourceHash.ToLowerInvariant())
if($failed){exit 1}
