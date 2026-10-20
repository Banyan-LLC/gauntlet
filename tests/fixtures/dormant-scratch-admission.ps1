param([string]$HelperPath="$PSScriptRoot/dormant-scratch-helper.ps1")
$ErrorActionPreference='Stop'
$helper=[IO.File]::ReadAllText($HelperPath)
$marker="$"+"source=@'"
$start=$helper.IndexOf($marker)+$marker.Length
$end=$helper.IndexOf("'@",$start,[StringComparison]::Ordinal)
if($start -lt $marker.Length -or $end -lt $start){throw 'Embedded helper source unavailable'}
$source=$helper.Substring($start,$end-$start)
$identity=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source))).ToLowerInvariant()
$source=$source.Replace('__IDENTITY__',$identity)
$harness=[IO.File]::ReadAllText("$PSScriptRoot/dormant-scratch-admission.cs")
# Compile the exact embedded helper and the fixture in one assembly. No
# production filesystem/native source is loaded, enabled, replaced or mocked.
Add-Type -TypeDefinition ($source+$harness) -ErrorAction Stop
exit [GauntletFixtureScratch.AdditionalAdmissionCases]::Run()
