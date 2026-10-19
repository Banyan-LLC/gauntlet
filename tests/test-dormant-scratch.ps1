param(
    [string]$FixtureExecutable=[Environment]::ProcessPath,
    [string]$ExpectedFixtureVersion=$PSVersionTable.PSVersion.ToString(),
    [int]$ExpectedDotnetMajor=[Environment]::Version.Major
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/helpers.ps1"
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $repo 'gauntlet-review/scripts/lib.ps1')
Assert-True ($IsWindows -is [bool] -and $IsWindows) 'scratch custody controls run on the supported Windows platform'
$bootstrap=Join-Path $PSScriptRoot 'fixtures/dormant-scratch-isolated.ps1'
foreach($name in @(
    'dormant-scratch-helper.ps1','dormant-native-scratch.ps1','dormant-native-cleanup.ps1',
    'dormant-scratch-deadline-harness.cs','dormant-scratch-admission.cs',
    'dormant-scratch-deadlines.ps1','dormant-scratch-admission.ps1','dormant-scratch-isolated.ps1'
)){
    Assert-True ([IO.File]::Exists((Join-Path $PSScriptRoot ('fixtures/'+$name)))) ($name+' complete fixture exists')
}
if($script:Failures.Count){Write-TestResult}
$expectedPath=[IO.Path]::GetFullPath($FixtureExecutable)
foreach($name in @('scratch','cleanup','deadlines','admission')){
    $childArgs=@('-NoProfile','-File',$bootstrap,'-Case',$name,'-RepoRoot',$repo,
        '-ExpectedExecutable',$expectedPath,'-ExpectedVersion',$ExpectedFixtureVersion,
        '-ExpectedDotnetMajor',$ExpectedDotnetMajor.ToString([Globalization.CultureInfo]::InvariantCulture))
    $result=Invoke-BoundedProcess -FileName $expectedPath -ArgList $childArgs -WorkingDirectory $repo -TimeoutSec 180 -RequireProcessTreeRetirement
    Write-Host $result.Stdout
    if($result.Stderr){Write-Host $result.Stderr}
    Assert-True ($result.StartFailed -is [bool] -and -not $result.StartFailed -and
        $result.TimedOut -is [bool] -and -not $result.TimedOut -and
        $result.ExitCode -is [int] -and $result.ExitCode -eq 0 -and
        $result.ProcessTreeRetired -is [bool] -and $result.ProcessTreeRetired -and
        $null -eq $result.ErrorMessage) ($name+' fresh child succeeds with actual main-runner tree retirement')
    [ordered]@{case=$name;executable=$expectedPath;ExitCode=$result.ExitCode;StartFailed=$result.StartFailed;
        TimedOut=$result.TimedOut;ProcessTreeRetired=$result.ProcessTreeRetired;ErrorMessage=$result.ErrorMessage}|
        ConvertTo-Json -Compress|Write-Output
}
Write-TestResult
