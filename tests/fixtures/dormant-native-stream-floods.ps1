param([Parameter(Mandatory)][string]$RepoRoot,[string]$Source)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
if(-not $Source){$Source=Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1'}
. $Source
function Invoke-FloodWorker {
 param($State,$Arguments)
 $ErrorActionPreference='Continue';$WarningPreference='Continue';$VerbosePreference='Continue';$DebugPreference='Continue';$InformationPreference='Continue';$ProgressPreference='Continue'
 try{
  $payload='x'*512
  for($i=0;$i -lt 64;$i++){
   $State['Emitted']=$i+1
   $channels=if($Arguments.Mode -ceq 'combined'){@('Warning','Verbose','Debug','Information','Progress')}else{@($Arguments.Mode)}
   foreach($channel in $channels){
    switch($channel){
     'Success'{Write-Output $payload}
     'Error'{Write-Error -Exception ([IO.IOException]::new($payload)) -ErrorAction Continue}
     'Warning'{Write-Warning $payload}
     'Verbose'{Write-Verbose $payload -Verbose}
     'Debug'{Write-Debug $payload -Debug}
     'Information'{Write-Information $payload -InformationAction Continue}
     'Progress'{Write-Progress -Activity $payload -Status $payload -PercentComplete ($i%100)}
    }
   }
  }
  $State['Result']=New-ReviewReadOnlyRecord -Values @{Value='must-refuse-flood'}
 }finally{$State['CoreRetired']=$true}
}
foreach($mode in @('Success','Error','Warning','Verbose','Debug','Information','Progress','combined')){
 $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
 $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
 $state['Emitted']=0
 $definitions=Get-ReviewWorkerDefinitions -LibraryDefinition (Get-Command Invoke-ReviewOwnedWork).ScriptBlock
 $definitions['Invoke-FloodWorker']=(Get-Command Invoke-FloodWorker).ScriptBlock
 $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+10L*[Diagnostics.Stopwatch]::Frequency
 $watch=[Diagnostics.Stopwatch]::StartNew()
 $result=Invoke-ReviewOwnedWork -Kind stream_flood -OwnerRegistry $registry -DeadlineTimestamp $deadline -WorkerName Invoke-FloodWorker -Definitions $definitions -Arguments @{Mode=$mode} -State $state
 $owner=$state['OwnedWorkOwner'];$watch.Stop()
 $retained=0
 if($owner['InvokeTask'].IsCompletedSuccessfully -and $null -ne $owner['InvokeTask'].Result){$retained+=$owner['InvokeTask'].Result.Count}
 foreach($channel in @('Error','Warning','Verbose','Debug','Information','Progress')){$retained+=$owner['Pipeline'].Streams.$channel.Count}
 $guard=$owner['StreamGuard']
 Assert-True ($null -ne $result.Failure -and $result.Failure.Code -cin @('owned_stream_limit','owned_unexpected_output')) "$mode actual flooding triggers stable original-worker stream refusal"
 Assert-True (-not $result.Completed -and $null -eq $result.Result -and $state['Emitted'] -lt 64) "$mode original worker stops at admission failure before remaining emissions"
 Assert-True ($retained -eq 0) "$mode raw returned output and diagnostic collections retain no flood records"
 Assert-True ($null -ne $guard) "$mode same original owner retains bounded native guard"
 if($null -ne $guard){
  Assert-True ($guard.TotalAdmittedBytes -le 65536) "$mode aggregate emitted-byte admission stays bounded"
  $channelBounded=$true;foreach($channel in 0..6){$channelBounded=$channelBounded -and $guard.ChannelAdmittedBytes($channel) -le 32768}
  Assert-True $channelBounded "$mode every independent channel admission stays bounded"
  if($mode -ceq 'combined'){
   $individualsBelow=$true;foreach($channel in 1..6){$individualsBelow=$individualsBelow -and $guard.ChannelAdmittedBytes($channel) -lt 32768}
   Assert-True ($individualsBelow -and $guard.TotalAdmittedBytes -gt 32768) 'combined flood triggers aggregate cap with every channel below its own cap'
  }
 }
 Assert-True ($owner['StopRequested'] -is [bool] -and $owner['StopRequested'] -and $null -ne $owner['StopTask']) "$mode same original owner retains its single original pipeline stop task"
 Assert-True (($result.Failure|ConvertTo-Json -Depth 12 -Compress) -notmatch 'xxx|MessageData|StackTrace|Pipeline|Registry') "$mode refusal diagnostics retain no raw worker data or private authority"
 Assert-True ([object]::ReferenceEquals($owner['State'],$state) -and $owner['Deadline'] -eq $deadline -and $watch.Elapsed.TotalSeconds -lt 8) "$mode original state and deadline bound observer"
 [ordered]@{case=$mode;emitted=$state['Emitted'];raw_retained=$retained;retired=$result.Retired;completed=$result.Completed;failure=$(if($result.Failure){$result.Failure.Code}else{$null});guard_present=$null -ne $guard;elapsed_ms=$watch.ElapsedMilliseconds}|ConvertTo-Json -Compress|Write-Output
 $settle=[Diagnostics.Stopwatch]::StartNew()
 while($registry.Count -gt 0 -and $settle.ElapsedMilliseconds -lt 3000){$null=Complete-ReviewOwnedWork -OwnerRegistry $registry;Start-Sleep -Milliseconds 10}
 Assert-Eq $registry.Count 0 "$mode explicit observation physically settles original worker and stop/disposal"
 Assert-True ($null -ne $owner['DisposeTask'] -and $owner['OutputDisposed'] -is [bool] -and $owner['OutputDisposed']) "$mode same original retained disposer closes explicit output collection"
}
function Invoke-BelowLimitStreamWorker {
 param($State,$Arguments)
 try{
  switch($Arguments.Mode){
   'ordinary_error'{Write-Error -Exception ([ComponentModel.Win32Exception]::new(5,'SENSITIVE-ERROR-MESSAGE')) -ErrorAction Continue}
   'ordinary_warning'{Write-Warning 'SENSITIVE-WARNING-MESSAGE'}
   'large_warning'{Write-Warning ('x'*1000000)}
   'information_graph'{Write-Information -MessageData ([byte[]]::new(1000000)) -InformationAction Continue}
  }
  $State['Continued']=$true
  $State['Result']=New-ReviewReadOnlyRecord -Values @{Value='explicit-state-result'}
 }finally{$State['CoreRetired']=$true}
}
foreach($mode in @('ordinary_error','ordinary_warning','large_warning','information_graph')){
 $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
 $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
 $defs=Get-ReviewWorkerDefinitions -LibraryDefinition (Get-Command Invoke-ReviewOwnedWork).ScriptBlock
 $defs['Invoke-BelowLimitStreamWorker']=(Get-Command Invoke-BelowLimitStreamWorker).ScriptBlock
 $result=Invoke-ReviewOwnedWork -Kind bounded_diagnostic -OwnerRegistry $registry -DeadlineTimestamp ([Diagnostics.Stopwatch]::GetTimestamp()+10L*[Diagnostics.Stopwatch]::Frequency) -WorkerName Invoke-BelowLimitStreamWorker -Definitions $defs -Arguments @{Mode=$mode} -State $state
 $owner=$state['OwnedWorkOwner'];$guard=$owner['StreamGuard']
 switch($mode){
  'ordinary_error'{
   Assert-True ($result.Failure.Code -ceq 'owned_error_stream' -and $result.Failure.Cause.Type -ceq 'System.ComponentModel.Win32Exception' -and $result.Failure.Cause.NativeError -eq 5 -and $state['Continued']) 'below-limit actual Win32 error retains its typed code/HResult/native error without stopping later state publication'
   Assert-True ($null -eq $result.Result -and $result.Retired -and -not $result.TimedOut) 'below-limit ordinary error still refuses result independently of physical retirement'
  }
  'ordinary_warning'{Assert-True ($result.Completed -and $result.Retired -and $null -eq $result.Failure -and $result.Result.Value -ceq 'explicit-state-result') 'below-limit discarded warning permits explicit state result without raw diagnostic retention'}
  'large_warning'{Assert-True ($result.Failure.Code -ceq 'owned_stream_limit' -and -not $state.ContainsKey('Continued') -and $guard.TotalAdmittedBytes -eq 0) 'oversized first diagnostic refuses before collection insertion or any admitted payload'}
  'information_graph'{Assert-True ($result.Failure.Code -ceq 'owned_stream_shape' -and -not $state.ContainsKey('Continued') -and $guard.TotalAdmittedBytes -eq 0) 'arbitrary information graph refuses before collection storage or formatting'}
 }
 Assert-True ($owner['Output'].Count -eq 0 -and $owner['Pipeline'].Streams.Warning.Count -eq 0 -and $owner['Pipeline'].Streams.Information.Count -eq 0) "$mode keeps explicit output and diagnostic collections empty"
 $settle=[Diagnostics.Stopwatch]::StartNew()
 while($registry.Count -gt 0 -and $settle.ElapsedMilliseconds -lt 3000){$null=Complete-ReviewOwnedWork -OwnerRegistry $registry;Start-Sleep -Milliseconds 10}
 Assert-Eq $registry.Count 0 "$mode physically settles same worker and explicit output disposer"
}
Assert-True ($null -eq ('GauntletLive.Native' -as [type])) 'all generic stream controls preserve cold native process type'
Write-TestResult
