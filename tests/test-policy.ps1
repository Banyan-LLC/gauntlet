. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\..\gauntlet-review\scripts\lib.ps1"
$names = @('apps','browser_use','enable_request_compression','fast_mode','personality',
           'guardian_approval','remote_compaction_v2','shell_tool','code_mode_host',
           'shell_snapshot','js_repl','brand_new_capability')
$set = Get-DisableSet -FeatureNames $names
foreach ($allowed in @('enable_request_compression','remote_compaction_v2','fast_mode','personality','guardian_approval')) {
    Assert-True ($set -notcontains $allowed) "allowlisted '$allowed' not disabled"
}
foreach ($denied in @('apps','browser_use','shell_tool','code_mode_host','shell_snapshot')) {
    Assert-True ($set -contains $denied) "'$denied' disabled"
}
Assert-True ($set -contains 'brand_new_capability') "novel feature auto-disabled"
Assert-True ($set -contains 'js_repl') "config-disabled feature still disabled (state ignored)"
Assert-Eq ($set -join ',') (($set | Sort-Object) -join ',') "sorted for stable audit"

# Parameter-contract safety: -FeatureNames is deliberately NOT [Parameter(Mandatory)] (see
# Assert-NoEmptyStringElements in lib.ps1) -- Mandatory would let an array containing an empty
# string silently defeat this function's caller instead of failing closed. See
# Test-EmptyElementFailsClosed in helpers.ps1 for the full rationale and how this was verified
# to fail against the old [Parameter(Mandatory)][string[]] contract.
Test-EmptyElementFailsClosed -LibPath "$PSScriptRoot\..\gauntlet-review\scripts\lib.ps1" `
    -CallExpression "Get-DisableSet -FeatureNames @('apps', '', 'browser_use')" `
    -Name 'Get-DisableSet -FeatureNames'

Write-TestResult
