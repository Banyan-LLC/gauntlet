#Requires -Version 7
<# gauntlet-review: run ONE hermetic review round (one ATTEMPT of one logical round).
   Exit codes are defined once in the plan's contracts section; this comment is the short form.
   0 ok
   | 10 budget -- the fixed upstream character limit or preflight byte budget refuses
     BEFORE an attempt runs, OR
     (acceptance-time usage gate, added: real-CLI evidence, see task-7-report.md) the CLI's OWN
     reported usage.input_tokens leaves under 25% context headroom after a round completed.
     Retrying the identical prompt cannot change its own token count, so this is a human flag,
     never a retryable failure.
   | 11 failed attempt (ONE retry allowed) -- process failure, invalid verdict, OR (acceptance-
     time usage gate) an unusable usage report: missing/malformed/duplicated usage, or a
     top-level error event in the run's event stream.
   | 12 environment (CLI/token/harness)
   | 13 pin changed or missing (re-invoke same round with -AcceptNewBinary)
   | 14 round cap OR attempts exhausted, state flagged | 16 carry-over ledger required/invalid #>
param(
    [Parameter(Mandatory)][ValidateSet('doc','pr','local')][string]$Mode,
    [Parameter(Mandatory)][string]$PromptFile,
    [Parameter(Mandatory)][string]$StateDir,
    [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$Round,
    [Parameter(Mandatory)][string]$RepoRoot,
    # Provenance — required so an attempt record identifies exactly WHAT was reviewed.
    [string]$ArtifactPath,          # doc mode (required)
    [string]$ArtifactCommit,        # doc mode (required)
    [int]$PrNumber,                 # pr mode (required)
    [string]$BaseOid,               # pr mode (required)
    [string]$HeadSha,               # pr mode (required)
    # base ref NAME + the base branch's LIVE TIP, captured by the caller BEFORE composing this
    # round (P1 fix, see docs/build-log/task-14-report.md, drill 6): this script is hermetic and
    # must NOT call gh itself, so these are accepted as provenance, not derived here. Threaded
    # into attempt metadata only; the actual drift ENFORCEMENT lives in Publish-CodexReview and
    # Test-HandoffFresh (lib.ps1), which do call gh.
    [string]$BaseRefName,           # pr mode (required)
    [string]$BaseTipOid,            # pr mode (required)
    [string]$CarryOverFile,         # required for round > 1 (validated ledger; see Test-CarryOverLedger)
    [string]$VerifiedReferenceFile, # one exact approved added-spec duplicate
    [switch]$CompactAddedFiles,
    [switch]$CompactIndentation,
    [switch]$CompactReviewMetadata,
    [string]$OwnerRepo,             # compact PR mode: actual repository, author read access
    [string[]]$RequiredCheckNames,  # exact required check names, no omitted checks
    [switch]$AcceptNewBinary,       # re-probe and re-pin after exit 13, same round number
    [ValidateRange(1, 100)][int]$RoundCap = 10,
    [ValidateRange(1024, 10000000)][int]$BudgetBytes = 100000,
    [ValidateRange(1, 86400)][int]$TimeoutSec = 1800,
    [string]$CliPathOverride        # TEST-ONLY; also the only way a wrapper may be pinned
)
# Exactly one retry. Not a parameter at any level: a public override — even one labelled
# "test-only" — is still a public override, and the bounded-loop invariant must not be
# reachable from a caller. Tests exercise the bound by invoking three times.
$MaxAttempts = 2
. "$PSScriptRoot\lib.ps1"

# Kept in this fingerprinted entry point so installing a renderer cannot leave
# its PR acquisition/verification policy outside the certified wrapper snapshot.
function Invoke-ReviewGhRead {
    param([string]$Token,[string[]]$GhArgs)
    Assert-NoEmptyStringElements -FunctionName 'Invoke-ReviewGhRead' -ParameterName 'GhArgs' -Values $GhArgs
    $gh=Resolve-GhInvocation
    # Native containment bounds aggregate stdout+stderr at 4 MiB and kills/reaps
    # the job on overflow or deadline. A partial stream is never accepted as JSON.
    $run=Invoke-BoundedProcess -FileName $gh.FileName -ArgList ($gh.PrefixArgs+$GhArgs) -TimeoutSec 60 -EnvironmentMap @{GH_TOKEN=$Token} -RequireProcessTreeRetirement
    if ($run.StartFailed -or $run.TimedOut -or $run.ExitCode -ne 0 -or -not $run.ProcessTreeRetired -or $run.ErrorMessage) { throw 'Bounded PR acquisition failed or exceeded retention/deadline limits' }
    [pscustomobject]@{ExitCode=0;Stdout=$run.Stdout}
}

function Get-VerifiedPrReviewInput {
    param([string]$Token,[string]$OwnerRepo,[int]$Pr,[string]$BaseOid,[string]$HeadSha,
          [string]$BaseRefName,[string]$BaseTipOid,[string[]]$RequiredCheckNames)
    if ($OwnerRepo -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Pr -le 0 -or
        $BaseOid -cnotmatch '^[0-9a-f]{40}$' -or $HeadSha -cnotmatch '^[0-9a-f]{40}$' -or
        $BaseTipOid -cnotmatch '^[0-9a-f]{40}$' -or $BaseRefName -cne 'main' -or
        -not $RequiredCheckNames -or @($RequiredCheckNames | Where-Object {[string]::IsNullOrWhiteSpace($_)}).Count -or
        @($RequiredCheckNames | Sort-Object -Unique).Count -ne $RequiredCheckNames.Count) { throw 'Invalid compact PR provenance or required check names' }
    # Direct exact-head comparison establishes synchronization without an
    # unbounded poll/read path. The caller may use Wait-PrHeadSynced before this.
    $response=Invoke-ReviewGhRead -Token $Token -GhArgs @('pr','view',"$Pr",'--repo',$OwnerRepo,'--json','number,url,title,body,baseRefOid,headRefOid,baseRefName')
    if ($response.ExitCode -ne 0) { throw 'PR metadata unavailable' }
    $prObject=ConvertFrom-Json -InputObject $response.Stdout -ErrorAction Stop
    if ($prObject.number -ne $Pr -or $prObject.baseRefOid -cne $BaseOid -or $prObject.headRefOid -cne $HeadSha -or
        $prObject.baseRefName -cne $BaseRefName -or $prObject.title -isnot [string] -or $prObject.body -isnot [string]) { throw 'PR metadata changed or malformed' }
    $tipResponse=Invoke-ReviewGhRead -Token $Token -GhArgs @('api',"repos/$OwnerRepo/git/ref/heads/$BaseRefName")
    $tip=ConvertFrom-Json -InputObject $tipResponse.Stdout -ErrorAction Stop
    if ($tip.object.sha -cne $BaseTipOid) { throw 'Live PR base tip changed or unavailable' }
    $checkResponse=Invoke-ReviewGhRead -Token $Token -GhArgs @('api','--paginate','--slurp',"repos/$OwnerRepo/commits/$HeadSha/check-runs")
    $statusResponse=Invoke-ReviewGhRead -Token $Token -GhArgs @('api','--paginate','--slurp',"repos/$OwnerRepo/commits/$HeadSha/status")
    if ($checkResponse.ExitCode -ne 0 -or $statusResponse.ExitCode -ne 0) { throw 'Complete exact-head CI evidence unavailable' }
    $pages=@(ConvertFrom-Json -InputObject $checkResponse.Stdout -ErrorAction Stop)
    $statusPages=@(ConvertFrom-Json -InputObject $statusResponse.Stdout -ErrorAction Stop)
    if (-not $pages.Count -or -not $statusPages.Count) { throw 'Empty CI response' }
    $runs=@($pages | ForEach-Object { $_.check_runs } | ForEach-Object { $_ })
    if ($pages[0].total_count -ne $runs.Count) { throw 'Partial or inconsistent check-run response' }
    foreach ($run in $runs) {
        if ($run.head_sha -cne $HeadSha -or $run.status -cne 'completed' -or
            $run.conclusion -cnotin @('success','neutral','skipped') -or [string]::IsNullOrWhiteSpace($run.name)) { throw 'CI check missing exact successful head evidence' }
    }
    foreach ($name in $RequiredCheckNames) {
        $required=@($runs | Where-Object name -CEQ $name)
        if ($required.Count -ne 1 -or $required[0].conclusion -cne 'success') { throw "Required check is missing, duplicated, or unsuccessful: $name" }
    }
    $statuses=@($statusPages | ForEach-Object { $_.statuses } | ForEach-Object { $_ })
    if ($statusPages[0].total_count -ne $statuses.Count) { throw 'Partial commit status response' }
    foreach ($page in $statusPages) {
        if ($page.sha -cne $HeadSha -or ($page.total_count -gt 0 -and $page.state -cne 'success')) { throw 'Commit status does not confirm reviewed head' }
    }
    foreach ($status in $statuses) { if ($status.state -cne 'success') { throw 'Unsuccessful commit status' } }
    # Shared exact head plus column names avoids duplicating long property names;
    # every actual check/status record remains in the untrusted summary. Full API
    # responses also remain in immutable attempt provenance, never in trusted context.
    $checkRows=@($runs | ForEach-Object { ,@($_.name,$_.status,$_.conclusion,$_.details_url) })
    $statusRows=@($statuses | ForEach-Object { ,@($_.context,$_.state,$_.target_url) })
    $metadata=[ordered]@{repository=$OwnerRepo;number=$Pr;url=$prObject.url;title=$prObject.title;body=$prObject.body
        base_oid=$BaseOid;head_sha=$HeadSha;base_ref_name=$BaseRefName;base_tip_oid=$BaseTipOid
        check_columns=@('name','status','conclusion','details_url');checks=$checkRows
        status_columns=@('context','state','target_url');statuses=$statusRows}
    $text="== PR METADATA (untrusted) ==`n"+(ConvertTo-Json -InputObject $metadata -Depth 8 -Compress)+"`n"
    [pscustomobject]@{Text=$text;Metadata=$metadata;Provenance=[ordered]@{repository=$OwnerRepo;pr_number=$Pr;base_oid=$BaseOid;head_sha=$HeadSha;base_ref_name=$BaseRefName;base_tip_oid=$BaseTipOid
        metadata_sha256=(Get-ReviewTextHash $text);required_check_names=@($RequiredCheckNames);synchronized=$true
        captured_at=(Get-Date -AsUTC -Format o);pr_response=$response.Stdout;base_tip_response=$tipResponse.Stdout;check_response=$checkResponse.Stdout;status_response=$statusResponse.Stdout}}
}

function Assert-PrReviewInputFresh {
    param([string]$Token,[object]$InputRecord)
    $p=$InputRecord.Provenance
    $fresh=Get-VerifiedPrReviewInput -Token $Token -OwnerRepo $p.repository -Pr $p.pr_number -BaseOid $p.base_oid -HeadSha $p.head_sha -BaseRefName $p.base_ref_name -BaseTipOid $p.base_tip_oid -RequiredCheckNames $p.required_check_names
    if ($fresh.Text -cne $InputRecord.Text) { throw 'PR metadata or CI changed while composing the review' }
}

function Get-ReviewGitQuotedPath {
    param([string]$Path)
    $bytes=[Text.Encoding]::UTF8.GetBytes($Path)
    if (@($bytes | Where-Object {$_ -lt 32 -or $_ -ge 127 -or $_ -eq 34 -or $_ -eq 92}).Count -eq 0) { return $Path }
    $out=[Text.StringBuilder]::new();[void]$out.Append('"')
    foreach($byte in $bytes) {
        $escape=switch([int]$byte){7{'\a'}8{'\b'}9{'\t'}10{'\n'}11{'\v'}12{'\f'}13{'\r'}34{'\"'}92{'\\'}default{$null}}
        if($escape){[void]$out.Append($escape)}
        elseif($byte -lt 32 -or $byte -ge 127){[void]$out.Append('\').Append([Convert]::ToString($byte,8).PadLeft(3,'0'))}
        else{[void]$out.Append([char]$byte)}
    }
    [void]$out.Append('"');$out.ToString()
}

function Get-CompactReviewGitRange {
    param([string]$RepoRoot,[string]$BaseOid,[string]$HeadSha,[ValidateSet('local','pr')][string]$Mode)
    if ($BaseOid -cnotmatch '^[0-9a-f]{40}$' -or $HeadSha -cnotmatch '^[0-9a-f]{40}$') { throw 'Compact reviews require full immutable commit IDs' }
    $git=@(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
    $nullFile=if($IsWindows){'NUL'}else{'/dev/null'}
    $gx=@('--no-optional-locks','--literal-pathspecs','--attr-source=4b825dc642cb6eb9a060e54bf8d69288fbee4904','-C',$RepoRoot,'-c','core.useReplaceRefs=false','-c','core.quotePath=true',
        '-c',('core.attributesFile='+$nullFile),'-c','diff.noprefix=false','-c','diff.mnemonicPrefix=false','-c','diff.algorithm=myers')
    # Drop ambient Git override variables and global/system configuration.
    # Use the immutable empty attribute tree, not worktree/index attributes.
    # Genuine binary summaries stay literal, as in the original review format.
    $gitEnvironment=@{GIT_NO_LAZY_FETCH='1';GIT_CONFIG_NOSYSTEM='1';GIT_CONFIG_SYSTEM=$nullFile;GIT_CONFIG_GLOBAL=$nullFile;GIT_CONFIG_COUNT='0';GIT_ATTR_NOSYSTEM='1'}
    foreach($name in @('SystemRoot','WINDIR','PATH','TEMP','TMP')) {if(Test-Path "Env:$name"){$gitEnvironment[$name]=(Get-Item "Env:$name").Value}}
    $runGit={param([string[]]$GitArguments)
        $result=Invoke-BoundedProcess -FileName $git -ArgList ($gx+$GitArguments) -TimeoutSec 60 -ClearEnvironment -EnvironmentMap $gitEnvironment -RequireProcessTreeRetirement
        if($result.StartFailed -or $result.TimedOut -or $result.ExitCode -ne 0 -or -not $result.ProcessTreeRetired -or $result.ErrorMessage){throw "Cannot generate complete immutable Git review range ($($GitArguments[0]), exit $($result.ExitCode)): $($result.ErrorMessage) $($result.Stderr)"}
        $result.Stdout
    }
    foreach($oid in @($BaseOid,$HeadSha)) {
        if ((& $runGit -GitArguments @('rev-parse','--verify',"$oid^{commit}")).Trim() -cne $oid) { throw 'Review commit identity mismatch' }
    }
    $infoAttributes=(& $runGit -GitArguments @('rev-parse','--path-format=absolute','--git-path','info/attributes')).Trim()
    # info/attributes outranks --attr-source. Refuse its presence rather than
    # silently accept an unverified patch policy; never alter the user's file.
    try {
        $null=Get-Item -LiteralPath $infoAttributes -Force -ErrorAction Stop
        throw 'Repository info/attributes must be absent for verified review generation'
    } catch [System.Management.Automation.ItemNotFoundException] { }
    $mergeBase=(& $runGit -GitArguments @('merge-base',$BaseOid,$HeadSha)).Trim()
    if($Mode -ceq 'local' -and $mergeBase -cne $BaseOid){throw 'Local review base is not an ancestor'}
    $range=if($Mode -ceq 'pr'){@("$BaseOid...$HeadSha")}else{@($BaseOid,$HeadSha)}
    $common=@('diff','--no-ext-diff','--no-textconv','--no-color','--ignore-submodules=none','--no-renames','--no-relative','--diff-filter=ACDMRTUXB')
    $diff=& $runGit -GitArguments ($common+@('--patch','--src-prefix=a/','--dst-prefix=b/','--line-prefix=','--unified=3','--inter-hunk-context=0')+$range+@('--'))
    $raw=& $runGit -GitArguments ($common+@('--raw','-z','--no-abbrev')+$range+@('--'))
    $rawParts=$raw.Split([char]0);$paths=[Collections.Generic.List[object]]::new();$headers=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for($i=0;$i -lt $rawParts.Length-1;$i+=2) {
        if($rawParts[$i] -cnotmatch '^:([0-7]{6}) ([0-7]{6}) ([0-9a-f]{40}) ([0-9a-f]{40}) ([ACDMTUXB])$' -or $i+1 -ge $rawParts.Length){throw 'Malformed independent changed-path coverage'}
        $entry=[ordered]@{path=$rawParts[$i+1];old_mode=$Matches[1];new_mode=$Matches[2];old_blob=$Matches[3];new_blob=$Matches[4];status=$Matches[5]}
        $expected='diff --git '+(Get-ReviewGitQuotedPath ('a/'+$entry.path))+' '+(Get-ReviewGitQuotedPath ('b/'+$entry.path))
        if(-not$headers.Add($expected)){throw 'Duplicate independent changed path'}
        $paths.Add($entry)
    }
    $actualHeaders=@([regex]::Matches($diff,'(?m)^diff --git [^\r\n]*')|ForEach-Object Value)
    if($actualHeaders.Count -ne $headers.Count){throw 'Generated patch omits changed paths'}
    foreach($header in $actualHeaders){if(-not$headers.Remove($header)){throw 'Generated patch path coverage mismatch'}}
    [pscustomobject]@{Diff=$diff;MergeBase=$mergeBase;OriginalSha256=(Get-ReviewTextHash $diff);ChangedPaths=$paths.ToArray();ChangedPathsSha256=(Get-ReviewTextHash $raw)}
}

$boundInputLeases = $null
try {
$boundInputLeases = New-BoundReviewLease -SkillRoot (Split-Path $PSScriptRoot -Parent)
# Single schema now (see task-7-report.md): the codex-facing generation schema and the local
# structural-validation schema used to be two files differing only in a top-level if/then that
# the real API rejects outright. They are identical once if/then is removed, so one file now
# serves both --output-schema (below) and Test-Verdict's structural check.
$schemaPath = "$PSScriptRoot\..\schemas\verdict.schema.json"
New-Item -ItemType Directory -Force $StateDir | Out-Null

if ($Mode -eq 'doc' -and -not ($ArtifactPath -and $ArtifactCommit)) { Write-Error "doc mode requires -ArtifactPath and -ArtifactCommit"; exit 12 }
if ($Mode -eq 'pr' -and -not ($PrNumber -and $BaseOid -and $HeadSha -and $BaseRefName -and $BaseTipOid)) { Write-Error "pr mode requires -PrNumber, -BaseOid, -HeadSha, -BaseRefName, -BaseTipOid"; exit 12 }
# local mode reviews a LOCAL branch diff (baseOid..headSha) with no PR and no publish. Only the
# cheap parameter-PRESENCE check runs here; all git resolution/ancestry/diff work is deferred to
# AFTER the bounds/replay checks below (see the local-mode provenance block), so a capped or
# replayed invocation returns its cap/replay result without ever touching the repository.
if ($Mode -eq 'local' -and -not ($BaseOid -and $HeadSha)) { Write-Error "local mode requires -BaseOid and -HeadSha"; exit 12 }

# --- BOUNDS FIRST. Both caps are checked before any probe, pin, harness, or process work, so a
#     refused invocation launches nothing and leaves pin/harness state untouched.
if ($Round -gt $RoundCap) {
    Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="round cap $RoundCap reached at round $Round" }
    Write-Error "HUMAN FLAG: round cap $RoundCap reached."
    exit 14
}
# A completed round is FINISHED. Re-invoking it would consume an attempt and, worse, rewrite
# the canonical verdict that every later round's recommendation ids are derived from - silently
# invalidating the carry-over ledger of every subsequent round. State is deliberately left
# UNTOUCHED here (unlike the genuine bound-exhaustion cases below): the round already completed
# successfully, so state.json already correctly reflects that outcome, and stamping it 'flagged'
# would overwrite a true 'approved'/'in_review' result with a misleading one over a replay that
# is the CALLER's mistake, not a new failure of the review itself.
$canonicalVerdict = Join-Path $StateDir "round-$Round-verdict.json"
if (Test-Path $canonicalVerdict) {
    Write-Error "Round $Round already completed successfully; its canonical verdict is immutable. Advance to round $($Round + 1)."
    exit 14
}
$priorAttempts = @(Get-ChildItem $StateDir -Filter "round-$Round-attempt-*-meta.json" -ErrorAction SilentlyContinue).Count
$attempt = $priorAttempts + 1
if ($attempt -gt $MaxAttempts) {
    Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="round $Round exhausted $MaxAttempts attempts" }
    Write-Error "HUMAN FLAG: round $Round already used $priorAttempts of $MaxAttempts allowed attempts."
    exit 14
}

# --- Carry-over ledger. Fresh sessions carry no memory, so for round > 1 continuity is a
#     VALIDATED artifact, not prose: every prior recommendation exactly once, verbatim, with
#     a status and a reason where the status is not 'addressed'. Validated before any process
#     runs, and the script — not the caller — renders it into the payload.
$carryText = ''
$carrySha = $null
# @(...) around the call, NOT just around $out inside the function -- self-review fix (see
# task-7-report.md). Get-PriorRecommendations already does `return @($out)` internally, but
# PowerShell's pipeline still unwraps a 0-item result to $null and a 1-item result to a bare
# scalar when the caller captures it with plain assignment; only wrapping the CALL SITE in
# @(...) reliably forces array semantics for 0/1/many. Confirmed empirically: with the bare
# form, `(Get-PriorRecommendations ...).Count` throws PropertyNotFoundException under
# Set-StrictMode -Version Latest (inherited from dot-sourcing lib.ps1) on every round with zero
# prior recommendations -- i.e. every round 1, and most later rounds in this test file, since
# the fake shim's default verdict carries none. That is the common case, not an edge case, so
# the brief's own given line failed nearly every scenario in this suite.
$priorCount = @(Get-PriorRecommendations -StateDir $StateDir -UpToRound $Round).Count
if ($priorCount -gt 0) {
    if (-not $CarryOverFile) {
        Write-Error "Round $Round has $priorCount prior recommendation(s); -CarryOverFile is required so none can be silently dropped."
        exit 16
    }
    $ledger = Test-CarryOverLedger -StateDir $StateDir -Round $Round -LedgerPath $CarryOverFile
    if (-not $ledger.Valid) {
        Write-RoundState -StateDir $StateDir -Patch @{ status='failed_attempt'; failure_reason="carry-over: $($ledger.Reason)" }
        Write-Error "Carry-over ledger rejected: $($ledger.Reason)"
        exit 16
    }
    $carryText = ConvertTo-CarryOverText -Entries $ledger.Entries
    # Hash the RENDERED text — that is literally what the reviewer was shown. The source file is
    # caller-owned and may be edited or deleted afterwards, so a hash of it proves nothing later.
    $carrySha = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [Text.Encoding]::UTF8.GetBytes($carryText)) | ForEach-Object { $_.ToString('x2') })
}

# --- local-mode provenance. Runs AFTER the bounds/replay checks AND after carry-over validation,
#     so a capped/replayed round, or a later round with a missing/invalid ledger, returns its own
#     result (14/16) without touching the repo. Best-effort HERMETIC diff: replace objects OFF,
#     lazy fetch OFF, no external diff / textconv / color, explicit `--`; refs resolved to CANONICAL
#     OIDs; base MUST be an ancestor of head. Scope: local mode is a NON-authoritative pre-check the
#     operator runs on their OWN repo to cut PR rounds -- pr mode on the PR is the authoritative
#     gate -- so it does not additionally defend the generated diff against the operator's own
#     ambient repo config (submodule/attribute knobs); an imperfect local diff costs at most one
#     extra pr round, never a security gap.
$canonBase = $null; $canonHead = $null; $localDiff = $null; $localDiffSha = $null
if ($Mode -eq 'local' -and -not $CompactAddedFiles) {
    $env:GIT_NO_LAZY_FETCH = '1'
    $gx = @('-C', $RepoRoot, '-c', 'core.useReplaceRefs=false')
    $canonBase = (git @gx rev-parse --verify --quiet "$BaseOid^{commit}")
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($canonBase)) { Write-Error "local mode: BaseOid '$BaseOid' does not resolve to a commit in $RepoRoot"; exit 12 }
    $canonHead = (git @gx rev-parse --verify --quiet "$HeadSha^{commit}")
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($canonHead)) { Write-Error "local mode: HeadSha '$HeadSha' does not resolve to a commit in $RepoRoot"; exit 12 }
    $canonBase = $canonBase.Trim(); $canonHead = $canonHead.Trim()
    git @gx merge-base --is-ancestor $canonBase $canonHead
    if ($LASTEXITCODE -ne 0) { Write-Error "local mode: BaseOid ($canonBase) is not an ancestor of HeadSha ($canonHead) -- disconnected or diverged history"; exit 12 }
    $localDiff = (git @gx diff --no-ext-diff --no-textconv --no-color $canonBase $canonHead -- | Out-String)
    if ($LASTEXITCODE -ne 0) { Write-Error "local mode: 'git diff $canonBase $canonHead' failed (exit $LASTEXITCODE)"; exit 12 }
    $localDiffSha = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [Text.Encoding]::UTF8.GetBytes($localDiff)) | ForEach-Object { $_.ToString('x2') })
}

$promptBody = Get-Content -Raw -Encoding utf8 $PromptFile
$referenceCoverage = $null
$compactCoverage=$null; $metadataCoverage=$null; $prInput=$null; $prToken=$null; $compactRange=$null
if ($CompactIndentation -and -not $CompactAddedFiles) { Write-Error 'Indentation encoding requires verified compact composition'; exit 12 }
if ($CompactReviewMetadata -and -not $CompactAddedFiles) { Write-Error 'Historical metadata encoding requires verified compact composition'; exit 12 }
if ($CompactAddedFiles -and $Mode -notin @('local','pr')) { Write-Error 'Compact representation requires local or PR mode'; exit 12 }
if ($VerifiedReferenceFile -and $Mode -ne 'local' -and -not ($Mode -eq 'pr' -and $CompactAddedFiles)) { Write-Error 'PR verified references require compact verified composition'; exit 12 }
if ($CompactAddedFiles) {
    try {
        $compactRange=Get-CompactReviewGitRange -RepoRoot $RepoRoot -BaseOid $BaseOid -HeadSha $HeadSha -Mode $Mode
        $canonBase=$BaseOid; $canonHead=$HeadSha; $localDiff=$compactRange.Diff; $localDiffSha=$compactRange.OriginalSha256
        if ($Mode -eq 'pr') {
            $gh=Resolve-GhInvocation
            $auth=Invoke-BoundedProcess -FileName $gh.FileName -ArgList ($gh.PrefixArgs+@('auth','token','-u','geoffroth')) -TimeoutSec 30 -RequireProcessTreeRetirement
            if ($auth.StartFailed -or $auth.TimedOut -or $auth.ExitCode -ne 0 -or -not $auth.ProcessTreeRetired -or $auth.ErrorMessage -or [string]::IsNullOrWhiteSpace($auth.Stdout)) { throw 'Author read token unavailable' }
            $prToken=$auth.Stdout.Trim()
            $prInput=Get-VerifiedPrReviewInput -Token $prToken -OwnerRepo $OwnerRepo -Pr $PrNumber -BaseOid $BaseOid -HeadSha $HeadSha -BaseRefName $BaseRefName -BaseTipOid $BaseTipOid -RequiredCheckNames $RequiredCheckNames
        }
    } catch { Write-Error "Verified review provenance refused: $($_.Exception.Message)"; exit 12 }
}
if ($Mode -eq 'local' -or $CompactAddedFiles) {
    # The PromptFile is the PREAMBLE (header + trusted context) ONLY and must be ENFORCED as such:
    # reject a caller-supplied review-material section (normalized: leading whitespace and case are
    # ignored) so ALL reviewed bytes provably come from the generated, digest-bound diff.
    if ($promptBody -match '(?im)^\s*==\s*REVIEW MATERIAL') { Write-Error "local mode: PromptFile must be a preamble only and must NOT contain a '== REVIEW MATERIAL ==' section (the diff is generated from the verified range)"; exit 12 }
    # Append the review material generated hermetically above from the verified range, so the
    # reviewed bytes are provably that range and its digest (recorded in meta) binds provenance.
    $reviewDiff = $localDiff
    if ($VerifiedReferenceFile) {
        try {
            $representation = ConvertTo-VerifiedReviewDiff -RepoRoot $RepoRoot -BaseOid $canonBase -HeadSha $canonHead -Preamble $promptBody -Diff $localDiff -ReferenceFile $VerifiedReferenceFile
            $reviewDiff = $representation.Diff
            $referenceCoverage = $representation.Manifest
        } catch { Write-Error "Verified reference refused: $($_.Exception.Message)"; exit 12 }
    }
    $preambleText = if ($VerifiedReferenceFile -or $CompactAddedFiles) { $promptBody } else { $promptBody.TrimEnd() }
    $protocol=''
    if ($CompactAddedFiles) {
        try {
            $compact=ConvertTo-CompactReviewDiff -RepoRoot $RepoRoot -BaseOid $canonBase -HeadSha $canonHead -Diff $reviewDiff -CompactIndentation:$CompactIndentation
            if ((Restore-CompactReviewDiff -Diff $compact.Diff -Manifest $compact.Manifest) -cne $reviewDiff.Replace("`r`n","`n")) { throw 'Representation reconstruction mismatch' }
            $reviewDiff=$compact.Diff; $compactCoverage=$compact.Manifest
            $protocol=(Get-CompactReviewProtocol)+"`n"
            if($CompactIndentation){$protocol+=(Get-CompactIndentationProtocol)+"`n"}
            if($CompactReviewMetadata){
                $metadata=ConvertTo-ReviewMetadataDiff -RepoRoot $RepoRoot -BaseOid $canonBase -HeadSha $canonHead -Diff $reviewDiff -CompactManifest $compactCoverage
                if((Restore-ReviewMetadataDiff -Diff $metadata.Diff -Manifest $metadata.Manifest) -cne $reviewDiff){throw 'Metadata reconstruction mismatch'}
                $reviewDiff=$metadata.Diff;$metadataCoverage=$metadata.Manifest
                $protocol+=(Get-ReviewMetadataProtocol)+"`n"
            }
        } catch { Write-Error "Compact representation refused: $($_.Exception.Message)"; exit 12 }
    }
    $prText=if($prInput){$prInput.Text}else{''}
    $promptBody = $preambleText + "`n`n" + $protocol + "== REVIEW MATERIAL (untrusted) ==`n" + $prText + $reviewDiff + "`n"
}
$originalCarrySha = $carrySha
if ($VerifiedReferenceFile -or $CompactAddedFiles) {
    $promptBody = $promptBody.Replace("`r`n", "`n")
    $carryText = $carryText.Replace("`r`n", "`n")
    $carrySha = Get-ReviewTextHash $carryText
}
$prompt = $carryText + $promptBody
# Check the fully rendered payload, including carry-over and generated review
# material, before any CLI probe, harness, attempt metadata or dispatch. This
# upstream limit is not configurable and raising BudgetBytes cannot bypass it.
$characters = Test-PromptCharacterLimit -PromptText $prompt
if (-not $characters.Ok) {
    Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="prompt character limit: $($characters.Characters) > $($characters.Limit) characters" }
    Write-Error "Prompt contains $($characters.Characters) Unicode characters; the fixed upstream limit is $($characters.Limit). No attempt ran. Raising BudgetBytes cannot change this limit. Never truncate review material."
    exit 10
}
# This byte preflight (100,000-byte default -BudgetBytes) is an OPERATIONAL INPUT BOUND ONLY -- a
# cheap, local, BEFORE-the-round estimate from the prompt's own byte count. It is NOT the formal
# guarantee (added: real-CLI evidence, see task-7-report.md) and does not promise an oversized
# request is never attempted: bytes only bound tokens from above, and CLI-side overhead is not
# visible here. The formal guarantee is enforced AFTER the round runs, at the acceptance-time usage
# gate near the canonical verdict write below: a completed review is accepted and publishable only
# when the real CLI itself reported at least 25% context headroom (see Get-RunUsage in lib.ps1).
# A preflight overflow is RETRYABLE by raising -BudgetBytes -- the caller may do so AUTONOMOUSLY up
# to the 500,000-byte ceiling; only a prompt genuinely over 500,000 bytes is a human flag. The
# ceiling is in bytes and implies no token count: gpt-6.1-sol's tokenizer is undocumented, so the
# usage gate below decides on the real reported count. (The acceptance-time usage-gate exit 10
# below is NOT retryable.)
$effectiveByteBudget=if($CompactAddedFiles){[math]::Min($BudgetBytes,1048576)}else{$BudgetBytes}
$budget = Test-EmbedBudget -PromptText $prompt -BudgetBytes $effectiveByteBudget
if (-not $budget.Ok) {
    Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="embed budget: $($budget.Bytes) > $BudgetBytes bytes" }
    Write-Error "prompt is $($budget.Bytes) bytes over the $BudgetBytes-byte preflight budget; No round ran. Raise -BudgetBytes and retry (autonomously up to 500000); a prompt over 500000 bytes is a human flag. Never truncate."
    exit 10
}

# --- Binary pin (see the pin transition table). Every round is a fresh session, so the only
#     cross-round continuity is the pinned binary and the harness.
$pinFile = Join-Path $StateDir 'cli-pin.json'
$pin = if (Test-Path $pinFile) { Get-Content -Raw $pinFile | ConvertFrom-Json } else { $null }
$repin = $AcceptNewBinary -or ($Round -eq 1 -and -not $pin)

if (-not $repin) {
    if (-not $pin) { Write-Error "No cli-pin.json for round $Round. Re-invoke the SAME round with -AcceptNewBinary."; exit 13 }
    if (-not (Test-BinaryUnchanged -PinnedCli $pin)) { Write-Error "Pinned CLI changed (path/hash/version). Re-invoke the SAME round with -AcceptNewBinary; history and round number are kept."; exit 13 }
    # Run the PINNED binary. Re-selecting candidates here could silently swap the reviewer
    # mid-loop whenever discovery order changes (a new hashed dir sorts newer).
    $cli = Test-CodexCandidate -Path $pin.Path -AllowWrapper:([bool]$CliPathOverride)
    if (-not $cli) { Write-Error "Pinned CLI at $($pin.Path) no longer passes the compatibility probe. Re-invoke with -AcceptNewBinary."; exit 13 }
} else {
    try {
        $candidates = if ($CliPathOverride) { @($CliPathOverride) } else { Get-CodexCandidates }
        $cli = Select-CodexCli -Candidates $candidates -AllowWrapper:([bool]$CliPathOverride)
    } catch {
        Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="CLI probe: $($_.Exception.Message)" }
        Write-Error $_.Exception.Message; exit 12
    }
    @{ Path=$cli.Path; Sha256=$cli.Sha256; Version=$cli.Version } | ConvertTo-Json | Set-Content $pinFile -Encoding utf8
}

$disable = Get-DisableSet -FeatureNames $cli.FeatureNames
if (Get-BoundReviewProfile) {
    $boundInputLeases.Add([IO.FileStream]::new($cli.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    if ((Get-FileHash -LiteralPath $cli.Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $cli.Sha256) { Write-Error 'Selected CLI changed before its execution lease'; exit 13 }
}

# --- Premise manifest gate, AFTER selection so it binds the binary that will actually run.
#     Validating the path the manifest names would let a manifest for A authorize a review
#     executed by B. There is no bypass switch: calibration is a separate entry point
#     (calibrate-premises.ps1), not a flag on the production path.
$profileHash = Get-InvocationProfileHash -DisableSet $disable
# -AllowProvenanceOnlyGateSources (P1 fix, see docs/build-log/task-14-report.md, FINDING 1b): this
# script runs from an INSTALLED skill at runtime, which never has a tests/ sibling (install.ps1
# ships only gauntlet-review/ and gauntlet-dev/) -- so it always identifies itself as a
# possible installed tree. This is safe to pass unconditionally, including for a dev-repo run:
# Test-PremiseManifest verifies gate sources STRICTLY whenever they are actually present, and only
# falls back to provenance-only when they are wholly absent (see its own docstring).
$manifest = Test-PremiseManifest -SkillRoot (Split-Path $PSScriptRoot -Parent) -ActualCli $cli `
    -InvocationProfileHash $profileHash -AllowProvenanceOnlyGateSources
if (-not $manifest.Valid) {
    Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="premise manifest: $($manifest.Reason)" }
    # Two distinct self-serve causes as of the live-evidence gate (see task-14-report.md): stack
    # drift is fixed by calibrate-premises.ps1 alone, but missing/stale live evidence is NOT --
    # calibration only proves the stack ACCEPTED, never LIVE-VERIFIED, and always drops the whole
    # live_evidence object, so both live gates must be rerun too. live_evidence now carries TWO
    # independently fingerprinted sub-records (schema_gate, security_battery -- FINDING 2, see
    # task-14-report.md); $manifest.Reason above already names the SPECIFIC gate to rerun when
    # only one of the two is missing or stale.
    Write-Error "HUMAN FLAG: $($manifest.Reason). Stack-identity drift (CLI/schema/AGENTS.md/invocation profile): run calibrate-premises.ps1. Missing or stale live evidence: rerun the specific live gate named above (tests/live/live-schema-gate.ps1 and/or tests/live/live-security.ps1)."
    exit 12
}

$prev = if (Test-Path (Join-Path $StateDir 'state.json')) { Read-RoundState -StateDir $StateDir } else { $null }

# Only the new representation opts into this stricter capacity contract. Existing
# review histories retain their prior policy. Probe before harness/attempt writes.
$activeBoundProfile = Get-BoundReviewProfile
$referenceCapacity = $null
if ($activeBoundProfile) { $referenceCapacity = $activeBoundProfile.capacity }
if ($VerifiedReferenceFile -and -not $activeBoundProfile) {
    $catalogRun = Invoke-BoundedProcess -FileName $cli.Path -ArgList @('debug','models') -TimeoutSec 60 -RequireProcessTreeRetirement
    if ($catalogRun.StartFailed -or $catalogRun.TimedOut -or $catalogRun.ExitCode -ne 0 -or -not $catalogRun.ProcessTreeRetired) { Write-Error 'Pinned CLI context catalog unavailable; no attempt ran'; exit 12 }
    # The bundled probe must not read ambient config or a custom catalog. No
    # credentials are copied into this unique empty home. Keep unexpected output
    # files for diagnosis rather than recursively deleting an unverified tree.
    $catalogHome = Join-Path ([IO.Path]::GetTempPath()) ('gauntlet-catalog-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($catalogHome)
    try {
        $bundledRun = Invoke-BoundedProcess -FileName $cli.Path -ArgList @('debug','models','--bundled') -EnvironmentMap @{ CODEX_HOME=$catalogHome } -WorkingDirectory $catalogHome -TimeoutSec 60 -RequireProcessTreeRetirement
    } finally {
        try { [IO.Directory]::Delete($catalogHome,$false) } catch { Write-Warning "Catalog probe retained its nonempty directory: $catalogHome" }
    }
    if ($bundledRun.StartFailed -or $bundledRun.TimedOut -or $bundledRun.ExitCode -ne 0 -or -not $bundledRun.ProcessTreeRetired) { Write-Error 'Pinned CLI bundled context catalog unavailable; no attempt ran'; exit 12 }
    try {
        $referenceCapacity = Get-ReviewCapacityFromCatalog -CatalogJson $catalogRun.Stdout
        $bundledCapacity = Get-ReviewCapacityFromCatalog -CatalogJson $bundledRun.Stdout
        if ($referenceCapacity.context_window -ne $bundledCapacity.context_window -or $referenceCapacity.effective_percent -ne $bundledCapacity.effective_percent) {
            Write-Error 'Refreshed and bundled CLI context limits disagree; actual sealed capacity is unverified. No attempt ran.'
            exit 12
        }
        $referenceCapacity | Add-Member -NotePropertyName bundled_catalog_sha256 -NotePropertyValue $bundledCapacity.catalog_sha256
    }
    catch { Write-Error "CLI capacity refused: $($_.Exception.Message)"; exit 12 }
}

# --- Harness. Created once per loop; thereafter ONLY the recorded path is reused, always
#     verified clean. A vanished harness is an environment fault: silently provisioning another
#     would hide that the loop's working root changed under it, and the harness is the one
#     directory whose emptiness the hermeticity argument depends on.
try {
    $recorded = if ($prev -and $prev.PSObject.Properties['harness_dir']) { $prev.harness_dir } else { $null }
    if ($recorded) {
        # Reuse ONLY the recorded path, always re-validated. A vanished harness is an
        # environment fault, not something to paper over by silently provisioning another.
        if (-not (Test-Path $recorded)) { throw "recorded harness '$recorded' is missing" }
        $harness = Assert-HarnessSafe -Dir $recorded -RepoRoot $RepoRoot
    } else {
        $harness = New-HarnessDir -RepoRoot $RepoRoot
    }
} catch {
    Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="harness: $($_.Exception.Message)" }
    Write-Error "HUMAN FLAG: $($_.Exception.Message)"; exit 12
}
# Record the harness IMMEDIATELY, not only after a successful attempt. Self-review fix (see
# task-7-report.md): the brief's own script recorded harness_dir ONLY in the final success
# patch at the bottom of this file. If attempt 1 of a round fails (invalid verdict / process
# failure / timeout), that patch is never reached, so state.json never gains a 'harness_dir'
# property. Two consequences, both real: (a) attempt 2's reuse check
# ($prev.PSObject.Properties['harness_dir']) would then find nothing to reuse and silently
# mint a SECOND harness for the same round, defeating "created once per loop, thereafter
# reused"; (b) lib.ps1 runs under Set-StrictMode -Version Latest, which this script inherits
# from dot-sourcing it — a caller (or this suite's own ATTEMPT CAP test) that reads
# `(Read-RoundState -StateDir $StateDir).harness_dir` after two failed attempts and no
# success would hit PropertyNotFoundException, an uncaught crash, not a clean read. Recording
# right after the harness is created/re-validated — before Codex ever runs — closes both gaps
# while still being idempotent with the success patch below (same $harness value either way).
Write-RoundState -StateDir $StateDir -Patch @{ harness_dir=$harness }

$stem = "round-$Round-attempt-$attempt"
$rawPath = Join-Path $StateDir "$stem-verdict.raw.json"

# Last acquisition check before immutable attempt allocation or model dispatch.
# Publication still performs its independent post-review freshness checks.
if ($prInput) {
    try { Assert-PrReviewInputFresh -Token $prToken -InputRecord $prInput }
    catch { Write-Error "PR input changed before dispatch: $($_.Exception.Message)"; exit 12 }
}

$codexArgs = New-CodexArgs -HarnessDir $harness -SchemaPath $schemaPath -VerdictPath $rawPath -DisableSet $disable
$audit = Get-InvocationAudit -CodexArgs $codexArgs -HarnessDir $harness `
    -SchemaPath $schemaPath -VerdictPath $rawPath -ExpectedDisable $disable

$shaOf = { param($t) -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($t)) | ForEach-Object { $_.ToString('x2') }) }
$meta = @{
    round=$Round; attempt=$attempt; mode=$Mode
    # Three separate hashes: the whole payload alone would make the carry-over unauditable,
    # since a changed prompt body and a dropped finding are indistinguishable in one digest.
    prompt_sha256=(& $shaOf $prompt); prompt_body_sha256=(& $shaOf $promptBody)
    carryover_rendered_sha256=$carrySha; carryover_source_file=$CarryOverFile; carryover_entries=$priorCount
    prompt_bytes=$budget.Bytes; audit=$audit; harness_dir=$harness
    cli_path=$cli.Path; cli_sha256=$cli.Sha256; cli_version=$cli.Version
    timestamp=(Get-Date -AsUTC -Format o)
}
if ($Mode -eq 'doc') { $meta.artifact_path = $ArtifactPath; $meta.artifact_commit = $ArtifactCommit }
elseif ($Mode -eq 'local') { $meta.base_oid = $canonBase; $meta.head_sha = $canonHead; $meta.reviewed_diff_sha256 = $localDiffSha }
else {
    $meta.pr_number = $PrNumber; $meta.base_oid = $BaseOid; $meta.head_sha = $HeadSha
    $meta.base_ref_name = $BaseRefName; $meta.base_tip_oid = $BaseTipOid
}
if ($CompactAddedFiles) {
    $meta.compact_review_coverage=$compactCoverage
    $meta.reviewed_diff_sha256=$localDiffSha
    $meta.reviewed_merge_base=$compactRange.MergeBase
    $meta.reviewed_changed_paths=$compactRange.ChangedPaths
    $meta.reviewed_changed_paths_sha256=$compactRange.ChangedPathsSha256
    $meta.compact_protocol_sha256=(Get-ReviewTextHash (Get-CompactReviewProtocol))
    $meta.prompt_characters=$characters.Characters
    if($prInput){$meta.pr_input_provenance=$prInput.Provenance}
}
if ($VerifiedReferenceFile) {
    $meta.verified_reference_coverage = $referenceCoverage
    $meta.context_capacity = $referenceCapacity
    $meta.reference_manifest_sha256 = $referenceCoverage.reference_manifest_sha256
    $meta.carryover_original_rendered_sha256 = $originalCarrySha
}
if($CompactReviewMetadata){
    $meta.review_metadata_coverage=$metadataCoverage
    $meta.review_metadata_protocol_sha256=(Get-ReviewTextHash (Get-ReviewMetadataProtocol))
}
if($CompactIndentation){
    $meta.compact_indentation_protocol_sha256=(Get-ReviewTextHash (Get-CompactIndentationProtocol))
}
if ($activeBoundProfile) {
    $meta.context_capacity = $referenceCapacity
    $meta.bound_capacity_profile_sha256 = $activeBoundProfile.profile_sha256
    $meta.capacity_runtime_proof_sha256 = (Get-FileHash -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'capacity-runtime-proof.json') -Algorithm SHA256).Hash.ToLowerInvariant()
}
Write-AttemptMeta -StateDir $StateDir -Round $Round -Attempt $attempt -Meta $meta
# Persist what the reviewer actually received, under our own control: the normalized ledger and
# the exact rendered carry-over. The caller's ledger file can change or vanish; these cannot.
if ($carryText) {
    [System.IO.File]::WriteAllText((Join-Path $StateDir "$stem-carryover.json"),
        ($ledger.Entries | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    # WriteAllText, NOT Set-Content: $carryText already ends in a newline and Set-Content would
    # append another, so the persisted file would not hash to carryover_rendered_sha256 or match
    # the bytes actually sent to Codex - defeating the point of persisting it.
    [System.IO.File]::WriteAllText((Join-Path $StateDir "$stem-carryover.txt"),
        $carryText, [Text.UTF8Encoding]::new($false))
}

$run = Invoke-CodexProcess -CliPath $cli.Path -CodexArgs $codexArgs -PromptText $prompt -HarnessDir $harness -TimeoutSec $TimeoutSec
try { Write-AttemptProcessResult -StateDir $StateDir -Round $Round -Attempt $attempt -Meta $meta -Run $run -PromptText $prompt }
catch {
    Write-RoundState -StateDir $StateDir -Patch @{ status='failed_attempt'; failure_reason="round $Round attempt ${attempt}: process diagnostic receipt could not be persisted" }
    Write-Error "Process diagnostic receipt could not be persisted: $($_.Exception.Message)"
    exit 11
}
$run.StdoutLines | Set-Content -Path (Join-Path $StateDir "$stem-events.jsonl") -Encoding utf8
if ($run.StartFailed -or $run.TimedOut -or $run.ExitCode -ne 0 -or -not (Test-Path $rawPath)) {
    $reason = if ($run.StartFailed) { "codex failed to start: $($run.ErrorMessage)" }
              elseif ($run.TimedOut) { "codex timed out" }
              else { "codex exit $($run.ExitCode) or no verdict file" }
    Write-RoundState -StateDir $StateDir -Patch @{ status='failed_attempt'; failure_reason="round $Round attempt ${attempt}: $reason" }
    Write-Error "$reason. Retry this round once (recorded as the next attempt); a further attempt returns 14."
    exit 11
}

# --- Acceptance-time usage gate (added: real-CLI evidence, see task-7-report.md), BEFORE the
#     canonical verdict is ever written. A completed review is accepted and publishable only
#     when the run's OWN accounting proves it: no top-level error event, exactly one
#     turn.completed event, and a genuine positive-integer usage.input_tokens (Get-RunUsage,
#     lib.ps1). The attempt meta written above is immutable and predates this process running;
#     the usage RESULT is a separate, create-only artifact, never folded back into it.
$usage = Get-RunUsage -EventLines $run.StdoutLines
if ($activeBoundProfile -and (Get-BoundReviewProfile).profile_sha256 -cne $activeBoundProfile.profile_sha256) { Write-Error 'Bound capacity profile changed during execution'; exit 12 }
if (-not $usage.Ok) {
    Write-RoundState -StateDir $StateDir -Patch @{ status='failed_attempt'; failure_reason="round $Round attempt ${attempt}: usage gate: $($usage.Reason)" }
    Write-Error "Usage gate failed: $($usage.Reason). Retry this round once, then human flag."
    exit 11
}
try {
    Write-NewFileExclusive -Path (Join-Path $StateDir "$stem-usage.json") -Text (
        [pscustomobject]@{ round=$Round; attempt=$attempt; raw_event=$usage.RawLine; input_tokens=$usage.InputTokens } |
            ConvertTo-Json -Depth 4)
} catch [System.IO.IOException] {
    Write-Error "refusing to overwrite the usage artifact for round $Round attempt ${attempt} (another invocation won the race)"
    exit 14
}
# 0.75 x gpt-6.1-sol's documented 1,050,000-token context window, less its documented 128,000-token
# max-output reserve (OpenAI model page, re-checked 2026-10-10 when the pin moved from gpt-6-sol and
# 2026-09-24 when it moved from gpt-5.6-sol; all three document the same two limits), is 659,500: input_tokens above that leaves under 25%
# headroom. Retrying the SAME prompt cannot change its own token count, so this is a human flag
# (10) -- unlike every other usage-gate rejection above, which is a retryable failed attempt (11).
$maximumInputTokens = if ($referenceCapacity) { $referenceCapacity.maximum_input_tokens } else { 659500 }
if ($usage.InputTokens -gt $maximumInputTokens) {
    Write-RoundState -StateDir $StateDir -Patch @{ status='flagged'; failure_reason="round $Round attempt ${attempt}: usage over budget: input_tokens=$($usage.InputTokens) (max $maximumInputTokens for >=25% headroom)" }
    Write-Error "HUMAN FLAG: input_tokens $($usage.InputTokens) leaves under 25% context headroom (limit $maximumInputTokens). Retrying the same prompt cannot help."
    exit 10
}

$verdict = Test-Verdict -Json (Get-Content -Raw $rawPath) -SchemaPath $schemaPath
if (-not $verdict.Valid) {
    # ${attempt}: (braced), NOT $attempt: -- self-review fix (see task-7-report.md). PowerShell's
    # double-quoted-string parser reads a bare "$attempt:" as an attempt at a scope-qualified
    # variable reference (the same syntax as $env:, $script:, etc.), which is a hard ParserError
    # here ("':' was not followed by a valid variable name character") -- confirmed empirically:
    # this is a literal copy of the brief's own given line, and it fails the ENTIRE script's
    # parse, so every test in this file that invokes invoke-codex.ps1 failed before this fix. The
    # sibling failure branch a few lines above already uses the correct ${attempt}: form; this one
    # didn't match it.
    Write-RoundState -StateDir $StateDir -Patch @{ status='failed_attempt'; failure_reason="round $Round attempt ${attempt}: invalid verdict — $($verdict.Reason)" }
    Write-Error "Invalid verdict: $($verdict.Reason). Retry this round once, then human flag."
    exit 11
}
# Canonical round result — written ONLY by a successful attempt, and CREATE-ONLY. Recommendation
# ids are derived from this file, so overwriting it would retroactively change every later
# round's ledger. The guard at the top of the script normally prevents reaching this twice;
# this is the belt-and-braces half of that invariant.
try { Write-NewFileExclusive -Path $canonicalVerdict -Text $verdict.NormalizedJson }
catch [System.IO.IOException] {
    Write-Error "refusing to overwrite the canonical verdict for round $Round (another invocation won the race)"
    exit 14
}
Write-RoundState -StateDir $StateDir -Patch @{
    round=$Round; attempt=$attempt
    status=$(if ($verdict.Normalized.verdict -eq 'approve') { 'approved' } else { 'in_review' })
    verdict=$verdict.Normalized.verdict; downgraded=[bool]$verdict.Downgraded
    harness_dir=$harness; failure_reason=$null
}
Write-Output $verdict.NormalizedJson
exit 0
} finally {
    if ($boundInputLeases) { foreach ($lease in $boundInputLeases) { $lease.Dispose() } }
}
