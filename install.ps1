#Requires -Version 7
$src = $PSScriptRoot
. "$src\codex-review\scripts\lib.ps1"
# Installation is a gate too: it uses the SAME selection policy and stack-identity manifest a
# review round checks, so "valid at install" means the recorded CLI/schema/AGENTS.md/invocation-
# profile binding actually matches what rounds will run -- catching a broken or drifted reviewer
# stack now rather than at the first review.
try { $instCli = Select-CodexCli -Candidates (Get-CodexCandidates) } catch {
    Write-Error "refusing to install: no usable Codex CLI ($($_.Exception.Message))"; exit 1
}
$instProfile = Get-InvocationProfileHash -DisableSet (Get-DisableSet -FeatureNames $instCli.FeatureNames)
$pm = Test-PremiseManifest -SkillRoot "$src\codex-review" -ActualCli $instCli `
    -InvocationProfileHash $instProfile
if (-not $pm.Valid) {
    # Two distinct self-serve causes as of the live-evidence gate (see task-14-report.md): stack
    # drift is fixed by calibrate-premises.ps1 alone, but missing/stale live evidence is NOT --
    # calibration only proves the stack ACCEPTED, never LIVE-VERIFIED, and always drops the whole
    # live_evidence object, so both live gates must be rerun too. live_evidence now carries TWO
    # independently fingerprinted sub-records (schema_gate, security_battery -- FINDING 2, see
    # task-14-report.md); $pm.Reason above already names the SPECIFIC gate to rerun when only one
    # of the two is missing or stale.
    Write-Error "refusing to install: $($pm.Reason). Stack-identity drift (CLI/schema/AGENTS.md/invocation profile): run scripts/calibrate-premises.ps1 first. Missing or stale live evidence: rerun the specific live gate named above (tests/live/live-schema-gate.ps1 and/or tests/live/live-security.ps1) first."
    exit 1
}
$dst = "$env:USERPROFILE\.claude\skills"
New-Item -ItemType Directory -Force $dst | Out-Null
foreach ($skill in 'codex-review','codex-reviewed-dev') {
    if (Test-Path "$dst\$skill") { Remove-Item -Recurse -Force "$dst\$skill" }
    Copy-Item -Recurse "$src\$skill" "$dst\$skill"
    Write-Host "installed $skill -> $dst\$skill"
}
$claudeMd = "$env:USERPROFILE\.claude\CLAUDE.md"
$pointer = 'Substantial feature tasks follow the codex-reviewed-dev pipeline (Codex review gates on spec, plan, and PR) unless the user opts out with "skip codex review".'
if (-not (Test-Path $claudeMd) -or -not ((Get-Content -Raw $claudeMd) -match [regex]::Escape('codex-reviewed-dev pipeline'))) {
    Add-Content -Path $claudeMd -Value "`n$pointer"
    Write-Host "appended pointer to $claudeMd"
} else { Write-Host "pointer already present" }
