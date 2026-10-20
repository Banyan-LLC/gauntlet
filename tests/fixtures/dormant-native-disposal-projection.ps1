param(
 [Parameter(Mandatory)][string]$RepoRoot,
 [Parameter(Mandatory)][string]$Source,
 [ValidateSet('all','generic','facade')][string]$Mode='all',
 [ValidateRange(0,7)][int]$Mask=0,
 [switch]$EarlierWorker,
 [switch]$ExpireFacade
)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
$sourceHash=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
. $Source
if($Mode -ceq 'all'){
 # Each failed facade owner remains fenced. Never clear or reuse its registry:
 # a fresh child is required for every actual native/disposal combination.
 $cases=@(@{Mode='generic';Mask=0})+@(foreach($maskValue in 0..7){@{Mode='facade';Mask=$maskValue}})+@(@{Mode='facade';Mask=4;EarlierWorker=$true},@{Mode='facade';Mask=7;ExpireFacade=$true},@{Mode='facade';Mask=7;EarlierWorker=$true;ExpireFacade=$true})
 foreach($case in $cases){
  $argsList=@('-NoProfile','-File',$PSCommandPath,'-RepoRoot',$RepoRoot,'-Source',$Source,'-Mode',$case.Mode,'-Mask',[string]$case.Mask)
  if($case.ContainsKey('EarlierWorker') -and $case.EarlierWorker){$argsList+=@('-EarlierWorker')}
  if($case.ContainsKey('ExpireFacade') -and $case.ExpireFacade){$argsList+=@('-ExpireFacade')}
  $child=Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList $argsList -WorkingDirectory $RepoRoot -TimeoutSec 180 -RequireProcessTreeRetirement
  Write-Host $child.Stdout
  if($child.Stderr){Write-Host $child.Stderr}
  Assert-True ($child.ExitCode -eq 0 -and -not $child.StartFailed -and -not $child.TimedOut -and $child.ProcessTreeRetired -and $null -eq $child.ErrorMessage -and $null -eq $child.Failure -and $child.CleanupFailures.Count -eq 0) ($case.Mode+'/'+$case.Mask+' isolated regression succeeds and original outer tree retires')
 }
 Assert-Eq ((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash) $sourceHash 'outer driver preserves exact requested source'
 Write-TestResult
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.ObjectModel;
using System.IO;
using System.Management.Automation;
using System.Threading;
using System.Threading.Tasks;
public sealed class ProjectionPipelineDisposalException:IOException {
 public ProjectionPipelineDisposalException():base("PRIVATE_PIPELINE_DISPOSAL_MESSAGE"){HResult=unchecked((int)0x8004f101);}
}
public sealed class ProjectionOutputDisposalException:IOException {
 public ProjectionOutputDisposalException():base("PRIVATE_OUTPUT_DISPOSAL_MESSAGE"){HResult=unchecked((int)0x8004f102);}
}
public sealed class ProjectionGuardDisposalException:IOException {
 public ProjectionGuardDisposalException():base("PRIVATE_GUARD_DISPOSAL_MESSAGE"){HResult=unchecked((int)0x8004f103);}
}
public sealed class ProjectionWorkerException:Exception {
 public ProjectionWorkerException():base("PRIVATE_EARLIER_WORKER_MESSAGE"){HResult=unchecked((int)0x8004f104);}
}
public class ProjectionDisposalResource:IDisposable {
 public readonly IDisposable Original;
 public readonly Exception Failure;
 public int Calls;public bool OriginalDisposed;
 public ProjectionDisposalResource(IDisposable original,Exception failure){Original=original;Failure=failure;}
 public virtual void Dispose(){Interlocked.Increment(ref Calls);Original.Dispose();OriginalDisposed=true;if(Failure!=null)throw Failure;}
}
public sealed class ProjectionGuardResource:ProjectionDisposalResource {
 public ProjectionGuardResource(IDisposable original,Exception failure):base(original,failure){}
 public object FirstError{get{return Original.GetType().GetProperty("FirstError").GetValue(Original);}}
 public bool NativeCancellationsRetired{get{return (bool)Original.GetType().GetProperty("NativeCancellationsRetired").GetValue(Original);}}
}
public sealed class ProjectionPipeline:ProjectionDisposalResource {
 readonly PowerShell inner;
 public ProjectionPipeline(PowerShell value,Exception failure):base(value,failure){inner=value;}
 public PSCommand Commands{get{return inner.Commands;}}
 public PSDataStreams Streams{get{return inner.Streams;}}
 public ProjectionPipeline AddScript(string value){inner.AddScript(value);return this;}
 public ProjectionPipeline AddArgument(object value){inner.AddArgument(value);return this;}
 public Collection<PSObject> Invoke(){return inner.Invoke();}
 public void Invoke<TInput,TOutput>(PSDataCollection<TInput> input,PSDataCollection<TOutput> output,PSInvocationSettings settings){inner.Invoke<TInput,TOutput>(input,output,settings);}
 public Task StopAsync(AsyncCallback callback,object state){return inner.StopAsync(callback,state);}
}
public static class ProjectionFactory {
 public static int Mask;public static ProjectionPipeline Pipeline;
 public static ProjectionDisposalResource Output;public static ProjectionGuardResource Guard;
 public static object Create(){Pipeline=new ProjectionPipeline(PowerShell.Create(),(Mask&1)!=0?new ProjectionPipelineDisposalException():null);return Pipeline;}
}
'@

# One exact constructor boundary only. Creation, initializer, configuration and
# invocation still run on the original retained production startup/invoke tasks.
$originalCreation=(Get-Command Start-ReviewOwnedPipelineCreation).ScriptBlock
$creationText=$originalCreation.ToString();$creationNeedle='[Management.Automation.PowerShell]'
if([regex]::Matches($creationText,[regex]::Escape($creationNeedle)).Count -ne 1){throw 'Private regression refuses changed constructor boundary'}
$tokens=$null;$parseErrors=$null
$creationAst=[Management.Automation.Language.Parser]::ParseInput($creationText.Replace($creationNeedle,'[ProjectionFactory]'),$originalCreation.File,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Private constructor instrumentation did not parse'}
Set-Item Function:Start-ReviewOwnedPipelineCreation $creationAst.GetScriptBlock()
$script:OriginalDisposal=(Get-Command Start-ReviewPipelineDisposal).ScriptBlock
$script:LastDisposalOwner=$null
$script:ProjectionRetainedOwners=[Collections.Generic.List[object]]::new()
function Start-ReviewPipelineDisposal {
 param($Owner,$Pipeline)
 if($Pipeline -isnot [ProjectionPipeline] -or -not [object]::ReferenceEquals($Owner['Pipeline'],$Pipeline)){throw 'Exact original wrapped pipeline required'}
 if($Owner['Output'] -is [ProjectionDisposalResource]){throw 'Original disposer was scheduled more than once'}
 $Owner['FixtureOriginalOutput']=$Owner['Output'];$Owner['FixtureOriginalGuard']=$Owner['StreamGuard']
 $outputFailure=if(([ProjectionFactory]::Mask -band 2) -ne 0){[ProjectionOutputDisposalException]::new()}else{$null}
 $guardFailure=if(([ProjectionFactory]::Mask -band 4) -ne 0){[ProjectionGuardDisposalException]::new()}else{$null}
 [ProjectionFactory]::Output=[ProjectionDisposalResource]::new($Owner['Output'],$outputFailure)
 [ProjectionFactory]::Guard=[ProjectionGuardResource]::new($Owner['StreamGuard'],$guardFailure)
 $Owner['Output']=[ProjectionFactory]::Output;$Owner['StreamGuard']=[ProjectionFactory]::Guard
 $script:LastDisposalOwner=$Owner
 # Actual unchanged Start-ReviewPipelineDisposal and its emitted disposal action.
 $task=& $script:OriginalDisposal -Owner $Owner -Pipeline $Pipeline
 if($script:ExpireFacade){
  # Transparent controller observation barrier after the real retained disposer
  # was published. No clock, task state, result or exception is substituted.
  while((Get-ReviewRemainingMilliseconds $Owner['Deadline']) -gt 0){[Threading.Thread]::Sleep([Math]::Min(10,(Get-ReviewRemainingMilliseconds $Owner['Deadline'])))}
 }
 return ,$task
}
if($EarlierWorker){
 # The original worker actually runs native execution and its original finally.
 # Then a genuine later worker exception precedes independent guard disposal.
 $script:OriginalProcessWorker=(Get-Command Invoke-ReviewProcessWorker).ScriptBlock
 $script:OriginalDefinitions=(Get-Command Get-ReviewWorkerDefinitions).ScriptBlock
 function Invoke-ReviewProcessWorker {
  param($State,$Arguments)
  Invoke-ProjectionOriginalProcessWorker -State $State -Arguments $Arguments
  throw [ProjectionWorkerException]::new()
 }
 function Get-ReviewWorkerDefinitions {
  param([Parameter(Mandatory)][scriptblock]$LibraryDefinition)
  $definitions=& $script:OriginalDefinitions -LibraryDefinition $LibraryDefinition
  $definitions['Invoke-ProjectionOriginalProcessWorker']=$script:OriginalProcessWorker
  return $definitions
 }
}

$script:RoleInfo=@(
 @{Bit=1;Name='pipeline';Code='owned_disposal';Field='DisposalFailure';Raw='PipelineDisposalException';Type='ProjectionPipelineDisposalException';HResult=[int]-2147159807},
 @{Bit=2;Name='output';Code='owned_output_disposal';Field='OutputDisposalFailure';Raw='OutputDisposalException';Type='ProjectionOutputDisposalException';HResult=[int]-2147159806},
 @{Bit=4;Name='guard';Code='owned_stream_guard_disposal';Field='StreamGuardDisposalFailure';Raw='StreamGuardDisposalException';Type='ProjectionGuardDisposalException';HResult=[int]-2147159805}
)
function Get-ProjectionFaults($Outcome){@($Outcome.Failure)+@($Outcome.CleanupFailures)|Where-Object {$null -ne $_}}
function Assert-OriginalDisposal($Owner,[int]$Value,[string]$Case){
 $resources=@([ProjectionFactory]::Pipeline,[ProjectionFactory]::Output,[ProjectionFactory]::Guard)
 Assert-True ($null -ne $Owner['CreationTask'] -and $Owner['CreationTask'].IsCompletedSuccessfully -and $null -ne $Owner['InvokeTask'] -and $Owner['InvokeTask'].IsCompleted) ($Case+' retains actual original creation and invocation tasks')
 Assert-True ([object]::ReferenceEquals($Owner['Pipeline'],$resources[0]) -and [object]::ReferenceEquals($Owner['CreationTask'].Result,$resources[0])) ($Case+' original factory result remains original owner pipeline')
 Assert-True ([object]::ReferenceEquals($resources[1].Original,$Owner['FixtureOriginalOutput']) -and [object]::ReferenceEquals($resources[2].Original,$Owner['FixtureOriginalGuard'])) ($Case+' wrappers retain exact original output collection and guard')
 Assert-True ($null -ne $Owner['DisposeTask'] -and $Owner['DisposeTask'].IsCompleted -and $Owner['DisposalIntent']) ($Case+' retained original disposal task actually settles')
 foreach($index in 0..2){
  $resource=$resources[$index];$role=$script:RoleInfo[$index];$fails=($Value -band $role.Bit) -ne 0
  Assert-True ($resource.Calls -eq 1 -and $resource.OriginalDisposed) ($Case+' '+$role.Name+' actually disposes its exact original once before any controlled failure')
  Assert-True (($null -ne $Owner[$role.Raw]) -eq $fails) ($Case+' '+$role.Name+' independent raw failure slot matches stimulus')
  if($fails){Assert-True ([object]::ReferenceEquals($Owner[$role.Raw],$resource.Failure)) ($Case+' '+$role.Name+' retains exact thrown original exception')}
 }
 Assert-True ($Owner['DisposeTask'].IsCompletedSuccessfully -eq ($Value -eq 0)) ($Case+' task success is actual all-resource disposal outcome')
}
function Assert-PublicRole($Fault,$Role,[switch]$Flat,[string]$Case){
 Assert-True ($null -ne $Fault -and $Fault.IsReadOnly -and $Fault.Code -ceq $Role.Code -and $Fault.Stage -ceq 'worker_dispose') ($Case+' '+$Role.Name+' separate stable bounded public fault')
 if($null -eq $Fault){return}
 $cause=if($Flat){$Fault}else{$Fault.Cause}
 Assert-True ($null -ne $cause -and $cause.Type -ceq $Role.Type -and $cause.HResult -eq $Role.HResult) ($Case+' '+$Role.Name+' actual distinct type/HResult survives projection without aggregate wrapper')
}
function Assert-ProjectionLedger($Outcome,$Owner,[int]$Value,[bool]$WorkerFails,[bool]$Expired,[switch]$Flat,[string]$Case){
 $faults=@(Get-ProjectionFaults $Outcome)
 $roles=@($script:RoleInfo|Where-Object {($Value -band $_.Bit) -ne 0})
 $expected=@();if($WorkerFails){$expected+=@{Name='worker';Code='owned_worker';Type='ProjectionWorkerException';HResult=[int]-2147159804}}
 $expected+=@($roles)
 $primary=if($expected.Count){$expected[0]}else{$null}
 $selected=@();if($expected.Count -gt 1){$selected=@($expected|Select-Object -Skip 1 -First 2)}
 if($Expired){
  if($null -eq $primary){$primary=@{Name='deadline';Code='owned_deadline'}}
  elseif($primary.Code -cne 'owned_deadline'){$selected=@($selected|Select-Object -First 1)+@(@{Name='deadline';Code='owned_deadline'})}
 }
 $required=@();if($null -ne $primary){$required+=@($primary)};$required+=@($selected)
 Assert-True ($Outcome.IsReadOnly -and $Outcome.CleanupFailures.IsReadOnly -and $Outcome.CleanupFailures.Count -le 2) ($Case+' immutable outcome preserves two-secondary bound')
 # The established public Invoke-ReviewOwnedWork catch may add its separate
 # owned_startup observer fault after actual resource faults. It must never
 # replace a genuine selected resource or consume an invented pipeline slot.
 $actualRequired=@($faults|Where-Object {$_.Code -cne 'owned_startup'})
 Assert-Eq $actualRequired.Count $required.Count ($Case+' public ledger contains exact selected genuine causes and no disposal-wrapper duplicate')
 $actualCodes=@($actualRequired|ForEach-Object {$_.Code}) -join ',';$expectedCodes=@($required|ForEach-Object {$_.Code}) -join ','
 Assert-Eq $actualCodes $expectedCodes ($Case+' deterministic worker/pipeline/output/guard ordering and deadline-last reserve')
 foreach($role in $roles){
  $wanted=@($required|Where-Object {$_.Code -ceq $role.Code}).Count
  $matches=@($faults|Where-Object {$_.Code -ceq $role.Code})
  Assert-Eq $matches.Count $wanted ($Case+' '+$role.Name+' public cause appears exactly as selected')
  if($wanted -eq 1 -and $matches.Count -eq 1){Assert-PublicRole -Fault $matches[0] -Role $role -Flat:$Flat -Case $Case}
  if(-not $Flat){
   Assert-True ($null -ne $Owner[$role.Field] -and $Owner[$role.Field].Code -ceq $role.Code) ($Case+' '+$role.Name+' independent original projection slot exists')
   if($wanted -eq 1 -and $matches.Count -eq 1){Assert-True ([object]::ReferenceEquals($matches[0],$Owner[$role.Field])) ($Case+' '+$role.Name+' generic public cause is exact retained immutable fault')}
  }
 }
 if($WorkerFails){
  if($Flat){Assert-True ($Outcome.Failure.Code -ceq 'owned_worker' -and $Outcome.Failure.Type -ceq 'ProjectionWorkerException' -and $Outcome.Failure.HResult -eq [int]-2147159804) ($Case+' actual earlier worker primary survives native flat projection')}
  else{Assert-True ([object]::ReferenceEquals($Outcome.Failure,$Owner['State']['Failure'])) ($Case+' earlier actual worker fault remains exact primary')}
 }
 if($Expired){Assert-True ($Outcome.TimedOut -and $Owner['Abandoned'] -and $Owner['TimedOut'] -and $null -ne $Owner['DeadlineFailure'] -and @($faults|Where-Object Code -ceq 'owned_deadline').Count -eq 1) ($Case+' original expiry is irreversible and retained once')}
 if($Value -ne 0){Assert-True (-not $Owner['RetirementConfirmed'] -and $Owner['Registry'].ContainsKey($Owner['Token'])) ($Case+' failed original disposer keeps original registry fenced')}
 $encoded=$Outcome|ConvertTo-Json -Depth 16 -Compress
 Assert-True (-not $encoded.Contains('PRIVATE_')) ($Case+' public evidence contains no original exception messages')
 if($Flat){foreach($fault in $faults){Assert-True ($fault.Keys.Count -eq 5) ($Case+' every native facade fault retains flat-five shape')}}
}

function Invoke-DirectProjectionCase([int]$Value,[bool]$WorkerFails=$false,[bool]$Expire=$false){
 [ProjectionFactory]::Mask=$Value
 $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
 $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal)
 $owner=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal)
 $token=[guid]::NewGuid().ToString('n');$deadline=[Diagnostics.Stopwatch]::GetTimestamp()+10L*[Diagnostics.Stopwatch]::Frequency
 foreach($pair in @{Kind='disposal_projection';State=$state;Registry=$registry;Token=$token;Deadline=$deadline;Abandoned=$false;TimedOut=$false;Submitted=$false;StartupSettled=$false;StartupPublishPending=$false;StartupStage='worker_create';RetirementConfirmed=$false;Pipeline=$null;CreationTask=$null;InvokeTask=$null;DisposeTask=$null;Failure=$null;CleanupFailures=@()}.GetEnumerator()){$owner[$pair.Key]=$pair.Value}
 $state['OwnedWorkOwner']=$owner;$state['Deadline']=$deadline;$state['Abandoned']=$false;$state['CoreRetired']=$false
 $script:ProjectionRetainedOwners.Add($owner)
 $registry.Add($token,$owner)
 $bootstrap=@'
param($state,$source,$workerFails)
$ErrorActionPreference='Stop'
. $source
try{
 $state['ActionEntered']=$true
 if($workerFails){throw [ProjectionWorkerException]::new()}
 $state['Result']=New-ReviewReadOnlyRecord -Values @{Value='actual-explicit-worker-result'}
}catch{$state['Failure']=New-ReviewTransportFault -Code 'owned_worker' -Stage 'worker_action' -Exception $_.Exception}
finally{$state['CoreRetired']=$true}
'@
 $created=Start-ReviewOwnedPipelineCreation -Owner $owner -Bootstrap $bootstrap -ArgumentList @($state,$Source,$WorkerFails);$owner['CreationTask']=$created
 if(-not $created.Wait((Get-ReviewRemainingMilliseconds $deadline)) -or -not $created.IsCompletedSuccessfully){throw 'Actual direct creation did not settle within original deadline'}
 $pipeline=$created.Result
 $owner['Submitted']=$true;$owner['InvokeTask']=Start-ReviewOwnedPipelineInvocation -Pipeline $pipeline -Owner $owner
 $owner['StartupPublishPending']=$true;$owner['StartupSettled']=$true
 if(-not $owner['InvokeTask'].Wait((Get-ReviewRemainingMilliseconds $deadline)) -or -not $owner['InvokeTask'].IsCompletedSuccessfully){throw 'Actual direct invocation did not settle within original deadline'}
 $first=Complete-ReviewOwnedWork -OwnerRegistry $registry -Token $token
 $task=$owner['DisposeTask'];if($null -eq $task){throw 'Actual completion did not schedule its retained disposer'}
 try{$null=$task.Wait((Get-ReviewRemainingMilliseconds $deadline))}catch{}
 if(-not $task.IsCompleted){throw 'Controlled original disposer did not physically settle'}
 if($Expire){while((Get-ReviewRemainingMilliseconds $deadline) -gt 0){[Threading.Thread]::Sleep([Math]::Min(10,(Get-ReviewRemainingMilliseconds $deadline)))}}
 $outcome=Complete-ReviewOwnedWork -OwnerRegistry $registry -Token $token
 if($null -eq $outcome){$outcome=$first}
 $case='generic-mask'+$Value+'-worker'+$WorkerFails+'-expired'+$Expire
 Assert-OriginalDisposal -Owner $owner -Value $Value -Case $case
 Assert-ProjectionLedger -Outcome $outcome -Owner $owner -Value $Value -WorkerFails $WorkerFails -Expired $Expire -Case $case
 Assert-True ($owner['Deadline'] -eq $deadline -and $state['Deadline'] -eq $deadline) ($case+' retains unchanged original absolute deadline')
 if($Value -eq 0 -and -not $WorkerFails -and -not $Expire){Assert-True ($outcome.Retired -and $outcome.Completed -and $outcome.Result.Value -ceq 'actual-explicit-worker-result' -and $registry.Count -eq 0) ($case+' actual clean worker and all three original resources retire')}
 else{Assert-True (-not $outcome.Retired -and $null -eq $outcome.Result) ($case+' failed original resource cannot publish result or retirement')}
}

if($Mode -ceq 'generic'){
 # First ordinary case compiles the guard on a generous original deadline.
 foreach($value in 0..7){Invoke-DirectProjectionCase -Value $value}
 Invoke-DirectProjectionCase -Value 4 -WorkerFails $true
 Invoke-DirectProjectionCase -Value 7 -WorkerFails $true
 Invoke-DirectProjectionCase -Value 7 -Expire $true
 Invoke-DirectProjectionCase -Value 7 -WorkerFails $true -Expire $true
 Assert-True ($null -eq ('GauntletLive.Native' -as [type])) 'generic public projection controls keep native type cold'
}else{
 [ProjectionFactory]::Mask=$Mask
 # Real harmless native child. Never fabricate Core success, native receipt,
 # native retirement, task completion, result or error projector output.
 $timeout=if($ExpireFacade){12}else{30}
 $result=Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList @('-NoProfile','-NonInteractive','-Command','[Console]::Out.Write("disposal-projection-native");exit 0') -WorkingDirectory $RepoRoot -TimeoutSec $timeout -RequireProcessTreeRetirement
 $owner=$script:LastDisposalOwner;$state=$owner['State'];$actual=$state['Result'];$receipt=$result.NativeProcessResult;$case='facade-mask'+$Mask+'-worker'+[bool]$EarlierWorker+'-expired'+[bool]$ExpireFacade
 Assert-OriginalDisposal -Owner $owner -Value $Mask -Case $case
 Assert-True ($null -ne $actual -and $actual.GetType().FullName -ceq 'GauntletLive.Native+RunResult' -and $actual.ExitCode -eq 0 -and -not $actual.StartFailed -and -not $actual.TimedOut -and $actual.ProcessTreeRetired -and $actual.Stdout -ceq 'disposal-projection-native' -and $null -eq $actual.Failure -and $actual.CleanupFailures.Length -eq 0) ($case+' real native execution and original job retire before generic disposal faults')
 Assert-True ($null -ne $receipt -and $receipt.IsReadOnly -and $receipt.Keys.Count -eq 6) ($case+' genuine immutable actual-native six-scalar receipt remains separate')
 if($null -ne $receipt){foreach($pair in @{ExitCode=$actual.ExitCode;StartFailed=$actual.StartFailed;TimedOut=$actual.TimedOut;ErrorMessage=$actual.ErrorMessage;StderrText=$actual.Stderr;ProcessTreeRetired=$actual.ProcessTreeRetired}.GetEnumerator()){Assert-True ($receipt.ContainsKey($pair.Key) -and [object]::Equals($receipt[$pair.Key],$pair.Value)) ($case+' native receipt preserves actual '+$pair.Key)}}
 Assert-ProjectionLedger -Outcome $result -Owner $owner -Value $Mask -WorkerFails ([bool]$EarlierWorker) -Expired ([bool]$ExpireFacade) -Flat -Case $case
 if($Mask -eq 0){Assert-True ($result.ExitCode -eq 0 -and $result.ProcessTreeRetired -and $null -eq $result.Failure -and $result.CleanupFailures.Count -eq 0) ($case+' actual clean aggregate succeeds')}
 else{Assert-True ($result.ExitCode -eq -1 -and -not $result.ProcessTreeRetired -and $result.TimedOut -eq [bool]$ExpireFacade -and -not $result.StartFailed -and $null -ne $result.Failure) ($case+' disposal refusal preserves actual retirement/startup and original aggregate expiry')}
}
Assert-Eq ((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash) $sourceHash 'private child preserves exact requested source'
Write-TestResult
