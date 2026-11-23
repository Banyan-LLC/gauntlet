<#
Prints the Python and state root of the active Claude Code profile's user-scope gauntlet-peer registration as one
JSON line, {"python": ..., "state_root": ...}, and exits 0. Otherwise prints one line naming the profile file it read
and exits 1.

The active profile follows the installer's rule (Get-GauntletClaudeProfile in mcp-registration.ps1):
<CLAUDE_CONFIG_DIR>/.claude.json when CLAUDE_CONFIG_DIR is set, else <HomeDir>/.claude.json. It never falls back to
the other profile, so it never reports a registration the running Claude Code does not use. Nothing is changed.
#>
param([string]$HomeDir = $HOME)
$ErrorActionPreference = 'Stop'

$dir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { $HomeDir }
$configFile = [IO.Path]::GetFullPath((Join-Path $dir '.claude.json'))
try {
    $config = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($configFile)) -AsHashtable
} catch {
    Write-Output "Cannot read the Claude Code profile $($configFile): $($_.Exception.Message)"
    exit 1
}
$servers = if ($config -is [System.Collections.IDictionary]) { $config['mcpServers'] } else { $null }
$entry = if ($servers -is [System.Collections.IDictionary]) { $servers['gauntlet-peer'] } else { $null }
$arguments = [object[]]@()       # assigned apart from the test: an `if` that yields @() would give $null
if ($entry -is [System.Collections.IDictionary] -and $null -ne $entry['args']) { $arguments = [object[]]@($entry['args']) }
$index = [array]::IndexOf($arguments, '--state-root')
if (-not ($entry -is [System.Collections.IDictionary]) -or -not ($entry['command'] -is [string]) -or
        $index -lt 0 -or $index + 1 -ge $arguments.Count) {
    Write-Output "No usable user-scope gauntlet-peer registration in $($configFile)."
    exit 1
}
[pscustomobject]@{ python = $entry['command']; state_root = [string]$arguments[$index + 1] } | ConvertTo-Json -Compress
exit 0
