. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\..\mcp-registration.ps1"
# Register-GauntletMcp (install.ps1's Claude Code registration) against stub commands: a fake claude that keeps a
# user-scope store in its own JSON file (the same file the function reads as the Claude Code configuration) and can
# fail any chosen call, and a fake python whose launcher dependency check passes or fails. Nothing real is touched.

$fakeClaude = @'
$dir = $PSScriptRoot
# Like the real CLI, CLAUDE_CONFIG_DIR moves the profile it changes.
$store = if ($env:CLAUDE_CONFIG_DIR) { Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json' } else { Join-Path $dir 'store.json' }
Add-Content (Join-Path $dir 'calls.log') ($args -join ' | ')
$count = 1 + [int](Get-Content (Join-Path $dir 'count.txt') -ErrorAction SilentlyContinue)
Set-Content (Join-Path $dir 'count.txt') $count
$failAt = @(Get-Content (Join-Path $dir 'fail-at.txt') -ErrorAction SilentlyContinue | ForEach-Object { [int]$_ })
if ($failAt -contains $count) { exit 1 }
if (Test-Path (Join-Path $dir 'no-write.txt')) { exit 0 }     # says yes and changes nothing (another profile, say)
$cfg = Get-Content -Raw $store | ConvertFrom-Json -AsHashtable
if (-not $cfg.Contains('mcpServers')) { $cfg['mcpServers'] = @{} }
switch ($args[1]) {
    'add-json' { if ($cfg.mcpServers.Contains($args[2])) { exit 1 }; $cfg.mcpServers[$args[2]] = ($args[3] | ConvertFrom-Json -AsHashtable) }
    'remove'   { if (-not $cfg.mcpServers.Contains($args[2])) { exit 1 }; $cfg.mcpServers.Remove($args[2]) }
    default    { exit 2 }
}
$cfg | ConvertTo-Json -Depth 32 | Set-Content $store
exit 0
'@
$fakePython = @'
Add-Content (Join-Path $PSScriptRoot 'python-calls.log') ($args -join ' ')
$code = [int](Get-Content (Join-Path $PSScriptRoot 'check-exit.txt') -ErrorAction SilentlyContinue)
if ($code) { Write-Output '{"code":"UNSUPPORTED_EXTRA","operation":"launch"}' }
exit $code
'@

function New-Bench([hashtable]$Servers = @{}, [int[]]$FailAt = @(), [int]$CheckExit = 0) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("gauntlet-reg-" + [guid]::NewGuid().ToString('N'))
    $venvScripts = Join-Path $root 'gauntlet\mcp-venv\Scripts'
    New-Item -ItemType Directory -Force $venvScripts | Out-Null
    Set-Content (Join-Path $root 'claude.ps1') $fakeClaude
    Set-Content (Join-Path $venvScripts 'python.ps1') $fakePython
    if ($FailAt) { Set-Content (Join-Path $root 'fail-at.txt') ($FailAt | ForEach-Object { "$_" }) }
    if ($CheckExit) { Set-Content (Join-Path $venvScripts 'check-exit.txt') $CheckExit }
    $store = [ordered]@{ numStartups = 7; projects = @{ 'C:/work/x' = @{ mcpServers = @{} } }
                         mcpServers = [ordered]@{ other = @{ type = 'stdio'; command = 'other.exe'; args = @('--x'); env = @{} } } }
    foreach ($k in $Servers.Keys) { $store.mcpServers[$k] = $Servers[$k] }
    $store | ConvertTo-Json -Depth 32 | Set-Content (Join-Path $root 'store.json')
    [pscustomobject]@{ Root = $root; Claude = (Join-Path $root 'claude.ps1'); Config = (Join-Path $root 'store.json')
                       Python = (Join-Path $venvScripts 'python.ps1'); Calls = (Join-Path $root 'calls.log') }
}
function Get-Store($Bench) { Get-Content -Raw $Bench.Config | ConvertFrom-Json -AsHashtable }
function Get-Calls($Bench) { if (Test-Path $Bench.Calls) { @(Get-Content $Bench.Calls) } else { @() } }
function Get-Entries($Servers) {      # each server's definition as compact JSON, by name: independent of key order
    $out = [ordered]@{}
    foreach ($name in ($Servers.Keys | Sort-Object)) { $out[$name] = $Servers[$name] | ConvertTo-Json -Depth 32 -Compress }
    ($out.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"
}

$oldCore = @{ type = 'stdio'; command = 'C:\old\python.exe'; args = @('-m', 'gauntlet_review.collaborative', '--repo', 'C:\w'); env = @{ KEEP = '1' } }
$oldPeer = @{ type = 'stdio'; command = 'C:\old\python.exe'; args = @('-m', 'gauntlet_review.codex_bridge', '--repo', 'C:\w'); env = @{} }
$originals = @{ 'gauntlet-core' = $oldCore; 'gauntlet-peer' = $oldPeer }

# A fresh registration: both entries point at the absolute interpreter and the launcher, with the default state root.
$b = New-Bench
$r = Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config
Assert-True $r.Registered "fresh registration succeeds"
$s = Get-Store $b
Assert-Eq $s.mcpServers['gauntlet-core'].command $b.Python "core command is the interpreter"
Assert-Eq ($s.mcpServers['gauntlet-core'].args -join ' ') "-I -m gauntlet_review.launch core --state-root $(Join-Path $b.Root 'gauntlet\state')" "core launcher args with the default state root"
Assert-Eq ($s.mcpServers['gauntlet-peer'].args[3]) 'peer' "peer runs the launcher's peer role"
Assert-Eq $s.mcpServers['other'].command 'other.exe' "an unrelated server is untouched"
Assert-Eq $s.numStartups 7 "unrelated settings are untouched"
Assert-Eq (Get-Content (Join-Path (Split-Path $b.Python) 'python-calls.log')) '-I -m gauntlet_review.launch check' "the dependency check ran first"

# Replacing existing entries succeeds and drops the old definitions.
$b = New-Bench -Servers $originals
$r = Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config
Assert-True $r.Registered "replacement succeeds"
Assert-Eq (Get-Store $b).mcpServers['gauntlet-core'].args[2] 'gauntlet_review.launch' "core replaced"
$calls = Get-Calls $b
Assert-Eq $calls.Count 4 "four mutations for a replacement"
Assert-True ($calls[0] -like 'mcp | remove | gauntlet-core | *' -and $calls[1] -like 'mcp | add-json | gauntlet-core | *' -and
             $calls[2] -like 'mcp | remove | gauntlet-peer | *' -and $calls[3] -like 'mcp | add-json | gauntlet-peer | *') "each name is replaced in turn"

# A failure at any mutation puts both entries back exactly as they were, and says so.
foreach ($failAt in 1, 2, 3, 4) {
    $b = New-Bench -Servers $originals -FailAt $failAt
    $before = Get-Entries (Get-Store $b).mcpServers
    $message = $null
    try { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'both entries are back as they were') "failure at mutation $failAt reports the rollback"
    $after = Get-Store $b
    Assert-Eq (Get-Entries $after.mcpServers) $before "failure at mutation $failAt restores both originals"
    Assert-Eq $after.mcpServers['gauntlet-core'].env.KEEP '1' "failure at mutation $failAt keeps the original environment"
    Assert-Eq $after.numStartups 7 "failure at mutation $failAt leaves other settings alone"
}
# With no previous entries, a failed second add leaves neither name behind (no mixed pair).
$b = New-Bench -FailAt 2
$message = $null
try { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config | Out-Null } catch { $message = $_.Exception.Message }
Assert-True ($message -match 'adding the new gauntlet-peer failed') "failed second add is named"
$after = Get-Store $b
Assert-True (-not $after.mcpServers.Contains('gauntlet-core') -and -not $after.mcpServers.Contains('gauntlet-peer')) "no half-registered pair is left"

# A failing dependency check (missing or unsupported pins) changes nothing.
$b = New-Bench -Servers $originals -CheckExit 2
$before = Get-Content -Raw $b.Config
$r = Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config
Assert-True (-not $r.Registered) "a failed dependency check skips registration"
Assert-True ($r.Reason -match 'UNSUPPORTED_EXTRA') "the check's code is reported"
Assert-Eq (Get-Calls $b).Count 0 "no host mutation after a failed check"
Assert-Eq (Get-Content -Raw $b.Config) $before "the configuration is unchanged"

# A relative -McpPython is resolved to an absolute path that still works from another folder.
$b = New-Bench
Push-Location (Split-Path $b.Python)
try { $r = Register-GauntletMcp -McpPython '.\python.ps1' -Claude $b.Claude -ClaudeConfig $b.Config } finally { Pop-Location }
Assert-True $r.Registered "relative interpreter registers"
$command = (Get-Store $b).mcpServers['gauntlet-core'].command
Assert-True ([IO.Path]::IsPathRooted($command)) "the stored command is absolute"
Push-Location ([IO.Path]::GetTempPath())
try { Assert-True (Test-Path -LiteralPath $command -PathType Leaf) "the stored command resolves from another folder" } finally { Pop-Location }
Assert-Eq ((Get-Store $b).mcpServers['gauntlet-core'].args[5]) (Join-Path $b.Root 'gauntlet\state') "default state root from the resolved interpreter"

# Missing pieces skip without touching anything.
$b = New-Bench -Servers $originals
$before = Get-Content -Raw $b.Config
$r = Register-GauntletMcp -McpPython $b.Python -Claude 'no-such-claude-command-1f2e' -ClaudeConfig $b.Config
Assert-True (-not $r.Registered -and $r.Reason -match 'not on PATH') "a missing claude command skips"
$r = Register-GauntletMcp -McpPython (Join-Path $b.Root 'nope\python.exe') -Claude $b.Claude -ClaudeConfig $b.Config
Assert-True (-not $r.Registered -and $r.Reason -match 'does not exist') "a missing interpreter skips"
$r = Register-GauntletMcp -Claude $b.Claude -ClaudeConfig $b.Config -DefaultPythons @((Join-Path $b.Root 'none.exe'))
Assert-True (-not $r.Registered -and $r.Reason -match 'no collaborative venv') "no default venv skips"
Set-Content $b.Config '{not json'
$r = Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config
Assert-True (-not $r.Registered -and $r.Reason -match 'cannot read') "an unreadable configuration skips"
Assert-Eq (Get-Calls $b).Count 0 "no host mutation for any skip"
Assert-Throws { Register-GauntletMcp -McpPython $b.Python -StateRoot 'relative\state' -Claude $b.Claude -ClaudeConfig (Join-Path $b.Root 'absent.json') } "a relative -StateRoot is refused"

# R2-F1: with CLAUDE_CONFIG_DIR set the CLI changes another profile than the default configuration. Without -ClaudeConfig
# nothing is read or changed; naming that profile registers there; a wrong -ClaudeConfig never costs the real entries.
$b = New-Bench
$profileDir = Join-Path $b.Root 'profile'
New-Item -ItemType Directory $profileDir | Out-Null
$profileStore = Join-Path $profileDir '.claude.json'
[ordered]@{ mcpServers = [ordered]@{ 'gauntlet-core' = $oldCore; 'gauntlet-peer' = $oldPeer } } | ConvertTo-Json -Depth 32 | Set-Content $profileStore
$homeBefore = Get-Content -Raw $b.Config
$profileBefore = Get-Content -Raw $profileStore
$savedDir = $env:CLAUDE_CONFIG_DIR
try {
    $env:CLAUDE_CONFIG_DIR = $profileDir
    $r = Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude
    Assert-True (-not $r.Registered -and $r.Reason -match 'CLAUDE_CONFIG_DIR') "an override without -ClaudeConfig is refused"
    Assert-Eq (Get-Calls $b).Count 0 "no host change while the profile is unconfirmed"
    Assert-Eq (Get-Content -Raw $profileStore) $profileBefore "the custom profile is untouched by the refusal"
    $message = $null
    try { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'adding the new gauntlet-core failed') "a wrong -ClaudeConfig fails at the first add"
    Assert-Eq (Get-Entries (Get-Content -Raw $profileStore | ConvertFrom-Json -AsHashtable).mcpServers) (Get-Entries ($profileBefore | ConvertFrom-Json -AsHashtable).mcpServers) "a wrong -ClaudeConfig removes no real entry"
    Remove-Item (Join-Path $b.Root 'calls.log')
    $r = Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $profileStore
    Assert-True $r.Registered "naming the profile registers"
    Assert-Eq ((Get-Content -Raw $profileStore | ConvertFrom-Json -AsHashtable).mcpServers['gauntlet-peer'].args[3]) 'peer' "the profile holds the new entries"
    Assert-Eq (Get-Content -Raw $b.Config) $homeBefore "the home configuration is never touched"
} finally { $env:CLAUDE_CONFIG_DIR = $savedDir }

# R2-F2: a forward failure and then a rollback failure are reported as they are, decided by reading the result back.
$b = New-Bench -FailAt 2, 3                       # add core, add peer fails, removing the new core fails too
$message = $null
try { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config | Out-Null } catch { $message = $_.Exception.Message }
Assert-True ($message -notmatch 'both entries are back') "an incomplete rollback is never reported as complete"
Assert-True ($message -match 'gauntlet-core could not be put back') "the entry left behind is named"
Assert-True ((Get-Store $b).mcpServers.Contains('gauntlet-core')) "the stub really kept the new core (the report matches the state)"
$b = New-Bench -Servers $originals -FailAt 4, 5   # with originals: add peer fails, putting back the old peer fails
$message = $null
try { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config | Out-Null } catch { $message = $_.Exception.Message }
$after = Get-Store $b
Assert-True ($message -match '^Claude Code MCP registration failed: adding the new gauntlet-peer failed; gauntlet-peer could not be put back') "only the peer is reported: $message"
Assert-Eq (ConvertTo-Json -InputObject (ConvertTo-GauntletCanonical $after.mcpServers['gauntlet-core']) -Depth 32 -Compress) (ConvertTo-Json -InputObject (ConvertTo-GauntletCanonical $oldCore) -Depth 32 -Compress) "the core is back as it was"

# R2-F3: original definitions never appear in a message; the ones not put back are kept in a backup only the user reads.
$secretCore = @{ type = 'stdio'; command = 'C:\old\python.exe'; args = @('--token', 'arg-secret-marker'); env = @{ TOKEN = 'fixture-secret-marker' } }
$b = New-Bench -Servers @{ 'gauntlet-core' = $secretCore; 'gauntlet-peer' = $oldPeer } -FailAt 2, 3   # add core fails; putting back the old core fails
$message = $null
try { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config | Out-Null } catch { $message = $_.Exception.Message }
Assert-True ($message -notmatch 'secret-marker') "no original value appears in the message"
Assert-True ($message -match 'gauntlet-core could not be put back') "the unrestored name is reported"
$backup = if ($message -match 'definitions are in (\S+) \(readable by you only\)') { $Matches[1] } else { $null }
Assert-True ($backup -and (Test-Path -LiteralPath $backup)) "the backup's path is reported and the file exists"
if ($backup) {
    $kept = Get-Content -Raw -LiteralPath $backup | ConvertFrom-Json -AsHashtable
    Assert-Eq $kept['gauntlet-core'].env.TOKEN 'fixture-secret-marker' "the backup holds the original definition"
    if ($IsWindows) {
        $acl = Get-Acl -LiteralPath $backup
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $rules = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value })
        Assert-True ($acl.AreAccessRulesProtected -and $rules.Count -eq 1 -and $rules[0] -eq $sid) "the backup is readable by the user alone"
    }
}

# A CLI that says yes but changes nothing (it uses another profile) is caught by the read-back, not reported as success.
$b = New-Bench
Set-Content (Join-Path $b.Root 'no-write.txt') 'x'
$message = $null
try { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config | Out-Null } catch { $message = $_.Exception.Message }
Assert-True ($message -match 'does not show the new gauntlet-core and gauntlet-peer') "registration is checked by reading the configuration back"

Write-TestResult
