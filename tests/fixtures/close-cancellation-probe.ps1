param([Parameter(Mandatory)][string]$Source)
$ErrorActionPreference="Stop"
$hash=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
$text=[IO.File]::ReadAllText($Source)
$changes=@(
 @("public static string SourceIdentity { get { return `"__GAUNTLET_NATIVE_SOURCE_IDENTITY__`"; } }","public static Action FixtureJobClose; public static string SourceIdentity { get { return `"__GAUNTLET_NATIVE_SOURCE_IDENTITY__`"; } }"),
 @("lock(custody.JobSync){CloseOwned(result,custody,ref job);","lock(custody.JobSync){FixtureJobClose?.Invoke();CloseOwned(result,custody,ref job);")
)
foreach($change in $changes){if($text.Split($change[0],[StringSplitOptions]::None).Length -ne 2){throw "Instrumentation anchor not unique"};$text=$text.Replace($change[0],$change[1])}
. ([scriptblock]::Create($text))
Initialize-LiveGateNative
Add-Type -TypeDefinition @"
using System;using System.Diagnostics;using System.Reflection;using System.Threading;using System.Threading.Tasks;
public static class CloseCancellationProbe{
 public static bool GateEntered,RunCompletePastDeadline;public static long Elapsed;public static object Result;
 public static void Run(Type native,ProcessStartInfo start){
  var entered=new ManualResetEventSlim(false);var release=new ManualResetEventSlim(false);var cts=new CancellationTokenSource();Task cancel=null;
  native.GetField("FixtureJobClose").SetValue(null,(Action)(()=>{entered.Set();release.Wait();}));
  var method=native.GetMethod("RunMilliseconds",new[]{typeof(ProcessStartInfo),typeof(string),typeof(int),typeof(CancellationToken)});
  var watch=Stopwatch.StartNew();var run=Task.Run(()=>method.Invoke(null,new object[]{start,"",1500,cts.Token}));
  try{
   GateEntered=entered.Wait(5000);if(!GateEntered)throw new Exception("Original job close gate not entered");
   cancel=Task.Run(()=>cts.Cancel());
   while(!cts.IsCancellationRequested)Thread.Sleep(1);
   while(watch.ElapsedMilliseconds<2300)Thread.Sleep(1);
   RunCompletePastDeadline=run.IsCompleted;
  }finally{
   release.Set();if(!run.Wait(5000))throw new Exception("Run did not finish after original close released");Result=run.Result;Elapsed=watch.ElapsedMilliseconds;
   if(cancel!=null&&!cancel.Wait(5000))throw new Exception("Original cancellation callback did not retire");
   cts.Dispose();release.Dispose();entered.Dispose();
  }
 }
}
"@
$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=[Environment]::ProcessPath;$start.WorkingDirectory=[IO.Path]::GetTempPath()
foreach($arg in @("-NoProfile","-Command","exit 0")){$start.ArgumentList.Add($arg)}
[CloseCancellationProbe]::Run(("GauntletLive.Native" -as [type]),$start)
@{runtime=$PSVersionTable.PSVersion.ToString();dotnet=[Environment]::Version.ToString();gate_entered=[CloseCancellationProbe]::GateEntered;run_completed_800ms_past_deadline=[CloseCancellationProbe]::RunCompletePastDeadline;elapsed_ms=[CloseCancellationProbe]::Elapsed;native_result=[CloseCancellationProbe]::Result;source_sha256=$hash.ToLowerInvariant()}|ConvertTo-Json -Depth 6
if((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -cne $hash){throw "Source changed"}
