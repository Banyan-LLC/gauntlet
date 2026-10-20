namespace GauntletFixtureScratch {
 using System.Reflection;
 public static class AdditionalAdmissionCases {
  static bool Timeout(Exception error){if(error==null)return false;if(error is TimeoutException)return true;if(error is AggregateException)foreach(var inner in ((AggregateException)error).InnerExceptions)if(Timeout(inner))return true;return Timeout(error.InnerException);}
  static void Require(bool value,string message){if(!value)throw new Exception(message);}
  static IntPtr Root(Owner owner){return (IntPtr)typeof(Owner).GetField("root",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(owner);}
  static int failed;
  static void Case(string name,Action body){try{body();Console.WriteLine("PASS "+name);}catch(Exception error){failed++;Console.WriteLine("FAIL "+name+": "+error.ToString());}}

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

  static void ManagedCapture(){
   Case("safe-handle-capture-original-task",()=>{
    Owner owner=null;ApiCall api=null;Task original=null;FileStream stream=null;var scope=new Scope("capture");
    scope.Execute(()=>{
     scope.Own(ref owner,"capture");stream=new FileStream(owner.FilePath("control.txt"),FileMode.CreateNew,FileAccess.ReadWrite,FileShare.ReadWrite|FileShare.Delete);scope.RetainResource(stream);
     stream.WriteByte(97);owner.TraceOperations=true;owner.BlockOperation="StreamSafeFileHandle";owner.OperationEntered=new ManualResetEventSlim(false);owner.ContinueOperation=new ManualResetEventSlim(false);
     var deadline=owner.Deadline;
     api=new ApiCall(scope,()=>owner.RemoveControlFile("control.txt",stream));
     Require(owner.OperationEntered.Wait(2000),"original SafeFileHandle getter gate not reached");
     original=owner.OriginalTask;scope.Retain(original);bool pendingBeforeRelease=!original.IsCompleted;
     var controls=(System.Collections.IList)typeof(Owner).GetField("externalControls",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(owner);
     bool enrolledBeforeGetter=controls.Count==1&&Object.ReferenceEquals(controls[0].GetType().GetField("Stream").GetValue(controls[0]),stream);
     bool originalNotYetCaptured=enrolledBeforeGetter&&controls[0].GetType().GetField("Original").GetValue(controls[0])==null;
     int admitted=owner.OperationTrace.Count;while(Stopwatch.GetTimestamp()<=deadline+Stopwatch.Frequency/100)Thread.Sleep(2);
     bool publicCallBounded=SpinWait.SpinUntil(()=>api.Task.IsCompleted,500);var observed=api.Failure;
     owner.ContinueOperation.Set();Settle(original);Settle(api.Task);
     Require(pendingBeforeRelease,"blocking getter ran outside original pending task");
     Require(enrolledBeforeGetter&&originalNotYetCaptured,"exact original stream was not enrolled before blocking getter");
     Require(publicCallBounded&&Timeout(observed),"public cleanup call hung beyond original deadline while getter remained held");
     Require(Object.ReferenceEquals(observed,api.Failure)&&Timeout(api.Failure)&&Timeout(original.Exception),"original getter timeout was not retained independently of completion");
     Require(owner.OperationTrace.Count==admitted,"new I/O admitted after original getter resumed beyond deadline");
     Require(Object.ReferenceEquals(original,owner.OriginalTask)&&owner.Deadline==deadline&&!owner.Retired,"original getter authority changed");
     Require(stream.CanRead&&Root(owner)!=IntPtr.Zero,"unattempted original stream/root closure custody lost");
     api.AcceptFailure(observed);
    },F("capture-original",()=>{if(original==null&&owner!=null){original=owner.OriginalTask;scope.Retain(original);}}),
      F("release-getter",()=>Release(owner==null?null:owner.ContinueOperation)),
      F("settle-api",()=>{if(api!=null)Settle(api.Task);}),
      F("settle-original",()=>Settle(original)),
      C("eligible-control-cleanup",()=>{if(stream!=null&&owner!=null&&Stopwatch.GetTimestamp()<owner.Deadline)owner.RemoveControlFile("control.txt",stream);}),
      C("eligible-owner-cleanup",()=>CleanupEligible(owner)));
   });
  }

  public static int Run(){
   foreach(bool blockTarget in new[]{false,true}){
    string name=blockTarget?"target-read-original-caller-expiry":"caller-read-before-target-admission";
    Case(name,()=>{
     Owner caller=null,target=null,blocked=null;ApiCall api=null;Task original=null;var scope=new Scope(name);
     scope.Execute(()=>{
      scope.Own(ref caller,"caller");scope.Own(ref target,"target",30);target.WriteText("sentinel.txt","unchanged");
      var deadline=caller.Deadline;var targetDeadline=target.Deadline;caller.TraceOperations=true;target.TraceOperations=true;
      blocked=blockTarget?target:caller;blocked.BlockOperation="GetFileInformationByHandle";blocked.OperationEntered=new ManualResetEventSlim(false);blocked.ContinueOperation=new ManualResetEventSlim(false);
      api=new ApiCall(scope,()=>caller.CreateSiblingJunctionControl("scratch-cross-"+Guid.NewGuid().ToString("n"),target));
      Require(blocked.OperationEntered.Wait(2000),"original held-root read gate not reached");
      original=caller.OriginalTask;scope.Retain(original);var originalTarget=target.OriginalTask;scope.Retain(originalTarget);
      int admittedCaller=caller.OperationTrace.Count,admittedTarget=target.OperationTrace.Count;
      while(Stopwatch.GetTimestamp()<=deadline+Stopwatch.Frequency/100)Thread.Sleep(2);
      Require(SpinWait.SpinUntil(()=>api.Task.IsCompleted,500),"original public caller did not return at its deadline");var observed=api.Failure;
      Require(Timeout(observed)&&!original.IsCompleted,"original caller timeout and pending custody not independently preserved");
      blocked.ContinueOperation.Set();Settle(original);Settle(api.Task);
      Require(target.OperationTrace.Count==(blockTarget?admittedTarget:0),"healthy target admitted a read after original caller expired");
      Require(caller.OperationTrace.Count==admittedCaller,"expired caller admitted I/O after original held-root call");
      Require(Object.ReferenceEquals(observed,api.Failure)&&Timeout(original.Exception)&&Timeout(api.Failure),"original caller did not preserve timeout after physical completion");
      Require(Object.ReferenceEquals(original,caller.OriginalTask)&&Object.ReferenceEquals(originalTarget,target.OriginalTask),"original owner task identity changed");
      Require(caller.Deadline==deadline&&target.Deadline==targetDeadline&&Stopwatch.GetTimestamp()<targetDeadline,"original deadline authority changed");
      Require(!caller.Retired&&Root(caller)!=IntPtr.Zero&&Root(target)!=IntPtr.Zero,"original held-root custody was lost");
      Require(target.ReadText("sentinel.txt")=="unchanged","target original content changed");
      api.AcceptFailure(observed);
     },F("capture-original",()=>{if(original==null&&caller!=null){original=caller.OriginalTask;scope.Retain(original);}}),
       F("release-root-read",()=>Release(blocked==null?null:blocked.ContinueOperation)),
       F("settle-original",()=>Settle(original)),
       F("settle-api",()=>{if(api!=null)Settle(api.Task);}),
       C("eligible-target-cleanup",()=>{if((original!=null&&!original.IsCompleted)||(api!=null&&!api.Task.IsCompleted))throw new InvalidOperationException("Original borrower remains unresolved; target custody retained");CleanupEligible(target);}),
       C("eligible-caller-cleanup",()=>CleanupEligible(caller)));
    });
   }
   ManagedCapture();FinalizerContracts(Case);Case("early-api-failure-observation",()=>Require(RunApiEarlyFailureProbe()==0,"early original API/worker cause lost"));
   Console.WriteLine("TOTAL 7; FAILURES "+failed);foreach(var scope in Scope.Retained)scope.Report();return failed;
  }

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
