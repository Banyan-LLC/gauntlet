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
  Replace-Once 'Marshal.FreeHGlobal(handles);' 'FixtureGate?.Invoke("handles_memory_free");Marshal.FreeHGlobal(handles);'
  Replace-Once 'Marshal.FreeHGlobal(environment);' 'FixtureGate?.Invoke("environment_memory_free");Marshal.FreeHGlobal(environment);'
  Replace-Once 'attributes = Marshal.AllocHGlobal(size);' 'attributes = Marshal.AllocHGlobal(size);FixtureAttributes=attributes;'
  Replace-Once 'handles = Marshal.AllocHGlobal(IntPtr.Size * 3);' 'handles = Marshal.AllocHGlobal(IntPtr.Size * 3);FixtureHandles=handles;'
  Replace-Once 'Marshal.WriteIntPtr(handles, IntPtr.Size * 2, stderrWrite);' 'Marshal.WriteIntPtr(handles, IntPtr.Size * 2, stderrWrite);FixtureHandleValues=new IntPtr[]{stdinRead,stdoutWrite,stderrWrite};'
  Replace-Once 'public static Action<string> FixtureGate;' 'public static IntPtr FixtureAttributes,FixtureHandles;public static IntPtr[] FixtureHandleValues;public static Action<string> FixtureGate;'
 }
}
. ([scriptblock]::Create($text))
Initialize-LiveGateNative
Add-Type -TypeDefinition @'
using System;using System.Diagnostics;using System.Reflection;using System.Runtime.InteropServices;using System.Threading;using System.Threading.Tasks;
public static class DormantLifecycleBridge {
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool CloseHandle(IntPtr handle);
 public static object Result;public static bool PendingAfterExit;public static bool SameOwnerRetained;
 public static int CleanupCalls,FailedCloses,AttributeMemoryFreed,HandlesMemoryFreed,EnvironmentMemoryFreed;public static long Elapsed;
 public static bool ExactAttributesRetained,ExactHandlesRetained,OriginalHandleValuesIntact;
 public static long AttributePointer,HandlesPointer;
 public static void Run(Type native,ProcessStartInfo start,string mode) {
  var gate=new ManualResetEventSlim(false);var source=new CancellationTokenSource();int eof=0;
  var flags=BindingFlags.Public|BindingFlags.Static;
  var field=native.GetField("FixtureGate",flags);
  Action<string> action=(stage)=>{
   if(stage=="attribute_cleanup")throw new System.IO.IOException("fixture attribute deletion fault");
   if(stage=="attribute_memory_free")Interlocked.Increment(ref AttributeMemoryFreed);
   if(stage=="handles_memory_free")Interlocked.Increment(ref HandlesMemoryFreed);
   if(stage=="environment_memory_free")Interlocked.Increment(ref EnvironmentMemoryFreed);
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
    if(mode=="attribute_failure"){
     var lookup=registry.GetType().GetMethod("TryGetValue");object[] original={Result,null};
     if(!(bool)lookup.Invoke(registry,original))throw new InvalidOperationException("Original result custody was lost");
     var unresolved=(System.Collections.Generic.List<object>)original[1].GetType().GetField("Unresolved").GetValue(original[1]);
     var attributes=(IntPtr)native.GetField("FixtureAttributes",flags).GetValue(null);
     var handles=(IntPtr)native.GetField("FixtureHandles",flags).GetValue(null);
     AttributePointer=attributes.ToInt64();HandlesPointer=handles.ToInt64();
     ExactAttributesRetained=attributes!=IntPtr.Zero&&unresolved.Contains(attributes);
     ExactHandlesRetained=handles!=IntPtr.Zero&&unresolved.Contains(handles);
     if(AttributeMemoryFreed==0&&HandlesMemoryFreed==0&&ExactAttributesRetained&&ExactHandlesRetained){
      var values=(IntPtr[])native.GetField("FixtureHandleValues",flags).GetValue(null);
      OriginalHandleValuesIntact=values.Length==3;
      for(int index=0;index<3;index++)OriginalHandleValuesIntact&=values[index]!=IntPtr.Zero&&Marshal.ReadIntPtr(handles,index*IntPtr.Size)==values[index];
     }
    }
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
 'attribute_failure' {$result.ExitCode -eq -1 -and -not $result.ProcessTreeRetired -and $result.Failure.Code -ceq 'native_cleanup' -and $result.Failure.Stage -ceq 'attribute_cleanup' -and [DormantLifecycleBridge]::AttributeMemoryFreed -eq 0 -and [DormantLifecycleBridge]::HandlesMemoryFreed -eq 0 -and [DormantLifecycleBridge]::ExactAttributesRetained -and [DormantLifecycleBridge]::ExactHandlesRetained -and [DormantLifecycleBridge]::OriginalHandleValuesIntact -and [DormantLifecycleBridge]::EnvironmentMemoryFreed -eq 1 -and [DormantLifecycleBridge]::CleanupCalls -eq 3 -and [DormantLifecycleBridge]::SameOwnerRetained}
}
@{mode=$Mode;passed=[bool]$ok;attribute_pointer=[DormantLifecycleBridge]::AttributePointer;handles_pointer=[DormantLifecycleBridge]::HandlesPointer;attribute_memory_freed=[DormantLifecycleBridge]::AttributeMemoryFreed;handles_memory_freed=[DormantLifecycleBridge]::HandlesMemoryFreed;environment_memory_freed=[DormantLifecycleBridge]::EnvironmentMemoryFreed;exact_attributes_retained=[DormantLifecycleBridge]::ExactAttributesRetained;exact_handles_retained=[DormantLifecycleBridge]::ExactHandlesRetained;original_handle_values_intact=[DormantLifecycleBridge]::OriginalHandleValuesIntact;elapsed_ms=[DormantLifecycleBridge]::Elapsed;runtime=$PSVersionTable.PSVersion.ToString();dotnet=[Environment]::Version.ToString();pending_after_parent_exit=[DormantLifecycleBridge]::PendingAfterExit;cleanup_calls=[DormantLifecycleBridge]::CleanupCalls;failed_closes=[DormantLifecycleBridge]::FailedCloses;same_owner_retained=[DormantLifecycleBridge]::SameOwnerRetained;source_sha256=$sourceHash.ToLowerInvariant();native_result=$result}|ConvertTo-Json -Depth 6
if((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -cne $sourceHash){throw 'Candidate source changed during instrumented verification'}
if(-not $ok){exit 1}
