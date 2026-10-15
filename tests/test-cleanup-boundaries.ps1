# Deterministic OS-boundary scheduling in an isolated native helper. Dummy data only.
. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference='Stop'
$initializer=(Get-Command Initialize-LiveGateNative).ScriptBlock.ToString()
$hooks=@'
        public static string DelayDispositionPath;
        public static int InventoryDelayMs, InventoryCalls;
        public static bool PauseClose, PauseObserver;
        public static ManualResetEventSlim CloseEntered=new ManualResetEventSlim(false), ReleaseClose=new ManualResetEventSlim(false);
        public static ManualResetEventSlim ObserverCompleted=new ManualResetEventSlim(false), ReleaseObserver=new ManualResetEventSlim(false);
        public static Task InspectAsync(Custody owner) { return Task.Run(() => owner.Inspect(2,100)); }
'@
$initializer=$initializer.Replace('public static class Native {', "public static class Native {`n$hooks")
# Delay AFTER the actual native disposition and its immediate state recording, before
# the next deadline observation. Both anchors exercise the real implementation.
$anchor=if ($initializer.Contains('Require(entry.DeleteRequested);')) { 'Require(entry.DeleteRequested);' }
        else { 'Require(SetFileInformationByHandle(entry.Handle,21,ref flags,4));' }
$initializer=$initializer.Replace($anchor, "$anchor if (String.Equals(entry.Path,DelayDispositionPath,StringComparison.OrdinalIgnoreCase)) Thread.Sleep(150);")
$inventory='var entries=Inventory(kind,kind == "Schema" ? 2 : 10000,clock,milliseconds,opened);'
$initializer=$initializer.Replace($inventory, "Interlocked.Increment(ref InventoryCalls); if (InventoryDelayMs != 0) Thread.Sleep(InventoryDelayMs); $inventory")
$initializer=$initializer.Replace('void CloseHandles() {', 'void CloseHandles() { if (PauseClose) { CloseEntered.Set(); ReleaseClose.Wait(TimeSpan.FromSeconds(5)); }')
$initializer=$initializer.Replace('} catch (Exception error) {', '} catch (Exception error) { if (PauseObserver) { ObserverCompleted.Set(); ReleaseObserver.Wait(TimeSpan.FromSeconds(5)); }')
& ([scriptblock]::Create($initializer))

function New-BoundaryFixture {
    $path=Join-Path ([IO.Path]::GetTempPath()) ('gauntlet-native-boundary-'+[guid]::NewGuid().ToString('N'))
    $custody=[GauntletLive.Native+Custody]::new()
    $custody.Create($path)
    [pscustomobject]@{Path=$path;Custody=$custody;Identity=[GauntletLive.Native]::DirectoryIdentity($path)}
}
function Wait-Worker($Fixture) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while ($Fixture.Custody.Busy -and $timer.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 5 }
    if ($Fixture.Custody.Busy) { throw 'Boundary fixture native worker did not retire' }
}
function Complete-BoundaryFixture($Fixture) {
    [GauntletLive.Native]::PauseClose=$false
    [GauntletLive.Native]::PauseObserver=$false
    [GauntletLive.Native]::ReleaseClose.Set()
    [GauntletLive.Native]::ReleaseObserver.Set()
    [GauntletLive.Native]::DelayDispositionPath=$null
    [GauntletLive.Native]::InventoryDelayMs=0
    Wait-Worker $Fixture
    $Fixture.Custody.Dispose()
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while (-not $Fixture.Custody.Released -and $timer.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 5 }
    if (-not $Fixture.Custody.Released) { throw 'Boundary fixture custody did not release' }
    if ([IO.Directory]::Exists($Fixture.Path)) {
        if ([GauntletLive.Native]::DirectoryIdentity($Fixture.Path) -cne $Fixture.Identity) { throw 'Boundary fixture identity changed' }
        Assert-LiveGatePathComponents -Path $Fixture.Path
        # Explicit fixture leaves only; no recursive deletion or discovery-based authority.
        foreach ($name in @('auth.json','locked.txt')) { [IO.File]::Delete((Join-Path $Fixture.Path $name)) }
        foreach ($name in @('child','unexpected-producer')) {
            $child=Join-Path $Fixture.Path $name
            if ([IO.Directory]::Exists($child)) { Assert-LiveGatePathComponents -Path $child; [IO.Directory]::Delete($child,$false) }
        }
        [IO.Directory]::Delete($Fixture.Path,$false)
    }
}

foreach ($target in @('root','child','file')) {
    $fixture=New-BoundaryFixture
    try {
        $delayed=if ($target -eq 'child') { $fixture.Custody.AddDirectory($fixture.Path,'child') }
                 elseif ($target -eq 'file') {
                     $fixture.Custody.WriteFile($fixture.Path,'auth.json',[Text.Encoding]::UTF8.GetBytes('dummy-only'))
                     Join-Path $fixture.Path 'auth.json'
                 } else { $fixture.Path }
        [GauntletLive.Native]::DelayDispositionPath=$delayed
        Assert-Throws { $fixture.Custody.Cleanup('Security',100) } "$target disposition followed by deadline fails closed"
        Wait-Worker $fixture
        [GauntletLive.Native]::DelayDispositionPath=$null
        $errorText=$null
        try { $fixture.Custody.Cleanup('Security',1000) } catch { $errorText=$_.Exception.Message }
        Assert-True ($null -eq $errorText) "$target original delete-pending handle reconciles: $errorText"
        Assert-True (-not [IO.Directory]::Exists($fixture.Path)) "$target reconciliation verifies original tree absent"
    } finally { Complete-BoundaryFixture $fixture }
}

$fixture=New-BoundaryFixture
try {
    [GauntletLive.Native]::InventoryDelayMs=150
    [GauntletLive.Native]::PauseClose=$true
    [GauntletLive.Native]::CloseEntered.Reset(); [GauntletLive.Native]::ReleaseClose.Reset()
    Assert-Throws { $fixture.Custody.Cleanup('Security',50) } 'delayed worker times out before disposal'
    $fixture.Custody.Dispose()
    Assert-True ([GauntletLive.Native]::CloseEntered.Wait(3000)) 'deferred disposal reaches handle closure after worker retires'
    Wait-Worker $fixture
    $before=[GauntletLive.Native]::InventoryCalls
    Assert-Throws { $fixture.Custody.Cleanup('Security',100) } 'cleanup refuses irreversible disposal intent'
    Assert-Eq ([GauntletLive.Native]::InventoryCalls) $before 'retry cannot enter native cleanup while deferred disposal is pending'
} finally { Complete-BoundaryFixture $fixture }

$fixture=New-BoundaryFixture
try {
    # Make Inspect fail before mutation, then pause its observer after the task is done.
    [GauntletLive.Native]::InventoryDelayMs=0
    [IO.File]::WriteAllText((Join-Path $fixture.Path 'locked.txt'),'dummy-only')
    $lock=[IO.File]::Open((Join-Path $fixture.Path 'locked.txt'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    [GauntletLive.Native]::PauseObserver=$true; [GauntletLive.Native]::PauseClose=$true
    [GauntletLive.Native]::ObserverCompleted.Reset(); [GauntletLive.Native]::ReleaseObserver.Reset()
    [GauntletLive.Native]::CloseEntered.Reset(); [GauntletLive.Native]::ReleaseClose.Reset()
    $observer=[GauntletLive.Native]::InspectAsync($fixture.Custody)
    Assert-True ([GauntletLive.Native]::ObserverCompleted.Wait(3000)) 'inspection observer pauses after its native task settles'
    $fixture.Custody.Dispose()
    [GauntletLive.Native]::ReleaseObserver.Set()
    Assert-True ([GauntletLive.Native]::CloseEntered.Wait(3000)) 'deferred release reaches native handle closure'
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while (-not $observer.IsCompleted -and $timer.ElapsedMilliseconds -lt 500) { Start-Sleep -Milliseconds 5 }
    Assert-True $observer.IsCompleted 'bounded observer retires while deferred handle closure remains blocked'
    Assert-True (-not $fixture.Custody.Released) 'physical release is not claimed before handle closure completes'
} finally {
    $lock.Dispose()
    Complete-BoundaryFixture $fixture
}

$fixture=New-BoundaryFixture
$lock=$null
try {
    $fixture.Custody.WriteFile($fixture.Path,'auth.json',[Text.Encoding]::UTF8.GetBytes('dummy-only'))
    [GauntletLive.Native]::InventoryDelayMs=150
    Assert-Throws { $fixture.Custody.Cleanup('Security',100) } 'first inventory timeout fences producers and readers'
    Wait-Worker $fixture
    [GauntletLive.Native]::InventoryDelayMs=0
    $locked=Join-Path $fixture.Path 'locked.txt'
    [IO.File]::WriteAllText($locked,'dummy-only')
    $lock=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    Assert-Throws { $fixture.Custody.Cleanup('Security',1000) } 'settled retry reports inventory sharing violation'
    Assert-Throws { $fixture.Custody.FileSha256((Join-Path $fixture.Path 'auth.json')) } 'failed retry never revives credential readers'
    Assert-Throws { $fixture.Custody.AddDirectory($fixture.Path,'unexpected-producer') } 'failed retry never revives producers'
    $lock.Dispose(); $lock=$null
    $fixture.Custody.Cleanup('Security',1000)
    Assert-True (-not [IO.Directory]::Exists($fixture.Path)) 'original custody still cleans after transient sharing failure'
} finally {
    if ($lock) { $lock.Dispose() }
    Complete-BoundaryFixture $fixture
}
Write-TestResult
