. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
$invoke=Join-Path $PSScriptRoot '../gauntlet-review/scripts/invoke-codex.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($invoke,[ref]$tokens,[ref]$errors)
Assert-Eq $errors.Count 0 'entry parses'
Assert-True ($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -contains 'CompactRepeatedLines') 'source-line framing is explicit opt-in'
function Entry([string]$Prefix) {
    $body=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[0].Body
    $matches=@($body.Statements | Where-Object {$_.Extent.Text.StartsWith($Prefix,[StringComparison]::Ordinal)})
    if($matches.Count -ne 1){throw "Missing unique production statement: $Prefix"}
    return $matches[0].Extent.Text
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('source-line-input-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $root 'src')) | Out-Null
try {
    function Fixture-Git([string[]]$GitArguments) { $v=& git -C $root @GitArguments; if($LASTEXITCODE){throw 'Fixture Git failed'}; $v }
    Fixture-Git @('init','-q'); Fixture-Git @('-c','user.name=geoffroth','-c','user.email=test@example.invalid','commit','-q','--allow-empty','-m','base')
    $base=(Fixture-Git @('rev-parse','HEAD')).Trim()
    $private='PRIVATE_SOURCE_LINE_INPUT'
    $body=("value($private"+('x'*384)+")`n")*2000
    foreach($name in @('a.kt','b.kt')) {[IO.File]::WriteAllText((Join-Path $root "src/$name"),$body,[Text.UTF8Encoding]::new($false))}
    Fixture-Git @('-c','core.autocrlf=false','add','src'); Fixture-Git @('-c','user.name=geoffroth','-c','user.email=test@example.invalid','commit','-q','-m','head')
    $head=(Fixture-Git @('rev-parse','HEAD')).Trim();$preamble=Join-Path $root 'preamble.txt';[IO.File]::WriteAllText($preamble,'Review complete input.')
    $missing=Join-Path $root 'absent-cli.exe'
    function Run([string]$Name,[string[]]$Flags,[string]$Mode='local',[long]$Budget=1048576) {
        $state=Join-Path $root $Name
        $arguments=@('-NoProfile','-File',$invoke,'-Mode',$Mode,'-PromptFile',$preamble,'-StateDir',$state,'-Round','1','-RepoRoot',$root,'-BaseOid',$base,'-HeadSha',$head,'-BudgetBytes',$Budget.ToString([Globalization.CultureInfo]::InvariantCulture),'-CliPathOverride',$missing)+$Flags
        if($Mode -eq 'doc'){$arguments+=@('-ArtifactPath','fixture.md','-ArtifactCommit',$head)}
        $r=Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList $arguments -TimeoutSec 60 -RequireProcessTreeRetirement
        Assert-True (-not $r.StartFailed -and -not $r.TimedOut -and $r.ProcessTreeRetired) "$Name bounded completion"
        Assert-Eq @(Get-ChildItem $state -Recurse -File -ErrorAction SilentlyContinue | Where-Object Name -match 'attempt|meta|cli-pin').Count 0 "$Name no attempt allocated"
        Assert-True (-not($r.Stdout+$r.Stderr).Contains($private)) "$Name no source in diagnostics"
        [pscustomobject]@{Run=$r;State=$state}
    }
    $plain=Run plain @('-CompactAddedFiles');Assert-Eq $plain.Run.ExitCode 10 'literal complete payload over fixed cap'
    $encoded=Run encoded @('-CompactAddedFiles','-CompactRepeatedLines');Assert-Eq $encoded.Run.ExitCode 12 'encoded complete payload reaches deliberately absent CLI'
    $reason=(Get-Content -Raw (Join-Path $encoded.State 'state.json')|ConvertFrom-Json).failure_reason
    Assert-True ($reason -match '^CLI probe:') 'both exact full-prompt caps passed before CLI'
    $dependency=Run dependency @('-CompactRepeatedLines');Assert-Eq $dependency.Run.ExitCode 12 'source-line framing requires compact composition'
    Assert-True (($dependency.Run.Stdout+$dependency.Run.Stderr) -match 'Source-line encoding requires verified compact composition') 'specific dependency guard'
    $doc=Run doc @('-CompactAddedFiles','-CompactRepeatedLines') doc;Assert-Eq $doc.Run.ExitCode 12 'doc mode refused'

    foreach($name in @('Get-CompactReviewGitRange','Get-ReviewGitQuotedPath')) {
        $f=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq $name}.GetNewClosure(),$true)
        . ([scriptblock]::Create($f.Extent.Text))
    }
    $composition=Entry 'if ($Mode -eq ''local'' -or $CompactAddedFiles)'
    foreach($mode in @('local','pr')) {
        $range=Get-CompactReviewGitRange -RepoRoot $root -BaseOid $base -HeadSha $head -Mode $mode
        & {
            $Mode=$mode;$RepoRoot=$root;$canonBase=$base;$canonHead=$head;$localDiff=$range.Diff;$promptBody='Review complete input.'
            $CompactAddedFiles=$true;$CompactIndentation=$true;$CompactRepeatedLines=$true;$CompactReviewMetadata=$true;$VerifiedReferenceFile=$null
            $prInput=if($mode -eq 'pr'){[pscustomobject]@{Text="verified PR metadata`n"}}else{$null}
            . ([scriptblock]::Create($composition))
            Assert-True ((Test-PromptCharacterLimit -PromptText $promptBody).Ok) "$mode exact scalar gate"
            Assert-True ((Test-EmbedBudget -PromptText $promptBody -BudgetBytes 1048576).Ok) "$mode exact byte gate"
            Assert-True ($promptBody.Contains((Get-CompactSourceLineProtocol))) "$mode protocol embedded"
            $restored=Restore-ReviewMetadataDiff -Diff $reviewDiff -Manifest $metadataCoverage
            Assert-Eq (Restore-CompactReviewDiff -Diff $restored -Manifest $compactCoverage) $range.Diff "$mode layered exact complete diff"
            Assert-Eq @($compactCoverage.sections | Where-Object {$_.PSObject.Properties['encoding'] -and $_.encoding -ceq 'lines'}).Count 2 "$mode both files encoded"
            $meta=@{};. ([scriptblock]::Create((Entry 'if($CompactRepeatedLines)')))
            Assert-Eq $meta.compact_source_line_protocol_sha256 (Get-ReviewTextHash (Get-CompactSourceLineProtocol)) "$mode immutable protocol binding"
        }
    }
    # This candidate remains over the fixed cap even after all duplicate rows encode.
    # Merely changing BudgetBytes on the already-fitting candidate proves nothing.
    $unique=('z'*1048000)+"`nend`n"
    [IO.File]::WriteAllText((Join-Path $root 'src/unique.kt'),$unique,[Text.UTF8Encoding]::new($false))
    Fixture-Git @('-c','core.autocrlf=false','add','src/unique.kt')
    Fixture-Git @('-c','user.name=geoffroth','-c','user.email=test@example.invalid','commit','-q','-m','unique over-cap source')
    $head=(Fixture-Git @('rev-parse','HEAD')).Trim()
    $raised=Run -Name raised -Flags @('-CompactAddedFiles','-CompactRepeatedLines') -Budget 1048577
    Assert-Eq $raised.Run.ExitCode 10 'encoded complete payload still cannot exceed the unchanged cap'
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^source-line-input-[0-9a-f]{32}$'){throw 'Unsafe fixture cleanup'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-TestResult
