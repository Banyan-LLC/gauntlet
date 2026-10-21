param([Parameter(Mandatory)][string]$RepoRoot,[ValidateRange(1,15)][int]$Depth=15)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. (Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1')
$source=Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1'
$before=(Get-FileHash $source).Hash
Add-Type @'
using System;
using System.Reflection;
using System.Reflection.Emit;
public class TypeBoundError<A,B>:Exception {
 public static int Callbacks;
 public override System.Collections.IDictionary Data {get{Callbacks++;throw new InvalidOperationException("SENSITIVE");}}
}
public class TypeBoundPair<A,B>{}
public class TypeBoundCause<A,B>{}
public class TypeBoundData<A,B>:System.Collections.Hashtable {
 public override int Count {get{TypeBoundFixtures.DataCallbacks++;throw new InvalidOperationException("SENSITIVE-DATA-COUNT");}}
 public override System.Collections.IDictionaryEnumerator GetEnumerator(){TypeBoundFixtures.DataCallbacks++;throw new InvalidOperationException("SENSITIVE-DATA-ENUMERATOR");}
}
public class TypeBoundEnumerableError<T>:Exception,System.Collections.IEnumerable {
 public static int EnumeratorCalls;
 public System.Collections.IEnumerator GetEnumerator(){EnumeratorCalls++;throw new InvalidOperationException("Enumerable observation refused");}
}
public static class TypeBoundFixtures {
 static int serial;
 public static int DataCallbacks;
 public static Type Graph(int seed,int depth){
  Type t=new[]{typeof(int),typeof(string),typeof(long),typeof(byte),typeof(short),typeof(decimal),typeof(double),typeof(float),typeof(bool),typeof(char),typeof(uint),typeof(ulong),typeof(ushort),typeof(sbyte)}[seed];
  for(int i=0;i<depth;i++)t=typeof(TypeBoundPair<,>).MakeGenericType(t,t);
  return t;
 }
 public static Exception Declared(int length,bool nested){
  var assembly=AssemblyBuilder.DefineDynamicAssembly(new AssemblyName("DeclaredAssembly"+(++serial)),AssemblyBuilderAccess.Run);
  var module=assembly.DefineDynamicModule("main");
  if(nested){var outer=module.DefineType("Outer",TypeAttributes.Public);var child=outer.DefineNestedType("Inner",TypeAttributes.NestedPublic,typeof(Exception));var top=outer.CreateTypeInfo();return (Exception)Activator.CreateInstance(child.CreateTypeInfo().AsType());}
  return (Exception)Activator.CreateInstance(module.DefineType(new string('L',length),TypeAttributes.Public,typeof(Exception)).CreateTypeInfo().AsType());
 }
 public static Exception Error(int seed,int depth){
  var t=Graph(seed,depth);return (Exception)Activator.CreateInstance(typeof(TypeBoundError<,>).MakeGenericType(t,t));
 }
 public static Exception DataError(int seed,int depth){
  // The original fixed Exception.Data getter returns this stored IDictionary.
  // No override is involved; inspecting its type must precede every rejection.
  var graph=Graph(seed,depth);var data=Activator.CreateInstance(typeof(TypeBoundData<,>).MakeGenericType(graph,graph));
  var error=new System.IO.IOException("SENSITIVE-DATA");
  typeof(Exception).GetField("_data",BindingFlags.NonPublic|BindingFlags.Instance).SetValue(error,data);
  if(!Object.ReferenceEquals(error.Data,data))throw new InvalidOperationException("Original framework Data storage differs");
  return error;
 }
 static FieldBuilder Field(TypeBuilder t,string name,Type type){return t.DefineField("<"+name+">k__BackingField",type,FieldAttributes.Private);}
 public static Exception Transport(string mode,int seed,int depth){
  var assembly=AssemblyBuilder.DefineDynamicAssembly(new AssemblyName("TypeBoundAssembly"+(++serial)),AssemblyBuilderAccess.Run);
  var module=assembly.DefineDynamicModule("main");var graph=Graph(seed,depth);Type causeType,valueType;
  if(mode=="causevalue"){
   var basis=module.DefineType("GauntletTransport.SanitizedCause",TypeAttributes.Public);causeType=basis.CreateTypeInfo().AsType();
   var sub=module.DefineType("DerivedCause",TypeAttributes.Public,causeType);sub.DefineGenericParameters("A","B");valueType=sub.CreateTypeInfo().AsType().MakeGenericType(graph,graph);
  }else{
   causeType=mode=="arrayfield"?graph.MakeArrayType():graph;valueType=null;
  }
  var transport=module.DefineType("GauntletTransport.TransportException",TypeAttributes.Public,typeof(Exception));
  Field(transport,"Code",typeof(string));Field(transport,"Stage",typeof(string));Field(transport,"Cause",causeType);
  var type=transport.CreateTypeInfo().AsType();var error=(Exception)Activator.CreateInstance(type);
  type.GetField("<Code>k__BackingField",BindingFlags.NonPublic|BindingFlags.Instance).SetValue(error,"unsafe_code");
  type.GetField("<Stage>k__BackingField",BindingFlags.NonPublic|BindingFlags.Instance).SetValue(error,"unsafe_stage");
  if(valueType!=null)type.GetField("<Cause>k__BackingField",BindingFlags.NonPublic|BindingFlags.Instance).SetValue(error,Activator.CreateInstance(valueType));
  return error;
 }
}
'@
$global:TypeBoundMetadataCallbacks=0
foreach($name in @('IsGenericType','HasElementType','IsNested','Name','Namespace')){
 [type]|Add-Member -MemberType ScriptProperty -Name $name -Value {$global:TypeBoundMetadataCallbacks++;throw 'SENSITIVE-METADATA'} -Force
}
# Removing shape admission must fail this observable public fallback control.
$short=[TypeBoundFixtures]::Error(0,0)
$safe=Get-ReviewSafeCause $short
Assert-Eq $safe.Type 'System.Exception' 'constructed generic exception is refused before name formatting'
Assert-True ($safe.HResult -is [int] -and [TypeBoundError[int,int]]::Callbacks -eq 0) 'generic refusal retains primitive HResult without virtual Data'
foreach($declared in @([TypeBoundFixtures]::Declared(512,$false),[TypeBoundFixtures]::Declared(12,$true))){
 $projected=Get-ReviewSafeCause $declared
 Assert-Eq $projected.Type 'System.Exception' 'oversized or nested declared metadata uses fixed fallback'
}
$enumerable=[TypeBoundEnumerableError[int]]::new()
$enumCause=Get-ReviewSafeCause $enumerable
$enumFault=New-ReviewTransportFault fallback_code fallback_stage $enumerable
$enumInner=Get-ReviewSafeCause ([IO.IOException]::new('fixed outer',$enumerable))
Assert-True ($enumCause.Type -ceq 'System.Exception' -and $enumFault.Cause.Type -ceq 'System.Exception' -and $enumInner.Inner.Type -ceq 'System.Exception') 'constructed enumerable exceptions remain primitive direct and recursive causes'
Assert-Eq ([TypeBoundEnumerableError[int]]::EnumeratorCalls) 0 'delegate argument packs and recursive observations never enumerate an arbitrary exception'
# Warm private delegate/bootstrap/owner observation paths before measuring only
# each fresh hostile value. No FullName/ToString is requested on test Type DAGs.
$null=Get-ReviewSafeCause ([IO.IOException]::new())
$null=New-ReviewTransportFault fallback_code fallback_stage ([IO.IOException]::new())
function Observe-OriginalFault([Threading.Tasks.Task]$creation){
 $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
 $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal)
 $owner=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal)
 $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+10L*[Diagnostics.Stopwatch]::Frequency
 $state['Deadline']=$deadline;$state['Abandoned']=$false;$state['CoreRetired']=$false;$state['OwnedWorkOwner']=$owner
 foreach($pair in @{State=$state;Deadline=$deadline;Abandoned=$false;TimedOut=$false;Submitted=$false;StartupSettled=$true;StartupPublishPending=$true;StartupStage='worker_create';RetirementConfirmed=$false;Pipeline=$null;Output=$null;CreationTask=$creation;InvokeTask=$null;DisposeTask=$null;Failure=$null;CleanupFailures=@()}.GetEnumerator()){$owner[$pair.Key]=$pair.Value}
 $registry.Add('original',$owner)
 $result=Complete-ReviewOwnedWork -OwnerRegistry $registry -Token original
 Assert-True ($result.Retired -and $registry.Count -eq 0 -and [object]::ReferenceEquals($owner['CreationTask'],$creation) -and $owner['Deadline'] -eq $deadline -and -not $owner['TimedOut'] -and $null -eq $result.Result) 'original faulted task retires its own unchanged owner and deadline'
 return $result
}
$null=Observe-OriginalFault ([Threading.Tasks.Task[object]]::FromException([IO.IOException]::new()))
$seed=0
foreach($kind in @('exception','causefield','arrayfield','causevalue','data')){
 foreach($boundary in @('direct','observer')){
  $FaultException=if($kind -eq 'exception'){[TypeBoundFixtures]::Error($seed,$Depth)}elseif($kind -eq 'data'){[TypeBoundFixtures]::DataError($seed,$Depth)}else{[TypeBoundFixtures]::Transport($kind,$seed,$Depth)}
  $seed++
  # Task construction is outside the controller projection allocation sample.
  # The exact already-faulted original task is the observer input.
  $preparedTask=if($boundary -eq 'observer'){[Threading.Tasks.Task[object]]::FromException($FaultException)}else{$null}
  $start=[GC]::GetAllocatedBytesForCurrentThread()
  if($boundary -eq 'direct'){
   $projected=New-ReviewTransportFault fallback_code fallback_stage $FaultException
  }else{
   $observed=Observe-OriginalFault $preparedTask;$projected=$observed.Failure
  }
  $allocated=[GC]::GetAllocatedBytesForCurrentThread()-$start
  Write-Host ($kind+' '+$boundary+' allocation_bytes='+$allocated)
  Assert-True ($allocated -lt 4194304L) ($kind+' '+$boundary+' refuses unsafe shape before allocating formatted generic name')
  $expectedCode=if($boundary -eq 'direct'){'fallback_code'}else{'owned_creation'}
  Assert-Eq $projected.Code $expectedCode ($kind+' '+$boundary+' preserves original failure code')
  Assert-True (($projected|ConvertTo-Json -Depth 12 -Compress).Length -lt 4096 -and $projected.Cause.HResult -is [int]) ($kind+' '+$boundary+' publishes bounded primitive cause')
  if($kind -eq 'data'){
   $frameworkCause=if($boundary -eq 'observer'){$projected.Cause.Inner}else{$projected.Cause}
   Assert-Eq $frameworkCause.Type 'System.IO.IOException' ($boundary+' exact framework exception keeps primitive original cause after rejecting generic Data')
   Assert-Eq ([TypeBoundFixtures]::DataCallbacks) 0 ($boundary+' generic Data type refusal never invokes collection Count or enumerator')
  }
 }
}
# Exercise Get-ReviewSafeCause without NewFault on a separate uncached graph.
$directError=[TypeBoundFixtures]::Error(12,$Depth)
$start=[GC]::GetAllocatedBytesForCurrentThread()
$directCause=Get-ReviewSafeCause $directError
$allocated=[GC]::GetAllocatedBytesForCurrentThread()-$start
Write-Host ('safe-cause direct allocation_bytes='+$allocated)
Assert-True ($allocated -lt 4194304L -and $directCause.Type -ceq 'System.Exception') 'safe-cause direct rejects generic formatter allocation before fallback'
$inner=Get-ReviewSafeCause ([IO.IOException]::new('SENSITIVE',$directError))
Assert-True ($inner.Inner.Type -ceq 'System.Exception' -and $inner.Type -ceq 'System.IO.IOException') 'recursive exception causes enforce the same shape admission'
Assert-Eq $global:TypeBoundMetadataCallbacks 0 'new shape metadata inspection bypasses ETS callbacks'
Assert-Eq ([TypeBoundError[int,int]]::Callbacks) 0 'exception callback remains untouched'
Assert-Eq ((Get-FileHash $source).Hash) $before 'type-bound fixture preserves exact tested source'
Write-TestResult
