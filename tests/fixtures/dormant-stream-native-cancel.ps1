param([Parameter(Mandatory)][string]$RepoRoot,[string]$Source,[string]$Fixture)
$ErrorActionPreference='Stop'
if(-not $Source){$Source=Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1'}
if(-not $Fixture){$Fixture=Join-Path $PSScriptRoot 'dormant-stream-native-cancel-case.ps1'}
$before=(Get-FileHash $Source -Algorithm SHA256).Hash.ToLowerInvariant()
$passed=0;$inventory=@()
foreach($index in 0..8){
 $legacy=$index -eq 8
 $channel=if($legacy){2}else{$index}
 [string[]]$extra=if($legacy){@('-LegacyMilliseconds')}else{@()}
 $text=@(& ([Environment]::ProcessPath) -NoProfile -File $Fixture -RepoRoot $RepoRoot -Source $Source -Channel $channel @extra 2>&1)
 $exit=$LASTEXITCODE
 $text|Write-Output
 if($exit -ne 0 -or ($text -join [Environment]::NewLine) -notmatch '(\d+) passed, 0 failed'){throw ('Fresh original native child failed for stream channel '+$channel)}
 $passed+=[int]$Matches[1]
 $proof=@($text|Where-Object {$_ -is [string] -and $_.StartsWith('{')})[-1]|ConvertFrom-Json
 $inventory+=@{channel=$channel;legacy_milliseconds=$legacy;exit=$exit;proof=$proof}
}
foreach($inline in @($false,$true)){
 [string[]]$extra=if($inline){@('-Inline')}else{@()}
 $text=@(& ([Environment]::ProcessPath) -NoProfile -File $Fixture -RepoRoot $RepoRoot -Source $Source -Channel 7 -HoldCallerCallback @extra 2>&1)
 $exit=$LASTEXITCODE;$text|Write-Output
 if($exit -ne 0 -or ($text -join [Environment]::NewLine) -notmatch '(\d+) passed, 0 failed'){throw 'Original callback cohort control failed'}
 $passed+=[int]$Matches[1]
 $proof=@($text|Where-Object {$_ -is [string] -and $_.StartsWith('{')})[-1]|ConvertFrom-Json
 $inventory+=@{channel=7;kind='caller_cohort';inline=$inline;exit=$exit;proof=$proof}
}
foreach($constructor in @('precanceled','partial','partial_precanceled','unknown')){
 $text=@(& ([Environment]::ProcessPath) -NoProfile -File $Fixture -RepoRoot $RepoRoot -Source $Source -ConstructorCase $constructor 2>&1)
 $exit=$LASTEXITCODE;$text|Write-Output
 if($exit -ne 0 -or ($text -join [Environment]::NewLine) -notmatch '(\d+) passed, 0 failed'){throw ('Original constructor control failed: '+$constructor)}
 $passed+=[int]$Matches[1]
 $proof=@($text|Where-Object {$_ -is [string] -and $_.StartsWith('{')})[-1]|ConvertFrom-Json
 $inventory+=@{kind='constructor';case=$constructor;exit=$exit;proof=$proof}
}
$disposal=Join-Path $PSScriptRoot 'dormant-stream-native-disposal.ps1'
$text=@(& ([Environment]::ProcessPath) -NoProfile -File $disposal -RepoRoot $RepoRoot -Source $Source 2>&1)
$exit=$LASTEXITCODE;$text|Write-Output
if($exit -ne 0 -or ($text -join [Environment]::NewLine) -notmatch '(\d+) passed, 0 failed'){throw 'Fresh original independent disposal control failed'}
$passed+=[int]$Matches[1]
$after=(Get-FileHash $Source -Algorithm SHA256).Hash.ToLowerInvariant()
if($before -cne $after){throw 'Source changed during stream-to-native cancellation regression'}
[ordered]@{runtime=$PSVersionTable.PSVersion.ToString();source_sha=$after;source_stable=$true;fresh_children=$inventory;assertions=$passed}|ConvertTo-Json -Depth 10 -Compress|Write-Output
Write-Output ($passed.ToString()+' passed, 0 failed; 9 fresh native controls and 2 original callback cohorts and 4 original constructor controls and independent three-resource disposal')
