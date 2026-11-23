. "$PSScriptRoot\helpers.ps1"
# gauntlet-model/registration.ps1 finds the active Claude Code profile's gauntlet-peer registration the way the
# installer does (Get-GauntletClaudeProfile): CLAUDE_CONFIG_DIR when set, else the home folder, never the other one.
# Fixture profiles only; the real configuration is never read.

$script = Join-Path $PSScriptRoot '..\gauntlet-model\registration.ps1'
$savedConfigDir = $env:CLAUDE_CONFIG_DIR
$work = Join-Path ([IO.Path]::GetTempPath()) ("gauntlet-model-registration-" + [guid]::NewGuid().ToString('N'))

function Write-PeerProfile([string]$Dir, [string]$Python, [string]$Root) {
    New-Item -ItemType Directory -Force $Dir | Out-Null
    $entry = @{ type = 'stdio'; command = $Python
                args = @('-I', '-m', 'gauntlet_review.launch', 'peer', '--state-root', $Root, '--timeout-seconds', '1800') }
    @{ mcpServers = @{ 'gauntlet-peer' = $entry } } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Dir '.claude.json')
}

function Invoke-Registration([string]$HomeDir) {
    $output = @(& pwsh -NoProfile -File $script -HomeDir $HomeDir)
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($output -join "`n") }
}

try {
    $homeDir = Join-Path $work 'home'
    $customDir = Join-Path $work 'custom'
    $emptyDir = Join-Path $work 'empty'
    $brokenDir = Join-Path $work 'broken'
    $absentDir = Join-Path $work 'absent'
    Write-PeerProfile $homeDir 'C:\home\python.exe' 'C:\home\state'
    Write-PeerProfile $customDir 'C:\custom\python.exe' 'C:\custom\state'
    New-Item -ItemType Directory -Force $emptyDir, $brokenDir, $absentDir | Out-Null
    Set-Content (Join-Path $emptyDir '.claude.json') '{"mcpServers":{"gauntlet-core":{"command":"x","args":[]}}}'
    Set-Content (Join-Path $brokenDir '.claude.json') '{broken'

    $env:CLAUDE_CONFIG_DIR = $customDir
    $result = Invoke-Registration $homeDir
    Assert-Eq $result.Code 0 "CLAUDE_CONFIG_DIR profile is read"
    $found = $result.Text | ConvertFrom-Json
    Assert-Eq $found.python 'C:\custom\python.exe' "the custom profile's python is used"
    Assert-Eq $found.state_root 'C:\custom\state' "the custom profile's state root is used"

    Remove-Item Env:CLAUDE_CONFIG_DIR
    $result = Invoke-Registration $homeDir
    Assert-Eq $result.Code 0 "the home profile is read without CLAUDE_CONFIG_DIR"
    $found = $result.Text | ConvertFrom-Json
    Assert-Eq $found.python 'C:\home\python.exe' "the home profile's python is used"
    Assert-Eq $found.state_root 'C:\home\state' "the home profile's state root is used"

    $env:CLAUDE_CONFIG_DIR = $emptyDir
    $result = Invoke-Registration $homeDir
    Assert-Eq $result.Code 1 "a profile without gauntlet-peer is refused"
    Assert-True ($result.Text.Contains((Join-Path $emptyDir '.claude.json'))) "the refusal names the active profile file"
    Assert-True (-not $result.Text.Contains('C:\home')) "there is no fallback to the home profile"

    $env:CLAUDE_CONFIG_DIR = $brokenDir
    $result = Invoke-Registration $homeDir
    Assert-Eq $result.Code 1 "an unparseable profile is refused"
    Assert-True (-not $result.Text.Contains('C:\home')) "an unparseable profile does not fall back"

    $env:CLAUDE_CONFIG_DIR = $absentDir
    $result = Invoke-Registration $homeDir
    Assert-Eq $result.Code 1 "a missing profile file is refused"
} finally {
    if ($null -eq $savedConfigDir) { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
    else { $env:CLAUDE_CONFIG_DIR = $savedConfigDir }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-TestResult
