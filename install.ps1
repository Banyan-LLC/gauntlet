#Requires -Version 7
param(
    # Leave every host configuration untouched: do not register the collaborative servers with Claude Code.
    [switch]$SkipMcpRegistration,
    # The python of the venv that holds gauntlet-review[codex] from this checkout (default: the first of
    # %LOCALAPPDATA%\Gauntlet\mcp-venv and ~\.local\share\gauntlet\mcp-venv that exists).
    [string]$McpPython,
    # Where the launcher keeps one private review store per checkout and ref pair (default: 'state' beside the venv).
    [string]$StateRoot,
    # Optional confirmation of the Claude Code configuration the claude command changes (<CLAUDE_CONFIG_DIR>\.claude.json,
    # else ~\.claude.json); any other path stops the registration before any change.
    [string]$ClaudeConfig
)
$src = $PSScriptRoot
. "$src\gauntlet-review\scripts\lib.ps1"
# Installation is a gate too: it uses the SAME selection policy and stack-identity manifest a
# review round checks, so "valid at install" means the recorded CLI/schema/AGENTS.md/invocation-
# profile binding actually matches what rounds will run -- catching a broken or drifted reviewer
# stack now rather than at the first review.
try { $instCli = Select-CodexCli -Candidates (Get-CodexCandidates) } catch {
    Write-Error "refusing to install: no usable Codex CLI ($($_.Exception.Message))"; exit 1
}
$instProfile = Get-InvocationProfileHash -DisableSet (Get-DisableSet -FeatureNames $instCli.FeatureNames)
# Deliberately NO -AllowProvenanceOnlyGateSources (P1 fix, see docs/build-log/task-14-report.md,
# FINDING 1b): this script always runs from the SOURCE repo, where the gate sources
# (tests\helpers.ps1, tests\live\live-schema-gate.ps1, tests\live\live-security.ps1) are expected
# to be genuinely present -- so this call is strict/default mode. A source tree with even one gate
# source missing or renamed must refuse here, not be silently treated as an installed tree.
$pm = Test-PremiseManifest -SkillRoot "$src\gauntlet-review" -ActualCli $instCli `
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
foreach ($skill in 'gauntlet-review','gauntlet-dev') {
    if (Test-Path "$dst\$skill") { Remove-Item -Recurse -Force "$dst\$skill" }
    Copy-Item -Recurse "$src\$skill" "$dst\$skill"
    Write-Host "installed $skill -> $dst\$skill"
}
$claudeMd = "$env:USERPROFILE\.claude\CLAUDE.md"
$pointer = 'Substantial feature tasks follow the gauntlet-dev pipeline (Codex review gates on spec, plan, and PR) unless the user opts out with "skip codex review".'
if (-not (Test-Path $claudeMd) -or -not ((Get-Content -Raw $claudeMd) -match [regex]::Escape('gauntlet-dev pipeline'))) {
    Add-Content -Path $claudeMd -Value "`n$pointer"
    Write-Host "appended pointer to $claudeMd"
} else { Write-Host "pointer already present" }

# Collaborative route (docs/collaborative-mcp.md, "Global registration"): one user-scope Claude Code registration
# of each server, through the launcher, which binds every session to the checkout and branch it starts in. A
# project or local entry with the same name still takes precedence. Anything missing, or a -ClaudeConfig that is not
# the claude command's configuration, skips this step with a warning; a failed replacement undoes its changes, checks
# the result and stops the install, naming any entry that is not as it was.
if ($SkipMcpRegistration) { Write-Host "skipped Claude Code MCP registration (-SkipMcpRegistration)"; return }
. "$src\mcp-registration.ps1"
$registrationArgs = @{ McpPython = $McpPython; StateRoot = $StateRoot }
if ($ClaudeConfig) { $registrationArgs.ClaudeConfig = $ClaudeConfig }
try { $registration = Register-GauntletMcp @registrationArgs }
catch { Write-Error $_.Exception.Message; exit 1 }
if ($registration.Registered) {
    Write-Host "registered gauntlet-core and gauntlet-peer with Claude Code (user scope, $($registration.Python), review state under $($registration.StateRoot)); start a new session to load them"
} else {
    Write-Warning "skipped Claude Code MCP registration: $($registration.Reason)"
}
