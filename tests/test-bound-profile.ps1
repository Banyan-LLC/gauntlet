. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\..\gauntlet-review\scripts\lib.ps1"
$ErrorActionPreference = 'Stop'

# All catalog/profile bytes are synthetic. Never read the machine-local profile,
# account state, or model catalog; only redirect lookup, preserving the real parser.
$root = Join-Path ([IO.Path]::GetTempPath()) ('bound-profile-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$originalProfile = ${function:Get-BoundReviewProfile}
try {
    $script:fixtureSkillRoot = $root
    $script:fixtureProfileReader = $originalProfile
    function Get-BoundReviewProfile {
        param([string]$SkillRoot = $script:fixtureSkillRoot)
        & $script:fixtureProfileReader -SkillRoot $SkillRoot
    }
    $build = @{ HarnessDir='C:\fixture harness'; SchemaPath='C:\fixture schema.json'; VerdictPath='C:\fixture verdict.json'; DisableSet=@('apps','browser_use','shell_tool') }
    $audit = @{ HarnessDir=$build.HarnessDir; SchemaPath=$build.SchemaPath; VerdictPath=$build.VerdictPath; ExpectedDisable=$build.DisableSet }
    $catalogPath = Join-Path $root 'catalog snapshot.json'
    $profilePath = Join-Path $root 'capacity-profile.json'
    Assert-True ($null -eq (Get-BoundReviewProfile -SkillRoot $root)) 'missing optional profile returns null'
    $unboundArgs = New-CodexArgs @build
    Assert-Eq @($unboundArgs | Where-Object { $_ -match '^model_(catalog_json|context_window)=' }).Count 0 'optional profile absent: no capacity overrides'
    $null = Get-InvocationAudit -CodexArgs $unboundArgs @audit
    $unboundHash = Get-InvocationProfileHash -DisableSet $build.DisableSet

    $catalog = @{ models=@(@{ slug='gpt-6.1-sol'; context_window=272000; max_context_window=872000; effective_context_window_percent=95 }); snapshot_fixture='first' }
    function Write-FixtureCatalog {
        [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 8 -Compress))
    }
    function Write-FixtureProfile {
        [IO.File]::WriteAllText($profilePath, ($profile | ConvertTo-Json -Depth 8 -Compress))
    }
    Write-FixtureCatalog
    $profile = @{ version=1; model='gpt-6.1-sol'; catalog_path=$catalogPath; catalog_sha256=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant(); requested_context_window=872000; expected_default=272000; expected_maximum=872000; expected_effective_percent=95 }
    Write-FixtureProfile
    $bound = Get-BoundReviewProfile -SkillRoot $root
    Assert-Eq $bound.capacity.effective_tokens 828400 '872000 at 95 percent gives effective 828400 tokens'
    Assert-Eq $bound.capacity.maximum_input_tokens 493300 'headroom and output reserve leave input ceiling 493300'
    Assert-Eq $bound.capacity.catalog_default 272000 'bound override preserves catalog default evidence'
    Assert-Eq $bound.catalog_sha256 $profile.catalog_sha256 'bound snapshot SHA matches fixture bytes'
    $argsBound = New-CodexArgs @build
    $null = Get-InvocationAudit -CodexArgs $argsBound @audit
    $boundHash = Get-InvocationProfileHash -DisableSet $build.DisableSet
    Assert-True ($boundHash -cne $unboundHash) 'bound profile changes invocation profile hash'
    $hashArgs = New-CodexArgs -HarnessDir '<HARNESS>' -SchemaPath '<SCHEMA>' -VerdictPath '<VERDICT>' -DisableSet $build.DisableSet
    $hashMaterial = ($hashArgs -join "`u{001f}") + "`u{001f}" + $bound.catalog_sha256 + "`u{001f}" + $bound.profile_sha256
    $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashMaterial))).ToLowerInvariant()
    Assert-Eq $boundHash $expectedHash 'invocation hash explicitly includes canonical args, catalog SHA and profile SHA'
    Assert-Eq (Get-InvocationProfileHash -DisableSet $build.DisableSet) $boundHash 'unchanged profile hashes deterministically'
    Assert-Eq @($argsBound | Where-Object { $_ -ceq 'model_context_window=872000' }).Count 1 'exact requested window override occurs once'
    $catalogOverride = 'model_catalog_json=' + (ConvertTo-Json -Compress $catalogPath)
    Assert-Eq @($argsBound | Where-Object { $_ -ceq $catalogOverride }).Count 1 'snapshot path override is JSON quoted and occurs once'
    foreach ($override in @('model_context_window=872000', $catalogOverride)) {
        $index = [array]::IndexOf($argsBound, $override)
        Assert-True ($index -gt 0 -and $argsBound[$index-1] -ceq '-c') 'capacity override is a -c pair'
        $tampered = [string[]]@($argsBound)
        $tampered[$index] = if ($override -like 'model_context_window=*') { 'model_context_window=872001' } else { 'model_catalog_json="C:\\other.json"' }
        Assert-Throws { Get-InvocationAudit -CodexArgs $tampered @audit } "tampered $override rejected"
        $missing = [string[]]@(for ($i=0; $i -lt $argsBound.Count; $i++) { if ($i -ne ($index-1) -and $i -ne $index) { $argsBound[$i] } })
        Assert-Throws { Get-InvocationAudit -CodexArgs $missing @audit } "missing $override rejected"
        $duplicate = [string[]]@($argsBound[0..($argsBound.Count-2)] + @('-c',$override,'-'))
        Assert-Throws { Get-InvocationAudit -CodexArgs $duplicate @audit } "duplicate $override rejected"
    }
    $profile.requested_context_window = 872001
    Write-FixtureProfile
    Assert-Throws { Get-BoundReviewProfile -SkillRoot $root } 'requested window above actual catalog maximum rejected'
    Assert-Throws { New-CodexArgs @build } 'composer refuses above-maximum bound window'
    $profile.requested_context_window = 872000
    Write-FixtureProfile

    # A metadata-only change keeps CLI args and capacities identical. It must
    # invalidate the old binding, then alter the invocation hash when rebound.
    $catalog.snapshot_fixture = 'second'
    Write-FixtureCatalog
    Assert-Throws { Get-BoundReviewProfile -SkillRoot $root } 'changed snapshot bytes fail SHA verification'
    Assert-Throws { New-CodexArgs @build } 'composer fails closed on changed snapshot'
    Assert-Throws { Get-InvocationAudit -CodexArgs $argsBound @audit } 'audit fails closed on changed snapshot'
    Assert-Throws { Get-InvocationProfileHash -DisableSet $build.DisableSet } 'hash computation fails closed on changed snapshot'
    $profile.catalog_sha256 = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-FixtureProfile
    Assert-Eq ((New-CodexArgs @build) -join '|') ($argsBound -join '|') 'rebound metadata change leaves canonical CLI args identical'
    Assert-True ((Get-InvocationProfileHash -DisableSet $build.DisableSet) -cne $boundHash) 'invocation hash binds catalog SHA beyond identical argument array'
    foreach ($field in @('expected_default','expected_maximum','expected_effective_percent')) {
        $saved = $profile[$field]
        $profile[$field] = $saved + 1
        Write-FixtureProfile
        Assert-Throws { Get-BoundReviewProfile -SkillRoot $root } "mismatched $field rejected"
        $profile[$field] = $saved
    }
    $profile.runtime_probe_source_sha256 = 'b'*64
    Write-FixtureProfile
    $null=New-Item -ItemType Directory -Path (Join-Path $root 'scripts')
    $libraryPath=Join-Path $root 'scripts/lib.ps1'
    [IO.File]::WriteAllText($libraryPath,'fixture source')
    $proofPath=Join-Path $root 'capacity-runtime-proof.json'
    $profileHash=Get-InvocationProfileHash -DisableSet $build.DisableSet
    $cli=[pscustomobject]@{Sha256=('a'*64)}
    $proof=@{version=1;fixture_sha256=('b'*64);library_sha256=(Get-FileHash $libraryPath).Hash.ToLowerInvariant();cli_sha256=$cli.Sha256;profile_sha256=$profileHash;catalog_sha256=$profile.catalog_sha256;expected_effective_tokens=828400;actual_capacity_verified=$true;exit_code=0;process_tree_retired=$true;usage_valid=$true;trusted_runtime_context_values=@(828400);runtime_metric_records=@(@{metric_syntax='model_context_window_effective":828400';value=828400})}
    function Write-FixtureProof { $proof | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $proofPath }
    Write-FixtureProof
    Assert-True (Test-BoundRuntimeProof -SkillRoot $root -ActualCli $cli -InvocationProfileHash $profileHash).actual_capacity_verified 'exact producer/profile/catalog/runtime proof accepted'
    foreach($field in @('cli_sha256','profile_sha256','catalog_sha256','fixture_sha256','library_sha256')) {
        $saved=$proof[$field];$proof[$field]='0'*64;Write-FixtureProof
        Assert-Throws { Test-BoundRuntimeProof -SkillRoot $root -ActualCli $cli -InvocationProfileHash $profileHash } "$field drift rejects runtime proof"
        $proof[$field]=$saved
    }
    $proof.trusted_runtime_context_values=@(258400);Write-FixtureProof
    Assert-Throws { Test-BoundRuntimeProof -SkillRoot $root -ActualCli $cli -InvocationProfileHash $profileHash } 'incorrect effective runtime window rejects'
    $proof.trusted_runtime_context_values=@(828400);Write-FixtureProof
    $lease=New-BoundReviewLease -SkillRoot $root
    try {
        Assert-Throws {[IO.File]::WriteAllText($catalogPath,'replace')} 'bound catalog cannot be rewritten during lease'
        Assert-Throws {[IO.File]::WriteAllText($profilePath,'replace')} 'bound profile cannot be rewritten during lease'
    }finally{foreach($handle in $lease){$handle.Dispose()}}
    # Execute the production acceptance block, without any model process or
    # canonical verdict path. The real usage count must obey the bound ceiling.
    $invokeText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../gauntlet-review/scripts/invoke-codex.ps1'))
    $gateStart=$invokeText.IndexOf('$maximumInputTokens = ')
    $gateEnd=$invokeText.IndexOf('$verdict = Test-Verdict', $gateStart)
    $gateText=$invokeText.Substring($gateStart,$gateEnd-$gateStart)
    $library=(Resolve-Path "$PSScriptRoot/../gauntlet-review/scripts/lib.ps1").Path.Replace("'","''")
    foreach($tokens in @(493300,493301)) {
        $state=Join-Path $root ("usage-$tokens")
        [void][IO.Directory]::CreateDirectory($state)
        $code=". '$library'; `$referenceCapacity=@{maximum_input_tokens=493300}; `$usage=@{InputTokens=$tokens}; `$StateDir='$($state.Replace("'","''"))'; `$Round=2; `$attempt=1; " + $gateText + '; exit 0'
        $run=Invoke-BoundedProcess -FileName ([Environment]::ProcessPath) -ArgList @('-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))) -TimeoutSec 20 -RequireProcessTreeRetirement
        Assert-Eq $run.ExitCode $(if($tokens -eq 493300){0}else{10}) "actual usage acceptance at $tokens tokens"
        Assert-Eq @(Get-ChildItem $state -Filter '*verdict*').Count 0 'usage check never writes a canonical verdict'
    }
} finally {
    ${function:Get-BoundReviewProfile} = $originalProfile
    Remove-Variable fixtureSkillRoot,fixtureProfileReader -Scope Script -ErrorAction SilentlyContinue
    # Delete only the unique temporary fixture directory created above.
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-TestResult
