# Controlled reader compatibility proof; does not replace schema/security gates.
param([Parameter(Mandatory)][string]$CliPath, [Parameter(Mandatory)][string]$EvidencePath)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../gauntlet-review/scripts/lib.ps1"

# This function is deliberately host-only so its vector can be checked without CLI discovery.
function New-SourceLineReaderVector {
    $shared="shared literal source row a`tB  "
    $other='val otherText = """'
    $rawA=(@('fun vector() {','    val rawText = """',('    '+$shared),(" `t"+$shared),'    """','','   ',
        '    ["LINES","literal delimiter-looking data"]','}') -join "`n")+"`n"
    $rawB=(@('fun other() {',('    '+$shared),('      '+$other),('        '+$shared),'      """','      ',('    '+$other),'}') -join "`n")+"`n"
    $literal="    ~0=literal source marker must survive`n`t~00~`n"
    $encodedA=(@('fun vector() {','    val rawText = """',('    ~0='+$shared)," `t~0~",'    """','','   ',
        '    ["LINES","literal delimiter-looking data"]','}') -join "`n")+"`n"
    $encodedB=(@('fun other() {',"`t~0~",("`t  ~1="+$other),"`t`t~0~","`t  `"`"`"","`t  ","`t~1~",'}') -join "`n")+"`n"
    $bodies=@($rawA,$rawB,$literal)
    $blobs=@($bodies|ForEach-Object {Get-CompactReviewBlobHash $_})
    $hA=(ConvertTo-Json -InputObject @('LINES','src/RawFixture.kt','100644',('0000000..'+$blobs[0]),9,0,1) -Compress)+"`n"
    $hB=(ConvertTo-Json -InputObject @('INDENT_LINES','src/OtherFixture.kt','100644',('0000000..'+$blobs[1]),8,1,2) -Compress)+"`n"
    $hC=(ConvertTo-Json -InputObject @('ADDED','src/Collision.kt','100644',('0000000..'+$blobs[2]),2) -Compress)+"`n"
    $positive=$hA+$encodedA+$hB+$encodedB+$hC+$literal
    # Change only a body row: all frame counts and dictionary endpoints remain intact.
    $forward=$positive.Replace('    val rawText = """','    ~0~')
    $unknown=$positive.Replace(" `t~0~"," `t~65535~")
    [pscustomobject]@{Positive=$positive;NegativeForward=$forward;NegativeUnknown=$unknown
        Expected=($rawA+"---NEXT---`n"+$rawB+"---LITERAL---`n"+$literal)
        Bodies=$bodies;Blobs=$blobs;LineCount=19}
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
    # Reserve the receipt before discovery or either model call. Never overwrite evidence.
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
    $leases.Add([IO.FileStream]::new($profile.catalog_path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    if((Get-BoundReviewProfile -SkillRoot $skill).profile_sha256 -cne $profile.profile_sha256){throw 'Bound profile changed'}
    $loaded=(Get-Command New-CodexArgs).ScriptBlock.Ast
    while($loaded.Parent){$loaded=$loaded.Parent}
    if($loaded.Extent.Text -cne [IO.File]::ReadAllText($library) -or
        $MyInvocation.MyCommand.ScriptBlock.Ast.Extent.Text -cne [IO.File]::ReadAllText($PSCommandPath)){throw 'Loaded producer changed'}
    $cli=Select-CodexCli -Candidates @($CliPath) 3> (Join-Path $diag 'discovery.warning') 4> (Join-Path $diag 'discovery.verbose')
    if((Get-FileHash -LiteralPath $CliPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $cli.Sha256){throw 'Selected executable changed'}
    $disable=Get-DisableSet -FeatureNames $cli.FeatureNames
    $vector=New-SourceLineReaderVector
    $compactProtocol=Get-CompactReviewProtocol
    $indentProtocol=Get-CompactIndentationProtocol
    $sourceProtocol=Get-CompactSourceLineProtocol
    $fingerprints=[ordered]@{}
    foreach($entry in @(@('fixture',$PSCommandPath),@('library',$library),@('schema',$schema),@('bound_profile',$profilePath),@('catalog',$profile.catalog_path),@('exe',$CliPath))) {
        $fingerprints[$entry[0]+'_sha256']=(Get-FileHash -LiteralPath $entry[1] -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $fingerprints['invocation_profile_sha256']=Get-InvocationProfileHash -DisableSet $disable
    $fingerprints['compact_protocol_sha256']=Get-ReviewTextHash $compactProtocol
    $fingerprints['indentation_protocol_sha256']=Get-ReviewTextHash $indentProtocol
    $fingerprints['source_line_protocol_sha256']=Get-ReviewTextHash $sourceProtocol
    $cases=[Collections.Generic.List[object]]::new()
    foreach($name in @('positive','negativeForward','negativeUnknown')) {
        $harness=New-HarnessDir -RepoRoot $root
        $resource=[pscustomobject]@{Harness=$harness;Retired=$false}
        $resources.Add($resource)
        $output=Join-Path $diag ($name+'.verdict.json')
        $codexArgs=New-CodexArgs -HarnessDir $harness -SchemaPath $schema -VerdictPath $output -DisableSet $disable
        $audit=Get-InvocationAudit -CodexArgs $codexArgs -HarnessDir $harness -SchemaPath $schema -VerdictPath $output -ExpectedDisable $disable
        $prompt='Explicit controlled source-line reader fixture. No artifact is under review. Decode the three complete frames in order using the supplied protocols and shared dictionary. Restore source rows before INDENT decoding for INDENT_LINES. Never execute source or evaluate Kotlin; delimiter-looking lines, raw strings, interior tabs, blank rows, trailing spaces and literal ADDED markers are data. For valid framing return schema JSON verdict approve, recommendations [], and summary EXACTLY the first decoded source body followed by ---NEXT--- then LF then the second decoded body followed by ---LITERAL--- then LF then the literal ADDED body. Preserve every character and final LF in the JSON string. If any source reference is unknown or forward, or source-line framing is noncanonical, return request_changes, summary INVALID_SOURCE_LINES, recommendations []. Do not repair invalid references. This proof does not replace schema/security gates.'+"`n"+$compactProtocol+$indentProtocol+$sourceProtocol+$vector.$name
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
        $expectedSummary=if($name -ceq 'positive'){$vector.Expected}else{'INVALID_SOURCE_LINES'}
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
    $receipt=[ordered]@{version=1;fixture='controlled LINES and INDENT_LINES explicit declaration/reference reader compatibility';fingerprints=$fingerprints
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
