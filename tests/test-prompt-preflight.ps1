param([string]$WorkRoot = [IO.Path]::GetTempPath())
. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\..\gauntlet-review\scripts\lib.ps1"
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ('prompt-preflight-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
try {
    # These tests fail if admission is byte-based, caller-overridable, off by one,
    # or counts a valid astral pair as two upstream Unicode characters.
    $gate = Get-Command Test-PromptCharacterLimit -ErrorAction SilentlyContinue
    Assert-True ($null -ne $gate) 'complete prompt has a fixed character admission gate'
    if ($gate) {
        foreach ($case in @(
            @{ Text = 'a' * 1048576; Ok = $true; Count = 1048576; Name = 'ASCII exact boundary' },
            @{ Text = 'a' * 1048577; Ok = $false; Count = 1048577; Name = 'ASCII above boundary' },
            @{ Text = ([string][char]0x20ac) * 1048576; Ok = $true; Count = 1048576; Name = 'multibyte exact character boundary' },
            @{ Text = ([string][char]0x20ac) * 1048577; Ok = $false; Count = 1048577; Name = 'multibyte above boundary' },
            @{ Text = [char]::ConvertFromUtf32(0x1f642) * 1048576; Ok = $true; Count = 1048576; Name = 'astral scalar boundary' },
            @{ Text = ([char]::ConvertFromUtf32(0x1f642) * 1048576) + 'a'; Ok = $false; Count = 1048577; Name = 'astral scalar overflow' }
        )) {
            $result = Test-PromptCharacterLimit -PromptText $case.Text
            Assert-Eq $result.Ok $case.Ok $case.Name
            Assert-Eq $result.Characters $case.Count ($case.Name + ' Unicode characters')
        }
        Assert-Throws { Test-PromptCharacterLimit -PromptText ('a' * 1048577) -Limit 2000000 } 'no caller character-limit override'
        Assert-True (-not (Test-EmbedBudget -PromptText (([string][char]0x20ac) * 1000) -BudgetBytes 2000).Ok) 'independent byte gate still rejects multibyte overflow'
    }

    # Execute the real complete-render/preflight statements only. No CLI, Git,
    # harness creation or review loop is reachable, including on the RED code.
    $invokePath = Join-Path $PSScriptRoot '..\gauntlet-review\scripts\invoke-codex.ps1'
    $source = [IO.File]::ReadAllText($invokePath)
    $start = $source.IndexOf('$promptBody = Get-Content')
    $end = $source.IndexOf('# --- Binary pin', $start)
    $slice = '$VerifiedReferenceFile=$null;$CompactAddedFiles=$false;' + $source.Substring($start, $end - $start)
    $lib = (Resolve-Path "$PSScriptRoot\..\gauntlet-review\scripts\lib.ps1").Path.Replace("'", "''")
    $promptFile = Join-Path $root 'preamble.txt'
    [IO.File]::WriteAllText($promptFile, 'preamble')
    $entry = [pscustomobject]@{ id='1'; severity='important'; location='file:1'; issue='issue'; suggestion='fix'; status='addressed'; reason='' }
    $carry = ConvertTo-CarryOverText -Entries @($entry)
    $renderBase = $carry + "preamble`n`n== REVIEW MATERIAL (untrusted) ==`n`n"
    foreach ($extra in @(0, 1)) {
        $state = Join-Path $root "render-$extra"
        $null = New-Item -ItemType Directory -Path $state
        $diffLength = 1048576 - $renderBase.Length + $extra
        $code = ". '$lib'; `$Mode='local'; `$PromptFile='$($promptFile.Replace("'", "''"))'; `$StateDir='$($state.Replace("'", "''"))'; `$BudgetBytes=10000000; `$carryText=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($carry)))')); `$localDiff='d' * $diffLength;" + $slice + '; exit 0'
        $run = Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))) -TimeoutSec 20 -RequireProcessTreeRetirement
        Assert-Eq $run.ExitCode $(if ($extra) { 10 } else { 0 }) "complete carryover/preamble/diff boundary plus $extra refuses before dispatch"
        Assert-True (-not $run.StartFailed -and -not $run.TimedOut) 'offline preflight child settles'
        Assert-True $run.ProcessTreeRetired 'offline preflight child process tree retires'
        Assert-Eq @(Get-ChildItem $state -Filter '*attempt*').Count 0 'preflight consumes no attempt metadata'
        if ($extra -and (Test-Path (Join-Path $state 'state.json'))) {
            $flag = Read-RoundState -StateDir $state
            Assert-Eq $flag.status 'flagged' 'oversized prompt refusal is visible'
            Assert-True ($flag.failure_reason -match '1048577.*1048576') 'refusal records actual and fixed character counts'
        }
    }
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
    Assert-Eq @($parseErrors).Count 0 'invocation source parses'
    $calls = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
    $guardCalls = @($calls | Where-Object { $_.GetCommandName() -eq 'Test-PromptCharacterLimit' })
    Assert-Eq $guardCalls.Count 1 'one complete-prompt character gate'
    if ($guardCalls.Count -eq 1) {
        foreach ($name in @('Test-EmbedBudget','Write-AttemptMeta','Invoke-CodexProcess')) {
            $later = @($calls | Where-Object { $_.GetCommandName() -eq $name })[0]
            Assert-True ($guardCalls[0].Extent.StartOffset -lt $later.Extent.StartOffset) "character preflight precedes $name"
        }
    }

    # Losing stderr, serializing stdout/prompt/environment, or overwriting an
    # existing attempt must each fail these real create-only receipt controls.
    $writer = Get-Command Write-AttemptProcessResult -ErrorAction SilentlyContinue
    Assert-True ($null -ne $writer) 'per-attempt process diagnostics have an immutable writer'
    if ($writer) {
        $meta = @{ prompt_sha256=('a' * 64); cli_sha256=('b' * 64); cli_version='0.147.0'; prompt='PROMPT-NOT-A-RECEIPT'; credential='SECRET-NOT-A-RECEIPT' }
        foreach ($kind in @('exit','start','timeout','success')) {
            $state = Join-Path $root $kind
            $null = New-Item -ItemType Directory -Path $state
            $run = [pscustomobject]@{ ExitCode=$(if ($kind -eq 'success') { 0 } else { 1 }); StartFailed=($kind -eq 'start'); TimedOut=($kind -eq 'timeout'); ErrorMessage=$(if ($kind -eq 'start') { 'start failed' } else { $null }); StderrText='Error: turn/start: turn/start failed: Input exceeds the maximum length of 1048576 characters. (code -32602), data: {"input_error_code":"input_too_large","max_chars":1048576,"actual_chars":1807621}'; StdoutLines=@('MODEL-MATERIAL-NOT-A-RECEIPT'); ProcessTreeRetired=$true; credential='SECRET-NOT-A-RECEIPT' }
            Write-AttemptProcessResult -StateDir $state -Round 1 -Attempt 2 -Meta $meta -Run $run -PromptText 'safe synthetic prompt'
            $file = Join-Path $state 'round-1-attempt-2-process.json'
            $text = [IO.File]::ReadAllText($file); $receipt = $text | ConvertFrom-Json
            foreach ($field in @('ExitCode','StartFailed','TimedOut','ErrorMessage','StderrText','ProcessTreeRetired')) { Assert-Eq $receipt.$field $run.$field "$kind preserves $field" }
            Assert-Eq $receipt.prompt_sha256 $meta.prompt_sha256 'receipt binds exact attempt prompt digest'
            Assert-Eq $receipt.cli_sha256 $meta.cli_sha256 'receipt binds CLI identity'
            Assert-True ($text -notmatch 'NOT-A-RECEIPT') 'receipt excludes prompt, stdout and credentials'
            Assert-Throws { Write-AttemptProcessResult -StateDir $state -Round 1 -Attempt 2 -Meta $meta -Run $run -PromptText 'safe synthetic prompt' } 'attempt process receipt is create-only'
            Assert-Eq ([IO.File]::ReadAllText($file)) $text 'refused overwrite preserves original bytes'
        }
        foreach ($field in @('ErrorMessage','StderrText')) {
            $state = Join-Path $root ('echo-' + $field)
            $null = New-Item -ItemType Directory -Path $state
            $prompt = 'ENTIRE-PROMPT-MUST-NOT-BE-LOGGED'
            $echo = 'failure echoed [' + $prompt + ']'
            $run = [pscustomobject]@{ ExitCode=1; StartFailed=$false; TimedOut=$false; ErrorMessage='ordinary failure'; StderrText='ordinary stderr'; ProcessTreeRetired=$true }
            $run.$field = $echo
            $argsForReceipt = @{ StateDir=$state; Round=1; Attempt=1; Meta=$meta; Run=$run }
            if ($writer.Parameters.ContainsKey('PromptText')) { $argsForReceipt.PromptText = $prompt }
            Write-AttemptProcessResult @argsForReceipt
            $text = [IO.File]::ReadAllText((Join-Path $state 'round-1-attempt-1-process.json'))
            $receipt = $text | ConvertFrom-Json
            Assert-True ($text -notmatch [regex]::Escape($prompt)) "$field full prompt echo is never persisted"
            Assert-True ($null -eq $receipt.$field) "$field echoed text is suppressed"
            $suppression = $receipt.PSObject.Properties[$field + 'Suppression']
            Assert-True ($null -ne $suppression) "$field suppression is explicit"
            if ($suppression) {
                Assert-Eq $suppression.Value.reason 'complete_prompt_echo' 'suppression describes its narrow scope'
                Assert-Eq $suppression.Value.utf8_bytes ([Text.Encoding]::UTF8.GetByteCount($echo)) 'suppressed diagnostic original byte length retained'
                Assert-Eq $suppression.Value.sha256 ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($echo))).ToLowerInvariant()) 'suppressed diagnostic original digest retained'
            }
            $other = if ($field -eq 'ErrorMessage') { 'StderrText' } else { 'ErrorMessage' }
            Assert-Eq $receipt.$other $run.$other 'ordinary sibling diagnostic remains literal'
        }
    }
    $recordCalls = @($calls | Where-Object { $_.GetCommandName() -eq 'Write-AttemptProcessResult' })
    Assert-Eq $recordCalls.Count 1 'invocation persists the actual process result'
    if ($recordCalls.Count -eq 1) {
        $dispatch = @($calls | Where-Object { $_.GetCommandName() -eq 'Invoke-CodexProcess' })[0]
        # Acquisition helpers can reject their own bounded subprocesses before a
        # model attempt exists. Scope this ordering to the actual model dispatch.
        Assert-True ($recordCalls[0].Extent.StartOffset -gt $dispatch.Extent.StartOffset -and $recordCalls[0].Extent.StartOffset -lt $source.IndexOf('if ($run.StartFailed',$dispatch.Extent.EndOffset)) 'receipt precedes every model process-failure return'
    }
} finally {
    if ([IO.Path]::GetDirectoryName($root) -cne [IO.Path]::GetFullPath($WorkRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)) { throw 'fixture cleanup escaped its parent' }
    Remove-Item -LiteralPath $root -Recurse -Force
    Assert-True (-not (Test-Path -LiteralPath $root)) 'owned offline fixtures are absent after cleanup'
}
Write-TestResult
