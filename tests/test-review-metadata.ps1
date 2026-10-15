. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
foreach ($name in @('ConvertTo-ReviewMetadataDiff','Restore-ReviewMetadataDiff','Get-ReviewMetadataProtocol')) {
    Assert-True ([bool](Get-Command $name -ErrorAction SilentlyContinue)) "$name exists"
}
if ($script:Failures.Count) { Write-TestResult }

$longToken='"a long raw metadata token repeated for canonical validation"'
Assert-Throws { Convert-ReviewMetadataTokens -Body '["x",@0@]' -State (New-ReviewMetadataTokenState) -Decode } 'non-shortening reference rejected independently of framing hashes'
Assert-Throws { Convert-ReviewMetadataTokens -Body ('['+$longToken+',@0@,@1@]') -State (New-ReviewMetadataTokenState) -Decode } 'reference to a later duplicate rejected independently of framing hashes'
Assert-Throws { Convert-ReviewMetadataTokens -Body ('['+$longToken+','+$longToken+']') -State (New-ReviewMetadataTokenState) -Decode } 'noncanonical repeated literal rejected independently of framing hashes'

$root=Join-Path ([IO.Path]::GetTempPath()) ('review-metadata-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
try {
    function Git-Fixture([string[]]$Arguments) {
        $out=& git -C $root @Arguments
        if ($LASTEXITCODE) { throw "Fixture git failed: $Arguments" }
        return $out
    }
    function Put-Fixture([string]$Path,[string]$Body) {
        $full=Join-Path $root $Path
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
        [IO.File]::WriteAllText($full,$Body,[Text.UTF8Encoding]::new($false))
    }
    function Copy-Manifest($Manifest) { $Manifest | ConvertTo-Json -Depth 100 | ConvertFrom-Json }
    Git-Fixture @('init','-q')
    Put-Fixture 'docs/superpowers/reviews/existing.json' '{"old":true}'
    Git-Fixture @('-c','core.autocrlf=false','add','.')
    Git-Fixture @('-c','user.name=geoffroth','-c','user.email=test@example.invalid','commit','-qm','base')
    $base=(Git-Fixture @('rev-parse','HEAD')).Trim()
    $long='a repeated raw string long enough to save bytes'
    $bodies=[ordered]@{
        'docs/superpowers/reviews/a.json'=(('["{0}","x","{0}","x","\u0061","a","@1@","café λ 😀","\"quoted\"","\\"]' -f $long)+"`n")
        'docs/superpowers/reviews/nested/b.json'=("{`"$long`":`"$long`",`"marker`":`"REVIEWJSON[evil]\\n diff --git a/x b/x`",`"escaped`":`"\u0061`"}`n")
        'docs/superpowers/reviews/c.jsonl'=("`"$long`"`nnull`n[]`n{}`nfalse`n42`n`"`"`n")
        'docs/superpowers/reviews/d.json'=("[`"$long`",`"@999999@`",null]")
        'docs/superpowers/reviews/empty.json'=''
        'docs/superpowers/reviews/null.json'='null'
        'docs/superpowers/reviews/invalid.json'="{invalid`n"
        'docs/superpowers/reviews/executable.json'=("[`"$long`",`"$long`"]`n")
        'docs/superpowers/reviews/existing.json'=("[`"$long`",`"$long`"]`n")
        'docs/superpowers/reviews-other/a.json'=("[`"$long`",`"$long`"]`n")
        'docs/other.json'=("[`"$long`",`"$long`"]`n")
        'src/code.ps1'="Write-Output '@1@'`n"
        'tests/test-body.ps1'="'REVIEWJSON[]'`n"
        'docs/superpowers/reviews/raw.txt'=("$long`n$long`n")
    }
    foreach ($path in $bodies.Keys) { Put-Fixture $path $bodies[$path] }
    Git-Fixture @('-c','core.autocrlf=false','add','.')
    Git-Fixture @('update-index','--chmod=+x','docs/superpowers/reviews/executable.json')
    Git-Fixture @('-c','user.name=geoffroth','-c','user.email=test@example.invalid','commit','-qm','head')
    $head=(Git-Fixture @('rev-parse','HEAD')).Trim()
    $git=@(Get-Command git -CommandType Application)[0].Source
    $run=Invoke-BoundedProcess -FileName $git -ArgList @('-C',$root,'diff','--no-ext-diff','--no-textconv','--no-color',$base,$head) -TimeoutSec 30 -RequireProcessTreeRetirement
    $original=$run.Stdout.Replace("`r`n","`n")
    $compact=ConvertTo-CompactReviewDiff -RepoRoot $root -BaseOid $base -HeadSha $head -Diff $original
    function Render-Metadata([string]$Text=$compact.Diff,$InputManifest=$compact.Manifest,[string]$Base=$base,[string]$Head=$head) {
        ConvertTo-ReviewMetadataDiff -RepoRoot $root -BaseOid $Base -HeadSha $Head -Diff $Text -CompactManifest $InputManifest
    }
    $r=Render-Metadata
    Assert-True (-not [string]::IsNullOrWhiteSpace((Get-ReviewMetadataProtocol))) 'protocol supplied'
    Assert-Eq (Restore-ReviewMetadataDiff -Diff $r.Diff -Manifest $r.Manifest) $compact.Diff 'exact compact input round trip including noLF'
    Assert-Eq (Restore-ReviewMetadataDiff -Diff $r.Diff -Manifest (Copy-Manifest $r.Manifest)) $compact.Diff 'manifest serialization round trip'
    Assert-Eq (Restore-CompactReviewDiff -Diff (Restore-ReviewMetadataDiff -Diff $r.Diff -Manifest $r.Manifest) -Manifest $compact.Manifest) $original 'both manifest layers restore original Git diff'
    Assert-True ($r.Diff.Contains('["REVIEWJSON",')) 'eligible metadata encoded'
    $headers=@($r.Diff -split "`n" | Where-Object { $_.StartsWith('["REVIEWJSON",') })
    foreach ($header in $headers) {
        $fields=$header | ConvertFrom-Json
        Assert-Eq $fields.Count 8 'metadata header has tag and seven ordered fields'
        Assert-Eq $fields[2] '100644' 'metadata header regular mode'
        Assert-True ($fields[4] -is [long] -or $fields[4] -is [int]) 'header lineCount integer'
        Assert-True ($fields[5] -is [bool]) 'header finalLf boolean'
        Assert-True ($fields[6] -is [long] -or $fields[6] -is [int]) 'header tokenStart integer'
        Assert-True ($fields[7] -ceq "1,$($fields[4])" -or ($fields[4] -eq 1 -and $fields[7] -ceq '1')) 'exact original hunk range supplied in prompt'
        if ($fields[1] -eq 'docs/superpowers/reviews/a.json') { Assert-Eq $fields[6] 0 'first token ordinal starts at zero' }
        if ($fields[1] -eq 'docs/superpowers/reviews/nested/b.json') {
            Assert-True ($fields[6] -gt 10) 'cross-section ordinal counts literals and references'
        }
        if ($fields[1] -eq 'docs/superpowers/reviews/d.json') { Assert-Eq $fields[5] $false 'noLF identity retained in header' }
    }
    # Reconstruct original unified sections using ONLY prompt-visible framing and
    # earlier decoded tokens, not input_compact or other sidecar-only fields.
    $visibleState=New-ReviewMetadataTokenState
    $offset=0
    foreach($entry in $r.Manifest.sections){
        $frame=$r.Diff.Substring($offset,$entry.rendered_length);$offset+=$entry.rendered_length
        if(-not $entry.metadata){continue}
        $end=$frame.IndexOf("`n");$f=$frame.Substring(0,$end)|ConvertFrom-Json
        Assert-Eq $f[6] $visibleState.Tokens.Count 'visible tokenStart is independently sufficient'
        $encoded=$frame.Substring($end+1)
        if(-not $f[5]){$encoded=$encoded.Substring(0,$encoded.Length-1)}
        $decoded=Convert-ReviewMetadataTokens -Body $encoded -State $visibleState -Decode
        $withLF=if($f[5]){$decoded}else{$decoded+"`n"}
        $visible="diff --git a/$($f[1]) b/$($f[1])`nnew file mode $($f[2])`nindex $($f[3])`n--- /dev/null`n+++ b/$($f[1])`n@@ -0,0 +$($f[7]) @@`n"+'+'+$withLF.Substring(0,$withLF.Length-1).Replace("`n","`n+")+"`n"
        if(-not $f[5]){$visible+='\ No newline at end of file'+"`n"}
        $expectedPart=@([regex]::Split($original,'(?m)(?=^diff --git )')|Where-Object{$_.StartsWith("diff --git a/$($f[1]) b/$($f[1])`n",[StringComparison]::Ordinal)})[0]
        Assert-Eq $visible $expectedPart 'prompt-visible metadata frame reconstructs exact original diff'
    }
    Assert-True ($r.Diff.Contains('@0@')) 'repeat references first raw token ordinal'
    Assert-True ($r.Diff.Contains('@4@')) 'escaped spelling token retains its own ordinal across sections'
    Assert-True ($r.Diff.Contains('"x","'+$long+'"') -eq $false) 'long repeated raw token replaced'
    Assert-True ($r.Diff.Contains('"x",@0@,"x"')) 'short repeated token stays literal while still counting'
    foreach ($raw in @('"\u0061"','"a"','"@1@"','"café λ 😀"','"\"quoted\""','"\\"','"@999999@"')) {
        Assert-True ($r.Diff.Contains($raw)) "raw token spelling preserved: $raw"
    }
    # Locate sections exclusively with the input sidecar lengths, never diff-like body text.
    $offset=0
    foreach ($s in $compact.Manifest.sections) {
        $literal=$compact.Diff.Substring($offset,$s.rendered_length)
        $offset+=$s.rendered_length
        if ($s.header -match '(existing\.json|executable\.json|reviews-other/|docs/other\.json|src/code\.ps1|tests/test-body\.ps1|raw\.txt|empty\.json|invalid\.json)') {
            Assert-True ($r.Diff.Contains($literal)) "ineligible section literal: $($s.header)"
        }
    }
    Assert-Throws { Render-Metadata -Base $head } 'wrong base identity rejected'
    Assert-Throws { Render-Metadata -Head $base } 'wrong head identity rejected'
    Assert-Throws { Render-Metadata -Text ($compact.Diff.Replace($long,'altered raw body')) } 'input body tamper rejected'
    $bad=Copy-Manifest $compact.Manifest
    $bad.sections=@($bad.sections)[0..($bad.sections.Count-2)]
    Assert-Throws { Render-Metadata -InputManifest $bad } 'input coverage gap rejected'
    foreach ($badRef in @('@2@','@00@','@+0@','@999999999@','@1@')) {
        # @1@ points at a short token: expansion must also enforce canonical shorter-only use.
        Assert-Throws { Restore-ReviewMetadataDiff -Diff ($r.Diff.Replace('@0@',$badRef)) -Manifest $r.Manifest } "invalid reference $badRef rejected"
    }
    foreach ($changed in @(
        $r.Diff.Replace('["REVIEWJSON",','["REVIEWJSONX",'),
        $r.Diff.Replace('"100644"','"100755"'),
        $r.Diff.Replace('café λ 😀','changed'),
        ($r.Diff+"extra`n"),
        $r.Diff.TrimEnd("`n")
    )) { Assert-Throws { Restore-ReviewMetadataDiff -Diff $changed -Manifest $r.Manifest } 'header/body/framing tamper rejected' }
    foreach ($field in @('base','head','input_sha256','rendered_sha256','input_manifest')) {
        $m=Copy-Manifest $r.Manifest
        Assert-True ($null -ne $m.PSObject.Properties[$field]) "manifest binds $field"
        if ($null -ne $m.PSObject.Properties[$field]) {
            $m.$field='tampered'
            Assert-Throws { Restore-ReviewMetadataDiff -Diff $r.Diff -Manifest $m } "manifest $field tamper rejected"
        }
    }
    foreach ($field in @('input_length','rendered_length')) {
        $m=Copy-Manifest $r.Manifest
        Assert-True ($null -ne $m.sections[0].PSObject.Properties[$field]) "manifest records $field"
        if ($null -ne $m.sections[0].PSObject.Properties[$field]) {
            $m.sections[0].$field=0
            Assert-Throws { Restore-ReviewMetadataDiff -Diff $r.Diff -Manifest $m } "manifest $field tamper rejected"
        }
    }
    $m=Copy-Manifest $r.Manifest
    $m.sections=@($m.sections)+@($m.sections)[0]
    Assert-Throws { Restore-ReviewMetadataDiff -Diff $r.Diff -Manifest $m } 'duplicate output coverage rejected'
    foreach ($path in @('../escape.json','docs/superpowers/reviews/../escape.json','docs/superpowers/reviews/unknown.json')) {
        $fake="diff --git a/$path b/$path`nnew file mode 100644`nindex 0000000..1234567`n--- /dev/null`n+++ b/$path`n@@ -0,0 +1,2 @@`n+[]`n+[]`n"
        # Unsafe paths pass through; plausible unknown eligible paths may fail Git verification.
        $refused=$false
        try {
            $c=ConvertTo-CompactReviewDiff -RepoRoot $root -BaseOid $base -HeadSha $head -Diff $fake
            $x=Render-Metadata -Text $c.Diff -InputManifest $c.Manifest
        } catch { $refused=$true }
        if ($refused) { Assert-True $true "$path refused by Git eligibility verification" }
        else { Assert-True (-not $x.Diff.Contains('["REVIEWJSON",')) "$path never compacted" }
    }
    # Resource boundaries must fail closed before walking unbounded tokens/strings.
    foreach ($payload in @(('"'+('x'*1048576)+'"'),('['+(('"x",'*16385))+'null]'))) {
        Put-Fixture 'docs/superpowers/reviews/limit.json' $payload
        Git-Fixture @('-c','core.autocrlf=false','add','.')
        Git-Fixture @('-c','user.name=geoffroth','-c','user.email=test@example.invalid','commit','-qm','limit')
        $limitHead=(Git-Fixture @('rev-parse','HEAD')).Trim()
        $p=Invoke-BoundedProcess -FileName $git -ArgList @('-C',$root,'diff','--no-ext-diff','--no-textconv','--no-color',$head,$limitHead) -TimeoutSec 30 -RequireProcessTreeRetirement
        Assert-Throws {
            $c=ConvertTo-CompactReviewDiff -RepoRoot $root -BaseOid $head -HeadSha $limitHead -Diff $p.Stdout.Replace("`r`n","`n")
            ConvertTo-ReviewMetadataDiff -RepoRoot $root -BaseOid $head -HeadSha $limitHead -Diff $c.Diff -CompactManifest $c.Manifest } 'oversize input or excessive token count refused'
    }
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^review-metadata-[0-9a-f]{32}$') { throw 'Unsafe fixture cleanup target' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-TestResult
