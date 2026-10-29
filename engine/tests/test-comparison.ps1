param([switch]$NativeWindows)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'comparison-model.ps1')
. (Join-Path $root 'comparison-controller.ps1')
function Assert($Ok,[string]$Message){if(!$Ok){throw $Message}}
function Reject([scriptblock]$Work,[string]$Message){$failed=$false;try{& $Work}catch{$failed=$true};Assert $failed $Message}
function Profile([string]$Browser='Chrome',[int]$Count=1){
    $tabs=@(for($n=1;$n -le $Count;$n++){@{id=[long]$n;revision=[guid]::NewGuid().ToString('D');title=('Pagina '+$n);blocked='';discarded=$false}})
    return @{Browser=$Browser;Ready=$true;Session=[guid]::NewGuid().ToString('D');Seen=[DateTime]::UtcNow;LastSequence=1L;Tabs=$tabs}
}
function Sample([double]$Private=2GB,[double]$Own=50MB,[string]$Identity='1:created:path'){
    return [pscustomobject]@{AppPrivateBytes=$Private;AppCommitBytes=3GB;OwnPrivateBytes=$Own;AvailableBytes=2GB;TotalBytes=16GB;AppProcesses=1;
        Complete=$true;IdentityKey=$Identity;CpuPercent=0.1;PageFaultsPerSecond=1.0;IoReadBytesPerSecond=0.0;CounterCoverageComplete=$true}
}
function Pair([double]$After=1GB,[double]$Own=50MB,[int]$Spike=-1){
    $p=Profile;$s=New-ComparisonSession $p 1 $p.Tabs 'Stesse pagine e attivita'
    for($t=0;$t -le 900;$t+=5){[void](Add-ComparisonSample $s (Sample) $t)}
    Assert ($s.Phase -eq 'ready' -and $s.Applied -eq 0) 'Baseline claims or performs an intervention'
    $s.Phase='ame';$s.LastSeconds=$null;$s.Applied=1
    for($t=0;$t -le 900;$t+=5){$bytes=if($t -eq $Spike){2GB}else{$After};[void](Add-ComparisonSample $s (Sample $bytes $Own) $t)}
    return $s
}
$s=Pair
Assert ($s.Outcome.Complete -and $s.Outcome.Code -eq 'observed_threshold_met' -and $s.Outcome.NetObservedDropBytes -eq (1GB-50MB)) 'Measured AME overhead is not subtracted'
Assert (!$s.Outcome.CausationEstablished -and !$s.Outcome.ApplicationLatencyMeasured -and !$s.Outcome.HardFaultsMeasured -and !$s.Outcome.CanRecommendAutomaticOptimization) 'Observational result overclaims effectiveness or speed'
$s.Ame[2].CpuPercent=30
$cost=Get-ComparisonAssessment $s
Assert ($cost.CostWarning -and $cost.AmePeakCpu -eq 30) 'Early activity spike hidden by final-window medians'
$s=Pair (2GB-600MB) 200MB
Assert ($s.Outcome.Code -eq 'observed_below_threshold' -and $s.Outcome.NetObservedDropBytes -eq 400MB) 'Subthreshold result called substantial'
$s=Pair (2GB-30MB) 50MB
Assert ($s.Outcome.Code -eq 'no_net_observed_benefit' -and $s.Outcome.NetObservedDropBytes -eq -20MB) 'Negative net benefit loses its sign'
$s=Pair 1GB 50MB 25
Assert ($s.Outcome.Code -eq 'observed_below_threshold' -and $s.Outcome.ConservativeDropBytes -lt 0) 'Early rebound erased by final-window median'
$p=Profile;$s=New-ComparisonSession $p 1 $p.Tabs 'Stesso lavoro'
for($t=0;$t -le 900;$t+=5){$bytes=if($t -lt 600){3GB}else{1GB};[void](Add-ComparisonSample $s (Sample $bytes) $t)}
$s.Phase='ame';$s.LastSeconds=$null;$s.Applied=1
for($t=0;$t -le 900;$t+=5){[void](Add-ComparisonSample $s (Sample 1GB) $t)}
Assert ($s.Outcome.Code -eq 'no_net_observed_benefit') 'Native baseline drop wrongly credited to AME'
$p=Profile;$s=New-ComparisonSession $p 1 $p.Tabs 'Stesso lavoro'
[void](Add-ComparisonSample $s (Sample) 0)
Reject {Add-ComparisonSample $s (Sample) 13} 'Gap accepted'
Reject {Add-ComparisonSample $s (Sample) 0} 'Duplicate/backward monotonic time accepted'
$missing=Sample;$missing.OwnPrivateBytes=$null
Reject {Add-ComparisonSample $s $missing 5} 'Missing AME overhead invented as zero'
$nan=Sample;$nan.AppPrivateBytes=[double]::NaN
Reject {Add-ComparisonSample $s $nan 5} 'NaN RAM accepted'
$s.Outcome=Get-ComparisonAssessment $s
Assert (!$s.Outcome.Complete) 'Partial session called complete'
$p=Profile Chrome 6
Reject {New-ComparisonSession $p 1 $p.Tabs 'stesso lavoro'} 'Six tabs accepted'
$p=Profile;$p.Tabs[0].blocked='audio'
Reject {New-ComparisonSession $p 1 $p.Tabs 'stesso lavoro'} 'Protected tab accepted'
$p=Profile
Reject {New-ComparisonSession $p 1 @($p.Tabs[0],$p.Tabs[0]) 'stesso lavoro'} 'Duplicate tab accepted'
Reject {New-ComparisonSession $p 1 $p.Tabs ''} 'Missing workload description accepted'
$s=Pair;$s.Ame[40].IdentityKey='same-pid:new-creation:path';$s.Ame[40].CounterCoverageComplete=$false
$o=Get-ComparisonAssessment $s
Assert $o.ProcessChanges 'PID identity reuse hidden'
foreach($row in $s.Ame){$row.CounterCoverageComplete=$false;$row.CpuPercent=$null;$row.PageFaultsPerSecond=$null;$row.IoReadBytesPerSecond=$null}
$o=Get-ComparisonAssessment $s
Assert ($null -eq $o.CpuDeltaPercentagePoints -and $null -eq $o.FaultRateDelta -and $null -eq $o.IoReadRateDelta) 'Missing activity metrics represented as zero'

# The production collector compiles on every validation host. Only Windows can
# execute its P/Invoke calls; the normal Windows launcher runs that check too.
if(!('AmeComparison.Sampler' -as [type])){Add-Type -Path (Join-Path $root 'src/comparison-metrics.cs')}
if($NativeWindows){
    $native=[AmeComparison.Sampler]::new('chrome',$root);$reading=$native.Read()
    Assert ($reading.TotalBytes -gt 0 -and $null -ne $reading.OwnPrivateBytes -and $reading.OwnPrivateBytes -gt 0) 'Actual Windows observer overhead unavailable'
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('ame comparison '+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$script:comparisonReportsDirectory=Join-Path $temp 'reports'
$script:comparison=$null;$script:comparisonClockValue=0.0;$script:mode='observe'
$script:profiles=@{};$script:browserRequests=@{};$script:browserConfirmed=0;$script:comparisonUpdates=0
function Get-ComparisonClock {return $script:comparisonClockValue}
function Update-ComparisonDisplay {$script:comparisonUpdates++}
function New-ComparisonSampler([string]$Browser){
    $reader=[pscustomobject]@{}
    $reader|Add-Member ScriptMethod Read {if($script:comparison.Phase -eq 'ame'){return Sample 1GB}else{return Sample}}
    return $reader
}
$script:bridge=[pscustomobject]@{Sent=(New-Object 'Collections.Generic.List[object]');Fail=$false}
$bridge|Add-Member ScriptMethod Send {param($id,$json);if($this.Fail){return $false};$this.Sent.Add(($json|ConvertFrom-Json));return $true}
function Begin([string]$Browser='Chrome',[int]$Count=1){
    $script:comparison=$null;$script:comparisonClockValue=0;$script:profiles=@{1=(Profile $Browser $Count)}
    Start-ComparisonBaseline 1 $profiles[1].Tabs 'Stesse app e pagine' $true
    for($t=5;$t -le 900;$t+=5){$script:comparisonClockValue=$t;Invoke-ComparisonTick}
    Assert ($comparison.Phase -eq 'ready') 'Controller did not complete baseline'
}
function Acknowledge([string]$Outcome='discarded'){
    $r=@($script:comparison.Requests.GetEnumerator()|Where-Object {$_.Value.Outcome -eq 'pending'})[0]
    Assert ($null -ne $r) 'No serial pending request'
    [void](Receive-ComparisonResult 1 ([pscustomobject]@{request=$r.Key;tab=$r.Value.Tab;outcome=$Outcome;reason='fixture';operation_ms=1}))
    if($Outcome -eq 'discarded'){$profiles[1].Tabs|Where-Object {$_.id -eq $r.Value.Tab}|ForEach-Object {$_.discarded=$true};$profiles[1].LastSequence++}
    return $r.Key
}
try{
    $p=Profile;$profiles=@{1=$p}
    Reject {Start-ComparisonBaseline 1 $p.Tabs 'Stesso lavoro' $false} 'Unconfirmed native configuration accepted'
    Begin Chrome 5
    Reject {New-ComparisonGuard} 'Existing mutation-controller guard not shared by comparison'
    Assert ($bridge.Sent.Count -eq 0 -and $comparison.Baseline.Count -eq 181) 'Baseline sent a browser command'
    Start-ComparisonAme $true
    Assert ($bridge.Sent.Count -eq 1 -and $comparison.Phase -eq 'applying') 'Discard queue is not serial'
    $first=Acknowledge
    $count=$bridge.Sent.Count
    [void](Receive-ComparisonResult 1 ([pscustomobject]@{request=$first;tab=1;outcome='discarded'}))
    Assert ($comparison.Applied -eq 1 -and $bridge.Sent.Count -eq $count) 'Duplicate result sends another action'
    for($i=0;$i -lt 4;$i++){[void](Acknowledge)}
    Assert ($comparison.Applied -eq 5 -and $comparison.Phase -eq 'ame' -and $bridge.Sent.Count -eq 5) 'Serial 1-5 confirmations lost'
    Invoke-ComparisonTick
    for($t=905;$t -le 1800;$t+=5){$script:comparisonClockValue=$t;Invoke-ComparisonTick}
    Assert ($comparison.Phase -eq 'done' -and $comparison.Outcome.Code -eq 'observed_threshold_met' -and $comparison.Ame.Count -eq 181) 'Production comparison tick lost a complete outcome'
    $probe=New-ComparisonGuard;$probe.Dispose()
    Record-ComparisonReturn $first 350
    Record-ComparisonReturn $first 350
    Assert ($comparison.ReturnLoads.Count -eq 1 -and !$comparison.ReturnLoads[0].ApplicationReadyMeasured) 'Reload duplicated or called application readiness'
    $report=$comparison.ReportPath
    $zip=& (Join-Path $root 'export-diagnostics.ps1') -Report @($report) -OutputDirectory (Join-Path $temp 'exports with spaces')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($zip.Path)
    try{
        $reader=New-Object IO.StreamReader($archive.GetEntry('RIEPILOGO.json').Open())
        try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
        Assert ($manifest.browser_discard_confirmations -eq 5 -and $manifest.comparison_outcomes.Count -eq 1) 'Export lost actual confirmed discards or comparison'
        Assert ($null -ne $archive.GetEntry($manifest.reports[0].archive_entry)) 'Browser name overwrote archive report path'
        Assert (!$manifest.causation_established -and !$manifest.latency_measured) 'Export invented causality or latency'
    }finally{$archive.Dispose()}
    Begin Firefox
    $profiles[1].Tabs[0].discarded=$true
    $before=$bridge.Sent.Count;Start-ComparisonAme $true
    Assert ($comparison.Outcome.Code -eq 'no_additional_targets' -and $comparison.Applied -eq 0 -and $bridge.Sent.Count -eq $before) 'Native release counted as AME intervention'
    Begin Firefox
    Start-ComparisonAme $true
    Stop-Comparison 'Annullato'
    Reject {Start-ComparisonBaseline 1 $profiles[1].Tabs 'Stesse pagine' $true} 'Unresolved previous action allowed a new baseline'
    $before=$bridge.Sent.Count;[void](Acknowledge)
    Assert ($comparison.Phase -eq 'incomplete' -and $comparison.Applied -eq 1 -and $bridge.Sent.Count -eq $before) 'Late acknowledgement resumed cancelled work'
    Begin
    Start-ComparisonAme $true
    $pending=@($comparison.Requests.GetEnumerator())[0]
    $script:comparisonClockValue=921;Invoke-ComparisonTick
    Assert ($comparison.Phase -eq 'incomplete' -and $pending.Value.Outcome -eq 'unknown') 'Timeout falsely says no action'
    [void](Receive-ComparisonResult 1 ([pscustomobject]@{request=$pending.Key;tab=$pending.Value.Tab;outcome='discarded';operation_ms=21000}))
    Assert ($comparison.Phase -eq 'incomplete' -and $comparison.Applied -eq 1) 'Late timeout result hidden or resumes work'
    Begin
    Start-ComparisonAme $true;[void](Acknowledge)
    $profiles[1].Tabs[0].discarded=$false;$profiles[1].LastSequence++
    Invoke-ComparisonTick
    Assert ($comparison.Phase -eq 'incomplete' -and $comparison.Returned) 'Early reuse called durable benefit'
    Reject {Assert-ComparisonCooldown 1 $comparison.Session 1} 'Early browser return bypasses existing cooldown'
    Begin
    $profiles[1].Tabs[0].revision=[guid]::NewGuid().ToString()
    Invoke-ComparisonTick
    Assert ($comparison.Phase -eq 'incomplete') 'Changed workload accepted'
    Begin
    $profiles.Remove(1);Invoke-ComparisonTick
    Assert ($comparison.Phase -eq 'incomplete') 'Disconnect leaves comparison running'
    Begin
    $before=$bridge.Sent.Count;$bridge.Fail=$true
    Reject {Start-ComparisonAme $true} 'Transport failure hidden'
    $bridge.Fail=$false
    Assert ($comparison.Phase -eq 'incomplete' -and $bridge.Sent.Count -eq $before) 'Transport failure repeats mutation'
    Assert ($comparisonUpdates -gt 100) 'Live display is not refreshed'

    # Execute production UI functions and button bodies, with real WinForms
    # controls on Windows and small data-only controls elsewhere.
    $ui=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'comparison-panel.ps1'),[ref]$null,[ref]$null)
    $script:comparison=$null;$script:profiles=@{1=(Profile Chrome 6)};$script:comparisonClockValue=0
    if($NativeWindows){
        Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
        $script:hubTabs=New-Object Windows.Forms.TabControl
        . (Join-Path $root 'comparison-panel.ps1')
    }else{
        $comparisonProfile=[pscustomobject]@{Items=(New-Object 'Collections.Generic.List[object]');SelectedIndex=-1;Enabled=$true}
        $comparisonProfile|Add-Member ScriptProperty SelectedItem {if($this.SelectedIndex -ge 0 -and $this.SelectedIndex -lt $this.Items.Count){return $this.Items[$this.SelectedIndex]};return $null}
        $comparisonChoices=[pscustomobject]@{Items=(New-Object 'Collections.Generic.List[object]');CheckedItems=@();Enabled=$true}
        $comparisonWorkload=[pscustomobject]@{Text='Stesse applicazioni e pagine';Enabled=$true}
        $comparisonNative=[pscustomobject]@{Checked=$true;Enabled=$true};$comparisonSacrificial=[pscustomobject]@{Checked=$true;Enabled=$true}
        foreach($name in @('comparisonRefresh','comparisonBaselineButton','comparisonAmeButton','comparisonCancelButton','comparisonExportButton')){Set-Variable -Name $name -Value ([pscustomobject]@{Enabled=$true})}
        $comparisonProgress=[pscustomobject]@{Text=''};$comparisonSummary=[pscustomobject]@{Text=''}
        foreach($name in @('Refresh-ComparisonChoices','Refresh-ComparisonProfiles','Update-ComparisonDisplay')){
            $fn=$ui.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
            . ([scriptblock]::Create($fn.Extent.Text))
        }
    }
    function Click([string]$Control){
        $needle='$'+$Control+'.Add_Click('
        $fn=$ui.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith($needle)},$true)
        Assert ($null -ne $fn) ('UI callback missing: '+$Control)
        & $fn.Arguments[0].ScriptBlock.GetScriptBlock()
    }
    Click 'comparisonRefresh';Refresh-ComparisonChoices
    Assert ($comparisonChoices.Items.Count -eq 6 -and $comparisonProfile.Items.Count -eq 1) 'UI does not populate connected profile/tab choices'
    $comparisonNative.Checked=$true;$comparisonSacrificial.Checked=$true;$comparisonWorkload.Text='Stesse applicazioni e pagine'
    if($NativeWindows){
        for($n=0;$n -lt 6;$n++){$comparisonChoices.SetItemChecked($n,$true)}
        Assert ($comparisonChoices.CheckedItems.Count -eq 5) 'Native checkbox accepts a sixth tab'
    }else{$comparisonChoices.CheckedItems=@($comparisonChoices.Items[0])}
    Click 'comparisonBaselineButton'
    Assert ($comparison.Phase -eq 'baseline' -and !$comparisonBaselineButton.Enabled -and !$comparisonAmeButton.Enabled -and $comparisonCancelButton.Enabled) 'Actual first button has no visible running state'
    Assert ($comparisonProgress.Text -like '*Fase 1/2*' -and $comparisonProgress.Text -like '*rimanenti*') 'Countdown is not visible'
    $hub=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'hub.ps1'),[ref]$null,[ref]$null)
    $fn=$hub.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-Engine'},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
    Reject {Start-Engine 'recover-test'} 'Native trim allowed during baseline'
    $browser=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'browser-panel.ps1'),[ref]$null,[ref]$null)
    $fn=$browser.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith('$discardButton.Add_Click(')},$true)
    $script:browserState=[pscustomobject]@{Text=''};function Add-HubLog([string]$Message){}
    $before=$bridge.Sent.Count;& $fn.Arguments[0].ScriptBlock.GetScriptBlock()
    Assert ($bridge.Sent.Count -eq $before -and $browserState.Text -like '*Confronto beneficio in corso*') 'Ordinary browser discard bypasses comparison gate'
    for($t=5;$t -le 900;$t+=5){$script:comparisonClockValue=$t;Invoke-ComparisonTick}
    Assert ($comparisonAmeButton.Enabled -and !$comparisonBaselineButton.Enabled) 'Second button not enabled after complete baseline'
    Click 'comparisonAmeButton'
    Assert ($comparison.Phase -eq 'applying') 'Actual second button did not request chosen discard'
    Click 'comparisonCancelButton'
    Assert ($comparison.Phase -eq 'incomplete' -and $comparisonBaselineButton.Enabled -and !$comparisonCancelButton.Enabled -and $comparisonSummary.Text -like '*Nessun altro comando*') 'Actual cancel button hides result or leaves actions enabled'
    if($NativeWindows){$script:hubTabs.Dispose()}
    Write-Host ('PASS paired comparison: 15-minute phases, native baseline, 1-5 serial discards, overhead, signed results, rebound, missing metrics, identity change, cancel, late ack, timeout, reload and ZIP; native Windows: '+[bool]$NativeWindows)
}finally{if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)};$script:comparisonReportsDirectory=$null}
