# PRIVATE PROPOSAL ONLY. Source instrumentation is test-only and create-only in memory.
param(
  [Parameter(Mandatory)][string]$Source,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedSourceSha256,
  [Parameter(Mandatory)][ValidateSet('both','retirement_then_capture','mixed_limit','stdin_after_limit')][string]$Mode,
  [Parameter(Mandatory)][ValidateSet('direct','facade')][string]$Boundary,
  [switch]$DeadlineControl,
  [switch]$EarlyCapture
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not $IsWindows){throw [PlatformNotSupportedException]::new('Native I/O control requires Windows')}
if($DeadlineControl -and $Boundary -ne 'facade'){throw [ArgumentException]::new('Deadline control requires the original facade owner')}
if($EarlyCapture -and ($Mode -ne 'both' -or $DeadlineControl)){throw [ArgumentException]::new('Early capture requires the ordinary both-channel control')}
if($null -ne ('GauntletLive.Native' -as [type]) -or $null -ne ('GauntletOwnedWork.StreamGuard' -as [type])){throw [InvalidOperationException]::new('Fresh Native/StreamGuard-cold child required')}
$beforeHash=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
if(-not [string]::Equals($beforeHash,$ExpectedSourceSha256,[StringComparison]::Ordinal)){throw [InvalidOperationException]::new('Unexpected exact source bytes')}
$text=[IO.File]::ReadAllText($Source)
$anchors=[Collections.Generic.List[object]]::new()
function Replace-Once([string]$Before,[string]$After){
  if($script:text.Split($Before,[StringSplitOptions]::None).Length -ne 2){throw [InvalidOperationException]::new('Strict native I/O instrumentation anchor must occur exactly once: '+$Before)}
  $script:anchors.Add([ordered]@{before=$Before;after=$After})
  $script:text=$script:text.Replace($Before,$After)
}
$fields=@'
public static string FixtureMode;
public static bool FixtureEarlyCapture,FixtureOriginalEofClosed;
public static readonly ManualResetEventSlim FixtureCaptureRelease=new ManualResetEventSlim(false);
public static Stream FixtureOutputStream,FixtureErrorStream;
public static Task<string> FixtureOutputTask,FixtureErrorTask;
public static Task FixtureWriteTask;public static bool FixtureWritePendingAtLimit;
public static object FixtureOriginalCustody;
public static RunResult FixtureOriginalResult;
public static Win32Exception FixtureOutputError,FixtureErrorError,FixtureRetirementError;
public static int FixtureOutputReads,FixtureErrorReads,FixtureProcessId;
public static long FixtureOutputFaultAt,FixtureErrorFaultAt,FixtureRetirementFaultAt,FixtureDeadline;
public static string SourceIdentity { get { return "__GAUNTLET_NATIVE_SOURCE_IDENTITY__"; } }
'@
Replace-Once 'public static string SourceIdentity { get { return "__GAUNTLET_NATIVE_SOURCE_IDENTITY__"; } }' $fields
Replace-Once 'var result = new RunResult();' 'var result = new RunResult();FixtureOriginalResult=result;'
Replace-Once 'var custody=new RunCustody{Deadline=deadlineTimestamp};' 'var custody=new RunCustody{Deadline=deadlineTimestamp};FixtureOriginalCustody=custody;FixtureDeadline=deadlineTimestamp;'
Replace-Once 'created = true;' 'created = true;FixtureProcessId=checked((int)process.ProcessId);'
Replace-Once 'writeTask = inputStream.WriteAsync(inputBytes, 0, inputBytes.Length);' 'if(FixtureEarlyCapture){FixtureCaptureRelease.Set();if(!SpinWait.SpinUntil(()=>FixtureOutputTask.IsCompleted&&FixtureErrorTask.IsCompleted,remaining()))throw new TimeoutException("Early capture setup did not settle under original deadline");}writeTask = inputStream.WriteAsync(inputBytes, 0, inputBytes.Length);FixtureWriteTask=writeTask;'
Replace-Once 'if(stdinWrite!=IntPtr.Zero||Volatile.Read(ref custody.CleanupExpired)!=0)throw new RecordedFailureAbort("Original stdin EOF closure failed");' 'FixtureOriginalEofClosed=stdinWrite==IntPtr.Zero;if(stdinWrite!=IntPtr.Zero||Volatile.Read(ref custody.CleanupExpired)!=0)throw new RecordedFailureAbort("Original stdin EOF closure failed");'
Replace-Once 'Interlocked.Exchange(ref Exceeded,1);' 'Interlocked.Exchange(ref Exceeded,1);FixtureWritePendingAtLimit=FixtureWriteTask!=null&&!FixtureWriteTask.IsCompleted;FixtureCaptureRelease.Set();'
Replace-Once 'outputTask=Capture(outputStream, budget); errorTask=Capture(errorStream, budget);' 'FixtureOutputStream=outputStream;FixtureErrorStream=errorStream;outputTask=Capture(outputStream, budget); errorTask=Capture(errorStream, budget);FixtureOutputTask=outputTask;FixtureErrorTask=errorTask;'
$readFault=@'
int read=await stream.ReadAsync(buffer,count,chunkSize-count).ConfigureAwait(false);
if(read>0) {
  bool originalOutput=Object.ReferenceEquals(stream,FixtureOutputStream);
  bool originalError=Object.ReferenceEquals(stream,FixtureErrorStream);
  if(!originalOutput&&!originalError)throw new InvalidOperationException("Fixture did not observe original capture stream");
  if(originalOutput)Interlocked.Increment(ref FixtureOutputReads);else Interlocked.Increment(ref FixtureErrorReads);
  if((originalOutput&&FixtureMode!="stdin_after_limit")||FixtureMode=="both") {
    int left=(int)Math.Clamp((budget.Custody.Deadline-Stopwatch.GetTimestamp())*1000/Stopwatch.Frequency,0L,int.MaxValue);
    if(!FixtureCaptureRelease.Wait(left))throw new TimeoutException("Fixture capture gate was not released under original deadline");
    var injected=new Win32Exception(originalOutput?1117:31,originalOutput?"fixture stdout read fault":"fixture stderr read fault");
    if(originalOutput){FixtureOutputError=injected;FixtureOutputFaultAt=Stopwatch.GetTimestamp();}
    else{FixtureErrorError=injected;FixtureErrorFaultAt=Stopwatch.GetTimestamp();}
    throw injected;
  }
}
'@
Replace-Once 'int read=await stream.ReadAsync(buffer,count,chunkSize-count).ConfigureAwait(false);' $readFault
$retirementFault=@'
stage="process_retirement";
if(FixtureMode=="retirement_then_capture") {
  if(!exited)throw new InvalidOperationException("Fixture requires actual parent exit before retirement fault");
  FixtureRetirementError=new Win32Exception(5,"fixture original retirement observation fault");
  FixtureRetirementFaultAt=Stopwatch.GetTimestamp();throw FixtureRetirementError;
}
'@
Replace-Once 'stage="process_retirement";' $retirementFault
Replace-Once 'stage="process_capture";' 'stage="process_capture";FixtureCaptureRelease.Set();'
# This release is inside the ORIGINAL finally, after real process retirement.
# It exposes later faults from original capture tasks when the main try threw.
Replace-Once 'var ioTasks=new List<Task>();' 'FixtureCaptureRelease.Set();var ioTasks=new List<Task>();'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($text,$Source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw [InvalidOperationException]::new('Strict instrumented definition pack did not parse')}
$nativeTemplates=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('namespace GauntletLive {')},$true))
if($nativeTemplates.Count -ne 1){throw [InvalidOperationException]::new('One complete native template required')}
$expectedIdentity=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($nativeTemplates[0].Value))).ToLowerInvariant()
$instrumentedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
. $ast.GetScriptBlock()
Initialize-LiveGateNative
$native='GauntletLive.Native' -as [type]
if(-not [string]::Equals([GauntletLive.Native]::SourceIdentity,$expectedIdentity,[StringComparison]::Ordinal)){throw [InvalidOperationException]::new('Instrumented native template identity mismatch')}
[GauntletLive.Native]::FixtureMode=$Mode
[GauntletLive.Native]::FixtureEarlyCapture=[bool]$EarlyCapture
$checks=[Collections.Generic.List[object]]::new()
function Check([bool]$Condition,[string]$Name){$script:checks.Add([ordered]@{passed=$Condition;name=$Name})}
Add-Type -TypeDefinition @'
using System;using System.Threading;using System.Threading.Tasks;
public static class NativeIoOriginalDisposalGate {
  public static readonly ManualResetEventSlim Entered=new ManualResetEventSlim(false),Release=new ManualResetEventSlim(false);
  public static Task Start(Action original){return Task.Run(()=>{Entered.Set();Release.Wait();original();});}
}
'@ -ErrorAction Stop
$script:FixtureOriginalOwner=$null
$originalDisposal=(Get-Command Start-ReviewPipelineDisposal -CommandType Function).ScriptBlock
if($DeadlineControl){
  function Start-ReviewPipelineDisposal {
    param($Owner,$Pipeline)
    $script:FixtureOriginalOwner=$Owner;$Owner['DisposalIntent']=$true
    $original=Get-ReviewOwnedPipelineDisposalAction -Owner $Owner -Pipeline $Pipeline
    $task=[NativeIoOriginalDisposalGate]::Start($original);$Owner['DisposeTask']=$task;return ,$task
  }
}
# Finite output from a real harmless child avoids a new pipe-saturation stimulus.
$command='[Console]::Out.Write("o");[Console]::Out.Flush();[Console]::Error.Write("e");[Console]::Error.Flush();exit 0'
$stdinText=''
if($Mode -in @('mixed_limit','stdin_after_limit')){$command='[Console]::Out.Write("o");[Console]::Out.Flush();[Console]::Error.Write(("e"*4194305));[Console]::Error.Flush();Start-Sleep -Seconds 120'}
if($Mode -eq 'stdin_after_limit'){$stdinText='x'*600000}
$arguments=@('-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
$result=$null;$actual=$null;$escaped=$null;$finalizerErrors=[Collections.Generic.List[Exception]]::new()
$operationDeadline=0L
try{
  if($Boundary -eq 'direct'){
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=[Environment]::ProcessPath;$start.WorkingDirectory=[IO.Path]::GetTempPath()
    foreach($arg in $arguments){$start.ArgumentList.Add($arg)}
    $operationDeadline=[Diagnostics.Stopwatch]::GetTimestamp()+20L*[Diagnostics.Stopwatch]::Frequency
    $result=[GauntletLive.Native]::RunUntil($start,$stdinText,$operationDeadline,[Threading.CancellationToken]::None)
  }else{
    $operationDeadline=[Diagnostics.Stopwatch]::GetTimestamp()+20L*[Diagnostics.Stopwatch]::Frequency
    $result=Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList $arguments -StdinText $stdinText -WorkingDirectory ([IO.Path]::GetTempPath()) -DeadlineTimestamp $operationDeadline -RequireProcessTreeRetirement
  }
  $actual=[GauntletLive.Native]::FixtureOriginalResult
  $custody=[GauntletLive.Native]::FixtureOriginalCustody
  $out=[GauntletLive.Native]::FixtureOutputTask;$err=[GauntletLive.Native]::FixtureErrorTask;$write=[GauntletLive.Native]::FixtureWriteTask
  Check ($null -ne $actual -and $null -ne $custody -and [GauntletLive.Native]::FixtureProcessId -gt 0) 'actual original RunUntil receipt custody and created native process are retained'
  Check ([GauntletLive.Native]::FixtureDeadline -le $operationDeadline -and [GauntletLive.Native]::FixtureDeadline -eq $custody.Deadline) 'actual native custody keeps its original inherited deadline'
  Check ($null -ne $out -and $null -ne $err -and $out.IsCompleted -and $err.IsCompleted) 'same original capture tasks reach terminal states'
  Check ([GauntletLive.Native]::FixtureOutputReads -gt 0 -and [GauntletLive.Native]::FixtureErrorReads -gt 0) 'both original capture streams actually read real child bytes'
  if($Mode -ne 'stdin_after_limit'){
    Check ($out.IsFaulted -and [object]::ReferenceEquals($out.Exception.GetBaseException(),[GauntletLive.Native]::FixtureOutputError)) 'stdout task carries exact exception thrown inside original Capture body'
  }
  if($Mode -eq 'both'){
    Check ($err.IsFaulted -and [object]::ReferenceEquals($err.Exception.GetBaseException(),[GauntletLive.Native]::FixtureErrorError)) 'stderr task carries distinct exact exception thrown inside original Capture body'
  }elseif($Mode -eq 'retirement_then_capture'){
    Check ($err.IsCompletedSuccessfully -and $null -ne [GauntletLive.Native]::FixtureRetirementError -and [GauntletLive.Native]::FixtureRetirementFaultAt -lt [GauntletLive.Native]::FixtureOutputFaultAt) 'original retirement fault precedes later original stdout task fault while stderr succeeds'
  }else{
    Check ($err.IsFaulted -and $err.Exception.GetBaseException() -is [InvalidOperationException]) 'real other-channel CaptureBudget.Limit faults original stderr task'
    if($Mode -eq 'stdin_after_limit'){
      Check ([GauntletLive.Native]::FixtureWritePendingAtLimit -and $null -ne $write -and $write.IsCompleted -and $write.IsFaulted -and $out.IsCompletedSuccessfully) 'real original WriteAsync was pending at actual cap crossing and its terminal fault is observed after actual job retirement'
    }
  }
  Check ($actual.ProcessTreeRetired -and -not $actual.StartFailed -and -not $actual.TimedOut -and $actual.ExitCode -eq -1) 'real native process and original I/O retire despite refused execution result'
  Check ($custody.JobClosed -and $custody.CleanupTask.IsCompletedSuccessfully -and $custody.CleanupExpired -eq 0 -and $custody.Unresolved.Count -eq 0) 'real original native handles streams and cleanup physically settle without fabricated retirement'
  $runRegistry=$native.GetField('runs',[Reflection.BindingFlags]'NonPublic,Static').GetValue($null)
  Check (-not $runRegistry.ContainsKey($actual)) 'actual native owner removes only the physically retired original run'
  if($Boundary -eq 'direct'){Check ([object]::ReferenceEquals($result,$actual)) 'direct return is exact original RunUntil receipt'}
  else{
    $receipt=$result.NativeProcessResult
    $scalars=@{ExitCode=$actual.ExitCode;StartFailed=$actual.StartFailed;TimedOut=$actual.TimedOut;ErrorMessage=$actual.ErrorMessage;StderrText=$actual.Stderr;ProcessTreeRetired=$actual.ProcessTreeRetired}
    $same=$null -ne $receipt -and $receipt.IsReadOnly -and $receipt.Keys.Count -eq 6
    foreach($key in $scalars.Keys){$same=$same -and $receipt.ContainsKey($key) -and [object]::Equals($receipt[$key],$scalars[$key])}
    Check $same 'facade native-six receipt matches all actual original native scalar values'
  }
  $ledger=@($result.Failure)+@($result.CleanupFailures)
  Check ($null -ne $result.Failure -and @($result.CleanupFailures).Count -le 2) 'failure plus at most two secondary faults remain bounded'
  $five=$true
  foreach($fault in $ledger){
    if($null -eq $fault){$five=$false;continue}
    if($Boundary -eq 'facade'){$five=$five -and $fault.IsReadOnly -and $fault.Keys.Count -eq 5}else{$five=$five -and @($fault.PSObject.Properties).Count -eq 5}
    foreach($key in @('Code','Stage','Type','HResult','NativeError')){if($Boundary -eq 'facade'){$five=$five -and $fault.ContainsKey($key)}else{$five=$five -and $null -ne $fault.PSObject.Properties[$key]}}
    $five=$five -and $fault.Code -is [string] -and $fault.Code -cmatch '^[a-z][a-z0-9_]{0,63}$' -and $fault.Stage -is [string] -and $fault.Stage -cmatch '^[a-z][a-z0-9_]{0,63}$'
  }
  Check $five 'all projected faults expose exactly the bounded five-field coded schema'
  if($EarlyCapture){
    Check ([GauntletLive.Native]::FixtureOriginalEofClosed -and $write.IsCompletedSuccessfully) 'early-capture setup proves actual original stdin write and raw EOF close succeeded'
    Check (@($ledger|Where-Object {$_.Code -ceq 'native_failure'}).Count -eq 0) 'successful original raw EOF close does not invent a native failure after independent early captures'
  }
  if($Mode -ne 'stdin_after_limit'){
    Check (@($ledger|Where-Object {$_.NativeError -eq 1117 -and $_.Type -ceq 'System.ComponentModel.Win32Exception'}).Count -eq 1) 'exact original stdout native cause is represented once'
  }
  if($Mode -in @('both','retirement_then_capture')){
    $other=if($Mode -eq 'both'){31}else{5}
    Check (@($ledger|Where-Object {$_.NativeError -eq $other -and $_.Type -ceq 'System.ComponentModel.Win32Exception'}).Count -eq 1) 'independent stderr or earlier retirement native cause is represented once'
  }else{
    Check (@($ledger|Where-Object {$_.Code -ceq 'capture_limit'}).Count -eq 1) 'same actual capture-budget refusal is represented once without duplicate synthetic slot consumption'
    if($Mode -eq 'stdin_after_limit'){
      $writeCause=$write.Exception.GetBaseException()
      Check (@($ledger|Where-Object {$_.Code -ceq 'stdin_failure' -and $_.Type -ceq $writeCause.GetType().FullName -and $_.HResult -eq $writeCause.HResult}).Count -eq 1) 'actual terminal original stdin task cause survives earlier capture-limit ErrorMessage and finally observation'
    }
  }
  if($Mode -eq 'retirement_then_capture'){
    Check ($result.Failure.NativeError -eq 5 -and $result.Failure.Stage -ceq 'process_retirement') 'earlier real retirement-stage failure remains primary'
  }
  if($DeadlineControl){
    $owner=$script:FixtureOriginalOwner
    Check ([NativeIoOriginalDisposalGate]::Entered.IsSet -and $null -ne $owner -and -not $owner['DisposeTask'].IsCompleted -and -not $result.ProcessTreeRetired -and $result.TimedOut) 'same original generic disposer remains unresolved at actual owner deadline'
    Check (@($result.CleanupFailures|Where-Object {$_.Code -ceq 'owned_deadline'}).Count -eq 1 -and @($result.CleanupFailures).Count -eq 2) 'two-secondary saturation retains independent native cause and actual owning deadline'
    Check ([object]::ReferenceEquals($owner['Registry'][$owner['Token']],$owner) -and $owner['Deadline'] -eq $operationDeadline) 'deadline refusal retains original generic owner token registry and clock'
  }else{Check ($result.ProcessTreeRetired -and -not $result.TimedOut) 'in-time direct or facade outcome reports actual physical retirement separately from failure'}
}catch{$escaped=$_}
finally{
  # Release only existing test gates. Never replace a task, receipt, owner or deadline.
  try{[GauntletLive.Native]::FixtureCaptureRelease.Set()}catch{$finalizerErrors.Add($_.Exception)}
  try{[NativeIoOriginalDisposalGate]::Release.Set()}catch{$finalizerErrors.Add($_.Exception)}
  try{
    $owner=$script:FixtureOriginalOwner
    if($null -ne $owner){
      try{$settled=$owner['DisposeTask'].Wait(5000)}catch{$settled=$owner['DisposeTask'].IsCompleted;throw}
      if(-not $settled){throw [TimeoutException]::new('Exact original released disposer did not physically settle')}
      $observation=Complete-ReviewOwnedWork -OwnerRegistry $owner['Registry'] -Token $owner['Token']
      Check ($owner['RetirementConfirmed'] -and $owner['Registry'].Count -eq 0 -and $null -ne $observation -and $observation.Retired -and -not $observation.Completed -and $null -eq $observation.Result) 'released same original disposer permits only late physical reconciliation'
      Check (-not $result.ProcessTreeRetired -and $result.TimedOut -and $result.ExitCode -eq -1) 'late reconciliation never rewrites immutable earlier facade refusal'
    }
  }catch{$finalizerErrors.Add($_.Exception)}
  try{Set-Item Function:Start-ReviewPipelineDisposal $originalDisposal}catch{$finalizerErrors.Add($_.Exception)}
}
$afterHash=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
Check ([string]::Equals($beforeHash,$afterHash,[StringComparison]::Ordinal)) 'source raw bytes remain identical after original operation and finalization'
$failed=@($checks|Where-Object {-not $_.passed})
[ordered]@{proposal='native-io-private-red-v1';runtime=$PSVersionTable.PSVersion.ToString();dotnet=[Environment]::Version.ToString();source_sha256=$beforeHash;source_after_sha256=$afterHash;instrumented_pack_sha256=$instrumentedHash;native_template_identity=$expectedIdentity;mode=$Mode;boundary=$Boundary;deadline_control=[bool]$DeadlineControl;native_process_id=[GauntletLive.Native]::FixtureProcessId;operation_deadline=$operationDeadline;native_deadline=[GauntletLive.Native]::FixtureDeadline;checks=$checks.ToArray();failed_count=$failed.Count;escaped_error=$(if($null -ne $escaped){$escaped.ToString()}else{$null});finalizer_errors=@($finalizerErrors|ForEach-Object {$_.ToString()});actual_native=$actual;result=$result;original_stdout_task_faulted=$([GauntletLive.Native]::FixtureOutputTask.IsFaulted);original_stderr_task_faulted=$([GauntletLive.Native]::FixtureErrorTask.IsFaulted);original_stdin_task_faulted=$($null -ne [GauntletLive.Native]::FixtureWriteTask -and [GauntletLive.Native]::FixtureWriteTask.IsFaulted);original_stdin_pending_at_cap=[GauntletLive.Native]::FixtureWritePendingAtLimit;original_stdin_cause=$(if($null -ne [GauntletLive.Native]::FixtureWriteTask -and [GauntletLive.Native]::FixtureWriteTask.IsFaulted){[GauntletLive.Native]::FixtureWriteTask.Exception.GetBaseException().ToString()}else{$null});strict_anchor_count=$anchors.Count}|ConvertTo-Json -Depth 12
if($failed.Count -gt 0 -or $null -ne $escaped -or $finalizerErrors.Count -gt 0){exit 1}
