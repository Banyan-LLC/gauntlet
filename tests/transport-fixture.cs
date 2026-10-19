namespace GauntletTransportTests
{
    using System;
    using System.Collections.Generic;
    using System.IO;
    using System.Linq;
    using System.Net;
    using System.Net.Http;
    using System.Net.Sockets;
    using System.Text;
    using System.Text.Json;
    using System.Threading;
    using System.Threading.Tasks;
    using System.Threading.Tasks.Sources;

    public sealed class Check { public string Name; public bool Passed; }

    // In-memory upstream seam: all network in this suite is literal loopback.
    internal sealed class Upstream : HttpMessageHandler
    {
        internal readonly List<HttpRequestMessage> Requests = new List<HttpRequestMessage>();
        internal readonly List<byte[]> Bodies = new List<byte[]>();
        internal HttpStatusCode Status = HttpStatusCode.OK;
        internal byte[] Reply = Encoding.UTF8.GetBytes("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"synthetic\",\"status\":\"completed\",\"output\":[]}}\n\n");
        internal byte[] CatalogReply = Encoding.UTF8.GetBytes("{\"models\":[]}");
        internal long? DeclaredLength;
        internal Exception SendFailure=null;
        internal HttpContent ResponseOverride=null,RequestOverride=null;
        internal string MediaType="canonical";
        internal bool Stall;
        internal bool IgnoreCancellation;
        internal bool StreamStall;
        internal bool UnknownLength;
        internal readonly Dictionary<string,string> ReplyHeaders = new Dictionary<string,string>();
        internal readonly TaskCompletionSource<bool> Release = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource<bool> Entered = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource<bool> SecondEntered = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        internal bool Disposed;
        internal bool DisposeFailure=false;
        internal Action DuringDispose;
        internal Action<HttpResponseMessage> BeforeReturn;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Requests.Add(request);
            Bodies.Add(request.Content == null ? Array.Empty<byte>() : await request.Content.ReadAsByteArrayAsync(ct));
            if(RequestOverride!=null) request.Content=RequestOverride;
            Entered.TrySetResult(true);
            if(Requests.Count==2) SecondEntered.TrySetResult(true);
            if(SendFailure!=null) throw SendFailure;
            if (Stall) {
                if (IgnoreCancellation) await Release.Task;
                else await Task.Delay(Timeout.Infinite, ct);
            }
            byte[] reply=request.Method==HttpMethod.Get ? CatalogReply : Reply;
            var result = new HttpResponseMessage(Status) { Content = ResponseOverride ?? (UnknownLength || StreamStall ? new StreamContent(new ReplyStream(reply,StreamStall)) : new ByteArrayContent(reply)) };
            if(DeclaredLength.HasValue) result.Content.Headers.ContentLength=DeclaredLength.Value;
            result.Content.Headers.ContentType = MediaType==null ? null : System.Net.Http.Headers.MediaTypeHeaderValue.Parse(MediaType=="canonical" ? (request.Method == HttpMethod.Get ? "application/json" : "text/event-stream") : MediaType);
            foreach(var h in ReplyHeaders) result.Headers.TryAddWithoutValidation(h.Key,h.Value);
            if ((int)Status >= 300) result.Headers.Location = new Uri("https://invalid.example/secret");
            if(BeforeReturn!=null) BeforeReturn(result);
            return result;
        }
        protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing);if(DuringDispose!=null) DuringDispose();if(DisposeFailure) throw new IOException("secret-cleanup"); }
    }

    internal sealed class NativeLease : IDisposable
    {
        readonly string path=Path.Combine(Path.GetTempPath(),"gauntlet-disposal-"+Guid.NewGuid().ToString("N"));
        readonly FileStream stream;
        readonly Action<string> afterClose;
        internal NativeLease() : this(null) {}
        internal NativeLease(Action<string> afterClose) {
            this.afterClose=afterClose;
            stream=new FileStream(path,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.None,4096,FileOptions.DeleteOnClose);
        }
        internal bool IsExclusive() {if(!File.Exists(path)) return false;try {using(var probe=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,FileShare.None)) return false;}catch(IOException) {return true;}}
        public void Dispose() {stream.Dispose();if(afterClose!=null) afterClose(path);}
    }
    internal sealed class LeasedContent : HttpContent
    {
        readonly byte[] bytes;readonly NativeLease lease;readonly bool contentFailure,streamFailure;
        internal LeasedContent(byte[] bytes,NativeLease lease,bool contentFailure,bool streamFailure) {this.bytes=bytes;this.lease=lease;this.contentFailure=contentFailure;this.streamFailure=streamFailure;}
        protected override bool TryComputeLength(out long length) {length=bytes.Length;return true;}
        protected override Task SerializeToStreamAsync(Stream target,TransportContext context) {return target.WriteAsync(bytes,0,bytes.Length);}
        protected override Task<Stream> CreateContentReadStreamAsync() {return Task.FromResult<Stream>(new LeasedStream(bytes,contentFailure ? null : lease,streamFailure));}
        protected override void Dispose(bool disposing) {if(contentFailure) throw new IOException("secret-content-disposal");base.Dispose(disposing);}
    }
    internal sealed class LeasedStream : MemoryStream
    {
        readonly NativeLease lease;readonly bool fail;
        internal LeasedStream(byte[] bytes,NativeLease lease,bool fail) : base(bytes,false) {this.lease=lease;this.fail=fail;}
        protected override void Dispose(bool disposing) {if(fail) throw new IOException("secret-stream-disposal");base.Dispose(disposing);if(lease!=null) lease.Dispose();}
    }

    internal sealed class ReplyStream : Stream
    {
        readonly byte[] bytes; readonly bool stall; int offset;
        internal int ReadAttempts;
        internal ReplyStream(byte[] bytes,bool stall) {this.bytes=bytes;this.stall=stall;}
        public override bool CanRead {get{return true;}} public override bool CanSeek {get{return false;}} public override bool CanWrite {get{return false;}}
        public override long Length {get{throw new NotSupportedException();}} public override long Position {get{throw new NotSupportedException();}set{throw new NotSupportedException();}}
        public override void Flush() {} public override long Seek(long x,SeekOrigin o) {throw new NotSupportedException();} public override void SetLength(long n) {throw new NotSupportedException();} public override void Write(byte[] b,int o,int n) {throw new NotSupportedException();}
        public override int Read(byte[] b,int o,int n) {throw new NotSupportedException();}
        public override async ValueTask<int> ReadAsync(Memory<byte> b,CancellationToken ct=default(CancellationToken)) {
            ReadAttempts++;
            if(stall) await Task.Delay(Timeout.Infinite,ct);
            int n=Math.Min(b.Length,bytes.Length-offset); bytes.AsMemory(offset,n).CopyTo(b); offset+=n; return n;
        }
    }
    internal sealed class ControlledTailStream : Stream
    {
        readonly byte[] prefix,tail;int offset;bool released;
        internal readonly TaskCompletionSource<bool> AtEof=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource<bool> Release=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        internal ControlledTailStream(byte[] prefix,byte[] tail) {this.prefix=prefix;this.tail=tail;}
        public override bool CanRead {get{return true;}}public override bool CanWrite {get{return false;}}public override bool CanSeek {get{return false;}}
        public override long Length {get{throw new NotSupportedException();}}public override long Position {get{throw new NotSupportedException();}set{throw new NotSupportedException();}}
        public override void Flush() {}public override long Seek(long n,SeekOrigin o) {throw new NotSupportedException();}public override void SetLength(long n) {throw new NotSupportedException();}public override void Write(byte[] b,int o,int n) {throw new NotSupportedException();}public override int Read(byte[] b,int o,int n) {throw new NotSupportedException();}
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer,CancellationToken ct=default(CancellationToken)) {
            if(!released&&offset<prefix.Length) {int n=Math.Min(buffer.Length,prefix.Length-offset);prefix.AsMemory(offset,n).CopyTo(buffer);offset+=n;return n;}
            if(!released) {AtEof.TrySetResult(true);await Release.Task.WaitAsync(ct);released=true;offset=0;}
            int count=Math.Min(buffer.Length,tail.Length-offset);tail.AsMemory(offset,count).CopyTo(buffer);offset+=count;return count;
        }
    }
    internal sealed class HostileChallengeContent : HttpContent
    {
        internal int ReadAttempts;
        protected override bool TryComputeLength(out long length) {length=long.MaxValue;return true;}
        protected override Task SerializeToStreamAsync(Stream target,TransportContext context) {ReadAttempts++;throw new IOException("secret-upstream-body");}
        protected override Task<Stream> CreateContentReadStreamAsync() {ReadAttempts++;throw new IOException("secret-upstream-body");}
    }

    // Return this source directly to HandleAsync. The observation is published
    // only after its registered await continuation has processed the exception.
    internal sealed class ObservedTailFailure : IValueTaskSource,IDisposable
    {
        ManualResetValueTaskSourceCore<bool> completion;
        readonly TaskCompletionSource<bool> registered,settled;
        readonly CancellationTokenRegistration cancellation;
        int completed;
        internal readonly TaskCompletionSource<bool> Observed=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        internal ObservedTailFailure(CancellationToken ct,TaskCompletionSource<bool> registered,TaskCompletionSource<bool> settled) {
            this.registered=registered;this.settled=settled;
            completion.RunContinuationsAsynchronously=false;
            cancellation=ct.Register(()=>Complete(new OperationCanceledException(ct)));
        }
        internal ValueTask Pending {get {return new ValueTask(this,completion.Version);}}
        internal void Fail() {Complete(new IOException("synthetic-tail-before-native-observation"));}
        void Complete(Exception failure) {if(Interlocked.CompareExchange(ref completed,1,0)==0) completion.SetException(failure);}
        public ValueTaskSourceStatus GetStatus(short token) {return completion.GetStatus(token);}
        public void GetResult(short token) {try {completion.GetResult(token);}finally {settled.TrySetResult(true);}}
        public void OnCompleted(Action<object> continuation,object state,short token,ValueTaskSourceOnCompletedFlags flags) {
            completion.OnCompleted(value=>{try {continuation(value);}finally {Observed.TrySetResult(true);}},state,token,flags);
            registered.TrySetResult(true);
        }
        public void Dispose() {cancellation.Dispose();}
    }

    // Hold the original socket write after a known byte boundary, rather than
    // relying on a continuation winning a scheduling race against FinishClient.
    internal sealed class ControlledDeliveryStream : NetworkStream
    {
        readonly byte[] terminal;readonly string mode;readonly MemoryStream delivered=new MemoryStream();
        bool headerWritten,terminalWritten;
        ObservedTailFailure tailFailure;
        internal readonly TaskCompletionSource<bool> AtBoundary=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource<bool> Release=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource<bool> Settled=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        internal bool DisposedBeforeSettlement;
        internal ControlledDeliveryStream(Socket socket,byte[] terminal,string mode) : base(socket,false) {this.terminal=terminal;this.mode=mode;}
        internal byte[] Delivered {get {lock(delivered) return delivered.ToArray();}}
        internal bool HasTailFailureProbe {get {return tailFailure!=null;}}
        internal Task TailFailureObserved {get {return tailFailure.Observed.Task;}}
        internal void FailTail() {tailFailure.Fail();}
        async Task Publish(ReadOnlyMemory<byte> bytes,CancellationToken ct) {
            await base.WriteAsync(bytes,ct).ConfigureAwait(false);
            lock(delivered) {byte[] copy=bytes.ToArray();delivered.Write(copy,0,copy.Length);}
        }
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> bytes,CancellationToken ct=default(CancellationToken)) {
            if(mode.StartsWith("tail-before-",StringComparison.Ordinal)&&headerWritten&&terminalWritten) {
                if(tailFailure!=null) throw new InvalidOperationException("Synthetic tail write was repeated.");
                tailFailure=new ObservedTailFailure(ct,AtBoundary,Settled);
                return tailFailure.Pending;
            }
            return WriteCoreAsync(bytes,ct);
        }
        async ValueTask WriteCoreAsync(ReadOnlyMemory<byte> bytes,CancellationToken ct) {
            if(!headerWritten) {headerWritten=true;await Publish(bytes,ct).ConfigureAwait(false);return;}
            if(!terminalWritten&&mode!="undelivered") {
                if(bytes.Length<terminal.Length||!bytes.Span.Slice(0,terminal.Length).SequenceEqual(terminal)) throw new InvalidOperationException("Synthetic terminal boundary was not supplied.");
                await Publish(bytes.Slice(0,terminal.Length),ct).ConfigureAwait(false);terminalWritten=true;
                if((mode=="tail-in-flight"||mode.StartsWith("tail-before-",StringComparison.Ordinal))&&bytes.Length==terminal.Length) return;
            }
            try {
                AtBoundary.TrySetResult(true);
                await Release.Task.WaitAsync(ct).ConfigureAwait(false);
                if(mode=="undelivered"||mode=="write-failure"||mode=="tail-in-flight"||bytes.Length>terminal.Length) throw new IOException("synthetic-consumer-retired");
            } finally {Settled.TrySetResult(true);}
        }
        protected override void Dispose(bool disposing) {
            if(AtBoundary.Task.IsCompleted&&!Settled.Task.IsCompleted) DisposedBeforeSettlement=true;
            if(tailFailure!=null) tailFailure.Dispose();
            base.Dispose(disposing);
        }
    }

    // Return the source directly to the real HandleAsync read await. Complete
    // it inline only after OnCompleted has registered that actual continuation.
    internal sealed class InlineCancellationReadStream : Stream,IValueTaskSource<int>
    {
        ManualResetValueTaskSourceCore<int> completion;
        CancellationTokenRegistration cancellation;
        int reads,completed;
        internal CancellationToken ReadToken;
        internal Exception Failure;
        internal Action AfterConsumer;
        internal bool Disposed;
        internal long ConsumerEnteredAt,ConsumerReturnedAt;
        internal readonly TaskCompletionSource<bool> AwaitRegistered=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource<bool> ConsumerReturned=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        internal InlineCancellationReadStream() {completion.RunContinuationsAsynchronously=false;}
        public override bool CanRead {get{return true;}}public override bool CanWrite {get{return false;}}public override bool CanSeek {get{return false;}}
        public override long Length {get{throw new NotSupportedException();}}public override long Position {get{throw new NotSupportedException();}set{throw new NotSupportedException();}}
        public override void Flush() {}public override long Seek(long n,SeekOrigin o) {throw new NotSupportedException();}public override void SetLength(long n) {throw new NotSupportedException();}public override void Write(byte[] b,int o,int n) {throw new NotSupportedException();}public override int Read(byte[] b,int o,int n) {throw new NotSupportedException();}
        public override ValueTask<int> ReadAsync(Memory<byte> buffer,CancellationToken ct=default(CancellationToken)) {
            if(Interlocked.Increment(ref reads)!=1) throw new InvalidOperationException("fixture expects one original pending read");
            ReadToken=ct;
            // This registration follows Bridge.OnCancellation and the scheduler's
            // sentinel; the owned CTS invokes this newer callback first.
            cancellation=ct.Register(()=>Complete(new OperationCanceledException(ct)));
            return new ValueTask<int>(this,completion.Version);
        }
        internal void FailUnrelated() {Complete(new OperationCanceledException("synthetic-unrelated-cancellation"));}
        void Complete(Exception failure) {
            if(Interlocked.CompareExchange(ref completed,1,0)==0) {Failure=failure;completion.SetException(failure);}
        }
        public ValueTaskSourceStatus GetStatus(short token) {return completion.GetStatus(token);}
        public int GetResult(short token) {return completion.GetResult(token);}
        public void OnCompleted(Action<object> continuation,object state,short token,ValueTaskSourceOnCompletedFlags flags) {
            completion.OnCompleted(value=>{
                ConsumerEnteredAt=System.Diagnostics.Stopwatch.GetTimestamp();
                try {continuation(value);}
                finally {
                    ConsumerReturnedAt=System.Diagnostics.Stopwatch.GetTimestamp();
                    if(AfterConsumer!=null) AfterConsumer();
                    ConsumerReturned.TrySetResult(true);
                }
            },state,token,flags);
            AwaitRegistered.TrySetResult(true);
        }
        protected override void Dispose(bool disposing) {if(disposing) {cancellation.Dispose();Disposed=true;}base.Dispose(disposing);}
    }

    public static class Suite
    {
        static readonly List<Check> Checks = new List<Check>();
        static void Check(bool ok, string name) { Checks.Add(new Check { Name = name, Passed = ok }); }
        static void Reject(string json, string prompt, string name)
        {
            try { GauntletTransport.Bridge.Transform(Encoding.UTF8.GetBytes(json), prompt); Check(false, name); }
            catch (GauntletTransport.TransportException e) { Check(e.Message == "Transport request rejected.", name); }
        }
        static string Payload(string text) { return JsonSerializer.Serialize(new { model="gpt-6.1-sol", stream=true, input=new [] { new { role="user", content=new [] { new { type="input_text", text=text, metadata=new { label="keep", n=4 } } } } }, future = new { array=new object[] { true, null, 12.5, "\r\n" } } }); }
        static byte[] Request(GauntletTransport.Bridge bridge, string body, string method="POST", string path="/backend-api/codex/responses", string extra="", bool capability=true, string host=null)
        {
            byte[] bytes=Encoding.UTF8.GetBytes(body);
            return Encoding.UTF8.GetBytes(method+" "+path+" HTTP/1.1\r\nHost: "+(host ?? new Uri(bridge.Endpoint).Authority)+"\r\n"+
                (capability ? "X-Gauntlet-Capability: "+bridge.GetCapability()+"\r\n" : "")+
                "Authorization: Bearer synthetic-token\r\nChatGPT-Account-Id: synthetic-account\r\n"+
                (method == "POST" ? "Content-Type: application/json\r\nContent-Length: "+bytes.Length+"\r\n" : "")+extra+"\r\n"+body);
        }
        static async Task<byte[]> Exchange(GauntletTransport.Bridge bridge, byte[] request)
        {
            using (var client=new TcpClient(AddressFamily.InterNetwork)) {
                await client.ConnectAsync(IPAddress.Loopback,new Uri(bridge.Endpoint).Port);
                using(var stream=client.GetStream()) {
                    await stream.WriteAsync(request);
                    using(var result=new MemoryStream()) {
                        try { await stream.CopyToAsync(result); } catch(IOException) { }
                        return result.ToArray();
                    }
                }
            }
        }
        static async Task Retire(GauntletTransport.Bridge bridge)
        {
            bridge.Close();
            var winner=await Task.WhenAny(bridge.Completion,Task.Delay(2500));
            Check(winner == bridge.Completion && bridge.GetProof().Retired,"worker physically retires after close");
        }
        static string Body(byte[] response) { var text=Encoding.UTF8.GetString(response); int pos=text.IndexOf("\r\n\r\n",StringComparison.Ordinal); return pos<0 ? "" : text.Substring(pos+4); }
        static byte[] BodyBytes(byte[] response) {for(int i=0;i+3<response.Length;i++) if(response[i]==13&&response[i+1]==10&&response[i+2]==13&&response[i+3]==10) return response.Skip(i+4).ToArray(); return Array.Empty<byte>();}
        static async Task TerminalDeliveryFinish(string mode)
        {
            var handler=new Upstream();byte[] terminal=handler.Reply,tail=Encoding.UTF8.GetBytes(": heartbeat\n\n");
            bool coalesced=mode=="coalesced-tail"||mode=="tail-in-flight";
            if(coalesced) handler.Reply=terminal.Concat(tail).ToArray();
            long deadline=System.Diagnostics.Stopwatch.GetTimestamp()+(mode=="deadline" ? System.Diagnostics.Stopwatch.Frequency : System.Diagnostics.Stopwatch.Frequency*5);
            ControlledDeliveryStream controlled=null;
            var selected=new TaskCompletionSource<ControlledDeliveryStream>(TaskCreationOptions.RunContinuationsAsynchronously);
            var bridge=new GauntletTransport.Bridge("prompt",deadline,handler,client=>{
                controlled=new ControlledDeliveryStream(client.Client,terminal,mode);selected.TrySetResult(controlled);return controlled;
            });
            using(var consumer=new TcpClient(AddressFamily.InterNetwork)) {
                try {
                    await consumer.ConnectAsync(IPAddress.Loopback,new Uri(bridge.Endpoint).Port);
                    await consumer.GetStream().WriteAsync(Request(bridge,Payload("prompt")));
                    await Task.WhenAny(selected.Task,bridge.Completion);
                    Check(selected.Task.IsCompleted,"terminal delivery "+mode+" selects its owned client stream");
                    if(!selected.Task.IsCompleted) return;
                    controlled=await selected.Task;
                    await Task.WhenAny(controlled.AtBoundary.Task,bridge.Completion);
                    Check(controlled.AtBoundary.Task.IsCompleted,"terminal delivery "+mode+" reaches controlled original write");
                    if(!controlled.AtBoundary.Task.IsCompleted) return;
                    if(mode!="undelivered") {
                        byte[] expected=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n").Concat(terminal).ToArray();
                        byte[] received=new byte[expected.Length];int count=0;
                        using(var bound=new CancellationTokenSource(bridge.RemainingMilliseconds)) {
                            while(count<received.Length) {int n=await consumer.GetStream().ReadAsync(received.AsMemory(count),bound.Token);if(n==0) break;count+=n;}
                        }
                        Check(count==expected.Length&&received.SequenceEqual(expected),"terminal delivery "+mode+" consumer receives the exact terminal before write settlement");
                    }
                    Check(!controlled.Settled.Task.IsCompleted,"terminal delivery "+mode+" original write is still pending at consumer retirement");
                    consumer.Close();
                    bridge.FinishClient();
                    Check(bridge.GetProof().ErrorCode=="","terminal delivery "+mode+" does not replace a pending write with client_finish_early");
                    Check(!bridge.GetProof().Success&&bridge.GetProof().Responses==0,"terminal delivery "+mode+" remains provisional before original write settlement");
                    if(mode!="deadline") controlled.Release.TrySetResult(true);
                    await bridge.Completion;
                    var proof=bridge.GetProof();
                    bool success=mode=="delivered-pending"||mode=="coalesced-tail"||mode=="tail-in-flight";
                    Check(proof.Retired&&proof.Completed&&proof.Success==success&&proof.Responses==(success ? 1 : 0)&&bridge.DeadlineTimestamp==deadline,"terminal delivery "+mode+" settles the owned worker under its original deadline");
                    Check(controlled.Settled.Task.IsCompleted&&!controlled.DisposedBeforeSettlement,"terminal delivery "+mode+" retires the original write before disposing its stream");
                    if(success) Check(proof.ErrorCode==""&&BodyBytes(controlled.Delivered).SequenceEqual(terminal),"terminal delivery "+mode+" acknowledges exactly the delivered terminal");
                    else if(mode=="deadline") Check(proof.ErrorCode=="deadline"&&bridge.RemainingMilliseconds==0,"terminal delivery deadline cannot start a fresh settlement budget");
                    else Check(proof.ErrorCode=="transport_io"&&proof.ErrorCause!=null&&proof.ErrorCause.Type=="System.IO.IOException","terminal delivery "+mode+" preserves the original write failure cause");
                    if(mode=="undelivered") Check(BodyBytes(controlled.Delivered).Length==0,"terminal delivery undelivered never acknowledges unwritten terminal bytes");
                    if(coalesced) Check(proof.DrainedTailBytes==tail.Length,"terminal delivery "+mode+" validates and accounts for the coalesced heartbeat");
                } finally {
                    if(controlled!=null) controlled.Release.TrySetResult(true);
                    bridge.Close();await bridge.Completion;
                    if(controlled!=null) controlled.Dispose();
                }
            }
        }
        static async Task TailFailureBeforeRetirement(string mode)
        {
            var handler=new Upstream();byte[] terminal=handler.Reply,tail=Encoding.UTF8.GetBytes(": heartbeat\n\n");
            handler.Reply=terminal.Concat(tail).ToArray();
            long deadline=System.Diagnostics.Stopwatch.GetTimestamp()+System.Diagnostics.Stopwatch.Frequency*(mode=="tail-before-deadline" ? 1 : 5);
            ControlledDeliveryStream controlled=null;
            var selected=new TaskCompletionSource<ControlledDeliveryStream>(TaskCreationOptions.RunContinuationsAsynchronously);
            var bridge=new GauntletTransport.Bridge("prompt",deadline,handler,client=>{
                controlled=new ControlledDeliveryStream(client.Client,terminal,mode);selected.TrySetResult(controlled);return controlled;
            });
            using(var consumer=new TcpClient(AddressFamily.InterNetwork)) {
                try {
                    await consumer.ConnectAsync(IPAddress.Loopback,new Uri(bridge.Endpoint).Port);
                    await consumer.GetStream().WriteAsync(Request(bridge,Payload("prompt")));
                    await Task.WhenAny(selected.Task,bridge.Completion);
                    Check(selected.Task.IsCompleted,mode+" selects the original owned stream");
                    if(!selected.Task.IsCompleted) return;
                    controlled=await selected.Task;
                    await Task.WhenAny(controlled.AtBoundary.Task,bridge.Completion);
                    Check(controlled.AtBoundary.Task.IsCompleted&&controlled.HasTailFailureProbe,mode+" registers the real HandleAsync tail await before failure");
                    if(!controlled.AtBoundary.Task.IsCompleted||!controlled.HasTailFailureProbe) return;
                    byte[] expected=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n").Concat(terminal).ToArray();
                    byte[] received=new byte[expected.Length];int count=0;
                    using(var bound=new CancellationTokenSource(bridge.RemainingMilliseconds)) {
                        while(count<received.Length) {int n=await consumer.GetStream().ReadAsync(received.AsMemory(count),bound.Token);if(n==0) break;count+=n;}
                    }
                    Check(count==expected.Length&&received.SequenceEqual(expected),mode+" consumer receives the exact terminal before native-exit observation");
                    consumer.Close();controlled.FailTail();
                    await controlled.TailFailureObserved;
                    var pending=bridge.GetProof();
                    Check(pending.ErrorCode==""&&!pending.Success&&!pending.Retired&&pending.Responses==0,mode+" keeps proof provisional after the real tail-error continuation and before native-exit observation");
                    if(mode=="tail-before-finish") bridge.FinishClient();
                    else if(mode=="tail-before-close") bridge.Close();
                    await bridge.Completion;
                    var proof=bridge.GetProof();bool success=mode=="tail-before-finish";
                    Check(proof.Retired&&proof.Completed&&proof.Success==success&&proof.Responses==(success ? 1 : 0)&&bridge.DeadlineTimestamp==deadline,mode+" settles the original owner under the unchanged deadline");
                    Check(controlled.Settled.Task.IsCompleted&&!controlled.DisposedBeforeSettlement,mode+" observes original write settlement before stream disposal");
                    Check(BodyBytes(controlled.Delivered).SequenceEqual(terminal)&&proof.DrainedTailBytes==(success ? tail.Length : 0),mode+" accounts for exactly the delivered terminal and admitted tail drain");
                    if(success) Check(proof.ErrorCode=="",mode+" accepts graceful native retirement observed after tail I/O failure");
                    else if(mode=="tail-before-deadline") Check(proof.ErrorCode=="deadline"&&bridge.RemainingMilliseconds==0,mode+" cannot replace missing graceful finish with a fresh wait budget");
                    else Check(proof.ErrorCode=="transport_io"&&proof.ErrorCause!=null&&proof.ErrorCause.Type=="System.IO.IOException",mode+" preserves the original tail IOException on unsuccessful close");
                } finally {
                    if(controlled!=null) controlled.Release.TrySetResult(true);
                    bridge.Close();await bridge.Completion;
                    if(controlled!=null) controlled.Dispose();
                }
            }
        }
        static async Task Bad(string name, Func<GauntletTransport.Bridge, byte[]> request, bool allowClosed=false, string expectedError=null)
        {
            var handler=new Upstream(); var bridge=new GauntletTransport.Bridge("prompt",1500,handler);
            try {
                byte[] reply=await Exchange(bridge,request(bridge));
                Check((Encoding.ASCII.GetString(reply).StartsWith("HTTP/1.1 400 ",StringComparison.Ordinal)||(allowClosed&&reply.Length==0&&bridge.GetProof().ErrorCode=="header_limit"&&bridge.GetProof().ErrorStage=="request"&&!bridge.GetProof().Success&&bridge.GetProof().Retired)) && handler.Requests.Count==0 && (expectedError==null||bridge.GetProof().ErrorCode==expectedError),name);
                Check(bridge.GetProof().ErrorCode.Length>0 && !bridge.GetProof().Success,name+" blocks acceptance");
            } finally { await Retire(bridge); }
        }
        static async Task SubagentRequestHeader(string name)
        {
            var handler=new Upstream();var bridge=new GauntletTransport.Bridge("prompt",3000,handler);
            try {
                byte[] reply=await Exchange(bridge,Request(bridge,Payload("prompt"),extra:name+": synthetic-subagent\r\n"));
                await Retire(bridge);
                Check(BodyBytes(reply).SequenceEqual(handler.Reply)&&handler.Requests.Count==1,"subagent metadata request reaches the fixed upstream "+name);
                Check(handler.Requests.Count==1&&handler.Requests[0].Headers.GetValues("x-openai-subagent").Single()=="synthetic-subagent"&&handler.Requests[0].RequestUri==new Uri("https://chatgpt.com/backend-api/codex/responses")&&!handler.Requests[0].Headers.Contains("X-Gauntlet-Capability"),"only admitted subagent metadata forwarded without local capability "+name);
                var proof=bridge.GetProof();
                Check(proof.Success&&proof.Retired&&proof.PromptSeen&&proof.Responses==1&&!JsonSerializer.Serialize(proof).Contains("synthetic-subagent"),"subagent metadata preserves complete prompt acceptance and private proof "+name);
            } finally {await Retire(bridge);}
        }
        static async Task HeaderPolicyCause(string headerName, bool forwarding=false)
        {
            var handler=new Upstream();var bridge=new GauntletTransport.Bridge("prompt",3000,handler);
            var allowed=(HashSet<string>)typeof(GauntletTransport.Bridge).GetField("ForwardHeaders",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Static).GetValue(null);
            bool added=false;
            try {
                if(forwarding) added=allowed.Add("content-type");
                await Exchange(bridge,Request(bridge,Payload("prompt"),extra:forwarding ? "" : headerName+": sensitive-header-value-sentinel\r\n"));
                await Retire(bridge);
                var proof=bridge.GetProof();var cause=proof.ErrorCause;
                var property=typeof(GauntletTransport.SanitizedCause).GetProperty("HeaderNameSha256");
                string digest=cause==null||property==null ? null : (string)property.GetValue(cause);
                string expected=Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.ASCII.GetBytes(headerName.ToLowerInvariant()))).ToLowerInvariant();
                Check(proof.ErrorCode=="header_policy"&&proof.ErrorStage=="request"&&!proof.Success&&proof.Retired,"header rejection remains failed and retired "+headerName.Length+" "+forwarding);
                Check(cause!=null&&cause.Type=="GauntletTransport.HeaderPolicyException","header failure has fixed typed diagnostic cause "+headerName.Length+" "+forwarding);
                Check(digest==expected,"header policy identifies only lower-case name digest "+headerName.Length+" "+forwarding);
                string json=JsonSerializer.Serialize(cause);
                Check(!json.Contains(headerName)&&!json.Contains(headerName.ToLowerInvariant())&&!json.Contains("sensitive-header-value-sentinel"),"header name and value never retained in public cause "+headerName.Length+" "+forwarding);
                Check(json.Length<1024&&handler.Requests.Count==0,"header diagnostic remains bounded before upstream dispatch "+headerName.Length+" "+forwarding);
            } finally {if(added) allowed.Remove("content-type");await Retire(bridge);}
        }
        static async Task BadResponse(string name,byte[] body,bool catalog=false,long? declared=null,bool afterSuccess=false,string mediaType="canonical",bool requireBodyValidation=false)
        {
            var h=new Upstream();var b=new GauntletTransport.Bridge("prompt",3000,h);
            if(afterSuccess) await Exchange(b,Request(b,Payload("prompt")));
            h.Reply=body;h.CatalogReply=body;h.DeclaredLength=declared;h.MediaType=mediaType;
            await Exchange(b,Request(b,catalog ? "" : Payload("prompt"),catalog ? "GET" : "POST",catalog ? "/backend-api/codex/models" : "/backend-api/codex/responses"));
            await Retire(b);var p=b.GetProof();
            Check(!p.Success&&p.ErrorCode.Length>0&&(!requireBodyValidation||p.ErrorCode!="upstream_content_type")&&p.Responses==(afterSuccess ? 1 : 0)&&p.Models==0,name);
        }
        static bool AuthFlag(GauntletTransport.Proof proof,string property,bool expected) {var p=proof.GetType().GetProperty(property);return p!=null&&(bool)p.GetValue(proof)==expected;}
        static int AuthCount(GauntletTransport.Proof proof,string property) {var p=proof.GetType().GetProperty(property);return p==null ? -1 : (int)p.GetValue(proof);}
        static string AuthPayload() {string json=Payload("prompt");return json.Substring(0,json.Length-1)+",\"tools\":[],\"text\":{\"format\":{\"type\":\"json_schema\",\"schema\":{\"type\":\"object\",\"properties\":{\"verdict\":{\"type\":\"string\"}}}}}}";}
        static async Task AuthSequence(string name,string[] steps,bool success,int responses,int models,bool pendingCatalog,bool pendingResponse,string errorCode,bool timeout=false)
        {
            var handler=new Upstream();var bridge=new GauntletTransport.Bridge("prompt",timeout ? 300 : 5000,handler);
            long original=bridge.DeadlineTimestamp;bool expectedStatuses=true;int catalogChallenges=0,responseChallenges=0;
            foreach(string step in steps) {
                if(bridge.Completion.IsCompleted) {expectedStatuses=false;break;}
                bool catalog=step[0]=='G',challenge=step.Contains("401");
                handler.Status=challenge ? HttpStatusCode.Unauthorized : step.Contains("403") ? HttpStatusCode.Forbidden : HttpStatusCode.OK;
                handler.Reply=step.Contains("bad")&&!catalog ? Encoding.UTF8.GetBytes("data: {\"type\":\"response.created\"}\n\n") : new Upstream().Reply;
                handler.CatalogReply=step.Contains("bad")&&catalog ? Encoding.UTF8.GetBytes("{") : Encoding.UTF8.GetBytes("{\"models\":[]}");
                byte[] reply;
                try {reply=await Exchange(bridge,Request(bridge,catalog ? "" : AuthPayload(),catalog ? "GET" : "POST",catalog ? "/backend-api/codex/models" : "/backend-api/codex/responses"));}
                catch(SocketException) {expectedStatuses=false;break;}
                string text=Encoding.UTF8.GetString(reply);
                expectedStatuses&=text.StartsWith("HTTP/1.1 "+(challenge ? "401 " : step.Contains("403") ? "502 " : "200 "),StringComparison.Ordinal);
                if(challenge) {if(catalog) catalogChallenges++;else responseChallenges++;}
            }
            if(timeout) await Task.WhenAny(bridge.Completion,Task.Delay(2000));
            await Retire(bridge);var proof=bridge.GetProof();
            Check(expectedStatuses&&proof.Success==success&&proof.Responses==responses&&proof.Models==models&&proof.ErrorCode==errorCode&&AuthFlag(proof,"PendingCatalogAuthChallenge",pendingCatalog)&&AuthFlag(proof,"PendingResponseAuthChallenge",pendingResponse)&&AuthCount(proof,"CatalogAuthChallenges")==catalogChallenges&&AuthCount(proof,"ResponseAuthChallenges")==responseChallenges&&bridge.DeadlineTimestamp==original,"bounded 401 state "+name);
            Check(handler.Bodies.Where(bytes=>bytes.Length>0).All(bytes=>{using(var parsed=JsonDocument.Parse(bytes)) {var root=parsed.RootElement;return root.GetProperty("model").GetString()=="gpt-6.1-sol"&&root.GetProperty("stream").GetBoolean()&&root.GetProperty("tools").GetArrayLength()==0&&root.GetProperty("text").GetProperty("format").GetProperty("schema").GetProperty("properties").GetProperty("verdict").GetProperty("type").GetString()=="string"&&root.GetProperty("input")[0].GetProperty("content")[0].GetProperty("text").GetString()=="prompt";}}),"401 retries preserve exact prompt model schema zero-tools "+name);
            if(errorCode=="auth_challenge_unresolved") Check(proof.ErrorCause!=null&&proof.ErrorCause.HttpStatus==401,"unresolved challenge exposes only numeric HTTP401 cause "+name);
            if(steps.Length==8) {
                bool refused=false;try {await Exchange(bridge,Request(bridge,AuthPayload()));}catch(SocketException) {refused=true;}
                Check(refused&&handler.Requests.Count==8,"401 recovery retains global eight-request cap "+name);
            }
            if(errorCode=="upstream_status"||errorCode=="sse_incomplete"||errorCode=="catalog_json") {
                bool refused=false;try {await Exchange(bridge,Request(bridge,AuthPayload()));}catch(SocketException) {refused=true;}
                Check(refused,"permanent failure cannot be cleared by another auth recovery request "+name);
            }
        }
        static async Task<bool> ObserveUndrainedClose(TcpListener listener,CancellationToken ct)
        {
            try {
                using(var accepted=await listener.AcceptTcpClientAsync(ct)) using(var stream=accepted.GetStream()) {
                    byte[] one=new byte[1];var header=new StringBuilder();
                    while(header.Length<4096&&!header.ToString().EndsWith("\r\n\r\n",StringComparison.Ordinal)) {int n=await stream.ReadAsync(one.AsMemory(),ct);if(n==0) return false;header.Append((char)one[0]);}
                    await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 401 Unauthorized\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n"),ct);
                    // Never send a body chunk. A draining client waits here; a no-drain disposer closes.
                    try {return await stream.ReadAsync(one.AsMemory(),ct)==0;}catch(IOException) {return !ct.IsCancellationRequested;}
                }
            }catch(OperationCanceledException) {return false;}
        }
        static async Task ProbeNativeNoDrain()
        {
            var listener=new TcpListener(IPAddress.Loopback,0);listener.Server.ExclusiveAddressUse=true;listener.Start(1);
            using(var bound=new CancellationTokenSource(2000)) {
                var observed=ObserveUndrainedClose(listener,bound.Token);HttpClient client=null;
                bool closed=false;
                try {
                    var factory=typeof(GauntletTransport.Bridge).GetMethod("CreateHandler",System.Reflection.BindingFlags.Static|System.Reflection.BindingFlags.NonPublic);
                    client=new HttpClient((HttpMessageHandler)factory.Invoke(null,null),true);
                    using(var request=new HttpRequestMessage(HttpMethod.Get,"http://127.0.0.1:"+((IPEndPoint)listener.LocalEndpoint).Port+"/challenge")) {
                        request.Version=HttpVersion.Version11;request.VersionPolicy=HttpVersionPolicy.RequestVersionExact;
                        var response=await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,bound.Token);response.Dispose();
                        var winner=await Task.WhenAny(observed,Task.Delay(500));closed=winner==observed&&await observed;
                    }
                } finally {
                    if(client!=null) client.Dispose();bound.Cancel();listener.Stop();await observed;
                }
                Check(closed,"native fixed-handler disposal closes stalled chunked401 without waiting to drain body");
            }
        }
        static async Task RequestCountBoundary()
        {
            foreach(int count in new [] {7,8}) {
                var upstream=new Upstream();var bridge=new GauntletTransport.Bridge("prompt",5000,upstream);
                try {
                    long original=bridge.DeadlineTimestamp;
                    for(int i=0;i<count;i++) await Exchange(bridge,Request(bridge,Payload("prompt")));
                    Check(!bridge.Completion.IsCompleted&&!bridge.FailureToken.IsCancellationRequested,"request budget waits for confirmed consumer finish at "+count);
                    bridge.FinishClient();await Task.WhenAny(bridge.Completion,Task.Delay(2000));
                    var proof=bridge.GetProof();
                    Check(bridge.Completion.IsCompleted&&proof.Success&&proof.Retired&&proof.Responses==count&&proof.ErrorCode==""&&upstream.Requests.Count==count,"exact "+count+" completed requests preserve successful native consumer finish");
                    Check(bridge.DeadlineTimestamp==original,"request boundary preserves original absolute deadline at "+count);
                } finally {await Retire(bridge);}
            }
            var handler=new Upstream();var limited=new GauntletTransport.Bridge("prompt",5000,handler);
            try {
                long original=limited.DeadlineTimestamp;
                for(int i=0;i<8;i++) await Exchange(limited,Request(limited,Payload("prompt")));
                long admittedBytes=limited.GetProof().RequestBytes;
                int signals=0;using(var fatal=limited.FailureToken.Register(()=>Interlocked.Increment(ref signals))) {
                    bool connected=false,closed=false;
                    using(var ninth=new TcpClient(AddressFamily.InterNetwork)) {
                        try {
                            await ninth.ConnectAsync(IPAddress.Loopback,new Uri(limited.Endpoint).Port);connected=true;
                            // Send no header or body: exhausting the count must not wait to read either.
                            using(var bound=new CancellationTokenSource(1500)) {
                                try {closed=await ninth.GetStream().ReadAsync(new byte[1].AsMemory(),bound.Token)==0;}
                                catch(IOException) {closed=true;}
                            }
                        } catch(SocketException) { }
                    }
                    await Task.WhenAny(limited.Completion,Task.Delay(2000));
                    var proof=limited.GetProof();
                    Check(connected&&closed,"ninth connection receives bounded count refusal without sending any request bytes");
                    Check(proof.Retired&&proof.Completed&&!proof.Success&&proof.ErrorCode=="request_limit"&&proof.ErrorStage=="request_count","actual ninth attempt latches typed request-count failure after eight successes");
                    Check(limited.FailureToken.IsCancellationRequested&&signals==1,"request-count refusal publishes the owning native job fatal signal exactly once");
                    Check(handler.Requests.Count==8&&proof.Responses==8&&proof.RequestBytes==admittedBytes,"overflow sentinel reads no ninth body and forwards at most eight requests");
                    Check(limited.DeadlineTimestamp==original&&limited.Completion.IsCompleted,"overflow retirement preserves original absolute deadline");
                }
            } finally {await Retire(limited);}
        }

        static async Task CancellationCallbackOrder(string mode)
        {
            long deadline=System.Diagnostics.Stopwatch.GetTimestamp()+System.Diagnostics.Stopwatch.Frequency*5;
            // Observation gates use the same immutable raw-clock budget. A logical
            // zero after cancellation must not manufacture a new cleanup budget.
            Func<int> originalClockBudget=()=> (int)Math.Max(0m,Math.Ceiling(((decimal)deadline-System.Diagnostics.Stopwatch.GetTimestamp())*1000m/System.Diagnostics.Stopwatch.Frequency));
            CancellationTokenSource scheduled=null;CancellationToken originalToken=default(CancellationToken);
            CancellationTokenRegistration olderCallback=default(CancellationTokenRegistration);
            int requestedDelay=0,olderCallbackRuns=0,olderCallbacksAtObservation=-1,remainingAtObservation=-1;
            bool cancellationAtObservation=false;long observationAt=0;
            GauntletTransport.Proof observed=null;
            var input=new InlineCancellationReadStream();
            var handler=new Upstream {ResponseOverride=new StreamContent(input)};
            var bridge=new GauntletTransport.Bridge("prompt",deadline,handler,null,(owner,remaining)=>{
                scheduled=owner;originalToken=owner.Token;requestedDelay=remaining;
                // Older than the read callback, newer than Bridge.OnCancellation.
                // Its absence at the observation proves neither older callback ran.
                olderCallback=originalToken.Register(()=>Interlocked.Increment(ref olderCallbackRuns));
            });
            input.AfterConsumer=()=>{
                observed=bridge.GetProof();remainingAtObservation=bridge.RemainingMilliseconds;
                cancellationAtObservation=originalToken.IsCancellationRequested;
                olderCallbacksAtObservation=Volatile.Read(ref olderCallbackRuns);
                observationAt=System.Diagnostics.Stopwatch.GetTimestamp();
            };
            Task<byte[]> pending=null;
            try {
                pending=Exchange(bridge,Request(bridge,Payload("prompt")));
                await Task.WhenAny(input.AwaitRegistered.Task,bridge.Completion,Task.Delay(originalClockBudget()));
                Check(input.AwaitRegistered.Task.IsCompleted,mode+" registers the actual original read await before completing its ValueTask source");
                if(!input.AwaitRegistered.Task.IsCompleted) return;
                Check(scheduled!=null&&requestedDelay>0&&requestedDelay<=5000&&input.ReadToken==originalToken,mode+" retains the original cancellation owner and original remaining budget");
                Check(!bridge.Completion.IsCompleted&&System.Diagnostics.Stopwatch.GetTimestamp()<deadline,mode+" starts cancellation while the original task is pending and raw clock has time remaining");
                if(mode=="owned-deadline") scheduled.Cancel();
                else if(mode=="explicit-close") bridge.Close();
                else input.FailUnrelated();
                Check(input.ConsumerReturned.Task.IsCompleted&&olderCallbacksAtObservation==0,mode+" observes the real inline consumer return before either older cancellation callback");
                if(!input.ConsumerReturned.Task.IsCompleted) return;
                Check(input.ConsumerEnteredAt<deadline&&input.ConsumerReturnedAt<deadline&&observationAt<deadline,mode+" classifies cancellation before the unchanged raw deadline actually expires");
                bool ownedDeadline=mode=="owned-deadline";
                string expected=ownedDeadline ? "deadline" : "cancelled_active";
                Check(cancellationAtObservation==(mode!="unrelated-oce"),mode+" distinguishes original-owner cancellation from unrelated OperationCanceledException");
                Check(ownedDeadline ? remainingAtObservation==0 : remainingAtObservation>0,mode+" reports deadline ownership without depending on the deferred bridge callback");
                Check(observed!=null&&observed.ErrorCode==expected&&observed.ErrorStage=="response_stream"&&observed.ErrorCause!=null&&observed.ErrorCause.Type=="System.OperationCanceledException"&&observed.ErrorCause.HResult==input.Failure.HResult,mode+" publishes the original read cause with the correct cancellation class before older callbacks");
                await Task.WhenAny(bridge.Completion,Task.Delay(originalClockBudget()));
                Check(bridge.Completion.IsCompleted,mode+" physically completes its original owner within the unchanged raw-clock budget");
                if(!bridge.Completion.IsCompleted) return;
                await pending;
                var proof=bridge.GetProof();
                Check(proof.Retired&&proof.Completed&&!proof.Success&&handler.Disposed&&input.Disposed&&proof.Responses==0&&proof.Models==0,mode+" retires owned resources without authorizing a partial response");
                Check(proof.ErrorCode==expected&&proof.ErrorStage=="response_stream"&&proof.ErrorCause!=null&&proof.ErrorCause.Type=="System.OperationCanceledException"&&proof.ErrorCause.HResult==input.Failure.HResult,mode+" retains the original typed primary cause through final cleanup");
                Check(bridge.DeadlineTimestamp==deadline&&bridge.FailureToken.IsCancellationRequested&&proof.CleanupFailures.Length==0,mode+" preserves the immutable deadline and original fatal signal without cleanup faults");
            } finally {
                bridge.Close();await bridge.Completion;
                if(pending!=null) await pending;
                olderCallback.Dispose();input.Dispose();
            }
        }

        static async Task FinalCleanupDeadline(string mode)
        {
            bool late=mode!="timely",prior=mode=="prior-upstream",cleanupFailure=prior||mode=="cleanup-primary";
            long deadline=System.Diagnostics.Stopwatch.GetTimestamp()+System.Diagnostics.Stopwatch.Frequency*2;
            CancellationTokenSource scheduled=null;int requestedDelay=0;
            bool cleanupEntered=false,enteredBeforeDeadline=false,timerCanceledDuringCleanup=false;
            long cleanupExit=0;
            var upstreamFailure=new HttpRequestException("synthetic-upstream",new IOException("synthetic-inner"));
            var handler=new Upstream {SendFailure=prior ? upstreamFailure : null,DisposeFailure=cleanupFailure};
            handler.DuringDispose=()=>{
                cleanupEntered=true;enteredBeforeDeadline=System.Diagnostics.Stopwatch.GetTimestamp()<deadline;
                // Withhold only this fixture's timer; the owned cleanup crosses the
                // actual original clock condition, not an assumed scheduling delay.
                if(late) SpinWait.SpinUntil(()=>System.Diagnostics.Stopwatch.GetTimestamp()>=deadline);
                cleanupExit=System.Diagnostics.Stopwatch.GetTimestamp();
                timerCanceledDuringCleanup=scheduled.IsCancellationRequested;
            };
            var bridge=new GauntletTransport.Bridge("prompt",deadline,handler,null,(owner,remaining)=>{
                scheduled=owner;requestedDelay=remaining;
            });
            try {
                await Exchange(bridge,Request(bridge,Payload("prompt")));
                if(!prior) bridge.FinishClient();
                await bridge.Completion;
                var proof=bridge.GetProof();
                Check(scheduled!=null&&requestedDelay>0&&requestedDelay<=2000,"final cleanup "+mode+" schedules only the original owner and remaining budget");
                Check(cleanupEntered&&enteredBeforeDeadline,"final cleanup "+mode+" enters owned disposal before the original deadline");
                Check(late ? cleanupExit>=deadline&&bridge.RemainingMilliseconds==0 : cleanupExit<deadline,"final cleanup "+mode+" measures actual original-clock completion");
                Check(!timerCanceledDuringCleanup,"final cleanup "+mode+" crosses cleanup without a deadline callback");
                Check(bridge.Completion.IsCompleted&&handler.Disposed&&proof.Retired==!cleanupFailure&&proof.Completed==!cleanupFailure,"final cleanup "+mode+" preserves physical retirement separately from acceptance");
                Check(proof.Success==(mode=="timely"),"final cleanup "+mode+" accepts only timely successful cleanup");
                Check(proof.Responses==(prior ? 0 : 1)&&proof.Models==0,"final cleanup "+mode+" preserves original validated response accounting");
                Check(bridge.DeadlineTimestamp==deadline,"final cleanup "+mode+" cannot restart or move the original deadline");
                if(prior) {
                    Check(proof.ErrorCode=="upstream_io"&&proof.ErrorStage=="upstream"&&proof.ErrorCause!=null&&proof.ErrorCause.Type=="System.Net.Http.HttpRequestException"&&proof.ErrorCause.HResult==upstreamFailure.HResult&&proof.ErrorCause.Inner!=null&&proof.ErrorCause.Inner.Type=="System.IO.IOException"&&proof.ErrorCause.Inner.HResult==upstreamFailure.InnerException.HResult,"final cleanup prior-upstream retains the original typed primary and inner cause after deadline");
                    Check(proof.CleanupFailures.Length==1&&proof.CleanupFailures[0].Stage=="cleanup_http"&&proof.CleanupFailures[0].Cause!=null&&proof.CleanupFailures[0].Cause.Type=="System.IO.IOException","final cleanup prior-upstream retains the distinct cleanup secondary");
                } else if(cleanupFailure) {
                    Check(proof.ErrorCode=="cleanup"&&proof.ErrorStage=="cleanup_http"&&proof.ErrorCause!=null&&proof.ErrorCause.Type=="System.IO.IOException","final cleanup cleanup-primary retains its original cleanup cause after deadline");
                    Check(proof.CleanupFailures.Length==1&&proof.CleanupFailures[0].Stage=="cleanup_http"&&proof.CleanupFailures[0].Cause!=null&&proof.CleanupFailures[0].Cause.Type=="System.IO.IOException","final cleanup cleanup-primary keeps bounded cleanup evidence");
                } else {
                    Check(mode=="timely" ? proof.ErrorCode=="" : proof.ErrorCode=="deadline"&&proof.ErrorStage=="cleanup_deadline","final cleanup "+mode+" applies the final original-clock acceptance gate");
                    if(late) Check(bridge.FailureToken.IsCancellationRequested,"final cleanup late notifies the original owner before disposing the failure signal");
                }
            } finally {bridge.Close();await bridge.Completion;}
        }

        static void NativeLeaseReplacementSafety()
        {
            byte[] marker=Encoding.ASCII.GetBytes("replacement-owned-by-regression\n");
            FileStream replacement=null;string replacementPath=null;
            bool originalNameVacant=false,replacementPresentBeforeReturn=false,replacementPreserved=false;
            try {
                var lease=new NativeLease(path=>{
                    replacementPath=path;originalNameVacant=!File.Exists(path);
                    replacement=new FileStream(path,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.ReadWrite|FileShare.Delete,4096,FileOptions.DeleteOnClose);
                    replacement.Write(marker,0,marker.Length);replacement.Flush();
                    replacementPresentBeforeReturn=File.Exists(path);
                });
                lease.Dispose();
                Check(originalNameVacant,"lease replacement callback observes the original name vacant after its owned handle closes");
                Check(replacementPresentBeforeReturn,"lease replacement exists before original Dispose returns from its callback");
                if(File.Exists(replacementPath)) {
                    FileStream reader=null;
                    try {reader=new FileStream(replacementPath,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);}
                    catch(IOException) {replacementPreserved=false;}
                    catch(UnauthorizedAccessException) {replacementPreserved=false;}
                    if(reader!=null) using(reader) {
                        byte[] observed=new byte[marker.Length];int count=0;
                        while(count<observed.Length) {int n=reader.Read(observed,count,observed.Length-count);if(n==0) break;count+=n;}
                        replacementPreserved=count==marker.Length&&reader.Length==marker.Length&&observed.SequenceEqual(marker);
                    }
                }
                Check(replacementPreserved,"original lease Dispose preserves the replacement name and exact replacement bytes");
            } finally {if(replacement!=null) replacement.Dispose();}
            Check(replacementPath!=null&&!File.Exists(replacementPath),"replacement cleanup uses only its own DeleteOnClose handle");
        }

        public static async Task<Check[]> Run()
        {
            NativeLeaseReplacementSafety();
            foreach(string mode in new [] {"timely","late","prior-upstream","cleanup-primary"}) await FinalCleanupDeadline(mode);
            foreach(string mode in new [] {"owned-deadline","explicit-close","unrelated-oce"}) await CancellationCallbackOrder(mode);
            await ProbeNativeNoDrain();
            await RequestCountBoundary();
            await AuthSequence("catalog fallback to inference",new [] {"G401","P200"},true,1,0,false,false,"");
            await AuthSequence("catalog retry then inference",new [] {"G401","G200","P200"},true,1,1,false,false,"");
            await AuthSequence("response retry",new [] {"P401","P200"},true,1,0,false,false,"");
            await AuthSequence("repeated bounded recovery",new [] {"G401","G401","P401","P200"},true,1,0,false,false,"");
            await AuthSequence("catalog cannot clear later response challenge",new [] {"P200","P401","G200"},false,1,1,false,true,"auth_challenge_unresolved");
            await AuthSequence("old inference cannot clear later catalog challenge",new [] {"P200","G401"},false,1,0,true,false,"auth_challenge_unresolved");
            await AuthSequence("unrecovered response",new [] {"P401"},false,0,0,false,true,"auth_challenge_unresolved");
            await AuthSequence("unrecovered catalog",new [] {"G401"},false,0,0,true,false,"auth_challenge_unresolved");
            await AuthSequence("eight unrecovered responses",Enumerable.Repeat("P401",8).ToArray(),false,0,0,false,true,"auth_challenge_unresolved");
            await AuthSequence("eight unrecovered catalogs",Enumerable.Repeat("G401",8).ToArray(),false,0,0,true,false,"auth_challenge_unresolved");
            await AuthSequence("last-slot recovery",Enumerable.Repeat("G401",7).Concat(new [] {"P200"}).ToArray(),true,1,0,false,false,"");
            await AuthSequence("deadline during recovery",new [] {"P401"},false,0,0,false,true,"deadline",timeout:true);
            await AuthSequence("fatal malformed response never rehabilitated",new [] {"P200","P401","P200bad"},false,1,0,false,true,"sse_incomplete");
            await AuthSequence("fatal malformed catalog never rehabilitated",new [] {"P200","G401","G200bad"},false,1,0,true,false,"catalog_json");
            await AuthSequence("other statuses remain fatal",new [] {"P401","P403"},false,0,0,false,true,"upstream_status");
            foreach(bool catalogChallenge in new [] {false,true}) {
                var hostile=new HostileChallengeContent();hostile.Headers.ContentEncoding.Add("zstd");
                var challengeHandler=new Upstream {Status=HttpStatusCode.Unauthorized,ResponseOverride=hostile,MediaType="text/html",DeclaredLength=long.MaxValue};
                challengeHandler.ReplyHeaders["WWW-Authenticate"]="Bearer secret-upstream-header";
                challengeHandler.ReplyHeaders["Set-Cookie"]="secret-upstream-cookie";
                challengeHandler.ReplyHeaders["X-Private-Metadata"]="secret-upstream-header";
                var challengeBridge=new GauntletTransport.Bridge("prompt",3000,challengeHandler);
                byte[] challengeReply=await Exchange(challengeBridge,Request(challengeBridge,catalogChallenge ? "" : AuthPayload(),catalogChallenge ? "GET" : "POST",catalogChallenge ? "/backend-api/codex/models" : "/backend-api/codex/responses"));
                string local=Encoding.UTF8.GetString(challengeReply);bool staticJson=false;
                if(local.StartsWith("HTTP/1.1 401 ",StringComparison.Ordinal)) {
                    using(var parsed=JsonDocument.Parse(BodyBytes(challengeReply))) staticJson=parsed.RootElement.GetProperty("error").GetProperty("code").GetString()=="unauthorized";
                }
                string lengthLine=local.Split(new [] {"\r\n"},StringSplitOptions.None).FirstOrDefault(line=>line.StartsWith("Content-Length: ",StringComparison.Ordinal));
                Check(staticJson&&BodyBytes(challengeReply).Length<=256&&lengthLine=="Content-Length: "+BodyBytes(challengeReply).Length&&local.Contains("Content-Type: application/json\r\n")&&local.Contains("Connection: close\r\n")&&local.Contains("Cache-Control: no-store\r\n")&&!local.Contains("secret-")&&!local.Contains("WWW-Authenticate:")&&!local.Contains("Set-Cookie:")&&!local.Contains("Location:")&&hostile.ReadAttempts==0&&challengeBridge.GetProof().Responses==0&&challengeBridge.GetProof().Models==0,"genuine "+(catalogChallenge ? "GET" : "POST")+"401 emits bounded static challenge without requesting hostile body or headers");
                challengeHandler.ResponseOverride=null;challengeHandler.Status=HttpStatusCode.OK;challengeHandler.MediaType="canonical";challengeHandler.DeclaredLength=null;challengeHandler.ReplyHeaders.Clear();
                bool recovered=true;try {await Exchange(challengeBridge,Request(challengeBridge,AuthPayload()));}catch(SocketException) {recovered=false;}
                await Retire(challengeBridge);
                Check(recovered&&challengeBridge.GetProof().Success&&hostile.ReadAttempts==0&&!JsonSerializer.Serialize(challengeBridge.GetProof()).Contains("secret-"),"static challenge can recover without body/header material in proof "+catalogChallenge);
            }
            foreach(string badHeaders in new [] {"count","bytes","syntax"}) {
                var hostile=new HostileChallengeContent();var h=new Upstream {Status=HttpStatusCode.Unauthorized,ResponseOverride=hostile};
                if(badHeaders=="count") for(int i=0;i<65;i++) h.ReplyHeaders["x-extra-"+i]="v";
                else if(badHeaders=="bytes") h.ReplyHeaders["x-extra"]=new string('x',32769);
                else h.ReplyHeaders["x-extra"]="secret-header\ninvalid";
                var b=new GauntletTransport.Bridge("prompt",3000,h);await Exchange(b,Request(b,AuthPayload()));await Retire(b);var p=b.GetProof();
                Check(p.ErrorCode=="upstream_headers"&&!p.Success&&AuthCount(p,"ResponseAuthChallenges")==0&&AuthFlag(p,"PendingResponseAuthChallenge",false)&&hostile.ReadAttempts==0,"401 validates "+badHeaders+" header bound before status replacement");
            }
            foreach(var status in new [] {HttpStatusCode.OK,HttpStatusCode.Unauthorized})
            foreach(string field in new [] {"x-extra","Content-Encoding","Content-Length"}) {
                var hostile=new HostileChallengeContent();
                var h=new Upstream {Status=status,ResponseOverride=hostile};bool injected=false;
                string value=field=="Content-Length" ? "12\n34" : "secret-header\ninvalid";
                h.BeforeReturn=response=>{
                    var headers=field=="x-extra" ? (System.Net.Http.Headers.HttpHeaders)response.Headers : response.Content.Headers;
                    if(!headers.TryAddWithoutValidation(field,value)) throw new InvalidOperationException("fixture header injection refused");
                    System.Net.Http.Headers.HeaderStringValues raw;
                    if(!headers.NonValidated.TryGetValues(field,out raw)||raw.Count!=1||raw.Single()!=value)
                        throw new InvalidOperationException("fixture raw malformed header was not retained");
                    injected=true;
                };
                var b=new GauntletTransport.Bridge("prompt",3000,h);
                byte[] reply=await Exchange(b,Request(b,AuthPayload()));await Retire(b);var p=b.GetProof();
                string label=((int)status)+" raw "+field;
                Check(injected,label+" injection guard reached with exact unparsed LF");
                Check(p.ErrorCode=="upstream_headers"&&p.ErrorStage=="upstream"&&!p.Success,label+" rejects before typed-header processing");
                Check(p.ResponseAuthChallenges==0&&p.CatalogAuthChallenges==0&&!p.PendingResponseAuthChallenge&&!p.PendingCatalogAuthChallenge&&p.Responses==0&&p.Models==0,label+" never records challenge or completed response");
                Check(hostile.ReadAttempts==0,label+" never reads hostile body");
                Check(Encoding.ASCII.GetString(reply).StartsWith("HTTP/1.1 502 ",StringComparison.Ordinal)&&Body(reply)=="Transport request rejected.\n",label+" emits only static rejection");
                Check(p.Retired&&h.Disposed&&p.CleanupFailures.Length==0,label+" retires original transport without cleanup fault");
            }
            foreach(bool catalogRecovery in new [] {false,true}) {
                var h=new Upstream {Status=HttpStatusCode.Unauthorized};var b=new GauntletTransport.Bridge("prompt",5000,h);
                byte[] first=await Exchange(b,Request(b,catalogRecovery ? "" : AuthPayload(),catalogRecovery ? "GET" : "POST",catalogRecovery ? "/backend-api/codex/models" : "/backend-api/codex/responses"));
                if(!Encoding.UTF8.GetString(first).StartsWith("HTTP/1.1 401 ",StringComparison.Ordinal)) {Check(false,"challenge clears only after complete validated recovery EOF "+catalogRecovery);await Retire(b);continue;}
                h.Status=HttpStatusCode.OK;var delayed=new ControlledTailStream(catalogRecovery ? h.CatalogReply : h.Reply,Array.Empty<byte>());h.ResponseOverride=new StreamContent(delayed);
                var bodyPending=Exchange(b,Request(b,catalogRecovery ? "" : AuthPayload(),catalogRecovery ? "GET" : "POST",catalogRecovery ? "/backend-api/codex/models" : "/backend-api/codex/responses"));
                await delayed.AtEof.Task;
                Check(AuthFlag(b.GetProof(),catalogRecovery ? "PendingCatalogAuthChallenge" : "PendingResponseAuthChallenge",true)&&b.GetProof().Responses==0&&b.GetProof().Models==0,"terminal before recovery EOF cannot clear pending challenge "+catalogRecovery);
                delayed.Release.TrySetResult(true);await bodyPending;h.ResponseOverride=null;
                if(catalogRecovery) await Exchange(b,Request(b,AuthPayload()));
                await Retire(b);Check(b.GetProof().Success&&AuthFlag(b.GetProof(),"PendingCatalogAuthChallenge",false)&&AuthFlag(b.GetProof(),"PendingResponseAuthChallenge",false),"challenge clears only after complete validated recovery EOF "+catalogRecovery);
            }
            foreach(bool requestCleanup in new [] {false,true}) {
                using(var lease=new NativeLease()) {
                    var h=new Upstream {Status=HttpStatusCode.Unauthorized};var content=new LeasedContent(Array.Empty<byte>(),lease,true,false);
                    if(requestCleanup) h.RequestOverride=content;else h.ResponseOverride=content;
                    var b=new GauntletTransport.Bridge("prompt",3000,h);await Exchange(b,Request(b,AuthPayload()));b.Close();await b.Completion;var p=b.GetProof();
                    Check(lease.IsExclusive()&&!p.Success&&!p.Retired&&p.ErrorCode=="cleanup"&&p.CleanupFailures.Length>0&&AuthCount(p,"ResponseAuthChallenges")==1&&AuthFlag(p,"PendingResponseAuthChallenge",true),"401 "+(requestCleanup ? "request" : "response")+" disposal failure retains native custody and cannot recover");
                }
            }
            var finishChallengeHandler=new Upstream {Status=HttpStatusCode.Unauthorized};var finishChallenge=new GauntletTransport.Bridge("prompt",3000,finishChallengeHandler);
            await Exchange(finishChallenge,Request(finishChallenge,AuthPayload()));finishChallenge.FinishClient();await finishChallenge.Completion;
            Check(!finishChallenge.GetProof().Success&&finishChallenge.GetProof().ErrorCode=="auth_challenge_unresolved"&&AuthFlag(finishChallenge.GetProof(),"PendingResponseAuthChallenge",true),"graceful finish cannot erase unresolved challenge");
            var deliveryHandler=new Upstream();var deliveryBridge=new GauntletTransport.Bridge("prompt",5000,deliveryHandler);
            await Exchange(deliveryBridge,Request(deliveryBridge,AuthPayload()));
            var deliveryBody=new HostileChallengeContent();deliveryHandler.Status=HttpStatusCode.Unauthorized;deliveryHandler.ResponseOverride=deliveryBody;deliveryHandler.Stall=true;deliveryHandler.IgnoreCancellation=true;
            using(var resettingClient=new TcpClient(AddressFamily.InterNetwork)) {
                await resettingClient.ConnectAsync(IPAddress.Loopback,new Uri(deliveryBridge.Endpoint).Port);await resettingClient.GetStream().WriteAsync(Request(deliveryBridge,AuthPayload()));await deliveryHandler.SecondEntered.Task;
                resettingClient.Client.LingerState=new LingerOption(true,0);
            }
            // TCP reset delivery is platform dependent; force the owned server stream to fail
            // before releasing the stalled response, so this exercises delivery failure itself.
            var deliverySocket=(TcpClient)typeof(GauntletTransport.Bridge).GetField("active",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic).GetValue(deliveryBridge);
            deliverySocket.GetStream().Dispose();deliveryHandler.Release.TrySetResult(true);await deliveryBridge.Completion;
            var deliveryProof=deliveryBridge.GetProof();
            Check(!deliveryProof.Success&&deliveryProof.Retired&&deliveryProof.ErrorCode=="transport_io"&&deliveryProof.ErrorStage=="auth_challenge_delivery"&&deliveryProof.Responses==1&&AuthCount(deliveryProof,"ResponseAuthChallenges")==1&&AuthFlag(deliveryProof,"PendingResponseAuthChallenge",true)&&deliveryBody.ReadAttempts==0,"401 delivery failure is permanent after prior success and never reads challenge body");
            foreach(bool catalogLength in new [] {false,true}) {
                var h=new Upstream {Status=HttpStatusCode.Unauthorized};var b=new GauntletTransport.Bridge("prompt",3000,h);
                await Exchange(b,Request(b,catalogLength ? "" : AuthPayload(),catalogLength ? "GET" : "POST",catalogLength ? "/backend-api/codex/models" : "/backend-api/codex/responses"));
                h.Status=HttpStatusCode.OK;h.DeclaredLength=(catalogLength ? h.CatalogReply.Length : h.Reply.Length)+1;
                await Exchange(b,Request(b,catalogLength ? "" : AuthPayload(),catalogLength ? "GET" : "POST",catalogLength ? "/backend-api/codex/models" : "/backend-api/codex/responses"));await Retire(b);
                Check(!b.GetProof().Success&&b.GetProof().ErrorCode=="response_length"&&b.GetProof().Responses==0&&b.GetProof().Models==0&&AuthFlag(b.GetProof(),catalogLength ? "PendingCatalogAuthChallenge" : "PendingResponseAuthChallenge",true),"recovery length mismatch cannot clear pending challenge "+catalogLength);
            }
            var noEofHandler=new Upstream {Status=HttpStatusCode.Unauthorized};var noEofBridge=new GauntletTransport.Bridge("prompt",1000,noEofHandler);long noEofDeadline=noEofBridge.DeadlineTimestamp;
            await Exchange(noEofBridge,Request(noEofBridge,AuthPayload()));noEofHandler.Status=HttpStatusCode.OK;
            var noEofStream=new ControlledTailStream(noEofHandler.Reply,Array.Empty<byte>());noEofHandler.ResponseOverride=new StreamContent(noEofStream);
            var noEofReply=Exchange(noEofBridge,Request(noEofBridge,AuthPayload()));await Task.WhenAny(noEofStream.AtEof.Task,noEofBridge.Completion);await noEofBridge.Completion;await noEofReply;
            Check(noEofStream.AtEof.Task.IsCompleted&&!noEofBridge.GetProof().Success&&noEofBridge.GetProof().ErrorCode=="deadline"&&noEofBridge.GetProof().Responses==0&&AuthFlag(noEofBridge.GetProof(),"PendingResponseAuthChallenge",true)&&noEofBridge.DeadlineTimestamp==noEofDeadline,"recovery terminal without EOF retains challenge until original deadline failure");
            noEofStream.Release.TrySetResult(true);
            foreach(string variant in new [] {"missing","mixed","plain","binary"}) {
                foreach(bool catalog in new [] {false,true}) {
                    string mime=variant=="missing" ? null : variant=="mixed" ? (catalog ? "Application/JSON; charset=utf-8" : "Text/Event-Stream; charset=utf-8") : variant=="plain" ? "text/plain; charset=utf-8" : "application/octet-stream";
                    var handler=new Upstream {MediaType=mime};var bridge=new GauntletTransport.Bridge("prompt",3000,handler);
                    byte[] reply=await Exchange(bridge,Request(bridge,catalog ? "" : Payload("prompt"),catalog ? "GET" : "POST",catalog ? "/backend-api/codex/models" : "/backend-api/codex/responses"));
                    await Retire(bridge);var mimeProof=bridge.GetProof();
                    Check(mimeProof.ErrorCode==""&&mimeProof.Retired&&(catalog ? mimeProof.Models==1 : mimeProof.Responses==1&&mimeProof.Success)&&BodyBytes(reply).SequenceEqual(catalog ? handler.CatalogReply : handler.Reply),"valid "+(catalog ? "catalog" : "SSE")+" ignores advisory "+variant+" upstream MIME and preserves bytes");
                    string text=Encoding.UTF8.GetString(reply);int end=text.IndexOf("\r\n\r\n",StringComparison.Ordinal);
                    string[] headerLines=end<0 ? Array.Empty<string>() : text.Substring(0,end).Split(new [] {"\r\n"},StringSplitOptions.None);
                    Check(headerLines.Count(line=>line.StartsWith("Content-Type:",StringComparison.OrdinalIgnoreCase))==1&&headerLines.Contains("Content-Type: "+(catalog ? "application/json" : "text/event-stream")),"route emits one canonical "+(catalog ? "catalog" : "SSE")+" MIME for "+variant+" upstream metadata");
                    if(catalog) {
                        await BadResponse(variant+" MIME cannot authorize HTML catalog",Encoding.UTF8.GetBytes("<html>secret-body</html>"),catalog:true,mediaType:mime,requireBodyValidation:true);
                        await BadResponse(variant+" MIME cannot authorize truncated catalog",Encoding.UTF8.GetBytes("{\"models\":["),catalog:true,mediaType:mime,requireBodyValidation:true);
                        await BadResponse(variant+" MIME cannot authorize wrong catalog shape",Encoding.UTF8.GetBytes("{\"other\":[]}"),catalog:true,mediaType:mime,requireBodyValidation:true);
                        await BadResponse(variant+" MIME bad catalog fences previous successful response",Encoding.UTF8.GetBytes("{"),catalog:true,afterSuccess:true,mediaType:mime,requireBodyValidation:true);
                    } else {
                        await BadResponse(variant+" MIME cannot authorize HTML inference",Encoding.UTF8.GetBytes("<html>secret-body</html>"),mediaType:mime,requireBodyValidation:true);
                        await BadResponse(variant+" MIME cannot authorize plain JSON inference",Encoding.UTF8.GetBytes("{\"type\":\"response.completed\",\"response\":{\"id\":\"synthetic\"}}"),mediaType:mime,requireBodyValidation:true);
                        await BadResponse(variant+" MIME cannot authorize truncated SSE",Encoding.UTF8.GetBytes("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"synthetic\"}}\n"),mediaType:mime,requireBodyValidation:true);
                        await BadResponse(variant+" MIME cannot authorize failed SSE terminal",Encoding.UTF8.GetBytes("data: {\"type\":\"response.failed\"}\n\n"),mediaType:mime,requireBodyValidation:true);
                        await BadResponse(variant+" MIME bad SSE fences previous successful response",Array.Empty<byte>(),afterSuccess:true,mediaType:mime,requireBodyValidation:true);
                    }
                }
            }
            var absoluteConstructor=typeof(GauntletTransport.Bridge).GetConstructor(new [] {typeof(string),typeof(long)});
            Check(absoluteConstructor!=null,"bridge accepts original attempt absolute deadline without restarting clock");
            if(absoluteConstructor!=null) {
                long original=System.Diagnostics.Stopwatch.GetTimestamp()+(long)(System.Diagnostics.Stopwatch.Frequency*2m);
                await Task.Delay(30);
                var originalBridge=(GauntletTransport.Bridge)absoluteConstructor.Invoke(new object[]{"prompt",original});
                Check(originalBridge.DeadlineTimestamp==original&&originalBridge.RemainingMilliseconds<2000,"constructor retains startup-consumed original deadline");
                await Retire(originalBridge);
            }
            var codeProperty=typeof(GauntletTransport.TransportException).GetProperty("Code");
            var stageProperty=typeof(GauntletTransport.TransportException).GetProperty("Stage");
            var causeProperty=typeof(GauntletTransport.TransportException).GetProperty("Cause");
            Check(codeProperty!=null&&stageProperty!=null&&causeProperty!=null,"typed failures expose static code stage and sanitized cause");
            try {GauntletTransport.Bridge.Transform(Encoding.UTF8.GetBytes("{bad: secret-prompt}"),"prompt");Check(false,"JSON parse cause preserved safely");}
            catch(GauntletTransport.TransportException e) {
                var cause=causeProperty==null ? null : causeProperty.GetValue(e);
                string encoded=JsonSerializer.Serialize(cause);
                Check(codeProperty!=null&&(string)codeProperty.GetValue(e)=="json_parse"&&cause!=null&&!encoded.Contains("secret-prompt")&&!encoded.Contains("StackTrace")&&!encoded.Contains("Message")&&e.InnerException==null,"JSON parse cause preserved safely");
            }
            var boundedType=typeof(GauntletTransport.Bridge).Assembly.GetType("GauntletTransport.BoundedBuffer");
            Check(boundedType!=null,"output retention uses fixed-capacity bounded buffer");
            if(boundedType!=null) {
                var bounded=(Stream)Activator.CreateInstance(boundedType,System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic,null,new object[]{8,"test_limit","transform"},null);
                bounded.Write(new byte[8],0,8); bool rejected=false;
                try {bounded.WriteByte(1);}catch(GauntletTransport.TransportException){rejected=true;}
                Check(rejected&&bounded.Length==8,"bounded stream rejects first overflowing byte before retention");bounded.Dispose();
            }
            string repeatedMetadata="{\"model\":\"gpt-6.1-sol\",\"stream\":true,\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":"+JsonSerializer.Serialize(new string('a',1000000))+",\"metadata\":"+JsonSerializer.Serialize(new string('m',900000))+"}]}]}";
            try {GauntletTransport.Bridge.Transform(Encoding.UTF8.GetBytes(repeatedMetadata),new string('a',1000000));Check(false,"repeated metadata expansion fails within output buffer limit");}
            catch(GauntletTransport.TransportException e) {Check(codeProperty!=null&&(string)codeProperty.GetValue(e)=="transform_output_limit","repeated metadata expansion fails within output buffer limit");}
            await BadResponse("empty SSE cannot count as a completed response",Array.Empty<byte>());
            await BadResponse("unterminated terminal event rejected",Encoding.UTF8.GetBytes("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n"));
            await BadResponse("nonterminal SSE EOF rejected",Encoding.UTF8.GetBytes("data: {\"type\":\"response.created\"}\n\n"));
            await BadResponse("failed terminal SSE rejected",Encoding.UTF8.GetBytes("data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\"}}\n\n"));
            await BadResponse("incomplete terminal SSE rejected",Encoding.UTF8.GetBytes("data: {\"type\":\"response.incomplete\"}\n\n"));
            await BadResponse("declared SSE length mismatch rejected",new Upstream().Reply,declared:9999);
            await BadResponse("empty catalog EOF rejected",Array.Empty<byte>(),catalog:true);
            await BadResponse("truncated catalog JSON rejected",Encoding.UTF8.GetBytes("{\"models\":["),catalog:true);
            await BadResponse("catalog shape requires models array",Encoding.UTF8.GetBytes("{\"other\":[]}"),catalog:true);
            await BadResponse("catalog duplicate keys rejected",Encoding.UTF8.GetBytes("{\"models\":[],\"models\":[]}"),catalog:true);
            await BadResponse("bad later SSE fences previous successful proof",Array.Empty<byte>(),afterSuccess:true);
            await BadResponse("bad later catalog fences previous successful proof",Encoding.UTF8.GetBytes("{"),catalog:true,afterSuccess:true);
            await BadResponse("completed SSE requires terminal response ID",Encoding.UTF8.GetBytes("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"));
            await BadResponse("completed SSE requires successful terminal status",Encoding.UTF8.GetBytes("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"synthetic\",\"status\":\"failed\"}}\n\n"));
            await BadResponse("duplicate completed event rejected",Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(new Upstream().Reply)+Encoding.UTF8.GetString(new Upstream().Reply)));
            await BadResponse("data after completed event rejected",Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(new Upstream().Reply)+"data: {\"type\":\"response.created\"}\n\n"));
            await BadResponse("mismatched created and completed IDs rejected",Encoding.UTF8.GetBytes("data: {\"type\":\"response.created\",\"response\":{\"id\":\"different\"}}\n\n"+Encoding.UTF8.GetString(new Upstream().Reply)));
            await BadResponse("malformed SSE JSON rejected",Encoding.UTF8.GetBytes("data: {bad-secret}\n\n"));
            await BadResponse("duplicate SSE JSON keys rejected",Encoding.UTF8.GetBytes("data: {\"type\":\"response.created\",\"type\":\"response.completed\"}\n\n"));
            await BadResponse("invalid SSE UTF8 rejected",new byte[]{100,97,116,97,58,32,0xff,10,10});
            await BadResponse("malformed long SSE data cannot prove completion",Encoding.UTF8.GetBytes("data: "+new string('x',262144)+"\n\n"));
            await BadResponse("catalog declared length mismatch rejected",Encoding.UTF8.GetBytes("{\"models\":[]}"),catalog:true,declared:100);
            try {GauntletTransport.Bridge.Transform(Encoding.UTF8.GetBytes("{\"input\":[],\"many\":["+string.Join(",",Enumerable.Repeat("0",65536))+"]}"),"prompt");Check(false,"token admission rejects structural expansion before DOM");}
            catch(GauntletTransport.TransportException e) {Check(codeProperty!=null&&(string)codeProperty.GetValue(e)=="json_token_limit","token admission rejects structural expansion before DOM");}
            var wrappedHandler=new Upstream {SendFailure=new HttpRequestException("secret-url",new IOException("secret-header",new SocketException(10061))),DisposeFailure=true};
            var wrappedBridge=new GauntletTransport.Bridge("prompt",3000,wrappedHandler);
            await Exchange(wrappedBridge,Request(wrappedBridge,Payload("prompt")));wrappedBridge.Close();await wrappedBridge.Completion;
            string wrappedProof=JsonSerializer.Serialize(wrappedBridge.GetProof());
            Check(wrappedProof.Contains("SocketException")&&wrappedProof.Contains("10061")&&!wrappedProof.Contains("secret-")&&!wrappedProof.Contains("StackTrace")&&!wrappedProof.Contains("Message"),"bounded sanitized inner chain preserves socket cause without raw failure text");
            Check(wrappedProof.Contains("CleanupFailures")&&wrappedProof.Contains("cleanup_http")&&!wrappedBridge.GetProof().Retired&&!wrappedBridge.GetProof().Success,"cleanup secondary is preserved separately from primary upstream failure");
            var constructionHandler=new Upstream {DisposeFailure=true};
            try {new GauntletTransport.Bridge("prompt",System.Diagnostics.Stopwatch.GetTimestamp()-1L,constructionHandler);Check(false,"faulted constructor retains nonpublic unresolved resource custody");}
            catch(GauntletTransport.TransportException failure) {
                var anchorProperty=typeof(GauntletTransport.TransportException).GetProperty("UnresolvedOwner",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic);
                object anchor=anchorProperty==null ? null : anchorProperty.GetValue(failure);
                object retainedHandler=anchor==null ? null : anchor.GetType().GetProperty("Handler",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic).GetValue(anchor);
                object retainedBridge=anchor==null ? null : anchor.GetType().GetProperty("Bridge",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic).GetValue(anchor);
                Check(anchor!=null&&retainedBridge!=null&&object.ReferenceEquals(retainedHandler,constructionHandler)&&typeof(GauntletTransport.TransportException).GetProperty("UnresolvedOwner")==null&&failure.CleanupFailures.Length==1,"faulted constructor retains nonpublic unresolved resource custody");
            }
            var largeEvent=new Upstream();largeEvent.Reply=Encoding.UTF8.GetBytes("data: "+JsonSerializer.Serialize(new {type="response.completed",response=new {id="synthetic",status="completed",output=new [] {new {type="reasoning",encrypted_content=new string('x',1200000)}}}})+"\n\n: heartbeat\n\n");
            var largeEventBridge=new GauntletTransport.Bridge("prompt",10000,largeEvent);
            byte[] largeEventReply=await Exchange(largeEventBridge,Request(largeEventBridge,Payload("prompt")));await Retire(largeEventBridge);
            Check(largeEventBridge.GetProof().Success&&BodyBytes(largeEventReply).SequenceEqual(largeEvent.Reply),"response-derived bound preserves large encrypted reasoning terminal and trailing heartbeat");
            var optionalStatus=new Upstream {Reply=Encoding.UTF8.GetBytes("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"synthetic\"}}\n\n")};
            var optionalStatusBridge=new GauntletTransport.Bridge("prompt",3000,optionalStatus);await Exchange(optionalStatusBridge,Request(optionalStatusBridge,Payload("prompt")));await Retire(optionalStatusBridge);
            Check(optionalStatusBridge.GetProof().Success,"pinned response.completed protocol permits omitted optional status");
            var metadataEvent=new Upstream {Reply=Encoding.UTF8.GetBytes("event: ignored-name\ndata: {\"type\":\"codex.response.metadata\",\"future\":true}\n\ndata: {\"type\":\"responsesapi.websocket_timing\"}\n\nevent: message\n"+Encoding.UTF8.GetString(optionalStatus.Reply))};
            var metadataEventBridge=new GauntletTransport.Bridge("prompt",3000,metadataEvent);await Exchange(metadataEventBridge,Request(metadataEventBridge,Payload("prompt")));await Retire(metadataEventBridge);
            Check(metadataEventBridge.GetProof().Success,"pinned JSON type is authoritative while unknown metadata events and event names are preserved");
            foreach(string phase in new [] {"stream","response","request","primary-and-response"}) {
                using(var lease=new NativeLease()) {
                    var handler=new Upstream();byte[] reply=phase=="primary-and-response" ? Encoding.UTF8.GetBytes("data: {\"type\":\"response.created\"}\n\n") : handler.Reply;
                    var content=new LeasedContent(reply,lease,phase!="stream",phase=="stream");
                    if(phase=="request") handler.RequestOverride=content;else handler.ResponseOverride=content;
                    var ownedDisposal=new GauntletTransport.Bridge("prompt",3000,handler);
                    await Exchange(ownedDisposal,Request(ownedDisposal,Payload("prompt")));ownedDisposal.Close();await ownedDisposal.Completion;
                    var disposalProof=ownedDisposal.GetProof();
                    string expectedPrimary=phase=="primary-and-response" ? "sse_incomplete" : "cleanup";
                    Check(lease.IsExclusive()&&!disposalProof.Retired&&!disposalProof.Completed&&!disposalProof.Success&&disposalProof.ErrorCode==expectedPrimary&&disposalProof.CleanupFailures.Length>0,"native exclusive "+phase+" disposal failure retains custody and fences physical retirement");
                    Check(!JsonSerializer.Serialize(disposalProof).Contains("secret-"),phase+" disposer fault remains sanitized");
                }
            }
            var finishMethod=typeof(GauntletTransport.Bridge).GetMethod("FinishClient");
            Check(finishMethod!=null,"graceful client retirement can drain active validated upstream EOF");
            if(finishMethod!=null) {
                foreach(string mode in new [] {"delivered-pending","coalesced-tail","undelivered","write-failure","deadline","tail-in-flight"}) await TerminalDeliveryFinish(mode);
                foreach(string mode in new [] {"tail-before-finish","tail-before-deadline","tail-before-close"}) await TailFailureBeforeRetirement(mode);
                foreach(string mode in new [] {"valid-heartbeat","bad-trailer","bad-length","deadline"}) {
                    var handler=new Upstream();byte[] trailer=Encoding.UTF8.GetBytes(mode=="bad-trailer" ? "data: {\"type\":\"response.created\"}\n\n" : mode=="valid-heartbeat" ? ": heartbeat\n\n" : "");
                    var controlled=new ControlledTailStream(handler.Reply,trailer);handler.ResponseOverride=new StreamContent(controlled);
                    if(mode=="bad-length") handler.DeclaredLength=handler.Reply.Length+1;
                    var finishing=new GauntletTransport.Bridge("prompt",mode=="deadline" ? 500 : 3000,handler);
                    using(var child=new TcpClient(AddressFamily.InterNetwork)) {
                        await child.ConnectAsync(IPAddress.Loopback,new Uri(finishing.Endpoint).Port);await child.GetStream().WriteAsync(Request(finishing,Payload("prompt")));
                        await controlled.AtEof.Task;
                        var received=new MemoryStream();byte[] read=new byte[4096];
                        while(!Encoding.UTF8.GetString(received.ToArray()).Contains(Encoding.UTF8.GetString(handler.Reply))) {int n=await child.GetStream().ReadAsync(read);if(n==0) break;received.Write(read,0,n);}
                    }
                    long original=finishing.DeadlineTimestamp;finishMethod.Invoke(finishing,null);
                    if(mode!="deadline") controlled.Release.TrySetResult(true);
                    await Task.WhenAny(finishing.Completion,Task.Delay(4000));
                    var p=finishing.GetProof();
                    Check(finishing.Completion.IsCompleted&&p.Retired&&finishing.DeadlineTimestamp==original&&(mode=="valid-heartbeat" ? p.Success&&p.Responses==1 : !p.Success&&p.Responses==0&&p.ErrorCode==(mode=="bad-trailer" ? "sse_after_terminal" : mode=="bad-length" ? "response_length" : "deadline")),"graceful finish "+mode+" validates same-deadline tail after retired consumer");
                    controlled.Release.TrySetResult(true);await Retire(finishing);
                }
                var earlyHandler=new Upstream();var earlyFinish=new GauntletTransport.Bridge("prompt",3000,earlyHandler);
                await Exchange(earlyFinish,Request(earlyFinish,Payload("prompt")));earlyHandler.Stall=true;
                var earlyPending=Exchange(earlyFinish,Request(earlyFinish,Payload("prompt")));await earlyHandler.SecondEntered.Task;
                finishMethod.Invoke(earlyFinish,null);await earlyFinish.Completion;await earlyPending;
                Check(!earlyFinish.GetProof().Success&&earlyFinish.GetProof().ErrorCode=="client_finish_early"&&earlyFinish.GetProof().Responses==1,"finish before second terminal cannot reuse previous completed proof");await Retire(earlyFinish);
                var idleFinish=new GauntletTransport.Bridge("prompt",3000,new Upstream());await Exchange(idleFinish,Request(idleFinish,Payload("prompt")));finishMethod.Invoke(idleFinish,null);await idleFinish.Completion;
                Check(idleFinish.GetProof().Success&&idleFinish.GetProof().ErrorCode=="","idle graceful listener retirement preserves verified completed response");await Retire(idleFinish);
            }
            var deadlineProperty=typeof(GauntletTransport.Bridge).GetProperty("DeadlineTimestamp");
            Check(deadlineProperty!=null,"bridge exports its original absolute monotonic deadline");
            if(deadlineProperty!=null) {
                long before=System.Diagnostics.Stopwatch.GetTimestamp();
                var absolute=new GauntletTransport.Bridge("prompt",2000,new Upstream());
                long after=System.Diagnostics.Stopwatch.GetTimestamp();
                long deadline=(long)deadlineProperty.GetValue(absolute);
                long duration=(long)(2m*System.Diagnostics.Stopwatch.Frequency);
                Check(deadline>=before+duration&&deadline<=after+duration,"absolute deadline belongs to construction origin and timeout");
                int initialRemaining=absolute.RemainingMilliseconds;
                await Task.Delay(30);
                long now=System.Diagnostics.Stopwatch.GetTimestamp();
                int nativeRemaining=(int)Math.Max(0m,Math.Ceiling(((decimal)deadline-now)*1000m/System.Diagnostics.Stopwatch.Frequency));
                int bridgeRemaining=absolute.RemainingMilliseconds;
                Check(Math.Abs(nativeRemaining-bridgeRemaining)<=2&&bridgeRemaining<initialRemaining,"remaining budget tracks the same native absolute deadline");
                Check((long)deadlineProperty.GetValue(absolute)==deadline,"absolute deadline remains unchanged after elapsed work");
                await Retire(absolute);
                Check((long)deadlineProperty.GetValue(absolute)==deadline,"owner close cannot move original absolute deadline");
            }
            string astral=char.ConvertFromUtf32(0x1f333);
            string sections="== REVIEW MATERIAL ==\r\nsource: complete\r\ntests: complete\r\nprior finding r1: addressed\r\n";
            string prompt=sections+new string('a',199999-sections.Length)+astral+"\r\n\"\\"+new string('b',299993);
            Check(Encoding.UTF8.GetByteCount(prompt)==500000,"complete source tests and carryover prompt reaches the exact byte-budget ceiling");
            var transformed=GauntletTransport.Bridge.Transform(Encoding.UTF8.GetBytes(Payload(prompt)),prompt);
            Check(transformed.WorkingByteCharge<=GauntletTransport.Bridge.TransformWorkingByteLimit&&transformed.WorkingByteCharge>transformed.Bytes.Length+Encoding.UTF8.GetByteCount(Payload(prompt))+prompt.Length*2L,"explicit aggregate admission includes request prompt output and transform temporaries");
            using(var parsed=JsonDocument.Parse(transformed.Bytes)) {
                var blocks=parsed.RootElement.GetProperty("input")[0].GetProperty("content");
                string joined=string.Concat(blocks.EnumerateArray().Select(x=>x.GetProperty("text").GetString()));
                Check(joined==prompt && blocks.GetArrayLength()==3,"500k prompt reconstructs exactly without separators");
                Check(blocks[0].GetProperty("text").GetString().Length==199999,"split backs up before astral surrogate pair");
                Check(blocks.EnumerateArray().All(x=>x.GetProperty("text").GetString().Length<=200000),"every emitted text respects scalar-safe chunk bound");
                Check(blocks.EnumerateArray().All(x=>x.GetProperty("metadata").GetProperty("label").GetString()=="keep"),"text metadata preserved on every piece");
                Check(parsed.RootElement.GetProperty("future").GetProperty("array")[2].GetDouble()==12.5 && parsed.RootElement.GetProperty("stream").GetBoolean(),"nontext fields preserved logically");
            }
            string expectedHash=Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(prompt))).ToLowerInvariant();
            Check(transformed.PromptSha256==expectedHash && transformed.PromptSeen,"proof hash binds complete original prompt");
            string nontext="{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"prompt\"},{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,synthetic\",\"detail\":\"high\"}]}],\"n\":123456789012345678901234567890}";
            using(var preserved=JsonDocument.Parse(GauntletTransport.Bridge.Transform(Encoding.UTF8.GetBytes(nontext),"prompt").Bytes)) {
                Check(preserved.RootElement.GetProperty("input")[0].GetProperty("content")[1].GetProperty("detail").GetString()=="high" && preserved.RootElement.GetProperty("n").GetRawText()=="123456789012345678901234567890","nontext blocks and large numeric values retain logical data");
            }
            string continuation="{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"prompt\"}]},{\"type\":\"function_call\",\"call_id\":\"synthetic\",\"name\":\"test\",\"arguments\":\"{}\"},{\"type\":\"function_call_output\",\"call_id\":\"synthetic\",\"output\":\"fixture\"},{\"type\":\"reasoning\",\"summary\":[]}]}";
            try {using(var preserved=JsonDocument.Parse(GauntletTransport.Bridge.Transform(Encoding.UTF8.GetBytes(continuation),"prompt").Bytes)) Check(preserved.RootElement.GetProperty("input")[2].GetProperty("output").GetString()=="fixture","tool continuation and reasoning inputs preserved with original user prompt");} catch(GauntletTransport.TransportException) {Check(false,"tool continuation and reasoning inputs preserved with original user prompt");}
            Reject("{\"input\":[{\"type\":\"unexpected\"}]}","prompt","unknown nonmessage shape rejected");
            string fullProtocol=continuation.Replace("\"summary\":[]","\"summary\":[],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"synthetic\"}]");
            fullProtocol=fullProtocol.Substring(0,fullProtocol.Length-2)+",{\"type\":\"tool_search_call\",\"execution\":\"client\",\"arguments\":{}},{\"type\":\"mcp_tool_call_output\",\"call_id\":\"fake\",\"output\":\"ok\"}]}";
            try {GauntletTransport.Bridge.Transform(Encoding.UTF8.GetBytes(fullProtocol),"prompt");Check(true,"pinned reasoning content and tool search MCP output shapes retained");} catch(GauntletTransport.TransportException) {Check(false,"pinned reasoning content and tool search MCP output shapes retained");}
            Reject(continuation.Replace("\"type\":\"reasoning\",\"summary\":[]","\"type\":\"compaction\",\"encrypted_content\":\"synthetic\""),"prompt","compaction cannot conceal complete review history");
            Reject(continuation.Replace("\"type\":\"reasoning\",\"summary\":[]","\"type\":\"computer_call\""),"prompt","unrecognized guessed protocol variants fail closed");
            var empty=GauntletTransport.Bridge.Transform(Encoding.UTF8.GetBytes(Payload("")),"");
            Check(empty.PieceCount==1 && empty.MaximumPieceCharacters==0,"empty input_text retained");
            string exact=new string('x',200000);
            Check(GauntletTransport.Bridge.Transform(Encoding.UTF8.GetBytes(Payload(exact)),exact).PieceCount==1,"exact chunk boundary stays one block");
            Reject(Payload("prefix"),"missing","omitted composed prompt rejected");
            Reject("{\"input\":[],\"input\":[]}","prompt","duplicate root keys rejected");
            Reject("{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"prompt\",\"x\":{\"a\":1,\"a\":2}}]}]}","prompt","nested duplicate keys rejected");
            Reject("{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"\\uD800\"}]}]}","prompt","unpaired escaped surrogate rejected");
            Reject("{\"input\":[{\"role\":\"user\",\"content\":\"prompt\"}]}","prompt","unexpected content shape rejected");
            Reject("{\"input\":[{\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"prompt\"}]}]}","prompt","developer prompt does not satisfy user completeness");
            Reject("{\"input\":[],\"deep\":"+new string('[',65)+"0"+new string(']',65)+"}","prompt","JSON depth bound enforced");
            try { GauntletTransport.Bridge.Transform(new byte[]{0x7b,0xc0,0xaf,0x7d},"prompt"); Check(false,"malformed UTF8 rejected"); } catch(GauntletTransport.TransportException) { Check(true,"malformed UTF8 rejected"); }

            var upstream=new Upstream(); var good=new GauntletTransport.Bridge("prompt",5000,upstream);
            try {
                byte[] reply=await Exchange(good,Request(good,Payload("prompt"),extra:"OpenAI-Beta: responses=experimental\r\nversion: 0.162.0-alpha.17.2\r\nsession_id: synthetic-session\r\noriginator: codex_cli_rs\r\n"));
                Check(Body(reply)==Encoding.UTF8.GetString(upstream.Reply),"successful SSE bytes remain byte-identical including CRLF");
                var forwarded=upstream.Requests[0];
                Check(forwarded.RequestUri==new Uri("https://chatgpt.com/backend-api/codex/responses"),"upstream destination fixed independently of local URI");
                using(var wire=JsonDocument.Parse(upstream.Bodies[0])) Check(wire.RootElement.GetProperty("model").GetString()=="gpt-6.1-sol"&&wire.RootElement.GetProperty("stream").GetBoolean(),"certified model and streaming profile reach upstream unchanged");
                Check(forwarded.Headers.Authorization.ToString()=="Bearer synthetic-token" && forwarded.Headers.GetValues("ChatGPT-Account-Id").Single()=="synthetic-account","bearer and account forwarded");
                Check(forwarded.Headers.Contains("OpenAI-Beta") && forwarded.Headers.Contains("version") && forwarded.Headers.Contains("session_id") && forwarded.Headers.Contains("originator"),"required beta version session origin headers forwarded");
                Check(!forwarded.Headers.Contains("X-Gauntlet-Capability") && forwarded.Headers.Host==null,"local capability and Host stripped");
                byte[] models=await Exchange(good,Request(good,"","GET","/backend-api/codex/models?client_version=0.162.0-alpha.17.2"));
                Check(upstream.Requests[1].RequestUri==new Uri("https://chatgpt.com/backend-api/codex/models?client_version=0.162.0-alpha.17.2"),"models path and validated client version forwarded");
            } finally { await Retire(good); }
            var proof=good.GetProof();
            Check(proof.Success && proof.PromptSeen && proof.Responses==1 && proof.Models==1,"acceptance proof requires verified Responses and worker retirement");
            Check(proof.RequestBytes>0 && proof.ResponseBytes>0,"proof records bounded byte counts");
            Check(!JsonSerializer.Serialize(proof).Contains("synthetic-token") && !JsonSerializer.Serialize(proof).Contains(good.GetCapability()),"proof contains no fake credential or capability");
            var bytesHandler=new Upstream(); bytesHandler.Reply=Encoding.UTF8.GetBytes(": unicode 🌳\r\n"+Encoding.UTF8.GetString(bytesHandler.Reply).Replace("\n","\r\n"));
            var byteBridge=new GauntletTransport.Bridge("prompt",2000,bytesHandler);
            try {Check(BodyBytes(await Exchange(byteBridge,Request(byteBridge,Payload("prompt")))).SequenceEqual(bytesHandler.Reply),"SSE forwarding preserves every byte without UTF8 decode/reencode");} finally {await Retire(byteBridge);}

            var semantics=new Upstream();
            foreach(string h in new [] {"x-codex-turn-state","x-models-etag","openai-model","x-reasoning-included","x-request-id","x-codex-safety-buffering-enabled","x-codex-safety-buffering-faster-model","x-codex-primary-used-percent","x-codex-secondary-reset-at","x-codex-credits-has-credits"}) semantics.ReplyHeaders[h]="synthetic";
            semantics.ReplyHeaders["Set-Cookie"]="secret-cookie"; semantics.ReplyHeaders["Location"]="https://invalid.example/secret";
            var semanticBridge=new GauntletTransport.Bridge("prompt",2000,semantics);
            try {
                string r=Encoding.ASCII.GetString(await Exchange(semanticBridge,Request(semanticBridge,Payload("prompt"),extra:"x-codex-turn-state: state\r\nx-oai-attestation: synthetic\r\nx-codex-parent-thread-id: parent\r\n")));
                Check(semantics.Requests.Count==1 && semantics.Requests[0].Headers.Contains("x-oai-attestation") && semantics.Requests[0].Headers.Contains("x-codex-turn-state"),"attestation turn-state parent metadata forwarded");
                Check(semantics.ReplyHeaders.Where(h=>h.Key.StartsWith("x-",StringComparison.Ordinal)||h.Key=="openai-model").All(h=>r.IndexOf(h.Key+": synthetic\r\n",StringComparison.OrdinalIgnoreCase)>=0),"reviewed response model safety rate and turn metadata preserved");
                Check(!r.Contains("secret-cookie")&&!r.Contains("Location:"),"response cookies and redirect destinations stripped");
            } finally {await Retire(semanticBridge);}

            await Bad("missing capability rejected",b=>Request(b,Payload("prompt"),capability:false));
            await Bad("wrong capability rejected",b=>Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(Request(b,Payload("prompt"))).Replace(b.GetCapability(),new string('0',64))));
            await Bad("nonliteral host rejected",b=>Request(b,Payload("prompt"),host:"localhost:"+new Uri(b.Endpoint).Port));
            await Bad("unknown route rejected",b=>Request(b,Payload("prompt"),path:"/backend-api/codex/analytics-events/events"));
            await Bad("absolute target rejected",b=>Request(b,Payload("prompt"),path:"https://chatgpt.com/backend-api/codex/responses"));
            await Bad("duplicate framing header rejected",b=>Request(b,Payload("prompt"),extra:"Content-Length: 1\r\n"));
            await Bad("chunked framing rejected",b=>Request(b,Payload("prompt"),extra:"Transfer-Encoding: chunked\r\n"));
            await Bad("compression rejected",b=>Request(b,Payload("prompt"),extra:"Content-Encoding: zstd\r\n"));
            await Bad("upgrade rejected",b=>Request(b,Payload("prompt"),extra:"Upgrade: websocket\r\n"));
            await Bad("expect rejected",b=>Request(b,Payload("prompt"),extra:"Expect: 100-continue\r\n"));
            await Bad("connection nominated auth rejected",b=>Request(b,Payload("prompt"),extra:"Connection: Authorization\r\n"));
            await Bad("API key shape refused",b=>Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(Request(b,Payload("prompt"))).Replace("Bearer synthetic-token","Bearer sk-fake")));
            await Bad("account header required",b=>Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(Request(b,Payload("prompt"))).Replace("ChatGPT-Account-Id: synthetic-account\r\n","")));
            await Bad("unknown header rejected",b=>Request(b,Payload("prompt"),extra:"X-Arbitrary-Target: secret\r\n"));
            await SubagentRequestHeader("x-openai-subagent");
            await SubagentRequestHeader("X-OpenAI-Subagent");
            await Bad("subagent metadata lookalike remains rejected",b=>Request(b,Payload("prompt"),extra:"x-openai-subagent-extra: synthetic\r\n"),expectedError:"header_policy");
            await Bad("subagent metadata cannot bypass capability",b=>Request(b,Payload("prompt"),extra:"x-openai-subagent: synthetic\r\n",capability:false));
            await Bad("subagent metadata cannot bypass route",b=>Request(b,Payload("prompt"),extra:"x-openai-subagent: synthetic\r\n",path:"/backend-api/codex/analytics-events/events"));
            await Bad("subagent metadata cannot bypass original prompt",b=>Request(b,Payload("different"),extra:"x-openai-subagent: synthetic\r\n"));
            await HeaderPolicyCause("X-Private-Name-Sentinel");
            await HeaderPolicyCause("x-private-name-sentinel");
            await HeaderPolicyCause("X-"+new string('A',4096));
            await HeaderPolicyCause("content-type",forwarding:true);
            await Bad("encoded route ambiguity rejected",b=>Request(b,Payload("prompt"),path:"/backend-api/codex/%72esponses"));
            await Bad("query injection rejected",b=>Request(b,"","GET","/backend-api/codex/models?client_version=1&target=bad"));
            await Bad("oversized client version rejected",b=>Request(b,"","GET","/backend-api/codex/models?client_version="+new string('a',129)));
            await Bad("header byte cap enforced",b=>Request(b,Payload("prompt"),extra:"User-Agent: "+new string('a',32768)+"\r\n"),allowClosed:true,expectedError:"header_limit");
            await Bad("body declared bound enforced",b=>Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(Request(b,Payload("prompt"))).Replace("Content-Length: "+Encoding.UTF8.GetByteCount(Payload("prompt")),"Content-Length: 4194305")));
            await Bad("JSON completeness rejection fails whole attempt",b=>Request(b,Payload("other")));
            await Bad("wrong inference model rejected",b=>Request(b,Payload("prompt").Replace("gpt-6.1-sol","other-model")));
            await Bad("legacy inference model rejected",b=>Request(b,Payload("prompt").Replace("gpt-6.1-sol","gpt-6-sol")));
            await Bad("missing inference model rejected",b=>Request(b,Payload("prompt").Replace("\"model\":\"gpt-6.1-sol\",","")));
            await Bad("nonstream inference rejected",b=>Request(b,Payload("prompt").Replace("\"stream\":true","\"stream\":false")));
            await Bad("missing stream flag rejected",b=>Request(b,Payload("prompt").Replace("\"stream\":true,","")));
            await Bad("regional route unsupported explicitly",b=>Request(b,Payload("prompt"),extra:"x-openai-internal-codex-residency: eu\r\n"));
            await Bad("header count cap enforced",b=>Request(b,Payload("prompt"),extra:string.Concat(Enumerable.Range(0,65).Select(i=>"x-extra-"+i+": x\r\n"))));
            await Bad("non-HTTP11 rejected",b=>Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(Request(b,Payload("prompt"))).Replace("HTTP/1.1","HTTP/1.0")));

            foreach(var status in new [] {HttpStatusCode.Redirect,HttpStatusCode.Forbidden,HttpStatusCode.InternalServerError}) {
                var h=new Upstream { Status=status, Reply=Encoding.UTF8.GetBytes("secret-upstream-error") }; var b=new GauntletTransport.Bridge("prompt",2000,h);
                try { var r=Encoding.UTF8.GetString(await Exchange(b,Request(b,Payload("prompt")))); Check(r.StartsWith("HTTP/1.1 502 ",StringComparison.Ordinal) && !r.Contains("secret-upstream-error") && !r.Contains("Location:"),"upstream "+(int)status+" refused with safe static error"); } finally { await Retire(b); }
            }
            foreach(bool catalog in new [] {false,true})
            foreach(bool afterSuccess in new [] {false,true}) {
                var h=new Upstream();var b=new GauntletTransport.Bridge("prompt",5000,h);
                long original=b.DeadlineTimestamp;
                if(afterSuccess) {
                    await Exchange(b,Request(b,AuthPayload()));
                    Check(b.GetProof().Responses==1&&b.GetProof().ErrorCode=="","partial-status control completes prior inference "+catalog);
                }
                var content=new ReplyStream(catalog ? h.CatalogReply : h.Reply,false);
                h.Status=HttpStatusCode.PartialContent;h.ResponseOverride=new StreamContent(content);
                byte[] reply=await Exchange(b,Request(b,catalog ? "" : AuthPayload(),catalog ? "GET" : "POST",catalog ? "/backend-api/codex/models" : "/backend-api/codex/responses"));
                await Retire(b);var p=b.GetProof();string label="206 "+(catalog ? "models" : "responses")+" afterSuccess="+afterSuccess;
                Check(h.Requests.Count==(afterSuccess ? 2 : 1)&&p.PromptSeen==(afterSuccess||!catalog),label+" reaches actual upstream with valid route payload");
                Check(!p.Success&&p.ErrorCode=="upstream_status"&&p.ErrorStage=="upstream"&&p.ErrorCause!=null&&p.ErrorCause.HttpStatus==206,label+" permanently rejects partial representation");
                Check(p.Responses==(afterSuccess ? 1 : 0)&&p.Models==0&&p.ResponseAuthChallenges==0&&p.CatalogAuthChallenges==0&&!p.PendingResponseAuthChallenge&&!p.PendingCatalogAuthChallenge,label+" cannot count partial or rehabilitate prior success");
                Check(content.ReadAttempts==0&&Encoding.ASCII.GetString(reply).StartsWith("HTTP/1.1 502 ",StringComparison.Ordinal)&&Body(reply)=="Transport request rejected.\n",label+" refuses before body with static error");
                Check(p.Retired&&h.Disposed&&p.CleanupFailures.Length==0&&b.FailureToken.IsCancellationRequested&&b.DeadlineTimestamp==original,label+" retains fatal signal and original physical retirement/deadline");
            }
            foreach(int size in new [] { 4194305,16777217 }) {
                var h=new Upstream { Reply=new byte[size],CatalogReply=new byte[size] }; var b=new GauntletTransport.Bridge("prompt",5000,h);
                try { await Exchange(b,Request(b,size==4194305 ? "" : Payload("prompt"),size==4194305 ? "GET" : "POST",size==4194305 ? "/backend-api/codex/models" : "/backend-api/codex/responses")); Check(b.GetProof().ErrorCode=="response_limit","upstream byte limit rejects "+size); } finally { await Retire(b); }
            }
            var incremental=new Upstream {UnknownLength=true,Reply=Encoding.ASCII.GetBytes(string.Concat(Enumerable.Repeat(":x\n\n",4194305)))}; var incrementalBridge=new GauntletTransport.Bridge("prompt",5000,incremental);
            try {await Exchange(incrementalBridge,Request(incrementalBridge,Payload("prompt"))); Check(incrementalBridge.GetProof().ErrorCode=="response_limit" && incrementalBridge.GetProof().ResponseBytes<=16777216,"actual streamed bytes capped without Content-Length");} finally {await Retire(incrementalBridge);}
            var streamStall=new Upstream {StreamStall=true}; var streamBridge=new GauntletTransport.Bridge("prompt",200,streamStall);
            var streamPending=Exchange(streamBridge,Request(streamBridge,Payload("prompt"))); await Task.WhenAny(streamBridge.Completion,Task.Delay(1500));
            bool streamCompletedAtPredicate=streamBridge.Completion.IsCompleted;
            var streamProofAtPredicate=streamCompletedAtPredicate ? streamBridge.GetProof() : null;
            bool streamDeadlinePredicate=streamCompletedAtPredicate&&streamProofAtPredicate.ErrorCode=="deadline";
            string streamFailureDiagnostics=streamDeadlinePredicate ? "" : " [diagnostic "+JsonSerializer.Serialize(new {
                CompletedAtPredicate=streamCompletedAtPredicate,
                ErrorCode=streamProofAtPredicate==null ? null : streamProofAtPredicate.ErrorCode,
                ErrorStage=streamProofAtPredicate==null ? null : streamProofAtPredicate.ErrorStage,
                ErrorCause=streamProofAtPredicate==null ? null : streamProofAtPredicate.ErrorCause,
                CompletionStatus=streamBridge.Completion.Status.ToString(),
                RemainingMilliseconds=streamBridge.RemainingMilliseconds,
                OriginalDeadline=streamBridge.DeadlineTimestamp,ObservedAt=System.Diagnostics.Stopwatch.GetTimestamp()
            })+"]";
            Check(streamDeadlinePredicate,"original deadline cancels stalled upstream stream"+streamFailureDiagnostics); await streamPending; await Retire(streamBridge);
            var maximumHandler=new Upstream();var maximum=new GauntletTransport.Bridge("prompt",5000,maximumHandler);
            try {
                for(int i=0;i<8;i++) await Exchange(maximum,Request(maximum,Payload("prompt")));
                bool refused=false;
                try {refused=(await Exchange(maximum,Request(maximum,Payload("prompt")))).Length==0;} catch(SocketException) {refused=true;}
                await Task.WhenAny(maximum.Completion,Task.Delay(1500));var maximumProof=maximum.GetProof();
                Check(refused&&maximumProof.Responses==8&&maximumProof.ErrorCode=="request_limit"&&maximumProof.ErrorStage=="request_count"&&maximum.Completion.IsCompleted&&maximumHandler.Requests.Count==8,"request cap retires listener with typed refusal before ninth upstream dispatch");
            } finally {await Retire(maximum);}
            var disconnected=new GauntletTransport.Bridge("prompt",1000,new Upstream()); using(var c=new TcpClient(AddressFamily.InterNetwork)) {await c.ConnectAsync(IPAddress.Loopback,new Uri(disconnected.Endpoint).Port); await c.GetStream().WriteAsync(Encoding.ASCII.GetBytes("POST "));}
            await Task.WhenAny(disconnected.Completion,Task.Delay(1500)); Check(disconnected.Completion.IsCompleted&&!disconnected.GetProof().Success&&disconnected.GetProof().ErrorCode=="request_incomplete","caller disconnect retires incomplete reader and fails attempt"); await Retire(disconnected);
            var idle=new GauntletTransport.Bridge("prompt",150,new Upstream());
            await Task.WhenAny(idle.Completion,Task.Delay(1500));
            Check(idle.Completion.IsCompleted && idle.GetProof().ErrorCode=="deadline" && idle.RemainingMilliseconds==0,"original deadline bounds idle accept");
            await Retire(idle);
            var idleClosed=new GauntletTransport.Bridge("prompt",1000,new Upstream()); await Retire(idleClosed);
            Check(!idleClosed.GetProof().Success&&!idleClosed.GetProof().PromptSeen&&idleClosed.GetProof().Responses==0,"retiring idle bridge cannot authorize a fabricated verdict");
            var invalidHandler=new Upstream(); bool badConstructor=false;
            try {new GauntletTransport.Bridge("prompt",0,invalidHandler);} catch(GauntletTransport.TransportException) {badConstructor=true;}
            Check(badConstructor&&invalidHandler.Disposed,"failed construction releases transferred upstream owner");
            foreach(bool bodyStall in new [] {false,true}) {
                var b=new GauntletTransport.Bridge("prompt",200,new Upstream()); using(var c=new TcpClient(AddressFamily.InterNetwork)) {
                    await c.ConnectAsync(IPAddress.Loopback,new Uri(b.Endpoint).Port);
                    await c.GetStream().WriteAsync(Encoding.ASCII.GetBytes(bodyStall ? "POST /backend-api/codex/responses HTTP/1.1\r\nHost: "+new Uri(b.Endpoint).Authority+"\r\nX-Gauntlet-Capability: "+b.GetCapability()+"\r\nAuthorization: Bearer synthetic-token\r\nChatGPT-Account-Id: synthetic-account\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{" : "POST "));
                    await Task.WhenAny(b.Completion,Task.Delay(1500));
                    Check(b.Completion.IsCompleted && b.GetProof().ErrorCode=="deadline",bodyStall ? "deadline closes stalled body reader" : "deadline closes stalled header reader");
                } await Retire(b);
            }
            var blocked=new Upstream {Stall=true}; var waiting=new GauntletTransport.Bridge("prompt",200,blocked);
            var pending=Exchange(waiting,Request(waiting,Payload("prompt")));
            await Task.WhenAny(waiting.Completion,Task.Delay(1500));
            Check(waiting.Completion.IsCompleted && waiting.GetProof().ErrorCode=="deadline","deadline cancels upstream send"); await pending; await Retire(waiting);
            var cancelAfterSuccessHandler=new Upstream(); var cancelAfterSuccess=new GauntletTransport.Bridge("prompt",5000,cancelAfterSuccessHandler);
            await Exchange(cancelAfterSuccess,Request(cancelAfterSuccess,Payload("prompt")));
            cancelAfterSuccessHandler.Stall=true;
            var activeAfterSuccess=Exchange(cancelAfterSuccess,Request(cancelAfterSuccess,Payload("prompt")));
            await cancelAfterSuccessHandler.SecondEntered.Task;
            cancelAfterSuccess.Close(); await cancelAfterSuccess.Completion; await activeAfterSuccess;
            var activeCancelProof=cancelAfterSuccess.GetProof();
            Check(activeCancelProof.Retired&&!activeCancelProof.Success&&activeCancelProof.ErrorCode=="cancelled_active"&&activeCancelProof.Responses==1,"explicit cancellation of second active request fences earlier successful Responses proof");
            await Retire(cancelAfterSuccess);
            var streamAfterSuccessHandler=new Upstream(); var streamAfterSuccess=new GauntletTransport.Bridge("prompt",5000,streamAfterSuccessHandler);
            await Exchange(streamAfterSuccess,Request(streamAfterSuccess,Payload("prompt")));
            streamAfterSuccessHandler.StreamStall=true;
            using(var c=new TcpClient(AddressFamily.InterNetwork)) {
                await c.ConnectAsync(IPAddress.Loopback,new Uri(streamAfterSuccess.Endpoint).Port);
                await c.GetStream().WriteAsync(Request(streamAfterSuccess,Payload("prompt")));
                byte[] initialResponse=new byte[1024]; using(var bound=new CancellationTokenSource(1500)) await c.GetStream().ReadAsync(initialResponse.AsMemory(),bound.Token);
                streamAfterSuccess.Close(); await streamAfterSuccess.Completion;
            }
            var streamCancelProof=streamAfterSuccess.GetProof();
            Check(streamCancelProof.Retired&&!streamCancelProof.Success&&streamCancelProof.ErrorCode=="cancelled_active"&&streamCancelProof.Responses==1,"explicit cancellation during second response stream fences earlier successful proof");
            await Retire(streamAfterSuccess);
            var idleAfterSuccess=new GauntletTransport.Bridge("prompt",2000,new Upstream());
            await Exchange(idleAfterSuccess,Request(idleAfterSuccess,Payload("prompt")));
            await Retire(idleAfterSuccess);
            Check(idleAfterSuccess.GetProof().Success&&idleAfterSuccess.GetProof().ErrorCode=="","explicit idle accept close preserves completed Responses proof");
            var ignores=new Upstream {Stall=true,IgnoreCancellation=true}; var owned=new GauntletTransport.Bridge("prompt",150,ignores);
            var ignored=Exchange(owned,Request(owned,Payload("prompt")));
            await ignores.Entered.Task; await Task.Delay(200); owned.Close();
            Check(!owned.Completion.IsCompleted && !owned.GetProof().Retired && !owned.GetProof().Success && !ignores.Disposed,"noncooperative upstream remains owned and cannot claim retirement");
            ignores.Release.TrySetResult(true); await owned.Completion; await ignored; await Retire(owned);
            Check(ignores.Disposed,"upstream owner disposed after its physical retirement");
            return Checks.ToArray();
        }
    }
}
