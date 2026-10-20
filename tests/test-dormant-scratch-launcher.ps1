param(
    [string]$FixtureExecutable=[Environment]::ProcessPath,
    [string]$ExpectedFixtureVersion=$PSVersionTable.PSVersion.ToString(),
    [int]$ExpectedDotnetMajor=[Environment]::Version.Major
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/helpers.ps1"
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $repo 'gauntlet-review/scripts/lib.ps1')
. "$PSScriptRoot/fixtures/dormant-scratch-helper.ps1"
$owner=New-DormantScratchOwner -Prefix scratch-launch-refusal -TimeoutSec 150
$primary=$null
try{
    $owner.Initialize()
    # Copy the actual bootstrap bytes into an original sealed scratch leaf.
    # Only its five external fixture boundaries are controlled here.
    $bootstrapText=[IO.File]::ReadAllText("$PSScriptRoot/fixtures/dormant-scratch-isolated.ps1")
    $owner.WriteText('dormant-scratch-isolated.ps1',$bootstrapText)
    foreach($file in @('dormant-native-scratch.ps1','dormant-native-cleanup.ps1','dormant-scratch-deadlines.ps1','dormant-scratch-admission.ps1','dormant-scratch-lifecycle.ps1')){
        $owner.WriteText($file,'param([string]$RepoRoot)'+[Environment]::NewLine+'Write-Output "INTENTIONAL_NESTED_EXIT_37"'+[Environment]::NewLine+'exit 37'+[Environment]::NewLine)
    }
    foreach($file in @('dormant-scratch-helper.ps1','dormant-scratch-deadline-harness.cs','dormant-scratch-admission.cs','dormant-scratch-lifecycle.cs')){
        $owner.WriteText($file,'// Intentionally unused fixture-existence control.')
    }
    $expectedPath=[IO.Path]::GetFullPath($FixtureExecutable)
    foreach($case in @('scratch','cleanup','deadlines','admission','lifecycle')){
        $childArgs=@('-NoProfile','-File',$owner.FilePath('dormant-scratch-isolated.ps1'),'-Case',$case,'-RepoRoot',$repo,
            '-ExpectedExecutable',$expectedPath,'-ExpectedVersion',$ExpectedFixtureVersion,'-ExpectedDotnetMajor',$ExpectedDotnetMajor.ToString())
        $result=Invoke-BoundedProcess -FileName $expectedPath -ArgList $childArgs -WorkingDirectory $repo -TimeoutSec 30 -RequireProcessTreeRetirement
        Assert-True ($result.ExitCode -is [int] -and $result.ExitCode -eq 37 -and $result.StartFailed -is [bool] -and -not $result.StartFailed -and
            $result.TimedOut -is [bool] -and -not $result.TimedOut -and $result.ProcessTreeRetired -is [bool] -and $result.ProcessTreeRetired -and
            $null -eq $result.ErrorMessage -and $result.Stdout.Contains('INTENTIONAL_NESTED_EXIT_37')) ($case+' bootstrap propagates the actual nested fixture exit37 with original tree retirement')
        [ordered]@{control='nested_exit';case=$case;ExitCode=$result.ExitCode;StartFailed=$result.StartFailed;TimedOut=$result.TimedOut;
            ProcessTreeRetired=$result.ProcessTreeRetired;ErrorMessage=$result.ErrorMessage}|ConvertTo-Json -Compress|Write-Output
    }
    $launcherArgs=@('-NoProfile','-File',"$PSScriptRoot/test-dormant-scratch.ps1",'-FixtureDirectory',$owner.Path,
        '-FixtureExecutable',$expectedPath,'-ExpectedFixtureVersion',$ExpectedFixtureVersion,'-ExpectedDotnetMajor',$ExpectedDotnetMajor.ToString())
    $result=Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList $launcherArgs -WorkingDirectory $repo -TimeoutSec 150 -RequireProcessTreeRetirement
    # Preserve the complete expected-negative child output as a structured
    # receipt, distinct from this test's own assertion summary.
    [ordered]@{control='expected_launcher_failure';ExitCode=$result.ExitCode;StartFailed=$result.StartFailed;
        TimedOut=$result.TimedOut;ProcessTreeRetired=$result.ProcessTreeRetired;ErrorMessage=$result.ErrorMessage;
        Stdout=$result.Stdout;Stderr=$result.Stderr}|ConvertTo-Json -Compress -Depth 8|Write-Output
    $receipts=@($result.Stdout -split '\r?\n'|Where-Object {$_ -match '^\{"case":'}|ForEach-Object {$_|ConvertFrom-Json}|Where-Object {$_.PSObject.Properties.Name -contains 'ExitCode'})
    $failedChildren=@($receipts|Where-Object {$_.ExitCode -is [long] -or $_.ExitCode -is [int]}|Where-Object {
        $_.ExitCode -eq 37 -and $_.StartFailed -is [bool] -and -not $_.StartFailed -and $_.TimedOut -is [bool] -and -not $_.TimedOut -and
        $_.ProcessTreeRetired -is [bool] -and $_.ProcessTreeRetired -and $null -eq $_.ErrorMessage})
    Assert-True ($result.ExitCode -is [int] -and $result.ExitCode -eq 1 -and $result.StartFailed -is [bool] -and -not $result.StartFailed -and
        $result.TimedOut -is [bool] -and -not $result.TimedOut -and $result.ProcessTreeRetired -is [bool] -and $result.ProcessTreeRetired -and
        $null -eq $result.ErrorMessage -and $receipts.Count -eq 5 -and $failedChildren.Count -eq 5) 'actual launcher refuses all five nested failures and retires its original process tree'
}catch{$primary=$_;throw}finally{Complete-DormantScratchCleanup -Primary $primary -Actions @({$owner.Cleanup()})}
Assert-True $owner.Retired 'negative launcher controls retire only their original scratch custody'
Write-TestResult
