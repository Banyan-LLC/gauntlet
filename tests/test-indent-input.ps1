. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
$invoke=Join-Path $PSScriptRoot '../gauntlet-review/scripts/invoke-codex.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($invoke,[ref]$tokens,[ref]$errors)
Assert-Eq $errors.Count 0 'entry parses'
Assert-True ($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -contains 'CompactIndentation') 'indentation is explicit opt-in'
function Entry([string]$Prefix) {
    $body=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[0].Body
    $matches=@($body.Statements | Where-Object {$_.Extent.Text.StartsWith($Prefix,[StringComparison]::Ordinal)})
    if($matches.Count -ne 1){throw "Missing unique production statement: $Prefix"}
    return $matches[0].Extent.Text
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('indent-input-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $root 'src')) | Out-Null
try {
    function Fixture-Git([string[]]$GitArguments) { $v=& git -C $root @GitArguments; if($LASTEXITCODE){throw 'Fixture Git failed'}; $v }
    Fixture-Git @('init','-q'); Fixture-Git @('-c','user.name=geoffroth','-c','user.email=test@example.invalid','commit','-q','--allow-empty','-m','base')
    $base=(Fixture-Git @('rev-parse','HEAD')).Trim()
    $private='PRIVATE_INDENT_INPUT'
    $body=(' '*600000)+"value($private)`nend`n"
    foreach($name in @('a.kt','b.kt')) {[IO.File]::WriteAllText((Join-Path $root "src/$name"),$body,[Text.UTF8Encoding]::new($false))}
    Fixture-Git @('-c','core.autocrlf=false','add','src'); Fixture-Git @('-c','user.name=geoffroth','-c','user.email=test@example.invalid','commit','-q','-m','head')
    $head=(Fixture-Git @('rev-parse','HEAD')).Trim();$preamble=Join-Path $root 'preamble.txt';[IO.File]::WriteAllText($preamble,'Review complete input.')
    $missing=Join-Path $root 'absent-cli.exe'
    function Run([string]$Name,[string[]]$Flags,[string]$Mode='local') {
        $state=Join-Path $root $Name
        $arguments=@('-NoProfile','-File',$invoke,'-Mode',$Mode,'-PromptFile',$preamble,'-StateDir',$state,'-Round','1','-RepoRoot',$root,'-BaseOid',$base,'-HeadSha',$head,'-BudgetBytes','1048576','-CliPathOverride',$missing)+$Flags
        if($Mode -eq 'doc'){$arguments+=@('-ArtifactPath','fixture.md','-ArtifactCommit',$head)}
        $r=Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList $arguments -TimeoutSec 60 -RequireProcessTreeRetirement
        Assert-True (-not $r.StartFailed -and -not $r.TimedOut -and $r.ProcessTreeRetired) "$Name bounded completion"
        Assert-Eq @(Get-ChildItem $state -Recurse -File -ErrorAction SilentlyContinue | Where-Object Name -match 'attempt|meta|cli-pin').Count 0 "$Name no attempt allocated"
        Assert-True (-not($r.Stdout+$r.Stderr).Contains($private)) "$Name no source in diagnostics"
        [pscustomobject]@{Run=$r;State=$state}
    }
    $plain=Run plain @('-CompactAddedFiles');Assert-Eq $plain.Run.ExitCode 10 'literal complete payload over fixed cap'
    $encoded=Run encoded @('-CompactAddedFiles','-CompactIndentation');Assert-Eq $encoded.Run.ExitCode 12 'encoded complete payload reaches deliberately absent CLI'
    $reason=(Get-Content -Raw (Join-Path $encoded.State 'state.json')|ConvertFrom-Json).failure_reason
    Assert-True ($reason -match '^CLI probe:') 'both exact full-prompt caps passed before CLI'
    $dependency=Run dependency @('-CompactIndentation');Assert-Eq $dependency.Run.ExitCode 12 'indent requires compact composition'
    Assert-True (($dependency.Run.Stdout+$dependency.Run.Stderr) -match 'Indentation encoding requires verified compact composition') 'specific dependency guard'
    $doc=Run doc @('-CompactAddedFiles','-CompactIndentation') doc;Assert-Eq $doc.Run.ExitCode 12 'doc mode refused'
    foreach($name in @('Get-CompactReviewGitRange','Get-ReviewGitQuotedPath')) {
        $f=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq $name}.GetNewClosure(),$true)
        . ([scriptblock]::Create($f.Extent.Text))
    }
    $composition=Entry 'if ($Mode -eq ''local'' -or $CompactAddedFiles)'
    foreach($mode in @('local','pr')) {
        $range=Get-CompactReviewGitRange -RepoRoot $root -BaseOid $base -HeadSha $head -Mode $mode
        & {
            $Mode=$mode;$RepoRoot=$root;$canonBase=$base;$canonHead=$head;$localDiff=$range.Diff;$promptBody='Review complete input.'
            $CompactAddedFiles=$true;$CompactRepeatedLines=$false;$CompactIndentation=$true;$CompactReviewMetadata=$true;$VerifiedReferenceFile=$null
            $prInput=if($mode -eq 'pr'){[pscustomobject]@{Text="verified PR metadata`n"}}else{$null}
            . ([scriptblock]::Create($composition))
            Assert-True ((Test-PromptCharacterLimit -PromptText $promptBody).Ok) "$mode exact scalar gate"
            Assert-True ((Test-EmbedBudget -PromptText $promptBody -BudgetBytes 1048576).Ok) "$mode exact byte gate"
            Assert-True ($promptBody.Contains((Get-CompactIndentationProtocol))) "$mode protocol embedded"
            $restored=Restore-ReviewMetadataDiff -Diff $reviewDiff -Manifest $metadataCoverage
            Assert-Eq (Restore-CompactReviewDiff -Diff $restored -Manifest $compactCoverage) $range.Diff "$mode layered exact complete diff"
            Assert-Eq @($compactCoverage.sections | Where-Object {$_.PSObject.Properties['encoding'] -and $_.encoding -ceq 'indent'}).Count 2 "$mode both files encoded"
            $meta=@{};. ([scriptblock]::Create((Entry 'if($CompactIndentation)')))
            Assert-Eq $meta.compact_indentation_protocol_sha256 (Get-ReviewTextHash (Get-CompactIndentationProtocol)) "$mode immutable protocol binding"
        }
    }
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^indent-input-[0-9a-f]{32}$'){throw 'Unsafe fixture cleanup'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-TestResult
