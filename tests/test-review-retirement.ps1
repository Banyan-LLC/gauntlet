. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"

# Execute the actual production call and acceptance condition with a controlled
# runner result. No synthetic copy of those expressions can hide wiring drift.
$entry=Join-Path $PSScriptRoot '../gauntlet-review/scripts/invoke-codex.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
Assert-Eq $errors.Count 0 'production invoker parses'
$call=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Extent.Text.StartsWith('$run = Invoke-CodexProcess ')},$true)
$gate=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if ($run.StartFailed -or $run.TimedOut -or $run.ExitCode -ne 0 -or ') -and $n.Extent.Text.Contains('-not (Test-Path $rawPath)')},$true)
Assert-True ($null -ne $call -and $null -ne $gate) 'exact main reviewer call and pre-canonical gate are present'
$saved=${function:Invoke-CodexProcess}
try {
    function Invoke-CodexProcess {
        param($CliPath,$CodexArgs,$PromptText,$HarnessDir,$TimeoutSec,[switch]$RequireProcessTreeRetirement)
        $script:requestedRetirement=[bool]$RequireProcessTreeRetirement
        $script:controlledRun
    }
    $cli=[pscustomobject]@{Path='MOCK-NOT-EXECUTED'};$codexArgs=@('mock');$prompt='mock';$harness='mock';$TimeoutSec=1
    # A real existing source file stands in for the raw-verdict existence check.
    $rawPath=$entry
    foreach($retired in @($false,$null,1,'true',$true)) {
        foreach($message in @($null,'unconfirmed retirement')) {
            $script:controlledRun=[pscustomobject]@{StartFailed=$false;TimedOut=$false;ExitCode=0;ProcessTreeRetired=$retired;ErrorMessage=$message}
            $script:requestedRetirement=$false
            . ([scriptblock]::Create($call.Extent.Text))
            Assert-True $script:requestedRetirement 'production reviewer explicitly requests owned tree retirement'
            $rejected=[bool](& ([scriptblock]::Create($gate.Clauses[0].Item1.Extent.Text)))
            $expected=($retired -isnot [bool] -or -not $retired -or [bool]$message)
            Assert-Eq $rejected $expected "canonical acceptance requires Boolean retirement proof and no runner error ($retired/$message)"
        }
    }
} finally { ${function:Invoke-CodexProcess}=$saved }

# Exercise the same real owned runner with a harmless local script. This is not
# a model call and does not mutate any review state or certification manifest.
if ($IsWindows) {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('gauntlet-review-retirement-'+[guid]::NewGuid())
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $scriptPath=Join-Path $root 'short.ps1'
    [IO.File]::WriteAllText($scriptPath,'[Console]::In.ReadToEnd() | Out-Null; [Console]::Out.Write("owned-short")')
    $r=Invoke-CodexProcess -CliPath $scriptPath -CodexArgs @('fixture') -PromptText 'bounded input' -HarnessDir $root -TimeoutSec 15 -RequireProcessTreeRetirement
    Assert-True (-not $r.StartFailed -and -not $r.TimedOut -and -not $r.ErrorMessage -and $r.ExitCode -eq 0) 'owned local reviewer fixture completes'
    Assert-True $r.ProcessTreeRetired 'owned local reviewer fixture proves tree retirement'
    Assert-Eq ($r.StdoutLines -join '') 'owned-short' 'owned runner drains output before acceptance'
    # Evidence is intentionally retained, including failed controls.
    Write-Host "Retained review-retirement fixture: $root"
}
Write-TestResult
