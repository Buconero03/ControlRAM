param([Parameter(Mandatory=$true)][guid]$RunId,[ValidateRange(0,86400)][int]$MaxSeconds=0)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'agent-state.ps1')
. (Join-Path $PSScriptRoot 'agent-model.ps1')
. (Join-Path $PSScriptRoot 'agent-runtime.ps1')
$script:agentDirectory=Get-AgentDirectory
[void][IO.Directory]::CreateDirectory($script:agentDirectory)
$script:agentRunId=$RunId.ToString('D');$script:agentProcessId=$PID
$self=[Diagnostics.Process]::GetCurrentProcess();$script:agentCreation=$self.StartTime.ToFileTimeUtc().ToString();$self.Dispose()
$script:agent=$null;$script:agentBridge=$null;$script:agentInventory=$null;$script:inventorySlot=1
$hubLock=$null;$mutationLock=$null;$ownsAgent=$false;$clock=[Diagnostics.Stopwatch]::StartNew()
try{
    if($PSVersionTable.PSEdition -eq 'Core' -or [IntPtr]::Size -ne 8){throw 'Agente: usa Windows PowerShell 5.1 a 64 bit tramite AUTOMATICO.cmd.'}
    Assert-AgentValidated
    $created=$false;$hubLock=[Threading.Mutex]::new($false,'Local\AME-Process-Hub',[ref]$created)
    if(!$created){throw 'Un pannello o agente AME e gia attivo. Chiudilo prima di avviare AUTOMATICO.cmd.'}
    $ownsAgent=$true
    $created=$false;$mutationLock=[Threading.Mutex]::new($false,'Local\AME-MemoryPriority-Controller',[ref]$created)
    if(!$created){throw 'Un controller AME e gia attivo. Nessuna seconda automazione avviata.'}
    $acl=New-Object Security.AccessControl.DirectorySecurity;$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetAccessRuleProtection($true,$false)
    foreach($owner in @($sid,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))){$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($owner,'FullControl','ContainerInherit, ObjectInherit','None','Allow')))}
    [IO.Directory]::SetAccessControl($script:agentDirectory,$acl)
    $script:agent=New-AgentState (Get-AgentConfig (Join-Path $PSScriptRoot 'agent-config.json'))
    try{$script:agent.History=@(Get-AgentHistory (Join-Path $script:agentDirectory 'history.json'))}catch{$script:agent.HistoryFailure=$_.Exception.Message}
    $previous=@($script:agent.History|Sort-Object utc|Select-Object -Last 1)
    if($previous.Count){$r=$previous[0];$script:agent.LastResult=@{request=$r.request;utc=$r.utc;browser=$r.browser;host=$r.host;outcome=$r.outcome;assessment=$r.assessment;message=$(if($r.message){[string]$r.message}else{'Esito precedente: '+$r.outcome+'. Nessuna misura conclusiva disponibile per questa richiesta.'})}}
    $script:agentBrowserConfig=Get-Content (Join-Path $PSScriptRoot 'browser/config.json') -Raw|ConvertFrom-Json
    Add-Type -Path (Join-Path $PSScriptRoot 'src/hub-runtime.cs')
    Add-Type -Path (Join-Path $PSScriptRoot 'src/comparison-metrics.cs')
    Add-Type -Path (Join-Path $PSScriptRoot 'src/resource-api-client.cs')
    $dllPath=Join-Path $PSScriptRoot 'build/ame-resource-api.dll'
    if(Test-Path -LiteralPath $dllPath){try{$script:agent.NativeClient=New-Object AmeHub.ResourceApiClient($dllPath)}catch{}}
    try{$script:agentApiBus=New-Object AmeHub.InternalApiBusServer}catch{$script:agentApiBus=$null}
    $script:agentBridge=New-Object AmeHub.BrowserBridge((Join-Path $PSScriptRoot 'build/ame-browser-host.exe'))
    $script:agent.Phase='monitoring';Write-AgentEvent @{type='agent_start';message='Agente R22 attivo in background con API interna Windows e distribuzione automatica Multi-Lane (Browser, Processi Interni, Processi Windows).'}
    Write-AgentStatus
    $nextStatus=0.0;$nextJournal=0.0
    while(!$script:agent.StopReason){
        $now=$clock.Elapsed.TotalSeconds;$utc=[DateTime]::UtcNow
        if($MaxSeconds -gt 0 -and $now -ge $MaxSeconds){$script:agent.StopReason='Durata richiesta conclusa.';break}
        $stop=Read-AgentJson (Join-Path $script:agentDirectory 'stop.json') 4096
        if($stop -and $stop.run_id -ceq $script:agentRunId){$script:agent.StopReason='Arresto richiesto dall utente.';break}
        if($null -ne $script:agent.LastLoopClock -and ($now-$script:agent.LastLoopClock -gt 12 -or $utc -lt $script:agent.LastLoopUtc -or ($utc-$script:agent.LastLoopUtc).TotalSeconds -gt 12)){
            $script:agent.PressureSince=$null;$script:agent.LastTelemetry=$null
            if($script:agent.Pending){Set-AgentResult $(if($script:agent.Pending.Phase -eq 'awaiting_ack'){'unknown'}else{'incomplete'}) 'Sospensione o continuita persa: nessun retry.'}
        }
        $script:agent.LastLoopClock=$now;$script:agent.LastLoopUtc=$utc
        Poll-AgentInventory $now;Poll-AgentBrowser $now;Poll-AgentInternalApiBus $now
        if($script:agent.StopReason){break}
        if($null -eq $script:agent.LastMetrics -or $now-$script:agent.LastMetrics -ge 5){
            foreach($browser in @($script:agent.Profiles.Values|Where-Object Ready|ForEach-Object {$_.Browser}|Select-Object -Unique)){
                try{
                    if(!$script:agent.Samplers.ContainsKey($browser)){$script:agent.Samplers[$browser]=[AmeComparison.Sampler]::new($browser.ToLowerInvariant(),$PSScriptRoot)}
                    $reading=$script:agent.Samplers[$browser].Read();$script:agent.Readings[$browser]=@{At=$clock.Elapsed.TotalSeconds;Reading=$reading}
                    if($null -ne $reading.OwnPrivateBytes -and $reading.OwnPrivateBytes -gt $script:agent.Config.maximum_own_private_mib*1MB){$script:agent.StopReason='Budget RAM privata AME superato: agente fermato.'}
                }catch{$script:agent.Readings.Remove($browser);if($script:agent.Pending -and $script:agent.Pending.Browser -eq $browser){Set-AgentResult 'incomplete' 'Lettura memoria non disponibile.'}}
            }
            $script:agent.LastMetrics=$now
        }
        if($script:agent.StopReason){break}
        $now=$clock.Elapsed.TotalSeconds
        Update-AgentAction $now
        [void](Invoke-DistributedMemoryCycle $now)
        if(!$script:agent.Pending -and $now -ge $script:agent.NextDecision){
            $script:agent.NextDecision=$now+5
            $candidate=Get-AgentCandidate $script:agent $now ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
            if($candidate){
                $cached=$script:agent.Readings[$candidate.Browser]
                if($cached -and $now-$cached.At -le 6){try{Start-AgentAction $candidate $cached.Reading $now}catch{$script:agent.Status=$_.Exception.Message;$script:agent.NextDecision=$now+60;Write-AgentEvent @{type='agent_declined';message=$_.Exception.Message}}}
                else{$script:agent.Status='Metriche del browser o costo AME non disponibili: nessun intervento.'}
            }
        }
        if($now -ge $nextStatus){Write-AgentStatus;$nextStatus=$now+5}
        if($now -ge $nextJournal){Write-AgentEvent @{type='agent_status';message=$script:agent.Status;process_count=@($script:agent.LastInventory).Count;own_private_bytes=$script:agent.OwnPrivateBytes;last_result=$script:agent.LastResult};$nextJournal=$now+30}
        Start-Sleep -Milliseconds 250
    }
}catch{
    if(!$script:agent){$script:agent=@{Phase='error';Status=$_.Exception.Message;Recent=@();Profiles=@{};LastInventory=@();Applied=0;Config=$null;Pending=$null;StopReason='';OwnPrivateBytes=$null;OwnCpu=$null;LastTelemetry=$null;LastResult=$null;HistoryFailure=''}}
    $script:agent.StopReason='Errore agente: '+$_.Exception.Message
    if($ownsAgent){try{Write-AgentEvent @{type='agent_error';message=$script:agent.StopReason}}catch{}}
    else{try{Write-AgentJson (Join-Path $script:agentDirectory 'startup-error.json') @{run_id=$script:agentRunId;message=$script:agent.StopReason} 4096}catch{}}
}finally{
    if($script:agent -and $script:agent.Pending){try{Set-AgentResult $(if($script:agent.Pending.Phase -eq 'awaiting_ack'){'unknown'}else{'incomplete'}) 'Agente fermato prima della conclusione. Le richieste gia inviate possono completarsi.'}catch{}}
    $restoredOnExit=0
    try{if($ownsAgent){$restoredOnExit=Restore-AllAgentProcesses}}catch{}
    try{if($script:agentApiBus){$script:agentApiBus.Dispose()}}catch{}
    try{if($script:agent -and $script:agent.NativeClient){$script:agent.NativeClient.Dispose()}}catch{}
    try{if($script:agentBridge){$script:agentBridge.Dispose()}}catch{}
    try{Stop-AgentInventory}catch{}
    if($script:agent -and $ownsAgent){
        $script:agent.Phase='stopped'
        $script:agent.Status=($script:agent.StopReason+' (Tutti i processi ripristinati alle impostazioni originali di Windows).')
        try{Write-AgentEvent @{type='agent_end';restored=$restoredOnExit;message=$script:agent.Status};Write-AgentStatus}catch{}
    }
    if($mutationLock){$mutationLock.Dispose()};if($hubLock){$hubLock.Dispose()};$clock.Stop()
}
