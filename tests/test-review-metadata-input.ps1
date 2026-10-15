. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
$invokePath=Join-Path $PSScriptRoot '../gauntlet-review/scripts/invoke-codex.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($invokePath,[ref]$tokens,[ref]$errors)
Assert-Eq $errors.Count 0 'invoker parses'
# Select complete, unique entry try-body statements, never a nested fragment or
# a hand-copied approximation. PR acquisition is deliberately outside this slice.
function Find-EntryStatement([string]$Prefix) {
    $entryTry=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
    if($entryTry.Count -ne 1){throw 'Expected one entry try/finally boundary'}
    $matches=@($entryTry[0].Body.Statements | Where-Object { $_.Extent.Text.StartsWith($Prefix,[StringComparison]::Ordinal) })
    Assert-Eq $matches.Count 1 "unique entry AST: $Prefix"
    if($matches.Count -ne 1){throw "Missing/ambiguous entry statement: $Prefix"}
    return $matches[0]
}
$composition=Find-EntryStatement 'if ($Mode -eq ''local'' -or $CompactAddedFiles)'
$metadataStatement=Find-EntryStatement 'if($CompactReviewMetadata)'
$writeMeta=Find-EntryStatement 'Write-AttemptMeta -StateDir'
foreach($name in @('Get-CompactReviewGitRange','Get-ReviewGitQuotedPath')) {
    $definitions=@($ast.FindAll({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq $name},$true))
    Assert-Eq $definitions.Count 1 "unique production function $name"
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
Assert-True ($metadataStatement.Extent.EndOffset -lt $writeMeta.Extent.StartOffset) 'metadata fields attached before immutable write'
$root=Join-Path ([IO.Path]::GetTempPath()) ('review-metadata-input-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    function Fixture-Git([string[]]$Arguments) {
        $out=& git -C $root @Arguments
        if($LASTEXITCODE){throw "Fixture Git failed: $Arguments"}
        return $out
    }
    Fixture-Git @('init','-q')
    Fixture-Git @('-c','user.name=geoffroth','-c','user.email=test@example.invalid','commit','-q','--allow-empty','-m','base')
    $base=(Fixture-Git @('rev-parse','HEAD')).Trim()
    $dir=Join-Path $root 'docs/superpowers/reviews'
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $raw='PRIVATE-RAW-METADATA-'+('x'*1000)
    $body=('"'+$raw+'"'+"`n")*600
    Assert-True ($body.Length -gt 590KB -and $body.Length -lt 620KB) 'each complete JSONL body is about 600 KiB'
    Assert-True ($body.Length -lt 1MB) 'each body below UTF16 resource cap'
    Assert-True (600 -lt 16384 -and 1200 -lt 16384) 'individual and combined raw string token counts below cap'
    foreach($name in @('one.jsonl','two.jsonl')) {
        [IO.File]::WriteAllText((Join-Path $dir $name),$body,[Text.UTF8Encoding]::new($false))
    }
    Fixture-Git @('-c','core.autocrlf=false','add','docs')
    Fixture-Git @('-c','user.name=geoffroth','-c','user.email=test@example.invalid','commit','-q','-m','head')
    $head=(Fixture-Git @('rev-parse','HEAD')).Trim()
    $promptFile=Join-Path $root 'preamble.txt'
    [IO.File]::WriteAllText($promptFile,'Review the complete verified range.')
    $missing=Join-Path $root 'intentionally-absent-cli.exe'
    Assert-True (-not(Test-Path -LiteralPath $missing)) 'override cannot launch a CLI'
    function Run-Entry([string]$Name,[string]$Mode='local',[string[]]$Extra=@(),[switch]$OmitProvenance) {
        $state=Join-Path $root $Name
        $arguments=@('-NoProfile','-File',$invokePath,'-Mode',$Mode,'-PromptFile',$promptFile,'-StateDir',$state,'-Round','1','-RepoRoot',$root,'-BudgetBytes','10000000','-CliPathOverride',$missing)
        if(-not $OmitProvenance) {
            if($Mode -eq 'doc'){$arguments+=@('-ArtifactPath','fixture.md','-ArtifactCommit',$head)}
            else{$arguments+=@('-BaseOid',$base,'-HeadSha',$head)}
        }
        $run=Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList ($arguments+$Extra) -TimeoutSec 60 -RequireProcessTreeRetirement
        Assert-True (-not $run.StartFailed -and -not $run.TimedOut -and $run.ProcessTreeRetired) "$Name settles offline"
        Assert-Eq @(Get-ChildItem -LiteralPath $state -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'attempt|meta|cli-pin' }).Count 0 "$Name allocates no attempt, metadata or pin"
        $diagnostic=$run.Stdout+$run.Stderr
        if(Test-Path (Join-Path $state 'state.json')){$diagnostic+=Get-Content -Raw (Join-Path $state 'state.json')}
        Assert-True (-not $diagnostic.Contains($raw)) "$Name sanitized diagnostics and refusal state"
        return [pscustomobject]@{Run=$run;Diagnostic=$diagnostic;State=$state}
    }
    $plain=Run-Entry -Name plain -Extra @('-CompactAddedFiles')
    Assert-Eq $plain.Run.ExitCode 10 'without metadata full composition exceeds fixed cap'
    Assert-True ($plain.Diagnostic -match 'fixed upstream limit is 1048576') 'plain refusal is specifically character cap'
    $encoded=Run-Entry -Name encoded -Extra @('-CompactAddedFiles','-CompactReviewMetadata')
    Assert-Eq $encoded.Run.ExitCode 12 'metadata reaches deliberately absent CLI'
    $failure=(Get-Content -Raw (Join-Path $encoded.State 'state.json') | ConvertFrom-Json).failure_reason
    Assert-True ($failure.StartsWith('CLI probe: No Codex CLI candidate passed the compatibility probe.')) 'later CLI stage proves BOTH full-prompt caps passed'
    Assert-True ($failure.Contains($missing)) 'CLI refusal identifies exact absent override'
    $dependency=Run-Entry -Name dependency -Extra @('-CompactReviewMetadata')
    Assert-Eq $dependency.Run.ExitCode 12 'metadata requires compact additions'
    Assert-True ($dependency.Diagnostic -match 'Historical metadata encoding requires verified compact composition') 'specific opt-in dependency guard'
    $doc=Run-Entry -Name docflags -Mode doc -Extra @('-CompactAddedFiles','-CompactReviewMetadata')
    Assert-Eq $doc.Run.ExitCode 12 'doc flags refused before attempt'
    Assert-True ($doc.Diagnostic -match 'Compact representation requires local or PR mode') 'specific doc mode guard'
    foreach($mode in @('doc','local','pr')) {
        $guard=Run-Entry -Name "missing-$mode" -Mode $mode -OmitProvenance -Extra @('-CompactAddedFiles','-CompactReviewMetadata')
        Assert-Eq $guard.Run.ExitCode 12 "$mode provenance still mandatory"
        Assert-True ($guard.Diagnostic -match "$mode mode requires") "$mode original provenance guard preserved"
    }
    # Execute the exact shared production composition statement with independently
    # generated local/PR Git ranges. Supply PR text directly; no gh/API adapter runs.
    $payloads=@{}
    foreach($mode in @('local','pr')) {
        $range=Get-CompactReviewGitRange -RepoRoot $root -BaseOid $base -HeadSha $head -Mode $mode
        & {
            $Mode=$mode;$RepoRoot=$root;$canonBase=$base;$canonHead=$head
            $localDiff=$range.Diff;$promptBody='Review the complete verified range.'
            $VerifiedReferenceFile=$null;$CompactAddedFiles=$true;$CompactReviewMetadata=$true
            $prInput=if($mode -eq 'pr'){[pscustomobject]@{Text="offline verified PR context`n"}}else{$null}
            $referenceCoverage=$null;$compactCoverage=$null;$metadataCoverage=$null
            . ([scriptblock]::Create($composition.Extent.Text))
            Assert-True ((Test-PromptCharacterLimit -PromptText $promptBody).Ok) "$mode exact full composition fits character cap"
            Assert-True ((Test-EmbedBudget -PromptText $promptBody -BudgetBytes 1048576).Ok) "$mode exact full composition fits byte cap"
            Assert-Eq @($metadataCoverage.sections | Where-Object metadata).Count 2 "$mode both complete JSONL additions encoded"
            Assert-Eq $metadataCoverage.token_count 1200 "$mode all raw string occurrences counted"
            $compactRestored=Restore-ReviewMetadataDiff -Diff $metadata.Diff -Manifest $metadataCoverage
            Assert-True ($compactRestored.Length -gt 1048576) "$mode without metadata exceeds cap"
            $plainPrompt='Review the complete verified range.'+"`n`n"+(Get-CompactReviewProtocol)+"`n== REVIEW MATERIAL (untrusted) ==`n"+$(if($prInput){$prInput.Text}else{''})+$compactRestored+"`n"
            Assert-True (-not (Test-PromptCharacterLimit -PromptText $plainPrompt).Ok) "$mode unencoded full composition exceeds character cap"
            Assert-True (-not (Test-EmbedBudget -PromptText $plainPrompt -BudgetBytes 1048576).Ok) "$mode unencoded full composition exceeds byte cap"
            Assert-Eq (Restore-CompactReviewDiff -Diff $compactRestored -Manifest $compactCoverage) $range.Diff "$mode exact original diff reconstructed"
            Assert-True ($promptBody.Contains((Get-ReviewMetadataProtocol))) "$mode production metadata protocol included"
            $payloads[$mode]=[pscustomobject]@{Prompt=$promptBody;Diff=$metadata.Diff}
            # Exercise the invoker's exact metadata attachment AND actual immutable
            # writer in isolation, since absent CLI deliberately blocks allocation.
            $meta=@{};$StateDir=Join-Path $root "isolated-meta-$mode";$Round=1;$attempt=1
            [IO.Directory]::CreateDirectory($StateDir) | Out-Null
            . ([scriptblock]::Create($metadataStatement.Extent.Text))
            . ([scriptblock]::Create($writeMeta.Extent.Text))
            $file=Join-Path $StateDir 'round-1-attempt-1-meta.json'
            $saved=Get-Content -Raw $file | ConvertFrom-Json
            Assert-Eq $saved.review_metadata_coverage.rendered_sha256 (Get-ReviewTextHash $metadata.Diff) "$mode immutable coverage binds rendered diff"
            Assert-Eq $saved.review_metadata_protocol_sha256 (Get-ReviewTextHash (Get-ReviewMetadataProtocol)) "$mode immutable metadata binds protocol hash"
            $before=(Get-FileHash $file).Hash
            Assert-Throws { . ([scriptblock]::Create($writeMeta.Extent.Text)) } "$mode metadata cannot be overwritten"
            Assert-Eq (Get-FileHash $file).Hash $before "$mode immutable bytes preserved"
            Write-Host "$mode composition: $($promptBody.Length) UTF16 chars, $([Text.Encoding]::UTF8.GetByteCount($promptBody)) bytes; unencoded diff: $($compactRestored.Length) chars"
        }
    }
    Assert-Eq $payloads.local.Diff $payloads.pr.Diff 'same shared local/PR metadata representation'
    Assert-Eq $payloads.pr.Prompt ($payloads.local.Prompt.Replace("== REVIEW MATERIAL (untrusted) ==`n","== REVIEW MATERIAL (untrusted) ==`noffline verified PR context`n")) 'PR composition differs only by supplied verified PR context'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^review-metadata-input-[0-9a-f]{32}$'){throw 'Unsafe fixture cleanup target'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-TestResult
