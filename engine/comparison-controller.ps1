# All calls run on the existing UI timer. Sampling is read-only and independent
# of the optional ten-minute inventory engine. Only phase 2 can request discards.
function Get-ComparisonClock { return $script:comparisonClock.Elapsed.TotalSeconds }
function New-ComparisonGuard {
    $created=$false
    $guard=[Threading.Mutex]::new($false,'Local\AME-MemoryPriority-Controller',[ref]$created)
    if(!$created){$guard.Dispose();throw 'Un controller AME e gia attivo in questa sessione Windows. Fermalo prima del confronto.'}
    return $guard
}
function Release-ComparisonGuard {
    if($script:comparisonGuard){$script:comparisonGuard.Dispose();$script:comparisonGuard=$null}
}
function Assert-ComparisonCooldown([int]$Connection,[string]$Session,[long]$Tab) {
    $key=$Connection.ToString()+':'+$Session+':'+$Tab
    if($script:browserCooldown -and $script:browserCooldown.ContainsKey($key) -and $script:browserCooldown[$key] -gt [DateTime]::UtcNow){throw 'Scheda gia tornata rapidamente in uso: scaricamento sconsigliato per 30 minuti. Scegli altre schede.'}
}
function Set-ComparisonCooldown([long]$Tab) {
    if(!$script:browserCooldown){$script:browserCooldown=@{}}
    $s=$script:comparison;$key=$s.Connection.ToString()+':'+$s.Session+':'+$Tab
    $script:browserCooldown[$key]=[DateTime]::UtcNow.AddMinutes(30)
}
function New-ComparisonSampler([string]$Browser) {
    if(!('AmeComparison.Sampler' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'src/comparison-metrics.cs')}
    return [AmeComparison.Sampler]::new($Browser.ToLowerInvariant(),$PSScriptRoot)
}
function Write-ComparisonEvent([hashtable]$Event) {
    $s=$script:comparison
    if(!$s -or !$s.ReportPath){throw 'Registro del confronto non disponibile.'}
    $Event.utc=[DateTime]::UtcNow.ToString('o');$Event.comparison_id=$s.Id;$Event.browser=$s.Browser
    $line=($Event|ConvertTo-Json -Depth 10 -Compress)+"`n";$encoding=New-Object Text.UTF8Encoding($false)
    $bytes=$encoding.GetByteCount($line)
    if($s.ReportBytes+$bytes -gt 4MB){throw 'Limite di 4 MiB del report confronto raggiunto.'}
    [IO.File]::AppendAllText($s.ReportPath,$line,$encoding);$s.ReportBytes+=$bytes
}
function Complete-ComparisonReport {
    $s=$script:comparison
    if(!$s -or $s.EndWritten){return}
    if(!$s.Outcome){$s.Outcome=Get-ComparisonAssessment $s}
    try{
        Write-ComparisonEvent @{type='comparison_assessed';outcome=$s.Outcome;status=$s.Status;phase=$s.Phase;failure=$s.Failure;confirmed_discards=$s.Applied;skipped=$s.Skipped}
        Write-ComparisonEvent @{type='comparison_end';phase=$s.Phase;measurement_complete=$s.Outcome.Complete}
        $s.EndWritten=$true
    }finally{Release-ComparisonGuard}
}
function Stop-Comparison([string]$Reason='Confronto annullato dall utente.') {
    $s=$script:comparison
    if(!$s -or ($s.Phase -notin @('baseline','ready','applying','ame') -and !($s.Phase -eq 'done' -and !$s.EndWritten))){return}
    $s.Failure=$Reason;$s.Phase='incomplete';$s.Queue=@();$s.Outcome=$null
    $s.Status=$Reason+' Nessun altro comando verra inviato. Le richieste gia inviate possono completarsi; le schede restano aperte.'
    try{Complete-ComparisonReport}catch{$s.Status+=' Salvataggio non riuscito: '+$_.Exception.Message}
    Update-ComparisonDisplay
}
function Get-ComparisonProfile {
    $s=$script:comparison;$p=$script:profiles[$s.Connection]
    if(!$p -or !$p.Ready -or $p.Session -cne $s.Session -or $p.Browser -cne $s.Browser -or ([DateTime]::UtcNow-$p.Seen).TotalSeconds -ge 25){throw 'Collegamento browser assente, cambiato o non aggiornato.'}
    return $p
}
function Start-ComparisonBaseline([int]$Connection,[object[]]$Tabs,[string]$Workload,[bool]$NativeSaverConfirmed) {
    if(Test-ComparisonBusy){throw 'Un confronto e gia in corso. Annullalo prima di ricominciare.'}
    $old=$script:comparison
    if($old -and @($old.Requests.Values|Where-Object {$_.Outcome -in @('pending','unknown')}).Count){
        $oldProfile=$script:profiles[$old.Connection]
        if($oldProfile -and $oldProfile.Session -ceq $old.Session){throw 'Esito della precedente richiesta ancora sconosciuto. Attendi la conferma oppure Scollega e Collega di nuovo il profilo prima di un nuovo confronto.'}
    }
    if($script:pendingBrowser -or $script:batchActive -or $script:pendingRecoveryMode -or $script:restartMode -or $script:mode -in @('recover','recover-test')){throw 'Concludi o ferma gli altri interventi prima di iniziare il confronto.'}
    if(!$NativeSaverConfirmed){throw 'Attiva il risparmio memoria integrato e conferma di mantenere la stessa impostazione nelle due fasi.'}
    $p=$script:profiles[$Connection]
    if(!$p -or ([DateTime]::UtcNow-$p.Seen).TotalSeconds -ge 25){throw 'Elenco schede non aggiornato. Collega il browser e premi Aggiorna.'}
    $candidate=New-ComparisonSession $p $Connection $Tabs $Workload
    foreach($tab in $candidate.Tabs){Assert-ComparisonCooldown $Connection $p.Session $tab.id}
    $sampler=New-ComparisonSampler $p.Browser
    $guard=New-ComparisonGuard
    try{
        $folder=if($script:comparisonReportsDirectory){$script:comparisonReportsDirectory}else{Join-Path $PSScriptRoot 'reports'}
        [void][IO.Directory]::CreateDirectory($folder)
        $candidate.ReportPath=Join-Path $folder ('comparison-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+$candidate.Id.Substring(0,8)+'.jsonl')
        $script:comparison=$candidate;$script:comparisonUiError='';$script:comparisonGuard=$guard;$script:comparisonSampler=$sampler;$script:comparisonClock=[Diagnostics.Stopwatch]::StartNew()
        Write-ComparisonEvent @{type='comparison_session';duration_seconds=900;threshold_bytes=500MB;connection=$Connection;session=$p.Session;selected_tabs=$candidate.Tabs;workload=$Workload;
            native_saver_user_confirmed=$true;native_saver_verified=$false;scope='all_browser_processes_in_desktop_session';baseline_observer_present=$true;full_measured_ame_overhead_charged=$true;
            causation_established=$false;hard_faults_measured=$false;application_latency_measured=$false;io_reads_include_other_io=$true}
        Invoke-ComparisonTick
    }catch{$guard.Dispose();$script:comparisonGuard=$null;throw}
}
function Start-ComparisonAme([bool]$Confirmed) {
    $s=$script:comparison
    if(!$s -or $s.Phase -ne 'ready'){throw 'Completa prima i 15 minuti della fase 1.'}
    if(!$Confirmed){return}
    try{
        $p=Get-ComparisonProfile
        if((Get-ComparisonClock)-$s.ReadyAt -gt 300){throw 'Sono passati piu di 5 minuti dalla fase 1. Ripeti il confronto con dati freschi.'}
        if((Get-ComparisonInventoryKey $p) -cne $s.InventoryKey){throw 'Le pagine sono cambiate dalla fase 1. Ripeti il confronto con lo stesso insieme di pagine.'}
        $s.Queue=@($s.Tabs);$s.Phase='applying';$s.Status='Fase 2: verifico e invio uno scaricamento alla volta, senza nuovi tentativi.'
        Write-ComparisonEvent @{type='comparison_phase';phase='applying';manual_confirmation=$true}
        Send-NextComparisonDiscard
    }catch{Stop-Comparison $_.Exception.Message;throw}
    Update-ComparisonDisplay
}
function Send-NextComparisonDiscard {
    $s=$script:comparison
    if(!$s -or $s.Phase -ne 'applying'){return}
    if(@($s.Requests.Values|Where-Object {$_.Outcome -eq 'pending'}).Count){return}
    $p=Get-ComparisonProfile
    while($s.Queue.Count){
        $selected=$s.Queue[0];$s.Queue=@($s.Queue|Select-Object -Skip 1)
        $matches=@($p.Tabs|Where-Object {$_.id -eq $selected.id -and $_.revision -ceq $selected.revision})
        if($matches.Count -ne 1){throw 'Una scheda scelta e cambiata. Nessun altro comando inviato.'}
        $tab=$matches[0]
        if($tab.discarded){$s.Skipped++;Write-ComparisonEvent @{type='comparison_skipped';tab=$selected.id;reason='already_discarded_by_browser'};continue}
        if($tab.blocked){throw ('Scheda diventata protetta: '+$tab.blocked)}
        Assert-ComparisonCooldown $s.Connection $s.Session $tab.id
        $request=[guid]::NewGuid().ToString('D')
        $s.Requests[$request]=@{Tab=[long]$tab.id;Revision=[string]$tab.revision;Outcome='pending';SentAt=(Get-ComparisonClock);SequenceAtAck=0L}
        $command=@{type='discard';session=$s.Session;request=$request;tab=[long]$tab.id;revision=[string]$tab.revision;confirmed=$true;deadline=[DateTimeOffset]::UtcNow.AddSeconds(8).ToUnixTimeMilliseconds()}
        Write-ComparisonEvent @{type='comparison_request';request=$request;tab=$tab.id;manual_confirmation=$true}
        if(!$script:bridge.Send($s.Connection,($command|ConvertTo-Json -Compress))){throw 'Richiesta non inviata: collegamento chiuso. Nessun nuovo tentativo.'}
        $s.Status='Scaricamento richiesto per '+$tab.title+'. Attendo conferma; ancora nessuna riduzione RAM dichiarata.'
        return
    }
    if(!$s.Applied){
        $s.Phase='done';$s.Outcome=Get-ComparisonAssessment $s;$s.Outcome.Code='no_additional_targets'
        $s.Status='Nessuna scheda aggiuntiva da scaricare: il browser le ha gia scaricate durante la fase 1. Nessun intervento AME applicato.'
        $s.Outcome.Status=$s.Status;Complete-ComparisonReport;return
    }
    $s.Phase='ame';$s.PhaseStarted=Get-ComparisonClock;$s.LastSeconds=$null;$s.LastReadAt=$null;$s.LastSampleUtc=$null;$s.LastElapsed=0
    $s.Status='Scaricamenti confermati: '+$s.Applied+'. Inizio 15 minuti di misura, senza ulteriori interventi.'
    Write-ComparisonEvent @{type='comparison_phase';phase='ame';confirmed_discards=$s.Applied}
}
function Receive-ComparisonResult([int]$Connection,$Event) {
    $s=$script:comparison
    if(!$s -or $Connection -ne $s.Connection -or !$s.Requests.ContainsKey([string]$Event.request)){return $false}
    $request=$s.Requests[[string]$Event.request]
    if($request.Tab -ne $Event.tab -or $request.Outcome -notin @('pending','unknown')){return $true}
    $request.Outcome=[string]$Event.outcome
    Write-ComparisonEvent @{type='browser_result';request=$Event.request;tab=$Event.tab;outcome=$Event.outcome;reason=$Event.reason;operation_ms=$Event.operation_ms;after_cancellation=($s.Phase -ne 'applying')}
    if($Event.outcome -eq 'discarded'){
        $s.Applied++;$request.SequenceAtAck=$script:profiles[$Connection].LastSequence
        $script:browserConfirmed++;$script:browserRequests[[string]$Event.request]=@{Connection=$Connection;Tab=$Event.tab}
        # A late acknowledgement remains recorded after cancellation, but never resumes a phase.
        if($s.Phase -eq 'applying'){Send-NextComparisonDiscard}
    }elseif($s.Phase -eq 'applying'){Stop-Comparison ('Scaricamento rifiutato: '+[string]$Event.reason)}
    Update-ComparisonDisplay
    return $true
}
function Record-ComparisonReturn([string]$Request,$Milliseconds) {
    $s=$script:comparison
    if(!$s -or !$s.Requests.ContainsKey($Request)){return}
    if($s.Requests[$Request].Outcome -ne 'discarded'){return}
    if($s.Requests[$Request].ReturnRecorded){return}
    $valid=$null -ne $Milliseconds -and ![double]::IsNaN([double]$Milliseconds) -and ![double]::IsInfinity([double]$Milliseconds) -and [double]$Milliseconds -ge 0 -and [double]$Milliseconds -le 3600000
    if(!$valid){return}
    $s.Requests[$Request].ReturnRecorded=$true
    $item=[pscustomobject]@{Request=$Request;Milliseconds=[double]$Milliseconds;ApplicationReadyMeasured=$false}
    $s.ReturnLoads.Add($item)
    Write-ComparisonEvent @{type='comparison_reactivation';request=$Request;load_observed_ms=[double]$Milliseconds;application_ready_measured=$false;baseline_latency_measured=$false}
    if($s.Phase -in @('applying','ame')){$s.Returned=$true;Set-ComparisonCooldown $s.Requests[$Request].Tab;Stop-Comparison 'Una scheda e tornata in uso prima dei 15 minuti: durata incompleta.'}
    Update-ComparisonDisplay
}
function Invoke-ComparisonTick {
    $s=$script:comparison
    if(!$s){Update-ComparisonDisplay;return}
    try{
        if(Test-ComparisonBusy){
            $p=Get-ComparisonProfile
            if($s.Phase -in @('applying','ame')){
                foreach($request in @($s.Requests.Values|Where-Object {$_.Outcome -eq 'discarded'})){
                    $tab=@($p.Tabs|Where-Object {$_.id -eq $request.Tab})
                    if($p.LastSequence -gt $request.SequenceAtAck -and $tab.Count -eq 1 -and !$tab[0].discarded){$s.Returned=$true;Set-ComparisonCooldown $request.Tab;throw 'Una scheda e tornata in uso prima della fine: beneficio limitato al periodo di inattivita.'}
                }
            }
            if((Get-ComparisonInventoryKey $p) -cne $s.InventoryKey){throw 'Insieme di pagine cambiato: confronto interrotto per evitare un risultato fuorviante.'}
            if($s.Phase -eq 'ready' -and (Get-ComparisonClock)-$s.ReadyAt -gt 300){throw 'Fase 2 non avviata entro 5 minuti. Ripeti il confronto.'}
        }
        if($s.Phase -eq 'applying'){
            foreach($request in @($s.Requests.Values|Where-Object {$_.Outcome -eq 'pending'})){
                if((Get-ComparisonClock)-$request.SentAt -gt 20){$request.Outcome='unknown';throw 'Conferma assente dopo 20 secondi: azione di esito sconosciuto. Nessun nuovo tentativo.'}
            }
        }elseif($s.Phase -in @('baseline','ame')){
            $now=Get-ComparisonClock
            if($null -eq $s.LastReadAt -or $now-$s.LastReadAt -ge 5){
                $utc=[DateTime]::UtcNow
                if($s.LastSampleUtc -and (($utc-$s.LastSampleUtc).TotalSeconds -gt 12 -or $utc -lt $s.LastSampleUtc)){throw 'Continuita temporale persa: sospensione del PC o orologio cambiato.'}
                $phase=$s.Phase;$sample=$script:comparisonSampler.Read()
                $row=Add-ComparisonSample $s $sample ($now-$s.PhaseStarted);$s.LastReadAt=$now;$s.LastSampleUtc=$utc
                Write-ComparisonEvent @{type='comparison_sample';phase=$phase;sample=$row}
                if($s.Phase -eq 'ready'){$s.ReadyAt=$now;Write-ComparisonEvent @{type='comparison_phase';phase='ready';status=$s.Status}}
                elseif($s.Phase -eq 'done'){Complete-ComparisonReport}
            }
        }
    }catch{Stop-Comparison $_.Exception.Message}
    Update-ComparisonDisplay
}
