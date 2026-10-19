using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace GauntletTransport
{
    public sealed class SanitizedCause
    {
        public string Type { get; internal set; }
        public int HResult { get; internal set; }
        public long? JsonLine { get; internal set; }
        public long? JsonByte { get; internal set; }
        public int? SocketError { get; internal set; }
        public int? NativeError {get;internal set;}
        public int? HttpStatus { get; internal set; }
        public string HeaderNameSha256 { get; internal set; }
        public SanitizedCause Inner { get; internal set; }
        public int OmittedInnerCauses { get; internal set; }
        internal static SanitizedCause From(Exception error)
        {return From(error,0);}
        static SanitizedCause From(Exception error,int depth)
        {
            if(error==null) return null;
            string name=error.GetType().FullName??"Exception";
            if(name.Length>256||name.Any(c=>!((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||"._+`[]".IndexOf(c)>=0))) name="Exception";
            var cause=new SanitizedCause {Type=name,HResult=error.HResult};
            var json=error as JsonException; if(json!=null) {cause.JsonLine=json.LineNumber;cause.JsonByte=json.BytePositionInLine;}
            var socket=error as SocketException; if(socket!=null) cause.SocketError=socket.NativeErrorCode;
            var native=error as System.ComponentModel.Win32Exception;if(native!=null) cause.NativeError=native.NativeErrorCode;
            var http=error as HttpRequestException; if(http!=null&&http.StatusCode.HasValue) cause.HttpStatus=(int)http.StatusCode.Value;
            var header=error as HeaderPolicyException;if(header!=null) cause.HeaderNameSha256=header.NameSha256;
            var aggregate=error as AggregateException;
            if(aggregate!=null&&aggregate.InnerExceptions.Count>1) cause.OmittedInnerCauses=aggregate.InnerExceptions.Count-1;
            if(error.InnerException!=null) {if(depth<2) cause.Inner=From(error.InnerException,depth+1);else cause.OmittedInnerCauses++;}
            return cause;
        }
    }
    public sealed class SanitizedFailure
    {
        public string Code {get;internal set;}
        public string Stage {get;internal set;}
        public SanitizedCause Cause {get;internal set;}
    }
    internal sealed class HeaderPolicyException : Exception
    {
        internal string NameSha256 {get;private set;}
        internal HeaderPolicyException(string name) : base("Request header rejected.")
        {
            // Names have already passed the bounded ASCII token parser. Retain only
            // their case-insensitive digest; never retain the name or header value.
            NameSha256=Convert.ToHexString(SHA256.HashData(Encoding.ASCII.GetBytes(name.ToLowerInvariant()))).ToLowerInvariant();
        }
    }
    // No rejected input, header, credential or native exception enters the public surface.
    public class TransportException : Exception
    {
        public string Code {get;private set;}
        public string Stage {get;private set;}
        public SanitizedCause Cause {get;private set;}
        public SanitizedFailure[] CleanupFailures {get;internal set;}=Array.Empty<SanitizedFailure>();
        internal object UnresolvedOwner {get;private set;}
        internal void RetainOwner(object owner) {UnresolvedOwner=owner;}
        internal TransportException(string code="request_shape",string stage="transform_validate",Exception cause=null)
            : base("Transport request rejected.") {Code=code;Stage=stage;Cause=SanitizedCause.From(cause);}
        internal TransportException(TransportException failure) : base("Transport request rejected.") {Code=failure.Code;Stage=failure.Stage;Cause=failure.Cause;CleanupFailures=failure.CleanupFailures;UnresolvedOwner=failure.UnresolvedOwner;}
    }
    internal sealed class ConstructionCustody
    {
        internal Bridge Bridge {get;private set;}
        internal HttpMessageHandler Handler {get;private set;}
        internal ConstructionCustody(Bridge bridge,HttpMessageHandler handler) {Bridge=bridge;Handler=handler;}
    }

    // Capacity is allocated once; rejected writes never grow retention past the limit.
    internal sealed class BoundedBuffer : Stream
    {
        readonly byte[] bytes; readonly string code,stage; int length;
        internal BoundedBuffer(int capacity,string code,string stage) {bytes=new byte[capacity];this.code=code;this.stage=stage;}
        internal ReadOnlyMemory<byte> Written {get{return bytes.AsMemory(0,length);}}
        internal byte[] ToArray() {byte[] result=new byte[length];Buffer.BlockCopy(bytes,0,result,0,length);return result;}
        internal void Reset() {length=0;}
        public override bool CanRead {get{return false;}} public override bool CanSeek {get{return false;}} public override bool CanWrite {get{return true;}}
        public override long Length {get{return length;}} public override long Position {get{return length;}set{throw new NotSupportedException();}}
        public override void Flush() {} public override long Seek(long x,SeekOrigin origin) {throw new NotSupportedException();}
        public override void SetLength(long value) {throw new NotSupportedException();} public override int Read(byte[] b,int o,int n) {throw new NotSupportedException();}
        public override void Write(byte[] b,int o,int n) {if(n>bytes.Length-length) throw new TransportException(code,stage);Buffer.BlockCopy(b,o,bytes,length,n);length+=n;}
        public override void WriteByte(byte value) {if(length==bytes.Length) throw new TransportException(code,stage);bytes[length++]=value;}
    }

    // Emits escaped strings a scalar at a time: no whole escaped-token scratch buffer.
    internal sealed class JsonSink
    {
        struct Frame {internal bool Object,First,Pending;}
        readonly BoundedBuffer output; readonly Frame[] frames=new Frame[Bridge.JsonDepthLimit]; int depth;
        internal JsonSink(BoundedBuffer output) {this.output=output;}
        void Byte(char c) {output.WriteByte((byte)c);}
        void BeforeValue() {
            if(depth==0) return;var frame=frames[depth-1];
            if(frame.Object) {if(!frame.Pending) throw new TransportException("json_write","transform_write");frame.Pending=false;}
            else {if(!frame.First) Byte(',');frame.First=false;}
            frames[depth-1]=frame;
        }
        void Start(bool obj) {BeforeValue();if(depth==frames.Length) throw new TransportException("json_depth","transform_write");Byte(obj?'{':'[');frames[depth++]=new Frame {Object=obj,First=true};}
        internal void WriteStartObject() {Start(true);} internal void WriteStartArray() {Start(false);}
        internal void WriteEndObject() {End(true);} internal void WriteEndArray() {End(false);}
        void End(bool obj) {if(depth==0||frames[depth-1].Object!=obj||frames[depth-1].Pending) throw new TransportException("json_write","transform_write");depth--;Byte(obj?'}':']');}
        internal void WritePropertyName(string name) {
            if(depth==0||!frames[depth-1].Object||frames[depth-1].Pending) throw new TransportException("json_write","transform_write");
            var f=frames[depth-1];if(!f.First) Byte(',');f.First=false;f.Pending=true;frames[depth-1]=f;
            String(name,0,name.Length);Byte(':');
        }
        internal void WriteStringValue(string value) {WriteStringValue(value,0,value.Length);}
        internal void WriteStringValue(string value,int offset,int length) {BeforeValue();String(value,offset,length);}
        void String(string value,int offset,int length) {
            Byte('"');int end=offset+length;
            for(int i=offset;i<end;i++) {
                int scalar=value[i];
                if(scalar=='"'||scalar=='\\') {Byte('\\');Byte((char)scalar);continue;}
                if(scalar<32) {const string hex="0123456789abcdef";Byte('\\');Byte('u');Byte('0');Byte('0');Byte(hex[scalar>>4]);Byte(hex[scalar&15]);continue;}
                if(char.IsHighSurrogate((char)scalar)) {if(++i>=end||!char.IsLowSurrogate(value[i])) throw new TransportException("json_unicode","transform_write");scalar=char.ConvertToUtf32((char)scalar,value[i]);}
                else if(char.IsLowSurrogate((char)scalar)) throw new TransportException("json_unicode","transform_write");
                if(scalar<128) output.WriteByte((byte)scalar);
                else if(scalar<2048) {output.WriteByte((byte)(192|(scalar>>6)));output.WriteByte((byte)(128|(scalar&63)));}
                else if(scalar<65536) {output.WriteByte((byte)(224|(scalar>>12)));output.WriteByte((byte)(128|((scalar>>6)&63)));output.WriteByte((byte)(128|(scalar&63)));}
                else {output.WriteByte((byte)(240|(scalar>>18)));output.WriteByte((byte)(128|((scalar>>12)&63)));output.WriteByte((byte)(128|((scalar>>6)&63)));output.WriteByte((byte)(128|(scalar&63)));}
            } Byte('"');
        }
        void Literal(string raw) {BeforeValue();foreach(char c in raw) {if(c>127) throw new TransportException("json_write","transform_write");Byte(c);}}
        internal void Element(JsonElement element) {
            switch(element.ValueKind) {
                case JsonValueKind.Object:WriteStartObject();foreach(var p in element.EnumerateObject()) {WritePropertyName(p.Name);Element(p.Value);}WriteEndObject();break;
                case JsonValueKind.Array:WriteStartArray();foreach(var v in element.EnumerateArray()) Element(v);WriteEndArray();break;
                case JsonValueKind.String:WriteStringValue(element.GetString());break;
                case JsonValueKind.Number:Literal(element.GetRawText());break;
                case JsonValueKind.True:Literal("true");break;case JsonValueKind.False:Literal("false");break;case JsonValueKind.Null:Literal("null");break;
                default:throw new TransportException("json_shape","transform_write");
            }
        }
    }

    public sealed class TransformResult
    {
        internal bool SupportedInferenceProfile { get; set; }
        public byte[] Bytes { get; internal set; }
        public string PromptSha256 { get; internal set; }
        public bool PromptSeen { get; internal set; }
        public int TextBlocks { get; internal set; }
        public int PieceCount { get; internal set; }
        public int MaximumOriginalCharacters { get; internal set; }
        public int MaximumPieceCharacters { get; internal set; }
        public long WorkingByteCharge { get; internal set; }
    }

    public sealed class Proof
    {
        public bool Success { get; internal set; }
        public bool Retired { get; internal set; }
        public bool Completed { get; internal set; }
        public string ErrorCode { get; internal set; }
        public string ErrorStage { get; internal set; }
        public SanitizedCause ErrorCause { get; internal set; }
        public SanitizedFailure[] CleanupFailures {get;internal set;}
        public string PromptSha256 { get; internal set; }
        public bool PromptSeen { get; internal set; }
        public int Responses { get; internal set; }
        public int Models { get; internal set; }
        public int TextBlocks { get; internal set; }
        public int PieceCount { get; internal set; }
        public int MaximumOriginalCharacters { get; internal set; }
        public int MaximumPieceCharacters { get; internal set; }
        public long RequestBytes { get; internal set; }
        public long ResponseBytes { get; internal set; }
        public long ResponseWorkingByteCharge {get;internal set;}
        public long DrainedTailBytes {get;internal set;}
        public bool PendingCatalogAuthChallenge {get;internal set;}
        public bool PendingResponseAuthChallenge {get;internal set;}
        public int CatalogAuthChallenges {get;internal set;}
        public int ResponseAuthChallenges {get;internal set;}
    }

    public sealed class Bridge
    {
        public const string SourceIdentity = "__GAUNTLET_TRANSPORT_SOURCE_SHA256__";
        public const string CapabilityHeader = "X-Gauntlet-Capability";
        public const int HeaderByteLimit = 32768;
        public const int HeaderCountLimit = 64;
        public const int RequestByteLimit = 4194304;
        public const int ResponseByteLimit = 16777216;
        public const int CatalogByteLimit = 4194304;
        public const int RequestCountLimit = 8;
        public const int TextCharacterLimit = 200000;
        public const int JsonDepthLimit = 64;
        public const int JsonTokenLimit = 65536;
        public const long TransformWorkingByteLimit = 67108864;
        public const int SseLineByteLimit = ResponseByteLimit;
        public const int SseEventByteLimit = ResponseByteLimit;
        public const long ResponseWorkingByteLimit = 201326592;
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        static readonly HashSet<string> ForwardHeaders = new HashSet<string>(new [] {
            "authorization", "chatgpt-account-id", "accept", "user-agent", "originator", "version",
            "openai-beta", "session-id", "thread-id", "session_id", "x-client-request-id",
            "x-codex-beta-features", "x-codex-turn-metadata", "x-codex-window-id",
            "x-openai-internal-codex-responses-lite", "x-codex-turn-state", "x-oai-attestation",
            "x-codex-parent-thread-id", "x-openai-subagent"
        }, StringComparer.OrdinalIgnoreCase);
        static readonly HashSet<string> ResponseHeaders = new HashSet<string>(new [] {
            "etag", "x-models-etag", "openai-model", "x-reasoning-included", "x-request-id", "x-codex-turn-state",
            "x-codex-safety-buffering-enabled", "x-codex-safety-buffering-faster-model",
            "x-codex-primary-used-percent", "x-codex-primary-window-minutes", "x-codex-primary-reset-at",
            "x-codex-secondary-used-percent", "x-codex-secondary-window-minutes", "x-codex-secondary-reset-at",
            "x-codex-limit-name", "x-codex-credits-has-credits", "x-codex-credits-unlimited", "x-codex-credits-balance"
        }, StringComparer.OrdinalIgnoreCase);
        static readonly HashSet<string> NonMessageTypes = new HashSet<string>(new [] {
            "function_call", "function_call_output", "reasoning", "custom_tool_call", "custom_tool_call_output",
            "additional_tools", "agent_message", "local_shell_call", "web_search_call", "tool_search_call",
            "tool_search_output", "image_generation_call", "configuration_update", "mcp_tool_call_output"
        }, StringComparer.Ordinal);
        readonly object sync = new object();
        readonly long deadlineTimestamp;
        readonly string expectedPrompt;
        readonly string promptHash;
        readonly string capability;
        readonly TcpListener listener;
        readonly HttpClient http;
        readonly CancellationTokenSource cancel = new CancellationTokenSource();
        readonly CancellationTokenSource failureSignal = new CancellationTokenSource();
        readonly CancellationTokenRegistration registration;
        TcpClient active;
        string error = "";
        string errorStage="",stage="startup";
        SanitizedCause errorCause;
        readonly List<SanitizedFailure> cleanupFailures=new List<SanitizedFailure>();
        readonly List<object> unresolvedResources=new List<object>();
        bool networkCleanupFailed;
        bool retired, promptSeen, explicitClose, deadlineCancellation,finishing,terminalForwarded;
        bool pendingCatalogAuthChallenge,pendingResponseAuthChallenge;
        int catalogAuthChallenges,responseAuthChallenges;
        int responses, models, textBlocks, pieces, maxOriginal, maxPiece;
        long requestBytes, responseBytes,responseWorkingByteCharge,drainedTailBytes;
        public string Endpoint { get; private set; }
        public Task Completion { get; private set; }
        // The native owner only polls this token; the bridge cause is published first.
        public CancellationToken FailureToken { get; private set; }
        public long DeadlineTimestamp { get { return deadlineTimestamp; } }
        public int RemainingMilliseconds
        {
            get {
                if(Volatile.Read(ref deadlineCancellation)) return 0;
                decimal ticks=(decimal)deadlineTimestamp-Stopwatch.GetTimestamp();
                if(ticks<=0) return 0;
                return (int)Math.Min(int.MaxValue,Math.Ceiling(ticks*1000m/Stopwatch.Frequency));
            }
        }

        internal Bridge(string expectedPrompt, int timeoutMilliseconds)
            : this(expectedPrompt, DeadlineFromTimeout(timeoutMilliseconds), CreateHandler()) { }
        public Bridge(string expectedPrompt,long originalDeadlineTimestamp)
            : this(expectedPrompt,originalDeadlineTimestamp,CreateHandler()) { }

        // Test seam deliberately internal: no production wrapper option selects an endpoint or handler.
        internal Bridge(string expectedPrompt, int timeoutMilliseconds, HttpMessageHandler handler)
            : this(expectedPrompt,DeadlineForHandler(timeoutMilliseconds,handler),handler) { }
        internal Bridge(string expectedPrompt,long originalDeadlineTimestamp,HttpMessageHandler handler)
        {
            FailureToken=failureSignal.Token;
            try {
                deadlineTimestamp=originalDeadlineTimestamp;
                if (expectedPrompt == null || handler == null) throw new TransportException("startup_arguments","startup");
                if(RemainingMilliseconds==0) throw new TransportException("deadline","startup");
                ValidateUnicode(expectedPrompt);
                if(Utf8.GetByteCount(expectedPrompt)>RequestByteLimit) throw new TransportException("prompt_limit","startup");
                promptHash = HashString(expectedPrompt);
                this.expectedPrompt = expectedPrompt;
                capability = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
                http = new HttpClient(handler, true) { Timeout = Timeout.InfiniteTimeSpan };
                listener = new TcpListener(IPAddress.Loopback, 0);
                listener.Server.ExclusiveAddressUse = true;
                listener.Start(1);
                Endpoint = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/backend-api/codex";
                registration = cancel.Token.Register(OnCancellation);
                if(RemainingMilliseconds==0) throw new TransportException("deadline","startup");
                cancel.CancelAfter(RemainingMilliseconds);
                Completion = RunAsync();
            } catch(Exception failure) {
                // No partially constructed owner may leave a bound socket or timer behind.
                var cleanup=new List<SanitizedFailure>();
                try { if(listener!=null) listener.Stop(); } catch(Exception e) {AddCleanup(cleanup,"cleanup_listener",e);}
                try { registration.Dispose(); } catch(Exception e) {AddCleanup(cleanup,"cleanup_registration",e);}
                try { if(http!=null) http.Dispose(); else if(handler!=null) handler.Dispose(); } catch(Exception e) {AddCleanup(cleanup,"cleanup_http",e);}
                try {cancel.Dispose();}catch(Exception e) {AddCleanup(cleanup,"cleanup_cancellation",e);}
                try {failureSignal.Dispose();}catch(Exception e) {AddCleanup(cleanup,"cleanup_failure_signal",e);}
                var typed=failure as TransportException??new TransportException("startup_failure","startup",failure);
                typed.CleanupFailures=cleanup.ToArray();
                if(cleanup.Count>0) typed.RetainOwner(new ConstructionCustody(this,handler));
                throw typed;
            }
        }
        static long DeadlineFromTimeout(int milliseconds)
        {
            if(milliseconds<=0) throw new TransportException("startup_arguments","startup");
            try {return checked(Stopwatch.GetTimestamp()+Math.Max(1L,checked((long)((decimal)milliseconds*Stopwatch.Frequency/1000m))));}
            catch(Exception failure) {throw new TransportException("startup_deadline","startup",failure);}
        }
        static long DeadlineForHandler(int milliseconds,HttpMessageHandler handler)
        {
            try {return DeadlineFromTimeout(milliseconds);}catch(TransportException failure) {
                try {if(handler!=null) handler.Dispose();}catch(Exception e) {
                    failure.CleanupFailures=new [] {new SanitizedFailure {Code="cleanup",Stage="cleanup_http",Cause=SanitizedCause.From(e)}};
                    failure.RetainOwner(new ConstructionCustody(null,handler));
                }
                throw;
            }
        }
        static void AddCleanup(List<SanitizedFailure> failures,string atStage,Exception cause) {if(failures.Count<2) failures.Add(new SanitizedFailure {Code="cleanup",Stage=atStage,Cause=SanitizedCause.From(cause)});}

        static HttpMessageHandler CreateHandler()
        {
            try {return new SocketsHttpHandler { AllowAutoRedirect=false, UseCookies=false, UseProxy=false,
                AutomaticDecompression=DecompressionMethods.None, MaxResponseHeadersLength=32,
                MaxResponseDrainSize=0,ResponseDrainTimeout=TimeSpan.Zero };}
            catch(Exception failure) {throw new TransportException("startup_handler","startup",failure);}
        }
        public string GetCapability() { return capability; }
        public void Close()
        {
            try {
                lock(sync) { if(!cancel.IsCancellationRequested) explicitClose=true; }
                cancel.Cancel();
            } catch (ObjectDisposedException) { }
        }
        // Called only by the attempt worker after successful native consumer/tree retirement.
        // Terminal bytes must already have been written; this permits validation of EOF/heartbeats,
        // and never turns an early consumer exit into proof of an undelivered model response.
        public void FinishClient()
        {
            bool early;
            lock(sync) {
                if(finishing) return;
                Volatile.Write(ref finishing,true);
                early=active!=null&&!terminalForwarded;
            }
            if(early) {Fail("client_finish_early","client_finish");Close();return;}
            StopListener();
        }
        void OnCancellation()
        {
            bool deadline;
            lock(sync) {deadline=!explicitClose;if(deadline) Volatile.Write(ref deadlineCancellation,true);}
            if(deadline) Fail("deadline","deadline");else PublishFailureSignal();
            StopNetwork();
        }
        void StopNetwork()
        {
            StopListener();
            TcpClient client;lock(sync) {client=active;active=null;}
            if(!DisposeOwned(client,"cleanup_client")) networkCleanupFailed=true;
        }
        bool IsUnresolved(object resource) {lock(sync) {return unresolvedResources.Any(held=>object.ReferenceEquals(held,resource));}}
        void Hold(object resource) {if(resource!=null) lock(sync) {if(!unresolvedResources.Any(held=>object.ReferenceEquals(held,resource))) unresolvedResources.Add(resource);}}
        bool DisposeOwned(IDisposable resource,string atStage)
        {
            if(resource==null) return true;
            if(IsUnresolved(resource)) return false;
            try {resource.Dispose();return true;}
            catch(Exception e) {Hold(resource);Fail("cleanup",atStage,e);return false;}
        }
        void StopListener()
        {
            if(IsUnresolved(listener)) return;
            try {listener.Stop();}catch(Exception e) {Hold(listener);networkCleanupFailed=true;Fail("cleanup","cleanup_listener",e);}
        }
        void Fail(string code,string atStage=null,Exception cause=null) {Fail(new TransportException(code,atStage??stage,cause));}
        void PublishFailureSignal() {try {failureSignal.Cancel();}catch(ObjectDisposedException) { }}
        void Fail(TransportException failure) {
            lock(sync) {
                if(failure.Code=="cleanup") AddCleanup(cleanupFailures,failure.Stage,failure.Cause);
                if(error.Length==0) {error=failure.Code;errorStage=failure.Stage;errorCause=failure.Cause;}
            }
            PublishFailureSignal();
        }
        static void AddCleanup(List<SanitizedFailure> failures,string atStage,SanitizedCause cause) {if(failures.Count<2) failures.Add(new SanitizedFailure {Code="cleanup",Stage=atStage,Cause=cause});}
        public Proof GetProof()
        {
            lock(sync) {
                bool settled=retired && Completion!=null && Completion.IsCompleted;
                return new Proof { Success=settled && error.Length==0 && promptSeen && responses>0&&!pendingCatalogAuthChallenge&&!pendingResponseAuthChallenge,
                    Retired=settled, Completed=settled, ErrorCode=error, ErrorStage=errorStage,ErrorCause=errorCause,CleanupFailures=cleanupFailures.ToArray(),PromptSha256=promptHash, PromptSeen=promptSeen,
                    Responses=responses, Models=models, TextBlocks=textBlocks, PieceCount=pieces,
                    MaximumOriginalCharacters=maxOriginal, MaximumPieceCharacters=maxPiece,
                    RequestBytes=requestBytes, ResponseBytes=responseBytes,ResponseWorkingByteCharge=responseWorkingByteCharge,DrainedTailBytes=drainedTailBytes,
                    PendingCatalogAuthChallenge=pendingCatalogAuthChallenge,PendingResponseAuthChallenge=pendingResponseAuthChallenge,
                    CatalogAuthChallenges=catalogAuthChallenges,ResponseAuthChallenges=responseAuthChallenges };
            }
        }

        async Task RunAsync()
        {
            bool activeTransaction=false;
            try {
                for(int i=0;i<=RequestCountLimit && !cancel.IsCancellationRequested&&!Volatile.Read(ref finishing);i++) {
                    if(i==RequestCountLimit) {
                        // Preserve the existing first cause when the final admitted slot was
                        // an unrecovered challenge: no further recovery request is admitted.
                        bool unresolved;lock(sync) unresolved=pendingCatalogAuthChallenge||pendingResponseAuthChallenge;
                        if(unresolved) throw new TransportException("auth_challenge_unresolved","auth_challenge",new HttpRequestException("",null,HttpStatusCode.Unauthorized));
                    }
                    stage="accept";
                    TcpClient client = await listener.AcceptTcpClientAsync(cancel.Token).ConfigureAwait(false);
                    activeTransaction=true;
                    lock(sync) {active=client;terminalForwarded=false;}
                    // One overflow sentinel accepts no HTTP bytes. Exactly eight completed
                    // exchanges may still finish normally; an actual ninth connection must
                    // latch the shared native-job failure before parsing or upstream work.
                    if(i==RequestCountLimit) {Fail("request_limit","request_count");break;}
                    if(Volatile.Read(ref finishing)) throw new TransportException("client_finish_early","client_finish");
                    NetworkStream stream=null;
                    try {
                        if (!((IPEndPoint)client.Client.RemoteEndPoint).Address.Equals(IPAddress.Loopback)) throw new Rejection("peer");
                        stream=client.GetStream();
                            try { await HandleAsync(stream).ConfigureAwait(false); }
                            catch(Rejection e) { Fail(e); if(e.CanReply) await SafeError(stream,e.Upstream ? 502 : 400).ConfigureAwait(false); }
                            catch(TransportException e) { Fail(e); await SafeError(stream,400).ConfigureAwait(false); }
                    } catch(Exception e) {
                        var typed=e as TransportException;
                        if(typed!=null) Fail(typed);
                        else if(RemainingMilliseconds==0) Fail("deadline",stage,e);
                        else if(cancel.IsCancellationRequested||e is OperationCanceledException) Fail("cancelled_active",stage,e);
                        else Fail("transport_io",stage,e);
                        throw;
                    } finally {
                        if(DisposeOwned(stream,"cleanup_client_stream")) DisposeOwned(client,"cleanup_client");else Hold(client);
                        lock(sync) active=null;
                    }
                    activeTransaction=false;
                    // A rejected request fences the entire attempt, including later valid traffic.
                    lock(sync) { if (error.Length != 0) break; }
                }
            }
            catch(TransportException e) {Fail(e);}
            catch(OperationCanceledException e) {
                if(RemainingMilliseconds==0) Fail("deadline",stage,e);
                else if(activeTransaction) Fail("cancelled_active",stage,e);
            }
            catch(Exception e) {
                if(Volatile.Read(ref finishing)&&!activeTransaction&&(e is SocketException||e is ObjectDisposedException)) { }
                else if(RemainingMilliseconds==0) Fail("deadline",stage,e);
                else if(cancel.IsCancellationRequested) { if(activeTransaction) Fail("cancelled_active",stage,e); }
                else Fail("transport_io",stage,e);
            }
            finally {
                if(RemainingMilliseconds==0) Fail("deadline");
                else if(cancel.IsCancellationRequested&&activeTransaction) Fail("cancelled_active");
                StopNetwork();
                // This finally is reached only after the awaited native/handler work physically retires.
                bool disposed=!networkCleanupFailed;
                try { http.Dispose(); } catch(Exception e) { Fail("cleanup","cleanup_http",e); disposed=false; }
                try { registration.Dispose(); } catch(Exception e) { Fail("cleanup","cleanup_registration",e); disposed=false; }
                try { cancel.Dispose(); } catch(Exception e) { Fail("cleanup","cleanup_cancellation",e); disposed=false; }
                bool unresolvedAuth;lock(sync) unresolvedAuth=pendingCatalogAuthChallenge||pendingResponseAuthChallenge;
                if(unresolvedAuth) Fail("auth_challenge_unresolved","auth_challenge",new HttpRequestException("",null,HttpStatusCode.Unauthorized));
                try { failureSignal.Dispose(); } catch(Exception e) { Fail("cleanup","cleanup_failure_signal",e); disposed=false; }
                lock(sync) retired=disposed&&!networkCleanupFailed&&unresolvedResources.Count==0;
            }
        }

        sealed class Rejection : TransportException
        {
            internal bool Upstream; internal bool CanReply=true;
            internal Rejection(string code,bool upstream=false,Exception cause=null) : base(code,upstream?"upstream":"request",cause) {Upstream=upstream;}
            internal Rejection(TransportException failure) : base(failure) {Upstream=true;CanReply=false;}
        }
        sealed class Request
        {
            internal string Method, Target;
            internal Dictionary<string,string> Headers;
            internal byte[] Body;
        }
        static bool Token(string value)
        {
            if(value.Length==0) return false;
            foreach(char c in value) if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||"!#$%&'*+-.^_`|~".IndexOf(c)>=0)) return false;
            return true;
        }
        static bool SafeValue(string value)
        {
            foreach(char c in value) if(c<0x20 || c>0x7e) return false;
            return true;
        }
        static bool AsciiLetterOrDigit(char c)
        {
            return (c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9');
        }
        async Task<Request> ReadRequest(NetworkStream stream)
        {
            byte[] header=new byte[HeaderByteLimit+1]; int count=0,end=-1;
            while(end<0) {
                int read=await stream.ReadAsync(header.AsMemory(count,Math.Min(4096,header.Length-count)),cancel.Token).ConfigureAwait(false);
                if(read==0) throw new Rejection("request_incomplete");
                int start=Math.Max(0,count-3); count+=read;
                for(int i=start;i+3<count;i++) if(header[i]==13&&header[i+1]==10&&header[i+2]==13&&header[i+3]==10) { end=i+4; break; }
                if(end<0 && count>=HeaderByteLimit) throw new Rejection("header_limit");
                if(end>HeaderByteLimit) throw new Rejection("header_limit");
            }
            for(int i=0;i<end;i++) if(header[i]>127 || (header[i]<32 && header[i]!=13 && header[i]!=10)) throw new Rejection("header_syntax");
            string[] lines=Encoding.ASCII.GetString(header,0,end-4).Split(new [] {"\r\n"},StringSplitOptions.None);
            string[] first=lines[0].Split(' ');
            if(first.Length!=3 || first[2]!="HTTP/1.1" || (first[0]!="POST" && first[0]!="GET")) throw new Rejection("request_line");
            if(lines.Length-1>HeaderCountLimit) throw new Rejection("header_limit");
            var headers=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            for(int i=1;i<lines.Length;i++) {
                int colon=lines[i].IndexOf(':');
                if(colon<=0) throw new Rejection("header_syntax");
                string name=lines[i].Substring(0,colon), value=lines[i].Substring(colon+1).Trim(' ');
                if(!Token(name)||!SafeValue(value)||headers.ContainsKey(name)) throw new Rejection("header_syntax");
                headers.Add(name,value);
            }
            string supplied;
            if(!headers.TryGetValue("Host",out supplied)||supplied!=new Uri(Endpoint).Authority) throw new Rejection("host");
            if(!headers.TryGetValue(CapabilityHeader,out supplied)||supplied.Length!=capability.Length||!CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(supplied),Encoding.ASCII.GetBytes(capability))) throw new Rejection("capability");
            foreach(var item in headers) {
                if(item.Key.Equals("connection",StringComparison.OrdinalIgnoreCase)) {
                    if(!item.Value.Equals("close",StringComparison.OrdinalIgnoreCase) && !item.Value.Equals("keep-alive",StringComparison.OrdinalIgnoreCase)) throw new Rejection("framing");
                } else if(!ForwardHeaders.Contains(item.Key) && !item.Key.Equals("host",StringComparison.OrdinalIgnoreCase) && !item.Key.Equals(CapabilityHeader,StringComparison.OrdinalIgnoreCase) && !item.Key.Equals("content-type",StringComparison.OrdinalIgnoreCase) && !item.Key.Equals("content-length",StringComparison.OrdinalIgnoreCase)) throw new Rejection("header_policy",cause:new HeaderPolicyException(item.Key));
            }
            if(!headers.TryGetValue("Authorization",out supplied)||!supplied.StartsWith("Bearer ",StringComparison.Ordinal)||supplied.Length<=7||supplied.Substring(7).StartsWith("sk-",StringComparison.OrdinalIgnoreCase)||supplied.Substring(7).Any(c=>c==' ')) throw new Rejection("auth_shape");
            if(!headers.TryGetValue("ChatGPT-Account-Id",out supplied)||supplied.Length==0||supplied.Length>256||supplied.Any(c=>!(AsciiLetterOrDigit(c)||c=='-'||c=='_'))) throw new Rejection("auth_shape");
            bool post=first[0]=="POST";
            ValidateTarget(first[1],post);
            int length=0;
            if(post) {
                if(!headers.TryGetValue("Content-Type",out supplied)||!(supplied.Equals("application/json",StringComparison.OrdinalIgnoreCase)||supplied.Equals("application/json; charset=utf-8",StringComparison.OrdinalIgnoreCase))) throw new Rejection("content_type");
                if(!headers.TryGetValue("Content-Length",out supplied)||supplied.Length==0||supplied.Any(c=>c<'0'||c>'9')||!int.TryParse(supplied,out length)||length<=0||length>RequestByteLimit) throw new Rejection("request_limit");
            } else if(headers.ContainsKey("Content-Type") || (headers.TryGetValue("Content-Length",out supplied)&&supplied!="0")) throw new Rejection("framing");
            int prefetched=count-end;
            if(prefetched>length) throw new Rejection("framing");
            byte[] body=new byte[length]; Buffer.BlockCopy(header,end,body,0,prefetched);
            for(int offset=prefetched;offset<length;) {
                int read=await stream.ReadAsync(body.AsMemory(offset,length-offset),cancel.Token).ConfigureAwait(false);
                if(read==0) throw new Rejection("request_incomplete");
                offset+=read;
            }
            lock(sync) requestBytes+=end+length;
            return new Request {Method=first[0],Target=first[1],Headers=headers,Body=body};
        }
        static void ValidateTarget(string target,bool post)
        {
            if(post) { if(target!="/backend-api/codex/responses") throw new Rejection("route"); return; }
            const string path="/backend-api/codex/models";
            if(target==path) return;
            const string prefix=path+"?client_version=";
            if(!target.StartsWith(prefix,StringComparison.Ordinal)) throw new Rejection("route");
            string version=target.Substring(prefix.Length);
            if(version.Length==0||version.Length>128||version.Any(c=>!(AsciiLetterOrDigit(c)||c=='.'||c=='-'||c=='_'))) throw new Rejection("query");
        }

        sealed class SseValidator : IDisposable
        {
            readonly byte[] line=new byte[SseLineByteLimit];int lineLength;
            readonly BoundedBuffer data=new BoundedBuffer(SseEventByteLimit,"sse_event_limit","sse_validate");
            readonly int promptCharacters;
            internal long WorkingByteCharge {get;private set;}
            internal bool TerminalSeen {get{return completed;}}
            string eventName,responseId;bool completed,done;
            internal SseValidator(int promptCharacters) {this.promptCharacters=promptCharacters;WorkingByteCharge=ResponseCharge(0,0,promptCharacters);}
            void Reject(string code) {throw new TransportException(code,"sse_validate");}
            internal void Feed(byte[] bytes,int count) {
                for(int i=0;i<count;i++) {
                    byte b=bytes[i];
                    if(b==10) {int n=lineLength;if(n>0&&line[n-1]==13) n--;ProcessLine(n);lineLength=0;}
                    else {if(lineLength==line.Length) Reject("sse_line_limit");line[lineLength++]=b;}
                }
            }
            void ProcessLine(int length) {
                try {Utf8.GetCharCount(line.AsSpan(0,length));}catch(Exception cause) {throw new TransportException("sse_utf8","sse_validate",cause);}
                if(length==0) {Dispatch();return;}
                if(line[0]==':') return;
                int colon=Array.IndexOf(line,(byte)':',0,length);int fieldLength=colon<0 ? length : colon;
                int start=colon<0 ? length : colon+1;if(start<length&&line[start]==32) start++;
                string field=Encoding.ASCII.GetString(line,0,fieldLength);
                if(field=="event") {
                    if(length-start>128) Reject("sse_event_shape");
                    eventName=Utf8.GetString(line,start,length-start);
                } else if(field=="data") {
                    if(data.Length>0) data.WriteByte(10);
                    data.Write(line,start,length-start);
                }
            }
            void CheckId(JsonElement element) {
                if(element.ValueKind!=JsonValueKind.String) Reject("sse_response_id");
                string id=element.GetString();if(id.Length==0||id.Length>256||!SafeValue(id)) Reject("sse_response_id");
                if(responseId!=null&&responseId!=id) Reject("sse_response_id");responseId=id;
            }
            void Dispatch() {
                if(data.Length==0) {eventName=null;return;}
                if(data.Written.Span.SequenceEqual(Encoding.ASCII.GetBytes("[DONE]"))) {
                    if(!completed||done) Reject("sse_terminal");done=true;data.Reset();eventName=null;return;
                }
                if(completed||done) Reject("sse_after_terminal");
                try {
                    int tokens=PreflightJson(data.Written.Span);
                    WorkingByteCharge=Math.Max(WorkingByteCharge,ResponseCharge(data.Written.Length,tokens,promptCharacters));
                    using(var doc=JsonDocument.Parse(data.Written,new JsonDocumentOptions {MaxDepth=JsonDepthLimit})) {
                        ValidateJson(doc.RootElement);JsonElement type=default(JsonElement),response=default(JsonElement),id=default(JsonElement),status=default(JsonElement);
                        if(doc.RootElement.ValueKind!=JsonValueKind.Object||!doc.RootElement.TryGetProperty("type",out type)||type.ValueKind!=JsonValueKind.String) Reject("sse_event_shape");
                        string kind=type.GetString();
                        if(kind=="error"||kind=="response.error"||kind=="response.failed"||kind=="response.incomplete") Reject("sse_failed");
                        if(kind.Length>128) Reject("sse_event_shape");
                        if(doc.RootElement.TryGetProperty("response_id",out id)) CheckId(id);
                        if(doc.RootElement.TryGetProperty("response",out response)&&response.ValueKind==JsonValueKind.Object&&response.TryGetProperty("id",out id)) CheckId(id);
                        if(kind=="response.completed") {
                            if(!doc.RootElement.TryGetProperty("response",out response)||response.ValueKind!=JsonValueKind.Object||!response.TryGetProperty("id",out id)) Reject("sse_terminal");
                            CheckId(id);
                            if(response.TryGetProperty("status",out status)&&(status.ValueKind!=JsonValueKind.String||status.GetString()!="completed")) Reject("sse_terminal");
                            completed=true;
                        }
                    }
                }catch(TransportException) {throw;}
                catch(Exception cause) {throw new TransportException("sse_json","sse_validate",cause);}
                data.Reset();eventName=null;
            }
            internal void Finish() {if(lineLength!=0||data.Length!=0||eventName!=null) Reject("sse_unterminated");if(!completed) Reject("sse_incomplete");}
            public void Dispose() {data.Dispose();}
        }

        static long ResponseCharge(int eventBytes,int tokens,int promptCharacters)
        {
            // Independent response-phase admission, not a managed/native heap guarantee. Includes
            // fixed line/event storage, raw/decode/parser temporaries, held request/prompt and scratch.
            long charge=checked(SseLineByteLimit+(long)SseEventByteLimit+eventBytes*5L+tokens*128L+RequestByteLimit*4L+promptCharacters*2L+131072L);
            if(charge>ResponseWorkingByteLimit) throw new TransportException("response_working_limit","response_validate");return charge;
        }
        static long ValidateCatalog(ReadOnlyMemory<byte> bytes,int promptCharacters)
        {
            try {
                int tokens=PreflightJson(bytes.Span);long charge=ResponseCharge(bytes.Length,tokens,promptCharacters);
                using(var doc=JsonDocument.Parse(bytes,new JsonDocumentOptions {MaxDepth=JsonDepthLimit})) {
                    ValidateJson(doc.RootElement);JsonElement models;
                    if(doc.RootElement.ValueKind!=JsonValueKind.Object||!doc.RootElement.TryGetProperty("models",out models)||models.ValueKind!=JsonValueKind.Array) throw new TransportException("catalog_shape","catalog_validate");
                    foreach(var model in models.EnumerateArray()) if(model.ValueKind!=JsonValueKind.Object) throw new TransportException("catalog_shape","catalog_validate");
                }
                return charge;
            }catch(TransportException) {throw;}
            catch(Exception cause) {throw new TransportException("catalog_json","catalog_validate",cause);}
        }

        async Task HandleAsync(NetworkStream stream)
        {
            stage="request_read";
            cancel.Token.ThrowIfCancellationRequested();
            Request request=await ReadRequest(stream).ConfigureAwait(false);
            bool post=request.Method=="POST";
            byte[] body=request.Body;
            if(post) {
                stage="transform";
                TransformResult result=Transform(body,expectedPrompt); body=result.Bytes;
                if(!result.SupportedInferenceProfile) throw new Rejection("inference_profile");
                cancel.Token.ThrowIfCancellationRequested();
                lock(sync) {
                    promptSeen|=result.PromptSeen; textBlocks+=result.TextBlocks; pieces+=result.PieceCount;
                    maxOriginal=Math.Max(maxOriginal,result.MaximumOriginalCharacters); maxPiece=Math.Max(maxPiece,result.MaximumPieceCharacters);
                }
            }
            string fixedPath=post ? "/responses" : "/models";
            string query=post || request.Target.IndexOf('?')<0 ? "" : request.Target.Substring(request.Target.IndexOf('?'));
            HttpRequestMessage upstream=null;HttpResponseMessage response=null;Stream input=null;
            try {
                upstream=new HttpRequestMessage(post ? HttpMethod.Post : HttpMethod.Get,"https://chatgpt.com/backend-api/codex"+fixedPath+query);
                upstream.Version=HttpVersion.Version11;
                upstream.VersionPolicy=HttpVersionPolicy.RequestVersionExact;
                if(post) { upstream.Content=new ByteArrayContent(body); upstream.Content.Headers.ContentType=new System.Net.Http.Headers.MediaTypeHeaderValue("application/json"); }
                foreach(var header in request.Headers) if(ForwardHeaders.Contains(header.Key)) {
                    if(!upstream.Headers.TryAddWithoutValidation(header.Key,header.Value)) throw new Rejection("header_policy",cause:new HeaderPolicyException(header.Key));
                }
                stage="upstream_send";
                try { response=await http.SendAsync(upstream,HttpCompletionOption.ResponseHeadersRead,cancel.Token).ConfigureAwait(false); }
                catch(OperationCanceledException) { throw; }
                catch(Exception failure) { throw new Rejection("upstream_io",true,failure); }
                {
                    stage="response_headers";
                    string responseFields=ReviewedResponseHeaders(response,response.StatusCode!=HttpStatusCode.Unauthorized);
                    if(response.StatusCode==HttpStatusCode.Unauthorized) {
                        lock(sync) {
                            if(post) {pendingResponseAuthChallenge=true;responseAuthChallenges++;}
                            else {pendingCatalogAuthChallenge=true;catalogAuthChallenges++;}
                        }
                        await SendAuthChallenge(stream).ConfigureAwait(false);
                        return;
                    }
                    if(response.StatusCode!=HttpStatusCode.OK) throw new Rejection("upstream_status",true,new HttpRequestException("",null,response.StatusCode));
                    if(response.Content.Headers.ContentEncoding.Count>0) throw new Rejection("upstream_encoding",true);
                    int limit=post ? ResponseByteLimit : CatalogByteLimit;
                    if(response.Content.Headers.ContentLength.HasValue&&response.Content.Headers.ContentLength.Value>limit) throw new Rejection("response_limit",true);
                    // Pinned clients consume route-specific bytes; upstream MIME is advisory.
                    // Emit one canonical local type while the bounded body validators prove the protocol.
                    string media=post ? "text/event-stream" : "application/json";
                    byte[] responseHeader=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: "+media+"\r\nConnection: close\r\nCache-Control: no-store\r\n"+responseFields+"\r\n");
                    await stream.WriteAsync(responseHeader,cancel.Token).ConfigureAwait(false);
                    stage=post ? "response_stream" : "catalog_stream";
                    try {
                        using(var events=post ? new SseValidator(expectedPrompt.Length) : null)
                        using(var catalog=post ? null : new BoundedBuffer(CatalogByteLimit,"catalog_limit","catalog_validate"))
                        {
                            input=await response.Content.ReadAsStreamAsync(cancel.Token).ConfigureAwait(false);
                            byte[] buffer=new byte[16384]; int total=0;
                            while(true) {
                                int n=await input.ReadAsync(buffer.AsMemory(),cancel.Token).ConfigureAwait(false);
                                if(n==0) break;
                                if(n>limit-total) throw new Rejection("response_limit",true);
                                total+=n;
                                if(post) {events.Feed(buffer,n);lock(sync) responseWorkingByteCharge=Math.Max(responseWorkingByteCharge,events.WorkingByteCharge);}else catalog.Write(buffer,0,n);
                                bool drainOnly;lock(sync) drainOnly=finishing&&terminalForwarded;
                                if(drainOnly) {lock(sync) drainedTailBytes+=n;}
                                else {
                                    await stream.WriteAsync(buffer.AsMemory(0,n),cancel.Token).ConfigureAwait(false);
                                    if(post&&events.TerminalSeen) lock(sync) terminalForwarded=true;
                                    await stream.FlushAsync(cancel.Token).ConfigureAwait(false);
                                }
                                lock(sync) responseBytes+=n;
                            }
                            if(response.Content.Headers.ContentLength.HasValue&&response.Content.Headers.ContentLength.Value!=total) throw new Rejection("response_length",true);
                            if(post) events.Finish();else {long charge=ValidateCatalog(catalog.Written,expectedPrompt.Length);lock(sync) responseWorkingByteCharge=Math.Max(responseWorkingByteCharge,charge);}
                        }
                    } catch(Rejection e) {e.CanReply=false;throw;}
                    catch(TransportException e) {throw new Rejection(e);}
                    cancel.Token.ThrowIfCancellationRequested();
                    lock(sync) {
                        if(post) {responses++;pendingCatalogAuthChallenge=false;pendingResponseAuthChallenge=false;}
                        else {models++;pendingCatalogAuthChallenge=false;}
                    }
                }
            } catch(TransportException e) {Fail(e);throw;}
            catch(OperationCanceledException e) {Fail(RemainingMilliseconds==0 ? "deadline" : "cancelled_active",stage,e);throw;}
            catch(Exception e) {Fail("transport_io",stage,e);throw;}
            finally {
                if(DisposeOwned(input,"cleanup_response_stream")) DisposeOwned(response,"cleanup_response");else Hold(response);
                DisposeOwned(upstream,"cleanup_request");
            }
        }
        static string ReviewedResponseHeaders(HttpResponseMessage response,bool forward)
        {
            var fields=new StringBuilder();long bytes=0;int count=0;
            foreach(var field in response.Headers.NonValidated.Concat(response.Content.Headers.NonValidated)) foreach(string value in field.Value) {
                count++;bytes+=field.Key.Length+(long)value.Length+4;
                if(count>HeaderCountLimit||bytes>HeaderByteLimit||!Token(field.Key)||!SafeValue(value)) throw new Rejection("upstream_headers",true);
                if(forward&&ResponseHeaders.Contains(field.Key)) fields.Append(field.Key).Append(": ").Append(value).Append("\r\n");
            }
            return fields.ToString();
        }
        async Task SendAuthChallenge(NetworkStream stream)
        {
            stage="auth_challenge_delivery";
            byte[] body=Encoding.ASCII.GetBytes("{\"error\":{\"code\":\"unauthorized\",\"message\":\"Authentication required.\"}}\n");
            byte[] header=Encoding.ASCII.GetBytes("HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: "+body.Length+"\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n");
            await stream.WriteAsync(header,cancel.Token).ConfigureAwait(false);
            await stream.WriteAsync(body,cancel.Token).ConfigureAwait(false);
            await stream.FlushAsync(cancel.Token).ConfigureAwait(false);
        }
        async Task SafeError(NetworkStream stream,int status)
        {
            try {
                byte[] body=Encoding.ASCII.GetBytes("Transport request rejected.\n");
                byte[] header=Encoding.ASCII.GetBytes("HTTP/1.1 "+status+" Rejected\r\nContent-Type: text/plain\r\nContent-Length: "+body.Length+"\r\nConnection: close\r\n\r\n");
                await stream.WriteAsync(header,cancel.Token).ConfigureAwait(false);
                await stream.WriteAsync(body,cancel.Token).ConfigureAwait(false);
            } catch { }
        }

        static void ValidateUnicode(string value)
        {
            for(int i=0;i<value.Length;i++) {
                char c=value[i];
                if(char.IsHighSurrogate(c)) { if(++i>=value.Length||!char.IsLowSurrogate(value[i])) throw new TransportException("json_unicode","json_validate"); }
                else if(char.IsLowSurrogate(c)) throw new TransportException("json_unicode","json_validate");
            }
        }
        static void AppendHash(IncrementalHash hash,string value,int offset,int length,byte[] scratch)
        {
            int end=offset+length;
            while(offset<end) {
                int n=Math.Min(4096,end-offset);if(offset+n<end&&char.IsHighSurrogate(value[offset+n-1])) n--;
                int bytes=Utf8.GetBytes(value.AsSpan(offset,n),scratch.AsSpan());hash.AppendData(scratch,0,bytes);offset+=n;
            }
        }
        static string HashString(string value) {
            using(var hash=IncrementalHash.CreateHash(HashAlgorithmName.SHA256)) {AppendHash(hash,value,0,value.Length,new byte[16384]);return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();}
        }
        static int PreflightJson(ReadOnlySpan<byte> bytes)
        {
            Utf8.GetCharCount(bytes);
            var reader=new Utf8JsonReader(bytes,new JsonReaderOptions {MaxDepth=JsonDepthLimit,AllowTrailingCommas=false,CommentHandling=JsonCommentHandling.Disallow});
            int tokens=0;while(reader.Read()) if(++tokens>JsonTokenLimit) throw new TransportException("json_token_limit","json_preflight");return tokens;
        }
        static void ValidateJson(JsonElement element)
        {
            if(element.ValueKind==JsonValueKind.Object) {
                var names=new HashSet<string>(StringComparer.Ordinal);
                foreach(var property in element.EnumerateObject()) { ValidateUnicode(property.Name); if(!names.Add(property.Name)) throw new TransportException("json_duplicate","json_validate"); ValidateJson(property.Value); }
            } else if(element.ValueKind==JsonValueKind.Array) foreach(var child in element.EnumerateArray()) ValidateJson(child);
            else if(element.ValueKind==JsonValueKind.String) ValidateUnicode(element.GetString());
        }
        public static TransformResult Transform(byte[] requestBody,string expectedPrompt)
        {
            string atStage="transform_preflight";
            try {
                if(requestBody==null||requestBody.Length==0||requestBody.Length>RequestByteLimit||expectedPrompt==null) throw new TransportException("request_limit",atStage);
                ValidateUnicode(expectedPrompt);
                if(Utf8.GetByteCount(expectedPrompt)>RequestByteLimit) throw new TransportException("prompt_limit",atStage);
                int tokens=PreflightJson(requestBody);
                // Admission accounting is a conservative working-data policy, not a CLR/native heap cap.
                // Seven raw-body charges cover retained bytes and decoded/raw-token temporaries; token
                // allowance covers DOM/duplicate-key structure. Output+copy and scratch are explicit.
                long charge=checked(requestBody.LongLength*7+expectedPrompt.Length*2L+tokens*128L+RequestByteLimit*2L+65536L);
                if(charge>TransformWorkingByteLimit) throw new TransportException("transform_working_limit",atStage);
                atStage="transform_json";
                using(JsonDocument doc=JsonDocument.Parse(requestBody,new JsonDocumentOptions {MaxDepth=JsonDepthLimit,AllowTrailingCommas=false,CommentHandling=JsonCommentHandling.Disallow})) {
                    atStage="transform_validate";
                    ValidateJson(doc.RootElement);
                    JsonElement input;
                    if(doc.RootElement.ValueKind!=JsonValueKind.Object||!doc.RootElement.TryGetProperty("input",out input)||input.ValueKind!=JsonValueKind.Array) throw new TransportException();
                    JsonElement model,stream;
                    var result=new TransformResult {PromptSha256=HashString(expectedPrompt),WorkingByteCharge=charge,
                        SupportedInferenceProfile=doc.RootElement.TryGetProperty("model",out model)&&model.ValueKind==JsonValueKind.String&&model.GetString()=="gpt-6.1-sol"&&
                            doc.RootElement.TryGetProperty("stream",out stream)&&stream.ValueKind==JsonValueKind.True};
                    atStage="transform_write";
                    using(var output=new BoundedBuffer(RequestByteLimit,"transform_output_limit",atStage)) {
                        var writer=new JsonSink(output);
                            writer.WriteStartObject();
                            foreach(var property in doc.RootElement.EnumerateObject()) {
                                writer.WritePropertyName(property.Name);
                                if(property.Name!="input") { writer.Element(property.Value); continue; }
                                writer.WriteStartArray();
                                foreach(var message in input.EnumerateArray()) WriteMessage(writer,message,expectedPrompt,result);
                                writer.WriteEndArray();
                            }
                            writer.WriteEndObject();
                        if(!result.PromptSeen) throw new TransportException("prompt_missing","transform_validate");
                        result.Bytes=output.ToArray(); return result;
                    }
                }
            } catch(TransportException) {throw;}
            catch(JsonException failure) {throw new TransportException("json_parse",atStage,failure);}
            catch(DecoderFallbackException failure) {throw new TransportException("json_utf8",atStage,failure);}
            catch(Exception failure) {throw new TransportException("transform_failure",atStage,failure);}
        }
        static void WriteMessage(JsonSink writer,JsonElement message,string prompt,TransformResult result)
        {
            JsonElement role,content,itemType;
            if(message.ValueKind==JsonValueKind.Object&&message.TryGetProperty("type",out itemType)&&itemType.ValueKind==JsonValueKind.String&&NonMessageTypes.Contains(itemType.GetString())) {
                string kind=itemType.GetString();
                if((message.TryGetProperty("role",out role)&&kind!="additional_tools") ||
                   (message.TryGetProperty("content",out content)&&kind!="reasoning"&&kind!="agent_message")) throw new TransportException();
                writer.Element(message); return;
            }
            if(message.ValueKind!=JsonValueKind.Object||!message.TryGetProperty("role",out role)||role.ValueKind!=JsonValueKind.String||!message.TryGetProperty("content",out content)||content.ValueKind!=JsonValueKind.Array) throw new TransportException();
            if(message.TryGetProperty("type",out itemType)&&(itemType.ValueKind!=JsonValueKind.String||itemType.GetString()!="message")) throw new TransportException();
            string r=role.GetString();
            if(r!="user"&&r!="developer"&&r!="system"&&r!="assistant") throw new TransportException();
            writer.WriteStartObject();
            foreach(var field in message.EnumerateObject()) {
                writer.WritePropertyName(field.Name);
                if(field.Name!="content") {writer.Element(field.Value);continue;}
                writer.WriteStartArray();
                foreach(var block in content.EnumerateArray()) {
                    JsonElement type,text;
                    if(block.ValueKind!=JsonValueKind.Object||!block.TryGetProperty("type",out type)||type.ValueKind!=JsonValueKind.String) throw new TransportException();
                    if(type.GetString()!="input_text") {writer.Element(block);continue;}
                    if(!block.TryGetProperty("text",out text)||text.ValueKind!=JsonValueKind.String) throw new TransportException();
                    string value=text.GetString(); result.TextBlocks++;
                    result.MaximumOriginalCharacters=Math.Max(result.MaximumOriginalCharacters,value.Length);
                    if(r=="user"&&value.IndexOf(prompt,StringComparison.Ordinal)>=0) result.PromptSeen=true;
                    using(var reconstructed=IncrementalHash.CreateHash(HashAlgorithmName.SHA256)) {
                    byte[] scratch=new byte[16384];int offset=0,reconstructedOffset=0;
                    do {
                        int length=Math.Min(TextCharacterLimit,value.Length-offset);
                        if(length>0&&offset+length<value.Length&&char.IsHighSurrogate(value[offset+length-1])) length--;
                        if(!value.AsSpan(offset,length).SequenceEqual(value.AsSpan(reconstructedOffset,length))) throw new TransportException("text_reconstruction","transform_write");
                        AppendHash(reconstructed,value,offset,length,scratch);reconstructedOffset+=length;
                        result.PieceCount++; result.MaximumPieceCharacters=Math.Max(result.MaximumPieceCharacters,length);
                        writer.WriteStartObject();
                        foreach(var property in block.EnumerateObject()) {writer.WritePropertyName(property.Name);if(property.Name=="text") writer.WriteStringValue(value,offset,length);else writer.Element(property.Value);}
                        writer.WriteEndObject(); offset+=length;
                    } while(offset<value.Length);
                    if(reconstructedOffset!=value.Length||HashString(value)!=Convert.ToHexString(reconstructed.GetHashAndReset()).ToLowerInvariant()) throw new TransportException("text_reconstruction","transform_write");
                    }
                }
                writer.WriteEndArray();
            }
            writer.WriteEndObject();
        }
    }
}
