. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1"
$ErrorActionPreference = 'Stop'
$invoke = Join-Path $PSScriptRoot '../gauntlet-review/scripts/invoke-codex.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($invoke, [ref]$tokens, [ref]$errors)
Assert-Eq $errors.Count 0 'entry parses'
Assert-True ($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -contains 'CompactSourceFrames') 'source frames are explicit opt-in'
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

$root = Join-Path ([IO.Path]::GetTempPath()) ('source-frame-input-' + [guid]::NewGuid().ToString('N'))
$script:SourceFrameProcessPending = $false
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
    $private = 'PRIVATE_SOURCE_FRAME_INPUT'
    $coreA = 'value(' + $private + ('x' * 384) + ')'
    $coreB = 'other(' + $private + ('y' * 384) + ')'
    $cycles = 150
    $body = ("$coreA`n        $coreB`n        $coreA`n$coreB`n") * $cycles
    Assert-True ($body.Length -lt 1048576) 'each complete repeated source body is below the decoded cap'
    foreach ($name in @('a.kt', 'b.kt')) {
        [IO.File]::WriteAllText((Join-Path $root "src/$name"), $body, [Text.UTF8Encoding]::new($false))
    }
    # The unchanged source-line pass refuses these reserved cores at either indent.
    # Its INDENT output may subsequently become F, never FL; tilde is not indentation.
    $literalBody = '~0=SOURCE_FRAME_LITERAL_' + ('r' * 64) + "`n~0~`n        ~0=SOURCE_FRAME_LITERAL_" + ('s' * 64) + "`n        ~0~`n"
    [IO.File]::WriteAllText((Join-Path $root 'src/literal.asm'), $literalBody, [Text.UTF8Encoding]::new($false))
    # Neither ADDED nor LINES is a valid input to the outer F/FL adapter.
    [IO.File]::WriteAllText((Join-Path $root 'src/plain.java'), "class FramePlain {}`n", [Text.UTF8Encoding]::new($false))
    $plainLinesBody = ('plainSource(' + $private + ('p' * 80) + ")`n") * 40
    [IO.File]::WriteAllText((Join-Path $root 'src/plain-lines.java'), $plainLinesBody, [Text.UTF8Encoding]::new($false))
    $historyDir = Join-Path $root 'docs/superpowers/reviews'
    [IO.Directory]::CreateDirectory($historyDir) | Out-Null
    $historyBody = ('"' + $private + ('h' * 384) + '"' + "`n") * 1400
    # Even ignoring every other file, diff header, protocol and added-line marker,
    # these bodies still exceed the cap after the legacy indentation savings.
    # Each cycle replaces two eight-space prefixes by two TABs apiece: 12 bytes saved.
    $plainBodyLowerBound = 2L * [Text.Encoding]::UTF8.GetByteCount($body) - 2L * $cycles * 12L + [Text.Encoding]::UTF8.GetByteCount($historyBody)
    Assert-True ($plainBodyLowerBound -gt 1048576) 'smaller plain fixture remains genuinely over the fixed byte cap'
    if ($script:Failures.Count) { Write-TestResult }
    [IO.File]::WriteAllText((Join-Path $historyDir 'fixture.jsonl'), $historyBody, [Text.UTF8Encoding]::new($false))
    Fixture-Git @('-c', 'core.autocrlf=false', 'add', 'src', 'docs')
    Fixture-Git @('-c', 'user.name=geoffroth', '-c', 'user.email=test@example.invalid', 'commit', '-q', '-m', 'head')
    $head = (Fixture-Git @('rev-parse', 'HEAD')).Trim()
    $preamble = Join-Path $root 'preamble.txt'
    [IO.File]::WriteAllText($preamble, 'Review complete input.', [Text.UTF8Encoding]::new($false))
    $missing = Join-Path $root 'deliberately-absent-cli.exe'
    Assert-True (-not (Test-Path -LiteralPath $missing)) 'no CLI executable or shim exists'
    $allFlags = @('-CompactAddedFiles', '-CompactIndentation', '-CompactRepeatedLines', '-CompactReviewMetadata', '-CompactSourceFrames')

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
        $script:SourceFrameProcessPending = $true
        try {
            $run = Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList ($arguments + $Flags) -TimeoutSec 60 -RequireProcessTreeRetirement
        } catch {
            $timer.Stop()
            Write-Host "Run metadata: name=$Name; elapsed_ms=$($timer.ElapsedMilliseconds); exception_type=$($_.Exception.GetType().FullName); retirement=unknown"
            Assert-True $false "$Name bounded process call failed; fixture retained without confirmed retirement"
            Write-TestResult
        }
        $timer.Stop()
        if ($run.ProcessTreeRetired) { $script:SourceFrameProcessPending = $false }
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

    $plain = Run -Name plain -Flags @('-CompactAddedFiles', '-CompactIndentation')
    Assert-Eq $plain.Run.ExitCode 10 'complete unreferenced source exceeds fixed cap'
    $encoded = Run -Name encoded -Flags $allFlags
    Assert-Eq $encoded.Run.ExitCode 12 'complete five-flag payload reaches deliberately absent CLI'
    if ($script:Failures.Count) { Write-TestResult }
    $encodedStateFile = Join-Path $encoded.State 'state.json'
    Assert-True (Test-Path -LiteralPath $encodedStateFile) 'encoded CLI refusal writes its state record'
    if ($script:Failures.Count) { Write-TestResult }
    $reason = (Get-Content -Raw $encodedStateFile | ConvertFrom-Json).failure_reason
    Assert-True ($reason -match '^CLI probe:') 'both full-prompt caps pass before the absent CLI probe'
    Assert-True ($reason.Contains($missing)) 'CLI refusal identifies the exact absent override'

    $missingDependencies = @(
        @{ Name = 'missing-both'; Flags = @('-CompactSourceFrames') },
        @{ Name = 'missing-indent'; Flags = @('-CompactAddedFiles', '-CompactSourceFrames') },
        @{ Name = 'missing-added'; Flags = @('-CompactIndentation', '-CompactSourceFrames') }
    )
    foreach ($case in $missingDependencies) {
        $refused = Run -Name $case.Name -Flags $case.Flags
        Assert-Eq $refused.Run.ExitCode 12 "$($case.Name) dependency refused before attempt"
        Assert-True ($refused.Diagnostic -match '(?i)(source.frame|indentation|verified compact)') "$($case.Name) dependency diagnostic"
        Assert-True (-not ($refused.Diagnostic -match 'CLI probe:')) "$($case.Name) does not reach CLI probing"
    }
    $doc = Run -Name doc -Flags $allFlags -Mode doc
    Assert-Eq $doc.Run.ExitCode 12 'source frames rejected in doc mode before attempt'
    Assert-True ($doc.Diagnostic -match 'Compact representation requires local or PR mode') 'original doc-mode guard remains effective'
    foreach ($mode in @('local', 'pr')) {
        $refused = Run -Name "missing-provenance-$mode" -Flags $allFlags -Mode $mode -OmitProvenance
        Assert-Eq $refused.Run.ExitCode 12 "$mode provenance remains required"
        Assert-True ($refused.Diagnostic -match "$mode mode requires") "$mode original provenance guard"
    }

    # Source frames cannot bypass the canonical prior-recommendation ledger gate.
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
    Assert-Eq $ledger.Run.ExitCode 16 'frames do not bypass required carry-over ledger'
    Assert-Eq (Get-FileHash -LiteralPath $priorVerdict).Hash $priorHash 'canonical prior verdict remains byte-identical'

    foreach ($name in @('Get-CompactReviewGitRange', 'Get-ReviewGitQuotedPath')) {
        $definitions = @($ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq $name }.GetNewClosure(), $true))
        if ($definitions.Count -ne 1) { throw "Missing unique production function: $name" }
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    $composition = Entry 'if ($Mode -eq ''local'' -or $CompactAddedFiles)'
    $frameMeta = Entry 'if($CompactSourceFrames)'
    $writeMeta = Entry 'Write-AttemptMeta -StateDir'
    Assert-True ($frameMeta.Extent.EndOffset -lt $writeMeta.Extent.StartOffset) 'frame protocol hash attaches before immutable metadata write'
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
            $CompactReviewMetadata = $true; $CompactSourceFrames = $true
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
            foreach ($protocol in @((Get-CompactReviewProtocol), (Get-CompactIndentationProtocol), (Get-CompactSourceLineProtocol), (Get-ReviewMetadataProtocol), (Get-CompactSourceFrameProtocol))) {
                Assert-True ($promptBody.Contains($protocol)) "$mode complete production protocol included"
            }
            Assert-Eq $compactCoverage.version 1 "$mode root manifest schema remains version one"
            Assert-Eq $compactCoverage.source_frame_version 1 "$mode explicit source-frame manifest version"
            Assert-Eq @($compactCoverage.sections).Count 6 "$mode every source/history section remains covered"
            Assert-Eq @($compactCoverage.sections | Where-Object { $_.PSObject.Properties['encoding'] -and $_.encoding -ceq 'source-frame-lines' }).Count 2 "$mode both repeated Kotlin files use FL"
            Assert-Eq @($compactCoverage.sections | Where-Object { $_.PSObject.Properties['encoding'] -and $_.encoding -ceq 'source-frame' }).Count 1 "$mode literal collision file stays F"
            Assert-Eq @($metadataCoverage.sections | Where-Object metadata).Count 1 "$mode complete historical JSON is retained and encoded"
            $restoredFrames = Restore-ReviewMetadataDiff -Diff $reviewDiff -Manifest $metadataCoverage
            Assert-True ($restoredFrames -match '(?m)^~[0-9]+=value\(') "$mode zero-indent FL declaration remains unambiguous"
            Assert-True ($restoredFrames -match '(?m)^\+~[0-9]+=other\(') "$mode eight-space FL declaration uses plus indentation"
            Assert-True ($restoredFrames -match '(?m)^\+~[0-9]+~$') "$mode eight-space FL reference uses plus indentation"
            Assert-True ($restoredFrames -match '(?m)^~1~$') "$mode zero-indent FL reference remains an undecorated core"
            Assert-True ($restoredFrames.Contains("`n~0=SOURCE_FRAME_LITERAL_")) "$mode zero-indent reserved literal remains in F"
            Assert-True ($restoredFrames.Contains("`n+~0=SOURCE_FRAME_LITERAL_")) "$mode indented reserved literal remains in F"
            Assert-True ($restoredFrames.Contains("`n~0~`n")) "$mode zero-indent reserved reference remains literal"
            Assert-True ($restoredFrames.Contains("`n+~0~`n")) "$mode indented reserved reference remains literal"
            foreach ($section in @($compactCoverage.sections | Where-Object {
                $_.PSObject.Properties['encoding'] -and $_.encoding -in @('source-frame', 'source-frame-lines')
            })) {
                Assert-True ($section.index -cmatch '^0{7}\.\.[0-9a-f]{7}$') "$mode manifest retains the actual seven-zero/seven-hex index"
                Assert-Eq $section.mode '100644' "$mode original manifest retains the implied regular mode"
                Assert-True ($section.blob -cmatch '^[0-9a-f]{40}$') "$mode independent full HEAD blob proof remains in the manifest"
                $abbreviation = $section.index.Substring(9)
                Assert-True ($section.blob.StartsWith($abbreviation, [StringComparison]::Ordinal)) "$mode exact index abbreviation remains a prefix of the full HEAD blob"
                $headers = @([regex]::Matches($restoredFrames, '(?m)^\[(?:"F"|"FL"),[^\r\n]+') | ForEach-Object { ConvertFrom-Json -InputObject $_.Value -NoEnumerate })
                $header = @($headers | Where-Object { $_[1] -ceq $section.path })
                Assert-Eq $header.Count 1 "$mode one compact frame header for $($section.path)"
                Assert-Eq $header[0][2] $abbreviation "$mode field two is exactly the seven-hex abbreviation"
                Assert-Eq $header[0][3] $section.count "$mode field three retains the original source row count"
                $expectedFields = if ($section.encoding -ceq 'source-frame-lines') { 6 } else { 4 }
                Assert-Eq $header[0].Count $expectedFields "$mode frame keeps its exact declared field count"
                if ($section.encoding -ceq 'source-frame-lines') {
                    Assert-Eq $header[0][4] $section.source_line_start "$mode FL retains the legacy dictionary start counter"
                    Assert-Eq $header[0][5] $section.source_line_end "$mode FL retains the legacy dictionary end counter"
                }
            }
            Assert-Eq (Restore-CompactReviewDiff -Diff $restoredFrames -Manifest $compactCoverage) $range.Diff "$mode exact complete original diff reconstructed"
            Assert-Eq $compactCoverage.original_sha256 (Get-ReviewTextHash $range.Diff) "$mode original full-range digest preserved"

            # Default-off rendering must not alter existing protocol/manifest bytes.
            $legacy = ConvertTo-CompactReviewDiff -RepoRoot $root -BaseOid $base -HeadSha $head -Diff $range.Diff -CompactIndentation -CompactRepeatedLines
            $disabled = ConvertTo-CompactReviewDiff -RepoRoot $root -BaseOid $base -HeadSha $head -Diff $range.Diff -CompactIndentation -CompactRepeatedLines -CompactSourceFrames:$false
            Assert-Eq $disabled.Diff $legacy.Diff "$mode disabled frame output is byte-identical"
            Assert-Eq ($disabled.Manifest | ConvertTo-Json -Depth 30 -Compress) ($legacy.Manifest | ConvertTo-Json -Depth 30 -Compress) "$mode disabled frame manifest is byte-identical"
            Assert-True (-not [bool]$disabled.Manifest.PSObject.Properties['source_frame_version']) "$mode no new manifest field when frames are disabled"
            Assert-Eq $compactCoverage.source_line_version $legacy.Manifest.source_line_version "$mode adapter preserves the legacy source-line version"
            Assert-Eq $compactCoverage.source_line_dictionary_count $legacy.Manifest.source_line_dictionary_count "$mode adapter never adds or removes source dictionary entries"
            Assert-Eq $compactCoverage.source_line_dictionary_utf16 $legacy.Manifest.source_line_dictionary_utf16 "$mode adapter never changes retained dictionary cores"
            Assert-True ($restoredFrames.Length -lt $legacy.Diff.Length) "$mode outer frames shorten the actual legacy rendering in UTF16"
            Assert-True ([Text.Encoding]::UTF8.GetByteCount($restoredFrames) -lt [Text.Encoding]::UTF8.GetByteCount($legacy.Diff)) "$mode outer frames shorten the actual legacy rendering in UTF8"
            Assert-Eq @($legacy.Manifest.sections | Where-Object { $_.PSObject.Properties['encoding'] -and $_.encoding -ceq 'indent-lines' }).Count 2 "$mode legacy source-line pass produces the two INDENT_LINES inputs first"
            $literalLegacy = @($legacy.Manifest.sections | Where-Object path -ceq 'src/literal.asm')
            Assert-Eq $literalLegacy[0].encoding 'indent' "$mode legacy reserved-core gate leaves the collision file INDENT"
            $plainLegacy = @($legacy.Manifest.sections | Where-Object path -ceq 'src/plain.java')
            Assert-True (-not [bool]$plainLegacy[0].PSObject.Properties['encoding']) "$mode plain source fixture remains ADDED"
            $plainLinesLegacy = @($legacy.Manifest.sections | Where-Object path -ceq 'src/plain-lines.java')
            Assert-Eq $plainLinesLegacy[0].encoding 'lines' "$mode unindented repeated source fixture remains LINES"
            for ($index = 0; $index -lt $legacy.Manifest.sections.Count; $index++) {
                $old = $legacy.Manifest.sections[$index]
                $outer = $compactCoverage.sections[$index]
                foreach ($field in @('header', 'path', 'mode', 'index', 'blob', 'count', 'compact', 'original_sha256', 'original_length')) {
                    Assert-Eq $outer.$field $old.$field "$mode adapter preserves ordered original identity $field for $($old.path)"
                }
                foreach ($field in @('source_line_start', 'source_line_end')) {
                    Assert-Eq ([bool]$outer.PSObject.Properties[$field]) ([bool]$old.PSObject.Properties[$field]) "$mode adapter preserves presence of $field for $($old.path)"
                    if ($old.PSObject.Properties[$field]) {
                        Assert-Eq $outer.$field $old.$field "$mode adapter preserves dictionary counter $field for $($old.path)"
                    }
                }
                $oldEncoding = if ($old.PSObject.Properties['encoding']) { $old.encoding } else { 'added' }
                if ($oldEncoding -in @('indent', 'indent-lines')) {
                    $expectedEncoding = if ($oldEncoding -ceq 'indent') { 'source-frame' } else { 'source-frame-lines' }
                    Assert-Eq $outer.encoding $expectedEncoding "$mode adapter wraps only the corresponding legacy kind for $($old.path)"
                    Assert-True ($outer.rendered_length -lt $old.rendered_length) "$mode wrapped section is strictly shorter for $($old.path)"
                } else {
                    Assert-Eq ($outer | ConvertTo-Json -Depth 20 -Compress) ($old | ConvertTo-Json -Depth 20 -Compress) "$mode ADDED/LINES manifest section remains byte-identical for $($old.path)"
                }
            }
            & {
                $CompactSourceFrames = $false
                $meta = @{}
                . ([scriptblock]::Create($frameMeta.Extent.Text))
                Assert-True (-not $meta.ContainsKey('compact_source_frame_protocol_sha256')) "$mode no frame protocol hash when disabled"
            }

            $meta = @{}
            . ([scriptblock]::Create((Entry 'if ($CompactAddedFiles)' -Metadata).Extent.Text))
            . ([scriptblock]::Create((Entry 'if($CompactReviewMetadata)').Extent.Text))
            . ([scriptblock]::Create((Entry 'if($CompactIndentation)').Extent.Text))
            . ([scriptblock]::Create((Entry 'if($CompactRepeatedLines)').Extent.Text))
            . ([scriptblock]::Create($frameMeta.Extent.Text))
            Assert-Eq $meta.compact_source_frame_protocol_sha256 (Get-ReviewTextHash (Get-CompactSourceFrameProtocol)) "$mode immutable frame protocol hash"
            Assert-Eq $meta.compact_source_line_protocol_sha256 (Get-ReviewTextHash (Get-CompactSourceLineProtocol)) "$mode legacy line protocol hash unchanged"
            Assert-Eq $meta.compact_indentation_protocol_sha256 (Get-ReviewTextHash (Get-CompactIndentationProtocol)) "$mode legacy indentation protocol hash unchanged"
            if ($mode -eq 'pr') {
                Assert-Eq ($meta.pr_input_provenance | ConvertTo-Json -Depth 8 -Compress) ($provenance | ConvertTo-Json -Depth 8 -Compress) 'PR head/base and complete CI provenance unchanged'
            }
            $StateDir = Join-Path $root "isolated-meta-$mode"; $Round = 1; $attempt = 1
            [IO.Directory]::CreateDirectory($StateDir) | Out-Null
            . ([scriptblock]::Create($writeMeta.Extent.Text))
            $metaFile = Join-Path $StateDir 'round-1-attempt-1-meta.json'
            $saved = Get-Content -Raw $metaFile | ConvertFrom-Json
            Assert-Eq $saved.compact_source_frame_protocol_sha256 (Get-ReviewTextHash (Get-CompactSourceFrameProtocol)) "$mode actual immutable writer persists frame hash"
            $before = (Get-FileHash -LiteralPath $metaFile).Hash
            Assert-Throws { . ([scriptblock]::Create($writeMeta.Extent.Text)) } "$mode immutable metadata cannot be overwritten"
            Assert-Eq (Get-FileHash -LiteralPath $metaFile).Hash $before "$mode immutable metadata bytes stay fixed"
            $payloads[$mode] = [pscustomobject]@{ Prompt = $promptBody; Diff = $reviewDiff }
        }
    }
    Assert-Eq $payloads.local.Diff $payloads.pr.Diff 'shared local/PR source-frame representation is identical'
    Assert-Eq $payloads.pr.Prompt ($payloads.local.Prompt.Replace("== REVIEW MATERIAL (untrusted) ==`n", "== REVIEW MATERIAL (untrusted) ==`noffline verified PR/CI context`n")) 'PR composition differs only by verified PR/CI text'

    # Explicit negative representations exercise fallback without changing any Git
    # arguments, refs, files, or the actual range used by the positive entry tests.
    # These are never substituted into that range to make a source frame qualify.
    $negativeRange = Get-CompactReviewGitRange -RepoRoot $root -BaseOid $base -HeadSha $head -Mode local
    $negativeBaseline = ConvertTo-CompactReviewDiff -RepoRoot $root -BaseOid $base -HeadSha $head -Diff $negativeRange.Diff -CompactIndentation -CompactRepeatedLines
    foreach ($spelling in @('full40zero40hex', 'sevenzero8hex')) {
        $negativeDiff = $negativeRange.Diff
        foreach ($section in $negativeBaseline.Manifest.sections) {
            if (-not $section.compact) { continue }
            Assert-True ($section.index -cmatch '^0{7}\.\.[0-9a-f]{7}$') "$spelling starts from the actual untouched Git index"
            $negativeIndex = if ($spelling -ceq 'full40zero40hex') {
                ('0' * 40) + '..' + $section.blob
            } else {
                '0000000..' + $section.blob.Substring(0, 8)
            }
            $negativeDiff = $negativeDiff.Replace("index $($section.index)`n", "index $negativeIndex`n")
        }
        $old = ConvertTo-CompactReviewDiff -RepoRoot $root -BaseOid $base -HeadSha $head -Diff $negativeDiff -CompactIndentation -CompactRepeatedLines
        $fallback = ConvertTo-CompactReviewDiff -RepoRoot $root -BaseOid $base -HeadSha $head -Diff $negativeDiff -CompactIndentation -CompactRepeatedLines -CompactSourceFrames
        Assert-Eq $fallback.Diff $old.Diff "$spelling is not newly admitted by the source-frame adapter"
        Assert-Eq ($fallback.Manifest | ConvertTo-Json -Depth 30 -Compress) ($old.Manifest | ConvertTo-Json -Depth 30 -Compress) "$spelling retains the exact legacy fallback manifest"
        Assert-True (-not [bool]$fallback.Manifest.PSObject.Properties['source_frame_version']) "$spelling introduces no source-frame version"
        Assert-Eq (Restore-CompactReviewDiff -Diff $fallback.Diff -Manifest $fallback.Manifest) $negativeDiff "$spelling legacy fallback reconstructs its exact original index spelling"
    }

    # A complete unique source remains genuinely oversized even with all encoders.
    # Raising the caller's byte budget cannot change the fixed upstream limits.
    $unique = ('z' * 1048000) + "`nend`n"
    [IO.File]::WriteAllText((Join-Path $root 'src/unique.kt'), $unique, [Text.UTF8Encoding]::new($false))
    Fixture-Git @('-c', 'core.autocrlf=false', 'add', 'src/unique.kt')
    Fixture-Git @('-c', 'user.name=geoffroth', '-c', 'user.email=test@example.invalid', 'commit', '-q', '-m', 'unique over-cap source')
    $head = (Fixture-Git @('rev-parse', 'HEAD')).Trim()
    $raised = Run -Name raised -Flags $allFlags -Budget 1048577
    Assert-Eq $raised.Run.ExitCode 10 'actual over-cap five-flag composition remains refused with raised budget'
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^source-frame-input-[0-9a-f]{32}$') {
        throw 'Unsafe fixture cleanup target'
    }
    if ($script:SourceFrameProcessPending) {
        Write-Host "Retained source-frame fixture: root=$resolved; process-tree retirement is unconfirmed."
    } else {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-TestResult
