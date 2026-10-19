# Dormant original-owner process definitions, extracted from 63dbc50992ce0ad792382900666440e95d7178bd.
# Production entry points do not load this file. Only a fresh isolated test child may load it
# until a separately certified activation assembles the matched runtime.
# Keep this one definition AST intact: native workers copy its complete function pack.
Set-StrictMode -Version Latest

function Initialize-ReviewOwnedStreams {
    # Called only by the retained original invocation before the caller action.
    $source=@'
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Management.Automation;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
namespace GauntletOwnedWork {
 public sealed class StreamGuard {
  public static string SourceIdentity {get{return "__GAUNTLET_STREAM_SOURCE_IDENTITY__";}}
  public const long ChannelEmissionBytes=32768, AggregateEmissionBytes=65536;
  // Collector state is fixed: seven counters/delegates and winner-only safe
  // error/refusal DTO builders. Losers allocate no diagnostic DTO. Cumulative
  // admission charges at least256bytes/record, so at most128records/channel
  // and256total can ever be inserted, even with concurrent producers. List
  // capacities/references are therefore bounded, without ReadAll/ToArray copies.
  // DataAdded removes raw references synchronously before a producer returns;
  // arbitrary incoming worker object graphs are neither copied nor kept after
  // that callback. Structural DTOs keep no raw message/target/exception graph.
  // Bounds cover backing capacities, delegates/arrays and overlapping builder
  // DTOs. Arbitrary memory allocated by a worker is not collector allocation.
  public const long RecordTransferBytes=4096, ChannelRetainedBytes=16384, AggregateRetainedBytes=131072;
  readonly ConcurrentDictionary<string,object> owner,state;
  readonly object gate=new object();
  readonly long[] admitted=new long[7],counts=new long[7];
  long total;int stopped,errorClaim;
  readonly Func<AsyncCallback,object,Task> stop;
  ReadOnlyDictionary<string,object> firstError,failure;
  public ReadOnlyDictionary<string,object> FirstError {get{return Volatile.Read(ref firstError);}}
  public ReadOnlyDictionary<string,object> Failure {get{return Volatile.Read(ref failure);}}
  public long ErrorCount {get{return Interlocked.Read(ref counts[1]);}}
  public long TotalAdmittedBytes {get{return Interlocked.Read(ref total);}}
  public long ChannelAdmittedBytes(int channel){return Interlocked.Read(ref admitted[channel]);}
  public long ChannelCount(int channel){return Interlocked.Read(ref counts[channel]);}
  static ReadOnlyDictionary<string,object> Record(Dictionary<string,object> values){return new ReadOnlyDictionary<string,object>(values);}
  static bool Code(string value){if(value==null||value.Length==0||value.Length>64||value[0]<'a'||value[0]>'z')return false;foreach(char c in value)if((c<'a'||c>'z')&&(c<'0'||c>'9')&&c!='_')return false;return true;}
  // No exception or diagnostic formatter participates in admission. These
  // fixed runtime fields expose existing primitive strings without invoking a
  // virtual Message/Data getter, expanding an aggregate, or copying its text.
  // A missing/changed runtime storage contract refuses initialization/admission.
  static FieldInfo StoredField(Type type,string name,Type expected){
   var field=type.GetField(name,BindingFlags.Instance|BindingFlags.NonPublic|BindingFlags.DeclaredOnly);
   if(field==null||field.FieldType!=expected)throw new InvalidOperationException("Unsupported stored diagnostic contract");
   return field;
  }
  static readonly FieldInfo messageField=StoredField(typeof(Exception),"_message",typeof(string));
  static readonly FieldInfo dataField=StoredField(typeof(Exception),"_data",typeof(System.Collections.IDictionary));
  static readonly FieldInfo jsonMessageField=StoredField(typeof(System.Text.Json.JsonException),"_message",typeof(string));
  static readonly FieldInfo errorIdField=StoredField(typeof(ErrorRecord),"_errorId",typeof(string));
  static readonly FieldInfo serializedErrorIdField=StoredField(typeof(ErrorRecord),"_serializedFullyQualifiedErrorId",typeof(string));
  static readonly FieldInfo detailsMessageField=StoredField(typeof(ErrorDetails),"_message",typeof(string));
  static readonly FieldInfo detailsActionField=StoredField(typeof(ErrorDetails),"_recommendedAction",typeof(string));
  static readonly Type dataType=typeof(Exception).Assembly.GetType("System.Collections.ListDictionaryInternal",true);
  static bool TrustedException(Exception error){
   var type=error.GetType();var assembly=type.Assembly;
   if(!(assembly==typeof(Exception).Assembly||assembly==typeof(RuntimeException).Assembly||assembly==typeof(Win32Exception).Assembly||assembly==typeof(System.Net.Sockets.SocketException).Assembly||assembly==typeof(System.Net.Http.HttpRequestException).Assembly||assembly==typeof(System.Text.Json.JsonException).Assembly))return false;
   // These two exact numeric-cause types override Message. Their fixed stored
   // strings/numeric fields are handled explicitly; neither getter is called.
   if(type==typeof(System.Net.Sockets.SocketException)||type==typeof(System.Text.Json.JsonException))return true;
   // Reject AggregateException and every other composite/overridden producer
   // before reading diagnostic storage or walking its first InnerException.
   return type.GetProperty("Message").GetMethod.DeclaringType==typeof(Exception)&&type.GetProperty("Data").GetMethod.DeclaringType==typeof(Exception);
  }
  static System.Collections.IDictionary SafeData(Exception error){
   var data=(System.Collections.IDictionary)dataField.GetValue(error);
   if(data==null)return null;
   if(data.GetType()!=dataType||data.Count>8)throw new InvalidOperationException("Unsupported exception data");
   int count=0;
   foreach(System.Collections.DictionaryEntry pair in data){
    if(++count>8||!(pair.Key is string key)||key.Length>64)throw new InvalidOperationException("Unsupported exception data");
    if(pair.Value!=null&&!(pair.Value is int)&&!(pair.Value is long)&&!(pair.Value is bool)&&!(pair.Value is string))throw new InvalidOperationException("Unsupported exception data graph");
    if(pair.Value is string value&&value.Length>64)throw new InvalidOperationException("Unsupported exception data text");
   }
   return data;
  }
  static ReadOnlyDictionary<string,object> Fault(string code,string stage,Exception error){
   Exception cause=error;
   try{
    for(int i=0;i<8&&cause!=null;i++){
     if(!TrustedException(cause)){cause=null;break;}
     // Repeat structural validation here: Fault also handles stop failures,
     // and a worker may mutate its Data after the earlier admission check.
     // Never call Contains/indexers, which dispatch Equals on arbitrary keys.
     var data=SafeData(cause);string safeCode=null,safeStage=null;
     if(data!=null){
      int count=0;
      foreach(System.Collections.DictionaryEntry pair in data){
       if(++count>8||!(pair.Key is string key))throw new InvalidOperationException("Unsupported exception data");
       if(String.Equals(key,"ReviewCode",StringComparison.Ordinal)&&pair.Value is string c&&Code(c))safeCode=c;
       if(String.Equals(key,"ReviewStage",StringComparison.Ordinal)&&pair.Value is string s&&Code(s))safeStage=s;
      }
     }
     if(safeCode!=null){code=safeCode;if(safeStage!=null)stage=safeStage;break;}
     if(cause.InnerException==null)break;cause=cause.InnerException;
    }
   }catch{cause=null;}
   string type=cause==null?null:cause.GetType().FullName;
   if(type!=null&&(type.Length>256||!SafeType(type)))type="System.Exception";
   object safe=cause==null?null:Record(new Dictionary<string,object>(StringComparer.Ordinal){
    {"Type",type},{"HResult",cause.HResult},{"JsonLine",cause is System.Text.Json.JsonException json?(object)json.LineNumber:null},{"JsonByte",cause is System.Text.Json.JsonException jsonByte?(object)jsonByte.BytePositionInLine:null},{"SocketError",cause is System.Net.Sockets.SocketException socket?(object)(int)socket.SocketErrorCode:null},{"HttpStatus",cause is System.Net.Http.HttpRequestException http&&http.StatusCode.HasValue?(object)(int)http.StatusCode.Value:null},
    {"NativeError",cause is Win32Exception native?(object)native.NativeErrorCode:null},{"Inner",null},{"OmittedInnerCauses",cause.InnerException==null?0:1}});
   return Record(new Dictionary<string,object>(StringComparer.Ordinal){{"Code",code},{"Stage",stage},{"Cause",safe}});
  }
  static bool SafeType(string text){foreach(char c in text)if(!((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||"_.+`[], ".IndexOf(c)>=0))return false;return true;}
  static long TextBytes(string text){return text==null?0:checked((long)text.Length*2);}
  static long Charge(int channel,object item){
   const long header=256;
   switch(channel){
    case 1:
     var e=(ErrorRecord)item;
     // A target/message-data graph is not an admitted diagnostic payload.
     if(e.TargetObject!=null)throw new InvalidOperationException("Unsupported error target graph");
     var ex=e.Exception;
     long exceptionBytes=0;
     for(int depth=0;ex!=null;depth++,ex=ex.InnerException){
      if(depth>=8||!TrustedException(ex))throw new InvalidOperationException("Unsupported exception graph");
      var data=SafeData(ex);
      // Data remains worker-mutable after SafeData returns. Bound and
      // validate this consumption independently; earlier validation is not
      // authority for a later enumeration of the same mutable dictionary.
      int dataCount=0;
      if(data!=null)foreach(System.Collections.DictionaryEntry pair in data){
       if(++dataCount>8||!(pair.Key is string key)||key.Length>64)throw new InvalidOperationException("Unsupported exception data");
       if(pair.Value!=null&&!(pair.Value is int)&&!(pair.Value is long)&&!(pair.Value is bool)&&!(pair.Value is string))throw new InvalidOperationException("Unsupported exception data graph");
       if(pair.Value is string value&&value.Length>64)throw new InvalidOperationException("Unsupported exception data text");
       exceptionBytes+=TextBytes(key)+TextBytes(pair.Value as string);
      }
      exceptionBytes+=TextBytes((string)messageField.GetValue(ex));
      if(ex.GetType()==typeof(System.Text.Json.JsonException)){
       exceptionBytes+=TextBytes((string)jsonMessageField.GetValue(ex))+TextBytes(((System.Text.Json.JsonException)ex).Path);
      }
     }
     var details=e.ErrorDetails;
     // FullyQualifiedErrorId may construct text from invocation metadata.
     // Charge its existing stored inputs instead; never invoke that formatter.
     return header+exceptionBytes+TextBytes((string)errorIdField.GetValue(e))+TextBytes((string)serializedErrorIdField.GetValue(e))+
      (details==null?0:TextBytes((string)detailsMessageField.GetValue(details))+TextBytes((string)detailsActionField.GetValue(details)));

    case 2:return header+TextBytes(((WarningRecord)item).Message);
    case 3:return header+TextBytes(((VerboseRecord)item).Message);
    case 4:return header+TextBytes(((DebugRecord)item).Message);
    case 5:
     var info=(InformationRecord)item;
     if(info.MessageData!=null&&!(info.MessageData is string))throw new InvalidOperationException("Unsupported information graph");
     if(info.Tags.Count>16)throw new InvalidOperationException("Unsupported information tags");
     long bytes=header+TextBytes((string)info.MessageData)+TextBytes(info.Source);
     int tagCount=0;foreach(var tag in info.Tags){if(++tagCount>16)throw new InvalidOperationException("Unsupported information tags");if(tag!=null&&tag.Length>64)throw new InvalidOperationException("Unsupported information tag");bytes+=TextBytes(tag);}
     return bytes;
    case 6:
     var p=(ProgressRecord)item;return header+TextBytes(p.Activity)+TextBytes(p.StatusDescription)+TextBytes(p.CurrentOperation);
    default:return 0;
   }
  }
  void Refuse(string code){
   if(Interlocked.CompareExchange(ref stopped,1,0)!=0)return;
   owner["StopRequested"]=true;owner["Abandoned"]=true;state["Abandoned"]=true;
   var value=Fault(code,"worker_stream",null);
   owner.TryAdd("StreamFailure",value);Volatile.Write(ref failure,value);
   try{owner["StopTask"]=stop(null,null);}
   catch(Exception error){owner.TryAdd("StopFailure",Fault("owned_stop","worker_stop",error));}
  }
  void Adding(int channel,DataAddingEventArgs args){
   if(Volatile.Read(ref stopped)!=0)throw new PipelineStoppedException();
   if(channel==0){Refuse("owned_unexpected_output");throw new PipelineStoppedException();}
   long charge;
   try{charge=Charge(channel,args.ItemAdded);}catch{Refuse("owned_stream_shape");throw new PipelineStoppedException();}
   bool entered=Monitor.TryEnter(gate),overflow=false;
   if(!entered){Refuse("owned_stream_busy");throw new PipelineStoppedException();}
   try{
    if(charge>RecordTransferBytes||charge>ChannelEmissionBytes-admitted[channel]||charge>AggregateEmissionBytes-total)overflow=true;
    else{admitted[channel]+=charge;total+=charge;counts[channel]++;}
   }finally{Monitor.Exit(gate);}
   if(overflow){Refuse("owned_stream_limit");throw new PipelineStoppedException();}
   if(channel==1&&Interlocked.CompareExchange(ref errorClaim,1,0)==0){var e=(ErrorRecord)args.ItemAdded;Volatile.Write(ref firstError,Fault("owned_error_stream","worker_invoke",e.Exception));}
  }
  void Attach<T>(PSDataCollection<T> collection,int channel){
   if(collection.Count!=0)throw new InvalidOperationException("Guard refuses preexisting stream data");
   collection.DataAddedCount=1;
   collection.DataAdding+=(sender,args)=>Adding(channel,args);
   collection.DataAdded+=(sender,args)=>((PSDataCollection<T>)sender).Clear();
  }
  public StreamGuard(object pipeline,PSDataCollection<PSObject> output,ConcurrentDictionary<string,object> originalOwner){
   owner=originalOwner;state=(ConcurrentDictionary<string,object>)owner["State"];
   if(!Object.ReferenceEquals(owner["Pipeline"],pipeline)||!Object.ReferenceEquals(state["OwnedWorkOwner"],owner))throw new InvalidOperationException("Original worker authority required");
   var streams=(PSDataStreams)pipeline.GetType().GetProperty("Streams").GetValue(pipeline);
   var method=pipeline.GetType().GetMethod("StopAsync",new[]{typeof(AsyncCallback),typeof(object)});
   if(method==null||method.ReturnType!=typeof(Task))throw new InvalidOperationException("Original pipeline stop required");
   stop=(Func<AsyncCallback,object,Task>)Delegate.CreateDelegate(typeof(Func<AsyncCallback,object,Task>),pipeline,method);
   Attach(output,0);Attach(streams.Error,1);Attach(streams.Warning,2);Attach(streams.Verbose,3);Attach(streams.Debug,4);Attach(streams.Information,5);Attach(streams.Progress,6);
  }
 }
}
'@
    $identity=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source))).ToLowerInvariant()
    $loaded='GauntletOwnedWork.StreamGuard' -as [type]
    if($null -ne $loaded){
        $underlying=$null;$value=$null
        try{
            $property=$loaded.GetProperty('SourceIdentity',[Reflection.BindingFlags]'Public,Static')
            if($null -ne $property -and $property.PropertyType -eq [string] -and $null -ne $property.GetMethod -and $property.GetMethod.IsStatic -and $property.GetIndexParameters().Count -eq 0){$value=$property.GetValue($null)}
        }catch{$underlying=$_.Exception}
        if($value -is [string] -and $value -cmatch '^[0-9a-f]{64}$' -and [string]::Equals($value,$identity,[StringComparison]::Ordinal)){return}
        $error=[InvalidOperationException]::new('Loaded owned-stream helper differs from current source',$underlying)
        $error.Data['ReviewCode']='owned_stream_source_mismatch';$error.Data['ReviewStage']='worker_stream_init';throw $error
    }
    Add-Type -TypeDefinition $source.Replace('__GAUNTLET_STREAM_SOURCE_IDENTITY__',$identity) -ErrorAction Stop
}


function Get-ReviewOwnerRegistry {
    param([Parameter(Mandatory)][ValidateSet('LiveGateDirectories','LiveGateInputs','ReviewTransportOwners','ReviewProcessOwners','ReviewCapacityOwners','ReviewInstallOwners','ReviewManifestWriters','ReviewFilesystemOwners','ReaderProducerCustodies','SecurityWorkOwners','SecurityGateOwners','SecurityProcessRuns','SecurityAuthSourceReads','SecurityHarnesses','SecurityCleanupResults')][string]$Name,[switch]$List)
    $domain=[AppDomain]::CurrentDomain;$entered=$false
    try{
        $entered=[Threading.Monitor]::TryEnter($domain)
        if(-not $entered){$failure=[InvalidOperationException]::new('Ownership registry refused');$failure.Data['ReviewCode']='registry_busy';$failure.Data['ReviewStage']='registry_init';throw $failure}
        $key='GauntletReview.OwnerRegistries.v1'
        $registries=$domain.GetData($key)
        if($null -eq $registries){$registries=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$domain.SetData($key,$registries)}
        if(-not $registries.ContainsKey($Name)){
            $value=if($List){[Collections.Generic.List[object]]::new()}else{[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)}
            # Avoid PowerShell enumerating an empty List while assigning the factory result.
            if($List){$value=[Collections.Generic.List[object]]::new()}
            $registries.Add($Name,[pscustomobject]@{List=[bool]$List;Value=$value})
        }
        $entry=$registries[$Name]
        if($entry.List -cne [bool]$List){$failure=[InvalidOperationException]::new('Ownership registry refused');$failure.Data['ReviewCode']='registry_shape';$failure.Data['ReviewStage']='registry_init';throw $failure}
        return ,$entry.Value
    }finally{if($entered){[Threading.Monitor]::Exit($domain)}}
}

function Initialize-LiveGateNative {
    if (-not $IsWindows) {
        $refusal=[PlatformNotSupportedException]::new('Live gate ownership and process containment require Windows')
        $refusal.Data['ReviewCode']='native_platform_unsupported';$refusal.Data['ReviewStage']='native_initialization'
        throw $refusal
    }
    $source = @'
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;
namespace GauntletLive {
    public static class Native {
        public static string SourceIdentity { get { return "__GAUNTLET_NATIVE_SOURCE_IDENTITY__"; } }
        public sealed class RunResult {
            public int? ExitCode;
            public string Stdout = "", Stderr = "", ErrorMessage;
            public bool TimedOut, StartFailed, ProcessTreeRetired;
            public NativeFailure Failure;
            public NativeFailure[] CleanupFailures=Array.Empty<NativeFailure>();
        }
        public sealed class NativeFailure {
            public string Code {get;internal set;}
            public string Stage {get;internal set;}
            public string Type {get;internal set;}
            public int HResult {get;internal set;}
            public int? NativeError {get;internal set;}
        }
        static NativeFailure SafeFailure(string code,string stage,Exception exception) {
            exception=exception.GetBaseException();var type=exception.GetType().FullName;
            return new NativeFailure {Code=code,Stage=stage,Type=type.Length<=256?type:"System.Exception",HResult=exception.HResult,
                NativeError=exception is Win32Exception native?(int?)native.NativeErrorCode:null};
        }
        static void RecordFailure(RunResult result,string code,string stage,Exception exception,bool cleanup=false) {
            exception=exception.GetBaseException();
            var type=exception.GetType().FullName;
            var fault=new NativeFailure {Code=code,Stage=stage,Type=type.Length<=256?type:"System.Exception",HResult=exception.HResult,
                NativeError=exception is Win32Exception native?(int?)native.NativeErrorCode:null};
            if(Interlocked.CompareExchange(ref result.Failure,fault,null)!=null&&cleanup) {
                while(true) {
                    var previous=result.CleanupFailures;if(previous.Length>=2)break;
                    var next=new NativeFailure[previous.Length+1];Array.Copy(previous,next,previous.Length);next[previous.Length]=fault;
                    if(ReferenceEquals(Interlocked.CompareExchange(ref result.CleanupFailures,next,previous),previous))break;
                }
            }
        }
        [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes {
            public int Length;
            public IntPtr Descriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct StartupInfo {
            public int Size;
            public string Reserved, Desktop, Title;
            public uint X, Y, XSize, YSize, XCount, YCount, Fill, Flags;
            public ushort Show, ReservedSize;
            public IntPtr ReservedBytes, Input, Output, Error;
        }
        [StructLayout(LayoutKind.Sequential)] struct StartupInfoEx {
            public StartupInfo Info;
            public IntPtr Attributes;
        }
        [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {
            public IntPtr Process, Thread;
            public uint ProcessId, ThreadId;
        }
        [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveLimit;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
            public BasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [StructLayout(LayoutKind.Sequential)] struct Accounting {
            public long UserTime, KernelTime, PeriodUserTime, PeriodKernelTime;
            public uint PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses;
        }
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr security, IntPtr name);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimits limits, int size);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int kind, out Accounting info, int size, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint exitCode);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref SecurityAttributes security, uint size);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, UIntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool CreateProcessW(string app, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity,
            bool inherit, uint flags, IntPtr environment, string cwd, ref StartupInfoEx startup, out ProcessInfo process);

        static void Require(bool success) { if (!success) throw new Win32Exception(Marshal.GetLastWin32Error()); }
        static void Close(ref IntPtr handle) {
            if(handle==IntPtr.Zero)return;
            if(!CloseHandle(handle))throw new Win32Exception(Marshal.GetLastWin32Error());
            handle=IntPtr.Zero;
        }
        // A bounded registry retains the ORIGINAL run, handles and incomplete IO after
        // failed cleanup. Exhaustion refuses new work; it never drops prior custody.
        sealed class RunCustody {
            public readonly object JobSync=new object();
            public IntPtr Job;
            public bool JobClosed;
            public long Deadline=long.MaxValue;
            public int CleanupExpired;
            public readonly List<object> Unresolved=new List<object>();
            public Exception TerminationError;
            public Task CleanupTask;
            public CancellationTokenRegistration Cancellation;
            public void Terminate() {
                // A close/termination already admitted on this exact original job
                // owns its lifetime. Signaling cancellation must never wait behind
                // that operation or extend the caller's original deadline.
                if(!Monitor.TryEnter(JobSync))return;
                try {
                    if(JobClosed||Job==IntPtr.Zero||Volatile.Read(ref CleanupExpired)!=0||Stopwatch.GetTimestamp()>=Deadline)return;
                    if(!TerminateJobObject(Job,1)&&TerminationError==null)
                        TerminationError=new Win32Exception(Marshal.GetLastWin32Error());
                }finally{Monitor.Exit(JobSync);}
            }
        }
        const int MaximumRuns=8;
        static int activeRuns;
        static readonly System.Collections.Concurrent.ConcurrentDictionary<RunResult,RunCustody> runs=
            new System.Collections.Concurrent.ConcurrentDictionary<RunResult,RunCustody>();
        static bool AdmitCleanup(RunResult result,RunCustody custody,object resource) {
            if(resource==null)return false;
            if(Volatile.Read(ref custody.CleanupExpired)!=0||Stopwatch.GetTimestamp()>=custody.Deadline) {
                // Retain the exact unattempted resource beyond task completion;
                // closure captures alone are not continuing ownership evidence.
                custody.Unresolved.Add(resource);
                if(Interlocked.Exchange(ref custody.CleanupExpired,1)==0)
                    RecordFailure(result,"native_cleanup_deadline","process_cleanup",new TimeoutException(),true);
                return false;
            }
            return true;
        }
        static void DisposeOwned(RunResult result,RunCustody custody,IDisposable resource) {
            if(!AdmitCleanup(result,custody,resource))return;
            try{resource.Dispose();}
            catch(Exception error){RecordFailure(result,"native_cleanup","stream_cleanup",error,true);custody.Unresolved.Add(resource);}
        }
        static void CloseOwned(RunResult result,RunCustody custody,ref IntPtr handle) {
            if(handle==IntPtr.Zero||!AdmitCleanup(result,custody,handle))return;
            try{Close(ref handle);}
            catch(Exception error){RecordFailure(result,"native_cleanup","handle_cleanup",error,true);custody.Unresolved.Add(handle);}
        }
        static string Quote(string value) {
            if (value.IndexOf('\0') >= 0) throw new ArgumentException("Child argument contains a null character");
            if (value.Length != 0 && value.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return value;
            var output = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value) {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { output.Append('\\', 2 * slashes + 1); output.Append('"'); }
                else { output.Append('\\', slashes); output.Append(c); }
                slashes = 0;
            }
            output.Append('\\', 2 * slashes); output.Append('"');
            return output.ToString();
        }
        static uint ActiveCount(IntPtr job) {
            Accounting accounting;
            Require(QueryInformationJobObject(job, 1, out accounting, Marshal.SizeOf<Accounting>(), IntPtr.Zero));
            return accounting.ActiveProcesses;
        }
        sealed class CaptureBudget {
            public int Used, Exceeded;
            long retained;
            public long PeakRetained;
            public const int MaximumBytes=4*1024*1024;
            public const int MaximumInputBytes=1024*1024;
            public const long MaximumRetainedBytes=16L*1024*1024;
            // Storage metadata cannot grow with read fragmentation: chunks are
            // filled before append. Raw caps bound <=1024 committed byte arrays,
            // <=2 pending arrays and <=2048 combined List backing slots. Reserve
            // 128KiB for their array/object headers, list slots, decoder state and
            // string headers in addition to charged byte/UTF16 payload capacity.
            // This is an IO-storage bound, not a bound on total CLR/OS heap use.
            public const int CaptureMetadataReserve=128*1024;
            public readonly RunCustody Custody;
            public CaptureBudget(RunCustody custody){Custody=custody;Reserve(CaptureMetadataReserve);}
            public void Limit() {
                Interlocked.Exchange(ref Exceeded,1);
                // The cap-crossing reader terminates this original job immediately.
                Custody.Terminate();
                throw new InvalidOperationException("Process IO exceeded its retention budget");
            }
            public void Reserve(long bytes) {
                long next=Interlocked.Add(ref retained,bytes);
                long peak;do{peak=Volatile.Read(ref PeakRetained);if(next<=peak)break;}
                while(Interlocked.CompareExchange(ref PeakRetained,next,peak)!=peak);
                if(next>MaximumRetainedBytes){Interlocked.Add(ref retained,-bytes);Limit();}
            }
            public void Release(long bytes){Interlocked.Add(ref retained,-bytes);}
        }
        static async Task<string> Capture(Stream stream,CaptureBudget budget) {
            // Payload accounting includes actual allocated byte capacities and final
            // UTF16 strings while chunks coexist. There is no whole-buffer byte copy.
            const int chunkSize=4096;
            var chunks=new List<KeyValuePair<byte[],int>>();
            long retainedChunks=0;
            byte[] buffer=null;
            try {
                int channelBytes=0;
                while(true) {
                    budget.Reserve(chunkSize);buffer=new byte[chunkSize];retainedChunks+=chunkSize;
                    int count=0;
                    while(count<chunkSize) {
                        int read=await stream.ReadAsync(buffer,count,chunkSize-count).ConfigureAwait(false);
                        if(read==0)break;
                        count+=read;channelBytes+=read;
                        if(channelBytes>CaptureBudget.MaximumBytes||Interlocked.Add(ref budget.Used,read)>CaptureBudget.MaximumBytes)budget.Limit();
                    }
                    if(count!=0)chunks.Add(new KeyValuePair<byte[],int>(buffer,count));
                    else {budget.Release(chunkSize);retainedChunks-=chunkSize;}
                    buffer=null;
                    if(count<chunkSize)break;
                }
                var decoder=Encoding.UTF8.GetDecoder();
                // Decoder state retains no data beyond at most three pending UTF8 bytes.
                budget.Reserve(16);
                int chars=0;
                try {
                    for(int i=0;i<chunks.Count;i++)chars=checked(chars+decoder.GetCharCount(chunks[i].Key,0,chunks[i].Value,i==chunks.Count-1));
                    long stringBytes=checked((long)chars*2);
                    budget.Reserve(stringBytes);
                    bool made=false;
                    try {
                        string text=string.Create(chars,chunks,(destination,items)=>{
                            var writer=Encoding.UTF8.GetDecoder();int offset=0;
                            for(int i=0;i<items.Count;i++){
                                writer.Convert(items[i].Key.AsSpan(0,items[i].Value),destination.Slice(offset),i==items.Count-1,
                                    out int consumed,out int written,out bool completed);
                                if(consumed!=items[i].Value||!completed)throw new InvalidOperationException("UTF8 capture decoding did not complete");
                                offset+=written;
                            }
                        });
                        made=true;return text;
                    }finally{if(!made)budget.Release(stringBytes);}
                }finally{budget.Release(16);}
            } finally {
                buffer=null;chunks.Clear();budget.Release(retainedChunks);
            }
        }
        public static RunResult Run(ProcessStartInfo start, string input, int seconds) {
            return RunMilliseconds(start, input, checked(seconds * 1000));
        }
        public static RunResult RunMilliseconds(ProcessStartInfo start, string input, int milliseconds) {
            return RunMilliseconds(start,input,milliseconds,CancellationToken.None);
        }
        public static RunResult RunMilliseconds(ProcessStartInfo start,string input,int milliseconds,CancellationToken failureCancellation) {
            return RunUntil(start,input,checked(Stopwatch.GetTimestamp() + (long)milliseconds * Stopwatch.Frequency / 1000),failureCancellation);
        }
        public static RunResult RunUntil(ProcessStartInfo start, string input, long deadlineTimestamp) {
            return RunUntil(start,input,deadlineTimestamp,CancellationToken.None);
        }
        public static RunResult RunUntil(ProcessStartInfo start,string input,long deadlineTimestamp,CancellationToken failureCancellation) {
            var result = new RunResult();
            Func<int> remaining = () => (int)Math.Clamp((deadlineTimestamp - Stopwatch.GetTimestamp()) * 1000 / Stopwatch.Frequency, 0L, Int32.MaxValue);
            long totalMs = remaining();
            long reserveMs = Math.Min(5000, totalMs / 4);
            Func<int> executionRemaining = () => (int)Math.Max(0, remaining() - reserveMs);
            IntPtr job=IntPtr.Zero, stdinRead=IntPtr.Zero, stdinWrite=IntPtr.Zero, stdoutRead=IntPtr.Zero,
                stdoutWrite=IntPtr.Zero, stderrRead=IntPtr.Zero, stderrWrite=IntPtr.Zero;
            IntPtr attributes=IntPtr.Zero, handles=IntPtr.Zero, environment=IntPtr.Zero;
            bool attributesReady=false, assigned=false, created=false;
            ProcessInfo process = new ProcessInfo();
            FileStream inputStream=null, outputStream=null, errorStream=null;
            Task<string> outputTask=null, errorTask=null;
            Task writeTask=null;
            var custody=new RunCustody{Deadline=deadlineTimestamp};
            if(Interlocked.Increment(ref activeRuns)>MaximumRuns) {
                Interlocked.Decrement(ref activeRuns);
                RecordFailure(result,"native_capacity","native_admission",new InvalidOperationException());
                result.StartFailed=true;result.ExitCode=-1;result.ProcessTreeRetired=true;
                result.ErrorMessage="Original native run capacity is exhausted";return result;
            }
            if(!runs.TryAdd(result,custody)){Interlocked.Decrement(ref activeRuns);throw new InvalidOperationException("Native run identity collision");}
            var budget = new CaptureBudget(custody);
            byte[] inputBytes=null;
            long inputCharge=0;
            CancellationTokenRegistration cancellationRegistration=default(CancellationTokenRegistration);
            string stage="native_setup";
            bool abortRecorded=false;
            Func<bool> peerFailure = () => {
                if(!failureCancellation.IsCancellationRequested) return false;
                if(!abortRecorded){RecordFailure(result,"transport_abort",stage,new OperationCanceledException(),true);abortRecorded=true;}
                result.ErrorMessage="Paired review transport failed";result.ExitCode=-1;
                custody.Terminate();return true;
            };
            try {
                if(peerFailure()) throw new OperationCanceledException("Paired review transport failed before launch");
                stage="stdin_admission";
                input=input??"";
                if(input.Length>CaptureBudget.MaximumInputBytes) {
                    RecordFailure(result,"stdin_limit",stage,new InvalidOperationException());
                    throw new InvalidOperationException("Process stdin exceeded its UTF8 budget");
                }
                int inputByteCount=Encoding.UTF8.GetByteCount(input);
                if(inputByteCount>CaptureBudget.MaximumInputBytes) {
                    RecordFailure(result,"stdin_limit",stage,new InvalidOperationException());
                    throw new InvalidOperationException("Process stdin exceeded its UTF8 budget");
                }
                inputCharge=checked((long)input.Length*2+inputByteCount);
                budget.Reserve(inputCharge);
                inputBytes=Encoding.UTF8.GetBytes(input);
                stage="native_setup";
                if (remaining() == 0) { result.TimedOut=true; throw new TimeoutException("Original process deadline expired before launch"); }
                job = CreateJobObjectW(IntPtr.Zero, IntPtr.Zero);
                if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                custody.Job=job;
                cancellationRegistration=failureCancellation.Register(custody.Terminate);
                custody.Cancellation=cancellationRegistration;
                var limits = new ExtendedLimits();
                limits.Basic.Flags = 0x2000; // KILL_ON_JOB_CLOSE, without either breakaway flag.
                Require(SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf<ExtendedLimits>()));
                var security = new SecurityAttributes { Length=Marshal.SizeOf<SecurityAttributes>(), Inherit=true };
                Require(CreatePipe(out stdinRead, out stdinWrite, ref security, 0));
                Require(CreatePipe(out stdoutRead, out stdoutWrite, ref security, 0));
                Require(CreatePipe(out stderrRead, out stderrWrite, ref security, 0));
                Require(SetHandleInformation(stdinWrite, 1, 0));
                Require(SetHandleInformation(stdoutRead, 1, 0));
                Require(SetHandleInformation(stderrRead, 1, 0));
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                attributes = Marshal.AllocHGlobal(size);
                Require(InitializeProcThreadAttributeList(attributes, 1, 0, ref size));
                attributesReady = true;
                handles = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(handles, 0, stdinRead);
                Marshal.WriteIntPtr(handles, IntPtr.Size, stdoutWrite);
                Marshal.WriteIntPtr(handles, IntPtr.Size * 2, stderrWrite);
                Require(UpdateProcThreadAttribute(attributes, 0, new UIntPtr(0x20002), handles,
                    new IntPtr(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero));
                var envText = new StringBuilder();
                foreach (var entry in start.Environment.OrderBy(e => e.Key, StringComparer.OrdinalIgnoreCase)) {
                    if (entry.Key.Contains('=') || entry.Key.Contains('\0') || (entry.Value ?? "").Contains('\0')) throw new ArgumentException("Invalid child environment entry");
                    envText.Append(entry.Key).Append('=').Append(entry.Value).Append('\0');
                }
                envText.Append('\0');
                if (start.Environment.Count == 0) envText.Append('\0');
                environment = Marshal.StringToHGlobalUni(envText.ToString());
                var startup = new StartupInfoEx();
                startup.Info.Size = Marshal.SizeOf<StartupInfoEx>();
                startup.Info.Flags = 0x100;
                startup.Info.Input=stdinRead; startup.Info.Output=stdoutWrite; startup.Info.Error=stderrWrite;
                startup.Attributes=attributes;
                var command = new StringBuilder(Quote(start.FileName));
                foreach (var argument in start.ArgumentList) command.Append(' ').Append(Quote(argument));
                // No executable instruction runs until assignment to the non-breakaway job.
                stage="process_creation";
                if(peerFailure()) throw new OperationCanceledException("Paired review transport failed before creation");
                if (remaining() == 0) { result.TimedOut=true; throw new TimeoutException("Original process deadline expired before creation"); }
                Require(CreateProcessW(start.FileName, command, IntPtr.Zero, IntPtr.Zero, true,
                    0x08080404, environment, start.WorkingDirectory, ref startup, out process));
                created = true;
                if(peerFailure())throw new OperationCanceledException("Paired review transport failed after creation");
                if(remaining()==0){result.TimedOut=true;throw new TimeoutException("Original deadline expired before job assignment");}
                Require(AssignProcessToJobObject(job, process.Process));
                assigned = true;
                CloseOwned(result,custody,ref stdinRead);CloseOwned(result,custody,ref stdoutWrite);CloseOwned(result,custody,ref stderrWrite);
                if(result.Failure!=null||Volatile.Read(ref custody.CleanupExpired)!=0)throw new InvalidOperationException("Original process setup closure failed");
                if(peerFailure())throw new OperationCanceledException("Paired review transport failed before stream setup");
                inputStream = new FileStream(new SafeFileHandle(stdinWrite, false), FileAccess.Write, 4096, false);
                outputStream = new FileStream(new SafeFileHandle(stdoutRead, false), FileAccess.Read, 4096, false);
                errorStream = new FileStream(new SafeFileHandle(stderrRead, false), FileAccess.Read, 4096, false);
                outputTask=Capture(outputStream, budget); errorTask=Capture(errorStream, budget);
                if(peerFailure()) throw new OperationCanceledException("Paired review transport failed before resume");
                if (executionRemaining() == 0) { result.TimedOut=true; throw new TimeoutException("Original process deadline expired before resume"); }
                if (ResumeThread(process.Thread) == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
                CloseOwned(result,custody,ref process.Thread);
                if(result.Failure!=null||Volatile.Read(ref custody.CleanupExpired)!=0)throw new InvalidOperationException("Original process thread closure failed");
                stage="stdin";
                writeTask = inputStream.WriteAsync(inputBytes, 0, inputBytes.Length);
                while (!writeTask.IsCompleted && executionRemaining() > 0 && Volatile.Read(ref budget.Exceeded) == 0 && !failureCancellation.IsCancellationRequested)
                    Thread.Sleep(Math.Min(10, executionRemaining()));
                if(Volatile.Read(ref budget.Exceeded)!=0) {
                    RecordFailure(result,"capture_limit","process_capture",new InvalidOperationException());
                    result.ErrorMessage="Aggregate process output exceeded its retention budget";
                }
                peerFailure();
                bool stdinDone = writeTask.IsCompletedSuccessfully;
                if (result.ErrorMessage==null && (writeTask.IsFaulted || writeTask.IsCanceled)) {
                    result.ErrorMessage="stdin transport failed before the complete prompt was delivered: " + writeTask.Exception?.GetBaseException().Message;
                    RecordFailure(result,"stdin_failure",stage,(Exception)writeTask.Exception??new OperationCanceledException());
                }
                if(stdinDone) {
                    // EOF is the checked close of the original raw pipe, after its
                    // write is terminal. The non-owning managed wrapper is disposed
                    // only by the existing bounded original cleanup task.
                    CloseOwned(result,custody,ref stdinWrite);
                    if(result.Failure!=null||Volatile.Read(ref custody.CleanupExpired)!=0)throw new InvalidOperationException("Original stdin EOF closure failed");
                }
                bool exited = false;
                stage="process_exit";
                while (stdinDone && result.ErrorMessage == null && executionRemaining() > 0 && Volatile.Read(ref budget.Exceeded) == 0 && !failureCancellation.IsCancellationRequested) {
                    if (WaitForSingleObject(process.Process, (uint)Math.Min(20, executionRemaining())) == 0) { exited=true; break; }
                }
                peerFailure();
                result.TimedOut = !exited && executionRemaining() == 0;
                uint exitCode;
                if(exited&&remaining()>0) { Require(GetExitCodeProcess(process.Process, out exitCode)); result.ExitCode=unchecked((int)exitCode); }
                else if(remaining()==0){result.TimedOut=true;result.ExitCode=-1;}
                else { result.ExitCode=-1; }
                // Parent exit is insufficient: terminate and query the entire owned job.
                stage="process_retirement";
                // Execution stopped at the existing reserved-quarter cutoff. A
                // normal timeout still retires here before the ABSOLUTE deadline;
                // a stage stalled through that reserve starts no late kill/query.
                if(AdmitCleanup(result,custody,job)&&remaining()>0&&ActiveCount(job)!=0&&AdmitCleanup(result,custody,job))Require(TerminateJobObject(job, 1));
                while(remaining()>0&&ActiveCount(job)!=0){peerFailure();Thread.Sleep(Math.Min(10,remaining()));}
                result.ProcessTreeRetired=remaining()>0&&Volatile.Read(ref custody.CleanupExpired)==0&&ActiveCount(job)==0&&remaining()>0;
                if (!result.ProcessTreeRetired) {result.ErrorMessage="Owned process job did not retire before the shared deadline";RecordFailure(result,"retirement_deadline",stage,new TimeoutException());}
                stage="process_capture";
                while((!outputTask.IsCompleted||!errorTask.IsCompleted)&&remaining()>0) {
                    peerFailure();
                    try{Task.WaitAll(new Task[]{outputTask,errorTask},Math.Min(10,remaining()));}catch(AggregateException){}
                }
                peerFailure();
                if (outputTask.IsCompletedSuccessfully) result.Stdout=outputTask.Result;
                if (errorTask.IsCompletedSuccessfully) result.Stderr=errorTask.Result;
                if (Volatile.Read(ref budget.Exceeded) != 0) {
                    result.ErrorMessage="Aggregate process output exceeded its retention budget";
                    RecordFailure(result,"capture_limit",stage,new InvalidOperationException());
                } else if (outputTask.IsFaulted || errorTask.IsFaulted) {
                    result.ErrorMessage="Owned process output transport failed: " + (outputTask.Exception ?? errorTask.Exception)?.GetBaseException().Message;
                    RecordFailure(result,"capture_failure",stage,outputTask.Exception??errorTask.Exception);
                } else if (!outputTask.IsCompletedSuccessfully || !errorTask.IsCompletedSuccessfully) {
                    result.TimedOut=true; result.ErrorMessage="Owned process pipes did not complete before the shared deadline";
                    RecordFailure(result,"capture_deadline",stage,new TimeoutException());
                }
                if (result.ErrorMessage != null) result.ExitCode=-1;
            } catch (Exception error) {
                RecordFailure(result,"native_failure",stage,error);
                result.StartFailed = !assigned;
                result.ErrorMessage=error.Message;
                result.ExitCode=-1;
            } finally {
                // Closing a job requests termination but is never itself retirement evidence.
                if (created && !result.ProcessTreeRetired) {
                    try {
                        if (assigned) {
                            if(AdmitCleanup(result,custody,job))Require(TerminateJobObject(job, 1));
                            while(remaining()>0&&ActiveCount(job)!=0){peerFailure();Thread.Sleep(Math.Min(10,remaining()));}
                            result.ProcessTreeRetired=remaining()>0&&Volatile.Read(ref custody.CleanupExpired)==0&&ActiveCount(job)==0&&remaining()>0;
                        } else {
                            if(AdmitCleanup(result,custody,process.Process))Require(TerminateProcess(process.Process, 1));
                            result.ProcessTreeRetired=remaining()>0&&Volatile.Read(ref custody.CleanupExpired)==0&&WaitForSingleObject(process.Process,(uint)remaining())==0&&remaining()>0;
                        }
                    } catch (Exception cleanupError) { result.ProcessTreeRetired=false; RecordFailure(result,"native_cleanup","process_cleanup",cleanupError,true);result.ErrorMessage += "; retirement: " + cleanupError.Message; }
                } else if (!created) { result.ProcessTreeRetired=true; }
                // Every exit path, including a suspended-start abort, must observe the
                // actual stdin and inherited-pipe tasks before claiming retirement.
                var ioTasks=new List<Task>();
                if(writeTask!=null) ioTasks.Add(writeTask);
                if(outputTask!=null) ioTasks.Add(outputTask);
                if(errorTask!=null) ioTasks.Add(errorTask);
                while(ioTasks.Any(task=>!task.IsCompleted)&&remaining()>0) {
                    peerFailure();
                    try{Task.WaitAll(ioTasks.ToArray(),Math.Min(10,remaining()));}catch(AggregateException){}
                }
                peerFailure();
                if(ioTasks.Any(task=>!task.IsCompleted)) {
                    result.ProcessTreeRetired=false;result.ExitCode=-1;
                    result.ErrorMessage="Owned process IO did not retire before the shared deadline";
                    RecordFailure(result,"pipe_retirement","process_cleanup",new TimeoutException(),true);
                }
                if(outputTask!=null&&outputTask.IsCompletedSuccessfully) result.Stdout=outputTask.Result;
                if(errorTask!=null&&errorTask.IsCompletedSuccessfully) result.Stderr=errorTask.Result;
                bool ioRetired=ioTasks.All(task=>task.IsCompleted);
                if(!ioRetired||remaining()==0) {
                    // Deadline expiry transfers no custody and starts no further IO
                    // disposal. These exact references stay in the bounded run owner.
                    foreach(var resource in new object[]{inputStream,outputStream,errorStream,writeTask,outputTask,errorTask,inputBytes,input})if(resource!=null)custody.Unresolved.Add(resource);
                    foreach(var handle in new IntPtr[]{job,process.Thread,process.Process,stdinRead,stdinWrite,stdoutRead,stdoutWrite,stderrRead,stderrWrite,attributes,handles,environment})if(handle!=IntPtr.Zero)custody.Unresolved.Add(handle);
                    Interlocked.Exchange(ref custody.CleanupExpired,1);
                    RecordFailure(result,"native_cleanup_deadline","process_cleanup",new TimeoutException(),true);
                    result.ProcessTreeRetired=false;result.ExitCode=-1;result.ErrorMessage="Original native cleanup exceeded the shared deadline";
                } else {
                // One original cleanup task owns all independent resources. A late
                // disposer cannot extend the caller's deadline or publish success.
                custody.CleanupTask=Task.Run(()=>{
                // Independent resources are each attempted even if another disposer fails.
                DisposeOwned(result,custody,inputStream);DisposeOwned(result,custody,outputStream);DisposeOwned(result,custody,errorStream);
                CloseOwned(result,custody,ref process.Thread);CloseOwned(result,custody,ref process.Process);
                CloseOwned(result,custody,ref stdinRead);CloseOwned(result,custody,ref stdinWrite);
                CloseOwned(result,custody,ref stdoutRead);CloseOwned(result,custody,ref stdoutWrite);
                CloseOwned(result,custody,ref stderrRead);CloseOwned(result,custody,ref stderrWrite);
                bool attributesDeleted=!attributesReady;
                if(attributesReady&&AdmitCleanup(result,custody,attributes)){try{DeleteProcThreadAttributeList(attributes);attributesDeleted=true;}catch(Exception error){RecordFailure(result,"native_cleanup","attribute_cleanup",error,true);custody.Unresolved.Add(attributes);}}
                if(attributesDeleted&&attributes!=IntPtr.Zero&&AdmitCleanup(result,custody,attributes)){try{Marshal.FreeHGlobal(attributes);}catch(Exception error){RecordFailure(result,"native_cleanup","memory_cleanup",error,true);custody.Unresolved.Add(attributes);}}
                // UpdateProcThreadAttribute borrows this exact lpValue allocation
                // until the initialized attribute list is confirmed destroyed.
                // Failed/refused destruction already retains attributes above.
                if(!attributesDeleted&&handles!=IntPtr.Zero)custody.Unresolved.Add(handles);
                if(attributesDeleted&&handles!=IntPtr.Zero&&AdmitCleanup(result,custody,handles)){try{Marshal.FreeHGlobal(handles);}catch(Exception error){RecordFailure(result,"native_cleanup","memory_cleanup",error,true);custody.Unresolved.Add(handles);}}
                if(environment!=IntPtr.Zero&&AdmitCleanup(result,custody,environment)){try{Marshal.FreeHGlobal(environment);}catch(Exception error){RecordFailure(result,"native_cleanup","memory_cleanup",error,true);custody.Unresolved.Add(environment);}}
                // Serialize close with the original overflow/cancellation callback so a
                // late signal cannot target a recycled numeric handle.
                lock(custody.JobSync){CloseOwned(result,custody,ref job);if(job==IntPtr.Zero){custody.JobClosed=true;custody.Job=IntPtr.Zero;}}
                if(AdmitCleanup(result,custody,cancellationRegistration))cancellationRegistration.Dispose();
                if(custody.TerminationError!=null)RecordFailure(result,"native_cleanup","job_termination",custody.TerminationError,true);
                });
                while(!custody.CleanupTask.IsCompleted&&remaining()>0) {
                    peerFailure();try{custody.CleanupTask.Wait(Math.Min(10,remaining()));}catch(AggregateException){}
                }
                peerFailure();
                if(!custody.CleanupTask.IsCompletedSuccessfully||remaining()==0) {
                    Interlocked.Exchange(ref custody.CleanupExpired,1);
                    result.ProcessTreeRetired=false;result.ExitCode=-1;result.ErrorMessage="Original native cleanup exceeded the shared deadline";
                    RecordFailure(result,"native_cleanup_deadline","process_cleanup",custody.CleanupTask.Exception??(Exception)new TimeoutException(),true);
                }
                if(writeTask==null||writeTask.IsCompleted){inputBytes=null;input=null;budget.Release(inputCharge);}
                if(custody.CleanupTask.IsCompleted&&custody.Unresolved.Count!=0){result.ProcessTreeRetired=false;result.ExitCode=-1;result.ErrorMessage="Original native resource custody remains unresolved";}
                if(custody.CleanupTask.IsCompletedSuccessfully&&Volatile.Read(ref custody.CleanupExpired)==0&&custody.Unresolved.Count==0&&result.ProcessTreeRetired){RunCustody released;if(runs.TryRemove(result,out released))Interlocked.Decrement(ref activeRuns);}
                }
                peerFailure();
                if(result.Failure!=null||result.CleanupFailures.Length!=0)result.ExitCode=-1;
            }
            return result;
        }
    }
}
'@
    $sourceIdentity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source))).ToLowerInvariant()
    $loaded = 'GauntletLive.Native' -as [type]
    if ($loaded) {
        $identityMatches=$false;$identityFailure=$null
        try {
            $flags=[Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::Static
            $identityProperty=$loaded.GetProperty('SourceIdentity',$flags)
            if($null -ne $identityProperty -and $identityProperty.PropertyType -eq [string] -and $identityProperty.CanRead -and
               $identityProperty.GetIndexParameters().Count -eq 0 -and $null -ne $identityProperty.GetGetMethod() -and $identityProperty.GetGetMethod().IsStatic){
                $actualIdentity=$identityProperty.GetValue($null)
                $identityMatches=$actualIdentity -is [string] -and
                    [regex]::IsMatch($actualIdentity,'\A[0-9a-f]{64}\z',[Text.RegularExpressions.RegexOptions]::CultureInvariant) -and
                    [string]::Equals($actualIdentity,$sourceIdentity,[StringComparison]::Ordinal)
            }
        } catch {$identityFailure=$_.Exception}
        if($identityMatches){return}
        $refusal=[InvalidOperationException]::new('Loaded live-gate native helper differs from current source; use a fresh PowerShell process',$identityFailure)
        $refusal.Data['ReviewCode']='native_source_identity';$refusal.Data['ReviewStage']='native_initialization'
        throw $refusal
    }
    Add-Type -TypeDefinition $source.Replace('__GAUNTLET_NATIVE_SOURCE_IDENTITY__', $sourceIdentity) -ErrorAction Stop
}

function Get-ReviewOwnedWorkRetirement {
    param([Parameter(Mandatory)]$State)
    $owner=$null
    if(-not $State.TryGetValue('OwnedWorkOwner',[ref]$owner) -or $null -eq $owner -or -not [object]::ReferenceEquals($owner['State'],$State)){
        return (New-ReviewReadOnlyRecord -Values @{Retired=$false})
    }
    $null=Complete-ReviewOwnedWork -OwnerRegistry $owner['Registry'] -Token $owner['Token']
    $retired=$false
    if([Threading.Monitor]::TryEnter($owner)){
        try{$retired=$owner['RetirementConfirmed'] -is [bool] -and $owner['RetirementConfirmed']}finally{[Threading.Monitor]::Exit($owner)}
    }
    New-ReviewReadOnlyRecord -Values @{Retired=[bool]$retired}
}

function Get-ReviewOwnedWorkContext {
    $value=$ExecutionContext.SessionState.PSVariable.Get('script:ReviewOwnedWorkContext')
    if($null -eq $value -or $null -eq $value.Value){return $null}
    $state=$value.Value;$owner=$null
    if(-not $state.TryGetValue('OwnedWorkOwner',[ref]$owner) -or $null -eq $owner -or -not [object]::ReferenceEquals($owner['State'],$state)){return $null}
    if(-not [Threading.Monitor]::TryEnter($owner['Registry'])){Throw-ReviewCodedFailure 'registry_busy' 'native_admission'}
    try{
        if($owner['Registry'].ContainsKey($owner['Token']) -and [object]::ReferenceEquals($owner['Registry'][$owner['Token']],$owner)){return $state}
    }finally{[Threading.Monitor]::Exit($owner['Registry'])}
    return $null
}

function Get-ReviewProcessRetirement {
    param([Parameter(Mandatory)]$State)
    if(-not $State.ContainsKey('OwnedWorkOwner') -and $State.ContainsKey('AdmissionOutcome')){
        $admission=$State['AdmissionOutcome']
        if($null -eq $admission.Token -and $admission.Retired -is [bool] -and $admission.Retired -and $State['NativeNeverStarted']){return (New-ReviewReadOnlyRecord -Values @{Retired=$true})}
    }
    $worker=if($State['Inline']){$null}else{Get-ReviewOwnedWorkRetirement -State $State}
    $settled=$State['Settled'] -is [bool] -and $State['Settled']
    if(-not $State['Inline'] -and $worker.Retired -and -not $State.ContainsKey('ActionEntered')){$settled=$true}
    $native=$settled -and ($State['NativeNeverStarted'] -or ($null -ne $State['Result'] -and $State['Result'].ProcessTreeRetired -is [bool] -and $State['Result'].ProcessTreeRetired))
    $retired=$native -and ($State['Inline'] -or $worker.Retired)
    New-ReviewReadOnlyRecord -Values @{Retired=[bool]$retired}
}

function Invoke-ReviewProcessWorker {
    param($State,$Arguments)
    $previous=$ExecutionContext.SessionState.PSVariable.Get('script:ReviewNativeProcessState')
    $script:ReviewNativeProcessState=$State
    $pipeline=$null;$before=0
    try{
        $context=Get-ReviewOwnedWorkContext
        if($null -eq $context -or $null -eq $context['OwnedWorkOwner']['Pipeline']){Throw-ReviewCodedFailure 'native_owner_missing' 'native_startup'}
        $pipeline=$context['OwnedWorkOwner']['Pipeline'];$guard=$context['OwnedWorkOwner']['StreamGuard'];$before=$guard.ErrorCount
        $State['Result']=Invoke-BoundedProcessCore @Arguments
    }finally{
        if($null -ne $pipeline -and $null -ne $guard -and $guard.ErrorCount -gt $before){
            $State['NativeErrorStream']=$guard.FirstError
        }
        $State['Settled']=$true
        $State['CoreRetired']=$State['NativeNeverStarted'] -or ($null -ne $State['Result'] -and $State['Result'].ProcessTreeRetired -is [bool] -and $State['Result'].ProcessTreeRetired)
        $script:ReviewNativeProcessState=if($null -ne $previous){$previous.Value}else{$null}
    }
}

function Get-ReviewWorkerDefinitions {
    param([Parameter(Mandatory)][scriptblock]$LibraryDefinition)
    $ast=$LibraryDefinition.Ast;while($ast.Parent){$ast=$ast.Parent}
    $definitions=@{}
    foreach($function in $ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){
        $command=Get-Command $function.Name -CommandType Function -ErrorAction Stop
        $definitions[$function.Name]=$command.ScriptBlock
    }
    return $definitions
}

function Invoke-BoundedProcess {
    param([Parameter(Mandatory)][string]$FileName,[string[]]$ArgList=@(),[string]$StdinText,
        [string]$WorkingDirectory=([IO.Path]::GetTempPath()),[ValidateRange(1,86400)][int]$TimeoutSec=120,
        [ValidateRange(1,86400000)][int]$TimeoutMilliseconds,[ValidateRange(1,[long]::MaxValue)][long]$DeadlineTimestamp,
        [hashtable]$EnvironmentMap,[Threading.CancellationToken]$FailureCancellationToken=[Threading.CancellationToken]::None,
        [switch]$ClearEnvironment,[switch]$RequireProcessTreeRetirement)
    $entry=[Diagnostics.Stopwatch]::GetTimestamp()
    $argsCopy=@{};foreach($key in $PSBoundParameters.Keys){$argsCopy[$key]=$PSBoundParameters[$key]}
    $deadline=if($PSBoundParameters.ContainsKey('DeadlineTimestamp')){$DeadlineTimestamp}else{$entry+[long]$TimeoutSec*[Diagnostics.Stopwatch]::Frequency}
    if($PSBoundParameters.ContainsKey('TimeoutMilliseconds') -or $PSBoundParameters.ContainsKey('TimeoutSec')){
        $budget=if($PSBoundParameters.ContainsKey('TimeoutMilliseconds')){$TimeoutMilliseconds}else{[long]$TimeoutSec*1000}
        $deadline=[Math]::Min($deadline,$entry+[long]($budget*[Diagnostics.Stopwatch]::Frequency/1000.0))
    }
    $context=Get-ReviewOwnedWorkContext
    $filesystem=Get-ReviewFilesystemState
    $producer=$null
    if($null -ne (Get-Command Get-ReviewProducerIoState -CommandType Function -ListImported -ErrorAction SilentlyContinue)){$producer=Get-ReviewProducerIoState}
    foreach($parent in @($context,$filesystem,$producer)){if($null -ne $parent){$deadline=[Math]::Min($deadline,[long]$parent['Deadline'])}}
    if($null -ne $producer){
        try {
            foreach($prior in $producer['NativeOwners'].ToArray()){
                $physical=Get-ReviewProcessRetirement -State $prior
                if($null -eq $physical -or $physical.Retired -isnot [bool] -or -not $physical.Retired){Throw-ReviewCodedFailure 'native_prior_owner' 'native_admission'}
            }
        } catch {Throw-ReviewCodedFailure 'native_prior_owner' 'native_admission' $_.Exception}
    }
    $argsCopy.DeadlineTimestamp=$deadline;$argsCopy.RequireProcessTreeRetirement=$true
    $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal)
    $state['Deadline']=$deadline;$state['Settled']=$false;$state['NativeNeverStarted']=$true;$state['Result']=$null
    $state['CoreRetired']=$false;$state['Abandoned']=$false;$state['Stage']='native_startup';$state['Inline']=$null -ne $context
    if($null -ne $producer){$producer['NativeOwners'].Enqueue($state)}
    $slot=$null
    if($null -ne $filesystem){Assert-ReviewFilesystemStep -Stage 'native_admission';$slot=@{Result=$null;Retired=$false};$filesystem['NativeRuns'].Add($slot)}
    $outcome=$null
    if($null -ne $context){
        Invoke-ReviewProcessWorker -State $state -Arguments $argsCopy
    }else{
        $definitions=Get-ReviewWorkerDefinitions -LibraryDefinition (Get-Command Invoke-BoundedProcess).ScriptBlock
        $outcome=Invoke-ReviewOwnedWork -Kind 'native_process' -OwnerRegistry (Get-ReviewOwnerRegistry -Name ReviewProcessOwners) -DeadlineTimestamp $deadline -WorkerName Invoke-ReviewProcessWorker -Definitions $definitions -Arguments $argsCopy -State $state
        $state['AdmissionOutcome']=$outcome
    }
    $actual=$state['Result'];$native=$null
    if($null -ne $actual -and $actual.GetType().FullName -ceq 'GauntletLive.Native+RunResult'){
        $native=New-ReviewReadOnlyRecord -Values @{ExitCode=$actual.ExitCode;StartFailed=$actual.StartFailed;TimedOut=$actual.TimedOut;ErrorMessage=$actual.ErrorMessage;StderrText=$actual.Stderr;ProcessTreeRetired=$actual.ProcessTreeRetired}
    }
    # Preserve the first native cause before later worker/disposal faults, in one flat safe schema.
    $flatten={
        param($Fault)
        if($null -eq $Fault){return $null}
        $cause=$Fault
        if($Fault -is [Collections.IDictionary]){if($Fault.Keys -ccontains 'Cause'){$cause=$Fault['Cause']}}
        elseif($Fault.PSObject.Properties['Cause']){$cause=$Fault.Cause}
        New-ReviewReadOnlyRecord -Values @{Code=$Fault.Code;Stage=$Fault.Stage;Type=$(if($null -ne $cause){$cause.Type}else{$null});HResult=$(if($null -ne $cause){$cause.HResult}else{$null});NativeError=$(if($null -ne $cause){$cause.NativeError}else{$null})}
    }
    $faults=[Collections.Generic.List[object]]::new()
    if($null -ne $actual -and $actual.PSObject.Properties['Failure'] -and $null -ne $actual.Failure){$faults.Add($actual.Failure)}
    if($null -ne $actual -and $actual.PSObject.Properties['CleanupFailures']){foreach($secondary in $actual.CleanupFailures){$faults.Add($secondary)}}
    if($null -ne $state['NativeErrorStream']){$faults.Add($state['NativeErrorStream'])}
    if($null -ne $outcome){
        if($null -ne $outcome.Failure -and -not ($null -ne $state['NativeErrorStream'] -and $outcome.Failure.Code -ceq 'owned_error_stream' -and $outcome.Failure.Stage -ceq 'worker_invoke')){$faults.Add($outcome.Failure)}
        foreach($secondary in $outcome.CleanupFailures){$faults.Add($secondary)}
    }
    $primary=if($faults.Count -gt 0){$faults[0]}else{$null}
    $originalOwner=$state['OwnedWorkOwner']
    $deadlineFault=if($null -ne $outcome -and $outcome.TimedOut -and $null -ne $originalOwner -and [object]::ReferenceEquals($originalOwner['State'],$state)){$originalOwner['DeadlineFailure']}else{$null}
    if([object]::ReferenceEquals($primary,$deadlineFault)){$deadlineFault=$null}
    $selected=[Collections.Generic.List[object]]::new()
    foreach($source in $faults){
        if($null -eq $source -or [object]::ReferenceEquals($primary,$source) -or [object]::ReferenceEquals($deadlineFault,$source)){continue}
        $duplicate=$false;foreach($prior in $selected){if([object]::ReferenceEquals($prior,$source)){$duplicate=$true;break}}
        if(-not $duplicate -and $selected.Count -lt 2){$selected.Add($source)}
    }
    if($null -ne $deadlineFault){if($selected.Count -eq 2){$selected.RemoveAt(1)};$selected.Add($deadlineFault)}
    $failure=if($null -ne $primary){& $flatten $primary}else{$null}
    $cleanup=@(foreach($source in $selected){& $flatten $source})
    $retired=[bool](Get-ReviewProcessRetirement -State $state).Retired
    $accepted=$retired -and $null -ne $actual -and $null -eq $failure -and $cleanup.Count -eq 0 -and ($null -eq $outcome -or ($outcome.Completed -and $outcome.Retired))
    $result=New-ReviewReadOnlyRecord -Values @{
        ExitCode=$(if($accepted){$actual.ExitCode}else{-1});Stdout=$(if($null -ne $actual){$actual.Stdout}else{''});Stderr=$(if($null -ne $actual){$actual.Stderr}else{''})
        TimedOut=(($null -ne $outcome -and $outcome.TimedOut) -or ($null -ne $actual -and $actual.TimedOut));StartFailed=$(if($null -ne $actual){$actual.StartFailed}else{-not $state.ContainsKey('ActionEntered')})
        ErrorMessage=$(if($null -ne $actual -and $null -ne $actual.ErrorMessage){$actual.ErrorMessage}elseif(-not $accepted){'Owned native operation failed'}else{$null})
        ProcessTreeRetired=$retired;NativeProcessResult=$native;Failure=$failure;CleanupFailures=[Array]::AsReadOnly([object[]]$cleanup)
    }
    if($null -ne $slot){
        $slot.Result=$result;$slot.Retired=(Get-ReviewProcessRetirement -State $state).Retired
        if(-not $slot.Retired){Throw-ReviewTransportFault 'filesystem_native_unretired'}
        Assert-ReviewFilesystemStep -Stage 'native_completion'
    }
    return $result
}

function Invoke-BoundedProcessCore {
    <# Process core preserved for the dormant facade, which always requests native
       containment. The contained path guarantees:
         - stdin is written ASYNCHRONOUSLY, so a child that never drains the pipe (600 KB
           prompts far exceed the ~64 KB pipe buffer) cannot block us before the clock starts;
         - stdout and stderr are read concurrently, so a full stderr buffer cannot deadlock;
         - ONE shared deadline covers stdin + exit, so total time is bounded by TimeoutSec;
         - timeout kills the whole process TREE;
         - it NEVER throws for process-level failure — callers map the result to exit codes. #>
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string[]]$ArgList = @(),
        [string]$StdinText,
        [string]$WorkingDirectory = ([System.IO.Path]::GetTempPath()),
        [ValidateRange(1, 86400)][int]$TimeoutSec = 120,
        [ValidateRange(1, 86400000)][int]$TimeoutMilliseconds,
        [ValidateRange(1,[long]::MaxValue)][long]$DeadlineTimestamp,
        [hashtable]$EnvironmentMap,
        [Threading.CancellationToken]$FailureCancellationToken=[Threading.CancellationToken]::None,
        [switch]$ClearEnvironment,
        [switch]$RequireProcessTreeRetirement
    )
    $r = [pscustomobject]@{ ExitCode=$null; Stdout=''; Stderr=''; TimedOut=$false; StartFailed=$false; ErrorMessage=$null; ProcessTreeRetired=$false; Failure=$null; CleanupFailures=[Array]::AsReadOnly([object[]]@()) }
    $stage='native_prepare'
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $FileName
        foreach ($a in $ArgList) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false; $psi.WorkingDirectory = $WorkingDirectory
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        if ($ClearEnvironment) { $psi.EnvironmentVariables.Clear() }
        if ($EnvironmentMap) { foreach ($k in $EnvironmentMap.Keys) { $psi.EnvironmentVariables[$k] = $EnvironmentMap[$k] } }
        if ($RequireProcessTreeRetirement -or $PSBoundParameters.ContainsKey('DeadlineTimestamp')) {
            $stage='native_initialization'
            Initialize-LiveGateNative
            $stage='native_process_start'
            $nativeState=$ExecutionContext.SessionState.PSVariable.Get('script:ReviewNativeProcessState')
            if($null -ne $nativeState -and $null -ne $nativeState.Value){$nativeState.Value['NativeNeverStarted']=$false}
            if ($PSBoundParameters.ContainsKey('DeadlineTimestamp')) { return [GauntletLive.Native]::RunUntil($psi,$StdinText,$DeadlineTimestamp,$FailureCancellationToken) }
            $boundedMilliseconds = if ($PSBoundParameters.ContainsKey('TimeoutMilliseconds')) { $TimeoutMilliseconds } else { $TimeoutSec * 1000 }
            return [GauntletLive.Native]::RunMilliseconds($psi, $StdinText, $boundedMilliseconds,$FailureCancellationToken)
        }
        $nativeState=$ExecutionContext.SessionState.PSVariable.Get('script:ReviewNativeProcessState')
        if($null -ne $nativeState -and $null -ne $nativeState.Value){$nativeState.Value['NativeNeverStarted']=$false}
        $stage='native_process_start'
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        $cause=Get-ReviewSafeCause -Exception ($_.Exception.GetBaseException())
        $admissionFault=New-ReviewTransportFault -Code 'native_startup' -Stage $stage -Exception $_.Exception
        $r.Failure=New-ReviewReadOnlyRecord -Values @{Code=$admissionFault.Code;Stage=$admissionFault.Stage;Type=$cause.Type;HResult=$cause.HResult;NativeError=$cause.NativeError}
        $r.StartFailed = $true; $r.ErrorMessage = $_.Exception.Message; return $r
    }
    $boundedMilliseconds = if ($PSBoundParameters.ContainsKey('TimeoutMilliseconds')) { $TimeoutMilliseconds } else { $TimeoutSec * 1000 }
    $processClock = [Diagnostics.Stopwatch]::StartNew()
    $remainingMs = { [int][Math]::Max(0, $boundedMilliseconds - $processClock.ElapsedMilliseconds) }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $stdinOk = $true
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($StdinText ?? ''))
        if ($bytes.Length -gt 0) {
            $writeTask = $proc.StandardInput.BaseStream.WriteAsync($bytes, 0, $bytes.Length)
            $stdinOk = $writeTask.Wait((& $remainingMs))
        }
        if ($stdinOk) { $proc.StandardInput.Close() }
    } catch { $stdinOk = $false; $r.ErrorMessage = $_.Exception.Message }
    # A child that exits without draining stdin is a normal failure, not a hang.
    if (-not $stdinOk -and $proc.HasExited) { $stdinOk = $true }
    $exited = $false
    if ($stdinOk) { $exited = $proc.WaitForExit((& $remainingMs)) }
    if (-not $exited) {
        $r.TimedOut = $true
        try { $proc.Kill($true) } catch {}
        $null = $proc.WaitForExit(10000)
    }
    try { $null = [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 15000) } catch {}
    if ($outTask.IsCompletedSuccessfully) { $r.Stdout = $outTask.Result }
    if ($errTask.IsCompletedSuccessfully) { $r.Stderr = $errTask.Result }
    $r.ExitCode = if ($r.TimedOut) { -1 } else { $proc.ExitCode }
    return $r
}

function Get-ReviewFilesystemState {
    $variable=$ExecutionContext.SessionState.PSVariable.Get('script:ReviewFilesystemState')
    if($null -ne $variable){return $variable.Value}
    return $null
}

function Assert-ReviewFilesystemStep {
    param([Parameter(Mandatory)][string]$Stage)
    $state=Get-ReviewFilesystemState
    if($null -eq $state){return}
    $state['Stage']=$Stage
    if($state['Abandoned'] -or (Get-ReviewRemainingMilliseconds -DeadlineTimestamp $state['Deadline']) -le 0){
        Throw-ReviewTransportFault 'filesystem_deadline'
    }
}

function Get-ReviewRemainingMilliseconds {
    param([long]$DeadlineTimestamp)
    $ticks=$DeadlineTimestamp-[Diagnostics.Stopwatch]::GetTimestamp()
    if($ticks -le 0){return 0}
    [int][Math]::Min([int]::MaxValue,[Math]::Floor($ticks*1000.0/[Diagnostics.Stopwatch]::Frequency))
}

function New-ReviewReadOnlyRecord {
    param([Collections.IDictionary]$Values)
    $copy=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($key in $Values.Keys){$copy.Add([string]$key,$Values[$key])}
    return ,[Collections.ObjectModel.ReadOnlyDictionary[string,object]]::new($copy)
}

function Get-ReviewSafeCause {
    param([Exception]$Exception,[int]$Depth=0)
    if($null -eq $Exception){return $null}
    # Bootstrap uses static CLR APIs only. Shared reflection metadata may have
    # ETS members; only fresh private open-instance delegates invoke it below.
    $bind={param([type]$DelegateType,[type]$Target,[string]$Name,[type[]]$Parameters=@()) [Delegate]::CreateDelegate($DelegateType,[Reflection.RuntimeReflectionExtensions]::GetRuntimeMethod($Target,$Name,$Parameters))}
    $getType=& $bind ([Func[object,type]]) ([object]) 'GetType'
    $getName=& $bind ([Func[type,string]]) ([type]) 'get_FullName'
    $getLength=& $bind ([Func[string,int]]) ([string]) 'get_Length'
    $getChars=& $bind ([Func[string,char[]]]) ([string]) 'ToCharArray'
    $getHResult=& $bind ([Func[Exception,int]]) ([Exception]) 'get_HResult'
    $getInner=& $bind ([Func[Exception,Exception]]) ([Exception]) 'get_InnerException'
    $getNative=& $bind ([Func[ComponentModel.Win32Exception,int]]) ([ComponentModel.Win32Exception]) 'get_NativeErrorCode'
    $getSocket=& $bind ([Func[Net.Sockets.SocketException,Net.Sockets.SocketError]]) ([Net.Sockets.SocketException]) 'get_SocketErrorCode'
    $getJsonLine=& $bind ([Func[Text.Json.JsonException,Nullable[long]]]) ([Text.Json.JsonException]) 'get_LineNumber'
    $getJsonByte=& $bind ([Func[Text.Json.JsonException,Nullable[long]]]) ([Text.Json.JsonException]) 'get_BytePositionInLine'
    $getHttpStatus=& $bind ([Func[Net.Http.HttpRequestException,Nullable[Net.HttpStatusCode]]]) ([Net.Http.HttpRequestException]) 'get_StatusCode'
    $rawType=$getName.Invoke($getType.Invoke($Exception));$type='System.Exception'
    if($rawType -is [string] -and $getLength.Invoke($rawType) -le 256){
        $type=[string]::new($getChars.Invoke($rawType))
        if(-not [regex]::IsMatch($type,'\A[A-Za-z0-9_.+\x60\[\], ]+\z',[Text.RegularExpressions.RegexOptions]::CultureInvariant)){$type='System.Exception'}
    }
    $cause=@{Type=$type;HResult=$getHResult.Invoke($Exception);JsonLine=$null;JsonByte=$null;SocketError=$null;HttpStatus=$null;NativeError=$null;Inner=$null;OmittedInnerCauses=0}
    if($Exception -is [ComponentModel.Win32Exception]){$cause.NativeError=$getNative.Invoke($Exception)}
    if($Exception -is [Net.Sockets.SocketException]){$cause.SocketError=[int]$getSocket.Invoke($Exception)}
    if($Exception -is [Text.Json.JsonException]){$cause.JsonLine=$getJsonLine.Invoke($Exception);$cause.JsonByte=$getJsonByte.Invoke($Exception)}
    if($Exception -is [Net.Http.HttpRequestException]){$status=$getHttpStatus.Invoke($Exception);if($null -ne $status){$cause.HttpStatus=[int]$status}}
    $inner=$getInner.Invoke($Exception)
    if($null -ne $inner){if($Depth -lt 2){$cause.Inner=Get-ReviewSafeCause -Exception $inner -Depth ($Depth+1)}else{$cause.OmittedInnerCauses=1}}
    New-ReviewReadOnlyRecord -Values $cause
}

function New-ReviewTransportFault {
    # Untyped identifiers avoid coercion during parameter binding. Every access
    # to boundary objects/metadata below uses a fresh private CLR delegate.
    param($Code,$Stage,[Exception]$Exception)
    $bind={param([type]$DelegateType,[type]$Target,[string]$Name,[type[]]$Parameters=@()) [Delegate]::CreateDelegate($DelegateType,[Reflection.RuntimeReflectionExtensions]::GetRuntimeMethod($Target,$Name,$Parameters))}
    $getType=& $bind ([Func[object,type]]) ([object]) 'GetType'
    $getName=& $bind ([Func[type,string]]) ([type]) 'get_FullName'
    $getAssembly=& $bind ([Func[type,Reflection.Assembly]]) ([type]) 'get_Assembly'
    $getField=& $bind ([Func[type,string,Reflection.BindingFlags,Reflection.FieldInfo]]) ([type]) 'GetField' ([type[]]@([string],[Reflection.BindingFlags]))
    $getFieldType=& $bind ([Func[Reflection.FieldInfo,type]]) ([Reflection.FieldInfo]) 'get_FieldType'
    $getFieldValue=& $bind ([Func[Reflection.FieldInfo,object,object]]) ([Reflection.FieldInfo]) 'GetValue' ([type[]]@([object]))
    $getProperty=& $bind ([Func[type,string,Reflection.PropertyInfo]]) ([type]) 'GetProperty' ([type[]]@([string]))
    $getPropertyMethod=& $bind ([Func[Reflection.PropertyInfo,Reflection.MethodInfo]]) ([Reflection.PropertyInfo]) 'get_GetMethod'
    $getDeclaring=& $bind ([Func[Reflection.MemberInfo,type]]) ([Reflection.MemberInfo]) 'get_DeclaringType'
    $getInner=& $bind ([Func[Exception,Exception]]) ([Exception]) 'get_InnerException'
    $getData=& $bind ([Func[Exception,Collections.IDictionary]]) ([Exception]) 'get_Data'
    $getCount=& $bind ([Func[Collections.ICollection,int]]) ([Collections.ICollection]) 'get_Count'
    $getEnumerator=& $bind ([Func[Collections.IDictionary,Collections.IDictionaryEnumerator]]) ([Collections.IDictionary]) 'GetEnumerator'
    $moveNext=& $bind ([Func[Collections.IEnumerator,bool]]) ([Collections.IEnumerator]) 'MoveNext'
    $getKey=& $bind ([Func[Collections.IDictionaryEnumerator,object]]) ([Collections.IDictionaryEnumerator]) 'get_Key'
    $getValue=& $bind ([Func[Collections.IDictionaryEnumerator,object]]) ([Collections.IDictionaryEnumerator]) 'get_Value'
    $getLength=& $bind ([Func[string,int]]) ([string]) 'get_Length'
    $getChars=& $bind ([Func[string,char[]]]) ([string]) 'ToCharArray'
    $copyText={
        param($Value,[int]$Maximum)
        if($Value -isnot [string]){return $null}
        $length=$getLength.Invoke($Value)
        if($length -lt 1 -or $length -gt $Maximum){return $null}
        return ,([string]::new($getChars.Invoke($Value)))
    }
    $identifier={param($Value) $text=& $copyText $Value 64;if($null -ne $text -and [regex]::IsMatch($text,'\A[a-z][a-z0-9_]{0,63}\z',[Text.RegularExpressions.RegexOptions]::CultureInvariant)){return $text};return $null}
    $Code=& $identifier $Code;if($null -eq $Code){$Code='owned_failure'}
    $Stage=& $identifier $Stage;if($null -eq $Stage){$Stage='unknown'}
    $flags=[Reflection.BindingFlags]'NonPublic,Instance,DeclaredOnly'
    $field={
        param([object]$Value,[string]$Name,[type]$Expected)
        if($null -eq $Value){throw [InvalidOperationException]::new('Missing structural fault field')}
        $entry=$getField.Invoke($getType.Invoke($Value),('<'+$Name+'>k__BackingField'),$flags)
        if($null -eq $entry -or -not [object]::ReferenceEquals($getFieldType.Invoke($entry),$Expected)){throw [InvalidOperationException]::new('Invalid structural fault field')}
        return ,($getFieldValue.Invoke($entry,$Value))
    }
    $copyTransportCause={
        param([object]$Value,[int]$Depth)
        if($null -eq $Value){return $null}
        $valueType=$getType.Invoke($Value)
        if(-not [string]::Equals($getName.Invoke($valueType),'GauntletTransport.SanitizedCause',[StringComparison]::Ordinal)){throw [InvalidOperationException]::new('Invalid structural cause')}
        $type=& $copyText (& $field $Value 'Type' ([string])) 256
        if($null -eq $type -or -not [regex]::IsMatch($type,'\A[A-Za-z0-9_.+\x60\[\], ]+\z',[Text.RegularExpressions.RegexOptions]::CultureInvariant)){throw [InvalidOperationException]::new('Invalid structural cause type')}
        $values=@{Type=$type;HResult=(& $field $Value 'HResult' ([int]));JsonLine=$null;JsonByte=$null;SocketError=$null;HttpStatus=$null;NativeError=$null;HeaderNameSha256=$null;Inner=$null;OmittedInnerCauses=0}
        foreach($name in @('JsonLine','JsonByte')){$values[$name]=& $field $Value $name ([Nullable[long]])}
        foreach($name in @('SocketError','HttpStatus','NativeError')){$values[$name]=& $field $Value $name ([Nullable[int]])}
        $rawHash=& $field $Value 'HeaderNameSha256' ([string]);$hash=if($null -eq $rawHash){$null}else{& $copyText $rawHash 64}
        if($null -ne $rawHash -and ($null -eq $hash -or -not [regex]::IsMatch($hash,'\A[0-9a-f]{64}\z',[Text.RegularExpressions.RegexOptions]::CultureInvariant))){throw [InvalidOperationException]::new('Invalid structural cause digest')}
        $values.HeaderNameSha256=$hash
        $omitted=& $field $Value 'OmittedInnerCauses' ([int]);if($omitted -lt 0){throw [InvalidOperationException]::new('Invalid structural cause count')};$values.OmittedInnerCauses=$omitted
        $innerField=$getField.Invoke($valueType,'<Inner>k__BackingField',$flags)
        if($null -eq $innerField -or -not [object]::ReferenceEquals($getFieldType.Invoke($innerField),$valueType)){throw [InvalidOperationException]::new('Invalid structural inner cause')}
        $inner=$getFieldValue.Invoke($innerField,$Value)
        if($null -ne $inner){if($Depth -lt 2){$values.Inner=& $copyTransportCause $inner ($Depth+1)}elseif($values.OmittedInnerCauses -lt [int]::MaxValue){$values.OmittedInnerCauses++}}
        New-ReviewReadOnlyRecord -Values $values
    }
    $coreAssembly=$getAssembly.Invoke([Exception]);$typed=$Exception
    for($i=0;$i -lt 8 -and $null -ne $typed;$i++){
        $runtimeType=$getType.Invoke($typed)
        if([string]::Equals($getName.Invoke($runtimeType),'GauntletTransport.TransportException',[StringComparison]::Ordinal)){
            try{
                $transportCode=& $identifier (& $field $typed 'Code' ([string]));$transportStage=& $identifier (& $field $typed 'Stage' ([string]))
                if($null -eq $transportCode -or $null -eq $transportStage){throw [InvalidOperationException]::new('Invalid structural fault identifier')}
                $causeField=$getField.Invoke($runtimeType,'<Cause>k__BackingField',$flags)
                if($null -eq $causeField -or -not [string]::Equals($getName.Invoke($getFieldType.Invoke($causeField)),'GauntletTransport.SanitizedCause',[StringComparison]::Ordinal)){throw [InvalidOperationException]::new('Invalid structural fault cause')}
                $safeCause=& $copyTransportCause ($getFieldValue.Invoke($causeField,$typed)) 0
                return (New-ReviewReadOnlyRecord -Values @{Code=$transportCode;Stage=$transportStage;Cause=$safeCause})
            }catch{}
        }
        $assembly=$getAssembly.Invoke($runtimeType);$framework=$false
        foreach($allowed in @([Exception],[Management.Automation.RuntimeException],[ComponentModel.Win32Exception],[Net.Sockets.SocketException],[Net.Http.HttpRequestException],[Text.Json.JsonException])){if([object]::ReferenceEquals($assembly,$getAssembly.Invoke($allowed))){$framework=$true;break}}
        if($framework){
            try{
                $property=$getProperty.Invoke($runtimeType,'Data');$getter=if($null -ne $property){$getPropertyMethod.Invoke($property)}else{$null}
                if($null -ne $getter -and [object]::ReferenceEquals($getDeclaring.Invoke($getter),[Exception])){
                    $data=$getData.Invoke($typed);$dataType=if($null -ne $data){$getType.Invoke($data)}else{$null}
                    if($null -ne $dataType -and [object]::ReferenceEquals($getAssembly.Invoke($dataType),$coreAssembly) -and [string]::Equals($getName.Invoke($dataType),'System.Collections.ListDictionaryInternal',[StringComparison]::Ordinal)){
                        $count=$getCount.Invoke($data)
                        if($count -le 8){
                            $candidateCode=$null;$candidateStage=$null;$enumerator=$getEnumerator.Invoke($data)
                            for($entryIndex=0;$entryIndex -lt $count;$entryIndex++){
                                if(-not $moveNext.Invoke($enumerator)){throw [InvalidOperationException]::new('Changed diagnostic dictionary')}
                                $key=$getKey.Invoke($enumerator)
                                if($key -is [string]){
                                    if([string]::Equals($key,'ReviewCode',[StringComparison]::Ordinal)){$candidateCode=$getValue.Invoke($enumerator)}
                                    elseif([string]::Equals($key,'ReviewStage',[StringComparison]::Ordinal)){$candidateStage=$getValue.Invoke($enumerator)}
                                }
                            }
                            $safeCode=& $identifier $candidateCode;$safeStage=& $identifier $candidateStage
                            if($null -ne $safeCode){$Code=$safeCode;if($null -ne $safeStage){$Stage=$safeStage};break}
                        }
                    }
                }
            }catch{}
        }
        $typed=$getInner.Invoke($typed)
    }
    New-ReviewReadOnlyRecord -Values @{Code=$Code;Stage=$Stage;Cause=(Get-ReviewSafeCause -Exception $Exception)}
}


function Throw-ReviewTransportFault {
    param([string]$Code)
    $fault=[InvalidOperationException]::new('Review attempt refused')
    $fault.Data['ReviewCode']=$Code
    throw $fault
}

function Get-ReviewOwnedPipelineDisposalAction {
    param($Owner,$Pipeline)
    # Both independent caller-owned objects are disposed by one retained CLR
    # task. No PowerShell scriptblock runs on its runspace-less task thread.
    $ownerType=[Collections.Concurrent.ConcurrentDictionary[string,object]]
    $setItem=$ownerType.GetProperty('Item').GetSetMethod()
    $dispose=[IDisposable].GetMethod('Dispose')
    $errorsType=[Collections.Generic.List[Exception]]
    $thunk=[Reflection.Emit.DynamicMethod]::new('GauntletOwnedPipelineDisposal',[void],[type[]]@([object[]]),$true)
    $il=$thunk.GetILGenerator();$op=[Reflection.Emit.OpCodes]
    $errors=$il.DeclareLocal($errorsType);$exception=$il.DeclareLocal([Exception])
    $il.Emit($op::Newobj,$errorsType.GetConstructor([type[]]@()));$il.Emit($op::Stloc,$errors)
    function Read-DisposalPack([int]$Index){$il.Emit($op::Ldarg_0);$il.Emit($op::Ldc_I4,$Index);$il.Emit($op::Ldelem_Ref)}
    function Write-DisposalFlag([string]$Name){Read-DisposalPack 2;$il.Emit($op::Castclass,$ownerType);$il.Emit($op::Ldstr,$Name);$il.Emit($op::Ldc_I4_1);$il.Emit($op::Box,[bool]);$il.Emit($op::Callvirt,$setItem)}
    foreach($entry in @(@{Index=0;Fault='PipelineDisposalException';Flag='PipelineDisposed'},@{Index=1;Fault='OutputDisposalException';Flag='OutputDisposed'})){
        $skip=$il.DefineLabel();Read-DisposalPack $entry.Index;$il.Emit($op::Brfalse,$skip)
        $null=$il.BeginExceptionBlock()
        Read-DisposalPack $entry.Index;$il.Emit($op::Castclass,[IDisposable]);$il.Emit($op::Callvirt,$dispose)
        Write-DisposalFlag $entry.Flag
        $il.BeginCatchBlock([Exception]);$il.Emit($op::Stloc,$exception)
        Read-DisposalPack 2;$il.Emit($op::Castclass,$ownerType);$il.Emit($op::Ldstr,$entry.Fault);$il.Emit($op::Ldloc,$exception);$il.Emit($op::Callvirt,$setItem)
        $il.Emit($op::Ldloc,$errors);$il.Emit($op::Ldloc,$exception);$il.Emit($op::Callvirt,$errorsType.GetMethod('Add'))
        $il.EndExceptionBlock();$il.MarkLabel($skip)
    }
    $done=$il.DefineLabel();$il.Emit($op::Ldloc,$errors);$il.Emit($op::Callvirt,$errorsType.GetProperty('Count').GetGetMethod());$il.Emit($op::Brfalse,$done)
    $il.Emit($op::Ldstr,'Independent owned pipeline resources failed disposal');$il.Emit($op::Ldloc,$errors)
    $il.Emit($op::Newobj,[AggregateException].GetConstructor([type[]]@([string],[Collections.Generic.IEnumerable[Exception]])));$il.Emit($op::Throw)
    $il.MarkLabel($done);$il.Emit($op::Ret)
    $pack=[object[]]@($Pipeline,$Owner['Output'],$Owner)
    return ,$thunk.CreateDelegate([Action],$pack)
}

function Start-ReviewPipelineDisposal {
    param($Owner,$Pipeline)
    $Owner['DisposalIntent']=$true
    $dispose=Get-ReviewOwnedPipelineDisposalAction -Owner $Owner -Pipeline $Pipeline
    $task=[Threading.Tasks.Task]::Run([Action]$dispose);$Owner['DisposeTask']=$task
    return ,$task
}

function Throw-ReviewCodedFailure {
    param([string]$Code,[string]$Stage,[Exception]$Exception)
    if($Code -cnotmatch '^[a-z][a-z0-9_]{0,63}$'){$Code='owned_failure'}
    if($Stage -cnotmatch '^[a-z][a-z0-9_]{0,63}$'){$Stage='unknown'}
    $failure=[InvalidOperationException]::new('Owned operation refused',$Exception)
    $failure.Data['ReviewCode']=$Code;$failure.Data['ReviewStage']=$Stage
    throw $failure
}

function Start-ReviewOwnedPipelineCreation {
    param($Owner,[string]$Bootstrap,[object[]]$ArgumentList)
    # Fixed CLR instructions, never a PowerShell callback on a runspace-less Task.
    # Creation AND all configuration run on that same retained creation task.
    $method=[Management.Automation.PowerShell].GetMethod('Create',[Type[]]@())
    if($null -eq $Owner){
        $create=[Delegate]::CreateDelegate([Func[object]],$method)
        return [Threading.Tasks.Task[object]]::Factory.StartNew([Func[object]]$create)
    }
    if($ArgumentList.Count -gt 8){Throw-ReviewCodedFailure 'owned_argument_bound' 'worker_create'}
    $ownerType=[Collections.Concurrent.ConcurrentDictionary[string,object]]
    $setItem=$ownerType.GetProperty('Item').GetSetMethod()
    $getItem=$ownerType.GetProperty('Item').GetGetMethod()
    $invoke=[Reflection.MethodBase].GetMethod('Invoke',[type[]]@([object],[object[]]))
    $getType=[object].GetMethod('GetType',[type[]]@())
    $getMethod=[type].GetMethod('GetMethod',[type[]]@([string],[type[]]))
    $clock=[Diagnostics.Stopwatch].GetMethod('GetTimestamp',[type[]]@())
    $getExactMethod=[type].GetMethod('GetMethod',[type[]]@([string],[int],[type[]]))
    $getProperty=[type].GetMethod('GetProperty',[type[]]@([string]))
    $getValue=[Reflection.PropertyInfo].GetMethod('GetValue',[type[]]@([object]))
    $initializer="param(`$owner)`n& {`n"+(Get-Command Initialize-ReviewOwnedStreams -CommandType Function).ScriptBlock.ToString()+"`n}`n`$owner['StreamType']=[GauntletOwnedWork.StreamGuard]"
    $thunk=[Reflection.Emit.DynamicMethod]::new('GauntletOwnedPipelineStartup',[object],[type[]]@([object[]]),$true)
    $il=$thunk.GetILGenerator();$op=[Reflection.Emit.OpCodes]
    $pipeline=$il.DeclareLocal([object]);$pipelineType=$il.DeclareLocal([type])
    $arguments=$il.DeclareLocal([object[]]);$index=$il.DeclareLocal([int]);$one=$il.DeclareLocal([object[]])
    $expired=$il.DefineLabel();$loop=$il.DefineLabel();$test=$il.DefineLabel()
    function Read-StartupPack([int]$Index){$il.Emit($op::Ldarg_0);$il.Emit($op::Ldc_I4,$Index);$il.Emit($op::Ldelem_Ref)}
    function Set-StartupStage([string]$Stage){
        Read-StartupPack 1;$il.Emit($op::Castclass,$ownerType);$il.Emit($op::Ldstr,'StartupStage');$il.Emit($op::Ldstr,$Stage);$il.Emit($op::Callvirt,$setItem)
    }
    function Test-StartupClock {
        $il.Emit($op::Call,$clock);Read-StartupPack 4;$il.Emit($op::Unbox_Any,[long]);$il.Emit($op::Bge,$expired)
        Read-StartupPack 1;$il.Emit($op::Castclass,$ownerType);$il.Emit($op::Ldstr,'Abandoned');$il.Emit($op::Callvirt,$getItem);$il.Emit($op::Unbox_Any,[bool]);$il.Emit($op::Brtrue,$expired)
    }
    function Invoke-StartupMethod([string]$Name,[int]$TypesIndex){
        $il.Emit($op::Ldloc,$pipelineType);$il.Emit($op::Ldstr,$Name);Read-StartupPack $TypesIndex;$il.Emit($op::Castclass,[type[]]);$il.Emit($op::Callvirt,$getMethod)
        $il.Emit($op::Ldloc,$pipeline);$il.Emit($op::Ldloc,$one);$il.Emit($op::Callvirt,$invoke);$il.Emit($op::Pop)
    }
    Set-StartupStage 'worker_create';Test-StartupClock
    Read-StartupPack 0;$il.Emit($op::Castclass,[Reflection.MethodBase]);$il.Emit($op::Ldnull);$il.Emit($op::Ldnull);$il.Emit($op::Callvirt,$invoke);$il.Emit($op::Stloc,$pipeline)
    # Publish the exact object before any configuration can block. The observer
    # cannot dispose it until this original creation task physically completes.
    Read-StartupPack 1;$il.Emit($op::Castclass,$ownerType);$il.Emit($op::Ldstr,'Pipeline');$il.Emit($op::Ldloc,$pipeline);$il.Emit($op::Callvirt,$setItem)
    Set-StartupStage 'worker_stream_init';Test-StartupClock
    $il.Emit($op::Ldloc,$pipeline);$il.Emit($op::Callvirt,$getType);$il.Emit($op::Stloc,$pipelineType)
    $il.Emit($op::Ldc_I4_1);$il.Emit($op::Newarr,[object]);$il.Emit($op::Stloc,$one)
    # Only fixed initializer source executes before guards are attached. It
    # compiles/validates the helper under this SAME original creation task.
    $il.Emit($op::Ldloc,$one);$il.Emit($op::Ldc_I4_0);Read-StartupPack 7;$il.Emit($op::Stelem_Ref)
    Invoke-StartupMethod 'AddScript' 5
    $il.Emit($op::Ldloc,$one);$il.Emit($op::Ldc_I4_0);Read-StartupPack 1;$il.Emit($op::Stelem_Ref)
    Invoke-StartupMethod 'AddArgument' 6
    $il.Emit($op::Ldloc,$pipelineType);$il.Emit($op::Ldstr,'Invoke');$il.Emit($op::Ldc_I4_0);Read-StartupPack 8;$il.Emit($op::Castclass,[type[]]);$il.Emit($op::Callvirt,$getExactMethod)
    $il.Emit($op::Ldloc,$pipeline);$il.Emit($op::Ldnull);$il.Emit($op::Callvirt,$invoke);$il.Emit($op::Pop)
    Test-StartupClock
    $il.Emit($op::Ldloc,$pipelineType);$il.Emit($op::Ldstr,'Commands');$il.Emit($op::Callvirt,$getProperty);$il.Emit($op::Ldloc,$pipeline);$il.Emit($op::Callvirt,$getValue)
    $il.Emit($op::Castclass,[Management.Automation.PSCommand]);$il.Emit($op::Callvirt,[Management.Automation.PSCommand].GetMethod('Clear'))
    $il.Emit($op::Ldloc,$pipelineType);$il.Emit($op::Ldstr,'Streams');$il.Emit($op::Callvirt,$getProperty);$il.Emit($op::Ldloc,$pipeline);$il.Emit($op::Callvirt,$getValue)
    $il.Emit($op::Castclass,[Management.Automation.PSDataStreams]);$il.Emit($op::Callvirt,[Management.Automation.PSDataStreams].GetMethod('ClearStreams'))
    Set-StartupStage 'worker_configure';Test-StartupClock
    $il.Emit($op::Ldloc,$one);$il.Emit($op::Ldc_I4_0);Read-StartupPack 2;$il.Emit($op::Stelem_Ref)
    Invoke-StartupMethod 'AddScript' 5
    Read-StartupPack 3;$il.Emit($op::Castclass,[object[]]);$il.Emit($op::Stloc,$arguments)
    $il.Emit($op::Ldc_I4_0);$il.Emit($op::Stloc,$index);$il.Emit($op::Br,$test)
    $il.MarkLabel($loop);Test-StartupClock
    $il.Emit($op::Ldloc,$one);$il.Emit($op::Ldc_I4_0);$il.Emit($op::Ldloc,$arguments);$il.Emit($op::Ldloc,$index);$il.Emit($op::Ldelem_Ref);$il.Emit($op::Stelem_Ref)
    Invoke-StartupMethod 'AddArgument' 6
    $il.Emit($op::Ldloc,$index);$il.Emit($op::Ldc_I4_1);$il.Emit($op::Add);$il.Emit($op::Stloc,$index)
    $il.MarkLabel($test);$il.Emit($op::Ldloc,$index);$il.Emit($op::Ldloc,$arguments);$il.Emit($op::Ldlen);$il.Emit($op::Conv_I4);$il.Emit($op::Blt,$loop)
    Test-StartupClock;$il.Emit($op::Ldloc,$pipeline);$il.Emit($op::Ret)
    $il.MarkLabel($expired);$il.Emit($op::Ldstr,'Original worker startup deadline expired');$il.Emit($op::Newobj,[TimeoutException].GetConstructor([type[]]@([string])));$il.Emit($op::Throw)
    $pack=[object[]]@($method,$Owner,$Bootstrap,[object[]]$ArgumentList,[long]$Owner['Deadline'],[type[]]@([string]),[type[]]@([object]),$initializer,[type[]]@())
    $create=$thunk.CreateDelegate([Func[object]],$pack)
    [Threading.Tasks.Task[object]]::Factory.StartNew([Func[object]]$create)
}

function Start-ReviewOwnedPipelineInvocation {
    param($Pipeline,$Owner)
    if($null -eq $Owner -or -not [object]::ReferenceEquals($Owner['Pipeline'],$Pipeline)){Throw-ReviewCodedFailure 'owned_owner_missing' 'worker_invoke'}
    $output=[Management.Automation.PSDataCollection[Management.Automation.PSObject]]::new(1)
    $Owner['Output']=$output
    if((Get-ReviewRemainingMilliseconds $Owner['Deadline']) -le 0){Throw-ReviewCodedFailure 'owned_deadline' 'worker_stream_init'}
    $verified=$Owner['StreamType']
    if($verified -isnot [type] -or -not [object]::ReferenceEquals($verified,('GauntletOwnedWork.StreamGuard' -as [type]))){Throw-ReviewCodedFailure 'owned_stream_source_missing' 'worker_stream_init'}
    $Owner['StreamGuard']=[GauntletOwnedWork.StreamGuard]::new($Pipeline,$output,$Owner)
    $methods=@($Pipeline.GetType().GetMethods()|Where-Object {$_.Name -ceq 'Invoke' -and $_.IsGenericMethodDefinition -and $_.GetGenericArguments().Count -eq 2 -and $_.GetParameters().Count -eq 3 -and $_.GetParameters()[0].ParameterType.IsGenericType -and $_.GetParameters()[0].ParameterType.GetGenericTypeDefinition() -eq [Management.Automation.PSDataCollection`1]})
    if($methods.Count -ne 1){Throw-ReviewCodedFailure 'owned_pipeline_shape' 'worker_invoke'}
    $method=$methods[0].MakeGenericMethod([type[]]@([Management.Automation.PSObject],[Management.Automation.PSObject]))
    $invoke=[Reflection.MethodBase].GetMethod('Invoke',[type[]]@([object],[object[]]))
    $thunk=[Reflection.Emit.DynamicMethod]::new('GauntletOwnedBoundedInvoke',[object],[type[]]@([object[]]),$true)
    $il=$thunk.GetILGenerator();$op=[Reflection.Emit.OpCodes]
    $il.Emit($op::Ldarg_0);$il.Emit($op::Ldc_I4_0);$il.Emit($op::Ldelem_Ref);$il.Emit($op::Castclass,[Reflection.MethodBase])
    $il.Emit($op::Ldarg_0);$il.Emit($op::Ldc_I4_1);$il.Emit($op::Ldelem_Ref)
    $il.Emit($op::Ldarg_0);$il.Emit($op::Ldc_I4_2);$il.Emit($op::Ldelem_Ref);$il.Emit($op::Castclass,[object[]])
    $il.Emit($op::Callvirt,$invoke);$il.Emit($op::Ret)
    $pack=[object[]]@($method,$Pipeline,[object[]]@($null,$output,$null))
    $action=$thunk.CreateDelegate([Func[object]],$pack)
    [Threading.Tasks.Task[object]]::Factory.StartNew([Func[object]]$action)
}

function Get-ReviewOwnedWorkEntries {
    param($OwnerRegistry,[string]$Token)
    $entries=[Collections.Generic.List[object]]::new()
    if(-not [Threading.Monitor]::TryEnter($OwnerRegistry)){return}
    try{
        foreach($key in $(if($Token){@($Token)}else{@($OwnerRegistry.Keys)})){
            if($OwnerRegistry.ContainsKey($key)){$entries.Add([pscustomobject]@{Token=$key;Owner=$OwnerRegistry[$key]})}
        }
    }finally{[Threading.Monitor]::Exit($OwnerRegistry)}
    $entries.ToArray()
}

function Remove-ReviewOwnedWorkEntry {
    param($OwnerRegistry,[string]$Token,$Owner)
    if(-not [Threading.Monitor]::TryEnter($OwnerRegistry)){return $false}
    try{
        if($OwnerRegistry.ContainsKey($Token) -and [object]::ReferenceEquals($OwnerRegistry[$Token],$Owner)){return $OwnerRegistry.Remove($Token)}
        return $false
    }finally{[Threading.Monitor]::Exit($OwnerRegistry)}
}

function Get-ReviewOwnedWorkFailures {
    param($Owner)
    # Each source publishes one immutable reference. No compound aggregation is
    # shared between the controller and concurrent completion observers.
    # Source order expresses diagnostic precedence, not measured chronology.
    $state=$Owner['State'];$sources=[Collections.Generic.List[object]]::new()
    if($state.ContainsKey('Failure') -and $null -ne $state['Failure']){$sources.Add($state['Failure'])}
    foreach($name in @('StreamFailure','CreationFailure','InvocationFailure','ErrorStreamFailure','DisposalFailure','OutputDisposalFailure','StopFailure','ObserverFailure','DeadlineFailure')){
        $fault=$Owner[$name];if($null -ne $fault){$sources.Add($fault)}
    }
    $primary=if($sources.Count){$sources[0]}else{$null}
    $deadlineFailure=$Owner['DeadlineFailure'];$kept=[Collections.Generic.List[object]]::new()
    foreach($item in $sources){
        if([object]::ReferenceEquals($primary,$item) -or [object]::ReferenceEquals($deadlineFailure,$item)){continue}
        $duplicate=$false;foreach($existing in $kept){if([object]::ReferenceEquals($existing,$item)){$duplicate=$true;break}}
        if(-not $duplicate -and $kept.Count -lt 2){$kept.Add($item)}
    }
    if($null -ne $deadlineFailure -and -not [object]::ReferenceEquals($primary,$deadlineFailure)){
        if($kept.Count -eq 2){$kept.RemoveAt(1)};$kept.Add($deadlineFailure)
    }
    New-ReviewReadOnlyRecord -Values @{Failure=$primary;CleanupFailures=[Array]::AsReadOnly([object[]]$kept.ToArray())}
}

function Complete-ReviewOwnedWork {
    param([Parameter(Mandatory)]$OwnerRegistry,[string]$Token)
    $snapshots=[Collections.Generic.List[object]]::new()
    foreach($entry in @(Get-ReviewOwnedWorkEntries -OwnerRegistry $OwnerRegistry -Token $Token)){
        $key=$entry.Token;$owner=$entry.Owner
        if(-not [Threading.Monitor]::TryEnter($owner)){continue}
        try{
        $state=$owner['State']
        # The sole startup producer publishes readiness only after every creation/submission
        # field is stored. The observer settles that publication under this same owner lock.
        # A null InvokeTask during configuration is never evidence of no submission.
        if($owner['StartupPublishPending']){$owner['StartupSettled']=$true}
        if((Get-ReviewRemainingMilliseconds $owner['Deadline']) -le 0){
            $owner['Abandoned']=$true;$owner['TimedOut']=$true;$state['Abandoned']=$true
            if($null -eq $owner['DeadlineFailure']){$null=$owner.TryAdd('DeadlineFailure',(New-ReviewTransportFault 'owned_deadline' 'owned_observer' $null))}
        }
        if(-not $owner['StartupSettled']){
            $faults=Get-ReviewOwnedWorkFailures -Owner $owner
            $owner['Failure']=$faults.Failure;$owner['CleanupFailures']=$faults.CleanupFailures
            $snapshot=New-ReviewReadOnlyRecord -Values @{Token=$key;Completed=$false;Retired=$false;TimedOut=[bool]$owner['TimedOut'];Result=$null;Failure=$faults.Failure;CleanupFailures=$faults.CleanupFailures}
            # The original owner lock serializes the final publication decision, including
            # a not-yet-settled startup snapshot. Preparing its DTO may itself cross expiry.
            if((Get-ReviewRemainingMilliseconds $owner['Deadline']) -le 0){
                $owner['Abandoned']=$true;$owner['TimedOut']=$true;$state['Abandoned']=$true
                if($null -eq $owner['DeadlineFailure']){$null=$owner.TryAdd('DeadlineFailure',(New-ReviewTransportFault 'owned_deadline' 'owned_observer' $null))}
                $faults=Get-ReviewOwnedWorkFailures -Owner $owner
                $owner['Failure']=$faults.Failure;$owner['CleanupFailures']=$faults.CleanupFailures
                $snapshot=New-ReviewReadOnlyRecord -Values @{Token=$key;Completed=$false;Retired=$false;TimedOut=$true;Result=$null;Failure=$faults.Failure;CleanupFailures=$faults.CleanupFailures}
            }
            $snapshots.Add($snapshot)
            continue
        }
        $created=$owner['CreationTask'];$invoked=$owner['InvokeTask'];$dispose=$owner['DisposeTask']
        if($null -ne $created -and $created.IsCompleted){
            if($created.IsCompletedSuccessfully){
                if($null -eq $owner['Pipeline']){$owner['Pipeline']=$created.Result}
            }else{
                if($null -eq $owner['CreationFailure']){$null=$owner.TryAdd('CreationFailure',(New-ReviewTransportFault -Code 'owned_creation' -Stage $owner['StartupStage'] -Exception $created.Exception))}
            }
            if($null -eq $invoked -or $invoked.IsCompleted){
                if($null -ne $invoked -and -not $invoked.IsCompletedSuccessfully){
                    if($null -eq $owner['InvocationFailure']){$null=$owner.TryAdd('InvocationFailure',(New-ReviewTransportFault -Code 'owned_invocation' -Stage 'worker_invoke' -Exception $invoked.Exception))}
                }
                if($null -ne $owner['StreamGuard'] -and $null -ne $owner['StreamGuard'].FirstError){
                    if($null -eq $owner['ErrorStreamFailure']){$null=$owner.TryAdd('ErrorStreamFailure',$owner['StreamGuard'].FirstError)}
                }
                if(-not $owner['Submitted'] -or -not $state.ContainsKey('ActionEntered')){$state['CoreRetired']=$true}
                if($null -ne $owner['Pipeline'] -and $null -eq $dispose -and (-not $owner['StopRequested'] -or ($null -ne $owner['StopTask'] -and $owner['StopTask'].IsCompleted))){
                    $dispose=Start-ReviewPipelineDisposal -Owner $owner -Pipeline $owner['Pipeline']
                }
            }
        }
        $workerDone=$null -ne $created -and $created.IsCompleted -and ($null -eq $invoked -or $invoked.IsCompleted)
        $disposed=($null -eq $owner['Pipeline'] -and $workerDone) -or ($null -ne $dispose -and $dispose.IsCompletedSuccessfully -and ($null -eq $owner['Output'] -or ($owner['OutputDisposed'] -is [bool] -and $owner['OutputDisposed'])))
        if($null -ne $owner['OutputDisposalException'] -and $null -eq $owner['OutputDisposalFailure']){$null=$owner.TryAdd('OutputDisposalFailure',(New-ReviewTransportFault -Code 'owned_output_disposal' -Stage 'worker_dispose' -Exception $owner['OutputDisposalException']))}
        if($null -ne $dispose -and $dispose.IsFaulted){
            if($null -eq $owner['DisposalFailure']){$null=$owner.TryAdd('DisposalFailure',(New-ReviewTransportFault -Code 'owned_disposal' -Stage 'worker_dispose' -Exception $dispose.Exception))}
        }
        $stop=$owner['StopTask'];$stopDone=-not $owner['StopRequested'] -or ($null -ne $stop -and $stop.IsCompletedSuccessfully)
        if($null -ne $stop -and ($stop.IsFaulted -or $stop.IsCanceled)){
            if($null -eq $owner['StopFailure']){$null=$owner.TryAdd('StopFailure',(New-ReviewTransportFault -Code 'owned_stop' -Stage 'worker_stop' -Exception $stop.Exception))}
        }
        $retired=$workerDone -and $disposed -and $stopDone -and $state['CoreRetired'] -is [bool] -and $state['CoreRetired']
        $faults=Get-ReviewOwnedWorkFailures -Owner $owner
        # Retained only for private diagnostics; public outcomes use this local
        # immutable projection, never the convenience fields as authority.
        $owner['Failure']=$faults.Failure;$owner['CleanupFailures']=$faults.CleanupFailures
        $failure=$faults.Failure
        $result=if($null -eq $failure -and -not $owner['Abandoned'] -and $null -ne $invoked -and $invoked.IsCompletedSuccessfully -and $state.ContainsKey('Result')){$state['Result']}else{$null}
        $snapshot=New-ReviewReadOnlyRecord -Values @{Token=$key;Completed=(-not $owner['Abandoned'] -and $null -ne $invoked -and $invoked.IsCompletedSuccessfully);Retired=[bool]$retired;TimedOut=[bool]$owner['TimedOut'];Result=$result;Failure=$failure;CleanupFailures=$faults.CleanupFailures}
        if($retired){$owner['RetirementConfirmed']=$true;$null=Remove-ReviewOwnedWorkEntry -OwnerRegistry $OwnerRegistry -Token $key -Owner $owner}
        # This is the acceptance linearization point under the original owner lock.
        # Disposal, projection, DTO construction and retirement bookkeeping above
        # cannot turn entry-time budget into permission to publish after expiry.
        if((Get-ReviewRemainingMilliseconds $owner['Deadline']) -le 0){
            $owner['Abandoned']=$true;$owner['TimedOut']=$true;$state['Abandoned']=$true
            if($null -eq $owner['DeadlineFailure']){$null=$owner.TryAdd('DeadlineFailure',(New-ReviewTransportFault 'owned_deadline' 'owned_observer' $null))}
            $faults=Get-ReviewOwnedWorkFailures -Owner $owner
            $owner['Failure']=$faults.Failure;$owner['CleanupFailures']=$faults.CleanupFailures
            $snapshot=New-ReviewReadOnlyRecord -Values @{Token=$key;Completed=$false;Retired=[bool]$retired;TimedOut=$true;Result=$null;Failure=$faults.Failure;CleanupFailures=$faults.CleanupFailures}
        }
        $snapshots.Add($snapshot)
        }finally{[Threading.Monitor]::Exit($owner)}
    }
    $snapshots.ToArray()
}

function Invoke-ReviewOwnedWork {
    param([Parameter(Mandatory)][string]$Kind,[Parameter(Mandatory)]$OwnerRegistry,[Parameter(Mandatory)][long]$DeadlineTimestamp,
        [Parameter(Mandatory)][string]$WorkerName,[Parameter(Mandatory)]$Definitions,$Arguments,
        [Parameter(Mandatory)]$State,[Collections.IDictionary]$SharedVariables=@{})
    $empty=@{Token=$null;Completed=$false;Retired=$true;TimedOut=$false;Result=$null;Failure=$null;CleanupFailures=[Array]::AsReadOnly([object[]]@())}
    $token=[guid]::NewGuid().ToString('n')
    $State['Deadline']=$DeadlineTimestamp;$State['CoreRetired']=$false;$State['Abandoned']=$false
    $owner=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($pair in @{Kind=$Kind;State=$State;Registry=$OwnerRegistry;Token=$token;Deadline=$DeadlineTimestamp;Abandoned=$false;TimedOut=$false;Submitted=$false;StartupSettled=$false;StartupPublishPending=$false;StartupStage='worker_create';RetirementConfirmed=$false;Pipeline=$null;CreationTask=$null;InvokeTask=$null;DisposeTask=$null;Failure=$null;CleanupFailures=@()}.GetEnumerator()){$owner[$pair.Key]=$pair.Value}
    if(-not [Threading.Monitor]::TryEnter($OwnerRegistry)){$empty.Failure=New-ReviewTransportFault 'registry_busy' 'entry' $null;return (New-ReviewReadOnlyRecord -Values $empty)}
    try{
        if($OwnerRegistry.Count -gt 0){$empty.Failure=New-ReviewTransportFault 'prior_owner_unresolved' 'entry' $null;return (New-ReviewReadOnlyRecord -Values $empty)}
        # Private original authority for callers that must reconcile a timed-out attempt.
        # Never included in immutable outcomes or diagnostic projections.
        $State['OwnedWorkOwner']=$owner
        $OwnerRegistry.Add($token,$owner)
    }finally{[Threading.Monitor]::Exit($OwnerRegistry)}
    try{
        if($Kind -cnotmatch '^[a-z][a-z0-9_-]{0,47}$' -or $WorkerName -cnotmatch '^[A-Za-z][A-Za-z0-9-]{0,127}$' -or $Definitions.Count -gt 256 -or $SharedVariables.Count -gt 128){Throw-ReviewCodedFailure 'owned_argument_bound' 'entry'}
        $workerDefinitions=@{}
        foreach($name in $Definitions.Keys){$workerDefinitions[$name]=$Definitions[$name]}
        foreach($name in @('New-ReviewReadOnlyRecord','Get-ReviewSafeCause','New-ReviewTransportFault','Throw-ReviewCodedFailure','Initialize-ReviewOwnedStreams')){
            if(-not $workerDefinitions.ContainsKey($name)){$workerDefinitions[$name]=(Get-Command $name -CommandType Function).ScriptBlock}
        }
        if((Get-ReviewRemainingMilliseconds $DeadlineTimestamp) -le 0){Throw-ReviewCodedFailure 'owned_deadline' 'entry'}
        $bootstrap=@'
param($state,$definitions,$arguments,$variables,$workerName)
$ErrorActionPreference='Stop'
foreach($key in $variables.Keys){Set-Variable -Name $key -Scope Script -Value $variables[$key]}
foreach($name in $definitions.Keys){
    # Never rebind the caller's ScriptBlock to another runspace. Preserve its original
    # File metadata, without claiming this copied body is the whole library AST.
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($definitions[$name].ToString(),$definitions[$name].File,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw [InvalidOperationException]::new('Owned definition refused')}
    Set-Item -LiteralPath ('function:'+ $name) -Value $ast.GetScriptBlock()
}
try {
    $script:ReviewOwnedWorkContext=$state
    if($state['Abandoned'] -or [Diagnostics.Stopwatch]::GetTimestamp() -ge [long]$state['Deadline']){Throw-ReviewCodedFailure 'owned_deadline' 'worker_entry'}
    $owner=$state['OwnedWorkOwner']
    if($null -eq $owner['StreamGuard']){Throw-ReviewCodedFailure 'owned_stream_missing' 'worker_stream_init'}
    if($state['Abandoned'] -or [Diagnostics.Stopwatch]::GetTimestamp() -ge [long]$state['Deadline']){Throw-ReviewCodedFailure 'owned_deadline' 'worker_entry'}
    $state['ActionEntered']=$true
    & $workerName -State $state -Arguments $arguments
}
catch {
    if(($null -eq $state['OwnedWorkOwner']['StreamFailure']) -and (-not $state.ContainsKey('Failure') -or $null -eq $state['Failure'])){$state['Failure']=New-ReviewTransportFault -Code 'owned_worker' -Stage $(if($state.ContainsKey('Stage')){$state['Stage']}else{'worker'}) -Exception $_.Exception}
}
'@
        $owner['CreationTask']=Start-ReviewOwnedPipelineCreation -Owner $owner -Bootstrap $bootstrap -ArgumentList @($State,$workerDefinitions,$Arguments,$SharedVariables,$WorkerName)
        if(-not $owner['CreationTask'].Wait((Get-ReviewRemainingMilliseconds $DeadlineTimestamp))){Throw-ReviewCodedFailure 'owned_deadline' 'worker_create'}
        $pipeline=$owner['CreationTask'].Result;$owner['Pipeline']=$pipeline
        if((Get-ReviewRemainingMilliseconds $DeadlineTimestamp) -le 0){Throw-ReviewCodedFailure 'owned_deadline' 'worker_start'}
        $owner['Submitted']=$true;$owner['InvokeTask']=Start-ReviewOwnedPipelineInvocation -Pipeline $pipeline -Owner $owner
        $owner['StartupPublishPending']=$true
        if(-not $owner['InvokeTask'].Wait((Get-ReviewRemainingMilliseconds $DeadlineTimestamp))){Throw-ReviewCodedFailure 'owned_deadline' 'worker'}
        $snapshot=Complete-ReviewOwnedWork -OwnerRegistry $OwnerRegistry -Token $token
        if($null -ne $owner['DisposeTask']){$null=$owner['DisposeTask'].Wait((Get-ReviewRemainingMilliseconds $DeadlineTimestamp));$observed=Complete-ReviewOwnedWork -OwnerRegistry $OwnerRegistry -Token $token;if($null -ne $observed){$snapshot=$observed}}
        if((Get-ReviewRemainingMilliseconds $DeadlineTimestamp) -le 0){Throw-ReviewCodedFailure 'owned_deadline' 'worker_dispose'}
        if($null -eq $snapshot){
            $owner['Abandoned']=$true;$State['Abandoned']=$true
            $null=$owner.TryAdd('ObserverFailure',(New-ReviewTransportFault 'owned_observer_unavailable' 'worker_observe' $null))
            $faults=Get-ReviewOwnedWorkFailures -Owner $owner
            $empty.Token=$token;$empty.Retired=$false;$empty.Failure=$faults.Failure;$empty.CleanupFailures=$faults.CleanupFailures
            return (New-ReviewReadOnlyRecord -Values $empty)
        }
        return $snapshot
    }catch{
        $observerFailure=New-ReviewTransportFault -Code 'owned_startup' -Stage $owner['StartupStage'] -Exception $_.Exception
        if($observerFailure.Code -ceq 'owned_deadline'){
            $null=$owner.TryAdd('DeadlineFailure',$observerFailure)
        }else{$null=$owner.TryAdd('ObserverFailure',$observerFailure)}
        $owner['TimedOut']=[bool]$owner['TimedOut'] -or (Get-ReviewRemainingMilliseconds $DeadlineTimestamp) -le 0
        $owner['Abandoned']=$true;$State['Abandoned']=$true
        $owner['StartupPublishPending']=$true
        if($null -eq $owner['CreationTask']){$State['CoreRetired']=$true;$owner['RetirementConfirmed']=$true;$null=Remove-ReviewOwnedWorkEntry -OwnerRegistry $OwnerRegistry -Token $token -Owner $owner;$faults=Get-ReviewOwnedWorkFailures -Owner $owner;$empty.Token=$token;$empty.Failure=$faults.Failure;$empty.TimedOut=$owner['TimedOut'];$empty.CleanupFailures=$faults.CleanupFailures;return (New-ReviewReadOnlyRecord -Values $empty)}
        $snapshot=Complete-ReviewOwnedWork -OwnerRegistry $OwnerRegistry -Token $token
        if($null -ne $snapshot){return $snapshot}
        # A deadline crossed just after confirmed disposal cannot erase the failure DTO.
        $faults=Get-ReviewOwnedWorkFailures -Owner $owner
        $empty.Token=$token;$empty.Retired=$false;$empty.Failure=$faults.Failure;$empty.TimedOut=$owner['TimedOut'];$empty.CleanupFailures=$faults.CleanupFailures
        New-ReviewReadOnlyRecord -Values $empty
    }
}
