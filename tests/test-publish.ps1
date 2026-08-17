. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\..\codex-review\scripts\lib.ps1"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "codexpub-$([guid]::NewGuid())"
New-Item -ItemType Directory -Force $tmp | Out-Null

# Hostile content must flow byte-safely into the JSON payload (never a command line).
$hostileVerdict = @{verdict='request_changes'; summary="quotes `" back`` tick `$(boom) newline`nend";
    recommendations=@(@{severity='blocking'; location='a"b'; issue="i`n`"x`""; suggestion='s`$(y)'})} | ConvertTo-Json -Depth 5 -Compress
$hv = $hostileVerdict | ConvertFrom-Json
$marker = Get-ReviewMarker -Pr 7 -Base 'b0e1' -Head 'h3ad' -BaseRefName 'main' -BaseTipOid 'tip0000ab' -Round 2 -NormalizedJson $hostileVerdict
Assert-True ($marker -match '^<!-- codex-review:pr=7:base=b0e1:base_ref=main:base_tip=tip0000ab:head=h3ad:round=2:digest=[0-9a-f]{12} -->$') "marker format"
$body = ConvertTo-ReviewBody -NormalizedVerdict $hv -Marker $marker
Assert-True ($body.Contains($marker)) "marker embedded"
$hugeObj = @{verdict='approve';summary=('s'*800);recommendations=@(1..20 | ForEach-Object {
    @{severity='nit';location=('l'*150);issue=('i'*500);suggestion=('g'*500)}})} | ConvertTo-Json -Depth 5 | ConvertFrom-Json
Assert-Throws { ConvertTo-ReviewBody -NormalizedVerdict $hugeObj -Marker $marker } "oversized body throws"

# Scripted fake gh.
$script:GhCalls = [System.Collections.Generic.List[object]]::new()
function Invoke-Gh { param([string]$Token,[string[]]$GhArgs,[string]$InputFile)
    $script:GhCalls.Add(@{Args=$GhArgs; Input=$(if($InputFile){Get-Content -Raw $InputFile}else{$null}); Token=$Token})
    $handler = $script:GhScript[0]
    # Self-review fix: the brief's own `$script:GhScript[1..($script:GhScript.Count)]` is an
    # off-by-one — valid indices for an N-element array are 0..N-1, so `1..N` always requests one
    # index past the end, and PowerShell's array-slice-by-range indexer throws "Index was outside
    # the bounds of the array" for that (confirmed empirically) rather than clamping. Because that
    # throw happens on the ASSIGNMENT's right-hand side, `$script:GhScript` is left unchanged, so
    # the queue never advances: every subsequent call keeps replaying handler 0 instead of moving
    # through the script. `Select-Object -Skip 1` (wrapped in `@()` so 0/1/many all stay arrays)
    # drops exactly the first element for every queue length, including the N=1 case that a plain
    # `1..($Count-1)` still gets wrong (`1..0` counts DOWN to produce the two-element index list
    # (1,0), and index 1 is again out of bounds on a 1-element array).
    $script:GhScript = @($script:GhScript | Select-Object -Skip 1)
    & $handler $GhArgs
}
function New-OidsResponse([string]$b,[string]$h,[string]$refName='main') { { param($a) [pscustomobject]@{ExitCode=0; Stdout=(@{baseRefOid=$b; headRefOid=$h; baseRefName=$refName} | ConvertTo-Json)} }.GetNewClosure() }
# The base branch's LIVE tip -- a SEPARATE, INDEPENDENT endpoint from `pr view`'s (static)
# baseRefOid above (P1 fix, see docs/build-log/task-14-report.md, drill 6). Modeling these as two
# genuinely independent fixtures is the whole point: a fake that moved both together would not
# reproduce the defect this fix closes (baseRefOid never moves; this endpoint does).
function New-RefResponse([string]$sha) { { param($a) [pscustomobject]@{ExitCode=0; Stdout=(@{ref='refs/heads/main'; object=@{sha=$sha}} | ConvertTo-Json -Depth 4)} }.GetNewClosure() }
function New-JsonResponse($obj) { { param($a) [pscustomobject]@{ExitCode=0; Stdout=($obj | ConvertTo-Json -Depth 6)} }.GetNewClosure() }
function New-FailResponse() { { param($a) [pscustomobject]@{ExitCode=1; Stdout='{"message":"Forbidden"}'} } }
# `gh api user --jq .login` returns plain text (jq's raw scalar output), never JSON — a distinct
# helper from New-JsonResponse so the fixture matches what production actually parses.
function New-TextResponse([string]$s) { { param($a) [pscustomobject]@{ExitCode=0; Stdout=$s} }.GetNewClosure() }
# Every Publish-CodexReview call now makes the identity-gate lookup FIRST; this is that
# response, prepended to every existing scripted queue below so the rest of each sequence still
# lines up. Its own dedicated tests (actor mismatch, wrong-author dismissal, non-default
# -Reviewer forwarding) live further down.
function New-ActorOk() { New-TextResponse 'BanyanLLC' }

# Shared base provenance used by most fixtures below: -BaseRefName/-BaseTipOid are new MANDATORY
# parameters on Publish-CodexReview (P1 fix, see docs/build-log/task-14-report.md, drill 6) --
# every call site needs them regardless of what that specific test is exercising.
$mainRef = 'main'; $mainTip = 'tip0000ab'

$vJson = '{"verdict":"approve","summary":"LGTM","recommendations":[{"severity":"nit","location":"x","issue":"i","suggestion":"s"}]}'
$vObj = $vJson | ConvertFrom-Json
$marker2 = Get-ReviewMarker -Pr 7 -Base 'b0e1' -Head 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 2 -NormalizedJson $vJson
$review = @{ id=555; state='APPROVED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body="x $marker2" }

# Happy path (hostile chars already covered above through the body builder). Pre- and
# post-publication base-tip checks each add one call (Get-BaseBranchTip) alongside the existing
# Get-PrOids call they sit next to. FINDING 2 (P1, see docs/build-log/task-14-report.md): the
# marker scan now comes right after the identity gate, BEFORE the pre-publication drift check
# (oids/tip) -- reordered from this suite's original sequence, to match the reordering in
# Publish-CodexReview itself.
$script:GhScript = @(
    (New-ActorOk),
    (New-JsonResponse @(@(@{id=1;state='APPROVED';user=@{login='someone'};body='no'}), @())),
    (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip),
    (New-JsonResponse $review), (New-JsonResponse $review),
    (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip)
)
$code = Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 2 -NormalizedJson $vJson -StateDir $tmp
Assert-Eq $code 0 "happy path 0"
$post = $script:GhCalls | Where-Object { $_.Args -contains 'POST' }
Assert-True ($post.Input -match '"commit_id"\s*:\s*"h3ad"') "commit_id pinned"
Assert-True ($post.Input -match '"event"\s*:\s*"APPROVE"') "event APPROVE"
# `@(...).Count -gt 0`, NOT `(...) -ne $null`: on a MULTI-element result, `-ne $null` is
# PowerShell's element-wise FILTERING operator, not a comparison -- it hands back every
# non-null element, i.e. an Object[]. Assert-True's [bool]$Condition then fails argument
# transformation ("Cannot convert value 'System.Object[]' to type 'System.Boolean'"), and that
# error is NON-TERMINATING at script level: the run continues and the assertion contributes to
# NEITHER $script:Passes NOR $script:Failures -- a silent no-op that still reports "N passed,
# 0 failed". The base-tip check below is exactly how that bites: drill 6 (see
# docs/build-log/task-14-report.md) added a SECOND Get-BaseBranchTip call (pre- AND
# post-publication), both hitting this identical endpoint, so the filter started returning two
# elements and the assertion stopped verifying anything. The slurp check above is the same shape
# and survives only by luck -- one call matches today, so Where-Object yields a scalar and
# `-ne $null` is a genuine [bool]. Wrapping both in @() and counting makes 0/1/many behave
# identically and keeps a future second matching call from silently disarming the assertion.
Assert-True (@($script:GhCalls | Where-Object { ($_.Args -join ' ') -match '--paginate --slurp' }).Count -gt 0) "slurp pagination"
Assert-True (@($script:GhCalls | Where-Object { ($_.Args -join ' ') -match "git/ref/heads/$mainRef" }).Count -gt 0) "live base-branch-tip endpoint called"
$pub = Get-Content -Raw "$tmp\publication.json" | ConvertFrom-Json
Assert-Eq $pub.github_review_id 555 "publication persisted"
Assert-True ($pub.digest -match '^[0-9a-f]{12}$') "standalone digest recorded"
Assert-Eq $pub.base_ref_name $mainRef "publication records base ref name"
Assert-Eq $pub.base_tip_oid $mainTip "publication records base tip oid"

# Downgrade regression: approve+important normalized upstream => event must be REQUEST_CHANGES.
$dgJson = '{"verdict":"request_changes","summary":"x","recommendations":[{"severity":"important","location":"l","issue":"i","suggestion":"s"}]}'
$dgObj = $dgJson | ConvertFrom-Json
$dgMarker = Get-ReviewMarker -Pr 7 -Base 'b0e1' -Head 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 3 -NormalizedJson $dgJson
$dgReview = @{ id=600; state='CHANGES_REQUESTED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body="x $dgMarker" }
$script:GhCalls.Clear()
$script:GhScript = @(
    (New-ActorOk), (New-JsonResponse @(@())), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip),
    (New-JsonResponse $dgReview), (New-JsonResponse $dgReview), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip)
)
$code = Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $dgObj -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 3 -NormalizedJson $dgJson -StateDir $tmp
Assert-Eq $code 0 "downgraded verdict publishes"
Assert-True (($script:GhCalls | Where-Object { $_.Args -contains 'POST' }).Input -match '"event"\s*:\s*"REQUEST_CHANGES"') "DOWNGRADED VERDICT PUBLISHES AS REQUEST_CHANGES"

# Pre-publication drift (head) -> 2, no POST. FINDING 2 (P1): drift is now checked only AFTER the
# marker scan finds no match -- so an empty scan response is now part of this fixture (it was not
# before the reorder, since drift used to run unconditionally first).
$script:GhCalls.Clear(); $script:GhScript = @((New-ActorOk), (New-JsonResponse @(@())), (New-OidsResponse 'b0e1' 'NEWHEAD' $mainRef))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 2 -NormalizedJson $vJson -StateDir $tmp) 2 "pre-drift (head) 2"
Assert-True (-not ($script:GhCalls | Where-Object { $_.Args -contains 'POST' })) "no mutation"

# Pre-publication drift (base ref RENAMED) -> 2, no POST. Same FINDING 2 fixture update as above.
$script:GhCalls.Clear(); $script:GhScript = @((New-ActorOk), (New-JsonResponse @(@())), (New-OidsResponse 'b0e1' 'h3ad' 'renamed-branch'))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 2 -NormalizedJson $vJson -StateDir $tmp) 2 "pre-drift (base ref renamed) 2"
Assert-True (-not ($script:GhCalls | Where-Object { $_.Args -contains 'POST' })) "no mutation"

# Pre-publication drift (base branch TIP moved, baseRefOid/name unchanged) -> 2, no POST. Same
# defect class as drill 6, caught one stage earlier than handoff (see the Handoff section below
# for the dedicated discrimination proof of this exact scenario). Same FINDING 2 fixture update.
$script:GhCalls.Clear(); $script:GhScript = @((New-ActorOk), (New-JsonResponse @(@())), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse 'MOVEDPRETIP'))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 2 -NormalizedJson $vJson -StateDir $tmp) 2 "pre-drift (base tip moved) 2"
Assert-True (-not ($script:GhCalls | Where-Object { $_.Args -contains 'POST' })) "no mutation"

# Recovery beyond page one; DISMISSED marker does not suppress; post-POST BASE/HEAD/BASE-TIP drift; wrong state; 403.
# FINDING 2 (P1, see docs/build-log/task-14-report.md): this is the DIRECT proof of the
# reordering's whole point. An exact marker match now short-circuits straight to read-back +
# verification -- the pre-publication drift check (oids/tip) is never even consulted when an
# existing marker is found, so this fixture no longer supplies those two responses at all (it did
# before the reorder, when drift always ran first regardless of what the scan would find).
$page1 = @(1..30 | ForEach-Object { @{id=$_; state='COMMENTED'; user=@{login='BanyanLLC'}; body="unrelated $_"} })
$page2 = @(@{ id=777; state='APPROVED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body="recovered $marker2" })
$script:GhCalls.Clear()
$script:GhScript = @((New-ActorOk), (New-JsonResponse @($page1, $page2)),
    (New-JsonResponse $page2[0]), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 2 -NormalizedJson $vJson -StateDir $tmp) 0 "page-2 recovery verified"
Assert-True (-not ($script:GhCalls | Where-Object { $_.Args -contains 'POST' })) "no duplicate POST"
Assert-Eq $script:GhCalls.Count 5 "recovery via an exact marker match makes exactly 5 calls (identity, scan, get-back, post-verify oids+tip) -- the pre-publication drift check (2 more calls) is never consulted (FINDING 2); a regression here would exhaust this fixture's queue and fail some other way, but this pins the exact count directly"

# A dismissed review carrying the marker does NOT count as "existing" (filtered by state), so this
# scenario still goes through the "not found" -> drift-check -> POST path -- scan moves to right
# after the identity gate (FINDING 2), but the pre-publication oids/tip check still runs.
$script:GhCalls.Clear()
$dismissed = @(@(@{ id=778; state='DISMISSED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body="old $marker2" }))
$script:GhScript = @((New-ActorOk), (New-JsonResponse $dismissed), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip),
    (New-JsonResponse $review), (New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 2 -NormalizedJson $vJson -StateDir $tmp) 0 "dismissed marker ignored"
Assert-True (@($script:GhCalls | Where-Object { $_.Args -contains 'POST' }).Count -gt 0) "fresh POST after dismissed marker"

# post-POST drift now has THREE independent ways to trip -- base oid, head oid, and (P1 fix) the
# base branch's live TIP moving even while baseRefOid/name hold steady. Each case supplies its
# own oids-response AND its own ref-tip-response so exactly one property drifts at a time.
foreach ($driftCase in @(
    @{oids=(New-OidsResponse 'MOVEDBASE' 'h3ad' $mainRef); tip=(New-RefResponse $mainTip); name='base'},
    @{oids=(New-OidsResponse 'b0e1' 'MOVEDHEAD' $mainRef); tip=(New-RefResponse $mainTip); name='head'},
    @{oids=(New-OidsResponse 'b0e1' 'h3ad' $mainRef); tip=(New-RefResponse 'MOVEDPOSTTIP'); name='base_tip'}
)) {
    $script:GhCalls.Clear()
    $script:GhScript = @((New-ActorOk), (New-JsonResponse @(@())), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip),
        (New-JsonResponse $review), (New-JsonResponse $review), $driftCase.oids, $driftCase.tip,
        (New-JsonResponse (@{ id=555; state='DISMISSED' })), (New-JsonResponse (@{ id=555; state='DISMISSED' })))
    Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 2 -NormalizedJson $vJson -StateDir $tmp) 3 "post-POST $($driftCase.name) drift -> dismissed -> 3"
    $dis = $script:GhCalls | Where-Object { ($_.Args -join ' ') -match 'dismissals' }
    Assert-True ($dis.Input -match '"event"\s*:\s*"DISMISS"' -and $dis.Input -match '"message"') "$($driftCase.name): dismissal body complete"
}

$commented = @{ id=556; state='COMMENTED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body="x $marker2" }
$script:GhScript = @((New-ActorOk), (New-JsonResponse @(@())), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip),
    (New-JsonResponse $commented), (New-JsonResponse $commented), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip),
    (New-JsonResponse (@{ id=556; state='DISMISSED' })), (New-JsonResponse (@{ id=556; state='DISMISSED' })))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 2 -NormalizedJson $vJson -StateDir $tmp) 3 "COMMENTED state dismissed -> 3"

$script:GhScript = @((New-ActorOk), (New-JsonResponse @(@())), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip),
    (New-JsonResponse $review), (New-JsonResponse $review), (New-OidsResponse 'MOVEDBASE' 'h3ad' $mainRef), (New-RefResponse $mainTip), (New-FailResponse))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 2 -NormalizedJson $vJson -StateDir $tmp) 4 "dismissal denied -> 4"

# IDENTITY: a token that authenticates as someone other than the expected reviewer must be
# refused BEFORE any mutation — no drift check, scan, or POST may happen once the identity
# check has failed. Exit 12 reuses the existing "no usable token for '$Reviewer'" contract: a
# token that authenticates as the wrong person is exactly as unusable as no token at all.
$script:GhCalls.Clear()
$script:GhScript = @((New-TextResponse 'someone-else'))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 2 -NormalizedJson $vJson -StateDir $tmp) 12 "actor mismatch refused before mutation"
Assert-Eq $script:GhCalls.Count 1 "actor mismatch stops after the identity check alone (no oids/scan/POST)"

# IDENTITY: a review read back with the right state/commit but the WRONG user.login must fail
# post-publication verification the same as any other verification failure, and be dismissed —
# this is the defence-in-depth half, independent of the pre-mutation token check above.
$wrongAuthor = @{ id=557; state='APPROVED'; commit_id='h3ad'; user=@{login='someone-else'}; body="x $marker2" }
$script:GhCalls.Clear()
$script:GhScript = @((New-ActorOk), (New-JsonResponse @(@())), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip),
    (New-JsonResponse $wrongAuthor), (New-JsonResponse $wrongAuthor), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip),
    (New-JsonResponse (@{ id=557; state='DISMISSED' })), (New-JsonResponse (@{ id=557; state='DISMISSED' })))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 2 -NormalizedJson $vJson -StateDir $tmp) 3 "review authored by someone else fails post-verification -> dismissed"

# HOSTILE CONTENT THROUGH THE REAL PUBLISHER: it must survive as data, never as syntax.
$script:GhCalls.Clear()
$hostileMarker = Get-ReviewMarker -Pr 7 -Base 'b0e1' -Head 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 9 -NormalizedJson $hostileVerdict
$hostileReview = @{ id=999; state='CHANGES_REQUESTED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body="x $hostileMarker" }
$script:GhScript = @(
    (New-ActorOk), (New-JsonResponse @(@())), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip),
    (New-JsonResponse $hostileReview), (New-JsonResponse $hostileReview), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip)
)
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $hv -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 9 -NormalizedJson $hostileVerdict -StateDir $tmp) 0 "hostile verdict publishes"
$hPost = $script:GhCalls | Where-Object { $_.Args -contains 'POST' }
$sent = $hPost.Input | ConvertFrom-Json
Assert-True ($sent.body.Contains($hv.summary)) "hostile summary round-trips byte-exact through the JSON payload"
Assert-True ($sent.body.Contains($hv.recommendations[0].suggestion)) "hostile suggestion round-trips byte-exact"
Assert-Eq $sent.commit_id 'h3ad' "commit still pinned with hostile content"
foreach ($call in $script:GhCalls) {
    Assert-True (($call.Args -join ' ') -notmatch '\$\(|boom|`') "hostile text never appears in argv"
}

# Handoff freshness: every negative case must be caught. base_ref_name/base_tip_oid (P1 fix, see
# docs/build-log/task-14-report.md, drill 6): publication.json now records what the base was
# believed to be AT PUBLICATION TIME, and Test-HandoffFresh independently re-verifies both the
# base ref's NAME and its LIVE TIP against a SEPARATE endpoint from the PR's (static) baseRefOid.
@{ base_oid='b0e1'; reviewed_head_sha='h3ad'; base_ref_name=$mainRef; base_tip_oid=$mainTip
   github_review_id=555; digest='abcdefabcdef'; marker=$marker2 } |
    ConvertTo-Json | Set-Content "$tmp\publication.json" -Encoding utf8
$greenChecks = { param($a) [pscustomobject]@{ExitCode=0; Stdout=(@(@{check_runs=@(@{name='ci';status='completed';conclusion='success'})}) | ConvertTo-Json -Depth 6)} }
$noStatuses  = { param($a) [pscustomobject]@{ExitCode=0; Stdout=(@{total_count=0; state='pending'} | ConvertTo-Json)} }
$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip), $greenChecks, $noStatuses)
Assert-True (Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json").Fresh "(b) fresh handoff passes -- nothing moved"

# (a) DISCRIMINATION CASE: the base branch TIP moved but the PR's baseRefOid (modeled here via
# New-OidsResponse's STATIC field, held constant at 'main'/unchanged) did NOT -- exactly drill 6's
# live finding. Moving ONLY the tip (a genuinely SEPARATE fixture/endpoint, New-RefResponse) is
# the point: a fake that moved both together would not reproduce the defect this fix closes.
$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse 'MOVEDTIP'))
$hfBase = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json"
Assert-True ((-not $hfBase.Fresh) -and $hfBase.Reason -eq 'base advanced') "(a) TIP-ONLY drift (baseRefOid unchanged) caught as 'base advanced'"

# (e) head advanced is still its own, distinct, unaffected reason.
$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'b0e1' 'MOVEDHEAD' $mainRef))
$hfHead = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json"
Assert-True ((-not $hfHead.Fresh) -and $hfHead.Reason -eq 'head advanced') "(e) HEAD advanced still reported as 'head advanced'"

# (c) the PR's base ref NAME changed (retargeted to a different base branch) -- fails closed with
# its own distinct reason, checked BEFORE the live-tip call (comparing tips across two different
# branches would be meaningless).
$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad' 'renamed-branch'))
$hfRenamed = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json"
Assert-True ((-not $hfRenamed.Fresh) -and $hfRenamed.Reason -match 'renamed') "(c) base ref NAME changed fails closed"

# (d) the base branch ref cannot be read at all (deleted branch, API error, ...) -- unreadable is
# never evidence of "unchanged"; fails closed with a distinct reason, never silently passes.
$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-FailResponse))
$hfUnread = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json"
Assert-True ((-not $hfUnread.Fresh) -and $hfUnread.Reason -match 'unreadable') "(d) base branch ref unreadable fails closed"

$edited = @{ id=555; state='APPROVED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body='body was edited, marker removed' }
$script:GhScript = @((New-JsonResponse $edited))
$hfE = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json"
Assert-True ((-not $hfE.Fresh) -and $hfE.Reason -match 'marker') "EDITED body (marker gone) caught"

$foreign = @{ id=555; state='APPROVED'; commit_id='h3ad'; user=@{login='someone-else'}; body="x $marker2" }
$script:GhScript = @((New-JsonResponse $foreign))
$hfF = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json"
Assert-True ((-not $hfF.Fresh) -and $hfF.Reason -match 'reviewer') "WRONG REVIEWER caught"

$redChecks = { param($a) [pscustomobject]@{ExitCode=0; Stdout=(@(@{check_runs=@(@{name='ci';status='completed';conclusion='failure'})}) | ConvertTo-Json -Depth 6)} }
$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip), $redChecks)
$hfR = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json"
Assert-True ((-not $hfR.Fresh) -and $hfR.Reason -match 'failure') "RED CI on the reviewed sha caught"

$pendingChecks = { param($a) [pscustomobject]@{ExitCode=0; Stdout=(@(@{check_runs=@(@{name='ci';status='in_progress';conclusion=$null})}) | ConvertTo-Json -Depth 6)} }
$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip), $pendingChecks)
Assert-True (-not (Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json").Fresh) "PENDING CI caught"

# FAIL CLOSED: an unreadable CI endpoint must never read as green.
$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip), (New-FailResponse))
$hfC = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json"
Assert-True ((-not $hfC.Fresh) -and $hfC.Reason -match 'check-runs') "check-runs read failure fails closed"
$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad' $mainRef), (New-RefResponse $mainTip), $greenChecks, (New-FailResponse))
$hfS = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json"
Assert-True ((-not $hfS.Fresh) -and $hfS.Reason -match 'status') "commit-status read failure fails closed"

# A THROWN transport error must still produce {Fresh=false, Reason}, not escape the gate.
$throwTimeout = { param($a) throw "TRANSIENT: gh timed out after 120s" }
$script:GhScript = @($throwTimeout)
$hfT = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json"
Assert-True ((-not $hfT.Fresh) -and $hfT.Reason -match 'transport') "gh TIMEOUT is caught and reported as not-fresh"
$throwStart = { param($a) throw "TRANSIENT: gh could not start: file not found" }
$script:GhScript = @($throwStart)
Assert-True (-not (Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json").Fresh) "gh START FAILURE is caught"
$malformed = { param($a) [pscustomobject]@{ExitCode=0; Stdout='not json at all'} }
$script:GhScript = @($malformed)
Assert-True (-not (Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json").Fresh) "MALFORMED response is caught"

# =====================================================================================
# FINDING 2 (P1, see docs/build-log/task-14-report.md): (a) the marker scan now runs before the
# drift check (already exercised throughout the Publish-CodexReview tests above, reordered); this
# section covers the two things not yet exercised: the crash-then-base-moves recovery scenario,
# and Revoke-SupersededReview's three independent safety preconditions plus Test-HandoffFresh's
# read-only contract.
# =====================================================================================

# --- Crash recovery under drift: POST succeeds, but the process fails BEFORE publication.json is
# persisted (simulated directly: this call models a RETRY of that crashed attempt), and the base
# branch has ALREADY moved by the time the retry runs. The retry must FIND the marker (it really
# was already published) and route it through post-verification -- which independently re-checks
# LIVE base state and correctly finds it has drifted -- so it must DISMISS (return 3), never the
# stale exit-2 "drift" outcome (which, pre-fix, would only ever have been reachable by never
# discovering the already-published review in the first place).
$script:GhCalls.Clear()
$crashMarker = Get-ReviewMarker -Pr 7 -Base 'b0e1' -Head 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 11 -NormalizedJson $vJson
$crashReview = @{ id=888; state='APPROVED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body="x $crashMarker" }
$script:GhScript = @(
    (New-ActorOk),
    (New-JsonResponse @(@($crashReview))),                 # scan finds it -- POST already happened on GitHub
    (New-JsonResponse $crashReview),                        # get-back
    (New-OidsResponse 'b0e1' 'h3ad' $mainRef),               # post-verify oids: base/head still match...
    (New-RefResponse 'MOVEDTIPSINCECRASH'),                  # ...but the base branch's LIVE TIP has since moved
    (New-JsonResponse (@{ id=888; state='DISMISSED' })),     # dismiss PUT
    (New-JsonResponse (@{ id=888; state='DISMISSED' }))      # dismiss re-GET
)
$retryCode = Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 11 -NormalizedJson $vJson -StateDir $tmp
Assert-Eq $retryCode 3 "crash-then-base-moves: retry finds the already-published marker and DISMISSES on since-drifted base tip, never a stale exit-2"
Assert-True (-not ($script:GhCalls | Where-Object { $_.Args -contains 'POST' })) "crash-then-base-moves: no duplicate POST -- the marker recovery path never re-publishes"

# --- Revoke-SupersededReview: dedicated fixture, isolated from the shared $tmp\publication.json
# used by the Handoff-freshness section above.
$retireDir = Join-Path $tmp 'retirement'; New-Item -ItemType Directory -Force $retireDir | Out-Null
$retireMarker = Get-ReviewMarker -Pr 7 -Base 'b0e1' -Head 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Round 4 -NormalizedJson $vJson
$retirePubFile = Join-Path $retireDir 'publication.json'
@{ base_oid='b0e1'; reviewed_head_sha='h3ad'; base_ref_name=$mainRef; base_tip_oid=$mainTip
   github_review_id=901; digest='abcdefabcdef'; marker=$retireMarker; round=4 } |
    ConvertTo-Json | Set-Content $retirePubFile -Encoding utf8
$retireReviewOk = @{ id=901; state='APPROVED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body="x $retireMarker" }

# (positive control) genuinely superseded (head advanced), correctly authored, exact marker ->
# revoked. Without this, every refusal test below could trivially "pass" by refusing everything.
$script:GhCalls.Clear()
$script:GhScript = @(
    (New-JsonResponse $retireReviewOk),                  # Test-HandoffFresh: get review (author/marker/state/commit all ok)
    (New-OidsResponse 'b0e1' 'MOVEDHEAD901' $mainRef),    # Test-HandoffFresh: Get-PrOids -> head advanced
    (New-JsonResponse $retireReviewOk),                   # Revoke-SupersededReview: its OWN re-read (author ok, marker ok, not dismissed)
    (New-JsonResponse (@{ id=901; state='DISMISSED' })),  # dismiss PUT
    (New-JsonResponse (@{ id=901; state='DISMISSED' }))   # dismiss re-GET
)
$revOk = Revoke-SupersededReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile $retirePubFile
Assert-True $revOk.Revoked "(positive control) a genuinely superseded, correctly-authored, exact-marker review IS revoked"

# retirement refuses a review NOT authored by the configured reviewer -- Test-HandoffFresh's OWN
# earlier read sees the CORRECT author (so it reaches the drift check and reports 'head advanced'
# normally); Revoke-SupersededReview's OWN SEPARATE later re-read sees a DIFFERENT author. This
# proves precondition (i) is a genuinely independent re-check, not merely inherited from
# Test-HandoffFresh's check ordering.
$script:GhCalls.Clear()
$retireReviewWrongAuthorLater = @{ id=901; state='APPROVED'; commit_id='h3ad'; user=@{login='someone-else'}; body="x $retireMarker" }
$script:GhScript = @(
    (New-JsonResponse $retireReviewOk),
    (New-OidsResponse 'b0e1' 'MOVEDHEAD901' $mainRef),
    (New-JsonResponse $retireReviewWrongAuthorLater)
)
$revBadAuthor = Revoke-SupersededReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile $retirePubFile
Assert-True ((-not $revBadAuthor.Revoked) -and $revBadAuthor.Reason -match 'authored by') "retirement refuses a review NOT authored by the configured reviewer (independent re-check)"
Assert-Eq (@($script:GhCalls | Where-Object { ($_.Args -join ' ') -match 'dismissals' }).Count) 0 "no dismissal attempted when the author check fails"

# retirement refuses a review whose live body no longer carries the exact marker -- same
# independent-re-check proof as above, this time for precondition (ii).
$script:GhCalls.Clear()
$retireReviewNoMarkerLater = @{ id=901; state='APPROVED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body='body edited, marker gone' }
$script:GhScript = @(
    (New-JsonResponse $retireReviewOk),
    (New-OidsResponse 'b0e1' 'MOVEDHEAD901' $mainRef),
    (New-JsonResponse $retireReviewNoMarkerLater)
)
$revNoMarker = Revoke-SupersededReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile $retirePubFile
Assert-True ((-not $revNoMarker.Revoked) -and $revNoMarker.Reason -match 'marker') "retirement refuses a review whose exact tool marker is absent from the live body (independent re-check)"
Assert-Eq (@($script:GhCalls | Where-Object { ($_.Args -join ' ') -match 'dismissals' }).Count) 0 "no dismissal attempted when the marker check fails"

# retirement refuses a NON-drift not-fresh reason -- a red build is not supersession, and must
# never trigger retirement of a review that may still accurately describe the current code.
$script:GhCalls.Clear()
$retireRedChecks = { param($a) [pscustomobject]@{ExitCode=0; Stdout=(@(@{check_runs=@(@{name='ci';status='completed';conclusion='failure'})}) | ConvertTo-Json -Depth 6)} }
$script:GhScript = @(
    (New-JsonResponse $retireReviewOk),
    (New-OidsResponse 'b0e1' 'h3ad' $mainRef),    # head UNCHANGED
    (New-RefResponse $mainTip),                    # base tip UNCHANGED
    $retireRedChecks
)
$revCiRed = Revoke-SupersededReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile $retirePubFile
Assert-True ((-not $revCiRed.Revoked) -and $revCiRed.Reason -match 'not a head/base drift condition') "retirement refuses a CI-failure (non-drift) reason -- never mistakes red CI for supersession"

# retirement refuses when the review is still genuinely fresh (nothing moved at all).
$script:GhCalls.Clear()
$script:GhScript = @(
    (New-JsonResponse $retireReviewOk),
    (New-OidsResponse 'b0e1' 'h3ad' $mainRef),
    (New-RefResponse $mainTip),
    $greenChecks, $noStatuses
)
$revFresh = Revoke-SupersededReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile $retirePubFile
Assert-True ((-not $revFresh.Revoked) -and $revFresh.Reason -match 'still fresh') "retirement refuses a review that is genuinely still fresh -- nothing is superseded"

# dismissal DENIAL (e.g. protected-branch restriction) -- reason names the denial, for a caller to
# map to exit 4, exactly like the identical failure mode already handled inside Publish-CodexReview.
$script:GhCalls.Clear()
$script:GhScript = @(
    (New-JsonResponse $retireReviewOk),
    (New-OidsResponse 'b0e1' 'MOVEDHEAD901' $mainRef),
    (New-JsonResponse $retireReviewOk),
    (New-FailResponse)
)
$revDenied = Revoke-SupersededReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile $retirePubFile
Assert-True ((-not $revDenied.Revoked) -and $revDenied.Reason -match 'denied') "dismissal denial is refused with a Reason naming the denial (maps to exit 4)"

# Test-HandoffFresh MUST remain read-only: it reports, it never mutates -- even when it detects
# drift. Proven against a RECORDING check of every call this in-process fake made (equivalent to a
# recording fake `gh`, since this file's own Invoke-Gh override IS the interception point every
# call in this process goes through).
$script:GhCalls.Clear()
$script:GhScript = @((New-JsonResponse $retireReviewOk), (New-OidsResponse 'b0e1' 'MOVEDHEAD901' $mainRef))
$null = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile $retirePubFile
$mutatingCalls = @($script:GhCalls | Where-Object { ($_.Args -join ' ') -match '(-X\s+(POST|PUT))|dismissals' })
Assert-Eq $mutatingCalls.Count 0 "Test-HandoffFresh performs NO mutating gh call even when it detects drift (read-only contract)"

# PUBLISHER ENTRY PATH: a hanging `gh auth token` must return exit 12 within the deadline.
# The generic bounded-runner test would still pass if publish-review.ps1 itself regressed, so
# this drives the real entry script with a `gh` shim that hangs. Exit-12-and-fast is NOT
# sufficient on its own: a real `gh` with no stored token also exits nonzero fast, so those two
# assertions alone cannot tell "our shim intercepted" from "a real gh ran". Two things close
# that gap:
#   - PATH is restricted to ONLY the shim directory (not merely prepended to the real PATH).
#     A regression to a bare Process.Start(FileName='gh') never consults PATHEXT on Windows, so
#     it would skip a .cmd/.ps1 shim in favour of a real gh.exe found later on PATH — this repo's
#     dev machine has one at "C:\Program Files\GitHub CLI\gh.exe", confirmed reachable via the
#     normal PATH. Restricting PATH to just the shim dir leaves that regression nowhere else to
#     find a real gh at all, so it fails closed instead of silently running live.
#   - the shim writes a sentinel file before it sleeps, and the test asserts the file exists.
#     Only the shim's own execution can produce it, so this is the actual proof of interception.
$ghDir = "$tmp\fakegh"; New-Item -ItemType Directory -Force $ghDir | Out-Null
$sentinel = "$ghDir\ran.sentinel"
Set-Content "$ghDir\gh.ps1" -Encoding utf8 -Value @'
Set-Content -Path "$PSScriptRoot\ran.sentinel" -Value "ran" -Encoding utf8
Start-Sleep 300
'@
Set-Content "$ghDir\gh.cmd" -Encoding ascii -Value "@`"$([System.Environment]::ProcessPath)`" -NoProfile -File `"%~dp0gh.ps1`" %*"
# FINDING 1 (P1, see docs/build-log/task-14-report.md): the provenance gate (Test-PublishProvenance)
# now runs before ANY gh call, so this fixture must supply a canonical verdict path AND a
# matching attempt record for the arguments used below, or the real script would be rejected at
# the NEW gate (exit 6) before ever reaching the gh-hang behavior this test actually exercises.
Write-AttemptMeta -StateDir $tmp -Round 1 -Attempt 1 -Meta @{
    round=1; pr_number=7; base_oid='b0e1'; head_sha='h3ad'; base_ref_name=$mainRef; base_tip_oid=$mainTip
}
$vFile = "$tmp\round-1-verdict.json"; Set-Content $vFile -Value $vJson -Encoding utf8
$pubEntry = "$PSScriptRoot\..\codex-review\scripts\publish-review.ps1"
$pwshExe = [System.Environment]::ProcessPath   # resolved BEFORE PATH is restricted below: a
                                                # PATH-less child cannot resolve `pwsh` by name
$swPub = [System.Diagnostics.Stopwatch]::StartNew()
$oldPath = $env:PATH; $env:PATH = $ghDir   # ONLY the shim dir — a regression cannot reach a real gh.exe
& $pwshExe -NoProfile -File $pubEntry -OwnerRepo 'o/r' -Pr 7 -Round 1 -VerdictFile $vFile -StateDir $tmp -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip
$pubExit = $LASTEXITCODE; $env:PATH = $oldPath; $swPub.Stop()
Assert-Eq $pubExit 12 "publisher entry returns 12 when `gh auth token` hangs"
Assert-True ($swPub.Elapsed.TotalSeconds -lt 90) "publisher entry returned within the token deadline ($([int]$swPub.Elapsed.TotalSeconds)s), not after 300s"
Assert-True (Test-Path $sentinel) "gh shim actually ran (PATH-restricted interception proven, not a coincidental real gh)"

# PUBLISHER ENTRY PATH, FORWARDING: publish-review.ps1 must thread a non-default -Reviewer into
# Publish-CodexReview end-to-end, not silently fall back to the library's own default. Proven
# through the REAL entry script (not the in-process Invoke-Gh override) with a `gh` shim that
# authenticates as a CUSTOM reviewer: if forwarding regressed, the identity gate inside
# Publish-CodexReview would compare against the library's own default ('BanyanLLC') instead of
# the custom value passed on the command line, mismatch, and abort at exit 12 before any other
# gh call. With forwarding intact it clears that gate and fails later, at the deliberately
# unimplemented `pr view` call, which publish-review.ps1 maps to exit 5 — proof enough it got
# past identity, without needing to fake the entire GitHub review-publish surface.
$ghDir2 = "$tmp\fakegh2"; New-Item -ItemType Directory -Force $ghDir2 | Out-Null
Set-Content "$ghDir2\gh.ps1" -Encoding utf8 -Value @'
param()
$a = $args
if ($a[0] -eq 'auth' -and $a[1] -eq 'token') { Write-Output 'FAKETOKEN'; exit 0 }
if ($a[0] -eq 'api' -and $a -contains 'user') { Write-Output 'custom-reviewer'; exit 0 }
exit 7
'@
Set-Content "$ghDir2\gh.cmd" -Encoding ascii -Value "@`"$([System.Environment]::ProcessPath)`" -NoProfile -File `"%~dp0gh.ps1`" %*"
# FINDING 1 (P1): own round number (2, not 1) so this fixture is independent of the block above's
# round-1 attempt record/verdict in the same $tmp -- same reasoning as that block's comment.
Write-AttemptMeta -StateDir $tmp -Round 2 -Attempt 1 -Meta @{
    round=2; pr_number=7; base_oid='b0e1'; head_sha='h3ad'; base_ref_name=$mainRef; base_tip_oid=$mainTip
}
$vFile2 = "$tmp\round-2-verdict.json"; Set-Content $vFile2 -Value $vJson -Encoding utf8
$oldPath2 = $env:PATH; $env:PATH = $ghDir2   # ONLY the shim dir, same isolation as the block above
& $pwshExe -NoProfile -File $pubEntry -OwnerRepo 'o/r' -Pr 7 -Round 2 -VerdictFile $vFile2 -StateDir $tmp -BaseOid 'b0e1' -HeadSha 'h3ad' -BaseRefName $mainRef -BaseTipOid $mainTip -Reviewer 'custom-reviewer'
$fwdExit = $LASTEXITCODE; $env:PATH = $oldPath2
Assert-Eq $fwdExit 5 "non-default -Reviewer is forwarded end-to-end (clears the identity gate under the custom name, then fails later — not exit 12)"

# =====================================================================================
# FINDING 1 (P1, see docs/build-log/task-14-report.md): publish-review.ps1 must bind its
# caller-supplied -Pr/-Round/-BaseOid/-HeadSha/-BaseRefName/-BaseTipOid to the immutable attempt
# record that actually produced the canonical verdict, and refuse LOCALLY -- before any `gh`
# call -- on any mismatch. PROVEN LIVE (see the finding): a round-3 verdict genuinely reviewed at
# base tip 3dc0738 was re-published with tip 2403a80 simply by passing different arguments --
# the verdict was relabelled as covering a base context it never reviewed.
# =====================================================================================

# --- Direct unit tests of Test-PublishProvenance: fast, precise, no process spawn.
$provDir = Join-Path $tmp 'provenance'; New-Item -ItemType Directory -Force $provDir | Out-Null
Write-AttemptMeta -StateDir $provDir -Round 5 -Attempt 1 -Meta @{
    round=5; pr_number=42; base_oid='baseoidAAA'; head_sha='headshaAAA'
    base_ref_name='main'; base_tip_oid='tipAAA'
}
$provVerdict = Join-Path $provDir 'round-5-verdict.json'
Set-Content $provVerdict -Value $vJson -Encoding utf8

function New-ProvArgs([hashtable]$Overrides = @{}) {
    $a = @{ StateDir=$provDir; Round=5; VerdictFile=$provVerdict; Pr=42
            BaseOid='baseoidAAA'; HeadSha='headshaAAA'; BaseRefName='main'; BaseTipOid='tipAAA' }
    foreach ($k in $Overrides.Keys) { $a[$k] = $Overrides[$k] }
    return $a
}

# NOTE: `Test-PublishProvenance @(New-ProvArgs ...)` would be WRONG here -- `@(...)` is the array-
# subexpression operator, which wraps the hashtable in a 1-element ARRAY rather than splatting it;
# splatting requires `@` directly against a variable holding the hashtable. Each call below
# assigns to a variable first, then splats that variable, so PowerShell actually maps the keys
# onto Test-PublishProvenance's named parameters instead of failing a type-conversion bind.
$argsD = New-ProvArgs
Assert-True (Test-PublishProvenance @argsD).Ok "(d) fully matching arguments pass Test-PublishProvenance"

$argsTip = New-ProvArgs @{ BaseTipOid='tipBBB' }
$tipMismatch = Test-PublishProvenance @argsTip
Assert-True ((-not $tipMismatch.Ok) -and $tipMismatch.Reason -match 'base_tip_oid') "(a) base-tip mismatch fails closed and names base_tip_oid"

$argsHead = New-ProvArgs @{ HeadSha='headshaBBB' }
$headMismatch = Test-PublishProvenance @argsHead
Assert-True ((-not $headMismatch.Ok) -and $headMismatch.Reason -match 'head_sha') "(b) head-sha mismatch fails closed and names head_sha"

$argsPr = New-ProvArgs @{ Pr=999 }
$prMismatch = Test-PublishProvenance @argsPr
Assert-True ((-not $prMismatch.Ok) -and $prMismatch.Reason -match '\bpr\b') "(c) wrong PR number fails closed and names pr"

$argsBaseOid = New-ProvArgs @{ BaseOid='baseoidZZZ' }
$baseOidMismatch = Test-PublishProvenance @argsBaseOid
Assert-True ((-not $baseOidMismatch.Ok) -and $baseOidMismatch.Reason -match 'base_oid') "base-oid mismatch fails closed and names base_oid"

$argsRef = New-ProvArgs @{ BaseRefName='other-branch' }
$refMismatch = Test-PublishProvenance @argsRef
Assert-True ((-not $refMismatch.Ok) -and $refMismatch.Reason -match 'base_ref_name') "base-ref-name mismatch fails closed and names base_ref_name"

$arbitraryFile = Join-Path $tmp 'some-other-file.json'; Set-Content $arbitraryFile -Value $vJson -Encoding utf8
$argsArb = New-ProvArgs @{ VerdictFile=$arbitraryFile }
$arbResult = Test-PublishProvenance @argsArb
Assert-True ((-not $arbResult.Ok) -and $arbResult.Reason -match 'canonical') "an arbitrary -VerdictFile path (not the canonical round file) is rejected"

$argsWrongRound = New-ProvArgs @{ Round=6 }
$wrongRoundPath = Test-PublishProvenance @argsWrongRound
Assert-True ((-not $wrongRoundPath.Ok) -and $wrongRoundPath.Reason -match 'canonical') "-VerdictFile for a different round than -Round claims is rejected"

# (c) wrong round, the OTHER way: the attempt record's own internal 'round' field disagrees with
# the filename/-Round used to locate it (a tampered or hand-edited attempt record) -- the
# canonical-PATH check alone cannot catch this, since -VerdictFile still correctly names round 7's
# file; only the attempt record's own CONTENT check does. Own round number (7), isolated from the
# round-5 fixture above, so this scenario's tampered record cannot become "the highest attempt"
# picked for any other test in this section.
Write-AttemptMeta -StateDir $provDir -Round 7 -Attempt 1 -Meta @{
    round=99; pr_number=42; base_oid='baseoidAAA'; head_sha='headshaAAA'
    base_ref_name='main'; base_tip_oid='tipAAA'
}
$verdict7 = Join-Path $provDir 'round-7-verdict.json'; Set-Content $verdict7 -Value $vJson -Encoding utf8
$roundFieldMismatch = Test-PublishProvenance -StateDir $provDir -Round 7 -VerdictFile $verdict7 `
    -Pr 42 -BaseOid 'baseoidAAA' -HeadSha 'headshaAAA' -BaseRefName 'main' -BaseTipOid 'tipAAA'
Assert-True ((-not $roundFieldMismatch.Ok) -and $roundFieldMismatch.Reason -match '\bround\b') "attempt record's own 'round' field disagreeing with the filename/-Round is caught, not just the path check"

# (e) missing attempt metadata entirely -- a canonical verdict exists but no attempt record does.
$noAttemptDir = Join-Path $tmp 'provenance-noattempt'; New-Item -ItemType Directory -Force $noAttemptDir | Out-Null
$noAttemptVerdict = Join-Path $noAttemptDir 'round-1-verdict.json'; Set-Content $noAttemptVerdict -Value $vJson -Encoding utf8
$noAttempt = Test-PublishProvenance -StateDir $noAttemptDir -Round 1 -VerdictFile $noAttemptVerdict -Pr 1 -BaseOid 'x' -HeadSha 'y' -BaseRefName 'main' -BaseTipOid 'z'
Assert-True ((-not $noAttempt.Ok) -and $noAttempt.Reason -match 'no attempt metadata') "(e) missing attempt metadata fails closed"

# --- Subprocess-level proof: a mismatch must fail with EXIT 6 and never invoke `gh` at all --
# proven via a fake `gh` that records every invocation to a file; the file must never be created.
# A fully-matching call, by contrast, must clear this gate and reach `gh` (proven by the SAME
# recording file becoming non-empty) -- a positive control, so an accidentally-inert recording
# shim cannot make every case look like "no gh call" trivially.
$provEntryDir = Join-Path $tmp 'provenance-entry'; New-Item -ItemType Directory -Force $provEntryDir | Out-Null
Write-AttemptMeta -StateDir $provEntryDir -Round 1 -Attempt 1 -Meta @{
    round=1; pr_number=7; base_oid='b0e1'; head_sha='h3ad'; base_ref_name=$mainRef; base_tip_oid=$mainTip
}
$provEntryVerdict = Join-Path $provEntryDir 'round-1-verdict.json'
Set-Content $provEntryVerdict -Value $vJson -Encoding utf8
$verdict3Entry = Join-Path $provEntryDir 'round-3-verdict.json'; Set-Content $verdict3Entry -Value $vJson -Encoding utf8

$ghDirRec = "$tmp\fakegh-recording"; New-Item -ItemType Directory -Force $ghDirRec | Out-Null
$callsLog = "$ghDirRec\calls.log"
Set-Content "$ghDirRec\gh.ps1" -Encoding utf8 -Value @'
param()
Add-Content -Path "$PSScriptRoot\calls.log" -Value ($args -join ' ') -Encoding utf8
exit 1
'@
Set-Content "$ghDirRec\gh.cmd" -Encoding ascii -Value "@`"$([System.Environment]::ProcessPath)`" -NoProfile -File `"%~dp0gh.ps1`" %*"

function New-EntryArgs([hashtable]$Overrides = @{}) {
    $a = @{ OwnerRepo='o/r'; Pr=7; Round=1; VerdictFile=$provEntryVerdict; StateDir=$provEntryDir
            BaseOid='b0e1'; HeadSha='h3ad'; BaseRefName=$mainRef; BaseTipOid=$mainTip }
    foreach ($k in $Overrides.Keys) { $a[$k] = $Overrides[$k] }
    return $a
}
function Invoke-PublisherEntryRecording([hashtable]$PublishArgs) {
    if (Test-Path $callsLog) { Remove-Item $callsLog -Force }
    $argv = [System.Collections.Generic.List[string]]::new()
    $argv.Add('-NoProfile'); $argv.Add('-File'); $argv.Add($pubEntry)
    foreach ($k in $PublishArgs.Keys) { $argv.Add("-$k"); $argv.Add([string]$PublishArgs[$k]) }
    $oldPathRec = $env:PATH; $env:PATH = $ghDirRec
    & $pwshExe @argv
    $exit = $LASTEXITCODE
    $env:PATH = $oldPathRec
    [pscustomobject]@{ Exit=$exit; Logged=(Test-Path $callsLog) }
}

$rTip = Invoke-PublisherEntryRecording (New-EntryArgs @{ BaseTipOid='WRONGTIP' })
Assert-Eq $rTip.Exit 6 "(a) tip-A verdict + tip-B argument: publisher entry exits 6"
Assert-True (-not $rTip.Logged) "(a) tip mismatch: gh was NEVER invoked (recording file never created)"

$rHead = Invoke-PublisherEntryRecording (New-EntryArgs @{ HeadSha='WRONGHEAD' })
Assert-Eq $rHead.Exit 6 "(b) head-A verdict + head-B argument: publisher entry exits 6"
Assert-True (-not $rHead.Logged) "(b) head mismatch: gh was NEVER invoked (recording file never created)"

$rPr = Invoke-PublisherEntryRecording (New-EntryArgs @{ Pr=999 })
Assert-Eq $rPr.Exit 6 "(c) wrong PR number: publisher entry exits 6"
Assert-True (-not $rPr.Logged) "(c) wrong PR number: gh was NEVER invoked (recording file never created)"

$rRound = Invoke-PublisherEntryRecording (New-EntryArgs @{ Round=2; VerdictFile=(Join-Path $provEntryDir 'round-2-verdict.json') })
Assert-Eq $rRound.Exit 6 "(c) wrong round: publisher entry exits 6"
Assert-True (-not $rRound.Logged) "(c) wrong round: gh was NEVER invoked (recording file never created)"

$rMissingAttempt = Invoke-PublisherEntryRecording (New-EntryArgs @{ Round=3; VerdictFile=$verdict3Entry })
Assert-Eq $rMissingAttempt.Exit 6 "(e) missing attempt metadata: publisher entry exits 6"
Assert-True (-not $rMissingAttempt.Logged) "(e) missing attempt metadata: gh was NEVER invoked (recording file never created)"

$rOk = Invoke-PublisherEntryRecording (New-EntryArgs)
Assert-Eq $rOk.Exit 12 "(d) fully matching arguments clear the provenance gate and proceed as before (reaches the gh-token stage, exit 12 against this always-fails shim)"
Assert-True $rOk.Logged "(d) fully matching arguments: gh WAS invoked -- positive control proving the recording shim genuinely works"

# Parameter-contract safety: Invoke-Gh -GhArgs is deliberately NOT [Parameter(Mandatory)] (see
# Assert-NoEmptyStringElements in lib.ps1) -- Mandatory would let an array containing an empty
# string silently defeat the caller instead of failing closed. This test targets the REAL
# lib.ps1 Invoke-Gh, not this file's own in-process shadow (defined near the top, above) --
# Test-EmptyElementFailsClosed always runs in a fresh CHILD process that dot-sources lib.ps1
# itself, so the shadow in THIS process's scope never comes into it. See
# Test-EmptyElementFailsClosed in helpers.ps1 for the full rationale and how this was verified to
# fail against the old [Parameter(Mandatory)][string[]] contract.
Test-EmptyElementFailsClosed -LibPath "$PSScriptRoot\..\codex-review\scripts\lib.ps1" `
    -CallExpression "Invoke-Gh -Token 'faketoken' -GhArgs @('pr', '')" `
    -Name 'Invoke-Gh -GhArgs'

# =====================================================================================
# Wait-PrHeadSynced (P1 fix, see docs/build-log/task-14-report.md, drill/round 9 of the live
# e2e): a real drill found `gh pr view --json headRefOid` returning the PRE-PUSH head seconds
# after a push, wasting a full round of the 10-round cap on a stale review. This is the bounded
# poll a caller must run before composing any pr-mode prompt.
#
# Overrides Invoke-Gh with a COUNTING fake (not the fixed queue used above): a real poll loop's
# call count depends on wall-clock timing (Start-Sleep, PollIntervalSec), not a scripted
# sequence -- a finite queue would run out under ordinary timing jitter and fail the test for the
# wrong reason. $script:HeadPollSequence is the ordered list of heads to report; once exhausted
# it keeps repeating its LAST entry, so it stays correct regardless of exactly how many times the
# loop polls before resolving.
# =====================================================================================
$staleHead = 'aaaaaaaaaa'; $expectedHead = 'bbbbbbbbbb'; $thirdHead = 'cccccccccc'
$script:HeadPollCount = 0
$script:HeadPollSequence = @($staleHead)
function Invoke-Gh { param([string]$Token,[string[]]$GhArgs,[string]$InputFile)
    $script:HeadPollCount++
    $idx = [Math]::Min($script:HeadPollCount, $script:HeadPollSequence.Count) - 1
    [pscustomobject]@{ ExitCode=0; Stdout=(@{baseRefOid='b0e1'; headRefOid=$script:HeadPollSequence[$idx]; baseRefName='main'} | ConvertTo-Json) }
}

# (i) stale, then becomes the expected head within the timeout -> Synced=true.
$script:HeadPollCount = 0
$script:HeadPollSequence = @($staleHead, $staleHead, $expectedHead)
$r1 = Wait-PrHeadSynced -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -ExpectedHead $expectedHead -StaleHead $staleHead -TimeoutSec 5 -PollIntervalSec 1
Assert-True $r1.Synced "(i) becomes synced within the timeout"
Assert-Eq $r1.ActualHead $expectedHead "(i) reports the actual (now-synced) head"
Assert-True ($script:HeadPollCount -ge 2) "(i) actually polled more than once (proves it waited, not a lucky first read)"

# (ii) permanently stale -> Synced=false, bounded, with a clear reason naming the timeout.
$script:HeadPollCount = 0
$script:HeadPollSequence = @($staleHead)
$swStale = [System.Diagnostics.Stopwatch]::StartNew()
$r2 = Wait-PrHeadSynced -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -ExpectedHead $expectedHead -StaleHead $staleHead -TimeoutSec 2 -PollIntervalSec 1
$swStale.Stop()
Assert-True (-not $r2.Synced) "(ii) permanently stale never syncs"
Assert-Eq $r2.ActualHead $staleHead "(ii) reports the still-stale head"
Assert-True ($r2.Reason -match 'timed out') "(ii) reason names the timeout"
Assert-True ($swStale.Elapsed.TotalSeconds -lt 10) "(ii) bounded -- returned near the 2s timeout, not hung"

# (iii) an UNEXPECTED third head (neither the expected commit nor the known-stale one) ->
# Synced=false with a DISTINCT reason from plain staleness, detected WITHOUT waiting out the
# timeout: someone else pushed is not "still propagating", so polling further would only waste
# time on a wrong assumption.
$script:HeadPollCount = 0
$script:HeadPollSequence = @($thirdHead)
$swThird = [System.Diagnostics.Stopwatch]::StartNew()
$r3 = Wait-PrHeadSynced -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -ExpectedHead $expectedHead -StaleHead $staleHead -TimeoutSec 30 -PollIntervalSec 5
$swThird.Stop()
Assert-True (-not $r3.Synced) "(iii) unexpected third head is not synced"
Assert-Eq $r3.ActualHead $thirdHead "(iii) reports the unexpected head"
Assert-True ($r3.Reason -notmatch 'timed out') "(iii) reason is distinct from a plain timeout"
Assert-True ($r3.Reason -match 'unexpected') "(iii) reason flags the head as unexpected"
Assert-True ($swThird.Elapsed.TotalSeconds -lt 5) "(iii) detected immediately, not after waiting out a 30s timeout"

# (iv) FINDING 3 (P2, see docs/build-log/task-14-report.md): the regression this finding was
# reported without -- WITHOUT -StaleHead (a first sync, with no prior head to name -- the most
# common caller), a head that is initially stale and only later becomes the expected commit must
# still return Synced=$true, and must genuinely have POLLED MORE THAN ONCE (the call count is the
# proof: the pre-fix bug returned "unexpected head" on the FIRST poll instead of continuing, so a
# call count of 1 here would mean the regression is back, even if Synced happened to read $true by
# some other coincidence).
$script:HeadPollCount = 0
$script:HeadPollSequence = @($staleHead, $staleHead, $expectedHead)
$r4 = Wait-PrHeadSynced -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -ExpectedHead $expectedHead -TimeoutSec 5 -PollIntervalSec 1
Assert-True $r4.Synced "(iv) no -StaleHead: becomes synced within the timeout, not rejected as 'unexpected' on the first stale read"
Assert-Eq $r4.ActualHead $expectedHead "(iv) no -StaleHead: reports the actual (now-synced) head"
Assert-True ($script:HeadPollCount -ge 2) "(iv) no -StaleHead: actually polled more than once (the pre-fix bug returned 'unexpected head' after exactly 1 poll)"

Write-TestResult
