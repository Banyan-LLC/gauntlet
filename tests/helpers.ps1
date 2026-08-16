$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Passes = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if ($Condition) { $script:Passes++ } else { $script:Failures.Add($Name); Write-Host "FAIL: $Name" -ForegroundColor Red }
}
function Assert-Eq($Actual, $Expected, [string]$Name) {
    Assert-True ($Actual -eq $Expected) "$Name (expected '$Expected', got '$Actual')"
}
function Assert-Throws([scriptblock]$Block, [string]$Name) {
    $threw = $false; try { & $Block | Out-Null } catch { $threw = $true }
    Assert-True $threw $Name
}
function Write-TestResult {
    Write-Host "$($script:Passes) passed, $($script:Failures.Count) failed"
    if ($script:Failures.Count -gt 0) { exit 1 } else { exit 0 }
}

function New-FakeCodexShim {
    # Fake codex CLI. The .cmd wrapper invokes pwsh by ABSOLUTE path so it runs even when
    # the child environment has no PATH (the production runner clears the environment).
    #
    # Event stream fidelity (see task-7-report.md): two prior blockers shipped because a fake
    # was unfaithful to the real CLI (login status via stdout instead of stderr; a fake that
    # never validated the schema it was handed). This shim's 'exec' event stream is REALISTIC,
    # not a stand-in -- confirmed against live runs against the real CLI. Real event taxonomy:
    # thread.started, turn.started, item.completed (item.type = agent_message | error),
    # turn.completed, error. The terminal event is EXACTLY ONE
    #   {"type":"turn.completed","usage":{"input_tokens":N,"cached_input_tokens":0,
    #    "cache_write_input_tokens":0,"output_tokens":25,"reasoning_output_tokens":0}}
    # -- default InputTokens (9456) is the evidence's own measured example (147 prompt bytes ->
    # input_tokens 9456). -UsageBehavior deliberately simulates each acceptance-time usage-gate
    # failure mode the real CLI could exhibit, so those guards are genuinely exercised rather
    # than merely asserted never-reached.
    param([string]$Dir, [string]$Version = "9.9.9",
          [string]$ExecHelp, [string]$ResumeHelp, [string]$FeaturesText,
          [string]$VerdictJson = '{"verdict":"approve","summary":"ok","recommendations":[]}',
          [ValidateSet('normal','invalid-verdict','no-verdict','ignore-stdin-sleep')][string]$Behavior = 'normal',
          [int]$LoginStatusExitCode = 0,
          [int]$InputTokens = 9456,
          [ValidateSet('normal','no-usage-field','malformed-usage','duplicate-turn-completed','error-event',
                       'unparseable-line','null-line','no-type-object','turn-failed')]
          [string]$UsageBehavior = 'normal',
          [string]$MalformedInputTokensLiteral = '"not-a-number"')
    New-Item -ItemType Directory -Force $Dir | Out-Null
    @{version=$Version; execHelp=$ExecHelp; resumeHelp=$ResumeHelp; features=$FeaturesText; verdict=$VerdictJson
      behavior=$Behavior; loginStatusExitCode=$LoginStatusExitCode
      inputTokens=$InputTokens; usageBehavior=$UsageBehavior; malformedInputTokensLiteral=$MalformedInputTokensLiteral} |
        ConvertTo-Json -Depth 3 | Set-Content "$Dir\config.json" -Encoding utf8
    Set-Content -Path "$Dir\shim.ps1" -Encoding utf8 -Value @'
param()
$cfg = Get-Content -Raw "$PSScriptRoot\config.json" | ConvertFrom-Json
$a = $args
if ($a[0] -eq '--version') { Write-Output "codex-cli $($cfg.version)"; exit 0 }
if ($a[0] -eq 'login' -and $a[1] -eq 'status') { [Console]::Error.WriteLine("Logged in using ChatGPT"); exit $cfg.loginStatusExitCode }
if ($a[0] -eq 'features' -and $a[1] -eq 'list') { Write-Output $cfg.features; exit 0 }
if ($a[0] -eq 'exec' -and $a -contains '--help') {
    if ($a[1] -eq 'resume') { Write-Output $cfg.resumeHelp } else { Write-Output $cfg.execHelp }
    exit 0
}
if ($a[0] -eq 'exec') {
    # Behaviors the tests need. 'ignore-stdin-sleep' NEVER drains stdin — that is the
    # deadlock case the bounded runner must survive.
    if ($cfg.behavior -eq 'ignore-stdin-sleep') { Start-Sleep 300; exit 0 }
    $stdin = [Console]::OpenStandardInput()
    $ms = [System.IO.MemoryStream]::new(); $stdin.CopyTo($ms); $bytes = $ms.ToArray()
    $sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $shaHex = -join ($sha | ForEach-Object { $_.ToString('x2') })
    @{args=@($a); stdinBytes=$bytes.Length; stdinSha256=$shaHex; env_CANARY=$env:CODEX_TEST_CANARY} |
        ConvertTo-Json -Depth 3 | Set-Content "$PSScriptRoot\receipt.json" -Encoding utf8
    $oIdx = [array]::IndexOf($a, '-o')
    if ($oIdx -ge 0 -and $cfg.behavior -ne 'no-verdict') {
        $payload = if ($cfg.behavior -eq 'invalid-verdict') { '{"nope":true}' } else { $cfg.verdict }
        Set-Content -Path $a[$oIdx+1] -Value $payload -Encoding utf8
    }
    # Realistic terminal event stream (confirmed against the real CLI, see task-7-report.md):
    # thread.started, turn.started, item.completed, then EXACTLY ONE turn.completed carrying
    # usage -- unless the fixture deliberately simulates one of the usage-gate's failure modes.
    Write-Output '{"type":"thread.started","thread_id":"11111111-2222-3333-4444-555555555555"}'
    Write-Output '{"type":"turn.started"}'
    Write-Output '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}'
    $goodUsage = '{"type":"turn.completed","usage":{"input_tokens":' + $cfg.inputTokens + ',"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":25,"reasoning_output_tokens":0}}'
    switch ($cfg.usageBehavior) {
        'no-usage-field'           { Write-Output '{"type":"turn.completed"}' }
        'malformed-usage'          { Write-Output ('{"type":"turn.completed","usage":{"input_tokens":' + $cfg.malformedInputTokensLiteral + ',"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":25,"reasoning_output_tokens":0}}') }
        'duplicate-turn-completed' { Write-Output $goodUsage; Write-Output $goodUsage }
        'error-event'              { Write-Output '{"type":"error","message":"simulated upstream error"}' }
        # FINDING 4a (see docs/build-log/task-14-report.md): each of these emits a VALID terminal
        # turn.completed (proving the run otherwise looked fine) PLUS, separately, one malformed
        # line -- Get-RunUsage must fail closed on the malformed line even though a genuine
        # terminal event is also present, not silently skip it and accept the good one anyway.
        'unparseable-line'         { Write-Output $goodUsage; Write-Output 'not-json-at-all {{{' }
        'null-line'                { Write-Output $goodUsage; Write-Output 'null' }
        'no-type-object'           { Write-Output $goodUsage; Write-Output '{"foo":"bar"}' }
        'turn-failed'              { Write-Output $goodUsage; Write-Output '{"type":"turn.failed","message":"simulated turn failure"}' }
        default                    { Write-Output $goodUsage }
    }
    exit 0
}
exit 64
'@
    $pwshAbs = [System.Environment]::ProcessPath   # absolute path of the running pwsh
    # @echo off (own line, `@`-prefixed so even IT is never echoed): without it, cmd.exe echoes
    # every line it executes to STDOUT that isn't itself `@`-prefixed. The launch line below always
    # was `@`-prefixed, but a test that later `Add-Content`s a bare (non-`@`) line onto this file
    # to simulate binary tampering (e.g. "rem tampered-between-rounds", used across this suite to
    # exercise Test-BinaryUnchanged) does NOT prefix its appended line -- so once that tampered
    # binary is genuinely re-pinned and RUN (not merely hash-rejected), cmd.exe echoes
    # "<cwd>>rem tampered-between-rounds" onto stdout as an extra, un-asked-for event-stream line.
    # The pre-FINDING-4a Get-RunUsage silently `continue`d past that stray line and never noticed;
    # the fixed, fail-closed Get-RunUsage correctly rejects it as an unparseable line -- exposing
    # this latent fixture issue rather than a defect in the fix. Fixed at the root: `@echo off`
    # suppresses the echo for every line cmd.exe executes from this file, appended or not.
    Set-Content -Path "$Dir\shim.cmd" -Encoding ascii -Value "@echo off`r`n@`"$pwshAbs`" -NoProfile -File `"%~dp0shim.ps1`" %*"
    return "$Dir\shim.cmd"
}

function Test-EmptyElementFailsClosed {
    <# Regression helper for the [Parameter(Mandatory)][string[]] empty-element bug (see
       Assert-NoEmptyStringElements in lib.ps1). PowerShell's parameter binder applies an
       implicit "no element may be null or an empty string" check to MANDATORY [string]/
       [string[]] parameters specifically -- and on a [string[]] the rejection is a
       NON-TERMINATING "Cannot bind argument ... because it is an empty string" error. That
       matters because of what happens next in the REAL call shape (a bare assignment with no
       try/catch, under Set-StrictMode, followed by a separate `if` reading the result -- exactly
       how invoke-codex.ps1 calls these functions): the assignment never completes, so the target
       variable is never set; reading it next hits ANOTHER non-terminating StrictMode error; and
       the `if` that was supposed to react to failure runs NEITHER branch and the calling script
       reaches its end and exits 0, having silently skipped the entire check. This is not
       hypothetical -- it already shipped once, in Get-RunUsage's -EventLines (see its own
       comment), and was confirmed by direct repro before being caught.

       This helper reproduces that exact shape in an ISOLATED CHILD PROCESS (so a still-broken
       contract cannot take the whole test run down with it) and asserts the child exits NONZERO
       and never reaches its final line -- i.e., the new contract fails LOUDLY and immediately
       via a genuine `throw`, instead of silently limping to a false "success". Verified by
       running this exact helper against a scratch copy of lib.ps1 with the three parameters
       reverted to [Parameter(Mandatory)][string[]] and no explicit check: all three cases came
       back exit=0 with the child reaching its final line -- i.e., this regression test fails
       against the old contract, as intended. #>
    param([Parameter(Mandatory)][string]$CallExpression, [Parameter(Mandatory)][string]$LibPath, [Parameter(Mandatory)][string]$Name)
    $script = @"
Set-StrictMode -Version Latest
. '$LibPath'
`$x = $CallExpression
if (-not `$x) { Write-Host 'HIT IF' } else { Write-Host 'HIT ELSE' }
Write-Host 'END OF SCRIPT REACHED'
exit 0
"@
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "empty-elem-$([guid]::NewGuid().ToString('n')).ps1"
    Set-Content -Path $tmp -Value $script -Encoding utf8
    try {
        $out = pwsh -NoProfile -File $tmp 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -ne 0) "$Name`: an empty-string array element fails CLOSED (nonzero exit), not silently"
        Assert-True ($out -notmatch 'END OF SCRIPT REACHED') "$Name`: does not silently run to completion past the bad input"
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Set-FakeCodexBehavior {
    # Flips a shim's behavior WITHOUT touching shim.cmd, so an existing binary pin stays valid —
    # exactly what the retry test needs (same round, same binary, different outcome).
    param([Parameter(Mandatory)][string]$Dir,
          [ValidateSet('normal','invalid-verdict','no-verdict','ignore-stdin-sleep')][string]$Behavior,
          [string]$VerdictJson,
          [int]$InputTokens,
          [ValidateSet('normal','no-usage-field','malformed-usage','duplicate-turn-completed','error-event',
                       'unparseable-line','null-line','no-type-object','turn-failed')]
          [string]$UsageBehavior,
          [string]$MalformedInputTokensLiteral)
    $cfg = Get-Content -Raw "$Dir\config.json" | ConvertFrom-Json
    if ($PSBoundParameters.ContainsKey('Behavior')) { $cfg.behavior = $Behavior }
    if ($VerdictJson) { $cfg.verdict = $VerdictJson }
    if ($PSBoundParameters.ContainsKey('InputTokens')) { $cfg.inputTokens = $InputTokens }
    if ($PSBoundParameters.ContainsKey('UsageBehavior')) { $cfg.usageBehavior = $UsageBehavior }
    if ($MalformedInputTokensLiteral) { $cfg.malformedInputTokensLiteral = $MalformedInputTokensLiteral }
    $cfg | ConvertTo-Json -Depth 3 | Set-Content "$Dir\config.json" -Encoding utf8
}
