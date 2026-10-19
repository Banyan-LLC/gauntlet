$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/helpers.ps1"
$source = Join-Path $PSScriptRoot '../gauntlet-review/scripts/review-transport.cs'
Assert-True (Test-Path -LiteralPath $source) 'bounded lossless transport implementation exists'
if (-not (Test-Path -LiteralPath $source)) { Write-TestResult }
$text = [IO.File]::ReadAllText($source).Replace('__GAUNTLET_TRANSPORT_SOURCE_SHA256__', ('a' * 64))
$fixture = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'transport-fixture.cs'))
Add-Type -TypeDefinition ($text + "`n" + $fixture) -ErrorAction Stop
foreach ($result in [GauntletTransportTests.Suite]::Run().GetAwaiter().GetResult()) {
    Assert-True $result.Passed $result.Name
}
# Exact pinned Responses wire shapes: inherited root remains a normal user message,
# while the NEW child task may be an opaque agent_message encrypted_content item.
# This exercises actual Transform, not a mock or a change to its per-request policy.
$rootPrompt='synthetic-complete-parent-for-full-history'
$opaqueChild=[ordered]@{type='agent_message';author='synthetic-parent';recipient='synthetic-child';content=@([ordered]@{type='encrypted_content';encrypted_content='synthetic-opaque-child-message'})}
$rootMessage=[ordered]@{type='message';role='user';content=@([ordered]@{type='input_text';text=$rootPrompt})}
$fullHistory=[ordered]@{model='gpt-6.1-sol';stream=$true;input=@($rootMessage,$opaqueChild)}
$fullBytes=[Text.Encoding]::UTF8.GetBytes(($fullHistory|ConvertTo-Json -Depth 8 -Compress))
$fullResult=[GauntletTransport.Bridge]::Transform($fullBytes,$rootPrompt)
Assert-True $fullResult.PromptSeen 'full-history plaintext parent satisfies actual per-request prompt proof with opaque child task'
$decoded=[Text.Encoding]::UTF8.GetString($fullResult.Bytes)|ConvertFrom-Json
Assert-Eq $decoded.input[0].role 'user' 'full-history Transform preserves inherited parent user role'
Assert-Eq $decoded.input[0].content[0].text $rootPrompt 'full-history Transform preserves complete inherited parent plaintext'
Assert-Eq ($decoded.input[1]|ConvertTo-Json -Depth 6 -Compress) ($opaqueChild|ConvertTo-Json -Depth 6 -Compress) 'full-history Transform preserves encrypted child item logically unchanged'
$freshHistory=[ordered]@{model='gpt-6.1-sol';stream=$true;input=@($opaqueChild)}
$freshRejected=$false;$freshCode=$null;$freshStage=$null
try{[GauntletTransport.Bridge]::Transform([Text.Encoding]::UTF8.GetBytes(($freshHistory|ConvertTo-Json -Depth 8 -Compress)),$rootPrompt)|Out-Null}
catch{
    $cause=$_.Exception
    while($null -ne $cause.InnerException -and $cause -isnot [GauntletTransport.TransportException]){$cause=$cause.InnerException}
    if($cause -is [GauntletTransport.TransportException]){$freshRejected=$true;$freshCode=$cause.Code;$freshStage=$cause.Stage}
}
Assert-True $freshRejected 'fresh opaque child without root is rejected by actual Transform'
Assert-Eq $freshCode 'prompt_missing' 'fresh child rejection retains exact original-prompt failure code'
Assert-Eq $freshStage 'transform_validate' 'fresh child rejection retains exact original-prompt failure stage'
# A prior successful Transform must never authorize a later prompt-less child request.
Assert-True $fullResult.PromptSeen 'earlier full-history success remains separate from fresh-request rejection'
Write-TestResult
