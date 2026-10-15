. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$path=Join-Path $PSScriptRoot 'live/live-indent-review.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert-Eq $errors.Count 0 'reader fixture parses'
$function=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq 'New-IndentReaderVector'},$true)
. ([scriptblock]::Create($function.Extent.Text))
$v=New-IndentReaderVector
foreach($name in @('Positive','Negative')) {
    $frame=$v.$name;$first=$frame.IndexOf("`n");$header=$frame.Substring(0,$first)|ConvertFrom-Json
    Assert-Eq $header[0] INDENT "$name explicit indentation frame"
    $cursor=$first+1;$end=$cursor
    for($i=0;$i -lt $header[4];$i++){$end=$frame.IndexOf("`n",$end)+1;if($end -le 0){throw 'Fixture frame truncated'}}
    $body=$frame.Substring($cursor,$end-$cursor)
    if($name -ceq 'Positive') {
        $decoded=ConvertFrom-CompactIndentationBody -Body $body -Count $header[4]
        $tail=$frame.Substring($end);$hEnd=$tail.IndexOf("`n");$fallback=$tail.Substring(0,$hEnd)|ConvertFrom-Json
        Assert-Eq $fallback[0] ADDED 'literal leading tab uses unchanged framing'
        $literal=$tail.Substring($hEnd+1)
        Assert-Eq ($decoded+"---LITERAL---`n"+$literal) $v.Expected 'production decoder matches exact reader expectation'
        Assert-Eq (Get-CompactReviewBlobHash $decoded) $v.Blobs[0] 'full source blob identity'
        Assert-Eq (Get-CompactReviewBlobHash $literal) $v.Blobs[1] 'literal-tab source blob identity'
        Assert-True ($decoded.Contains('"""') -and $decoded.Contains("`n`n")) 'raw strings and blank lines retained'
        Assert-True ($decoded.Contains("a`tB") -and $literal.StartsWith("`t")) 'interior and literal-leading tabs retain their distinct rules'
    } else { Assert-Throws {ConvertFrom-CompactIndentationBody -Body $body -Count $header[4]} 'production decoder rejects independent noncanonical reader case' }
}
Assert-True ($v.Expected.Length -le 800) 'exact decoded source fits schema summary'
Write-TestResult
