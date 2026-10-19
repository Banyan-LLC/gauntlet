# Fixture cleanup preservation v1: primary and independent cleanup errors.
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. (Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1')
Initialize-LiveGateNative
Add-Type -TypeDefinition 'public static class DormantContextFixture { public static int CoreCalls; public static long Deadline; public static object State; }'
$savedCore=(Get-Command Invoke-BoundedProcessCore).ScriptBlock
# Sealed OS boundary only: actual public admission/owner/observer/retirement run.
function Invoke-BoundedProcessCore {
    param($FileName,$ArgList,$StdinText,$WorkingDirectory,$TimeoutSec,$TimeoutMilliseconds,$DeadlineTimestamp,$EnvironmentMap,$FailureCancellationToken,[switch]$ClearEnvironment,[switch]$RequireProcessTreeRetirement)
    [DormantContextFixture]::CoreCalls++
    [DormantContextFixture]::Deadline=$DeadlineTimestamp
    [DormantContextFixture]::State=$script:ReviewNativeProcessState
    $script:ReviewNativeProcessState['NativeNeverStarted']=$false
    $native=[GauntletLive.Native+RunResult]::new()
    $native.ExitCode=0;$native.Stdout='context-fixture';$native.Stderr='';$native.ProcessTreeRetired=$true
    return $native
}
# This pure context seam is imported explicitly. It never invokes a producer.
function Get-ReviewProducerIoState {
    $variable=$ExecutionContext.SessionState.PSVariable.Get('script:DormantFixtureProducer')
    if($null -ne $variable){return $variable.Value}
    return $null
}
function New-ContextFixtureState([long]$Deadline){
    $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $state['Deadline']=$Deadline;$state['Abandoned']=$false
    $state['NativeOwners']=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    $state['NativeRuns']=[Collections.Generic.List[object]]::new()
    return ,$state
}
function Invoke-ContextFixtureWorker {
    param($State,$Arguments)
    try{$State['Result']=Invoke-BoundedProcess -FileName 'never-launch.exe' -TimeoutSec 20 -RequireProcessTreeRetirement}
    finally{$State['CoreRetired']=$true}
}
$fixturePrimary0=$null
try {
try{
    $producer=New-ContextFixtureState ([Diagnostics.Stopwatch]::GetTimestamp()+8L*[Diagnostics.Stopwatch]::Frequency)
    $script:DormantFixtureProducer=$producer
    $result=Invoke-BoundedProcess -FileName 'never-launch.exe' -TimeoutSec 20 -RequireProcessTreeRetirement
    Assert-True ($result.ExitCode -eq 0 -and $result.ProcessTreeRetired -and [DormantContextFixture]::Deadline -eq $producer['Deadline']) 'present imported pure producer context supplies exact smaller original deadline'
    $queued=$producer['NativeOwners'].ToArray()
    Assert-True ($queued.Count -eq 1 -and [object]::ReferenceEquals($queued[0],[DormantContextFixture]::State) -and (Get-ReviewProcessRetirement -State $queued[0]).Retired) 'present context records exact original native state and actual retirement'
    $filesystem=New-ContextFixtureState ([Diagnostics.Stopwatch]::GetTimestamp()+6L*[Diagnostics.Stopwatch]::Frequency)
    $script:ReviewFilesystemState=$filesystem
    $result=Invoke-BoundedProcess -FileName 'never-launch.exe' -TimeoutSec 20 -RequireProcessTreeRetirement
    Assert-True ($result.ExitCode -eq 0 -and $result.ProcessTreeRetired -and [DormantContextFixture]::Deadline -eq $filesystem['Deadline']) 'present filesystem context wins minimum deadline over larger producer and local cap'
    Assert-True ($filesystem['NativeRuns'].Count -eq 1 -and $filesystem['NativeRuns'][0].Retired -and [object]::ReferenceEquals($filesystem['NativeRuns'][0].Result,$result) -and $filesystem['Stage'] -ceq 'native_completion') 'filesystem hook retains exact native result slot and completion boundary'
    Remove-Variable ReviewFilesystemState -Scope Script
    $script:DormantFixtureProducer=$null
    $defs=Get-ReviewWorkerDefinitions -LibraryDefinition (Get-Command Invoke-BoundedProcess).ScriptBlock
    $defs['Invoke-ContextFixtureWorker']=(Get-Command Invoke-ContextFixtureWorker).ScriptBlock
    $defs['Get-ReviewProducerIoState']=(Get-Command Get-ReviewProducerIoState).ScriptBlock
    $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+5L*[Diagnostics.Stopwatch]::Frequency
    $outer=Invoke-ReviewOwnedWork -Kind context_fixture -OwnerRegistry $registry -DeadlineTimestamp $deadline -WorkerName Invoke-ContextFixtureWorker -Definitions $defs -Arguments @{} -State $state
    Assert-True ($outer.Completed -and $outer.Retired -and $outer.Result.ExitCode -eq 0 -and [DormantContextFixture]::Deadline -eq $deadline -and $registry.Count -eq 0) 'actual nested inline native facade cannot reset original generic owner deadline'
    $producer=New-ContextFixtureState ([Diagnostics.Stopwatch]::GetTimestamp()+10L*[Diagnostics.Stopwatch]::Frequency)
    $script:DormantFixtureProducer=$producer
    $prior=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    foreach($pair in @{Inline=$true;Settled=$true;NativeNeverStarted=$false;Result=$null}.GetEnumerator()){$prior[$pair.Key]=$pair.Value}
    $producer['NativeOwners'].Enqueue($prior)
    $before=[DormantContextFixture]::CoreCalls;$failure=$null
    try{$null=Invoke-BoundedProcess -FileName 'never-launch.exe' -TimeoutSec 20 -RequireProcessTreeRetirement}catch{$failure=$_.Exception}
    Assert-True ($null -ne $failure -and $failure.Data['ReviewCode'] -ceq 'native_prior_owner' -and $failure.Data['ReviewStage'] -ceq 'native_admission') 'actual original producer queue refuses second invocation while prior native outcome is unknown'
    $queued=$producer['NativeOwners'].ToArray()
    Assert-True ([DormantContextFixture]::CoreCalls -eq $before -and $queued.Count -eq 1 -and [object]::ReferenceEquals($queued[0],$prior)) 'prior-owner refusal never dispatches Core or replaces original native ownership slot'
    Assert-Eq (Get-ReviewOwnerRegistry ReviewProcessOwners).Count 0 'pure context contract cases leave no native worker owner'
}
catch{throw}
}catch{$fixturePrimary0=$_;throw}finally{
$fixtureCleanup0=[Collections.Generic.List[Exception]]::new()
try{
$script:DormantFixtureProducer=$null
}catch{$fixtureCleanup0.Add($_.Exception)}
try{
Remove-Variable ReviewFilesystemState -Scope Script -ErrorAction SilentlyContinue
}catch{$fixtureCleanup0.Add($_.Exception)}
try{
Set-Item Function:Invoke-BoundedProcessCore $savedCore
}catch{$fixtureCleanup0.Add($_.Exception)}
if($fixtureCleanup0.Count -gt 0){
 if($null -ne $fixturePrimary0){
  $previous=@();if($fixturePrimary0.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary0.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary0.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup0.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup0.ToArray())}
}
}
Write-TestResult
