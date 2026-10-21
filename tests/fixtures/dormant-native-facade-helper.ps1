# Shared source-only assertions for the public facade deadline fixtures.
function Get-FacadeNativeScalars($Actual){
 @{ExitCode=$Actual.ExitCode;StartFailed=$Actual.StartFailed;TimedOut=$Actual.TimedOut;ErrorMessage=$Actual.ErrorMessage;StderrText=$Actual.Stderr;ProcessTreeRetired=$Actual.ProcessTreeRetired}
}
function Test-FacadeNativeSix($Receipt,$Scalars){
 if($null -eq $Receipt -or $null -eq $Scalars -or -not $Receipt.IsReadOnly -or $Receipt.Keys.Count -ne 6){return $false}
 $same=$Receipt.ExitCode -is [int] -and $Receipt.StartFailed -is [bool] -and $Receipt.TimedOut -is [bool] -and $Receipt.ProcessTreeRetired -is [bool] -and $Receipt.StderrText -is [string] -and ($null -eq $Receipt.ErrorMessage -or $Receipt.ErrorMessage -is [string])
 foreach($key in $Scalars.Keys){$same=$same -and $Receipt.ContainsKey($key) -and [object]::Equals($Receipt[$key],$Scalars[$key])}
 return $same
}
function Test-FacadeFlatFault($Projected,$Original){
 if($null -eq $Projected -or $null -eq $Original){return $false}
 $cause=if($Original -is [Collections.IDictionary] -and $Original.Keys -ccontains 'Cause'){$Original['Cause']}else{$Original}
 $type=if($null -ne $cause){$cause.Type}else{$null}
 $hresult=if($null -ne $cause){$cause.HResult}else{$null}
 $nativeError=if($null -ne $cause){$cause.NativeError}else{$null}
 return $Projected.Code -ceq $Original.Code -and $Projected.Stage -ceq $Original.Stage -and [object]::Equals($Projected.Type,$type) -and [object]::Equals($Projected.HResult,$hresult) -and [object]::Equals($Projected.NativeError,$nativeError)
}
function Test-FacadeFlatLedger($Result){
 if($null -eq $Result -or -not $Result.IsReadOnly -or -not $Result.CleanupFailures.IsReadOnly -or $Result.CleanupFailures.Count -gt 2){return $false}
 foreach($fault in @($Result.Failure)+@($Result.CleanupFailures)){
  if($null -eq $fault -or -not $fault.IsReadOnly -or $fault.Keys.Count -ne 5){return $false}
  foreach($key in @('Code','Stage','Type','HResult','NativeError')){if(-not $fault.ContainsKey($key)){return $false}}
 }
 return $true
}
