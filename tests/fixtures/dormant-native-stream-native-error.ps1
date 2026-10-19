param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$Source)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. $Source
$original=(Get-Command Invoke-BoundedProcessCore).ScriptBlock
Set-Item Function:Invoke-FixtureNativeCore $original
function Invoke-BoundedProcessCore {
 param($FileName,$ArgList,$StdinText,$WorkingDirectory,$TimeoutSec,$TimeoutMilliseconds,$DeadlineTimestamp,$EnvironmentMap,$FailureCancellationToken,[switch]$ClearEnvironment,[switch]$RequireProcessTreeRetirement)
 Write-Error -Exception ([ComponentModel.Win32Exception]::new(5,'SENSITIVE-STREAM-NATIVE-CONTROL')) -ErrorAction Continue
 Invoke-FixtureNativeCore @PSBoundParameters
}
# Add only the saved original leaf dependency; all ownership/guard/projection
# functions remain the actual source functions and actual native cmd child.
$saved=(Get-Command Get-ReviewWorkerDefinitions).ScriptBlock
function Get-ReviewWorkerDefinitions {
 param([Parameter(Mandatory)][scriptblock]$LibraryDefinition)
 $ast=$LibraryDefinition.Ast;while($ast.Parent){$ast=$ast.Parent}
 $definitions=@{}
 foreach($function in $ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){$definitions[$function.Name]=(Get-Command $function.Name -CommandType Function).ScriptBlock}
 $definitions['Invoke-FixtureNativeCore']=(Get-Command Invoke-FixtureNativeCore).ScriptBlock
 return $definitions
}
try{
 $cmd=Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
 $result=Invoke-BoundedProcess -FileName $cmd -ArgList @('/d','/c','exit','0') -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutSec 10 -RequireProcessTreeRetirement
 Assert-True ($result.ExitCode -eq -1 -and $result.ProcessTreeRetired -and -not $result.StartFailed -and -not $result.TimedOut) 'ordinary below-cap error refuses aggregate while actual same original native tree physically retires'
 Assert-True ($null -ne $result.NativeProcessResult -and $result.NativeProcessResult.IsReadOnly -and $result.NativeProcessResult.Keys.Count -eq 6) 'ordinary drained error preserves exact immutable actual native six-field receipt'
 Assert-True ($result.NativeProcessResult.ExitCode -eq 0 -and $result.NativeProcessResult.ProcessTreeRetired -and -not $result.NativeProcessResult.StartFailed -and -not $result.NativeProcessResult.TimedOut -and $null -eq $result.NativeProcessResult.ErrorMessage) 'actual native successful scalars remain truthful after worker error refusal'
 Assert-True ($result.Failure.Code -ceq 'owned_error_stream' -and $result.Failure.Stage -ceq 'worker_invoke' -and $result.Failure.Type -ceq 'System.ComponentModel.Win32Exception' -and $result.Failure.NativeError -eq 5 -and $result.Failure.HResult -is [int] -and $result.Failure.Keys.Count -eq 5) 'ordinary error retains actual safe code type HResult NativeError in native flat-five projection'
 Assert-Eq $result.CleanupFailures.Count 0 'same first actual error is not duplicated by generic and native observations'
 Assert-True (($result.Failure|ConvertTo-Json -Depth 12 -Compress) -notmatch 'SENSITIVE-|Message|StackTrace|Pipeline|Registry') 'drained native error preserves only bounded structural diagnostics'
 Assert-Eq (Get-ReviewOwnerRegistry ReviewProcessOwners).Count 0 'ordinary native error observation physically settles original worker and explicit output disposer'
}finally{Set-Item Function:Invoke-BoundedProcessCore $original;Set-Item Function:Get-ReviewWorkerDefinitions $saved}
Write-TestResult
