param([string]$HelperPath="$PSScriptRoot/dormant-scratch-helper.ps1")
$ErrorActionPreference='Stop'
$helper=[IO.File]::ReadAllText($HelperPath)
$marker="$"+"source=@'"
$start=$helper.IndexOf($marker)+$marker.Length
$end=$helper.IndexOf("'@",$start,[StringComparison]::Ordinal)
if($start -lt $marker.Length -or $end -lt $start){throw 'Embedded helper source unavailable'}
$source=$helper.Substring($start,$end-$start)
$originalSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source))).ToLowerInvariant()
$oldBody='void Run(Action action,bool cleanup=false){Start(action,cleanup);Wait();}'
$newBody='void Run(Action<Operation> action,bool cleanup=false){var operation=Start(action,cleanup);Wait(operation);}'
if($source.Contains($oldBody)){
    $source=$source.Replace($oldBody,'void Run(Action action,bool cleanup=false){Start(action,cleanup);R1ProposalCases.AfterStart(this,cleanup);Wait();}')
    $binding='submitted-old-Run'
}elseif($source.Contains($newBody)){
    $source=$source.Replace($newBody,'void Run(Action<Operation> action,bool cleanup=false){var operation=Start(action,cleanup);R1ProposalCases.AfterStart(this,cleanup);Wait(operation);}')
    $binding='captured-operation-Run'
}else{throw 'Driver requires one of the two exact inspected Run bodies; refusing unreviewed source instrumentation'}
$instrumentedSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source))).ToLowerInvariant()
$source=$source.Replace('__IDENTITY__',$instrumentedSha)
[ordered]@{kind='SCRATCH_LIFECYCLE_REGRESSION_WITH_EXPLICIT_TEST_SCHEDULING_BARRIER';binding=$binding;original_embedded_sha256=$originalSha;instrumented_embedded_sha256=$instrumentedSha;instrumentation='one barrier after Start in Run; no result/task/exception/native substitution';runtime=$PSVersionTable.PSVersion.ToString();dotnet=[Environment]::Version.ToString();executable=[Environment]::ProcessPath}|ConvertTo-Json -Compress|Write-Output
Add-Type -TypeDefinition ($source+[IO.File]::ReadAllText("$PSScriptRoot/dormant-scratch-lifecycle.cs")) -ErrorAction Stop
exit [GauntletFixtureScratch.R1ProposalCases]::Run()
