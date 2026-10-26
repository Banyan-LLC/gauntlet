#Requires -Version 7
# Registers the collaborative servers with Claude Code at user scope through the launcher (docs/collaborative-mcp.md,
# "Global registration"). install.ps1 dot-sources this file; tests dot-source it with stub commands.

function New-GauntletMcpSkip([string]$Reason) {
    [pscustomobject]@{ Registered = $false; Reason = $Reason; Python = $null; StateRoot = $null }
}

function ConvertTo-GauntletCanonical($Value) {
    # A copy with every dictionary's keys sorted, so two definitions compare equal whatever their key order.
    if ($Value -is [System.Collections.IDictionary]) {
        $sorted = [ordered]@{}
        foreach ($key in ($Value.Keys | Sort-Object)) { $sorted[$key] = ConvertTo-GauntletCanonical $Value[$key] }
        return $sorted
    }
    if ($Value -is [System.Collections.IList]) { return , @(foreach ($item in $Value) { ConvertTo-GauntletCanonical $item }) }
    $Value
}

function Read-GauntletUserEntries([string]$ClaudeConfig, [string[]]$Names) {
    # The user-scope definitions of $Names in $ClaudeConfig: name -> @{ Raw (compact JSON in the file's own order, to
    # put back exactly); Canonical (sorted keys, to compare) }. Only a file that does not exist means no entries; any
    # other failure to read or parse it throws, whatever the caller's error preference, so an unreadable configuration
    # is never taken as proof that entries are absent or restored.
    $ErrorActionPreference = 'Stop'
    $found = @{}
    try { $text = [IO.File]::ReadAllText($ClaudeConfig) }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { return $found }
    $config = ConvertFrom-Json -InputObject $text -AsHashtable -ErrorAction Stop
    $servers = if ($config -is [System.Collections.IDictionary]) { $config['mcpServers'] } else { $null }
    if ($servers -is [System.Collections.IDictionary]) {
        foreach ($name in $Names) {
            if ($servers.Contains($name)) {
                $found[$name] = @{ Raw = ConvertTo-Json -InputObject $servers[$name] -Compress -Depth 32
                                   Canonical = ConvertTo-Json -InputObject (ConvertTo-GauntletCanonical $servers[$name]) -Compress -Depth 32 }
            }
        }
    }
    $found
}

function Get-GauntletClaudeProfile {
    # The user configuration the claude command reads and changes: <CLAUDE_CONFIG_DIR>/.claude.json when that is set,
    # else ~/.claude.json (seen with the CLI: an entry in a profile's .claude.json shows as "Scope: User config").
    $dir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { $HOME }
    [IO.Path]::GetFullPath((Join-Path $dir '.claude.json'))
}

function Write-GauntletBackupText([string]$Path, [string]$Text) {
    # One place that writes a backup's bytes (tests replace it to inject a failed or short write).
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Save-GauntletMcpBackup([string]$ClaudeConfig, [hashtable]$Definitions) {
    # Keeps original definitions that could not be put back in a new file only the current user can read, next to the
    # configuration, and returns its path once its content reads back exactly; $null when it could not be made
    # private or written (then nothing is left behind). Definitions can hold credentials, so they never go into a message.
    $ErrorActionPreference = 'Stop'                       # any failed step below fails the backup, whatever the caller's
    $path = "$ClaudeConfig.gauntlet-mcp-backup-$((Get-Date).ToString('yyyyMMddTHHmmssfff')).json"
    $created = $false
    try {
        $fs = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)   # never an existing file
        $fs.Dispose()
        $created = $true
        if ($IsWindows) {
            $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            & icacls $path /inheritance:r /grant:r "*${sid}:F" *> $null
            if ($LASTEXITCODE -ne 0) { throw "icacls exited $LASTEXITCODE" }
        } else {
            & chmod 600 $path
            if ($LASTEXITCODE -ne 0) { throw "chmod exited $LASTEXITCODE" }
        }
        $body = [ordered]@{}
        foreach ($name in ($Definitions.Keys | Sort-Object)) { $body[$name] = $Definitions[$name] | ConvertFrom-Json -AsHashtable }
        $text = ConvertTo-Json -InputObject $body -Depth 32
        Write-GauntletBackupText $path $text
        if ([IO.File]::ReadAllText($path) -cne $text) { throw 'the backup does not read back as written' }
        return $path
    } catch {
        if ($created) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        return $null
    }
}

function Register-GauntletMcp {
    <#
    Returns [pscustomobject]@{ Registered; Reason; Python; StateRoot }. Every check runs before the host is changed:
    the configuration read is the one the claude command changes (Get-GauntletClaudeProfile: CLAUDE_CONFIG_DIR's
    .claude.json, else ~/.claude.json; an explicit -ClaudeConfig must name that same file), the interpreter is resolved
    to an absolute path, the launcher's model-free dependency check (both servers' exact pins) passes in it, and the
    current user-scope definitions of both names are read. Then each name is replaced in turn and the result is read
    back. If any step fails (a refused or throwing command, or a read-back that fails or disagrees), the changes the
    command made are undone in reverse, the configuration is read back to check, and the function throws, naming any
    name that is not as it was; original definitions it could not put back (or could not check) are kept in a backup
    only the user can read, never in a message. No other host setting and no review store is touched.
    #>
    param(
        [string]$McpPython,
        [string]$StateRoot,
        [string]$Claude = 'claude',
        [string]$ClaudeConfig,
        [string[]]$DefaultPythons = @(
            $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Gauntlet\mcp-venv\Scripts\python.exe' }),
            (Join-Path $HOME '.local\share\gauntlet\mcp-venv\Scripts\python.exe'))
    )
    if (-not (Get-Command $Claude -ErrorAction SilentlyContinue)) { return New-GauntletMcpSkip "the $Claude command is not on PATH" }
    $effective = Get-GauntletClaudeProfile
    if ($ClaudeConfig) {                                  # an assertion about the profile, checked before anything is read
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not [string]::Equals([IO.Path]::GetFullPath($ClaudeConfig), $effective, $comparison)) {
            return New-GauntletMcpSkip "-ClaudeConfig $ClaudeConfig is not the configuration the $Claude command changes ($effective, from CLAUDE_CONFIG_DIR or the home folder); nothing was changed"
        }
    }
    $ClaudeConfig = $effective
    if (-not $McpPython) {
        $McpPython = $DefaultPythons | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
        if (-not $McpPython) { return New-GauntletMcpSkip 'no collaborative venv found; create one as docs/collaborative-mcp.md describes, then rerun with -McpPython <its python>' }
    }
    # An absolute filesystem path, resolved before anything uses it: the entry must work from every project.
    try { $McpPython = (Resolve-Path -LiteralPath $McpPython -ErrorAction Stop).ProviderPath }
    catch { return New-GauntletMcpSkip "-McpPython $McpPython does not exist" }
    if (-not (Test-Path -LiteralPath $McpPython -PathType Leaf)) { return New-GauntletMcpSkip "-McpPython $McpPython is not a file" }
    if (-not [IO.Path]::IsPathRooted($McpPython)) { return New-GauntletMcpSkip "-McpPython $McpPython did not resolve to an absolute path" }

    # The same model-free dependency checks both servers run at startup, exact pins included. Starts nothing.
    $checkOutput = & $McpPython -I -m gauntlet_review.launch check 2>&1
    if ($LASTEXITCODE -ne 0) {
        return New-GauntletMcpSkip "$McpPython failed the launcher's dependency check ($((($checkOutput | Out-String).Trim()))); install gauntlet-review[codex] from this checkout (docs/collaborative-mcp.md)"
    }

    if (-not $StateRoot) { $StateRoot = Join-Path (Split-Path (Split-Path (Split-Path $McpPython))) 'state' }
    if (-not [IO.Path]::IsPathRooted($StateRoot)) { throw "-StateRoot must be an absolute path" }
    $StateRoot = [IO.Path]::GetFullPath($StateRoot)

    # The current user-scope definitions, kept so a failed replacement can put them back exactly.
    $names = 'gauntlet-core', 'gauntlet-peer'
    try { $original = Read-GauntletUserEntries $ClaudeConfig $names }
    catch { return New-GauntletMcpSkip "cannot read $ClaudeConfig to keep its current entries ($($_.Exception.Message))" }
    $entries = @{}
    foreach ($role in 'core', 'peer') {
        $entries["gauntlet-$role"] = [ordered]@{ type = 'stdio'; command = $McpPython; env = @{}
            args = @('-I', '-m', 'gauntlet_review.launch', $role, '--state-root', $StateRoot) }
    }

    $failure = $null
    $done = [System.Collections.Generic.List[object]]::new()   # the changes the CLI made, so a rollback undoes only those
    try {
        foreach ($name in $names) {
            if ($original.ContainsKey($name)) {
                & $Claude mcp remove $name -s user *> $null
                if ($LASTEXITCODE -ne 0) { $failure = "removing the existing $name failed"; break }
                $done.Add(@{ Name = $name; Step = 'removed' })
            }
            & $Claude mcp add-json $name (ConvertTo-Json -InputObject $entries[$name] -Compress -Depth 32) -s user *> $null
            if ($LASTEXITCODE -ne 0) { $failure = "adding the new $name failed"; break }
            $done.Add(@{ Name = $name; Step = 'added' })
        }
    } catch {                                             # a command that throws (or cannot start) is a failure like any other
        $failure = "running the $Claude command failed ($($_.Exception.GetType().Name))"
    }
    if (-not $failure) {                                 # the CLI said yes: the configuration must show it
        try {
            $after = Read-GauntletUserEntries $ClaudeConfig $names
            $missing = @($names | Where-Object {
                -not $after.ContainsKey($_) -or $after[$_].Canonical -ne (ConvertTo-Json -InputObject (ConvertTo-GauntletCanonical $entries[$_]) -Compress -Depth 32) })
            if ($missing) { $failure = "$ClaudeConfig does not show the new $($missing -join ' and ')" }
        } catch { $failure = "$ClaudeConfig could not be read back to check the new entries" }
    }
    if ($failure) {
        for ($i = $done.Count - 1; $i -ge 0; $i--) {      # undo in reverse; never touch a name the CLI did not change
            $step = $done[$i]
            try {
                if ($step.Step -eq 'added') { & $Claude mcp remove $step.Name -s user *> $null }
                else { & $Claude mcp add-json $step.Name $original[$step.Name].Raw -s user *> $null }
            } catch { }                                   # a throwing undo is judged, like every other, by the read-back below
        }
        $checked = $true
        try {
            $after = Read-GauntletUserEntries $ClaudeConfig $names
            $unrestored = @($names | Where-Object {
                $was = if ($original.ContainsKey($_)) { $original[$_].Canonical } else { $null }
                $now = if ($after.ContainsKey($_)) { $after[$_].Canonical } else { $null }
                $was -ne $now })
        } catch { $checked = $false; $unrestored = $names }
        if (-not $unrestored) { throw "Claude Code MCP registration failed: $failure; both entries are back as they were" }
        $state = "$($unrestored -join ' and ') " + $(if ($checked) { 'could not be put back' } else { "could not be checked: $ClaudeConfig cannot be read back" })
        $lost = @{}
        foreach ($name in $unrestored) { if ($original.ContainsKey($name)) { $lost[$name] = $original[$name].Raw } }
        if ($lost.Count) {
            $backup = Save-GauntletMcpBackup $ClaudeConfig $lost
            $state += if ($backup) { "; their original definitions are in $backup (readable by you only)" }
                      else { '; their original definitions could not be saved privately, so they are not shown' }
        }
        throw "Claude Code MCP registration failed: $failure; $state"
    }
    [pscustomobject]@{ Registered = $true; Reason = $null; Python = $McpPython; StateRoot = $StateRoot }
}
