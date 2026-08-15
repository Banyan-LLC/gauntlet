. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\..\codex-review\scripts\lib.ps1"
# Single schema now (see task-7-report.md): schemas/verdict.schema.json serves both
# --output-schema and Test-Verdict's structural check.
$schemaPath = "$PSScriptRoot\..\codex-review\schemas\verdict.schema.json"
$disable = @('apps','browser_use','shell_tool')

$r1 = New-CodexArgs -HarnessDir 'C:\h' -SchemaPath 'C:\s.json' -VerdictPath 'C:\v.json' -DisableSet $disable
Assert-Eq $r1[0] 'exec' "fresh-session exec"; Assert-Eq $r1[-1] '-' "prompt over stdin"
Assert-True ($r1 -notcontains 'resume') "no resume subcommand in this design"
Assert-True (($r1 -join ' ') -match '-s read-only') "every round carries -s read-only"
Assert-True (($r1 -join ' ') -match '-C C:') "every round carries -C harness"

# Audit: value-level, mode-aware, canonical. Each case is a bypass the presence-only
# version accepted — every one of these MUST throw.
$auditCommon = @{ HarnessDir='C:\h'; SchemaPath='C:\s.json'; VerdictPath='C:\v.json'; ExpectedDisable=$disable }
$a1 = Get-InvocationAudit -CodexArgs $r1 @auditCommon
Assert-True ($a1 -notmatch 'PROMPT') "audit line carries no prompt"

$sIdx = [array]::IndexOf($r1, '-s')
$mutSandbox = [string[]]@($r1); $mutSandbox[$sIdx + 1] = 'danger-full-access'
Assert-Throws { Get-InvocationAudit -CodexArgs $mutSandbox @auditCommon } "BYPASS: -s danger-full-access rejected"
$cIdx = [array]::IndexOf($r1, '-C')
$mutCwd = [string[]]@($r1); $mutCwd[$cIdx + 1] = 'C:\somewhere-else'
Assert-Throws { Get-InvocationAudit -CodexArgs $mutCwd @auditCommon } "BYPASS: wrong -C rejected"
$mIdx = [array]::IndexOf($r1, '-m')
$mutModel = [string[]]@($r1); $mutModel[$mIdx + 1] = 'gpt-4o-mini'
Assert-Throws { Get-InvocationAudit -CodexArgs $mutModel @auditCommon } "BYPASS: wrong model rejected"
Assert-Throws { Get-InvocationAudit -CodexArgs ([string[]]@($r1) + @('-c','web_search="live"')) @auditCommon } "BYPASS: duplicate conflicting -c rejected"
Assert-Throws { Get-InvocationAudit -CodexArgs ([string[]]@($r1) + @('--enable','shell_tool')) @auditCommon } "BYPASS: --enable rejected"
Assert-Throws { Get-InvocationAudit -CodexArgs ([string[]]@($r1) + @('--dangerously-bypass-approvals-and-sandbox')) @auditCommon } "BYPASS: sandbox-bypass flag rejected"
$mutEffort = [string[]]@($r1)
$eIdx = [array]::IndexOf($mutEffort, 'model_reasoning_effort="xhigh"'); $mutEffort[$eIdx] = 'model_reasoning_effort="low"'
Assert-Throws { Get-InvocationAudit -CodexArgs $mutEffort @auditCommon } "BYPASS: downgraded reasoning effort rejected"
$reordered = [string[]]@(@($r1[0]) + @($r1[2..($r1.Count-1)]) + @($r1[1]))
Assert-Throws { Get-InvocationAudit -CodexArgs $reordered @auditCommon } "reordered args fail canonical equality"
Assert-Throws { Get-InvocationAudit -CodexArgs ([string[]]@($r1 | Where-Object { $_ -ne '--ignore-user-config' })) @auditCommon } "missing hermetic flag rejected"
Assert-Throws { Get-InvocationAudit -CodexArgs $r1 @auditCommon -ExpectedDisable @('apps','browser_use') } "disable-set mismatch rejected"
$withResume = [string[]]@(@($r1[0]) + @('resume','1111-2222') + @($r1[1..($r1.Count-1)]))
Assert-Throws { Get-InvocationAudit -CodexArgs $withResume @auditCommon } "BYPASS: a smuggled 'resume' subcommand is rejected"
$noSandbox = [string[]]@($r1 | Where-Object { $_ -cne '-s' -and $_ -cne 'read-only' })
Assert-Throws { Get-InvocationAudit -CodexArgs $noSandbox @auditCommon } "missing -s read-only rejected"

# LAYER 2 DISCRIMINATOR: every bypass case above is also a multiset change (a value is
# wrong, missing, or extra), so Layer 1's own -c/--disable checks — themselves sorted
# multiset comparisons — already reject every one of them without needing Layer 2 at all.
# This case is different: swap the VALUES of two same-flag '-c' occurrences so the full
# array multiset is untouched (same count, same flags, same sorted contents, '-' still
# last) — only their order changes. Layer 1 cannot see that (it sorts before comparing);
# only Layer 2's canonical, position-by-position equality can. If Layer 2 were ever
# weakened to a sorted-multiset comparison (i.e. made to look like Layer 1's own checks),
# this transposition would silently pass both layers and this test would stop failing.
$cValueIdx = @(for ($i = 0; $i -lt $r1.Count; $i++) { if ($r1[$i] -ceq '-c') { $i + 1 } })
if ($cValueIdx.Count -lt 2) { throw 'test fixture error: expected >=2 -c occurrences to swap' }
$swappedVals = [string[]]@($r1)
$i0 = $cValueIdx[0]; $i1 = $cValueIdx[1]
$tmp = $swappedVals[$i0]; $swappedVals[$i0] = $swappedVals[$i1]; $swappedVals[$i1] = $tmp
if ($swappedVals.Count -ne $r1.Count) { throw 'test fixture error: transposition changed argument count' }
if ((($swappedVals | Sort-Object) -join '|') -cne (($r1 | Sort-Object) -join '|')) { throw 'test fixture error: transposition changed the multiset' }
if ($swappedVals[-1] -cne '-') { throw "test fixture error: transposition disturbed the trailing '-'" }
Assert-Throws { Get-InvocationAudit -CodexArgs $swappedVals @auditCommon } "LAYER2: transposed -c values (multiset-identical, order differs) rejected only by canonical ordinal equality"

# LAYER 1 DISCRIMINATOR: Layer 2 only proves the actual array matches whatever
# New-CodexArgs produces — it says nothing about whether New-CodexArgs itself is
# trustworthy. Shadow New-CodexArgs for this scope so it "canonically" emits a forbidden
# sandbox value; if Layer 1's absolute '-s' check were ever deleted, Layer 2 would see
# actual == canonical (both wrong the same way, since both came from the same compromised
# builder) and the invocation would sail through with nothing left to catch it. Restored
# via try/finally so a failed assertion can never leave the shadow in place for later tests.
$savedNewCodexArgs = ${function:New-CodexArgs}
try {
    ${function:New-CodexArgs} = {
        param(
            [Parameter(Mandatory)][string]$HarnessDir,
            [Parameter(Mandatory)][string]$SchemaPath,
            [Parameter(Mandatory)][string]$VerdictPath,
            [Parameter(Mandatory)][string[]]$DisableSet,
            [string]$Model = 'gpt-5.6-sol',
            [string]$Effort = 'xhigh'
        )
        # Same shape as the real builder in lib.ps1, except the sandbox value is forbidden.
        $a = [System.Collections.Generic.List[string]]::new()
        $a.Add('exec')
        $a.AddRange([string[]]@('--ignore-user-config','--ignore-rules','--skip-git-repo-check'))
        $a.AddRange([string[]]@('-s','danger-full-access','-C',$HarnessDir))
        $a.AddRange([string[]]@('-m',$Model,'-c',"model_reasoning_effort=`"$Effort`""))
        $a.AddRange([string[]]@('-c','web_search="disabled"','-c','shell_environment_policy.inherit="none"'))
        foreach ($f in $DisableSet) { $a.Add('--disable'); $a.Add($f) }
        $a.AddRange([string[]]@('--output-schema',$SchemaPath,'-o',$VerdictPath,'--json','-'))
        return $a.ToArray()
    }
    $compromised = New-CodexArgs -HarnessDir 'C:\h' -SchemaPath 'C:\s.json' -VerdictPath 'C:\v.json' -DisableSet $disable
    if ($compromised -notcontains 'danger-full-access') { throw 'test fixture error: shadow builder did not inject the forbidden value' }
    Assert-Throws { Get-InvocationAudit -CodexArgs $compromised @auditCommon } "LAYER1: forbidden '-s danger-full-access' rejected even though it agrees exactly with a compromised canonical builder"
} finally {
    ${function:New-CodexArgs} = $savedNewCodexArgs
}

# Normalization is canonical: one object, one JSON, downgrade applied IN the object. The
# severity invariant now rests SOLELY here (see task-7-report.md): the schema no longer encodes
# it (if/then is gone, rejected by the real API), so BOTH severities that used to be caught by
# the schema's if/then -- 'important' and 'blocking' -- must each be proven to downgrade, in
# BOTH the returned object and the returned JSON, discriminating this from a no-op normalizer.
$ap = '{"verdict":"approve","summary":"x","recommendations":[{"severity":"important","location":"l","issue":"i","suggestion":"s"}]}'
$v = Test-Verdict -Json $ap -SchemaPath $schemaPath
Assert-True $v.Valid "approve+important structurally valid"
Assert-True $v.Downgraded "approve+important downgraded flagged"
Assert-Eq $v.Normalized.verdict 'request_changes' "approve+important: NORMALIZED OBJECT verdict is request_changes"
Assert-True ($v.NormalizedJson -match '"verdict"\s*:\s*"request_changes"') "approve+important: NORMALIZED JSON carries the downgrade"

$apBlocking = '{"verdict":"approve","summary":"x","recommendations":[{"severity":"blocking","location":"l","issue":"i","suggestion":"s"}]}'
$vBlocking = Test-Verdict -Json $apBlocking -SchemaPath $schemaPath
Assert-True $vBlocking.Valid "approve+blocking structurally valid"
Assert-True $vBlocking.Downgraded "approve+blocking downgraded flagged"
Assert-Eq $vBlocking.Normalized.verdict 'request_changes' "approve+blocking: NORMALIZED OBJECT verdict is request_changes"
Assert-True ($vBlocking.NormalizedJson -match '"verdict"\s*:\s*"request_changes"') "approve+blocking: NORMALIZED JSON carries the downgrade"

$clean = Test-Verdict -Json '{"verdict":"approve","summary":"ok","recommendations":[]}' -SchemaPath $schemaPath
Assert-True ($clean.Valid -and -not $clean.Downgraded -and $clean.Normalized.verdict -eq 'approve') "clean approve untouched"
$garbage = Test-Verdict -Json 'not json' -SchemaPath $schemaPath
Assert-True (-not $garbage.Valid) "garbage invalid"

# Parameter-contract safety: -DisableSet (New-CodexArgs) and -CodexArgs (Get-InvocationAudit) are
# deliberately NOT [Parameter(Mandatory)] (see Assert-NoEmptyStringElements in lib.ps1) --
# Mandatory would let an array containing an empty string silently defeat the caller instead of
# failing closed. See Test-EmptyElementFailsClosed in helpers.ps1 for the full rationale and how
# this was verified to fail against the old [Parameter(Mandatory)][string[]] contract.
$libPathForContract = "$PSScriptRoot\..\codex-review\scripts\lib.ps1"
Test-EmptyElementFailsClosed -LibPath $libPathForContract `
    -CallExpression "New-CodexArgs -HarnessDir 'C:\h' -SchemaPath 'C:\s.json' -VerdictPath 'C:\v.json' -DisableSet @('apps', '', 'browser_use')" `
    -Name 'New-CodexArgs -DisableSet'
Test-EmptyElementFailsClosed -LibPath $libPathForContract `
    -CallExpression "Get-InvocationAudit -CodexArgs @('exec', '') -HarnessDir 'C:\h' -SchemaPath 'C:\s.json' -VerdictPath 'C:\v.json' -ExpectedDisable @('apps')" `
    -Name 'Get-InvocationAudit -CodexArgs'
# Get-InvocationAudit -ExpectedDisable: same shape, same fix, applied later than the three above
# (see task-14-report.md's "fourth identically-shaped case" concern) -- given the SAME contract
# here: Mandatory removed, Assert-NoEmptyStringElements added as an explicit first-line check.
Test-EmptyElementFailsClosed -LibPath $libPathForContract `
    -CallExpression "Get-InvocationAudit -CodexArgs @('exec', '-') -HarnessDir 'C:\h' -SchemaPath 'C:\s.json' -VerdictPath 'C:\v.json' -ExpectedDisable @('apps', '')" `
    -Name 'Get-InvocationAudit -ExpectedDisable'

Write-TestResult
