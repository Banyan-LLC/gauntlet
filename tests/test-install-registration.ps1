. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\..\mcp-registration.ps1"
# Register-GauntletMcp (install.ps1's Claude Code registration) against stub commands: a fake claude that keeps a
# user-scope store in its own JSON file (the same file the function reads as the Claude Code configuration) and can
# fail any chosen call, and a fake python whose launcher dependency check passes or fails. Nothing real is touched.

$fakeClaude = @'
$dir = $PSScriptRoot
$store = Join-Path $dir 'store.json'
Add-Content (Join-Path $dir 'calls.log') ($args -join ' | ')
$count = 1 + [int](Get-Content (Join-Path $dir 'count.txt') -ErrorAction SilentlyContinue)
Set-Content (Join-Path $dir 'count.txt') $count
$failAt = [int](Get-Content (Join-Path $dir 'fail-at.txt') -ErrorAction SilentlyContinue)
if ($count -eq $failAt) { exit 1 }
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

function New-Bench([hashtable]$Servers = @{}, [int]$FailAt = 0, [int]$CheckExit = 0) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("gauntlet-reg-" + [guid]::NewGuid().ToString('N'))
    $venvScripts = Join-Path $root 'gauntlet\mcp-venv\Scripts'
    New-Item -ItemType Directory -Force $venvScripts | Out-Null
    Set-Content (Join-Path $root 'claude.ps1') $fakeClaude
    Set-Content (Join-Path $venvScripts 'python.ps1') $fakePython
    if ($FailAt) { Set-Content (Join-Path $root 'fail-at.txt') $FailAt }
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

Write-TestResult
