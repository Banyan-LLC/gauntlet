. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
Assert-True ([bool](Get-Command ConvertTo-CompactReviewDiff -ErrorAction SilentlyContinue)) 'compact renderer exists'
if (-not (Get-Command ConvertTo-CompactReviewDiff -ErrorAction SilentlyContinue)) { Write-TestResult }
$root=Join-Path ([IO.Path]::GetTempPath()) ('compact-review-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
try {
    git -C $root init -q
    [IO.File]::WriteAllText("$root/existing.txt","before`n")
    git -C $root -c core.autocrlf=false add .
    git -C $root -c user.name=geoffroth -c user.email=test@example.invalid commit -qm base
    $base=(git -C $root rev-parse HEAD).Trim()
    $body="Unicode café λ`n`ndiff --git a/fake b/fake`n@@ -0,0 +1,99 @@`n[`"ADDED`",`"fake`",`"100644`",`"0..1`",99]`n+literal plus`n"
    [IO.File]::WriteAllText("$root/safe-file.txt",$body)
    [IO.File]::WriteAllText("$root/one.txt","one`n")
    [IO.File]::WriteAllText("$root/empty.txt",'')
    [IO.File]::WriteAllText("$root/no-lf.txt","first`nno newline")
    [IO.File]::WriteAllText("$root/space name.txt","quoted`n")
    [IO.File]::WriteAllText("$root/executable.txt","executable`nsecond`n")
    [IO.File]::WriteAllText("$root/existing.txt","after`n")
    git -C $root -c core.autocrlf=false add .
    git -C $root update-index --chmod=+x executable.txt
    git -C $root -c user.name=geoffroth -c user.email=test@example.invalid commit -qm head
    $head=(git -C $root rev-parse HEAD).Trim()
    $git=@(Get-Command git -CommandType Application)[0].Source
    $run=Invoke-BoundedProcess -FileName $git -ArgList @('-C',$root,'diff','--no-ext-diff','--no-textconv','--no-color',$base,$head) -TimeoutSec 30 -RequireProcessTreeRetirement
    $diff=$run.Stdout.Replace("`r`n","`n")
    function Render([string]$d=$diff) { ConvertTo-CompactReviewDiff -RepoRoot $root -BaseOid $base -HeadSha $head -Diff $d }
    $r=Render
    Assert-Eq (Get-ReviewTextHash (Get-CompactReviewProtocol)) '5f86531ba9d59cd56a2aa789acb653d0899e75aaae2dd4a41f9098f3ee674b6f' 'exact approved protocol hash'
    Assert-Eq ([Text.Encoding]::UTF8.GetByteCount((Get-CompactReviewProtocol))) 831 'exact protocol byte count'
    Assert-True ((Get-CompactReviewProtocol).StartsWith("`n== VERIFIED COMPLETE ADDED-FILE ENCODING ==`nA compact")) 'protocol boundary'
    Assert-Eq $r.Manifest.sections.Count 7 'all sections covered'
    Assert-Eq @($r.Manifest.sections | Where-Object compact).Count 1 'only canonical complete addition qualifies'
    Assert-True ($r.Diff.Contains("`n"+$body)) 'literal body preserved including markers'
    Assert-Eq (Restore-CompactReviewDiff -Diff $r.Diff -Manifest $r.Manifest) $diff 'exact full round trip'
    Assert-Eq (Restore-CompactReviewDiff -Diff $r.Diff -Manifest ($r.Manifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json)) $diff 'sidecar JSON round trip'
    Assert-Eq (Render ($diff.Replace("`n","`r`n"))).Diff $r.Diff 'CRLF normalized to LF'
    Assert-Throws { Render ($diff+"`r") } 'standalone CR refused'
    $s=@($r.Manifest.sections | Where-Object compact)[0]
    Assert-Throws { Render ($diff.Replace('new file mode 100755','new file mode 100644')) } 'HEAD executable mode mismatch throws'
    Assert-Throws { Render ($diff.Replace("diff --git a/safe-file.txt b/safe-file.txt`nnew file mode 100644","diff --git a/safe-file.txt b/safe-file.txt`nnew file mode 100755")) } 'HEAD regular mode mismatch throws'
    Assert-Throws { Render ($diff.Replace('++literal plus'+"`n",'').Replace('@@ -0,0 +1,6 @@','@@ -0,0 +1,5 @@')) } 'well formed partial body fails full blob verification'
    foreach ($badCount in @('0','-1','06','many','2147483648')) {
        Assert-Throws { Render ($diff.Replace('@@ -0,0 +1,6 @@',"@@ -0,0 +1,$badCount @@")) } "invalid declared count $badCount rejected"
    }
    Assert-Eq $s.count 6 'body line count'
    Assert-Eq $s.blob (git -C $root rev-parse "${head}:safe-file.txt").Trim() 'full head blob recorded'
    foreach ($part in @('existing.txt','one.txt','empty.txt','no-lf.txt','space name.txt','executable.txt')) {
        $entry=@($r.Manifest.sections | Where-Object { $_.header.Contains($part) })[0]
        Assert-Eq $entry.original_sha256 $entry.rendered_sha256 "$part unchanged"
    }
    Assert-Throws { Render ($diff+$diff) } 'duplicate sections refused'
    Assert-Throws { Render ($diff.Replace('+Unicode café λ','+altered')) } 'body tampering refused'
    Assert-Throws { Render ($diff.Replace('@@ -0,0 +1,6 @@','@@ -0,0 +1,5 @@')) } 'count mismatch refused'
    Assert-Throws { Render ($diff.Replace($s.index,('0'*7+'..'+'f'*7))) } 'index mismatch refused'
    Assert-Throws { ConvertTo-CompactReviewDiff -RepoRoot $root -BaseOid $head -HeadSha $head -Diff $diff } 'already present base path refused'
    foreach ($field in @('path','mode','index','count','blob','original_sha256','rendered_sha256','header')) {
        $m=$r.Manifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $target=@($m.sections | Where-Object compact)[0]
        $target.$field=if($field -eq 'count'){5}else{'tampered'}
        Assert-Throws { Restore-CompactReviewDiff -Diff $r.Diff -Manifest $m } "manifest $field tampering refused"
    }
    foreach ($field in @('original_sha256','rendered_sha256','version')) {
        $m=$r.Manifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $m.$field=if($field -eq 'version'){2}else{'bad'}
        Assert-Throws { Restore-CompactReviewDiff -Diff $r.Diff -Manifest $m } "global $field tampering refused"
    }
    Assert-Throws { Restore-CompactReviewDiff -Diff ($r.Diff.Replace('Unicode café λ','changed')) -Manifest $r.Manifest } 'rendered body tampering refused'
    Assert-Throws { Restore-CompactReviewDiff -Diff ($r.Diff.TrimEnd("`n")) -Manifest $r.Manifest } 'missing final LF refused'
    $compactHeader=($r.Diff -split "`n" | Where-Object { $_.StartsWith('["ADDED"') })[0]
    foreach ($changed in @(
        $compactHeader.Replace('"safe-file.txt"','"other.txt"'),
        $compactHeader.Replace('"100644"','"100755"'),
        $compactHeader.Replace(',6]',',5]'),
        $compactHeader.Replace($s.index,'0000000..abcdef0')
    )) {
        Assert-Throws { Restore-CompactReviewDiff -Diff ($r.Diff.Replace($compactHeader,$changed)) -Manifest $r.Manifest } 'payload header tampering refused'
    }
    foreach ($path in @('nested/file-name_1.txt','a.b/c_d.txt','.gitattributes','.github/workflows/build.yml')) {
        Assert-True (Test-CompactReviewPath $path) "safe path $path"
    }
    foreach ($path in @('../escape','dir/../escape','dir//file','dir/./file','space name','"quoted"','dir/')) {
        Assert-True (-not (Test-CompactReviewPath $path)) "unsafe path $path"
    }
    $extra="diff --git a/multi.txt b/multi.txt`nnew file mode 100644`nindex 0000000..1234567`n--- /dev/null`n+++ b/multi.txt`n@@ -0,0 +1,2 @@`n+first`n+second`n@@ -0,0 +4,2 @@`n+third`n+fourth`n"
    $extra=$extra.Replace('multi.txt','safe-file.txt'); $multi=Render $extra
    Assert-True ($multi.Diff.EndsWith($extra)) 'multiple hunks remain exact'
    $quoted="diff --git a/`"quoted.txt`" b/`"quoted.txt`"`nnew file mode 100644`nindex 0000000..1234567`n--- /dev/null`n+++ b/`"quoted.txt`"`n@@ -0,0 +1,2 @@`n+a`n+b`n"
    Assert-True ((Render ($diff+$quoted)).Diff.EndsWith($quoted)) 'quoted section remains exact'
    $alias="diff --git a/old-name b/safe-file.txt`nsimilarity index 100%`nrename from old-name`nrename to safe-file.txt`n"
    Assert-Throws { Render ($diff+$alias) } 'different headers with same destination refused'
    # Rebind the outer checksum to exercise the section checksum gate.
    $changed=$r.Diff.Replace('Unicode café λ','body changed')
    $m=$r.Manifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $m.rendered_sha256=Get-ReviewTextHash $changed
    Assert-Throws { Restore-CompactReviewDiff -Diff $changed -Manifest $m } 'section hash independently enforced'
    # Rebind both rendered checksums: the full blob must still reject altered content.
    $changed=$r.Diff.Replace('Unicode café λ','Unicode cafe x')
    $m=$r.Manifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $m.rendered_sha256=Get-ReviewTextHash $changed
    $target=@($m.sections | Where-Object compact)[0]
    $offset=0
    foreach ($entry in $m.sections) {
        if ($entry.compact) {
            $target.rendered_sha256=Get-ReviewTextHash ($changed.Substring($offset,$target.rendered_length))
            break
        }
        $offset+=$entry.rendered_length
    }
    Assert-Throws { Restore-CompactReviewDiff -Diff $changed -Manifest $m } 'full blob independently enforced after rendered hashes rebind'
    $ref="diff --git a/docs/spec.md b/docs/spec.md`nnew file mode 100644`nindex 0000000..1234567`n--- /dev/null`n+++ b/docs/spec.md`n@@ -0,0 +1,2 @@`n[Verified complete-body reference: approved body]`n"
    $rr=Render ($diff+$ref)
    Assert-True ($rr.Diff.EndsWith($ref)) 'approved reference unchanged'
    Assert-Eq (Restore-CompactReviewDiff -Diff $rr.Diff -Manifest $rr.Manifest) ($diff+$ref) 'reference round trip'
} finally {
    # Only this unique test-owned root is removed.
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-TestResult


