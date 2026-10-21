param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][ValidateSet('boolean','unicode','missing','instance','platform','production')][string]$Case)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
$Source=Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1'
. $Source
$initializer=(Get-Command Initialize-LiveGateNative).ScriptBlock
if($Case -ceq 'platform'){
    $body=$initializer.ToString()
    $needle='if (-not $IsWindows)'
    if([regex]::Matches($body,[regex]::Escape($needle)).Count -ne 1){throw 'Platform guard instrumentation no longer exact'}
    $instrumented=$body.Replace($needle,'if ($true)')
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($instrumented,$initializer.File,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Instrumented guard parse failed'}
    Set-Item Function:Initialize-LiveGateNative $ast.GetScriptBlock()
}elseif($Case -ceq 'production'){
    $originalLibrary=(Join-Path $RepoRoot 'gauntlet-review/scripts/lib.ps1')
    $tokens=$null;$errors=$null;$originalAst=[Management.Automation.Language.Parser]::ParseFile($originalLibrary,[ref]$tokens,[ref]$errors)
    $definitions=@($originalAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Initialize-LiveGateNative'},$false))
    if($errors.Count -or $definitions.Count -ne 1){throw 'Actual unchanged production initializer is ambiguous'}
    $productionFailure=$null
    try{& $definitions[0].Body.GetScriptBlock()}catch{$productionFailure=$_}
    if($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -eq 2){
        Assert-True ($null -ne $productionFailure) 'unchanged actual production native helper still exposes the documented .NET6 compile baseline'
        Assert-True ($null -eq ([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type) 'failed unchanged floor compilation cannot create a pretend production type'
        $text=if($null -ne $productionFailure){$productionFailure.ToString()}else{''}
        Assert-True ($text.Contains('HashData') -or $text.Contains('System.IO.FileStream')) 'actual production floor failure matches the explicitly deferred stream-hash baseline'
        Write-TestResult
    }
    if($null -ne $productionFailure){throw $productionFailure}
    Assert-True ($null -ne ([Management.Automation.PSTypeName]::new('GauntletLive.Native')).Type) 'exact unchanged production native type is genuinely compiled before guard test'
}else{
    $body=$initializer.ToString();$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($body,$initializer.File,[ref]$tokens,[ref]$errors)
    $cs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('namespace GauntletLive {')},$true))
    if($cs.Count -ne 1){throw 'Native identity source is ambiguous'}
    $identity=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($cs[0].Value))).ToLowerInvariant()
    $property=switch($Case){
      boolean {'public static bool SourceIdentity {get{return true;}}'}
      unicode {'public static string SourceIdentity {get{return "'+$identity.Substring(0,32)+'\u200B'+$identity.Substring(32)+'";}}'}
      missing {'public static int Other {get{return 1;}}'}
      instance {'public string SourceIdentity {get{return "'+$identity+'";}}'}
    }
    $modifier=if($Case -ceq 'instance'){''}else{'static '}
    Add-Type ('namespace GauntletLive {public '+$modifier+'class Native {'+$property+'}}') -ErrorAction Stop
}
$failure=$null
try{Initialize-LiveGateNative}catch{$failure=$_.Exception}
$code=if($Case -ceq 'platform'){'native_platform_unsupported'}else{'native_source_identity'}
Assert-True ($null -ne $failure) "$Case refuses original foreign/platform admission"
if($null -ne $failure){
 Assert-True ($failure -is [InvalidOperationException] -or $failure -is [PlatformNotSupportedException]) "$Case typed guard exception"
 Assert-Eq $failure.Data['ReviewCode'] $code "$Case stable direct admission code"
 Assert-Eq $failure.Data['ReviewStage'] 'native_initialization' "$Case stable direct admission stage"
}
$core=Invoke-BoundedProcessCore -FileName 'synthetic-never-executed.exe' -TimeoutSec 5 -RequireProcessTreeRetirement
Assert-True ($core.StartFailed -and -not $core.TimedOut -and $null -ne $core.Failure) "$Case core fails before native creation"
Assert-Eq $core.Failure.Code $code "$Case flat core retains guard code"
Assert-Eq $core.Failure.Stage 'native_initialization' "$Case flat core retains guard stage"
$facade=Invoke-BoundedProcess -FileName 'synthetic-never-executed.exe' -TimeoutSec 10 -RequireProcessTreeRetirement
Assert-True ($facade.StartFailed -and -not $facade.TimedOut -and $facade.ProcessTreeRetired -and $null -eq $facade.NativeProcessResult) "$Case public facade confirms no native result and physically settled worker"
Assert-Eq $facade.Failure.Code $code "$Case public facade retains guard code"
Assert-Eq $facade.Failure.Stage 'native_initialization' "$Case public facade retains guard stage"
Write-TestResult
