. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\..\mcp-registration.ps1"
# Register-GauntletMcp (install.ps1's Claude Code registration) against stub commands: a fake claude that keeps a
# user-scope store in <CLAUDE_CONFIG_DIR>/.claude.json, as the real CLI does (each bench points CLAUDE_CONFIG_DIR at its
# own folder, so the real home configuration is never read or changed), and can fail, throw or skip writing at any
# chosen call; and a fake python whose launcher dependency check passes or fails. Nothing real is touched.

$fakeClaude = @'
$dir = $PSScriptRoot
$store = Join-Path $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { $dir }) '.claude.json'
Add-Content (Join-Path $dir 'calls.log') ($args -join ' | ')
$count = 1 + [int](Get-Content (Join-Path $dir 'count.txt') -ErrorAction SilentlyContinue)
Set-Content (Join-Path $dir 'count.txt') $count
$failAt = @(Get-Content (Join-Path $dir 'fail-at.txt') -ErrorAction SilentlyContinue | ForEach-Object { [int]$_ })
$throwAt = @(Get-Content (Join-Path $dir 'throw-at.txt') -ErrorAction SilentlyContinue | ForEach-Object { [int]$_ })
# lock-after.txt / unlock-at.txt: after call N the store is held open with no sharing (a real lock, as another program
# would hold it), until call M starts. The stub runs in the test's process, so the handle lives in a global.
$lockAfter = @(Get-Content (Join-Path $dir 'lock-after.txt') -ErrorAction SilentlyContinue | ForEach-Object { [int]$_ })
$unlockAt = @(Get-Content (Join-Path $dir 'unlock-at.txt') -ErrorAction SilentlyContinue | ForEach-Object { [int]$_ })
if ($unlockAt -contains $count -and $global:GauntletTestLock) { $global:GauntletTestLock.Dispose(); $global:GauntletTestLock = $null }
$code = & {
    if ($failAt -contains $count) { return 1 }
    if ($throwAt -contains $count) { throw "stub claude failed at call $count" }
    if (Test-Path (Join-Path $dir 'no-write.txt')) { return 0 }     # says yes and changes nothing
    $cfg = Get-Content -Raw $store | ConvertFrom-Json -AsHashtable
    if (-not $cfg.Contains('mcpServers')) { $cfg['mcpServers'] = @{} }
    switch ($args[1]) {
        'add-json' { if ($cfg.mcpServers.Contains($args[2])) { return 1 }; $cfg.mcpServers[$args[2]] = ($args[3] | ConvertFrom-Json -AsHashtable) }
        'remove'   { if (-not $cfg.mcpServers.Contains($args[2])) { return 1 }; $cfg.mcpServers.Remove($args[2]) }
        default    { return 2 }
    }
    $cfg | ConvertTo-Json -Depth 32 | Set-Content $store
    return 0
} @args
if ($lockAfter -contains $count) { $global:GauntletTestLock = [IO.File]::Open($store, 'Open', 'ReadWrite', 'None') }
exit $code
'@
$fakePython = @'
Add-Content (Join-Path $PSScriptRoot 'python-calls.log') ($args -join ' ')
$code = [int](Get-Content (Join-Path $PSScriptRoot 'check-exit.txt') -ErrorAction SilentlyContinue)
if ($code) { Write-Output '{"code":"UNSUPPORTED_EXTRA","operation":"launch"}' }
exit $code
'@

function New-Bench([hashtable]$Servers = @{}, [int[]]$FailAt = @(), [int[]]$ThrowAt = @(), [int[]]$LockAfter = @(), [int[]]$UnlockAt = @(), [int]$CheckExit = 0) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("gauntlet-reg-" + [guid]::NewGuid().ToString('N'))
    $venvScripts = Join-Path $root 'gauntlet\mcp-venv\Scripts'
    New-Item -ItemType Directory -Force $venvScripts | Out-Null
    Set-Content (Join-Path $root 'claude.ps1') $fakeClaude
    Set-Content (Join-Path $venvScripts 'python.ps1') $fakePython
    if ($FailAt) { Set-Content (Join-Path $root 'fail-at.txt') ($FailAt | ForEach-Object { "$_" }) }
    if ($ThrowAt) { Set-Content (Join-Path $root 'throw-at.txt') ($ThrowAt | ForEach-Object { "$_" }) }
    if ($LockAfter) { Set-Content (Join-Path $root 'lock-after.txt') ($LockAfter | ForEach-Object { "$_" }) }
    if ($UnlockAt) { Set-Content (Join-Path $root 'unlock-at.txt') ($UnlockAt | ForEach-Object { "$_" }) }
    if ($CheckExit) { Set-Content (Join-Path $venvScripts 'check-exit.txt') $CheckExit }
    $store = [ordered]@{ numStartups = 7; projects = @{ 'C:/work/x' = @{ mcpServers = @{} } }
                         mcpServers = [ordered]@{ other = @{ type = 'stdio'; command = 'other.exe'; args = @('--x'); env = @{} } } }
    foreach ($k in $Servers.Keys) { $store.mcpServers[$k] = $Servers[$k] }
    $store | ConvertTo-Json -Depth 32 | Set-Content (Join-Path $root '.claude.json')
    $env:CLAUDE_CONFIG_DIR = $root                    # the profile both the stub and Register-GauntletMcp use
    [pscustomobject]@{ Root = $root; Claude = (Join-Path $root 'claude.ps1'); Config = (Join-Path $root '.claude.json')
                       Python = (Join-Path $venvScripts 'python.ps1'); Calls = (Join-Path $root 'calls.log') }
}
function Get-Store($Bench) { Get-Content -Raw $Bench.Config | ConvertFrom-Json -AsHashtable }
function Get-Calls($Bench) { if (Test-Path $Bench.Calls) { @(Get-Content $Bench.Calls) } else { @() } }
function Get-Entries($Servers) {      # each server's definition as compact JSON, by name: independent of key order
    $out = [ordered]@{}
    foreach ($name in ($Servers.Keys | Sort-Object)) { $out[$name] = ConvertTo-Json -InputObject (ConvertTo-GauntletCanonical $Servers[$name]) -Depth 32 -Compress }
    ($out.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"
}
function Get-Failure([scriptblock]$Call) { try { & $Call | Out-Null; $null } catch { $_.Exception.Message } }

$oldCore = @{ type = 'stdio'; command = 'C:\old\python.exe'; args = @('-m', 'gauntlet_review.collaborative', '--repo', 'C:\w'); env = @{ KEEP = '1' } }
$oldPeer = @{ type = 'stdio'; command = 'C:\old\python.exe'; args = @('-m', 'gauntlet_review.codex_bridge', '--repo', 'C:\w'); env = @{} }
$originals = @{ 'gauntlet-core' = $oldCore; 'gauntlet-peer' = $oldPeer }
$savedConfigDir = $env:CLAUDE_CONFIG_DIR
try {

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

# Replacing existing entries succeeds and drops the old definitions; -ClaudeConfig may be left out.
$b = New-Bench -Servers $originals
$r = Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude
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
    $message = Get-Failure { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config }
    Assert-True ($message -match 'both entries are back as they were') "failure at mutation $failAt reports the rollback"
    $after = Get-Store $b
    Assert-Eq (Get-Entries $after.mcpServers) $before "failure at mutation $failAt restores both originals"
    Assert-Eq $after.mcpServers['gauntlet-core'].env.KEEP '1' "failure at mutation $failAt keeps the original environment"
    Assert-Eq $after.numStartups 7 "failure at mutation $failAt leaves other settings alone"
}
# With no previous entries, a failed second add leaves neither name behind (no mixed pair).
$b = New-Bench -FailAt 2
$message = Get-Failure { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config }
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
Assert-Throws { Register-GauntletMcp -McpPython $b.Python -StateRoot 'relative\state' -Claude $b.Claude } "a relative -StateRoot is refused"

# R3-F1 (R2-F1): the configuration read is the one the claude command changes, CLAUDE_CONFIG_DIR's .claude.json. A
# -ClaudeConfig naming any other file is refused before any call, so populated, different definitions in both files
# survive; the same file (however spelled) or no -ClaudeConfig registers in that profile alone.
$snapCore = @{ type = 'stdio'; command = 'snapshot-old-core.exe'; args = @(); env = @{} }
$snapPeer = @{ type = 'stdio'; command = 'snapshot-old-peer.exe'; args = @(); env = @{} }
$b = New-Bench -Servers @{ 'gauntlet-core' = $snapCore; 'gauntlet-peer' = $snapPeer }     # a populated file the CLI does not use
$profileDir = Join-Path $b.Root 'profile'
New-Item -ItemType Directory $profileDir | Out-Null
$profileStore = Join-Path $profileDir '.claude.json'
[ordered]@{ mcpServers = [ordered]@{ 'gauntlet-core' = @{ type = 'stdio'; command = 'actual-profile-core.exe'; args = @(); env = @{} }
                                     'gauntlet-peer' = @{ type = 'stdio'; command = 'actual-profile-peer.exe'; args = @(); env = @{} } } } |
    ConvertTo-Json -Depth 32 | Set-Content $profileStore
$otherBefore = Get-Content -Raw $b.Config
$profileBefore = Get-Content -Raw $profileStore
$env:CLAUDE_CONFIG_DIR = $profileDir
$r = Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config
Assert-True (-not $r.Registered -and $r.Reason -match 'is not the configuration the') "a -ClaudeConfig other than the CLI's profile is refused"
Assert-Eq (Get-Calls $b).Count 0 "no call before the profile is confirmed"
Assert-Eq (Get-Content -Raw $profileStore) $profileBefore "the CLI's populated profile is untouched"
Assert-Eq (Get-Content -Raw $b.Config) $otherBefore "the other populated file is untouched"
$r = Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig (Join-Path $profileDir '.\.claude.json')
Assert-True $r.Registered "the same file, spelled another way, registers"
Assert-Eq ((Get-Content -Raw $profileStore | ConvertFrom-Json -AsHashtable).mcpServers['gauntlet-peer'].args[3]) 'peer' "the CLI's profile holds the new entries"
Assert-Eq (Get-Content -Raw $b.Config) $otherBefore "the other file is never touched"

# R2-F2: a forward failure and then a rollback failure are reported as they are, decided by reading the result back.
$b = New-Bench -FailAt 2, 3                       # add core, add peer fails, removing the new core fails too
$message = Get-Failure { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config }
Assert-True ($message -notmatch 'both entries are back') "an incomplete rollback is never reported as complete"
Assert-True ($message -match 'gauntlet-core could not be put back') "the entry left behind is named"
Assert-True ((Get-Store $b).mcpServers.Contains('gauntlet-core')) "the stub really kept the new core (the report matches the state)"
$b = New-Bench -Servers $originals -FailAt 4, 5   # with originals: add peer fails, putting back the old peer fails
$message = Get-Failure { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config }
$after = Get-Store $b
Assert-True ($message -match '^Claude Code MCP registration failed: adding the new gauntlet-peer failed; gauntlet-peer could not be put back') "only the peer is reported: $message"
Assert-Eq (Get-Entries @{ c = $after.mcpServers['gauntlet-core'] }) (Get-Entries @{ c = $oldCore }) "the core is back as it was"

# R3-F2: a read-back that fails after the changes, and a command that throws, go through the same recovery.
$realRead = ${function:Read-GauntletUserEntries}
$script:reads = 0
$script:failReads = @()
function Read-GauntletUserEntries([string]$ClaudeConfig, [string[]]$Names) {
    $script:reads++
    if ($script:failReads -contains $script:reads) { throw [IO.IOException]::new('injected read-back failure') }
    & $realRead $ClaudeConfig $Names
}
try {
    $b = New-Bench -Servers $originals
    $script:reads = 0; $script:failReads = @(2)         # the snapshot reads; the check after the four changes fails
    $message = Get-Failure { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config }
    Assert-True ($message -match 'could not be read back to check the new entries; both entries are back as they were') "a failed read-back is undone like any failure: $message"
    Assert-Eq (Get-Calls $b).Count 8 "four changes, then four undone"
    Assert-Eq (Get-Entries (Get-Store $b).mcpServers) (Get-Entries ([ordered]@{ 'gauntlet-core' = $oldCore; 'gauntlet-peer' = $oldPeer; other = @{ type = 'stdio'; command = 'other.exe'; args = @('--x'); env = @{} } })) "both originals are back"

    $b = New-Bench -Servers $originals
    $script:reads = 0; $script:failReads = @(2, 3)      # and the final check cannot read either
    $message = Get-Failure { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config }
    Assert-True ($message -match 'gauntlet-core and gauntlet-peer could not be checked') "an unreadable result is reported as unchecked"
    $backup = if ($message -match 'definitions are in (\S+) \(readable by you only\)') { $Matches[1] } else { $null }
    Assert-True ($backup -and (Test-Path -LiteralPath $backup)) "the originals are kept when the result cannot be checked"
    if ($backup) { Assert-Eq ((@((Get-Content -Raw -LiteralPath $backup | ConvertFrom-Json -AsHashtable).Keys) | Sort-Object) -join ',') 'gauntlet-core,gauntlet-peer' "both originals are in the backup" }
} finally { ${function:Read-GauntletUserEntries} = $realRead }

$b = New-Bench -Servers $originals -ThrowAt 3      # removing the old peer throws
$message = Get-Failure { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config }
Assert-True ($message -match 'failed \(RuntimeException\); both entries are back as they were') "a throwing command is undone like a refused one: $message"
Assert-Eq (Get-Entries @{ c = (Get-Store $b).mcpServers['gauntlet-core'] }) (Get-Entries @{ c = $oldCore }) "the core it had replaced is back"
$b = New-Bench -Servers $originals -FailAt 4 -ThrowAt 5   # add peer fails, then putting back the old peer throws
$message = Get-Failure { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config }
Assert-True ($message -notmatch 'both entries are back' -and $message -match 'gauntlet-peer could not be put back') "a throwing undo is judged by the read-back: $message"
Assert-Eq (Get-Entries @{ c = (Get-Store $b).mcpServers['gauntlet-core'] }) (Get-Entries @{ c = $oldCore }) "the undo after the throwing one still ran"

# R2-F3: original definitions never appear in a message; the ones not put back are kept in a backup only the user reads.
$secretCore = @{ type = 'stdio'; command = 'C:\old\python.exe'; args = @('--token', 'arg-secret-marker'); env = @{ TOKEN = 'fixture-secret-marker' } }
$b = New-Bench -Servers @{ 'gauntlet-core' = $secretCore; 'gauntlet-peer' = $oldPeer } -FailAt 2, 3   # add core fails; putting back the old core fails
$message = Get-Failure { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config }
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

# R3-F3: a backup whose write fails, reports a non-terminating error or comes up short is never advertised, and no
# incomplete file is left, whatever the caller's error preference.
$realWrite = ${function:Write-GauntletBackupText}
$savedPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    foreach ($mode in 'throw', 'nonterminating', 'short') {
        $script:writeMode = $mode
        function Write-GauntletBackupText([string]$Path, [string]$Text) {
            switch ($script:writeMode) {
                'throw'          { throw [IO.IOException]::new('injected write failure') }
                'nonterminating' { Write-Error 'injected non-terminating write failure' }
                'short'          { [IO.File]::WriteAllText($Path, $Text.Substring(0, 5)) }
            }
        }
        $b = New-Bench -Servers @{ 'gauntlet-core' = $secretCore; 'gauntlet-peer' = $oldPeer } -FailAt 2, 3
        $message = Get-Failure { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config }
        Assert-True ($message -match 'could not be saved privately' -and $message -notmatch 'definitions are in') "a $($script:writeMode) backup write is reported as not saved"
        Assert-Eq @(Get-ChildItem -Path "$($b.Config).gauntlet-mcp-backup-*" -ErrorAction SilentlyContinue).Count 0 "a $($script:writeMode) backup write leaves no file"
        Assert-True ($message -notmatch 'secret-marker') "a $($script:writeMode) backup write keeps the values out of the message"
    }
} finally { $ErrorActionPreference = $savedPreference; ${function:Write-GauntletBackupText} = $realWrite }

# R4-F1: under the normal Continue preference, a configuration that cannot be read (here held open by another handle
# with no sharing, as another program would) is never taken as absent or restored, at the first read, at the check
# after the changes, or at the final check; only a missing file means no entries.
$savedPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $b = New-Bench -Servers $originals
    $lock = [IO.File]::Open($b.Config, 'Open', 'ReadWrite', 'None')
    try { $r = Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config } finally { $lock.Dispose() }
    Assert-True (-not $r.Registered -and $r.Reason -match 'cannot read') "a locked configuration at the first read skips"
    Assert-Eq (Get-Calls $b).Count 0 "no call when the current entries cannot be read"

    $b = New-Bench -LockAfter 2 -UnlockAt 3           # locked after the second add, released when the undo starts
    try { $message = Get-Failure { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config } }
    finally { if ($global:GauntletTestLock) { $global:GauntletTestLock.Dispose(); $global:GauntletTestLock = $null } }
    Assert-True ($message -match 'could not be read back to check the new entries; both entries are back as they were') "a locked check after the changes is undone: $message"
    $after = Get-Store $b
    Assert-True (-not $after.mcpServers.Contains('gauntlet-core') -and -not $after.mcpServers.Contains('gauntlet-peer')) "both new entries were undone"

    $b = New-Bench -FailAt 2, 3 -LockAfter 3          # add core, add peer fails, removing the new core fails, final check locked
    try { $message = Get-Failure { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config } }
    finally { if ($global:GauntletTestLock) { $global:GauntletTestLock.Dispose(); $global:GauntletTestLock = $null } }
    Assert-True ($message -notmatch 'both entries are back' -and $message -match 'gauntlet-core and gauntlet-peer could not be checked') "a locked final check is never reported as restored: $message"
    Assert-True ((Get-Store $b).mcpServers.Contains('gauntlet-core')) "the core really is still there (the report was right not to claim otherwise)"

    $b = New-Bench -Servers $originals
    Assert-Eq (Read-GauntletUserEntries (Join-Path $b.Root 'no-such.json') @('gauntlet-core', 'gauntlet-peer')).Count 0 "a missing file means no entries"
    Assert-Eq (Read-GauntletUserEntries (Join-Path $b.Root 'no-such-dir\.claude.json') @('gauntlet-core')).Count 0 "a missing folder means no entries"
    $lock = [IO.File]::Open($b.Config, 'Open', 'ReadWrite', 'None')
    try { Assert-Throws { Read-GauntletUserEntries $b.Config @('gauntlet-core') } "a locked file throws under Continue" } finally { $lock.Dispose() }
    Set-Content $b.Config '{not json'
    Assert-Throws { Read-GauntletUserEntries $b.Config @('gauntlet-core') } "an unparseable file throws under Continue"
} finally { $ErrorActionPreference = $savedPreference }

# A CLI that says yes but changes nothing is caught by the read-back, not reported as success.
$b = New-Bench
Set-Content (Join-Path $b.Root 'no-write.txt') 'x'
$message = Get-Failure { Register-GauntletMcp -McpPython $b.Python -Claude $b.Claude -ClaudeConfig $b.Config }
Assert-True ($message -match 'does not show the new gauntlet-core and gauntlet-peer') "registration is checked by reading the configuration back"

} finally { $env:CLAUDE_CONFIG_DIR = $savedConfigDir }
Write-TestResult
