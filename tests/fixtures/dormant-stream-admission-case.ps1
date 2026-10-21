param([string]$RepoRoot,[string]$Source,[string]$Expectation='green',[string]$Case='aggregate')
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
if(-not $Source){$Source=Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1'}
. $Source
Add-Type -TypeDefinition @'
using System;using System.ComponentModel;using System.Net;using System.Net.Http;using System.Net.Sockets;using System.Text.Json;using System.Management.Automation;
public sealed class StreamAdmissionCallbackException:Exception{public static int Calls;public override string Message{get{Calls++;return "CALLBACK-MESSAGE";}}}
public sealed class StreamAdmissionKey{
 public static int Calls;public override bool Equals(object other){Calls++;return false;}public override int GetHashCode(){Calls++;return 1;}
}
public static class StreamAdmissionFixture{
 public static long Allocated;public static int Calls;
 public static Exception Make(string mode){
 switch(mode){
 case "aggregate":var a=new Exception[65];a[0]=new StreamAdmissionCallbackException();for(int i=1;i<a.Length;i++)a[i]=new Exception(new string('s',32768));return new AggregateException("aggregate",a);
 case "override":return new StreamAdmissionCallbackException();
 case "nested":return new Exception("outer",new AggregateException(new StreamAdmissionCallbackException()));
 case "oversized":return new Exception(new string('s',1000000));
 case "win32":return new Win32Exception(5,"PRIVATE-MESSAGE");
 case "socket":return new SocketException(10061);
 case "json":return new JsonException("PRIVATE-MESSAGE","$.a",7,9);
 case "http":return new HttpRequestException("PRIVATE-MESSAGE",null,HttpStatusCode.Forbidden);
 case "jsonoversized":return new JsonException("short",new string('p',1000000),7,9);
 case "runtime":var runtime=new RuntimeException("PRIVATE-MESSAGE");runtime.Data["ReviewCode"]="fixture_typed";runtime.Data["ReviewStage"]="fixture_stage";return runtime;
 case "datatext":var data=new Exception("short");data.Data["text"]=new string('d',1000000);return data;
 case "datagraph":var graph=new Exception("short");graph.Data["value"]=new byte[1000000];return graph;
 case "details":case "errorid":return new Exception("short");
 case "mutation_count":case "mutation_key":case "mutation_value":case "mutation_text":var mutable=new Exception("short");mutable.Data["seed"]=1;return mutable;
 case "datakey":case "faultdata":var keyed=new Exception("short");keyed.Data.Add(new StreamAdmissionKey(),"value");StreamAdmissionKey.Calls=0;return keyed;
 default:throw new ArgumentException("mode");}}
 public static ErrorRecord Record(string mode){
 var record=new ErrorRecord(Make(mode),mode=="errorid"?new string('i',1000000):"bounded_fixture",ErrorCategory.NotSpecified,null);
 if(mode=="details")record.ErrorDetails=new ErrorDetails(new string('e',1000000));
 return record;
 }
 public static void Add(PowerShell ps,string mode){
 if(mode=="mutation_tags"){
  var info=new InformationRecord("short","fixture");long start=GC.GetAllocatedBytesForCurrentThread();
  try{ps.Streams.Information.Add(info);}finally{Allocated=GC.GetAllocatedBytesForCurrentThread()-start;}return;
 }
 var r=Record(mode);long b=GC.GetAllocatedBytesForCurrentThread();int c=StreamAdmissionCallbackException.Calls;try{ps.Streams.Error.Add(r);}finally{Allocated=GC.GetAllocatedBytesForCurrentThread()-b;Calls=StreamAdmissionCallbackException.Calls-c;}}
}
'@
if($Expectation -ceq 'red'){
 Initialize-ReviewOwnedStreams
 $m=('GauntletOwnedWork.StreamGuard' -as [type]).GetMethod('Charge',[Reflection.BindingFlags]'NonPublic,Static')
 $r=[StreamAdmissionFixture]::Record('aggregate');$b=[GC]::GetAllocatedBytesForCurrentThread()
 try{$null=$m.Invoke($null,[object[]]@(1,$r))}catch{}
 $allocated=[GC]::GetAllocatedBytesForCurrentThread()-$b
 Assert-True ([StreamAdmissionCallbackException]::Calls -gt 0) 'old admission invokes arbitrary inner Message'
 Assert-True ($allocated -gt 4000000) 'old admission allocates expanded string before cap'
 [ordered]@{getter_calls=[StreamAdmissionCallbackException]::Calls;allocated_bytes=$allocated}|ConvertTo-Json -Compress|Write-Output
 Write-TestResult;return
}
if($Case -ceq 'faultdata'){
 Initialize-ReviewOwnedStreams
 $m=('GauntletOwnedWork.StreamGuard' -as [type]).GetMethod('Fault',[Reflection.BindingFlags]'NonPublic,Static')
 $r=[StreamAdmissionFixture]::Make('faultdata');$b=[GC]::GetAllocatedBytesForCurrentThread()
 $fault=$m.Invoke($null,[object[]]@('owned_stop','worker_stop',$r))
 $allocated=[GC]::GetAllocatedBytesForCurrentThread()-$b
 Assert-Eq ([StreamAdmissionKey]::Calls) 0 'standalone stop-failure projection invokes no custom key equality/hash'
 Assert-Eq ([StreamAdmissionCallbackException]::Calls) 0 'standalone stop-failure projection invokes no formatter'
 Assert-True ($fault.Code -ceq 'owned_stop' -and $fault.Stage -ceq 'worker_stop' -and $null -eq $fault.Cause) 'standalone stop-failure refuses unsupported data graph with stable structural fallback'
 Assert-True ($allocated -lt 1000000) 'standalone projection allocates no expanded diagnostic'
 [ordered]@{case=$Case;getter_calls=0;key_calls=[StreamAdmissionKey]::Calls;allocated_bytes=$allocated;failure=$fault.Code;admitted=0;retired=$null}|ConvertTo-Json -Compress|Write-Output
 Write-TestResult;return
}
$mutationCase=$Case.StartsWith('mutation_',[StringComparison]::Ordinal)
if($mutationCase){
 # This fixture changes only the in-memory initializer definition. Production
 # source bytes remain pinned. The hook mutates the same dictionary exactly
 # after SafeData returns, before its second consumption in Charge.
 $initializer=(Get-Command Initialize-ReviewOwnedStreams).ScriptBlock.ToString()
 $afterValidation='var data=SafeData(ex);'
 $consumer='if(data!=null)foreach(System.Collections.DictionaryEntry pair in data){'
 if(($initializer.Split($afterValidation,[StringSplitOptions]::None).Count -ne 2) -or ($initializer.Split($consumer,[StringSplitOptions]::None).Count -ne 2)){throw 'Mutation instrumentation anchor changed'}
 $initializer=$initializer.Replace($afterValidation,$afterValidation+' StreamAdmissionMutation.Mutate(data);')
 $initializer=$initializer.Replace($consumer,$consumer+' StreamAdmissionMutation.Visits++;')
 $tagsCheck='if(info.Tags.Count>16)throw new InvalidOperationException("Unsupported information tags");'
 $tagsLoop='foreach(var tag in info.Tags){'
 if($initializer.Split($tagsCheck,[StringSplitOptions]::None).Count -ne 2 -or $initializer.Split($tagsLoop,[StringSplitOptions]::None).Count -ne 2){throw 'Tags instrumentation anchor changed'}
 $initializer=$initializer.Replace($tagsCheck,$tagsCheck+' StreamAdmissionMutation.MutateTags(info.Tags);')
 $initializer=$initializer.Replace($tagsLoop,$tagsLoop+' StreamAdmissionMutation.Visits++;')
 $fixtureClass=@'
public static class StreamAdmissionMutation {
 public static int Mutations,Visits,CountAfter,KeyCalls;
 static readonly string Mode="__MODE__";
 sealed class Key {public override bool Equals(object value){KeyCalls++;return false;}public override int GetHashCode(){KeyCalls++;return 1;}}
 public static void MutateTags(System.Collections.Generic.List<string> tags){
  if(Mode!="mutation_tags")return;
  Mutations++;for(int i=0;i<17;i++)tags.Add("short");CountAfter=tags.Count;
 }
 public static void Mutate(System.Collections.IDictionary data){
  Mutations++;if(Mutations!=1)throw new System.InvalidOperationException("Unexpected repeated mutation hook");
  switch(Mode){
   case "mutation_count":for(int i=0;i<16;i++)data.Add("late"+i,"short");break;
   case "mutation_key":data.Add(new Key(),"short");break;
   case "mutation_value":data.Add("late",new byte[1]);break;
   case "mutation_text":data.Add("late",new string('d',100));break;
  }
  CountAfter=data.Count;KeyCalls=0;
 }
}
'@
 $fixtureClass=$fixtureClass.Replace('__MODE__',$Case)
 $terminator="`n'@"
 if($initializer.Split($terminator,[StringSplitOptions]::None).Count -ne 2){throw 'Initializer source terminator changed'}
 $initializer=$initializer.Replace($terminator,"`n"+$fixtureClass+$terminator)
 Set-Item Function:Initialize-ReviewOwnedStreams ([scriptblock]::Create($initializer))
}
function Invoke-AdmissionWorker{
 param($State,$Arguments)
 try{[StreamAdmissionFixture]::Add($State['OwnedWorkOwner']['Pipeline'],$Arguments.Mode);$State['Continued']=$true;$State['Result']=New-ReviewReadOnlyRecord -Values @{Value='explicit'}}finally{$State['CoreRetired']=$true}
}
$registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$defs=Get-ReviewWorkerDefinitions -LibraryDefinition (Get-Command Invoke-ReviewOwnedWork).ScriptBlock
$defs['Invoke-AdmissionWorker']=(Get-Command Invoke-AdmissionWorker).ScriptBlock
$deadline=[Diagnostics.Stopwatch]::GetTimestamp()+15L*[Diagnostics.Stopwatch]::Frequency
$result=Invoke-ReviewOwnedWork -Kind stream_admission -OwnerRegistry $registry -DeadlineTimestamp $deadline -WorkerName Invoke-AdmissionWorker -Definitions $defs -Arguments @{Mode=$Case} -State $state
$owner=$state['OwnedWorkOwner'];$guard=$owner['StreamGuard']
if($Expectation -ceq 'mutation_red'){
 Assert-True ($Case -cin @('mutation_count','mutation_tags') -and [StreamAdmissionMutation]::Mutations -eq 1 -and [StreamAdmissionMutation]::CountAfter -eq 17 -and [StreamAdmissionMutation]::Visits -eq 17) 'old source consumes all seventeen entries appended after validation'
 Assert-True ($guard.TotalAdmittedBytes -gt 0 -and $state['Continued']) 'old source admits above its entry cap'
 if($Case -ceq 'mutation_count'){
  Assert-True ($result.Failure.Code -ceq 'owned_error_stream' -and $null -eq $result.Result) 'old error admits unsupported dictionary shape before publishing structural failure'
 }else{
  Assert-True ($result.Completed -and $result.Result.Value -ceq 'explicit' -and $null -eq $result.Failure) 'old information admission permits explicit success above tag cap'
 }
 Assert-True ($registry.Count -eq 0 -and $owner['OutputDisposed'] -and $owner['RetirementConfirmed']) 'red actual original worker physically retires'
 [ordered]@{case=$Case;visited=[StreamAdmissionMutation]::Visits;count_after=[StreamAdmissionMutation]::CountAfter;admitted=$guard.TotalAdmittedBytes}|ConvertTo-Json -Compress|Write-Output
 Write-TestResult;return
}
Assert-Eq ([StreamAdmissionCallbackException]::Calls) 0 "$Case zero arbitrary getters"
Assert-Eq ([StreamAdmissionKey]::Calls) 0 "$Case zero custom key callbacks"
Assert-Eq ([StreamAdmissionFixture]::Calls) 0 "$Case zero admission callbacks"
Assert-True ([StreamAdmissionFixture]::Allocated -lt 1000000) "$Case no expanded allocation"
Assert-True ($null -eq $result.Result -and $null -ne $result.Failure) "$Case error refuses success"
Assert-True ($owner['Deadline'] -eq $deadline -and [object]::ReferenceEquals($owner['State'],$state)) "$Case original owner clock and state"
Assert-Eq $owner['Pipeline'].Streams.Error.Count 0 "$Case no retained raw error record"
Assert-Eq $owner['Pipeline'].Streams.Information.Count 0 "$Case no retained raw information record"
if($Case -cin @('aggregate','override','nested','oversized','jsonoversized','datatext','datagraph','details','errorid','datakey','mutation_count','mutation_key','mutation_value','mutation_text','mutation_tags')){
 Assert-True ($result.Failure.Code -cin @('owned_stream_shape','owned_stream_limit') -and $guard.TotalAdmittedBytes -eq 0 -and -not $result.Completed -and -not $state.ContainsKey('Continued')) "$Case rejected before admission"
}else{
 Assert-True ($result.Failure.Code -ceq $(if($Case -ceq 'runtime'){'fixture_typed'}else{'owned_error_stream'}) -and $state['Continued'] -and $guard.TotalAdmittedBytes -gt 0 -and $guard.TotalAdmittedBytes -le 4096) "$Case legitimate bounded error"
 $cause=$result.Failure.Cause
 switch($Case){
 'win32'{Assert-True ($cause.Type -ceq 'System.ComponentModel.Win32Exception' -and $cause.NativeError -eq 5) 'Win32 numeric cause'}
 'socket'{Assert-True ($cause.Type -ceq 'System.Net.Sockets.SocketException' -and $cause.SocketError -eq 10061 -and $cause.NativeError -eq 10061) 'socket numeric cause'}
 'json'{Assert-True ($cause.Type -ceq 'System.Text.Json.JsonException' -and $cause.JsonLine -eq 7 -and $cause.JsonByte -eq 9) 'JSON numeric cause'}
 'runtime'{Assert-True ($cause.Type -ceq 'System.Management.Automation.RuntimeException' -and $result.Failure.Stage -ceq 'fixture_stage') 'runtime typed code and cause'}
 'http'{Assert-True ($cause.Type -ceq 'System.Net.Http.HttpRequestException' -and $cause.HttpStatus -eq 403) 'HTTP numeric cause'}
 }}
if($mutationCase){
 Assert-Eq ([StreamAdmissionMutation]::Mutations) 1 'one deterministic mutation after original SafeData return'
 Assert-Eq ([StreamAdmissionMutation]::KeyCalls) 0 'mutated dictionary invokes no arbitrary key callback'
 if($Expectation -cne 'mutation_red'){
  Assert-True ([StreamAdmissionMutation]::Visits -le $(if($Case -ceq 'mutation_tags'){17}else{9})) 'second enumeration independently enforces its per-channel entry limit'
  Assert-True ($result.Failure.Code -ceq 'owned_stream_shape' -and $guard.TotalAdmittedBytes -eq 0) 'late count or primitive shape mutation refuses before admission'
 }
}
Assert-True (($result.Failure|ConvertTo-Json -Depth 10 -Compress) -notmatch 'CALLBACK-|PRIVATE-|ssss|StackTrace|Message') "$Case bounded DTO"
$w=[Diagnostics.Stopwatch]::StartNew();while($registry.Count -gt 0 -and $w.ElapsedMilliseconds -lt 5000){$null=Complete-ReviewOwnedWork -OwnerRegistry $registry;Start-Sleep -Milliseconds 10}
Assert-True ($registry.Count -eq 0 -and $owner['OutputDisposed'] -and $owner['RetirementConfirmed']) "$Case original physical retirement"
Assert-True ($null -eq ('GauntletLive.Native' -as [type])) "$Case native cold"
[ordered]@{case=$Case;getter_calls=[StreamAdmissionCallbackException]::Calls;allocated_bytes=[StreamAdmissionFixture]::Allocated;failure=$result.Failure.Code;admitted=$guard.TotalAdmittedBytes;retired=$result.Retired;mutation_visits=$(if($mutationCase){[StreamAdmissionMutation]::Visits}else{$null})}|ConvertTo-Json -Compress|Write-Output
Write-TestResult
