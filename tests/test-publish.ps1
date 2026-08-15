. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\..\codex-review\scripts\lib.ps1"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "codexpub-$([guid]::NewGuid())"
New-Item -ItemType Directory -Force $tmp | Out-Null

# Hostile content must flow byte-safely into the JSON payload (never a command line).
$hostileVerdict = @{verdict='request_changes'; summary="quotes `" back`` tick `$(boom) newline`nend";
    recommendations=@(@{severity='blocking'; location='a"b'; issue="i`n`"x`""; suggestion='s`$(y)'})} | ConvertTo-Json -Depth 5 -Compress
$hv = $hostileVerdict | ConvertFrom-Json
$marker = Get-ReviewMarker -Pr 7 -Base 'b0e1' -Head 'h3ad' -Round 2 -NormalizedJson $hostileVerdict
Assert-True ($marker -match '^<!-- codex-review:pr=7:base=b0e1:head=h3ad:round=2:digest=[0-9a-f]{12} -->$') "marker format"
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
function New-OidsResponse([string]$b,[string]$h) { { param($a) [pscustomobject]@{ExitCode=0; Stdout=(@{baseRefOid=$b; headRefOid=$h} | ConvertTo-Json)} }.GetNewClosure() }
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

$vJson = '{"verdict":"approve","summary":"LGTM","recommendations":[{"severity":"nit","location":"x","issue":"i","suggestion":"s"}]}'
$vObj = $vJson | ConvertFrom-Json
$marker2 = Get-ReviewMarker -Pr 7 -Base 'b0e1' -Head 'h3ad' -Round 2 -NormalizedJson $vJson
$review = @{ id=555; state='APPROVED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body="x $marker2" }

# Happy path (hostile chars already covered above through the body builder).
$script:GhScript = @(
    (New-ActorOk),
    (New-OidsResponse 'b0e1' 'h3ad'),
    (New-JsonResponse @(@(@{id=1;state='APPROVED';user=@{login='someone'};body='no'}), @())),
    (New-JsonResponse $review), (New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad')
)
$code = Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -Round 2 -NormalizedJson $vJson -StateDir $tmp
Assert-Eq $code 0 "happy path 0"
$post = $script:GhCalls | Where-Object { $_.Args -contains 'POST' }
Assert-True ($post.Input -match '"commit_id"\s*:\s*"h3ad"') "commit_id pinned"
Assert-True ($post.Input -match '"event"\s*:\s*"APPROVE"') "event APPROVE"
Assert-True (($script:GhCalls | Where-Object { ($_.Args -join ' ') -match '--paginate --slurp' }) -ne $null) "slurp pagination"
$pub = Get-Content -Raw "$tmp\publication.json" | ConvertFrom-Json
Assert-Eq $pub.github_review_id 555 "publication persisted"
Assert-True ($pub.digest -match '^[0-9a-f]{12}$') "standalone digest recorded"

# Downgrade regression: approve+important normalized upstream => event must be REQUEST_CHANGES.
$dgJson = '{"verdict":"request_changes","summary":"x","recommendations":[{"severity":"important","location":"l","issue":"i","suggestion":"s"}]}'
$dgObj = $dgJson | ConvertFrom-Json
$dgMarker = Get-ReviewMarker -Pr 7 -Base 'b0e1' -Head 'h3ad' -Round 3 -NormalizedJson $dgJson
$dgReview = @{ id=600; state='CHANGES_REQUESTED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body="x $dgMarker" }
$script:GhCalls.Clear()
$script:GhScript = @(
    (New-ActorOk), (New-OidsResponse 'b0e1' 'h3ad'), (New-JsonResponse @(@())),
    (New-JsonResponse $dgReview), (New-JsonResponse $dgReview), (New-OidsResponse 'b0e1' 'h3ad')
)
$code = Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $dgObj -BaseOid 'b0e1' -HeadSha 'h3ad' -Round 3 -NormalizedJson $dgJson -StateDir $tmp
Assert-Eq $code 0 "downgraded verdict publishes"
Assert-True (($script:GhCalls | Where-Object { $_.Args -contains 'POST' }).Input -match '"event"\s*:\s*"REQUEST_CHANGES"') "DOWNGRADED VERDICT PUBLISHES AS REQUEST_CHANGES"

# Pre-publication drift (head) -> 2, no POST.
$script:GhCalls.Clear(); $script:GhScript = @((New-ActorOk), (New-OidsResponse 'b0e1' 'NEWHEAD'))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -Round 2 -NormalizedJson $vJson -StateDir $tmp) 2 "pre-drift 2"
Assert-True (-not ($script:GhCalls | Where-Object { $_.Args -contains 'POST' })) "no mutation"

# Recovery beyond page one; DISMISSED marker does not suppress; post-POST BASE and HEAD drift; wrong state; 403.
$page1 = @(1..30 | ForEach-Object { @{id=$_; state='COMMENTED'; user=@{login='BanyanLLC'}; body="unrelated $_"} })
$page2 = @(@{ id=777; state='APPROVED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body="recovered $marker2" })
$script:GhCalls.Clear()
$script:GhScript = @((New-ActorOk), (New-OidsResponse 'b0e1' 'h3ad'), (New-JsonResponse @($page1, $page2)),
    (New-JsonResponse $page2[0]), (New-OidsResponse 'b0e1' 'h3ad'))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -Round 2 -NormalizedJson $vJson -StateDir $tmp) 0 "page-2 recovery verified"
Assert-True (-not ($script:GhCalls | Where-Object { $_.Args -contains 'POST' })) "no duplicate POST"

$script:GhCalls.Clear()
$dismissed = @(@(@{ id=778; state='DISMISSED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body="old $marker2" }))
$script:GhScript = @((New-ActorOk), (New-OidsResponse 'b0e1' 'h3ad'), (New-JsonResponse $dismissed),
    (New-JsonResponse $review), (New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad'))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -Round 2 -NormalizedJson $vJson -StateDir $tmp) 0 "dismissed marker ignored"
Assert-True (($script:GhCalls | Where-Object { $_.Args -contains 'POST' }) -ne $null) "fresh POST after dismissed marker"

foreach ($driftCase in @(@{oids=(New-OidsResponse 'MOVEDBASE' 'h3ad'); name='base'}, @{oids=(New-OidsResponse 'b0e1' 'MOVEDHEAD'); name='head'})) {
    $script:GhCalls.Clear()
    $script:GhScript = @((New-ActorOk), (New-OidsResponse 'b0e1' 'h3ad'), (New-JsonResponse @(@())),
        (New-JsonResponse $review), (New-JsonResponse $review), $driftCase.oids,
        (New-JsonResponse (@{ id=555; state='DISMISSED' })), (New-JsonResponse (@{ id=555; state='DISMISSED' })))
    Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -Round 2 -NormalizedJson $vJson -StateDir $tmp) 3 "post-POST $($driftCase.name) drift -> dismissed -> 3"
    $dis = $script:GhCalls | Where-Object { ($_.Args -join ' ') -match 'dismissals' }
    Assert-True ($dis.Input -match '"event"\s*:\s*"DISMISS"' -and $dis.Input -match '"message"') "$($driftCase.name): dismissal body complete"
}

$commented = @{ id=556; state='COMMENTED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body="x $marker2" }
$script:GhScript = @((New-ActorOk), (New-OidsResponse 'b0e1' 'h3ad'), (New-JsonResponse @(@())),
    (New-JsonResponse $commented), (New-JsonResponse $commented), (New-OidsResponse 'b0e1' 'h3ad'),
    (New-JsonResponse (@{ id=556; state='DISMISSED' })), (New-JsonResponse (@{ id=556; state='DISMISSED' })))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -Round 2 -NormalizedJson $vJson -StateDir $tmp) 3 "COMMENTED state dismissed -> 3"

$script:GhScript = @((New-ActorOk), (New-OidsResponse 'b0e1' 'h3ad'), (New-JsonResponse @(@())),
    (New-JsonResponse $review), (New-JsonResponse $review), (New-OidsResponse 'MOVEDBASE' 'h3ad'), (New-FailResponse))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -Round 2 -NormalizedJson $vJson -StateDir $tmp) 4 "dismissal denied -> 4"

# IDENTITY: a token that authenticates as someone other than the expected reviewer must be
# refused BEFORE any mutation — no drift check, scan, or POST may happen once the identity
# check has failed. Exit 12 reuses the existing "no usable token for '$Reviewer'" contract: a
# token that authenticates as the wrong person is exactly as unusable as no token at all.
$script:GhCalls.Clear()
$script:GhScript = @((New-TextResponse 'someone-else'))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -Round 2 -NormalizedJson $vJson -StateDir $tmp) 12 "actor mismatch refused before mutation"
Assert-Eq $script:GhCalls.Count 1 "actor mismatch stops after the identity check alone (no oids/scan/POST)"

# IDENTITY: a review read back with the right state/commit but the WRONG user.login must fail
# post-publication verification the same as any other verification failure, and be dismissed —
# this is the defence-in-depth half, independent of the pre-mutation token check above.
$wrongAuthor = @{ id=557; state='APPROVED'; commit_id='h3ad'; user=@{login='someone-else'}; body="x $marker2" }
$script:GhCalls.Clear()
$script:GhScript = @((New-ActorOk), (New-OidsResponse 'b0e1' 'h3ad'), (New-JsonResponse @(@())),
    (New-JsonResponse $wrongAuthor), (New-JsonResponse $wrongAuthor), (New-OidsResponse 'b0e1' 'h3ad'),
    (New-JsonResponse (@{ id=557; state='DISMISSED' })), (New-JsonResponse (@{ id=557; state='DISMISSED' })))
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $vObj -BaseOid 'b0e1' -HeadSha 'h3ad' -Round 2 -NormalizedJson $vJson -StateDir $tmp) 3 "review authored by someone else fails post-verification -> dismissed"

# HOSTILE CONTENT THROUGH THE REAL PUBLISHER: it must survive as data, never as syntax.
$script:GhCalls.Clear()
$hostileMarker = Get-ReviewMarker -Pr 7 -Base 'b0e1' -Head 'h3ad' -Round 9 -NormalizedJson $hostileVerdict
$hostileReview = @{ id=999; state='CHANGES_REQUESTED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body="x $hostileMarker" }
$script:GhScript = @(
    (New-ActorOk), (New-OidsResponse 'b0e1' 'h3ad'), (New-JsonResponse @(@())),
    (New-JsonResponse $hostileReview), (New-JsonResponse $hostileReview), (New-OidsResponse 'b0e1' 'h3ad')
)
Assert-Eq (Publish-CodexReview -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -NormalizedVerdict $hv -BaseOid 'b0e1' -HeadSha 'h3ad' -Round 9 -NormalizedJson $hostileVerdict -StateDir $tmp) 0 "hostile verdict publishes"
$hPost = $script:GhCalls | Where-Object { $_.Args -contains 'POST' }
$sent = $hPost.Input | ConvertFrom-Json
Assert-True ($sent.body.Contains($hv.summary)) "hostile summary round-trips byte-exact through the JSON payload"
Assert-True ($sent.body.Contains($hv.recommendations[0].suggestion)) "hostile suggestion round-trips byte-exact"
Assert-Eq $sent.commit_id 'h3ad' "commit still pinned with hostile content"
foreach ($call in $script:GhCalls) {
    Assert-True (($call.Args -join ' ') -notmatch '\$\(|boom|`') "hostile text never appears in argv"
}

# Handoff freshness: every negative case must be caught.
@{ base_oid='b0e1'; reviewed_head_sha='h3ad'; github_review_id=555; digest='abcdefabcdef'; marker=$marker2 } |
    ConvertTo-Json | Set-Content "$tmp\publication.json" -Encoding utf8
$greenChecks = { param($a) [pscustomobject]@{ExitCode=0; Stdout=(@(@{check_runs=@(@{name='ci';status='completed';conclusion='success'})}) | ConvertTo-Json -Depth 6)} }
$noStatuses  = { param($a) [pscustomobject]@{ExitCode=0; Stdout=(@{total_count=0; state='pending'} | ConvertTo-Json)} }
$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad'), $greenChecks, $noStatuses)
Assert-True (Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json").Fresh "fresh handoff passes"

$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'BASEMOVED' 'h3ad'))
Assert-True (-not (Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json").Fresh) "BASE-ONLY drift caught"

$edited = @{ id=555; state='APPROVED'; commit_id='h3ad'; user=@{login='BanyanLLC'}; body='body was edited, marker removed' }
$script:GhScript = @((New-JsonResponse $edited))
$hfE = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json"
Assert-True ((-not $hfE.Fresh) -and $hfE.Reason -match 'marker') "EDITED body (marker gone) caught"

$foreign = @{ id=555; state='APPROVED'; commit_id='h3ad'; user=@{login='someone-else'}; body="x $marker2" }
$script:GhScript = @((New-JsonResponse $foreign))
$hfF = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json"
Assert-True ((-not $hfF.Fresh) -and $hfF.Reason -match 'reviewer') "WRONG REVIEWER caught"

$redChecks = { param($a) [pscustomobject]@{ExitCode=0; Stdout=(@(@{check_runs=@(@{name='ci';status='completed';conclusion='failure'})}) | ConvertTo-Json -Depth 6)} }
$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad'), $redChecks)
$hfR = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json"
Assert-True ((-not $hfR.Fresh) -and $hfR.Reason -match 'failure') "RED CI on the reviewed sha caught"

$pendingChecks = { param($a) [pscustomobject]@{ExitCode=0; Stdout=(@(@{check_runs=@(@{name='ci';status='in_progress';conclusion=$null})}) | ConvertTo-Json -Depth 6)} }
$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad'), $pendingChecks)
Assert-True (-not (Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json").Fresh) "PENDING CI caught"

# FAIL CLOSED: an unreadable CI endpoint must never read as green.
$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad'), (New-FailResponse))
$hfC = Test-HandoffFresh -Token 'tok' -OwnerRepo 'o/r' -Pr 7 -PublicationFile "$tmp\publication.json"
Assert-True ((-not $hfC.Fresh) -and $hfC.Reason -match 'check-runs') "check-runs read failure fails closed"
$script:GhScript = @((New-JsonResponse $review), (New-OidsResponse 'b0e1' 'h3ad'), $greenChecks, (New-FailResponse))
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
$vFile = "$tmp\norm-verdict.json"; Set-Content $vFile -Value $vJson -Encoding utf8
$pubEntry = "$PSScriptRoot\..\codex-review\scripts\publish-review.ps1"
$pwshExe = [System.Environment]::ProcessPath   # resolved BEFORE PATH is restricted below: a
                                                # PATH-less child cannot resolve `pwsh` by name
$swPub = [System.Diagnostics.Stopwatch]::StartNew()
$oldPath = $env:PATH; $env:PATH = $ghDir   # ONLY the shim dir — a regression cannot reach a real gh.exe
& $pwshExe -NoProfile -File $pubEntry -OwnerRepo 'o/r' -Pr 7 -Round 1 -VerdictFile $vFile -StateDir $tmp -BaseOid 'b0e1' -HeadSha 'h3ad'
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
$vFile2 = "$tmp\norm-verdict2.json"; Set-Content $vFile2 -Value $vJson -Encoding utf8
$oldPath2 = $env:PATH; $env:PATH = $ghDir2   # ONLY the shim dir, same isolation as the block above
& $pwshExe -NoProfile -File $pubEntry -OwnerRepo 'o/r' -Pr 7 -Round 1 -VerdictFile $vFile2 -StateDir $tmp -BaseOid 'b0e1' -HeadSha 'h3ad' -Reviewer 'custom-reviewer'
$fwdExit = $LASTEXITCODE; $env:PATH = $oldPath2
Assert-Eq $fwdExit 5 "non-default -Reviewer is forwarded end-to-end (clears the identity gate under the custom name, then fails later — not exit 12)"

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

Write-TestResult
