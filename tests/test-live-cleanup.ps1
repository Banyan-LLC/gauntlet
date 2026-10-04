# Offline acceptance only. No Codex invocation, real credentials or recursive deletion.
. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\..\gauntlet-review\scripts\lib.ps1"
$ErrorActionPreference = 'Stop'
$required = @('New-LiveGateDirectory','Get-LiveGateDirectoryRecord','Remove-LiveGateDirectory','Invoke-LiveGateStamp')
foreach ($name in $required) { Assert-True ($null -ne (Get-Command $name -ErrorAction SilentlyContinue)) "live cleanup API exists: $name" }
if ($script:Failures.Count -gt 0) { Write-TestResult }

$owned = [System.Collections.Generic.List[object]]::new()
try {
    $booleanProbe = New-LiveGateDirectory -Kind Schema
    $owned.Add($booleanProbe)
    Assert-True (-not (Remove-LiveGateDirectory -Record $booleanProbe -ProcessTreeRetired 1).Accepted) 'numeric truth cannot substitute for retirement proof'
    # Wrong cleanup scope, foreign ownership, unexpected content, failed retirement and
    # failed removal must preserve the target and prevent evidence publication.
    $schema = New-LiveGateDirectory -Kind Schema
    $owned.Add($schema)
    Assert-Throws { New-OwnedLiveGateDirectory -Path $schema.Path -Kind Schema } 'exclusive creation refuses an existing generated target'
    Assert-Throws { New-OwnedLiveGateDirectory -Path ([IO.Path]::GetTempPath()) -Kind Schema } 'owner factory refuses root equality'
    Assert-Throws { New-OwnedLiveGateDirectory -Path ($schema.Path + '-evil') -Kind Schema } 'owner factory refuses malformed generated identifiers'
    [IO.File]::WriteAllText((Join-Path $schema.Path 'events.jsonl'), 'offline events')
    [IO.File]::WriteAllText((Join-Path $schema.Path 'verdict.json'), '{}')
    $result = Remove-LiveGateDirectory -Record $schema -ProcessTreeRetired $false
    Assert-True (-not $result.Accepted) 'unknown process retirement refuses cleanup'
    Assert-True ([IO.Directory]::Exists($schema.Path)) 'unretired cleanup preserves its owned target'

    $foreign = [pscustomobject]@{ Token = [guid]::NewGuid().ToString('n'); Path = $schema.Path }
    Assert-True (-not (Remove-LiveGateDirectory -Record $foreign -ProcessTreeRetired $true).Accepted) 'foreign token cannot delete another run'
    $wrongPath = [pscustomobject]@{ Token = $schema.Token; Path = [IO.Path]::GetTempPath() }
    Assert-True (-not (Remove-LiveGateDirectory -Record $wrongPath -ProcessTreeRetired $true).Accepted) 'root equality cannot inherit child ownership'
    $sibling = [pscustomobject]@{ Token = $schema.Token; Path = $schema.Path + '-evil' }
    Assert-True (-not (Remove-LiveGateDirectory -Record $sibling -ProcessTreeRetired $true).Accepted) 'same-prefix sibling cannot inherit ownership'

    $unexpected = Join-Path $schema.Path 'foreign.txt'
    [IO.File]::WriteAllText($unexpected, 'preserve')
    $result = Remove-LiveGateDirectory -Record $schema -ProcessTreeRetired $true
    Assert-True (-not $result.Accepted) 'unexpected schema entries refuse all disposal'
    Assert-True ([IO.File]::Exists((Join-Path $schema.Path 'events.jsonl'))) 'unexpected entry does not permit partial schema disposal'
    [IO.File]::Delete($unexpected)

    $linkTarget = New-LiveGateDirectory -Kind Schema
    $owned.Add($linkTarget)
    $junction = Join-Path $schema.Path 'linked'
    New-Item -ItemType Junction -Path $junction -Target $linkTarget.Path -ErrorAction Stop | Out-Null
    try {
        Assert-Throws { Assert-LiveGatePathComponents -Path $junction } 'directory-component validator refuses a junction'
        Assert-True (-not (Remove-LiveGateDirectory -Record $schema -ProcessTreeRetired $true).Accepted) 'schema cleanup refuses a reparse entry'
        Assert-True ([IO.Directory]::Exists($linkTarget.Path)) 'refused link cleanup preserves its separate target'
    } finally { [IO.Directory]::Delete($junction, $false) }
    Assert-True (Remove-LiveGateDirectory -Record $linkTarget -ProcessTreeRetired $true).Accepted 'separate linked target retains its own independent ownership'

    $lockedPath = Join-Path $schema.Path 'events.jsonl'
    $lock = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $result = Remove-LiveGateDirectory -Record $schema -ProcessTreeRetired $true
        Assert-True (-not $result.Accepted) 'permission or sharing failure is not treated as absence'
        Assert-True ([IO.Directory]::Exists($schema.Path)) 'failed cleanup retains the owned directory'
        $stampProbe = [System.Collections.Generic.List[string]]::new()
        Assert-Throws { Invoke-LiveGateStamp -FailureCount 0 -CleanupResults @($result) -Stamp { $stampProbe.Add('stamped') } } 'failed cleanup refuses stamping'
        Assert-Eq $stampProbe.Count 0 'failed cleanup does not call the evidence writer'
    } finally { $lock.Dispose() }
    $result = Remove-LiveGateDirectory -Record $schema -ProcessTreeRetired $true
    Assert-True $result.Accepted 'known schema files and their empty directory are removed'
    Assert-True (-not [IO.Directory]::Exists($schema.Path)) 'successful schema cleanup verifies absence'
    Assert-True (-not (Remove-LiveGateDirectory -Record $schema -ProcessTreeRetired $true).Accepted) 'consumed ownership cannot authorize a later directory'
    $missing = New-LiveGateDirectory -Kind Schema
    $owned.Add($missing)
    [IO.Directory]::Delete($missing.Path, $false)
    Assert-True (Remove-LiveGateDirectory -Record $missing -ProcessTreeRetired $true).Accepted 'genuinely missing owned target is accepted without hiding IO errors'

    $harness = New-HarnessDir -RepoRoot (Split-Path $PSScriptRoot -Parent)
    $harnessRecord = Get-LiveGateDirectoryRecord -Path $harness
    $owned.Add($harnessRecord)
    $residue = Join-Path $harness 'residue.txt'
    [IO.File]::WriteAllText($residue, 'preserve')
    Assert-True (-not (Remove-LiveGateDirectory -Record $harnessRecord -ProcessTreeRetired $true).Accepted) 'nonempty harness is never recursively swept'
    Assert-True ([IO.File]::Exists($residue)) 'nonempty harness residue remains for inspection'
    [IO.File]::Delete($residue)
    Assert-True (Remove-LiveGateDirectory -Record $harnessRecord -ProcessTreeRetired $true).Accepted 'empty owned harness is removed without recursion'

    $old = New-LiveGateDirectory -Kind Schema
    $owned.Add($old)
    [IO.Directory]::Delete($old.Path, $false)
    [IO.Directory]::CreateDirectory($old.Path) | Out-Null
    Assert-True (-not (Remove-LiveGateDirectory -Record $old -ProcessTreeRetired $true).Accepted) 'replacement directory cannot reuse a stale creation record'
    [IO.Directory]::Delete($old.Path, $false)

    $security = New-LiveGateDirectory -Kind Security
    $owned.Add($security)
    $result = Remove-LiveGateDirectory -Record $security -ProcessTreeRetired $true
    Assert-True (-not $result.Accepted) 'security tree cleanup requires explicit run-level authorization'
    Assert-True ([IO.Directory]::Exists($security.Path)) 'missing authorization never deletes even an empty security root'
    # This fixture deliberately never exercises the recursive code path.
    [IO.Directory]::Delete($security.Path, $false)

    $stampProbe = [System.Collections.Generic.List[string]]::new()
    Assert-Throws { Invoke-LiveGateStamp -FailureCount 1 -CleanupResults @([pscustomobject]@{Accepted=$true}) -Stamp { $stampProbe.Add('stamped') } } 'an earlier assertion failure refuses evidence'
    Assert-Throws { Invoke-LiveGateStamp -FailureCount 0 -CleanupResults @() -Stamp { $stampProbe.Add('stamped') } } 'missing cleanup acceptance refuses evidence'
    Assert-Throws { Invoke-LiveGateStamp -FailureCount 0 -CleanupResults @([pscustomobject]@{Accepted='yes'}) -Stamp { $stampProbe.Add('stamped') } } 'nonboolean cleanup claim refuses evidence'
    Invoke-LiveGateStamp -FailureCount 0 -CleanupResults @([pscustomobject]@{Accepted=$true}) -Stamp { $stampProbe.Add('stamped') }
    Assert-Eq $stampProbe.Count 1 'evidence callback runs only after accepted cleanup and zero failures'

    # Real local process containment catches parent-only retirement, pipe inheritance and
    # non-reading stdin. The only executable is this PowerShell installation.
    Assert-True ((Get-Command Invoke-BoundedProcess).Parameters.ContainsKey('RequireProcessTreeRetirement')) 'bounded runner can require physical process-tree retirement'
    if ($script:Failures.Count -gt 0) { Write-TestResult }
    $pwsh = [Environment]::ProcessPath
    $job = Invoke-BoundedProcess -FileName $pwsh -ArgList @('-NoProfile','-Command','[Console]::Write("out"); [Console]::Error.Write("err"); exit 7') -TimeoutSec 10 -RequireProcessTreeRetirement
    Assert-Eq $job.ExitCode 7 'contained runner preserves child exit code'
    Assert-Eq $job.Stdout 'out' 'contained runner captures stdout'
    Assert-Eq $job.Stderr 'err' 'contained runner captures stderr'
    Assert-True $job.ProcessTreeRetired 'normal completion confirms an empty job'
    Assert-True (-not $job.StartFailed) 'contained local executable starts'
    $job = Invoke-BoundedProcess -FileName $pwsh -ArgList @('-NoProfile','-Command','[Console]::Write($env:GATE_OFFLINE); [Console]::Error.Write($env:UNSET_GATE_CANARY)') -ClearEnvironment -EnvironmentMap @{SystemRoot=$env:SystemRoot;GATE_OFFLINE='fixture'} -TimeoutSec 10 -RequireProcessTreeRetirement
    Assert-Eq $job.Stdout 'fixture' 'contained runner uses its exact explicit child environment'
    Assert-Eq $job.Stderr '' 'contained runner does not inherit unspecified environment values'

    $quoteArgs = @('space value','quote"value','trailing\','')
    # -File retains raw argument values while -Command interprets its suffix as source.
    $fixture = New-LiveGateDirectory -Kind Schema
    $owned.Add($fixture)
    $scriptFile = Join-Path $fixture.Path 'argv.ps1'
    [IO.File]::WriteAllText($scriptFile, '[Console]::Write(($args | ConvertTo-Json -Compress))')
    $job = Invoke-BoundedProcess -FileName $pwsh -ArgList (@('-NoProfile','-File',$scriptFile) + $quoteArgs) -TimeoutSec 10 -RequireProcessTreeRetirement
    $received = @($job.Stdout | ConvertFrom-Json)
    Assert-Eq $received.Count 4 'contained argument quoting retains empty argument'
    for ($i=0; $i -lt 4; $i++) { Assert-Eq $received[$i] $quoteArgs[$i] "contained argument $i survives Windows quoting" }
    [IO.File]::Delete($scriptFile)

    $childCode = '$child = [Diagnostics.Process]::Start([Environment]::ProcessPath, "-NoProfile -Command Start-Sleep 60"); [Console]::WriteLine($child.Id); exit 0'
    $job = Invoke-BoundedProcess -FileName $pwsh -ArgList @('-NoProfile','-Command',$childCode) -TimeoutSec 10 -RequireProcessTreeRetirement
    Assert-True $job.ProcessTreeRetired 'parent exit also retires a still-running descendant'
    $childId = [int]$job.Stdout.Trim()
    Assert-True ($null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'descendant is physically gone after job retirement'

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $job = Invoke-BoundedProcess -FileName $pwsh -ArgList @('-NoProfile','-Command','Start-Sleep 60') -StdinText ('x' * 600000) -TimeoutSec 4 -RequireProcessTreeRetirement
    $timer.Stop()
    Assert-True $job.TimedOut 'non-reading contained child hits its deadline'
    Assert-True $job.ProcessTreeRetired 'timeout confirms retirement rather than merely requesting kill'
    Assert-True ($timer.Elapsed.TotalSeconds -lt 8) 'execution and retirement stay within a bounded total'
    $job = Invoke-BoundedProcess -FileName 'C:\does-not-exist\never.exe' -TimeoutSec 2 -RequireProcessTreeRetirement
    Assert-True $job.StartFailed 'contained launch failure is structured'
    Assert-True $job.ProcessTreeRetired 'a launch that created no process leaves no credential consumer'
} catch {
    Assert-True $false "offline cleanup acceptance aborted: $($_.Exception.Message)"
} finally {
    # Every target below is an exact fixture returned by this run's creation API.
    # No unknown entry is swept and no recursive remover is invoked by this suite.
    foreach ($record in $owned) {
        if ([IO.Directory]::Exists($record.Path)) {
            foreach ($name in @('events.jsonl','verdict.json','argv.ps1')) {
                $file = Join-Path $record.Path $name
                if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
            }
            if (@([IO.Directory]::EnumerateFileSystemEntries($record.Path)).Count -eq 0) { [IO.Directory]::Delete($record.Path, $false) }
        }
    }
}
Write-TestResult
