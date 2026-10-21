$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;
public sealed class NativeFixturePipe:IDisposable {
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe,out uint pid);
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe,out uint pid);
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool inJob);
 public readonly string Name="gauntlet-native-"+Guid.NewGuid().ToString("N"),Nonce=Guid.NewGuid().ToString("N");
 public static NativeFixturePipe Original;
 public readonly long Deadline;
 public readonly int ServerPid=Environment.ProcessId;
 public NamedPipeServerStream Server;
 public SafePipeHandle Handle;
 public Process Child;
 public Task Initialization,Connection,PipeDisposal,ProcessDisposal;
 public Task<int> Read;
 readonly byte[] buffer=new byte[64];
 public bool Retired,CleanupOnTime;
 public Exception InitializationError,PipeDisposalError,ProcessDisposalError;
 int requested,initialized,pipeDisposalStarted,processDisposalStarted;
 public NativeFixturePipe(long deadline){
  Deadline=deadline;
  if(Interlocked.CompareExchange(ref Original,this,null)!=null)throw new InvalidOperationException("Original pipe scope already exists");
  // Publish each original task before any task body can perform its first I/O.
  Initialization=new Task(()=>{
   try{
    Admit(Deadline);Server=new NamedPipeServerStream(Name,PipeDirection.In,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous|PipeOptions.CurrentUserOnly,64,64);
    Admit(Deadline);Handle=Server.SafePipeHandle;
    Admit(Deadline);Connection=Server.WaitForConnectionAsync();
   }catch(Exception error){InitializationError=error;throw;}
   finally{Volatile.Write(ref initialized,1);if(Volatile.Read(ref requested)!=0)StartDisposals();}
  });
  PipeDisposal=new Task(()=>{try{Admit(Deadline);if(Server!=null)Server.Dispose();Admit(Deadline);}catch(Exception error){PipeDisposalError=error;throw;}});
  ProcessDisposal=new Task(()=>{try{Admit(Deadline);if(Child!=null)Child.Dispose();Admit(Deadline);}catch(Exception error){ProcessDisposalError=error;throw;}});
  Initialization.Start(TaskScheduler.Default);
  Wait(Initialization,Deadline);
 }
 public static int Remaining(long deadline){return (int)Math.Clamp((deadline-Stopwatch.GetTimestamp())*1000/Stopwatch.Frequency,0L,int.MaxValue);}
 public static void Admit(long deadline){if(Remaining(deadline)<=0)throw new TimeoutException("Original fixture pipe deadline");}
 public static void Wait(Task task,long deadline){
  if(task==null)throw new InvalidOperationException("Original fixture task was not admitted");
  while(!task.IsCompleted&&Remaining(deadline)>0)Thread.Sleep(Math.Min(5,Remaining(deadline)));
  if(!task.IsCompleted)throw new TimeoutException("Original fixture pipe task deadline");
  task.GetAwaiter().GetResult();Admit(deadline);
 }
 public int ReadPid(){
  Wait(Connection,Deadline);
  Admit(Deadline);uint peer;if(!GetNamedPipeClientProcessId(Handle,out peer))throw new Win32Exception(Marshal.GetLastWin32Error());
  Admit(Deadline);
  if(peer==0||peer>int.MaxValue)throw new InvalidOperationException("Invalid pipe client PID");
  int used=0;
  while(used<buffer.Length){
   Admit(Deadline);Read=Server.ReadAsync(buffer,used,buffer.Length-used);Wait(Read,Deadline);
   int count=Read.GetAwaiter().GetResult();if(count==0)break;used+=count;
   if(buffer[used-1]==10)break;
  }
  if(Encoding.ASCII.GetString(buffer,0,used)!=Nonce+":"+peer.ToString(CultureInfo.InvariantCulture)+"\n")throw new InvalidOperationException("Original pipe nonce or peer mismatch");
  return (int)peer;
 }
 public void VerifyJob(int pid,object originalCustody){
  var type=originalCustody.GetType();object sync=type.GetField("JobSync").GetValue(originalCustody);
  Admit(Deadline);if(!Monitor.TryEnter(sync))throw new InvalidOperationException("Original job query busy");
  try{
   long nativeDeadline=(long)type.GetField("Deadline").GetValue(originalCustody);
   Admit(Deadline);Admit(nativeDeadline);
   IntPtr job=(IntPtr)type.GetField("Job").GetValue(originalCustody);
   if(job==IntPtr.Zero||(bool)type.GetField("JobClosed").GetValue(originalCustody))throw new InvalidOperationException("Original job already closed");
   Admit(Deadline);Admit(nativeDeadline);Child=Process.GetProcessById(pid);
   Admit(Deadline);Admit(nativeDeadline);IntPtr process=Child.Handle;
   Admit(Deadline);Admit(nativeDeadline);bool contained;if(!IsProcessInJob(process,job,out contained))throw new Win32Exception(Marshal.GetLastWin32Error());
   Admit(Deadline);Admit(nativeDeadline);
   if(!contained)throw new InvalidOperationException("Pipe sender is outside original native job");
  }finally{Monitor.Exit(sync);}
 }
 public bool Alive(){Admit(Deadline);bool alive=!Child.HasExited;Admit(Deadline);return alive;}
 public bool Exited(int milliseconds){Admit(Deadline);bool exited=Child.WaitForExit(Math.Min(milliseconds,Remaining(Deadline)));Admit(Deadline);return exited;}
 void StartDisposals(){
  // Independent original attempts: a pipe-disposal fault cannot skip process disposal.
  if(Volatile.Read(ref initialized)==0)return;
  if(Interlocked.CompareExchange(ref pipeDisposalStarted,1,0)==0)PipeDisposal.Start(TaskScheduler.Default);
  if(Interlocked.CompareExchange(ref processDisposalStarted,1,0)==0)ProcessDisposal.Start(TaskScheduler.Default);
 }
 static void Observe(Task task,long deadline){
  if(task==null)return;
  while(!task.IsCompleted&&Remaining(deadline)>0)Thread.Sleep(Math.Min(5,Remaining(deadline)));
  if(task.IsFaulted){var observed=task.Exception;}
 }
 public void Dispose(){
  Volatile.Write(ref requested,1);StartDisposals();
  foreach(var task in new Task[]{Initialization,PipeDisposal,ProcessDisposal,Connection,Read})Observe(task,Deadline);
  Retired=Initialization.IsCompleted&&PipeDisposal.IsCompletedSuccessfully&&ProcessDisposal.IsCompletedSuccessfully&&
   InitializationError==null&&PipeDisposalError==null&&ProcessDisposalError==null&&Handle!=null&&Handle.IsClosed&&
   Connection!=null&&Connection.IsCompleted&&(Read==null||Read.IsCompleted);
  CleanupOnTime=Remaining(Deadline)>0;
 }
 sealed class ClientScope {
  public NamedPipeClientStream Client;public SafePipeHandle Handle;public Task Connection,Write,Flush,Disposal;
  public readonly long Deadline;public Exception DisposalError;
  public ClientScope(long deadline){Deadline=deadline;}
  public void Dispose(){
   Disposal=new Task(()=>{try{Admit(Deadline);if(Client!=null)Client.Dispose();Admit(Deadline);}catch(Exception error){DisposalError=error;throw;}});
   Disposal.Start(TaskScheduler.Default);Observe(Disposal,Deadline);
   foreach(var task in new Task[]{Connection,Write,Flush})Observe(task,Deadline);

  }
 }
 static ClientScope originalClient;
 public static void Send(string name,string nonce,int expectedServer,long deadline){
  if(name==null||!name.StartsWith("gauntlet-native-",StringComparison.Ordinal)||name.Length!=48||nonce==null||nonce.Length!=32)throw new ArgumentException("Invalid original pipe coordinates");
  foreach(char c in name.Substring(16)+nonce)if(!((c>='a'&&c<='f')||(c>='0'&&c<='9')))throw new ArgumentException("Invalid original pipe coordinates");
  var scope=new ClientScope(deadline);
  if(Interlocked.CompareExchange(ref originalClient,scope,null)!=null)throw new InvalidOperationException("Original client scope already exists");
  Exception primary=null;
  try{
   Admit(deadline);scope.Client=new NamedPipeClientStream(".",name,PipeDirection.Out,PipeOptions.Asynchronous);
   Admit(deadline);scope.Connection=scope.Client.ConnectAsync(Remaining(deadline));Wait(scope.Connection,deadline);
   Admit(deadline);scope.Handle=scope.Client.SafePipeHandle;
   Admit(deadline);uint server;if(!GetNamedPipeServerProcessId(scope.Handle,out server))throw new Win32Exception(Marshal.GetLastWin32Error());Admit(deadline);
   if(server!=(uint)expectedServer)throw new InvalidOperationException("Original pipe server PID mismatch");
   byte[] bytes=Encoding.ASCII.GetBytes(nonce+":"+Environment.ProcessId.ToString(CultureInfo.InvariantCulture)+"\n");
   Admit(deadline);scope.Write=scope.Client.WriteAsync(bytes,0,bytes.Length);Wait(scope.Write,deadline);
   Admit(deadline);scope.Flush=scope.Client.FlushAsync();Wait(scope.Flush,deadline);
  }catch(Exception error){primary=error;}
  finally{scope.Dispose();}
  var errors=new System.Collections.Generic.List<Exception>();
  if(primary!=null)errors.Add(primary);
  if(scope.DisposalError!=null)errors.Add(scope.DisposalError);
  if(scope.Disposal==null||!scope.Disposal.IsCompletedSuccessfully)errors.Add(new TimeoutException("Original child pipe disposal did not retire"));
  foreach(var task in new Task[]{scope.Connection,scope.Write,scope.Flush})if(task!=null&&!task.IsCompleted)errors.Add(new TimeoutException("Original child pipe operation remains pending"));
  if(errors.Count!=0)throw new AggregateException("Original pipe send and cleanup failures",errors);
 }
}
public static class NativeFixtureCleanup {
 public static Task Blocking,Caller;
 public static Exception BlockingError,CallerError;
 public static bool Retired;
 public static void Start(CancellationTokenRegistration blocking,CancellationTokenSource caller,long deadline){
  Blocking=new Task(()=>{try{NativeFixturePipe.Admit(deadline);blocking.Dispose();NativeFixturePipe.Admit(deadline);}catch(Exception error){BlockingError=error;throw;}});
  Caller=new Task(()=>{try{NativeFixturePipe.Admit(deadline);caller.Dispose();NativeFixturePipe.Admit(deadline);}catch(Exception error){CallerError=error;throw;}});
  Blocking.Start(TaskScheduler.Default);Caller.Start(TaskScheduler.Default);
 }
 public static void Finish(long deadline){
  foreach(var task in new Task[]{Blocking,Caller}){try{NativeFixturePipe.Wait(task,deadline);}catch{}}
  Retired=Blocking.IsCompletedSuccessfully&&Caller.IsCompletedSuccessfully&&BlockingError==null&&CallerError==null&&NativeFixturePipe.Remaining(deadline)>0;
 }
}
'@
