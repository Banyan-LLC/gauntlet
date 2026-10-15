#Requires -Version 7
# Offline setup regression. No credential access, live model or mutating Git process.
. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\..\gauntlet-review\scripts\lib.ps1"
$ErrorActionPreference = 'Stop'

# Execute the real setup statements, stopping before CLI selection or credential setup.
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    "$PSScriptRoot\live\live-security.ps1", [ref]$tokens, [ref]$parseErrors)
Assert-Eq @($parseErrors).Count 0 'live security source parses before setup extraction'
$body = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
Assert-Eq $body.Count 1 'one outer security try block owns setup and cleanup'
if ($script:Failures.Count -gt 0) { Write-TestResult }
$assignments = @($body[0].Body.Statements | Where-Object {
    $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
    $_.Left -is [Management.Automation.Language.VariableExpressionAst]
})
$start = @($assignments | Where-Object { $_.Left.VariablePath.UserPath -eq 'repo' })
$end = @($assignments | Where-Object { $_.Left.VariablePath.UserPath -eq 'cli' })
Assert-Eq $start.Count 1 'one control-directory setup assignment exists'
Assert-Eq $end.Count 1 'one CLI-selection boundary exists'
if ($script:Failures.Count -gt 0) { Write-TestResult }
$setup = $ast.Extent.Text.Substring($start[0].Extent.StartOffset,
    $end[0].Extent.StartOffset - $start[0].Extent.StartOffset)

function Invoke-SecurityProcess {
    throw 'Offline setup must not dispatch a process to initialize or commit a repository'
}

$securityDirectory = $null
$repo = $null
$harness = $null
$setupError = $null
try {
    $securityDirectory = New-LiveGateDirectory -Kind Security
    $guidRoot = $securityDirectory.Path
    try { . ([scriptblock]::Create($setup)) }
    catch { $setupError = $_.Exception.Message }
    Assert-True ($null -eq $setupError) "security setup needs only an owned directory: $setupError"
    if ($null -eq $setupError) {
        Assert-Eq $repo (Join-Path $guidRoot 'repo') 'setup creates the expected owned child'
        Assert-True ([IO.Directory]::Exists($repo)) 'ordinary control directory exists'
        Assert-Eq @([IO.Directory]::EnumerateFileSystemEntries($repo)).Count 0 'control directory starts empty'
        Assert-Throws { New-LiveGateChildDirectory -Record $securityDirectory -Name 'repo' } 'existing child cannot be adopted again'

        # Keep the real read-only Git discovery in Assert-HarnessSafe. A non-repository
        # directory must still support the genuine protected harness API.
        $harness = New-HarnessDir -RepoRoot $repo -RequireLiveGateOwnership
        Assert-True ([IO.Directory]::Exists($harness)) 'protected harness exists outside the control directory'
        Assert-True (-not (Test-PathUnderRoot -Path $harness -Root $guidRoot)) 'harness remains outside the security tree'
        Assert-Eq @([IO.Directory]::EnumerateFileSystemEntries($harness)).Count 0 'protected harness starts empty'
        $record = Get-LiveGateDirectoryRecord -Path $harness
        $refused = Remove-LiveGateDirectory -Record $record -ProcessTreeRetired $false
        Assert-True (-not $refused.Accepted) 'unretired harness cleanup is refused'
        Assert-True ([IO.Directory]::Exists($harness)) 'refused cleanup preserves the owned harness'
    }
} finally {
    # No child process is dispatched by this setup; the synchronous Git discovery has
    # returned before cleanup. Include registered factories that might have thrown.
    $records = @(Get-LiveGateDirectoryRecords)
    $cleanup = @(Complete-LiveGateDirectories -Kinds Harness,Security -ProcessTreeRetired $true -AllowSecurityTreeCleanup)
    foreach ($result in $cleanup) {
        Assert-True $result.Accepted "owned directory cleanup accepted: $($result.Path): $($result.Error)"
    }
    foreach ($record in $records) {
        Assert-True (-not [IO.Directory]::Exists($record.Path)) "owned directory is absent after cleanup: $($record.Path)"
    }
    if ($repo) { Assert-True (-not [IO.Directory]::Exists($repo)) 'owned control child is absent after cleanup' }
    Assert-Eq @(Get-LiveGateDirectoryRecords).Count 0 'all native directory ownership is retired'
}
Write-TestResult
