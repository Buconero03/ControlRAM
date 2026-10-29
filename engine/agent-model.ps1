# Pure policy and feedback: this file never changes application memory.
function Get-AgentConfig([string]$Path) {
    if((Get-Item -LiteralPath $Path).Length -gt 16KB){throw 'Configurazione agente oltre 16 KiB.'}
    $c=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json
    if($c.schema_version -ne 1 -or $c.automatic_browser_release -isnot [bool]){throw 'Configurazione agente non valida.'}
    foreach($rule in @(@('pressure_percent',80,99),@('pressure_seconds',30,600),@('minimum_inactive_minutes',15,1440),@('observation_seconds',300,900),@('minimum_net_mib',16,2048),@('global_cooldown_seconds',300,86400),@('maximum_actions_hour',1,4),@('maximum_actions_day',1,16),@('maximum_own_private_mib',64,1024),@('maximum_own_cpu_percent',1,10))){
        $v=$c.PSObject.Properties[$rule[0]].Value
        if($null -eq $v -or [double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v) -or [double]$v -ne [math]::Floor([double]$v) -or $v -lt $rule[1] -or $v -gt $rule[2]){throw ('Configurazione agente: valore non valido per '+$rule[0])}
    }
    foreach($flag in @('automatic_windows_reclaim','automatic_internal_compact','automatic_browser_subprocesses','memory_compression_auto_flush','background_cpu_priority_demotion')){
        if($null -eq $c.PSObject.Properties[$flag]){$c|Add-Member NoteProperty $flag $true -Force}
        elseif($c.$flag -isnot [bool]){throw ('Configurazione agente: flag booleano non valido per '+$flag)}
    }
    foreach($opt in @(@('soft_pressure_percent',30,95,80),@('distributed_max_batch_processes',1,128,16),@('distributed_target_reclaim_mib',32,16384,2048),@('memory_compression_flush_hours',1,48,5),@('memory_compression_flush_threshold_mib',100,16384,1500),@('reclaim_process_pacing_ms',0,1000,60),@('background_cpu_rate_cap_percent',0,100,10),@('clamp_target_threshold_mib',64,65536,1200))){
        if($null -eq $c.PSObject.Properties[$opt[0]]){$c|Add-Member NoteProperty $opt[0] $opt[3] -Force}
        else{
            $v=$c.PSObject.Properties[$opt[0]].Value
            if($null -eq $v -or [double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v) -or [double]$v -ne [math]::Floor([double]$v) -or $v -lt $opt[1] -or $v -gt $opt[2]){throw ('Configurazione agente: valore non valido per '+$opt[0])}
        }
    }
    if($null -eq $c.PSObject.Properties['operation_mode']){$c|Add-Member NoteProperty 'operation_mode' 'standard' -Force}
    elseif($c.operation_mode -notin @('standard','multilane','clamp')){throw 'Configurazione agente: operation_mode deve essere standard, multilane o clamp.'}
    if($null -eq $c.PSObject.Properties['clamp_target_process']){$c|Add-Member NoteProperty 'clamp_target_process' '' -Force}
    return $c
}
function New-AgentState($Config) {
    return @{Config=$Config;Profiles=@{};History=@();Pending=$null;Recent=@();PressureSince=$null;LastTelemetry=$null;LastInventory=@();InventoryAt=$null;
        Status='Avvio osservazione automatica.';Phase='starting';Applied=0;LastSampleClock=$null;Readings=@{};Samplers=@{};LastMetrics=$null;
        HistoryFailure='';InventoryFailure='';OwnPrivateBytes=$null;OwnCpu=$null;OwnCpuOverSince=$null;StopReason='';LastDecision='';LastLoopClock=$null;LastLoopUtc=$null;LastResult=$null;KnownRequests=@{};NextDecision=0.0;
        NativeClient=$null;ActiveObservations=@{};ProcessCooldowns=@{};ModifiedProcesses=@{};ClampedProcesses=@{};InternalCompactions=0;WindowsReclaims=0;BrowserSubprocessReclaims=0;RestoredProcesses=0;LastDistributedCycle=0.0;LastInternalCompact=0.0;
        CompressionFlushes=0;LastCompressionFlushEpoch=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();MemoryCompressionMiB=0.0}
}
function Test-AgentHost([string]$HostName) {return $HostName.Length -le 253 -and $HostName -cmatch '^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$' -and $HostName.Contains('.') -and !$HostName.Contains('..')}
function ConvertTo-AgentUtc($Value) {
    if($Value -is [DateTime]){return $Value.ToUniversalTime()}
    if($Value -is [DateTimeOffset]){return $Value.UtcDateTime}
    return [DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None).UtcDateTime
}
function Get-AgentHistory([string]$Path,[DateTime]$Now=[DateTime]::UtcNow) {
    if(!(Test-Path -LiteralPath $Path)){return @()}
    if((Get-Item -LiteralPath $Path).Length -gt 1MB){throw 'Storico agente oltre 1 MiB: interventi bloccati.'}
    $saved=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json
    if($saved.schema_version -ne 1 -or $null -eq $saved.actions -or @($saved.actions).Count -gt 512){throw 'Storico agente non valido: interventi bloccati.'}
    $ids=@{}
    foreach($r in @($saved.actions)){
        $g=[guid]::Empty;$stamp=ConvertTo-AgentUtc $r.utc
        if(![guid]::TryParse([string]$r.request,[ref]$g) -or $ids.ContainsKey([string]$r.request) -or $r.browser -notin @('Chrome','Firefox') -or !(Test-AgentHost ([string]$r.host)) -or
           $stamp -gt $Now.AddMinutes(1) -or
           $r.outcome -notin @('intent','discarded','observed_retained','short_benefit','small_benefit','incomplete','declined','not_sent','unknown','activity_cost')){throw 'Record storico agente non valido: interventi bloccati.'}
        $ids[[string]$r.request]=$true
        $r.utc=$stamp.ToString('o')
        if($stamp -ge $Now.AddDays(-7)){Write-Output $r}
    }
}
function Get-AgentBlock($State,[string]$Browser,[string]$HostName,[DateTime]$Now=[DateTime]::UtcNow) {
    if($State.HistoryFailure){return $State.HistoryFailure}
    $hour=@();$day=@()
    foreach($r in $State.History){
        $age=($Now-(ConvertTo-AgentUtc $r.utc)).TotalSeconds
        if($age -lt 0){return 'Orologio cambiato: storico da verificare.'}
        if($age -lt 86400){$day+=@($r)}
        if($age -lt 3600){$hour+=@($r)}
        if($age -lt $State.Config.global_cooldown_seconds){return 'Pausa tra gli interventi automatici.'}
        if($age -lt 3600 -and $r.outcome -in @('intent','discarded','unknown','activity_cost','incomplete')){return 'Verifica precedente incerta o attivita aumentata: pausa di un ora.'}
        if($r.browser -eq $Browser -and $r.host -ceq $HostName){
            $limit=if($r.outcome -in @('short_benefit','small_benefit','activity_cost','unknown','intent','discarded')){86400}else{3600}
            if($age -lt $limit){return 'Sito in attesa dopo il risultato precedente.'}
        }
    }
    if($hour.Count -ge $State.Config.maximum_actions_hour){return 'Limite di interventi per ora raggiunto.'}
    if($day.Count -ge $State.Config.maximum_actions_day){return 'Limite giornaliero raggiunto.'}
    return ''
}
function Update-AgentTelemetry($State,$Sample,[double]$At,[double]$Now) {
    if($Sample.type -ne 'sample' -or $null -eq $Sample.physical_total_bytes -or $Sample.physical_total_bytes -le 0 -or
       $null -eq $Sample.physical_available_bytes -or $Sample.physical_available_bytes -lt 0 -or $Sample.physical_available_bytes -gt $Sample.physical_total_bytes -or
       [double]::IsNaN([double]$Sample.physical_total_bytes) -or [double]::IsInfinity([double]$Sample.physical_total_bytes) -or [double]::IsNaN([double]$Sample.physical_available_bytes) -or [double]::IsInfinity([double]$Sample.physical_available_bytes) -or [double]::IsNaN($At) -or [double]::IsInfinity($At) -or $Now-$At -gt 8 -or $At-$Now -gt 1){return}
    if($State.LastTelemetry -and ($At -le $State.LastTelemetry.At -or $At-$State.LastTelemetry.At -gt 12)){$State.PressureSince=$null}
    $percent=100*(1-[double]$Sample.physical_available_bytes/[double]$Sample.physical_total_bytes)
    $State.LastTelemetry=@{At=$At;Percent=$percent;AvailableBytes=$Sample.physical_available_bytes;TotalBytes=$Sample.physical_total_bytes}
    if($percent -ge $State.Config.pressure_percent){if($null -eq $State.PressureSince){$State.PressureSince=$At}}else{$State.PressureSince=$null}
    if($Sample.process_snapshot_complete){$State.LastInventory=@($Sample.processes);$State.InventoryAt=$At}
}
function Get-AgentCandidate($State,[double]$Now,[long]$EpochMilliseconds) {
    if(!$State.Config.automatic_browser_release){$State.Status='Sola osservazione: automatico disattivato nella configurazione.';return $null}
    if($State.Pending){return $null}
    if($State.HistoryFailure -or $State.InventoryFailure){$State.Status='Interventi bloccati: '+$State.HistoryFailure+' '+$State.InventoryFailure;return $null}
    if(!$State.LastTelemetry -or $Now-$State.LastTelemetry.At -gt 8 -or $null -eq $State.InventoryAt -or $Now-$State.InventoryAt -gt 20){$State.Status='Attendo telemetria e inventario completi e aggiornati.';return $null}
    if($null -eq $State.PressureSince -or $Now-$State.PressureSince -lt $State.Config.pressure_seconds){$State.Status='Osservo tutti i processi; attendo pressione RAM persistente. Nessun intervento necessario o ancora idoneo.';return $null}
    $candidates=@();$authorized=0;$blocked=''
    foreach($id in @($State.Profiles.Keys)){
        $p=$State.Profiles[$id]
        if(!$p.Ready -or !$p.AutoCapable -or $p.Truncated -or $Now-$p.Seen -ge 25){continue}
        foreach($tab in $p.Tabs){
            if($tab.auto_allowed -ne $true){continue};$authorized++
            if($tab.blocked -or $tab.discarded -or !(Test-AgentHost ([string]$tab.host)) -or $null -eq $tab.lastAccessed){continue}
            $age=$EpochMilliseconds-[double]$tab.lastAccessed
            if([double]::IsNaN($age) -or [double]::IsInfinity($age) -or $tab.lastAccessed -le 0 -or $age -lt $State.Config.minimum_inactive_minutes*60000){continue}
            $reason=Get-AgentBlock $State $p.Browser $tab.host
            if($reason){$blocked=$reason;continue}
            $candidates+=@([pscustomobject]@{Connection=[int]$id;Session=$p.Session;Browser=$p.Browser;Tab=[long]$tab.id;Revision=[string]$tab.revision;Host=[string]$tab.host;LastAccessed=[double]$tab.lastAccessed})
        }
    }
    if(!$candidates.Count){$State.Status=if($blocked){$blocked}elseif(!$authorized){'Nessun sito autorizzato pronto: collega l estensione 0.5.0 e autorizza i siti ricaricabili.'}else{'Nessuna scheda autorizzata idonea: rispetto protezioni e almeno 15 minuti di inattivita.'};return $null}
    return @($candidates|Sort-Object LastAccessed,Browser,Tab)[0]
}
function Get-DistributedReclaimPlan($State,[double]$Now,[bool]$Force=$false) {
    if(!$State.LastTelemetry -or $Now-$State.LastTelemetry.At -gt 8 -or $null -eq $State.InventoryAt -or $Now-$State.InventoryAt -gt 20){return $null}
    $percent=[double]$State.LastTelemetry.Percent
    $softPressure=$Force -or ($percent -ge $State.Config.soft_pressure_percent)
    $hardPressure=$Force -or ($null -ne $State.PressureSince -and ($Now-$State.PressureSince) -ge $State.Config.pressure_seconds) -or ($percent -ge $State.Config.pressure_percent)
    if(!$softPressure -and !$hardPressure){return $null}

    $internalCompact=$false
    if($State.Config.automatic_internal_compact -and ($Force -or (($Now-$State.LastInternalCompact -ge 120) -and ($null -eq $State.OwnPrivateBytes -or $State.OwnPrivateBytes -ge 24MB -or $hardPressure)))){
        $internalCompact=$true
    }

    $rows=@($State.LastInventory)
    $browserCandidates=@()
    $windowsCandidates=@()
    $fgImage=''
    foreach($r in $rows){if($r.foreground_window_owner -eq $true -and $r.image_path){$fgImage=[string]$r.image_path;break}}

    $browserParentPids=@{}
    foreach($r in $rows){
        $n=([string]$r.name).ToLowerInvariant()
        if($n -in @('chrome.exe','firefox.exe','msedge.exe','brave.exe')){$browserParentPids[[int]$r.pid]=$true}
    }

    # Dev/IDE runtimes: Stage 10 (MemoryPriority + WorkingSetTrim, NO EcoQoS CPU throttling so they never freeze)
    $devRuntimeTargets=@(
        'antigravity.exe','language_server_windows_x64.exe','language_server.exe','codex.exe',
        'code.exe','cursor.exe','node.exe','node_repl.exe','bun.exe','deno.exe',
        'python.exe','pythonw.exe','powershell.exe','pwsh.exe','postgres.exe','sqlservr.exe','wsl.exe'
    )
    # Background Desktop/AI & UWP apps: Stage 14 (MemoryPriority + EcoQoS + WorkingSetTrim when in background)
    $backgroundAppTargets=@(
        'chatgpt.exe','claude.exe','gemini.exe','msedgewebview2.exe',
        'searchhost.exe','phoneexperiencehost.exe','widgetboard.exe','widgets.exe',
        'crossdeviceservice.exe','backgroundtaskhost.exe','onedrive.exe','nvcontainer.exe','notepad.exe'
    )
    # Core OS shell/services: completely excluded so Windows taskbar, input, and services never glitch
    $excludedCoreOs=@(
        'ame.exe','ame-browser-host.exe','explorer.exe','dwm.exe','csrss.exe','lsass.exe','smss.exe',
        'services.exe','wininit.exe','winlogon.exe','svchost.exe','sihost.exe','taskhostw.exe',
        'runtimebroker.exe','textinputhost.exe','startmenuexperiencehost.exe','shellhost.exe',
        'shellexperiencehost.exe','applicationframehost.exe','dllhost.exe','fontdrvhost.exe','ctfmon.exe','conhost.exe'
    )

    foreach($r in $rows){
        if($r.same_user -ne $true -or $r.critical -eq $true -or $r.foreground_window_owner -eq $true -or !$r.memory_available -or $null -eq $r.private_working_set_bytes){continue}
        if(!$r.image_path -or !$r.creation_filetime -or [int]$r.pid -le 4){continue}
        $key=([string]$r.pid+':'+[string]$r.creation_filetime)
        if(!$Force -and $State.ProcessCooldowns.ContainsKey($key) -and ($Now-[double]$State.ProcessCooldowns[$key]) -lt 120){continue}
        $name=([string]$r.name).ToLowerInvariant()
        if($name -in $excludedCoreOs){continue}

        $priv=[double]$r.private_working_set_bytes
        $idle=if($null -ne $r.low_activity_seconds){[double]$r.low_activity_seconds}else{0.0}
        $cpu=if($null -ne $r.cpu_percent){[double]$r.cpu_percent}elseif($Force){0.0}else{99.0}
        $isSameAsFg=($fgImage -and [string]::Equals([string]$r.image_path,$fgImage,[StringComparison]::OrdinalIgnoreCase))

        if($name -in @('chrome.exe','firefox.exe','msedge.exe','brave.exe')){
            $minBrIdle=if($Force){0}else{15}
            $maxBrCpu=if($Force){3.0}else{0.8}
            if($State.Config.automatic_browser_subprocesses -and $browserParentPids.ContainsKey([int]$r.parent_pid) -and $priv -ge 24MB -and $idle -ge $minBrIdle -and $cpu -lt $maxBrCpu){
                $stages=if($isSameAsFg -or !$State.Config.background_cpu_priority_demotion){[uint32]10}else{[uint32]14}
                $browserCandidates+=@([pscustomobject]@{Pid=[uint32]$r.pid;Key=$key;Path=[string]$r.image_path;Name=[string]$r.name;PrivateBytes=$priv;Stages=$stages;Lane='browser_subprocess'})
            }
        }elseif($State.Config.automatic_windows_reclaim){
            $isDevRuntime=($name -in $devRuntimeTargets) -or ($name -like 'language_server*') -or ($name -like '*antigravity*')
            $isBgApp=($name -in $backgroundAppTargets)
            $isPriority=($isDevRuntime -or $isBgApp)
            $minIdle=if($Force){0}elseif($isPriority){10}elseif($hardPressure){15}else{20}
            $minMem=if($isPriority){8MB}elseif($hardPressure){32MB}else{48MB}
            $maxCpu=if($Force){8.0}elseif($isPriority){2.0}else{1.0}
            if($priv -ge $minMem -and $idle -ge $minIdle -and $cpu -lt $maxCpu){
                # Never apply EcoQoS (4) to dev runtimes, foreground sibling processes, or if CPU demotion is disabled
                $stages=if($isDevRuntime -or $isSameAsFg -or !$State.Config.background_cpu_priority_demotion){[uint32]10}else{[uint32]14}
                $windowsCandidates+=@([pscustomobject]@{Pid=[uint32]$r.pid;Key=$key;Path=[string]$r.image_path;Name=[string]$r.name;PrivateBytes=$priv;Stages=$stages;Lane='windows_process'})
            }
        }
    }

    $maxBatch=if($Force){128}else{[int]$State.Config.distributed_max_batch_processes}
    $browserSelected=@($browserCandidates|Sort-Object PrivateBytes -Descending|Select-Object -First $maxBatch)
    $windowsSelected=@($windowsCandidates|Sort-Object PrivateBytes -Descending|Select-Object -First $maxBatch)

    if(!$internalCompact -and !$browserSelected.Count -and !$windowsSelected.Count){return $null}
    return [pscustomobject]@{
        SoftPressure=$softPressure
        HardPressure=$hardPressure
        RamPercent=$percent
        TargetBudgetBytes=([uint64]$State.Config.distributed_target_reclaim_mib * 1MB)
        CompactInternal=$internalCompact
        BrowserSubprocesses=$browserSelected
        WindowsProcesses=$windowsSelected
    }
}
function Test-AgentReading($Reading) {
    if(!$Reading -or !$Reading.Complete -or $Reading.AppProcesses -lt 1){return $false}
    foreach($name in @('AppPrivateBytes','OwnPrivateBytes','AppCommitBytes','AvailableBytes','TotalBytes')){
        $v=$Reading.$name
        if($null -eq $v -or [double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v) -or [double]$v -lt 0){return $false}
    }
    return $Reading.TotalBytes -gt 0 -and $Reading.AvailableBytes -le $Reading.TotalBytes
}
function New-AgentObservation($Reading,[double]$At,$Config) {
    if(!(Test-AgentReading $Reading) -or [double]::IsNaN($At) -or [double]::IsInfinity($At)){throw 'Lettura browser o costo AME incompleta.'}
    if($Reading.OwnPrivateBytes -gt $Config.maximum_own_private_mib*1MB){throw 'Consumo privato residente AME oltre il budget configurato.'}
    if($Reading.AppPrivateBytes -lt $Reading.OwnPrivateBytes+$Config.minimum_net_mib*1MB){throw 'Memoria del browser troppo piccola rispetto al costo AME e alla soglia minima.'}
    return @{Before=$Reading;Started=$At;Last=$null;LastSeconds=$null;BestDrop=0.0;BestNet=0.0;Samples=@();Count=0;ReboundSince=$null;CostWarning=$false;ProcessChanges=$false}
}
function Add-AgentObservation($Observation,$Reading,[double]$At,$Config) {
    $s=$Observation;$seconds=$At-$s.Started
    if(!(Test-AgentReading $Reading) -or [double]::IsNaN($At) -or [double]::IsInfinity($At) -or
       $seconds -lt 0 -or ($null -eq $s.LastSeconds -and $seconds -gt 12) -or ($null -ne $s.LastSeconds -and ($seconds -le $s.LastSeconds -or $seconds-$s.LastSeconds -gt 12))){throw 'Misura incompleta o continuita persa.'}
    $drop=[double]$s.Before.AppPrivateBytes-[double]$Reading.AppPrivateBytes;$net=$drop-[double]$Reading.OwnPrivateBytes
    $s.BestDrop=[math]::Max($s.BestDrop,$drop);$s.BestNet=[math]::Max($s.BestNet,$net);$s.LastSeconds=$seconds;$s.Last=$Reading;$s.Count++
    if($s.Before.IdentityKey -cne $Reading.IdentityKey){$s.ProcessChanges=$true}
    $s.Samples=@($s.Samples|Where-Object {$_.Seconds -ge $seconds-60})+@([pscustomobject]@{Seconds=$seconds;Net=$net;Drop=$drop})
    if($s.Samples.Count -gt 30){throw 'Limite dei campioni finestra superato.'}
    if($s.Before.CounterCoverageComplete -and $Reading.CounterCoverageComplete){
        foreach($metric in @(@('CpuPercent',5),@('PageFaultsPerSecond',1000),@('IoReadBytesPerSecond',4MB))){
            if($null -ne $s.Before.($metric[0]) -and $null -ne $Reading.($metric[0]) -and $Reading.($metric[0]) -gt $s.Before.($metric[0])+$metric[1]){$s.CostWarning=$true}
        }
    }
    $outcome='observing'
    if($seconds -ge 5 -and $s.BestDrop -gt 0 -and $drop -le $s.BestDrop*0.2){if($null -eq $s.ReboundSince){$s.ReboundSince=$seconds}}else{$s.ReboundSince=$null}
    if($null -ne $s.ReboundSince -and $seconds-$s.ReboundSince -ge 10){$outcome='short_benefit'}
    elseif($seconds -ge 60 -and $s.BestNet -lt $Config.minimum_net_mib*1MB){$outcome='small_benefit'}
    elseif($seconds -ge $Config.observation_seconds){
        $last=@($s.Samples);$min=($last|Measure-Object -Property Net -Minimum).Minimum
        $outcome=if($last.Count -ge 10 -and $last[0].Seconds -le $seconds-50 -and $min -ge $Config.minimum_net_mib*1MB){'observed_retained'}else{'short_benefit'}
    }
    if($outcome -ne 'observing' -and $s.CostWarning){$outcome='activity_cost'}
    return [pscustomobject]@{Outcome=$outcome;Seconds=$seconds;DropBytes=$drop;OwnPrivateBytes=$Reading.OwnPrivateBytes;NetObservedDropBytes=$net;CommitDropBytes=([double]$s.Before.AppCommitBytes-[double]$Reading.AppCommitBytes);
        SystemAvailableDeltaBytes=([double]$Reading.AvailableBytes-[double]$s.Before.AvailableBytes);CostWarning=$s.CostWarning;ProcessChanges=$s.ProcessChanges;CausationEstablished=$false;HardFaultsMeasured=$false;ApplicationLatencyMeasured=$false;ActivityCountersAvailable=([bool]$s.Before.CounterCoverageComplete -and [bool]$Reading.CounterCoverageComplete)}
}
