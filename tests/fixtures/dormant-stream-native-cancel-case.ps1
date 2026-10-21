param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$Source,[ValidateRange(0,7)][int]$Channel=2,[switch]$LegacyMilliseconds,[switch]$HoldCallerCallback,[switch]$Inline,[ValidateSet("none","precanceled","partial","partial_precanceled","unknown")][string]$ConstructorCase="none")
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. $Source
. (Join-Path $PSScriptRoot 'dormant-stream-native-pipe.ps1')
# Break caught: remove the original stream-refusal -> native cancellation link.
# The actual original pipeline, guard, native job and cleanup paths run unchanged.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Threading;
using System.Threading.Tasks;
public static class StreamNativeCancellationFixture {
 public static Task Producer;
 public static readonly ManualResetEventSlim CallbackEntered=new(false),CallbackRelease=new(false);
 public static CancellationTokenRegistration Blocking;
 public static System.Collections.Concurrent.ConcurrentDictionary<string,object> NativeState;
 public static void Hold(CancellationToken token,object state){
  NativeState=(System.Collections.Concurrent.ConcurrentDictionary<string,object>)state;
  Blocking=token.Register(()=>{CallbackEntered.Set();CallbackRelease.Wait();});
 }
 public static object OriginalNativeResult,OriginalNativeCustody;
 public static long RefusedAt,ExitedAt;
 public static int NativePid,Emissions;
 public static bool NativeAliveAtRefusal,PromptDeath;
 public static string ProducerFailure;
 public static void Start(object pipeline,object output,object pipe,int channel,CancellationTokenSource caller) {
  var streams=(PSDataStreams)pipeline.GetType().GetProperty("Streams").GetValue(pipeline);
  Producer=Task.Run(()=>{
   try {
    long deadline=(long)pipe.GetType().GetField("Deadline").GetValue(pipe);
    NativePid=(int)pipe.GetType().GetMethod("ReadPid").Invoke(pipe,null);
    {

     // Test-only reflection observes the exact retained original run before
     // cancellation. It creates no replacement process/result/custody.
     Type nativeType=null;
     foreach(var assembly in AppDomain.CurrentDomain.GetAssemblies()){
      nativeType=assembly.GetType("GauntletLive.Native",false);
      if(nativeType!=null)break;
     }
     var registry=(System.Collections.IEnumerable)nativeType.GetField("runs",System.Reflection.BindingFlags.Static|System.Reflection.BindingFlags.NonPublic).GetValue(null);
     int originals=0;
     foreach(var item in registry){
      OriginalNativeResult=item.GetType().GetProperty("Key").GetValue(item);
      OriginalNativeCustody=item.GetType().GetProperty("Value").GetValue(item);
      originals++;
     }
     if(originals!=1)throw new InvalidOperationException("Expected one actual original native run");
     pipe.GetType().GetMethod("VerifyJob").Invoke(pipe,new object[]{NativePid,OriginalNativeCustody});
     NativeAliveAtRefusal=(bool)pipe.GetType().GetMethod("Alive").Invoke(pipe,null);
     string text=new string('x',1500);
     RefusedAt=Stopwatch.GetTimestamp();
     if(channel==7)caller.Cancel();
     else try {
      for(int i=0;i<130;i++){
       Emissions++;
       switch(channel){
        case 0:((PSDataCollection<PSObject>)output).Add(PSObject.AsPSObject(text));break;
        case 1:streams.Error.Add(new ErrorRecord(new InvalidOperationException(text),"fixture",ErrorCategory.NotSpecified,null));break;
        case 2:streams.Warning.Add(new WarningRecord(text));break;
        case 3:streams.Verbose.Add(new VerboseRecord(text));break;
        case 4:streams.Debug.Add(new DebugRecord(text));break;
        case 5:streams.Information.Add(new InformationRecord(text,"fixture"));break;
        case 6:streams.Progress.Add(new ProgressRecord(i,"fixture",text));break;
       }
      }
     } catch(PipelineStoppedException) {}
     int remaining=(int)Math.Clamp((deadline-Stopwatch.GetTimestamp())*1000/Stopwatch.Frequency,0L,int.MaxValue);
     if(remaining<=0)throw new TimeoutException("Original fixture deadline before process observation");
     PromptDeath=(bool)pipe.GetType().GetMethod("Exited").Invoke(pipe,new object[]{Math.Min(1500,remaining)})&&Stopwatch.GetTimestamp()<deadline;
     if(PromptDeath)ExitedAt=Stopwatch.GetTimestamp();
    }
   } catch(Exception error) {ProducerFailure=error.GetType().FullName;}
  });
 }
}
'@
$pipe=$null
$child=Join-Path $PSScriptRoot 'dormant-stream-native-sleeper.ps1'
$caller=[Threading.CancellationTokenSource]::new()
$original=(Get-Command Invoke-BoundedProcessCore).ScriptBlock
Set-Item Function:Invoke-FixtureNativeCore $original
function Invoke-BoundedProcessCore {
 param($FileName,$ArgList,$StdinText,$WorkingDirectory,$TimeoutSec,$TimeoutMilliseconds,$DeadlineTimestamp,$EnvironmentMap,$FailureCancellationToken,[switch]$ClearEnvironment,[switch]$RequireProcessTreeRetirement)
 $context=Get-ReviewOwnedWorkContext
 $owner=$context['OwnedWorkOwner']
 if($script:FixtureHold){
  $nativeState=$ExecutionContext.SessionState.PSVariable.Get('script:ReviewNativeProcessState').Value
  [StreamNativeCancellationFixture]::Hold($FailureCancellationToken,$nativeState)
 }
 if($script:FixtureConstructorCase -ceq 'none'){[StreamNativeCancellationFixture]::Start($owner['Pipeline'],$owner['Output'],$script:FixturePipe,$script:FixtureChannel,$script:FixtureCaller)}
 if($script:FixtureLegacyMilliseconds){
  # Exercise the existing relative Core path with a deliberately narrower 2s
  # native budget inside the still-original 12s owned invocation.
  if((Get-ReviewRemainingMilliseconds $owner['Deadline']) -le 2000){throw 'Fixture lacks its original outer budget'}
  $null=$PSBoundParameters.Remove('DeadlineTimestamp')
  $PSBoundParameters['TimeoutMilliseconds']=2000
 }
 Invoke-FixtureNativeCore @PSBoundParameters
}
function Invoke-FixtureInlineWorker {
 param($State,$Arguments)
 try{$State['Result']=Invoke-BoundedProcess @Arguments}finally{$State['CoreRetired']=$true}
}
# Copy only the saved leaf and variables alongside the unchanged original pack.
$savedDefinitions=(Get-Command Get-ReviewWorkerDefinitions).ScriptBlock
function Get-ReviewWorkerDefinitions {
 param([Parameter(Mandatory)][scriptblock]$LibraryDefinition)
 $ast=$LibraryDefinition.Ast;while($ast.Parent){$ast=$ast.Parent}
 $definitions=@{}
 foreach($function in $ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){$definitions[$function.Name]=(Get-Command $function.Name -CommandType Function).ScriptBlock}
 $definitions['Invoke-FixtureNativeCore']=(Get-Command Invoke-FixtureNativeCore).ScriptBlock
 $definitions['Invoke-FixtureInlineWorker']=(Get-Command Invoke-FixtureInlineWorker).ScriptBlock
 return $definitions
}
# Make the normal public native facade expose its original owner state locally.
$savedOwned=(Get-Command Invoke-ReviewOwnedWork).ScriptBlock
Set-Item Function:Invoke-FixtureOwnedWork $savedOwned
function Invoke-ReviewOwnedWork {
 param($Kind,$OwnerRegistry,$DeadlineTimestamp,$WorkerName,$Definitions,$Arguments,$State,$SharedVariables=@{})
 $script:FixtureObservedState=$State
 $SharedVariables=@{FixturePipe=$script:FixturePipe;FixtureHold=$script:FixtureHold;FixtureConstructorCase=$script:FixtureConstructorCase;FixtureChannel=$script:FixtureChannel;FixtureCaller=$script:FixtureCaller;FixtureLegacyMilliseconds=$script:FixtureLegacyMilliseconds}
 Invoke-FixtureOwnedWork @PSBoundParameters -SharedVariables $SharedVariables
}
$fixtureDeadline=0L
$savedInitializer=(Get-Command Initialize-ReviewOwnedStreams).ScriptBlock
if($ConstructorCase -in @('partial','partial_precanceled','unknown')){
 $body=$savedInitializer.ToString()
 $needle=if($ConstructorCase -ceq 'unknown'){'registration=token.Register(state=>((Entry)state).Cancel(),this);'}else{'caller.Register();refusal.Register();'}
 $injection=if($ConstructorCase -ceq 'unknown'){'if(Volatile.Read(ref attempted)!=0)throw new System.IO.IOException("FIXTURE-UNKNOWN-REGISTER");registration=token.Register(state=>((Entry)state).Cancel(),this);'}else{'caller.Register();throw new System.IO.IOException("FIXTURE-PARTIAL-REGISTER");'}
 if([regex]::Matches($body,[regex]::Escape($needle)).Count -ne 1){throw 'Constructor fixture refuses changed registration site'}
 $body=$body.Replace($needle,$injection)
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseInput($body,$savedInitializer.File,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'Constructor instrumentation failed to parse'}
 Set-Item Function:Initialize-ReviewOwnedStreams $ast.GetScriptBlock()
}
$script:FixtureConstructorCase=$ConstructorCase
$script:FixtureHold=[bool]$HoldCallerCallback;$script:FixtureChannel=$Channel;$script:FixtureCaller=$caller;$script:FixtureLegacyMilliseconds=[bool]$LegacyMilliseconds
$fixturePrimaryError=$null;$fixtureCleanupErrors=[Collections.Generic.List[object]]::new()
try {
 if($Inline -and -not $HoldCallerCallback){throw 'Inline is reserved for callback-cohort control'}
 if($HoldCallerCallback -and $Channel -ne 7){throw 'Callback-cohort control uses original caller cancellation'}
 $fixtureDeadline=[Diagnostics.Stopwatch]::GetTimestamp()+12L*[Diagnostics.Stopwatch]::Frequency
 $pipe=[NativeFixturePipe]::new($fixtureDeadline);$script:FixturePipe=$pipe
 if($ConstructorCase -in @('precanceled','partial_precanceled')){$caller.Cancel()}
 $nativeArguments=@{FileName=[Environment]::ProcessPath;ArgList=@('-NoProfile','-File',$child,'-PipeName',$pipe.Name,'-Nonce',$pipe.Nonce,'-ServerPid',[string]$pipe.ServerPid,'-Deadline',[string]$fixtureDeadline);WorkingDirectory=$PSScriptRoot;DeadlineTimestamp=$fixtureDeadline;FailureCancellationToken=$caller.Token;RequireProcessTreeRetirement=$true}
 if($Inline){
  $rootState=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
  $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
  $defs=Get-ReviewWorkerDefinitions -LibraryDefinition (Get-Command Invoke-BoundedProcess).ScriptBlock
  $rootOutcome=Invoke-ReviewOwnedWork -Kind native_link_cohort -OwnerRegistry $registry -DeadlineTimestamp $fixtureDeadline -WorkerName Invoke-FixtureInlineWorker -Definitions $defs -Arguments $nativeArguments -State $rootState
  $result=$rootState['Result'];$state=[StreamNativeCancellationFixture]::NativeState
 }else{
  $result=Invoke-BoundedProcess @nativeArguments
  $state=$script:FixtureObservedState;$rootState=$state
 }
 $owner=$rootState['OwnedWorkOwner']
 if($ConstructorCase -cne 'none'){. (Join-Path $PSScriptRoot 'dormant-stream-native-constructor-assertions.ps1')}
 elseif($HoldCallerCallback){. (Join-Path $PSScriptRoot 'dormant-stream-native-link-assertions.ps1')}
 else{
 if(-not [StreamNativeCancellationFixture]::Producer.Wait((Get-ReviewRemainingMilliseconds $fixtureDeadline))){throw 'Original producer deadline'}
 $poll=[Diagnostics.Stopwatch]::StartNew()
 while(-not $owner['RetirementConfirmed'] -and $poll.ElapsedMilliseconds -lt 2000 -and (Get-ReviewRemainingMilliseconds $fixtureDeadline) -gt 0){$null=Complete-ReviewOwnedWork -OwnerRegistry $owner['Registry'] -Token $owner['Token'];Start-Sleep -Milliseconds 5}
 $generic=Get-ReviewOwnedWorkRetirement -State $state
 $native=Get-ReviewProcessRetirement -State $state
 Assert-True ([StreamNativeCancellationFixture]::Producer.IsCompletedSuccessfully -and $null -eq [StreamNativeCancellationFixture]::ProducerFailure) 'actual concurrent CLR producer completes without fixture error'
 Assert-True ([StreamNativeCancellationFixture]::NativeAliveAtRefusal) 'same original native child is alive when concurrent refusal begins'
 Assert-True ([StreamNativeCancellationFixture]::PromptDeath) 'same original native child physically exits within 1500ms of refusal'
 Assert-True ($result.ExitCode -eq -1 -and -not $result.TimedOut -and -not $result.StartFailed) 'aggregate refuses execution without inventing a startup or deadline failure'
 Assert-True ($null -ne $state['Result'] -and $state['Result'].ProcessTreeRetired -and -not $state['Result'].TimedOut -and -not $state['Result'].StartFailed) 'retained original native result truthfully confirms actual job retirement before deadline'
 Assert-True ($generic.Retired -and $native.Retired -and $result.ProcessTreeRetired -and $owner['RetirementConfirmed'] -and $owner['Registry'].Count -eq 0) 'generic native aggregate and original registry agree on actual retirement'
 Assert-True ([object]::ReferenceEquals($state['Result'],[StreamNativeCancellationFixture]::OriginalNativeResult)) 'retained native result is the exact original pending run object observed before refusal'
 Assert-True ($state['Deadline'] -eq $owner['Deadline'] -and [object]::ReferenceEquals($owner['State'],$state)) 'original deadline state and owner remain the authority'
 Assert-True ($null -ne $result.NativeProcessResult -and $result.NativeProcessResult.IsReadOnly -and $result.NativeProcessResult.Keys.Count -eq 6) 'actual native receipt preserves exact immutable six scalar fields'
 $disposedField=[Threading.CancellationTokenSource].GetField('_disposed',[Reflection.BindingFlags]'Instance,NonPublic')
 $link=$state['NativeFailureCancellation']
 $signal=if($link -is [Threading.CancellationTokenSource]){$link}else{$link.GetType().GetField('signal',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($link)}
 Assert-True ($state['NativeFailureCancellationDisposed'] -is [bool] -and $state['NativeFailureCancellationDisposed'] -and [bool]$disposedField.GetValue($signal)) 'exact retained cancellation link is physically disposed after native registration cleanup'
 $refusalField=$owner['StreamGuard'].GetType().GetField('refusal',[Reflection.BindingFlags]'Instance,NonPublic')
 $refusal=if($null -ne $refusalField){$refusalField.GetValue($owner['StreamGuard'])}else{$null}
 Assert-True ($refusal -is [Threading.CancellationTokenSource] -and $owner['StreamGuardDisposed'] -is [bool] -and $owner['StreamGuardDisposed'] -and [bool]$disposedField.GetValue($refusal)) 'exact original guard cancellation source is disposed by same original retained resource task'
 Assert-True ($null -ne $result.Failure -and $result.Failure.IsReadOnly -and $result.Failure.Keys.Count -eq 5) 'aggregate native failure preserves exact immutable flat five-field schema'
 $custody=[StreamNativeCancellationFixture]::OriginalNativeCustody
 Assert-True ($null -ne $custody -and $(if($LegacyMilliseconds){$custody.Deadline -le $owner['Deadline']}else{$custody.Deadline -eq $owner['Deadline']}) -and $custody.JobClosed -and $custody.CleanupExpired -eq 0 -and $custody.CleanupTask.IsCompletedSuccessfully) 'exact original native custody closes its job through original successful cleanup within its original deadline without extending the owner deadline'
 if($Channel -lt 7){
  $visible=@($result.Failure)+@($result.CleanupFailures)
  $expected=if($Channel -eq 0){'owned_unexpected_output'}else{'owned_stream_limit'}
  Assert-True (@($visible|Where-Object {$_.Code -ceq $expected -and $_.Stage -ceq 'worker_stream'}).Count -eq 1) 'original bounded stream refusal remains visible once in public native failure projection'
 }
 if($Channel -lt 7){
  $code=if($Channel -eq 0){'owned_unexpected_output'}else{'owned_stream_limit'}
  Assert-True ($owner['StreamFailure'].Code -ceq $code -and $owner['StopRequested'] -and $owner['Abandoned']) 'actual original guarded stream crossing remains the refusal cause'
  Assert-True ($owner['StopTask'].IsCompletedSuccessfully -and $owner['DisposeTask'].IsCompletedSuccessfully -and $owner['OutputDisposed']) 'original stop invocation pipeline and output disposal physically settle'
 }else{
  Assert-True ($caller.IsCancellationRequested -and $null -eq $owner['StreamFailure']) 'original caller cancellation remains effective independently of stream refusal'
 }
 $latency=if([StreamNativeCancellationFixture]::ExitedAt){[long](([StreamNativeCancellationFixture]::ExitedAt-[StreamNativeCancellationFixture]::RefusedAt)*1000/[Diagnostics.Stopwatch]::Frequency)}else{$null}
 [ordered]@{runtime=$PSVersionTable.PSVersion.ToString();channel=$Channel;legacy_milliseconds=[bool]$LegacyMilliseconds;native_deadline=$custody.Deadline;native_pid=[StreamNativeCancellationFixture]::NativePid;native_alive_at_refusal=[StreamNativeCancellationFixture]::NativeAliveAtRefusal;prompt_death=[StreamNativeCancellationFixture]::PromptDeath;death_latency_ms=$latency;emissions=[StreamNativeCancellationFixture]::Emissions;producer_failure=[StreamNativeCancellationFixture]::ProducerFailure;generic_retired=$generic.Retired;native_retired=$native.Retired;aggregate_retired=$result.ProcessTreeRetired;aggregate_timeout=$result.TimedOut;native_timeout=$(if($null -ne $state['Result']){$state['Result'].TimedOut}else{$null});stream_code=$(if($null -ne $owner['StreamFailure']){$owner['StreamFailure'].Code}else{$null});aggregate_code=$result.Failure.Code;owner_deadline=$owner['Deadline'];state_deadline=$state['Deadline'];native_receipt=$result.NativeProcessResult}|ConvertTo-Json -Depth 6 -Compress|Write-Output
 }
 }catch{$fixturePrimaryError=$_}finally{
 [StreamNativeCancellationFixture]::CallbackRelease.Set()
 # Start independent cleanup attempts before any bounded observation can consume
 # the remaining original deadline; retained task fields preserve every failure.
 try{[NativeFixtureCleanup]::Start([StreamNativeCancellationFixture]::Blocking,$caller,$fixtureDeadline)}catch{$fixtureCleanupErrors.Add($_)}
 try{
  if($null -ne [StreamNativeCancellationFixture]::Producer){$null=[StreamNativeCancellationFixture]::Producer.Wait((Get-ReviewRemainingMilliseconds $fixtureDeadline))}
 }catch{$fixtureCleanupErrors.Add($_)}
 $pipe=[NativeFixturePipe]::Original
 try{if($null -ne $pipe){$pipe.Dispose()}}catch{$fixtureCleanupErrors.Add($_)}
 try{[NativeFixtureCleanup]::Finish($fixtureDeadline)}catch{$fixtureCleanupErrors.Add($_)}
 Set-Item Function:Initialize-ReviewOwnedStreams $savedInitializer
 Set-Item Function:Invoke-BoundedProcessCore $original
 Set-Item Function:Get-ReviewWorkerDefinitions $savedDefinitions
 Set-Item Function:Invoke-ReviewOwnedWork $savedOwned
}
Assert-True ([NativeFixtureCleanup]::Retired) 'independent original test registration and caller source tasks retire within original deadline'
Assert-True ($null -ne $pipe -and $pipe.Retired -and $pipe.CleanupOnTime) 'exact original named pipe process handle connection read and disposal tasks retire inside original fixture deadline'
Assert-True ($fixtureCleanupErrors.Count -eq 0) 'all independent fixture cleanup failures remain observed separately'
$fixtureFailures=[Collections.Generic.List[Exception]]::new()
if($null -ne $fixturePrimaryError){$fixtureFailures.Add($fixturePrimaryError.Exception)}
foreach($errorRecord in $fixtureCleanupErrors){$fixtureFailures.Add($errorRecord.Exception)}
if($null -ne $pipe){
 foreach($errorCause in @($pipe.InitializationError,$pipe.PipeDisposalError,$pipe.ProcessDisposalError)){if($null -ne $errorCause){$fixtureFailures.Add($errorCause)}}
}
foreach($errorCause in @([NativeFixtureCleanup]::BlockingError,[NativeFixtureCleanup]::CallerError)){if($null -ne $errorCause){$fixtureFailures.Add($errorCause)}}
if(-not [NativeFixtureCleanup]::Retired -or $null -eq $pipe -or -not $pipe.Retired -or -not $pipe.CleanupOnTime){$fixtureFailures.Add([TimeoutException]::new('Original fixture cleanup remains unresolved or late'))}
if($fixtureFailures.Count){throw [AggregateException]::new('Original fixture primary and independent cleanup failures',$fixtureFailures)}
Write-TestResult
