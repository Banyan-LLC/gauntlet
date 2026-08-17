. "$PSScriptRoot\helpers.ps1"

<# Regression for the ASSERTION HARNESS ITSELF (helpers.ps1's Assert-True).

   Why this file exists: a silent no-op assertion is the worst failure mode this suite has, because
   it is indistinguishable from success. `Assert-True ((pipeline) -ne $null)` produces an Object[]
   whenever the pipeline yields more than one element, and the old [bool]$Condition signature let
   the parameter binder reject that with a NON-TERMINATING error -- the assertion incremented
   neither counter and the file still reported "N passed, 0 failed". That shipped (drill 6; see
   helpers.ps1's own comment and docs/build-log/progress.md). Assert-True now fails loudly and
   COUNTABLY on any non-[bool]; this file is the proof that it still does.

   Why a CHILD PROCESS: the claim under test is about $script:Passes / $script:Failures themselves.
   Asserting it in-process would mean deliberately provoking failures in the very counters this
   file reports with, corrupting its own result. Each probe therefore runs in an isolated pwsh that
   dot-sources the real helpers.ps1, makes exactly ONE Assert-True call, and prints the resulting
   counters -- so a still-broken harness cannot launder its own verdict. Same isolation rationale
   as Test-EmptyElementFailsClosed in helpers.ps1.

   This deliberately tests the SHIPPED helpers.ps1 by path, not a copy: helpers.ps1 is part of
   Get-GateFingerprint's fixed list, so the file these probes exercise is byte-identical to the one
   the live-evidence stamps are computed over. #>

$helpersPath = (Resolve-Path "$PSScriptRoot\helpers.ps1").Path

function Invoke-AssertTrueProbe {
    # Runs `Assert-True (<ConditionLiteral>) 'probe'` in a child pwsh against the real helpers.ps1
    # and reports the counters it left behind. ConditionLiteral is injected as SOURCE TEXT so each
    # case exercises genuine parameter binding (single-element arrays are NOT unwrapped by the
    # binder -- verified -- which a pre-built variable could accidentally paper over).
    param([Parameter(Mandatory)][string]$ConditionLiteral)
    $child = @"
. '$helpersPath'
Assert-True ($ConditionLiteral) 'probe-assertion'
Write-Output "PASSES=`$(`$script:Passes)"
Write-Output "FAILURES=`$(`$script:Failures.Count)"
Write-Output "TEXT=`$(`$script:Failures -join ' ~ ')"
exit 0
"@
    $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) "assert-probe-$([guid]::NewGuid().ToString('n')).ps1"
    Set-Content -Path $tmpFile -Value $child -Encoding utf8
    try {
        $out = pwsh -NoProfile -File $tmpFile 2>&1 | Out-String
        return [pscustomobject]@{
            Passes   = $(if ($out -match 'PASSES=(\d+)')   { [int]$Matches[1] } else { -1 })
            Failures = $(if ($out -match 'FAILURES=(\d+)') { [int]$Matches[1] } else { -1 })
            Text     = $(if ($out -match 'TEXT=(.*)')      { $Matches[1] }      else { '' })
            Raw      = $out
        }
    } finally { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
}

# --- Non-boolean conditions must produce a COUNTED FAILURE (never a silent skip) ---------------
# Each case pins the reported type and count as well as the counters: a failure that does not say
# WHAT arrived is not actionable, and the count is what distinguishes the multi-element filtering
# bug from an ordinary type mistake.
foreach ($case in @(
    @{ Literal = '@(1,2)';       Label = 'multi-element Object[] (the shipped bug shape)'; Type = 'System.Object[]'; Count = 2 },
    @{ Literal = '@(1)';         Label = 'single-element Object[] (the latent shape)';     Type = 'System.Object[]'; Count = 1 },
    @{ Literal = '@()';          Label = 'empty Object[]';                                 Type = 'System.Object[]'; Count = 0 },
    @{ Literal = "'a string'";   Label = 'string';                                         Type = 'System.String';   Count = 1 },
    @{ Literal = '$null';        Label = 'null';                                           Type = '$null';           Count = 0 }
)) {
    $r = Invoke-AssertTrueProbe -ConditionLiteral $case.Literal
    Assert-Eq $r.Failures 1 "$($case.Label): records exactly one COUNTED failure"
    Assert-Eq $r.Passes   0 "$($case.Label): does not count as a pass"
    # .Contains(), NOT -like: these needles contain '[]' (System.Object[]), and -like would read
    # that as an empty CHARACTER CLASS and throw WildcardPatternException -- which, like the bug
    # this whole file guards against, is non-terminating and uncounted. Caught here in the act:
    # the first draft of this loop used -like and silently reported 36 passed instead of 39.
    Assert-True ($r.Text.Contains('NON-BOOLEAN CONDITION'))  "$($case.Label): failure text names the defect class"
    Assert-True ($r.Text.Contains("type=$($case.Type)"))     "$($case.Label): failure text reports the received type ($($case.Type))"
    Assert-True ($r.Text.Contains("count=$($case.Count)"))   "$($case.Label): failure text reports the element count ($($case.Count))"
    Assert-True ($r.Text.Contains('probe-assertion'))        "$($case.Label): failure text still identifies WHICH assertion"
}

# --- Genuine booleans must retain EXACTLY the previous behavior --------------------------------
$rTrue = Invoke-AssertTrueProbe -ConditionLiteral '$true'
Assert-Eq $rTrue.Passes   1 '$true still counts as a pass'
Assert-Eq $rTrue.Failures 0 '$true records no failure'

$rFalse = Invoke-AssertTrueProbe -ConditionLiteral '$false'
Assert-Eq $rFalse.Passes   0 '$false does not count as a pass'
Assert-Eq $rFalse.Failures 1 '$false records exactly one failure'
Assert-True (-not $rFalse.Text.Contains('NON-BOOLEAN')) '$false fails as an ordinary assertion, NOT as a harness type error'

# An ordinary comparison -- the overwhelmingly common real call shape -- must be unaffected.
$rExpr = Invoke-AssertTrueProbe -ConditionLiteral "'abc' -match '^a'"
Assert-Eq $rExpr.Passes   1 'an ordinary -match comparison still counts as a pass'
Assert-Eq $rExpr.Failures 0 'an ordinary -match comparison records no failure'

# --- The end-to-end claim: the ORIGINAL bug shape is now caught rather than silently skipped ----
# Reproduces the exact expression that shipped broken: a two-element pipeline result compared with
# `-ne $null`. Before the backstop this incremented NEITHER counter; it must now be a real failure.
$rShipped = Invoke-AssertTrueProbe -ConditionLiteral '(@(1,2) | Where-Object { $_ -gt 0 }) -ne $null'
Assert-Eq $rShipped.Failures 1 'the shipped `(multi-element pipeline) -ne $null` shape is now a COUNTED failure'
Assert-Eq $rShipped.Passes   0 'the shipped bug shape is not silently skipped (it used to increment neither counter)'

Write-TestResult
