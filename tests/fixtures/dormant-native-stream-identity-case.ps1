param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][ValidateSet('boolean','missing','instance','unicode','writeonly','throwing')][string]$Mode)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. $Source
$definition=(Get-Command Initialize-ReviewOwnedStreams).ScriptBlock
$strings=@($definition.Ast.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.StartsWith('using System;',[StringComparison]::Ordinal)},$true))
if($strings.Count -ne 1){throw 'Fixture refuses changed actual stream source AST'}
$expected=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($strings[0].Value))).ToLowerInvariant()
$property=switch($Mode){
 'boolean'{'public static bool SourceIdentity {get{return true;}}'}
 'missing'{''}
 'instance'{'public string SourceIdentity {get{return "'+$expected+'";}}'}
 'unicode'{'public static string SourceIdentity {get{return "'+$expected+'\u00ad";}}'}
 'writeonly'{'public static string SourceIdentity {set{}}'}
 'throwing'{'public static string SourceIdentity {get{throw new System.IO.IOException("SENSITIVE-IDENTITY-GETTER");}}'}
}
Add-Type -TypeDefinition ('namespace GauntletOwnedWork { public sealed class StreamGuard {'+$property+'} }') -ErrorAction Stop
$foreign='GauntletOwnedWork.StreamGuard' -as [type]
$caught=$null;try{Initialize-ReviewOwnedStreams}catch{$caught=$_.Exception}
Assert-True ($caught -is [InvalidOperationException] -and $caught.Data['ReviewCode'] -ceq 'owned_stream_source_mismatch' -and $caught.Data['ReviewStage'] -ceq 'worker_stream_init') "$Mode helper guard uses typed stable refusal without coercion"
Assert-True ([object]::ReferenceEquals($foreign,('GauntletOwnedWork.StreamGuard' -as [type]))) "$Mode guard refuses without replacing foreign type"
function Invoke-ForbiddenIdentityWorker {param($State,$Arguments)try{$State['ForbiddenAction']=$true}finally{$State['CoreRetired']=$true}}
$registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$defs=Get-ReviewWorkerDefinitions -LibraryDefinition (Get-Command Invoke-ReviewOwnedWork).ScriptBlock
$defs['Invoke-ForbiddenIdentityWorker']=(Get-Command Invoke-ForbiddenIdentityWorker).ScriptBlock
$result=Invoke-ReviewOwnedWork -Kind stream_identity -OwnerRegistry $registry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+5L*[Diagnostics.Stopwatch]::Frequency) -WorkerName Invoke-ForbiddenIdentityWorker -Definitions $defs -Arguments @{} -State $state
Assert-True ($result.Failure.Code -ceq 'owned_stream_source_mismatch' -and -not $result.Completed -and $null -eq $result.Result -and -not $state.ContainsKey('ForbiddenAction')) "$Mode actual original creation task preserves guard refusal code and never dispatches worker"
Assert-True (($result.Failure|ConvertTo-Json -Depth 12 -Compress) -notmatch 'SENSITIVE-|StackTrace|SourceIdentity|Pipeline|Registry') "$Mode public guard cause excludes raw getter/source diagnostics and authority"
$watch=[Diagnostics.Stopwatch]::StartNew()
while($registry.Count -gt 0 -and $watch.ElapsedMilliseconds -lt 3000){$null=Complete-ReviewOwnedWork -OwnerRegistry $registry;Start-Sleep -Milliseconds 10}
Assert-Eq $registry.Count 0 "$Mode exact original initializer pipeline physically settles after refusal"
Assert-True ($null -eq ('GauntletLive.Native' -as [type])) "$Mode stream helper refusal preserves cold native process type"
Write-TestResult
