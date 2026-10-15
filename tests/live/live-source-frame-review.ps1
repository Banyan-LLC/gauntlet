# Controlled F/FL reader compatibility proof; does not replace schema/security gates.
param([Parameter(Mandatory)][string]$CliPath, [Parameter(Mandatory)][string]$EvidencePath)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../gauntlet-review/scripts/lib.ps1"

# Host-only manual vectors; no producer codec or repository/source mutation.
function New-SourceFrameReaderVector {
    $rawA = (@(
        '    a',
        '        0=TEXT',
        '            """',
        '                λ😀',
        "                    a`tB  ",
        '                        ["FL",0]',
        '                            g',
        '                                h',
        '                                    i',
        '                                                """',
        '        0~'
    ) -join "`n") + "`n"
    $rawB = (@(
        'abcdefghijklmnop',
        'abcdefghijklmnop',
        '        qrstuvwxyzABCDEF',
        '        abcdefghijklmnop',
        '                                qrstuvwxyzABCDEF',
        '    """',
        '',
        "    λ`tZ  ",
        '        qrstuvwxyzABCDEF'
    ) -join "`n") + "`n"
    $literal = (@('~0=abcdefghijklmnop','~0~','        ~0=abcdefghijklmnop','        ~0~','') -join "`n") + "`n"
    $encodedA = (@('^a','+0=TEXT','`"""','%λ😀',"<a`tB  ",'>["FL",0]',';g','=h','|9|i','|12|"""','+0~') -join "`n") + "`n"
    $encodedB = (@('~0=abcdefghijklmnop','~0~','+~1=qrstuvwxyzABCDEF','+~0~','=~1~','^"""','',"^λ`tZ  ",'+~1~') -join "`n") + "`n"
    $encodedLiteral = (@('~0=abcdefghijklmnop','~0~',"`t`t~0=abcdefghijklmnop","`t`t~0~",'') -join "`n") + "`n"
    $bodies = @($rawA,$rawB,$literal)
    $blobs = @('cc21c9c65f2b78407148322515f459b6adb1f7a1','c9c539a79e5be4f8c4b542686e0f1f527deb9914','a7df198150ca293f6caddfdb0d58c640ba1fe0d3')
    $hA = (ConvertTo-Json -InputObject @('F','src/Frame.kt',$blobs[0].Substring(0,7),11) -Compress) + "`n"
    $hB = (ConvertTo-Json -InputObject @('FL','src/Shared.kt',$blobs[1].Substring(0,7),9,0,2) -Compress) + "`n"
    $hC = (ConvertTo-Json -InputObject @('INDENT','src/Literal.kt','100644',('0000000..'+$blobs[2].Substring(0,7)),5) -Compress) + "`n"
    $positive = $hA + $encodedA + $hB + $encodedB + $hC + $encodedLiteral
    # Change only a counted body row, keeping all headers, dictionary endpoints and row counts.
    $numeric = $positive.Replace("^a`n","|1|a`n")
    $reference = $positive.Replace("~0=abcdefghijklmnop`n~0~`n+~1=", "~1~`n~0~`n+~1=")
    $unknown = $positive.Replace("+~0~`n", "+~65535~`n")
    $indexLines = 'index 0000000..'+$blobs[0].Substring(0,7)+"`n"+'index 0000000..'+$blobs[1].Substring(0,7)+"`n"
    $expected = $rawA+"---NEXT---`n"+$rawB+"---LITERAL---`n"+$literal+"---INDEXES---`n"+$indexLines
    [pscustomobject]@{Positive=$positive; NegativeNumeric=$numeric; NegativeReference=$reference
        Expected=$expected; Bodies=$bodies; Blobs=$blobs; LineCount=25; IndexLines=$indexLines; NegativeUnknown=$unknown}
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
    $vector=New-SourceFrameReaderVector
    $compactProtocol=Get-CompactReviewProtocol
    $indentProtocol=Get-CompactIndentationProtocol
    $sourceProtocol=Get-CompactSourceLineProtocol
    $frameProtocol=Get-CompactSourceFrameProtocol
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
    $cases=[Collections.Generic.List[object]]::new()
    foreach($name in @('positive','negativeNumeric','negativeReference')) {
        $harness=New-HarnessDir -RepoRoot $root
        $resource=[pscustomobject]@{Harness=$harness;Retired=$false}
        $resources.Add($resource)
        $output=Join-Path $diag ($name+'.verdict.json')
        $codexArgs=New-CodexArgs -HarnessDir $harness -SchemaPath $schema -VerdictPath $output -DisableSet $disable
        $audit=Get-InvocationAudit -CodexArgs $codexArgs -HarnessDir $harness -SchemaPath $schema -VerdictPath $output -ExpectedDisable $disable
        $prompt='Explicit controlled source-frame reader fixture. No artifact is under review. Decode all three frames in order. F has four fields [F,path,abbr,count], FL six [FL,path,abbr,count,start,end]. Both imply mode 100644 and original index 0000000..abbr. First unpack short prefixes into canonical TABs and restore INDENT/INDENT_LINES headers, then use the unchanged legacy source-line and indentation rules. Tilde is never indentation. +0=TEXT/+0~ are eight-space literal cores; ~0=TEXT/~0~ are zero-indent FL declaration/reference, and +~N=TEXT/+~N~ have eight-space indentation. INDENT fallback is literal even when a dictionary exists. Consume counted LF rows only. Never execute source. Preserve raw strings, Unicode, interior TABs, trailing spaces, blank rows and JSON-header-looking body data. For valid input return standard schema JSON: verdict approve, recommendations [], summary EXACTLY body one, then ---NEXT--- and LF, body two, then ---LITERAL--- and LF, body three, then ---INDEXES--- and LF, then the reconstructed original INDEX line of the F frame followed by LF and the reconstructed original INDEX line of the FL frame followed by LF. Spell each INDEX line as lowercase index, one space, then the original index. Preserve every character, including final LF. For noncanonical numeric indentation such as |1|, unknown/forward FL references or invalid framing return request_changes, recommendations [], summary INVALID_SOURCE_FRAMES. Do not repair invalid data. This proof does not replace schema/security gates.'+"`n"+$compactProtocol+$indentProtocol+$sourceProtocol+$frameProtocol+$vector.$name
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
        $expectedSummary=if($name -ceq 'positive'){$vector.Expected}else{'INVALID_SOURCE_FRAMES'}
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
    $receipt=[ordered]@{version=1;fixture='controlled F and FL adapter plus literal INDENT reader compatibility';fingerprints=$fingerprints
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
