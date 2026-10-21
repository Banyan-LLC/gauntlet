param([Parameter(Mandatory)][string]$RepoRoot,[string]$Source=(Join-Path $RepoRoot 'gauntlet-review/scripts/dormant-native.ps1'))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'tests/helpers.ps1')
. $Source
$script:OriginalCompletionRecord=(Get-Command New-ReviewReadOnlyRecord).ScriptBlock
$script:CompletionPause=$null
function New-ReviewReadOnlyRecord {
    param([Collections.IDictionary]$Values)
    if($null -ne $script:CompletionPause -and $Values.Contains('Completed') -and $Values['Token'] -ceq $script:CompletionPause.Token -and $script:CompletionPause.Calls -eq 0){
        $script:CompletionPause.Calls++
        $script:CompletionPause.Entered=[Diagnostics.Stopwatch]::GetTimestamp()
        $script:CompletionPause.LockHeld=[Threading.Monitor]::IsEntered($script:CompletionPause.Owner)
        # Existing DTO seam pauses after entry against the same absolute deadline.
        while([Diagnostics.Stopwatch]::GetTimestamp() -le $script:CompletionPause.Deadline){[Threading.Thread]::Sleep(5)}
        [Threading.Thread]::Sleep(10)
        $script:CompletionPause.Exited=[Diagnostics.Stopwatch]::GetTimestamp()
    }
    & $script:OriginalCompletionRecord -Values $Values
}
$records=[Collections.Generic.List[object]]::new()
foreach($case in @('success','earlier_failure','startup_unsettled')){
    $registry=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $owner=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::Ordinal)
    $token='completion-'+$case
    $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+6L*[Diagnostics.Stopwatch]::Frequency
    $settled=$case -cne 'startup_unsettled'
    foreach($pair in @{Kind='completion';Registry=$registry;Token=$token;State=$state;Deadline=$deadline;Abandoned=$false;TimedOut=$false;Submitted=$settled;StartupSettled=$settled;StartupPublishPending=$settled;StartupStage='worker_create';RetirementConfirmed=$false;Pipeline=$null;CreationTask=$null;InvokeTask=$null;DisposeTask=$null;Failure=$null;CleanupFailures=@()}.GetEnumerator()){$owner[$pair.Key]=$pair.Value}
    $state['OwnedWorkOwner']=$owner;$state['Deadline']=$deadline;$state['Abandoned']=$false
    $primary=$null
    if($case -ceq 'earlier_failure'){$primary=New-ReviewTransportFault 'fixture_primary' 'completion_control' $null;$state['Failure']=$primary}
    $creation=Start-ReviewOwnedPipelineCreation -Owner $owner -Bootstrap 'param($state) try{$state["ActionEntered"]=$true;$state["Result"]="original-result"}finally{$state["CoreRetired"]=$true}' -ArgumentList @($state)
    $owner['CreationTask']=$creation
    Assert-True ($creation.Wait(4000) -and $creation.IsCompletedSuccessfully) ($case+': original creation task physically settles')
    $pipeline=$creation.Result;$owner['Pipeline']=$pipeline
    if($settled){
        $invocation=Start-ReviewOwnedPipelineInvocation -Pipeline $pipeline -Owner $owner;$owner['InvokeTask']=$invocation
        Assert-True ($invocation.Wait(1000) -and $invocation.IsCompletedSuccessfully) ($case+': original invocation physically settles')
        $dispose=Start-ReviewPipelineDisposal -Owner $owner -Pipeline $pipeline
        Assert-True ($dispose.Wait(1000) -and $dispose.IsCompletedSuccessfully -and $owner['OutputDisposed']) ($case+': original pipeline and output physically dispose')
    }
    $registry.Add($token,$owner)
    $script:CompletionPause=@{Token=$token;Owner=$owner;Deadline=$deadline;Calls=0;Entered=0L;Exited=0L;LockHeld=$false}
    $snapshot=Complete-ReviewOwnedWork -OwnerRegistry $registry -Token $token
    Assert-True ($script:CompletionPause.Calls -eq 1 -and $script:CompletionPause.Entered -lt $deadline -and $script:CompletionPause.Exited -gt $deadline -and $script:CompletionPause.LockHeld) ($case+': direct completion crosses original clock under original owner lock')
    Assert-True ($snapshot.TimedOut -and -not $snapshot.Completed -and $null -eq $snapshot.Result) ($case+': direct Complete cannot publish late success')
    Assert-True ($owner['Abandoned'] -and $owner['TimedOut'] -and $state['Abandoned'] -and $null -ne $owner['DeadlineFailure']) ($case+': expiry irreversibly latches original owner/state')
    Assert-True ($snapshot.IsReadOnly -and $null -ne $snapshot.Failure -and $snapshot.Failure.IsReadOnly -and $snapshot.CleanupFailures.IsReadOnly) ($case+': failure DTO is immutable')
    if($case -ceq 'earlier_failure'){
        Assert-True ([object]::ReferenceEquals($snapshot.Failure,$primary) -and @($snapshot.CleanupFailures).Count -le 2 -and @($snapshot.CleanupFailures|Where-Object {$_.Code -ceq 'owned_deadline'}).Count -eq 1) 'earlier primary identity survives with one bounded deadline secondary'
    }else{Assert-True ($null -ne $snapshot.Failure -and $snapshot.Failure.Code -ceq 'owned_deadline' -and @($snapshot.CleanupFailures).Count -eq 0) ($case+': deadline is sole cause')}
    $deadlineFailure=$owner['DeadlineFailure']
    if($settled){
        Assert-True ($snapshot.Retired -and $registry.Count -eq 0 -and $owner['RetirementConfirmed']) ($case+': physical retirement remains independent of failed acceptance')
    }else{
        Assert-True (-not $snapshot.Retired -and $registry.Count -eq 1) 'unsettled startup retains original owner'
        $owner['StartupSettled']=$true;$owner['StartupPublishPending']=$true
        $late=$null;$watch=[Diagnostics.Stopwatch]::StartNew()
        while($registry.Count -gt 0 -and $watch.ElapsedMilliseconds -lt 3000){$next=Complete-ReviewOwnedWork -OwnerRegistry $registry -Token $token;if($null -ne $next){$late=$next};[Threading.Thread]::Sleep(5)}
        Assert-True ($registry.Count -eq 0 -and $late.Retired -and $owner['DisposeTask'].IsCompletedSuccessfully -and $null -eq $owner['Output']) 'late original unused pipeline physically retires with no output ever allocated'
        Assert-True ($late.TimedOut -and -not $late.Completed -and $null -eq $late.Result -and [object]::ReferenceEquals($late.Failure,$snapshot.Failure) -and [object]::ReferenceEquals($deadlineFailure,$owner['DeadlineFailure'])) 'late retirement cannot rescue acceptance or replace deadline cause'
    }
    Assert-True ($snapshot.TimedOut -and -not $snapshot.Completed -and $null -eq $snapshot.Result) ($case+': original immutable failure stays failed')
    $records.Add(@{case=$case;lock_held=$script:CompletionPause.LockHeld;entered_before=($script:CompletionPause.Entered -lt $deadline);exited_after=($script:CompletionPause.Exited -gt $deadline);Completed=$snapshot.Completed;NoResult=($null -eq $snapshot.Result);TimedOut=$snapshot.TimedOut;Retired=$owner['RetirementConfirmed'];RegistryCount=$registry.Count})
    $script:CompletionPause=$null
}
Write-Output ('COMPLETION_PUBLICATION_CONTROL='+($records|ConvertTo-Json -Compress))
Write-TestResult
