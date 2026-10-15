. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
Assert-True ((Get-Command ConvertTo-CompactReviewDiff).Parameters.ContainsKey('CompactIndentation')) 'explicit indentation opt-in exists'
Assert-True ([bool](Get-Command Get-CompactIndentationProtocol -ErrorAction SilentlyContinue)) 'separate protocol exists'
if($script:Failures.Count){Write-TestResult}

# Use the clean tool repository's immutable added-file blobs: no fixture commits.
$repo=Split-Path $PSScriptRoot
$head=(git -C $repo rev-parse HEAD).Trim()
$base=(git -C $repo rev-parse HEAD~1).Trim()
function New-Addition([string]$Path,[string]$Body){
    $blob=Get-CompactReviewBlobHash $Body
    $count=$Body.Split("`n").Length-1
    $index='0000000..'+$blob.Substring(0,7)
    $patch=(Get-CompactReviewOriginalHeader $Path '100644' $index $count)+'+'+$Body.Substring(0,$Body.Length-1).Replace("`n","`n+")+"`n"
    return [pscustomobject]@{Patch=$patch;Blob=$blob;Body=$Body;Path=$Path}
}
# Git provenance is substituted only for synthetic immutable blobs; renderer and
# decoder are real. This avoids commits and publication even in temporary repos.
$script:FixtureBodies=@{}
function Invoke-BoundedProcess {
    param($FileName,$ArgList,$TimeoutSec,[switch]$RequireProcessTreeRetirement)
    $path=$ArgList[-1];$stdout=''
    if($ArgList -contains 'ls-tree'){
        if($ArgList -contains $head){$stdout="100644 blob $(Get-CompactReviewBlobHash $script:FixtureBodies[$path])`t$path`n"}
    }elseif($ArgList -contains 'cat-file'){
        $path=$path.Substring($path.IndexOf(':')+1);$stdout=$script:FixtureBodies[$path]
    }else{throw 'Unexpected fixture Git request'}
    [pscustomobject]@{StartFailed=$false;TimedOut=$false;ExitCode=0;ProcessTreeRetired=$true;ErrorMessage=$null;Stdout=$stdout}
}
$body=''
foreach($n in 0..9){$body+=(' '*$n)+"token café λ 😀`tinterior  `n"}
$body+="`n        `n    [`"INDENT`",`"fake`",`"100644`",`"0..1`",9]`n    diff --git a/fake b/fake`n    +literal`n    @@ -0,0 +1,9 @@`n"
$script:FixtureBodies=[ordered]@{
    'src/sample.kt'=$body
    'src/Sample.java'="    class Sample {`n        }`n"
    'src/harness.asm'="    lda #0`n    rts`n"
    'src/leading.kt'="`tfirst`n        second`n"
    'src/mixed.kt'="  `tfirst`n        second`n"
    'src/blanktab.kt'="        first`n `t `n"
    'src/small.kt'=" x`n y`n"
    'src/no.py'="        first`n        last`n"
    'docs/no.kt'="        first`n        last`n"
    'docs/superpowers/reviews/history.json'="[`"long repeated historical token`",`"long repeated historical token`"]`n"
}
$diff='';foreach($path in $script:FixtureBodies.Keys){$diff+=(New-Addition $path $script:FixtureBodies[$path]).Patch}
$old=ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $diff
$r=ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $diff -CompactIndentation
Assert-Eq (Get-ReviewTextHash (Get-CompactReviewProtocol)) '5f86531ba9d59cd56a2aa789acb653d0899e75aaae2dd4a41f9098f3ee674b6f' 'old protocol unchanged'
Assert-Eq @($r.Manifest.sections | Where-Object {$_.PSObject.Properties['encoding']}).Count 3 'only eligible additions encoded'
Assert-Eq (Restore-CompactReviewDiff -Diff $r.Diff -Manifest $r.Manifest) $diff 'full diff round trip'
Assert-Eq (Restore-CompactReviewDiff -Diff $r.Diff -Manifest ($r.Manifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json)) $diff 'serialized manifest round trip'
$cursor=0;$oldCursor=0
foreach($s in $r.Manifest.sections){
    $o=$old.Manifest.sections | Where-Object header -CEQ $s.header
    $part=$r.Diff.Substring($cursor,$s.rendered_length)
    $oldPart=$old.Diff.Substring($oldCursor,$o.rendered_length)
    if($s.PSObject.Properties['encoding']){
        Assert-Eq $s.encoding 'indent' 'explicit encoding discriminator'
        Assert-True ($part.StartsWith('["INDENT",')) 'INDENT frame'
        $frame=$part.Substring(0,$part.IndexOf("`n")) | ConvertFrom-Json
        $lines=$part.Substring($part.IndexOf("`n")+1).Split("`n")
        Assert-Eq ($lines.Length-1) $frame[4] 'self-contained count'
        $plain=''
        foreach($line in $lines[0..($lines.Length-2)]){
            $tabs=$line.Length-$line.TrimStart([char]9).Length
            $plain+=(' '*(4*$tabs))+$line.Substring($tabs)+"`n"
        }
        Assert-Eq $plain $script:FixtureBodies[$s.path] 'independent prompt-only restoration'
        Assert-True ($part.Length -lt $oldPart.Length) 'strictly smaller frame'
    }else{
        Assert-Eq $part $oldPart 'fallback section identical'
        Assert-Eq ($s | ConvertTo-Json -Compress) ($o | ConvertTo-Json -Compress) 'fallback manifest identical'
    }
    $cursor+=$s.rendered_length;$oldCursor+=$o.rendered_length
}
$outer=ConvertTo-ReviewMetadataDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $r.Diff -CompactManifest $r.Manifest
Assert-Eq (Restore-ReviewMetadataDiff -Diff $outer.Diff -Manifest $outer.Manifest) $r.Diff 'metadata layering exact'
Assert-True ($outer.Diff.Contains('["INDENT",')) 'outer layer preserves indentation frames'
Assert-Eq (ConvertFrom-CompactIndentationBody -Body "`t   x`n" -Count 1) "       x`n" 'canonical remainder'
foreach($bad in @("`t    x`n"," `tx`n","`t `tx`n","`t`r`n","`tx","`tx`nextra`n")){
    Assert-Throws {ConvertFrom-CompactIndentationBody -Body $bad -Count 1} 'malformed indentation refused'
}
Assert-Throws {ConvertFrom-CompactIndentationBody -Body "`tx`n" -Count 1 -MaxDecodedLength 5} 'expansion bound'
Assert-Eq (ConvertFrom-CompactIndentationBody -Body "`tx`n" -Count 1 -MaxDecodedLength 6) "    x`n" 'exact expansion boundary'
Assert-Throws {ConvertFrom-CompactIndentationBody -Body "`tx`n" -Count 2147483647} 'hostile count'
Assert-Throws {ConvertFrom-CompactIndentationBody -Body (("`t"*262144)+"`n") -Count 1} 'per-body expansion cap'
foreach($mutation in @('encoding','blob','index','count','original_length')){
    $m=$r.Manifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $s=@($m.sections | Where-Object {$_.PSObject.Properties['encoding']})[0]
    $s.$mutation=switch($mutation){'encoding'{'unknown'} 'count'{2147483647} 'original_length'{1048577} default{'invalid'}}
    Assert-Throws {Restore-CompactReviewDiff -Diff $r.Diff -Manifest $m} "tampered $mutation refused"
}
$changed=$r.Diff.Replace('class Sample','class Tamper')
$m=$r.Manifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$m.rendered_sha256=Get-ReviewTextHash $changed
$offset=0
foreach($s in $m.sections){$s.rendered_sha256=Get-ReviewTextHash ($changed.Substring($offset,$s.rendered_length));$offset+=$s.rendered_length}
Assert-Throws {Restore-CompactReviewDiff -Diff $changed -Manifest $m} 'decoded blob checked after rendered hashes rebound'
$m=$r.Manifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json
foreach($s in $m.sections){$s.original_length=1048576}
Assert-Throws {Restore-CompactReviewDiff -Diff $r.Diff -Manifest $m} 'aggregate bound'

# Fully rebound outer/section hashes must not bypass expansion or index identity.
$single=$r.Manifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$section=@($single.sections | Where-Object path -CEQ 'src/Sample.java')[0]
$single.sections=@($section)
$largeBody=("`t"*262144)+"x`n"
$largeFrame=(ConvertTo-Json -InputObject @('INDENT',$section.path,$section.mode,$section.index,1) -Compress)+"`n"+$largeBody
$section.count=1;$section.rendered_length=$largeFrame.Length
$section.rendered_sha256=Get-ReviewTextHash $largeFrame
$section.original_length=1048578+(Get-CompactReviewOriginalHeader $section.path $section.mode $section.index 1).Length+1
$single.rendered_sha256=$section.rendered_sha256
try{Restore-CompactReviewDiff -Diff $largeFrame -Manifest $single | Out-Null;Assert-True $false 'rebound per-body budget enforced'}
catch{Assert-True ($_.Exception.Message -like '*expansion budget*') 'rebound per-body budget enforced before identity checks'}
$single=$r.Manifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$section=@($single.sections | Where-Object path -CEQ 'src/Sample.java')[0]
$single.sections=@($section)
$wrongIndex='0000000..fffffff'
$frame=(ConvertTo-Json -InputObject @('INDENT',$section.path,$section.mode,$wrongIndex,$section.count) -Compress)+"`n`tclass Sample {`n`t`t}`n"
$section.index=$wrongIndex;$section.rendered_length=$frame.Length
$section.rendered_sha256=Get-ReviewTextHash $frame;$single.rendered_sha256=$section.rendered_sha256
$wrongOriginal=(Get-CompactReviewOriginalHeader $section.path $section.mode $wrongIndex $section.count)+"+    class Sample {`n+        }`n"
$section.original_length=$wrongOriginal.Length;$section.original_sha256=Get-ReviewTextHash $wrongOriginal
$single.original_sha256=$section.original_sha256
try{Restore-CompactReviewDiff -Diff $frame -Manifest $single | Out-Null;Assert-True $false 'rebound index prefix refused'}
catch{Assert-True ($_.Exception.Message -like '*index/blob*') 'rebound index prefix refused independently'}
Assert-Eq (Get-ReviewTextHash (Get-CompactIndentationProtocol)) 'd58a6eae0c5764f4ccb99fbe10f720740a76ffb1eb4f387952ae1676cdff5a3c' 'exact protocol binding'
Write-Host ('Indent protocol SHA256: '+(Get-ReviewTextHash (Get-CompactIndentationProtocol)))
Write-Host ('Indent protocol bytes: '+[Text.Encoding]::UTF8.GetByteCount((Get-CompactIndentationProtocol)))
Write-TestResult
