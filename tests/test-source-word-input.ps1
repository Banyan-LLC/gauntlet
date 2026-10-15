. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference = 'Stop'
$invoke = Join-Path $PSScriptRoot '../gauntlet-review/scripts/invoke-codex.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($invoke, [ref]$tokens, [ref]$errors)
Assert-Eq $errors.Count 0 'entry parses'
Assert-True ($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -contains 'CompactSourceWords') 'source words are explicit opt-in'
if ($script:Failures.Count) { Write-TestResult }

function Entry([string]$Prefix, [switch]$Metadata) {
    $entryTry = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
    if ($entryTry.Count -ne 1) { throw 'Expected one production entry try/finally boundary' }
    $matches = @($entryTry[0].Body.Statements | Where-Object {
        $_.Extent.Text.StartsWith($Prefix, [StringComparison]::Ordinal) -and
        (-not $Metadata -or $_.Extent.Text.Contains('$meta.'))
    })
    if ($matches.Count -ne 1) { throw "Missing unique production statement: $Prefix" }
    return $matches[0]
}


$root = Join-Path ([IO.Path]::GetTempPath()) ('source-word-input-' + [guid]::NewGuid().ToString('N'))
$script:SourceWordProcessPending = $false
[IO.Directory]::CreateDirectory((Join-Path $root 'src')) | Out-Null
try {
    function Fixture-Git([string[]]$GitArguments) {
        $value = & git -C $root @GitArguments
        if ($LASTEXITCODE) { throw 'Fixture Git failed' }
        return $value
    }
    Fixture-Git @('init', '-q')
    Fixture-Git @('-c', 'user.name=geoffroth', '-c', 'user.email=test@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'base')
    $base = (Fixture-Git @('rev-parse', 'HEAD')).Trim()
    $private = 'PRIVATE_SOURCE_WORD_INPUT'
    $common = 'sharedEvidenceIdentifier(' + ('longDiagnosticSnapshot ' * 24) + ') // ' + $private
    $bodies = @{}
    foreach ($name in @('a.kt', 'b.kt')) {
        $localWord = if ($name -ceq 'a.kt') { 'firstLocalIdentifier' } else { 'secondLocalIdentifier' }
        $rows = [Collections.Generic.List[string]]::new()
        $rows.Add("        $common")
        for ($i = 0; $i -lt 18; $i++) {
            $rows.Add("        emitDiagnosticEvidence($i, " + (($localWord + ' ') * 24) + ')')
        }
        $rows.Add("        $common")
        $bodies[$name] = (($rows.ToArray() + $rows.ToArray()) -join "`n") + "`n"
    }
    # Reserved line cores force F; word compression remains profitable.
    $bodies['literal.asm'] = '~0=literal(' + ('longLiteralEvidence ' * 32) + ")`n        ~0~`n" +
        (('        label ' + ('longLiteralEvidence ' * 32) + "`t; @near Ω  `n") * 12)
    # Original @digit markers force whole-file word fallback; @near stays literal.
    $bodies['marker.kt'] = ('        marker(' + ('longMarkerEvidence ' * 32) + ', "@0 @01 @65536 @near")' + "`n") * 4
    $bodies['plain.java'] = "class Plain {}`n"
    foreach ($item in $bodies.GetEnumerator()) {
        [IO.File]::WriteAllText((Join-Path $root "src/$($item.Key)"), $item.Value, [Text.UTF8Encoding]::new($false))
    }
    $historyDir = Join-Path $root 'docs/superpowers/reviews'
    [IO.Directory]::CreateDirectory($historyDir) | Out-Null
    $historyBody = ('"' + $private + ' historical evidence must remain complete"' + "`n") * 12
    [IO.File]::WriteAllText((Join-Path $historyDir 'fixture.jsonl'), $historyBody, [Text.UTF8Encoding]::new($false))
    Fixture-Git @('-c', 'core.autocrlf=false', 'add', 'src', 'docs')
    Fixture-Git @('-c', 'user.name=geoffroth', '-c', 'user.email=test@example.invalid', 'commit', '-q', '-m', 'head')
    $head = (Fixture-Git @('rev-parse', 'HEAD')).Trim()
    $preamble = Join-Path $root 'preamble.txt'
    [IO.File]::WriteAllText($preamble, 'Review complete input.', [Text.UTF8Encoding]::new($false))
    $missing = Join-Path $root 'deliberately-absent-cli.exe'
    Assert-True (-not (Test-Path -LiteralPath $missing)) 'no CLI executable or shim exists'
    $priorFlags = @('-CompactAddedFiles', '-CompactIndentation', '-CompactRepeatedLines', '-CompactReviewMetadata', '-CompactSourceFrames')
    $allFlags = $priorFlags + '-CompactSourceWords'
    function Run(
        [string]$Name,
        [string[]]$Flags,
        [string]$Mode = 'local',
        [long]$Budget = 1048576,
        [int]$Round = 1,
        [switch]$OmitProvenance
    ) {
        $state = Join-Path $root $Name
        $arguments = @(
            '-NoProfile', '-File', $invoke, '-Mode', $Mode, '-PromptFile', $preamble,
            '-StateDir', $state, '-Round', $Round.ToString([Globalization.CultureInfo]::InvariantCulture),
            '-RepoRoot', $root, '-BudgetBytes', $Budget.ToString([Globalization.CultureInfo]::InvariantCulture),
            '-CliPathOverride', $missing
        )
        if (-not $OmitProvenance) {
            if ($Mode -eq 'doc') { $arguments += @('-ArtifactPath', 'fixture.md', '-ArtifactCommit', $head) }
            else { $arguments += @('-BaseOid', $base, '-HeadSha', $head) }
        }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $script:SourceWordProcessPending = $true
        try {
            $run = Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList ($arguments + $Flags) -TimeoutSec 60 -RequireProcessTreeRetirement
        } catch {
            $timer.Stop()
            Write-Host "Run metadata: name=$Name; elapsed_ms=$($timer.ElapsedMilliseconds); exception_type=$($_.Exception.GetType().FullName); retirement=unknown"
            Assert-True $false "$Name bounded process call failed; fixture retained without confirmed retirement"
            Write-TestResult
        }
        $timer.Stop()
        if ($run.ProcessTreeRetired) { $script:SourceWordProcessPending = $false }
        $outputBytes = [Text.Encoding]::UTF8.GetByteCount([string]$run.Stdout)
        $errorBytes = [Text.Encoding]::UTF8.GetByteCount([string]$run.Stderr)
        $hasError = -not [string]::IsNullOrEmpty($run.ErrorMessage)
        Write-Host "Run metadata: name=$Name; elapsed_ms=$($timer.ElapsedMilliseconds); exit_code=$($run.ExitCode); timed_out=$($run.TimedOut); start_failed=$($run.StartFailed); tree_retired=$($run.ProcessTreeRetired); stdout_bytes=$outputBytes; stderr_bytes=$errorBytes; error_present=$hasError"
        $settled = -not $run.StartFailed -and -not $run.TimedOut -and $run.ProcessTreeRetired
        Assert-True $settled "$Name bounded offline completion"
        if (-not $settled) { Write-TestResult }
        $files = @(Get-ChildItem -LiteralPath $state -Recurse -File -ErrorAction SilentlyContinue)
        Assert-Eq @($files | Where-Object Name -match 'attempt|meta|cli-pin|carryover').Count 0 "$Name no attempt, pin, metadata or rendered ledger allocated"
        $diagnostic = $run.Stdout + $run.Stderr
        $stateFile = Join-Path $state 'state.json'
        if (Test-Path -LiteralPath $stateFile) {
            $stateText = Get-Content -Raw $stateFile
            $diagnostic += $stateText
            $saved = $stateText | ConvertFrom-Json
            Assert-True (-not [bool]$saved.PSObject.Properties['harness_dir']) "$Name no harness allocated"
        }
        Assert-True (-not $diagnostic.Contains($private)) "$Name no source/history in diagnostics or refusal state"
        Assert-True (-not (Test-Path -LiteralPath $missing)) "$Name absent CLI remains absent"
        return [pscustomobject]@{ Run = $run; State = $state; Diagnostic = $diagnostic }
    }


    $encoded = Run -Name encoded -Flags $allFlags
    Assert-Eq $encoded.Run.ExitCode 12 'full word composition reaches deliberately absent CLI'
    $stateFile = Join-Path $encoded.State 'state.json'
    Assert-True (Test-Path -LiteralPath $stateFile) 'refusal state exists before reading'
    if ($script:Failures.Count) { Write-TestResult }
    $reason = (Get-Content -Raw $stateFile | ConvertFrom-Json).failure_reason
    Assert-True ($reason -match '^CLI probe:') 'word functionality completes before absent CLI probe'
    if ($script:Failures.Count) { Write-TestResult }
    $missingDependencies = @(
        @{ Name = 'missing-added'; Flags = @('-CompactIndentation', '-CompactSourceFrames', '-CompactSourceWords') },
        @{ Name = 'missing-indent'; Flags = @('-CompactAddedFiles', '-CompactSourceFrames', '-CompactSourceWords') },
        @{ Name = 'missing-frames'; Flags = @('-CompactAddedFiles', '-CompactIndentation', '-CompactSourceWords') }
    )
    foreach ($case in $missingDependencies) {
        $refused = Run -Name $case.Name -Flags $case.Flags
        Assert-Eq $refused.Run.ExitCode 12 "$($case.Name) dependency refused before attempt"
        Assert-True ($refused.Diagnostic -match '(?i)(source.word|source.frame|indentation|verified compact)') "$($case.Name) dependency diagnostic"
        Assert-True (-not ($refused.Diagnostic -match 'CLI probe:')) "$($case.Name) does not reach CLI probing"
    }
    $doc = Run -Name doc -Flags $allFlags -Mode doc
    Assert-Eq $doc.Run.ExitCode 12 'source words rejected in doc mode before attempt'
    Assert-True ($doc.Diagnostic -match 'Compact representation requires local or PR mode') 'original doc-mode guard remains effective'
    foreach ($mode in @('local', 'pr')) {
        $refused = Run -Name "missing-provenance-$mode" -Flags $allFlags -Mode $mode -OmitProvenance
        Assert-Eq $refused.Run.ExitCode 12 "$mode provenance remains required"
        Assert-True ($refused.Diagnostic -match "$mode mode requires") "$mode original provenance guard"
    }

    # Source words cannot bypass the canonical prior-recommendation ledger gate.
    $ledgerState = Join-Path $root 'missing-ledger'
    [IO.Directory]::CreateDirectory($ledgerState) | Out-Null
    $priorVerdict = Join-Path $ledgerState 'round-1-verdict.json'
    $prior = @{
        verdict = 'request_changes'; summary = 'retain prior findings'
        recommendations = @(@{ severity = 'important'; location = 'src/a.kt:1'; issue = 'retain complete issue'; suggestion = 'retain complete suggestion' })
    }
    [IO.File]::WriteAllText($priorVerdict, ($prior | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $priorHash = (Get-FileHash -LiteralPath $priorVerdict).Hash
    $ledger = Run -Name missing-ledger -Flags $allFlags -Round 2
    Assert-Eq $ledger.Run.ExitCode 16 'words do not bypass required carry-over ledger'
    Assert-Eq (Get-FileHash -LiteralPath $priorVerdict).Hash $priorHash 'canonical prior verdict remains byte-identical'

    foreach ($name in @('Get-CompactReviewGitRange', 'Get-ReviewGitQuotedPath')) {
        $definitions = @($ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq $name }.GetNewClosure(), $true))
        if ($definitions.Count -ne 1) { throw "Missing unique production function: $name" }
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    $composition = Entry 'if ($Mode -eq ''local'' -or $CompactAddedFiles)'
    $wordMeta = Entry 'if($CompactSourceWords)'
    $writeMeta = Entry 'Write-AttemptMeta -StateDir'
    Assert-True ($wordMeta.Extent.EndOffset -lt $writeMeta.Extent.StartOffset) 'word protocol hash attaches before immutable metadata write'
    $payloads = @{}
    foreach ($mode in @('local', 'pr')) {
        # Only independent Git range acquisition and production composition run here.
        # PR text/provenance are supplied offline; no GH adapter or live API runs.
        $range = Get-CompactReviewGitRange -RepoRoot $root -BaseOid $base -HeadSha $head -Mode $mode
        & {
            $Mode = $mode; $RepoRoot = $root; $canonBase = $base; $canonHead = $head
            $localDiff = $range.Diff; $localDiffSha = $range.OriginalSha256; $compactRange = $range
            $promptBody = 'Review complete input.'; $VerifiedReferenceFile = $null
            $CompactAddedFiles = $true; $CompactIndentation = $true; $CompactRepeatedLines = $true
            $CompactReviewMetadata = $true; $CompactSourceFrames = $true; $CompactSourceWords = $true
            $referenceCoverage = $null; $compactCoverage = $null; $metadataCoverage = $null
            $provenance = [pscustomobject]@{
                head_sha = $head; base_oid = $base; base_tip_oid = $base
                metadata_sha256 = Get-ReviewTextHash "offline verified PR/CI context`n"
                check_response = '{"head_sha":"' + $head + '","check_runs":[{"name":"required","conclusion":"success"}]}'
                status_response = '{"sha":"' + $head + '","state":"success"}'
            }
            $prInput = if ($mode -eq 'pr') { [pscustomobject]@{ Text = "offline verified PR/CI context`n"; Provenance = $provenance } } else { $null }
            $carryText = "Verbatim canonical prior recommendation`nstatus: addressed`n"
            $originalCarry = $carryText
            . ([scriptblock]::Create($composition.Extent.Text))
            $fullPrompt = $carryText + $promptBody
            $characters = Test-PromptCharacterLimit -PromptText $fullPrompt
            Assert-True $characters.Ok "$mode complete ledger plus composition fits scalar cap"
            Assert-True ((Test-EmbedBudget -PromptText $fullPrompt -BudgetBytes 1048576).Ok) "$mode complete ledger plus composition fits byte cap"
            Assert-Eq $carryText $originalCarry "$mode source framing leaves ledger text unchanged"
            $previousProtocolEnd = -1
            foreach ($protocol in @((Get-CompactReviewProtocol), (Get-CompactIndentationProtocol), (Get-CompactSourceLineProtocol), (Get-CompactSourceFrameProtocol), (Get-CompactSourceWordProtocol), (Get-ReviewMetadataProtocol))) {
                Assert-True ($promptBody.Contains($protocol)) "$mode complete production protocol included"
                $position = $promptBody.IndexOf($protocol, [StringComparison]::Ordinal)
                Assert-True ($position -gt $previousProtocolEnd) "$mode protocols follow added/indent/line/frame/word/metadata ordering"
                $previousProtocolEnd = $position + $protocol.Length - 1
            }

            Assert-Eq @($compactCoverage.sections).Count 6 "$mode complete ordered section coverage"
            Assert-Eq $compactCoverage.source_word_version 1 "$mode actual WORDS use adds version"
            Assert-Eq @($metadataCoverage.sections | Where-Object metadata).Count 1 "$mode full historical metadata retained"
            $wordDiff = Restore-ReviewMetadataDiff -Diff $reviewDiff -Manifest $metadataCoverage
            Assert-True ($wordDiff -match '(?m)^\["WORDS",') "$mode actual WORDS envelopes emitted"
            Assert-Eq (Restore-CompactReviewDiff -Diff $wordDiff -Manifest $compactCoverage) $range.Diff "$mode exact complete original Git diff restored"
            Assert-Eq $compactCoverage.original_sha256 (Get-ReviewTextHash $range.Diff) "$mode original full-range digest preserved"
            $legacy = ConvertTo-CompactReviewDiff -RepoRoot $root -BaseOid $base -HeadSha $head -Diff $range.Diff -CompactIndentation -CompactRepeatedLines -CompactSourceFrames
            $disabled = ConvertTo-CompactReviewDiff -RepoRoot $root -BaseOid $base -HeadSha $head -Diff $range.Diff -CompactIndentation -CompactRepeatedLines -CompactSourceFrames -CompactSourceWords:$false
            Assert-Eq $disabled.Diff $legacy.Diff "$mode default-off prior rendering byte-identical"
            Assert-Eq ($disabled.Manifest | ConvertTo-Json -Depth 40 -Compress) ($legacy.Manifest | ConvertTo-Json -Depth 40 -Compress) "$mode default-off manifest byte-identical"
            Assert-True (-not [bool]$disabled.Manifest.PSObject.Properties['source_word_version']) "$mode default-off adds no word version"
            & {
                $CompactSourceWords = $false
                $promptBody = 'Review complete input.'
                . ([scriptblock]::Create($composition.Extent.Text))
                Assert-True (-not $promptBody.Contains((Get-CompactSourceWordProtocol))) "$mode disabled words add no prompt protocol"
                Assert-Eq ($compactCoverage | ConvertTo-Json -Depth 40 -Compress) ($legacy.Manifest | ConvertTo-Json -Depth 40 -Compress) "$mode production default-off composition keeps prior manifest"
                $previousFrames = Restore-ReviewMetadataDiff -Diff $reviewDiff -Manifest $metadataCoverage
                Assert-Eq $previousFrames $legacy.Diff "$mode production default-off composition keeps prior frame bytes"
            }
            $withoutLines = ConvertTo-CompactReviewDiff -RepoRoot $root -BaseOid $base -HeadSha $head -Diff $range.Diff -CompactIndentation -CompactSourceFrames -CompactSourceWords
            Assert-Eq $withoutLines.Manifest.source_word_version 1 "$mode words work without the independent source-line option"
            Assert-True (-not [bool]$withoutLines.Manifest.PSObject.Properties['source_line_version']) "$mode words do not implicitly enable source lines"
            Assert-Eq (Restore-CompactReviewDiff -Diff $withoutLines.Diff -Manifest $withoutLines.Manifest) $range.Diff "$mode F-only words restore the exact complete range"
            Assert-True ($wordDiff.Length -lt $legacy.Diff.Length) "$mode actual previous rendering shortened in UTF16"
            Assert-True ([Text.Encoding]::UTF8.GetByteCount($wordDiff) -lt [Text.Encoding]::UTF8.GetByteCount($legacy.Diff)) "$mode actual previous rendering shortened in UTF8"
            $wrapped = @($compactCoverage.sections | Where-Object { $_.PSObject.Properties['word_legacy'] })
            Assert-Eq $wrapped.Count 3 "$mode both FL files and reserved-core F file wrapped"
            $headers = @([regex]::Matches($wordDiff, '(?m)^\["WORDS",[^\r\n]+') | ForEach-Object { ConvertFrom-Json -InputObject $_.Value -NoEnumerate })
            Assert-Eq $headers.Count $wrapped.Count "$mode one closed header per wrapped section"
            $tables = @{}
            foreach ($header in $headers) {
                Assert-Eq $header.Count 3 "$mode canonical three-field WORDS header"
                $inner = ConvertFrom-Json -InputObject $header[2] -NoEnumerate
                $tables[$inner[1]] = $header[1]
                Assert-True ($inner[0] -cin @('F', 'FL')) "$mode only prior F/FL header wrapped"
                Assert-True ($legacy.Diff.Contains([string]$header[2] + "`n")) "$mode exact previous header retained verbatim"
            }
            Assert-True (($tables['src/a.kt'] -join ',') -cne ($tables['src/b.kt'] -join ',')) "$mode local dictionaries differ around shared global line references"
            for ($i = 0; $i -lt $legacy.Manifest.sections.Count; $i++) {
                $old = $legacy.Manifest.sections[$i]; $outer = $compactCoverage.sections[$i]
                foreach ($field in @('header', 'path', 'mode', 'index', 'blob', 'count', 'compact', 'original_sha256', 'original_length')) {
                    Assert-Eq $outer.$field $old.$field "$mode original identity $field preserved for $($old.path)"
                }
                if ($outer.PSObject.Properties['word_legacy']) {
                    Assert-Eq ($outer.word_legacy | ConvertTo-Json -Depth 30 -Compress) ($old | ConvertTo-Json -Depth 30 -Compress) "$mode previous section retained exactly"
                    Assert-Eq ($outer.word_dictionary | ConvertTo-Json -Compress) ($tables[$outer.path] | ConvertTo-Json -Compress) "$mode manifest dictionary equals wire table"
                    Assert-True ($outer.rendered_length -lt $old.rendered_length) "$mode every wrapped section strictly shortens"
                } else {
                    Assert-Eq ($outer | ConvertTo-Json -Depth 30 -Compress) ($old | ConvertTo-Json -Depth 30 -Compress) "$mode ineligible section manifest byte-identical"
                }
            }
            foreach ($name in @('src/marker.kt', 'src/plain.java', 'docs/superpowers/reviews/fixture.jsonl')) {
                $section = @($compactCoverage.sections | Where-Object path -CEQ $name)[0]
                Assert-True (-not [bool]$section.PSObject.Properties['word_legacy']) "$mode $name remains unwrapped"
            }
            foreach ($field in @('source_line_version', 'source_line_dictionary_count', 'source_line_dictionary_utf16')) {
                Assert-Eq $compactCoverage.$field $legacy.Manifest.$field "$mode legacy line state $field unchanged"
            }
            & {
                $CompactSourceWords = $false; $meta = @{}
                . ([scriptblock]::Create($wordMeta.Extent.Text))
                Assert-True (-not $meta.ContainsKey('compact_source_word_protocol_sha256')) "$mode disabled word hash absent"
            }
            $meta = @{}
            . ([scriptblock]::Create((Entry 'if ($CompactAddedFiles)' -Metadata).Extent.Text))
            foreach ($prefix in @('if($CompactReviewMetadata)', 'if($CompactIndentation)', 'if($CompactRepeatedLines)', 'if($CompactSourceFrames)', 'if($CompactSourceWords)')) {
                . ([scriptblock]::Create((Entry $prefix).Extent.Text))
            }
            Assert-Eq $meta.compact_source_word_protocol_sha256 (Get-ReviewTextHash (Get-CompactSourceWordProtocol)) "$mode exact immutable word protocol hash"
            Assert-Eq $meta.compact_source_frame_protocol_sha256 (Get-ReviewTextHash (Get-CompactSourceFrameProtocol)) "$mode prior frame protocol hash unchanged"
            Assert-Eq $meta.compact_source_line_protocol_sha256 (Get-ReviewTextHash (Get-CompactSourceLineProtocol)) "$mode prior line protocol hash unchanged"
            Assert-Eq $meta.compact_indentation_protocol_sha256 (Get-ReviewTextHash (Get-CompactIndentationProtocol)) "$mode prior indentation protocol hash unchanged"
            if ($mode -eq 'pr') {
                Assert-Eq ($meta.pr_input_provenance | ConvertTo-Json -Depth 8 -Compress) ($provenance | ConvertTo-Json -Depth 8 -Compress) 'exact PR/CI provenance remains complete'
            }
            $StateDir = Join-Path $root "isolated-meta-$mode"; $Round = 1; $attempt = 1
            [IO.Directory]::CreateDirectory($StateDir) | Out-Null
            . ([scriptblock]::Create($writeMeta.Extent.Text))
            $metaFile = Join-Path $StateDir 'round-1-attempt-1-meta.json'
            $saved = Get-Content -Raw $metaFile | ConvertFrom-Json
            Assert-Eq $saved.compact_source_word_protocol_sha256 (Get-ReviewTextHash (Get-CompactSourceWordProtocol)) "$mode immutable writer persists word hash"
            $before = (Get-FileHash -LiteralPath $metaFile).Hash
            Assert-Throws { . ([scriptblock]::Create($writeMeta.Extent.Text)) } "$mode immutable metadata cannot be overwritten"
            Assert-Eq (Get-FileHash -LiteralPath $metaFile).Hash $before "$mode immutable metadata bytes fixed"
            $payloads[$mode] = [pscustomobject]@{ Prompt = $promptBody; Diff = $reviewDiff }
        }
    }
    Assert-Eq $payloads.local.Diff $payloads.pr.Diff 'local and offline PR representation identical'
    Assert-Eq $payloads.pr.Prompt ($payloads.local.Prompt.Replace("== REVIEW MATERIAL (untrusted) ==`n", "== REVIEW MATERIAL (untrusted) ==`noffline verified PR/CI context`n")) 'only verified PR/CI context differs'
    # A complete unique source remains genuinely oversized even with all encoders.
    # Raising the caller's byte budget cannot change the fixed upstream limits.
    $unique = ('z' * 1048000) + "`nend`n"
    [IO.File]::WriteAllText((Join-Path $root 'src/unique.kt'), $unique, [Text.UTF8Encoding]::new($false))
    Fixture-Git @('-c', 'core.autocrlf=false', 'add', 'src/unique.kt')
    Fixture-Git @('-c', 'user.name=geoffroth', '-c', 'user.email=test@example.invalid', 'commit', '-q', '-m', 'unique over-cap source')
    $head = (Fixture-Git @('rev-parse', 'HEAD')).Trim()
    $raised = Run -Name raised -Flags $allFlags -Budget 1048577
    Assert-Eq $raised.Run.ExitCode 10 'actual over-cap six-flag composition remains refused with raised budget'
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^source-word-input-[0-9a-f]{32}$') {
        throw 'Unsafe fixture cleanup target'
    }
    if ($script:SourceWordProcessPending) {
        Write-Host "Retained source-word fixture: root=$resolved; process-tree retirement is unconfirmed."
    } else {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-TestResult
