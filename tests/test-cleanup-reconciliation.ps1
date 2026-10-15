# Offline owned-tree regression. Dummy bytes only; no Codex or account credentials.
. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'

function New-DummyProfile([int]$Directories) {
    $record=New-LiveGateDirectory -Kind Security
    $files=[Collections.Generic.List[string]]::new()
    $folders=[Collections.Generic.List[string]]::new()
    for ($i=0; $i -lt $Directories; $i++) {
        $folder=Join-Path $record.Path "profile-$i"
        [IO.Directory]::CreateDirectory($folder) | Out-Null
        $folders.Add($folder)
        foreach ($name in @('auth.json','state.txt')) {
            $file=Join-Path $folder $name
            [IO.File]::WriteAllText($file,'dummy-only',[Text.UTF8Encoding]::new($false))
            $files.Add($file)
        }
    }
    [pscustomobject]@{Record=$record;Files=$files;Folders=$folders;Identity=[GauntletLive.Native]::DirectoryIdentity($record.Path)}
}
function Complete-DummyProfile($Fixture) {
    $record=$Fixture.Record
    if (-not $script:LiveGateDirectories.ContainsKey($record.Token)) { return }
    $custody=$script:LiveGateDirectories[$record.Token].Custody
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while ($custody.Busy -and $timer.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 5 }
    if ($custody.Busy) { throw 'Dummy cleanup worker did not retire; preserving fixture' }
    $custody.Dispose()
    if ([IO.Directory]::Exists($record.Path)) {
        if ([GauntletLive.Native]::DirectoryIdentity($record.Path) -cne $Fixture.Identity) { throw 'Dummy root identity changed' }
        Assert-LiveGatePathComponents -Path $record.Path
        # Explicit producer paths only. This fallback lets a deliberately red regression clean
        # up its own dummy data; it never authorizes a replacement or an enumerated subtree.
        foreach ($file in $Fixture.Files) { [IO.File]::Delete($file) }
        for ($i=$Fixture.Folders.Count-1;$i -ge 0;$i--) { [IO.Directory]::Delete($Fixture.Folders[$i],$false) }
        [IO.Directory]::Delete($record.Path,$false)
    }
    $script:LiveGateDirectories.Remove($record.Token) | Out-Null
}

$small=$null; $large=$null
try {
    $small=New-DummyProfile 100
    $first=Remove-LiveGateDirectory -Record $small.Record -ProcessTreeRetired $true -AllowSecurityTreeCleanup -TimeoutMs 1
    Assert-True (-not $first.Accepted) 'first deadline reports unresolved cleanup without discarding ownership'
    Assert-True $script:LiveGateDirectories.ContainsKey($small.Record.Token) 'failed cleanup retains its exact original owner'
    $custody=$script:LiveGateDirectories[$small.Record.Token].Custody
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while ($custody.Busy -and $timer.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 5 }
    Assert-True (-not $custody.Busy) 'expired cleanup physically stops before a retry'
    $retry=Remove-LiveGateDirectory -Record $small.Record -ProcessTreeRetired $true -AllowSecurityTreeCleanup
    Assert-True $retry.Accepted "a fresh explicit attempt reconciles the original owner: $($retry.Error)"
    Assert-True (-not [IO.Directory]::Exists($small.Record.Path)) 'reconciled dummy credential tree is absent'

    $large=New-DummyProfile 1024
    $result=$null; $failure=$null
    try { $result=Remove-LiveGateDirectory -Record $large.Record -ProcessTreeRetired $true -AllowSecurityTreeCleanup -TimeoutMs 60000 }
    catch { $failure=$_.Exception.Message }
    Assert-True ($null -eq $failure) "security cleanup accepts its finite volume budget: $failure"
    Assert-True ($null -ne $result -and $result.Accepted) 'the observed 3000-entry profile volume cleans up under a finite budget'
    Assert-True (-not [IO.Directory]::Exists($large.Record.Path)) 'large dummy credential tree removal is verified'
} finally {
    if ($small) { Complete-DummyProfile $small }
    if ($large) { Complete-DummyProfile $large }
}
Write-TestResult
