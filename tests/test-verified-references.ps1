. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('verified-ref-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    git -C $root init -q
    git -C $root -c user.name=geoffroth -c user.email=test@example.invalid commit -q --allow-empty -m base
    $base=(git -C $root rev-parse HEAD).Trim()
    $path='docs/superpowers/specs/approved.md'
    New-Item -ItemType Directory -Path (Split-Path (Join-Path $root $path)) -Force | Out-Null
    $body="# Approved`n`nAll source and tests remain visible.`n"
    [IO.File]::WriteAllText((Join-Path $root $path),$body,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $root 'source.txt'),"unique source`n")
    git -C $root -c core.autocrlf=false add .
    git -C $root -c user.name=geoffroth -c user.email=test@example.invalid commit -q -m added
    $head=(git -C $root rev-parse HEAD).Trim()
    $blob=(git -C $root rev-parse "${head}:$path").Trim()
    $diff=git -C $root diff --no-ext-diff --no-textconv --no-color $base $head -- | Out-String
    $pre="instructions`n== TRUSTED CONTEXT (approved controlling documents only) ==`n$body"
    $file=Join-Path $root 'reference.json'
    $request=@{version=1;base_oid=$base;head_sha=$head;entries=@(@{path=$path;blob=$blob;normalized_sha256=(Get-ReviewTextHash $body)})}
    function Save-Request { $request | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file -Encoding utf8 }
    function Render { param($p=$pre,$d=$diff) ConvertTo-VerifiedReviewDiff -RepoRoot $root -BaseOid $base -HeadSha $head -Preamble $p -Diff $d -ReferenceFile $file }
    Save-Request
    $result=Render
    Assert-Eq $result.Manifest.sections.Count 2 'coverage includes every section'
    Assert-Eq @($result.Manifest.sections | Where-Object referenced).Count 1 'one reference only'
    $unique=@($result.Manifest.sections | Where-Object { -not $_.referenced })[0]
    Assert-Eq $unique.original_sha256 $unique.rendered_sha256 'nonduplicate section is unchanged'
    Assert-True ($result.Diff.Contains('+unique source')) 'unique source is present'
    Assert-True ($result.Diff.Contains('@@ -0,0 +1,3 @@')) 'exact hunk metadata is present'
    Assert-True ($result.Diff.Contains('as this added artifact')) 'reviewer sees dual role'
    Assert-Eq $result.Manifest.original_diff_sha256 (Get-ReviewTextHash $diff) 'original diff hash retained'
    Assert-Throws { Render -p ($pre.Replace('All source','Altered source')) } 'altered embedded body fails'
    Assert-Throws { Render -p ($pre+$body) } 'duplicate embedded body fails'
    Assert-Throws { Render -p $body } 'missing trusted-context boundary fails'
    Assert-Throws { Render -d ($diff.Replace('+All source','+Altered source')) } 'altered diff content fails'
    Assert-Throws { Render -d ($diff.Replace('@@ -0,0 +1,3 @@','@@ -0,0 +1,4 @@')) } 'wrong hunk count fails'
    Assert-Throws { Render -d ($diff.Replace('new file mode 100644','new file mode 100755')) } 'wrong mode fails'
    Assert-Throws { Render -d ($diff+$diff) } 'duplicate diff section fails'
    foreach ($field in @('base_oid','head_sha')) {
        $saved=$request[$field]; $request[$field]='0'*40; Save-Request
        Assert-Throws { Render } "$field mismatch fails"
        $request[$field]=$saved
    }
    foreach ($field in @('blob','normalized_sha256','path')) {
        $saved=$request.entries[0][$field]; $request.entries[0][$field]='bad'; Save-Request
        Assert-Throws { Render } "$field mismatch fails"
        $request.entries[0][$field]=$saved
    }
    Save-Request
    Assert-Throws { Render -d ($diff.Replace("+All source and tests remain visible."," All source and tests remain visible.")) } 'nonaddition body fails'
    Assert-Throws { Render -d ($diff+"`r") } 'standalone CR fails'
    $capacity='{"models":[{"slug":"gpt-6.1-sol","context_window":500000,"max_context_window":872000,"effective_context_window_percent":95}]}'
    Assert-Eq (Get-ReviewCapacityFromCatalog $capacity).maximum_input_tokens 228250 'actual 500k capacity with reserve and headroom'
    Assert-Eq (Get-ReviewCapacityFromCatalog ($capacity.Replace('500000','272000'))).maximum_input_tokens 65800 'smaller actual context tightens gate'
    Assert-Throws { Get-ReviewCapacityFromCatalog '{}' } 'missing catalog fails'
    Assert-Throws { Get-ReviewCapacityFromCatalog ($capacity.Replace('500000','"500000"')) } 'string capacity fails'
    Assert-Throws { Get-ReviewCapacityFromCatalog ($capacity.Replace('500000','999999')) } 'context above maximum fails'
    Assert-Throws { Get-ReviewCapacityFromCatalog ($capacity.Replace(':95',':101')) } 'invalid effective percentage fails'
    Assert-Throws { Get-ReviewCapacityFromCatalog ($capacity.Replace('500000','100000')) } 'reserve cannot fit fails'
    $scriptText=Get-Content "$PSScriptRoot/../gauntlet-review/scripts/invoke-codex.ps1" -Raw
    Assert-True ($scriptText.IndexOf('ConvertTo-VerifiedReviewDiff') -lt $scriptText.IndexOf('Write-AttemptMeta -StateDir')) 'reference check precedes attempt allocation'
    Assert-True ($scriptText.IndexOf('Get-ReviewCapacityFromCatalog') -lt $scriptText.IndexOf('Write-AttemptMeta -StateDir')) 'capacity evidence precedes attempt allocation'
    Assert-True ($scriptText.Contains('$usage.InputTokens -gt $maximumInputTokens')) 'acceptance checks actual input tokens against captured limit'
    $meta=@{verified_reference_coverage=$result.Manifest}
    Write-AttemptMeta -StateDir $root -Round 2 -Attempt 1 -Meta $meta
    $record=Get-Content (Join-Path $root 'round-2-attempt-1-meta.json') -Raw | ConvertFrom-Json
    Assert-Eq $record.verified_reference_coverage.sections.Count 2 'immutable record keeps complete coverage'
    Assert-Throws { Write-AttemptMeta -StateDir $root -Round 2 -Attempt 1 -Meta $meta } 'existing attempt record cannot be replaced'
    # Exercise the actual entry point: a bad reference is refused before CLI
    # discovery, attempt allocation or review dispatch, even on round one.
    $state=Join-Path $root 'state'
    $preFile=Join-Path $root 'preamble.txt'
    [IO.File]::WriteAllText($preFile,$pre)
    $request.head_sha='0'*40; Save-Request
    $invoke=Join-Path $PSScriptRoot '../gauntlet-review/scripts/invoke-codex.ps1'
    $failure=Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList @('-NoProfile','-File',$invoke,'-Mode','local','-PromptFile',$preFile,'-StateDir',$state,'-Round','1','-RepoRoot',$root,'-BaseOid',$base,'-HeadSha',$head,'-VerifiedReferenceFile',$file,'-CliPathOverride',(Join-Path $root 'must-not-run.exe')) -TimeoutSec 30 -RequireProcessTreeRetirement
    Assert-Eq $failure.ExitCode 12 'invalid reference entry point refuses'
    Assert-Eq @(Get-ChildItem $state -Filter '*attempt*').Count 0 'invalid reference allocates no attempt'
    Assert-True (-not (Test-Path (Join-Path $state 'cli-pin.json'))) 'invalid reference never probes CLI'
    # Execute the real capacity admission block with an offline process stub.
    $capacityStart=$scriptText.IndexOf('$referenceCapacity = $null')
    $capacityEnd=$scriptText.IndexOf('# --- Harness.', $capacityStart)
    $capacityBlock='$activeBoundProfile=$null;' + $scriptText.Substring($capacityStart,$capacityEnd-$capacityStart)
    $libPath=(Resolve-Path "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1").Path.Replace("'","''")
    foreach ($case in @('mismatch','malformed','unavailable','insufficient','matching')) {
        $live=$capacity
        $bundled=$capacity.Replace('500000','272000')
        if ($case -eq 'malformed') { $live='{}' }
        if ($case -eq 'insufficient') { $live=$capacity.Replace('500000','100000'); $bundled=$live }
        if ($case -eq 'matching') { $bundled=$live }
        $live64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($live))
        $bundle64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bundled))
        $childCode=". '$libPath'; `$VerifiedReferenceFile='test'; `$cli=@{Path='never-run'}; function Invoke-BoundedProcess { param(`$FileName,`$ArgList,`$TimeoutSec,`$EnvironmentMap,`$WorkingDirectory,[switch]`$RequireProcessTreeRetirement) `$text=if(`$ArgList -contains '--bundled'){[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$bundle64'))}else{[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$live64'))}; [pscustomobject]@{StartFailed=('$case' -eq 'unavailable');TimedOut=`$false;ExitCode=0;ProcessTreeRetired=`$true;Stdout=`$text} }; " + $capacityBlock + '; exit 0'
        $child=Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList @('-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCode))) -TimeoutSec 30 -RequireProcessTreeRetirement
        Assert-Eq $child.ExitCode $(if($case -eq 'matching'){0}else{12}) "real capacity admission: $case"
    }
} finally {
    # This suite creates only regular entries under its unique owned temp root.
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-TestResult
