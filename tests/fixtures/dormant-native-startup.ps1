# Fixture cleanup preservation v1: primary and independent cleanup errors.
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
$library=Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1'
. $library
Add-Type -TypeDefinition @'
using System;
using System.Reflection;
using System.Threading;
using System.Collections.Concurrent;
public static class StartupDeadlineFixture {
 public static readonly ManualResetEventSlim Entered=new(false),Release=new(false);
 public static Func<object> Factory;
 public static string Stage;
 public static int ActionCalls;
 public static object ExpectedLibraryDefinition;
 public static readonly ConcurrentBag<StartupPipelineFixture> Pipelines=new();
 public static void Pause(string stage){if(Stage==stage){Entered.Set();Release.Wait(2500);}}
 public static object Create(){Pause("create");var pipeline=new StartupPipelineFixture(Factory());Pipelines.Add(pipeline);return pipeline;}
 public static void Reset(string stage){Stage=stage;ActionCalls=0;Entered.Reset();Release.Reset();}
 public static void EnterAction(){Interlocked.Increment(ref ActionCalls);}
 public static void ColdInitialize(){Pause("native_initialize");throw new InvalidOperationException("Synthetic cold initialization stopped before native launch");}
}
public sealed class StartupPipelineFixture:IDisposable {
 readonly object inner;
 public volatile bool Disposed,InvocationComplete;
 public StartupPipelineFixture(object pipeline){inner=pipeline;}
 MethodInfo NoArgs(string name){foreach(var m in inner.GetType().GetMethods())if(m.Name==name&&!m.IsGenericMethod&&m.GetParameters().Length==0)return m;throw new MissingMethodException();}
 public StartupPipelineFixture AddScript(string text){StartupDeadlineFixture.Pause("configure");inner.GetType().GetMethod("AddScript",new[]{typeof(string)}).Invoke(inner,new object[]{text});return this;}
 public StartupPipelineFixture AddArgument(object value){inner.GetType().GetMethod("AddArgument",new[]{typeof(object)}).Invoke(inner,new[]{value});return this;}
 public object Streams {get{return inner.GetType().GetProperty("Streams").GetValue(inner);}}
 public object Invoke(){StartupDeadlineFixture.Pause("submit");try{return NoArgs("Invoke").Invoke(inner,Array.Empty<object>());}finally{InvocationComplete=true;}}
 public IAsyncResult BeginInvoke(){StartupDeadlineFixture.Pause("submit");return (IAsyncResult)NoArgs("BeginInvoke").Invoke(inner,Array.Empty<object>());}
 public void Dispose(){StartupDeadlineFixture.Pause("dispose");NoArgs("Dispose").Invoke(inner,Array.Empty<object>());Disposed=true;}
}
'@
$realPowerShell=[Management.Automation.PowerShell]
[StartupDeadlineFixture]::Factory=[Delegate]::CreateDelegate([Func[object]],$realPowerShell.GetMethod('Create',[type[]]@()))
. $library
$originalStartupDefinitions=@{}
$instrumentedStartupDefinitions=@{}
foreach($name in @('Start-ReviewOwnedPipelineCreation')){
 $definition=(Get-Command $name).ScriptBlock
 $originalStartupDefinitions[$name]=$definition
 $body=$definition.ToString();$tokens=$null;$errors=$null
 $bodyAst=[Management.Automation.Language.Parser]::ParseInput($body,$definition.File,[ref]$tokens,[ref]$errors)
 $typeNodes=@($bodyAst.FindAll({param($n)$n -is [Management.Automation.Language.TypeExpressionAst] -and $n.Extent.Text -ceq '[Management.Automation.PowerShell]'},$true))
 if($errors.Count -ne 0 -or $typeNodes.Count -ne 1){throw 'Startup fixture refuses changed constructor AST shape'}
 $node=$typeNodes[0];$before=$body.Substring(0,$node.Extent.StartOffset);$after=$body.Substring($node.Extent.EndOffset)
 $instrumented=$before+'[StartupDeadlineFixture]'+$after
 if(-not [string]::Equals($before+$node.Extent.Text+$after,$body,[StringComparison]::Ordinal) -or
    -not [string]::Equals($instrumented.Replace('[StartupDeadlineFixture]','[Management.Automation.PowerShell]'),$body,[StringComparison]::Ordinal)){
  throw 'Startup fixture changed text outside the exact constructor type token'
 }
 $instrumentedAst=[Management.Automation.Language.Parser]::ParseInput($instrumented,$definition.File,[ref]$tokens,[ref]$errors)
 if($errors.Count -ne 0){throw 'Startup fixture constructor instrumentation did not parse'}
 $instrumentedStartupDefinitions[$name]=$instrumentedAst.GetScriptBlock()
 Set-Item -LiteralPath ('Function:'+$name) -Value $instrumentedAst.GetScriptBlock()
}
function Invoke-StartupFixtureAction {
 param($State,$Arguments)
 try{[StartupDeadlineFixture]::EnterAction();$State['Result']=New-ReviewReadOnlyRecord -Values @{Value='synthetic'}}finally{$State['CoreRetired']=$true}
}
function Close-StartupFixtureOwners {
 param($Registry)
 [StartupDeadlineFixture]::Release.Set()
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($Registry.Count -gt 0 -and $clock.ElapsedMilliseconds -lt 5000){
  foreach($entry in @(Get-ReviewOwnedWorkEntries -OwnerRegistry $Registry)){
   $owner=$entry.Owner
   if($owner.ContainsKey('State')){Complete-ReviewOwnedWork -OwnerRegistry $Registry -Token $entry.Token|Out-Null;continue}
   # Legacy RED teardown only: observe its original real Async before closing the
   # exact pipeline. This does not turn a RED result into acceptance.
   if($owner.ContainsKey('Async') -and -not $owner['Async'].IsCompleted){continue}
   if($owner.ContainsKey('Pipeline')){
    if(-not $owner.ContainsKey('DisposeTask')){$null=Start-ReviewPipelineDisposal -Owner $owner -Pipeline $owner['Pipeline']}
    if(-not $owner['DisposeTask'].IsCompletedSuccessfully){continue}
   }
   if($owner['CoreRetired']){$null=Remove-ReviewOwnedWorkEntry -OwnerRegistry $Registry -Token $entry.Token -Owner $owner}
  }
  Start-Sleep -Milliseconds 10
 }
 Assert-Eq $Registry.Count 0 'fixture original workers physically settle before the next case'
}
# Execute real generic creation/configuration/invocation/disposal before timing
# intentionally blocked stages. This does not initialize native or launch a child.
[StartupDeadlineFixture]::Reset('warmup')
$warmRegistry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$warmDefinitions=@{};foreach($name in @('Invoke-StartupFixtureAction','New-ReviewReadOnlyRecord')){$warmDefinitions[$name]=(Get-Command $name).ScriptBlock}
$warmState=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$warm=Invoke-ReviewOwnedWork -Kind startup_warmup -OwnerRegistry $warmRegistry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+5L*[Diagnostics.Stopwatch]::Frequency) -WorkerName Invoke-StartupFixtureAction -Definitions $warmDefinitions -Arguments @{} -State $warmState
Assert-True ($warm.Completed -and $warm.Retired -and -not $warm.TimedOut -and $null -eq $warm.Failure -and $warmRegistry.Count -eq 0 -and $warmState['OwnedWorkOwner']['DisposeTask'].IsCompletedSuccessfully) 'real generic warmup physically completes before timed startup barriers'
Assert-True ($null -eq ([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type) 'generic warmup never compiles or executes native helper'
if(-not $warm.Completed -or -not $warm.Retired -or $null -ne $warm.Failure){throw 'Fixture refuses timed barriers after unconfirmed generic warmup'}
$fixturePrimary0=$null
try {
try {
 foreach($kind in @('generic')){
  foreach($stage in @('create','configure','submit')){
   [StartupDeadlineFixture]::Reset($stage)
   $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
   $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+[long](0.3*[Diagnostics.Stopwatch]::Frequency)
   $watch=[Diagnostics.Stopwatch]::StartNew();$result=$null
   $fixturePrimary1=$null
try {
try {
    if($kind -ceq 'generic'){
     $defs=@{};foreach($name in @('Invoke-StartupFixtureAction','New-ReviewReadOnlyRecord')){$defs[$name]=(Get-Command $name).ScriptBlock}
     $result=Invoke-ReviewOwnedWork -Kind startup_fixture -OwnerRegistry $registry -DeadlineTimestamp $deadline -WorkerName Invoke-StartupFixtureAction -Definitions $defs -Arguments @{} -State ([Collections.Concurrent.ConcurrentDictionary[string,object]]::new())
    }
    $watch.Stop()
    Assert-True ([StartupDeadlineFixture]::Entered.IsSet) "$kind/$stage actual startup stage reached its barrier"
    Assert-True ($watch.ElapsedMilliseconds -lt 1650) "$kind/$stage observer returns while original startup remains blocked"
    if($kind -ceq 'generic'){Assert-True ($result.TimedOut -and -not $result.Retired -and -not $result.Completed -and $null -eq $result.Result) "$kind/$stage never accepts an unknown startup"}
    Assert-Eq $registry.Count 1 "$kind/$stage retains exactly the original startup owner"
    Assert-Eq ([StartupDeadlineFixture]::ActionCalls) 0 "$kind/$stage cannot start action after its deadline"
   }
catch{throw}
}catch{$fixturePrimary1=$_;throw}finally{
$fixtureCleanup1=[Collections.Generic.List[Exception]]::new()
try{
Close-StartupFixtureOwners -Registry $registry
}catch{$fixtureCleanup1.Add($_.Exception)}
if($fixtureCleanup1.Count -gt 0){
 if($null -ne $fixturePrimary1){
  $previous=@();if($fixturePrimary1.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary1.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary1.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup1.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup1.ToArray())}
}
}
   Assert-Eq ([StartupDeadlineFixture]::ActionCalls) 0 "$kind/$stage late configuration/submission cannot run the expired action"
  }
 }
}
catch{throw}
}catch{$fixturePrimary0=$_;throw}finally{
$fixtureCleanup0=[Collections.Generic.List[Exception]]::new()
try{
[StartupDeadlineFixture]::Release.Set()
}catch{$fixtureCleanup0.Add($_.Exception)}
try{
foreach($name in $originalStartupDefinitions.Keys){Set-Item -LiteralPath ('Function:'+$name) -Value $originalStartupDefinitions[$name]}
}catch{$fixtureCleanup0.Add($_.Exception)}
if($fixtureCleanup0.Count -gt 0){
 if($null -ne $fixturePrimary0){
  $previous=@();if($fixturePrimary0.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary0.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary0.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup0.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup0.ToArray())}
}
}

# Direct runner's cold initialization is gated before any native type or OS child.
. $library
# Separate bounded PowerShell bootstrap setup; native initialization stays cold.
$setupDeadline=[Diagnostics.Stopwatch]::GetTimestamp()+5L*[Diagnostics.Stopwatch]::Frequency
$nativeAbsentBefore=$null -eq ([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type
Assert-True $nativeAbsentBefore 'complete dormant-definition setup starts with native type absent'
if(-not $nativeAbsentBefore){throw 'Fixture refuses already initialized native type'}
[StartupDeadlineFixture]::Reset('full_definition_setup')
$setupLibrary=(Get-Command Invoke-BoundedProcess).ScriptBlock
$setupDefinitions=Get-ReviewWorkerDefinitions -LibraryDefinition $setupLibrary
$setupAst=$setupLibrary.Ast;while($setupAst.Parent){$setupAst=$setupAst.Parent}
$setupFunctions=@($setupAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false))
$setupComplete=$setupDefinitions.Count -eq $setupFunctions.Count
foreach($node in $setupFunctions){$setupComplete=$setupComplete -and $setupDefinitions.ContainsKey($node.Name) -and [object]::ReferenceEquals($setupDefinitions[$node.Name],(Get-Command $node.Name -CommandType Function).ScriptBlock)}
Assert-True $setupComplete 'setup captures the same complete actual dormant definition pack'
$setupDefinitions['Invoke-StartupFixtureAction']=(Get-Command Invoke-StartupFixtureAction).ScriptBlock
$setupState=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal)
$setupRegistry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$fixturePrimary2=$null
try {
try{
 $setup=Invoke-ReviewOwnedWork -Kind startup_full_bootstrap -OwnerRegistry $setupRegistry -DeadlineTimestamp $setupDeadline -WorkerName Invoke-StartupFixtureAction -Definitions $setupDefinitions -Arguments @{} -State $setupState
 $setupOwner=$setupState['OwnedWorkOwner']
 $setupAccepted=$setup.Completed -and $setup.Retired -and -not $setup.TimedOut -and $null -eq $setup.Failure -and $setup.CleanupFailures.Count -eq 0
 Assert-True $setupAccepted 'complete dormant-definition setup completes and retires without failure on its original five-second clock'
 $setupOriginal=$null -ne $setupOwner -and [object]::ReferenceEquals($setupOwner['State'],$setupState) -and [object]::ReferenceEquals($setupOwner['Registry'],$setupRegistry) -and $setupOwner['Deadline'] -eq $setupDeadline -and $null -ne $setupOwner['CreationTask'] -and $setupOwner['CreationTask'].IsCompletedSuccessfully -and $null -ne $setupOwner['InvokeTask'] -and $setupOwner['InvokeTask'].IsCompletedSuccessfully -and $null -ne $setupOwner['DisposeTask'] -and $setupOwner['DisposeTask'].IsCompletedSuccessfully -and $setupOwner['RetirementConfirmed']
 Assert-True $setupOriginal 'setup original creation invocation and disposal physically settle'
 Assert-True ([StartupDeadlineFixture]::ActionCalls -eq 1 -and $null -ne $setup.Result -and $setup.Result.Value -ceq 'synthetic' -and $setupState['CoreRetired']) 'setup invokes only the pure fixture action once'
 $setupEmpty=$setupRegistry.Count -eq 0 -and (Get-ReviewOwnerRegistry ReviewProcessOwners).Count -eq 0
 Assert-True $setupEmpty 'setup leaves no original owner or pre-created cold native target owner'
 $nativeAbsentAfter=$null -eq ([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type
 Assert-True $nativeAbsentAfter 'complete dormant-definition setup never loads the native type'
 if(-not $setupAccepted -or -not $setupOriginal -or -not $setupEmpty -or -not $nativeAbsentAfter -or -not $setupComplete){throw 'Fixture refuses cold stage after unconfirmed bootstrap setup'}
}
catch{throw}
}catch{$fixturePrimary2=$_;throw}finally{
$fixtureCleanup2=[Collections.Generic.List[Exception]]::new()
try{
if($setupRegistry.Count -gt 0){Close-StartupFixtureOwners -Registry $setupRegistry}
}catch{$fixtureCleanup2.Add($_.Exception)}
if($fixtureCleanup2.Count -gt 0){
 if($null -ne $fixturePrimary2){
  $previous=@();if($fixturePrimary2.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary2.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary2.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup2.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup2.ToArray())}
}
}

$savedInitializer=(Get-Command Initialize-LiveGateNative).ScriptBlock
function Initialize-LiveGateNative {[StartupDeadlineFixture]::ColdInitialize()}
[StartupDeadlineFixture]::Reset('no_pause')
$warmCold=Invoke-BoundedProcess -FileName 'synthetic-never-executed.exe' -TimeoutSec 5 -RequireProcessTreeRetirement
Assert-True ($warmCold.StartFailed -and -not $warmCold.TimedOut -and $warmCold.ProcessTreeRetired -and $null -eq $warmCold.NativeProcessResult -and $warmCold.Failure.Code -ceq 'native_startup' -and $warmCold.Failure.Stage -ceq 'native_initialization' -and (Get-ReviewOwnerRegistry ReviewProcessOwners).Count -eq 0) 'same actual public facade pre-native setup physically settles before timed cold barrier'
Assert-True ($null -eq ([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type) 'same facade setup leaves original native type entirely cold'
if($warmCold.TimedOut -or -not $warmCold.ProcessTreeRetired -or $null -ne $warmCold.NativeProcessResult){throw 'Fixture refuses cold barrier after unknown setup'}
[StartupDeadlineFixture]::Reset('native_initialize')
$watch=[Diagnostics.Stopwatch]::StartNew()
$cold=Invoke-BoundedProcess -FileName 'synthetic-never-executed.exe' -TimeoutMilliseconds 700 -RequireProcessTreeRetirement
$watch.Stop()
[pscustomobject]@{case='cold_initialize';elapsed_ms=$watch.ElapsedMilliseconds;ExitCode=$cold.ExitCode;TimedOut=$cold.TimedOut;StartFailed=$cold.StartFailed;ProcessTreeRetired=$cold.ProcessTreeRetired;error_class=$(if([string]::Equals($cold.ErrorMessage,'Synthetic cold initialization stopped before native launch',[StringComparison]::Ordinal)){'fixture_cold_initializer'}elseif($cold.ErrorMessage){'other_bounded_error'}else{'none'})}|ConvertTo-Json -Compress|Write-Output
Assert-True ([StartupDeadlineFixture]::Entered.IsSet) 'actual public direct runner reached cold initialization barrier'
Assert-True ($watch.ElapsedMilliseconds -lt 1650) 'cold native initialization is observed within original entry deadline'
Assert-True ($cold.TimedOut -and -not $cold.ProcessTreeRetired) 'cold initialization timeout cannot fabricate native retirement'
$processRegistry=$null
try{$processRegistry=Get-ReviewOwnerRegistry ReviewProcessOwners}catch{}
Assert-True ($null -ne $processRegistry -and $processRegistry.Count -eq 1) 'cold initialization retains exact original direct-process owner'
[StartupDeadlineFixture]::Release.Set()
if($null -ne $processRegistry){Close-StartupFixtureOwners -Registry $processRegistry}
Set-Item Function:Initialize-LiveGateNative $savedInitializer

# Isolate OS-creation startup from compilation: compile the ACTUAL native helper
# with one sealed gate that always throws immediately before CreateProcessW.
# Cold compilation was independently covered above; no process can be launched.
$nativeOriginal=$savedInitializer.ToString()
$nativeClassMarker='public static class Native {'
$nativeCreateMarker='Require(CreateProcessW(start.FileName, command, IntPtr.Zero, IntPtr.Zero, true,'
if([regex]::Matches($nativeOriginal,[regex]::Escape($nativeClassMarker)).Count -ne 1 -or
   [regex]::Matches($nativeOriginal,[regex]::Escape($nativeCreateMarker)).Count -ne 1 -or
   [regex]::Matches($nativeOriginal,'static extern bool CreateProcessW\(string app, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity,\s+bool inherit, uint flags, IntPtr environment, string cwd, ref StartupInfoEx startup, out ProcessInfo process\);').Count -ne 1){
 throw 'Refuse unsafe native fixture: original creation site or method signature differs'
}
$nativeFixture=$nativeOriginal.Replace($nativeClassMarker,@'
public static class Native {
 public static readonly ManualResetEventSlim FixtureEntered=new(false),FixtureRelease=new(false);
 public static void FixtureBeforeCreate(){FixtureEntered.Set();FixtureRelease.Wait(2500);throw new Win32Exception(2);}
'@).Replace($nativeCreateMarker,'FixtureBeforeCreate(); '+$nativeCreateMarker)
if([regex]::Matches($nativeFixture,[regex]::Escape('FixtureBeforeCreate(); '+$nativeCreateMarker)).Count -ne 1 -or
   [regex]::Matches($nativeFixture,'public static void FixtureBeforeCreate\(\)\{FixtureEntered.Set\(\);FixtureRelease.Wait\(2500\);throw new Win32Exception\(2\);\}').Count -ne 1){
 throw 'Refuse unsafe native fixture: sealed pre-creation throw was not installed exactly once'
}
Assert-True ($nativeFixture.Contains('FixtureBeforeCreate(); Require(CreateProcessW(')) 'process-creation fixture gates the actual native creation site'
Set-Item Function:Initialize-LiveGateNative ([scriptblock]::Create($nativeFixture))
Initialize-LiveGateNative
[GauntletLive.Native]::FixtureRelease.Set()
$warmNative=Invoke-BoundedProcess -FileName 'synthetic-never-executed.exe' -TimeoutSec 5 -RequireProcessTreeRetirement
Assert-True ([GauntletLive.Native]::FixtureEntered.IsSet -and $warmNative.StartFailed -and -not $warmNative.TimedOut -and $warmNative.ProcessTreeRetired -and $null -ne $warmNative.NativeProcessResult -and $warmNative.Failure.Code -ceq 'native_failure' -and $warmNative.Failure.Stage -ceq 'process_creation' -and $warmNative.Failure.NativeError -eq 2 -and (Get-ReviewOwnerRegistry ReviewProcessOwners).Count -eq 0) 'same sealed actual pre-CreateProcess path physically settles before timed creation barrier'
if(-not $warmNative.ProcessTreeRetired -or $null -eq $warmNative.NativeProcessResult){throw 'Fixture refuses creation barrier after unknown sealed setup'}
[GauntletLive.Native]::FixtureRelease.Reset();[GauntletLive.Native]::FixtureEntered.Reset()
$watch.Restart()
$start=Invoke-BoundedProcess -FileName 'synthetic-never-executed.exe' -TimeoutMilliseconds 700 -RequireProcessTreeRetirement
$watch.Stop()
[pscustomobject]@{case='process_creation';elapsed_ms=$watch.ElapsedMilliseconds;ExitCode=$start.ExitCode;TimedOut=$start.TimedOut;StartFailed=$start.StartFailed;ProcessTreeRetired=$start.ProcessTreeRetired;error_class=$(if($start.ErrorMessage -and $start.ErrorMessage.Contains('Loaded live-gate native helper differs')){'native_source_identity_mismatch'}elseif($start.ErrorMessage){'other_bounded_error'}else{'none'})}|ConvertTo-Json -Compress|Write-Output
Assert-True ([GauntletLive.Native]::FixtureEntered.IsSet) 'actual native process_creation stage reached its sealed barrier'
Assert-True ($watch.ElapsedMilliseconds -lt 1650) 'actual native process creation is observed within original deadline'
Assert-True ($start.TimedOut -and -not $start.ProcessTreeRetired) 'unknown native startup cannot publish successful physical proof'
$processRegistry=$null
try{$processRegistry=Get-ReviewOwnerRegistry ReviewProcessOwners}catch{}
Assert-True ($null -ne $processRegistry -and $processRegistry.Count -eq 1) 'process creation retains original native owning worker'
[GauntletLive.Native]::FixtureRelease.Set()
if($null -ne $processRegistry){Close-StartupFixtureOwners -Registry $processRegistry}

# The native helper's sealed pre-create throw above proves no OS child exists.
# Retain its actual scalar receipt independently while the ORIGINAL real pipeline
# disposal is blocked; worker retirement must not be inferred from native retirement.
Set-Item Function:Start-ReviewOwnedPipelineCreation $instrumentedStartupDefinitions['Start-ReviewOwnedPipelineCreation']
[StartupDeadlineFixture]::Reset('dispose')
$watch.Restart()
$fixturePrimary3=$null
try {
try {
 $disposing=Invoke-BoundedProcess -FileName 'synthetic-never-executed.exe' -TimeoutMilliseconds 700 -RequireProcessTreeRetirement
 $watch.Stop()
 Assert-True ([StartupDeadlineFixture]::Entered.IsSet) 'actual direct process original pipeline reaches blocked disposal'
 Assert-True ($watch.ElapsedMilliseconds -lt 1650) 'direct process disposal shares its original entry deadline'
 Assert-True ($disposing.TimedOut -and -not $disposing.ProcessTreeRetired) 'native retirement cannot grant aggregate retirement while original disposal is blocked'
 $native=$null;$nativePresent=$false
 if($disposing -is [Collections.IDictionary]){$nativePresent=$disposing.ContainsKey('NativeProcessResult');if($nativePresent){$native=$disposing['NativeProcessResult']}}
 else{$nativeProperty=$disposing.PSObject.Properties['NativeProcessResult'];$nativePresent=$null -ne $nativeProperty;if($nativePresent){$native=$nativeProperty.Value}}
 Assert-True ($nativePresent -and $null -ne $native) 'direct aggregate retains the actual native scalar receipt separately'
 if($null -ne $native){
  $names=if($native -is [Collections.IDictionary]){@($native.Keys)}else{@(Get-PropertyNames -InputObject $native)}
  Assert-True ($names.Count -eq 6 -and @($names|Where-Object {$_ -cnotin @('ExitCode','StartFailed','TimedOut','ErrorMessage','StderrText','ProcessTreeRetired')}).Count -eq 0) 'actual native receipt contains exactly the six confirmed scalar fields'
  Assert-True (($null -eq $native.ExitCode -or $native.ExitCode -is [int]) -and ($null -eq $native.ErrorMessage -or $native.ErrorMessage -is [string]) -and $native.StderrText -is [string] -and $native.StartFailed -is [bool] -and $native.TimedOut -is [bool] -and $native.ProcessTreeRetired -is [bool]) 'actual native receipt preserves nullable exit/error and exact scalar types'
  Assert-True ($native.StartFailed -and -not $native.TimedOut -and $native.ProcessTreeRetired) 'actual no-child native failure remains distinct from observer timeout'
 }else{
  [pscustomobject]@{case='direct_disposal_receipt';result_type=$disposing.GetType().FullName;native_present=$nativePresent;native_type=$null;native_start_failed=$null;native_timed_out=$null;native_tree_retired=$null}|ConvertTo-Json -Compress|Write-Output
 }
 $processRegistry=Get-ReviewOwnerRegistry ReviewProcessOwners
 Assert-Eq $processRegistry.Count 1 'direct blocked disposal retains exactly the original generic owner'
 # SAME original C# result authority, not a constructed fallback/receipt.
 $disposingOwners=@(Get-ReviewOwnedWorkEntries -OwnerRegistry $processRegistry)
 Assert-True ($disposingOwners.Count -eq 1 -and $disposingOwners[0].Owner['State']['Result'].GetType().FullName -ceq 'GauntletLive.Native+RunResult') 'blocked disposal retains the SAME actual native result authority'
 if($disposingOwners.Count -eq 1){
  $nativeCause=$disposingOwners[0].Owner['State']['Result'].Failure
  Assert-True ($nativeCause.Code -ceq 'native_failure' -and $nativeCause.Stage -ceq 'process_creation' -and $nativeCause.NativeError -eq 2) 'sealed actual CreateProcess refusal retains its real typed primary cause'
  $aggregateCause=$disposing.Failure
  Assert-True ($null -ne $aggregateCause -and $aggregateCause.Code -ceq 'native_failure' -and $aggregateCause.Stage -ceq 'process_creation' -and $aggregateCause.NativeError -eq 2) 'later owned disposal deadline cannot overwrite original native primary cause'
  $secondary=@($disposing.CleanupFailures)
  Assert-True ($secondary.Count -ge 1 -and $secondary.Count -le 2 -and @($secondary|Where-Object {$_.Code -ceq 'owned_deadline'}).Count -eq 1) 'owned deadline is a distinct bounded secondary after actual native failure'
 }
}
catch{throw}
}catch{$fixturePrimary3=$_;throw}finally{
$fixtureCleanup3=[Collections.Generic.List[Exception]]::new()
try{
[StartupDeadlineFixture]::Release.Set()
}catch{$fixtureCleanup3.Add($_.Exception)}
try{
Close-StartupFixtureOwners -Registry (Get-ReviewOwnerRegistry ReviewProcessOwners)
}catch{$fixtureCleanup3.Add($_.Exception)}
try{
Set-Item Function:Start-ReviewOwnedPipelineCreation $originalStartupDefinitions['Start-ReviewOwnedPipelineCreation']
}catch{$fixtureCleanup3.Add($_.Exception)}
if($fixtureCleanup3.Count -gt 0){
 if($null -ne $fixturePrimary3){
  $previous=@();if($fixturePrimary3.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary3.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary3.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup3.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup3.ToArray())}
}
}


# An on-time initializer fault has no C# process receipt; preserve its actual
# bounded structural cause without copying exception messages into that cause.
$savedOnTimeInitializer=(Get-Command Initialize-LiveGateNative).ScriptBlock
function Initialize-LiveGateNative {[StartupDeadlineFixture]::ColdInitialize()}
[StartupDeadlineFixture]::Reset('no_pause')
$fixturePrimary4=$null
try {
try{
 $initializationFailure=Invoke-BoundedProcess -FileName 'synthetic-never-executed.exe' -TimeoutSec 5 -RequireProcessTreeRetirement
 Assert-True ($initializationFailure.StartFailed -and -not $initializationFailure.TimedOut -and $initializationFailure.ProcessTreeRetired) 'on-time initializer failure confirms never-started original worker physically settled'
 Assert-True ($null -eq $initializationFailure.NativeProcessResult) 'pre-native initializer failure cannot invent an actual C# native receipt'
 Assert-True ($null -ne $initializationFailure.Failure) 'actual on-time initializer error retains typed structural cause'
 if($null -ne $initializationFailure.Failure){
  Assert-Eq $initializationFailure.Failure.Code 'native_startup' 'initializer failure preserves fixed native startup code'
  Assert-Eq $initializationFailure.Failure.Stage 'native_initialization' 'initializer failure identifies its actual pre-native stage'
  $cause=$initializationFailure.Failure
  Assert-True ($cause.Type -ceq 'System.InvalidOperationException' -and $cause.HResult -is [int] -and $null -eq $cause.NativeError) 'initializer failure retains actual safe base cause type and HResult in the native failure shape'
  $encoded=$initializationFailure.Failure|ConvertTo-Json -Depth 8 -Compress
  Assert-True (-not $encoded.Contains('Synthetic cold initialization stopped before native launch') -and -not $encoded.Contains('synthetic-never-executed.exe')) 'structured initializer cause excludes exception text and invocation data'
 }
 Assert-Eq (Get-ReviewOwnerRegistry ReviewProcessOwners).Count 0 'known on-time initializer failure leaves no unresolved direct owner'
}
catch{throw}
}catch{$fixturePrimary4=$_;throw}finally{
$fixtureCleanup4=[Collections.Generic.List[Exception]]::new()
try{
Set-Item Function:Initialize-LiveGateNative $savedOnTimeInitializer
}catch{$fixtureCleanup4.Add($_.Exception)}
if($fixtureCleanup4.Count -gt 0){
 if($null -ne $fixturePrimary4){
  $previous=@();if($fixturePrimary4.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary4.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary4.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup4.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup4.ToArray())}
}
}


# R4: actual public admission/generic observer/candidate; only OS-facing Core is sealed.
Add-Type -TypeDefinition @"
public static class OwnedFailureFixture {
 public static int CoreCalls; public static object LastState; public static object LastNative;
 public static void Hit(){System.Threading.Interlocked.Increment(ref CoreCalls);}
}
"@
$savedR4Core=(Get-Command Invoke-BoundedProcessCore).ScriptBlock
$savedR4Initializer=(Get-Command Initialize-LiveGateNative).ScriptBlock
function Invoke-BoundedProcessCore {
 param($FileName,$ArgList,$StdinText,$WorkingDirectory,$TimeoutSec,$TimeoutMilliseconds,$DeadlineTimestamp,$EnvironmentMap,$FailureCancellationToken,[switch]$ClearEnvironment,[switch]$RequireProcessTreeRetirement)
 [OwnedFailureFixture]::Hit()
 $script:ReviewNativeProcessState['NativeNeverStarted']=$false
 $native=[GauntletLive.Native+RunResult]::new()
 $native.ExitCode=0;$native.Stdout='synthetic native success';$native.Stderr=''
 $native.StartFailed=$false;$native.TimedOut=$false;$native.ProcessTreeRetired=$true
 [OwnedFailureFixture]::LastNative=$native
 if($ArgList -contains 'owned_error_stream'){Write-Error -Exception ([IO.IOException]::new('Synthetic owned worker error')) -ErrorAction Continue}
 return $native
}
function Get-R4Optional {
 param($Value,[string]$Name)
 if($null -eq $Value){return $null}
 if($Value -is [Collections.IDictionary]){if($Value.ContainsKey($Name)){return $Value[$Name]};return $null}
 $property=$Value.PSObject.Properties[$Name];if($null -ne $property){return $property.Value};return $null
}
$fixturePrimary5=$null
try {
try{
 [OwnedFailureFixture]::CoreCalls=0
 $failed=Invoke-BoundedProcess -FileName 'synthetic-never-executed.exe' -ArgList @('owned_error_stream') -TimeoutSec 5 -RequireProcessTreeRetirement
 Assert-Eq ([OwnedFailureFixture]::CoreCalls) 1 'actual public facade enters sealed native DTO leaf once'
 Assert-True ($null -ne $failed.Failure -and $failed.Failure.Code -ceq 'owned_error_stream' -and $failed.Failure.Stage -ceq 'worker_invoke') 'actual generic observer retains causal owned error stream'
 Assert-True ($failed.ExitCode -eq -1 -and -not [string]::IsNullOrWhiteSpace($failed.ErrorMessage)) 'owned error refuses aggregate success despite native exit zero'
 $native=Get-R4Optional $failed NativeProcessResult
 $nativeNames=if($native -is [Collections.IDictionary]){@($native.Keys)}elseif($null -ne $native){@($native.PSObject.Properties.Name)}else{@()}
 [ordered]@{case='owned_error_receipt_shape';aggregate_exit=$failed.ExitCode;aggregate_exit_type=$(if($null -ne $failed.ExitCode){$failed.ExitCode.GetType().FullName}else{$null});aggregate_start_failed=$failed.StartFailed;aggregate_timed_out=$failed.TimedOut;aggregate_retired=$failed.ProcessTreeRetired;aggregate_error_null=$null -eq $failed.ErrorMessage;native_type=$(if($null -ne $native){$native.GetType().FullName}else{$null});native_keys=$nativeNames;native_exit=$(Get-R4Optional $native ExitCode);native_start_failed=$(Get-R4Optional $native StartFailed);native_timed_out=$(Get-R4Optional $native TimedOut);native_retired=$(Get-R4Optional $native ProcessTreeRetired);native_error_null=$null -eq (Get-R4Optional $native ErrorMessage);native_stderr_empty=[string]::Equals((Get-R4Optional $native StderrText),'',[StringComparison]::Ordinal)}|ConvertTo-Json -Depth 4 -Compress|Write-Output
 Assert-True ($null -ne $native) 'owned failure preserves actual native scalar receipt separately'
 if($null -ne $native){Assert-True ($native.Keys.Count -eq 6 -and $native.ExitCode -eq 0 -and -not $native.StartFailed -and -not $native.TimedOut -and [string]::Equals($native.ErrorMessage,([OwnedFailureFixture]::LastNative.ErrorMessage),[StringComparison]::Ordinal) -and $native.StderrText -ceq '' -and $native.ProcessTreeRetired) 'all six separate native scalars remain truthful after aggregate refusal'}
 Assert-True $failed.ProcessTreeRetired 'causal refusal retains actual original physical retirement'
 Assert-Eq (Get-ReviewOwnerRegistry ReviewProcessOwners).Count 0 'completed error-stream worker and disposal settle'
}
catch{throw}
}catch{$fixturePrimary5=$_;throw}finally{
$fixtureCleanup5=[Collections.Generic.List[Exception]]::new()
try{
Set-Item Function:Invoke-BoundedProcessCore $savedR4Core
}catch{$fixtureCleanup5.Add($_.Exception)}
if($fixtureCleanup5.Count -gt 0){
 if($null -ne $fixturePrimary5){
  $previous=@();if($fixturePrimary5.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary5.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary5.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup5.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup5.ToArray())}
}
}
Write-TestResult
