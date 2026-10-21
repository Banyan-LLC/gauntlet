param([Parameter(Mandatory)][string]$PipeName,[Parameter(Mandatory)][string]$Nonce,[Parameter(Mandatory)][int]$ServerPid,[Parameter(Mandatory)][long]$Deadline)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'dormant-stream-native-pipe.ps1')
[NativeFixturePipe]::Send($PipeName,$Nonce,$ServerPid,$Deadline)
Start-Sleep -Seconds 30
