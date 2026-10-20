param(
    [Parameter(Mandatory)][ValidateSet('scratch','cleanup','deadlines','admission','lifecycle')][string]$Case,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ExpectedExecutable,
    [Parameter(Mandatory)][string]$ExpectedVersion,
    [Parameter(Mandatory)][int]$ExpectedDotnetMajor
)
$ErrorActionPreference='Stop'
$actual=[Environment]::ProcessPath
if(-not [string]::Equals([IO.Path]::GetFullPath($actual),[IO.Path]::GetFullPath($ExpectedExecutable),[StringComparison]::OrdinalIgnoreCase) -or
   $PSVersionTable.PSVersion.ToString() -cne $ExpectedVersion -or [Environment]::Version.Major -ne $ExpectedDotnetMajor){
    throw 'Actual isolated fixture executable or runtime differs'
}
if($null -ne ('GauntletLive.Native' -as [type])){throw 'Scratch child must start without the production native type'}
[ordered]@{case=$Case;runtime=$PSVersionTable.PSVersion.ToString();dotnet=[Environment]::Version.ToString();executable=$actual;cold_native=$true}|
    ConvertTo-Json -Compress|Write-Output
$global:LASTEXITCODE=0
switch($Case){
    'scratch' {& "$PSScriptRoot/dormant-native-scratch.ps1" -RepoRoot $RepoRoot}
    'cleanup' {& "$PSScriptRoot/dormant-native-cleanup.ps1" -RepoRoot $RepoRoot}
    'deadlines' {& "$PSScriptRoot/dormant-scratch-deadlines.ps1"}
    'admission' {& "$PSScriptRoot/dormant-scratch-admission.ps1"}
    'lifecycle' {& "$PSScriptRoot/dormant-scratch-lifecycle.ps1"}
}
exit $global:LASTEXITCODE
