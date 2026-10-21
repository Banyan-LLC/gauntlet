param([Parameter(Mandatory)][string]$Source)
$ErrorActionPreference='Stop'
$sourceHash=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
. $Source
Initialize-LiveGateNative
$checks=0;$failures=0
function Check([bool]$Condition,[string]$Name){
    $script:checks++
    if($Condition){Write-Output ('PASS '+$Name)}else{$script:failures++;Write-Output ('FAIL '+$Name)}
}
$cases=[Collections.Generic.List[object]]::new()
function Add-Case([string]$Name,[int]$Prefix,[byte[]]$Bytes,[string]$Decoded,[string]$Tail='tail'){
    $prefixText='x'*$Prefix
    $payload=[byte[]]([Text.Encoding]::ASCII.GetBytes($prefixText)+$Bytes+[Text.Encoding]::ASCII.GetBytes($Tail))
    $cases.Add(@{Name=$Name;Bytes=$payload;Expected=$prefixText+$Decoded+$Tail})
}
# The expected Unicode scalars and replacement characters are literal test data.
# Every possible internal split of a 2-, 3-, or 4-byte scalar crosses byte 4096.
foreach($scalar in @(
    @{Name='two';Bytes=[byte[]]@(0xc2,0xa2);Text=[string][char]0x00a2},
    @{Name='three';Bytes=[byte[]]@(0xe2,0x82,0xac);Text=[string][char]0x20ac},
    @{Name='four';Bytes=[byte[]]@(0xf0,0x9f,0x98,0x80);Text=[char]::ConvertFromUtf32(0x1f600)}
)){
    for($split=1;$split -lt $scalar.Bytes.Length;$split++){
        Add-Case ($scalar.Name+'-split-'+$split) (4096-$split) $scalar.Bytes $scalar.Text
    }
    Add-Case ($scalar.Name+'-aligned') 4096 $scalar.Bytes $scalar.Text
}
Add-Case 'ascii' 4095 ([byte[]]@(0x41)) 'A'
Add-Case 'embedded-nul' 4095 ([byte[]]@(0x00)) ([string][char]0)
Add-Case 'empty' 0 ([byte[]]@()) '' ''
$replacement=[string][char]0xfffd
foreach($partial in @(
    @{Name='two-1';Bytes=[byte[]]@(0xc2)},
    @{Name='three-1';Bytes=[byte[]]@(0xe2)},
    @{Name='three-2';Bytes=[byte[]]@(0xe2,0x82)},
    @{Name='four-1';Bytes=[byte[]]@(0xf0)},
    @{Name='four-2';Bytes=[byte[]]@(0xf0,0x9f)},
    @{Name='four-3';Bytes=[byte[]]@(0xf0,0x9f,0x98)}
)){
    Add-Case ($partial.Name+'-flush-full') (4096-$partial.Bytes.Length) $partial.Bytes $replacement ''
    Add-Case ($partial.Name+'-flush-partial') 4095 $partial.Bytes $replacement ''
}
Add-Case 'malformed-three' 4095 ([byte[]]@(0xe2,0x28,0xa1)) ($replacement+'('+$replacement)
Add-Case 'malformed-four' 4094 ([byte[]]@(0xf0,0x9f,0x28,0x80)) ($replacement+'('+$replacement)
Add-Case 'stray-continuations' 4095 ([byte[]]@(0x80,0xbf)) ($replacement+$replacement)
$native='GauntletLive.Native' -as [type]
$flags=[Reflection.BindingFlags]'NonPublic,Static'
$custodyType=$native.GetNestedType('RunCustody',[Reflection.BindingFlags]'NonPublic')
$budgetType=$native.GetNestedType('CaptureBudget',[Reflection.BindingFlags]'NonPublic')
$capture=$native.GetMethod('Capture',$flags)
function Check-Text([string]$Actual,[string]$Expected,[string]$Name){
    Check ([string]::Equals($Actual,$Expected,[StringComparison]::Ordinal)) ($Name+' exact ordinal text')
    Check ($Actual.Length -eq $Expected.Length) ($Name+' exact UTF16 length')
    $actualBytes=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Actual))
    $expectedBytes=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Expected))
    Check ([string]::Equals($actualBytes,$expectedBytes,[StringComparison]::Ordinal)) ($Name+' exact UTF8 bytes')
}
foreach($case in $cases){
    $budget=[Activator]::CreateInstance($budgetType,[object[]]@([Activator]::CreateInstance($custodyType,$true)))
    $stream=[IO.MemoryStream]::new($case.Bytes,$false)
    try{
        $task=$capture.Invoke($null,[object[]]@($stream,$budget))
        $actual=$task.GetAwaiter().GetResult()
        Check-Text $actual $case.Expected ($case.Name+' direct')
        $peak=$budgetType.GetField('PeakRetained').GetValue($budget)
        $retained=$budgetType.GetField('retained',[Reflection.BindingFlags]'NonPublic,Instance').GetValue($budget)
        Check ($peak -le 16777216 -and $retained -eq (131072+2*$actual.Length)) ($case.Name+' direct bounded storage and scratch release')
    }catch{
        Check $false ($case.Name+' direct decode throws: '+$_.Exception.GetBaseException().Message)
    }finally{$stream.Dispose()}
    # Emit raw bytes through both real pipes; no console encoding or newline changes.
    $base64=[Convert]::ToBase64String($case.Bytes)
    $command='$bytes=[Convert]::FromBase64String('''+$base64+''');[Console]::OpenStandardOutput().Write($bytes,0,$bytes.Length);[Console]::OpenStandardError().Write($bytes,0,$bytes.Length)'
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=[Environment]::ProcessPath
    $start.WorkingDirectory=[IO.Path]::GetDirectoryName($Source)
    foreach($argument in @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))){
        $start.ArgumentList.Add($argument)
    }
    $result=[GauntletLive.Native]::RunMilliseconds($start,'',10000)
    Check ($result.ExitCode -eq 0 -and -not $result.StartFailed -and -not $result.TimedOut -and $result.ProcessTreeRetired -and $null -eq $result.ErrorMessage -and $null -eq $result.Failure -and $result.CleanupFailures.Count -eq 0) ($case.Name+' actual child succeeds and tree retires')
    Check-Text $result.Stdout $case.Expected ($case.Name+' real stdout')
    Check-Text $result.Stderr $case.Expected ($case.Name+' real stderr')
}
if((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -cne $sourceHash){throw 'Candidate source changed during UTF8 regression'}
@{checks=$checks;failures=$failures;cases=$cases.Count;runtime=$PSVersionTable.PSVersion.ToString();dotnet=[Environment]::Version.ToString();source_sha256=$sourceHash.ToLowerInvariant()}|ConvertTo-Json -Compress
if($failures){exit 1}
