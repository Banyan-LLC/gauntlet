param([string]$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
$fixture=Join-Path $RepoRoot 'tests/fixtures/dormant-native-real.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($fixture,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Observer fixture must parse'}
$definition=@($ast.FindAll({param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq 'Test-RealOriginalDescendantAlive'},$false))
if($definition.Count -ne 1){throw 'Exactly one real observer definition required'}
. ([scriptblock]::Create($definition[0].Extent.Text))
$original=[datetime]::Parse('2026-10-19T12:00:00.0000000Z',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
$expected=$original.ToUniversalTime().ToString('o')
$cases=@(
 @{Name='gone_before_lookup';Lookup='gone';Exited=@();Start=$original;Expected=$false;Disposed=0;Starts=0},
 @{Name='lookup_access_denied';Lookup='denied';Exited=@();Start=$original;Error='denied';Disposed=0;Starts=0},
 @{Name='lookup_unknown';Lookup='unknown';Exited=@();Start=$original;Error='unknown';Disposed=0;Starts=0},
 @{Name='exit_before_start';Exited=@($true);Start=$original;Expected=$false;Disposed=1;Starts=0},
 @{Name='null_start_after_exit';Exited=@($false,$true);Start=$null;Expected=$false;Disposed=1;Starts=1},
 @{Name='throw_start_after_exit';Exited=@($false,$true);Start='invalid';Expected=$false;Disposed=1;Starts=1},
 @{Name='exit_after_start';Exited=@($false,$true);Start=$original;Expected=$false;Disposed=1;Starts=1},
 @{Name='live_original';Exited=@($false,$false);Start=$original;Expected=$true;Disposed=1;Starts=1},
 @{Name='pid_reuse';Exited=@($false,$false);Start=$original.AddSeconds(1);Expected=$false;Disposed=1;Starts=1},
 @{Name='null_start_live';Exited=@($false,$false);Start=$null;Error='Live process';Disposed=1;Starts=1},
 @{Name='invalid_start_live';Exited=@($false,$false);Start='invalid';Error='start-invalid';Disposed=1;Starts=1},
 @{Name='start_access_denied';Exited=@($false,$true);Start='denied';Error='denied';Disposed=1;Starts=1},
 @{Name='start_unknown';Exited=@($false,$true);Start='unknown';Error='unknown';Disposed=1;Starts=1},
 @{Name='exit_access_denied';Exited=@('denied');Start=$original;Error='denied';Disposed=1;Starts=0},
 @{Name='exit_unknown';Exited=@('unknown');Start=$original;Error='unknown';Disposed=1;Starts=0},
 @{Name='lookup_null';Lookup='null';Exited=@();Start=$original;Error='no observation';Disposed=0;Starts=0},
 @{Name='exit_null';Exited=@($null);Start=$original;Error='Boolean';Disposed=1;Starts=0},
 @{Name='exit_after_start_null';Exited=@($false,$null);Start=$original;Error='Boolean';Disposed=1;Starts=1},
 @{Name='exit_after_start_denied';Exited=@($false,'denied');Start=$original;Error='denied';Disposed=1;Starts=1},
 @{Name='exit_after_start_unknown';Exited=@($false,'unknown');Start=$original;Error='unknown';Disposed=1;Starts=1},
 @{Name='exit_invalid_scalar';Exited=@(17);Start=$original;Error='Boolean';Disposed=1;Starts=0},
 @{Name='start_invalid_scalar';Exited=@($false);Start=17;Error='DateTime';Disposed=1;Starts=1},
 @{Name='disposal_failure';Exited=@($false,$false);Start=$original;DisposeFailure=$true;Error='cleanup failed';Disposed=1;Starts=1},
 @{Name='primary_and_disposal';Exited=@($false);Start='denied';DisposeFailure=$true;Error='denied';Disposed=1;Starts=1}
)
foreach($case in $cases){
 $script:observation=@{Case=$case;Disposed=0;Starts=0;ExitIndex=0}
 $caught=$null;$actual=$null
 try{
  $actual=Test-RealOriginalDescendantAlive -ProcessId 1234 -StartedUtc $expected -Lookup {
   param($Id)
   if($Id -ne 1234){throw 'Wrong original PID'}
   switch($script:observation.Case.Lookup){
    null{return $null}
    gone{throw [ArgumentException]::new('known missing process')}
    denied{throw [ComponentModel.Win32Exception]::new(5,'denied')}
    unknown{throw [IO.IOException]::new('unknown')}
   }
   [pscustomobject]@{OriginalProcess=$true}
  } -ReadStart {
   param($Observed)
   $script:observation.Starts++
   $value=$script:observation.Case.Start
   if($value -is [string]){
    switch($value){
     invalid{throw [InvalidOperationException]::new('start-invalid')}
     denied{throw [ComponentModel.Win32Exception]::new(5,'denied')}
     unknown{throw [IO.IOException]::new('unknown')}
    }
   }
   return $value
  } -ReadExited {
   param($Observed)
   $index=$script:observation.ExitIndex;$script:observation.ExitIndex++
   $values=$script:observation.Case.Exited
   if($index -ge $values.Count){throw 'Unexpected extra exit lookup'}
   $value=$values[$index]
   if($value -is [string]){
    if($value -ceq 'denied'){throw [ComponentModel.Win32Exception]::new(5,'denied')}
    throw [IO.IOException]::new('unknown')
   }
   return $value
  } -Dispose {
   param($Observed)
   $script:observation.Disposed++
   if($script:observation.Case.DisposeFailure){throw [IO.IOException]::new('dispose-secondary')}
  }
 }catch{$caught=$_}
 if($case.ContainsKey('Error')){
  Assert-True ($null -ne $caught -and $caught.Exception.ToString().Contains($case.Error)) ($case.Name+' fails closed with original error')
 }else{
  Assert-True ($null -eq $caught -and $actual -is [bool] -and $actual -eq $case.Expected) ($case.Name+' retains exact original identity/exit result')
 }
 Assert-Eq $script:observation.Disposed $case.Disposed ($case.Name+' disposes every acquired observation exactly once')
 Assert-Eq $script:observation.Starts $case.Starts ($case.Name+' reads start only within admitted observation')
 if($case.Name -ceq 'primary_and_disposal'){
  Assert-True ($caught.Exception -is [ComponentModel.Win32Exception] -and $caught.Exception.NativeErrorCode -eq 5 -and @($caught.Exception.Data['DormantFixtureCleanupFailures']).Count -eq 1 -and $caught.Exception.Data['DormantFixtureCleanupFailures'][0].Message -ceq 'dispose-secondary') 'independent disposal failure appends without replacing original access denial'
 }
}
foreach($invalidId in @(0,-1)){
 $script:invalidLookupCalls=0;$caught=$null
 try{Test-RealOriginalDescendantAlive -ProcessId $invalidId -StartedUtc $expected -Lookup {$script:invalidLookupCalls++;throw [ArgumentException]::new('cannot classify invalid PID as absence')}}catch{$caught=$_}
 Assert-True ($null -ne $caught -and $caught.Exception -is [ArgumentOutOfRangeException] -and $script:invalidLookupCalls -eq 0) 'nonpositive PID fails before known-absence lookup classification'
}
Write-TestResult
