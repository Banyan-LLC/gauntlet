# Offline source-word contracts. Fake Git only; never print payloads or dispatch a model.
. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference = 'Stop'
foreach ($name in @('Get-CompactSourceWordProtocol','ConvertTo-CompactSourceWordBody','ConvertFrom-CompactSourceWordBody')) {
    Assert-True ([bool](Get-Command $name -ErrorAction SilentlyContinue)) "source-word API exists: $name"
}
Assert-True ((Get-Command ConvertTo-CompactReviewDiff).Parameters.ContainsKey('CompactSourceWords')) 'words require explicit opt-in'
if ($script:Failures.Count) { Write-TestResult }

$repo=Split-Path $PSScriptRoot
$head='a'*40; $base='b'*40
$script:WordBodies=@{}
$script:WordRequests=[Collections.Generic.List[string]]::new()
function Invoke-BoundedProcess {
    param($FileName,$ArgList,$TimeoutSec,[switch]$RequireProcessTreeRetirement)
    $script:WordRequests.Add(($ArgList -join [char]31))
    $path=$ArgList[-1]; $stdout=''
    if ($ArgList -contains 'ls-tree') {
        if ($ArgList -contains $head) { $stdout="100644 blob $(Get-CompactReviewBlobHash $script:WordBodies[$path])`t$path`n" }
    } elseif ($ArgList -contains 'cat-file') {
        $path=$path.Substring($path.IndexOf(':')+1); $stdout=$script:WordBodies[$path]
    } else { throw 'Unexpected fake Git request' }
    [pscustomobject]@{StartFailed=$false;TimedOut=$false;ExitCode=0;ProcessTreeRetired=$true;ErrorMessage=$null;Stdout=$stdout}
}
function New-WordAddition([string]$Path,[string]$Body) {
    $script:WordBodies[$Path]=$Body
    $blob=Get-CompactReviewBlobHash $Body
    $count=$Body.Split("`n").Length-1
    $header=Get-CompactReviewOriginalHeader $Path '100644' ('0000000..'+$blob.Substring(0,7)) $count
    [pscustomobject]@{Path=$Path;Body=$Body;Blob=$blob;Count=$count
        Patch=$header+'+'+$Body.Substring(0,$Body.Length-1).Replace("`n","`n+")+"`n"}
}
function Render-Word([string]$Diff,[switch]$Lines,[switch]$Off) {
    ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $Diff `
        -CompactIndentation -CompactSourceFrames -CompactRepeatedLines:$Lines -CompactSourceWords:(-not $Off)
}
function Copy-WordManifest($Manifest) { $Manifest|ConvertTo-Json -Depth 60|ConvertFrom-Json }
function Split-WordParts($Result) {
    $cursor=0
    foreach ($section in $Result.Manifest.sections) {
        $part=$Result.Diff.Substring($cursor,$section.rendered_length); $cursor+=$section.rendered_length
        [pscustomobject]@{Section=$section;Text=$part}
    }
}
function Bind-WordParts($Manifest,[string[]]$Parts) {
    for ($i=0;$i -lt $Parts.Count;$i++) {
        $Manifest.sections[$i].rendered_length=$Parts[$i].Length
        $Manifest.sections[$i].rendered_sha256=Get-ReviewTextHash $Parts[$i]
    }
    $text=$Parts -join ''; $Manifest.rendered_sha256=Get-ReviewTextHash $text
    $text
}
function Assert-WordSame($Actual,$Expected,[string]$Name) {
    Assert-True ($Actual.Diff -ceq $Expected.Diff) "$Name exact output"
    Assert-True (($Actual.Manifest|ConvertTo-Json -Depth 60 -Compress) -ceq
        ($Expected.Manifest|ConvertTo-Json -Depth 60 -Compress)) "$Name exact manifest"
}

# Direct codec contract: a local table, single expansion, literal near markers.
$plain=("^assertEquals(failure, assertEquals); // failure λ😀 @near @- @`n"*24)
$encoded=ConvertTo-CompactSourceWordBody -Body $plain -Count 24
Assert-True ($null -ne $encoded) 'profitable body receives local word table'
Assert-True (@($encoded.Dictionary).Count -ge 2) 'both profitable repeated words selected'
Assert-True ((ConvertFrom-CompactSourceWordBody -Body $encoded.Body -Count 24 -Dictionary $encoded.Dictionary) -ceq $plain) 'body roundtrips Unicode comments and near markers'
foreach ($marker in @('@0','@01','@65536','@9suffix','λ@0','"@0"')) {
    $collision=$plain+"^literal $marker`n"
    Assert-True ($null -eq (ConvertTo-CompactSourceWordBody -Body $collision -Count 25)) 'any original ASCII digit marker forces whole-file fallback'
}
foreach ($bad in @('@01 @0','@65536 @0','@1 @1','x@0 @0','@0x @0','_@0 @0','@0_ @0','@-1 @0','@+0 @0','@٠ @0','@0 assertEquals')) {
    Assert-Throws { ConvertFrom-CompactSourceWordBody -Body ($bad+"`n") -Count 1 -Dictionary @('assertEquals') } 'malformed unknown boundary or unexpanded selected word fails closed'
}
foreach ($table in @(@('assertEquals','assertEquals'),@('ab'),@('bad-word'),@('@0'),@('λword'),@('123word'))) {
    Assert-Throws { ConvertFrom-CompactSourceWordBody -Body "@0 @0`n" -Count 1 -Dictionary $table } 'invalid duplicate or recursive table rejected'
}
Assert-Throws { ConvertFrom-CompactSourceWordBody -Body "@0 literal`n" -Count 1 -Dictionary @('assertEquals') } 'selected word requires two references'
Assert-Throws { ConvertFrom-CompactSourceWordBody -Body "@0 @0`n" -Count 1 -Dictionary @('assertEquals') -MaxDecodedLength 4 } 'expansion precharged before append'
Assert-Throws { ConvertFrom-CompactSourceWordBody -Body "@0 @0`n" -Count 1 -Dictionary @('assertEquals') -MaxDecodedLength 1048577 } 'caller cannot raise body cap'
Assert-True ((ConvertFrom-CompactSourceWordBody -Body "λ@0é @0`n" -Count 1 -Dictionary @('assertEquals')) -ceq "λassertEqualsé assertEquals`n") 'word boundaries use ASCII rather than Unicode categories'
foreach ($badBody in @('no LF',"x`r`n","x`nextra`n")) {
    Assert-Throws { ConvertFrom-CompactSourceWordBody -Body $badBody -Count 1 -Dictionary @('assertEquals') } 'counted LF grammar retained'
}
$oversize=('assertEquals '*90000)+"`n"
Assert-Throws { ConvertFrom-CompactSourceWordBody -Body $oversize -Count 1 -Dictionary @() } 'decoded source cap applies without references too'
$tooMany=0..65536|ForEach-Object { 'word_'+$_ }
Assert-Throws { ConvertFrom-CompactSourceWordBody -Body "@0 @0`n" -Count 1 -Dictionary $tooMany } 'actual table entry cap checked'
$tooLarge=@(('a'*2097153),('b'*2097153))
Assert-Throws { ConvertFrom-CompactSourceWordBody -Body "@0 @0 @1 @1`n" -Count 1 -Dictionary $tooLarge } 'actual table retained units cap checked'

# F and FL must both profit; no producer-derived oracle is used for original source.
$body=''
for ($i=0;$i -lt 64;$i++) { $body+="        assertEquals(failureValue, expectedValue$i); // assertEquals failureValue`n" }
$body+=("        assertEquals(failureValue, sharedExpected); // repeated whole core`n"*16)
$a=New-WordAddition 'src/word-a.kt' $body
$b=New-WordAddition 'src/word-b.java' ($body.Replace('failureValue','differentFailure'))
$diff=$a.Patch+$b.Patch
$baseline=ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $diff -CompactIndentation -CompactSourceFrames
Assert-WordSame (Render-Word $diff -Off) $baseline 'explicit words off versus absent flag'
Assert-True (-not [bool]$baseline.Manifest.PSObject.Properties['source_word_version']) 'legacy off adds no word version'
foreach ($lines in @($false,$true)) {
    $script:WordRequests.Clear(); $old=Render-Word $diff -Lines:$lines -Off
    $requests=$script:WordRequests.ToArray()
    $script:WordRequests.Clear(); $new=Render-Word $diff -Lines:$lines
    Assert-True (($script:WordRequests.ToArray() -join "`n") -ceq ($requests -join "`n")) 'word pass adds no Git calls or substituted provenance'
    Assert-Eq $new.Manifest.source_word_version 1 'word root version present only on use'
    Assert-True ($new.Diff.Length -lt $old.Diff.Length) 'whole word envelopes shorten UTF16'
    Assert-True ([Text.Encoding]::UTF8.GetByteCount($new.Diff) -lt [Text.Encoding]::UTF8.GetByteCount($old.Diff)) 'whole word envelopes shorten UTF8'
    Assert-True ((Restore-CompactReviewDiff -Diff $new.Diff -Manifest $new.Manifest) -ceq $diff) 'all source bodies and ordered identities roundtrip'
    $parts=@(Split-WordParts $new); $oldParts=@(Split-WordParts $old)
    foreach ($i in 0..1) {
        $at=$parts[$i].Text.IndexOf("`n"); $h=@($parts[$i].Text.Substring(0,$at)|ConvertFrom-Json)
        Assert-Eq $h.Count 3 'WORDS envelope has exactly three fields'
        Assert-Eq $h[0] 'WORDS' 'word discriminator exact'
        Assert-True ($h[2] -ceq $oldParts[$i].Text.Substring(0,$oldParts[$i].Text.IndexOf("`n"))) 'previous header preserved verbatim as string'
        foreach ($field in @('header','path','mode','blob','index','count','original_length','original_sha256')) {
            Assert-True ($parts[$i].Section.$field -ceq $oldParts[$i].Section.$field) 'outer words preserve each original identity'
        }
        Assert-True ([bool]$parts[$i].Section.PSObject.Properties['word_legacy']) 'previous section retained'
        Assert-True (@($parts[$i].Section.word_dictionary).Count -gt 0) 'section retains actual local table'
    }
}

# Whole-file literal-marker fallback and old-frame literal @0 are mandatory after prior line processing.
foreach ($suffix in @('@0','@01','@65536')) {
    $literal=New-WordAddition 'src/literal.kt' ($body+"    literal $suffix`n")
    Assert-WordSame (Render-Word $literal.Patch) (Render-Word $literal.Patch -Off) 'reserved marker fallback'
}
$tiny=New-WordAddition 'src/tiny.asm' "    lda symbol`n"
Assert-WordSame (Render-Word $tiny.Patch) (Render-Word $tiny.Patch -Off) 'unprofitable table fallback'
Assert-Throws { ConvertTo-CompactReviewDiff -RepoRoot $repo -BaseOid $base -HeadSha $head -Diff $a.Patch -CompactSourceWords } 'words cannot bypass required prior adapters'

# Culture does not change ASCII matching or ordinal optimizer tie breaks.
$thread=[Threading.Thread]::CurrentThread; $culture=$thread.CurrentCulture; $ui=$thread.CurrentUICulture
try {
    $thread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('en-US')
    $english=Render-Word $diff -Lines
    $thread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('tr-TR')
    $thread.CurrentUICulture=$thread.CurrentCulture
    Assert-WordSame (Render-Word $diff -Lines) $english 'Turkish ordinal output'
} finally { $thread.CurrentCulture=$culture; $thread.CurrentUICulture=$ui }

# Rebound outer digests cannot conceal typed summaries, omitted identities or changed table/header.
$r=Render-Word $diff -Lines
foreach ($field in @('source_word_version','source_word_dictionary_count','source_word_dictionary_utf16')) {
    foreach ($value in @('1',-1,2147483647)) {
        $m=Copy-WordManifest $r.Manifest; $m.$field=$value
        Assert-Throws { Restore-CompactReviewDiff -Diff $r.Diff -Manifest $m } 'word root typed version and actual charge summary enforced'
    }
}
foreach ($attack in @('path','mode','blob','index','count','header','table','original_length','order')) {
    $m=Copy-WordManifest $r.Manifest; $parts=@(Split-WordParts $r|ForEach-Object Text)
    $s=$m.sections[0]; $at=$parts[0].IndexOf("`n"); $h=@($parts[0].Substring(0,$at)|ConvertFrom-Json)
    switch ($attack) {
        'path' { $s.path='../escape.kt' }
        'mode' { $s.mode='100755' }
        'blob' { $s.blob='f'*40 }
        'index' { $s.index='0000000..fffffff' }
        'count' { $s.count=[string]$s.count }
         'header' { $h[2]='["F","src/tampered.kt","fffffff",1]' }
        'table' { $h[1]=@('replacementWord'); $s.word_dictionary=@('replacementWord') }
        'original_length' { $s.original_length=1 }
        'order' { $m.sections=@($m.sections[1],$m.sections[0]); $parts=@($parts[1],$parts[0]) }
    }
    if ($attack -ne 'order') { $parts[0]=(ConvertTo-Json -InputObject $h -Depth 10 -Compress)+"`n"+$parts[0].Substring($at+1) }
    $changed=Bind-WordParts $m $parts
    Assert-Throws { Restore-CompactReviewDiff -Diff $changed -Manifest $m } 'rebound word provenance and canonical envelope attack rejected'
}
# Actual retained-state reservations, not merely oversized declared summaries.
$state=New-CompactSourceLineState -ReservedEntries 1
for ($i=0;$i -lt 65534;$i++) {
    $value='retained_core_'+$i.ToString('D5',[Globalization.CultureInfo]::InvariantCulture)
    $state.Cores.Add($value); [void]$state.Known.Add($value); $state.Characters+=$value.Length
}
$next='new_actual_core_abcdefghijklmnopqrstuvwxyz'
$line="~65534=$next`n"
Assert-True ((ConvertFrom-CompactSourceLineBody -Body $line -Count 1 -Start 65534 -End 65535 -State $state) -ceq ($next+"`n")) '65535 actual lines plus one reserved word exactly reach shared entry cap'
$priorCount=$state.Cores.Count; $priorUnits=$state.Characters
Assert-Throws { ConvertFrom-CompactSourceLineBody -Body "~65535=overflow_actual_core_abcdefghijklmnopqrstuvwxyz`n" -Count 1 -Start 65535 -End 65535 -State $state } 'dishonest end count cannot admit one entry beyond actual shared capacity'
Assert-Eq $state.Cores.Count $priorCount 'entry overflow rejected BEFORE mutating retained dictionary'
Assert-Eq $state.Characters $priorUnits 'entry overflow leaves actual retained units unchanged'

$state=New-CompactSourceLineState -ReservedCharacters 12
$target=4194304L-12-$next.Length
for ($i=0;$i -lt 4;$i++) {
    $length=[int][Math]::Min(1048576L,$target-$state.Characters)
    $value=([string][char](65+$i))*$length
    $state.Cores.Add($value);[void]$state.Known.Add($value);$state.Characters+=$value.Length
}
Assert-True ((ConvertFrom-CompactSourceLineBody -Body ("~4=$next`n") -Count 1 -Start 4 -End 5 -State $state) -ceq ($next+"`n")) 'actual retained line units plus reserved word units reach exactly four MiB'
$priorUnits=$state.Characters
Assert-Throws { ConvertFrom-CompactSourceLineBody -Body "~5=overflow_actual_core_abcdefghijklmnopqrstuvwxyz`n" -Count 1 -Start 5 -End 5 -State $state } 'dishonest end summary cannot admit over-cap retained characters'
Assert-Eq $state.Cores.Count 5 'unit overflow rejected BEFORE adding new core'
Assert-Eq $state.Characters $priorUnits 'unit overflow leaves actual unit counter unchanged'
$zero=New-CompactSourceLineState
Assert-True (-not [bool]$zero.PSObject.Properties['ReservedEntries'] -and -not [bool]$zero.PSObject.Properties['ReservedCharacters']) 'zero reservations preserve legacy state shape'
Assert-True ($null -eq (ConvertTo-CompactSourceWordBody -Body $plain -Count 24 -ReservedEntries 65536)) 'frequency staging falls back when no shared entry remains'
Assert-True ($null -eq (ConvertTo-CompactSourceWordBody -Body $plain -Count 24 -ReservedCharacters 4194304)) 'frequency staging falls back when no shared units remain'
$stagingBody=(('longIdentifierOne longIdentifierTwo '*32).TrimEnd())+"`n"
$staging=ConvertTo-CompactSourceWordBody -Body $stagingBody -Count 1 -ReservedEntries 65534 -ReservedCharacters (4194304-34)
Assert-True ($null -ne $staging -and @($staging.Dictionary).Count -eq 2) 'two actual staged keys fit exactly remaining shared entries and units'
Assert-True ($null -eq (ConvertTo-CompactSourceWordBody -Body $stagingBody -Count 1 -ReservedEntries 65535)) 'staging falls back before admitting second key past shared entry capacity'
Assert-True ($null -eq (ConvertTo-CompactSourceWordBody -Body $stagingBody -Count 1 -ReservedCharacters (4194304-33))) 'staging falls back before admitting one retained unit past shared character capacity'
# Reservations must survive BOTH the word and F/FL restore dispatch boundaries.
$wordCount=[long]$r.Manifest.source_word_dictionary_count
$wordUnits=[long]$r.Manifest.source_word_dictionary_utf16
$lineCount=if ($r.Manifest.PSObject.Properties['source_line_dictionary_count']) {[long]$r.Manifest.source_line_dictionary_count} else {0L}
$lineUnits=if ($r.Manifest.PSObject.Properties['source_line_dictionary_utf16']) {[long]$r.Manifest.source_line_dictionary_utf16} else {0L}
Assert-True ((Restore-CompactReviewDiff -Diff $r.Diff -Manifest $r.Manifest -ReservedEntries (65536-$wordCount-$lineCount) -ReservedCharacters (4194304-$wordUnits-$lineUnits)) -ceq $diff) 'full layered restore accepts exact shared reservations'
Assert-Throws { Restore-CompactReviewDiff -Diff $r.Diff -Manifest $r.Manifest -ReservedEntries (65537-$wordCount-$lineCount) } 'full layered restore refuses actual shared entry overflow'
Assert-Throws { Restore-CompactReviewDiff -Diff $r.Diff -Manifest $r.Manifest -ReservedCharacters (4194305-$wordUnits-$lineUnits) } 'full layered restore refuses actual shared unit overflow'

# Equal-saving ASCII I/i words actually participate in the local table and decimal IDs 10+.
$tieWords=@('IIIIIIIIIIIIIIII','iiiiiiiiiiiiiiii')+@(0..11|ForEach-Object {'TOKEN'+$_.ToString('D11',[Globalization.CultureInfo]::InvariantCulture)})
$tieBody=((($tieWords -join ' ')+" İ λ @near `n")*16)
$culture=[Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('en-US')
    $tieEnglish=ConvertTo-CompactSourceWordBody -Body $tieBody -Count 16
    [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('tr-TR')
    $tieTurkish=ConvertTo-CompactSourceWordBody -Body $tieBody -Count 16
    Assert-True (($tieEnglish|ConvertTo-Json -Depth 10 -Compress) -ceq ($tieTurkish|ConvertTo-Json -Depth 10 -Compress)) 'actual I/i optimizer ties are ordinal across cultures'
    Assert-True ($tieEnglish.Dictionary -ccontains 'IIIIIIIIIIIIIIII' -and $tieEnglish.Dictionary -ccontains 'iiiiiiiiiiiiiiii') 'both ASCII case variants selected independently'
    Assert-True (-not ($tieEnglish.Dictionary -ccontains 'İ')) 'dotted I remains Unicode literal outside ASCII words'
    $ordinal=[string[]]$tieWords.Clone()
    [Array]::Sort($ordinal,[StringComparer]::Ordinal)
    Assert-True ((@($tieEnglish.Dictionary)[0..13] -join "`n") -ceq ($ordinal -join "`n")) 'equal-saving word IDs follow ordinal I TOKEN i order'
    Assert-True ($tieEnglish.Body -cmatch '@1[0-3](?![0-9])') 'canonical decimal IDs ten and above exercised'
    Assert-True ((ConvertFrom-CompactSourceWordBody -Body $tieEnglish.Body -Count 16 -Dictionary $tieEnglish.Dictionary) -ceq $tieBody) 'multi-digit IDs and Unicode near boundaries roundtrip'
} finally {[Threading.Thread]::CurrentThread.CurrentCulture=$culture}

$protocol=Get-CompactSourceWordProtocol
Assert-True ($protocol.Length -gt 0) 'separate word protocol fingerprint material exists'
Assert-True ($protocol.Contains('prior rendered F/FL body',[StringComparison]::Ordinal)) 'word protocol applies marker eligibility to prior rendered F/FL body'
Assert-True (-not $protocol.Contains('Original source containing @ immediately followed by an ASCII digit cannot be wrapped',[StringComparison]::Ordinal)) 'word protocol must not prohibit original markers reached only through global line references'
Write-TestResult
