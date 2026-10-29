$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'agent-model.ps1')
. (Join-Path $root 'agent-state.ps1')
. (Join-Path $root 'agent-runtime.ps1')
$script:checks=0
function Assert($ok,[string]$message){$script:checks++;if(!$ok){throw $message}}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed $Message}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ame automatic '+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$config=Get-AgentConfig (Join-Path $root 'agent-config.json')
function Reading([double]$PrivateMiB=1000,[double]$OwnMiB=100){
    return [pscustomobject]@{Complete=$true;AppPrivateBytes=$PrivateMiB*1MB;OwnPrivateBytes=$OwnMiB*1MB;AppCommitBytes=1500MB;AvailableBytes=2GB;TotalBytes=16GB;AppProcesses=3;IdentityKey='a';CounterCoverageComplete=$true;CpuPercent=1;PageFaultsPerSecond=1;IoReadBytesPerSecond=0}
}
function Ready-State {
    $state=New-AgentState $config
    $sample=[pscustomobject]@{type='sample';physical_total_bytes=16GB;physical_available_bytes=1GB;process_snapshot_complete=$true;processes=@()}
    foreach($at in @(0,10,20,30)){Update-AgentTelemetry $state $sample $at $at}
    $state.Profiles[1]=@{Ready=$true;AutoCapable=$true;Truncated=$false;Seen=30;Browser='Chrome';Session=[guid]::NewGuid().ToString();LastSequence=1;Tabs=@([pscustomobject]@{id=42;revision=[guid]::NewGuid().ToString();host='example.org';title='Example';auto_allowed=$true;blocked='';discarded=$false;lastAccessed=[DateTimeOffset]::UtcNow.AddMinutes(-20).ToUnixTimeMilliseconds()})}
    return $state
}
function Reset-Runtime {
    $script:agent=Ready-State;$script:agentDirectory=$temp;$script:agentRunId=[guid]::NewGuid().ToString();$script:agentProcessId=$PID;$script:agentCreation='1'
    $script:agentBrowserConfig=Get-Content (Join-Path $root 'browser/config.json') -Raw|ConvertFrom-Json
    $script:agentBridge=[pscustomobject]@{Sent=(New-Object Collections.ArrayList);Allow=$true;Entries=@();Disconnected=(New-Object Collections.ArrayList)}
    $script:agentBridge|Add-Member ScriptMethod Send {param($connection,$json);[void]$this.Sent.Add(@{connection=$connection;message=($json|ConvertFrom-Json)});return $this.Allow}
    $script:agentBridge|Add-Member ScriptMethod Drain {return $this.Entries}
    $script:agentBridge|Add-Member ScriptMethod Disconnect {param($connection);[void]$this.Disconnected.Add($connection)}
}
try{
    Assert ($config.observation_seconds -eq 300 -and $config.minimum_inactive_minutes -ge 15) 'Unsafe defaults'
    $bad=Join-Path $temp 'bad.json';$copy=$config|ConvertTo-Json|ConvertFrom-Json;$copy.minimum_inactive_minutes=1
    Write-AgentJson $bad $copy;Reject {Get-AgentConfig $bad} 'Invalid inactivity accepted'
    Assert (!(Test-AgentHost 'EXAMPLE.ORG') -and !(Test-AgentHost 'a..org') -and !(Test-AgentHost '::1')) 'Invalid hosts accepted'
    $s=Ready-State;$epoch=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Assert ($null -ne (Get-AgentCandidate $s 30 $epoch)) 'Eligible authorized site not selected'
    foreach($gate in @('Ready','AutoCapable','Truncated')){
        $s=Ready-State;$s.Profiles[1][$gate]=($gate -eq 'Truncated');Assert ($null -eq (Get-AgentCandidate $s 30 $epoch)) ('Gate bypass: '+$gate)
    }
    foreach($field in @('auto_allowed','blocked','discarded','lastAccessed')){
        $s=Ready-State;$s.Profiles[1].Tabs[0].$field=switch($field){'auto_allowed'{$false}'blocked'{'protected'}'discarded'{$true}'lastAccessed'{$null}}
        Assert ($null -eq (Get-AgentCandidate $s 30 $epoch)) ('Tab gate bypass: '+$field)
    }
    $s=Ready-State;Assert ($null -eq (Get-AgentCandidate $s 39 $epoch)) 'Stale native telemetry accepted'
    $s=Ready-State;$s.Profiles[1].Seen=0;Assert ($null -eq (Get-AgentCandidate $s 30 $epoch)) 'Stale browser inventory accepted'
    $s=Ready-State;$s.InventoryAt=0;Assert ($null -eq (Get-AgentCandidate $s 30 $epoch)) 'Stale complete inventory accepted'
    $s=Ready-State;$s.HistoryFailure='corrupt';Assert ($null -eq (Get-AgentCandidate $s 30 $epoch)) 'Corrupt history permits action'
    $s=Ready-State;$sample=@{type='sample';physical_total_bytes=16GB;physical_available_bytes=1GB;process_snapshot_complete=$true;processes=@()}
    Update-AgentTelemetry $s $sample 50 50;Assert ($s.PressureSince -eq 50) 'Gap retained old pressure period'
    Update-AgentTelemetry $s $sample 51 70;Assert ($s.LastTelemetry.At -eq 50) 'Buffered old telemetry treated fresh'
    $sample.physical_available_bytes=8GB;Update-AgentTelemetry $s $sample 52 52;Assert ($null -eq $s.PressureSince) 'Low pressure did not reset wait'
    $before=Reading;$o=New-AgentObservation $before 0 $config
    foreach($t in 5..60|Where-Object {$_%5 -eq 0}){$f=Add-AgentObservation $o (Reading 700) $t $config}
    Assert ($f.Outcome -eq 'observing' -and $f.NetObservedDropBytes -eq 200MB) 'Own cost not charged correctly'
    foreach($t in 65..300|Where-Object {$_%5 -eq 0}){$f=Add-AgentObservation $o (Reading 700) $t $config}
    Assert ($f.Outcome -eq 'observed_retained' -and !$f.CausationEstablished -and !$f.ApplicationLatencyMeasured -and !$f.HardFaultsMeasured) 'Invalid retained claim'
    Assert ($o.Samples.Count -le 30) 'Unbounded observation window'
    $o=New-AgentObservation $before 0 $config
    foreach($t in @(5,10,15,20)){$f=Add-AgentObservation $o (Reading $(if($t -eq 5){700}else{1000})) $t $config}
    Assert ($f.Outcome -eq 'short_benefit' -and $f.NetObservedDropBytes -eq -100MB) 'Rebound or signed negative lost'
    $o=New-AgentObservation $before 0 $config
    foreach($t in 5..60|Where-Object {$_%5 -eq 0}){$f=Add-AgentObservation $o (Reading 990) $t $config}
    Assert ($f.Outcome -eq 'small_benefit') 'Small benefit not blocked'
    $o=New-AgentObservation $before 0 $config
    foreach($t in 5..300|Where-Object {$_%5 -eq 0}){$r=Reading 700;$r.CpuPercent=20;$f=Add-AgentObservation $o $r $t $config}
    Assert ($f.Outcome -eq 'activity_cost') 'Activity cost hidden behind RAM reduction'
    $o=New-AgentObservation $before 0 $config;$r=Reading 700;$r.IdentityKey='new';$r.CounterCoverageComplete=$false;$f=Add-AgentObservation $o $r 5 $config
    Assert ($f.ProcessChanges -and !$f.ActivityCountersAvailable) 'Identity churn or unknown activity concealed'
    Reject {Add-AgentObservation $o (Reading 700) 20 $config} 'Observation gap accepted'
    foreach($field in @('AppPrivateBytes','OwnPrivateBytes','AppCommitBytes','AvailableBytes')){
        $r=Reading;$r.$field=$null;Reject {New-AgentObservation $r 0 $config} ('Missing reading accepted: '+$field)
        $r.$field=-1;Reject {New-AgentObservation $r 0 $config} ('Negative reading accepted: '+$field)
    }
    $r=Reading;$r.AppPrivateBytes=[double]::NaN;Reject {New-AgentObservation $r 0 $config} 'NaN accepted'
    Reject {New-AgentObservation (Reading 150) 0 $config} 'Insufficient headroom accepted'
    $s=Ready-State;$now=[DateTime]::UtcNow
    $s.History=@([pscustomobject]@{request=[guid]::NewGuid().ToString();browser='Chrome';host='example.org';utc=$now.AddMinutes(-20).ToString('o');outcome='short_benefit'})
    Assert ([bool](Get-AgentBlock $s 'Chrome' 'example.org' $now)) 'Short benefit not learned'
    Assert (!(Get-AgentBlock $s 'Chrome' 'other.org' $now)) 'Unrelated host blocked unnecessarily'
    $s.History[0].outcome='intent';Assert ([bool](Get-AgentBlock $s 'Firefox' 'other.org' $now)) 'Interrupted intent bypasses global cooldown'
    $s.History[0].utc=$now.AddHours(-25).ToString('o');Assert (!(Get-AgentBlock $s 'Chrome' 'example.org' $now)) 'Expired block retained'
    $s.History=@(1..2|ForEach-Object {[pscustomobject]@{request=[guid]::NewGuid().ToString();browser='Chrome';host="site$_.org";utc=$now.AddMinutes(-20*$_).ToString('o');outcome='observed_retained'}})
    Assert ([bool](Get-AgentBlock $s 'Firefox' 'other.org' $now)) 'Hourly action limit bypassed'
    Write-AgentJson (Join-Path $temp 'history.json') @{schema_version=1;actions=$s.History}
    Assert (@(Get-AgentHistory (Join-Path $temp 'history.json')).Count -eq 2) 'Persistent history did not roundtrip'
    Assert ((ConvertTo-AgentUtc ([DateTime]::SpecifyKind([DateTime]::Parse('2026-10-15T10:00:00'),[DateTimeKind]::Utc))).ToString('o').StartsWith('2026-10-15T10:00:00')) 'UTC DateTime lost timezone'
    Assert ((ConvertTo-AgentUtc '2026-10-15T12:00:00+02:00').Hour -eq 10) 'Offset history parsed as local time'
    Write-AgentJson (Join-Path $temp 'history.json') @{schema_version=1;actions=@($s.History[0],$s.History[0])}
    Reject {Get-AgentHistory (Join-Path $temp 'history.json')} 'Duplicate intent accepted'
    Reset-Runtime;$candidate=Get-AgentCandidate $script:agent 30 $epoch
    Start-AgentAction $candidate (Reading) 30
    $pending=$script:agent.Pending;$request=$pending.Request;$command=$script:agentBridge.Sent[0].message
    Assert ($command.authorization -eq 'site_policy_v1' -and $command.confirmed -eq $false) 'Automatic command masquerades as manual consent'
    Assert ((Get-AgentHistory (Join-Path $temp 'history.json'))[0].outcome -eq 'intent') 'Intent not persisted before command'
    Start-AgentAction $candidate (Reading) 31;Assert ($script:agentBridge.Sent.Count -eq 1) 'Concurrent automatic actions'
    Receive-AgentBrowser 1 @{type='result';session=$pending.Session;request=$request;tab=99;outcome='discarded'} 31
    Assert ($script:agent.Applied -eq 0) 'Wrong tab ACK counted'
    Receive-AgentBrowser 1 @{type='result';session=$pending.Session;request=$request;tab=42;outcome='discarded'} 31
    Assert ($script:agent.Applied -eq 1 -and $pending.Phase -eq 'observing') 'Valid ACK did not start observation'
    Receive-AgentBrowser 1 @{type='result';session=$pending.Session;request=$request;tab=42;outcome='discarded'} 32
    Assert ($script:agent.Applied -eq 1) 'Duplicate ACK counted'
    $script:agent.Readings.Chrome=@{At=36;Reading=(Reading 700)};Update-AgentAction 36
    Assert ($null -ne $script:agent.Pending) 'Ended observation too early'
    Receive-AgentBrowser 1 @{type='tab-return';session=$pending.Session;request='unrelated';tab=42;load_observed_ms=1} 37
    Assert ($null -ne $script:agent.Pending) 'Uncorrelated return ended action'
    Receive-AgentBrowser 1 @{type='tab-return';session=$pending.Session;request=$request;tab=42;load_observed_ms=200} 37
    Assert ($null -eq $script:agent.Pending -and $script:agent.LastResult.outcome -eq 'short_benefit') 'Confirmed return not learned'
    Get-AgentCandidate $script:agent 38 $epoch|Out-Null;Assert ($script:agent.LastResult.outcome -eq 'short_benefit') 'Next wait hides previous result'
    Reset-Runtime;$candidate=Get-AgentCandidate $script:agent 30 $epoch;Start-AgentAction $candidate (Reading) 30
    $pending=$script:agent.Pending;Update-AgentAction 51
    Assert ($null -eq $script:agent.Pending -and $script:agent.LastResult.outcome -eq 'unknown') 'ACK timeout falsely concludes no action'
    Receive-AgentBrowser 1 @{type='result';session=$pending.Session;request=$pending.Request;tab=42;outcome='discarded'} 52
    Assert ($script:agent.Applied -eq 1 -and $null -eq $script:agent.Pending -and $pending.Record.late_discard_confirmed -and $script:agent.LastResult.outcome -eq 'incomplete') 'Late ACK retried or concealed'
    Reset-Runtime;$candidate=Get-AgentCandidate $script:agent 30 $epoch;$script:agentBridge.Allow=$false;Start-AgentAction $candidate (Reading) 30
    Assert ($script:agent.LastResult.outcome -eq 'not_sent' -and $null -eq $script:agent.Pending) 'Failed send remains pending'
    Reset-Runtime;$candidate=Get-AgentCandidate $script:agent 30 $epoch;$script:agent.Profiles[1].Tabs[0].auto_allowed=$false
    Reject {Start-AgentAction $candidate (Reading) 30} 'Revoked candidate sent'
    Assert ($script:agentBridge.Sent.Count -eq 0) 'Rejected command still sent'
    Reset-Runtime;$script:agent.Profiles.Clear();$session=[guid]::NewGuid().ToString()
    Receive-AgentBrowser 3 @{type='hello';protocol=4;session=$session;extension=$script:agentBrowserConfig.firefox_extension_id;browser='Firefox';capabilities=@('automatic-site-policy-v1')} 0
    Assert (!$script:agent.Profiles[3].Ready -and $script:agentBridge.Sent[0].message.agent_mode -eq 'automatic_authorized_sites') 'Hello treated as ready'
    $tab=[pscustomobject]@{id=5;revision=[guid]::NewGuid().ToString();title='test';blocked='';discarded=$false;host='example.org';auto_allowed=$true;lastAccessed=$epoch-1200000}
    Receive-AgentBrowser 3 @{type='snapshot';protocol=4;session=$session;sequence=1;tabs=@($tab);truncated=$false} 1
    Assert ($script:agent.Profiles[3].Ready -and $script:agentBridge.Sent[1].message.type -eq 'inventory_ack') 'Inventory not acknowledged'
    Reject {Receive-AgentBrowser 3 @{type='snapshot';protocol=4;session=$session;sequence=1;tabs=@($tab)} 2} 'Duplicate inventory sequence accepted'
    Poll-AgentBrowser 32;Assert (!$script:agent.Profiles.ContainsKey(3)) 'Stale profile remains ready'
    Reset-Runtime
    $script:agent.LastInventory=@(@{name='unknown.exe';pid=1;memory_available=$false;private_working_set_bytes=$null},@{name='chatgpt.exe';pid=2;image_path='app';memory_available=$true;private_working_set_bytes=100MB})
    $rows=@(Get-AgentProcessSummary)
    Assert ($null -eq ($rows|Where-Object name -eq 'unknown.exe').private_bytes) 'Unknown RAM shown as zero'
    Assert (($rows|Where-Object name -eq 'chatgpt.exe').method -match 'nessun rilascio') 'Unimplemented app advertised actionable'
    # Dictionary telemetry is also used by the Windows PowerShell 5.1 test/runtime callers.
    # Exercise all representations and count only AME components, retaining unknown metrics.
    foreach($representation in @('dictionary','object','mixed')){
        Reset-Runtime
        $budgetRows=@(
            @{pid=$PID;memory_available=$true;private_working_set_bytes=100MB;cpu_percent=1.25},
            @{pid=-101;image_path=(Join-Path $root 'build\ame.exe');memory_available=$true;private_working_set_bytes=3MB;cpu_percent=0.15},
            @{pid=-102;image_path=(Join-Path $root 'build\ame-browser-host.exe');memory_available=$true;private_working_set_bytes=2MB;cpu_percent=0.10},
            @{pid=-103;image_path='unrelated.exe';memory_available=$true;private_working_set_bytes=999MB;cpu_percent=99}
        )
        if($representation -eq 'object'){$budgetRows=@($budgetRows|ForEach-Object {[pscustomobject]$_})}
        elseif($representation -eq 'mixed'){$budgetRows[1]=[pscustomobject]$budgetRows[1]}
        Update-AgentOwnBudget $budgetRows 0
        Assert ($script:agent.OwnPrivateBytes -eq 105MB -and [math]::Abs($script:agent.OwnCpu-1.5) -lt 0.000001 -and !$script:agent.StopReason) ('Own component totals incorrect for '+$representation)
    }
    Update-AgentOwnBudget @(@{pid=$PID;memory_available=$true;private_working_set_bytes=0;cpu_percent=0}) 1
    Assert ($null -ne $script:agent.OwnPrivateBytes -and $script:agent.OwnPrivateBytes -eq 0 -and $null -ne $script:agent.OwnCpu -and $script:agent.OwnCpu -eq 0) 'Measured zero converted to unknown'
    foreach($missing in @(
        @{pid=$PID;memory_available=$true;private_working_set_bytes=$null;cpu_percent=0},
        @{pid=$PID;memory_available=$false;private_working_set_bytes=100MB;cpu_percent=0}
    )){
        $script:agent.OwnCpuOverSince=0
        Update-AgentOwnBudget @($missing) 2
        Assert ($null -eq $script:agent.OwnPrivateBytes -and $null -eq $script:agent.OwnCpu -and $null -eq $script:agent.OwnCpuOverSince) 'Unavailable RAM became a valid budget reading'
    }
    $script:agent.OwnCpuOverSince=0
    Update-AgentOwnBudget @(@{pid=$PID;memory_available=$true;private_working_set_bytes=100MB;cpu_percent=$null}) 3
    Assert ($script:agent.OwnPrivateBytes -eq 100MB -and $null -eq $script:agent.OwnCpu -and $null -eq $script:agent.OwnCpuOverSince) 'Unknown CPU became zero or discarded known RAM'
    Update-AgentOwnBudget @() 4
    Assert ($null -eq $script:agent.OwnPrivateBytes -and $null -eq $script:agent.OwnCpu) 'Missing own processes produced measured zero'
    Update-AgentOwnBudget @(@{pid=$PID;memory_available=$true;private_working_set_bytes=300MB;cpu_percent=0}) 0
    Assert ([bool]$script:agent.StopReason) 'Own memory budget not enforced'
    $script:agent.StopReason='';foreach($t in @(0,10,20,30)){Update-AgentOwnBudget @(@{pid=$PID;memory_available=$true;private_working_set_bytes=100MB;cpu_percent=3}) $t}
    Assert ([bool]$script:agent.StopReason) 'Sustained own CPU budget not enforced'
    Write-AgentStatus;$status=Read-AgentJson (Join-Path $temp 'status.json');Assert ($status.revision -eq 'R22' -and !$status.causation_established) 'Status missing or overclaims'
    Write-AgentJson (Join-Path $temp 'atomic.json') @{n=1};Write-AgentJson (Join-Path $temp 'atomic.json') @{n=2}
    Assert ((Read-AgentJson (Join-Path $temp 'atomic.json')).n -eq 2 -and @(Get-ChildItem $temp -Filter '*.tmp').Count -eq 0) 'Atomic replacement leaked files'
    Reject {Write-AgentJson (Join-Path $temp 'atomic.json') @{n=('x'*500)} 50} 'Oversized state accepted'
    for($n=0;$n -lt 190;$n++){Write-AgentEvent @{type='test';message=('x'*50000)}}
    $journals=@(Get-ChildItem $temp -Filter 'agent-events-*.jsonl')
    Assert ($journals.Count -eq 4 -and @($journals|Where-Object Length -gt 2MB).Count -eq 0 -and $script:agent.Recent.Count -le 60) 'Journal retention unbounded'
    Write-AgentEvent @{type='agent_assessed';outcome='short_benefit';message='Memoria tornata';assessment=@{NetObservedDropBytes=-100MB}}
    $bundle=& (Join-Path $root 'export-diagnostics.ps1') -Report (Join-Path $temp 'agent-events-0.jsonl') -OutputDirectory (Join-Path $temp 'export')
    $zip=[IO.Compression.ZipFile]::OpenRead($bundle.Path)
    try{
        $stream=New-Object IO.StreamReader($zip.GetEntry('RIEPILOGO.json').Open());try{$manifest=$stream.ReadToEnd()|ConvertFrom-Json}finally{$stream.Dispose()}
        Assert ($manifest.agent_outcomes.Count -eq 1 -and $manifest.agent_outcomes[0].assessment.NetObservedDropBytes -eq -100MB) 'Agent diagnosis lost signed outcome'
    }finally{$zip.Dispose()}
    $worker=Get-Content (Join-Path $root 'agent.ps1') -Raw
    Assert ($worker -notmatch 'Windows.Forms|EmptyWorkingSet|SetProcessWorkingSetSize|Stop-Process' -and $worker -match 'AME-MemoryPriority-Controller' -and $worker -match 'AME-Process-Hub') 'Headless worker lacks isolation or mutates arbitrary apps'
    # Verify Multi-Lane Distributed Planner (Internal + Browser Subprocesses + Windows Processes)
    Reset-Runtime
    $script:agent.LastInventory=@(
        [pscustomobject]@{pid=100;parent_pid=1;name='chrome.exe';image_path='C:\Program Files\Google\Chrome\Application\chrome.exe';same_user=$true;critical=$false;foreground_window_owner=$false;memory_available=$true;private_working_set_bytes=200MB;creation_filetime='111';low_activity_seconds=120;cpu_percent=0.05},
        [pscustomobject]@{pid=101;parent_pid=100;name='chrome.exe';image_path='C:\Program Files\Google\Chrome\Application\chrome.exe';same_user=$true;critical=$false;foreground_window_owner=$false;memory_available=$true;private_working_set_bytes=180MB;creation_filetime='112';low_activity_seconds=90;cpu_percent=0.02},
        [pscustomobject]@{pid=200;parent_pid=1;name='firefox.exe';image_path='C:\Program Files\Mozilla Firefox\firefox.exe';same_user=$true;critical=$false;foreground_window_owner=$false;memory_available=$true;private_working_set_bytes=220MB;creation_filetime='211';low_activity_seconds=120;cpu_percent=0.05},
        [pscustomobject]@{pid=201;parent_pid=200;name='firefox.exe';image_path='C:\Program Files\Mozilla Firefox\firefox.exe';same_user=$true;critical=$false;foreground_window_owner=$false;memory_available=$true;private_working_set_bytes=160MB;creation_filetime='212';low_activity_seconds=80;cpu_percent=0.01},
        [pscustomobject]@{pid=300;parent_pid=1;name='heavyapp.exe';image_path='D:\Apps\heavyapp.exe';same_user=$true;critical=$false;foreground_window_owner=$false;memory_available=$true;private_working_set_bytes=400MB;creation_filetime='311';low_activity_seconds=120;cpu_percent=0.01},
        [pscustomobject]@{pid=400;parent_pid=1;name='activeapp.exe';image_path='D:\Apps\activeapp.exe';same_user=$true;critical=$false;foreground_window_owner=$true;memory_available=$true;private_working_set_bytes=500MB;creation_filetime='411';low_activity_seconds=0;cpu_percent=15.0}
    )
    $script:agent.InventoryAt=30
    $plan=Get-DistributedReclaimPlan $script:agent 30
    Assert ($null -ne $plan -and $plan.HardPressure -and $plan.BrowserSubprocesses.Count -eq 2 -and $plan.WindowsProcesses.Count -eq 1 -and $plan.WindowsProcesses[0].Pid -eq 300) 'Distributed multi-lane plan failed to select idle browser child and Windows processes while excluding foreground app'
    Write-Host ('PASS '+$script:checks+' automatic agent checks: gates, virtual 5m feedback, persistence, actual handlers, late ACK, budgets, bounded logs and distributed multi-lane planner.')
}finally{if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}}
