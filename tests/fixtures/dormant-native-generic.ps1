# Fixture cleanup preservation v1: primary and independent cleanup errors.
# Retained bounded PowerShell worker, synthetic state and barriers only.
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
$library=Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1'
. $library
$ErrorActionPreference='Stop'
$available=Get-Command Invoke-ReviewOwnedWork -ErrorAction SilentlyContinue
Assert-True ($null -ne $available) 'bounded retained owned-work observer exists'
if(-not $available){Write-TestResult}
function Invoke-OwnedFixtureWorker {
    param($State,$Arguments)
    try{
        $State['Stage']='fixture_preflight';$Arguments.Entered.Set()
        if($Arguments.Block){$null=$Arguments.Release.Wait(5000)}
        if((Get-ReviewRemainingMilliseconds $State['Deadline']) -le 0){Throw-ReviewCodedFailure -Code 'fixture_deadline' -Stage 'fixture_preflight'}
        $Arguments.Observed['Calls']=1
        $State['Result']=New-ReviewReadOnlyRecord -Values @{Value='fixture';DefinitionFile=(Get-Command Invoke-OwnedFixtureWorker).ScriptBlock.File}
    }finally{$State['CoreRetired']=$true}
}
$defs=@{};foreach($n in @('Invoke-OwnedFixtureWorker','Get-ReviewRemainingMilliseconds','New-ReviewReadOnlyRecord','Throw-ReviewCodedFailure')){$defs[$n]=(Get-Command $n).ScriptBlock}
$registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
function New-FixtureArguments([bool]$Block){@{Block=$Block;Entered=[Threading.ManualResetEventSlim]::new($false);Release=[Threading.ManualResetEventSlim]::new($false);Observed=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()}}
$args1=New-FixtureArguments $false
$state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$deadline=[Diagnostics.Stopwatch]::GetTimestamp()+[long](10*[Diagnostics.Stopwatch]::Frequency)
$result=Invoke-ReviewOwnedWork -Kind fixture -OwnerRegistry $registry -DeadlineTimestamp $deadline -WorkerName Invoke-OwnedFixtureWorker -Definitions $defs -Arguments $args1 -State $state
Assert-True ($result.Completed -and $result.Retired -and -not $result.TimedOut) 'actual owned worker completes and physically disposes within original clock'
Assert-Eq $result.Result.Value 'fixture' 'worker publishes its explicit immutable DTO'
Assert-True $result.IsReadOnly 'owned observer result is immutable'
Assert-True ($result.Result.DefinitionFile.EndsWith('dormant-native-generic.ps1')) 'worker function keeps original AST/File definition provenance'
Assert-Eq $registry.Count 0 'known retired worker removed only after actual disposal'
$args2=New-FixtureArguments $true;$state2=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$deadline=[Diagnostics.Stopwatch]::GetTimestamp()+[long](0.3*[Diagnostics.Stopwatch]::Frequency)
$clock=[Diagnostics.Stopwatch]::StartNew()
$late=Invoke-ReviewOwnedWork -Kind fixture -OwnerRegistry $registry -DeadlineTimestamp $deadline -WorkerName Invoke-OwnedFixtureWorker -Definitions $defs -Arguments $args2 -State $state2
$clock.Stop()
Assert-True ($clock.ElapsedMilliseconds -lt 1500 -and $late.TimedOut -and -not $late.Completed -and -not $late.Retired) 'blocked preflight returns bounded with unresolved actual worker'
Assert-Eq $registry.Count 1 'blocked preflight retains owning operation'
Assert-True (-not $args2.Observed.ContainsKey('Calls')) 'blocked preflight has no submitted child surrogate'
$refused=Invoke-ReviewOwnedWork -Kind fixture -OwnerRegistry $registry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+[long][Diagnostics.Stopwatch]::Frequency) -WorkerName Invoke-OwnedFixtureWorker -Definitions $defs -Arguments $args1 -State ([Collections.Concurrent.ConcurrentDictionary[string,object]]::new())
Assert-Eq $refused.Failure.Code 'prior_owner_unresolved' 'prior unknown operation fences next admission'
$args2.Release.Set()
$wait=[Diagnostics.Stopwatch]::StartNew()
while($registry.Count -gt 0 -and $wait.ElapsedMilliseconds -lt 4000){Complete-ReviewOwnedWork -OwnerRegistry $registry|Out-Null;[Threading.Thread]::Sleep(10)}
Assert-Eq $registry.Count 0 'explicit observation retires completed abandoned worker and its actual pipeline'
Assert-True (-not $args2.Observed.ContainsKey('Calls')) 'late preflight cannot mutate after original deadline'
Assert-True (-not $late.Completed -and $null -eq $late.Result) 'immutable timeout cannot become late acceptance'
Add-Type -TypeDefinition @'
using System;
using System.Threading;
public static class OwnedWorkBarrier {
    public static ManualResetEventSlim Entered=new ManualResetEventSlim(false),Release=new ManualResetEventSlim(false);
    public static IDisposable Pipeline;
    public static Func<object> Factory;
    public static object Registry;
    public static void HoldRegistry() {lock(Registry){Entered.Set();Release.Wait(TimeSpan.FromSeconds(5));}}
    public static object Create() {Entered.Set();Release.Wait(TimeSpan.FromSeconds(5));return Factory();}
    public static void Dispose() {Entered.Set();Release.Wait(TimeSpan.FromSeconds(5));Pipeline.Dispose();}
}
'@
$realDisposal=(Get-Command Start-ReviewPipelineDisposal).ScriptBlock
function Start-ReviewPipelineDisposal {
    param($Owner,$Pipeline)
    [OwnedWorkBarrier]::Pipeline=$Pipeline
    $method=[OwnedWorkBarrier].GetMethod('Dispose')
    $dispose=[Delegate]::CreateDelegate([Action],$method)
    $task=[Threading.Tasks.Task]::Run([Action]$dispose);$Owner['DisposeTask']=$task;return ,$task
}
$args3=New-FixtureArguments $false;$state3=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$clock.Restart()
$blocked=Invoke-ReviewOwnedWork -Kind fixture -OwnerRegistry $registry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+[long](0.3*[Diagnostics.Stopwatch]::Frequency)) -WorkerName Invoke-OwnedFixtureWorker -Definitions $defs -Arguments $args3 -State $state3
$clock.Stop()
Assert-True ([OwnedWorkBarrier]::Entered.IsSet -and $clock.ElapsedMilliseconds -lt 1500 -and $blocked.TimedOut -and -not $blocked.Retired) 'actual pipeline disposal blocked on worker never blocks observer past original budget'
Assert-Eq $registry.Count 1 'blocked actual disposer remains retained'
[OwnedWorkBarrier]::Release.Set()
$wait.Restart();while($registry.Count -gt 0 -and $wait.ElapsedMilliseconds -lt 4000){Complete-ReviewOwnedWork -OwnerRegistry $registry|Out-Null;[Threading.Thread]::Sleep(10)}
Assert-Eq $registry.Count 0 'explicit physical completion observes actual original disposer'
Set-Item function:Start-ReviewPipelineDisposal -Value $realDisposal
$realCreation=(Get-Command Start-ReviewOwnedPipelineCreation).ScriptBlock
[OwnedWorkBarrier]::Entered.Reset();[OwnedWorkBarrier]::Release.Reset()
[OwnedWorkBarrier]::Factory=[Delegate]::CreateDelegate([Func[object]],[Management.Automation.PowerShell].GetMethod('Create',[type[]]@()))
function Start-ReviewOwnedPipelineCreation {
    $factory=[Delegate]::CreateDelegate([Func[object]],[OwnedWorkBarrier].GetMethod('Create'))
    [Threading.Tasks.Task[object]]::Factory.StartNew([Func[object]]$factory)
}
$args4=New-FixtureArguments $false;$state4=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$clock.Restart()
$creating=Invoke-ReviewOwnedWork -Kind fixture -OwnerRegistry $registry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+[long](0.3*[Diagnostics.Stopwatch]::Frequency)) -WorkerName Invoke-OwnedFixtureWorker -Definitions $defs -Arguments $args4 -State $state4
$clock.Stop()
Assert-True ([OwnedWorkBarrier]::Entered.IsSet -and $clock.ElapsedMilliseconds -lt 1500 -and $creating.TimedOut -and -not $creating.Retired) 'actual pipeline factory blocked on worker stays inside observer budget'
Assert-True ($registry.Count -eq 1 -and -not $args4.Observed.ContainsKey('Calls')) 'pending creation retains owner and has no launched action'
[OwnedWorkBarrier]::Release.Set()
$wait.Restart();while($registry.Count -gt 0 -and $wait.ElapsedMilliseconds -lt 4000){Complete-ReviewOwnedWork -OwnerRegistry $registry|Out-Null;[Threading.Thread]::Sleep(10)}
Assert-True ($registry.Count -eq 0 -and -not $args4.Observed.ContainsKey('Calls')) 'late created unused pipeline is physically disposed without executing action'
Set-Item function:Start-ReviewOwnedPipelineCreation -Value $realCreation
[OwnedWorkBarrier]::Entered.Reset();[OwnedWorkBarrier]::Release.Reset();[OwnedWorkBarrier]::Registry=$registry
$hold=[Delegate]::CreateDelegate([Action],[OwnedWorkBarrier].GetMethod('HoldRegistry'))
$holder=[Threading.Tasks.Task]::Run([Action]$hold)
$null=[OwnedWorkBarrier]::Entered.Wait(1000)
$busy=Invoke-ReviewOwnedWork -Kind fixture -OwnerRegistry $registry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+[long][Diagnostics.Stopwatch]::Frequency) -WorkerName Invoke-OwnedFixtureWorker -Definitions $defs -Arguments (New-FixtureArguments $false) -State ([Collections.Concurrent.ConcurrentDictionary[string,object]]::new())
Assert-True ($null -ne $busy.Failure -and $busy.Failure.Code -ceq 'registry_busy' -and $registry.Count -eq 0) 'actual locked shared registry refuses admission nonblocking without creating owner'
[OwnedWorkBarrier]::Release.Set();$null=$holder.Wait(1000)
$callerDefinitions=@{}
foreach($name in @('Invoke-ReviewOwnedWork','Complete-ReviewOwnedWork','Get-ReviewOwnedWorkEntries','Remove-ReviewOwnedWorkEntry','Start-ReviewOwnedPipelineCreation','Start-ReviewOwnedPipelineInvocation','Start-ReviewPipelineDisposal','Get-ReviewRemainingMilliseconds','New-ReviewReadOnlyRecord','Get-ReviewSafeCause','New-ReviewTransportFault','Throw-ReviewCodedFailure','Get-ReviewOwnedWorkFailures','Invoke-OwnedFixtureWorker')){$callerDefinitions[$name]=(Get-Command $name).ScriptBlock}
$start=[Threading.Barrier]::new(2);$simultaneous=New-FixtureArguments $true;$callers=@()
$callerBootstrap=@'
param($definitions,$registry,$start,$arguments)
$ErrorActionPreference='Stop'
foreach($name in $definitions.Keys){Set-Item ('function:'+$name) -Value ([scriptblock]::Create($definitions[$name].ToString()))}
$null=$start.SignalAndWait(3000)
Invoke-ReviewOwnedWork -Kind concurrent -OwnerRegistry $registry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+[long](3*[Diagnostics.Stopwatch]::Frequency)) -WorkerName Invoke-OwnedFixtureWorker -Definitions $definitions -Arguments $arguments -State ([Collections.Concurrent.ConcurrentDictionary[string,object]]::new())
'@
$fixturePrimary0=$null
try {
try{
    foreach($index in 1..2){$pipeline=[Management.Automation.PowerShell]::Create();$null=$pipeline.AddScript($callerBootstrap).AddArgument($callerDefinitions).AddArgument($registry).AddArgument($start).AddArgument($simultaneous);$callers+=@{Pipeline=$pipeline;Async=$pipeline.BeginInvoke()}}
    $outcomes=@(foreach($caller in $callers){Assert-True ($caller.Async.AsyncWaitHandle.WaitOne(5000)) 'simultaneous caller returns inside fixture bound';$caller.Pipeline.EndInvoke($caller.Async)})
    Assert-Eq @($outcomes|Where-Object {$_.TimedOut}).Count 1 'two actual runspaces admit exactly one blocked action'
    Assert-Eq @($outcomes|Where-Object {$null -ne $_.Failure -and $_.Failure.Code -cin @('prior_owner_unresolved','registry_busy')}).Count 1 'other simultaneous runspace is refused by atomic registry admission'
    Assert-Eq $registry.Count 1 'one actual pending action retains exactly one shared registry owner'
}
catch{throw}
}catch{$fixturePrimary0=$_;throw}finally{
$fixtureCleanup0=[Collections.Generic.List[Exception]]::new()
try{
$simultaneous.Release.Set()
}catch{$fixtureCleanup0.Add($_.Exception)}
try{
$wait.Restart()
}catch{$fixtureCleanup0.Add($_.Exception)}
try{
while($registry.Count -gt 0 -and $wait.ElapsedMilliseconds -lt 4000){Complete-ReviewOwnedWork -OwnerRegistry $registry|Out-Null;[Threading.Thread]::Sleep(10)}
}catch{$fixtureCleanup0.Add($_.Exception)}
try{
foreach($caller in $callers){$caller.Pipeline.Dispose()}
}catch{$fixtureCleanup0.Add($_.Exception)}
try{
$start.Dispose()
}catch{$fixtureCleanup0.Add($_.Exception)}
if($fixtureCleanup0.Count -gt 0){
 if($null -ne $fixturePrimary0){
  $previous=@();if($fixturePrimary0.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary0.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary0.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup0.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup0.ToArray())}
}
}
Assert-Eq $registry.Count 0 'simultaneous admission owner retires only after actual worker cleanup'
[OwnedWorkBarrier]::Entered.Reset();[OwnedWorkBarrier]::Release.Reset()
$normalInvocation=$callerDefinitions['Start-ReviewOwnedPipelineInvocation']
$callerDefinitions['Start-ReviewOwnedPipelineInvocation']=[scriptblock]::Create(@'
param($Pipeline)
[OwnedWorkBarrier]::Entered.Set();$null=[OwnedWorkBarrier]::Release.Wait(5000)
$method=@($Pipeline.GetType().GetMethods()|Where-Object {$_.Name -ceq 'Invoke' -and -not $_.IsGenericMethod -and $_.GetParameters().Count -eq 0})[0]
$invoke=[Delegate]::CreateDelegate([Func[object]],$Pipeline,$method)
[Threading.Tasks.Task[object]]::Factory.StartNew([Func[object]]$invoke)
'@)
$pausedArguments=New-FixtureArguments $false
$pausedCaller=[Management.Automation.PowerShell]::Create()
$null=$pausedCaller.AddScript(@'
param($definitions,$registry,$arguments)
$ErrorActionPreference='Stop'
foreach($name in $definitions.Keys){Set-Item ('function:'+$name) -Value ([scriptblock]::Create($definitions[$name].ToString()))}
Invoke-ReviewOwnedWork -Kind startup -OwnerRegistry $registry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+[long](10*[Diagnostics.Stopwatch]::Frequency)) -WorkerName Invoke-OwnedFixtureWorker -Definitions $definitions -Arguments $arguments -State ([Collections.Concurrent.ConcurrentDictionary[string,object]]::new())
'@).AddArgument($callerDefinitions).AddArgument($registry).AddArgument($pausedArguments)
$pausedAsync=$pausedCaller.BeginInvoke()
$fixturePrimary1=$null
try {
try{
    Assert-True ([OwnedWorkBarrier]::Entered.Wait(3000)) 'actual caller pauses after creation before invocation publication'
    $during=Complete-ReviewOwnedWork -OwnerRegistry $registry
    Assert-True ($registry.Count -eq 1 -and $null -ne $during -and -not $during.Retired -and -not $during.Completed) 'concurrent completion cannot dispose or remove pipeline while startup is unsettled'
    [OwnedWorkBarrier]::Release.Set()
    Assert-True ($pausedAsync.AsyncWaitHandle.WaitOne(5000)) 'startup caller completes after explicit release'
    $after=$pausedCaller.EndInvoke($pausedAsync)
    Assert-True ($after.Completed -and $after.Retired -and $null -ne $after.Result -and $pausedArguments.Observed['Calls'] -eq 1) 'only settled publication admits action and eventual actual retirement'
}
catch{throw}
}catch{$fixturePrimary1=$_;throw}finally{
$fixtureCleanup1=[Collections.Generic.List[Exception]]::new()
try{
[OwnedWorkBarrier]::Release.Set()
}catch{$fixtureCleanup1.Add($_.Exception)}
try{
$pausedCaller.Dispose()
}catch{$fixtureCleanup1.Add($_.Exception)}
try{
$callerDefinitions['Start-ReviewOwnedPipelineInvocation']=$normalInvocation
}catch{$fixtureCleanup1.Add($_.Exception)}
if($fixtureCleanup1.Count -gt 0){
 if($null -ne $fixturePrimary1){
  $previous=@();if($fixturePrimary1.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary1.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary1.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup1.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup1.ToArray())}
}
}
function Test-OwnedExpiredPublication {
    $expiryRegistry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $expiryState=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $creation=Start-ReviewOwnedPipelineCreation;$null=$creation.Wait(1000);$pipeline=$creation.Result
    $null=$pipeline.AddScript('param($state) try{$state["ActionEntered"]=$true;$state["Result"]="actual-late-result"}finally{$state["CoreRetired"]=$true}').AddArgument($expiryState)
    $invocation=Start-ReviewOwnedPipelineInvocation -Pipeline $pipeline;$null=$invocation.Wait(1000)
    $expiredOwner=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    foreach($pair in @{State=$expiryState;Deadline=([Diagnostics.Stopwatch]::GetTimestamp()-1);Abandoned=$false;Submitted=$true;StartupSettled=$true;StartupPublishPending=$true;Pipeline=$pipeline;CreationTask=$creation;InvokeTask=$invocation;DisposeTask=$null;Failure=$null;CleanupFailures=@()}.GetEnumerator()){$expiredOwner[$pair.Key]=$pair.Value}
    $expiryRegistry.Add('expired',$expiredOwner)
    $expired=Complete-ReviewOwnedWork -OwnerRegistry $expiryRegistry
    $until=[Diagnostics.Stopwatch]::StartNew()
    while($expiryRegistry.Count -gt 0 -and $until.ElapsedMilliseconds -lt 1000){$expired=Complete-ReviewOwnedWork -OwnerRegistry $expiryRegistry;[Threading.Thread]::Sleep(5)}
    Assert-True ($expiredOwner['Abandoned'] -and -not $expired.Completed -and $null -eq $expired.Result) 'actual completion after deadline cannot accept result before controller abandonment'
    Assert-True ($expired.Retired -and $expiryRegistry.Count -eq 0) 'late physical retirement remains distinct from failed deadline acceptance'
}
Test-OwnedExpiredPublication
[OwnedWorkBarrier]::Entered.Reset();[OwnedWorkBarrier]::Release.Reset();[OwnedWorkBarrier]::Registry=$registry
$completionDefinitions=$defs.Clone()
$completionDefinitions['Invoke-OwnedFixtureWorker']=[scriptblock]::Create(@'
param($State,$Arguments)
try{
    $hold=[Delegate]::CreateDelegate([Action],[OwnedWorkBarrier].GetMethod('HoldRegistry'))
    $Arguments.Observed['Holder']=[Threading.Tasks.Task]::Run([Action]$hold)
    $null=[OwnedWorkBarrier]::Entered.Wait(1000)
    $State['Result']=New-ReviewReadOnlyRecord -Values @{Value='completed-under-contention'}
}finally{$State['CoreRetired']=$true}
'@)
$completionArguments=New-FixtureArguments $false
$fixturePrimary2=$null
try {
try{
    $contended=Invoke-ReviewOwnedWork -Kind contention -OwnerRegistry $registry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+[long](3*[Diagnostics.Stopwatch]::Frequency)) -WorkerName Invoke-OwnedFixtureWorker -Definitions $completionDefinitions -Arguments $completionArguments -State ([Collections.Concurrent.ConcurrentDictionary[string,object]]::new())
    Assert-True ($null -ne $contended -and $contended.IsReadOnly -and -not $contended.Completed -and -not $contended.Retired -and $null -eq $contended.Result) 'actual held registry at completion returns immutable unknown DTO instead of null or fabricated retirement'
    Assert-True ($registry.Count -eq 1 -and $null -ne $contended -and $contended.Failure.Code -ceq 'owned_observer_unavailable') 'completion contention retains actual owner and stable typed failure'
}
catch{throw}
}catch{$fixturePrimary2=$_;throw}finally{
$fixtureCleanup2=[Collections.Generic.List[Exception]]::new()
try{
[OwnedWorkBarrier]::Release.Set()
}catch{$fixtureCleanup2.Add($_.Exception)}
try{
$lateObservation=$null
}catch{$fixtureCleanup2.Add($_.Exception)}
try{
$wait.Restart()
}catch{$fixtureCleanup2.Add($_.Exception)}
try{
while($registry.Count -gt 0 -and $wait.ElapsedMilliseconds -lt 4000){$nextObservation=Complete-ReviewOwnedWork -OwnerRegistry $registry;if($null -ne $nextObservation){$lateObservation=$nextObservation};[Threading.Thread]::Sleep(10)}
}catch{$fixtureCleanup2.Add($_.Exception)}
if($fixtureCleanup2.Count -gt 0){
 if($null -ne $fixturePrimary2){
  $previous=@();if($fixturePrimary2.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary2.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary2.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup2.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup2.ToArray())}
}
}
Assert-Eq $registry.Count 0 'completion contention retires only after actual later registry observation'
Assert-True ($null -ne $lateObservation -and $lateObservation.Retired -and -not $lateObservation.Completed -and $null -eq $lateObservation.Result -and -not $lateObservation.TimedOut) 'failed in-time observation cannot later become acceptance or fabricated timeout'
# The completed worker cause remains primary when the original registry cannot
# be observed at all; no snapshot does not erase a separately confirmed fault.
function Invoke-OwnedContentionFailureWorker {
    param($State,$Arguments)
    try{
        $hold=[Delegate]::CreateDelegate([Action],[OwnedWorkBarrier].GetMethod('HoldRegistry'))
        $State['Holder']=[Threading.Tasks.Task]::Run([Action]$hold)
        $null=[OwnedWorkBarrier]::Entered.Wait(1000)
        throw [IO.IOException]::new('SENSITIVE-CONTENDED-WORKER')
    }finally{$State['CoreRetired']=$true}
}
$causeRegistry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$causeState=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
[OwnedWorkBarrier]::Entered.Reset();[OwnedWorkBarrier]::Release.Reset();[OwnedWorkBarrier]::Registry=$causeRegistry
$causeDefs=@{'Invoke-OwnedContentionFailureWorker'=(Get-Command Invoke-OwnedContentionFailureWorker).ScriptBlock}
$fixturePrimary3=$null
try {
try{
    $causeResult=Invoke-ReviewOwnedWork -Kind causal_contention -OwnerRegistry $causeRegistry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+3L*[Diagnostics.Stopwatch]::Frequency) -WorkerName Invoke-OwnedContentionFailureWorker -Definitions $causeDefs -Arguments @{} -State $causeState
    $originalCause=$causeState['Failure'];$causeOwner=$causeState['OwnedWorkOwner']
    Assert-True ([OwnedWorkBarrier]::Entered.IsSet -and $originalCause.Code -ceq 'owned_worker' -and $causeState['CoreRetired']) 'actual throwing worker confirms primary while original registry remains locked'
    Assert-True ([object]::ReferenceEquals($causeResult.Failure,$originalCause)) 'unavailable snapshot preserves exact original worker cause as primary'
    $secondary=@($causeResult.CleanupFailures)
    Assert-True ($secondary.Count -ge 1 -and $secondary.Count -le 2 -and @($secondary|Where-Object {$_.Code -ceq 'owned_observer_unavailable'}).Count -eq 1) 'unavailable snapshot remains independently bounded secondary after confirmed worker failure'
    Assert-True (-not $causeResult.Completed -and -not $causeResult.Retired -and -not $causeResult.TimedOut -and $null -eq $causeResult.Result -and $causeRegistry.Count -eq 1 -and [object]::ReferenceEquals($causeOwner['State'],$causeState)) 'registry observation failure cannot accept result or infer original retirement or timeout'
}
catch{throw}
}catch{$fixturePrimary3=$_;throw}finally{
$fixtureCleanup3=[Collections.Generic.List[Exception]]::new()
try{
[OwnedWorkBarrier]::Release.Set()
}catch{$fixtureCleanup3.Add($_.Exception)}
try{
$watch=[Diagnostics.Stopwatch]::StartNew()
}catch{$fixtureCleanup3.Add($_.Exception)}
try{
while($causeRegistry.Count -gt 0 -and $watch.ElapsedMilliseconds -lt 5000){$null=Complete-ReviewOwnedWork -OwnerRegistry $causeRegistry;Start-Sleep -Milliseconds 10}
}catch{$fixtureCleanup3.Add($_.Exception)}
try{
Assert-Eq $causeRegistry.Count 0 'contended failed-worker fixture physically retires only after actual registry release and disposal'
}catch{$fixtureCleanup3.Add($_.Exception)}
if($fixtureCleanup3.Count -gt 0){
 if($null -ne $fixturePrimary3){
  $previous=@();if($fixturePrimary3.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary3.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary3.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup3.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup3.ToArray())}
}
}
# Reload in a genuinely different script scope must still name the original registry objects.
$dirs=Get-ReviewOwnerRegistry LiveGateDirectories;$readers=Get-ReviewOwnerRegistry SecurityAuthSourceReads -List
$token=[guid]::NewGuid().ToString('n')
$reloadDirectoryOwner=[pscustomobject]@{Custody=[pscustomobject]@{ConsumersRetired=$false}}
$reader=[pscustomobject]@{Retired=$false}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('owned-reload-'+[guid]::NewGuid().ToString('n')+'.ps1')
$fixturePrimary4=$null
try {
try{
$dirs.Add($token,$reloadDirectoryOwner)
$readers.Add($reader)
[IO.File]::WriteAllText($scratch,@'
param($Library,$Directories,$Readers)
. $Library
[pscustomobject]@{DirectoriesSame=[object]::ReferenceEquals($Directories,(Get-ReviewOwnerRegistry LiveGateDirectories));ReadersSame=[object]::ReferenceEquals($Readers,(Get-ReviewOwnerRegistry SecurityAuthSourceReads -List));DirectoryCount=(Get-ReviewOwnerRegistry LiveGateDirectories).Count;ReaderCount=$Readers.Count}
'@)
    $reload=& $scratch -Library $library -Directories $dirs -Readers $readers
    Assert-True ($reload.DirectoriesSame -and $reload.ReadersSame -and $reload.DirectoryCount -ge 1 -and $reload.ReaderCount -ge 1) 'cross-script reload preserves pending directory and auth-owner identity'
    Assert-Throws {Get-ReviewOwnerRegistry SecurityAuthSourceReads} 'reload cannot replace a list registry with a different shape'
}
catch{throw}
}catch{$fixturePrimary4=$_;throw}finally{
$fixtureCleanup4=[Collections.Generic.List[Exception]]::new()
try{
if($dirs.ContainsKey($token)){
    if(-not [object]::ReferenceEquals($dirs[$token],$reloadDirectoryOwner)){throw [InvalidOperationException]::new('Reload fixture directory owner changed; cleanup refused')}
    $dirs.Remove($token)|Out-Null
}
}catch{$fixtureCleanup4.Add($_.Exception)}
try{
for($readerIndex=$readers.Count-1;$readerIndex -ge 0;$readerIndex--){
    if([object]::ReferenceEquals($readers[$readerIndex],$reader)){$readers.RemoveAt($readerIndex);break}
}
}catch{$fixtureCleanup4.Add($_.Exception)}
try{
[IO.File]::Delete($scratch)
}catch{$fixtureCleanup4.Add($_.Exception)}
if($fixtureCleanup4.Count -gt 0){
 if($null -ne $fixturePrimary4){
  $previous=@();if($fixturePrimary4.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary4.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary4.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup4.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup4.ToArray())}
}
}
Write-TestResult
