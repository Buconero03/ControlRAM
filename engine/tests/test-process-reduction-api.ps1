$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'windows-model.ps1')
. (Join-Path $root 'process-reduction-api.ps1')
if(!('AmeHub.ReportTail' -as [type])){Add-Type -Path (Join-Path $root 'src/hub-runtime.cs')}
$script:count=0
function Check($ok,[string]$message){$script:count++;if(!$ok){throw $message}}
function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Check $rejected $Message}
$target=[pscustomobject]@{Pid=123;Key='123:456';Path='D:\Apps con spazi\caffe.exe';Name='caffe.exe'}
function Session {
    return @{type='recover_session';engine_revision='R10';single_test=$true;selected=@(@{pid=123;creation_filetime='456'});allowed_images=@($target.Path);observation_target_seconds=300}
}
function Applied-State {
    $s=New-AmeReductionState $target;Update-AmeReductionState $s (Session)
    Update-AmeReductionState $s @{type='recover_intent';pid=123;elapsed_seconds=60}
    Update-AmeReductionState $s @{type='recover_applied';pid=123;elapsed_seconds=60}
    return $s
}
function Feedback([double]$after=100MB,[double]$seconds=0) {
    return @{type='recover_feedback';pid=123;creation_filetime='456';elapsed_seconds=60+$seconds;seconds_after_action=$seconds;private_resident_before_bytes=300MB;private_resident_after_bytes=$after;private_commit_delta_bytes=0}
}
function Assessment([string]$Reason='resident_reduction_retained_5m') {
    return @{type='recover_assessed';pid=123;creation_filetime='456';image_path=$target.Path;elapsed_seconds=360;seconds_after_action=300;reason=$Reason;remaining_private_resident_reduction_bytes=200MB;minimum_private_resident_reduction_last_60s_bytes=180MB}
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ame process api '+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try{
    $info=New-AmeReductionStartInfo -Root $root -Targets @($target) -Report (Join-Path $temp 'report con spazi.jsonl') -StopFile (Join-Path $temp 'report.stop')
    Check (!$info.UseShellExecute -and $info.CreateNoWindow -and $info.RedirectStandardOutput -and $info.RedirectStandardError) 'Unsafe process start'
    Check ($info.Arguments -like '*"--recover-test"*"123:456"*"D:\Apps con spazi\caffe.exe"*') 'Identity/path not represented'
    foreach($key in @('0:1','4:1','123:0','4294967296:1','123:18446744073709551616','123:456 --observe')){
        $bad=[pscustomobject]@{Key=$key;Path=$target.Path};Reject {New-AmeReductionStartInfo -Root $root -Targets @($bad) -Report x -StopFile y} 'Invalid identity accepted'
    }
    foreach($image in @('app.exe','D:\Apps\bad".exe',"D:\Apps\bad`n.exe",'D:\Apps\')){
        $bad=[pscustomobject]@{Key=$target.Key;Path=$image};Reject {New-AmeReductionStartInfo -Root $root -Targets @($bad) -Report x -StopFile y} 'Invalid image accepted'
    }
    Reject {New-AmeReductionStartInfo -Root $root -Targets @($target,$target) -Report x -StopFile y} 'Single API accepts multiple targets'
    Reject {New-AmeReductionStartInfo -Root $root -Targets @($target) -Seconds 181 -Report x -StopFile y} 'Single API unbounded action window'
    $s=New-AmeReductionState $target;Reject {Update-AmeReductionState $s @{type='recover_applied';pid=123}} 'Action before session verified'
    foreach($wrong in @('pid','creation','image','engine','single')){
        $s=New-AmeReductionState $target;$e=Session
        switch($wrong){'pid'{$e.selected[0].pid=124}'creation'{$e.selected[0].creation_filetime='999'}'image'{$e.allowed_images=@('D:\other.exe')}'engine'{$e.engine_revision='R8'}'single'{$e.single_test=$false}}
        Reject {Update-AmeReductionState $s $e} ('Session mismatch accepted: '+$wrong)
    }
    $s=Applied-State;Check ($s.Applied -and $null -eq $s.ResidentDropBytes -and !$s.Assessed) 'Applied falsely means RAM reduced'
    Update-AmeReductionState $s (Feedback);Check ($s.ResidentDropBytes -eq 200MB -and $s.PrivateCommitDeltaBytes -eq 0) 'Resident and commit confused'
    Update-AmeReductionState $s (Feedback 350MB 5);Check ($s.ResidentDropBytes -eq -50MB) 'Signed RAM rebound lost'
    Update-AmeReductionState $s @{type='recover_target';pid=123;creation_filetime='456';elapsed_seconds=65;private_resident_bytes=360MB}
    Check ($s.ResidentDropBytes -eq -60MB -and $s.Message -like '*5 s*') 'Live per-process telemetry did not update visible RAM'
    Update-AmeReductionState $s @{type='recover_activity_warning';pid=123;elapsed_seconds=65;reason='activity_or_fault_increase_stop_further_actions'}
    Update-AmeReductionState $s @{type='recover_usage_warning';pid=123;elapsed_seconds=65;reason='foreground_return_observation_only'}
    Check ($s.Applied -and !$s.Assessed) 'Usage warnings end valid measurement'
    Update-AmeReductionState $s (Feedback 100MB 300);Update-AmeReductionState $s (Assessment)
    $finalText=$s.Message
    Update-AmeReductionState $s @{type='recover_target';pid=123;creation_filetime='456';elapsed_seconds=360;private_resident_bytes=140MB}
    Check ($s.Message -ceq $finalText) 'Final assessment overwritten by same-cycle telemetry'
    Update-AmeReductionState $s @{type='end'};Complete-AmeReductionState $s 0
    Check ($s.Final -and $s.Assessed -and $s.Phase -eq 'assessed' -and !$s.InternalCacheReleaseVerified -and !$s.CausationEstablished -and !$s.ApplicationLatencyMeasured) 'Final result overclaims'
    $s=Applied-State;$e=Assessment;$e.seconds_after_action=60;Reject {Update-AmeReductionState $s $e} 'Early positive accepted'
    $s=Applied-State;$e=Assessment;$e.minimum_private_resident_reduction_last_60s_bytes=[double]::NaN;Reject {Update-AmeReductionState $s $e} 'NaN positive accepted'
    $s=Applied-State;$e=Feedback;$e.private_resident_after_bytes=$null;Reject {Update-AmeReductionState $s $e} 'Missing RAM becomes zero'
    $s=Applied-State;$e=Feedback;$e.creation_filetime='999';Reject {Update-AmeReductionState $s $e} 'PID reuse result accepted'
    $s=Applied-State;Reject {Update-AmeReductionState $s @{type='recover_applied';pid=123}} 'Duplicate action counted'
    $s=Applied-State;Update-AmeReductionState $s @{type='end'};Complete-AmeReductionState $s 0
    Check ($s.Phase -eq 'incomplete' -and !$s.Assessed) 'Missing final assessment called successful'
    $s=New-AmeReductionState $target;Update-AmeReductionState $s (Session);Update-AmeReductionState $s @{type='recover_no_action';pid=123};Update-AmeReductionState $s @{type='end'};Complete-AmeReductionState $s 0
    Check ($s.Phase -eq 'no_action' -and !$s.Applied -and $null -eq $s.ResidentDropBytes) 'No-action outcome fabricated RAM'
    $s=New-AmeReductionState $target;Update-AmeReductionState $s (Session);Update-AmeReductionState $s @{type='recover_intent';pid=123};Update-AmeReductionState $s @{type='end'};Complete-AmeReductionState $s 0
    Check ($s.Phase -eq 'incomplete') 'Unresolved intent called no-action'
    $s=Applied-State;Complete-AmeReductionState $s 1;Check ($s.Phase -eq 'error' -and !$s.Assessed) 'Failed engine reported success'
    # Run the real bounded reader and handler over an incremental report.
    $path=Join-Path $temp 'recover-api.jsonl';$s=New-AmeReductionState $target
    $fake=[pscustomobject]@{HasExited=$false;ExitCode=0}
    $request=[pscustomobject]@{State=$s;Process=$fake;ErrorTask=[pscustomobject]@{IsCompleted=$true;Result=''};Report=$path;StopFile=$path+'.stop';Tail=$null;History=(Join-Path $temp 'history.json');Clock=[Diagnostics.Stopwatch]::StartNew();Closed=$false}
    $events=@((Session),@{type='recover_intent';pid=123;elapsed_seconds=60},@{type='recover_applied';pid=123;elapsed_seconds=60},(Feedback))
    [IO.File]::WriteAllText($path,((@($events|ForEach-Object {$_|ConvertTo-Json -Depth 5 -Compress})) -join "`n")+"`n")
    [void](Get-AmeProcessReduction $request);Check ($s.Applied -and $s.ResidentDropBytes -eq 200MB -and !$s.Final) 'Live controller events not read'
    $negative=Assessment 'rapid_resident_rebound';$negative.seconds_after_action=5;$negative.elapsed_seconds=65
    [IO.File]::AppendAllText($path,($negative|ConvertTo-Json -Depth 5 -Compress)+"`n{`"type`":`"end`"}`n")
    $fake.HasExited=$true;[void](Get-AmeProcessReduction $request)
    Check ($s.Final -and $s.Reason -eq 'rapid_resident_rebound' -and [bool](Get-RecoveryRepeatBlock $request.History $target)) 'Negative outcome not shared with panel history'
    $request.Tail.Dispose();$request.Tail=$null;$request.State=New-AmeReductionState $target;$fake.HasExited=$false
    [IO.File]::WriteAllText($path,"{`"type`":`"recover_session`"")
    [void](Get-AmeProcessReduction $request);Check (!$request.State.SessionVerified -and !$request.State.Applied) 'Partial line parsed as result'
    [IO.File]::AppendAllText($path,"}`n")
    [void](Get-AmeProcessReduction $request);Check ($request.State.Phase -eq 'error' -and (Test-Path $request.StopFile)) 'Invalid session did not request stop'
    $request.Tail.Dispose();$request.Clock.Stop()
    # Actual public starter with a native identity substitute and owned engine substitute.
    $fakeRoot=Join-Path $temp 'root con spazi';[void][IO.Directory]::CreateDirectory((Join-Path $fakeRoot 'build'))
    Copy-Item (Join-Path $root 'process-reduction-api.ps1') (Join-Path $fakeRoot 'process-reduction-api.ps1')
    [IO.File]::WriteAllText((Join-Path $fakeRoot 'build/ame.exe'),'engine fixture')
    @{engine_revision='R10';panel_revision='R22';exe_sha256=(Get-FileHash (Join-Path $fakeRoot 'build/ame.exe')).Hash;support_hashes=@{'process-reduction-api.ps1'=(Get-FileHash (Join-Path $fakeRoot 'process-reduction-api.ps1')).Hash}}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $fakeRoot 'build/windows-validation.json')
    $client=[pscustomobject]@{Calls=0;Refuse=$false}
    $client|Add-Member ScriptMethod Validate {param($key,$path);$this.Calls++;if($this.Refuse){throw 'Changed identity'};if($key -ne '123:456' -or $path -cne 'D:\Apps con spazi\caffe.exe'){throw 'Wrong target'}}
    $connection=[pscustomobject]@{Ready=$true;Client=$client}
    $script:starts=0;$script:ownedEngine=[pscustomobject]@{StartInfo=$null;HasExited=$false;ExitCode=0;Id=234;StandardError=[pscustomobject]@{};Disposed=$false}
    $script:ownedEngine.StandardError|Add-Member ScriptMethod ReadToEndAsync {return [pscustomobject]@{IsCompleted=$true;Result=''}}
    $script:ownedEngine|Add-Member ScriptMethod Start {$script:starts++;return $true}
    $script:ownedEngine|Add-Member ScriptMethod BeginOutputReadLine {}
    $script:ownedEngine|Add-Member ScriptMethod WaitForExit {param($timeout);$this.HasExited=$true;return $true}
    $script:ownedEngine|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    function New-Object([string]$TypeName){if($TypeName -eq 'Diagnostics.Process'){return $script:ownedEngine};return Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName}
    $oldOS=$env:OS
    try{
        $env:OS='Windows_NT'
        $operation=Start-AmeProcessReduction -Target $target -Connection $connection -Root $fakeRoot
        Check ($script:starts -eq 1 -and $client.Calls -eq 2 -and !$operation.State.Applied) 'Public API did not revalidate before engine start'
        Reject {Start-AmeProcessReduction -Target $target -Connection $connection -Root $fakeRoot} 'Concurrent controller accepted'
        Stop-AmeProcessReduction $operation
        Check ((Test-Path $operation.StopFile) -and $operation.State.Cancelled -and !$operation.State.Applied) 'Cancellation mutates target or lacks stop file'
        Close-AmeProcessReduction $operation
        Check ($operation.Closed -and $script:ownedEngine.Disposed -and $operation.State.Phase -eq 'incomplete') 'Owned controller not closed or missing report fabricated'
        $client.Refuse=$true;Reject {Start-AmeProcessReduction -Target $target -Connection $connection -Root $fakeRoot} 'Stale identity dispatched'
        Check ($script:starts -eq 1) 'Rejected identity still started engine'
        $client.Refuse=$false
        [IO.File]::AppendAllText((Join-Path $fakeRoot 'build/ame.exe'),'changed')
        Reject {Start-AmeProcessReduction -Target $target -Connection $connection -Root $fakeRoot} 'Changed engine reused validation'
    }finally{$env:OS=$oldOS;Remove-Item Function:New-Object -ErrorAction SilentlyContinue}
    Write-Host ('PASS '+$script:count+' general process API checks: exact identities, shared GUI arguments, live reader, signed metrics, 5m evidence, warnings, errors and persistent cooldown. Real Windows reduction not executed here.')
}finally{if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}}
