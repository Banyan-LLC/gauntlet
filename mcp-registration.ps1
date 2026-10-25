#Requires -Version 7
# Registers the collaborative servers with Claude Code at user scope through the launcher (docs/collaborative-mcp.md,
# "Global registration"). install.ps1 dot-sources this file; tests dot-source it with stub commands.

function New-GauntletMcpSkip([string]$Reason) {
    [pscustomobject]@{ Registered = $false; Reason = $Reason; Python = $null; StateRoot = $null }
}

function Register-GauntletMcp {
    <#
    Returns [pscustomobject]@{ Registered; Reason; Python; StateRoot }. Every check runs before the host is changed:
    the interpreter is resolved to an absolute path, the launcher's model-free dependency check (both servers' exact
    pins) passes in it, and the current user-scope definitions of both names are read from the Claude Code user
    configuration. Then each name is replaced in turn; if any step fails, both names are put back exactly as they
    were (absent, or their original definition) and the function throws, naming any name it could not restore.
    No other host setting and no review store is touched.
    #>
    param(
        [string]$McpPython,
        [string]$StateRoot,
        [string]$Claude = 'claude',
        [string]$ClaudeConfig = (Join-Path $HOME '.claude.json'),
        [string[]]$DefaultPythons = @(
            $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Gauntlet\mcp-venv\Scripts\python.exe' }),
            (Join-Path $HOME '.local\share\gauntlet\mcp-venv\Scripts\python.exe'))
    )
    if (-not (Get-Command $Claude -ErrorAction SilentlyContinue)) { return New-GauntletMcpSkip "the $Claude command is not on PATH" }
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
    $original = @{}
    if (Test-Path -LiteralPath $ClaudeConfig) {
        try { $config = Get-Content -Raw -LiteralPath $ClaudeConfig | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch { return New-GauntletMcpSkip "cannot read $ClaudeConfig to keep its current entries ($($_.Exception.Message))" }
        $servers = if ($config -is [System.Collections.IDictionary]) { $config['mcpServers'] } else { $null }
        if ($servers -is [System.Collections.IDictionary]) {
            foreach ($name in $names) {
                if ($servers.Contains($name)) { $original[$name] = $servers[$name] | ConvertTo-Json -Compress -Depth 32 }
            }
        }
    }
    $entries = @{}
    foreach ($role in 'core', 'peer') {
        $entries["gauntlet-$role"] = [ordered]@{ type = 'stdio'; command = $McpPython; env = @{}
            args = @('-I', '-m', 'gauntlet_review.launch', $role, '--state-root', $StateRoot) } | ConvertTo-Json -Compress
    }

    $failure = $null
    foreach ($name in $names) {
        if ($original.ContainsKey($name)) {
            & $Claude mcp remove $name -s user *> $null
            if ($LASTEXITCODE -ne 0) { $failure = "removing the existing $name failed"; break }
        }
        & $Claude mcp add-json $name $entries[$name] -s user *> $null
        if ($LASTEXITCODE -ne 0) { $failure = "adding the new $name failed"; break }
    }
    if ($failure) {
        $unrestored = @()
        foreach ($name in $names) {
            & $Claude mcp remove $name -s user *> $null        # it may already be absent
            if ($original.ContainsKey($name)) {
                & $Claude mcp add-json $name $original[$name] -s user *> $null
                if ($LASTEXITCODE -ne 0) { $unrestored += $name }
            }
        }
        $state = if ($unrestored) { "could not restore $($unrestored -join ' and '); their definitions were: " +
                     (($unrestored | ForEach-Object { "$_ = $($original[$_])" }) -join '; ') }
                 else { 'both entries are back as they were' }
        throw "Claude Code MCP registration failed: $failure; $state"
    }
    [pscustomobject]@{ Registered = $true; Reason = $null; Python = $McpPython; StateRoot = $StateRoot }
}
