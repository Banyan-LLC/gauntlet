
namespace GauntletFixtureScratch {
 using System.Reflection;
 public static class AdditionalAdmissionCases {
  static bool Timeout(Exception e){
   if(e==null)return false;if(e is TimeoutException)return true;
   if(e is AggregateException)foreach(var inner in ((AggregateException)e).InnerExceptions)if(Timeout(inner))return true;
   return Timeout(e.InnerException);
  }
  static void Require(bool value,string message){if(!value)throw new Exception(message);}
  static void Settle(Task task){Require(SpinWait.SpinUntil(()=>task.IsCompleted,3000),"original task failed to settle");}
  static IntPtr Root(Owner owner){return (IntPtr)typeof(Owner).GetField("root",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(owner);}
  static Owner New(string name,int seconds){
   var owner=new Owner(System.IO.Path.Combine(System.IO.Path.GetTempPath(),"scratch-r3-cross-"+name+"-"+Guid.NewGuid().ToString("n")),Stopwatch.GetTimestamp()+Stopwatch.Frequency*seconds);
   owner.Initialize();return owner;
  }

  static int ManagedCapture(){
   const string name="safe-handle-capture-original-task";Owner owner=null;Task api=null;FileStream stream=null;
   try{
    owner=New("capture",3);stream=new FileStream(owner.FilePath("control.txt"),FileMode.CreateNew,FileAccess.ReadWrite,FileShare.ReadWrite|FileShare.Delete);
    stream.WriteByte(97);
    owner.TraceOperations=true;owner.BlockOperation="StreamSafeFileHandle";owner.OperationEntered=new ManualResetEventSlim(false);owner.ContinueOperation=new ManualResetEventSlim(false);
    var deadline=owner.Deadline;Exception apiFailure=null;
    api=Task.Run(()=>{try{owner.RemoveControlFile("control.txt",stream);}catch(Exception error){apiFailure=error;}});
    Require(owner.OperationEntered.Wait(2000),"original SafeFileHandle getter gate not reached");
    var original=owner.OriginalTask;bool pendingBeforeRelease=!original.IsCompleted;
    var controls=(System.Collections.IList)typeof(Owner).GetField("externalControls",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(owner);
    bool enrolledBeforeGetter=controls.Count==1&&Object.ReferenceEquals(controls[0].GetType().GetField("Stream").GetValue(controls[0]),stream);
    bool originalNotYetCaptured=enrolledBeforeGetter&&controls[0].GetType().GetField("Original").GetValue(controls[0])==null;
    int admitted=owner.OperationTrace.Count;
    while(Stopwatch.GetTimestamp()<=deadline+Stopwatch.Frequency/100)Thread.Sleep(2);
    bool publicCallBounded=SpinWait.SpinUntil(()=>api.IsCompleted,500);
    Exception observed=null;try{owner.WaitCleanup();}catch(Exception error){observed=error;}
    owner.ContinueOperation.Set();Settle(original);Settle(api);
    Require(pendingBeforeRelease,"blocking getter ran outside original pending task");
    Require(enrolledBeforeGetter&&originalNotYetCaptured,"exact original stream was not enrolled before blocking getter");
    Require(publicCallBounded&&Timeout(apiFailure),"public cleanup call hung beyond original deadline while getter remained held");
    Require(Timeout(observed)&&Timeout(original.Exception),"original getter timeout was not retained independently of completion");
    Require(owner.OperationTrace.Count==admitted,"new I/O admitted after original getter resumed beyond deadline");
    Require(Object.ReferenceEquals(original,owner.OriginalTask)&&owner.Deadline==deadline&&!owner.Retired,"original getter authority changed");
    Require(stream.CanRead&&Root(owner)!=IntPtr.Zero,"unattempted original stream/root closure custody lost");
    Console.WriteLine("PASS "+name);return 0;
   }catch(Exception error){Console.WriteLine("FAIL "+name+": "+error.Message);return 1;}
   finally{
    if(owner!=null&&owner.ContinueOperation!=null)owner.ContinueOperation.Set();
    if(api!=null)Settle(api);
    if(owner!=null&&owner.OriginalTask!=null)Settle(owner.OriginalTask);
    if(owner!=null&&!owner.Retired)Console.WriteLine("RETAINED_ORIGINAL_RESOURCE "+owner.Path);
   }
  }
  public static int Run(){
   int failed=0;
   foreach(bool blockTarget in new[]{false,true}){
    string name=blockTarget?"target-read-original-caller-expiry":"caller-read-before-target-admission";
    Owner caller=null,target=null,blocked=null;Task api=null;Exception apiFailure=null;
    try{
     caller=New("caller",3);target=New("target",30);target.WriteText("sentinel.txt","unchanged");
     var deadline=caller.Deadline;var targetDeadline=target.Deadline;caller.TraceOperations=true;target.TraceOperations=true;
     blocked=blockTarget?target:caller;blocked.BlockOperation="GetFileInformationByHandle";blocked.OperationEntered=new ManualResetEventSlim(false);blocked.ContinueOperation=new ManualResetEventSlim(false);
     api=Task.Run(()=>{try{caller.CreateSiblingJunctionControl("scratch-cross-"+Guid.NewGuid().ToString("n"),target);}catch(Exception error){apiFailure=error;}});
     Require(blocked.OperationEntered.Wait(2000),"original held-root read gate not reached");
     var original=caller.OriginalTask;var originalTarget=target.OriginalTask;int admittedCaller=caller.OperationTrace.Count,admittedTarget=target.OperationTrace.Count;
     while(Stopwatch.GetTimestamp()<=deadline+Stopwatch.Frequency/100)Thread.Sleep(2);
     Exception observed=null;try{caller.WaitCleanup();}catch(Exception error){observed=error;}
     Require(Timeout(observed)&&!original.IsCompleted,"original caller timeout and pending custody not independently preserved");
     blocked.ContinueOperation.Set();Settle(original);Settle(api);
     Require(target.OperationTrace.Count==(blockTarget?admittedTarget:0),"healthy target admitted a read after original caller expired");
     Require(caller.OperationTrace.Count==admittedCaller,"expired caller admitted I/O after original held-root call");
     Require(Timeout(original.Exception)&&Timeout(apiFailure),"original caller did not preserve timeout after physical completion");
     Require(Object.ReferenceEquals(original,caller.OriginalTask)&&Object.ReferenceEquals(originalTarget,target.OriginalTask),"original owner task identity changed");
     Require(caller.Deadline==deadline&&target.Deadline==targetDeadline&&Stopwatch.GetTimestamp()<targetDeadline,"original deadline authority changed");
     Require(!caller.Retired&&Root(caller)!=IntPtr.Zero&&Root(target)!=IntPtr.Zero,"original held-root custody was lost");
     Require(target.ReadText("sentinel.txt")=="unchanged","target original content changed");
     Console.WriteLine("PASS "+name);
    }catch(Exception error){failed++;Console.WriteLine("FAIL "+name+": "+error.Message);}
    finally{
     if(blocked!=null&&blocked.ContinueOperation!=null)blocked.ContinueOperation.Set();
     if(caller!=null&&caller.OriginalTask!=null)Settle(caller.OriginalTask);
     if(api!=null)Settle(api);
     if(target!=null)target.Cleanup();
     if(caller!=null&&!caller.Retired)Console.WriteLine("RETAINED_ORIGINAL_RESOURCE "+caller.Path);
    }
   }
   failed+=ManagedCapture();Console.WriteLine("TOTAL 3; FAILURES "+failed);return failed;
  }
 }
}
