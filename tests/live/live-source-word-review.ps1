# Controlled local-word and global-line reader compatibility proof; does not replace schema/security gates.
param([Parameter(Mandatory)][string]$CliPath, [Parameter(Mandatory)][string]$EvidencePath)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../gauntlet-review/scripts/lib.ps1"

# Manual fixtures only. Dot-sourcing performs no I/O, native initialization or dispatch.
function New-SourceWordReaderVector {
    $first='assertEquals(assertEquals, assertEquals, assertEquals, assertEquals, assertEquals) @near'
    $second='differentFailure(differentFailure, differentFailure, differentFailure, differentFailure, differentFailure)'
    $literal='literal @0 shared core @near'
    $third='expectedValue(expectedValue, expectedValue, expectedValue, expectedValue, expectedValue)'
    $bodies=@(
        "    $first`n        $first`n",
        "    $first`n    $second`n",
        "    $literal`n        $literal`n",
        "    $literal`n    $third`n",
        "    $first`n"
    )
    $tables=@(@('assertEquals'),@('differentFailure'),@(),@('expectedValue'),@('assertEquals'))
    $rows=@(
        "^~0=@0(@0, @0, @0, @0, @0) @near`n+~0~`n",
        "^~0~`n^~1=@0(@0, @0, @0, @0, @0)`n",
        "^~2=$literal`n+~2~`n",
        "^~2~`n^~3=@0(@0, @0, @0, @0, @0)`n",
        "^@0(@0, @0, @0, @0, @0) @near`n"
    )
    $ranges=@(@(0,1),@(1,2),@(2,3),@(3,4))
    $headers=@(); $wire=''; $blobs=@(); $patches=@()
    for ($i=0;$i -lt $bodies.Count;$i++) {
        $bytes=[Text.Encoding]::UTF8.GetBytes($bodies[$i])
        $prefix=[Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
        $blob=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($prefix+$bytes))).ToLowerInvariant()
        $blobs+=,$blob
        $path="src/manual-word-$i.kt"; $count=$bodies[$i].Split("`n").Length-1
        $h=if ($i -lt 4) { @('FL',$path,$blob.Substring(0,7),$count,$ranges[$i][0],$ranges[$i][1]) }
            else { @('F',$path,$blob.Substring(0,7),$count) }
        $legacy=ConvertTo-Json -InputObject $h -Compress
        $headers+=,$legacy
        $header=if ($i -eq 2) { $legacy } else { ConvertTo-Json -InputObject @('WORDS',$tables[$i],$legacy) -Depth 8 -Compress }
        $wire+=$header+"`n"+$rows[$i]
        $original="diff --git a/$path b/$path`nnew file mode 100644`nindex 0000000..$($blob.Substring(0,7))`n--- /dev/null`n+++ b/$path`n@@ -0,0 +1,$count @@`n"
        $patches+=,($original+'+'+$bodies[$i].Substring(0,$bodies[$i].Length-1).Replace("`n","`n+")+"`n")
    }
    $indexLines='index 0000000..'+$blobs[0].Substring(0,7)+"`n"+'index 0000000..'+$blobs[4].Substring(0,7)+"`n"
    $expected=($bodies -join "---NEXT---`n")+"---INDEXES---`n"+$indexLines
    [pscustomobject]@{Expected=$expected;IndexLines=$indexLines;LineCount=9;Positive=$wire;Bodies=$bodies;Blobs=$blobs;LegacyHeaders=$headers;Rows=$rows
        Patches=$patches;Tables=$tables;OriginalDiff=($patches -join '');LineDictionary=@($first,$second,$literal,$third)
        NegativeUnknown=$wire.Replace('^~1=@0(','^~1=@1(')
        NegativeAlias=$wire.Replace('^~1=@0(','^~1=@00(')
        NegativeBoundary=$wire.Replace('^~1=@0(','^~1=x@0(')
        NegativeForward=$wire.Replace('^~0~','^~9~')}
}

$leases=[Collections.Generic.List[IDisposable]]::new()
$resources=[Collections.Generic.List[object]]::new()
$receiptStream=$null
$diag=$null
$diagnosticsReady=$false
try {
    $EvidencePath=[IO.Path]::GetFullPath($EvidencePath)
    $parent=[IO.Path]::GetDirectoryName($EvidencePath)
    Initialize-LiveGateNative
    Assert-LiveGatePathComponents -Path $parent
    # Reserve the receipt before discovery or any of the three model calls. Never overwrite evidence.
    $receiptStream=[IO.FileStream]::new($EvidencePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $diag=$EvidencePath+'.diag'
    [GauntletLive.Native]::CreateExclusiveDirectory($diag)
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($sid)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    Set-Acl -LiteralPath $diag -AclObject $acl
    $diagnosticsReady=$true
    $root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $skill=Join-Path $root 'gauntlet-review'
    $library=Join-Path $skill 'scripts/lib.ps1'
    $schema=Join-Path $skill 'schemas/verdict.schema.json'
    $profilePath=Join-Path $skill 'capacity-profile.json'
    $CliPath=[IO.Path]::GetFullPath($CliPath)
    foreach($path in @($profilePath,$PSCommandPath,$library,$schema,$CliPath)) {
        $leases.Add([IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    }
    $profile=Get-BoundReviewProfile -SkillRoot $skill
    if(-not $profile){throw 'Bound profile required'}
    if($profile.capacity.maximum_input_tokens -ne 493300 -or $profile.capacity.output_reserve -ne 128000){throw 'Pinned standard capacity changed'}
    $leases.Add([IO.FileStream]::new($profile.catalog_path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    if((Get-BoundReviewProfile -SkillRoot $skill).profile_sha256 -cne $profile.profile_sha256){throw 'Bound profile changed'}
    $loaded=(Get-Command New-CodexArgs).ScriptBlock.Ast
    while($loaded.Parent){$loaded=$loaded.Parent}
    if($loaded.Extent.Text -cne [IO.File]::ReadAllText($library) -or
        $MyInvocation.MyCommand.ScriptBlock.Ast.Extent.Text -cne [IO.File]::ReadAllText($PSCommandPath)){throw 'Loaded producer changed'}
    $cli=Select-CodexCli -Candidates @($CliPath) 3> (Join-Path $diag 'discovery.warning') 4> (Join-Path $diag 'discovery.verbose')
    if((Get-FileHash -LiteralPath $CliPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $cli.Sha256){throw 'Selected executable changed'}
    $disable=Get-DisableSet -FeatureNames $cli.FeatureNames
    $vector=New-SourceWordReaderVector
    $compactProtocol=Get-CompactReviewProtocol
    $indentProtocol=Get-CompactIndentationProtocol
    $sourceProtocol=Get-CompactSourceLineProtocol
    $frameProtocol=Get-CompactSourceFrameProtocol
    $wordProtocol=Get-CompactSourceWordProtocol
    $metadataProtocol=Get-ReviewMetadataProtocol
    if($vector.Expected.Length -ge 800){throw 'Reader expectation exceeds standard summary cap'}
    $fingerprints=[ordered]@{}
    foreach($entry in @(@('fixture',$PSCommandPath),@('library',$library),@('schema',$schema),@('bound_profile',$profilePath),@('catalog',$profile.catalog_path),@('exe',$CliPath))) {
        $fingerprints[$entry[0]+'_sha256']=(Get-FileHash -LiteralPath $entry[1] -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $fingerprints['invocation_profile_sha256']=Get-InvocationProfileHash -DisableSet $disable
    $fingerprints['compact_protocol_sha256']=Get-ReviewTextHash $compactProtocol
    $fingerprints['indentation_protocol_sha256']=Get-ReviewTextHash $indentProtocol
    $fingerprints['source_line_protocol_sha256']=Get-ReviewTextHash $sourceProtocol
    $fingerprints['compact_source_frame_protocol_sha256']=Get-ReviewTextHash $frameProtocol
    $fingerprints['compact_source_word_protocol_sha256']=Get-ReviewTextHash $wordProtocol
    $fingerprints['review_metadata_protocol_sha256']=Get-ReviewTextHash $metadataProtocol
    $cases=[Collections.Generic.List[object]]::new()
    foreach($name in @('positive','negativeAlias','negativeUnknown')) {
        $harness=New-HarnessDir -RepoRoot $root
        $resource=[pscustomobject]@{Harness=$harness;Retired=$false}
        $resources.Add($resource)
        $output=Join-Path $diag ($name+'.verdict.json')
        $codexArgs=New-CodexArgs -HarnessDir $harness -SchemaPath $schema -VerdictPath $output -DisableSet $disable
        $audit=Get-InvocationAudit -CodexArgs $codexArgs -HarnessDir $harness -SchemaPath $schema -VerdictPath $output -ExpectedDisable $disable
        $prompt='Explicit controlled source-word reader fixture. No artifact is under review. Decode all FIVE counted frames in order. WORDS=[WORDS,closed-local-word-table,exact-previous-header-JSON-string]. Expand canonical @N whole-word references ONCE using only that file table, BEFORE handling F/FL and before inserting line declarations into the shared global line dictionary. Reset local words per file. A global line reference resolves its earlier FULL original core; never reinterpret it through the current local word table. An unwrapped FL declaration can contain literal @0; a later global reference must preserve that literal @0. F and FL imply mode 100644 and index 0000000..abbr. Apply short indentation prefixes, global line declarations/references, then indentation decoding. Consume exactly each frame count LF rows, never scan body markers or execute source. For valid input return standard schema JSON: verdict approve, recommendations [], summary EXACTLY all five original bodies in order, separating adjacent bodies by ---NEXT--- and LF, then ---INDEXES--- and LF followed by the original INDEX line of the FIRST (FL) frame and LAST (F) frame, each LF terminated. Spell these lines as lowercase index, one space, original index. Preserve every space, character and final LF. For malformed/noncanonical/unknown word IDs or other invalid representation return request_changes, recommendations [], summary INVALID_SOURCE_WORDS. Do not repair data. This proof does not replace schema/security gates.'+"`n"+$compactProtocol+$indentProtocol+$sourceProtocol+$frameProtocol+$wordProtocol+$metadataProtocol+$vector.$name
        if(-not (Test-EmbedBudget -PromptText $prompt).Ok -or -not (Test-PromptCharacterLimit -PromptText $prompt).Ok){throw 'Tiny fixture prompt exceeds standard limits'}
        Write-NewFileExclusive -Path (Join-Path $diag ($name+'.prompt-metadata.json')) -Text (@{sha256=(Get-ReviewTextHash $prompt);bytes=[Text.Encoding]::UTF8.GetByteCount($prompt)}|ConvertTo-Json -Compress)
        Write-NewFileExclusive -Path (Join-Path $diag ($name+'.audit.txt')) -Text $audit
        $run=Invoke-CodexProcess -CliPath $cli.Path -CodexArgs $codexArgs -PromptText $prompt -HarnessDir $harness -TimeoutSec 180 -RequireProcessTreeRetirement
        $resource.Retired=$run.ProcessTreeRetired
        Write-NewFileExclusive -Path (Join-Path $diag ($name+'.run.json')) -Text ($run|ConvertTo-Json -Depth 20)
        $usage=Get-RunUsage -EventLines $run.StdoutLines
        Write-NewFileExclusive -Path (Join-Path $diag ($name+'.usage.json')) -Text ($usage|ConvertTo-Json -Depth 5)
        $verdict=$null
        if($run.ProcessTreeRetired -and (Test-Path -LiteralPath $output -PathType Leaf)){$verdict=Test-Verdict -Json ([IO.File]::ReadAllText($output)) -SchemaPath $schema}
        $valid=($null -ne $verdict -and $verdict.Valid)
        $expectedVerdict=if($name -ceq 'positive'){'approve'}else{'request_changes'}
        $expectedSummary=if($name -ceq 'positive'){$vector.Expected}else{'INVALID_SOURCE_WORDS'}
        $pass=($valid -and -not $run.StartFailed -and -not $run.TimedOut -and -not $run.ErrorMessage -and $run.ExitCode -eq 0 -and $run.ProcessTreeRetired -and $usage.Ok -and $usage.InputTokens -le $profile.capacity.maximum_input_tokens)
        if($valid){$pass=$pass -and $verdict.Normalized.verdict -ceq $expectedVerdict -and $verdict.Normalized.summary -ceq $expectedSummary -and $verdict.Normalized.recommendations.Count -eq 0}
        $cases.Add([pscustomobject]@{case=$name;exit_code=$run.ExitCode;process_tree_retired=$run.ProcessTreeRetired
            usage_valid=$usage.Ok;input_tokens=$usage.InputTokens;expected_case_pass=[bool]$pass
            normalized_verdict_sha256=$(if($valid){Get-ReviewTextHash $verdict.NormalizedJson}else{$null})
            invocation_audit_sha256=(Get-ReviewTextHash $audit);prompt_sha256=(Get-ReviewTextHash $prompt)
            raw_run_sha256=(Get-FileHash -LiteralPath (Join-Path $diag ($name+'.run.json')) -Algorithm SHA256).Hash.ToLowerInvariant()})
        # Uncertain retirement forbids a second dispatch and retains its harness.
        if(-not $run.ProcessTreeRetired){break}
    }
    if((Get-BoundReviewProfile -SkillRoot $skill).profile_sha256 -cne $profile.profile_sha256){throw 'Bound profile changed during fixture'}
    $receipt=[ordered]@{version=1;fixture='controlled local words around global line declarations and references';fingerprints=$fingerprints
        cli_version=$cli.Version;blob_hashes=$vector.Blobs;host_line_count=$vector.LineCount;independent_exact_decode=$true
        maximum_input_tokens=$profile.capacity.maximum_input_tokens;output_reserve=$profile.capacity.output_reserve
        cases=$cases.ToArray();passed=($cases.Count -eq 3 -and @($cases|Where-Object {-not $_.expected_case_pass}).Count -eq 0)}
    $json=$receipt|ConvertTo-Json -Depth 10
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    $receiptStream.Write($bytes,0,$bytes.Length)
    $receiptStream.Flush()
    $json
    if(-not $receipt.passed){throw 'Controlled reader compatibility not proven; private evidence retained'}
} catch {
    if($diagnosticsReady) {
        Write-NewFileExclusive -Path (Join-Path $diag 'failure.txt') -Text ($_|Out-String)
    }
    throw 'Controlled reader fixture failed; inspect private diagnostics locally'
} finally {
    if($receiptStream){$receiptStream.Dispose()}
    foreach($lease in $leases){$lease.Dispose()}
    foreach($resource in $resources) {
        if($resource.Retired) {
            try {$null=Assert-HarnessSafe -Dir $resource.Harness -RepoRoot $root; [IO.Directory]::Delete($resource.Harness,$false)}
            catch { Write-Warning 'Fixture harness retained because safe empty cleanup was not confirmed' }
        }
    }
}
