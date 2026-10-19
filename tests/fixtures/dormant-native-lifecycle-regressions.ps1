param([Parameter(Mandatory)][string]$Source,[ValidateSet('late_cancel','cleanup_faults','blocking_cleanup','attribute_failure')][string]$Mode='late_cancel')
$ErrorActionPreference='Stop'
$sourceHash=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
$text=[IO.File]::ReadAllText($Source)
function Replace-Once([string]$Before,[string]$After){
 if($script:text.Split($Before,[StringSplitOptions]::None).Length -ne 2){throw ('Fixture instrumentation anchor must occur once: '+$Before)}
 $script:text=$script:text.Replace($Before,$After)
}
# Sealed instrumentation changes only these exact native fault/gate points in a
# fresh isolated definition; the source hash/loader still covers the actual copy.
Replace-Once 'public static string SourceIdentity { get { return "__GAUNTLET_NATIVE_SOURCE_IDENTITY__"; } }' 'public static Action<string> FixtureGate; public static Func<IntPtr,bool> FixtureClose; public static int FixtureParentExit; public static string SourceIdentity { get { return "__GAUNTLET_NATIVE_SOURCE_IDENTITY__"; } }'
Replace-Once 'stage="process_capture";' 'stage="process_capture";FixtureParentExit=result.ExitCode==0?1:0;'
if($Mode -eq 'late_cancel'){
 if($text.Contains('                var decoder=Encoding.UTF8.GetDecoder();')){
  Replace-Once '                var decoder=Encoding.UTF8.GetDecoder();' '                FixtureGate?.Invoke("capture_eof");var decoder=Encoding.UTF8.GetDecoder();'
 }else{
  Replace-Once '                return Encoding.UTF8.GetString(retained.ToArray());' '                FixtureGate?.Invoke("capture_eof");return Encoding.UTF8.GetString(retained.ToArray());'
 }
}else{
 Replace-Once 'try{resource.Dispose();}' 'try{FixtureGate?.Invoke("stream_cleanup");resource.Dispose();}'
 Replace-Once 'if(!CloseHandle(handle))' 'if(FixtureClose!=null?!FixtureClose(handle):!CloseHandle(handle))'
 if($Mode -eq 'attribute_failure'){
  Replace-Once 'DeleteProcThreadAttributeList(attributes);attributesDeleted=true;' 'FixtureGate?.Invoke("attribute_cleanup");DeleteProcThreadAttributeList(attributes);attributesDeleted=true;'
  Replace-Once 'Marshal.FreeHGlobal(attributes);' 'FixtureGate?.Invoke("attribute_memory_free");Marshal.FreeHGlobal(attributes);'
 }
}
. ([scriptblock]::Create($text))
Initialize-LiveGateNative
Add-Type -TypeDefinition @'
using System;using System.Diagnostics;using System.Reflection;using System.Runtime.InteropServices;using System.Threading;using System.Threading.Tasks;
public static class DormantLifecycleBridge {
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool CloseHandle(IntPtr handle);
 public static object Result;public static bool PendingAfterExit;public static bool SameOwnerRetained;
 public static int CleanupCalls,FailedCloses,AttributeMemoryFreed;public static long Elapsed;
 public static void Run(Type native,ProcessStartInfo start,string mode) {
  var gate=new ManualResetEventSlim(false);var source=new CancellationTokenSource();int eof=0;
  var flags=BindingFlags.Public|BindingFlags.Static;
  var field=native.GetField("FixtureGate",flags);
  Action<string> action=(stage)=>{
   if(stage=="attribute_cleanup")throw new System.IO.IOException("fixture attribute deletion fault");
   if(stage=="attribute_memory_free")Interlocked.Increment(ref AttributeMemoryFreed);
   if(stage=="capture_eof"){Interlocked.Increment(ref eof);gate.Wait();}
   if(stage=="stream_cleanup"){
    int n=Interlocked.Increment(ref CleanupCalls);
    if(mode=="blocking_cleanup"&&n==1)gate.Wait();
    if(mode=="cleanup_faults"&&n==1)throw new System.IO.IOException("fixture cleanup fault");
   }
  };
  field.SetValue(null,action);
  if(mode=="cleanup_faults")native.GetField("FixtureClose",flags).SetValue(null,(Func<IntPtr,bool>)(handle=>{
   if(Volatile.Read(ref CleanupCalls)>0&&Interlocked.CompareExchange(ref FailedCloses,1,0)==0)return false;
   return CloseHandle(handle);
  }));
  var method=native.GetMethod("RunMilliseconds",new[]{typeof(ProcessStartInfo),typeof(string),typeof(int),typeof(CancellationToken)});
  var clock=Stopwatch.StartNew();
  var run=Task.Run(()=>method.Invoke(null,new object[]{start,"",mode=="blocking_cleanup"?1500:10000,source.Token}));
  try {
   if(mode=="late_cancel") {
    while(clock.ElapsedMilliseconds<6000&&(Volatile.Read(ref eof)<2||(int)native.GetField("FixtureParentExit",flags).GetValue(null)!=1))Thread.Sleep(1);
    PendingAfterExit=Volatile.Read(ref eof)==2&&(int)native.GetField("FixtureParentExit",flags).GetValue(null)==1&&!run.IsCompleted;
    source.Cancel();gate.Set();
   }
   if(mode=="blocking_cleanup"){
    while(clock.ElapsedMilliseconds<6000&&Volatile.Read(ref CleanupCalls)==0)Thread.Sleep(1);
    // The real cleanup task is blocked, and the original call must still return
    // at its deadline without claiming retirement or losing original custody.
   }
   if(!run.Wait(12000))throw new TimeoutException("Original fixture run did not return within external bound");
   Result=run.Result;Elapsed=clock.ElapsedMilliseconds;
   if(mode!="late_cancel"){
    var registry=native.GetField("runs",BindingFlags.NonPublic|BindingFlags.Static).GetValue(null);
    var contains=registry.GetType().GetMethod("ContainsKey");
    SameOwnerRetained=(bool)contains.Invoke(registry,new[]{Result});
   }
  }finally{
   gate.Set();source.Dispose();
   if(mode=="blocking_cleanup"){
    var registry=native.GetField("runs",BindingFlags.NonPublic|BindingFlags.Static).GetValue(null);
    var lookup=registry.GetType().GetMethod("TryGetValue");object[] args={Result,null};
    if(Result!=null&&(bool)lookup.Invoke(registry,args)){
     var task=(Task)args[1].GetType().GetField("CleanupTask").GetValue(args[1]);if(task!=null&&!task.Wait(5000))throw new TimeoutException("Released original cleanup task did not finish");
    }
   }
   gate.Dispose();
  }
 }
}
'@
$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=[Environment]::ProcessPath;$start.WorkingDirectory=[IO.Path]::GetTempPath()
$command=if($Mode -eq 'cleanup_faults'){'[Console]::Out.Write(("x"*4194305));exit 0'}else{'[Console]::Out.Write("done");exit 0'}
foreach($arg in @('-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))){$start.ArgumentList.Add($arg)}
[DormantLifecycleBridge]::Run(('GauntletLive.Native' -as [type]),$start,$Mode)
$result=[DormantLifecycleBridge]::Result
$ok=switch($Mode){
 'late_cancel' {[DormantLifecycleBridge]::PendingAfterExit -and $result.ExitCode -eq -1 -and $result.ProcessTreeRetired -and $null -ne $result.Failure -and $result.Failure.Code -ceq 'transport_abort'}
 'cleanup_faults' {$result.ExitCode -eq -1 -and -not $result.ProcessTreeRetired -and $result.Failure.Code -ceq 'capture_limit' -and $result.CleanupFailures.Length -eq 2 -and [DormantLifecycleBridge]::CleanupCalls -eq 3 -and [DormantLifecycleBridge]::FailedCloses -eq 1 -and [DormantLifecycleBridge]::SameOwnerRetained}
 'blocking_cleanup' {$result.ExitCode -eq -1 -and -not $result.ProcessTreeRetired -and ($result.Failure.Code -ceq 'native_cleanup_deadline' -or @($result.CleanupFailures.Code) -ccontains 'native_cleanup_deadline') -and [DormantLifecycleBridge]::Elapsed -lt 4000 -and [DormantLifecycleBridge]::SameOwnerRetained}
 'attribute_failure' {$result.ExitCode -eq -1 -and -not $result.ProcessTreeRetired -and $result.Failure.Code -ceq 'native_cleanup' -and $result.Failure.Stage -ceq 'attribute_cleanup' -and [DormantLifecycleBridge]::AttributeMemoryFreed -eq 0 -and [DormantLifecycleBridge]::SameOwnerRetained}
}
@{mode=$Mode;passed=[bool]$ok;elapsed_ms=[DormantLifecycleBridge]::Elapsed;runtime=$PSVersionTable.PSVersion.ToString();dotnet=[Environment]::Version.ToString();pending_after_parent_exit=[DormantLifecycleBridge]::PendingAfterExit;cleanup_calls=[DormantLifecycleBridge]::CleanupCalls;failed_closes=[DormantLifecycleBridge]::FailedCloses;same_owner_retained=[DormantLifecycleBridge]::SameOwnerRetained;source_sha256=$sourceHash.ToLowerInvariant();native_result=$result}|ConvertTo-Json -Depth 6
if((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -cne $sourceHash){throw 'Candidate source changed during instrumented verification'}
if(-not $ok){exit 1}
