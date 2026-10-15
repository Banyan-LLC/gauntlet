. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$path = Join-Path $PSScriptRoot 'live/live-source-frame-review.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert-Eq $errors.Count 0 'live source-frame fixture parses without dispatch'
$function = $ast.Find({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'New-SourceFrameReaderVector'
},$true)
Assert-True ($null -ne $function) 'manual host-only source-frame vector exists'
if ($null -eq $function) { Write-TestResult }
# Import only a function definition, never the live entry, native initialization or CLI discovery.
. ([scriptblock]::Create($function.Extent.Text))
$v = New-SourceFrameReaderVector

# Independent reader. No production source-frame, indentation or source-line decoder is called.
function Read-IndependentSourceFrameVector([string]$Text) {
    $dictionary = [Collections.Generic.List[string]]::new()
    $known = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $dictionaryUnits = 0L
    $cursor = 0; $total = 0L
    $bodies = [Collections.Generic.List[string]]::new()
    $headers = [Collections.Generic.List[object]]::new()
    $legacyHeaders = [Collections.Generic.List[object]]::new()
    $originalHeaders = [Collections.Generic.List[string]]::new()
    while ($cursor -lt $Text.Length) {
        $headerEnd = $Text.IndexOf("`n",$cursor)
        if ($headerEnd -lt 0) { throw 'INVALID_SOURCE_FRAMES' }
        $h = @($Text.Substring($cursor,$headerEnd-$cursor) | ConvertFrom-Json)
        $cursor = $headerEnd+1
        $short = $h[0] -cin @('F','FL')
        $lineFrame = $h[0] -ceq 'FL'
        $expectedFields = switch ($h[0]) { 'F' {4} 'FL' {6} 'INDENT' {5} default {throw 'INVALID_SOURCE_FRAMES'} }
        if ($h.Count -ne $expectedFields) { throw 'INVALID_SOURCE_FRAMES' }
        if ($h[1] -isnot [string] -or $h[1] -cnotmatch '^src/[A-Za-z0-9_-]+\.kt$') { throw 'INVALID_SOURCE_FRAMES' }
        if ($short) {
            if ($h[2] -isnot [string] -or $h[2] -cnotmatch '^[0-9a-f]{7}$') { throw 'INVALID_SOURCE_FRAMES' }
            $count = $h[3]
            $index = '0000000..'+$h[2]
            $legacy = @($(if ($lineFrame) {'INDENT_LINES'} else {'INDENT'}),$h[1],'100644',$index,$count)
            if ($lineFrame) { $legacy += @($h[4],$h[5]) }
        } else {
            if ($h[2] -cne '100644' -or $h[3] -cnotmatch '^0000000\.\.[0-9a-f]{7}$') { throw 'INVALID_SOURCE_FRAMES' }
            $count = $h[4]; $index = $h[3]; $legacy = $h
        }
        if (($count -isnot [int] -and $count -isnot [long]) -or $count -le 0 -or $count -gt 1048576) { throw 'INVALID_SOURCE_FRAMES' }
        if ($lineFrame) {
            foreach ($bound in @($h[4],$h[5])) {
                if (($bound -isnot [int] -and $bound -isnot [long]) -or $bound -lt 0 -or $bound -gt 65536) { throw 'INVALID_SOURCE_FRAMES' }
            }
            if ($h[4] -ne $dictionary.Count -or $h[5] -lt $h[4]) { throw 'INVALID_SOURCE_FRAMES' }
        }
        $decoded = [Text.StringBuilder]::new()
        for ($rowNumber=0; $rowNumber -lt $count; $rowNumber++) {
            # Find LF before numeric or prefix work; only consume declared source rows.
            $end = $Text.IndexOf("`n",$cursor)
            if ($end -lt 0) { throw 'INVALID_SOURCE_FRAMES' }
            $row = $Text.Substring($cursor,$end-$cursor); $cursor=$end+1
            if ($row.Contains("`r")) { throw 'INVALID_SOURCE_FRAMES' }
            if ($short) {
                $groups = 0; $skip = 0
                if ($row.Length -gt 0) {
                    $alphabet = @('^','+','`','%','<','>',';','=')
                    $symbol = [array]::IndexOf($alphabet,[string]$row[0])
                    if ($symbol -ge 0) { $groups=$symbol+1; $skip=1 }
                    elseif ($row -cmatch '^\|([0-9]+)\|') {
                        $digits = $Matches[1]
                        # Save the complete |N| boundary before digit validation replaces $Matches.
                        $skip = $Matches[0].Length
                        if ($digits -cnotmatch '^[1-9][0-9]{0,5}$') { throw 'INVALID_SOURCE_FRAMES' }
                        $groups = [int]$digits
                        if ($groups -lt 9 -or $groups -gt 262144) { throw 'INVALID_SOURCE_FRAMES' }
                    }
                }
                # Materialize the canonical legacy TAB prefix, not expanded source spaces yet.
                if ($groups -gt 1048576L-$row.Length) { throw 'INVALID_SOURCE_FRAMES' }
                $row = ("`t" * $groups)+$row.Substring($skip)
            }
            if ($lineFrame) {
                $at=0
                while ($at -lt $row.Length -and ($row[$at] -ceq ' ' -or $row[$at] -ceq "`t")) { $at++ }
                $prefix=$row.Substring(0,$at); $core=$row.Substring($at)
                $declaration=[regex]::Match($core,'^~([0-9]+)=(.*)$')
                $reference=[regex]::Match($core,'^~([0-9]+)~$')
                if ($declaration.Success -or $reference.Success) {
                    $digits = if ($declaration.Success) {$declaration.Groups[1].Value} else {$reference.Groups[1].Value}
                    if ($digits -cnotmatch '^(0|[1-9][0-9]{0,4})$') { throw 'INVALID_SOURCE_FRAMES' }
                    $id=[int]$digits
                    if ($id -gt 65535) { throw 'INVALID_SOURCE_FRAMES' }
                    if ($declaration.Success) {
                        $value=$declaration.Groups[2].Value
                        if ($id -ne $dictionary.Count -or $dictionary.Count -ge 65536 -or $value.Length -lt 16 -or
                            $value -cmatch '^[ \t]|^~[0-9]+(?:=|~$)' -or $known.Contains($value)) { throw 'INVALID_SOURCE_FRAMES' }
                        if ($value.Length -gt 4194304L-$dictionaryUnits) { throw 'INVALID_SOURCE_FRAMES' }
                        $dictionary.Add($value); [void]$known.Add($value); $dictionaryUnits += $value.Length
                    } else {
                        if ($id -ge $dictionary.Count) { throw 'INVALID_SOURCE_FRAMES' }
                        $value=$dictionary[$id]
                        if ($core.Length -ge $value.Length) { throw 'INVALID_SOURCE_FRAMES' }
                    }
                } else {
                    $value=$core
                    if ($known.Contains($value)) { throw 'INVALID_SOURCE_FRAMES' }
                }
                $row=$prefix+$value
            }
            # INDENT fallback deliberately skips all dictionary processing, even after FL.
            $tabs=0
            while ($tabs -lt $row.Length -and $row[$tabs] -ceq "`t") { $tabs++ }
            $rest=$row.Substring($tabs)
            if ($rest -cmatch '^ {4}|^ {0,3}\t') { throw 'INVALID_SOURCE_FRAMES' }
            $needed=4L*$tabs+$rest.Length+1
            if ($needed -gt 1048576L-$decoded.Length) { throw 'INVALID_SOURCE_FRAMES' }
            [void]$decoded.Append((' '*(4*$tabs))).Append($rest).Append("`n")
        }
        if ($lineFrame -and $dictionary.Count -ne $h[5]) { throw 'INVALID_SOURCE_FRAMES' }
        $value=$decoded.ToString()
        $originalHeader="diff --git a/$($h[1]) b/$($h[1])`nnew file mode 100644`nindex $index`n--- /dev/null`n+++ b/$($h[1])`n@@ -0,0 +1,$count @@`n"
        $charge=[long]$originalHeader.Length+$value.Length+$count
        if ($charge -gt 4194304L-$total) { throw 'INVALID_SOURCE_FRAMES' }
        $total += $charge
        $headers.Add($h); $legacyHeaders.Add($legacy); $originalHeaders.Add($originalHeader); $bodies.Add($value)
    }
    [pscustomobject]@{Bodies=$bodies.ToArray(); Headers=$headers.ToArray(); LegacyHeaders=$legacyHeaders.ToArray()
        OriginalHeaders=$originalHeaders.ToArray(); Dictionary=$dictionary.ToArray(); Units=$dictionaryUnits}
}

$decoded = Read-IndependentSourceFrameVector $v.Positive
Assert-Eq $decoded.Bodies.Count 3 'two short frames followed by literal legacy fallback'
Assert-Eq $decoded.Headers[0].Count 4 'manual F has four fields'
Assert-Eq $decoded.Headers[1].Count 6 'manual FL has six fields'
Assert-Eq $decoded.LegacyHeaders[0][0] 'INDENT' 'F restores legacy INDENT header'
Assert-Eq $decoded.LegacyHeaders[1][0] 'INDENT_LINES' 'FL restores legacy source-line header'
Assert-Eq $decoded.Headers[2][0] 'INDENT' 'literal source collision stays legacy INDENT'
Assert-Eq $decoded.Dictionary.Count 2 'only the two explicit FL declarations enter dictionary'
Assert-Eq $decoded.Units 32 'shared core dictionary charges each literal once'
$summary=$decoded.Bodies[0]+"---NEXT---`n"+$decoded.Bodies[1]+"---LITERAL---`n"+$decoded.Bodies[2]+"---INDEXES---`n"+
    'index '+$decoded.LegacyHeaders[0][3]+"`n"+'index '+$decoded.LegacyHeaders[1][3]+"`n"
Assert-True ($summary -ceq $v.Expected) 'independent complete decoded bodies delimiters and original INDEX lines agree'
Assert-Eq $v.Expected.Length 608 'fixed exact summary UTF-16 length'
Assert-True ($v.Expected.Length -lt 800) 'response fits unchanged standard summary schema'
Assert-Eq $v.LineCount 25 'source row count is fixed'
$totalRows=0
$expectedBlobs=@('cc21c9c65f2b78407148322515f459b6adb1f7a1','c9c539a79e5be4f8c4b542686e0f1f527deb9914','a7df198150ca293f6caddfdb0d58c640ba1fe0d3')
foreach ($i in 0..2) {
    Assert-True ($decoded.Bodies[$i] -ceq $v.Bodies[$i]) "manual expected body $i exact"
    $totalRows += $v.Bodies[$i].Split("`n").Length-1
    $bytes=[Text.Encoding]::UTF8.GetBytes($decoded.Bodies[$i])
    $prefix=[Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($prefix+$bytes))).ToLowerInvariant()
    Assert-Eq $hash $expectedBlobs[$i] "independent fixed full Git blob hash $i"
    Assert-Eq $v.Blobs[$i] $expectedBlobs[$i] "vector full-body identity $i"
    Assert-Eq $decoded.LegacyHeaders[$i][3] ('0000000..'+$hash.Substring(0,7)) "actual seven-zero/seven-hex original index $i"
    Assert-Eq $decoded.LegacyHeaders[$i][2] '100644' "implied or explicit original mode $i"
    Assert-True ($decoded.OriginalHeaders[$i].Contains("index 0000000..$($hash.Substring(0,7))`n")) "original INDEX header restored $i"
}
Assert-Eq $totalRows 25 'actual manual bodies account for every row'
Assert-True ($totalRows -le 30) 'manual source expectations stay small'
$frameRows=$decoded.Bodies[0].Split("`n")
Assert-True ($frameRows[8] -ceq ((' '*36)+'i')) 'numeric nine prefix leaves no marker characters in source'
Assert-True ($frameRows[9] -ceq ((' '*48)+'"""')) 'numeric twelve prefix leaves no marker characters in source'
foreach ($pair in @(@(0,4),@(1,8),@(2,12),@(3,16),@(4,20),@(5,24),@(6,28),@(7,32),@(8,36),@(9,48))) {
    $row=$frameRows[$pair[0]]
    $spaces=$row.Length-$row.TrimStart([char]32).Length
    Assert-Eq $spaces $pair[1] 'all eight symbol prefixes and numeric nine/twelve decode exact indentation'
}
Assert-True ($decoded.Bodies[0].Contains("        0=TEXT`n") -and $decoded.Bodies[0].Contains("        0~`n")) 'eight-space literal cores without tilde are not dictionary labels'
Assert-True ($v.Positive.Contains("~0=abcdefghijklmnop`n~0~`n") -and $v.Positive.Contains('+~1=qrstuvwxyzABCDEF')) 'zero-indent and eight-space FL declarations are unambiguous'
Assert-True ($decoded.Bodies[1].Contains("        abcdefghijklmnop`n") -and $decoded.Bodies[1].Contains("                                qrstuvwxyzABCDEF`n")) 'shared cores preserve eight/thirty-two-space references'
Assert-True ($decoded.Bodies[2].Contains("~0=abcdefghijklmnop`n~0~`n") -and $decoded.Bodies[2].Contains("        ~0=abcdefghijklmnop`n        ~0~`n")) 'literal tilde pairs at zero/eight indentation survive after dictionary is nonempty'
Assert-True ($decoded.Bodies[0].Contains('"""') -and $decoded.Bodies[1].Contains("`n`n")) 'raw string delimiters and blank source rows survive'
Assert-True ($decoded.Bodies[0].Contains("a`tB  `n") -and $decoded.Bodies[1].Contains("λ`tZ  `n")) 'interior TAB Unicode and trailing spaces remain exact'
Assert-True ($decoded.Bodies[0].Contains('["FL",0]')) 'header-looking JSON remains counted body data'

foreach ($case in @('NegativeNumeric','NegativeReference','NegativeUnknown')) {
    Assert-True ($v.$case -cne $v.Positive) "$case changes only the invalid body control"
    Assert-Eq ($v.$case.Split("`n").Length) ($v.Positive.Split("`n").Length) "$case preserves LF row count"
    # Walk counted ranges, never scan delimiter-looking source content for frame boundaries.
    $positiveRows=$v.Positive.Split("`n"); $badRows=$v.$case.Split("`n")
    foreach ($position in @(0,12,22)) {
        Assert-True ($positiveRows[$position] -ceq $badRows[$position]) "$case preserves exact frame header"
    }
    try { Read-IndependentSourceFrameVector $v.$case | Out-Null; Assert-True $false "$case must reject" }
    catch { Assert-True ($_.Exception.Message -ceq 'INVALID_SOURCE_FRAMES') "$case rejects without source execution or repair" }
}

# Protocol fingerprints are independent; the new protocol must not rewrite legacy text.
Assert-Eq (Get-ReviewTextHash (Get-CompactReviewProtocol)) '5f86531ba9d59cd56a2aa789acb653d0899e75aaae2dd4a41f9098f3ee674b6f' 'legacy ADDED protocol fingerprint unchanged'
Assert-Eq (Get-ReviewTextHash (Get-CompactIndentationProtocol)) 'd58a6eae0c5764f4ccb99fbe10f720740a76ffb1eb4f387952ae1676cdff5a3c' 'legacy indentation protocol fingerprint unchanged'
Assert-Eq (Get-ReviewTextHash (Get-CompactSourceLineProtocol)) '9261e72813f4c0ccf630a79aee6ba72a20e344462c3d89b581111f1bd4f4f9af' 'legacy source-line protocol fingerprint unchanged'
Assert-True ((Get-ReviewTextHash (Get-CompactSourceFrameProtocol)) -cmatch '^[0-9a-f]{64}$') 'new source-frame protocol has separate SHA256 fingerprint'

$fixture=$ast.Extent.Text
foreach ($guard in @('Get-CompactReviewProtocol','Get-CompactIndentationProtocol','Get-CompactSourceLineProtocol','Get-CompactSourceFrameProtocol',
    'compact_protocol_sha256','indentation_protocol_sha256','source_line_protocol_sha256','compact_source_frame_protocol_sha256',
    'RequireProcessTreeRetirement','Get-BoundReviewProfile','Test-EmbedBudget','Test-PromptCharacterLimit','Get-InvocationAudit',
    'CreateNew','FileShare]::Read','CreateExclusiveDirectory','SetAccessRuleProtection','maximum_input_tokens','output_reserve',
    '493300','128000','if(-not $run.ProcessTreeRetired){break}','if($resource.Retired)','Assert-HarnessSafe',
    'Test-Verdict','Normalized.summary -ceq $expectedSummary','Normalized.recommendations.Count -eq 0','INVALID_SOURCE_FRAMES')) {
    Assert-True ($fixture.Contains($guard)) "live lifecycle preserves $guard"
}
Assert-True ($fixture.Contains('$cases.Count -eq 3')) 'all three real reader cases required'
Assert-True ($fixture.Contains('$vector.Expected.Length -ge 800')) 'standard summary cap is checked without override'
Assert-True (-not $fixture.Contains('SourceExpected')) 'no summary-schema override is introduced'
Write-TestResult
