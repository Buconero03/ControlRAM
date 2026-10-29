function Get-WindowsRows($sample,[string]$windowsDirectory,[int]$sessionId) {
    $prefix=$windowsDirectory.TrimEnd('\') + '\'
    foreach ($processRow in @($sample.processes)) {
        $path=[string]$processRow.image_path
        $reason=''
        if (!$path -or !([string]$processRow.creation_filetime -match '^[0-9]+$') -or [string]$processRow.creation_filetime -match '^0+$' -or !$processRow.same_user -or $processRow.session_id -ne $sessionId) { $reason='Identita/utente/sessione non gestibile' }
        elseif ($path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { $reason='Processo Windows escluso' }
        elseif ($null -eq $processRow.critical -or $processRow.critical) { $reason='Critico o non verificabile' }
        elseif (!$processRow.memory_available -or $null -eq $processRow.private_working_set_bytes) { $reason='Memoria privata non disponibile' }
        elseif ($path -like '*\ame.exe') { $reason='Motore AME escluso' }
        elseif ($processRow.working_set_bytes -gt 2GB) { $reason='Oltre 2 GiB residenti: escluso' }
        elseif ($processRow.private_working_set_bytes -lt 128MB) { $reason='Meno di 128 MiB privati: escluso' }
        $state=if ($reason) { $reason } elseif ($processRow.foreground_window_owner) { 'Primo piano: protetto' } else { 'Selezionabile. Attivita verificata al recupero.' }
        [pscustomobject]@{Key=([string]$processRow.pid+':'+[string]$processRow.creation_filetime);Pid=[int]$processRow.pid;
            Creation=[string]$processRow.creation_filetime;Name=[string]$processRow.name;Path=$path;Blocked=$reason;
            PrivateBytes=$processRow.private_working_set_bytes;CommitBytes=$(if($processRow.memory_available){$processRow.private_commit_bytes}else{$null});
            Cpu=$processRow.cpu_percent;Faults=$processRow.page_faults_per_second;Idle=$processRow.low_activity_seconds;State=$state}
    }
}
function Get-WindowsRamOrderedRows([object[]]$rows) {
    $rows | Sort-Object @{Expression={if($null -eq $_.PrivateBytes){-1}else{[double]$_.PrivateBytes}};Descending=$true}, @{Expression={$_.Pid};Descending=$false}, Key
}
function Get-RecoveryStatus($event) {
    if ($event.disabled) {
        if($event.feedback_pending -and $event.usage_resumed){return 'App tornata in primo piano: altri interventi bloccati. Continuo solo la misura fino a 5 minuti.'}
        if($event.feedback_pending -and $event.activity_warning){return 'Attivita/fault aumentati: altri interventi bloccati. Continuo solo la misura della RAM fino a 5 minuti.'}
        if($event.disabled_reason -in @('rapid_resident_rebound','no_meaningful_resident_reduction','resident_reduction_not_retained','no_sustained_observed_benefit','resident_reduction_observed_after_activity_warning','resident_reduction_not_retained_5m','resident_reduction_retained_5m_with_activity','resident_reduction_retained_5m_after_resume')){return (Get-RecoveryOutcomeStatus ([pscustomobject]@{reason=$event.disabled_reason}))}
        return 'Nuovi interventi bloccati: ' + $event.disabled_reason
    }
    if ($event.single_test -and !$event.feedback_pending -and !$event.completed){return 'Servono 60 s consecutivi: CPU <0,1% e fault <10/s. Un superamento fa ripartire il conteggio. Massimo 3 min per processo. Soglia RAM non richiesta.'}
    if ($event.feedback_pending) { return 'Intervento applicato. Misuro la durata della riduzione per 5 minuti prima di valutarne un altro.' }
    if ($event.single_test -and $event.completed -ge 1){return 'Processo corrente gestito: nessun nuovo tentativo su questa identita.'}
    if ($event.completed -ge 3) { return 'Raggiunto il limite di tre interventi di questa sessione. Monitoraggio attivo.' }
    if (!$event.foreground_known) { return 'Applicazione in primo piano non identificabile: nessun intervento.' }
    if (!$event.pressure) { return 'Attendo RAM >= 85% persistente per 30 secondi e processi poco attivi per 60 secondi.' }
    return 'Pressione rilevata. Attendo un processo selezionato idoneo; consultare i motivi nel registro.'
}

function Get-RecoveryTargetStatus($event) {
    $text=switch([string]$event.reason) {
        'eligible' {'Pronto per una singola azione'}
        'foreground_family' {'Protetto: app in primo piano o sua famiglia. Porta AME in primo piano per consentire la verifica'}
        'foreground_unknown' {'Primo piano non identificabile: attendo'}
        'low_activity_under_60_seconds' {
            $message='Attendo bassa attivita: {0:N0}/60 s consecutivi' -f $event.low_activity_seconds
            if($null -ne $event.cpu_percent -and $null -ne $event.page_faults_per_second -and
               ($event.cpu_percent -ge 0.1 -or $event.page_faults_per_second -ge 10)){
                $message+='; conteggio ripartito per attivita (CPU {0:N2}%, fault/s {1:N1})' -f $event.cpu_percent,$event.page_faults_per_second
            }
            $message
        }
        'waiting_pressure_85_percent_30_seconds' {'Attendo RAM >=85% per 30 s'}
        'feedback_pending' {'Azione applicata: verifica della durata per 5 minuti'}
        'telemetry_missing' {'Attendo metriche valide'}
        'selected_process_no_longer_running' {'Processo terminato o identita cambiata'}
        'session_limit_or_already_attempted' {'Gia tentato o limite della sessione'}
        'session_disabled' {'Sessione bloccata: consulta il risultato'}
        'action_window_closed' {'Tempo per nuovi interventi scaduto: sola osservazione'}
        'controller_self' {'Motore AME escluso'}
        'owner_or_session' {'Utente o sessione differente: escluso'}
        'critical_or_unknown' {'Critico o non verificabile: escluso'}
        'private_resident_below_128_MiB' {'Meno di 128 MiB privati: escluso'}
        'target_over_2_GiB' {'Oltre 2 GiB residenti: escluso'}
        'image_not_allowed' {'Percorso non autorizzato: escluso'}
        default {[string]$event.reason}
    }
    if(!$event.single_test -and !$event.pressure -and $event.reason -ne 'waiting_pressure_85_percent_30_seconds'){$text+='; pressione RAM non raggiunta'}
    return $text
}
function Get-RecoveryFeedbackStatus($event) {
    $change=$event.private_resident_delta_bytes/1MB
    $available=$event.system_available_delta_bytes/1MB
    $phase=switch([string]$event.phase){'immediate'{'Subito'};'5s'{'Dopo 5 s'};'15s'{'Dopo 15 s'};'60s'{'Dopo 1 min'};'180s'{'Dopo 3 min'};'300s'{'Dopo 5 min'};'usage_resumed'{'App tornata in primo piano'};'rebound_check'{'Verifica durata'};'activity_warning'{'Attivita/fault aumentati'};'guard'{'Misura interrotta'};default{[string]$event.phase}}
    $text='{0}: RAM processo {1:+0.0;-0.0;0.0} MiB; disponibile PC {2:+0.0;-0.0;0.0} MiB. Variazioni osservate.' -f $phase,$change,$available
    if($null -ne $event.retained_percent){$text+=' Resta il {0:N0}% della riduzione massima ({1:N1} MiB).' -f $event.retained_percent,($event.remaining_private_resident_reduction_bytes/1MB)}
    if($event.activity_warning){$text+=' Attivita/fault aumentati; reattivita non misurata.'}
    if($event.usage_resumed){$text+=' App tornata in primo piano; solo osservazione.'}
    return $text
}
function Get-RecoveryOutcomeStatus($event) {
    $measure=if($null -ne $event.remaining_private_resident_reduction_bytes -and $null -ne $event.minimum_private_resident_reduction_last_60s_bytes){' Restano {0:N1} MiB in meno; minimo nell ultimo minuto: {1:N1} MiB.' -f ($event.remaining_private_resident_reduction_bytes/1MB),($event.minimum_private_resident_reduction_last_60s_bytes/1MB)}else{''}
    switch([string]$event.reason) {
        'resident_reduction_retained_5m' {return 'RAM ridotta a 5 minuti.'+$measure+' Reattivita non misurata.'}
        'resident_reduction_retained_5m_with_activity' {return 'RAM ridotta a 5 minuti.'+$measure+' Attivita/fault aumentati: beneficio sulle prestazioni non dimostrato; nessun altro intervento.'}
        'resident_reduction_retained_5m_after_resume' {return 'RAM ridotta a 5 minuti anche dopo il ritorno dell app in primo piano.'+$measure+' Reattivita non misurata; nessun altro intervento.'}
        'resident_reduction_not_retained_5m' {return 'Riduzione non mantenuta stabilmente nell ultimo minuto della prova di 5 minuti. Coda interrotta; ripetizione bloccata per 30 minuti.'}
        'sustained_observation_not_causal_proof' {return 'Riduzione osservata a 60 s; prestazioni e risparmio causale non dimostrati.'}
        'resident_reduction_observed_after_activity_warning' {return 'RAM ridotta ancora a 60 s. Attivita/fault aumentati: beneficio sulle prestazioni non dimostrato; nessun altro intervento.'}
        'no_sustained_observed_benefit' {return 'Beneficio persistente sul PC non confermato. Coda interrotta; ripetizione bloccata per 30 minuti.'}
        'rapid_resident_rebound' {return 'RAM quasi tutta tornata: almeno 80% riassorbito per 4 s. Coda interrotta; ripetizione bloccata per 30 minuti su questa identita.'}
        'no_meaningful_resident_reduction' {return 'Riduzione inferiore a 16 MiB nei primi 5 s: beneficio troppo piccolo. Coda interrotta; ripetizione bloccata per 30 minuti.'}
        'resident_reduction_not_retained' {return 'Riduzione quasi tutta persa o inferiore a 16 MiB a 60 s. Coda interrotta; ripetizione bloccata per 30 minuti.'}
        'feedback_sampling_gap' {return 'Misura incompleta: campioni mancanti o troppo distanti. Nessun beneficio confermato.'}
        'activity_or_fault_increase_stop_further_actions' {return 'Misura interrotta: attivita o fault aumentati. Esito non conclusivo.'}
        'foreground_return_stop_further_actions' {return 'Misura interrotta: applicazione tornata in primo piano. Esito non conclusivo.'}
        'stopped_or_timed_out_before_eligibility' {return 'Nessun intervento: richiesta fermata o condizioni non raggiunte entro 3 minuti.'}
        'stopped_before_full_feedback_no_rollback' {return 'Misura incompleta: arresto prima della fine della verifica.'}
        'access_denied' {return 'Nessuna azione: accesso al processo negato.'}
        'empty_working_set_failed' {return 'Azione fallita: Windows non ha eseguito il recupero.'}
        default {return 'Recupero interrotto: '+[string]$event.reason}
    }
}

function Read-RecoveryHistory([string]$path,[DateTime]$now=[DateTime]::UtcNow) {
    if(!$path -or !(Test-Path -LiteralPath $path)){return @()}
    if((Get-Item -LiteralPath $path).Length -gt 1MB){throw 'Storico recupero troppo grande: nessuna nuova richiesta avviata.'}
    try{
        $data=[IO.File]::ReadAllText($path)|ConvertFrom-Json
        if($data.schema_version -ne 1 -or @($data.records).Count -gt 512){throw 'Schema non valido'}
        foreach($record in @($data.records)){
            if($record.key -notmatch '^[1-9][0-9]{0,9}:[1-9][0-9]{0,19}$' -or !$record.image_path -or $record.image_path.Length -gt 32768 -or
                $record.reason -notin @('rapid_resident_rebound','no_meaningful_resident_reduction','resident_reduction_not_retained','no_sustained_observed_benefit','resident_reduction_not_retained_5m')){throw 'Identita/esito non valido'}
            # PowerShell 7 may deserialize ISO dates as DateTime; 5.1 leaves strings.
            if($record.until_utc -is [DateTime]){$until=$record.until_utc.ToUniversalTime()}
            else{
                if([string]$record.until_utc -notmatch '^\d{4}-\d{2}-\d{2}T.*Z$'){throw 'Scadenza UTC non valida'}
                $until=[DateTime]::Parse([string]$record.until_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            }
            if($until -gt $now.AddMinutes(31)){throw 'Scadenza non valida'}
            $record.until_utc=$until.ToString('o')
            if($until -gt $now){Write-Output $record}
        }
    }catch{throw 'Storico recupero non leggibile: nessuna nuova richiesta avviata. Conserva reports/recovery-history.json per la diagnosi.'}
}
function Get-RecoveryRepeatBlock([string]$path,$target,[DateTime]$now=[DateTime]::UtcNow) {
    foreach($record in @(Read-RecoveryHistory $path $now)){
        if($record.key -eq $target.Key -and [string]::Equals([string]$record.image_path,[string]$target.Path,[StringComparison]::OrdinalIgnoreCase)){
            $minutes=[math]::Max(1,[math]::Ceiling(([DateTime]::Parse([string]$record.until_utc).ToUniversalTime()-$now).TotalMinutes))
            return ('Recupero sconsigliato per {0}: precedente riduzione insufficiente o non duratura. Riprova tra circa {1} minuti.' -f $target.Name,$minutes)
        }
    }
    return ''
}
function Save-RecoveryOutcome([string]$path,$event,$authorized,[DateTime]$now=[DateTime]::UtcNow) {
    if(!$path -or $event.type -ne 'recover_assessed' -or $event.reason -notin @('rapid_resident_rebound','no_meaningful_resident_reduction','resident_reduction_not_retained','no_sustained_observed_benefit','resident_reduction_not_retained_5m')){return}
    $key=[string]$event.pid+':'+[string]$event.creation_filetime
    if($key -notmatch '^[1-9][0-9]{0,9}:[1-9][0-9]{0,19}$' -or !$event.image_path){return}
    $match=@($authorized|Where-Object {$_.Key -eq $key -and [string]::Equals([string]$_.Path,[string]$event.image_path,[StringComparison]::OrdinalIgnoreCase)})
    if($match.Count -ne 1){return}
    $records=@(Read-RecoveryHistory $path $now|Where-Object {$_.key -ne $key}|Select-Object -Last 511)
    $records+=@([pscustomobject]@{key=$key;image_path=[string]$event.image_path;reason=[string]$event.reason;until_utc=$now.AddMinutes(30).ToString('o')})
    $directory=[IO.Path]::GetDirectoryName($path);[void][IO.Directory]::CreateDirectory($directory)
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $json=@{schema_version=1;records=@($records)}|ConvertTo-Json -Depth 5
        if([Text.Encoding]::UTF8.GetByteCount($json) -gt 1MB){throw 'Storico recupero troppo grande: salvataggio interrotto.'}
        [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($path)){[IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$path)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}

function Get-RecoveryLiveMeasurement($measurement,[switch]$Final) {
    if($null -eq $measurement.Before -or $null -eq $measurement.After){return 'INTERVENTO ESEGUITO. Misura RAM attuale non disponibile; riduzione non quantificabile.'}
    $drop=([double]$measurement.Before-[double]$measurement.After)/1MB
    $status=if($drop -gt 0){'RAM DIMINUITA: {0:N1} MiB in meno.' -f $drop}elseif($drop -lt 0){'RAM RISALITA: {0:N1} MiB in piu rispetto a prima.' -f (-$drop)}else{'RAM INVARIATA rispetto a prima.'}
    $text=$status+(' Prima {0:N1} MiB -> {1} {2:N1} MiB (a {3:N0} s dall intervento).' -f ($measurement.Before/1MB),$(if($Final){'ultima misura'}else{'ora'}),($measurement.After/1MB),$measurement.Seconds)
    if(!$Final){$text+=' Verifica della durata in corso (5 minuti).'}
    if($measurement.Note){$text+=' '+$measurement.Note}
    return $text
}
