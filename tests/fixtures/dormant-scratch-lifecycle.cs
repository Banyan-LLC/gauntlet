namespace GauntletFixtureScratch {
 using System.Reflection;
 using System.Runtime.ExceptionServices;
 public static class R1ProposalCases {
  static Owner armed;
  static int armedUsed;
  static ManualResetEventSlim runEntered,runRelease;
  const int OwnerBound=17,ScopeBound=17,ControlBound=8;
  static int runStarted;
  static readonly List<Owner> retainedOwners=new List<Owner>();
  static readonly List<Scope> retainedScopes=new List<Scope>();
  static readonly List<object> retainedControls=new List<object>();
  static readonly BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
  // The private driver inserts this single transparent barrier AFTER Start in
  // Run. No Task, result, exception or native return value is substituted.
  public static void AfterStart(Owner owner,bool cleanup){
   if(!Object.ReferenceEquals(owner,armed)||cleanup||Interlocked.Exchange(ref armedUsed,1)!=0)return;
   runEntered.Set();runRelease.Wait();
  }
  static void Require(bool value,string message){if(!value)throw new InvalidOperationException(message);}
  static bool Has(Exception error,Func<Exception,bool> predicate){
   if(error==null)return false;if(predicate(error))return true;
   var aggregate=error as AggregateException;
   if(aggregate!=null)foreach(var inner in aggregate.InnerExceptions)if(Has(inner,predicate))return true;
   return Has(error.InnerException,predicate);
  }
  static bool Timeout(Exception error){return Has(error,e=>e is TimeoutException);}
  static bool Native(Exception error,int code){return Has(error,e=>e is Win32Exception&&((Win32Exception)e).NativeErrorCode==code);}
  static Exception Capture(Action action){try{action();return null;}catch(Exception error){return error;}}
  static object Invoke(Owner owner,string name,params object[] args){
   MethodInfo method=null;
   foreach(var candidate in typeof(Owner).GetMethods(Private)){
    if(candidate.Name!=name)continue;
    var parameters=candidate.GetParameters();
    if(name=="Run"&&(parameters.Length!=2||parameters[0].ParameterType!=typeof(Action)))continue;
    method=candidate;break;
   }
   if(method==null)throw new InvalidOperationException("Actual private helper method unavailable: "+name);
   try{return method.Invoke(owner,args);}
   catch(TargetInvocationException error){ExceptionDispatchInfo.Capture(error.InnerException).Throw();throw;}
  }
  sealed class CloseBothCallback {
   public Owner Owner;public IntPtr Root;
   public void Captured<T>(T operation){Invoke(Owner,"CloseBoth",operation,new IntPtr(0x7ffffff0),Root);}
  }
  static void RunCloseBoth(Owner owner,IntPtr root){
   var operationType=typeof(Owner).GetNestedType("Operation",BindingFlags.NonPublic);
   if(operationType==null){
    Action action=()=>Invoke(owner,"CloseBoth",new object[]{new IntPtr(0x7ffffff0),root});
    Invoke(owner,"Run",action,true);return;
   }
   var callback=new CloseBothCallback{Owner=owner,Root=root};
   var actionType=typeof(Action<>).MakeGenericType(operationType);
   var callbackMethod=typeof(CloseBothCallback).GetMethod("Captured").MakeGenericMethod(operationType);
   var actionWithCapturedOperation=Delegate.CreateDelegate(actionType,callback,callbackMethod);
   var run=typeof(Owner).GetMethod("Run",Private,null,new[]{actionType,typeof(bool)},null);
   if(run==null)throw new InvalidOperationException("Actual captured-operation Run unavailable");
   try{run.Invoke(owner,new object[]{actionWithCapturedOperation,true});}
   catch(TargetInvocationException error){ExceptionDispatchInfo.Capture(error.InnerException).Throw();throw;}
  }
  static void KeepControl(object control){if(retainedControls.Count>=ControlBound)throw new InvalidOperationException("Control retention bound exceeded");retainedControls.Add(control);}
  static Owner New(string name,int seconds,Scope scope,bool eligible=false){
   if(retainedOwners.Count>=OwnerBound)throw new InvalidOperationException("Owner retention bound exceeded");
   var owner=new Owner(System.IO.Path.Combine(System.IO.Path.GetTempPath(),"scratch-r1-proposal-"+name+"-"+Guid.NewGuid().ToString("n")),Stopwatch.GetTimestamp()+Stopwatch.Frequency*seconds);
   retainedOwners.Add(owner);scope.KeepOwner(owner,eligible);owner.Initialize();return owner;
  }
  static bool EarlyRound,AfterReadRound;
  static string CurrentCaseName;
  sealed class EarlyEvidence {
   public Exception Primary;public Owner Owner;public Task Api,Worker;
   public Func<Exception> Failure;public Func<Exception,bool> ExpectedWorker;public bool WorkerFault;
  }
  static bool EarlyCase(string name){return name=="closeboth-publishes-first-native-cause-before-block"||name=="external-control-publishes-dispose-cause-before-block"||name=="cleanupcore-publishes-sharing-cause-before-next-close"||name=="public-observer-acceptance-is-original-clock-bounded";}
  static void InjectEarly(Scope scope,Owner owner,Task api,Func<Exception> failure,Func<Exception,bool> expectedWorker,bool workerFault,bool afterRead=false){
   if(!EarlyRound||AfterReadRound!=afterRead)return;
   Require(SpinWait.SpinUntil(()=>api.IsCompleted,5000),"early observation stimulus API did not reach its own bounded result");
   var worker=owner.OriginalTask;scope.KeepTask(worker);
   var primary=new IOException("EARLY-OBSERVATION-"+CurrentCaseName);
   scope.Early=new EarlyEvidence{Primary=primary,Owner=owner,Api=api,Worker=worker,Failure=failure,ExpectedWorker=expectedWorker,WorkerFault=workerFault};
   throw primary;
  }
  static void VerifyEarly(Scope scope,Exception primary,Exception outcome){
   var record=scope.Early;var apiError=record.Failure();var terminal=record.Worker.Exception;
   var rawWorker=terminal==null?null:terminal.InnerException;
   Console.WriteLine("EARLY_OBSERVATION_ACTUAL_API "+apiError);
   Console.WriteLine("EARLY_OBSERVATION_ACTUAL_WORKER "+terminal);
   bool actualWorker=record.WorkerFault?record.Worker.IsFaulted&&record.ExpectedWorker(terminal):record.Worker.IsCompletedSuccessfully;
   bool apiRetained=false,workerRetained=!record.WorkerFault;
   foreach(var item in scope.Secondary){
    if(item.Phase=="observe-original-api"&&Object.ReferenceEquals(item.Error,apiError))apiRetained=true;
    if(item.Phase=="observe-original-worker"&&Has(item.Error,e=>Object.ReferenceEquals(e,rawWorker)))workerRetained=true;
   }
   Console.WriteLine("EARLY_OBSERVATION_RECORD api_retained="+apiRetained+" worker_retained="+workerRetained+" actual_worker="+actualWorker+" owner_retired="+record.Owner.Retired);
   Require(Object.ReferenceEquals(primary,record.Primary)&&Object.ReferenceEquals(scope.Primary,primary)&&Has(outcome,e=>Object.ReferenceEquals(e,primary)),"injected early primary identity lost");
   var evidence=new List<Exception>();if(apiError!=null)evidence.Add(apiError);if(terminal!=null)evidence.Add(terminal);
   if(!record.Api.IsCompleted||apiError==null||!Timeout(apiError)||!actualWorker)throw new AggregateException("early observation control failed to establish actual API/worker stimulus",evidence);
   if(!apiRetained||!workerRetained||!Has(outcome,e=>Object.ReferenceEquals(e,apiError))||(record.WorkerFault&&!Has(outcome,e=>Object.ReferenceEquals(e,rawWorker))))throw new AggregateException("actual API/worker causes missing from structured early-failure outcome",evidence);
   Require(!record.Owner.Retired,"early expired control invented owner retirement");
  }
  sealed class PhaseFailure {
   public readonly string Phase;public readonly Exception Error;
   public PhaseFailure(string phase,Exception error){Phase=phase;Error=error;}
  }
  sealed class Finalizer {
   public readonly string Phase;public readonly Action Action;public readonly bool CleanupDependency;public readonly Func<bool> Ready;public bool Observed,Succeeded,Accepted;
   public Exception Error{get;private set;}
   public void Retain(Exception error){if(Error!=null)throw new InvalidOperationException("Original finalizer failure already retained");Error=error;}
   public Finalizer(string phase,Action action,bool cleanupDependency,Func<bool> ready){Phase=phase;Action=action;CleanupDependency=cleanupDependency;Ready=ready;}
  }
  sealed class OwnerSlot {
   public readonly Owner Owner;public readonly bool Eligible;
   public OwnerSlot(Owner owner,bool eligible){Owner=owner;Eligible=eligible;}
  }
  sealed class Scope {
   const int ReleaseBound=2,TaskBound=4;
   readonly List<ManualResetEventSlim> releases=new List<ManualResetEventSlim>();
   readonly List<Task> tasks=new List<Task>();
   public void KeepRelease(ManualResetEventSlim release){if(releases.Count>=ReleaseBound)throw new InvalidOperationException("Release retention bound exceeded");releases.Add(release);}
   public void KeepTask(Task task){foreach(var known in tasks)if(Object.ReferenceEquals(known,task))return;if(tasks.Count>=TaskBound)throw new InvalidOperationException("Task retention bound exceeded");tasks.Add(task);}
   const int OwnerSlotBound=1,FinalizerBound=4;
   readonly List<OwnerSlot> owners=new List<OwnerSlot>();
   readonly List<Finalizer> finalizers=new List<Finalizer>();
   readonly List<PhaseFailure> secondary=new List<PhaseFailure>();
   public EarlyEvidence Early;
   public Action BeforeCleanupBoundary;public bool EnteredCleanup,CleanupBoundaryObserved;
   public Exception Primary{get;private set;}
   bool primaryRecorded;PhaseFailure overflow;
   public void SetPrimary(Exception error){if(primaryRecorded)throw new InvalidOperationException("Scope primary already recorded");Primary=error;primaryRecorded=true;}
   public System.Collections.ObjectModel.ReadOnlyCollection<PhaseFailure> Secondary{get{
    var snapshot=new List<PhaseFailure>(secondary);
    foreach(var item in finalizers)if(item.Error!=null&&!item.Accepted){
     bool present=false;foreach(var prior in snapshot)if(prior.Phase==item.Phase&&Object.ReferenceEquals(prior.Error,item.Error)){present=true;break;}
     if(!present){if(snapshot.Count<16)snapshot.Add(new PhaseFailure(item.Phase,item.Error));else if(overflow==null)overflow=new PhaseFailure("evidence-bound",new InvalidOperationException("Lifecycle secondary evidence bound exceeded",item.Error));}
    }
    if(overflow!=null)snapshot.Add(overflow);return Array.AsReadOnly(snapshot.ToArray());
   }}
   public void KeepOwner(Owner owner,bool eligible){if(owners.Count>=OwnerSlotBound)throw new InvalidOperationException("Scope owner bound exceeded");owners.Add(new OwnerSlot(owner,eligible));}
   public Finalizer KeepFinalizer(string phase,Action action,bool cleanupDependency=false,Func<bool> ready=null){if(finalizers.Count>=FinalizerBound)throw new InvalidOperationException("Scope finalizer bound exceeded");var item=new Finalizer(phase,action,cleanupDependency,ready);finalizers.Add(item);return item;}
   public Finalizer KeepObservation(string phase,Func<bool> ready,Action action){return KeepFinalizer(phase,action,false,ready);}
   public void Perform(Finalizer item){if(item.Observed)return;if(item.Ready!=null&&!item.Ready())throw new InvalidOperationException("Original observation remains unresolved");try{item.Action();item.Succeeded=true;}catch(Exception error){item.Retain(error);throw;}finally{item.Observed=true;}}
   public void Accept(Finalizer item){Require(item.Observed,"Expected original observation was never read");item.Accepted=true;}
   public Task CreateApi(Action action){var task=new Task(action,CancellationToken.None,TaskCreationOptions.DenyChildAttach);KeepTask(task);return task;}
   public Task StartApi(Action action){var task=CreateApi(action);task.Start(TaskScheduler.Default);return task;}
   public bool AllObservationsObserved(){foreach(var item in finalizers)if(item.Ready!=null&&!item.Observed)return false;return true;}
   public bool AllSettled(){foreach(var task in tasks)if(!task.IsCompleted)return false;foreach(var slot in owners){var task=slot.Owner.OriginalTask;if(task!=null&&!task.IsCompleted)return false;}return true;}
   void Record(string phase,Exception error){if(secondary.Count<16)secondary.Add(new PhaseFailure(phase,error));else if(overflow==null)overflow=new PhaseFailure("evidence-bound",new InvalidOperationException("Lifecycle secondary evidence bound exceeded",error));}
   void Attempt(string phase,Action action){try{action();}catch(Exception error){Record(phase,error);}}
   public void Render(){if(Primary!=null)Console.WriteLine("LIFECYCLE_PRIMARY "+Primary);foreach(var item in Secondary)Console.WriteLine("LIFECYCLE_SECONDARY phase="+item.Phase+" cause="+item.Error);}
   void DrainObservations(){foreach(var item in finalizers)if(item.Ready!=null&&!item.Observed)Attempt(item.Phase,()=>{if(item.Ready())Perform(item);});}
   public Exception Finish(Exception primary){
    DrainObservations();
    foreach(var release in releases){Attempt("release-original-gate",()=>release.Set());DrainObservations();}
    foreach(var slot in owners)Attempt("capture-original-owner-task",()=>{var task=slot.Owner.OriginalTask;if(task!=null)KeepTask(task);});
    foreach(var task in tasks){Attempt("settle-retained-task",()=>Require(SpinWait.SpinUntil(()=>task.IsCompleted,3000),"retained task unresolved after release"));DrainObservations();}
    // An API can publish its actual worker during settlement. Capture that
    // original task afterward, without creating a task, owner or deadline.
    foreach(var slot in owners){Attempt("settle-original-owner-worker",()=>{var task=slot.Owner.OriginalTask;if(task!=null){KeepTask(task);Require(SpinWait.SpinUntil(()=>task.IsCompleted,3000),"original owner worker unresolved after release");}});DrainObservations();}
    foreach(var item in finalizers)if(!item.Observed){Attempt(item.Phase,()=>Perform(item));DrainObservations();}
    foreach(var slot in owners)if(slot.Eligible&&!slot.Owner.Retired&&Stopwatch.GetTimestamp()<slot.Owner.Deadline)Attempt("eligible-original-owner-cleanup",()=>{if(BeforeCleanupBoundary!=null)BeforeCleanupBoundary();Require(AllSettled(),"original borrower/API physical settlement unresolved; cleanup refused");DrainObservations();Require(AllObservationsObserved(),"exact original API/worker observation unresolved; cleanup refused");foreach(var item in finalizers)if(item.CleanupDependency)Require(item.Succeeded,"original control physical closure unresolved; cleanup refused");CleanupBoundaryObserved=AllObservationsObserved();EnteredCleanup=true;slot.Owner.Cleanup();});
    var failures=new List<Exception>();if(primary!=null)failures.Add(primary);foreach(var item in Secondary)failures.Add(item.Error);
    if(failures.Count==0)return null;if(failures.Count==1)return failures[0];return new AggregateException("Lifecycle primary and independent phase-tagged finalization failures",failures);
   }
  }

  static void Completed(Task task){Require(SpinWait.SpinUntil(()=>task.IsCompleted,2000),"original task did not settle");}
  static void Case(string name,Action<Scope> body,ref int failures,Action<Scope,Exception,Exception> verifyExpected=null){
   if(EarlyRound&&!EarlyCase(name))return;
   CurrentCaseName=name;var displayName=EarlyRound?(AfterReadRound?"after-read-observation-":"early-observation-")+name:name;
   if(retainedScopes.Count>=ScopeBound)throw new InvalidOperationException("Scope retention bound exceeded");
   var scope=new Scope();retainedScopes.Add(scope);Exception primary=Capture(()=>body(scope));scope.SetPrimary(primary);var outcome=scope.Finish(primary);
   if(scope.Early!=null){var verification=Capture(()=>VerifyEarly(scope,primary,outcome));outcome=verification==null?null:new AggregateException("Early observation control failed",primary,verification);}
   else if(verifyExpected!=null){var verification=Capture(()=>verifyExpected(scope,primary,outcome));outcome=verification==null?null:new AggregateException("Expected-primary finalization control failed",primary,verification);}
   scope.Render();
   if(outcome==null)Console.WriteLine("PASS "+displayName);else{failures++;Console.WriteLine("FAIL "+displayName+": "+outcome);}
  }
  static void ArmNative(Owner owner,int closeOccurrence,Scope scope){
   owner.TraceOperations=true;owner.BlockOperation="CloseHandle";owner.BlockOccurrence=closeOccurrence;
   owner.OperationEntered=new ManualResetEventSlim(false);owner.ContinueOperation=new ManualResetEventSlim(false);scope.KeepRelease(owner.ContinueOperation);
  }
  static void ObserveHeld(Owner owner,SubmittedCall call,Func<Exception,bool> originalCause,Scope scope){
   var api=call.Api;scope.KeepTask(api);
   Require(owner.OperationEntered.Wait(2000),"later independent native close did not reach its barrier");
   InjectEarly(scope,owner,api,()=>call.Failure,originalCause,true);
   var original=call.Worker;Require(original!=null,"exact original worker unavailable");scope.KeepTask(original);
   bool pendingBefore=!original.IsCompleted;
   bool bounded=SpinWait.SpinUntil(()=>api.IsCompleted,5000);
   var observed=bounded?call.ReadApi():null;
   bool timeoutBefore=Timeout(observed),causeBefore=originalCause(observed);
   Console.WriteLine("API_FAILURE_BEFORE_RELEASE "+observed);
   Console.WriteLine("PRE_RELEASE_OBSERVATION pending="+pendingBefore+" bounded="+bounded+" timeout="+timeoutBefore+" retained_expected_cause="+causeBefore);
   // No assertion about retained cause runs before release and actual original
   // completion. The terminal fault independently proves the intended stimulus.
   owner.ContinueOperation.Set();Completed(original);Completed(api);
   var terminal=call.ReadWorker();
   InjectEarly(scope,owner,api,()=>call.Failure,originalCause,true,true);
   bool actualCause=original.IsFaulted&&originalCause(terminal);
   Console.WriteLine("ORIGINAL_WORKER_FAILURE_AFTER_RELEASE "+terminal);
   Console.WriteLine("POST_RELEASE_CAUSAL_TRUTH actual_expected_cause="+actualCause+" native6="+Native(terminal,6)+" sharing32="+Native(terminal,32)+" same_original="+Object.ReferenceEquals(original,owner.OriginalTask)+" retired="+owner.Retired);
   var evidence=new List<Exception>();if(observed!=null)evidence.Add(observed);if(terminal!=null)evidence.Add(terminal);
   if(!actualCause)throw new AggregateException("Control did not produce the expected underlying original-worker cause",evidence);
   if(!pendingBefore||!bounded||!timeoutBefore||!Object.ReferenceEquals(original,owner.OriginalTask)||owner.Retired)throw new AggregateException("Original pending/timeout/retirement custody control failed",evidence);
   if(!causeBefore||!originalCause(observed))throw new AggregateException("Earlier timeout snapshot lost the already observed original cleanup cause",evidence);
   call.Accept();
  }
  sealed class SubmittedCall {
   readonly Scope scope;readonly Owner owner;readonly Task before;
   Task worker;Exception failure,workerFailure;
   public Task Api{get;private set;}
   public readonly Finalizer ApiObservation,ApiTaskObservation,WorkerObservation;
   public SubmittedCall(Scope scope,Owner owner,Task exactWorker=null){
    this.scope=scope;this.owner=owner;before=owner.OriginalTask;worker=exactWorker;
    ApiObservation=scope.KeepObservation("observe-original-api",()=>Failure!=null||(Api!=null&&Api.IsCompleted),()=>{
     var error=Failure;if(error!=null)ExceptionDispatchInfo.Capture(error).Throw();
     Require(Api!=null&&Api.IsCompleted,"original API observation unresolved");
    });
    ApiTaskObservation=scope.KeepObservation("observe-original-api-task",()=>Api!=null&&Api.IsCompleted,()=>{Require(Api!=null&&Api.IsCompleted,"actual API task observation unresolved");Api.GetAwaiter().GetResult();});
    WorkerObservation=scope.KeepObservation("observe-original-worker",()=>{var task=Worker;return task!=null&&task.IsCompleted;},()=>{
     var task=Worker;if(task==null)return;Require(task.IsCompleted,"original worker observation unresolved");
     if(task.IsFaulted){if(workerFailure==null)workerFailure=task.Exception;ExceptionDispatchInfo.Capture(workerFailure).Throw();}
    });
   }
   public Task Worker{get{
    var known=Volatile.Read(ref worker);if(known!=null)return known;
    var actual=owner.OriginalTask;if(actual!=null&&!Object.ReferenceEquals(actual,before))Interlocked.CompareExchange(ref worker,actual,null);
    return Volatile.Read(ref worker);
   }}
   public Exception Failure{get{return Volatile.Read(ref failure);}}
   public void Start(Action action){
    if(Api!=null)throw new InvalidOperationException("Original API already submitted");
    Api=scope.CreateApi(()=>{try{action();}catch(Exception error){Volatile.Write(ref failure,error);}finally{var retained=Worker;}});
    try{Api.Start(TaskScheduler.Default);}catch(Exception error){Volatile.Write(ref failure,error);throw;}
   }
   public Exception ReadApi(){
    var original=Capture(()=>scope.Perform(ApiObservation));var task=Capture(()=>scope.Perform(ApiTaskObservation));
    if(original!=null&&task!=null&&!Object.ReferenceEquals(original,task))return new AggregateException("Original API capture and actual task failure",original,task);return original??task;
   }
   public Exception ReadWorker(){return Capture(()=>scope.Perform(WorkerObservation));}
   public void Accept(){Require(ApiTaskObservation.Succeeded,"Actual API task fault or cancellation was not an expected captured result");scope.Accept(ApiObservation);scope.Accept(ApiTaskObservation);scope.Accept(WorkerObservation);}
  }
  sealed class ThrowDisposeStream:FileStream {
   public readonly IOException OriginalFailure=new IOException("original controlled stream disposal failure");
   public ThrowDisposeStream(string path):base(path,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.ReadWrite|FileShare.Delete){}
   protected override void Dispose(bool disposing){throw OriginalFailure;}
  }
  public static int Run(){
   if(Interlocked.CompareExchange(ref runStarted,1,0)!=0)throw new InvalidOperationException("Controls require one fresh process");
   int failures=RunRound(false)+RunRound(true)+RunRound(true,true);
   foreach(var owner in retainedOwners)if(!owner.Retired)Console.WriteLine("RETAINED_ORIGINAL_RESOURCE "+owner.Path);
   Console.WriteLine("TOTAL 17; FAILURES "+failures);return failures;
  }
  static int RunRound(bool early,bool afterRead=false){
   EarlyRound=early;AfterReadRound=afterRead;int failed=0;
   Case("failed-begin-write-cannot-be-substituted",scope=>{
    var owner=New("begin-write",15,scope,true);owner.WriteText("same.txt","original");
    Task original=null;var prior=owner.OriginalTask;
    var observe=scope.KeepFinalizer("observe-begin-write",()=>{if(original==null&&!Object.ReferenceEquals(prior,owner.OriginalTask)){original=owner.OriginalTask;scope.KeepTask(original);}if(original!=null){Require(original.IsCompleted&&Object.ReferenceEquals(original,owner.OriginalTask),"exact write observer task unavailable");owner.WaitWriteText();}});
    owner.BeginWriteText("same.txt","must fail");original=owner.OriginalTask;scope.KeepTask(original);Completed(original);
    var replacement=Capture(()=>owner.Cleanup());
    Require(replacement is InvalidOperationException,"cleanup replaced a completed unobserved write operation");
    Require(Object.ReferenceEquals(original,owner.OriginalTask),"replacement changed exact task before observation");
    var observation=Capture(()=>scope.Perform(observe));Require(Has(observation,e=>e is InvalidOperationException&&e.Message=="Scratch leaf already owned"),"BeginWrite observer lost its original failure");
    owner.Cleanup();Require(owner.Retired,"observed write failure prevented later original cleanup");scope.Accept(observe);
   },ref failed);
   Case("failed-begin-cleanup-cannot-be-substituted",scope=>{
    var owner=New("begin-cleanup",15,scope,true);owner.WriteText("held.txt","original");
    var held=new FileStream(owner.FilePath("held.txt"),FileMode.Open,FileAccess.Read,FileShare.Read);KeepControl(held);
    Task original=null;var prior=owner.OriginalTask;
    var observe=scope.KeepFinalizer("observe-begin-cleanup",()=>{if(original==null&&!Object.ReferenceEquals(prior,owner.OriginalTask)){original=owner.OriginalTask;scope.KeepTask(original);}if(original!=null){Require(original.IsCompleted&&Object.ReferenceEquals(original,owner.OriginalTask),"exact cleanup observer task unavailable");owner.WaitCleanup();}});
    SafeFileHandle heldHandle=null;
    var dispose=scope.KeepFinalizer("dispose-original-held-stream",()=>{Require(scope.AllSettled(),"held stream borrower/API physical settlement unresolved");Require(Stopwatch.GetTimestamp()<owner.Deadline,"original held stream deadline expired");held.Dispose();Require(heldHandle!=null&&heldHandle.IsClosed,"original held stream physical closure unresolved");},true);
    heldHandle=held.SafeFileHandle;
    owner.BeginCleanup();original=owner.OriginalTask;scope.KeepTask(original);Completed(original);scope.Perform(dispose);
    var replacement=Capture(()=>owner.Cleanup());Require(replacement is InvalidOperationException,"cleanup replaced a completed unobserved cleanup operation");
    Require(Object.ReferenceEquals(original,owner.OriginalTask),"cleanup replacement changed exact task before observation");
    Require(Native(Capture(()=>scope.Perform(observe)),32),"BeginCleanup observer lost original sharing failure");
    owner.Cleanup();Require(owner.Retired,"observed cleanup failure prevented later same-owner cleanup");scope.Accept(observe);
   },ref failed);
   Case("concurrent-run-observes-exact-submission",scope=>{
    var owner=New("concurrent",15,scope,true);owner.WriteText("same.txt","original");
    armed=owner;armedUsed=0;runEntered=new ManualResetEventSlim(false);runRelease=new ManualResetEventSlim(false);scope.KeepRelease(runRelease);
    var call=new SubmittedCall(scope,owner);call.Start(()=>owner.WriteText("same.txt","must fail"));var api=call.Api;scope.KeepTask(api);
    Require(runEntered.Wait(2000),"synchronous Run did not reach post-Start test barrier");
    var original=owner.OriginalTask;scope.KeepTask(original);Completed(original);
    Require(Capture(()=>owner.Cleanup()) is InvalidOperationException,"concurrent cleanup replaced the unobserved synchronous task");
    runRelease.Set();Completed(api);
    Require(Has(call.ReadApi(),e=>e is InvalidOperationException&&e.Message=="Scratch leaf already owned"),"synchronous Run returned replacement success");
    Require(Has(call.ReadWorker(),e=>e is InvalidOperationException&&e.Message=="Scratch leaf already owned"),"actual synchronous original-worker failure lost");
    owner.Cleanup();Require(owner.Retired,"observed synchronous failure prevented original cleanup");call.Accept();
   },ref failed);
   Case("closeboth-publishes-first-native-cause-before-block",scope=>{
    var owner=New("close-both",3,scope);ArmNative(owner,2,scope);
    // Deliberate invalid POSITIVE handle, never a pseudo handle. The actual
    // terminal worker must independently prove native6 before its earlier
    // timeout snapshot is checked. Second close uses this exact owner root.
    var root=(IntPtr)typeof(Owner).GetField("root",Private).GetValue(owner);
    var call=new SubmittedCall(scope,owner);call.Start(()=>RunCloseBoth(owner,root));
    ObserveHeld(owner,call,error=>Native(error,6),scope);
   },ref failed);
   Case("external-control-publishes-dispose-cause-before-block",scope=>{
    var owner=New("external",3,scope);var stream=new ThrowDisposeStream(owner.FilePath("control.txt"));KeepControl(stream);stream.WriteByte(97);stream.Flush();ArmNative(owner,1,scope);
    var call=new SubmittedCall(scope,owner);call.Start(()=>owner.RemoveControlFile("control.txt",stream));
    ObserveHeld(owner,call,error=>Has(error,e=>Object.ReferenceEquals(e,stream.OriginalFailure)),scope);
   },ref failed);
   Case("cleanupcore-publishes-sharing-cause-before-next-close",scope=>{
    var owner=New("cleanup-core",3,scope);owner.WriteText("held.txt","original");owner.WriteText("later.txt","later original");
    var held=new FileStream(owner.FilePath("held.txt"),FileMode.Open,FileAccess.Read,FileShare.Read);KeepControl(held);ArmNative(owner,2,scope);
    var call=new SubmittedCall(scope,owner);call.Start(()=>owner.Cleanup());
    ObserveHeld(owner,call,error=>Native(error,32),scope);
   },ref failed);
   Case("public-observer-acceptance-is-original-clock-bounded",scope=>{
    var owner=New("observer-acceptance",3,scope);
    owner.BeginWriteText("original.txt","original completed write");var original=owner.OriginalTask;scope.KeepTask(original);Completed(original);
    Require(original.IsCompletedSuccessfully,"original write did not complete before observer gate");
    owner.BeforeWaitAcceptanceEntered=new ManualResetEventSlim(false);owner.ContinueWaitAcceptance=new ManualResetEventSlim(false);scope.KeepRelease(owner.ContinueWaitAcceptance);
    long completedAt=0;var call=new SubmittedCall(scope,owner,original);
    call.Start(()=>{try{owner.WaitWriteText();}finally{Interlocked.Exchange(ref completedAt,Stopwatch.GetTimestamp());}});var api=call.Api;scope.KeepTask(api);
    Require(owner.BeforeWaitAcceptanceEntered.Wait(2000),"public observer did not reach its acceptance gate");
    InjectEarly(scope,owner,api,()=>call.Failure,null,false);
    // 250ms is observation/scheduler tolerance, never an operation or cleanup
    // deadline. The actual completion ticks are logged independently.
    long tolerance=Stopwatch.Frequency/4;
    int observeMs=(int)Math.Clamp((owner.Deadline-Stopwatch.GetTimestamp())*1000/Stopwatch.Frequency+250,0L,5000L);
    bool completedWithoutRelease=SpinWait.SpinUntil(()=>api.IsCompleted,observeMs);
    long beforeReleaseCompletedAt=Interlocked.Read(ref completedAt);var beforeReleaseFailure=completedWithoutRelease?call.ReadApi():null;
    bool gateStillHeld=!owner.ContinueWaitAcceptance.IsSet;
    Console.WriteLine("OBSERVER_BEFORE_RELEASE completed="+completedWithoutRelease+" gate_held="+gateStillHeld+" deadline="+owner.Deadline+" completed_at="+beforeReleaseCompletedAt+" observation_tolerance_ticks="+tolerance+" failure="+beforeReleaseFailure);
    owner.ContinueWaitAcceptance.Set();Completed(api);
    var failure=call.Failure;if(!completedWithoutRelease)call.ReadApi();
    Require(call.ReadWorker()==null,"successful original observer worker became a failure");
    InjectEarly(scope,owner,api,()=>call.Failure,null,false,true);
    Console.WriteLine("OBSERVER_AFTER_RELEASE_FAILURE "+failure);
    var evidence=new List<Exception>();if(beforeReleaseFailure!=null)evidence.Add(beforeReleaseFailure);if(failure!=null&&!Object.ReferenceEquals(failure,beforeReleaseFailure))evidence.Add(failure);
    if(!completedWithoutRelease||!gateStillHeld||!Timeout(beforeReleaseFailure)||beforeReleaseCompletedAt==0||beforeReleaseCompletedAt>owner.Deadline+tolerance)throw new AggregateException("Public Wait exceeded its original deadline while acceptance gate remained held",evidence);
    Require(Object.ReferenceEquals(original,owner.OriginalTask)&&original.IsCompletedSuccessfully&&!owner.Retired,"public observer changed original completed-task or retirement truth");
    call.Accept();
   },ref failed);
   var injected=new IOException("EARLY-LIFECYCLE-PRIMARY");Owner earlyOwner=null;FileStream earlyHeld=null;SafeFileHandle earlyHandle=null;Task earlyOriginal=null;bool observedEarly=false;Exception earlyObservation=null;
   Case("early-primary-attempts-independent-healthy-finalization",scope=>{
    earlyOwner=New("early-primary",15,scope,true);earlyOwner.WriteText("held.txt","original guarded leaf");
    earlyHeld=new FileStream(earlyOwner.FilePath("held.txt"),FileMode.Open,FileAccess.Read,FileShare.Read);KeepControl(earlyHeld);
    var prior=earlyOwner.OriginalTask;
    scope.KeepFinalizer("observe-injected-begin-cleanup",()=>{if(earlyOriginal==null&&!Object.ReferenceEquals(prior,earlyOwner.OriginalTask)){earlyOriginal=earlyOwner.OriginalTask;scope.KeepTask(earlyOriginal);}if(earlyOriginal!=null){Require(earlyOriginal.IsCompleted&&Object.ReferenceEquals(earlyOriginal,earlyOwner.OriginalTask),"injected exact observer task unavailable");observedEarly=true;earlyObservation=Capture(()=>earlyOwner.WaitCleanup());if(earlyObservation!=null)ExceptionDispatchInfo.Capture(earlyObservation).Throw();}});
    scope.KeepFinalizer("dispose-injected-original-stream",()=>{Require(scope.AllSettled(),"injected stream borrower/API unresolved");Require(Stopwatch.GetTimestamp()<earlyOwner.Deadline,"injected original stream deadline expired");earlyHeld.Dispose();Require(earlyHandle!=null&&earlyHandle.IsClosed,"injected original stream physical closure unresolved");},true);
    earlyHandle=earlyHeld.SafeFileHandle;
    earlyOwner.BeginCleanup();earlyOriginal=earlyOwner.OriginalTask;scope.KeepTask(earlyOriginal);Completed(earlyOriginal);
    Require(earlyOriginal.IsFaulted&&Native(earlyOriginal.Exception,32),"injected actual sharing failure not established");
    throw injected;
   },ref failed,(scope,primary,outcome)=>{
    Console.WriteLine("EARLY_PRIMARY_FINALIZATION observed="+observedEarly+" sharing32="+Native(earlyObservation,32)+" stream_closed="+(earlyHandle!=null&&earlyHandle.IsClosed)+" owner_retired="+(earlyOwner!=null&&earlyOwner.Retired));
    Require(Object.ReferenceEquals(primary,injected)&&Object.ReferenceEquals(scope.Primary,injected)&&Has(outcome,e=>Object.ReferenceEquals(e,injected)),"actual injected primary identity lost");
    Require(observedEarly&&Native(earlyObservation,32),"matching original Begin/Wait observation skipped after early primary");
    Require(earlyHandle!=null&&earlyHandle.IsClosed,"original held stream closure skipped after early primary");
    Require(earlyOwner!=null&&earlyOwner.Retired,"healthy original-owner cleanup skipped after early primary");
    Require(scope.Secondary.Count==1&&scope.Secondary[0].Phase=="observe-injected-begin-cleanup"&&Object.ReferenceEquals(scope.Secondary[0].Error,earlyObservation),"phase-tagged independent secondary lost");
   });
   var boundaryPrimary=new IOException("EARLY-CLEANUP-BOUNDARY-PRIMARY");Owner boundaryOwner=null;SubmittedCall boundaryCall=null;Task boundaryWorker=null;bool heldAtBoundary=false;Exception boundaryApiError=null;
   Case("cleanup-boundary-observes-terminal-exact-api-before-retirement",scope=>{
    boundaryOwner=New("cleanup-boundary",15,scope,true);boundaryOwner.WriteText("same.txt","original");
    armed=boundaryOwner;armedUsed=0;runEntered=new ManualResetEventSlim(false);runRelease=new ManualResetEventSlim(false);
    // This exact API release is intentionally held through the final drain.
    // A transparent boundary hook releases it immediately before AllSettled.
    boundaryCall=new SubmittedCall(scope,boundaryOwner);boundaryCall.Start(()=>boundaryOwner.WriteText("same.txt","must fail"));
    scope.BeforeCleanupBoundary=()=>{
     heldAtBoundary=!boundaryCall.Api.IsCompleted&&!runRelease.IsSet&&!boundaryCall.ApiObservation.Observed&&!boundaryCall.ApiTaskObservation.Observed;
     runRelease.Set();Completed(boundaryCall.Api);boundaryApiError=boundaryCall.Failure;
     Require(heldAtBoundary,"exact API was not held through the last normal observation drain");
     Require(Has(boundaryApiError,e=>e is InvalidOperationException&&e.Message=="Scratch leaf already owned"),"released exact API did not report its real original worker failure");
    };
    Require(runEntered.Wait(2000),"boundary exact API did not reach the post-Start barrier");
    boundaryWorker=boundaryOwner.OriginalTask;scope.KeepTask(boundaryWorker);Completed(boundaryWorker);
    Require(boundaryWorker.IsFaulted&&Has(boundaryWorker.Exception,e=>e is InvalidOperationException&&e.Message=="Scratch leaf already owned"),"boundary actual original-worker stimulus unavailable");
    throw boundaryPrimary;
   },ref failed,(scope,primary,outcome)=>{
    bool apiRetained=false;foreach(var item in scope.Secondary)if(item.Phase=="observe-original-api"&&Object.ReferenceEquals(item.Error,boundaryApiError))apiRetained=true;
    Console.WriteLine("CLEANUP_BOUNDARY_RECORD held="+heldAtBoundary+" entered_cleanup="+scope.EnteredCleanup+" observed_before_cleanup="+scope.CleanupBoundaryObserved+" api_retained="+apiRetained+" actual_worker="+(boundaryWorker!=null&&boundaryWorker.IsFaulted)+" owner_retired="+(boundaryOwner!=null&&boundaryOwner.Retired));
    Console.WriteLine("CLEANUP_BOUNDARY_ACTUAL_API "+boundaryApiError);
    Require(Object.ReferenceEquals(primary,boundaryPrimary)&&Object.ReferenceEquals(scope.Primary,primary)&&Has(outcome,e=>Object.ReferenceEquals(e,primary)),"boundary injected primary identity lost");
    Require(heldAtBoundary&&boundaryCall.Api.IsCompleted&&boundaryApiError!=null&&boundaryWorker.IsFaulted,"boundary actual API/worker stimulus unavailable");
    Require(scope.EnteredCleanup&&scope.CleanupBoundaryObserved&&apiRetained&&Has(outcome,e=>Object.ReferenceEquals(e,boundaryApiError)),"original owner cleanup passed physical settlement before exact API observation/cause preservation");
    Require(boundaryOwner.Retired,"healthy boundary original-owner cleanup did not retire");
   });
   return failed;
  }
 }
}
