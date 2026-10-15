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
Assert-True ($required -contains 'computer_use') 'observable computer use requires positive and hermetic isolation proofs'
Assert-True ($narrowed -notcontains 'computer_use') 'observable computer use is not treated as an unobservable capability'
Assert-Eq (($required | Sort-Object) -join ',') 'apps,computer_use,mcp,plugins,shell,web' 'six independently observable classes are required'
Assert-Eq (($narrowed | Sort-Object) -join ',') 'skills,subagents' 'only genuinely unobservable classes remain narrowed'
Assert-Eq ((@($required)+@($narrowed) | Sort-Object -Unique) -join ',') (($master | Sort-Object) -join ',') 'the independent complete capability universe is preserved'
Write-TestResult
