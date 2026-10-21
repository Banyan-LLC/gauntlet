param([Parameter(Mandatory)][string]$Source)
$ErrorActionPreference="Stop"
$hash=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
$text=[IO.File]::ReadAllText($Source)
$changes=@(
 @("public static string SourceIdentity { get { return `"__GAUNTLET_NATIVE_SOURCE_IDENTITY__`"; } }","public static Action<string> FixtureRetire; public static string SourceIdentity { get { return `"__GAUNTLET_NATIVE_SOURCE_IDENTITY__`"; } }"),
 @('stage="process_retirement";','stage="process_retirement";FixtureRetire?.Invoke("retirement_entry");')
)
foreach($change in $changes){if($text.Split($change[0],[StringSplitOptions]::None).Length -ne 2){throw "Instrumentation anchor not unique"};$text=$text.Replace($change[0],$change[1])}
$before="Require(TerminateJobObject(job, 1));"
if($text.Split($before,[StringSplitOptions]::None).Length -ne 3){throw "Expected exact two direct termination sites"}
$text=$text.Replace($before,'{FixtureRetire?.Invoke("terminate_job");Require(TerminateJobObject(job, 1));}')
. ([scriptblock]::Create($text))
Initialize-LiveGateNative
Add-Type -TypeDefinition @"
using System;using System.Diagnostics;using System.Reflection;using System.Threading;using System.Threading.Tasks;
public static class DelayedRetirementProbe{
 public static bool GateEntered;public static int LateTerminations;public static object Result;
 public static void Run(Type native,ProcessStartInfo start){
  var entered=new ManualResetEventSlim(false);var release=new ManualResetEventSlim(false);
  var clock=Stopwatch.StartNew();
  native.GetField("FixtureRetire").SetValue(null,(Action<string>)(stage=>{
   if(stage=="retirement_entry"){entered.Set();release.Wait();}
   if(stage=="terminate_job"&&clock.ElapsedMilliseconds>=1800)Interlocked.Increment(ref LateTerminations);
  }));
  var method=native.GetMethod("RunMilliseconds",new[]{typeof(ProcessStartInfo),typeof(string),typeof(int)});
  var run=Task.Run(()=>method.Invoke(null,new object[]{start,"",1500}));
  try{
   GateEntered=entered.Wait(5000);if(!GateEntered)throw new Exception("Original retirement gate not entered");
   while(clock.ElapsedMilliseconds<1900)Thread.Sleep(1);
  }finally{
   release.Set();if(!run.Wait(5000))throw new Exception("Run did not finish after release");Result=run.Result;
   entered.Dispose();release.Dispose();
  }
 }
}
"@
$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=[Environment]::ProcessPath;$start.WorkingDirectory=[IO.Path]::GetTempPath()
foreach($arg in @("-NoProfile","-Command","Start-Sleep -Seconds 120")){$start.ArgumentList.Add($arg)}
[DelayedRetirementProbe]::Run(("GauntletLive.Native" -as [type]),$start)
@{runtime=$PSVersionTable.PSVersion.ToString();dotnet=[Environment]::Version.ToString();gate_entered=[DelayedRetirementProbe]::GateEntered;direct_job_terminations_after_original_deadline=[DelayedRetirementProbe]::LateTerminations;native_result=[DelayedRetirementProbe]::Result;source_sha256=$hash.ToLowerInvariant()}|ConvertTo-Json -Depth 6
if((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -cne $hash){throw "Source changed"}
