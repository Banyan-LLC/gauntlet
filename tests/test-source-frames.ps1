# Offline F/FL contract regressions. Do not dispatch a model or log source payloads.
. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference = 'Stop'
$realBoundedProcess = (Get-Command Invoke-BoundedProcess).ScriptBlock
foreach ($name in @('Get-CompactSourceFrameProtocol', 'ConvertTo-CompactSourceFrameBody',
    'ConvertFrom-CompactSourceFrameBody', 'Read-CompactSourceFrameRow')) {
    Assert-True ([bool](Get-Command $name -ErrorAction SilentlyContinue)) "source-frame API exists: $name"
}
Assert-True ((Get-Command ConvertTo-CompactReviewDiff).Parameters.ContainsKey('CompactSourceFrames')) 'source frames are explicit opt-in'
if ($script:Failures.Count) { Write-TestResult }

# Fixed immutable fake Git identities, with no repository mutation or history commands.
$repo = Split-Path $PSScriptRoot
$head = 'a' * 40
$base = 'b' * 40
$script:FrameBodies = @{}
$script:FrameModes = @{}
$script:FrameGitRequests = [Collections.Generic.List[string]]::new()
function Invoke-BoundedProcess {
    param($FileName, $ArgList, $TimeoutSec, [switch]$RequireProcessTreeRetirement)
    $script:FrameGitRequests.Add(($ArgList -join [char]31))
    $path = $ArgList[-1]
    $stdout = ''
    if ($ArgList -contains 'ls-tree') {
        if ($ArgList -contains $head) {
            $stdout = "$($script:FrameModes[$path]) blob $(Get-CompactReviewBlobHash $script:FrameBodies[$path])`t$path`n"
        }
    } elseif ($ArgList -contains 'cat-file') {
        $path = $path.Substring($path.IndexOf(':') + 1)
        $stdout = $script:FrameBodies[$path]
    } else { throw 'Unexpected fake Git request' }
    [pscustomobject]@{StartFailed=$false; TimedOut=$false; ExitCode=0; ProcessTreeRetired=$true; ErrorMessage=$null; Stdout=$stdout}
}
function New-FrameAddition([string]$Path, [string]$Body, [switch]$FullIndex, [string]$Mode='100644') {
    $script:FrameBodies[$Path] = $Body
    $script:FrameModes[$Path] = $Mode
    $blob = Get-CompactReviewBlobHash $Body
    $index = if ($FullIndex) { ('0' * 40) + '..' + $blob } else { '0000000..' + $blob.Substring(0,7) }
    $count = $Body.Split("`n").Length - 1
    $header = Get-CompactReviewOriginalHeader $Path $Mode $index $count
    [pscustomobject]@{Path=$Path; Body=$Body; Blob=$blob; Index=$index; Count=$count
        Patch=$header + '+' + $Body.Substring(0,$Body.Length-1).Replace("`n","`n+") + "`n"}
}
function Render-Frame([string]$Diff, [switch]$Lines) {
    ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $Diff `
        -CompactIndentation -CompactSourceFrames -CompactRepeatedLines:$Lines
}
function Copy-FrameManifest($Manifest) { $Manifest | ConvertTo-Json -Depth 40 | ConvertFrom-Json }
function Split-FrameParts($Result) {
    $cursor = 0
    foreach ($section in $Result.Manifest.sections) {
        $part = $Result.Diff.Substring($cursor,$section.rendered_length)
        $cursor += $section.rendered_length
        [pscustomobject]@{Section=$section; Text=$part}
    }
}
function Bind-FrameParts($Manifest, [string[]]$Parts) {
    for ($i=0; $i -lt $Parts.Count; $i++) {
        $Manifest.sections[$i].rendered_length = $Parts[$i].Length
        $Manifest.sections[$i].rendered_sha256 = Get-ReviewTextHash $Parts[$i]
    }
    $text = $Parts -join ''
    $Manifest.rendered_sha256 = Get-ReviewTextHash $text
    $text
}

# Independent adapter oracle: only frame headers and leading indentation may differ.
# Do not call a production body decoder to derive the expected legacy representation.
function Assert-LegacyFrameAdapter($Framed, $Legacy, [string]$Name) {
    $derived = Copy-FrameManifest $Framed.Manifest
    $derived.PSObject.Properties.Remove('source_frame_version')
    $parts = @()
    foreach ($part in @(Split-FrameParts $Framed)) {
        $text = $part.Text
        $section = $part.Section
        if ($section.encoding -cin @('source-frame','source-frame-lines')) {
            $at = $text.IndexOf("`n")
            $header = @($text.Substring(0,$at) | ConvertFrom-Json)
            $kind = if ($header[0] -ceq 'F') { 'INDENT' } else { 'INDENT_LINES' }
            $legacyHeader = @($kind,$header[1],'100644',('0000000..'+$header[2]),$header[3])
            if ($kind -ceq 'INDENT_LINES') { $legacyHeader += @($header[4],$header[5]) }
            $body = $text.Substring($at+1)
            $cursor = 0
            $rows = [Text.StringBuilder]::new()
            for ($i=0; $i -lt $section.count; $i++) {
                $end = $body.IndexOf("`n",$cursor)
                if ($end -lt 0) { throw 'Independent adapter found missing LF' }
                $row = $body.Substring($cursor,$end-$cursor)
                $cursor = $end+1
                $groups = 0
                $skip = 0
                if ($row.Length -gt 0) {
                    $symbol = @('^','+','`','%','<','>',';','=')
                    $index = [array]::IndexOf($symbol,[string]$row[0])
                    if ($index -ge 0) { $groups=$index+1; $skip=1 }
                    elseif ($row -cmatch '^\|([1-9][0-9]*)\|') {
                        $groups=[int]$Matches[1]; $skip=$Matches[0].Length
                        if ($groups -le 8) { throw 'Independent adapter found noncanonical numeric prefix' }
                    }
                }
                [void]$rows.Append(("`t" * $groups)).Append($row.Substring($skip)).Append("`n")
            }
            if ($cursor -ne $body.Length) { throw 'Independent adapter found excess rows' }
            $text = (ConvertTo-Json -InputObject $legacyHeader -Compress) + "`n" + $rows.ToString()
        }
        $parts += $text
    }
    for ($i=0; $i -lt $derived.sections.Count; $i++) {
        if ($derived.sections[$i].encoding -ceq 'source-frame') { $derived.sections[$i].encoding='indent' }
        elseif ($derived.sections[$i].encoding -ceq 'source-frame-lines') { $derived.sections[$i].encoding='indent-lines' }
    }
    $restored = Bind-FrameParts $derived $parts
    Assert-True ($restored -ceq $Legacy.Diff) "$Name adapter restores exact prior legacy bytes"
    Assert-True (($derived | ConvertTo-Json -Depth 40 -Compress) -ceq ($Legacy.Manifest | ConvertTo-Json -Depth 40 -Compress)) "$Name adapter preserves original identities and all dictionary counters"
    Assert-True ((Restore-CompactReviewDiff -Diff $restored -Manifest $derived) -ceq
        (Restore-CompactReviewDiff -Diff $Legacy.Diff -Manifest $Legacy.Manifest)) "$Name derived legacy restore agrees"
}

# Match only the error category, never emit exception text or a source payload.
function Assert-FrameReject([scriptblock]$Block, [string]$Pattern, [string]$Name) {
    $message = $null
    try { & $Block | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($null -ne $message -and $message -match $Pattern) $Name
}

# Independent literal codec vector: '+' is eight spaces; tilde is never indentation.
$alphabet = @('^', '+', '`', '%', '<', '>', ';', '=')
$plain = ''; $wire = ''
for ($groups=1; $groups -le 10; $groups++) {
    foreach ($remainder in 0..3) {
        $prefix = if ($groups -le 8) { $alphabet[$groups-1] } else { "|$groups|" }
        $plain += (' ' * (4*$groups+$remainder)) + "token cafe λ 😀`tinterior  `n"
        $wire += $prefix + (' ' * $remainder) + "token cafe λ 😀`tinterior  `n"
    }
}
$plain += "`n   `n    val raw = `"`"`"`n        [`"F`",`"FL`",`"diff --git`"]  `n    `"`"`"`n"
$wire += "`n   `n^val raw = `"`"`"`n+[`"F`",`"FL`",`"diff --git`"]  `n^`"`"`"`n"
$count = $plain.Split("`n").Length - 1
Assert-True ((ConvertTo-CompactSourceFrameBody -Body $plain -Count $count) -ceq $wire) 'eight symbols, numeric nine-plus, remainders and literal content encode exactly'
Assert-True ((ConvertFrom-CompactSourceFrameBody -Body $wire -Count $count) -ceq $plain) 'raw strings Unicode blank rows interior TAB and trailing spaces survive'
foreach ($literal in ($alphabet + @('|0|', '|8|', '|9|', '|09|', '|123|'))) {
    $body = "    ordinary first row`n        ${literal}literal source row`n"
    Assert-True ($null -eq (ConvertTo-CompactSourceFrameBody -Body $body -Count 2)) 'reserved source core forces whole-body fallback'
}
foreach ($body in @("`tactual leading TAB`n", "  `tmixed leading TAB`n", "    first`n `t `n")) {
    Assert-True ($null -eq (ConvertTo-CompactSourceFrameBody -Body $body -Count ($body.Split("`n").Length-1))) 'original leading TAB forces fallback'
}
Assert-True ((ConvertTo-CompactSourceFrameBody -Body "    |not-digits|literal`n" -Count 1) -ceq "^|not-digits|literal`n") 'non-numeric bars remain literal'
foreach ($bad in @("|0|x`n", "|1|x`n", "|8|x`n", "|09|x`n", "|999999999999999999999|x`n",
    "^    x`n", "    x`n", "^`tx`n", "^x`r`n", "^x", "^x`nextra`n")) {
    Assert-Throws { ConvertFrom-CompactSourceFrameBody -Body $bad -Count 1 } 'noncanonical malformed or excess F rows rejected'
}
Assert-Throws { ConvertFrom-CompactSourceFrameBody -Body "x`n" -Count 0 } 'zero row count is not a source frame'
foreach ($bad in @("x", "x`r`n", "x`nextra`n")) {
    Assert-Throws { ConvertTo-CompactSourceFrameBody -Body $bad -Count 1 } 'encoder refuses malformed counted rows'
}
Assert-Throws { ConvertFrom-CompactSourceFrameBody -Body "^x`n" -Count 2147483647 } 'hostile row count refused'
Assert-Throws { ConvertFrom-CompactSourceFrameBody -Body "^x`n" -Count 1 -MaxDecodedLength 1048577 } 'caller cannot raise one-MiB body cap'
Assert-Throws { ConvertFrom-CompactSourceFrameBody -Body "^x`n" -Count 1 -MaxDecodedLength 5 } 'decoded length checked before append'
Assert-True ((ConvertFrom-CompactSourceFrameBody -Body "^x`n" -Count 1 -MaxDecodedLength 6) -ceq "    x`n") 'exact decoded boundary accepted'
$exact = ('x' * 1048575) + "`n"
Assert-Eq (ConvertFrom-CompactSourceFrameBody -Body $exact -Count 1).Length 1048576 'exact one-MiB source accepted'
Assert-Throws { ConvertFrom-CompactSourceFrameBody -Body ('^' + ('x' * 1048572) + "`n") -Count 1 } 'indent expansion cannot exceed one MiB'
Assert-Throws { ConvertFrom-CompactSourceFrameBody -Body "|262144|x`n" -Count 1 } 'numeric expansion checked before allocation'

$core = 'abcdefghijklmnop'
foreach ($pair in @(@('', '~0=abcdefghijklmnop'), @('', '~0~'), @('+', '~0=abcdefghijklmnop'), @('+', '~0~'))) {
    $row = Read-CompactSourceFrameRow -Body ($pair[0]+$pair[1]+"`n") -Position 0
    Assert-True ($row.Prefix -ceq $pair[0]) 'F prefix remains separate from declaration/reference core'
    Assert-True ($row.Core -ceq $pair[1]) 'tilde begins code core at zero or eight-space indentation'
    Assert-Eq $row.Next ($pair[0].Length+$pair[1].Length+1) 'row cursor consumes one LF only'
}
$row = Read-CompactSourceFrameRow -Body "|9|  ~0~`n" -Position 0
Assert-True ($row.Prefix -ceq '|9|  ') 'numeric prefix and remainder stay literal'
Assert-True ($row.Core -ceq '~0~') 'numeric prefix does not swallow dictionary ID'
Assert-Throws { Read-CompactSourceFrameRow -Body (' ' * 1048576) -Position 0 } 'LF search precedes prefix work'

$a = New-FrameAddition 'src/a.kt' $plain
$b = New-FrameAddition 'src/b.java' $plain
$c = New-FrameAddition 'src/c.asm' "    lda #<some_long_literal_symbol`n    rts`n"
$diff = $a.Patch + $b.Patch + $c.Patch
$script:FrameGitRequests.Clear()
$legacy = ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $diff -CompactIndentation
$legacyRequests = $script:FrameGitRequests.ToArray()
$script:FrameGitRequests.Clear()
$r = Render-Frame $diff
Assert-True (($script:FrameGitRequests.ToArray() -join "`n") -ceq ($legacyRequests -join "`n")) 'outer adapter adds no Git calls and changes no provenance arguments'
Assert-True ((Restore-CompactReviewDiff -Diff $r.Diff -Manifest $r.Manifest) -ceq $diff) 'F restores exact complete ordered diff'
Assert-True ((Restore-CompactReviewDiff -Diff $r.Diff -Manifest (Copy-FrameManifest $r.Manifest)) -ceq $diff) 'serialized F manifest roundtrip'
Assert-LegacyFrameAdapter $r $legacy 'F'
Assert-Eq $r.Manifest.version 1 'root schema stays one'
Assert-Eq $r.Manifest.source_frame_version 1 'F root version bound'
Assert-True ($r.Diff.Length -lt $legacy.Diff.Length) 'whole UTF-16 representation shortens'
Assert-True ([Text.Encoding]::UTF8.GetByteCount($r.Diff) -lt [Text.Encoding]::UTF8.GetByteCount($legacy.Diff)) 'whole UTF-8 representation shortens'
foreach ($part in @(Split-FrameParts $r)) {
    $h = $part.Text.Substring(0,$part.Text.IndexOf("`n")) | ConvertFrom-Json
    Assert-Eq $h.Count 4 'F has four header fields'
    Assert-Eq $h[0] 'F' 'F discriminator'
    Assert-Eq $h[2] $part.Section.blob.Substring(0,7) 'field two is the exact seven-lowercase-hex HEAD abbreviation'
    Assert-True ($part.Section.blob -cmatch '^[0-9a-f]{40}$') 'manifest retains complete HEAD blob proof'
    Assert-Eq $part.Section.mode '100644' 'mode is retained and implied by F'
    Assert-True ($part.Section.index -ceq ('0000000..'+$part.Section.blob.Substring(0,7))) 'actual original seven-zero/seven-hex index stays in manifest'
    Assert-Eq $part.Section.encoding 'source-frame' 'F encoding explicit'
}
# The earlier full-index design does not qualify; keep the actual Git spelling.
$fullIndex = New-FrameAddition 'src/full-index.kt' $plain -FullIndex
$oldFull = ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $fullIndex.Patch -CompactIndentation
$newFull = Render-Frame $fullIndex.Patch
Assert-True ($newFull.Diff -ceq $oldFull.Diff) 'full forty-zero/full-blob index retains legacy framing'
Assert-True (($newFull.Manifest|ConvertTo-Json -Depth 40 -Compress) -ceq ($oldFull.Manifest|ConvertTo-Json -Depth 40 -Compress)) 'full-index fallback metadata unchanged'
Assert-True (-not [bool]$newFull.Manifest.PSObject.Properties['source_frame_version']) 'no outer version without eligible F index'
foreach ($index in @((('0'*6)+'..'+$a.Blob.Substring(0,7)), (('0'*8)+'..'+$a.Blob.Substring(0,7)),
    ('0000000..'+$a.Blob.Substring(0,8)), ('0000000..'+$a.Blob), (('0'*40)+'..'+$a.Blob.Substring(0,7)))) {
    $variant=$a.Patch.Replace($a.Index,$index)
    $before=ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $variant -CompactIndentation
    $after=Render-Frame $variant
    Assert-True ($after.Diff -ceq $before.Diff) 'other zero counts and abbreviation lengths retain legacy framing'
    Assert-True (($after.Manifest|ConvertTo-Json -Depth 40 -Compress) -ceq ($before.Manifest|ConvertTo-Json -Depth 40 -Compress)) 'nonbaseline index metadata unchanged'
}
foreach ($literal in ($alphabet + @('|9|', "`t"))) {
    $reserved = New-FrameAddition 'src/reserved.kt' ("    ordinary safe row`n    ${literal}literal source`n")
    $before = ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $reserved.Patch -CompactIndentation
    $after = Render-Frame $reserved.Patch
    Assert-True ($after.Diff -ceq $before.Diff) 'reserved core and original TAB use whole-file old representation'
    Assert-True (($after.Manifest|ConvertTo-Json -Depth 40 -Compress) -ceq ($before.Manifest|ConvertTo-Json -Depth 40 -Compress)) 'fallback metadata exact'
}
foreach ($path in @('docs/no.kt', 'src/no.py')) {
    $unsupported = New-FrameAddition $path $plain
    $before = ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $unsupported.Patch -CompactIndentation
    Assert-True ((Render-Frame $unsupported.Patch).Diff -ceq $before.Diff) 'unsupported path/extension stays legacy'
}
$off = ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $diff -CompactIndentation -CompactSourceFrames:$false
Assert-True ($off.Diff -ceq $legacy.Diff) 'switch off preserves exact output'
Assert-True (($off.Manifest|ConvertTo-Json -Depth 40 -Compress) -ceq ($legacy.Manifest|ConvertTo-Json -Depth 40 -Compress)) 'switch off preserves exact manifest'
$legacyLines = ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $diff -CompactIndentation -CompactRepeatedLines
$offLines = ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $diff -CompactIndentation -CompactRepeatedLines -CompactSourceFrames:$false
Assert-True ($offLines.Diff -ceq $legacyLines.Diff) 'switch off preserves existing source-line output'
Assert-True (($offLines.Manifest|ConvertTo-Json -Depth 40 -Compress) -ceq ($legacyLines.Manifest|ConvertTo-Json -Depth 40 -Compress)) 'switch off preserves existing source-line coverage'
Assert-Eq (Get-ReviewTextHash (Get-CompactReviewProtocol)) '5f86531ba9d59cd56a2aa789acb653d0899e75aaae2dd4a41f9098f3ee674b6f' 'ADDED protocol hash unchanged'
Assert-Eq (Get-ReviewTextHash (Get-CompactIndentationProtocol)) 'd58a6eae0c5764f4ccb99fbe10f720740a76ffb1eb4f387952ae1676cdff5a3c' 'INDENT protocol hash unchanged'
Assert-Eq (Get-ReviewTextHash (Get-ReviewMetadataProtocol)) '35bc6b04c9c2d689acfad4f6ac9e4ebab01326a7615ea7c15d223a1e19a0f983' 'metadata protocol hash unchanged'
Assert-Eq (Get-ReviewTextHash (Get-CompactSourceLineProtocol)) '9261e72813f4c0ccf630a79aee6ba72a20e344462c3d89b581111f1bd4f4f9af' 'legacy source-line protocol hash unchanged'
Assert-True ((Get-CompactSourceFrameProtocol).Length -gt 0) 'separate F/FL protocol exists'

# Independent hand-authored FL vector with both zero- and eight-space dictionary cores.
$expected = "$core`n        $core`n    $core`n                                      $core`n"
$vector = New-FrameAddition 'src/vector.kt' $expected
$single = Render-Frame $vector.Patch
$m = Copy-FrameManifest $single.Manifest
$section = $m.sections[0]
$section.encoding = 'source-frame-lines'
$section | Add-Member -NotePropertyName source_line_start -NotePropertyValue 0
$section | Add-Member -NotePropertyName source_line_end -NotePropertyValue 1
$m | Add-Member -NotePropertyName source_line_version -NotePropertyValue 1
$m | Add-Member -NotePropertyName source_line_dictionary_count -NotePropertyValue 1
$m | Add-Member -NotePropertyName source_line_dictionary_utf16 -NotePropertyValue 16
$flBody = "~0=$core`n+~0~`n^~0~`n|9|  ~0~`n"
$fl = (ConvertTo-Json -InputObject @('FL',$section.path,$section.blob.Substring(0,7),4,0,1) -Compress) + "`n" + $flBody
$fl = Bind-FrameParts $m @($fl)
Assert-True ((Restore-CompactReviewDiff -Diff $fl -Manifest $m) -ceq $vector.Patch) 'literal FL vector preserves cross-indent source without a decoder-derived oracle'
$repeatBody = "    $core`n        $core`n" * 16
$first = New-FrameAddition 'src/shared-a.kt' $repeatBody
$second = New-FrameAddition 'src/shared-b.kt' $repeatBody
$lines = Render-Frame ($first.Patch+$second.Patch) -Lines
$flParts = @(Split-FrameParts $lines)
$legacyShared = ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff ($first.Patch+$second.Patch) -CompactIndentation -CompactRepeatedLines
Assert-LegacyFrameAdapter $lines $legacyShared 'FL'

Assert-True ((Restore-CompactReviewDiff -Diff $lines.Diff -Manifest $lines.Manifest) -ceq ($first.Patch+$second.Patch)) 'FL renderer preserves shared cross-file cores'
Assert-Eq @($lines.Manifest.sections|Where-Object encoding -CEQ 'source-frame-lines').Count 2 'both shared source frames become FL'
foreach ($part in $flParts) {
    $h = @($part.Text.Substring(0,$part.Text.IndexOf("`n")) | ConvertFrom-Json)
    Assert-Eq $h.Count 6 'FL has six fields'
    Assert-Eq $h[0] 'FL' 'FL discriminator'
    Assert-Eq $h[2] $part.Section.blob.Substring(0,7) 'FL carries exact seven-hex abbreviation'
    Assert-Eq $h[3] $part.Section.count 'FL count remains typed and unchanged'
    Assert-Eq $h[4] $part.Section.source_line_start 'FL start remains unchanged'
    Assert-Eq $h[5] $part.Section.source_line_end 'FL end remains unchanged'
}
Assert-Eq $lines.Manifest.sections[1].source_line_start $lines.Manifest.sections[0].source_line_end 'ordered dictionary range carries between files'
Assert-True ([bool]($lines.Diff -cmatch '\+~[0-9]+[=~]')) 'eight-space plus prefix and dictionary label stay separate'

# Literal collision pairs are legal F source, NEVER FL declarations or references.
# Existing legacy reserved-core checks choose INDENT, then the final adapter wraps it as F.
# The unchanged source-line pass must neither declare nor count these literal collision cores.
foreach ($indent in @(0,4,8,38)) {
    foreach ($literal in @('~0=literal dictionary-looking source text', '~0~')) {
        $collisionBody = "    eligible repeated code before collision`n" * 8
        $collisionBody += (' '*$indent) + $literal + "`n"
        $collision = New-FrameAddition 'src/collision.kt' $collisionBody
        $alone = Render-Frame $collision.Patch
        $withLines = Render-Frame $collision.Patch -Lines
        Assert-True ($withLines.Diff -ceq $alone.Diff) 'legacy reserved-core fallback becomes F rather than FL'
        Assert-True (($withLines.Manifest|ConvertTo-Json -Depth 40 -Compress) -ceq ($alone.Manifest|ConvertTo-Json -Depth 40 -Compress)) 'collision fallback changes neither dictionary metadata nor F coverage'
        Assert-Eq $withLines.Manifest.sections[0].encoding 'source-frame' 'literal tilde is not mistaken for indentation'
        Assert-True ((Restore-CompactReviewDiff -Diff $withLines.Diff -Manifest $withLines.Manifest) -ceq $collision.Patch) 'literal declaration/reference source roundtrip exact'
        $following = Render-Frame ($collision.Patch+$first.Patch) -Lines
        Assert-Eq $following.Manifest.sections[1].source_line_start 0 'legacy collision fallback does not pollute shared dictionary start'
        Assert-Eq $following.Manifest.source_line_dictionary_count 1 'only following valid core enters dictionary'
        Assert-True ((Restore-CompactReviewDiff -Diff $following.Diff -Manifest $following.Manifest) -ceq ($collision.Patch+$first.Patch)) 'collision plus later dictionary frame roundtrip exact'
    }
}

# The adapter wraps only INDENT / INDENT_LINES. ADDED / LINES remain byte-identical.
foreach ($source in @(("unindented_literal_core_abcdefghijklmnop`n" * 16),
    ("`toriginal_TAB_abcdefghijklmnop`n" * 16))) {
    $unwrapped = New-FrameAddition 'src/unwrapped.kt' $source
    foreach ($useLines in @($false,$true)) {
        $before = ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $unwrapped.Patch -CompactIndentation -CompactRepeatedLines:$useLines
        $after = Render-Frame $unwrapped.Patch -Lines:$useLines
        Assert-True ($after.Diff -ceq $before.Diff) 'ADDED and LINES are not wrapped even with eligible original index'
        Assert-True (($after.Manifest|ConvertTo-Json -Depth 40 -Compress) -ceq ($before.Manifest|ConvertTo-Json -Depth 40 -Compress)) 'unwrapped source metadata remains exact'
        Assert-True (-not [bool]$after.Manifest.PSObject.Properties['source_frame_version']) 'no outer version for unwrapped legacy kinds'
    }
}

# Rebind outer and section hashes: identity and canonical headers must still reject tampering.
foreach ($field in @('mode','path','count','blob','index','abbreviation','encoding')) {
    $tampered = Copy-FrameManifest $r.Manifest
    $parts = @(Split-FrameParts $r | ForEach-Object Text)
    $s = $tampered.sections[0]; $at = $parts[0].IndexOf("`n")
    $h = @($parts[0].Substring(0,$at)|ConvertFrom-Json)
    switch ($field) {
        'mode' { $s.mode='100755' }
        'path' { $s.path='../escape.kt'; $h[1]='../escape.kt' }
        'count' { $s.count=2147483647; $h[3]=2147483647 }
        'blob' { $s.blob=$s.blob.Substring(0,7)+('f'*33) }
        'index' { $s.index=('0'*40)+'..'+$s.blob }
        'abbreviation' { $h[2]='fffffff'; $s.index='0000000..fffffff' }
        'encoding' { $s.encoding='indent' }
    }
    $parts[0]=(ConvertTo-Json -InputObject $h -Compress)+"`n"+$parts[0].Substring($at+1)
    $changed = Bind-FrameParts $tampered $parts
    Assert-Throws { Restore-CompactReviewDiff -Diff $changed -Manifest $tampered } 'rebound F mode path count blob index or encoding attack refused'
}
# Outer headers use only four/six fields and a lowercase seven-hex string.
foreach ($abbr in @('abcdef','abcdef01','ABCDEF0','0000000..abcdef0')) {
    $tampered = Copy-FrameManifest $r.Manifest
    $parts = @(Split-FrameParts $r | ForEach-Object Text)
    $at = $parts[0].IndexOf("`n")
    $h = @($parts[0].Substring(0,$at)|ConvertFrom-Json)
    $h[2] = $abbr
    $parts[0] = (ConvertTo-Json -InputObject $h -Compress)+"`n"+$parts[0].Substring($at+1)
    $part = Bind-FrameParts $tampered $parts
    Assert-Throws { Restore-CompactReviewDiff -Diff $part -Manifest $tampered } 'outer abbreviation spelling cannot be rebound'
}
foreach ($legacyShape in @($false,$true)) {
    $tampered = Copy-FrameManifest $r.Manifest
    $parts = @(Split-FrameParts $r | ForEach-Object Text)
    $s = $tampered.sections[0]
    $at = $parts[0].IndexOf("`n")
    $h = if ($legacyShape) { @('F',$s.path,$s.mode,$s.blob,$s.count) } else { @('F',$s.path,$s.blob.Substring(0,7)) }
    $parts[0] = (ConvertTo-Json -InputObject $h -Compress)+"`n"+$parts[0].Substring($at+1)
    $part = Bind-FrameParts $tampered $parts
    Assert-Throws { Restore-CompactReviewDiff -Diff $part -Manifest $tampered } 'F rejects old five-field and truncated three-field shapes'
    $tampered = Copy-FrameManifest $m
    $s = $tampered.sections[0]
    $h = if ($legacyShape) { @('FL',$s.path,$s.mode,$s.blob,4,0,1) } else { @('FL',$s.path,$s.blob.Substring(0,7),4,0) }
    $part = (ConvertTo-Json -InputObject $h -Compress)+"`n"+$flBody
    $part = Bind-FrameParts $tampered @($part)
    Assert-Throws { Restore-CompactReviewDiff -Diff $part -Manifest $tampered } 'FL rejects old seven-field and truncated five-field shapes'
}
$changed = $r.Diff.Replace('token cafe','token fake')
$tampered = Copy-FrameManifest $r.Manifest
$cursor=0; $parts=@()
foreach ($s in $tampered.sections) { $parts += $changed.Substring($cursor,$s.rendered_length); $cursor += $s.rendered_length }
$changed = Bind-FrameParts $tampered $parts
Assert-Throws { Restore-CompactReviewDiff -Diff $changed -Manifest $tampered } 'rebound source still verifies full blob'
$tampered = Copy-FrameManifest $lines.Manifest
$tampered.sections = @($tampered.sections[1],$tampered.sections[0])
$changed = Bind-FrameParts $tampered @($flParts[1].Text,$flParts[0].Text)
Assert-Throws { Restore-CompactReviewDiff -Diff $changed -Manifest $tampered } 'ordered dictionary sections cannot be rebound and swapped'
foreach ($field in @('source_frame_version','source_line_version','source_line_dictionary_count','source_line_dictionary_utf16')) {
    $tampered = Copy-FrameManifest $m
    $tampered.$field = if ($field -like '*version') { 2 } else { 2147483647 }
    Assert-Throws { Restore-CompactReviewDiff -Diff $fl -Manifest $tampered } 'invalid FL version or dictionary capacity refused'
}
foreach ($badBody in @("~0~`n+~0=$core`n^~0~`n|9|  ~0~`n", "~00=$core`n+~0~`n^~0~`n|9|  ~0~`n",
    "~0=$core`n+~1~`n^~0~`n|9|  ~0~`n", "~0=short`n+~0~`n^~0~`n|9|  ~0~`n")) {
    $tampered = Copy-FrameManifest $m; $s=$tampered.sections[0]
    $part=(ConvertTo-Json -InputObject @('FL',$s.path,$s.blob.Substring(0,7),4,0,1) -Compress)+"`n"+$badBody
    $part=Bind-FrameParts $tampered @($part)
    Assert-Throws { Restore-CompactReviewDiff -Diff $part -Manifest $tampered } 'rebound FL forward noncanonical unknown or short declaration refused'
}
$tampered = Copy-FrameManifest $r.Manifest
foreach ($s in $tampered.sections) { $s.original_length=2097152 }
Assert-FrameReject { Restore-CompactReviewDiff -Diff $r.Diff -Manifest $tampered } 'budget' 'four-MiB aggregate bound checked before reconstruction'

# Outer types must be checked before dispatch into the legacy restore path.
foreach ($field in @('version','source_frame_version')) {
    $tampered = Copy-FrameManifest $r.Manifest
    $tampered.$field = '1'
    Assert-Throws { Restore-CompactReviewDiff -Diff $r.Diff -Manifest $tampered } 'outer version requires integer type'
}
$tampered = Copy-FrameManifest $r.Manifest
$parts = @(Split-FrameParts $r | ForEach-Object Text)
$section = $tampered.sections[0]
$at = $parts[0].IndexOf("`n")
$header = @($parts[0].Substring(0,$at)|ConvertFrom-Json)
$header[3] = [string]$section.count
$section.count = [string]$section.count
$parts[0] = (ConvertTo-Json -InputObject $header -Compress) + "`n" + $parts[0].Substring($at+1)
$part = Bind-FrameParts $tampered $parts
Assert-Throws { Restore-CompactReviewDiff -Diff $part -Manifest $tampered } 'outer count requires integer type even when rebound'

# Charge TAB-prefix materialization against the source section before constructing derived text.
$tampered = Copy-FrameManifest $r.Manifest
$parts = @(Split-FrameParts $r | ForEach-Object Text)
$section = $tampered.sections[0]
$at = $parts[0].IndexOf("`n")
$parts[0] = $parts[0].Substring(0,$at+1) + "|10000|x`n" + ("x`n" * ($section.count-1))
$part = Bind-FrameParts $tampered $parts
Assert-FrameReject { Restore-CompactReviewDiff -Diff $part -Manifest $tampered } 'budget|bounds' 'derived legacy append cannot exceed original section length before blob checks'

# Existing source-line dictionary bounds remain in force for the shared FL dictionary.
$full = New-CompactSourceLineState
for ($i=0; $i -lt 65536; $i++) {
    $value='entry-'+$i.ToString('D10',[Globalization.CultureInfo]::InvariantCulture)
    $full.Cores.Add($value); [void]$full.Known.Add($value); $full.Characters += [long]$value.Length
}
Assert-True ((ConvertFrom-CompactSourceLineBody -Body "~65535~`n" -Count 1 -Start 65536 -End 65536 -State $full) -ceq "entry-0000065535`n") 'largest dictionary ID remains readable'
Assert-Throws { ConvertFrom-CompactSourceLineBody -Body "~65536=$core`n" -Count 1 -Start 65536 -End 65536 -State $full } 'entry cap cannot increase'
Assert-Eq $full.Cores.Count 65536 'entry refusal adds no dictionary entry'
$units = New-CompactSourceLineState
foreach ($i in 0..3) {
    $value=('x'*1048574)+[string]$i
    $units.Cores.Add($value); [void]$units.Known.Add($value); $units.Characters += [long]$value.Length
}
Assert-Throws { ConvertFrom-CompactSourceLineBody -Body "~4=$core`n" -Count 1 -Start 4 -End 5 -State $units } 'four-MiB retained dictionary cap cannot increase'
Assert-Eq $units.Cores.Count 4 'unit refusal adds no dictionary entry'
$tampered = Copy-FrameManifest $m; $s=$tampered.sections[0]
$huge="~0=$core`n|262144|~0~`n^~0~`n+~0~`n"
$part=(ConvertTo-Json -InputObject @('FL',$s.path,$s.blob.Substring(0,7),4,0,1) -Compress)+"`n"+$huge
$part=Bind-FrameParts $tampered @($part)
Assert-FrameReject { Restore-CompactReviewDiff -Diff $part -Manifest $tampered } 'budget|bounds' 'FL decoded body cap applies after BOTH layers before blob verification'

# Bounded native malformed-row regression; uses the real saved owner, not fake Git.
$library=(Resolve-Path "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1").Path.Replace("'","''")
$child=@(
    ". '$library'",
    'try {',
    ' Read-CompactSourceFrameRow -Body ('' ''*1048576) -Position 0 | Out-Null',
    ' exit 3',
    '} catch {',
    ' if($_.Exception.Message -match ''[Tt]runcat|[Mm]issing.*LF''){exit 0}',
    ' exit 4',
    '}'
) -join "`n"
$run=& $realBoundedProcess -FileName ([Environment]::ProcessPath) -ArgList @('-NoProfile','-Command',$child) -TimeoutSec 5 -RequireProcessTreeRetirement
Assert-True (-not $run.StartFailed -and -not $run.TimedOut) 'one-MiB whitespace rejects inside native deadline'
Assert-Eq $run.ExitCode 0 'missing LF gives explicit truncation evidence'
Assert-True $run.ProcessTreeRetired 'malformed-row native child is retired'
Write-TestResult
