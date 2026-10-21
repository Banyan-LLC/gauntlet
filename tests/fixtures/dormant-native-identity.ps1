# Fixture cleanup preservation v1: primary and independent cleanup errors.
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
$library=Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1'
$registryBefore=[AppDomain]::CurrentDomain.GetData('GauntletReview.OwnerRegistries.v1')
. $library
Assert-True ($null -eq ([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type) 'loading dormant functions leaves native type absent'
Assert-True ([object]::ReferenceEquals($registryBefore,[AppDomain]::CurrentDomain.GetData('GauntletReview.OwnerRegistries.v1'))) 'loading dormant functions creates no owner registries'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($library,[ref]$tokens,[ref]$errors)
Assert-Eq $errors.Count 0 'complete dormant definition file parses'
$nonFunctions=@($ast.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst] -and $_.Extent.Text -cne 'Set-StrictMode -Version Latest'})
Assert-Eq $nonFunctions.Count 0 'dormant file contains only definitions and explicit strict-mode setup'
Add-Type -TypeDefinition 'namespace GauntletLive { public static class Native { public static string SourceIdentity { get { return "foreign-source"; } } } }'
$foreign=([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type
$failure=$null
try{Initialize-LiveGateNative}catch{$failure=$_.Exception}
Assert-True ($null -ne $failure -and $failure.Message.Contains('Loaded live-gate native helper differs')) 'actual initializer refuses a different loaded native source'
Assert-True ([object]::ReferenceEquals($foreign,([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type)) 'refusal never replaces or authorizes foreign native type'
Write-TestResult
