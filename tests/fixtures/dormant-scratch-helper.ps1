# Test-only scratch custody. Never load production native/filesystem definitions.
function Initialize-DormantScratchHelper {
    if(-not $IsWindows){throw [PlatformNotSupportedException]::new('Scratch custody requires Windows')}
    $source=@'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;
namespace GauntletFixtureScratch {
 public sealed class Owner {
  public static string SourceIdentity {get{return "__IDENTITY__";}}
  static readonly ConcurrentDictionary<string,Owner> owners=new ConcurrentDictionary<string,Owner>();
  const uint Read=0x100081,Write=0x100083,Delete=0x110080;
  [StructLayout(LayoutKind.Sequential)] struct Unicode {public ushort Length,MaximumLength;public IntPtr Buffer;}
  [StructLayout(LayoutKind.Sequential)] struct ObjectAttributes {public int Length;public IntPtr Root,Name;public uint Attributes;public IntPtr Security,Quality;}
  [StructLayout(LayoutKind.Sequential)] struct IoStatus {public IntPtr Status,Information;}
  [StructLayout(LayoutKind.Sequential)] struct FileInfo {public uint Attributes;public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written;public uint Volume,SizeHigh,SizeLow,Links,IdHigh,IdLow;}
  [StructLayout(LayoutKind.Sequential)] struct Disposition { [MarshalAs(UnmanagedType.Bool)] public bool DeleteFile; }
  [StructLayout(LayoutKind.Sequential)] struct StandardInfo {public long AllocationSize,EndOfFile;public uint Links;[MarshalAs(UnmanagedType.U1)]public bool DeletePending;[MarshalAs(UnmanagedType.U1)]public bool Directory;}
  [DllImport("ntdll.dll",EntryPoint="NtCreateFile")] static extern uint NativeNtCreateFile(out IntPtr handle,uint access,ref ObjectAttributes attributes,out IoStatus status,IntPtr allocation,uint fileAttributes,uint share,uint disposition,uint options,IntPtr ea,uint eaLength);
  [DllImport("ntdll.dll",EntryPoint="RtlNtStatusToDosError")] static extern uint RtlNtStatusToDosError(uint status);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true,EntryPoint="CreateFileW")] static extern IntPtr NativeCreateFileW(string path,uint access,uint sharing,IntPtr security,uint creation,uint flags,IntPtr template);
  [DllImport("kernel32.dll",SetLastError=true,EntryPoint="ReOpenFile")] static extern IntPtr NativeReOpenFile(IntPtr original,uint access,uint sharing,uint flags);
  [DllImport("kernel32.dll",SetLastError=true,EntryPoint="GetFileInformationByHandle")] static extern bool NativeGetFileInformationByHandle(IntPtr handle,out FileInfo info);
  [DllImport("kernel32.dll",SetLastError=true,EntryPoint="SetFileInformationByHandle")] static extern bool NativeSetFileInformationByHandle(IntPtr handle,int kind,ref Disposition info,uint size);
  [DllImport("kernel32.dll",SetLastError=true,EntryPoint="WriteFile")] static extern bool NativeWriteFile(IntPtr handle,byte[] bytes,int length,out int written,IntPtr overlapped);
  [DllImport("kernel32.dll",SetLastError=true,EntryPoint="ReadFile")] static extern bool NativeReadFile(IntPtr handle,byte[] bytes,int length,out int read,IntPtr overlapped);
  [DllImport("kernel32.dll",SetLastError=true,EntryPoint="GetFileSizeEx")] static extern bool NativeGetFileSizeEx(IntPtr handle,out long length);
  [DllImport("kernel32.dll",SetLastError=true,EntryPoint="GetFileInformationByHandleEx")] static extern bool NativeGetFileInformationByHandleEx(IntPtr handle,int kind,out StandardInfo info,uint size);
  [DllImport("kernel32.dll",SetLastError=true,EntryPoint="FlushFileBuffers")] static extern bool NativeFlushFileBuffers(IntPtr handle);
  [DllImport("kernel32.dll",SetLastError=true,EntryPoint="CloseHandle")] static extern bool NativeCloseHandle(IntPtr handle);
  [DllImport("kernel32.dll",SetLastError=true,EntryPoint="DeviceIoControl")] static extern bool NativeDeviceIoControl(IntPtr handle,uint code,byte[] input,int inputSize,IntPtr output,int outputSize,out int returned,IntPtr overlapped);
  uint NtCreateFile(out IntPtr handle,uint access,ref ObjectAttributes attributes,out IoStatus status,IntPtr allocation,uint fileAttributes,uint share,uint disposition,uint options,IntPtr ea,uint eaLength){BeforeOperation("NtCreateFile");return NativeNtCreateFile(out handle,access,ref attributes,out status,allocation,fileAttributes,share,disposition,options,ea,eaLength);}
  IntPtr CreateFileW(string path,uint access,uint sharing,IntPtr security,uint creation,uint flags,IntPtr template){BeforeOperation("CreateFileW");return NativeCreateFileW(path,access,sharing,security,creation,flags,template);}
  IntPtr ReOpenFile(IntPtr original,uint access,uint sharing,uint flags){BeforeOperation("ReOpenFile");return NativeReOpenFile(original,access,sharing,flags);}
  bool GetFileInformationByHandle(IntPtr handle,out FileInfo info,Owner observingOwner=null){BeforeOperation("GetFileInformationByHandle",observingOwner);return NativeGetFileInformationByHandle(handle,out info);}
  bool SetFileInformationByHandle(IntPtr handle,int kind,ref Disposition info,uint size){BeforeOperation("SetFileInformationByHandle");return NativeSetFileInformationByHandle(handle,kind,ref info,size);}
  bool WriteFile(IntPtr handle,byte[] bytes,int length,out int written,IntPtr overlapped){BeforeOperation("WriteFile");return NativeWriteFile(handle,bytes,length,out written,overlapped);}
  bool ReadFile(IntPtr handle,byte[] bytes,int length,out int read,IntPtr overlapped){BeforeOperation("ReadFile");return NativeReadFile(handle,bytes,length,out read,overlapped);}
  bool GetFileSizeEx(IntPtr handle,out long length){BeforeOperation("GetFileSizeEx");return NativeGetFileSizeEx(handle,out length);}
  bool GetFileInformationByHandleEx(IntPtr handle,int kind,out StandardInfo info,uint size){BeforeOperation("GetFileInformationByHandleEx");return NativeGetFileInformationByHandleEx(handle,kind,out info,size);}
  bool FlushFileBuffers(IntPtr handle){BeforeOperation("FlushFileBuffers");return NativeFlushFileBuffers(handle);}
  bool CloseHandle(IntPtr handle){BeforeOperation("CloseHandle");return NativeCloseHandle(handle);}
  bool DeviceIoControl(IntPtr handle,uint code,byte[] input,int inputSize,IntPtr output,int outputSize,out int returned,IntPtr overlapped){BeforeOperation("DeviceIoControl");return NativeDeviceIoControl(handle,code,input,inputSize,output,outputSize,out returned,overlapped);}
  sealed class Leaf { public string Name,Identity;public IntPtr Handle,Seal,DeleteHandle,BindingHandle;public bool Disposed,Absent; }
  sealed class ExternalControl {public string Name,Identity;public FileStream Stream;public SafeFileHandle Original;public IntPtr DeleteHandle;public bool Closed;}
  readonly List<IntPtr> parents=new List<IntPtr>();
  readonly List<Leaf> leaves=new List<Leaf>();
  readonly List<JunctionControl> controls=new List<JunctionControl>();
  readonly List<IntPtr> probes=new List<IntPtr>();
  readonly List<ExternalControl> externalControls=new List<ExternalControl>();
  IntPtr root;string rootIdentity,rootLeaf;bool rootDisposed,failed;
  internal sealed class Operation {
   public Task Task;public bool Observed;
   readonly object failureGate=new object();
   readonly List<Exception> failures=new List<Exception>();
   Exception overflow;
   // The finite owner topology is smaller than this bound. Never replace the
   // first cause or call user-controlled equality/formatting while recording.
   public void RecordFailure(Exception error){
    if(error==null)return;
    lock(failureGate){
     foreach(var known in failures)if(Object.ReferenceEquals(known,error))return;
     if(failures.Count<255)failures.Add(error);
     else if(overflow==null){overflow=new InvalidOperationException("Scratch observed-failure custody bound exceeded; additional causes unresolved");failures.Add(overflow);}
    }
   }
   public Exception[] SnapshotFailures(){lock(failureGate){return failures.ToArray();}}
  }
  Task pending;
  Operation pendingOperation,writeOperation,cleanupOperation;
  readonly object gate=new object();
  public string Token{get;}=Guid.NewGuid().ToString("n");
  public string Path{get;}
  public long Deadline{get;}
  public bool Retired{get;private set;}
  public Task OriginalTask{get{lock(gate){return pending;}}}
  // Deterministic adversarial control, in this test utility only. The native
  // cleanup worker retains all original objects while the fixture substitutes.
  public ManualResetEventSlim BeforeDeleteEntered,ContinueDelete;
  public ManualResetEventSlim BeforeSealEntered,ContinueSeal;
  // Test-only admission controls surround the actual native boundary. A held
  // call remains the original worker; no cancellation, new deadline or owner.
  public bool TraceOperations;
  public readonly ConcurrentQueue<string> OperationTrace=new ConcurrentQueue<string>();
  public string BlockOperation;
  public int BlockOccurrence=1;
  public ManualResetEventSlim OperationEntered,ContinueOperation;
  public ManualResetEventSlim BeforeRetirementEntered,ContinueRetirement;
  public ManualResetEventSlim BeforeWaitAcceptanceEntered,ContinueWaitAcceptance;
  int operationGateUsed,operationOccurrences;
  void BeforeOperation(string operation,Owner observingOwner=null){
   Check();if(observingOwner!=null)observingOwner.Check();
   if(TraceOperations)OperationTrace.Enqueue(operation);
   if(operation==BlockOperation&&Interlocked.Increment(ref operationOccurrences)==BlockOccurrence&&Interlocked.Exchange(ref operationGateUsed,1)==0){
    if(OperationEntered!=null)OperationEntered.Set();
    if(ContinueOperation==null)throw new InvalidOperationException("Scratch operation control missing");
    ContinueOperation.Wait();
   }
  }
  void AcceptanceControl(ManualResetEventSlim entered,ManualResetEventSlim release){
   if(entered==null)return;entered.Set();
   if(release==null)throw new InvalidOperationException("Scratch acceptance control missing");
   release.Wait();
  }
  // Public observers cannot remain on a fixture gate beyond the original clock.
  // Worker-owned adversarial gates deliberately retain the original task instead.
  void ObserverAcceptanceControl(ManualResetEventSlim entered,ManualResetEventSlim release){
   if(entered==null)return;entered.Set();
   if(release==null)throw new InvalidOperationException("Scratch observer acceptance control missing");
   if(!release.Wait(Left()))throw new TimeoutException("Original scratch observer acceptance control expired");
  }
  int deleteGateUsed;
  public Owner(string path,long deadline){
   Path=System.IO.Path.GetFullPath(path);Deadline=deadline;
   if(Path.Length<4||Path.Length>1024||Path[1]!=':'||Path[2]!='\\'||Path.Split('\\').Length>32)throw new ArgumentException("Bounded local fixed scratch drive required");
   owners.TryAdd(Token,this);
  }
  int Left(){return (int)Math.Clamp((Deadline-Stopwatch.GetTimestamp())*1000/Stopwatch.Frequency,0L,int.MaxValue);}
  void Check(){if(Left()==0)throw new TimeoutException("Original scratch deadline expired");}
  static void Require(bool success){if(!success)throw new Win32Exception(Marshal.GetLastWin32Error());}
  static bool Invalid(IntPtr value){return value==IntPtr.Zero||value==new IntPtr(-1);}
  void Close(ref IntPtr handle){if(Invalid(handle)){handle=IntPtr.Zero;return;}Require(CloseHandle(handle));handle=IntPtr.Zero;}
  void CloseBoth(Operation operation,ref IntPtr first,ref IntPtr second){var failures=new List<Exception>();try{Close(ref first);}catch(Exception error){operation.RecordFailure(error);failures.Add(error);}try{Close(ref second);}catch(Exception error){operation.RecordFailure(error);failures.Add(error);}if(failures.Count!=0)throw new AggregateException("Independent scratch closure failed",failures);}
  static void Name(string name){if(String.IsNullOrEmpty(name)||name.Length>128||name=="."||name==".."||name.EndsWith(".")||name.EndsWith(" ")||name.IndexOfAny(new[]{'\\','/',':','\0','*','?','"','<','>','|'})>=0)throw new ArgumentException("Invalid scratch leaf");}
  FileInfo RawInfo(IntPtr handle,Owner observingOwner=null){FileInfo info;Require(GetFileInformationByHandle(handle,out info,observingOwner));return info;}
  FileInfo Info(IntPtr handle,Owner observingOwner=null){var info=RawInfo(handle,observingOwner);if((info.Attributes&0x400)!=0)throw new IOException("Scratch reparse point refused");return info;}
  string Identity(IntPtr handle,Owner observingOwner=null){var info=Info(handle,observingOwner);return info.Volume.ToString("x8")+":"+info.IdHigh.ToString("x8")+info.IdLow.ToString("x8");}
  string RawIdentity(IntPtr handle){var info=RawInfo(handle);return info.Volume.ToString("x8")+":"+info.IdHigh.ToString("x8")+info.IdLow.ToString("x8");}
  IntPtr Relative(IntPtr parent,string name,bool create,bool directory,uint access,uint sharing,out bool missing){
   Name(name);missing=false;var chars=Marshal.StringToHGlobalUni(name);IntPtr unicode=IntPtr.Zero;
   try{
    var text=new Unicode{Length=(ushort)(name.Length*2),MaximumLength=(ushort)(name.Length*2+2),Buffer=chars};
    unicode=Marshal.AllocHGlobal(Marshal.SizeOf<Unicode>());Marshal.StructureToPtr(text,unicode,false);
    var attributes=new ObjectAttributes{Length=Marshal.SizeOf<ObjectAttributes>(),Root=parent,Name=unicode,Attributes=0x40};
    IntPtr handle;IoStatus status;
    uint code=NtCreateFile(out handle,access,ref attributes,out status,IntPtr.Zero,0,sharing,create?2u:1u,0x200020u|(directory?1u:0x40u),IntPtr.Zero,0);
    if(code==0xc0000034u||code==0xc000000fu){missing=true;return IntPtr.Zero;}
    if(code>=0x80000000u)throw new Win32Exception((int)RtlNtStatusToDosError(code));
    return handle;
   }finally{if(unicode!=IntPtr.Zero)Marshal.FreeHGlobal(unicode);Marshal.FreeHGlobal(chars);}
  }
  Operation Start(Action<Operation> action,bool cleanup){
   lock(gate){
    if(Retired)throw new InvalidOperationException("Scratch already retired");
    if(pendingOperation!=null&&(!pendingOperation.Task.IsCompleted||!pendingOperation.Observed))throw new InvalidOperationException("Original scratch operation pending or unobserved");
    if(failed&&!cleanup)throw new InvalidOperationException("Failed scratch producer fenced");
    Check();var operation=new Operation();
    operation.Task=new Task(()=>{try{Check();action(operation);Check();}catch(Exception error){operation.RecordFailure(error);failed=true;throw;}},CancellationToken.None,TaskCreationOptions.DenyChildAttach);
    pendingOperation=operation;pending=operation.Task;
    try{operation.Task.Start(TaskScheduler.Default);}catch(Exception error){operation.RecordFailure(error);failed=true;throw;}return operation;
   }
  }
  void Wait(Operation operation){
   var task=operation.Task;Exception primary=null,acceptance=null;bool incomplete=false;
   try{
    try{
     if(!task.Wait(Left())){incomplete=true;failed=true;throw new TimeoutException("Original scratch worker unresolved at deadline");}
     task.GetAwaiter().GetResult();
    }catch(Exception error){primary=error;}
    try{ObserverAcceptanceControl(BeforeWaitAcceptanceEntered,ContinueWaitAcceptance);Check();}
    catch(Exception error){failed=true;acceptance=error;}
    if(incomplete){
     var observed=operation.SnapshotFailures();
     if(observed.Length!=0){var partial=new List<Exception>(observed);if(primary!=null)partial.Add(primary);primary=new AggregateException("Observed original scratch failures and independent incomplete worker",partial);}
    }
    if(acceptance!=null){if(primary!=null)throw new AggregateException("Original scratch failure and independent completion refusal",primary,acceptance);System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(acceptance).Throw();}
    if(primary!=null)System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(primary).Throw();
   }finally{lock(gate){operation.Observed=true;}}
  }
  void Run(Action<Operation> action,bool cleanup=false){var operation=Start(action,cleanup);Wait(operation);}
  void Run(Action action,bool cleanup=false){Run(operation=>action(),cleanup);}
  public void Initialize(){Run(()=>{
   BeforeOperation("DriveType");if(new DriveInfo(System.IO.Path.GetPathRoot(Path)).DriveType!=DriveType.Fixed)throw new ArgumentException("Bounded local fixed scratch drive required");
   if(root!=IntPtr.Zero||parents.Count!=0)throw new InvalidOperationException("Scratch initialization is single use");
   var drive=System.IO.Path.GetPathRoot(Path);var current=CreateFileW("\\\\?\\"+drive,Read,3,IntPtr.Zero,3,0x2200000,IntPtr.Zero);
   if(Invalid(current))throw new Win32Exception(Marshal.GetLastWin32Error());parents.Add(current);Info(current);
   var parts=Path.Substring(drive.Length).Split('\\');
   for(int index=0;index<parts.Length-1;index++){
    Check();bool missing;current=Relative(current,parts[index],false,true,Read,3,out missing);
    if(missing)throw new DirectoryNotFoundException("Scratch ancestor missing");parents.Add(current);Info(current);
   }
   rootLeaf=parts[parts.Length-1];bool absent;
   Check();root=Relative(current,rootLeaf,true,true,Delete|1,3,out absent);
   if(absent)throw new DirectoryNotFoundException("Scratch parent missing");rootIdentity=Identity(root);Check();
  });}
  public string FilePath(string name){Name(name);return System.IO.Path.Combine(Path,name);}
  void AssertRoot(Owner observingOwner=null){if(root==IntPtr.Zero||rootDisposed||Identity(root,observingOwner)!=rootIdentity)throw new InvalidOperationException("Original scratch root unavailable");}
  void WriteCore(string name,string text){
   AssertRoot();Name(name);if(leaves.Exists(value=>value.Name==name))throw new InvalidOperationException("Scratch leaf already owned");
   if(leaves.Count>=32||text==null||text.Length>1048576||Encoding.UTF8.GetByteCount(text)>1048576)throw new ArgumentException("Scratch fixture content or owner bound exceeded");
   var leaf=new Leaf{Name=name};leaves.Add(leaf);bool missing;
   Check();leaf.Handle=Relative(root,name,true,false,Write,7,out missing);
   if(missing)throw new DirectoryNotFoundException("Scratch root missing");leaf.Identity=Identity(leaf.Handle);
   var bytes=Encoding.UTF8.GetBytes(text);int written;Check();Require(WriteFile(leaf.Handle,bytes,bytes.Length,out written,IntPtr.Zero));if(written!=bytes.Length)throw new IOException("Partial scratch write");Require(FlushFileBuffers(leaf.Handle));
   var read=ReOpenFile(leaf.Handle,Read,7,0);if(Invalid(read))throw new Win32Exception(Marshal.GetLastWin32Error());
   // Publish the exact read handle before closing its original writer.
   leaf.Seal=read;Close(ref leaf.Handle);leaf.Handle=leaf.Seal;leaf.Seal=IntPtr.Zero;
   if(BeforeSealEntered!=null){BeforeSealEntered.Set();if(ContinueSeal==null||!ContinueSeal.Wait(Left()))throw new TimeoutException("Original scratch seal control expired");}
   Check();leaf.Seal=ReOpenFile(leaf.Handle,Read,1,0);if(Invalid(leaf.Seal)){leaf.Seal=IntPtr.Zero;throw new Win32Exception(Marshal.GetLastWin32Error());}
   if(Identity(leaf.Handle)!=leaf.Identity||Identity(leaf.Seal)!=leaf.Identity)throw new IOException("Scratch identity changed");
   // The close/reopen handoff is accepted only after the immutable seal is
   // acquired: verify BOTH the original bytes and the current relative name.
   // This catches a write or rename before sealing, without adopting its result.
   long length;Require(GetFileSizeEx(leaf.Handle,out length));if(length!=bytes.Length)throw new IOException("Scratch bytes changed before sealing");
   var buffer=new byte[4096];int offset=0;
   while(offset<bytes.Length){Check();int count;Require(ReadFile(leaf.Handle,buffer,Math.Min(buffer.Length,bytes.Length-offset),out count,IntPtr.Zero));if(count==0)throw new IOException("Scratch verification ended early");for(int index=0;index<count;index++)if(buffer[index]!=bytes[offset+index])throw new IOException("Scratch bytes changed before sealing");offset+=count;}
   leaf.BindingHandle=Relative(root,name,false,false,Read,7,out missing);if(missing||Identity(leaf.BindingHandle)!=leaf.Identity)throw new IOException("Scratch original name binding changed before sealing");Close(ref leaf.BindingHandle);Check();
  }
  public void WriteText(string name,string text){Run(()=>WriteCore(name,text));}
  public void BeginWriteText(string name,string text){lock(gate){writeOperation=Start(operation=>WriteCore(name,text),false);}}
  public void WaitWriteText(){Operation operation;lock(gate){operation=writeOperation;}if(operation==null)throw new InvalidOperationException("Original BeginWriteText operation unavailable");Wait(operation);}
  public string ReadText(string name){string text=null;Run(()=>{
   AssertRoot();var leaf=leaves.Find(value=>value.Name==name);if(leaf==null||leaf.Disposed||leaf.Seal==IntPtr.Zero)throw new InvalidOperationException("Scratch read requires original sealed leaf");
   // This path is used only while original root/ancestor and no-delete-sharing
   // leaf seals are retained. Its content cannot be replaced or rewritten.
   BeforeOperation("ReadAllText");text=File.ReadAllText(FilePath(name));Check();
  });return text;}
  public bool VerifyAbsent(string name){bool absent=false;Run(operation=>{AssertRoot();absent=Absent(operation,root,name);},true);return absent;}
  int ReserveProbe(){int slot=probes.FindIndex(handle=>handle==IntPtr.Zero);if(slot>=0)return slot;if(probes.Count>=32)throw new InvalidOperationException("Unresolved scratch observation bound exceeded");probes.Add(IntPtr.Zero);return probes.Count-1;}
  void CloseProbe(int slot){var handle=probes[slot];try{Close(ref handle);}finally{probes[slot]=handle;}}
  bool Absent(Operation operation,IntPtr parent,string name,bool directory=false){
   bool missing;Check();int slot=ReserveProbe();var handle=Relative(parent,name,false,directory,Read,7,out missing);if(missing)return true;probes[slot]=handle;Exception primary=null;
   try{Info(handle);return false;}catch(Exception error){operation.RecordFailure(error);primary=error;throw;}finally{try{CloseProbe(slot);}catch(Exception cleanup){operation.RecordFailure(cleanup);if(primary!=null)primary.Data["ScratchProbeCleanupFailure"]=cleanup;else throw;}}
  }
  void DispositionOriginal(IntPtr handle){var disposition=new Disposition{DeleteFile=true};Require(SetFileInformationByHandle(handle,4,ref disposition,(uint)Marshal.SizeOf<Disposition>()));}
  void RemoveLeaf(Operation operation,Leaf leaf){
   Close(ref leaf.BindingHandle);
   if(leaf.Identity==null){if(leaf.Handle!=IntPtr.Zero)throw new IOException("Original scratch identity unresolved");return;}
   if(!leaf.Disposed){
    Close(ref leaf.Seal);Check();
    if(BeforeDeleteEntered!=null&&Interlocked.Exchange(ref deleteGateUsed,1)==0){BeforeDeleteEntered.Set();if(ContinueDelete==null||!ContinueDelete.Wait(Left()))throw new TimeoutException("Original scratch deletion control expired");}
    if(leaf.DeleteHandle==IntPtr.Zero){leaf.DeleteHandle=ReOpenFile(leaf.Handle,Delete,7,0);if(Invalid(leaf.DeleteHandle)){leaf.DeleteHandle=IntPtr.Zero;throw new Win32Exception(Marshal.GetLastWin32Error());}}
    if(Identity(leaf.DeleteHandle)!=leaf.Identity)throw new IOException("Original scratch deletion identity differs");
    Check();DispositionOriginal(leaf.DeleteHandle);CloseBoth(operation,ref leaf.Handle,ref leaf.DeleteHandle);leaf.Disposed=true;
   }
   leaf.Absent=Absent(operation,root,leaf.Name);if(!leaf.Absent)throw new IOException("Scratch replacement remains; cleanup refused");
  }
  public void RemoveFile(string name){Run(operation=>{AssertRoot();var leaf=leaves.Find(value=>value.Name==name);if(leaf==null)throw new InvalidOperationException("Scratch file was not created by this owner");RemoveLeaf(operation,leaf);},true);}
  SafeFileHandle CaptureControlHandle(FileStream stream){BeforeOperation("StreamSafeFileHandle");return stream.SafeFileHandle;}
  public bool ControlDeletePending(FileStream stream){bool deleted=false;Run(()=>{Check();StandardInfo info;Require(GetFileInformationByHandleEx(CaptureControlHandle(stream).DangerousGetHandle(),1,out info,(uint)Marshal.SizeOf<StandardInfo>()));deleted=info.DeletePending;},true);return deleted;}
  public void RemoveControlFile(string name,FileStream stream){
   Name(name);ExternalControl control;
   lock(gate){control=externalControls.Find(value=>Object.ReferenceEquals(value.Stream,stream));if(control==null){if(externalControls.Count>=8)throw new InvalidOperationException("External control bound exceeded");control=new ExternalControl{Name=name,Stream=stream};externalControls.Add(control);}else if(control.Name!=name)throw new InvalidOperationException("External control name changed");}
   Run(operation=>{
    if(control.Original==null)control.Original=CaptureControlHandle(control.Stream);
    AssertRoot();if(!control.Closed){
     if(control.Identity==null)control.Identity=Identity(control.Original.DangerousGetHandle());
     if(control.DeleteHandle==IntPtr.Zero){control.DeleteHandle=ReOpenFile(control.Original.DangerousGetHandle(),Delete,7,0);if(Invalid(control.DeleteHandle)){control.DeleteHandle=IntPtr.Zero;throw new Win32Exception(Marshal.GetLastWin32Error());}}
     if(Identity(control.DeleteHandle)!=control.Identity)throw new IOException("External original control identity differs");Check();DispositionOriginal(control.DeleteHandle);
     var errors=new List<Exception>();try{BeforeOperation("StreamDispose");control.Stream.Dispose();if(!control.Original.IsClosed)throw new IOException("External original stream closure unresolved");}catch(Exception error){operation.RecordFailure(error);errors.Add(error);}try{Close(ref control.DeleteHandle);}catch(Exception error){operation.RecordFailure(error);errors.Add(error);}
     if(errors.Count!=0)throw new AggregateException("Independent original control closure failed",errors);control.Closed=true;
    }
    if(!Absent(operation,root,control.Name))throw new IOException("External original control removal unverified");
   },true);
  }
  public sealed class JunctionControl {
   internal Owner Parent;internal string Name,Identity;internal IntPtr ParentHandle,Handle,Writer,DeleteHandle;internal bool Deleted;
   internal void Remove(Operation operation){
    if(Deleted)return;Parent.Check();
    if(Writer!=IntPtr.Zero){if(Parent.RawIdentity(Writer)!=Identity)throw new IOException("Original junction identity differs");Parent.DispositionOriginal(Writer);Parent.CloseBoth(operation,ref Handle,ref Writer);}
    else{
     if(DeleteHandle==IntPtr.Zero){if(Handle==IntPtr.Zero)throw new IOException("Original junction custody missing");bool missing;DeleteHandle=Parent.Relative(ParentHandle,Name,false,true,Delete|1,7,out missing);if(missing)throw new IOException("Original junction entry missing");}
     if(Parent.RawIdentity(DeleteHandle)!=Identity){
      var primary=new IOException("Junction replacement refused");operation.RecordFailure(primary);
      try{Parent.Close(ref DeleteHandle);}catch(Exception cleanup){operation.RecordFailure(cleanup);primary.Data["ScratchJunctionCleanupFailure"]=cleanup;}
      throw primary;
     }Parent.DispositionOriginal(DeleteHandle);Parent.CloseBoth(operation,ref Handle,ref DeleteHandle);
    }
    Deleted=true;
   }
  }
  public string SiblingPath(string name){Name(name);return System.IO.Path.Combine(System.IO.Path.GetDirectoryName(Path),name);}
  public void CreateSiblingJunctionControl(string name,Owner target){Run(()=>{
   AssertRoot();target.AssertRoot(this);Name(name);if(controls.Count>=8)throw new InvalidOperationException("Scratch junction control bound exceeded");var parent=parents[parents.Count-1];var control=new JunctionControl{Parent=this,ParentHandle=parent,Name=name};controls.Add(control);bool missing;
   control.Writer=Relative(parent,name,true,true,Delete|3,7,out missing);if(missing)throw new IOException("Junction control parent missing");control.Identity=Identity(control.Writer);
   var substitute="\\??\\"+target.Path;var print=target.Path;var pathBytes=Encoding.Unicode.GetBytes(substitute+"\0"+print+"\0");
   var data=new byte[16+pathBytes.Length];Array.Copy(BitConverter.GetBytes(0xa0000003u),0,data,0,4);Array.Copy(BitConverter.GetBytes((ushort)(8+pathBytes.Length)),0,data,4,2);
   Array.Copy(BitConverter.GetBytes((ushort)(substitute.Length*2)),0,data,10,2);Array.Copy(BitConverter.GetBytes((ushort)((substitute.Length+1)*2)),0,data,12,2);Array.Copy(BitConverter.GetBytes((ushort)(print.Length*2)),0,data,14,2);Array.Copy(pathBytes,0,data,16,pathBytes.Length);
   int returned;Check();Require(DeviceIoControl(control.Writer,0x900a4,data,data.Length,IntPtr.Zero,0,out returned,IntPtr.Zero));Check();
   control.Handle=Relative(parent,name,false,true,Read,7,out missing);if(missing||RawIdentity(control.Handle)!=RawIdentity(control.Writer))throw new IOException("Junction creation identity differs");Close(ref control.Writer);Check();
  });}
  void CleanupCore(Operation operation){
   var failures=new List<Exception>();
   for(int index=0;index<probes.Count;index++){try{Check();CloseProbe(index);}catch(Exception error){operation.RecordFailure(error);failures.Add(error);}}
   foreach(var leaf in leaves){try{Check();RemoveLeaf(operation,leaf);}catch(Exception error){operation.RecordFailure(error);failures.Add(error);}}
   foreach(var control in controls){try{Check();control.Remove(operation);if(!Absent(operation,control.ParentHandle,control.Name))throw new IOException("Junction control removal unverified");}catch(Exception error){operation.RecordFailure(error);failures.Add(error);}}
   if(externalControls.Exists(control=>!control.Closed)){var error=new IOException("External original control custody unresolved");operation.RecordFailure(error);failures.Add(error);}
   if(failures.Count==0&&root!=IntPtr.Zero&&!rootDisposed){try{Check();if(Identity(root)!=rootIdentity)throw new IOException("Original scratch root identity differs");DispositionOriginal(root);Close(ref root);rootDisposed=true;}catch(Exception error){operation.RecordFailure(error);failures.Add(error);}}
   if(rootDisposed){try{Check();if(!Absent(operation,parents[parents.Count-1],rootLeaf,true))throw new IOException("Original scratch root removal unverified");}catch(Exception error){operation.RecordFailure(error);failures.Add(error);}}
   if(failures.Count==0&&(rootDisposed||root==IntPtr.Zero)){
    for(int index=parents.Count-1;index>=0;index--){var handle=parents[index];try{Check();Close(ref handle);parents[index]=handle;}catch(Exception error){operation.RecordFailure(error);failures.Add(error);}}
    if(failures.Count==0){AcceptanceControl(BeforeRetirementEntered,ContinueRetirement);Check();Retired=true;Owner retained;if(owners.TryGetValue(Token,out retained)&&Object.ReferenceEquals(this,retained))owners.TryRemove(Token,out retained);}
   }
   if(failures.Count!=0)throw new AggregateException("Original scratch cleanup refused",failures);
  }
  public void BeginCleanup(){lock(gate){cleanupOperation=Start(CleanupCore,true);}}
  public void WaitCleanup(){Operation operation;lock(gate){operation=cleanupOperation;}if(operation==null)throw new InvalidOperationException("Original BeginCleanup operation unavailable");Wait(operation);}
  public void Cleanup(){Run(CleanupCore,true);}
 }
}
'@
    $identity=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source))).ToLowerInvariant()
    $type='GauntletFixtureScratch.Owner' -as [type]
    if($null -ne $type){
        $property=$type.GetProperty('SourceIdentity',[Reflection.BindingFlags]'Public,Static')
        if($null -eq $property -or $property.PropertyType -ne [string] -or -not [string]::Equals($property.GetValue($null),$identity,[StringComparison]::Ordinal)){throw [InvalidOperationException]::new('Scratch helper source differs')}
        return
    }
    Add-Type -TypeDefinition ($source.Replace('__IDENTITY__',$identity)) -ErrorAction Stop
}
function New-DormantScratchOwner {
    param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,47}$')][string]$Prefix,[ValidateRange(1,180)][int]$TimeoutSec=120,[string]$Path)
    Initialize-DormantScratchHelper
    if(-not $Path){$Path=Join-Path ([IO.Path]::GetTempPath()) ($Prefix+'-'+[guid]::NewGuid().ToString('n'))}
    # Constructor performs no filesystem work. Caller retains this exact owner
    # before Initialize can create even a partial root/ancestor hold.
    [GauntletFixtureScratch.Owner]::new($Path,([Diagnostics.Stopwatch]::GetTimestamp()+[long]$TimeoutSec*[Diagnostics.Stopwatch]::Frequency))
}
function Complete-DormantScratchCleanup {
    param($Primary,[scriptblock[]]$Actions)
    $failures=[Collections.Generic.List[Exception]]::new()
    foreach($action in $Actions){try{& $action}catch{$failures.Add($_.Exception)}}
    if($failures.Count -gt 0){
        if($null -ne $Primary){
            $previous=@();if($Primary.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($Primary.Exception.Data['DormantFixtureCleanupFailures'])}
            $Primary.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$failures.ToArray()))
        }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$failures.ToArray())}
    }
}
