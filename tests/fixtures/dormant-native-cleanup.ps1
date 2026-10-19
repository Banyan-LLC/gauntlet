# Fixture cleanup preservation v1: primary and independent cleanup errors.
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
function Invoke-HeldCleanupFailure {
    param([string]$Path)
    $handle=$null
    $fixturePrimary0=$null
try {
try{
        $handle=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        throw [IO.IOException]::new('original fixture primary')
    }
catch{throw}
}catch{$fixturePrimary0=$_;throw}finally{
$fixtureCleanup0=[Collections.Generic.List[Exception]]::new()
try{
[IO.File]::Delete($Path)
}catch{$fixtureCleanup0.Add($_.Exception)}
try{
if($null -ne $handle){$handle.Dispose()}
}catch{$fixtureCleanup0.Add($_.Exception)}
if($fixtureCleanup0.Count -gt 0){
 if($null -ne $fixturePrimary0){
  $previous=@();if($fixturePrimary0.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary0.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary0.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup0.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup0.ToArray())}
}
}
}
function Invoke-PartialSetupFailure {
    param([string]$PartialPath,[string]$HeldPath)
    $fixturePrimary1=$null
try {
try{
        [IO.File]::WriteAllText($PartialPath,'partial actual setup')
        [IO.File]::WriteAllText($HeldPath,'blocked actual setup')
    }
catch{throw}
}catch{$fixturePrimary1=$_;throw}finally{
$fixtureCleanup1=[Collections.Generic.List[Exception]]::new()
try{
if([IO.File]::Exists($PartialPath)){[IO.File]::Delete($PartialPath)}
}catch{$fixtureCleanup1.Add($_.Exception)}
try{
[IO.File]::Delete($HeldPath)
}catch{$fixtureCleanup1.Add($_.Exception)}
if($fixtureCleanup1.Count -gt 0){
 if($null -ne $fixturePrimary1){
  $previous=@();if($fixturePrimary1.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary1.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary1.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup1.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup1.ToArray())}
}
}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('dormant-fixture-cleanup-'+[guid]::NewGuid().ToString('n'))
$path=Join-Path $root 'held.txt';$partial=Join-Path $root 'partial.txt'
$handle=$null
$fixturePrimary2=$null
try {
try{
    [void][IO.Directory]::CreateDirectory($root)
    [IO.File]::WriteAllText($path,'held actual fixture')
    $failure=$null
    try{Invoke-HeldCleanupFailure -Path $path}catch{$failure=$_.Exception}
    Assert-True ($null -ne $failure -and $failure.Message -ceq 'original fixture primary' -and $failure -is [IO.IOException]) 'real held-share cleanup refusal never replaces original escaping exception'
    $secondary=@($failure.Data['DormantFixtureCleanupFailures'])
    Assert-True ($secondary.Count -eq 1 -and $secondary[0].GetBaseException() -is [IO.IOException]) 'actual held deletion error remains independent cleanup evidence'
    $handle=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    Assert-True ($null -ne $handle) 'later independent cleanup statement physically releases original held handle'
    $failure=$null
    try{Invoke-PartialSetupFailure -PartialPath $partial -HeldPath $path}catch{$failure=$_.Exception}
    Assert-True ($null -ne $failure -and $failure.GetBaseException() -is [IO.IOException] -and $failure.Data.Contains('DormantFixtureCleanupFailures')) 'actual partial setup IO refusal remains primary when separate cleanup IO also fails'
    Assert-True (-not [IO.File]::Exists($partial)) 'partial setup cleanup still removes its original created leaf before later independent refusal'
    $secondary=@($failure.Data['DormantFixtureCleanupFailures'])
    Assert-True ($secondary.Count -eq 1 -and $secondary[0].GetBaseException() -is [IO.IOException]) 'partial setup preserves independent actual held-share cleanup cause'
}
catch{throw}
}catch{$fixturePrimary2=$_;throw}finally{
$fixtureCleanup2=[Collections.Generic.List[Exception]]::new()
try{
if($null -ne $handle){$handle.Dispose()}
}catch{$fixtureCleanup2.Add($_.Exception)}
try{
if([IO.File]::Exists($path)){[IO.File]::Delete($path)}
}catch{$fixtureCleanup2.Add($_.Exception)}
try{
if([IO.File]::Exists($partial)){[IO.File]::Delete($partial)}
}catch{$fixtureCleanup2.Add($_.Exception)}
try{
if([IO.Directory]::Exists($root)){[IO.Directory]::Delete($root,$false)}
}catch{$fixtureCleanup2.Add($_.Exception)}
if($fixtureCleanup2.Count -gt 0){
 if($null -ne $fixturePrimary2){
  $previous=@();if($fixturePrimary2.Exception.Data.Contains('DormantFixtureCleanupFailures')){$previous=@($fixturePrimary2.Exception.Data['DormantFixtureCleanupFailures'])}
  $fixturePrimary2.Exception.Data['DormantFixtureCleanupFailures']=[Array]::AsReadOnly([object[]]@($previous+$fixtureCleanup2.ToArray()))
 }else{throw [AggregateException]::new('Fixture cleanup failed',[Exception[]]$fixtureCleanup2.ToArray())}
}
}
Write-TestResult
