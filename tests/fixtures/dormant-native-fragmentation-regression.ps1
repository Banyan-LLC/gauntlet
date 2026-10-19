param([Parameter(Mandatory)][string]$Source)
$ErrorActionPreference='Stop'
$hash=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
$text=[IO.File]::ReadAllText($Source)
foreach($anchor in @('public static string SourceIdentity { get { return "__GAUNTLET_NATIVE_SOURCE_IDENTITY__"; } }','buffer=new byte[chunkSize];')){
 if($text.Split($anchor,[StringSplitOptions]::None).Length -ne 2){throw ('Instrumentation anchor is not unique: '+$anchor)}
}
$text=$text.Replace('public static string SourceIdentity { get { return "__GAUNTLET_NATIVE_SOURCE_IDENTITY__"; } }','public static int FixtureChunkAllocations; public static string SourceIdentity { get { return "__GAUNTLET_NATIVE_SOURCE_IDENTITY__"; } }')
$text=$text.Replace('buffer=new byte[chunkSize];','Interlocked.Increment(ref FixtureChunkAllocations);buffer=new byte[chunkSize];')
. ([scriptblock]::Create($text))
Initialize-LiveGateNative
Add-Type -TypeDefinition @'
using System;using System.IO;using System.Threading;using System.Threading.Tasks;
public sealed class DormantSingleByteStream:Stream {
 long remaining;public long Reads;
 public DormantSingleByteStream(long bytes){remaining=bytes;}
 public override bool CanRead=>true;public override bool CanSeek=>false;public override bool CanWrite=>false;
 public override long Length=>throw new NotSupportedException();public override long Position{get=>throw new NotSupportedException();set=>throw new NotSupportedException();}
 public override int Read(byte[] buffer,int offset,int count){Reads++;if(remaining==0)return 0;buffer[offset]=(byte)'x';remaining--;return 1;}
 public override Task<int> ReadAsync(byte[] buffer,int offset,int count,CancellationToken token)=>Task.FromResult(Read(buffer,offset,count));
 public override void Flush(){}public override long Seek(long offset,SeekOrigin origin)=>throw new NotSupportedException();
 public override void SetLength(long length)=>throw new NotSupportedException();public override void Write(byte[] buffer,int offset,int count)=>throw new NotSupportedException();
}
'@
$native='GauntletLive.Native' -as [type]
$flags=[Reflection.BindingFlags]'NonPublic,Static'
$custodyType=$native.GetNestedType('RunCustody',[Reflection.BindingFlags]'NonPublic')
$budgetType=$native.GetNestedType('CaptureBudget',[Reflection.BindingFlags]'NonPublic')
$budget=[Activator]::CreateInstance($budgetType,[object[]]@([Activator]::CreateInstance($custodyType,$true)))
$stream=[DormantSingleByteStream]::new(4194304)
try{
 $task=$native.GetMethod('Capture',$flags).Invoke($null,[object[]]@($stream,$budget));$result=$task.GetAwaiter().GetResult()
 $allocated=$native.GetField('FixtureChunkAllocations').GetValue($null)
 $peak=$budgetType.GetField('PeakRetained').GetValue($budget)
 $retained=$budgetType.GetField('retained',[Reflection.BindingFlags]'NonPublic,Instance').GetValue($budget)
 $ok=$result.Length -eq 4194304 -and $stream.Reads -eq 4194305 -and $allocated -eq 1025 -and $peak -eq 12714000 -and $retained -eq 8519680
 @{passed=[bool]$ok;runtime=$PSVersionTable.PSVersion.ToString();dotnet=[Environment]::Version.ToString();source_sha256=$hash.ToLowerInvariant();read_completions=$stream.Reads;allocated_chunks=$allocated;peak_charged_storage_bytes=$peak;final_charged_storage_bytes=$retained;decoded_characters=$result.Length}|ConvertTo-Json
 if(-not $ok){exit 1}
}finally{$stream.Dispose()}
if((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -cne $hash){throw 'Source changed during fragmentation regression'}
