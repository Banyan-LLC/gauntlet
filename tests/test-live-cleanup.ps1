# Offline acceptance only. No Codex invocation, real credentials or recursive deletion.
. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\..\gauntlet-review\scripts\lib.ps1"
$ErrorActionPreference = 'Stop'
$required = @('New-LiveGateDirectory','Get-LiveGateDirectoryRecord','Remove-LiveGateDirectory','Invoke-LiveGateStamp')
foreach ($name in $required) { Assert-True ($null -ne (Get-Command $name -ErrorAction SilentlyContinue)) "live cleanup API exists: $name" }
if ($script:Failures.Count -gt 0) { Write-TestResult }

$owned = [System.Collections.Generic.List[object]]::new()
try {
    Initialize-LiveGateNative
    $changedInitializer = (Get-Command Initialize-LiveGateNative).ScriptBlock.ToString().Replace('limits.Basic.Flags = 0x2000;', 'limits.Basic.Flags = 0x3000;')
    Assert-Throws { & ([scriptblock]::Create($changedInitializer)) } 'loaded native helper refuses a different source identity before reuse'
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
    Assert-Throws { [IO.Directory]::Delete($missing.Path, $false) } 'held ownership prevents unobserved external deletion'
    Assert-True (Remove-LiveGateDirectory -Record $missing -ProcessTreeRetired $true).Accepted 'the custody holder can dispose its own exact empty object'

    $liveHarnessMode = (Get-Command New-HarnessDir).Parameters.ContainsKey('RequireLiveGateOwnership')
    Assert-True $liveHarnessMode 'harness exposes protected live-gate ownership separately from ordinary invocation'
    $harness = if ($liveHarnessMode) { New-HarnessDir -RepoRoot (Split-Path $PSScriptRoot -Parent) -RequireLiveGateOwnership } else { New-HarnessDir -RepoRoot (Split-Path $PSScriptRoot -Parent) }
    $harnessRecord = Get-LiveGateDirectoryRecord -Path $harness
    $owned.Add($harnessRecord)
    $residue = Join-Path $harness 'residue.txt'
    [IO.File]::WriteAllText($residue, 'preserve')
    Assert-True (-not (Remove-LiveGateDirectory -Record $harnessRecord -ProcessTreeRetired $true).Accepted) 'nonempty harness is never recursively swept'
    Assert-True ([IO.File]::Exists($residue)) 'nonempty harness residue remains for inspection'
    [IO.File]::Delete($residue)
    Assert-True (Remove-LiveGateDirectory -Record $harnessRecord -ProcessTreeRetired $true).Accepted 'empty owned harness is removed without recursion'
    $hasFinalizer = $null -ne (Get-Command Complete-LiveGateDirectories -ErrorAction SilentlyContinue)
    Assert-True $hasFinalizer 'gate finalizer includes factories that threw before returning their ownership records'
    if ($hasFinalizer) {
        $tokensBefore = @((Get-LiveGateDirectoryRecords).Token)
        Assert-Throws { New-HarnessDir -RepoRoot (Join-Path $env:LOCALAPPDATA 'gauntlet-review/harness') -RequireLiveGateOwnership } 'post-creation discovery assertion can fail under its guarded lifecycle'
        $partial = @(Get-LiveGateDirectoryRecords | Where-Object { $_.Token -notin $tokensBefore })
        Assert-Eq $partial.Count 1 'a throwing factory still publishes its single exact partial creation'
        foreach ($partialRecord in $partial) { $owned.Add($partialRecord) }
        $finalized = @(Complete-LiveGateDirectories -Kinds @('Harness') -ProcessTreeRetired $true)
        Assert-Eq $finalized.Count 1 'finalizer observes the partial harness absent from caller assignments'
        Assert-True $finalized[0].Accepted 'partial empty harness is finalized through its original held object'
        Assert-True (-not [IO.Directory]::Exists($partial[0].Path)) 'partial creation leaves no untracked fixture behind'
    }

    $old = New-LiveGateDirectory -Kind Schema
    $owned.Add($old)
    $moved = $old.Path + '-moved'
    try { Assert-Throws { [IO.Directory]::Move($old.Path, $moved) } 'custody prevents directory replacement between creation and cleanup' }
    finally { if ([IO.Directory]::Exists($moved)) { [IO.Directory]::Move($moved, $old.Path) } }
    Assert-True (Remove-LiveGateDirectory -Record $old -ProcessTreeRetired $true).Accepted 'protected identity survives a rejected external rename'

    $security = New-LiveGateDirectory -Kind Security
    $owned.Add($security)
    $movedSecurity = $security.Path + '-moved'
    try { Assert-Throws { [IO.Directory]::Move($security.Path, $movedSecurity) } 'credential-tree custody prevents a renamed tree from passing absence checks' }
    finally { if ([IO.Directory]::Exists($movedSecurity)) { [IO.Directory]::Move($movedSecurity, $security.Path) } }
    $hasOwnedProducer = $null -ne (Get-Command New-LiveGateChildDirectory -ErrorAction SilentlyContinue) -and $null -ne (Get-Command Write-LiveGateChildFile -ErrorAction SilentlyContinue)
    Assert-True $hasOwnedProducer 'credential writes require an exclusively created owned child API'
    if ($hasOwnedProducer) {
        $producer = New-LiveGateDirectory -Kind Security
        $owned.Add($producer)
        # Load the real producer bodies without executing any live gate top-level statements.
        $producerTokens=$null; $producerErrors=$null
        $producerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'live/live-security.ps1'),[ref]$producerTokens,[ref]$producerErrors)
        foreach ($producerName in @('New-ControlHome','New-ControlCwd')) {
            $producerFunction=$producerAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $producerName },$true)
            . ([scriptblock]::Create($producerFunction.Extent.Text))
        }
        $dummySource=New-LiveGateDirectory -Kind Schema
        $owned.Add($dummySource)
        $authSrc=Join-Path $dummySource.Path 'events.jsonl'
        [IO.File]::WriteAllText($authSrc,'dummy-only')
        $securityDirectory=$producer
        $guidRoot=$producer.Path
        $offlineHome = New-ControlHome -Name 'offline' -ConfigToml 'dummy-config'
        $dummyCredential = [Text.Encoding]::UTF8.GetBytes('dummy-only')
        $auth = Join-Path $offlineHome 'auth.json'
        $read = [IO.FileStream]::new($auth,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $reader=[IO.StreamReader]::new($read); Assert-Eq ($reader.ReadToEnd()) 'dummy-only' 'owned producer writes only its supplied dummy bytes' }
        finally { $read.Dispose() }
        $hasOwnedHash = $null -ne (Get-Command Get-LiveGateChildFileHash -ErrorAction SilentlyContinue)
        Assert-True $hasOwnedHash 'production copy verification reads the held object rather than reopening its pathname'
        if ($hasOwnedHash) { Assert-Eq (Get-LiveGateChildFileHash -Record $producer -Path $auth) '832cb5e7d57e92b974279ac4967692d0a919a2e87bab4f722e64ad5826ec1078' 'held-object hashing verifies the actual dummy destination bytes' }
        Assert-Throws { Write-LiveGateChildFile -Record $producer -Directory $offlineHome -Name 'auth.json' -Bytes ([byte[]]@(0)) } 'existing credential destinations are never reused or overwritten'
        Assert-Throws { [IO.Directory]::Move($offlineHome, ($offlineHome + '-moved')) } 'credential home stays pinned through producer writes'
        Assert-Throws { [IO.File]::Move($auth, (Join-Path $producer.Path 'moved-auth.json')) } 'copied credential object cannot be renamed outside its registered home'
        $offlineInstructions=Join-Path $offlineHome 'AGENTS.md'
        Write-LiveGateChildFile -Record $producer -Directory $offlineHome -Name 'AGENTS.md' -Bytes $dummyCredential
        Assert-Throws { [IO.File]::AppendAllText($offlineInstructions,'changed') } 'copied trusted instructions cannot change while their owned consumer is active'
        Assert-Throws { New-LiveGateChildDirectory -Record $producer -Name 'home-offline' } 'an existing child cannot become a new credential destination'
        Assert-Throws { Write-LiveGateChildFile -Record $producer -Directory ([IO.Path]::GetTempPath()) -Name 'auth.json' -Bytes $dummyCredential } 'owned writer refuses a directory outside its private creation records'
        Assert-Throws { Write-LiveGateChildFile -Record $producer -Directory $offlineHome -Name '../escape' -Bytes $dummyCredential } 'owned writer refuses child path traversal'
        $offlineCwd=New-ControlCwd -Name 'offline'
        Assert-Throws { [IO.Directory]::Move($offlineCwd, ($offlineCwd+'-moved')) } 'real control working-directory producer retains stable containment'
        $poisonedHome=Join-Path $producer.Path 'home-preexisting'
        [IO.Directory]::CreateDirectory($poisonedHome) | Out-Null
        Assert-Throws { New-ControlHome -Name 'preexisting' } 'real credential producer refuses a precreated home before copying'
        $linkedHome=New-LiveGateChildDirectory -Record $producer -Name 'home-linked'
        $linkedConfig=Join-Path $linkedHome 'config.toml'
        New-Item -ItemType HardLink -Path $linkedConfig -Target $authSrc -ErrorAction Stop | Out-Null
        Assert-Throws { Write-LiveGateChildFile -Record $producer -Directory $linkedHome -Name 'config.toml' -Bytes $dummyCredential } 'linked destination cannot redirect the owned producer write'
        Assert-Eq ([IO.File]::ReadAllText($authSrc)) 'dummy-only' 'refused linked destination leaves foreign dummy bytes unchanged'
        $script:LiveGateDirectories[$producer.Token].Custody.Dispose()
        [IO.File]::Delete($auth)
        [IO.File]::Delete((Join-Path $offlineHome 'config.toml'))
        [IO.File]::Delete($offlineInstructions)
        [IO.File]::Delete($linkedConfig)
        [IO.Directory]::Delete($offlineHome,$false)
        [IO.Directory]::Delete($offlineCwd,$false)
        [IO.Directory]::Delete($poisonedHome,$false)
        [IO.Directory]::Delete($linkedHome,$false)
        [IO.Directory]::Delete($producer.Path,$false)
        Assert-True (-not (Remove-LiveGateDirectory -Record $producer -ProcessTreeRetired $true -AllowSecurityTreeCleanup).Accepted) 'released custody never authorizes even an absent credential tree'
    }
    $result = Remove-LiveGateDirectory -Record $security -ProcessTreeRetired $true
    Assert-True (-not $result.Accepted) 'security tree cleanup requires explicit run-level authorization'
    Assert-True ([IO.Directory]::Exists($security.Path)) 'missing authorization never deletes even an empty security root'
    Assert-True ($null -ne (Get-Command Assert-LiveGateTreeSafe -ErrorAction SilentlyContinue)) 'security tree has a read-only bounded validator'
    if ($script:Failures.Count -gt 0) { Write-TestResult }
    $nested = Join-Path $security.Path 'fixture'
    [IO.Directory]::CreateDirectory($nested) | Out-Null
    $dummy = Join-Path $nested 'dummy.txt'
    [IO.File]::WriteAllText($dummy, 'not a credential')
    try {
        Assert-True (Assert-LiveGateTreeSafe -Path $security.Path) 'regular owned security fixture passes read-only inventory'
        Assert-Throws { Assert-LiveGateTreeSafe -Path $security.Path -MaxEntries 1 } 'tree inventory refuses an exceeded aggregate entry budget'
        $link = Join-Path $nested 'linked'
        New-Item -ItemType Junction -Path $link -Target $booleanProbe.Path -ErrorAction Stop | Out-Null
        try { Assert-Throws { Assert-LiveGateTreeSafe -Path $security.Path } 'tree inventory refuses a nested reparse entry before any disposal' }
        finally { [IO.Directory]::Delete($link, $false) }
        $emptyDirectories=[Collections.Generic.List[string]]::new()
        try {
            for ($emptyIndex=0; $emptyIndex -lt 250; $emptyIndex++) {
                $emptyPath=Join-Path $nested "empty-$emptyIndex"
                [IO.Directory]::CreateDirectory($emptyPath) | Out-Null
                $emptyDirectories.Add($emptyPath)
            }
            $inventoryTimer=[Diagnostics.Stopwatch]::StartNew()
            Assert-Throws { Assert-LiveGateTreeSafe -Path $security.Path -TimeoutMs 1 } 'empty-directory processing cannot run past the shared inventory deadline'
            $inventoryTimer.Stop()
            Assert-True ($inventoryTimer.Elapsed.TotalSeconds -lt 2) 'bounded observation returns promptly even while metadata work is unresolved'
            $settleTimer=[Diagnostics.Stopwatch]::StartNew()
            while ($script:LiveGateDirectories[$security.Token].Custody.Busy -and $settleTimer.ElapsedMilliseconds -lt 1000) { Start-Sleep -Milliseconds 5 }
            Assert-True (-not $script:LiveGateDirectories[$security.Token].Custody.Busy) 'timed-out read-only worker completes without launching deletion'
        } finally { foreach ($emptyPath in $emptyDirectories) { [IO.Directory]::Delete($emptyPath,$false) } }
    } finally { [IO.File]::Delete($dummy); [IO.Directory]::Delete($nested, $false) }
    # This fixture deliberately never exercises the recursive code path.
    $script:LiveGateDirectories[$security.Token].Custody.Dispose()
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
    $runnerTimer = [Diagnostics.Stopwatch]::StartNew()
    $noisy = Invoke-BoundedProcess -FileName $pwsh -ArgList @('-NoProfile','-Command','[Console]::Write("o" * 3000000); [Console]::Error.Write("e" * 3000000); Start-Sleep 60') -TimeoutSec 12 -RequireProcessTreeRetirement
    $runnerTimer.Stop()
    Assert-True ($noisy.ErrorMessage -match 'output.*budget') 'aggregate output overflow remains a typed execution failure'
    Assert-True ($noisy.ExitCode -ne 0) 'incomplete output never retains a successful execution code'
    Assert-True $noisy.ProcessTreeRetired 'output overflow physically retires its owned job'
    Assert-True (($noisy.Stdout.Length + $noisy.Stderr.Length) -le 4194304) 'stdout and stderr share one retained-output budget'
    Assert-True ($runnerTimer.Elapsed.TotalSeconds -lt 8) 'output overflow ends execution promptly within its remaining deadline'
    $rejectedInput = Invoke-BoundedProcess -FileName (Join-Path $env:SystemRoot 'System32/cmd.exe') -ArgList @('/d','/c','exit','0') -StdinText ('x' * 6000000) -TimeoutSec 10 -RequireProcessTreeRetirement
    Assert-True ($rejectedInput.ErrorMessage -match 'stdin') 'zero parent exit cannot erase failed prompt delivery'
    Assert-True ($rejectedInput.ExitCode -ne 0) 'failed prompt delivery never reports execution success'
    Assert-True $rejectedInput.ProcessTreeRetired 'failed input still retires the entire owned job'
    $job = Invoke-BoundedProcess -FileName $pwsh -ArgList @('-NoProfile','-Command','[Console]::Write("out"); [Console]::Error.Write("err"); exit 7') -TimeoutSec 10 -RequireProcessTreeRetirement
    Assert-Eq $job.ExitCode 7 'contained runner preserves child exit code'
    Assert-Eq $job.Stdout 'out' 'contained runner captures stdout'
    Assert-Eq $job.Stderr 'err' 'contained runner captures stderr'
    Assert-True $job.ProcessTreeRetired 'normal completion confirms an empty job'
    Assert-True (-not $job.StartFailed) 'contained local executable starts'
    $cmd = Join-Path $env:SystemRoot 'System32/cmd.exe'
    $job = Invoke-BoundedProcess -FileName $cmd -ArgList @('/d','/c','echo','contained') -TimeoutSec 10 -RequireProcessTreeRetirement
    Assert-Eq $job.ExitCode 0 'contained runner retains command-wrapper compatibility'
    Assert-Eq $job.Stdout.Trim() 'contained' 'command-wrapper switches keep their native syntax'
    $previousGateCanary = $env:GATE_PARENT_ONLY
    try {
        $env:GATE_PARENT_ONLY = 'offline-canary'
        $job = Invoke-BoundedProcess -FileName $pwsh -ArgList @('-NoProfile','-Command','[Console]::Write($env:GATE_OFFLINE); [Console]::Error.Write($env:GATE_PARENT_ONLY)') -ClearEnvironment -EnvironmentMap @{SystemRoot=$env:SystemRoot;GATE_OFFLINE='fixture'} -TimeoutSec 10 -RequireProcessTreeRetirement
        Assert-Eq $job.Stdout 'fixture' 'contained runner uses its exact explicit child environment'
        Assert-Eq $job.Stderr '' 'contained runner does not inherit an existing parent canary'
    } finally { $env:GATE_PARENT_ONLY = $previousGateCanary }

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

    $hasInputBinding = $null -ne (Get-Command New-LiveGateInputs -ErrorAction SilentlyContinue) -and $null -ne (Get-Command Complete-LiveGateInputs -ErrorAction SilentlyContinue) -and (Get-Command Invoke-LiveGateStamp).Parameters.ContainsKey('Inputs')
    Assert-True $hasInputBinding 'live stamps require a captured input identity and reject untested drift'
    if ($hasInputBinding) {
        $inputFixture=New-LiveGateDirectory -Kind Schema
        $owned.Add($inputFixture)
        $fixtureDirectories=@('gauntlet-review','gauntlet-review/scripts','gauntlet-review/schemas','tests','tests/live')
        $fixtureFiles=[Collections.Generic.List[string]]::new()
        $inputRecords=[Collections.Generic.List[object]]::new()
        try {
            foreach ($relative in $fixtureDirectories) { [IO.Directory]::CreateDirectory((Join-Path $inputFixture.Path $relative)) | Out-Null }
            $publicSources=@('gauntlet-review/scripts/lib.ps1','gauntlet-review/scripts/invoke-codex.ps1','gauntlet-review/scripts/publish-review.ps1','gauntlet-review/scripts/calibrate-premises.ps1','gauntlet-review/schemas/verdict.schema.json','tests/helpers.ps1','tests/live/live-schema-gate.ps1','tests/live/live-security.ps1')
            foreach ($relative in $publicSources) {
                $destination=Join-Path $inputFixture.Path $relative
                [IO.File]::Copy((Join-Path (Split-Path $PSScriptRoot -Parent) $relative),$destination)
                $fixtureFiles.Add($destination)
            }
            $fakeCli=Join-Path $inputFixture.Path 'offline-cli.txt'
            $fakeAgents=Join-Path $inputFixture.Path 'offline-agents.md'
            $fakeSkill=Join-Path $inputFixture.Path 'gauntlet-review'
            $fakePremises=Join-Path $fakeSkill 'premises.json'
            [IO.File]::WriteAllText($fakeCli,'offline identity, never executed')
            [IO.File]::WriteAllText($fakeAgents,'offline trusted instructions')
            [IO.File]::WriteAllText($fakePremises,'{"offline_fixture":true}')
            foreach ($path in @($fakeCli,$fakeAgents,$fakePremises)) { $fixtureFiles.Add($path) }
            $fakeSelection=[pscustomobject]@{Path=$fakeCli;Version='offline-only';Sha256=(Get-FileHash -LiteralPath $fakeCli -Algorithm SHA256).Hash.ToLowerInvariant()}
            $bound=New-LiveGateInputs -SkillRoot $fakeSkill -Gate 'schema_gate' -ActualCli $fakeSelection -DisableSet @('apps') -AgentsPath $fakeAgents
            $inputRecords.Add($bound)
            Assert-Throws { [IO.File]::AppendAllText((Join-Path $fakeSkill 'schemas/verdict.schema.json'),'changed') } 'tested schema stays read-only until process retirement is confirmed'
            Assert-Throws { Complete-LiveGateInputs -Inputs $bound -ProcessTreeRetired 1 } 'numeric truth cannot release execution input leases'
            Complete-LiveGateInputs -Inputs $bound -ProcessTreeRetired $true
            $manifestLease=[IO.FileStream]::new($fakePremises,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
            try {
                $script:LiveGateInputs[$bound.Token] | Add-Member -NotePropertyName ManifestWriter -NotePropertyValue $manifestLease -Force
                Assert-Throws { [IO.File]::AppendAllText($fakePremises,'changed') } 'evidence transaction excludes a concurrent calibration writer'
                $manifestBindingAccepted=$false
                try { Assert-LiveGateInputs -Inputs $bound -RequireReleased; $manifestBindingAccepted=$true } catch { }
                Assert-True $manifestBindingAccepted 'evidence checks the captured manifest through its held transaction stream'
            } finally {
                $script:LiveGateInputs[$bound.Token].ManifestWriter=$null
                $manifestLease.Dispose()
            }
            $inputStampProbe=[Collections.Generic.List[string]]::new()
            Invoke-LiveGateStamp -FailureCount 0 -CleanupResults @([pscustomobject]@{Accepted=$true}) -Inputs $bound -Stamp { $inputStampProbe.Add('accepted') }
            Assert-Eq $inputStampProbe.Count 1 'unchanged captured inputs permit the inert stamp callback'
            foreach ($driftPath in @($fakeCli,$fakeAgents,(Join-Path $fakeSkill 'schemas/verdict.schema.json'),(Join-Path $fakeSkill 'scripts/publish-review.ps1'),(Join-Path $inputFixture.Path 'tests/live/live-schema-gate.ps1'),$fakePremises)) {
                $bound=New-LiveGateInputs -SkillRoot $fakeSkill -Gate 'schema_gate' -ActualCli $fakeSelection -DisableSet @('apps') -AgentsPath $fakeAgents
                $inputRecords.Add($bound)
                Complete-LiveGateInputs -Inputs $bound -ProcessTreeRetired $true
                $original=[IO.File]::ReadAllBytes($driftPath)
                try {
                    [IO.File]::AppendAllText($driftPath,"`nchanged")
                    $inputStampProbe.Clear()
                    Assert-Throws { Invoke-LiveGateStamp -FailureCount 0 -CleanupResults @([pscustomobject]@{Accepted=$true}) -Inputs $bound -Stamp { $inputStampProbe.Add('accepted') } } "changed captured input refuses evidence ($([IO.Path]::GetFileName($driftPath)))"
                    Assert-Eq $inputStampProbe.Count 0 'input drift never invokes the inert evidence callback'
                } finally { [IO.File]::WriteAllBytes($driftPath,$original) }
            }
            $unknownInputs=[pscustomobject]@{Token=[guid]::NewGuid().ToString('n')}
            Assert-Throws { Invoke-LiveGateStamp -FailureCount 0 -CleanupResults @([pscustomobject]@{Accepted=$true}) -Inputs $unknownInputs -Stamp { throw 'must not enter writer' } } 'caller supplied input tokens cannot authorize a stamp'
        } finally {
            foreach ($bound in $inputRecords) { Complete-LiveGateInputs -Inputs $bound -ProcessTreeRetired $true }
            foreach ($path in $fixtureFiles) { [IO.File]::Delete($path) }
            for ($directoryIndex=$fixtureDirectories.Count-1; $directoryIndex -ge 0; $directoryIndex--) { [IO.Directory]::Delete((Join-Path $inputFixture.Path $fixtureDirectories[$directoryIndex]),$false) }
        }
    }

    # Load only the production tracker function AST, never the live gate's top-level body.
    $tokens = $null; $errors = $null
    $securityAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'live/live-security.ps1'), [ref]$tokens, [ref]$errors)
    $tracker = $securityAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-SecurityProcess' }, $true)
    Assert-True ($null -ne $tracker) 'security gate tracks every owned process before launching it'
    if ($null -ne $tracker) {
        . ([scriptblock]::Create($tracker.Extent.Text))
        $script:SecurityProcessRuns = [Collections.Generic.List[object]]::new()
        $job = Invoke-SecurityProcess -FileName $pwsh -ArgList @('-NoProfile','-Command','exit 0') -TimeoutSec 10 -ClearEnvironment -EnvironmentMap @{SystemRoot=$env:SystemRoot}
        Assert-Eq $script:SecurityProcessRuns.Count 1 'real tracked local launch creates one ownership entry'
        Assert-True $script:SecurityProcessRuns[0].ProcessTreeRetired 'tracker records only the runner confirmed retirement'
        Assert-True $job.ProcessTreeRetired 'tracker preserves the physical runner result'
        Assert-Throws { Invoke-SecurityProcess -FileName $pwsh -TimeoutSec 0 -ClearEnvironment -EnvironmentMap @{SystemRoot=$env:SystemRoot} } 'tracker propagates a real runner binding failure'
        Assert-Eq $script:SecurityProcessRuns.Count 2 'failed launch still has a preexisting ownership entry'
        Assert-True (-not $script:SecurityProcessRuns[1].ProcessTreeRetired) 'incomplete runner cannot acquire retirement proof'
    }
} catch {
    Assert-True $false "offline cleanup acceptance aborted: $($_.Exception.Message)"
} finally {
    # Every target below is an exact fixture returned by this run's creation API.
    # No unknown entry is swept and no recursive remover is invoked by this suite.
    foreach ($record in $owned) {
        if ($script:LiveGateDirectories.ContainsKey($record.Token)) {
            $remainingOwner = $script:LiveGateDirectories[$record.Token]
            if ($remainingOwner.PSObject.Properties['Custody']) { $remainingOwner.Custody.Dispose() }
        }
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
