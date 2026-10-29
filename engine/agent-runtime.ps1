function Write-AgentEvent([hashtable]$Event) {
    $Event.utc=[DateTime]::UtcNow.ToString('o');$Event.run_id=$script:agentRunId
    $encoding=New-Object Text.UTF8Encoding($false);$line=($Event|ConvertTo-Json -Depth 10 -Compress)+"`n"
    if($encoding.GetByteCount($line) -gt 64KB){throw 'Evento agente oltre 64 KiB.'}
    $path=Join-Path $script:agentDirectory 'agent-events-0.jsonl'
    if((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length+$encoding.GetByteCount($line) -gt 2MB){
        $last=Join-Path $script:agentDirectory 'agent-events-3.jsonl';if(Test-Path -LiteralPath $last){[IO.File]::Delete($last)}
        for($i=2;$i -ge 0;$i--){$old=Join-Path $script:agentDirectory ('agent-events-'+$i+'.jsonl');if(Test-Path -LiteralPath $old){[IO.File]::Move($old,(Join-Path $script:agentDirectory ('agent-events-'+($i+1)+'.jsonl')))}}
    }
    [IO.File]::AppendAllText($path,$line,$encoding)
    if($Event.message){$script:agent.Recent=@($script:agent.Recent|Select-Object -Last 59)+@((Get-Date -Format 'HH:mm:ss')+' '+[string]$Event.message)}
}
function Save-AgentHistory {
    $now=[DateTime]::UtcNow
    $script:agent.History=@($script:agent.History|Where-Object {(ConvertTo-AgentUtc $_.utc) -ge $now.AddDays(-7)}|Select-Object -Last 512)
    try{Write-AgentJson (Join-Path $script:agentDirectory 'history.json') @{schema_version=1;actions=@($script:agent.History)} 1MB}
    catch{$script:agent.HistoryFailure='Salvataggio storico fallito: nessun altro intervento.';throw}
}
function Set-AgentResult([string]$Outcome,[string]$Message,$Assessment=$null) {
    $pending=$script:agent.Pending
    if(!$pending){return}
    $pending.Record.outcome=$Outcome
    $pending.Record|Add-Member NoteProperty message $Message -Force
    if($Assessment){$pending.Record|Add-Member NoteProperty assessment $Assessment -Force}
    Save-AgentHistory
    Write-AgentEvent @{type='agent_assessed';request=$pending.Request;browser=$pending.Browser;host=$pending.Host;outcome=$Outcome;assessment=$Assessment;message=$Message;causation_established=$false;application_latency_measured=$false;hard_faults_measured=$false}
    $script:agent.Status=$Message;$script:agent.Pending=$null
    $script:agent.LastResult=@{request=$pending.Request;utc=[DateTime]::UtcNow.ToString('o');outcome=$Outcome;message=$Message;assessment=$Assessment;browser=$pending.Browser;host=$pending.Host}
}
function Receive-AgentBrowser([int]$Connection,$Event,[double]$Now) {
    $a=$script:agent
    if($Event.type -eq 'hello'){
        $g=[guid]::Empty
        if($Event.protocol -ne 4 -or ![guid]::TryParse([string]$Event.session,[ref]$g) -or $a.Profiles.ContainsKey($Connection)){throw 'Presentazione browser non valida.'}
        $browser=if($Event.extension -ceq $script:agentBrowserConfig.extension_id){'Chrome'}elseif($Event.extension -ceq $script:agentBrowserConfig.firefox_extension_id){'Firefox'}else{throw 'Estensione non riconosciuta.'}
        if($Event.browser -and $Event.browser -cne $browser){throw 'Identita browser incoerente.'}
        $a.Profiles[$Connection]=@{Browser=$browser;Session=[string]$Event.session;Ready=$false;AutoCapable=(@($Event.capabilities) -contains 'automatic-site-policy-v1');Seen=$Now;LastSequence=0L;Tabs=@();Truncated=$false}
        if(!$script:agentBridge.Send($Connection,(@{type='welcome';protocol=4;session=$Event.session;agent_mode='automatic_authorized_sites'}|ConvertTo-Json -Compress))){throw 'Risposta al browser non inviata.'}
        Write-AgentEvent @{type='agent_connection';browser=$browser;connection=$Connection;message=($browser+': richiesta di collegamento ricevuta. Attendo l elenco.')}
        return
    }
    $p=$a.Profiles[$Connection]
    if(!$p -or $Event.session -cne $p.Session){throw 'Sessione browser non riconosciuta.'}
    if($Event.type -eq 'snapshot'){
        if($Event.protocol -ne 4 -or $null -eq $Event.sequence -or [double]$Event.sequence -ne [long]$Event.sequence -or $Event.sequence -le $p.LastSequence -or $null -eq $Event.tabs -or @($Event.tabs).Count -gt 300){throw 'Elenco schede o sequenza non validi.'}
        $seen=@{}
        foreach($tab in @($Event.tabs)){
            $revision=[guid]::Empty
            if($null -eq $tab.id -or $tab.id -lt 0 -or [double]$tab.id -ne [long]$tab.id -or $seen.ContainsKey([long]$tab.id) -or ![guid]::TryParse([string]$tab.revision,[ref]$revision) -or
               ([string]$tab.title).Length -gt 160 -or ([string]$tab.blocked).Length -gt 240 -or $tab.discarded -isnot [bool] -or ([string]$tab.host).Length -gt 253 -or ($null -ne $tab.auto_allowed -and $tab.auto_allowed -isnot [bool])){throw 'Metadati scheda non validi.'}
            $seen[[long]$tab.id]=$true
        }
        $first=!$p.Ready;$p.Tabs=@($Event.tabs);$p.LastSequence=[long]$Event.sequence;$p.Seen=$Now;$p.Truncated=[bool]$Event.truncated
        if(!$script:agentBridge.Send($Connection,(@{type='inventory_ack';protocol=4;session=$p.Session;sequence=$p.LastSequence;count=$p.Tabs.Count}|ConvertTo-Json -Compress))){throw 'Conferma inventario non inviata.'}
        $p.Ready=$true
        if($first){Write-AgentEvent @{type='agent_connection';browser=$p.Browser;connection=$Connection;message=($p.Browser+': COLLEGATO, '+$p.Tabs.Count+' schede. '+$(if($p.AutoCapable){'Autorizzazioni automatiche supportate.'}else{'Aggiorna l estensione a 0.5.0 per l automatico.'}))}}
        $pending=$a.Pending
        if($pending -and $pending.Connection -eq $Connection -and $pending.Phase -eq 'observing' -and $p.LastSequence -gt $pending.SequenceAtAck){
            $target=@($p.Tabs|Where-Object {$_.id -eq $pending.Tab})
            if($target.Count -ne 1){Set-AgentResult 'incomplete' 'Scheda non piu presente: misura incompleta.'}
            elseif(!$target[0].discarded){Set-AgentResult 'short_benefit' 'Scheda tornata in uso: beneficio limitato all inattivita. Nessun nuovo tentativo su questo sito per 24 ore.'}
        }
    }elseif($Event.type -eq 'result'){
        $pending=$a.Pending
        $known=$a.KnownRequests[[string]$Event.request]
        if(!$known -or !$p.Ready -or $known.Connection -ne $Connection -or $known.Session -cne $p.Session -or $known.Tab -ne $Event.tab -or $known.Handled){return}
        $known.Handled=$true
        if(!$pending -or $pending.Request -cne [string]$Event.request -or $pending.Phase -ne 'awaiting_ack'){
            if($Event.outcome -eq 'discarded'){
                $known.DiscardConfirmed=$true
                $a.Applied++;$known.Record.outcome='incomplete';$known.Record|Add-Member NoteProperty late_discard_confirmed $true -Force
                $lateMessage='Scaricamento confermato tardivamente: misura incompleta. Nessun retry.'
                $known.Record|Add-Member NoteProperty message $lateMessage -Force;Save-AgentHistory
                if(!$a.LastResult -or $a.LastResult.request -ceq [string]$Event.request){$a.LastResult=@{request=$Event.request;utc=[DateTime]::UtcNow.ToString('o');browser=$p.Browser;host=$known.Record.host;outcome='incomplete';message=$lateMessage;assessment=$null}}
                Write-AgentEvent @{type='browser_result';browser=$p.Browser;request=$Event.request;tab=$Event.tab;outcome='discarded';late=$true;message='Scaricamento confermato tardivamente: misura incompleta. Nessun retry.'}
            }
            return
        }
        if($Event.outcome -notin @('discarded','declined')){Set-AgentResult 'unknown' 'Esito browser non riconosciuto: nessun altro tentativo.';return}
        Write-AgentEvent @{type='browser_result';browser=$p.Browser;request=$Event.request;tab=$Event.tab;outcome=$Event.outcome;reason=$Event.reason;operation_ms=$Event.operation_ms;authorization='site_policy_v1';manual_confirmation=$false}
        if($Event.outcome -eq 'discarded'){
            $known.DiscardConfirmed=$true
            $a.Applied++;$pending.Record.outcome='discarded';Save-AgentHistory
            $pending.Phase='observing';$pending.SequenceAtAck=$p.LastSequence;$pending.Observation.Started=$Now;$pending.NextSample=$Now+5
            $a.Status='Scaricamento confermato. Misuro la durata e il costo AME per '+$a.Config.observation_seconds+' secondi; nessun altro intervento nel frattempo.'
        }else{Set-AgentResult 'declined' ('Browser: nessuno scaricamento confermato. '+[string]$Event.reason)}
    }elseif($Event.type -eq 'tab-return'){
        $known=$a.KnownRequests[[string]$Event.request]
        if(!$known -or !$known.DiscardConfirmed -or $known.ReturnRecorded -or $known.Connection -ne $Connection -or $known.Tab -ne $Event.tab -or $null -eq $Event.load_observed_ms -or [double]::IsNaN([double]$Event.load_observed_ms) -or [double]::IsInfinity([double]$Event.load_observed_ms) -or [double]$Event.load_observed_ms -lt 0 -or [double]$Event.load_observed_ms -gt 3600000){return}
        $known.ReturnRecorded=$true
        Write-AgentEvent @{type='agent_reactivation';request=$Event.request;load_observed_ms=$Event.load_observed_ms;application_ready_measured=$false}
        if($a.Pending -and $a.Pending.Request -ceq [string]$Event.request -and $a.Pending.Tab -eq $Event.tab -and $a.Pending.Connection -eq $Connection){Set-AgentResult 'short_benefit' 'Scheda tornata in uso: beneficio breve; sito in pausa per 24 ore.'}
    }else{throw 'Messaggio browser non supportato.'}
}
function Poll-AgentBrowser([double]$Now) {
    foreach($entry in $script:agentBridge.Drain()){
        $connection=[int]$entry.Connection
        try{
            if($entry.Error){throw [string]$entry.Error}
            Receive-AgentBrowser $connection ($entry.Json|ConvertFrom-Json) $Now
        }catch{
            if($script:agent.Pending -and $script:agent.Pending.Connection -eq $connection){Set-AgentResult $(if($script:agent.Pending.Phase -eq 'awaiting_ack'){'unknown'}else{'incomplete'}) ('Collegamento perso: '+$_.Exception.Message)}
            $script:agent.Profiles.Remove($connection);$script:agentBridge.Disconnect($connection)
            Write-AgentEvent @{type='agent_connection';connection=$connection;message=('Collegamento non disponibile: '+$_.Exception.Message)}
        }
    }
    foreach($connection in @($script:agent.Profiles.Keys)){
        $p=$script:agent.Profiles[$connection];$limit=if($p.Ready){30}else{15}
        if($Now-$p.Seen -ge $limit){
            if($script:agent.Pending -and $script:agent.Pending.Connection -eq $connection){Set-AgentResult $(if($script:agent.Pending.Phase -eq 'awaiting_ack'){'unknown'}else{'incomplete'}) 'Aggiornamenti browser scaduti: misura incompleta.'}
            $script:agent.Profiles.Remove($connection);$script:agentBridge.Disconnect([int]$connection)
            Write-AgentEvent @{type='agent_connection';message=($p.Browser+': NON COLLEGATO, inventario non aggiornato.')}
        }
    }
}
function Start-AgentAction($Candidate,$Reading,[double]$Now) {
    $a=$script:agent
    if($a.Pending){return}
    $current=Get-AgentCandidate $a $Now ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    if(!$current -or $current.Connection -ne $Candidate.Connection -or $current.Session -cne $Candidate.Session -or $current.Tab -ne $Candidate.Tab -or $current.Revision -cne $Candidate.Revision -or $current.Host -cne $Candidate.Host){throw 'Autorizzazione o condizioni automatiche cambiate prima dell invio.'}
    $observation=New-AgentObservation $Reading $Now $a.Config
    $profile=$a.Profiles[$Candidate.Connection]
    if(!$profile -or !$profile.Ready -or $profile.Session -cne $Candidate.Session -or $Now-$profile.Seen -ge 25){throw 'Collegamento cambiato prima dell azione.'}
    $match=@($profile.Tabs|Where-Object {$_.id -eq $Candidate.Tab -and $_.revision -ceq $Candidate.Revision -and $_.host -ceq $Candidate.Host -and $_.auto_allowed -eq $true -and !$_.blocked -and !$_.discarded})
    if($match.Count -ne 1){throw 'Scheda non piu autorizzata o idonea.'}
    $request=[guid]::NewGuid().ToString('D')
    $record=[pscustomobject]@{request=$request;browser=$Candidate.Browser;host=$Candidate.Host;utc=[DateTime]::UtcNow.ToString('o');outcome='intent'}
    $a.History+=@($record);Save-AgentHistory
    $a.Pending=@{Request=$request;Connection=$Candidate.Connection;Session=$Candidate.Session;Browser=$Candidate.Browser;Tab=$Candidate.Tab;Host=$Candidate.Host;Phase='awaiting_ack';Sent=$Now;Record=$record;Observation=$observation;NextSample=$null;SequenceAtAck=0L}
    $a.KnownRequests[$request]=@{Connection=$Candidate.Connection;Session=$Candidate.Session;Tab=$Candidate.Tab;Record=$record;Handled=$false;DiscardConfirmed=$false;ReturnRecorded=$false;Sent=$Now}
    if($a.KnownRequests.Count -gt 64){$old=@($a.KnownRequests.GetEnumerator()|Sort-Object {$_.Value.Sent}|Select-Object -First 1)[0];$a.KnownRequests.Remove($old.Key)}
    Write-AgentEvent @{type='agent_request';request=$request;browser=$Candidate.Browser;host=$Candidate.Host;tab=$Candidate.Tab;authorization='site_policy_v1';manual_confirmation=$false;message=($Candidate.Browser+': richiesta automatica su un sito autorizzato. Attendo conferma.')}
    $command=@{type='discard';session=$Candidate.Session;request=$request;tab=$Candidate.Tab;revision=$Candidate.Revision;confirmed=$false;authorization='site_policy_v1';deadline=[DateTimeOffset]::UtcNow.AddSeconds(8).ToUnixTimeMilliseconds()}
    if(!$script:agentBridge.Send($Candidate.Connection,($command|ConvertTo-Json -Compress))){Set-AgentResult 'not_sent' 'Richiesta non inviata. Nessun retry.'}
    else{$a.Status='Richiesta automatica inviata: nessuna riduzione RAM ancora confermata.'}
}
function Update-AgentAction([double]$Now) {
    $a=$script:agent;$p=$a.Pending
    if(!$p){return}
    if($p.Phase -eq 'awaiting_ack'){
        if($Now-$p.Sent -gt 20){Set-AgentResult 'unknown' 'Conferma non ricevuta: esito sconosciuto. Nessun retry; sito in pausa per 24 ore.'}
        return
    }
    if($Now -lt $p.NextSample){return}
    try{
        $cached=$a.Readings[$p.Browser]
        if($cached -and $Now-$cached.At -le 6 -and $cached.At -ge $p.Observation.Started){$reading=$cached.Reading}else{throw 'Metriche del browser recenti non disponibili.'}
        $feedback=Add-AgentObservation $p.Observation $reading $Now $a.Config
        $a.OwnPrivateBytes=$reading.OwnPrivateBytes;$p.NextSample=$Now+5
        Write-AgentEvent @{type='agent_feedback';request=$p.Request;browser=$p.Browser;feedback=$feedback}
        $a.Status=('{0}: {1:+0.0;-0.0;0.0} MiB privati residenti in meno, costo AME incluso. Durata {2:N0}/{3} s. Variazione osservata.' -f $p.Browser,($feedback.NetObservedDropBytes/1MB),$feedback.Seconds,$a.Config.observation_seconds)
        if($feedback.Outcome -ne 'observing'){
            $label=switch($feedback.Outcome){'observed_retained'{'Riduzione privata residente osservata per la durata prevista; causalita e prestazioni non verificate.'}'small_benefit'{'Beneficio netto osservato troppo piccolo: sito in pausa per 24 ore.'}'activity_cost'{'Attivita aumentata durante la misura: costo da verificare; sito in pausa per 24 ore.'}default{'Memoria risalita: beneficio breve; sito in pausa per 24 ore.'}}
            Set-AgentResult $feedback.Outcome $label $feedback
        }
    }catch{Set-AgentResult 'incomplete' ('Misura interrotta: '+$_.Exception.Message)}
}
function Start-AgentInventory([double]$Now) {
    $script:inventorySlot=1-$script:inventorySlot
    $path=Join-Path $script:agentDirectory ('inventory-'+$script:inventorySlot+'.jsonl')
    $stop=Join-Path $script:agentDirectory ('inventory-'+$script:inventorySlot+'.stop')
    foreach($file in @($path,$stop)){if(Test-Path -LiteralPath $file){[IO.File]::Delete($file)}}
    $argsList=@('--observe','--inventory','--seconds','300','--report',$path,'--stop-file',$stop)
    $quoted=foreach($arg in $argsList){if($arg.Contains('"') -or $arg.EndsWith('\')){throw 'Argomento avvio non valido.'};'"'+$arg+'"'}
    $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=Join-Path $PSScriptRoot 'build/ame.exe';$info.Arguments=$quoted -join ' '
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WorkingDirectory=$PSScriptRoot;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try{[void]$process.Start();$process.BeginOutputReadLine();$process.BeginErrorReadLine()}
    catch{$process.Dispose();throw}
    $script:agentInventory=@{Process=$process;Path=$path;Stop=$stop;Tail=$null;Started=$Now}
}
function Stop-AgentInventory {
    $i=$script:agentInventory
    if(!$i){return}
    if(!$i.Process.HasExited){[IO.File]::WriteAllText($i.Stop,'stop');[void]$i.Process.WaitForExit(5000)}
    if($i.Tail){$i.Tail.Dispose()};$i.Process.Dispose();$script:agentInventory=$null
}
function Update-AgentOwnBudget($Rows,[double]$At) {
    $own=@($Rows|Where-Object {$_.pid -eq $script:agentProcessId -or [string]::Equals([string]$_.image_path,(Join-Path $PSScriptRoot 'build\ame.exe'),[StringComparison]::OrdinalIgnoreCase) -or [string]::Equals([string]$_.image_path,(Join-Path $PSScriptRoot 'build\ame-browser-host.exe'),[StringComparison]::OrdinalIgnoreCase)})
    if(!$own.Count -or @($own|Where-Object {$null -eq $_.private_working_set_bytes -or !$_.memory_available}).Count){$script:agent.OwnPrivateBytes=$null;$script:agent.OwnCpu=$null;$script:agent.OwnCpuOverSince=$null;return}
    # PowerShell 5.1: project dictionary values before measuring, retaining the availability gates above.
    $script:agent.OwnPrivateBytes=($own|ForEach-Object {[double]$_.private_working_set_bytes}|Measure-Object -Sum).Sum
    if($script:agent.OwnPrivateBytes -ge 128MB){
        try{
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            if($script:agent.NativeClient){
                [void]$script:agent.NativeClient.CompactCurrentProcess([uint64]32MB)
            }
        }catch{}
    }
    if($script:agent.OwnPrivateBytes -gt $script:agent.Config.maximum_own_private_mib*1MB){
        $script:agent.StopReason='Budget RAM privata di AME superato: agente fermato per limitarne il costo.'
    }
    if(@($own|Where-Object {$null -eq $_.cpu_percent}).Count){$script:agent.OwnCpu=$null;$script:agent.OwnCpuOverSince=$null;return}
    $script:agent.OwnCpu=($own|ForEach-Object {[double]$_.cpu_percent}|Measure-Object -Sum).Sum
    if($script:agent.OwnCpu -gt $script:agent.Config.maximum_own_cpu_percent){
        if($null -eq $script:agent.OwnCpuOverSince){$script:agent.OwnCpuOverSince=$At}
        if($At-$script:agent.OwnCpuOverSince -ge 30){$script:agent.StopReason='Budget CPU di AME superato per 30 secondi: agente fermato.'}
    }else{$script:agent.OwnCpuOverSince=$null}
}
function Poll-AgentInventory([double]$Now) {
    if(!$script:agentInventory){Start-AgentInventory $Now;return}
    $i=$script:agentInventory
    if(!$i.Tail -and (Test-Path -LiteralPath $i.Path)){$i.Tail=New-Object AmeHub.ReportTail($i.Path)}
    if($i.Tail){
        for($chunk=0;$chunk -lt 8 -and $i.Tail.HasUnreadBytes;$chunk++){
            foreach($line in $i.Tail.ReadLines()){
                $sample=$line|ConvertFrom-Json
                if($sample.type -ne 'sample'){continue}
                $at=$i.Started+[double]$sample.elapsed_seconds
                Update-AgentTelemetry $script:agent $sample $at $Now
                if($sample.process_snapshot_complete -and $Now-$at -le 8){Update-AgentOwnBudget @($sample.processes) $at}
            }
        }
        if((Get-Item -LiteralPath $i.Path).Length -gt 8MB){[IO.File]::WriteAllText($i.Stop,'stop')}
    }
    if($i.Process.HasExited -and (!$i.Tail -or !$i.Tail.HasUnreadBytes)){
        $code=$i.Process.ExitCode;Stop-AgentInventory
        if($code -ne 0){throw ('Osservatore nativo terminato con codice '+$code+'. Nessun altro intervento.')}
        Start-AgentInventory $Now
    }
}
function Get-AgentProcessSummary {
    $rows=@($script:agent.LastInventory);$groups=@{}
    foreach($row in $rows){
        $key=if($row.image_path){[string]$row.image_path}else{[string]$row.name+':'+[string]$row.pid}
        if(!$groups.ContainsKey($key)){
            $isBrowser=($row.name -in @('chrome.exe','firefox.exe','msedge.exe','brave.exe'))
            $isClamped=($null -ne $script:agent.ClampedProcesses -and ($script:agent.ClampedProcesses.ContainsKey($key) -or ($script:agent.Config.operation_mode -eq 'clamp' -and $script:agent.Config.clamp_target_process -and $row.name -like ('*'+$script:agent.Config.clamp_target_process+'*'))))
            $distLabel=if($isClamped){
                'RAM Clamping Attivo (Mix A+B: Max '+$script:agent.Config.clamp_target_threshold_mib+' MiB)'
            }elseif($null -ne $script:agent.NativeClient){
                if($isBrowser){'API interna sottoprocessi + Estensione schede'}else{'API interna Windows attiva (VeryLow + EcoQoS + WorkingSetTrim)'}
            }else{'Non attiva'}
            $groups[$key]=@{name=[string]$row.name;count=0;private_bytes=0.0;complete=$true;method=$(if($isBrowser){'Schede autorizzate tramite estensione'}else{'Solo analisi: nessun rilascio interno integrato'});distributed_api=$distLabel}
        }
        $g=$groups[$key];$g.count++
        if($null -eq $row.private_working_set_bytes -or !$row.memory_available){$g.complete=$false}else{$g.private_bytes+=[double]$row.private_working_set_bytes}
    }
    foreach($g in @($groups.Values|Sort-Object {[double]$_.private_bytes} -Descending|Select-Object -First 35)){
        if(!$g.complete){$g.private_bytes=$null};[pscustomobject]$g
    }
}
function Restore-ActiveForegroundProcesses {
    $a=$script:agent
    if(!$a -or !$a.NativeClient -or !$a.ModifiedProcesses.Count){return}
    $rows=@($a.LastInventory)
    if(!$rows.Count){return}
    $fgImage=''
    foreach($r in $rows){if($r.foreground_window_owner -eq $true -and $r.image_path){$fgImage=[string]$r.image_path;break}}
    foreach($r in $rows){
        if(!$r.image_path -or !$r.creation_filetime){continue}
        $key=([string]$r.pid+':'+[string]$r.creation_filetime)
        if(!$a.ModifiedProcesses.ContainsKey($key)){continue}
        $isFg=($r.foreground_window_owner -eq $true) -or ($fgImage -and [string]::Equals([string]$r.image_path,$fgImage,[StringComparison]::OrdinalIgnoreCase))
        $cpu=if($null -ne $r.cpu_percent){[double]$r.cpu_percent}else{0.0}
        if($isFg -or $cpu -ge 3.0){
            try{
                if($a.NativeClient.RestoreProcess($key,[string]$r.image_path)){
                    $a.RestoredProcesses++
                }
            }catch{}
            $a.ModifiedProcesses.Remove($key)
        }
    }
}
function Restore-AllAgentProcesses {
    $a=$script:agent
    $count=0
    if($a -and $a.NativeClient){
        try{$count+=[int]$a.NativeClient.RestoreAllProcesses()}catch{}
        foreach($kv in @($a.ModifiedProcesses.GetEnumerator())){
            try{if($a.NativeClient.RestoreProcess([string]$kv.Key,[string]$kv.Value)){$count++}}catch{}
        }
        $a.ModifiedProcesses.Clear()
        foreach($kv in @($a.ClampedProcesses.GetEnumerator())){
            try{if($a.NativeClient.UnclampProcessWorkingSet([string]$kv.Key,[string]$kv.Value.Path)){$count++}}catch{}
        }
        $a.ClampedProcesses.Clear()
    }
    try{
        $sessionRestored=[AmeHub.ResourceApiClient]::RestoreAllUserSessionProcesses()
        if($sessionRestored -gt $count){$count=$sessionRestored}
    }catch{}
    if($a){$a.RestoredProcesses+=$count}
    return $count
}
function Invoke-DistributedMemoryCycle([double]$Now,[bool]$Force=$false) {
    $a=$script:agent
    if(!$a -or !$a.NativeClient){return $null}
    Restore-ActiveForegroundProcesses
    if($a.Config.operation_mode -eq 'clamp' -or ![string]::IsNullOrWhiteSpace($a.Config.clamp_target_process)){
        $targetProc=[string]$a.Config.clamp_target_process
        $clampMib=if($a.Config.clamp_target_threshold_mib){[uint64]$a.Config.clamp_target_threshold_mib}else{1200}
        $targetBytes=$clampMib*1MB
        $rows=@($a.LastInventory)
        foreach($r in $rows){
            if(!$r.name -or !$r.image_path -or !$r.creation_filetime){continue}
            $pName=[string]$r.name
            if(![string]::IsNullOrWhiteSpace($targetProc) -and ($pName -eq $targetProc -or $pName.ToLowerInvariant() -eq $targetProc.ToLowerInvariant())){
                $key=([string]$r.pid+':'+[string]$r.creation_filetime)
                if(!$a.ClampedProcesses.ContainsKey($key)){
                    try{
                        $cRes=$a.NativeClient.ClampProcessWorkingSet($key,[string]$r.image_path,$targetBytes)
                        $a.ClampedProcesses[$key]=@{Path=[string]$r.image_path;TargetBytes=$targetBytes;At=$Now;Name=$pName}
                        Write-AgentEvent @{type='process_ram_clamped';pid=$r.pid;name=$pName;target_bytes=$targetBytes;ws_before=$cRes.WorkingSetBeforeBytes;ws_after=$cRes.WorkingSetAfterBytes;message=('Modalita Clamping attiva: tetto RAM per '+$pName+' fissato a '+[math]::Round($targetBytes/1MB,1)+' MiB (Mix A+B).')}
                    }catch{}
                }
            }
        }
    }
    if(!$Force -and ($Now-$a.LastDistributedCycle -lt 15)){return $null}
    $plan=Get-DistributedReclaimPlan $a $Now $Force
    if(!$plan){return $null}
    $a.LastDistributedCycle=$Now
    $summary=@{internal_freed_bytes=[uint64]0;browser_subprocesses_affected=0;browser_reclaimed_bytes=[long]0;windows_processes_affected=0;windows_reclaimed_bytes=[uint64]0}
    if($plan.CompactInternal){
        try{
            $freed=$a.NativeClient.CompactCurrentProcess(32MB)
            $a.InternalCompactions++;$a.LastInternalCompact=$Now;$summary.internal_freed_bytes=$freed
            Write-AgentEvent @{type='internal_process_compacted';freed_bytes=$freed;message=('API interna: compattazione processo AME completata ('+[math]::Round($freed/1MB,1)+' MiB).')}
        }catch{}
    }
    $pacingMs = if($null -ne $a.Config.reclaim_process_pacing_ms){[int]$a.Config.reclaim_process_pacing_ms}else{60}
    $pacingCount = 0
    foreach($b in @($plan.BrowserSubprocesses)){
        try{
            if($pacingCount -gt 0 -and $pacingMs -gt 0){ Start-Sleep -Milliseconds $pacingMs }
            $res=$a.NativeClient.ExecuteProcessReclaim([string]$b.Key,[string]$b.Path,[uint32]$b.Stages)
            $pacingCount++
            $a.BrowserSubprocessReclaims++;$a.ProcessCooldowns[[string]$b.Key]=$Now;$a.ModifiedProcesses[[string]$b.Key]=[string]$b.Path
            $summary.browser_subprocesses_affected++
            $drop=[long]$res.WorkingSetBeforeBytes-[long]$res.WorkingSetAfterBytes
            if($drop -gt 0){$summary.browser_reclaimed_bytes+=$drop}
            Write-AgentEvent @{type='browser_subprocess_reclaimed';pid=$b.Pid;name=$b.Name;stages=$res.AppliedStages;ws_before=$res.WorkingSetBeforeBytes;ws_after=$res.WorkingSetAfterBytes;message=('API interna browser ('+$b.Name+' PID '+$b.Pid+'): stadio '+$res.AppliedStages+' applicato (-'+[math]::Round([math]::Max(0L,$drop)/1MB,1)+' MiB WS).')}
        }catch{$a.ProcessCooldowns[[string]$b.Key]=$Now}
    }
    $winList=@($plan.WindowsProcesses)
    if($winList.Count -gt 0){
        $targetBudget=if($Force){[uint64]8192MB}else{[uint64]$plan.TargetBudgetBytes}
        foreach($stageGroup in @($winList|Group-Object Stages)){
            $groupItems=@($stageGroup.Group)
            $keys=@($groupItems|ForEach-Object {[string]$_.Key})
            $paths=@($groupItems|ForEach-Object {[string]$_.Path})
            $stages=[uint32]$groupItems[0].Stages
            try{
                $grp=$a.NativeClient.ExecuteDistributedGroupReclaim($keys,$paths,$targetBudget,$stages)
                $a.WindowsReclaims+=[int]$grp.AffectedProcesses
                $summary.windows_processes_affected+=[int]$grp.AffectedProcesses
                $summary.windows_reclaimed_bytes+=$grp.TotalReclaimedBytes
                for($idx=0;$idx -lt $keys.Count;$idx++){
                    $a.ProcessCooldowns[$keys[$idx]]=$Now
                    $a.ModifiedProcesses[$keys[$idx]]=$paths[$idx]
                }
                if($grp.AffectedProcesses -gt 0){
                    Write-AgentEvent @{type='windows_distributed_reclaim';affected=$grp.AffectedProcesses;reclaimed_bytes=$grp.TotalReclaimedBytes;stages=$stages;message=('API interna Windows (Stadio '+$stages+'): lavoro distribuito su '+$grp.AffectedProcesses+' processi (-'+[math]::Round($grp.TotalReclaimedBytes/1MB,1)+' MiB WS).')}
                }
            }catch{
                foreach($w in $groupItems){
                    try{
                        if($pacingCount -gt 0 -and $pacingMs -gt 0){ Start-Sleep -Milliseconds $pacingMs }
                        $res=$a.NativeClient.ExecuteProcessReclaim([string]$w.Key,[string]$w.Path,[uint32]$w.Stages)
                        $pacingCount++
                        $a.WindowsReclaims++;$a.ProcessCooldowns[[string]$w.Key]=$Now;$a.ModifiedProcesses[[string]$w.Key]=[string]$w.Path
                        $summary.windows_processes_affected++
                        if($res.WorkingSetBeforeBytes -gt $res.WorkingSetAfterBytes){$summary.windows_reclaimed_bytes+=($res.WorkingSetBeforeBytes-$res.WorkingSetAfterBytes)}
                    }catch{$a.ProcessCooldowns[[string]$w.Key]=$Now}
                }
            }
        }
    }
    if($summary.internal_freed_bytes -gt 0 -or $summary.browser_subprocesses_affected -gt 0 -or $summary.windows_processes_affected -gt 0){
        $cycleBytes=[double]$summary.internal_freed_bytes+[double]$summary.browser_reclaimed_bytes+[double]$summary.windows_reclaimed_bytes
        $a.LastResult=@{
            utc=[DateTime]::UtcNow.ToString('o')
            outcome='distributed_reclaim'
            message=('API interna Multi-Lane attiva - Sottoprocessi Browser: '+$a.BrowserSubprocessReclaims+' | Processi Windows: '+$a.WindowsReclaims+' | Ripristinati al risveglio: '+$a.RestoredProcesses+' (Ultimo ciclo: -'+[math]::Round($cycleBytes/1MB,1)+' MiB Working Set).')
        }
    }
    if($a.NativeClient -and $a.Config.memory_compression_auto_flush){
        try{
            $compBytes=[double]$a.NativeClient.GetMemoryCompressionWorkingSetBytes()
            $compMiB=[math]::Round($compBytes/1MB,1)
            $a.MemoryCompressionMiB=$compMiB
            $nowEpoch=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $hoursElapsed=if($null -ne $a.LastCompressionFlushEpoch){($nowEpoch-[double]$a.LastCompressionFlushEpoch)/3600.0}else{999.0}
            $thresholdMiB=if($null -ne $a.Config.memory_compression_flush_threshold_mib){[double]$a.Config.memory_compression_flush_threshold_mib}else{1500.0}
            $targetHours=if($null -ne $a.Config.memory_compression_flush_hours){[double]$a.Config.memory_compression_flush_hours}else{5.0}

            # Cooldown di sicurezza: non ripetere il flush automatico prima di 30 minuti (0.5 ore)
            # anche se la memoria compressa rimane sopra la soglia
            $minAutoCooldownHours = 0.5
            if($hoursElapsed -ge $targetHours -or ($compMiB -ge $thresholdMiB -and $hoursElapsed -ge $minAutoCooldownHours)){
                $reason=if($compMiB -ge $thresholdMiB){"Soglia superata ($compMiB MiB >= $thresholdMiB MiB)"}else{"Intervallo raggiunto ({0:N1} h >= {1:N0} h)" -f $hoursElapsed,$targetHours}
                $pulseFreed=[double]$a.NativeClient.PulseFlushMemory([uint64]1536MB)
                $a.LastCompressionFlushEpoch=$nowEpoch
                $a.CompressionFlushes++
                $freedMiB=[math]::Round($pulseFreed/1MB,1)
                $msg=if($freedMiB -gt 0){
                    'Memory Pulse Flush eseguito ('+$reason+'): svuotata memoria compressa di Windows (-'+$freedMiB+' MiB).'
                }else{
                    'Memory Pulse Flush ('+$reason+'): 0 MiB rilasciati. RAM satura: Windows trattiene la memoria compressa per protezione.'
                }
                Write-AgentEvent @{
                    type='memory_compression_flushed'
                    freed_bytes=$pulseFreed
                    reason=$reason
                    compression_before_mib=$compMiB
                    message=$msg
                }
                $summary.internal_freed_bytes+=[uint64]$pulseFreed
            }
        }catch{}
    }
    return [pscustomobject]$summary
}
function Poll-AgentInternalApiBus([double]$Now) {
    if(!$script:agentApiBus -or !$script:agent){return}
    foreach($req in $script:agentApiBus.DrainRequests()){
        $reply=@{ok=$false;error='Comando non riconosciuto'}
        try{
            $cmd=$req.Payload|ConvertFrom-Json
            $action=[string]$cmd.command
            if($action -eq 'status'){
                $reply=@{ok=$true;phase=$script:agent.Phase;status=$script:agent.Status;internal_compactions=$script:agent.InternalCompactions;windows_reclaims=$script:agent.WindowsReclaims;browser_subprocess_reclaims=$script:agent.BrowserSubprocessReclaims;restored_processes=$script:agent.RestoredProcesses;confirmed_discards=$script:agent.Applied;pressure=$script:agent.LastTelemetry}
            }elseif($action -eq 'compact_internal'){
                if(!$script:agent.NativeClient){throw 'API nativa non inizializzata.'}
                $freed=$script:agent.NativeClient.CompactCurrentProcess(64MB)
                $script:agent.InternalCompactions++;$script:agent.LastInternalCompact=$Now
                Write-AgentEvent @{type='internal_process_compacted';freed_bytes=$freed;message=('API interna (comando pannello): compattazione processo AME completata ('+[math]::Round($freed/1MB,1)+' MiB).')}
                Write-AgentStatus
                $reply=@{ok=$true;freed_bytes=$freed}
            }elseif($action -eq 'reclaim_process'){
                if(!$script:agent.NativeClient){throw 'API nativa non inizializzata.'}
                $stages=if($cmd.stages){[uint32]$cmd.stages}else{[uint32]14}
                $res=$script:agent.NativeClient.ExecuteProcessReclaim([string]$cmd.key,[string]$cmd.path,$stages)
                $script:agent.WindowsReclaims++;$script:agent.ProcessCooldowns[[string]$cmd.key]=$Now;$script:agent.ModifiedProcesses[[string]$cmd.key]=[string]$cmd.path
                Write-AgentStatus
                $reply=@{ok=$true;pid=$res.Pid;applied_stages=$res.AppliedStages;ws_before=$res.WorkingSetBeforeBytes;ws_after=$res.WorkingSetAfterBytes;ws_delta=$res.WorkingSetDeltaBytes}
            }elseif($action -eq 'distribute_budget'){
                $script:agent.ProcessCooldowns.Clear()
                $script:agent.LastDistributedCycle=0.0
                $wave=Invoke-DistributedMemoryCycle $Now $true
                Write-AgentStatus
                $reply=@{ok=$true;wave=$wave}
            }elseif($action -eq 'restore_all'){
                $restored=Restore-AllAgentProcesses
                Write-AgentEvent @{type='processes_restored';restored=$restored;message=('Ripristino completo eseguito: '+$restored+' processi riportati alle priorita normali di Windows.')}
                Write-AgentStatus
                $reply=@{ok=$true;restored=$restored}
            }elseif($action -eq 'flush_compression'){
                if(!$script:agent.NativeClient){throw 'API nativa non inizializzata.'}
                $freed=[double]$script:agent.NativeClient.PulseFlushMemory([uint64]1536MB)
                $script:agent.LastCompressionFlushEpoch=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $script:agent.CompressionFlushes++
                $freedMiB=[math]::Round($freed/1MB,1)
                $msg = if($freedMiB -gt 0){
                    'Memory Pulse Flush manuale eseguito: svuotata memoria compressa di Windows (-'+$freedMiB+' MiB).'
                }else{
                    $ramPct = if($script:agent.LastTelemetry -and $null -ne $script:agent.LastTelemetry.Percent){[math]::Round([double]$script:agent.LastTelemetry.Percent,1)}else{0}
                    if($ramPct -ge 88){
                        'Memory Pulse Flush: 0 MiB svuotati. Con RAM al '+$ramPct+'%, Windows trattiene la memoria compressa per evitare crash. Esegui prima "Ottimizza Ora".'
                    }else{
                        'Memory Pulse Flush completato: nessun blocco compresso residuo rilasciabile da Windows (0 MiB).'
                    }
                }
                Write-AgentEvent @{type='memory_compression_flushed';freed_bytes=$freed;reason='manuale';message=$msg}
                Write-AgentStatus
                $reply=@{ok=$true;freed_bytes=$freed;message=$msg}
            }elseif($action -eq 'set_mode'){
                $mode=if($cmd.mode){[string]$cmd.mode}else{'standard'}
                if($mode -in @('standard','multilane','clamp')){
                    $script:agent.Config.operation_mode=$mode
                    if($cmd.target_process){$script:agent.Config.clamp_target_process=[string]$cmd.target_process}
                    if($cmd.target_threshold_mib){$script:agent.Config.clamp_target_threshold_mib=[int]$cmd.target_threshold_mib}
                    Write-AgentEvent @{type='operation_mode_changed';mode=$mode;target=$script:agent.Config.clamp_target_process;threshold_mib=$script:agent.Config.clamp_target_threshold_mib;message=('Modalita operativa impostata su: '+$mode.ToUpper()+' (Clamping target: '+$script:agent.Config.clamp_target_process+' @ '+$script:agent.Config.clamp_target_threshold_mib+' MiB).')}
                    Write-AgentStatus
                    $reply=@{ok=$true;mode=$mode}
                }else{
                    $reply=@{ok=$false;error='Modalita non valida'}
                }
            }elseif($action -eq 'clamp_process'){
                if(!$script:agent.NativeClient){throw 'API nativa non inizializzata.'}
                $targetBytes=if($cmd.target_bytes){[uint64]$cmd.target_bytes}elseif($cmd.target_mib){[uint64]([double]$cmd.target_mib * 1MB)}else{[uint64](1200MB)}
                $cRes=$script:agent.NativeClient.ClampProcessWorkingSet([string]$cmd.key,[string]$cmd.path,$targetBytes)
                $script:agent.ClampedProcesses[[string]$cmd.key]=@{Path=[string]$cmd.path;TargetBytes=$targetBytes;At=$Now;Name=[string]$cmd.name}
                Write-AgentEvent @{type='process_ram_clamped';pid=$cRes.Pid;name=$cmd.name;target_bytes=$targetBytes;ws_before=$cRes.WorkingSetBeforeBytes;ws_after=$cRes.WorkingSetAfterBytes;message=('RAM Clamping applicato: '+$cmd.name+' limitato a '+[math]::Round($targetBytes/1MB,1)+' MiB (Mix A+B).')}
                Write-AgentStatus
                $reply=@{ok=$true;pid=$cRes.Pid;ws_before=$cRes.WorkingSetBeforeBytes;ws_after=$cRes.WorkingSetAfterBytes;target_bytes=$targetBytes}
            }elseif($action -eq 'unclamp_process'){
                if(!$script:agent.NativeClient){throw 'API nativa non inizializzata.'}
                $ok=$script:agent.NativeClient.UnclampProcessWorkingSet([string]$cmd.key,[string]$cmd.path)
                $script:agent.ClampedProcesses.Remove([string]$cmd.key)
                Write-AgentEvent @{type='process_ram_unclamped';pid=$cmd.pid;name=$cmd.name;message=('RAM Clamping rimosso da '+$cmd.name+': ripristinata allocazione normale.')}
                Write-AgentStatus
                $reply=@{ok=$true}
            }
        }catch{$reply=@{ok=$false;error=$_.Exception.Message}}
        $script:agentApiBus.CompleteRequest($req.Id,($reply|ConvertTo-Json -Depth 6 -Compress))
    }
}
function Write-AgentStatus {
    $a=$script:agent;$profiles=@(foreach($id in @($a.Profiles.Keys)){$p=$a.Profiles[$id];@{browser=$p.Browser;connection=[int]$id;ready=$p.Ready;automatic_capable=$p.AutoCapable;tabs=$p.Tabs.Count;authorized_tabs=@($p.Tabs|Where-Object {$_.auto_allowed -eq $true}).Count;truncated=$p.Truncated}})
    $value=@{schema_version=1;revision='R22';root=$PSScriptRoot;run_id=$script:agentRunId;process_id=$script:agentProcessId;creation_filetime=$script:agentCreation;
        heartbeat_utc=[DateTime]::UtcNow.ToString('o');phase=$a.Phase;status=$a.Status;confirmed_discards=$a.Applied;process_count=@($a.LastInventory).Count;
        own_private_bytes=$a.OwnPrivateBytes;own_cpu_percent=$a.OwnCpu;pressure=$a.LastTelemetry;profiles=$profiles;processes=@(Get-AgentProcessSummary);recent=@($a.Recent);last_result=$a.LastResult;
        distributed=@{internal_compactions=$a.InternalCompactions;windows_reclaims=$a.WindowsReclaims;browser_subprocess_reclaims=$a.BrowserSubprocessReclaims;restored_processes=$a.RestoredProcesses;api_bus_active=($null -ne $script:agentApiBus);compression_mib=$a.MemoryCompressionMiB;compression_flushes=$a.CompressionFlushes;last_compression_flush_epoch=$a.LastCompressionFlushEpoch;clamped_count=$a.ClampedProcesses.Count;operation_mode=$a.Config.operation_mode;clamp_target_process=$a.Config.clamp_target_process;clamp_target_threshold_mib=$a.Config.clamp_target_threshold_mib};
        configuration=$a.Config;history_failure=$a.HistoryFailure;causation_established=$false;application_latency_measured=$false;hard_faults_measured=$false}
    Write-AgentJson (Join-Path $script:agentDirectory 'status.json') $value 256KB
}
