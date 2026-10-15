. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
$realBoundedProcess=(Get-Command Invoke-BoundedProcess).ScriptBlock
Assert-True ((Get-Command ConvertTo-CompactReviewDiff).Parameters.ContainsKey('CompactRepeatedLines')) 'source-line framing is explicit opt-in'
Assert-True ([bool](Get-Command Get-CompactSourceLineProtocol -ErrorAction SilentlyContinue)) 'separate source-line protocol exists'
if($script:Failures.Count){Write-TestResult}

$repo=Split-Path $PSScriptRoot
$head=(git -C $repo rev-parse HEAD).Trim();$base=(git -C $repo rev-parse HEAD~1).Trim()
function New-Addition([string]$Path,[string]$Body){
    $blob=Get-CompactReviewBlobHash $Body;$count=$Body.Split("`n").Length-1
    $index='0000000..'+$blob.Substring(0,7)
    [pscustomobject]@{Patch=(Get-CompactReviewOriginalHeader $Path '100644' $index $count)+'+'+$Body.Substring(0,$Body.Length-1).Replace("`n","`n+")+"`n";Body=$Body}
}
$shared='the literal source row remains entirely present and preserves cafe λ 😀  '
$body=@('    fun fixture() {','        val text = """',('            '+$shared),'',('       '+$shared),'        """',
    '        check(text == text)','        check(text == text)',("        val interior = `"a`tB`""),'       ',
    '        ["LINES","literal delimiter-looking content"]','    }') -join "`n"
$body+="`n"
$script:Bodies=[ordered]@{
    'src/a.kt'=$body;'src/b.kt'=$body
    'src/collision.kt'=("    val raw = `"`"`"`n    ~0=literal source marker must survive`n    ~00~`n    `"`"`"`n")
    'src/literal-tab.kt'=(("`t"+$shared+"`n")*12)
    'src/program.asm'=(("    lda #<a_shared_symbol_with_a_literal_operand`n")*12)
    'src/Program.java'=(("        System.out.println(`"literal shared source text`");`n")*12)
    'docs/no.kt'=$body;'src/no.py'=$body
    'docs/superpowers/reviews/history.json'="[`"historical unchanged token`",`"historical unchanged token`"]`n"
}
function Invoke-BoundedProcess {
    param($FileName,$ArgList,$TimeoutSec,[switch]$RequireProcessTreeRetirement)
    $path=$ArgList[-1];$stdout=''
    if($ArgList -contains 'ls-tree'){
        if($ArgList -contains $head){$stdout="100644 blob $(Get-CompactReviewBlobHash $script:Bodies[$path])`t$path`n"}
    }elseif($ArgList -contains 'cat-file'){$path=$path.Substring($path.IndexOf(':')+1);$stdout=$script:Bodies[$path]}
    else{throw 'Unexpected fixture Git request'}
    [pscustomobject]@{StartFailed=$false;TimedOut=$false;ExitCode=0;ProcessTreeRetired=$true;ErrorMessage=$null;Stdout=$stdout}
}
$diff='';foreach($path in $script:Bodies.Keys){$diff+=(New-Addition $path $script:Bodies[$path]).Patch}
$old=ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $diff -CompactIndentation
$r=ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $diff -CompactIndentation -CompactRepeatedLines
Assert-Eq (Restore-CompactReviewDiff -Diff $r.Diff -Manifest $r.Manifest) $diff 'all source and literal sections roundtrip'
Assert-Eq (Restore-CompactReviewDiff -Diff $r.Diff -Manifest ($r.Manifest|ConvertTo-Json -Depth 40|ConvertFrom-Json)) $diff 'serialized coverage roundtrip'
Assert-True ($r.Diff.Length -lt $old.Diff.Length) 'source framing strictly shortens whole input'
Assert-True ($r.Diff.Contains('~0=')) 'first source declaration has a visible ID'
Assert-True ([bool]($r.Diff -cmatch '~[0-9]+~')) 'source references are explicit'
Assert-Eq $r.Manifest.source_line_version 1 'source-line protocol version is bound'
Assert-True ($r.Manifest.source_line_dictionary_count -gt 0 -and $r.Manifest.source_line_dictionary_count -le 65536) 'dictionary count bounded'
Assert-True ($r.Manifest.source_line_dictionary_utf16 -le 4194304) 'dictionary retained characters bounded'
$offset=0;$previous=0
foreach($section in $r.Manifest.sections){
    $part=$r.Diff.Substring($offset,$section.rendered_length);$offset+=$section.rendered_length
    if($section.PSObject.Properties['source_line_start']){
        Assert-Eq $section.source_line_start $previous 'ordered dictionary start'
        Assert-True ($section.encoding -cin @('lines','indent-lines')) 'explicit new encoding discriminator'
        Assert-True ($part.Length -lt ($old.Manifest.sections|Where-Object path -CEQ $section.path).rendered_length) 'each frame strictly shortens'
        $previous=$section.source_line_end
    }
}
Assert-Eq $previous $r.Manifest.source_line_dictionary_count 'final dictionary count agrees'
foreach($path in @('src/collision.kt','docs/no.kt','src/no.py')){
    $before=$old.Manifest.sections|Where-Object path -CEQ $path;$after=$r.Manifest.sections|Where-Object path -CEQ $path
    Assert-Eq ($after|ConvertTo-Json -Compress) ($before|ConvertTo-Json -Compress) "$path fallback metadata unchanged"
}
$again=ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $diff -CompactIndentation
Assert-Eq $again.Diff $old.Diff 'disabled switch preserves exact old wire format'
Assert-Eq ($again.Manifest|ConvertTo-Json -Depth 40 -Compress) ($old.Manifest|ConvertTo-Json -Depth 40 -Compress) 'disabled switch preserves old coverage'
$plain=ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $diff -CompactRepeatedLines
Assert-Eq (Restore-CompactReviewDiff -Diff $plain.Diff -Manifest $plain.Manifest) $diff 'line framing works without indentation'
$outer=ConvertTo-ReviewMetadataDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $r.Diff -CompactManifest $r.Manifest
Assert-Eq (Restore-ReviewMetadataDiff -Diff $outer.Diff -Manifest $outer.Manifest) $r.Diff 'historical metadata remains independently reversible'
Assert-Eq (Restore-CompactReviewDiff -Diff (Restore-ReviewMetadataDiff -Diff $outer.Diff -Manifest $outer.Manifest) -Manifest $outer.Manifest.input_manifest) $diff 'layered restoration is exact'

$core='abcdefghijklmnop'
$valid="    ~0=$core`n`t~0~`n"
Assert-Eq (ConvertFrom-CompactSourceLineBody -Body $valid -Count 2 -Start 0 -End 1 -State (New-CompactSourceLineState) -MaxDecodedLength 39) ("    $core`n`t$core`n") 'independent literal expectation includes exact prefix'
Assert-Throws {ConvertFrom-CompactSourceLineBody -Body $valid -Count 2 -Start 0 -End 1 -State (New-CompactSourceLineState) -MaxDecodedLength 38} 'decoded source length checked before append'
foreach($bad in @(
    "~0~`n", "~0~`n~0=$core`n", "~00=$core`n", "~0=$core`n~00~`n",
    "~1=$core`n", "~0=$core`n~1=$core`n", "~0=$core`n~0=other_literal_source_value`n",
    "~0=$core`n$core`n", "~0=short`n", "~0= $core`n", "~0=~123=literal_source_marker`n",
    "~999999999999999999999999~`n", "~0=$core", "~0=$core`r`n"
)){
    $count=($bad.Split("`n").Length-1)
    Assert-Throws {ConvertFrom-CompactSourceLineBody -Body $bad -Count $count -Start 0 -End 1 -State (New-CompactSourceLineState)} 'noncanonical or unknown source framing refused'
}
Assert-Throws {ConvertFrom-CompactSourceLineBody -Body $valid -Count 2 -Start 1 -End 1 -State (New-CompactSourceLineState)} 'stale dictionary start refused'
Assert-Throws {ConvertFrom-CompactSourceLineBody -Body $valid -Count 2 -Start 0 -End 2 -State (New-CompactSourceLineState)} 'unmatched final dictionary count refused'
Assert-Throws {ConvertFrom-CompactSourceLineBody -Body $valid -Count 2147483647 -Start 0 -End 1 -State (New-CompactSourceLineState)} 'hostile row count refused'
Assert-Throws {ConvertFrom-CompactSourceLineBody -Body $valid -Count 2 -Start 0 -End 1 -State (New-CompactSourceLineState) -MaxDecodedLength 1048577} 'caller cannot raise source body limit'
foreach($field in @('source_line_version','source_line_dictionary_count','source_line_dictionary_utf16')){
    $m=$r.Manifest|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $m.$field=if($field -ceq 'source_line_version'){2}else{2147483647}
    Assert-Throws {Restore-CompactReviewDiff -Diff $r.Diff -Manifest $m} "rebound $field refused"
}
foreach($field in @('source_line_start','source_line_end')){
    $m=$r.Manifest|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $section=@($m.sections|Where-Object {$_.PSObject.Properties['source_line_start']})[0]
    $section.$field='0'
    Assert-Throws {Restore-CompactReviewDiff -Diff $r.Diff -Manifest $m} "string $field refused"
}
Assert-Eq (Get-ReviewTextHash (Get-CompactReviewProtocol)) '5f86531ba9d59cd56a2aa789acb653d0899e75aaae2dd4a41f9098f3ee674b6f' 'original added protocol unchanged'
Assert-Eq (Get-ReviewTextHash (Get-CompactIndentationProtocol)) 'd58a6eae0c5764f4ccb99fbe10f720740a76ffb1eb4f387952ae1676cdff5a3c' 'old indentation protocol unchanged'
Assert-Eq (Get-ReviewTextHash (Get-ReviewMetadataProtocol)) '35bc6b04c9c2d689acfad4f6ac9e4ebab01326a7615ea7c15d223a1e19a0f983' 'historical metadata protocol unchanged'

# Capacity boundaries are exercised without large decoded allocations.
$full=New-CompactSourceLineState
for($i=0;$i -lt 65536;$i++){
    $value='entry-'+$i.ToString('D10',[Globalization.CultureInfo]::InvariantCulture)
    $full.Cores.Add($value);[void]$full.Known.Add($value);$full.Characters+=[long]$value.Length
}
Assert-Eq (ConvertFrom-CompactSourceLineBody -Body "~65535~`n" -Count 1 -Start 65536 -End 65536 -State $full) "entry-0000065535`n" 'largest declared ID is readable'
Assert-Throws {ConvertFrom-CompactSourceLineBody -Body "~65536=$core`n" -Count 1 -Start 65536 -End 65536 -State $full} 'dictionary entry capacity cannot increase'
Assert-Eq $full.Cores.Count 65536 'capacity refusal adds no entry'
$units=New-CompactSourceLineState
foreach($i in 0..3){$value=('x'*1048574)+[string]$i;$units.Cores.Add($value);[void]$units.Known.Add($value);$units.Characters+=[long]$value.Length}
Assert-Throws {ConvertFrom-CompactSourceLineBody -Body "~4=$core`n" -Count 1 -Start 4 -End 5 -State $units} 'retained dictionary unit cap checked before append'
Assert-Eq $units.Cores.Count 4 'unit-cap refusal adds no entry'
$half='q'*524288
Assert-Throws {ConvertFrom-CompactSourceLineBody -Body ("~0=$half`n~0~`n~0~`n") -Count 3 -Start 0 -End 1 -State (New-CompactSourceLineState)} 'small references cannot amplify a body beyond one MiB'

# Rendered hashes can be rebound by an untrusted caller; original blob identity still wins.
$changed=$r.Diff.Replace('the literal source row','the altered source row')
$m=$r.Manifest|ConvertTo-Json -Depth 40|ConvertFrom-Json
$m.rendered_sha256=Get-ReviewTextHash $changed;$cursor=0
foreach($section in $m.sections){$section.rendered_sha256=Get-ReviewTextHash ($changed.Substring($cursor,$section.rendered_length));$cursor+=$section.rendered_length}
try{Restore-CompactReviewDiff -Diff $changed -Manifest $m|Out-Null;Assert-True $false 'rebound source still checks full blob'}
catch{Assert-True ($_.Exception.Message -like '*full blob*') 'rebound source still checks full blob'}
$m=$r.Manifest|ConvertTo-Json -Depth 40|ConvertFrom-Json
foreach($section in $m.sections){$section.original_length=1048576}
try{Restore-CompactReviewDiff -Diff $r.Diff -Manifest $m|Out-Null;Assert-True $false 'aggregate original budget before append'}
catch{Assert-True ($_.Exception.Message -like '*budget*') 'aggregate original budget before append'}

# Line references and indentation share the same per-source bound after both layers.
$m=$r.Manifest|ConvertTo-Json -Depth 40|ConvertFrom-Json
$section=@($m.sections|Where-Object {$_.PSObject.Properties['encoding'] -and $_.encoding -ceq 'indent-lines'})[0]
$m.sections=@($section);$section.count=2;$section.source_line_start=0;$section.source_line_end=1
$line='z'*100;$body="~0=$line`n"+("`t"*262144)+"~0~`n"
$frame=(ConvertTo-Json -InputObject @('INDENT_LINES',$section.path,$section.mode,$section.index,2,0,1) -Compress)+"`n"+$body
$section.rendered_length=$frame.Length;$section.rendered_sha256=Get-ReviewTextHash $frame
$section.original_length=1048778+(Get-CompactReviewOriginalHeader $section.path $section.mode $section.index 2).Length+2
$m.rendered_sha256=$section.rendered_sha256;$m.source_line_dictionary_count=1;$m.source_line_dictionary_utf16=100
try{Restore-CompactReviewDiff -Diff $frame -Manifest $m|Out-Null;Assert-True $false 'nested source expansion limit precedes identity checks'}
catch{Assert-True ($_.Exception.Message -like '*expansion budget*') 'nested source expansion limit precedes identity checks'}
$oldJson=$old.Manifest|ConvertTo-Json -Depth 40 -Compress
$reframed=ConvertTo-CompactSourceLineDiff -Diff $old.Diff -Manifest $old.Manifest
Assert-Eq ($old.Manifest|ConvertTo-Json -Depth 40 -Compress) $oldJson 'source pass never mutates input coverage'
Assert-Eq $reframed.Diff $r.Diff 'deterministic independent reapplication to old input'


# A full-size truncated whitespace row must reject in bounded time, not backtrack.
$library=(Resolve-Path "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1").Path.Replace("'","''")
$child=@(
    ". '$library'",
    'try {',
    ' ConvertFrom-CompactSourceLineBody -Body ('' ''*1048576) -Count 1 -Start 0 -End 0 -State (New-CompactSourceLineState) | Out-Null',
    ' exit 3',
    '} catch {',
    ' if($_.Exception.Message -like ''*Truncated source-line body*''){exit 0}',
    ' exit 4',
    '}'
) -join "`n"
$run=& $realBoundedProcess -FileName ([Environment]::ProcessPath) -ArgList @('-NoProfile','-Command',$child) -TimeoutSec 5 -RequireProcessTreeRetirement
Assert-True (-not $run.StartFailed -and -not $run.TimedOut) 'truncated one-MiB whitespace rejects before bounded deadline'
Assert-Eq $run.ExitCode 0 'malformed row reports truncation'
Assert-True $run.ProcessTreeRetired 'malformed-row regression retires its owned process'

Write-TestResult