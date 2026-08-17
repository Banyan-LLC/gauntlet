. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\..\gauntlet-review\scripts\lib.ps1"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "codexdisc-$([guid]::NewGuid())"
New-Item -ItemType Directory -Force $tmp | Out-Null

# Wrapper resolution rules.
$ri = Resolve-CliInvocation -Path 'C:\x\codex.exe'
Assert-Eq $ri.FileName 'C:\x\codex.exe' "exe runs directly"; Assert-Eq $ri.PrefixArgs.Count 0 "exe no prefix"
$ri = Resolve-CliInvocation -Path 'C:\x\codex.cmd'
Assert-True ($ri.FileName -match 'cmd\.exe$') "cmd via cmd.exe"
Assert-Eq ($ri.PrefixArgs -join ' ') '/d /c C:\x\codex.cmd' "cmd uses /d (AutoRun disabled) /c"
$ri = Resolve-CliInvocation -Path 'C:\x\codex.ps1'
Assert-Eq $ri.FileName ([System.Environment]::ProcessPath) "ps1 via absolute pwsh"
Assert-Throws { Resolve-CliInvocation -Path 'C:\x\codex.vbs' } "unknown wrapper rejected"

$goodExecHelp = '--output-schema --output-last-message --json --ignore-user-config --ignore-rules --skip-git-repo-check --ephemeral --disable -s, --sandbox -C, --cd -m, --model -c, --config'
$goodResumeHelp = '--output-schema --output-last-message --json --ignore-user-config --ignore-rules --skip-git-repo-check --disable -m, --model -c, --config'
$oldResumeHelp = '--json --ignore-user-config -m, --model -c, --config'
$features = @"
apps                       stable   true
enable_request_compression stable   true
fast_mode                  stable   true
personality                stable   true
guardian_approval          stable   true
remote_compaction_v2       stable   true
novel_thing                stable   true
"@

$binRoot = "$tmp\bin"; New-Item -ItemType Directory -Force "$binRoot\aaaa","$binRoot\bbbb" | Out-Null
'x' | Set-Content "$binRoot\aaaa\codex.exe"; Start-Sleep -Milliseconds 50; 'x' | Set-Content "$binRoot\bbbb\codex.exe"
'x' | Set-Content "$binRoot\codex.exe"
"CODEX_CLI_PATH = '$binRoot\aaaa\codex.exe'" | Set-Content "$tmp\config.toml"
$cands = Get-CodexCandidates -ConfigTomlPath "$tmp\config.toml" -BinRoot $binRoot
Assert-Eq $cands[0] "$binRoot\aaaa\codex.exe" "config path first"
Assert-Eq $cands[1] "$binRoot\bbbb\codex.exe" "newest hashed second"
Assert-Eq $cands[2] "$binRoot\codex.exe" "stable third"

Assert-True ($null -eq (Test-CodexCandidate -Path "C:\Program Files\WindowsApps\OpenAI.Codex_1\app\resources\codex.exe")) "WindowsApps rejected"

$good = New-FakeCodexShim -Dir "$tmp\good" -Version "0.147.0" -ExecHelp $goodExecHelp -ResumeHelp $goodResumeHelp -FeaturesText $features
Assert-True ($null -eq (Test-CodexCandidate -Path $good)) "PRODUCTION: .cmd wrapper rejected (not pinnable)"
$r = Test-CodexCandidate -Path $good -AllowWrapper
Assert-True ($null -ne $r) "wrapper accepted only under the test-only -AllowWrapper"
Assert-Eq $r.Version "0.147.0" "version captured"
Assert-True ($r.Sha256 -match '^[0-9a-f]{64}$') "sha captured"
Assert-True ($r.FeatureNames -contains 'novel_thing') "features enumerated"

$old = New-FakeCodexShim -Dir "$tmp\old" -Version "0.130.0" -ExecHelp $goodExecHelp -ResumeHelp $oldResumeHelp -FeaturesText $features
Assert-True ($null -ne (Test-CodexCandidate -Path $old -AllowWrapper)) "0.130-style binary is acceptable: with fresh sessions its resume-flag gaps are irrelevant"
$noAllow = New-FakeCodexShim -Dir "$tmp\na" -Version "1.0" -ExecHelp $goodExecHelp -ResumeHelp $goodResumeHelp -FeaturesText "apps stable true"
Assert-True ($null -eq (Test-CodexCandidate -Path $noAllow -AllowWrapper)) "missing allowlisted feature rejected"
# NOTE: the brief's fixture used $old (0.130-style) as the "rejected" candidate here, but $old is
# asserted PASSING two lines above ("0.130-style binary is acceptable") and the plan document
# (docs/design.md live battery, "Task 2 asserts the
# same thing — these two must not contradict") independently confirms that is intentional:
# Select-CodexCli is plain "first passing" with no version-preference logic, so a passing $old could
# never be skipped. Using $old here was therefore unsatisfiable by any correct implementation.
# $noAllow (asserted REJECTED immediately above) is the fixture that actually exercises fallthrough.
$sel = Select-CodexCli -Candidates @($noAllow, $good) -AllowWrapper
Assert-Eq $sel.Path $good "falls through to passing candidate"
Assert-Throws { Select-CodexCli -Candidates @($noAllow) -AllowWrapper } "exhausted candidates throw"

# Regression: the thrown message must carry WHY each candidate was rejected, not just which
# paths were tried. Test-CodexCandidate's rejection reasons used to live only on the Verbose
# stream (off by default), so the Assert-Throws above proves only that *something* threw -
# it would still pass even if the message carried no reasons at all. Capture the exception's
# .Message directly and check it names $noAllow's actual, specific rejection cause.
$thrownMessage = $null
try { Select-CodexCli -Candidates @($noAllow) -AllowWrapper } catch { $thrownMessage = $_.Exception.Message }
Assert-True ($null -ne $thrownMessage) "exhausted candidates throw an exception with a message"
Assert-True ($thrownMessage -and $thrownMessage.Contains("allowlisted 'enable_request_compression' missing")) "thrown message names the per-candidate rejection reason, not just the path"

# Exact version equality — a pinned prefix must not accept a longer real version.
$pinPrefix = [pscustomobject]@{ Path=$good; Sha256=(Get-FileHash -Algorithm SHA256 $good).Hash.ToLowerInvariant(); Version='0.147' }
Assert-True (-not (Test-BinaryUnchanged -PinnedCli $pinPrefix)) "version '0.147' does NOT match '0.147.0' (exact equality)"

# Regression: the real `codex login status` succeeds (exit 0) with EMPTY stdout and prints
# only to stderr — confirmed against the real CLI. A probe that judges authentication on
# stdout truthiness rejects every correctly-authenticated installation. Pin the contract
# directly at the process level (not just via the accept/reject outcome) so a future shim
# regression back to Write-Output cannot silently make this probe pass for the wrong reason.
$authOk = New-FakeCodexShim -Dir "$tmp\auth-ok" -Version "0.147.0" -ExecHelp $goodExecHelp -ResumeHelp $goodResumeHelp -FeaturesText $features
$riAuth = Resolve-CliInvocation -Path $authOk
$authProc = Invoke-BoundedProcess -FileName $riAuth.FileName -ArgList ($riAuth.PrefixArgs + @('login','status')) -TimeoutSec 30
Assert-Eq $authProc.ExitCode 0 "fake login status exits 0"
Assert-Eq $authProc.Stdout '' "fake login status stdout is empty (real CLI contract)"
Assert-True ($authProc.Stderr -match 'Logged in') "fake login status text goes to stderr (real CLI contract)"
Assert-True ($null -ne (Test-CodexCandidate -Path $authOk -AllowWrapper)) "empty-stdout/stderr-only login status (exit 0) is ACCEPTED"

# Inverse: a nonzero exit from login status must be REJECTED, regardless of what it printed.
$authFail = New-FakeCodexShim -Dir "$tmp\auth-fail" -Version "0.147.0" -ExecHelp $goodExecHelp -ResumeHelp $goodResumeHelp -FeaturesText $features -LoginStatusExitCode 1
Assert-True ($null -eq (Test-CodexCandidate -Path $authFail -AllowWrapper)) "nonzero-exit login status is REJECTED"

Write-TestResult
