param([Parameter(Mandatory)][string]$RepoRoot,[ValidateSet('ordinary','foreign','transport','metadata')][string]$Case='ordinary')
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. (Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1')
$before=(Get-FileHash (Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1')).Hash
if($Case -ceq 'ordinary'){
Add-Type @'
using System;
using System.Collections;
using System.ComponentModel;
public class ProjectionHostileException : Exception {
 public static int DataCalls,HiddenCalls;
 public new Type GetType(){HiddenCalls++;throw new InvalidOperationException("SENSITIVE-GETTYPE");}
 public override IDictionary Data {get{DataCalls++;throw new InvalidOperationException("SENSITIVE-DATA-GETTER");}}
 public new int HResult {get{HiddenCalls++;throw new InvalidOperationException("SENSITIVE-HRESULT-GETTER");}}
 public new Exception InnerException {get{HiddenCalls++;throw new InvalidOperationException("SENSITIVE-INNER-GETTER");}}
}
public class ProjectionHiddenNative : Win32Exception {
 public static int Calls;
 public ProjectionHiddenNative():base(32){}
 public new int NativeErrorCode {get{Calls++;throw new InvalidOperationException("SENSITIVE-NATIVE-GETTER");}}
}
public class ProjectionText {
 public static int Calls;
 public override string ToString(){Calls++;throw new InvalidOperationException("SENSITIVE-TOSTRING");}
}
public class ProjectionKey {
 public static int Calls;
 public override bool Equals(object other){Calls++;throw new InvalidOperationException("SENSITIVE-KEY-EQUALS");}
 public override int GetHashCode(){Calls++;throw new InvalidOperationException("SENSITIVE-KEY-HASH");}
}
'@
 $global:ProjectionEtsCalls=0
 $wrappedCode=[PSObject]::AsPSObject('legitimate_code')
 $wrappedStage=[PSObject]::AsPSObject('legitimate_stage')
 foreach($wrapped in @($wrappedCode,$wrappedStage)){
  $wrapped|Add-Member -MemberType ScriptProperty -Name Length -Value {$global:ProjectionEtsCalls++;throw 'SENSITIVE-ETS-LENGTH'} -Force
  $wrapped|Add-Member -MemberType ScriptMethod -Name ToString -Value {$global:ProjectionEtsCalls++;throw 'SENSITIVE-ETS-TOSTRING'} -Force
 }
 $fault=New-ReviewTransportFault $wrappedCode $wrappedStage ([IO.IOException]::new())
 Assert-True ($fault.Code -ceq 'legitimate_code' -and $fault.Stage -ceq 'legitimate_stage' -and $global:ProjectionEtsCalls -eq 0) 'ETS-wrapped actual string parameters use fixed CLR admission without callbacks'
 $etsError=[IO.IOException]::new();$etsError.Data['ReviewCode']=$wrappedCode;$etsError.Data['ReviewStage']=$wrappedStage
 $fault=New-ReviewTransportFault fallback_code fallback_stage $etsError
 Assert-True ($fault.Code -ceq 'legitimate_code' -and $fault.Stage -ceq 'legitimate_stage' -and $global:ProjectionEtsCalls -eq 0) 'ETS-wrapped framework Data code and stage invoke no script properties or formatter'
 Assert-True ($fault.Code.Length -eq 15 -and $fault.Stage.Length -eq 16 -and $global:ProjectionEtsCalls -eq 0) 'public identifiers are fresh primitive strings without ETS instance members'
 $etsRegistry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
 $etsState=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal)
 $etsOwner=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal)
 $etsDeadline=[Diagnostics.Stopwatch]::GetTimestamp()+10L*[Diagnostics.Stopwatch]::Frequency
 $etsState['Deadline']=$etsDeadline;$etsState['Abandoned']=$false;$etsState['CoreRetired']=$false;$etsState['OwnedWorkOwner']=$etsOwner
 $etsCreation=[Threading.Tasks.Task[object]]::FromException($etsError)
 foreach($pair in @{State=$etsState;Deadline=$etsDeadline;Abandoned=$false;TimedOut=$false;Submitted=$false;StartupSettled=$true;StartupPublishPending=$true;StartupStage='worker_create';RetirementConfirmed=$false;Pipeline=$null;Output=$null;CreationTask=$etsCreation;InvokeTask=$null;DisposeTask=$null;Failure=$null;CleanupFailures=@()}.GetEnumerator()){$etsOwner[$pair.Key]=$pair.Value}
 $etsRegistry.Add('original',$etsOwner)
 $observed=Complete-ReviewOwnedWork -OwnerRegistry $etsRegistry -Token original
 Assert-True ($observed.Failure.Code -ceq 'legitimate_code' -and $global:ProjectionEtsCalls -eq 0 -and $observed.Retired -and $etsRegistry.Count -eq 0) 'actual original creation-task controller observation has zero ETS callbacks'
 $wrappedType=[PSObject]::AsPSObject(([IO.IOException]).FullName)
 $wrappedType|Add-Member -MemberType ScriptProperty -Name Length -Value {$global:ProjectionEtsCalls++;throw 'SENSITIVE-TYPE-LENGTH'} -Force
 $safeType=Get-ReviewSafeCause ([IO.IOException]::new())
 Assert-True ($safeType.Type -ceq 'System.IO.IOException' -and $safeType.Type.Length -eq 21 -and $global:ProjectionEtsCalls -eq 0) 'safe cause type validation and publication strip ETS string members'
 $ex=[IO.IOException]::new('SENSITIVE-MESSAGE')
 $ex.Data['ReviewCode']='SENSITIVE-CODE-'+('X'*100000);$ex.Data['ReviewStage']='SENSITIVE-STAGE-'+('Y'*100000)
 $fault=New-ReviewTransportFault fallback_code fallback_stage $ex
 Assert-True ($fault.Code -ceq 'fallback_code' -and $fault.Stage -ceq 'fallback_stage') 'oversized and invalid Data identifiers retain fixed original fallbacks'
 Assert-True (($fault|ConvertTo-Json -Depth 12 -Compress).Length -lt 2048 -and ($fault|ConvertTo-Json -Depth 12 -Compress) -notmatch 'SENSITIVE-') 'oversized Data and raw messages never enter public fault'
 foreach($bad in @([ProjectionText]::new(),$true,17,('z'*65),"bad`n",'café')){
  $ex.Data['ReviewCode']=$bad;$ex.Data['ReviewStage']=$bad
  $fault=New-ReviewTransportFault fallback_code fallback_stage $ex
  Assert-True ($fault.Code -ceq 'fallback_code' -and $fault.Stage -ceq 'fallback_stage') 'malformed/non-string Data identifier cannot coerce or replace valid fallback'
 }
 $fault=New-ReviewTransportFault ([ProjectionText]::new()) ([ProjectionText]::new()) ([ProjectionHostileException]::new())
 Assert-True ($fault.Code -ceq 'owned_failure' -and $fault.Stage -ceq 'unknown' -and [ProjectionText]::Calls -eq 0) 'untyped public parameters refuse arbitrary ToString before conversion'
 Assert-True ([ProjectionHostileException]::DataCalls -eq 0 -and [ProjectionHostileException]::HiddenCalls -eq 0 -and $fault.Cause.HResult -is [int]) 'custom virtual Data and hidden base properties never run during projection'
 $native=Get-ReviewSafeCause ([ProjectionHiddenNative]::new())
 Assert-True ($native.NativeError -eq 32 -and [ProjectionHiddenNative]::Calls -eq 0) 'native structural scalar uses original framework getter, not custom hidden property'
 $keyError=[IO.IOException]::new();$keyError.Data.Add([ProjectionKey]::new(),'untrusted');[ProjectionKey]::Calls=0
 $fault=New-ReviewTransportFault fallback_code fallback_stage $keyError
 Assert-True ([ProjectionKey]::Calls -eq 0 -and $fault.Code -ceq 'fallback_code') 'framework Data enumeration never compares arbitrary dictionary keys'
 $ex=[IO.IOException]::new();$ex.Data['ReviewCode']='legitimate_code';$ex.Data['ReviewStage']='legitimate_stage'
 $fault=New-ReviewTransportFault fallback_code fallback_stage $ex
 Assert-True ($fault.Code -ceq 'legitimate_code' -and $fault.Stage -ceq 'legitimate_stage') 'legitimate bounded coded framework exceptions retain operation identity'
 $ex.Data['ReviewStage']=[ProjectionText]::new();$fault=New-ReviewTransportFault fallback_code fallback_stage $ex
 Assert-True ($fault.Code -ceq 'legitimate_code' -and $fault.Stage -ceq 'fallback_stage' -and [ProjectionText]::Calls -eq 0) 'malformed stage retains original stage without losing legitimate code'
 for($i=0;$i -lt 8;$i++){$ex.Data['filler'+$i]=$i};$fault=New-ReviewTransportFault fallback_code fallback_stage $ex
 Assert-True ($fault.Code -ceq 'fallback_code' -and $fault.Stage -ceq 'fallback_stage') 'oversized Data dictionary is refused before enumeration'
 function Invoke-ProjectionWorker {
  param($State,$Arguments)
  try {
   if($Arguments.Hostile){throw [ProjectionHostileException]::new()}
   $error=[IO.IOException]::new('SENSITIVE-WORKER-MESSAGE');$error.Data['ReviewCode']='SENSITIVE-'+('Z'*100000);$error.Data['ReviewStage']=[ProjectionText]::new();throw $error
  }finally{$State['CoreRetired']=$true}
 }
 foreach($hostile in @($false,$true)){
  $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
  $result=Invoke-ReviewOwnedWork -Kind projection -OwnerRegistry $registry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+10L*[Diagnostics.Stopwatch]::Frequency) -WorkerName Invoke-ProjectionWorker -Definitions @{'Invoke-ProjectionWorker'=(Get-Command Invoke-ProjectionWorker).ScriptBlock} -Arguments @{Hostile=$hostile} -State $state
  Assert-True ($result.Failure.Code -ceq 'owned_worker' -and $result.Retired -and $null -eq $result.Result -and $registry.Count -eq 0) 'actual generic worker keeps bounded refusal and original physical retirement'
  Assert-True (($result|ConvertTo-Json -Depth 12 -Compress).Length -lt 4096 -and ($result|ConvertTo-Json -Depth 12 -Compress) -notmatch 'SENSITIVE-') 'actual worker outcome excludes Data payload and arbitrary values'
 }
 Assert-True ([ProjectionHostileException]::DataCalls -eq 0 -and [ProjectionHostileException]::HiddenCalls -eq 0 -and [ProjectionText]::Calls -eq 0) 'worker exception handling never invokes hostile projection callbacks'
 $saved=(Get-Command Start-ReviewOwnedPipelineCreation).ScriptBlock
 $primary=$null
 try{
  function Start-ReviewOwnedPipelineCreation {param($Owner,$Bootstrap,$ArgumentList) [Threading.Tasks.Task[object]]::FromException([ProjectionHostileException]::new())}
  $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
  $result=Invoke-ReviewOwnedWork -Kind projection_observer -OwnerRegistry $registry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+5L*[Diagnostics.Stopwatch]::Frequency) -WorkerName Invoke-ProjectionWorker -Definitions @{} -Arguments @{} -State $state
  Assert-True ($result.Failure.Code -ceq 'owned_creation' -and $result.Retired -and $null -eq $result.Result -and $registry.Count -eq 0) 'controller observes faulted original creation task with bounded structural cause'
  Assert-True ([ProjectionHostileException]::DataCalls -eq 0 -and [ProjectionHostileException]::HiddenCalls -eq 0) 'controller observer avoids custom getters in original task exception chain'
 }catch{$primary=$_;throw}finally{
  try{Set-Item Function:Start-ReviewOwnedPipelineCreation $saved}catch{if($null -ne $primary){$primary.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($_.Exception))}else{throw}}
 }
}elseif($Case -ceq 'metadata'){
 # Prepare the genuine unchanged transport and metadata handles before adding
 # hostile ETS members; the sanitizer must subsequently bypass every member.
 Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $RepoRoot 'gauntlet-review/scripts/review-transport.cs'))) -ErrorAction Stop
 $transport='GauntletTransport.TransportException' -as [type]
 $ctor=$transport.GetConstructor([Reflection.BindingFlags]'NonPublic,Instance',$null,[type[]]@([string],[string],[Exception]),$null)
 $transportError=$ctor.Invoke([object[]]@('transport_code','transport_stage',[ComponentModel.Win32Exception]::new(32)))
 $causeField=$transport.GetField('<Cause>k__BackingField',[Reflection.BindingFlags]'NonPublic,Instance')
 $rawCause=$causeField.GetValue($transportError);$causeType=$rawCause.GetType()
 $typeField=$causeType.GetField('<Type>k__BackingField',[Reflection.BindingFlags]'NonPublic,Instance')
 $dataProperty=[Reflection.RuntimeReflectionExtensions]::GetRuntimeProperty([IO.IOException],'Data')
 $dataMethod=$dataProperty.GetMethod
 $hresultProperty=[Reflection.RuntimeReflectionExtensions]::GetRuntimeProperty([Exception],'HResult')
 $hresultMethod=$hresultProperty.GetMethod
 $jsonProperty=[Reflection.RuntimeReflectionExtensions]::GetRuntimeProperty([Text.Json.JsonException],'LineNumber')
 $targets=@()
 foreach($type in @([IO.IOException],[Exception],$transport,$causeType)){
  foreach($name in @('FullName','Assembly')){$targets+=@{Object=$type;Kind='ScriptProperty';Name=$name}}
  foreach($name in @('GetField','GetProperty','GetMethod')){$targets+=@{Object=$type;Kind='ScriptMethod';Name=$name}}
 }
 foreach($property in @($dataProperty,$hresultProperty,$jsonProperty)){
  foreach($name in @('GetMethod','DeclaringType')){$targets+=@{Object=$property;Kind='ScriptProperty';Name=$name}}
  $targets+=@{Object=$property;Kind='ScriptMethod';Name='GetValue'}
 }
 foreach($method in @($dataMethod,$hresultMethod)){
  $targets+=@{Object=$method;Kind='ScriptProperty';Name='DeclaringType'}
  $targets+=@{Object=$method;Kind='ScriptMethod';Name='Invoke'}
 }
 foreach($field in @($causeField,$typeField)){
  $targets+=@{Object=$field;Kind='ScriptProperty';Name='FieldType'}
  $targets+=@{Object=$field;Kind='ScriptMethod';Name='GetValue'}
 }
 $global:ProjectionMetadataCalls=0
 foreach($target in $targets){$target.Object|Add-Member -MemberType $target.Kind -Name $target.Name -Value {$global:ProjectionMetadataCalls++;throw [InvalidOperationException]::new('SENSITIVE-METADATA-CALLBACK')} -Force}
 $direct=Get-ReviewSafeCause ([IO.IOException]::new())
 Assert-True ($direct.Type -ceq 'System.IO.IOException' -and $direct.HResult -is [int] -and $global:ProjectionMetadataCalls -eq 0) 'direct safe cause bypasses all shared RuntimeType and property metadata members'
 $ordinary=[IO.IOException]::new();$ordinary.Data['ReviewCode']='metadata_code';$ordinary.Data['ReviewStage']='metadata_stage'
 $direct=New-ReviewTransportFault fallback_code fallback_stage $ordinary
 Assert-True ($direct.Code -ceq 'metadata_code' -and $direct.Stage -ceq 'metadata_stage' -and $global:ProjectionMetadataCalls -eq 0) 'direct coded fault bypasses RuntimeType Assembly/GetProperty and PropertyInfo/MethodInfo members'
 $projected=New-ReviewTransportFault fallback_code fallback_stage $transportError
 Assert-True ($projected.Code -ceq 'transport_code' -and $projected.Cause.NativeError -eq 32 -and $global:ProjectionMetadataCalls -eq 0) 'genuine compatibility projection bypasses FieldInfo FieldType/GetValue and cause RuntimeType members'
 foreach($numeric in @([ComponentModel.Win32Exception]::new(32),[Net.Sockets.SocketException]::new(10054),[Text.Json.JsonException]::new('SENSITIVE-JSON','path',11,22),[Net.Http.HttpRequestException]::new('SENSITIVE-HTTP',$null,[Net.HttpStatusCode]::Forbidden))){
  $safe=Get-ReviewSafeCause $numeric
  if($numeric -is [Text.Json.JsonException]){Assert-True ($safe.JsonLine -eq 11 -and $safe.JsonByte -eq 22) 'fixed nullable JSON delegate preserves numeric cause under metadata annotations'}
  elseif($numeric -is [Net.Sockets.SocketException]){Assert-Eq $safe.SocketError 10054 'fixed socket delegate preserves numeric cause under metadata annotations'}
  elseif($numeric -is [ComponentModel.Win32Exception]){Assert-Eq $safe.NativeError 32 'fixed native delegate preserves numeric cause under metadata annotations'}
  else{Assert-Eq $safe.HttpStatus 403 'fixed nullable HTTP delegate preserves numeric cause under metadata annotations'}
 }
 function Invoke-MetadataProjectionWorker {
  param($State,$Arguments)
  try{
   $State['MetadataCallbacks']=0
   $callback={$State['MetadataCallbacks']++;throw [InvalidOperationException]::new('SENSITIVE-WORKER-METADATA')}.GetNewClosure()
   [IO.IOException]|Add-Member -MemberType ScriptProperty -Name FullName -Value $callback -Force
   $error=[IO.IOException]::new('SENSITIVE-METADATA-WORKER');$error.Data['ReviewCode']='metadata_worker';$error.Data['ReviewStage']='metadata_action';throw $error
  }finally{$State['CoreRetired']=$true}
 }
 $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal)
 $result=Invoke-ReviewOwnedWork -Kind metadata -OwnerRegistry $registry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+10L*[Diagnostics.Stopwatch]::Frequency) -WorkerName Invoke-MetadataProjectionWorker -Definitions @{'Invoke-MetadataProjectionWorker'=(Get-Command Invoke-MetadataProjectionWorker).ScriptBlock} -Arguments @{} -State $state
 Assert-True ($result.Failure.Code -ceq 'metadata_worker' -and $result.Failure.Stage -ceq 'metadata_action' -and $result.Retired -and $null -eq $result.Result -and $registry.Count -eq 0 -and $state['MetadataCallbacks'] -eq 0 -and $global:ProjectionMetadataCalls -eq 0) 'actual worker fault projection invokes no metadata callbacks and physically retires original work'
 # Global System.Type lookup metadata is shared by unrelated original worker
 # startup code. Add it only after real worker creation has completed, so these
 # controls exercise the two fault projection boundaries rather than bootstrap.
 foreach($name in @('GetField','GetProperty','GetMethod')){[type]|Add-Member -MemberType ScriptMethod -Name $name -Value {$global:ProjectionMetadataCalls++;throw [InvalidOperationException]::new('SENSITIVE-TYPE-LOOKUP')} -Force}
 foreach($name in @('FullName','Assembly')){[type]|Add-Member -MemberType ScriptProperty -Name $name -Value {$global:ProjectionMetadataCalls++;throw [InvalidOperationException]::new('SENSITIVE-TYPE-PROPERTY')} -Force}
 $globalMetadata=New-ReviewTransportFault fallback_code fallback_stage $ordinary
 Assert-True ($globalMetadata.Code -ceq 'metadata_code' -and $global:ProjectionMetadataCalls -eq 0) 'fault delegate bootstrap uses only static CLR lookup even under annotated global Type metadata'
 $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal);$owner=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal)
 $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+10L*[Diagnostics.Stopwatch]::Frequency
 $state['Deadline']=$deadline;$state['Abandoned']=$false;$state['CoreRetired']=$false;$state['OwnedWorkOwner']=$owner
 $creation=[Threading.Tasks.Task[object]]::FromException($ordinary)
 foreach($pair in @{State=$state;Deadline=$deadline;Abandoned=$false;TimedOut=$false;Submitted=$false;StartupSettled=$true;StartupPublishPending=$true;StartupStage='worker_create';RetirementConfirmed=$false;Pipeline=$null;Output=$null;CreationTask=$creation;InvokeTask=$null;DisposeTask=$null;Failure=$null;CleanupFailures=@()}.GetEnumerator()){$owner[$pair.Key]=$pair.Value}
 $registry.Add('original',$owner);$observed=Complete-ReviewOwnedWork -OwnerRegistry $registry -Token original
 Assert-True ($observed.Failure.Code -ceq 'metadata_code' -and $observed.Retired -and $null -eq $observed.Result -and $registry.Count -eq 0 -and $global:ProjectionMetadataCalls -eq 0) 'actual controller observes original faulted creation task without shared metadata callbacks'
 Assert-True (($observed|ConvertTo-Json -Depth 12 -Compress) -notmatch 'SENSITIVE-|FieldInfo|PropertyInfo|MethodInfo|RuntimeType') 'public controller outcome retains bounded structural diagnostics without raw metadata'
 Assert-Eq $global:ProjectionMetadataCalls 0 'all annotated reflection metadata siblings remain untouched through all fault projections'

}elseif($Case -ceq 'foreign'){
Add-Type @'
using System;
using System.Collections.Generic;
namespace GauntletTransport {
 public class TransportException:Exception {
  public static int Calls;
  public string Code {get{Calls++;throw new InvalidOperationException("SENSITIVE-CODE-GETTER");}}
  public string Stage {get{Calls++;throw new InvalidOperationException("SENSITIVE-STAGE-GETTER");}}
  public object Cause {get;set;}=new Dictionary<string,object>{{"Secret","SENSITIVE-CAUSE-"+new string('Z',100000)}};
 }
}
'@
 $fault=New-ReviewTransportFault fallback_code fallback_stage ([GauntletTransport.TransportException]::new())
 Assert-True ($fault.Code -ceq 'fallback_code' -and $fault.Stage -ceq 'fallback_stage' -and [GauntletTransport.TransportException]::Calls -eq 0) 'same-name foreign exception cannot invoke Code/Stage getters or override fallbacks'
 Assert-True (($fault|ConvertTo-Json -Depth 12 -Compress).Length -lt 2048 -and ($fault|ConvertTo-Json -Depth 12 -Compress) -notmatch 'SENSITIVE-') 'raw foreign Cause graph is never published or retained in public fault'
}else{
 # Compile the entire unchanged dormant transport source, rather than the
 # unchanged production initializer with its independently deferred .NET6 bug.
 Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $RepoRoot 'gauntlet-review/scripts/review-transport.cs'))) -ErrorAction Stop
 $transport='GauntletTransport.TransportException' -as [type]
 $ctor=$transport.GetConstructor([Reflection.BindingFlags]'NonPublic,Instance',$null,[type[]]@([string],[string],[Exception]),$null)
 $causes=@([ComponentModel.Win32Exception]::new(32),[Net.Sockets.SocketException]::new(10054),[Text.Json.JsonException]::new('SENSITIVE-JSON','path',11,22),[Net.Http.HttpRequestException]::new('SENSITIVE-HTTP',$null,[Net.HttpStatusCode]::Forbidden))
 foreach($cause in $causes){
  $actual=$ctor.Invoke([object[]]@('transport_code','transport_stage',$cause));$fault=New-ReviewTransportFault fallback_code fallback_stage $actual
  Assert-True ($fault.Code -ceq 'transport_code' -and $fault.Stage -ceq 'transport_stage' -and $fault.Cause.Type -ceq $cause.GetType().FullName) 'genuine compiled transport preserves distinct typed cause without InnerException'
  Assert-True (($fault|ConvertTo-Json -Depth 12 -Compress) -notmatch 'SENSITIVE-|Message|StackTrace') 'genuine transport structural copy excludes raw messages'
  if($cause -is [Text.Json.JsonException]){Assert-True ($fault.Cause.JsonLine -eq 11 -and $fault.Cause.JsonByte -eq 22) 'genuine JSON source locations survive structural copy'}
  elseif($cause -is [Net.Sockets.SocketException]){Assert-Eq $fault.Cause.SocketError 10054 'genuine socket numeric error survives structural copy'}
  elseif($cause -is [ComponentModel.Win32Exception]){Assert-Eq $fault.Cause.NativeError 32 'genuine native numeric error survives structural copy'}
  elseif($cause -is [Net.Http.HttpRequestException]){Assert-Eq $fault.Cause.HttpStatus 403 'genuine HTTP status survives structural copy'}
 }
 $global:ProjectionEtsCalls=0
 $etsTransport=$ctor.Invoke([object[]]@('transport_code','transport_stage',[ComponentModel.Win32Exception]::new(32)))
 $etsCause=$transport.GetField('<Cause>k__BackingField',[Reflection.BindingFlags]'NonPublic,Instance').GetValue($etsTransport)
 foreach($entry in @(@{Target=$etsTransport;Name='Code';Value='transport_code'},@{Target=$etsTransport;Name='Stage';Value='transport_stage'},@{Target=$etsCause;Name='Type';Value='System.ComponentModel.Win32Exception'},@{Target=$etsCause;Name='HeaderNameSha256';Value=('a'*64)})){
  $wrapped=[PSObject]::AsPSObject($entry.Value)
  $wrapped|Add-Member -MemberType ScriptProperty -Name Length -Value {$global:ProjectionEtsCalls++;throw 'SENSITIVE-TRANSPORT-ETS-LENGTH'} -Force
  $wrapped|Add-Member -MemberType ScriptMethod -Name ToString -Value {$global:ProjectionEtsCalls++;throw 'SENSITIVE-TRANSPORT-ETS-TOSTRING'} -Force
  $entry.Target.GetType().GetField(('<'+$entry.Name+'>k__BackingField'),[Reflection.BindingFlags]'NonPublic,Instance').SetValue($entry.Target,$wrapped)
 }
 $etsProjected=New-ReviewTransportFault fallback_code fallback_stage $etsTransport
 Assert-True ($etsProjected.Code -ceq 'transport_code' -and $etsProjected.Stage -ceq 'transport_stage' -and $etsProjected.Cause.NativeError -eq 32 -and $global:ProjectionEtsCalls -eq 0) 'genuine transport identifier/type/hash string fields use no ETS callbacks'
 Assert-True ($etsProjected.Code.Length -eq 14 -and $etsProjected.Stage.Length -eq 15 -and $etsProjected.Cause.Type.Length -eq 36 -and $etsProjected.Cause.HeaderNameSha256.Length -eq 64 -and $global:ProjectionEtsCalls -eq 0) 'genuine transport text fields are fresh primitive copies without ETS members'
 $deep=[IO.IOException]::new('SENSITIVE-INNER');for($i=0;$i -lt 8;$i++){$deep=[IO.IOException]::new('SENSITIVE-INNER',$deep)}
 $actual=$ctor.Invoke([object[]]@('transport_code','transport_stage',$deep));$fault=New-ReviewTransportFault fallback_code fallback_stage $actual
 Assert-True ($null -ne $fault.Cause.Inner.Inner -and $null -eq $fault.Cause.Inner.Inner.Inner -and $fault.Cause.Inner.Inner.OmittedInnerCauses -gt 0) 'genuine transport cause depth and omitted count remain bounded'
 foreach($malformedControl in @(@{Name='Type';Value=('X'*100000)},@{Name='HeaderNameSha256';Value='SENSITIVE-HEADER'},@{Name='OmittedInnerCauses';Value=-1})){
  $malformed=$ctor.Invoke([object[]]@('transport_code','transport_stage',[ComponentModel.Win32Exception]::new(32)))
  $rawCause=$transport.GetField('<Cause>k__BackingField',[Reflection.BindingFlags]'NonPublic,Instance').GetValue($malformed)
  $rawCause.GetType().GetField(('<'+$malformedControl.Name+'>k__BackingField'),[Reflection.BindingFlags]'NonPublic,Instance').SetValue($rawCause,$malformedControl.Value)
  $refused=New-ReviewTransportFault fallback_code fallback_stage $malformed
  Assert-True ($refused.Code -ceq 'fallback_code' -and ($refused|ConvertTo-Json -Depth 12 -Compress).Length -lt 4096 -and ($refused|ConvertTo-Json -Depth 12 -Compress) -notmatch 'SENSITIVE-') ('malformed transport '+$malformedControl.Name+' refuses raw fields with bounded fallback')
 }
 $transport.GetField('<Code>k__BackingField',[Reflection.BindingFlags]'NonPublic,Instance').SetValue($actual,'SENSITIVE-'+('X'*100000))
 $fault=New-ReviewTransportFault fallback_code fallback_stage $actual
 Assert-True ($fault.Code -ceq 'fallback_code' -and ($fault|ConvertTo-Json -Depth 12 -Compress).Length -lt 4096) 'malformed genuine backing identifier is refused without raw retention'
}
Assert-True ($before -eq (Get-FileHash (Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1')).Hash) 'projection fixture leaves exact candidate source unchanged'
Write-TestResult
