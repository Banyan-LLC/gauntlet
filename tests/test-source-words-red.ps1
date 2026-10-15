# Minimal behavioral red: fixed fake Git, no model, no source payload logging.
. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
$head='a'*40; $base='b'*40; $path='src/word-red.kt'
$body=''
foreach ($i in 0..31) { $body+="        assertEquals(failureValue, expectedValue$i); // assertEquals failureValue`n" }
$script:WordRedBody=$body
$script:WordRedPath=$path
$blob=Get-CompactReviewBlobHash $body
$script:WordRedBlob=$blob
$header=Get-CompactReviewOriginalHeader $path '100644' ('0000000..'+$blob.Substring(0,7)) 32
$diff=$header+'+'+$body.Substring(0,$body.Length-1).Replace("`n","`n+")+"`n"
function Invoke-BoundedProcess {
    param($FileName,$ArgList,$TimeoutSec,[switch]$RequireProcessTreeRetirement)
    $stdout=''
    if ($ArgList -contains 'ls-tree') {
        if ($ArgList -contains $head) { $stdout="100644 blob $script:WordRedBlob`t$script:WordRedPath`n" }
    } elseif ($ArgList -contains 'cat-file') { $stdout=$script:WordRedBody }
    else { throw 'Unexpected fake Git request' }
    [pscustomobject]@{StartFailed=$false;TimedOut=$false;ExitCode=0;ProcessTreeRetired=$true;ErrorMessage=$null;Stdout=$stdout}
}
$argsForRender=@{RepoRoot=(Split-Path $PSScriptRoot);BaseOid=$base;HeadSha=$head;Diff=$diff
    CompactIndentation=$true;CompactSourceFrames=$true}
$before=ConvertTo-CompactReviewDiff @argsForRender
# Before the flag lands, exercise the actual baseline rather than fail parameter binding.
# Afterwards the identical assertion exercises the requested optional word pass.
if ((Get-Command ConvertTo-CompactReviewDiff).Parameters.ContainsKey('CompactSourceWords')) {
    $argsForRender.CompactSourceWords=$true
}
$actual=ConvertTo-CompactReviewDiff @argsForRender
Assert-True ($actual.Diff.StartsWith('["WORDS",',[StringComparison]::Ordinal)) 'profitable verified F body must receive WORDS envelope'
Assert-True ($actual.Diff.Length -lt $before.Diff.Length) 'word envelope must strictly shorten actual previous frame'
Assert-True ((Restore-CompactReviewDiff -Diff $actual.Diff -Manifest $actual.Manifest) -ceq $diff) 'word candidate must still restore exact original source diff'
Write-TestResult
