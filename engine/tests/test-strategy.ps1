param([string]$Diagnostic='')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'strategy-model.ps1')
. (Join-Path $root 'browser-model.ps1')
function Assert($ok,[string]$message){if(!$ok){throw $message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ame strategy '+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$path=Join-Path $temp 'strategy-history.json';$now=[DateTime]::UtcNow
$target=[pscustomobject]@{Key='21904:134362787950151731';Pid=21904;Name='chrome.exe';Path='C:\Apps\chrome.exe';Blocked='';PrivateBytes=320MB}
$outcome=[pscustomobject]@{type='recover_assessed';pid=21904;creation_filetime='134362787950151731';image_path=$target.Path;reason='rapid_resident_rebound';seconds_after_action=171.917;best_private_resident_reduction_bytes=319MB;remaining_private_resident_reduction_bytes=0;minimum_private_resident_reduction_last_60s_bytes=0}
try{
    # Reproduce the 5.1 absence of Count on a single custom object even under 7.x.
    $singleRecord=[pscustomobject]@{classification='retained'}
    $singleRecord|Add-Member NoteProperty Count $null
    Assert (($singleRecord|Where-Object classification -eq retained).Count -ne 1 -and
        @($singleRecord|Where-Object classification -eq retained).Count -eq 1) 'PS 5.1 single-result count regression'
    Assert (@($singleRecord|Where-Object classification -eq brief).Count -eq 0 -and
        @(@($singleRecord,$singleRecord)|Where-Object classification -eq retained).Count -eq 2) 'Zero/multiple filtered counts changed'
    Save-StrategyOutcome $path $outcome @($target) 'first.jsonl' $now
    $records=@(Read-StrategyHistory $path $now);$advice=Get-StrategyAdvice $target $records
    Assert ($records.Count -eq 1 -and $advice.CanReleaseTabs -and $advice.Bad -eq 1 -and $advice.Explanation -like '*sconsigliata*') 'Rebound not learned or app-supported route missing'
    Save-StrategyOutcome $path $outcome @($target) 'first.jsonl' $now
    Assert (@(Read-StrategyHistory $path $now).Count -eq 1) 'Same trial counted twice'
    $wrong=[pscustomobject]@{Key='21904:999';Path=$target.Path}
    Save-StrategyOutcome $path $outcome @($wrong) 'wrong.jsonl' $now
    Assert (@(Read-StrategyHistory $path $now).Count -eq 1) 'Unauthorized identity learned'
    $outcome.reason='resident_reduction_retained_5m';$outcome.seconds_after_action=200;$outcome.remaining_private_resident_reduction_bytes=64MB;$outcome.minimum_private_resident_reduction_last_60s_bytes=60MB
    Save-StrategyOutcome $path $outcome @($target) 'too-short.jsonl' $now
    Assert (@(Read-StrategyHistory $path $now).Count -eq 1) 'Early observation promoted to 5m evidence'
    $outcome.seconds_after_action=300
    Save-StrategyOutcome $path $outcome @($target) 'retained.jsonl' $now
    $records=@(Read-StrategyHistory $path $now)
    # Windows PowerShell 5.1 does not reliably expose Count on a single
    # PSCustomObject. Force filtered results into arrays before counting.
    Assert ($records.Count -eq 2 -and @($records|Where-Object classification -eq retained).Count -eq 1) 'Valid observed 5m outcome lost'
    $outcome.reason='resident_reduction_retained_5m_with_activity'
    Save-StrategyOutcome $path $outcome @($target) 'activity.jsonl' $now
    Assert (@(Read-StrategyHistory $path $now|Where-Object classification -eq retained_with_activity).Count -eq 1) 'Activity warning presented as clean benefit'
    $other=[pscustomobject]@{Key='5:8';Name='claude.exe';Path='D:\Different\app.exe';Blocked=''}
    $advice=Get-StrategyAdvice $other @(Read-StrategyHistory $path $now)
    Assert (!$advice.CanReleaseTabs -and $advice.Bad -eq 0 -and $advice.Method -like '*Nessun rilascio*') 'Invented integration or learning crossed app paths'
    Assert (@(Read-StrategyHistory $path $now.AddDays(8)).Count -eq 0) 'Old evidence never expires'
    [IO.File]::WriteAllText($path,'{broken');$failed=$false
    try{Save-StrategyOutcome $path $outcome @($target) 'broken.jsonl' $now}catch{$failed=$true}
    Assert ($failed -and [IO.File]::ReadAllText($path) -eq '{broken') 'Corrupt history silently overwritten'
    [IO.File]::Delete($path)
    $outcome.reason='rapid_resident_rebound';$outcome.seconds_after_action=172;$outcome.remaining_private_resident_reduction_bytes=0
    $session=@{type='recover_session';selected=@(@{pid=21904;creation_filetime='134362787950151731'});allowed_images=@($target.Path)}
    $report=Join-Path $temp 'recover-test-complete.jsonl'
    $text=($session|ConvertTo-Json -Compress)+"`n"+($outcome|ConvertTo-Json -Compress)+"`n"+'{"type":"end","feedback_pending":false}'+"`n"
    [IO.File]::WriteAllText($report,$text)
    Import-StrategyReports $temp $path
    Assert (@(Read-StrategyHistory $path).Count -eq 1) 'Existing completed trial not imported'
    [IO.File]::Delete($path);[IO.File]::WriteAllText($report,$text.TrimEnd([char]10))
    Import-StrategyReports $temp $path
    Assert (!(Test-Path -LiteralPath $path)) 'Partial final record learned'

    function New-Pending {
        return @{Before=@{private_working_set_bytes=500MB;private_commit_bytes=600MB;processes=4;unreadable=0};AckAt=$now;LastSample=$null;Incomplete=$false;Returned=$false;BestDrop=0;Samples=@()}
    }
    $reading=@{private_working_set_bytes=400MB;private_commit_bytes=500MB;processes=4;unreadable=0}
    $pending=New-Pending
    for($s=0;$s -le 300;$s+=5){$a=Get-BrowserObservation $pending $reading $now.AddSeconds($s);if($s -lt 300){Assert (!$a.Finished) 'Early stable result'}}
    Assert ($a.Finished -and $a.Outcome -eq 'aggregate_drop_observed_5m' -and $a.Status -like '*non attribuita*') 'Aggregate 5m evidence misrepresented'
    $pending=New-Pending;[void](Get-BrowserObservation $pending $reading $now)
    $pending.Returned=$true;$a=Get-BrowserObservation $pending $reading $now.AddSeconds(5)
    Assert ($a.Finished -and $a.Outcome -eq 'page_returned' -and $a.Status -like '*Nessun risparmio stabile*') 'Return ignored'
    $pending=New-Pending;[void](Get-BrowserObservation $pending $reading $now)
    $a=Get-BrowserObservation $pending $reading $now.AddSeconds(20)
    Assert ($a.Finished -and $a.Outcome -eq 'incomplete') 'Sampling gap ignored'
    $pending=New-Pending;$reading.unreadable=1
    $a=Get-BrowserObservation $pending $reading $now
    Assert ($a.Finished -and $null -eq $a.Drop -and $a.Outcome -eq 'incomplete') 'Partial data treated as zero or benefit'
    $reading.unreadable=0;$reading.processes=5;$pending=New-Pending
    Assert ((Get-BrowserObservation $pending $reading $now).Outcome -eq 'incomplete') 'Changing composition compared as stable'
    $reading.processes=4;$reading.private_working_set_bytes=520MB;$pending=New-Pending
    for($s=0;$s -le 300;$s+=5){$a=Get-BrowserObservation $pending $reading $now.AddSeconds($s)}
    Assert ($a.Outcome -eq 'no_durable_aggregate_drop' -and $a.Status -like '*in piu*') 'Rising RAM presented as saving'
    Write-Host 'PASS strategy history, identity/source scope, incomplete/expired evidence, existing reports and browser 5m/return/gap/partial measurements'

    # Execute the actual primary handler with light UI and identity substitutes.
    . (Join-Path $root 'release-support.ps1')
    $script:strategyPath=Join-Path $temp 'fresh.json';$script:selection=@{$target.Key=$target;$other.Key=$other}
    $script:queueStatus=[pscustomobject]@{Text=''};$script:result=[pscustomobject]@{Text=''};$script:state=[pscustomobject]@{Text=''}
    $script:hubTabs=[pscustomobject]@{SelectedTab='processes'};$script:releaseTab='release';$script:mode='observe';$script:batchActive=$false;$script:pendingRecoveryMode=$null;$script:restartMode=$null;$script:pendingBrowser=$null
    $script:checks=0;$script:commands=New-Object 'Collections.Generic.List[string]'
    function Save-Selection {}
    function Assert-ResourceApiTargets([object[]]$Targets){$script:checks+=$Targets.Count}
    function Write-PanelEvent([string]$action,[string]$stage,[string]$detail=''){$script:commands.Add($action+':'+$stage)}
    Request-Strategy
    Assert ($script:checks -eq 2 -and $script:hubTabs.SelectedTab -eq 'release' -and $result.Text -like '*Nessuna riduzione*' -and $queueStatus.Text -like '*Nessun rilascio*') 'Primary route omits identities, invents reductions or excludes unsupported app'
    $script:pendingBrowser=@{Ack=$true};Request-Strategy
    Assert ($result.Text -eq 'Strategia non avviata.' -and $script:checks -eq 2) 'Second intervention permitted during observation'
    $script:pendingBrowser=$null;$script:selection=@{$other.Key=$other};$script:hubTabs.SelectedTab='processes'
    Request-Strategy
    Assert ($script:hubTabs.SelectedTab -eq 'processes' -and $state.Text -like '*non e integrata*') 'Unsupported app implicitly assigned another app integration'
    Write-Host 'PASS actual strategy click: precise identity gate, app-supported route, unsupported app, no implicit mutation, concurrent action refusal'

    # Execute the actual browser event loop with a fake native bridge.
    $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'browser-panel.ps1'),[ref]$t,[ref]$e)
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'script:Poll-Browser'},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
    $script:bridge=[pscustomobject]@{Data=@()};$script:bridge|Add-Member ScriptMethod Drain {$data=$this.Data;$this.Data=@();return $data}
    $script:bridge|Add-Member ScriptMethod Disconnect {param($id)}
    $script:bridge|Add-Member ScriptMethod Send {param($id,$json);return $true}
    $script:browserClosing=@{}
    $script:profiles=@{1=@{Session='s';Seen=[DateTime]::UtcNow;Tabs=@();Ready=$true;LastSequence=0}};$script:browserRequests=@{};$script:browserCooldown=@{};$script:browserConfirmed=0
    $script:browserState=[pscustomobject]@{Text=''};$script:discardButton=[pscustomobject]@{Enabled=$false};$script:browserGrid=[pscustomobject]@{SelectedRows=@()}
    $script:browserEvents=New-Object 'Collections.Generic.List[object]'
    function Write-BrowserEvent($event){$script:browserEvents.Add($event)}
    function Add-HubLog([string]$message) {}
    function Update-BrowserGrid {}
    function Update-BrowserConnectionDisplay {}
    function Set-BrowserConnectionStatus {}
    $reader=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'script:Get-BrowserReading'},$true)
    . ([scriptblock]::Create($reader.Extent.Text))
    function Get-ChromeReading {return @{private_working_set_bytes=400MB;private_commit_bytes=500MB;processes=4;unreadable=0}}
    $script:pendingBrowser=New-Pending
    foreach($kv in @{Connection=1;Request='r';Tab=42;Session='s';Ack=$false;Sent=[DateTime]::UtcNow}.GetEnumerator()){$script:pendingBrowser[$kv.Key]=$kv.Value}
    $script:bridge.Data=@([pscustomobject]@{Connection=1;Error='';Json='{"type":"result","session":"s","request":"r","tab":42,"outcome":"discarded"}'})
    Poll-Browser
    Assert ($script:browserConfirmed -eq 1 -and $script:pendingBrowser.Ack -and $browserState.Text -like '*300 s*') 'Actual ack does not start clear observation'
    $script:bridge.Data=@([pscustomobject]@{Connection=1;Error='';Json='{"type":"snapshot","protocol":4,"sequence":1,"session":"s","tabs":[{"id":42,"revision":"12345678-1234-1234-1234-123456789012","title":"page","discarded":false}]}'})
    Poll-Browser
    Assert (!$script:pendingBrowser -and $browserState.Text -like '*Scheda tornata*' -and $script:browserCooldown.Count -eq 1) 'Snapshot return not assessed or cooldown missing'
    $script:pendingBrowser=New-Pending
    foreach($kv in @{Connection=1;Request='unknown';Tab=42;Session='s';Ack=$false;Sent=[DateTime]::UtcNow.AddSeconds(-30)}.GetEnumerator()){$script:pendingBrowser[$kv.Key]=$kv.Value}
    Poll-Browser
    Assert (!$script:pendingBrowser -and $browserState.Text -like '*esito sconosciuto*') 'Missing ack reported as success'
    # Same memory units cannot be mixed between browser aggregates.
    $firefoxPending=New-Pending;$firefoxPending.Browser='Firefox';$firefoxPending.Before.scope='all_firefox_processes_in_desktop_session'
    $reading=@{private_working_set_bytes=100MB;private_commit_bytes=200MB;processes=$firefoxPending.Before.processes;unreadable=0;scope='all_chrome_processes_in_desktop_session'}
    $mixed=Get-BrowserObservation $firefoxPending $reading
    Assert ($mixed.Outcome -eq 'incomplete' -and $null -eq $mixed.Drop -and $mixed.Status -like 'Firefox:*') 'Chrome and Firefox metrics mixed into apparent RAM reduction'
    $firefoxTarget=[pscustomobject]@{Name='firefox.exe';Path='C:\Apps\firefox.exe';Blocked=''}
    $advice=Get-StrategyAdvice $firefoxTarget @()
    Assert ($advice.CanReleaseTabs -and $advice.Method -like '*Firefox*') 'Firefox strategy route absent'
    Write-Host 'PASS actual browser loop: confirmed discard, visible live assessment, page return, cooldown and unknown acknowledgement'

    if($Diagnostic){
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $diagnosticFolder=Join-Path $temp 'diagnostic';[void][IO.Directory]::CreateDirectory($diagnosticFolder)
        $zip=[IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Diagnostic).Path)
        try{foreach($entry in $zip.Entries){if($entry.Name -like '*recover*.jsonl'){$dst=Join-Path $diagnosticFolder ($entry.Name -replace '^\d+-','');[IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dst)}}}finally{$zip.Dispose()}
        $realHistory=Join-Path $temp 'real.json';Import-StrategyReports $diagnosticFolder $realHistory
        $real=@(Read-StrategyHistory $realHistory)
        Assert ($real.Count -ge 1 -and @($real|Where-Object {$_.key -eq '21904:134362787950151731' -and $_.classification -eq 'brief'}).Count -eq 1) 'Provided real rebound not recognized'
        Write-Host 'PASS provided Windows diagnostic: actual PID 21904 rebound imported as brief benefit'
    }
}finally{if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}}
