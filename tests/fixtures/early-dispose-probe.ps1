param([Parameter(Mandatory)][string]$Source)
$ErrorActionPreference='Stop'
$hash=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
$text=[IO.File]::ReadAllText($Source)
function Change([string]$Before,[string]$After){if($script:text.Split($Before,[StringSplitOptions]::None).Length -ne 2){throw ('Expected one native anchor: '+$Before)};$script:text=$script:text.Replace($Before,$After)}
Change 'public static string SourceIdentity { get { return "__GAUNTLET_NATIVE_SOURCE_IDENTITY__"; } }' 'public static Action<string> FixtureDispose; public static string SourceIdentity { get { return "__GAUNTLET_NATIVE_SOURCE_IDENTITY__"; } }'
Change 'try{resource.Dispose();}' 'try{FixtureDispose?.Invoke("owned_dispose");resource.Dispose();}'
if($text.Contains('if (stdinDone) { inputStream.Dispose();')){
 Change 'if (stdinDone) { inputStream.Dispose();' 'if (stdinDone) { FixtureDispose?.Invoke("early_stdin_dispose");inputStream.Dispose();'
}
. ([scriptblock]::Create($text))
Initialize-LiveGateNative
Add-Type -TypeDefinition @'
using System;using System.Diagnostics;using System.Reflection;using System.Threading;using System.Threading.Tasks;
public static class EarlyDisposeProbe {
 public static bool Entered,CompletedWhileHeld,OwnerRetained;public static string FirstStage;public static long NativeReturnedMs;public static object Result;
 public static void Run(Type native,ProcessStartInfo start){
  var entered=new ManualResetEventSlim(false);var release=new ManualResetEventSlim(false);int gates=0;
  native.GetField("FixtureDispose").SetValue(null,(Action<string>)(stage=>{if(Interlocked.Increment(ref gates)==1){FirstStage=stage;entered.Set();release.Wait();}}));
  var method=native.GetMethod("RunMilliseconds",new[]{typeof(ProcessStartInfo),typeof(string),typeof(int)});
  var clock=Stopwatch.StartNew();var run=Task.Run(()=>{var result=method.Invoke(null,new object[]{start,"",1500});NativeReturnedMs=clock.ElapsedMilliseconds;return result;});
  try {
   Entered=entered.Wait(5000);if(!Entered)throw new Exception("Actual original disposal control was not entered");
   while(clock.ElapsedMilliseconds<2300)Thread.Sleep(1);CompletedWhileHeld=run.IsCompleted;
  } finally {
   release.Set();if(!run.Wait(5000))throw new Exception("Original native call failed to retire after gate release");Result=run.Result;
   var registry=native.GetField("runs",BindingFlags.NonPublic|BindingFlags.Static).GetValue(null);
   var lookup=registry.GetType().GetMethod("TryGetValue");object[] args={Result,null};
   if((bool)lookup.Invoke(registry,args)){
    var task=(Task)args[1].GetType().GetField("CleanupTask").GetValue(args[1]);if(task!=null&&!task.Wait(5000))throw new Exception("Released original cleanup task did not retire");
    OwnerRetained=(bool)registry.GetType().GetMethod("ContainsKey").Invoke(registry,new[]{Result});
   }
   entered.Dispose();release.Dispose();
  }
 }
}
'@
$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=[Environment]::ProcessPath;$start.WorkingDirectory=[IO.Path]::GetTempPath()
foreach($arg in @('-NoProfile','-Command','[Console]::In.ReadToEnd()|Out-Null;exit 0')){$start.ArgumentList.Add($arg)}
[EarlyDisposeProbe]::Run(('GauntletLive.Native' -as [type]),$start)
$r=[EarlyDisposeProbe]::Result
$ok=[EarlyDisposeProbe]::Entered -and [EarlyDisposeProbe]::CompletedWhileHeld -and [EarlyDisposeProbe]::NativeReturnedMs -lt 2100 -and [EarlyDisposeProbe]::FirstStage -ceq 'owned_dispose' -and $r.ExitCode -eq -1 -and -not $r.ProcessTreeRetired -and [EarlyDisposeProbe]::OwnerRetained
@{passed=[bool]$ok;runtime=$PSVersionTable.PSVersion.ToString();dotnet=[Environment]::Version.ToString();source_sha256=$hash.ToLowerInvariant();first_disposal_stage=[EarlyDisposeProbe]::FirstStage;gate_entered=[EarlyDisposeProbe]::Entered;caller_completed_while_gate_held=[EarlyDisposeProbe]::CompletedWhileHeld;native_call_returned_ms=[EarlyDisposeProbe]::NativeReturnedMs;owner_retained_after_cleanup_join=[EarlyDisposeProbe]::OwnerRetained;native_result=$r}|ConvertTo-Json -Depth 6
if((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -cne $hash){throw 'Original candidate source changed'}
if(-not $ok){exit 1}
