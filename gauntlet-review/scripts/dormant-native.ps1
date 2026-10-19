# Dormant original-owner process definitions, extracted from 63dbc50992ce0ad792382900666440e95d7178bd.
# Production entry points do not load this file. Only a fresh isolated test child may load it
# until a separately certified activation assembles the matched runtime.
# Keep this one definition AST intact: native workers copy its complete function pack.
Set-StrictMode -Version Latest

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
    if (-not $IsWindows) { throw 'Live gate ownership and process containment require Windows' }
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
            if(result.Failure==null)result.Failure=fault;
            else if(cleanup&&result.CleanupFailures.Length<2)result.CleanupFailures=result.CleanupFailures.Concat(new[]{fault}).ToArray();
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
        static void Close(ref IntPtr handle) { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
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
            public const int MaximumBytes = 4 * 1024 * 1024;
        }
        static async Task<string> Capture(FileStream stream, CaptureBudget budget) {
            var buffer = new byte[4096];
            using (var retained = new MemoryStream()) {
                int count;
                while ((count = await stream.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) != 0) {
                    if (Interlocked.Add(ref budget.Used, count) > CaptureBudget.MaximumBytes) {
                        Interlocked.Exchange(ref budget.Exceeded, 1);
                        throw new InvalidOperationException("Aggregate process output exceeded its retention budget");
                    }
                    retained.Write(buffer, 0, count);
                }
                return Encoding.UTF8.GetString(retained.ToArray());
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
            var budget = new CaptureBudget();
            string stage="native_setup";
            Func<bool> peerFailure = () => {
                if(!failureCancellation.IsCancellationRequested) return false;
                RecordFailure(result,"transport_abort",stage,new OperationCanceledException());
                result.ErrorMessage="Paired review transport failed";
                return true;
            };
            try {
                if(peerFailure()) throw new OperationCanceledException("Paired review transport failed before launch");
                if (remaining() == 0) { result.TimedOut=true; throw new TimeoutException("Original process deadline expired before launch"); }
                job = CreateJobObjectW(IntPtr.Zero, IntPtr.Zero);
                if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
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
                Require(AssignProcessToJobObject(job, process.Process));
                assigned = true;
                Close(ref stdinRead); Close(ref stdoutWrite); Close(ref stderrWrite);
                inputStream = new FileStream(new SafeFileHandle(stdinWrite, true), FileAccess.Write, 4096, false); stdinWrite=IntPtr.Zero;
                outputStream = new FileStream(new SafeFileHandle(stdoutRead, true), FileAccess.Read, 4096, false); stdoutRead=IntPtr.Zero;
                errorStream = new FileStream(new SafeFileHandle(stderrRead, true), FileAccess.Read, 4096, false); stderrRead=IntPtr.Zero;
                outputTask=Capture(outputStream, budget); errorTask=Capture(errorStream, budget);
                if(peerFailure()) throw new OperationCanceledException("Paired review transport failed before resume");
                if (executionRemaining() == 0) { result.TimedOut=true; throw new TimeoutException("Original process deadline expired before resume"); }
                if (ResumeThread(process.Thread) == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
                Close(ref process.Thread);
                var bytes = Encoding.UTF8.GetBytes(input ?? "");
                stage="stdin";
                writeTask = inputStream.WriteAsync(bytes, 0, bytes.Length);
                while (!writeTask.IsCompleted && executionRemaining() > 0 && Volatile.Read(ref budget.Exceeded) == 0 && !failureCancellation.IsCancellationRequested)
                    Thread.Sleep(Math.Min(10, executionRemaining()));
                peerFailure();
                bool stdinDone = writeTask.IsCompletedSuccessfully;
                if (result.ErrorMessage==null && (writeTask.IsFaulted || writeTask.IsCanceled)) {
                    result.ErrorMessage="stdin transport failed before the complete prompt was delivered: " + writeTask.Exception?.GetBaseException().Message;
                    RecordFailure(result,"stdin_failure",stage,(Exception)writeTask.Exception??new OperationCanceledException());
                }
                if (stdinDone) { inputStream.Dispose(); inputStream=null; }
                bool exited = false;
                stage="process_exit";
                while (stdinDone && result.ErrorMessage == null && executionRemaining() > 0 && Volatile.Read(ref budget.Exceeded) == 0 && !failureCancellation.IsCancellationRequested) {
                    if (WaitForSingleObject(process.Process, (uint)Math.Min(20, executionRemaining())) == 0) { exited=true; break; }
                }
                peerFailure();
                result.TimedOut = !exited && executionRemaining() == 0;
                uint exitCode;
                if (exited) { Require(GetExitCodeProcess(process.Process, out exitCode)); result.ExitCode=unchecked((int)exitCode); }
                else { result.ExitCode=-1; }
                // Parent exit is insufficient: terminate and query the entire owned job.
                stage="process_retirement";
                if (ActiveCount(job) != 0) Require(TerminateJobObject(job, 1));
                while (ActiveCount(job) != 0 && remaining() > 0) Thread.Sleep(Math.Min(10, remaining()));
                result.ProcessTreeRetired = ActiveCount(job) == 0;
                if (!result.ProcessTreeRetired) {result.ErrorMessage="Owned process job did not retire before the shared deadline";RecordFailure(result,"retirement_deadline",stage,new TimeoutException());}
                stage="process_capture";
                try { Task.WaitAll(new Task[] { outputTask, errorTask }, remaining()); } catch (AggregateException) { }
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
                            Require(TerminateJobObject(job, 1));
                            while (ActiveCount(job) != 0 && remaining() > 0) Thread.Sleep(Math.Min(10, remaining()));
                            result.ProcessTreeRetired=ActiveCount(job) == 0;
                        } else {
                            Require(TerminateProcess(process.Process, 1));
                            result.ProcessTreeRetired=WaitForSingleObject(process.Process, (uint)remaining()) == 0;
                        }
                    } catch (Exception cleanupError) { result.ProcessTreeRetired=false; RecordFailure(result,"native_cleanup","process_cleanup",cleanupError,true);result.ErrorMessage += "; retirement: " + cleanupError.Message; }
                } else if (!created) { result.ProcessTreeRetired=true; }
                // Every exit path, including a suspended-start abort, must observe the
                // actual stdin and inherited-pipe tasks before claiming retirement.
                var ioTasks=new List<Task>();
                if(writeTask!=null) ioTasks.Add(writeTask);
                if(outputTask!=null) ioTasks.Add(outputTask);
                if(errorTask!=null) ioTasks.Add(errorTask);
                try {if(ioTasks.Any(task=>!task.IsCompleted)) Task.WaitAll(ioTasks.ToArray(),remaining());}catch(AggregateException) { }
                if(ioTasks.Any(task=>!task.IsCompleted)) {
                    result.ProcessTreeRetired=false;result.ExitCode=-1;
                    result.ErrorMessage="Owned process IO did not retire before the shared deadline";
                    RecordFailure(result,"pipe_retirement","process_cleanup",new TimeoutException(),true);
                }
                if(outputTask!=null&&outputTask.IsCompletedSuccessfully) result.Stdout=outputTask.Result;
                if(errorTask!=null&&errorTask.IsCompletedSuccessfully) result.Stderr=errorTask.Result;
                Close(ref job); Close(ref process.Thread); Close(ref process.Process);
                Close(ref stdinRead); Close(ref stdinWrite); Close(ref stdoutRead); Close(ref stdoutWrite); Close(ref stderrRead); Close(ref stderrWrite);
                if (attributesReady) DeleteProcThreadAttributeList(attributes);
                if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
                if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
                if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
                if (inputStream != null) inputStream.Dispose();
                if (outputStream != null) outputStream.Dispose();
                if (errorStream != null) errorStream.Dispose();
            }
            return result;
        }
    }
}
'@
    $sourceIdentity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source))).ToLowerInvariant()
    $loaded = 'GauntletLive.Native' -as [type]
    if ($loaded) {
        $identityProperty = $loaded.GetProperty('SourceIdentity')
        if ($identityProperty -and $identityProperty.GetValue($null) -ceq $sourceIdentity) { return }
        throw 'Loaded live-gate native helper differs from current source; use a fresh PowerShell process'
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
        $pipeline=$context['OwnedWorkOwner']['Pipeline'];$before=$pipeline.Streams.Error.Count
        $State['Result']=Invoke-BoundedProcessCore @Arguments
    }finally{
        if($null -ne $pipeline -and $pipeline.Streams.Error.Count -gt $before){
            $cause=Get-ReviewSafeCause -Exception $pipeline.Streams.Error[$before].Exception
            $State['NativeErrorStream']=New-ReviewReadOnlyRecord -Values @{Code='owned_error_stream';Stage='worker_invoke';Type=$cause.Type;HResult=$cause.HResult;NativeError=$cause.NativeError}
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
        $r.Failure=New-ReviewReadOnlyRecord -Values @{Code='native_startup';Stage=$stage;Type=$cause.Type;HResult=$cause.HResult;NativeError=$cause.NativeError}
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
    $type=$Exception.GetType().FullName
    if($type.Length -gt 256 -or $type -cnotmatch '^[A-Za-z0-9_.+`\[\], ]+$'){$type='System.Exception'}
    $cause=@{Type=$type;HResult=[int]$Exception.HResult;JsonLine=$null;JsonByte=$null;SocketError=$null;HttpStatus=$null;NativeError=$null;Inner=$null;OmittedInnerCauses=0}
    if($Exception -is [ComponentModel.Win32Exception]){$cause.NativeError=[int]$Exception.NativeErrorCode}
    if($Exception -is [Net.Sockets.SocketException]){$cause.SocketError=[int]$Exception.SocketErrorCode}
    if($Exception -is [Text.Json.JsonException]){$cause.JsonLine=$Exception.LineNumber;$cause.JsonByte=$Exception.BytePositionInLine}
    if($Exception -is [Net.Http.HttpRequestException] -and $null -ne $Exception.StatusCode){$cause.HttpStatus=[int]$Exception.StatusCode}
    if($null -ne $Exception.InnerException){
        if($Depth -lt 2){$cause.Inner=Get-ReviewSafeCause -Exception $Exception.InnerException -Depth ($Depth+1)}else{$cause.OmittedInnerCauses=1}
    }
    New-ReviewReadOnlyRecord -Values $cause
}

function New-ReviewTransportFault {
    param([string]$Code,[string]$Stage,[Exception]$Exception)
    $typed=$Exception
    for($i=0;$i -lt 8 -and $null -ne $typed;$i++){
        if($typed.GetType().FullName -ceq 'GauntletTransport.TransportException'){
            return (New-ReviewReadOnlyRecord -Values @{Code=$typed.Code;Stage=$typed.Stage;Cause=$typed.Cause})
        }
        if($typed.Data.Contains('ReviewCode')){$Code=[string]$typed.Data['ReviewCode'];if($typed.Data.Contains('ReviewStage')){$Stage=[string]$typed.Data['ReviewStage']};break}
        $typed=$typed.InnerException
    }
    New-ReviewReadOnlyRecord -Values @{Code=$Code;Stage=$Stage;Cause=(Get-ReviewSafeCause -Exception $Exception)}
}

function Throw-ReviewTransportFault {
    param([string]$Code)
    $fault=[InvalidOperationException]::new('Review attempt refused')
    $fault.Data['ReviewCode']=$Code
    throw $fault
}

function Start-ReviewPipelineDisposal {
    param($Owner,$Pipeline)
    $Owner['DisposalIntent']=$true
    $dispose=[Delegate]::CreateDelegate([Action],$Pipeline,'Dispose')
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
    Set-StartupStage 'worker_configure';Test-StartupClock
    $il.Emit($op::Ldloc,$pipeline);$il.Emit($op::Callvirt,$getType);$il.Emit($op::Stloc,$pipelineType)
    $il.Emit($op::Ldc_I4_1);$il.Emit($op::Newarr,[object]);$il.Emit($op::Stloc,$one)
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
    $pack=[object[]]@($method,$Owner,$Bootstrap,[object[]]$ArgumentList,[long]$Owner['Deadline'],[type[]]@([string]),[type[]]@([object]))
    $create=$thunk.CreateDelegate([Func[object]],$pack)
    [Threading.Tasks.Task[object]]::Factory.StartNew([Func[object]]$create)
}

function Start-ReviewOwnedPipelineInvocation {
    param($Pipeline)
    $method=@($Pipeline.GetType().GetMethods()|Where-Object {$_.Name -ceq 'Invoke' -and -not $_.IsGenericMethod -and $_.GetParameters().Count -eq 0})[0]
    $invoke=[Delegate]::CreateDelegate([Func[object]],$Pipeline,$method)
    [Threading.Tasks.Task[object]]::Factory.StartNew([Func[object]]$invoke)
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
    foreach($name in @('CreationFailure','InvocationFailure','ErrorStreamFailure','DisposalFailure','ObserverFailure','DeadlineFailure')){
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
            $snapshots.Add((New-ReviewReadOnlyRecord -Values @{Token=$key;Completed=$false;Retired=$false;TimedOut=[bool]$owner['TimedOut'];Result=$null;Failure=$faults.Failure;CleanupFailures=$faults.CleanupFailures}))
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
                if($null -ne $owner['Pipeline'] -and $owner['Pipeline'].Streams.Error.Count -gt 0){
                    if($null -eq $owner['ErrorStreamFailure']){$null=$owner.TryAdd('ErrorStreamFailure',(New-ReviewTransportFault -Code 'owned_error_stream' -Stage 'worker_invoke' -Exception $owner['Pipeline'].Streams.Error[0].Exception))}
                }
                if(-not $owner['Submitted'] -or -not $state.ContainsKey('ActionEntered')){$state['CoreRetired']=$true}
                if($null -ne $owner['Pipeline'] -and $null -eq $dispose){
                    $dispose=Start-ReviewPipelineDisposal -Owner $owner -Pipeline $owner['Pipeline']
                }
            }
        }
        $workerDone=$null -ne $created -and $created.IsCompleted -and ($null -eq $invoked -or $invoked.IsCompleted)
        $disposed=($null -eq $owner['Pipeline'] -and $workerDone) -or ($null -ne $dispose -and $dispose.IsCompletedSuccessfully)
        if($null -ne $dispose -and $dispose.IsFaulted){
            if($null -eq $owner['DisposalFailure']){$null=$owner.TryAdd('DisposalFailure',(New-ReviewTransportFault -Code 'owned_disposal' -Stage 'worker_dispose' -Exception $dispose.Exception))}
        }
        $retired=$workerDone -and $disposed -and $state['CoreRetired'] -is [bool] -and $state['CoreRetired']
        $faults=Get-ReviewOwnedWorkFailures -Owner $owner
        # Retained only for private diagnostics; public outcomes use this local
        # immutable projection, never the convenience fields as authority.
        $owner['Failure']=$faults.Failure;$owner['CleanupFailures']=$faults.CleanupFailures
        $failure=$faults.Failure
        $result=if($null -eq $failure -and -not $owner['Abandoned'] -and $null -ne $invoked -and $invoked.IsCompletedSuccessfully -and $state.ContainsKey('Result')){$state['Result']}else{$null}
        $snapshot=New-ReviewReadOnlyRecord -Values @{Token=$key;Completed=(-not $owner['Abandoned'] -and $null -ne $invoked -and $invoked.IsCompletedSuccessfully);Retired=[bool]$retired;TimedOut=[bool]$owner['TimedOut'];Result=$result;Failure=$failure;CleanupFailures=$faults.CleanupFailures}
        if($retired){$owner['RetirementConfirmed']=$true;$null=Remove-ReviewOwnedWorkEntry -OwnerRegistry $OwnerRegistry -Token $key -Owner $owner}
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
        foreach($name in @('New-ReviewReadOnlyRecord','Get-ReviewSafeCause','New-ReviewTransportFault','Throw-ReviewCodedFailure')){
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
    $state['ActionEntered']=$true
    & $workerName -State $state -Arguments $arguments
}
catch {
    if(-not $state.ContainsKey('Failure') -or $null -eq $state['Failure']){$state['Failure']=New-ReviewTransportFault -Code 'owned_worker' -Stage $(if($state.ContainsKey('Stage')){$state['Stage']}else{'worker'}) -Exception $_.Exception}
}
'@
        $owner['CreationTask']=Start-ReviewOwnedPipelineCreation -Owner $owner -Bootstrap $bootstrap -ArgumentList @($State,$workerDefinitions,$Arguments,$SharedVariables,$WorkerName)
        if(-not $owner['CreationTask'].Wait((Get-ReviewRemainingMilliseconds $DeadlineTimestamp))){Throw-ReviewCodedFailure 'owned_deadline' 'worker_create'}
        $pipeline=$owner['CreationTask'].Result;$owner['Pipeline']=$pipeline
        if((Get-ReviewRemainingMilliseconds $DeadlineTimestamp) -le 0){Throw-ReviewCodedFailure 'owned_deadline' 'worker_start'}
        $owner['Submitted']=$true;$owner['InvokeTask']=Start-ReviewOwnedPipelineInvocation -Pipeline $pipeline
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
