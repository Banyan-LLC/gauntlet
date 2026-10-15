. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$path=Join-Path $PSScriptRoot 'live/live-source-line-review.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert-Eq $errors.Count 0 'source-line reader fixture parses without dispatch'
$function=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq 'New-SourceLineReaderVector'},$true)
Assert-True ($null -ne $function) 'host-only vector function exists'
. ([scriptblock]::Create($function.Extent.Text))
$v=New-SourceLineReaderVector

# Independent host implementation: never call either production body decoder to derive expectations.
function Read-IndependentSourceVector([string]$Text) {
    $dictionary=[Collections.Generic.List[string]]::new()
    $unique=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $dictionaryUnits=0L;$cursor=0;$total=0L
    $bodies=[Collections.Generic.List[string]]::new()
    $headers=[Collections.Generic.List[object]]::new()
    while($cursor -lt $Text.Length) {
        $headerEnd=$Text.IndexOf("`n",$cursor)
        if($headerEnd -lt 0){throw 'Missing frame header LF'}
        $h=ConvertFrom-Json $Text.Substring($cursor,$headerEnd-$cursor)
        $cursor=$headerEnd+1
        if($h[0] -cnotin @('LINES','INDENT_LINES','ADDED')){throw 'Unknown frame kind'}
        if($h.Count -ne $(if($h[0] -ceq 'ADDED'){5}else{7})){throw 'Wrong header field count'}
        if($h[4] -isnot [long] -and $h[4] -isnot [int]){throw 'Count is not integer'}
        if($h[4] -le 0 -or $h[4] -gt 1048576){throw 'Bad row count'}
        if($h[0] -cne 'ADDED' -and ($h[5] -ne $dictionary.Count -or $h[6] -lt $h[5] -or $h[6] -gt 65536)){throw 'Bad dictionary interval'}
        $body=[Text.StringBuilder]::new()
        for($row=0;$row -lt $h[4];$row++) {
            $end=$Text.IndexOf("`n",$cursor)
            if($end -lt 0){throw 'Missing body LF'}
            $line=$Text.Substring($cursor,$end-$cursor);$cursor=$end+1
            if($line.Contains("`r")){throw 'Noncanonical CR'}
            if($h[0] -cne 'ADDED') {
                $at=0
                while($at -lt $line.Length -and ($line[$at] -ceq ' ' -or $line[$at] -ceq "`t")){$at++}
                $prefix=$line.Substring(0,$at);$core=$line.Substring($at)
                $declaration=[regex]::Match($core,'^~([0-9]+)=(.*)$')
                $reference=[regex]::Match($core,'^~([0-9]+)~$')
                if($declaration.Success -or $reference.Success) {
                    $digits=if($declaration.Success){$declaration.Groups[1].Value}else{$reference.Groups[1].Value}
                    if($digits -cnotmatch '^(0|[1-9][0-9]{0,4})$'){throw 'Noncanonical ID'}
                    $id=[int]$digits
                    if($id -gt 65535){throw 'ID outside dictionary bounds'}
                    if($declaration.Success) {
                        $value=$declaration.Groups[2].Value
                        if($id -ne $dictionary.Count -or $dictionary.Count -ge 65536 -or $value.Length -lt 16 -or
                            $value -cmatch '^[ \t]|^~[0-9]+(?:=|~$)' -or $unique.Contains($value)){throw 'Invalid declaration'}
                        if($value.Length -gt 4194304L-$dictionaryUnits){throw 'Dictionary unit limit'}
                        $dictionary.Add($value);[void]$unique.Add($value);$dictionaryUnits+=$value.Length
                    } else {
                        if($id -ge $dictionary.Count){throw 'INVALID_SOURCE_LINES'}
                        $value=$dictionary[$id]
                        if($core.Length -ge $value.Length){throw 'Reference does not shorten'}
                    }
                } else {
                    $value=$core
                    if($unique.Contains($value)){throw 'Noncanonical literal repetition'}
                }
                $line=$prefix+$value
                if($h[0] -ceq 'INDENT_LINES') {
                    $n=0
                    while($n -lt $line.Length -and $line[$n] -ceq "`t"){$n++}
                    $rest=$line.Substring($n)
                    if($rest -cmatch '^ {4}|^ {0,3}\t'){throw 'Noncanonical indentation'}
                    if(4L*$n+$rest.Length+1 -gt 1048576L-$body.Length){throw 'Indent expansion limit'}
                    $line=(' '*(4*$n))+$rest
                }
            }
            if($line.Length+1L -gt 1048576L-$body.Length){throw 'Body limit'}
            [void]$body.Append($line).Append("`n")
        }
        if($h[0] -cne 'ADDED' -and $dictionary.Count -ne $h[6]){throw 'Wrong dictionary end'}
        $value=$body.ToString()
        $originalHeader="diff --git a/$($h[1]) b/$($h[1])`nnew file mode $($h[2])`nindex $($h[3])`n--- /dev/null`n+++ b/$($h[1])`n@@ -0,0 +1,$($h[4]) @@`n"
        $reconstructed=[long]$originalHeader.Length+$value.Length+$h[4]
        if($reconstructed -gt 4194304L-$total){throw 'Aggregate reconstructed diff limit'}
        $total+=$reconstructed
        $bodies.Add($value);$headers.Add($h)
    }
    [pscustomobject]@{Bodies=$bodies.ToArray();Headers=$headers.ToArray();Dictionary=$dictionary.ToArray();Units=$dictionaryUnits}
}

$decoded=Read-IndependentSourceVector $v.Positive
Assert-Eq $decoded.Bodies.Count 3 'two source frames and one whole literal fallback'
Assert-Eq $decoded.Headers[0][0] LINES 'first frame retains exact space/tab prefixes'
Assert-Eq $decoded.Headers[1][0] INDENT_LINES 'second frame restores rows before indentation'
Assert-Eq $decoded.Headers[2][0] ADDED 'reserved literal marker uses whole-file fallback'
Assert-Eq $decoded.Dictionary.Count 2 'contiguous shared dictionary has two explicit declarations'
Assert-Eq $decoded.Headers[0][5] 0 'first dictionary starts empty'
Assert-Eq $decoded.Headers[0][6] 1 'first dictionary ends after declaration zero'
Assert-Eq $decoded.Headers[1][5] 1 'second file consumes earlier dictionary'
Assert-Eq $decoded.Headers[1][6] 2 'second file declares next contiguous entry'
Assert-Eq ($decoded.Bodies[0]+"---NEXT---`n"+$decoded.Bodies[1]+"---LITERAL---`n"+$decoded.Bodies[2]) $v.Expected 'independent decode equals complete literal expectation'
$expectedBlobs=@('afc8f8e563bab070c2d3f9d07d81401953fbdb62','6b3454d478e0bdc2fa6d458b716c9852f1c48cc6','49c8b31dcb9f44cb502f666c07dd96ec4e3df275')
foreach($i in 0..2) {
    Assert-Eq $v.Blobs[$i] $expectedBlobs[$i] "fixed literal expected blob $i"
    Assert-Eq $decoded.Bodies[$i] $v.Bodies[$i] "literal source body $i exact"
    $bytes=[Text.Encoding]::UTF8.GetBytes($decoded.Bodies[$i])
    $prefix=[Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($prefix+$bytes))).ToLowerInvariant()
    Assert-Eq $hash $v.Blobs[$i] "independent full Git blob hash $i"
    Assert-Eq $decoded.Headers[$i][3] ('0000000..'+$hash) "index binds complete blob $i"
    Assert-Eq $decoded.Headers[$i][2] '100644' "mode remains exact $i"
}
Assert-Eq $decoded.Headers[0][1] 'src/RawFixture.kt' 'first path identity'
Assert-Eq $decoded.Headers[1][1] 'src/OtherFixture.kt' 'second path identity'
Assert-Eq $decoded.Headers[2][1] 'src/Collision.kt' 'literal path identity'
Assert-True ($decoded.Bodies[0].Contains(" `tshared") -and $decoded.Bodies[1].Contains('        shared')) 'cross-file references preserve differing prefixes'
Assert-True ($decoded.Bodies[0].Contains('"""') -and $decoded.Bodies[0].Contains("`n`n")) 'raw string delimiters and blank row survive'
Assert-True ($decoded.Bodies[0].Contains("a`tB  `n") -and $decoded.Bodies[1].Contains("a`tB  `n")) 'interior tabs and trailing spaces survive references'
Assert-True ($decoded.Bodies[0].Contains('["LINES","literal delimiter-looking data"]')) 'delimiter-looking line remains source data'
Assert-True ($decoded.Bodies[2].Contains('~0=literal') -and $decoded.Bodies[2].Contains("`t~00~")) 'literal reserved cores neither declare nor reference'
Assert-True ($v.Expected.Length -le 800) 'exact live response fits existing summary schema'
Assert-Eq $v.LineCount 19 'all LF-terminated rows counted'
foreach($case in @('NegativeForward','NegativeUnknown')) {
    Assert-True ($v.$case -cne $v.Positive) "$case changes source reference"
    $headers=@($v.Positive -split "`n"|Where-Object {$_ -cmatch '^\["(?:LINES|INDENT_LINES|ADDED)",'})
    $badHeaders=@($v.$case -split "`n"|Where-Object {$_ -cmatch '^\["(?:LINES|INDENT_LINES|ADDED)",'})
    Assert-Eq ($badHeaders -join "`n") ($headers -join "`n") "$case retains exact valid framing headers"
    Assert-Eq ($v.$case.Split("`n").Count) ($v.Positive.Split("`n").Count) "$case retains row count"
    try{Read-IndependentSourceVector $v.$case|Out-Null;Assert-True $false "$case rejects canonical unresolved ID"}
    catch{Assert-Eq $_.Exception.Message INVALID_SOURCE_LINES "$case rejects reference control without source execution"}
}
$fixture=$ast.Extent.Text
foreach($guard in @('Get-CompactSourceLineProtocol','Get-CompactIndentationProtocol','Get-CompactReviewProtocol',
    'source_line_protocol_sha256','indentation_protocol_sha256','compact_protocol_sha256',
    'RequireProcessTreeRetirement','Get-BoundReviewProfile','Test-EmbedBudget','Test-PromptCharacterLimit',
    'CreateNew','FileShare]::Read','CreateExclusiveDirectory','SetAccessRuleProtection','maximum_input_tokens',
    'if(-not $run.ProcessTreeRetired){break}','if($resource.Retired)','Assert-HarnessSafe')) {
    Assert-True ($fixture.Contains($guard)) "live proof retains $guard"
}
Assert-True ($fixture.Contains('$cases.Count -eq 3')) 'all three private cases required for proof'
Write-TestResult
