namespace GauntletFixtureScratch {
 using System.Reflection;
 public static class DeadlineCases {
  static readonly List<string> results=new List<string>();
  static int failures;
  static readonly List<Owner> retainedOwners=new List<Owner>();
  static readonly BindingFlags Private=BindingFlags.NonPublic|BindingFlags.Instance;
  static void Assert(bool value,string message){if(!value)throw new Exception(message);}
  static bool Timeout(Exception error){
   if(error==null)return false;if(error is TimeoutException)return true;
   if(error is AggregateException){foreach(var inner in ((AggregateException)error).InnerExceptions)if(Timeout(inner))return true;}
   return Timeout(error.InnerException);
  }
  static object Field(object value,string name){return value.GetType().GetField(name,Private|BindingFlags.Public).GetValue(value);}
  static IntPtr Handle(object value,string name){return (IntPtr)Field(value,name);}
  static object First(object owner,string name){return ((System.Collections.IList)Field(owner,name))[0];}
  static Owner New(string name){var owner=new Owner(System.IO.Path.Combine(System.IO.Path.GetTempPath(),"scratch-r3-"+name+"-"+Guid.NewGuid().ToString("n")),Stopwatch.GetTimestamp()+Stopwatch.Frequency*3);retainedOwners.Add(owner);owner.Initialize();return owner;}
  static void Expire(Owner owner){while(Stopwatch.GetTimestamp()<=owner.Deadline+Stopwatch.Frequency/100)Thread.Sleep(2);}
  static void Settle(Task task){Assert(SpinWait.SpinUntil(()=>task.IsCompleted,3000),"original task failed to settle after release");}
  static void Case(string name,Action body){try{body();results.Add("PASS "+name);}catch(Exception error){failures++;results.Add("FAIL "+name+": "+error.Message);}}
  static void Arm(Owner owner,string operation,int occurrence){
   string ignored;while(owner.OperationTrace.TryDequeue(out ignored)){}
   owner.TraceOperations=true;owner.BlockOperation=operation;owner.BlockOccurrence=occurrence;owner.OperationEntered=new ManualResetEventSlim(false);owner.ContinueOperation=new ManualResetEventSlim(false);
  }
  static void Blocked(string name,string operation,int occurrence,Action<Owner> setup,Action<Owner> begin,Action<Owner> retained){
   Case(name,()=>{
    var owner=New(name);if(setup!=null)setup(owner);Arm(owner,operation,occurrence);var deadline=owner.Deadline;
    begin(owner);
    try{
     Assert(owner.OperationEntered.Wait(2000),"original operation gate not reached");
     var atGate=owner.OperationTrace.Count;var original=owner.OriginalTask;
     Expire(owner);
     Exception observed=null;try{owner.WaitCleanup();}catch(Exception error){observed=error;}
     Assert(Timeout(observed),"deadline did not independently reject still-pending worker");
     Assert(Object.ReferenceEquals(original,owner.OriginalTask)&&!original.IsCompleted,"original task custody lost before release");
     owner.ContinueOperation.Set();Settle(original);
     Assert(owner.OperationTrace.Count==atGate,"later native operation admitted after expired "+operation+"; trace="+String.Join(",",owner.OperationTrace.ToArray()));
     Assert(Timeout(original.Exception),"original task failed without preserving timeout");
     Assert(!owner.Retired&&owner.Deadline==deadline,"expired owner was retired or original deadline replaced");
     observed=null;try{owner.WaitCleanup();}catch(Exception error){observed=error;}
     Assert(Timeout(observed),"later physical completion erased original timeout");
     if(retained!=null)retained(owner);
    }finally{owner.ContinueOperation.Set();if(owner.OriginalTask!=null)Settle(owner.OriginalTask);}
   });
  }
  public static string[] Run(){
   foreach(var operation in new[]{"WriteFile","FlushFileBuffers","ReOpenFile","CloseHandle","NtCreateFile","ReadFile"}){
    Blocked("write-"+operation,operation,1,null,o=>o.BeginWriteText("original.txt","original-content"),o=>{
     var leaf=First(o,"leaves");Assert(Handle(leaf,"Handle")!=IntPtr.Zero||Handle(leaf,"Seal")!=IntPtr.Zero,"original leaf custody disappeared");
     Assert(Handle(o,"root")!=IntPtr.Zero,"original root custody disappeared");
    });
   }
   Blocked("write-seal-identity","GetFileInformationByHandle",3,null,o=>o.BeginWriteText("original.txt","original-content"),o=>Assert(Handle(First(o,"leaves"),"Seal")!=IntPtr.Zero,"original seal custody disappeared"));
   Blocked("absent-final-acceptance","NtCreateFile",1,null,o=>{
    Task.Run(()=>{try{o.VerifyAbsent("never-created.txt");}catch{}});
    Assert(SpinWait.SpinUntil(()=>o.OperationEntered.IsSet,2000),"absence worker did not reach original probe");
   },o=>Assert(Handle(o,"root")!=IntPtr.Zero,"original root custody disappeared"));
   Blocked("leaf-disposition","SetFileInformationByHandle",1,o=>o.WriteText("original.txt","original-content"),o=>o.BeginCleanup(),o=>{
    var leaf=First(o,"leaves");Assert(Handle(leaf,"Handle")!=IntPtr.Zero&&Handle(leaf,"DeleteHandle")!=IntPtr.Zero,"unattempted original leaf close custody disappeared");
   });
   Blocked("leaf-first-close","CloseHandle",2,o=>o.WriteText("original.txt","original-content"),o=>o.BeginCleanup(),o=>{
    Assert(Handle(First(o,"leaves"),"DeleteHandle")!=IntPtr.Zero,"second independent leaf close was not retained");
   });
   foreach(var operation in new[]{"SetFileInformationByHandle","StreamDispose"}){
    FileStream external=null;
    Blocked("external-"+operation,operation,1,o=>{
     external=new FileStream(o.FilePath("control.txt"),FileMode.CreateNew,FileAccess.ReadWrite,FileShare.ReadWrite|FileShare.Delete);
     external.WriteByte(97);external.Flush(true);
    },o=>{
     Task.Run(()=>{try{o.RemoveControlFile("control.txt",external);}catch{}});
     Assert(SpinWait.SpinUntil(()=>o.OperationEntered.IsSet,2000),"external worker did not reach admitted operation");
    },o=>Assert(Handle(First(o,"externalControls"),"DeleteHandle")!=IntPtr.Zero,"external original delete handle was closed after expiry"));
   }
   foreach(var operation in new[]{"SetFileInformationByHandle","CloseHandle"}){
    Owner outside=null;
    Blocked("junction-"+operation,operation,1,o=>{outside=New("outside");o.CreateSiblingJunctionControl("scratch-junction-"+Guid.NewGuid().ToString("n"),outside);},o=>o.BeginCleanup(),o=>{
     var control=First(o,"controls");Assert(Handle(control,"DeleteHandle")!=IntPtr.Zero,"junction original delete handle was closed after expiry");
    });
    if(outside!=null&&!outside.Retired){try{outside.Cleanup();}catch{}}
   }
   Blocked("root-disposition","SetFileInformationByHandle",1,null,o=>o.BeginCleanup(),o=>Assert(Handle(o,"root")!=IntPtr.Zero,"original root close was admitted after expiry"));
   Case("last-parent-close",()=>{
    var owner=New("last-parent");var parents=(System.Collections.IList)Field(owner,"parents");
    Arm(owner,"CloseHandle",parents.Count+1);owner.BeginCleanup();
    try{Assert(owner.OperationEntered.Wait(2000),"last original parent close not reached");Expire(owner);owner.ContinueOperation.Set();Settle(owner.OriginalTask);Assert(!owner.Retired,"retirement accepted an expired final parent close");Assert(Timeout(owner.OriginalTask.Exception),"final parent close did not preserve timeout");}
    finally{owner.ContinueOperation.Set();Settle(owner.OriginalTask);}
   });
   Case("wait-final-acceptance",()=>{
    var owner=New("wait-accept");owner.BeforeWaitAcceptanceEntered=new ManualResetEventSlim(false);owner.ContinueWaitAcceptance=new ManualResetEventSlim(false);
    var waiter=Task.Run(()=>owner.WaitCleanup());
    try{Assert(owner.BeforeWaitAcceptanceEntered.Wait(2000),"wait acceptance gate not reached");Expire(owner);owner.ContinueWaitAcceptance.Set();Settle(waiter);Assert(Timeout(waiter.Exception),"Wait accepted original task after deadline");Assert(!owner.Retired,"Wait changed retirement");}
    finally{owner.ContinueWaitAcceptance.Set();Settle(waiter);}
   });
   Case("retirement-final-acceptance",()=>{
    var owner=New("retire-accept");owner.BeforeRetirementEntered=new ManualResetEventSlim(false);owner.ContinueRetirement=new ManualResetEventSlim(false);owner.BeginCleanup();
    try{Assert(owner.BeforeRetirementEntered.Wait(2000),"retirement acceptance gate not reached");Expire(owner);owner.ContinueRetirement.Set();Settle(owner.OriginalTask);Assert(!owner.Retired,"expired worker published retirement");Assert(Timeout(owner.OriginalTask.Exception),"retirement publication erased timeout");}
    finally{owner.ContinueRetirement.Set();Settle(owner.OriginalTask);}
   });
   results.Add("TOTAL "+results.Count+"; FAILURES "+failures);foreach(var owner in retainedOwners)if(!owner.Retired)results.Add("RETAINED_ORIGINAL_RESOURCE "+owner.Path);return results.ToArray();
  }
  public static int Failures{get{return failures;}}
 }
}
