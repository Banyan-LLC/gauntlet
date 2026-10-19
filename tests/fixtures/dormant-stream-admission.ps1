param([Parameter(Mandatory)][string]$RepoRoot,[string]$Source,[string]$ExpectedSha,[string]$Fixture)
$ErrorActionPreference='Stop'
if(-not $Source){$Source=Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1'}
if(-not $Fixture){$Fixture=Join-Path $RepoRoot 'tests/fixtures/dormant-stream-admission-case.ps1'}
if(-not $ExpectedSha){$ExpectedSha=(Get-FileHash $Source -Algorithm SHA256).Hash.ToLowerInvariant()}
$before=(Get-FileHash $Source -Algorithm SHA256).Hash.ToLowerInvariant()
if($before -cne $ExpectedSha){throw 'Source pin mismatch'}
$cases=@('aggregate','override','nested','oversized','win32','socket','json','http','runtime','jsonoversized','datatext','datagraph','details','errorid','datakey','faultdata','mutation_count','mutation_key','mutation_value','mutation_text','mutation_tags')
$passed=0;$inventory=@()
foreach($case in $cases){
 $text=@(& ([Environment]::ProcessPath) -NoProfile -File $Fixture -RepoRoot $RepoRoot -Source $Source -Case $case 2>&1)
 $exit=$LASTEXITCODE
 $text|Write-Output
 if($exit -ne 0 -or ($text -join "`n") -notmatch '(\d+) passed, 0 failed'){throw ('Fresh child failed: '+$case)}
 $passed+=[int]$Matches[1]
 $json=@($text|Where-Object {$_ -is [string] -and $_.StartsWith('{')})[-1]|ConvertFrom-Json
 if($json.getter_calls -ne 0 -or $json.allocated_bytes -ge 1000000){throw ('Admission proof failed: '+$case)}
 $inventory+=@{case=$case;exit=$exit;proof=$json}
}
$after=(Get-FileHash $Source -Algorithm SHA256).Hash.ToLowerInvariant()
if($before -cne $after){throw 'Source changed during regression'}
[ordered]@{runtime=$PSVersionTable.PSVersion.ToString();source_sha=$after;fresh_children=$inventory;assertions=$passed;source_stable=$true}|ConvertTo-Json -Depth 8 -Compress|Write-Output
Write-Output ($passed.ToString()+' passed, 0 failed; 21 fresh children: 20 original guarded workers and one standalone stop-failure projection')
