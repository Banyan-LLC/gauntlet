. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
$invokePath=Join-Path $PSScriptRoot '../gauntlet-review/scripts/invoke-codex.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($invokePath,[ref]$tokens,[ref]$parseErrors)
Assert-Eq $parseErrors.Count 0 'entry point parses'
foreach($name in @('Get-VerifiedPrReviewInput','Assert-PrReviewInputFresh','Get-CompactReviewGitRange','Get-ReviewGitQuotedPath','Invoke-ReviewGhRead')) {
    $definition=$ast.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$base='a'*40;$head='b'*40;$expectedTip='c'*40
$script:fixture=@{number=9;url='https://github.com/example/project/pull/9';title='title';body="body`nall content";baseRefOid=$base;headRefOid=$head;baseRefName='main'}
$script:runs=@(@{name='required';status='completed';conclusion='success';head_sha=$head;details_url='https://example.invalid/ci/1'})
$script:status=@{sha=$head;state='success';total_count=0;statuses=@()}
$script:tip=$expectedTip;$script:partial=$false
$boundedGhRead=${function:Invoke-ReviewGhRead}
function Invoke-ReviewGhRead {
    param($Token,$GhArgs)
    if($GhArgs[0] -ceq 'pr'){$data=$script:fixture}
    elseif($GhArgs[-1].Contains('/git/ref/heads/')){$data=@{object=@{sha=$script:tip}}}
    elseif($GhArgs[-1].EndsWith('/check-runs')){$data=@(@{total_count=$(if($script:partial){99}else{$script:runs.Count});check_runs=$script:runs})}
    elseif($GhArgs[-1].EndsWith('/status')){$data=@($script:status)}
    else{throw 'Unexpected read'}
    [pscustomobject]@{ExitCode=0;Stdout=ConvertTo-Json -InputObject $data -Depth 8 -Compress}
}
function Read-Fixture { Get-VerifiedPrReviewInput -Token secret -OwnerRepo example/project -Pr 9 -BaseOid $base -HeadSha $head -BaseRefName main -BaseTipOid $expectedTip -RequiredCheckNames required }
$result=Read-Fixture
Assert-True ($result.Text.Contains('all content')) 'complete multiline PR body retained'
Assert-Eq $result.Provenance.metadata_sha256 (Get-ReviewTextHash $result.Text) 'exact metadata bound'
Assert-Eq $result.Metadata.checks.Count 1 'one check row is retained as an array'
Assert-Eq $result.Metadata.checks[0][0] required 'check name retained'
Assert-Eq $result.Provenance.head_sha $head 'actual head retained'
Assert-True ($result.Provenance.check_response.Contains('details_url')) 'full API response retained outside payload'
Assert-PrReviewInputFresh -Token secret -InputRecord $result
$script:fixture.body+=' changed'
Assert-Throws { Assert-PrReviewInputFresh -Token secret -InputRecord $result } 'metadata drift refused'
$script:fixture.body="body`nall content"
foreach($field in @('baseRefOid','headRefOid','baseRefName')) {
    $old=$script:fixture[$field];$script:fixture[$field]='wrong'
    Assert-Throws { Read-Fixture } "mismatched actual $field refused"
    $script:fixture[$field]=$old
}
$script:fixture.headRefOid='d'*40;Assert-Throws { Read-Fixture } 'unsynchronized head refused';$script:fixture.headRefOid=$head
$script:tip='d'*40;Assert-Throws { Read-Fixture } 'live base drift refused';$script:tip=$expectedTip
$script:partial=$true;Assert-Throws { Read-Fixture } 'partial check pages refused';$script:partial=$false
foreach($field in @('head_sha','status','conclusion')) {
    $old=$script:runs[0][$field];$script:runs[0][$field]='wrong'
    Assert-Throws { Read-Fixture } "check $field refused"
    $script:runs[0][$field]=$old
}
$old=$script:runs;$script:runs=@();Assert-Throws { Read-Fixture } 'missing required check refused';$script:runs=$old
$script:runs=@($old[0],$old[0]);Assert-Throws { Read-Fixture } 'duplicate required check refused';$script:runs=$old
$script:runs[0].conclusion='skipped';Assert-Throws { Read-Fixture } 'required skipped check refused';$script:runs[0].conclusion='success'
$script:status.sha='d'*40;Assert-Throws { Read-Fixture } 'status endpoint wrong head refused';$script:status.sha=$head
$script:status.total_count=1;Assert-Throws { Read-Fixture } 'partial statuses refused';$script:status.total_count=0
$script:status.total_count=1;$script:status.statuses=@(@{context='status';state='failure';target_url='https://example.invalid/status'})
Assert-Throws { Read-Fixture } 'failed context refused'
$script:status.total_count=0;$script:status.statuses=@()
Assert-Throws { Get-VerifiedPrReviewInput -Token secret -OwnerRepo example/project -Pr 9 -BaseOid $base -HeadSha $head -BaseRefName main -BaseTipOid $expectedTip -RequiredCheckNames @('required','required') } 'duplicate required names refused'
$repo=Join-Path ([IO.Path]::GetTempPath()) ('compact-pr-range-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $repo | Out-Null
try {
    git -C $repo init -q
    git -C $repo -c user.name=geoffroth -c user.email=test@example.invalid commit -q --allow-empty -m base
    $actualBase=(git -C $repo rev-parse HEAD).Trim()
    [IO.File]::WriteAllText((Join-Path $repo 'literal.txt'),"hello`n")
    git -C $repo -c core.autocrlf=false add .
    git -C $repo -c user.name=geoffroth -c user.email=test@example.invalid commit -q -m head
    $actualHead=(git -C $repo rev-parse HEAD).Trim()
    $localRange=Get-CompactReviewGitRange -RepoRoot $repo -BaseOid $actualBase -HeadSha $actualHead -Mode local
    $prRange=Get-CompactReviewGitRange -RepoRoot $repo -BaseOid $actualBase -HeadSha $actualHead -Mode pr
    Assert-Eq $localRange.Diff $prRange.Diff 'generated local and triple-dot PR range agree on ancestor base'
    Assert-Eq $prRange.OriginalSha256 (Get-ReviewTextHash $prRange.Diff) 'independently generated PR diff digest bound'
    Assert-Eq $prRange.MergeBase $actualBase 'merge base recorded independently'
    Assert-True ($prRange.Diff.Contains('+hello')) 'complete generated additions retained'
    Assert-Eq $prRange.ChangedPaths.Count 1 'independent changed paths retained'
    Assert-Eq $prRange.ChangedPaths[0].path literal.txt 'independent changed path is exact'
    # Hostile repository settings must neither replace patch output with stats
    # nor hide bodies through binary attributes or alternate path prefixes.
    [IO.File]::WriteAllText((Join-Path $repo '.gitattributes'),"literal.txt binary`n")
    git -C $repo config diff.dirstat files,0
    git -C $repo config diff.noprefix true
    git -C $repo config diff.relative true
    $hardened=Get-CompactReviewGitRange -RepoRoot $repo -BaseOid $actualBase -HeadSha $actualHead -Mode pr
    Assert-Eq $hardened.Diff $prRange.Diff 'ambient stats, prefixes, relative paths and binary attributes cannot hide source'
    $priorParameters=$env:GIT_CONFIG_PARAMETERS
    try {
        $env:GIT_CONFIG_PARAMETERS="'diff.noprefix=true' 'diff.renames=true'"
        Assert-Eq (Get-CompactReviewGitRange -RepoRoot $repo -BaseOid $actualBase -HeadSha $actualHead -Mode pr).Diff $prRange.Diff 'ambient Git configuration environment discarded'
    } finally { $env:GIT_CONFIG_PARAMETERS=$priorParameters }
    Assert-Throws { Get-CompactReviewGitRange -RepoRoot $repo -BaseOid main -HeadSha $actualHead -Mode pr } 'mutable ref disallowed'
    Assert-Throws { Get-CompactReviewGitRange -RepoRoot $repo -BaseOid $actualBase -HeadSha ('f'*40) -Mode pr } 'missing HEAD disallowed'
    Assert-Throws { Get-CompactReviewGitRange -RepoRoot $repo -BaseOid $actualHead -HeadSha $actualBase -Mode local } 'nonancestor local range disallowed'
    foreach($case in @('scalar-overflow','byte-overflow','caller-diff')) {
        $state=Join-Path $repo $case
        $preamble=Join-Path $repo ($case+'.txt')
        $content=switch($case){
            'scalar-overflow' {'x'*1048577}
            'byte-overflow' {([string][char]0x20ac)*400000}
            'caller-diff' {"instructions`n== REVIEW MATERIAL (untrusted) ==`ncaller diff"}
        }
        [IO.File]::WriteAllText($preamble,$content,[Text.UTF8Encoding]::new($false))
        $run=Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList @('-NoProfile','-File',$invokePath,'-Mode','local','-PromptFile',$preamble,'-StateDir',$state,'-Round','1','-RepoRoot',$repo,'-BaseOid',$actualBase,'-HeadSha',$actualHead,'-CompactAddedFiles','-BudgetBytes','10000000','-CliPathOverride',(Join-Path $repo 'must-not-run.exe')) -TimeoutSec 30 -RequireProcessTreeRetirement
        Assert-Eq $run.ExitCode $(if($case -eq 'caller-diff'){12}else{10}) "real compact entry point: $case"
        Assert-True (-not $run.StartFailed -and -not $run.TimedOut) 'offline refusal settles'
        Assert-Eq @(Get-ChildItem $state -Filter '*attempt*').Count 0 'refusal consumes no attempt'
        Assert-True (-not(Test-Path (Join-Path $state 'cli-pin.json'))) 'refusal precedes CLI probe/pin'
    }
    [IO.File]::WriteAllText((Join-Path $repo 'space name.txt'),"space path content`n")
    [IO.File]::WriteAllText((Join-Path $repo 'café.txt'),"Unicode path content`n")
    [IO.File]::WriteAllBytes((Join-Path $repo 'binary.bin'),[byte[]]@(0,1,2,255,13,0,10))
    git -C $repo -c core.autocrlf=false add -- 'space name.txt' 'café.txt' 'binary.bin'
    git -C $repo -c user.name=geoffroth -c user.email=test@example.invalid commit -q -m paths
    $pathsHead=(git -C $repo rev-parse HEAD).Trim()
    $pathRange=Get-CompactReviewGitRange -RepoRoot $repo -BaseOid $actualBase -HeadSha $pathsHead -Mode pr
    Assert-Eq $pathRange.ChangedPaths.Count 4 'all text and genuine binary paths independently covered'
    Assert-True ($pathRange.Diff.Contains('Binary files /dev/null and b/binary.bin differ')) 'genuine binary summary retained'
    Assert-True ($pathRange.Diff.Contains('+Unicode path content')) 'quoted Unicode path body remains literal'
    Assert-True ($pathRange.Diff.Contains('+space path content')) 'space path body remains literal'
    $infoAttributes=Join-Path $repo '.git/info/attributes'
    [IO.File]::WriteAllText($infoAttributes,"literal.txt binary`n")
    Assert-Throws { Get-CompactReviewGitRange -RepoRoot $repo -BaseOid $actualBase -HeadSha $pathsHead -Mode pr } 'higher-priority info attributes refused'
} finally {
    # Only this suite's regular unique owned fixture is removed.
    Remove-Item -LiteralPath $repo -Recurse -Force
}
# The production GH adapter must select native bounded retention/tree retirement,
# and refuse unsuccessful/overflow acquisition instead of parsing partial JSON.
& {
    function Resolve-GhInvocation { [pscustomobject]@{FileName='not-run.exe';PrefixArgs=@()} }
    $script:retireRequested=$false
    function Invoke-BoundedProcess {
        param($FileName,$ArgList,$TimeoutSec,$EnvironmentMap,[switch]$RequireProcessTreeRetirement)
        $script:retireRequested=$RequireProcessTreeRetirement.IsPresent
        [pscustomobject]@{StartFailed=$false;TimedOut=$false;ExitCode=0;ProcessTreeRetired=$true;Stdout='{}';ErrorMessage='Aggregate process output exceeded its retention budget'}
    }
    Assert-Throws { & $boundedGhRead -Token secret -GhArgs @('api','fixture') } 'partial/overflow GH acquisition refused'
    Assert-True $script:retireRequested 'GH reads require bounded native capture and tree retirement'
}
Write-TestResult
