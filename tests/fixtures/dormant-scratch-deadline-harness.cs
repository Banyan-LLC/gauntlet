namespace GauntletFixtureScratch {
 using System.Reflection;
 public static class DeadlineCases {
  static readonly List<string> results=new List<string>();static int failures;
  static readonly BindingFlags Private=BindingFlags.NonPublic|BindingFlags.Instance;
  static void Require(bool value,string message){if(!value)throw new Exception(message);}
  static bool Timeout(Exception error){if(error==null)return false;if(error is TimeoutException)return true;if(error is AggregateException)foreach(var inner in ((AggregateException)error).InnerExceptions)if(Timeout(inner))return true;return Timeout(error.InnerException);}
  static object Field(object value,string name){return value.GetType().GetField(name,Private|BindingFlags.Public).GetValue(value);}
  static IntPtr Handle(object value,string name){return (IntPtr)Field(value,name);}
  static object First(object owner,string name){return ((System.Collections.IList)Field(owner,name))[0];}
  static void Expire(Owner owner){while(Stopwatch.GetTimestamp()<=owner.Deadline+Stopwatch.Frequency/100)Thread.Sleep(2);}
  static void Case(string name,Action body){try{body();results.Add("PASS "+name);}catch(Exception error){failures++;results.Add("FAIL "+name+": "+error.ToString());}}
  static void Arm(Owner owner,string operation,int occurrence){string ignored;while(owner.OperationTrace.TryDequeue(out ignored)){}owner.TraceOperations=true;owner.BlockOperation=operation;owner.BlockOccurrence=occurrence;owner.OperationEntered=new ManualResetEventSlim(false);owner.ContinueOperation=new ManualResetEventSlim(false);}


 sealed class PhaseFailure {
  public readonly string Phase;public readonly Exception Error;public readonly ApiCall Api;
  public PhaseFailure(string phase,Exception error,ApiCall api=null){Phase=phase;Error=error;Api=api;}
 }
 sealed class Finalizer {
  public readonly string Phase;public readonly Action Action;public readonly bool NeedsApiObservation;
  public Finalizer(string phase,Action action,bool needsApiObservation=false){Phase=phase;Action=action;NeedsApiObservation=needsApiObservation;}
 }
 sealed class CaseFailure:Exception {
  public readonly Scope Record;
  public CaseFailure(Scope record):base(record.Describe(),record.Primary){Record=record;}
 }
 sealed class Scope {
  internal static readonly List<Scope> Retained=new List<Scope>();
  readonly object gate=new object();
  readonly List<Owner> owners=new List<Owner>();
  readonly List<Task> tasks=new List<Task>();
  readonly List<ApiCall> apis=new List<ApiCall>();
  readonly List<object> resources=new List<object>();
  readonly List<PhaseFailure> secondary=new List<PhaseFailure>();
  public readonly string Name;
  Exception primary;Exception overflow;
  public Scope(string name){Name=name;lock(Retained){if(Retained.Count>=64)throw new InvalidOperationException("Harness case retention bound exceeded");Retained.Add(this);}}
  public Exception Primary{get{lock(gate)return primary;}}
  public System.Collections.ObjectModel.ReadOnlyCollection<PhaseFailure> History{get{lock(gate)return Array.AsReadOnly(secondary.ToArray());}}
  public System.Collections.ObjectModel.ReadOnlyCollection<PhaseFailure> Secondary{get{lock(gate){var active=new List<PhaseFailure>();foreach(var item in secondary)if(item.Api==null||!item.Api.IsAccepted(item.Error))active.Add(item);return Array.AsReadOnly(active.ToArray());}}}
  public void RegisterApi(ApiCall api){lock(gate){if(apis.Count>=8)throw new InvalidOperationException("Harness API retention bound exceeded");apis.Add(api);}}
  public void PublishApiFailure(ApiCall api,Exception error){Record("original-api-failure",error,api);}
  public bool HasApiFailure(ApiCall api,Exception error){lock(gate){foreach(var item in secondary)if(Object.ReferenceEquals(item.Api,api)&&Object.ReferenceEquals(item.Error,error))return true;return false;}}
  public void AcceptApiFailure(Exception error){ApiCall[] snapshot;lock(gate){snapshot=apis.ToArray();}foreach(var api in snapshot)if(Object.ReferenceEquals(api.Failure,error))api.AcceptFailure(error);}
  public void Retain(Task task){if(task==null)return;lock(gate){if(tasks.Contains(task))return;if(tasks.Count>=16)throw new InvalidOperationException("Harness task retention bound exceeded");tasks.Add(task);}}
  public void RetainResource(object resource){if(resource==null)return;lock(gate){if(resources.Count>=8)throw new InvalidOperationException("Harness resource retention bound exceeded");resources.Add(resource);}}
  public void Own(ref Owner slot,string prefix,int seconds=3,string path=null){
   slot=new Owner(path??System.IO.Path.Combine(System.IO.Path.GetTempPath(),"scratch-r3-"+prefix+"-"+Guid.NewGuid().ToString("n")),Stopwatch.GetTimestamp()+Stopwatch.Frequency*seconds);
   lock(gate){if(owners.Count>=4)throw new InvalidOperationException("Harness owner retention bound exceeded");owners.Add(slot);}
   slot.Initialize();
  }
  void Record(string phase,Exception error,ApiCall api=null){lock(gate){if(secondary.Count<16)secondary.Add(new PhaseFailure(phase,error,api));else if(overflow==null)overflow=new InvalidOperationException("Harness secondary evidence bound exceeded",error);}}
  void ObserveApis(){
   ApiCall[] snapshot;lock(gate){snapshot=apis.ToArray();}
   foreach(var api in snapshot){if(api.FinalObservationAttempted)continue;try{api.ObserveRemaining();}catch(Exception error){Record("observe-original-api",error);}}
  }
  bool ApisSettled(){lock(gate){foreach(var api in apis)if(!api.FinalObservationCompleted)return false;return true;}}
  bool ActiveFailures(){foreach(var item in secondary)if(item.Api==null||!item.Api.IsAccepted(item.Error))return true;return false;}
  public void Execute(Action body,params Finalizer[] finalizers){
   try{body();}catch(Exception error){lock(gate){primary=error;}}
   foreach(var finalizer in finalizers){
    if(finalizer.NeedsApiObservation){ObserveApis();if(!ApisSettled()){Record(finalizer.Phase,new InvalidOperationException("Original API observation remains unresolved; dependent cleanup refused"));continue;}}
    try{finalizer.Action();}catch(Exception error){Record(finalizer.Phase,error);}
   }
   ObserveApis();
   lock(gate){if(primary!=null||ActiveFailures()||overflow!=null)throw new CaseFailure(this);}
  }
  public string Describe(){
   lock(gate){
    var text=Name;if(primary!=null)text+=" | primary: "+primary.ToString();
    foreach(var item in secondary)text+=" | "+item.Phase+(item.Api!=null&&item.Api.IsAccepted(item.Error)?" [accepted]":"")+": "+item.Error.ToString();
    if(overflow!=null)text+=" | evidence-bound: "+overflow.ToString();return text;
   }
  }
  public void Report(){
   lock(gate){
    foreach(var owner in owners)if(!owner.Retired)Console.WriteLine("RETAINED_ORIGINAL_RESOURCE "+owner.Path);
    foreach(var task in tasks)if(!task.IsCompleted)Console.WriteLine("RETAINED_ORIGINAL_TASK "+Name);
   }
  }
 }
 sealed class ApiCall {
  public readonly Task Task;readonly Scope scope;Exception failure,accepted;int finalAttempted,finalCompleted;
  public Exception Failure{get{return Volatile.Read(ref failure);}}
  public bool FinalObservationAttempted{get{return Volatile.Read(ref finalAttempted)!=0;}}
  public bool FinalObservationCompleted{get{return Volatile.Read(ref finalCompleted)!=0;}}
  public bool IsAccepted(Exception error){return Object.ReferenceEquals(Volatile.Read(ref accepted),error);}
  void Capture(Exception error){Interlocked.CompareExchange(ref failure,error,null);scope.PublishApiFailure(this,error);}
  public ApiCall(Scope scope,Action body){
   this.scope=scope;Task=new Task(()=>{try{body();}catch(Exception error){Capture(error);}},CancellationToken.None,TaskCreationOptions.DenyChildAttach);
   scope.RegisterApi(this);scope.Retain(Task);try{Task.Start(TaskScheduler.Default);}catch(Exception error){Capture(error);throw;}
  }
  public void AcceptFailure(Exception error){if(error==null||!Task.IsCompleted||!Object.ReferenceEquals(error,Failure))throw new InvalidOperationException("Exact completed original API failure required");Volatile.Write(ref accepted,error);}
  public void Observe(){Settle(Task);Task.GetAwaiter().GetResult();var error=Failure;if(error!=null)System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(error).Throw();}
  public void ObserveRemaining(){
   if(Interlocked.Exchange(ref finalAttempted,1)!=0)return;
   if(!Task.IsCompleted)throw new InvalidOperationException("Original API task remains unresolved at exact observation");
   Task.GetAwaiter().GetResult();var error=Failure;
   if(error!=null&&!scope.HasApiFailure(this,error))throw new InvalidOperationException("Original API failure publication unavailable",error);
   Volatile.Write(ref finalCompleted,1);
  }
 }
 static Finalizer F(string phase,Action action){return new Finalizer(phase,action);}
 static Finalizer C(string phase,Action action){return new Finalizer(phase,action,true);}
 static void Settle(Task task,int milliseconds=3000){
  if(task==null)return;if(milliseconds<1||milliseconds>3000)throw new ArgumentOutOfRangeException("milliseconds");
  Require(SpinWait.SpinUntil(()=>task.IsCompleted,milliseconds),"original task failed to settle");
 }
 static void CleanupEligible(Owner owner){
  if(owner!=null&&!owner.Retired&&Stopwatch.GetTimestamp()<owner.Deadline)owner.Cleanup();
 }
 static void Release(ManualResetEventSlim gate){if(gate!=null)gate.Set();}
 static void ObserveExpected(Action observe){try{observe();}catch(Exception error){if(!Timeout(error))throw;}}
 static void FinalizerContracts(Action<string,Action> run){
  run("partial-submission-finalization",()=>{
   Owner owner=null;Task original=null;var marker=new InvalidOperationException("PRIMARY-PARTIAL-SUBMISSION");var scope=new Scope("partial-submit");CaseFailure failure=null;
   try{scope.Execute(()=>{
    scope.Own(ref owner,"partial-submit",30);owner.BlockOperation="WriteFile";owner.OperationEntered=new ManualResetEventSlim(false);owner.ContinueOperation=new ManualResetEventSlim(false);
    owner.BeginWriteText("partial.txt","partial");original=owner.OriginalTask;scope.Retain(original);
    Require(owner.OperationEntered.Wait(2000),"partial actual gate not reached");throw marker;
   },F("release",()=>Release(owner==null?null:owner.ContinueOperation)),F("settle-original",()=>Settle(original)),
     F("observe-write",()=>{if(original!=null)owner.WaitWriteText();}),C("eligible-cleanup",()=>CleanupEligible(owner)));}
   catch(CaseFailure error){failure=error;}
   Require(failure!=null&&Object.ReferenceEquals(scope.Primary,marker),"partial submission primary lost");
   Require(original!=null&&original.IsCompleted&&owner.Retired,"partial submission did not release, observe and clean original custody");
   Require(scope.Secondary.Count==0,"partial submission finalizer failed");
  });
  run("failed-settlement-independent-finalizers",()=>{
   Owner owner=null;var scope=new Scope("failed-settlement");var primary=new InvalidOperationException("PRIMARY-SETTLEMENT");var early=new IOException("EARLY-FINALIZER");
   var unresolved=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);scope.Retain(unresolved.Task);
   bool later=false;CaseFailure failure=null;
   try{scope.Execute(()=>{scope.Own(ref owner,"settlement",30);throw primary;},
    F("early-failure",()=>{throw early;}),F("bounded-settlement",()=>Settle(unresolved.Task,20)),
    F("later-action",()=>{later=true;}),C("eligible-cleanup",()=>CleanupEligible(owner)));}
   catch(CaseFailure error){failure=error;}
   var evidence=scope.Secondary;
   Require(failure!=null&&Object.ReferenceEquals(scope.Primary,primary),"settlement primary lost");
   Require(evidence.Count==2&&evidence[0].Phase=="early-failure"&&Object.ReferenceEquals(evidence[0].Error,early)&&evidence[1].Phase=="bounded-settlement","phase-tagged independent evidence lost");
   Require(later&&owner.Retired&&!unresolved.Task.IsCompleted,"failed settlement skipped later action/cleanup or replaced unresolved task");
   Require(failure.Message.Contains("PRIMARY-SETTLEMENT")&&failure.Message.Contains("EARLY-FINALIZER")&&failure.Message.Contains("original task failed to settle"),"structured failure diagnostics hide a cause");
  });
  run("partial-initialize-owner-publication",()=>{
   Owner owner=null;var scope=new Scope("partial-initialize");CaseFailure failure=null;
   var path=System.IO.Path.Combine(System.IO.Path.GetTempPath(),"scratch-missing-"+Guid.NewGuid().ToString("n"),"never-created");
   try{scope.Execute(()=>scope.Own(ref owner,"partial-init",30,path),C("eligible-cleanup",()=>CleanupEligible(owner)));}
   catch(CaseFailure error){failure=error;}
   Require(failure!=null&&scope.Primary!=null&&owner!=null&&owner.Retired,"partial Initialize did not publish owner before failure or attempt eligible original cleanup");
  });
 }
  static void Blocked(string name,string operation,int occurrence,Action<Scope,Owner> setup,Action<Scope,Owner> begin,Action<Owner> observe,Action<Owner> retained,params Finalizer[] extra){
   Case(name,()=>{
    Owner owner=null;Task original=null;long deadline=0;bool submitted=false;var scope=new Scope(name);
    var finish=new List<Finalizer>{
     F("capture-original",()=>{if(original==null&&owner!=null){original=owner.OriginalTask;scope.Retain(original);}}),
     F("release-operation",()=>Release(owner==null?null:owner.ContinueOperation)),
     F("settle-original",()=>Settle(original)),
     F("observe-original-operation",()=>{if(submitted)ObserveExpected(()=>observe(owner));})
    };
    finish.AddRange(extra);finish.Add(C("owner-eligible-cleanup",()=>CleanupEligible(owner)));
    scope.Execute(()=>{
     scope.Own(ref owner,name);if(setup!=null)setup(scope,owner);Arm(owner,operation,occurrence);deadline=owner.Deadline;
     submitted=true;begin(scope,owner);original=owner.OriginalTask;scope.Retain(original);
     Require(owner.OperationEntered.Wait(2000),"original operation gate not reached");
     var atGate=owner.OperationTrace.Count;Expire(owner);
     Exception observed=null;try{observe(owner);}catch(Exception error){observed=error;}
     Require(Timeout(observed),"deadline did not independently reject still-pending worker");scope.AcceptApiFailure(observed);
     Require(Object.ReferenceEquals(original,owner.OriginalTask)&&!original.IsCompleted,"original task custody lost before release");
     owner.ContinueOperation.Set();Settle(original);
     Require(owner.OperationTrace.Count==atGate,"later native operation admitted after expired "+operation+"; trace="+String.Join(",",owner.OperationTrace.ToArray()));
     Require(Timeout(original.Exception),"original task failed without preserving timeout");
     Require(!owner.Retired&&owner.Deadline==deadline,"expired owner was retired or original deadline replaced");
     observed=null;try{observe(owner);}catch(Exception error){observed=error;}
     Require(Timeout(observed),"later physical completion erased original timeout");scope.AcceptApiFailure(observed);if(retained!=null)retained(owner);
    },finish.ToArray());
   });
  }

  static void Boundary(string name,int kind){
   Case(name,()=>{
    Owner owner=null;Task original=null;ApiCall waiter=null;bool submitted=false;var scope=new Scope(name);
    scope.Execute(()=>{
     scope.Own(ref owner,name);
     if(kind==0){var parents=(System.Collections.IList)Field(owner,"parents");Arm(owner,"CloseHandle",parents.Count+1);submitted=true;owner.BeginCleanup();}
     else if(kind==1){owner.BeforeWaitAcceptanceEntered=new ManualResetEventSlim(false);owner.ContinueWaitAcceptance=new ManualResetEventSlim(false);submitted=true;owner.BeginWriteText("acceptance.txt","original");}
     else{owner.BeforeRetirementEntered=new ManualResetEventSlim(false);owner.ContinueRetirement=new ManualResetEventSlim(false);submitted=true;owner.BeginCleanup();}
     original=owner.OriginalTask;scope.Retain(original);
     if(kind==1)waiter=new ApiCall(scope,()=>owner.WaitWriteText());
     var entered=kind==0?owner.OperationEntered:kind==1?owner.BeforeWaitAcceptanceEntered:owner.BeforeRetirementEntered;
     Require(entered.Wait(2000),"original "+name+" gate not reached");Expire(owner);
     if(kind==1)Require(SpinWait.SpinUntil(()=>waiter.Task.IsCompleted,500),"public acceptance observer remained blocked beyond its original deadline before release");
     Release(kind==0?owner.ContinueOperation:kind==1?owner.ContinueWaitAcceptance:owner.ContinueRetirement);
     if(kind==1){Settle(waiter.Task);Require(Timeout(waiter.Failure),"Wait accepted original task after deadline");}
     else{Settle(original);Require(Timeout(original.Exception),"original "+name+" did not preserve timeout");}
     Require(!owner.Retired,"expired "+name+" published retirement");if(kind==1)waiter.AcceptFailure(waiter.Failure);
    },F("release-operation",()=>Release(owner==null?null:owner.ContinueOperation)),
      F("release-wait",()=>Release(owner==null?null:owner.ContinueWaitAcceptance)),
      F("release-retirement",()=>Release(owner==null?null:owner.ContinueRetirement)),
      F("settle-original",()=>Settle(original)),
      F("observe-operation",()=>{if(submitted)ObserveExpected(()=>{if(kind==1)owner.WaitWriteText();else owner.WaitCleanup();});}),
      F("settle-waiter",()=>{if(waiter!=null)Settle(waiter.Task);}),
      C("owner-eligible-cleanup",()=>CleanupEligible(owner)));
   });
  }

  public static string[] Run(){
   foreach(var operation in new[]{"WriteFile","FlushFileBuffers","ReOpenFile","CloseHandle","NtCreateFile","ReadFile"}){
    Blocked("write-"+operation,operation,1,null,(s,o)=>o.BeginWriteText("original.txt","original-content"),o=>o.WaitWriteText(),o=>{
     var leaf=First(o,"leaves");Require(Handle(leaf,"Handle")!=IntPtr.Zero||Handle(leaf,"Seal")!=IntPtr.Zero,"original leaf custody disappeared");Require(Handle(o,"root")!=IntPtr.Zero,"original root custody disappeared");
    });
   }
   Blocked("write-seal-identity","GetFileInformationByHandle",3,null,(s,o)=>o.BeginWriteText("original.txt","original-content"),o=>o.WaitWriteText(),o=>Require(Handle(First(o,"leaves"),"Seal")!=IntPtr.Zero,"original seal custody disappeared"));
   ApiCall absence=null;
   Blocked("absent-final-acceptance","NtCreateFile",1,null,(s,o)=>{
    absence=new ApiCall(s,()=>o.VerifyAbsent("never-created.txt"));Require(SpinWait.SpinUntil(()=>o.OperationEntered.IsSet,2000),"absence worker did not reach original probe");
   },o=>absence.Observe(),o=>Require(Handle(o,"root")!=IntPtr.Zero,"original root custody disappeared"),F("settle-absence-api",()=>{if(absence!=null)Settle(absence.Task);}));
   Blocked("leaf-disposition","SetFileInformationByHandle",1,(s,o)=>o.WriteText("original.txt","original-content"),(s,o)=>o.BeginCleanup(),o=>o.WaitCleanup(),o=>{
    var leaf=First(o,"leaves");Require(Handle(leaf,"Handle")!=IntPtr.Zero&&Handle(leaf,"DeleteHandle")!=IntPtr.Zero,"unattempted original leaf close custody disappeared");
   });
   Blocked("leaf-first-close","CloseHandle",2,(s,o)=>o.WriteText("original.txt","original-content"),(s,o)=>o.BeginCleanup(),o=>o.WaitCleanup(),o=>Require(Handle(First(o,"leaves"),"DeleteHandle")!=IntPtr.Zero,"second independent leaf close was not retained"));
   foreach(var operation in new[]{"SetFileInformationByHandle","StreamDispose"}){
    FileStream external=null;Owner externalOwner=null;ApiCall api=null;
    Blocked("external-"+operation,operation,1,(s,o)=>{externalOwner=o;external=new FileStream(o.FilePath("control.txt"),FileMode.CreateNew,FileAccess.ReadWrite,FileShare.ReadWrite|FileShare.Delete);s.RetainResource(external);external.WriteByte(97);external.Flush(true);},
     (s,o)=>{api=new ApiCall(s,()=>o.RemoveControlFile("control.txt",external));Require(SpinWait.SpinUntil(()=>o.OperationEntered.IsSet,2000),"external worker did not reach admitted operation");},
     o=>api.Observe(),o=>Require(Handle(First(o,"externalControls"),"DeleteHandle")!=IntPtr.Zero,"external original delete handle was closed after expiry"),F("settle-external-api",()=>{if(api!=null)Settle(api.Task);}),C("eligible-external-control-cleanup",()=>{if(external!=null&&externalOwner!=null&&Stopwatch.GetTimestamp()<externalOwner.Deadline)externalOwner.RemoveControlFile("control.txt",external);}));
   }
   foreach(var operation in new[]{"SetFileInformationByHandle","CloseHandle"}){
    Owner outside=null;
    Blocked("junction-"+operation,operation,1,(s,o)=>{s.Own(ref outside,"outside");o.CreateSiblingJunctionControl("scratch-junction-"+Guid.NewGuid().ToString("n"),outside);},
     (s,o)=>o.BeginCleanup(),o=>o.WaitCleanup(),o=>Require(Handle(First(o,"controls"),"DeleteHandle")!=IntPtr.Zero,"junction original delete handle was closed after expiry"),
     C("outside-eligible-cleanup",()=>CleanupEligible(outside)));
   }
   Blocked("root-disposition","SetFileInformationByHandle",1,null,(s,o)=>o.BeginCleanup(),o=>o.WaitCleanup(),o=>Require(Handle(o,"root")!=IntPtr.Zero,"original root close was admitted after expiry"));
   Boundary("last-parent-close",0);Boundary("wait-final-acceptance",1);Boundary("retirement-final-acceptance",2);
   FinalizerContracts(Case);Case("early-api-failure-observation",()=>Require(RunApiEarlyFailureProbe()==0,"early original API/worker cause lost"));
   results.Add("TOTAL "+results.Count+"; FAILURES "+failures);foreach(var scope in Scope.Retained)scope.Report();return results.ToArray();
  }
  public static int Failures{get{return failures;}}

  static bool ApiProbeContains(Exception outer,Exception exact){
   if(outer==null)return false;if(Object.ReferenceEquals(outer,exact))return true;
   if(outer is AggregateException)foreach(var inner in ((AggregateException)outer).InnerExceptions)if(ApiProbeContains(inner,exact))return true;
   return ApiProbeContains(outer.InnerException,exact);
  }
  public static int RunApiEarlyFailureProbe(){
   Owner owner=null;ApiCall api=null;Task original=null;Exception apiError=null,workerError=null;CaseFailure outcome=null;
   var primary=new InvalidOperationException("PRIMARY-BEFORE-API-OBSERVATION");var scope=new Scope("early-api-observation-probe");
   try{scope.Execute(()=>{
    scope.Own(ref owner,"api-observation",30);owner.WriteText("original.txt","original");
    api=new ApiCall(scope,()=>owner.WriteText("original.txt","must-not-overwrite"));Settle(api.Task);
    original=owner.OriginalTask;scope.Retain(original);apiError=api.Failure;
    Require(original.IsFaulted&&apiError!=null,"real worker/API failure not reached");workerError=original.Exception.InnerExceptions[0];
    Require(ApiProbeContains(apiError,workerError),"API does not retain exact original worker error");
    throw primary;
   },F("settle-api",()=>{if(api!=null)Settle(api.Task);}),F("settle-original",()=>Settle(original)),C("eligible-original-cleanup",()=>{Require(api!=null&&api.FinalObservationCompleted,"exact API observation must precede actual original cleanup");CleanupEligible(owner);}));}
   catch(CaseFailure error){outcome=error;}
   bool retained=false;foreach(var error in scope.Secondary)if(Object.ReferenceEquals(error.Error,apiError)&&ApiProbeContains(error.Error,workerError))retained=true;
   bool rendered=outcome!=null&&outcome.Message.Contains("PRIMARY-BEFORE-API-OBSERVATION")&&workerError!=null&&outcome.Message.Contains(workerError.Message);
   bool pass=outcome!=null&&Object.ReferenceEquals(scope.Primary,primary)&&apiError!=null&&workerError!=null&&retained&&rendered&&owner.Retired;
   Console.WriteLine((pass?"PASS":"FAIL")+" early-body-failure retains exact API and worker causes: primary="+Object.ReferenceEquals(scope.Primary,primary)+" exact_api_and_worker="+retained+" rendered="+rendered+" original_retired="+(owner!=null&&owner.Retired));
   return pass?0:1;
  }
}
}
