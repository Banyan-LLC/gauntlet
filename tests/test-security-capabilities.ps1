# Offline regression over the live battery's actual immutable capability declarations.
. "$PSScriptRoot\helpers.ps1"
$ErrorActionPreference = 'Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile(
    "$PSScriptRoot/live/live-security.ps1",[ref]$tokens,[ref]$errors)
Assert-Eq @($errors).Count 0 'live security source parses'
function Read-CapabilityDeclaration([string]$Name) {
    $commands=@($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Set-Variable'
    },$true) | Where-Object {
        $parts=@($_.CommandElements | ForEach-Object { $_.Extent.Text })
        $parts -contains $Name
    })
    Assert-Eq $commands.Count 1 "one immutable declaration exists for $Name"
    if ($commands.Count -ne 1) { return @() }
    # A child scope prevents the real Constant declaration escaping into the test scope.
    return @(& ([scriptblock]::Create('& { '+$commands[0].Extent.Text+'; @($'+$Name+') }')))
}
$required=@(Read-CapabilityDeclaration requiredClasses)
$narrowed=@(Read-CapabilityDeclaration narrowedClasses)
$master=@(Read-CapabilityDeclaration masterClassUniverse)
Assert-True ($required -notcontains 'computer_use') 'unproved headless computer use cannot be claimed as independently verified'
Assert-True ($narrowed -contains 'computer_use') 'computer use remains explicitly configured off without independent proof'
Assert-Eq (($required | Sort-Object) -join ',') 'apps,mcp,plugins,shell,web' 'the five independently proved classes remain required'
Assert-Eq (($narrowed | Sort-Object) -join ',') 'computer_use,skills,subagents' 'all three independent-proof limitations remain explicit'
Assert-Eq ((@($required)+@($narrowed) | Sort-Object -Unique) -join ',') (($master | Sort-Object) -join ',') 'the independent complete capability universe is preserved'
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$disabled=@(Get-DisableSet -FeatureNames @('computer_use','code_mode_host','shell_tool','enable_request_compression'))
Assert-True ($disabled -contains 'computer_use') 'canonical default-deny still disables computer use'
Assert-True ($disabled -contains 'code_mode_host') 'canonical default-deny still disables the code-mode host'
Write-TestResult
