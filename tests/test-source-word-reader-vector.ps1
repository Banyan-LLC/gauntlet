# Independent manual WORDS -> F/FL -> source-line -> indentation oracle.
. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
. "$PSScriptRoot/source-word-reader-vector.ps1"
$ErrorActionPreference='Stop'
function Expand-IndependentWords([string]$Body,[object[]]$Table,[long]$Limit=1048576) {
    if ($Table.Count -gt 65536) { throw 'INVALID_SOURCE_WORDS' }
    $known=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $units=0L
    foreach ($word in $Table) {
        if ($word -isnot [string] -or $word -cnotmatch '^[A-Za-z_][A-Za-z0-9_]{2,}$' -or -not $known.Add($word)) { throw 'INVALID_SOURCE_WORDS' }
        $units+=$word.Length
        if ($units -gt 4194304) { throw 'INVALID_SOURCE_WORDS' }
    }
    $uses=[int[]]::new($Table.Count); $out=[Text.StringBuilder]::new(); $at=0
    while ($at -lt $Body.Length) {
        $start=$at; $value=$null
        if ($Body[$at] -ceq '@' -and $at+1 -lt $Body.Length -and $Body[$at+1] -cmatch '[0-9]') {
            $at++; $digitsAt=$at
            while ($at -lt $Body.Length -and $Body[$at] -cmatch '[0-9]') { $at++ }
            $digits=$Body.Substring($digitsAt,$at-$digitsAt)
            if ($digits -cnotmatch '^(0|[1-9][0-9]{0,4})$') { throw 'INVALID_SOURCE_WORDS' }
            $id=[int]$digits
            if ($id -gt 65535 -or $id -ge $Table.Count -or
                ($start -gt 0 -and $Body[$start-1] -cmatch '[A-Za-z0-9_]') -or
                ($at -lt $Body.Length -and $Body[$at] -cmatch '[A-Za-z0-9_]')) { throw 'INVALID_SOURCE_WORDS' }
            $value=$Table[$id]
            if ($at-$start -ge $value.Length) { throw 'INVALID_SOURCE_WORDS' }
            $uses[$id]++
        } elseif ($Body[$at] -cmatch '[A-Za-z_]') {
            $at++
            while ($at -lt $Body.Length -and $Body[$at] -cmatch '[A-Za-z0-9_]') { $at++ }
            $value=$Body.Substring($start,$at-$start)
            if ($known.Contains($value)) { throw 'INVALID_SOURCE_WORDS' }
        } else { $value=[string]$Body[$at]; $at++ }
        if ($value.Length -gt $Limit-$out.Length) { throw 'INVALID_SOURCE_WORDS' }
        [void]$out.Append($value)
    }
    foreach ($use in $uses) { if ($use -lt 2) { throw 'INVALID_SOURCE_WORDS' } }
    $out.ToString()
}
function Read-IndependentSourceWords([string]$Text,[long]$ReservedEntries=0,[long]$ReservedUnits=0) {
    $lineTable=[Collections.Generic.List[string]]::new(); $lineUnits=0L
    $wordCount=0L; $wordUnits=0L; $cursor=0; $total=0L
    $bodies=@(); $envelopes=@(); $previous=@(); $headers=@()
    # Precharge ALL local tables before any legacy global declaration can be admitted.
    $scan=0
    while ($scan -lt $Text.Length) {
        $end=$Text.IndexOf("`n",$scan); if ($end -lt 0) { throw 'INVALID_SOURCE_WORDS' }
        $h=@($Text.Substring($scan,$end-$scan)|ConvertFrom-Json); $scan=$end+1
        if ($h[0] -ceq 'WORDS') {
            if ($h.Count -ne 3 -or $h[1] -isnot [array] -or $h[2] -isnot [string]) { throw 'INVALID_SOURCE_WORDS' }
            $wordCount+=@($h[1]).Count
            foreach ($word in $h[1]) { if ($word -isnot [string]) { throw 'INVALID_SOURCE_WORDS' }; $wordUnits+=$word.Length }
            $h=@($h[2]|ConvertFrom-Json)
        }
        if ($wordCount+$ReservedEntries -gt 65536 -or $wordUnits+$ReservedUnits -gt 4194304) { throw 'INVALID_SOURCE_WORDS' }
        if ($h[0] -cnotin @('F','FL') -or $h.Count -ne $(if ($h[0] -ceq 'F') {4} else {6}) -or
            $h[2] -cnotmatch '^[0-9a-f]{7}$' -or ($h[3] -isnot [int] -and $h[3] -isnot [long]) -or $h[3] -le 0 -or $h[3] -gt 1048576) { throw 'INVALID_SOURCE_WORDS' }
        for ($i=0;$i -lt $h[3];$i++) {
            $end=$Text.IndexOf("`n",$scan); if ($end -lt 0) { throw 'INVALID_SOURCE_WORDS' }; $scan=$end+1
        }
    }
    while ($cursor -lt $Text.Length) {
        $start=$cursor; $end=$Text.IndexOf("`n",$cursor)
        $outer=@($Text.Substring($cursor,$end-$cursor)|ConvertFrom-Json); $cursor=$end+1
        $wrapped=$outer[0] -ceq 'WORDS'
        $headerText=if ($wrapped) {$outer[2]} else {$Text.Substring($start,$end-$start)}
        $h=@($headerText|ConvertFrom-Json); $rawStart=$cursor
        for ($i=0;$i -lt $h[3];$i++) { $cursor=$Text.IndexOf("`n",$cursor)+1 }
        $raw=$Text.Substring($rawStart,$cursor-$rawStart)
        $body=if ($wrapped) {Expand-IndependentWords $raw $outer[1]} else {$raw}
        $previous+=,($headerText+"`n"+$body); $envelopes+=,$Text.Substring($start,$cursor-$start); $headers+=,$h
        $out=[Text.StringBuilder]::new()
        if ($h[0] -ceq 'FL' -and $h[4] -ne $lineTable.Count) { throw 'INVALID_SOURCE_WORDS' }
        foreach ($row in $body.Substring(0,$body.Length-1).Split("`n")) {
            $groups=0; $skip=0; $alphabet=@('^','+','`','%','<','>',';','=')
            if ($row.Length) {
                $symbol=[array]::IndexOf($alphabet,[string]$row[0])
                if ($symbol -ge 0) {$groups=$symbol+1;$skip=1}
                elseif ($row -cmatch '^\|([0-9]+)\|') {
                    $digits=$Matches[1];$skip=$Matches[0].Length
                    if ($digits -cnotmatch '^[1-9][0-9]{0,5}$' -or [int]$digits -lt 9 -or [int]$digits -gt 262144) { throw 'INVALID_SOURCE_WORDS' }
                    $groups=[int]$digits
                }
            }
            $core=$row.Substring($skip)
            if ($h[0] -ceq 'FL') {
                $decl=[regex]::Match($core,'^~(0|[1-9][0-9]{0,4})=(.*)$')
                $ref=[regex]::Match($core,'^~(0|[1-9][0-9]{0,4})~$')
                if ($decl.Success) {
                    $id=[int]$decl.Groups[1].Value; $core=$decl.Groups[2].Value
                    if ($id -ne $lineTable.Count -or $core.Length -lt 16 -or $lineTable.Contains($core) -or
                        $lineTable.Count+$wordCount+$ReservedEntries -ge 65536 -or
                        $core.Length -gt 4194304L-$lineUnits-$wordUnits-$ReservedUnits) { throw 'INVALID_SOURCE_WORDS' }
                    $lineTable.Add($core); $lineUnits+=$core.Length
                } elseif ($ref.Success) {
                    $id=[int]$ref.Groups[1].Value
                    if ($id -ge $lineTable.Count) { throw 'INVALID_SOURCE_WORDS' }
                    $core=$lineTable[$id]
                } elseif ($core -cmatch '^~[0-9]+[=~]' -or $lineTable.Contains($core)) { throw 'INVALID_SOURCE_WORDS' }
            }
            $needed=4L*$groups+$core.Length+1
            if ($needed -gt 1048576L-$out.Length) { throw 'INVALID_SOURCE_WORDS' }
            [void]$out.Append((' '*(4*$groups))).Append($core).Append("`n")
        }
        if ($h[0] -ceq 'FL' -and $h[5] -ne $lineTable.Count) { throw 'INVALID_SOURCE_WORDS' }
        if ($out.Length -gt 4194304L-$total) { throw 'INVALID_SOURCE_WORDS' }
        $total+=$out.Length; $bodies+=,$out.ToString()
    }
    [pscustomobject]@{Bodies=$bodies;Headers=$headers;Previous=$previous;Envelopes=$envelopes;LineTable=$lineTable.ToArray();WordCount=$wordCount;WordUnits=$wordUnits;LineUnits=$lineUnits}
}
# Bind the host proof to the exact function definition carried by the leased live file.
$helperTokens=$null; $helperErrors=$null; $liveTokens=$null; $liveErrors=$null
$helperAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'source-word-reader-vector.ps1'),[ref]$helperTokens,[ref]$helperErrors)
$liveAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'live/live-source-word-review.ps1'),[ref]$liveTokens,[ref]$liveErrors)
$selector={param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'New-SourceWordReaderVector'}
$helperFunction=$helperAst.Find($selector,$true); $liveFunction=$liveAst.Find($selector,$true)
Assert-Eq $helperErrors.Count 0 'manual helper parses'
Assert-Eq $liveErrors.Count 0 'live fixture parses without dispatch'
Assert-True ($null -ne $helperFunction -and $null -ne $liveFunction -and $helperFunction.Extent.Text -ceq $liveFunction.Extent.Text) 'host helper and actually dispatched live vector have EXACT same function AST text'
$liveText=$liveAst.Extent.Text
foreach ($guard in @('Initialize-LiveGateNative','Assert-LiveGatePathComponents','CreateExclusiveDirectory',
    '[IO.FileMode]::CreateNew','SetAccessRuleProtection($true,$false)','[IO.FileShare]::Read',
    'Get-BoundReviewProfile','Get-InvocationAudit','-RequireProcessTreeRetirement','Get-RunUsage',
    'Test-Verdict','normalized_verdict_sha256','Assert-HarnessSafe','if(-not $run.ProcessTreeRetired){break}',
    'maximum_input_tokens -ne 493300','output_reserve -ne 128000',
    "@('positive','negativeAlias','negativeUnknown')",'INVALID_SOURCE_WORDS',
    'compact_source_word_protocol_sha256','review_metadata_protocol_sha256')) {
    Assert-True ($liveText.Contains($guard,[StringComparison]::Ordinal)) 'live fixture retains required lifecycle schema capacity evidence and three-case guard'
}
$v=New-SourceWordReaderVector
$d=Read-IndependentSourceWords $v.Positive
$summary=($d.Bodies -join "---NEXT---`n")+"---INDEXES---`n"+
    'index 0000000..'+$d.Headers[0][2]+"`n"+'index 0000000..'+$d.Headers[4][2]+"`n"
Assert-True ($summary -ceq $v.Expected) 'all five exact source bodies plus delimiters and original F FL indices fit response'
Assert-Eq $v.Expected.Length 787 'fixed full summary UTF16 units'
Assert-True ($v.Expected.Length -lt 800) 'full exact summary remains below unchanged standard schema cap'
Assert-Eq $v.LineCount 9 'manual source row count fixed'
Assert-Eq $d.Bodies.Count 5 'manual vector contains four global-line frames and one plain F'
foreach ($i in 0..4) {
    Assert-True ($d.Bodies[$i] -ceq $v.Bodies[$i]) 'manual original source independent of production codecs'
    $bytes=[Text.Encoding]::UTF8.GetBytes($d.Bodies[$i]);$prefix=[Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($prefix+$bytes))).ToLowerInvariant()
    Assert-True ($hash -ceq $v.Blobs[$i]) 'full body Git proof independently recomputed'
    Assert-True ($d.Headers[$i][2] -ceq $hash.Substring(0,7)) 'seven-hex header binds exact original body'
    if ($i -ne 2) {
        Assert-True ($d.Envelopes[$i].Length -lt $d.Previous[$i].Length) 'EACH complete WORDS envelope shortens prior frame UTF16 including header and table'
        Assert-True ([Text.Encoding]::UTF8.GetByteCount($d.Envelopes[$i]) -lt [Text.Encoding]::UTF8.GetByteCount($d.Previous[$i])) 'EACH envelope also shortens UTF8'
    } else { Assert-True ($d.Envelopes[$i] -ceq $d.Previous[$i]) 'literal @0 declaration remains unwrapped' }
}
foreach ($i in 0..3) { Assert-True ($d.LineTable[$i] -ceq $v.LineDictionary[$i]) 'global table stores full expanded original core' }
Assert-True ($d.Bodies[1].Contains($v.LineDictionary[0])) 'later different local @0 table cannot reinterpret earlier global core'
Assert-True ($d.Bodies[3].Contains('literal @0 shared core @near')) 'global reference to unworded literal @0 is never recursively expanded'
Assert-True ($d.Bodies[2].Contains('@near') -and $d.Bodies[3].Contains('@near')) 'literal near marker survives both original declaration and later global reference'
Assert-True ($v.Rows[0].Contains('@near') -and $v.Rows[4].Contains('@near') -and $d.Bodies[0].Contains('@near') -and $d.Bodies[4].Contains('@near')) 'word scanner preserves authored near markers in WORDS FL declaration and WORDS F body'
foreach ($negative in @('NegativeUnknown','NegativeAlias','NegativeBoundary','NegativeForward')) {
    Assert-Throws { Read-IndependentSourceWords $v.$negative } 'independent reader rejects unknown alias boundary or global-forward reference'
}
# Real shared limits in the independent oracle; dishonest summaries are covered by production restore below.
Assert-Throws { Read-IndependentSourceWords $v.Positive -ReservedEntries 65529 } 'four local plus four global entries cannot exceed 65536'
Assert-Throws { Read-IndependentSourceWords $v.Positive -ReservedUnits (4194304-$d.WordUnits-$d.LineUnits+1) } 'actual shared retained units refuse one-unit overflow'
Assert-True ((Read-IndependentSourceWords $v.Positive -ReservedEntries 65528).Bodies[3] -ceq $v.Bodies[3]) 'exact shared entry boundary admitted'
Assert-True ((Read-IndependentSourceWords $v.Positive -ReservedUnits (4194304-$d.WordUnits-$d.LineUnits)).Bodies[3] -ceq $v.Bodies[3]) 'exact shared unit boundary admitted'

# The production body decoder must agree with authored previous rows; expected data never comes from it.
Assert-True ([bool](Get-Command ConvertFrom-CompactSourceWordBody -ErrorAction SilentlyContinue)) 'production word decoder available'
if (Get-Command ConvertFrom-CompactSourceWordBody -ErrorAction SilentlyContinue) {
    foreach ($i in @(0,1,3,4)) {
        $actual=ConvertFrom-CompactSourceWordBody -Body $v.Rows[$i] -Count $d.Headers[$i][3] -Dictionary $v.Tables[$i]
        Assert-True (($v.LegacyHeaders[$i]+"`n"+$actual) -ceq $d.Previous[$i]) 'production decoder matches independent manually authored legacy representation'
    }
}
# Construct the coverage manifest from the authored ORIGINAL bodies and independent intermediate
# rows, not from a production producer. This exercises the complete production restore ordering.
$sections=@()
foreach ($i in 0..4) {
    $h=$d.Headers[$i]; $patch=$v.Patches[$i]
    $previous=[pscustomobject]@{header=("diff --git a/$($h[1]) b/$($h[1])");path=$h[1];mode='100644'
        index=('0000000..'+$h[2]);count=$h[3];blob=$v.Blobs[$i];compact=$true
        original_length=$patch.Length;original_sha256=(Get-ReviewTextHash $patch)
        rendered_length=$d.Previous[$i].Length;rendered_sha256=(Get-ReviewTextHash $d.Previous[$i])
        encoding=$(if ($i -lt 4) {'source-frame-lines'} else {'source-frame'})}
    if ($i -lt 4) {
        $previous|Add-Member -NotePropertyName source_line_start -NotePropertyValue $h[4]
        $previous|Add-Member -NotePropertyName source_line_end -NotePropertyValue $h[5]
    }
    $section=$previous.PSObject.Copy()
    if ($i -ne 2) {
        $section.encoding='source-words'
        $section|Add-Member -NotePropertyName word_legacy -NotePropertyValue $previous
        $section|Add-Member -NotePropertyName word_dictionary -NotePropertyValue $v.Tables[$i]
        $section.rendered_length=$d.Envelopes[$i].Length
        $section.rendered_sha256=Get-ReviewTextHash $d.Envelopes[$i]
    }
    $sections+=,$section
}
$manifest=[pscustomobject]@{version=1;base=('b'*40);head=('a'*40);newline_normalization='CRLF to LF only'
    original_sha256=(Get-ReviewTextHash $v.OriginalDiff);rendered_sha256=(Get-ReviewTextHash $v.Positive)
    source_frame_version=1;source_line_version=1;source_line_dictionary_count=4;source_line_dictionary_utf16=$d.LineUnits
    source_word_version=1;source_word_dictionary_count=$d.WordCount;source_word_dictionary_utf16=$d.WordUnits;sections=$sections}
if (Get-Command Get-CompactSourceWordProtocol -ErrorAction SilentlyContinue) {
    $restored=$null
    try { $restored=Restore-CompactReviewDiff -Diff $v.Positive -Manifest $manifest }
    catch { Assert-True $false 'manual full production restore must admit local-table/global-literal marker vector' }
    Assert-True ($restored -ceq $v.OriginalDiff) 'manual mixed WORDS FL F and unworded literal @0 restore exact complete diff'
    Assert-True ((Restore-CompactReviewDiff -Diff $v.Positive -Manifest $manifest -ReservedEntries 65528 -ReservedCharacters (4194304-$d.WordUnits-$d.LineUnits)) -ceq $v.OriginalDiff) 'production manual vector accepts EXACT shared entry and retained-unit boundaries'
    foreach ($field in @('source_line_dictionary_count','source_line_dictionary_utf16')) {
        $dishonest=$manifest|ConvertTo-Json -Depth 50|ConvertFrom-Json
        $dishonest.$field=1
        Assert-Throws { Restore-CompactReviewDiff -Diff $v.Positive -Manifest $dishonest -ReservedEntries 65529 } 'dishonest legacy summaries cannot grant extra actual dictionary entry capacity'
        Assert-Throws { Restore-CompactReviewDiff -Diff $v.Positive -Manifest $dishonest -ReservedCharacters (4194304-$d.WordUnits-$d.LineUnits+1) } 'dishonest legacy summaries cannot grant extra actual retained-unit capacity'
    }
}
$pins=[ordered]@{
    'Get-CompactReviewProtocol'='5f86531ba9d59cd56a2aa789acb653d0899e75aaae2dd4a41f9098f3ee674b6f'
    'Get-CompactIndentationProtocol'='d58a6eae0c5764f4ccb99fbe10f720740a76ffb1eb4f387952ae1676cdff5a3c'
    'Get-CompactSourceLineProtocol'='9261e72813f4c0ccf630a79aee6ba72a20e344462c3d89b581111f1bd4f4f9af'
    'Get-CompactSourceFrameProtocol'='461dcb6cde8f9a1b2df432b5d62c51c270cd7e5bfbcccac716c8c225b0327035'
    'Get-ReviewMetadataProtocol'='35bc6b04c9c2d689acfad4f6ac9e4ebab01326a7615ea7c15d223a1e19a0f983'
}
foreach ($name in $pins.Keys) { Assert-Eq (Get-ReviewTextHash (& $name)) $pins[$name] 'old protocol fingerprint remains byte-identical' }
Write-TestResult
