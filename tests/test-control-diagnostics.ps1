# Offline only. Exercise the real positive-control loop with synthetic CLI responses.
[CmdletBinding()]
param([string]$ArtifactRoot = [IO.Path]::GetTempPath(), [string]$GatePath = (Join-Path $PSScriptRoot 'live/live-security.ps1'))
. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference = 'Stop'
$fixtureRoot = Join-Path $ArtifactRoot ('control-diagnostics-test-' + [guid]::NewGuid().ToString('n'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$tokens=$null; $errors=$null
$gateAst=[Management.Automation.Language.Parser]::ParseFile($GatePath,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Security gate does not parse' }
foreach ($name in @('New-ControlDiagnosticStore','Add-ControlDiagnosticCredentials','Write-FailedControlDiagnostic',
    'Protect-ControlDiagnosticText','Test-ControlDiagnosticDecodedSecret','Get-ControlDiagnosticExcerpt','Assert-Usable','Get-NovelSignatures',
    'Assert-NovelSignatures','New-IsolatedArgs','Assert-WebIsolation','Assert-SandboxIsolation')) {
    $definition=$gateAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if ($definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
$positiveLoop=$gateAst.Find({param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Extent.Text.StartsWith('foreach ($c in $classControls)')},$true)
if (-not $positiveLoop) { throw 'Positive-control loop was not found' }
$loopBody=[scriptblock]::Create($positiveLoop.Extent.Text)
$hasStore=$null -ne (Get-Command New-ControlDiagnosticStore -ErrorAction SilentlyContinue)
$diagnosticStore=if ($hasStore) { New-ControlDiagnosticStore -Root $fixtureRoot -CredentialRoot (Join-Path $fixtureRoot 'credential-tree') } else { [pscustomobject]@{Path=$fixtureRoot} }
$allFeatures=@('apps','code_mode_host','shell_tool','plugins')
$cli=[pscustomobject]@{Path='C:\synthetic CLI\codex.exe'}
$narrowedClasses=@('computer_use','skills','subagents')
$credentialCanary='synthetic-credential-7b8c/"line'
$credentialDocument='{"tokens":{"access_token":"synthetic-credential-7b8c/\"line"}}'
$credentialBytes=[Text.Encoding]::UTF8.GetBytes($credentialDocument)
if ($hasStore) { Add-ControlDiagnosticCredentials -Store $diagnosticStore -Bytes $credentialBytes }
function New-ControlCwd { param($Name) return $fixtureRoot }
function New-ControlHome { param($Name) return $fixtureRoot }
function Invoke-Control {
    param($CodexHome,$CodexArgs,$Prompt,$WorkingDirectory)
    $script:CapturedArgv=@($CodexArgs)
    if ($script:ThrowControl) { throw 'synthetic launch exception' }
    return $script:FixtureResult
}
function Read-DiagnosticFixture {
    param([string]$Path)
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $reader=[IO.StreamReader]::new($stream); return $reader.ReadToEnd() }
    finally { $stream.Dispose() }
}
function Invoke-FixtureLoop {
    param($Control,$Result,[switch]$Throw)
    $classControls=@($Control)
    $positiveFired=@{}; $controlSignatures=@{}; $controlOutputs=@{}; $canaryFired=@{}
    $script:FixtureResult=$Result; $script:ThrowControl=[bool]$Throw
    $before=@($script:Failures.ToArray())
    $script:Failures.Clear()
    $caught=$null
    try { . $loopBody } catch { $caught=$_.Exception.Message }
    $controlFailures=$script:Failures.Count
    $script:Failures.Clear()
    foreach ($failure in $before) { $script:Failures.Add($failure) }
    return [pscustomobject]@{Failures=$controlFailures; Exception=$caught}
}
$noSignal=[pscustomobject]@{Usable=$true;Reason=$null;InputTokens=12;Stdout='{"type":"item.completed","item":{"type":"agent_message","text":"NO_APPS_AVAILABLE"}}';Stderr='synthetic apps error';ExitCode=0;TimedOut=$false;StartFailed=$false}
$apps=[pscustomobject]@{Name='apps';Kind='feature';AllowFeatures=@('apps','code_mode_host');Prompt='synthetic prompt'}
try {
    $outcome=Invoke-FixtureLoop -Control $apps -Result $noSignal
    Assert-Eq $outcome.Failures 1 'missing apps signal still fails the required positive assertion'
    $appsPath=Join-Path $diagnosticStore.Path 'apps.json'
    Assert-True ([IO.File]::Exists($appsPath)) 'a failed real positive-control branch retains evidence outside credentials'
    if (-not [IO.File]::Exists($appsPath)) { Write-TestResult }
    $record=Read-DiagnosticFixture $appsPath | ConvertFrom-Json
    Assert-Eq $record.Executable 'C:\synthetic CLI\codex.exe' 'diagnostics preserve the exact executable'
    Assert-Eq ($record.Argv -join '|') ($script:CapturedArgv -join '|') 'diagnostics preserve argument boundaries and exact invocation'
    Assert-Eq $record.Stdout $noSignal.Stdout 'missing-signal diagnostics preserve the model outcome'
    Assert-Eq $record.Stderr 'synthetic apps error' 'missing-signal diagnostics preserve stderr'
    Assert-True $record.Usable 'a missing signal does not get mislabeled as an unusable process'
    Assert-Eq $record.ExitCode 0 'failed assertion does not invent a process failure'
    $acl=Get-Acl -LiteralPath $diagnosticStore.Path
    Assert-True $acl.AreAccessRulesProtected 'diagnostic privacy does not inherit broader parent access'
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    Assert-True ($rules.Count -gt 0 -and @($rules | Where-Object { $_.IdentityReference.Value -ne $sid }).Count -eq 0) 'only the current user receives diagnostic directory access'
    $fileRules=@((Get-Acl -LiteralPath $appsPath).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    Assert-True ($fileRules.Count -gt 0 -and @($fileRules | Where-Object { $_.IdentityReference.Value -ne $sid }).Count -eq 0) 'retained evidence inherits only private user access'

    $success=[pscustomobject]@{Usable=$true;Reason=$null;InputTokens=12;Stdout='{"type":"item.completed","item":{"type":"command_execution"}}';Stderr='';ExitCode=0;TimedOut=$false;StartFailed=$false}
    $shell=[pscustomobject]@{Name='shell';Kind='feature';AllowFeatures=@('shell_tool');Prompt='synthetic prompt'}
    $outcome=Invoke-FixtureLoop -Control $shell -Result $success
    Assert-Eq $outcome.Failures 0 'a successful positive control still passes'
    Assert-True (-not [IO.File]::Exists((Join-Path $diagnosticStore.Path 'shell.json'))) 'successful controls do not retain raw output'

    $encodedAuth=[Convert]::ToBase64String($credentialBytes)
    $unusable=[pscustomobject]@{Usable=$false;Reason='synthetic timeout';InputTokens=$null;Stdout=('{"type":"turn.failed","message":"'+$encodedAuth+'"}');Stderr=('Bearer unknown-test-token '+$credentialCanary+' '+$encodedAuth);ExitCode=1;TimedOut=$true;StartFailed=$false}
    $canary=[pscustomobject]@{Name='mcp';Kind='canary';AllowFeatures=@();Prompt='synthetic prompt';Home=$fixtureRoot;Marker=(Join-Path $fixtureRoot 'absent-marker')}
    $outcome=Invoke-FixtureLoop -Control $canary -Result $unusable
    Assert-True ($outcome.Failures -gt 0) 'unusable canary controls remain rejected'
    $recordText=Read-DiagnosticFixture (Join-Path $diagnosticStore.Path 'mcp.json')
    $record=$recordText | ConvertFrom-Json
    Assert-True (-not $record.Usable -and $record.TimedOut -and $record.ExitCode -eq 1) 'failed canary diagnostics retain process outcome'
    Assert-True ($recordText -notmatch 'synthetic-credential-7b8c' -and $recordText -notmatch 'unknown-test-token') 'known credentials and bearer credentials never reach evidence'
    Assert-True (-not $recordText.Contains($encodedAuth) -and $record.Stdout.Contains('[redacted]') -and $record.Stderr.Contains('[redacted]')) 'encoded complete credentials are removed from real failed-control model output and stderr'
    Assert-True $record.Redacted 'redaction is visible to the reader'
    $variants=@($credentialCanary, ($credentialCanary | ConvertTo-Json -Compress), [Uri]::EscapeDataString($credentialCanary), [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($credentialCanary)))
    foreach ($variant in $variants) { Assert-True ((Protect-ControlDiagnosticText -Store $diagnosticStore -Text $variant).Contains('[redacted]')) 'common credential encodings are redacted' }
    $documentJson=$credentialDocument | ConvertTo-Json -Compress
    $documentVariants=@($credentialDocument,$documentJson.Substring(1,$documentJson.Length-2),[Uri]::EscapeDataString($credentialDocument),[Convert]::ToBase64String($credentialBytes))
    foreach ($variant in $documentVariants) { Assert-Eq (Protect-ControlDiagnosticText -Store $diagnosticStore -Text $variant) '[redacted]' 'complete producer auth documents are redacted in common encodings' }

    $outcome=Invoke-FixtureLoop -Control ([pscustomobject]@{Name='plugins';Kind='feature';AllowFeatures=@('plugins');Prompt='synthetic prompt'}) -Result $null -Throw
    Assert-Eq $outcome.Exception 'synthetic launch exception' 'diagnostic retention preserves the original control exception'
    $record=Read-DiagnosticFixture (Join-Path $diagnosticStore.Path 'plugins.json') | ConvertFrom-Json
    Assert-Eq $record.Error 'synthetic launch exception' 'aborted controls retain a cause before cleanup'

    $large='START '+('x'*200000)+' END'
    $bounded=[pscustomobject]@{Usable=$false;Reason='large';InputTokens=$null;Stdout=$large;Stderr=$large;ExitCode=1;TimedOut=$false;StartFailed=$false}
    Write-FailedControlDiagnostic -Store $diagnosticStore -Name 'large' -Executable $cli.Path -Argv @('exec','') -Result $bounded
    $largePath=Join-Path $diagnosticStore.Path 'large.json'
    $record=Read-DiagnosticFixture $largePath | ConvertFrom-Json
    Assert-True ((Get-Item -LiteralPath $largePath).Length -le 1048576) 'large output cannot exceed the per-control byte budget'
    Assert-True ($record.Stdout.StartsWith('START ') -and $record.Stdout.EndsWith(' END') -and $record.Truncated) 'truncated evidence keeps the start and final model outcome and labels the omission'
    Assert-Eq $record.Argv[1] '' 'an empty argument survives diagnostic serialization'
    Assert-Throws { Write-FailedControlDiagnostic -Store $diagnosticStore -Name 'apps' -Executable $cli.Path -Argv @('exec') -Result $bounded } 'diagnostics never overwrite previous failure evidence'
    $outcome=Invoke-FixtureLoop -Control $apps -Result $noSignal
    Assert-True ($null -ne $outcome.Exception -and $outcome.Failures -gt 0) 'a retention failure aborts the real control loop without erasing the required assertion'
    Assert-Throws { Write-FailedControlDiagnostic -Store $diagnosticStore -Name '../escape' -Executable $cli.Path -Argv @('exec') -Result $bounded } 'control names cannot escape the private directory'
    Assert-Throws { Write-FailedControlDiagnostic -Store $diagnosticStore -Name 'argv-large' -Executable $cli.Path -Argv @('x'*70000) -Result $bounded } 'oversized argv is refused instead of silently changing an exact invocation'
    Assert-Throws { Add-ControlDiagnosticCredentials -Store $diagnosticStore -Bytes ([Text.Encoding]::UTF8.GetBytes('invalid synthetic auth')) } 'unparseable credentials fail before unsafe evidence is written'
    Assert-Throws { New-ControlDiagnosticStore -Root $fixtureRoot -CredentialRoot $fixtureRoot } 'diagnostic storage cannot be inside the retiring credential root'
    $linked=Join-Path $fixtureRoot 'linked-root'
    New-Item -ItemType Junction -Path $linked -Target $fixtureRoot -ErrorAction Stop | Out-Null
    Assert-Throws { New-ControlDiagnosticStore -Root $linked -CredentialRoot (Join-Path $fixtureRoot 'credentials') } 'diagnostic storage refuses a reparse-point destination'
    Assert-Eq $diagnosticStore.Count 4 'refused writes do not consume successful diagnostic slots'
    foreach ($name in @('five','six','seven','eight')) { Write-FailedControlDiagnostic -Store $diagnosticStore -Name $name -Executable $cli.Path -Argv @('exec') -Result $bounded }
    Assert-Throws { Write-FailedControlDiagnostic -Store $diagnosticStore -Name 'nine' -Executable $cli.Path -Argv @('exec') -Result $bounded } 'failure evidence cannot grow beyond the eight-control run budget'
} finally {
    if ($hasStore) { $diagnosticStore.Custody.Dispose() }
    # Retain all synthetic fixtures for review. No recursive or other cleanup.
}
Write-Host "Synthetic evidence: $fixtureRoot"
Write-TestResult
