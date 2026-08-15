# lib.ps1 — codex-review core library. Dot-source; no top-level side effects.
Set-StrictMode -Version Latest

$script:FeatureAllowlist = @('enable_request_compression','remote_compaction_v2','fast_mode','personality','guardian_approval')
$script:RequiredExecFlags = @('--output-schema','--output-last-message','--json','--ignore-user-config','--ignore-rules','--skip-git-repo-check','--disable','-s','-C','-m','-c')

function Invoke-BoundedProcess {
    <# THE process runner. Every external command in this skill goes through it: the Codex
       review, the compatibility probes, and gh. Guarantees:
         - stdin is written ASYNCHRONOUSLY, so a child that never drains the pipe (600 KB
           prompts far exceed the ~64 KB pipe buffer) cannot block us before the clock starts;
         - stdout and stderr are read concurrently, so a full stderr buffer cannot deadlock;
         - ONE shared deadline covers stdin + exit, so total time is bounded by TimeoutSec;
         - timeout kills the whole process TREE;
         - it NEVER throws for process-level failure — callers map the result to exit codes. #>
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string[]]$ArgList = @(),
        [string]$StdinText,
        [string]$WorkingDirectory = ([System.IO.Path]::GetTempPath()),
        [ValidateRange(1, 86400)][int]$TimeoutSec = 120,
        [hashtable]$EnvironmentMap,
        [switch]$ClearEnvironment
    )
    $r = [pscustomobject]@{ ExitCode=$null; Stdout=''; Stderr=''; TimedOut=$false; StartFailed=$false; ErrorMessage=$null }
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $FileName
        foreach ($a in $ArgList) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false; $psi.WorkingDirectory = $WorkingDirectory
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        if ($ClearEnvironment) { $psi.EnvironmentVariables.Clear() }
        if ($EnvironmentMap) { foreach ($k in $EnvironmentMap.Keys) { $psi.EnvironmentVariables[$k] = $EnvironmentMap[$k] } }
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        $r.StartFailed = $true; $r.ErrorMessage = $_.Exception.Message; return $r
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $remainingMs = { [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds) }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $stdinOk = $true
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($StdinText ?? ''))
        if ($bytes.Length -gt 0) {
            $writeTask = $proc.StandardInput.BaseStream.WriteAsync($bytes, 0, $bytes.Length)
            $stdinOk = $writeTask.Wait((& $remainingMs))
        }
        if ($stdinOk) { $proc.StandardInput.Close() }
    } catch { $stdinOk = $false; $r.ErrorMessage = $_.Exception.Message }
    # A child that exits without draining stdin is a normal failure, not a hang.
    if (-not $stdinOk -and $proc.HasExited) { $stdinOk = $true }
    $exited = $false
    if ($stdinOk) { $exited = $proc.WaitForExit((& $remainingMs)) }
    if (-not $exited) {
        $r.TimedOut = $true
        try { $proc.Kill($true) } catch {}
        $null = $proc.WaitForExit(10000)
    }
    try { $null = [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 15000) } catch {}
    if ($outTask.IsCompletedSuccessfully) { $r.Stdout = $outTask.Result }
    if ($errTask.IsCompletedSuccessfully) { $r.Stderr = $errTask.Result }
    $r.ExitCode = if ($r.TimedOut) { -1 } else { $proc.ExitCode }
    return $r
}

function Resolve-CliInvocation {
    param([Parameter(Mandatory)][string]$Path)
    switch -Regex ($Path) {
        '\.exe$'        { return [pscustomobject]@{ FileName=$Path; PrefixArgs=@() } }
        '\.(cmd|bat)$'  { return [pscustomobject]@{ FileName="$env:SystemRoot\System32\cmd.exe"; PrefixArgs=@('/d','/c',$Path) } }
        '\.ps1$'        { return [pscustomobject]@{ FileName=[System.Environment]::ProcessPath; PrefixArgs=@('-NoProfile','-File',$Path) } }
        default         { throw "unsupported CLI wrapper type: $Path (expected .exe, .cmd, .bat, or .ps1)" }
    }
}

function Get-CodexCandidates {
    param([string]$ConfigTomlPath = "$env:USERPROFILE\.codex\config.toml",
          [string]$BinRoot = "$env:LOCALAPPDATA\OpenAI\Codex\bin")
    $out = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $ConfigTomlPath) {
        $m = [regex]::Match((Get-Content -Raw $ConfigTomlPath), "CODEX_CLI_PATH\s*=\s*'([^']+)'")
        if ($m.Success) { $out.Add($m.Groups[1].Value) }
    }
    if (Test-Path $BinRoot) {
        Get-ChildItem $BinRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'codex.exe') } |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { $out.Add((Join-Path $_.FullName 'codex.exe')) }
        if (Test-Path (Join-Path $BinRoot 'codex.exe')) { $out.Add((Join-Path $BinRoot 'codex.exe')) }
    }
    $onPath = Get-Command codex -ErrorAction SilentlyContinue
    if ($onPath) { $out.Add($onPath.Source) }
    return @($out | Select-Object -Unique)
}

function Invoke-Candidate {
    # Bounded probe — a hung candidate must never wedge discovery. Probes read no untrusted
    # input, so they run with the inherited environment; only review sessions are hermetic.
    param([string]$Path, [string[]]$CliArgs, [ValidateRange(1,3600)][int]$TimeoutSec = 60)
    if (-not (Test-Path $Path)) { return $null }
    try { $inv = Resolve-CliInvocation -Path $Path } catch { return $null }
    $r = Invoke-BoundedProcess -FileName $inv.FileName -ArgList ($inv.PrefixArgs + $CliArgs) -TimeoutSec $TimeoutSec
    if ($r.StartFailed -or $r.TimedOut -or $r.ExitCode -ne 0) { return $null }
    return $r.Stdout
}

function Test-CandidateExitsZero {
    # For probes judged on EXIT CODE alone, never on stdout content. `codex login status`
    # answers on STDERR with an EMPTY stdout on success (confirmed against the real CLI), so a
    # probe that treats stdout truthiness as success rejects every correctly-authenticated
    # installation. Deliberately a sibling of Invoke-Candidate rather than a change to its
    # return contract: the three probes that legitimately parse stdout (--version, exec --help,
    # features list) and Test-BinaryUnchanged must keep working exactly as before, and must
    # never have stderr blended into what they parse.
    param([string]$Path, [string[]]$CliArgs, [ValidateRange(1,3600)][int]$TimeoutSec = 60)
    if (-not (Test-Path $Path)) { return $false }
    try { $inv = Resolve-CliInvocation -Path $Path } catch { return $false }
    $r = Invoke-BoundedProcess -FileName $inv.FileName -ArgList ($inv.PrefixArgs + $CliArgs) -TimeoutSec $TimeoutSec
    return (-not $r.StartFailed -and -not $r.TimedOut -and $r.ExitCode -eq 0)
}

function Get-FeatureNames {
    param([string]$FeaturesText)
    $names = foreach ($line in ($FeaturesText -split "`r?`n")) {
        if ($line -match '^\s*(\S+)\s+\S+\s+(true|false)\s*$') { $Matches[1] }
    }
    if (-not $names) { return $null }
    return @($names)
}

function Test-CodexCandidate {
    # -AllowWrapper is TEST-ONLY. Production pins real .exe binaries: hashing a .cmd/.ps1
    # wrapper hashes the wrapper, not the program it launches, so the pin would not detect
    # the actual reviewer binary being swapped underneath it.
    # -Reason is an optional [ref] out-parameter: on rejection it receives the same text
    # handed to Write-Verbose/Write-Warning, so a caller (Select-CodexCli) can surface WHY a
    # candidate was rejected without requiring -Verbose to be enabled. Omitting -Reason is
    # fully backward compatible: existing call sites are unaffected.
    param([Parameter(Mandatory)][string]$Path, [switch]$AllowWrapper, [ref]$Reason)
    if ($Path -match '\\WindowsApps\\') {
        $m = "reject (WindowsApps): $Path"; Write-Verbose $m; if ($Reason) { $Reason.Value = $m }; return $null
    }
    if (-not $AllowWrapper -and $Path -notmatch '\.exe$') {
        # Spec (amended round 3): the PATH/npm fallback stays in discovery so this is DIAGNOSED,
        # not invisible — but a shim cannot be pinned, so it is rejected with guidance.
        $m = "Codex candidate '$Path' is a wrapper, not a pinnable executable. Point CODEX_CLI_PATH at the underlying .exe or install the Codex desktop app."
        Write-Warning $m
        if ($Reason) { $Reason.Value = $m }
        return $null
    }
    $ver = Invoke-Candidate $Path @('--version')
    if (-not $ver -or $ver -notmatch 'codex-cli\s+(\S+)') {
        $m = "reject (--version): $Path"; Write-Verbose $m; if ($Reason) { $Reason.Value = $m }; return $null
    }
    $version = $Matches[1]
    if (-not (Test-CandidateExitsZero $Path @('login','status'))) {
        $m = "reject (login status): $Path"; Write-Verbose $m; if ($Reason) { $Reason.Value = $m }; return $null
    }
    $execHelp = Invoke-Candidate $Path @('exec','--help')
    foreach ($f in $script:RequiredExecFlags) {
        if ($execHelp -notmatch [regex]::Escape($f)) {
            $m = "reject (exec missing $f): $Path"; Write-Verbose $m; if ($Reason) { $Reason.Value = $m }; return $null
        }
    }
    # No resume probe: every round is a fresh `exec` session, so the resume flag surface
    # (which accepts neither -s nor -C) is not part of this design.
    $featText = Invoke-Candidate $Path @('features','list')
    if (-not $featText) {
        $m = "reject (features list): $Path"; Write-Verbose $m; if ($Reason) { $Reason.Value = $m }; return $null
    }
    $names = Get-FeatureNames -FeaturesText $featText
    if (-not $names) {
        $m = "reject (features unparseable): $Path"; Write-Verbose $m; if ($Reason) { $Reason.Value = $m }; return $null
    }
    foreach ($a in $script:FeatureAllowlist) {
        if ($names -notcontains $a) {
            $m = "reject (allowlisted '$a' missing): $Path"; Write-Verbose $m; if ($Reason) { $Reason.Value = $m }; return $null
        }
    }
    [pscustomobject]@{
        Path = $Path; Version = $version
        Sha256 = (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
        FeatureNames = $names
    }
}

function Select-CodexCli {
    param([string[]]$Candidates, [switch]$AllowWrapper)
    $reasons = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $Candidates) {
        $reason = $null
        $r = Test-CodexCandidate -Path $c -AllowWrapper:$AllowWrapper -Verbose -Reason ([ref]$reason)
        if ($r) { return $r }
        $reasons.Add("$c - $reason")
    }
    throw "No Codex CLI candidate passed the compatibility probe.`n$($reasons -join "`n")`nRemediation: open the Codex desktop app, run 'codex login', or install the standalone CLI."
}

# Test-BinaryUnchanged: pulled forward from Task 5 Step 3, same rationale as Invoke-BoundedProcess
# above. test-discovery.ps1's final assertion ("version '0.147' does NOT match '0.147.0'") calls
# this directly, and it is not otherwise defined anywhere in Task 2. It depends only on
# Invoke-Candidate (already defined above) and builtins, so it does not pull in any other part of
# Task 5 (Invoke-CodexProcess, Test-EmbedBudget, Test-PremiseManifest, etc. are NOT included here).
# Task 5 Step 3 re-adds this same function verbatim when appending to this file; if so, the second
# definition is an identical no-op redefinition, not a conflict — but Task 5's implementer should
# know it is already present and may skip re-adding it.
function Test-BinaryUnchanged {
    # Hash AND exactly-parsed version must match. Substring matching is unsafe:
    # a pinned "0.14" would silently accept "0.147.0-alpha.6.5".
    param([Parameter(Mandatory)][pscustomobject]$PinnedCli)
    if (-not (Test-Path $PinnedCli.Path)) { return $false }
    if ((Get-FileHash -Algorithm SHA256 $PinnedCli.Path).Hash.ToLowerInvariant() -cne $PinnedCli.Sha256) { return $false }
    $verText = Invoke-Candidate $PinnedCli.Path @('--version')
    if (-not $verText -or $verText -notmatch 'codex-cli\s+(\S+)') { return $false }
    return ($Matches[1] -ceq $PinnedCli.Version)
}

function Assert-NoEmptyStringElements {
    <# Gives a [string[]] parameter a DELIBERATE, terminating rejection of a missing value or an
       empty-string/$null element, instead of relying on PowerShell's [Parameter(Mandatory)]
       binder. That binder applies an implicit "no element may be null or an empty string" check
       to MANDATORY [string]/[string[]] parameters specifically (confirmed empirically elsewhere
       in this file -- this is what [AllowEmptyCollection()] alone does not waive), and on a
       [string[]] the rejection surfaces as a NON-TERMINATING "Cannot bind argument ... because
       it is an empty string" error. A real process's stdout, once split on newline, ALWAYS ends
       in a trailing empty-string element -- and because that bind failure is non-terminating, a
       caller's own `if (-not $result.Ok)`-shaped guard can silently fail to evaluate, skipping
       BOTH branches and defeating the check entirely with no error ever surfaced (this already
       shipped once, in Get-RunUsage's -EventLines -- see its own comment for the full
       repro). The seven parameters given this treatment (Get-InvocationAudit -CodexArgs,
       Get-InvocationAudit -ExpectedDisable, Get-DisableSet -FeatureNames, New-CodexArgs
       -DisableSet, Get-InvocationProfileHash -DisableSet, Invoke-CodexProcess -CodexArgs,
       Invoke-Gh -GhArgs) are all currently unreachable with a genuinely empty element -- every
       real caller's array is either regex- or code-derived and provably non-empty, or (Invoke-Gh)
       built from hand-written string literals and already-validated values -- but "currently
       unreachable" is not "provably safe for every future caller", and each is exactly the same
       shape as the bug that already shipped once. The last four were identified but deliberately
       left out of the first fix (see task-14-report.md): flagged rather than expanded into
       unilaterally, then actioned here once asked for by name. #>
    param([Parameter(Mandatory)][string]$FunctionName, [Parameter(Mandatory)][string]$ParameterName, [string[]]$Values)
    if ($null -eq $Values) { throw "${FunctionName}: -$ParameterName is required" }
    $bad = @($Values | Where-Object { [string]::IsNullOrEmpty($_) })
    if ($bad.Count -gt 0) { throw "${FunctionName}: -$ParameterName must not contain a null or empty-string element ($($bad.Count) found of $($Values.Count))" }
}

function Get-DisableSet {
    # Default-deny: every enumerated feature not on the allowlist. Reported state IGNORED
    # (features list reflects user config; reviews run --ignore-user-config).
    #
    # -FeatureNames is deliberately NOT [Parameter(Mandatory)]: see Assert-NoEmptyStringElements.
    # Required-ness and the no-empty-element check are both enforced explicitly below instead,
    # with a clean terminating error rather than PowerShell's Mandatory binder (which
    # non-terminating-errors on exactly this input shape).
    param([string[]]$FeatureNames)
    Assert-NoEmptyStringElements -FunctionName 'Get-DisableSet' -ParameterName 'FeatureNames' -Values $FeatureNames
    @($FeatureNames | Where-Object { $script:FeatureAllowlist -notcontains $_ } | Sort-Object -Unique)
}

function New-CodexArgs {
    # One shape only: every round is a fresh `codex exec` session.
    #
    # -DisableSet is deliberately NOT [Parameter(Mandatory)]: see Assert-NoEmptyStringElements
    # (defined above Get-DisableSet). Required-ness and the no-empty-element check are enforced
    # explicitly below instead of relying on PowerShell's Mandatory binder.
    param(
        [Parameter(Mandatory)][string]$HarnessDir,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$VerdictPath,
        [string[]]$DisableSet,
        [string]$Model = 'gpt-5.6-sol',
        [string]$Effort = 'xhigh'
    )
    Assert-NoEmptyStringElements -FunctionName 'New-CodexArgs' -ParameterName 'DisableSet' -Values $DisableSet
    $a = [System.Collections.Generic.List[string]]::new()
    $a.Add('exec')
    $a.AddRange([string[]]@('--ignore-user-config','--ignore-rules','--skip-git-repo-check'))
    $a.AddRange([string[]]@('-s','read-only','-C',$HarnessDir))
    $a.AddRange([string[]]@('-m',$Model,'-c',"model_reasoning_effort=`"$Effort`""))
    $a.AddRange([string[]]@('-c','web_search="disabled"','-c','shell_environment_policy.inherit="none"'))
    foreach ($f in $DisableSet) { $a.Add('--disable'); $a.Add($f) }
    $a.AddRange([string[]]@('--output-schema',$SchemaPath,'-o',$VerdictPath,'--json','-'))
    return $a.ToArray()
}

function Get-InvocationAudit {
    <# Two independent layers. Layer 1 parses flag/VALUE pairs from the actual array and checks
       hard invariants — presence checks alone are worthless, since `-s danger-full-access`,
       a wrong -C, a wrong model, a duplicate conflicting -c, or an appended `--enable shell_tool`
       all contain the "required" tokens. Layer 2 rebuilds the canonical array from the same
       declared inputs and demands exact ordinal equality, so ANY deviation fails.
       -CodexArgs and -ExpectedDisable are both deliberately NOT [Parameter(Mandatory)]: see
       Assert-NoEmptyStringElements (defined above Get-DisableSet). Required-ness and the
       no-empty-element check are enforced explicitly below instead of relying on PowerShell's
       Mandatory binder — an audit function whose whole job is to catch a tampered/adversarial
       argument array is exactly the wrong place to let a malformed input silently defeat the
       check instead of loudly failing it. #>
    param(
        [string[]]$CodexArgs,
        [Parameter(Mandatory)][string]$HarnessDir,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$VerdictPath,
        [string[]]$ExpectedDisable,
        [string]$Model = 'gpt-5.6-sol',
        [string]$Effort = 'xhigh'
    )
    Assert-NoEmptyStringElements -FunctionName 'Get-InvocationAudit' -ParameterName 'CodexArgs' -Values $CodexArgs
    Assert-NoEmptyStringElements -FunctionName 'Get-InvocationAudit' -ParameterName 'ExpectedDisable' -Values $ExpectedDisable
    # --- Layer 1: hard invariants on parsed pairs.
    foreach ($b in @('--enable','--dangerously-bypass-approvals-and-sandbox','--dangerously-bypass-hook-trust','--oss')) {
        if ($CodexArgs -contains $b) { throw "audit: banned argument '$b'" }
    }
    $single = @('-s','-C','-m','--output-schema','-o')
    $pairs = @{}
    $cVals = [System.Collections.Generic.List[string]]::new()
    $dVals = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $CodexArgs.Count; $i++) {
        $a = $CodexArgs[$i]
        if ($i + 1 -ge $CodexArgs.Count) { break }
        if ($a -ceq '-c')        { $cVals.Add($CodexArgs[$i + 1]); $i++; continue }
        if ($a -ceq '--disable') { $dVals.Add($CodexArgs[$i + 1]); $i++; continue }
        if ($single -contains $a) {
            if ($pairs.ContainsKey($a)) { throw "audit: duplicate '$a'" }
            $pairs[$a] = $CodexArgs[$i + 1]; $i++; continue
        }
    }
    if ($pairs['-s'] -cne 'read-only') { throw "audit: sandbox must be exactly 'read-only' (got '$($pairs['-s'])')" }
    if ($pairs['-C'] -cne $HarnessDir) { throw "audit: -C must be the harness '$HarnessDir' (got '$($pairs['-C'])')" }
    if ($CodexArgs -contains 'resume') { throw "audit: resume is not part of this design (every round is a fresh session)" }
    if ($pairs['-m'] -cne $Model) { throw "audit: model must be '$Model' (got '$($pairs['-m'])')" }
    if ($pairs['--output-schema'] -cne $SchemaPath) { throw "audit: output-schema mismatch" }
    if ($pairs['-o'] -cne $VerdictPath) { throw "audit: verdict path mismatch" }
    $expC = @("model_reasoning_effort=`"$Effort`"", 'web_search="disabled"', 'shell_environment_policy.inherit="none"') | Sort-Object
    $actC = @($cVals) | Sort-Object
    if ($cVals.Count -ne $expC.Count) { throw "audit: expected $($expC.Count) -c overrides, found $($cVals.Count) (duplicate or extra)" }
    if ((($actC -join '|')) -cne (($expC -join '|'))) { throw "audit: -c override mismatch: [$($cVals -join ', ')]" }
    $expD = @($ExpectedDisable | Sort-Object -Unique)
    if ($dVals.Count -ne $expD.Count) { throw "audit: expected $($expD.Count) --disable flags, found $($dVals.Count)" }
    if (((@($dVals) | Sort-Object) -join '|') -cne ($expD -join '|')) { throw "audit: disable-set mismatch" }
    foreach ($f in @('--ignore-user-config','--ignore-rules','--skip-git-repo-check','--json')) {
        if ($CodexArgs -notcontains $f) { throw "audit: missing '$f'" }
    }
    if ($CodexArgs[-1] -cne '-') { throw "audit: prompt must come from stdin ('-')" }
    # --- Layer 2: exact canonical equality.
    $canon = New-CodexArgs -HarnessDir $HarnessDir -SchemaPath $SchemaPath -VerdictPath $VerdictPath `
        -DisableSet $ExpectedDisable -Model $Model -Effort $Effort
    if ($canon.Count -ne $CodexArgs.Count) { throw "audit: argument count differs from canonical ($($CodexArgs.Count) vs $($canon.Count))" }
    for ($i = 0; $i -lt $canon.Count; $i++) {
        if ($canon[$i] -cne $CodexArgs[$i]) { throw "audit: position $i differs (canonical '$($canon[$i])', actual '$($CodexArgs[$i])')" }
    }
    return "codex $($CodexArgs -join ' ')"
}

function Test-Verdict {
    # Single source of truth for verdict consumption. Output is ALWAYS the normalized
    # object + canonical JSON; the severity invariant is applied by MUTATING the object,
    # so no downstream consumer can ever see an un-downgraded approve.
    #
    # SchemaPath (renamed from StructuralSchemaPath, see task-7-report.md): the split between
    # a codex-facing generation schema and a separate local-validation schema is GONE.
    # Evidence: the real API rejects our output schema with `invalid_json_schema: In
    # context=(), 'if' is not permitted` (HTTP 400, BEFORE inference) -- probing established
    # 'if'/'then' is the ONLY offending keyword (minLength/maxLength/maxItems are all
    # accepted). There is exactly one schema on disk now (schemas/verdict.schema.json), used
    # for BOTH --output-schema and this validation, so it no longer encodes the severity
    # invariant (approve implies nit-only recommendations) -- that invariant is now enforced
    # SOLELY by the normalization below, which runs before anything canonical is ever written
    # (invoke-codex.ps1) or published (publish-review.ps1).
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][string]$SchemaPath)
    $result = [pscustomobject]@{ Valid=$false; Reason=$null; Downgraded=$false; Normalized=$null; NormalizedJson=$null }
    $schema = Get-Content -Raw $SchemaPath
    if (-not (Test-Json -Json $Json -Schema $schema -ErrorAction SilentlyContinue)) {
        $result.Reason = 'structural validation failed'; return $result
    }
    $obj = $Json | ConvertFrom-Json
    if ($obj.verdict -eq 'approve') {
        $nonNit = @($obj.recommendations | Where-Object { $_.severity -ne 'nit' })
        if ($nonNit.Count -gt 0) {
            $obj.verdict = 'request_changes'
            $result.Downgraded = $true
            $result.Reason = "approve carried $($nonNit.Count) non-nit recommendation(s); downgraded"
        }
    }
    $result.Normalized = $obj
    $result.NormalizedJson = ($obj | ConvertTo-Json -Depth 6 -Compress)
    $result.Valid = $true
    return $result
}

# --- Task 5: process execution + premise manifest -------------------------------------
# NOTE: Invoke-BoundedProcess and Test-BinaryUnchanged for Task 5 already live above (pulled
# forward for Task 2, see the comment at Test-BinaryUnchanged's definition) and are not
# repeated here.

# Additions here require the empirical-necessity procedure, a spec amendment, and a test — see
# plan Task 5 Step 5. Every entry must be NECESSARY (proven by observed failure without it) and
# NON-SENSITIVE (a fixed machine constant, never a credential or user data).
#
# SystemRoot: PROVEN NECESSARY 2026-08-12. With a CODEX_HOME-only environment the real
# `codex exec` failed every request with "failed to connect to websocket: A non-recoverable
# error occurred during a database lookup (os error 11003)" against wss://chatgpt.com — i.e.
# DNS resolution fails, because Windows name-resolution needs SystemRoot to initialise. Isolated
# and confirmed without any model call: a child process with CODEX_HOME only cannot resolve
# chatgpt.com, and the same child with SystemRoot added resolves it. SystemDrive was tested and
# is NOT required. The earlier "CODEX_HOME only" verification used `codex --version`, which
# never touches the network and so could not have caught this.
# Non-sensitive: the value is the fixed OS install path (C:\Windows); it carries no credential.
$script:RequiredChildEnv = @{ SystemRoot = $env:SystemRoot }

function Test-EmbedBudget {
    param([Parameter(Mandatory)][string]$PromptText, [int]$BudgetBytes = 50000)
    $bytes = [Text.Encoding]::UTF8.GetByteCount($PromptText)
    [pscustomobject]@{ Ok = ($bytes -le $BudgetBytes); Bytes = $bytes }
}

function Write-NewFileExclusive {
    # Atomic create-only. A Test-Path check followed by Set-Content is not create-only: two
    # concurrent invocations can both pass the check and the second silently wins. FileMode
    # CreateNew makes the OS arbitrate, so exactly one writer can ever create the file.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $fs.Write($bytes, 0, $bytes.Length)
    } finally { $fs.Dispose() }
}

function Get-InvocationProfileHash {
    <# Hashes the ENTIRE canonical argument profile with volatile paths stubbed out, not a
       hand-picked trio of fields. Base overhead can shift with anything that changes injected
       context — sandbox mode, the ignore flags, web_search, the environment policy, model,
       effort, the complete disable set — and enumerating "the ones that matter" is exactly the
       kind of list that rots. Deriving the hash from New-CodexArgs means any future argument
       automatically becomes part of the binding.

       -DisableSet is deliberately NOT [Parameter(Mandatory)]: see Assert-NoEmptyStringElements
       (defined above Get-DisableSet). A Mandatory [string[]] rejects an array containing an
       empty-string element as a non-terminating bind error instead of a clean throw — exactly
       the shape that already shipped one fail-open bug (Get-RunUsage's -EventLines). #>
    param([string[]]$DisableSet,
          [string]$Model = 'gpt-5.6-sol', [string]$Effort = 'xhigh')
    Assert-NoEmptyStringElements -FunctionName 'Get-InvocationProfileHash' -ParameterName 'DisableSet' -Values $DisableSet
    $canon = New-CodexArgs -HarnessDir '<HARNESS>' -SchemaPath '<SCHEMA>' -VerdictPath '<VERDICT>' `
        -DisableSet $DisableSet -Model $Model -Effort $Effort
    $material = ($canon -join "`u{001f}")
    -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($material)) | ForEach-Object { $_.ToString('x2') })
}

function Test-StackAcceptance {
    <# Binds a review round to the reviewer STACK it was last vetted against: the selected CLI
       (path/version/content hash), the verdict schema, the account AGENTS.md (accepted trusted
       input), the invocation profile (model/effort/feature policy), and the model name. This is
       everything calibrate-premises.ps1 can (re)derive from a compatibility PROBE alone, with no
       live model call -- it proves the stack is internally consistent and matches what would
       actually run, i.e. ACCEPTED. It does NOT prove a real request against the real API was
       ever sent or accepted; that is what Test-PremiseManifest (below) additionally requires via
       a separate live-evidence record. calibrate-premises.ps1 validates its own output against
       THIS narrower check, not the full Test-PremiseManifest gate, which it can never satisfy on
       its own (see task-14-report.md).

       Historical (superseded 2026-08-12): this manifest used to ALSO carry four numeric budget
       premises (tokenizer_family, tokenizer_evidence, base_overhead_tokens, max_output_tokens,
       context_window_tokens) and enforce "BudgetBytes + base_overhead + max_output <= 0.75 x
       context_window" -- an ESTIMATE of whether a round would fit, resting on an unevidenced
       claim (tokens<=bytes, which holds only for a byte-level tokenizer and was never
       established for gpt-5.6-sol) and a conservative-but-approximate overhead sample. The
       live-evidence round found the real CLI's terminal turn.completed event reports the EXACT
       usage.input_tokens for the request that was just made, which subsumes the estimate
       entirely: see Get-RunUsage below and the acceptance-time usage gate in invoke-codex.ps1,
       which check the real measurement on every round instead of predicting it in advance. The
       numeric premises and the inequality are gone; the stack-identity binding below is what
       remains, because it still does real work no other check does: it forces re-validation
       whenever the CLI, schema, AGENTS.md, or invocation profile drifts out from under a prior
       result.

       -ActualCli is REQUIRED: validating the binary the manifest names proves nothing about
       the binary the round will actually run. A manifest recorded for A must not authorize a
       review executed by B. #>
    param([Parameter(Mandatory)][string]$SkillRoot,
          [Parameter(Mandatory)][pscustomobject]$ActualCli,
          [Parameter(Mandatory)][string]$InvocationProfileHash,
          [string]$Model = 'gpt-5.6-sol')
    $bad = { param($why) [pscustomobject]@{ Valid=$false; Reason=$why; Manifest=$null } }
    $path = Join-Path $SkillRoot 'premises.json'
    if (-not (Test-Path $path)) { return (& $bad "premises.json is absent") }
    try { $m = Get-Content -Raw $path | ConvertFrom-Json } catch { return (& $bad "premises.json is not valid JSON") }
    # lib.ps1 runs under Set-StrictMode -Version Latest (top of file). Under strict mode, dotting
    # into a JSON property that is ENTIRELY ABSENT (not merely present-with-null) throws
    # PropertyNotFoundException instead of yielding $null — confirmed empirically. That is the
    # opposite of what a fail-CLOSED validator needs: a hand-edited or drifted premises.json is
    # far more likely to simply omit a key than to write it out as an explicit null, and that is
    # exactly the case this function exists to catch and report, not crash on. Backfill every
    # top-level key this function ever dots into as an explicit $null (only when genuinely
    # absent) before any of them are read, so a wholly missing field takes the same "is missing"
    # Reason path below as every other validation failure, instead of throwing past the caller.
    foreach ($f in @('version','cli_sha256','cli_version','cli_path','schema_sha256','agents_md_sha256','model','invocation_profile_sha256')) {
        if ($m.PSObject.Properties.Name -notcontains $f) { $m | Add-Member -NotePropertyName $f -NotePropertyValue $null }
    }
    if ($m.version -ne 1) { return (& $bad "unsupported premises version '$($m.version)'") }
    foreach ($f in @('cli_sha256','cli_version','cli_path','schema_sha256','agents_md_sha256','model','invocation_profile_sha256')) {
        if ($null -eq $m.$f -or "$($m.$f)" -eq '') { return (& $bad "premises.json is missing '$f'") }
    }
    if ($m.model -cne $Model) { return (& $bad "premises recorded for model '$($m.model)', running '$Model'") }
    # Staleness: a manifest is valid only for the stack it was recorded against.
    $schemaSha = (Get-FileHash -Algorithm SHA256 (Join-Path $SkillRoot 'schemas\verdict.schema.json')).Hash.ToLowerInvariant()
    if ($m.schema_sha256 -cne $schemaSha) { return (& $bad "verdict schema changed since the premises were recorded") }
    if ($m.invocation_profile_sha256 -cne $InvocationProfileHash) { return (& $bad "invocation profile changed since the premises were recorded (model, reasoning effort, or feature policy)") }
    # THE BINARY THAT WILL ACTUALLY RUN — not merely the one the manifest names.
    if ($m.cli_path -cne $ActualCli.Path) { return (& $bad "premises recorded for '$($m.cli_path)' but this round would run '$($ActualCli.Path)'") }
    if ($m.cli_version -cne $ActualCli.Version) { return (& $bad "premises recorded for CLI version '$($m.cli_version)' but '$($ActualCli.Version)' was selected") }
    if ($m.cli_sha256 -cne $ActualCli.Sha256) { return (& $bad "Codex CLI changed since the premises were recorded") }
    $agentsPath = "$env:USERPROFILE\.codex\AGENTS.md"
    $agentsSha = if (Test-Path $agentsPath) { (Get-FileHash -Algorithm SHA256 $agentsPath).Hash.ToLowerInvariant() } else { 'absent' }
    if ($m.agents_md_sha256 -cne $agentsSha) { return (& $bad "account AGENTS.md changed since the premises were recorded (it is accepted trusted input)") }
    [pscustomobject]@{ Valid=$true; Reason=$null; Manifest=$m }
}

function Test-PremiseManifest {
    <# THE gate: normal invocation (invoke-codex.ps1) and installation (install.ps1) both refuse
       to proceed without this passing for the stack that would actually run.

       Binds authorization to LIVE EVIDENCE, not merely stack acceptance (added: see
       task-14-report.md). Test-StackAcceptance above proves premises.json's stack-identity
       fields are internally consistent and match the current CLI/schema/AGENTS.md/invocation
       profile -- but calibrate-premises.ps1 can reproduce a passing Test-StackAcceptance result
       from a compatibility PROBE alone, with no live model call, immediately after a CLI or
       schema change, with no live gate ever rerun. Presenting that probe as proof of a working
       reviewer stack would let a round run against a stack nobody has actually verified against
       the real API since the change. This function additionally requires a `live_evidence`
       record on the manifest: which live gate passed, when, and the exact fingerprint (CLI
       path/version/hash, schema hash, AGENTS.md hash, invocation-profile hash) it passed
       against. `live_evidence` is stamped ONLY by tests/live/live-schema-gate.ps1, on an actual
       passing request against the real API -- calibrate-premises.ps1 never writes or refreshes
       it, so recalibrating always drops any prior live evidence and a live gate rerun is
       required again before this passes. #>
    param([Parameter(Mandatory)][string]$SkillRoot,
          [Parameter(Mandatory)][pscustomobject]$ActualCli,
          [Parameter(Mandatory)][string]$InvocationProfileHash,
          [string]$Model = 'gpt-5.6-sol')
    $accepted = Test-StackAcceptance -SkillRoot $SkillRoot -ActualCli $ActualCli `
        -InvocationProfileHash $InvocationProfileHash -Model $Model
    if (-not $accepted.Valid) { return $accepted }
    $m = $accepted.Manifest
    $bad = { param($why) [pscustomobject]@{ Valid=$false; Reason=$why; Manifest=$null } }
    # Same StrictMode backfill discipline as Test-StackAcceptance above: a genuinely-absent
    # 'live_evidence' key (the normal case right after a fresh calibration) must fail closed with
    # a Reason, never throw PropertyNotFoundException past this function's contract.
    if ($m.PSObject.Properties.Name -notcontains 'live_evidence') { $m | Add-Member -NotePropertyName 'live_evidence' -NotePropertyValue $null }
    if ($null -eq $m.live_evidence) {
        return (& $bad "premises.json records stack acceptance but no live evidence (calibrate-premises.ps1 cannot provide it); run tests/live/live-schema-gate.ps1")
    }
    $le = $m.live_evidence
    foreach ($f in @('gate','verified_utc','cli_path','cli_version','cli_sha256','schema_sha256','agents_md_sha256','invocation_profile_sha256')) {
        if ($le.PSObject.Properties.Name -notcontains $f) { $le | Add-Member -NotePropertyName $f -NotePropertyValue $null }
    }
    foreach ($f in @('gate','verified_utc','cli_path','cli_version','cli_sha256','schema_sha256','agents_md_sha256','invocation_profile_sha256')) {
        if ($null -eq $le.$f -or "$($le.$f)" -eq '') { return (& $bad "live-evidence record is missing '$f'; run tests/live/live-schema-gate.ps1") }
    }
    # Compared against the MANIFEST's own top-level fields, not re-derived here: Test-StackAcceptance
    # just proved those are exactly the CURRENT stack, so this is "matches the current stack" with
    # no second round of hashing.
    if ($le.cli_path -cne $m.cli_path -or $le.cli_version -cne $m.cli_version -or $le.cli_sha256 -cne $m.cli_sha256) {
        return (& $bad "live-evidence record was stamped for a different CLI than the one that would run this round; rerun tests/live/live-schema-gate.ps1")
    }
    if ($le.schema_sha256 -cne $m.schema_sha256) { return (& $bad "live-evidence record predates the current verdict schema; rerun tests/live/live-schema-gate.ps1") }
    if ($le.agents_md_sha256 -cne $m.agents_md_sha256) { return (& $bad "live-evidence record predates the current AGENTS.md; rerun tests/live/live-schema-gate.ps1") }
    if ($le.invocation_profile_sha256 -cne $m.invocation_profile_sha256) { return (& $bad "live-evidence record predates the current invocation profile; rerun tests/live/live-schema-gate.ps1") }
    [pscustomobject]@{ Valid=$true; Reason=$null; Manifest=$m }
}

function Write-LiveEvidence {
    <# The ONLY writer of the live_evidence record Test-PremiseManifest requires (see above).
       Called by tests/live/live-schema-gate.ps1, and only there, after an actual live round
       against the real API has succeeded. Requires premises.json to already exist (calibrate-
       premises.ps1 must run first) -- this stamps the live-evidence sub-object onto the existing
       stack-acceptance manifest, it does not create one. #>
    param([Parameter(Mandatory)][string]$SkillRoot,
          [Parameter(Mandatory)][string]$Gate,
          [Parameter(Mandatory)][pscustomobject]$ActualCli,
          [Parameter(Mandatory)][string]$SchemaSha256,
          [Parameter(Mandatory)][string]$AgentsMdSha256,
          [Parameter(Mandatory)][string]$InvocationProfileHash)
    $path = Join-Path $SkillRoot 'premises.json'
    if (-not (Test-Path $path)) { throw "premises.json is absent; run calibrate-premises.ps1 before stamping live evidence" }
    $m = Get-Content -Raw $path | ConvertFrom-Json
    $evidence = [pscustomobject]@{
        gate = $Gate; verified_utc = (Get-Date -AsUTC -Format o)
        cli_path = $ActualCli.Path; cli_version = $ActualCli.Version; cli_sha256 = $ActualCli.Sha256
        schema_sha256 = $SchemaSha256; agents_md_sha256 = $AgentsMdSha256
        invocation_profile_sha256 = $InvocationProfileHash
    }
    if ($m.PSObject.Properties.Name -contains 'live_evidence') { $m.live_evidence = $evidence }
    else { $m | Add-Member -NotePropertyName 'live_evidence' -NotePropertyValue $evidence }
    $m | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding utf8
}

function Invoke-CodexProcess {
    # Thin, hermetic wrapper over the bounded runner.
    #
    # -CodexArgs is deliberately NOT [Parameter(Mandatory)]: see Assert-NoEmptyStringElements
    # (defined above Get-DisableSet). Same non-terminating-bind-error shape as the other
    # parameters given this treatment; enforced explicitly below instead.
    param(
        [Parameter(Mandatory)][string]$CliPath,
        [string[]]$CodexArgs,
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][string]$HarnessDir,
        [ValidateRange(1, 86400)][int]$TimeoutSec = 1800
    )
    Assert-NoEmptyStringElements -FunctionName 'Invoke-CodexProcess' -ParameterName 'CodexArgs' -Values $CodexArgs
    $inv = Resolve-CliInvocation -Path $CliPath
    $childEnv = @{ CODEX_HOME = "$env:USERPROFILE\.codex" }
    foreach ($k in $script:RequiredChildEnv.Keys) { $childEnv[$k] = $script:RequiredChildEnv[$k] }
    $res = Invoke-BoundedProcess -FileName $inv.FileName -ArgList ($inv.PrefixArgs + $CodexArgs) `
        -StdinText $PromptText -WorkingDirectory $HarnessDir -TimeoutSec $TimeoutSec `
        -EnvironmentMap $childEnv -ClearEnvironment
    [pscustomobject]@{
        ExitCode = $res.ExitCode; StdoutLines = ($res.Stdout -split "`r?`n"); StderrText = $res.Stderr
        TimedOut = $res.TimedOut; StartFailed = $res.StartFailed; ErrorMessage = $res.ErrorMessage
    }
}

# ---------------------------------------------------------------------------------------
# Acceptance-time usage gate. Evidence from live runs against the real CLI (accepted
# schema, see task-7-report.md): the terminal event is EXACTLY ONE
#   {"type":"turn.completed","usage":{"input_tokens":9456,"cached_input_tokens":0,
#    "cache_write_input_tokens":0,"output_tokens":25,"reasoning_output_tokens":0}}
# per run. Usage scales with prompt size (measured: 147 prompt bytes -> input_tokens 9456;
# 20,160 bytes -> 23,168 -- i.e. CLI overhead is roughly 9,400 tokens on top of the prompt
# itself). Real event taxonomy: thread.started, turn.started, item.completed (item.type =
# agent_message | error), turn.completed, error.
#
# invoke-codex.ps1 calls Get-RunUsage BEFORE the canonical verdict is ever written: a
# completed review is accepted and publishable only when the run's OWN accounting proves it
# stayed within budget -- never merely because a verdict file happened to be produced. The
# preflight byte budget (Test-EmbedBudget) is a cheap OPERATIONAL input estimate only; this
# is the formal guarantee.
# ---------------------------------------------------------------------------------------
function Get-RunUsage {
    <# Parses a completed run's raw stdout event stream (JSONL, one event per line) and
       enforces every acceptance-time invariant on it: no top-level error event, EXACTLY ONE
       turn.completed event, and that event's usage.input_tokens present as a genuine
       positive integer. Returns {Ok, Reason, InputTokens, RawLine} -- RawLine is the
       terminal event exactly as received, for the caller to persist verbatim alongside the
       parsed integer (see Write-NewFileExclusive at the round-N-attempt-M-usage.json call
       site). Deliberately silent, not throwing, on a line that fails to parse as JSON or
       parses to a bare JSON null: under Set-StrictMode -Version Latest (inherited from this
       file's own top-of-file directive) this function must fail CLOSED with a Reason on any
       malformed stream, never crash past its documented contract.
       -EventLines is deliberately NOT [Parameter(Mandatory)]: PowerShell's parameter binder
       applies an implicit "no element may be null or an empty string" check to MANDATORY
       [string]/[string[]] parameters specifically (confirmed empirically — this is what
       [AllowEmptyCollection()] alone does not waive). A real process's stdout, once split on
       newline, ALWAYS ends in a trailing empty-string element (output ends with a trailing
       newline), so a Mandatory here would reject every genuine call with a non-terminating
       "Cannot bind argument ... because it is an empty string" error -- and because that bind
       failure and the strict-mode "variable has not been set" error it cascades into are BOTH
       non-terminating, the caller's own `if (-not $usage.Ok)` condition would itself fail to
       evaluate and PowerShell would silently skip the ENTIRE if-statement (neither branch runs)
       and fall through to the next line, silently defeating the whole gate with no error ever
       surfaced to the caller. Confirmed by direct repro before this was caught. #>
    param([string[]]$EventLines)
    $bad = { param($why) [pscustomobject]@{ Ok=$false; Reason=$why; InputTokens=$null; RawLine=$null } }
    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $EventLines) {
        if (-not $line -or -not $line.Trim()) { continue }
        try { $parsed = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $parsed) { continue }
        $events.Add([pscustomobject]@{ Raw = $line; Parsed = $parsed })
    }
    $isType = { param($e, $t) ($e.Parsed.PSObject.Properties.Name -contains 'type') -and ($e.Parsed.type -ceq $t) }
    if (@($events | Where-Object { & $isType $_ 'error' }).Count -gt 0) {
        return (& $bad "the event stream reported a top-level error event")
    }
    $completed = @($events | Where-Object { & $isType $_ 'turn.completed' })
    if ($completed.Count -eq 0) { return (& $bad "no turn.completed event in the event stream") }
    if ($completed.Count -gt 1) { return (& $bad "$($completed.Count) turn.completed events in the event stream (expected exactly one)") }
    $ev = $completed[0]
    $hasUsage = $ev.Parsed.PSObject.Properties.Name -contains 'usage'
    $usage = if ($hasUsage) { $ev.Parsed.usage } else { $null }
    if (-not $hasUsage -or $null -eq $usage) { return (& $bad "turn.completed carries no usage object") }
    if ($usage.PSObject.Properties.Name -notcontains 'input_tokens') { return (& $bad "usage carries no input_tokens") }
    $it = $usage.input_tokens
    if ($it -isnot [int] -and $it -isnot [long]) { return (& $bad "usage.input_tokens is not an integer (got '$it')") }
    if ([long]$it -le 0) { return (& $bad "usage.input_tokens must be a positive integer (got $it)") }
    [pscustomobject]@{ Ok = $true; Reason = $null; InputTokens = [long]$it; RawLine = $ev.Raw }
}

# --- Task 6: harness placement, validated state paths, versioned merge-state, carry-over ledger --

function Test-PathUnderRoot {
    # Self-review fix: a bare `$Path.StartsWith($Root)` is NOT a directory-boundary check — it is
    # a character-prefix check. '...\codex-review\harness-evil\x' STARTS WITH the STRING
    # '...\codex-review\harness' (confirmed empirically), even though 'harness-evil' is a totally
    # different, unmanaged SIBLING directory, never created through New-HarnessDir's exclusivity
    # check, that could hold planted residue. Appending a trailing separator to $Root before
    # comparing makes the check segment-aware, matching how the filesystem actually nests
    # directories, so a same-prefix sibling can no longer be mistaken for "inside".
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $boundary = $Root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return ($Path -ceq $Root) -or $Path.StartsWith($boundary)
}

function Assert-HarnessSafe {
    # A harness must be outside the repo AND its git common dir (Codex reads AGENTS.md from the
    # git root down to cwd) AND empty. The prompt travels over stdin and the sandbox is read-only,
    # so a harness never legitimately contains a file — anything present is untrusted residue.
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$RepoRoot)
    if (-not (Test-Path $Dir -PathType Container)) { throw "harness missing: $Dir" }
    $abs = [System.IO.Path]::GetFullPath($Dir)
    $root = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'codex-review\harness'))
    if (-not (Test-PathUnderRoot -Path $abs -Root $root)) { throw "harness outside its managed root: $abs" }
    $repoAbs = [System.IO.Path]::GetFullPath($RepoRoot)
    $common = (git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir 2>$null)
    if ($common) { $common = $common.Trim() }
    if ((Test-PathUnderRoot -Path $abs -Root $repoAbs) -or
        ($common -and (Test-PathUnderRoot -Path $abs -Root ([System.IO.Path]::GetFullPath($common))))) {
        throw "harness must live outside the reviewed repository (AGENTS.md discovery boundary)"
    }
    $residue = @(Get-ChildItem -LiteralPath $abs -Force -ErrorAction SilentlyContinue)
    if ($residue.Count -gt 0) {
        throw "harness is not empty (untrusted residue: $(($residue | Select-Object -First 5 -ExpandProperty Name) -join ', '))"
    }
    return $abs
}

function New-HarnessDir {
    # Unpredictable name, generated on first use, must not already exist. A caller-chosen or
    # reusable id could point at a pre-existing directory holding a planted AGENTS.md.
    param([Parameter(Mandatory)][string]$RepoRoot)
    $root = Join-Path $env:LOCALAPPDATA 'codex-review\harness'
    New-Item -ItemType Directory -Force $root | Out-Null
    $bytes = [byte[]]::new(16)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $name = (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
    $dir = Join-Path $root $name
    if (Test-Path $dir) { throw "harness collision on $name — refusing to reuse an existing directory" }
    New-Item -ItemType Directory $dir | Out-Null          # no -Force: creation must be fresh
    return (Assert-HarnessSafe -Dir $dir -RepoRoot $RepoRoot)
}

function Get-StateDir {
    param(
        [Parameter(Mandatory)][ValidateSet('doc','pr')][string]$Mode,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Topic, [ValidateSet('spec','plan')][string]$Phase, [string]$Date,
        [string]$OwnerRepo, [int]$PrNumber
    )
    if ($Mode -eq 'doc') {
        if ($Topic -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw "invalid topic '$Topic'" }
        if ($Date -notmatch '^\d{4}-\d{2}-\d{2}$') { throw "invalid date '$Date'" }
        if (-not $Phase) { throw "doc mode requires -Phase" }
        $root = Join-Path $RepoRoot 'docs\superpowers\reviews'
        $dir = [System.IO.Path]::GetFullPath((Join-Path $root "$Date-$Topic\$Phase"))
    } else {
        if ($OwnerRepo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "invalid owner/repo '$OwnerRepo'" }
        if ($PrNumber -lt 1) { throw "invalid PR number $PrNumber" }
        $common = (git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir).Trim()
        if ($LASTEXITCODE -ne 0) { throw "not a git repository: $RepoRoot" }
        $root = Join-Path $common 'info\codex-review'
        $dir = [System.IO.Path]::GetFullPath((Join-Path $root "$($OwnerRepo -replace '/', '-')\pr-$PrNumber"))
    }
    # Test-PathUnderRoot, not a bare StartsWith: see its definition above for why a raw
    # character-prefix check would wrongly accept a sibling directory (e.g. '...\reviews-evil'
    # vs '...\reviews') as being inside the root.
    $rootFull = [System.IO.Path]::GetFullPath($root)
    if (-not (Test-PathUnderRoot -Path $dir -Root $rootFull)) { throw "state path escapes its root" }
    New-Item -ItemType Directory -Force $dir | Out-Null
    return $dir
}

function Write-RoundState {
    param([Parameter(Mandatory)][string]$StateDir, [Parameter(Mandatory)][hashtable]$Patch)
    $file = Join-Path $StateDir 'state.json'
    $state = @{}
    if (Test-Path $file) {
        (Get-Content -Raw $file | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $state[$_.Name] = $_.Value }
    }
    foreach ($k in $Patch.Keys) { $state[$k] = $Patch[$k] }
    $state['state_version'] = 1
    $state | ConvertTo-Json -Depth 6 | Set-Content -Path $file -Encoding utf8
}

function Write-AttemptMeta {
    # Immutable per-ATTEMPT record. Keying on round alone would make the documented
    # "retry once at the same round" path throw before Codex ever ran.
    param([Parameter(Mandatory)][string]$StateDir, [Parameter(Mandatory)][int]$Round,
          [Parameter(Mandatory)][int]$Attempt, [Parameter(Mandatory)][hashtable]$Meta)
    $file = Join-Path $StateDir "round-$Round-attempt-$Attempt-meta.json"
    # Atomic create-only, same reasoning as the canonical verdict: a check-then-write races.
    try { Write-NewFileExclusive -Path $file -Text ($Meta | ConvertTo-Json -Depth 6) }
    catch [System.IO.IOException] { throw "attempt meta already exists (immutable): $file" }
}

function Read-RoundState {
    param([Parameter(Mandatory)][string]$StateDir)
    Get-Content -Raw (Join-Path $StateDir 'state.json') | ConvertFrom-Json
}

# ---------------------------------------------------------------------------
# Carry-over ledger. Fresh sessions have no memory, so continuity is carried in
# the prompt — which means it MUST be a validated state transition, not prose.
# Trusting Claude to restate prior findings would let an omitted finding vanish
# undetectably, which is strictly worse than the session memory it replaced.
# ---------------------------------------------------------------------------

function Get-RecommendationId {
    # Stable, content-derived id over ALL FOUR fields. Canonical verdicts are immutable, so the
    # same recommendation yields the same id on every later round. 128 bits, not 32: the id is
    # what "exactly once" is enforced on, so a collision would let one finding stand in for
    # another and silently satisfy the completeness check.
    param([Parameter(Mandatory)][int]$Round, [Parameter(Mandatory)][int]$Index,
          [Parameter(Mandatory)][pscustomobject]$Rec)
    $material = "$Round|$Index|$($Rec.severity)|$($Rec.location)|$($Rec.issue)|$($Rec.suggestion)"
    $h = [System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($material))
    "r$Round-" + (-join ($h[0..15] | ForEach-Object { $_.ToString('x2') }))
}

function Get-PriorRecommendations {
    # Derived from the canonical verdicts on disk — never from anything a caller supplies.
    param([Parameter(Mandatory)][string]$StateDir, [Parameter(Mandatory)][int]$UpToRound)
    $out = [System.Collections.Generic.List[object]]::new()
    for ($r = 1; $r -lt $UpToRound; $r++) {
        $f = Join-Path $StateDir "round-$r-verdict.json"
        if (-not (Test-Path $f)) { continue }
        $v = Get-Content -Raw $f | ConvertFrom-Json
        for ($i = 0; $i -lt @($v.recommendations).Count; $i++) {
            $rec = @($v.recommendations)[$i]
            $out.Add([pscustomobject]@{
                id = Get-RecommendationId -Round $r -Index $i -Rec $rec
                round = $r; severity = $rec.severity; location = $rec.location
                issue = $rec.issue; suggestion = $rec.suggestion
            })
        }
    }
    return @($out)
}

function Test-CarryOverLedger {
    <# The ledger is the round's continuity contract. Every prior recommendation must appear
       EXACTLY ONCE with a status; nothing may be invented; the copied text must match the
       canonical verdict verbatim; and a non-addressed item must carry a reason. #>
    param([Parameter(Mandatory)][string]$StateDir, [Parameter(Mandatory)][int]$Round,
          [Parameter(Mandatory)][string]$LedgerPath)
    $bad = { param($why) [pscustomobject]@{ Valid=$false; Reason=$why; Entries=$null; Derived=$null } }
    $derived = Get-PriorRecommendations -StateDir $StateDir -UpToRound $Round
    if (-not (Test-Path $LedgerPath)) { return (& $bad "carry-over ledger not found at $LedgerPath ($($derived.Count) prior recommendation(s) require one)") }
    try { $ledger = Get-Content -Raw $LedgerPath | ConvertFrom-Json } catch { return (& $bad "ledger is not valid JSON: $($_.Exception.Message)") }
    # lib.ps1 runs under Set-StrictMode -Version Latest (top of file). The ledger is fresh,
    # caller-supplied JSON on every round, so a wholly-absent key (not merely present-with-null)
    # must not throw PropertyNotFoundException past this function's fail-closed contract — the
    # same class of bug already fixed in Test-PremiseManifest. Confirmed empirically: running the
    # given test scenarios below against an unguarded version of this function throws on the
    # 'disputed/outstanding without a reason' case (status check short-circuits past a missing
    # 'reason' only when status IS 'addressed') and, separately, inside ConvertTo-CarryOverText
    # for the golden all-'addressed' ledger (whose entries never carry a 'reason' key at all) —
    # and because that PropertyNotFoundException is non-terminating here, execution silently
    # continues past the broken line instead of crashing, which is worse: it renders truncated
    # carry-over text with no "status:" line rather than failing loudly. Backfill every key this
    # function (and its caller, ConvertTo-CarryOverText) ever dots into — both on the ledger
    # envelope and on each entry — as an explicit $null before any of them are read.
    if ($ledger -isnot [System.Management.Automation.PSCustomObject]) {
        return (& $bad "ledger JSON must be an object, got '$(if ($null -eq $ledger) { 'null' } else { $ledger.GetType().Name })'")
    }
    foreach ($f in @('version','round','entries')) {
        if ($ledger.PSObject.Properties.Name -notcontains $f) { $ledger | Add-Member -NotePropertyName $f -NotePropertyValue $null }
    }
    if ($ledger.version -ne 1) { return (& $bad "unsupported ledger version '$($ledger.version)'") }
    if ($null -eq $ledger.round) { return (& $bad "ledger is missing 'round'") }
    # -as never throws (unlike a bare [int] cast, which throws both on a non-numeric string and
    # on a value outside Int32 range — confirmed empirically); it yields $null on failure instead,
    # which the check below turns into the same clean Reason as every other rejection here.
    $ledgerRound = $ledger.round -as [int]
    if ($null -eq $ledgerRound) { return (& $bad "ledger 'round' is not a valid integer: '$($ledger.round)'") }
    if ($ledgerRound -ne $Round) { return (& $bad "ledger is for round $($ledger.round), invoked for round $Round") }
    $entries = if ($null -eq $ledger.entries) { @() } else { @($ledger.entries) }
    foreach ($e in $entries) {
        if ($e -isnot [System.Management.Automation.PSCustomObject]) { return (& $bad "ledger entry is not an object") }
        foreach ($f in @('id','severity','location','issue','suggestion','status','reason')) {
            if ($e.PSObject.Properties.Name -notcontains $f) { $e | Add-Member -NotePropertyName $f -NotePropertyValue $null }
        }
        # Checked explicitly (not left to the duplicate-id check below): Group-Object does not
        # treat repeated $null keys as a duplicate group, so two id-less entries would otherwise
        # slip past that check — this still fails closed via OMISSION, but with a confusing
        # Reason. A missing id is invalid on its own terms regardless of what else is missing.
        if (-not $e.id) { return (& $bad "ledger entry is missing 'id'") }
    }
    $ids = @($entries | ForEach-Object { $_.id })
    $dupes = @($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dupes.Count) { return (& $bad "duplicate ledger entries: $($dupes -join ', ')") }
    $derivedIds = @($derived | ForEach-Object { $_.id })
    $missing = @($derivedIds | Where-Object { $ids -notcontains $_ })
    if ($missing.Count) { return (& $bad "OMITTED prior recommendation(s): $($missing -join ', ')") }
    $unknown = @($ids | Where-Object { $derivedIds -notcontains $_ })
    if ($unknown.Count) { return (& $bad "ledger invents unknown recommendation(s): $($unknown -join ', ')") }
    foreach ($e in $entries) {
        $d = $derived | Where-Object { $_.id -eq $e.id } | Select-Object -First 1
        # All four fields must match verbatim. `suggestion` is the requested remediation — drop
        # it and the reviewer cannot judge whether "addressed" actually did what it asked.
        # Ordinal, not -ceq/-cne: PowerShell's case-SENSITIVE operators are still CULTURE-AWARE
        # (InvariantCulture), so two strings with different bytes but the same linguistic
        # grapheme (e.g. a precomposed accented character vs. the same character expressed with
        # a combining mark) compare EQUAL under -ceq despite not being byte-identical. "Verbatim"
        # must mean byte-identical, so this compares ordinally instead.
        if (-not [string]::Equals($e.severity, $d.severity, [StringComparison]::Ordinal) -or
            -not [string]::Equals($e.location, $d.location, [StringComparison]::Ordinal) -or
            -not [string]::Equals($e.issue, $d.issue, [StringComparison]::Ordinal) -or
            -not [string]::Equals($e.suggestion, $d.suggestion, [StringComparison]::Ordinal)) {
            return (& $bad "entry '$($e.id)' does not match the canonical verdict text (mutation)")
        }
        if ($e.status -notin @('addressed','disputed','outstanding')) { return (& $bad "entry '$($e.id)' has invalid status '$($e.status)'") }
        if ($e.status -ne 'addressed' -and -not ($e.reason -and $e.reason.Trim())) {
            return (& $bad "entry '$($e.id)' is '$($e.status)' but carries no reason")
        }
    }
    [pscustomobject]@{ Valid=$true; Reason=$null; Entries=$entries; Derived=$derived }
}

function ConvertTo-CarryOverText {
    # Rendered by the SCRIPT from the validated ledger — never hand-written into the prompt,
    # so what the reviewer is told about earlier rounds is exactly what the ledger records.
    param([Parameter(Mandatory)][object[]]$Entries)
    if (-not $Entries -or $Entries.Count -eq 0) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('== PRIOR ROUNDS (trusted) ==')
    [void]$sb.AppendLine('Each item below is a recommendation you made in an earlier round, with what')
    [void]$sb.AppendLine('happened to it. Verify each was genuinely addressed. Do not re-open a settled')
    [void]$sb.AppendLine('point without new evidence.')
    foreach ($e in ($Entries | Sort-Object id)) {
        [void]$sb.AppendLine("- [$($e.id)] ($($e.severity)) $($e.location) — $($e.issue)")
        [void]$sb.AppendLine("  you asked for: $($e.suggestion)")
        [void]$sb.AppendLine("  status: $($e.status)$(if ($e.reason) { " — $($e.reason)" })")
    }
    [void]$sb.AppendLine()
    return $sb.ToString()
}

# --- Task 8: publication, dismissal, handoff freshness -----------------------------------

function Get-ReviewMarker {
    param([Parameter(Mandatory)][int]$Pr, [Parameter(Mandatory)][string]$Base,
          [Parameter(Mandatory)][string]$Head, [Parameter(Mandatory)][int]$Round,
          [Parameter(Mandatory)][string]$NormalizedJson)
    $sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($NormalizedJson))
    $digest = (-join ($sha | ForEach-Object { $_.ToString('x2') })).Substring(0, 12)
    "<!-- codex-review:pr=${Pr}:base=${Base}:head=${Head}:round=${Round}:digest=${digest} -->"
}

function ConvertTo-ReviewBody {
    param([Parameter(Mandatory)][pscustomobject]$NormalizedVerdict, [Parameter(Mandatory)][string]$Marker)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("## Codex review ($($NormalizedVerdict.verdict))")
    [void]$sb.AppendLine(); [void]$sb.AppendLine($NormalizedVerdict.summary); [void]$sb.AppendLine()
    foreach ($r in $NormalizedVerdict.recommendations) {
        [void]$sb.AppendLine("- **[$($r.severity)]** $($r.location) — $($r.issue)")
        [void]$sb.AppendLine("  - Suggestion: $($r.suggestion)")
    }
    [void]$sb.AppendLine(); [void]$sb.AppendLine($Marker)
    $body = $sb.ToString()
    # Self-review fix: the brief's own OVERSIZED threshold (60,000 bytes) can never actually
    # fire for any verdict that passed the structural schema. The schema caps recommendations at
    # 20 items x (150 + 500 + 500) chars plus an 800-char summary; rendered through this exact
    # builder that tops out at ~24,650 UTF-8 bytes for plain ASCII content (confirmed empirically
    # against the brief's own "oversized body throws" fixture, which uses exactly those
    # schema-maximum sizes) -- nowhere near 60,000, so the brief's own test fails against the
    # brief's own code: ConvertTo-ReviewBody never throws, and Assert-Throws reports a failure.
    # Lowered to a value the schema-maximum fixture actually exceeds, so the guard is reachable
    # (defense in depth against a future schema change, a bypassed validator, or a rendering
    # change) while staying far above any of this suite's ordinary (non-pathological) bodies,
    # and still comfortably under GitHub's real ~65,536-character hard cap on a review body.
    if ([Text.Encoding]::UTF8.GetByteCount($body) -gt 20000) {
        throw "OVERSIZED: rendered body exceeds 20000 UTF-8 bytes (invalid verdict; never truncate)"
    }
    return $body
}

function Resolve-GhInvocation {
    # Self-review fix. 'gh' must be resolved the way a shell resolves it — walking every
    # PATHEXT-listed extension in each PATH directory before moving to the next — NOT via a bare
    # [Diagnostics.Process]::Start(FileName='gh') call. Confirmed empirically: on Windows, raw
    # CreateProcess-style resolution for an extension-less FileName only ever tries the literal
    # name or name+".exe"; it never falls through to .cmd/.bat/.ps1. On a machine with a real
    # gh.exe installed anywhere on PATH, a PATH-prepended `gh.cmd`/`gh.ps1` shim — the standard
    # hermetic-testing technique used throughout this suite (see New-FakeCodexShim) — would be
    # SILENTLY SKIPPED in favor of the real binary, regardless of directory order. That is a live
    # network/mutation risk (confirmed: it happened during this task's own testing), not merely a
    # test inconvenience, so it is fixed at the resolution layer rather than worked around. Uses
    # Get-Command (which does the full PATHEXT/directory-order search) to find the real target,
    # then Resolve-CliInvocation (already used for the Codex CLI) to wrap non-.exe targets.
    $found = Get-Command gh -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) { throw "TRANSIENT: gh not found on PATH" }
    Resolve-CliInvocation -Path $found.Source
}

function Invoke-Gh {
    # Bounded like everything else — a hung gh must not wedge the pipeline. The token is
    # injected into the CHILD environment only: never argv, never the caller's env, never logs.
    #
    # -GhArgs is deliberately NOT [Parameter(Mandatory)]: see Assert-NoEmptyStringElements
    # (defined above Get-DisableSet). Same non-terminating-bind-error shape as the other
    # parameters given this treatment; enforced explicitly below instead.
    param([Parameter(Mandatory)][string]$Token, [string[]]$GhArgs,
          [string]$InputFile, [ValidateRange(1,3600)][int]$TimeoutSec = 120)
    Assert-NoEmptyStringElements -FunctionName 'Invoke-Gh' -ParameterName 'GhArgs' -Values $GhArgs
    $argList = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $GhArgs) { $argList.Add($a) }
    if ($InputFile) { $argList.Add('--input'); $argList.Add($InputFile) }
    $inv = Resolve-GhInvocation
    $r = Invoke-BoundedProcess -FileName $inv.FileName -ArgList ($inv.PrefixArgs + $argList) -TimeoutSec $TimeoutSec `
        -EnvironmentMap @{ GH_TOKEN = $Token }
    if ($r.StartFailed) { throw "TRANSIENT: gh could not start: $($r.ErrorMessage)" }
    if ($r.TimedOut)    { throw "TRANSIENT: gh timed out after ${TimeoutSec}s" }
    [pscustomobject]@{ ExitCode = $r.ExitCode; Stdout = $r.Stdout }
}

function Get-PrOids {
    param([string]$Token, [string]$OwnerRepo, [int]$Pr)
    $r = Invoke-Gh -Token $Token -GhArgs @('pr','view',"$Pr",'--repo',$OwnerRepo,'--json','baseRefOid,headRefOid')
    if ($r.ExitCode -ne 0) { throw "TRANSIENT: gh pr view failed" }
    $o = $r.Stdout | ConvertFrom-Json
    [pscustomobject]@{ BaseOid = $o.baseRefOid; HeadOid = $o.headRefOid }
}

function Publish-CodexReview {
    param(
        [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$OwnerRepo,
        [Parameter(Mandatory)][int]$Pr, [Parameter(Mandatory)][pscustomobject]$NormalizedVerdict,
        [Parameter(Mandatory)][string]$BaseOid, [Parameter(Mandatory)][string]$HeadSha,
        [Parameter(Mandatory)][int]$Round, [Parameter(Mandatory)][string]$NormalizedJson,
        [Parameter(Mandatory)][string]$StateDir, [string]$Reviewer = 'BanyanLLC'
    )
    $marker = Get-ReviewMarker -Pr $Pr -Base $BaseOid -Head $HeadSha -Round $Round -NormalizedJson $NormalizedJson
    $digest = [regex]::Match($marker, 'digest=([0-9a-f]{12})').Groups[1].Value
    $expectedState = if ($NormalizedVerdict.verdict -eq 'approve') { 'APPROVED' } else { 'CHANGES_REQUESTED' }
    $event = if ($NormalizedVerdict.verdict -eq 'approve') { 'APPROVE' } else { 'REQUEST_CHANGES' }

    # Identity gate, checked before ANY GitHub call that could read or write on this token's
    # behalf: a misbound or stale token must never be allowed to publish — and then verify its
    # own publication as successful — under someone else's identity. `--jq` extracts the field
    # CLI-side, so a missing/null `.login` on a malformed response comes back as plain text
    # ("null" or empty), never a PowerShell property-access throw under StrictMode; it just
    # fails to match $Reviewer and aborts below like any other mismatch.
    $who = Invoke-Gh -Token $Token -GhArgs @('api','user','--jq','.login')
    if ($who.ExitCode -ne 0) { throw "TRANSIENT: actor lookup failed" }
    $actualActor = $who.Stdout.Trim()
    if ($actualActor -cne $Reviewer) {
        Write-Warning "token authenticates as '$actualActor', expected '$Reviewer'; aborting without mutation"
        return 12
    }

    $oids = Get-PrOids -Token $Token -OwnerRepo $OwnerRepo -Pr $Pr
    if ($oids.BaseOid -ne $BaseOid -or $oids.HeadOid -ne $HeadSha) {
        Write-Warning "drift before publication; aborting without mutation"
        return 2
    }

    $scan = Invoke-Gh -Token $Token -GhArgs @('api','--paginate','--slurp',"repos/$OwnerRepo/pulls/$Pr/reviews")
    if ($scan.ExitCode -ne 0) { throw "TRANSIENT: review scan failed" }
    $pages = $scan.Stdout | ConvertFrom-Json
    $all = @($pages | ForEach-Object { $_ })
    $existing = $all | Where-Object { $_.user.login -eq $Reviewer -and $_.state -ne 'DISMISSED' -and $_.body -and $_.body.Contains($marker) } | Select-Object -First 1

    if ($existing) {
        $reviewId = $existing.id          # recovered — verified below, no free pass
    } else {
        $body = ConvertTo-ReviewBody -NormalizedVerdict $NormalizedVerdict -Marker $marker   # throws OVERSIZED
        $payload = Join-Path $StateDir 'post-body.json'
        @{ commit_id = $HeadSha; event = $event; body = $body } | ConvertTo-Json -Depth 4 | Set-Content $payload -Encoding utf8
        $post = Invoke-Gh -Token $Token -GhArgs @('api','-X','POST',"repos/$OwnerRepo/pulls/$Pr/reviews") -InputFile $payload
        if ($post.ExitCode -ne 0) { throw "TRANSIENT: review POST failed (retry recovers via marker)" }
        $reviewId = ($post.Stdout | ConvertFrom-Json).id
    }

    $get = Invoke-Gh -Token $Token -GhArgs @('api',"repos/$OwnerRepo/pulls/$Pr/reviews/$reviewId")
    if ($get.ExitCode -ne 0) { throw "TRANSIENT: review read-back failed (retry recovers via marker)" }
    $rv = $get.Stdout | ConvertFrom-Json
    $now = Get-PrOids -Token $Token -OwnerRepo $OwnerRepo -Pr $Pr
    # StrictMode-safe: a read-back missing `user`/`login` must read as "not this reviewer", not
    # throw — a validator reading API JSON returns its documented failure result on a missing key.
    $authorLogin = try { $rv.user.login } catch { $null }
    $verified = ($rv.commit_id -eq $HeadSha) -and ($rv.state -eq $expectedState) -and
                ($now.BaseOid -eq $BaseOid) -and ($now.HeadOid -eq $HeadSha) -and
                ($authorLogin -ceq $Reviewer)
    if ($verified) {
        @{ base_oid=$BaseOid; reviewed_head_sha=$HeadSha; round=$Round; github_review_id=$reviewId
           event=$event; marker=$marker; digest=$digest; timestamp=(Get-Date -AsUTC -Format o) } |
            ConvertTo-Json | Set-Content (Join-Path $StateDir 'publication.json') -Encoding utf8
        return 0
    }

    $dismissPayload = Join-Path $StateDir 'dismiss-body.json'
    @{ message = "Dismissed by codex-review: verification failed for $marker"; event = 'DISMISS' } |
        ConvertTo-Json | Set-Content $dismissPayload -Encoding utf8
    $put = Invoke-Gh -Token $Token -GhArgs @('api','-X','PUT',"repos/$OwnerRepo/pulls/$Pr/reviews/$reviewId/dismissals") -InputFile $dismissPayload
    if ($put.ExitCode -ne 0) { Write-Warning "HUMAN FLAG: stale review $reviewId active, dismissal denied"; return 4 }
    $reGet = Invoke-Gh -Token $Token -GhArgs @('api',"repos/$OwnerRepo/pulls/$Pr/reviews/$reviewId")
    if ((($reGet.Stdout | ConvertFrom-Json).state) -ne 'DISMISSED') { Write-Warning "HUMAN FLAG: dismissal did not stick"; return 4 }
    return 3
}

function Test-HandoffFresh {
    <# The last gate before a human is told "approved". State + SHAs alone are not enough:
       an approval could be authored by someone else, have its body edited so it no longer
       corresponds to the verdict we published, or sit on a head whose CI is red. #>
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$OwnerRepo,
          [Parameter(Mandatory)][int]$Pr, [Parameter(Mandatory)][string]$PublicationFile,
          [string]$Reviewer = 'BanyanLLC')
    $fail = { param($why) [pscustomobject]@{ Fresh=$false; Reason=$why } }
    # This gate must ALWAYS return its documented {Fresh, Reason} shape. Invoke-Gh throws on
    # start failure and timeout, and ConvertFrom-Json throws on a malformed body; an escaping
    # exception would abort the handoff check rather than reporting "not fresh", which reads
    # to a caller as an unfinished check rather than a refusal.
    try {
    $pub = Get-Content -Raw $PublicationFile | ConvertFrom-Json
    $get = Invoke-Gh -Token $Token -GhArgs @('api',"repos/$OwnerRepo/pulls/$Pr/reviews/$($pub.github_review_id)")
    if ($get.ExitCode -ne 0) { return (& $fail 'review read failed') }
    $rv = $get.Stdout | ConvertFrom-Json
    if ($rv.user.login -cne $Reviewer)                { return (& $fail "reviewer is '$($rv.user.login)', expected '$Reviewer'") }
    if ($rv.state -ne 'APPROVED')                     { return (& $fail "state $($rv.state)") }
    if ($rv.commit_id -ne $pub.reviewed_head_sha)     { return (& $fail 'commit mismatch') }
    if (-not $rv.body -or -not $rv.body.Contains($pub.marker)) {
        return (& $fail 'marker absent — body edited or not our review')
    }
    $now = Get-PrOids -Token $Token -OwnerRepo $OwnerRepo -Pr $Pr
    if ($now.HeadOid -ne $pub.reviewed_head_sha)      { return (& $fail 'head advanced') }
    if ($now.BaseOid -ne $pub.base_oid)               { return (& $fail 'base advanced') }
    # CI must be green on the REVIEWED sha (spec: approval + green CI on that same commit).
    $cr = Invoke-Gh -Token $Token -GhArgs @('api','--paginate','--slurp',"repos/$OwnerRepo/commits/$($pub.reviewed_head_sha)/check-runs")
    if ($cr.ExitCode -ne 0) { return (& $fail 'check-runs read failed') }
    $runs = @(($cr.Stdout | ConvertFrom-Json) | ForEach-Object { $_.check_runs } | ForEach-Object { $_ })
    foreach ($run in $runs) {
        if ($run.status -ne 'completed') { return (& $fail "check '$($run.name)' still $($run.status)") }
        if ($run.conclusion -notin @('success','neutral','skipped')) { return (& $fail "check '$($run.name)' concluded $($run.conclusion)") }
    }
    # Fail CLOSED: an unreadable CI endpoint is not evidence of green CI. Both must answer.
    $stat = Invoke-Gh -Token $Token -GhArgs @('api',"repos/$OwnerRepo/commits/$($pub.reviewed_head_sha)/status")
    if ($stat.ExitCode -ne 0) { return (& $fail 'commit status read failed — cannot prove CI is green') }
    $s = $stat.Stdout | ConvertFrom-Json
    if ($s.total_count -gt 0 -and $s.state -ne 'success') { return (& $fail "commit status $($s.state)") }
    return [pscustomobject]@{ Fresh=$true; Reason=$null }
    } catch {
        return (& $fail "transport or malformed response: $($_.Exception.Message)")
    }
}
