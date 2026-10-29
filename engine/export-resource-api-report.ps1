param([string]$TracePath='',[string]$OutputPath='',[string]$SourceRoot=$PSScriptRoot,[string]$Failure='',[int]$NativeExitCode=-1)
$ErrorActionPreference='Stop'

function ConvertTo-ApiHtml($value){return [Net.WebUtility]::HtmlEncode([string]$value)}
function Format-ApiMiB($value){
    if($null -eq $value){return 'Non disponibile'}
    return ([double]$value / 1048576).ToString('0.0',[Globalization.CultureInfo]::GetCultureInfo('it-IT'))+' MiB'
}
function Get-ApiSourceListing([string]$path){
    if(!(Test-Path -LiteralPath $path)){return 'Sorgente non disponibile in questa cartella.'}
    $lines=[IO.File]::ReadAllLines($path,[Text.Encoding]::UTF8)
    $out=New-Object Text.StringBuilder
    for($i=0;$i -lt $lines.Length;$i++){[void]$out.AppendLine(('{0,4}: {1}' -f ($i+1),$lines[$i]))}
    return $out.ToString()
}
function Write-ResourceApiReport {
    param([string]$TracePath,[string]$OutputPath,[string]$SourceRoot,[string]$Failure='',[int]$NativeExitCode=-1)
    if(!$OutputPath){throw 'Specificare il percorso del resoconto HTML.'}
    $records=New-Object 'Collections.Generic.List[object]'
    $invalid=0;$partial=$false
    if($TracePath -and (Test-Path -LiteralPath $TracePath)){
        $bytes=[IO.File]::ReadAllBytes($TracePath)
        if($bytes.Length -gt 4194304){throw 'Registro API oltre il limite di 4 MiB.'}
        $utf8=New-Object Text.UTF8Encoding($false,$true)
        $text=$utf8.GetString($bytes)
        $partial=$text.Length -gt 0 -and !$text.EndsWith("`n")
        $lines=$text.Split([char]10)
        $last=$lines.Length-1
        for($i=0;$i -lt $lines.Length;$i++){
            if($partial -and $i -eq $last){continue}
            $line=$lines[$i].TrimEnd([char]13)
            if(!$line){continue}
            if($line.Length -gt 65536){$invalid++;continue}
            try{
                $r=$line|ConvertFrom-Json
                if($r.type -isnot [string] -or [string]$r.seq -notmatch '^\d+$' -or [string]$r.elapsed_ms -notmatch '^\d+$'){$invalid++;continue}
                [void][long]::Parse([string]$r.seq);[void][long]::Parse([string]$r.elapsed_ms)
                [void]$records.Add($r)
            }catch{$invalid++}
        }
    }
    $starts=@($records|Where-Object {$_.type -eq 'session_start'})
    $ends=@($records|Where-Object {$_.type -eq 'session_end'})
    $end=$null;if($ends.Count){$end=$ends[-1]}
    $orderValid=$true;$lastSeq=0;$lastTime=0
    foreach($r in $records){
        if([long]$r.seq -ne ($lastSeq+1) -or [long]$r.elapsed_ms -lt $lastTime){$orderValid=$false}
        $lastSeq=[long]$r.seq
        $lastTime=[long]$r.elapsed_ms
    }
    $complete=$starts.Count -eq 1 -and $ends.Count -eq 1 -and $records.Count -ge 2 -and
        $records[0].type -eq 'session_start' -and $records[$records.Count-1].type -eq 'session_end' -and
        $invalid -eq 0 -and !$partial -and $orderValid
    if($starts.Count -eq 1){$complete=$complete -and $starts[0].trace_version -eq 1 -and $starts[0].api_abi -eq 1}
    if(@($records|Where-Object {$_.type -eq 'check' -and $_.passed -eq $false}).Count){$complete=$false}
    $passed=$complete -and $end.passed -eq $true -and $NativeExitCode -in @(-1,0) -and !$Failure
    $origin='Registro non disponibile'
    if($starts.Count){$origin=[string]$starts[0].data_origin}
    $synthetic=$origin -eq 'synthetic_test'
    $status='OSSERVAZIONE INCOMPLETA';$statusClass='warn'
    if($passed){$status='DEMO COMPLETATA';$statusClass='ok'}
    elseif($Failure -or ($end -and $end.passed -eq $false) -or $NativeExitCode -gt 0){$status='DEMO NON COMPLETATA';$statusClass='bad'}
    if($synthetic){$status='ANTEPRIMA CON DATI SINTETICI';$statusClass='warn'}
    $calls=@($records|Where-Object {$_.type -eq 'call'})
    $before=@($records|Where-Object {$_.type -eq 'snapshot' -and $_.label -eq 'before_growth'}|Select-Object -First 1)
    $after=@($records|Where-Object {$_.type -eq 'snapshot' -and $_.label -eq 'after_growth'}|Select-Object -First 1)
    $beforeText='Non disponibile';$afterText='Non disponibile'
    if($before.Count -and ([int]$before[0].flags -band 1)){$beforeText=Format-ApiMiB $before[0].private_commit_sum_bytes}
    if($after.Count -and ([int]$after[0].flags -band 1)){$afterText=Format-ApiMiB $after[0].private_commit_sum_bytes}
    $notices=@($records|Where-Object {$_.type -eq 'event' -and $_.kind -eq 4})
    $noticeText='Nessun avviso di soglia registrato'
    if($notices.Count){$noticeText='Avviso Windows ricevuto oltre '+(Format-ApiMiB $notices[0].commit_notice_bytes)}
    $checksText='Non disponibile';if($end){$checksText=[string]$end.checks}
    $failureText=$Failure
    if(!$failureText -and $end -and $end.error){$failureText=[string]$end.error}
    if(!$complete){$failureText+=(' Registro incompleto o non valido: righe errate {0}; riga finale parziale {1}; sequenza valida {2}.' -f $invalid,$partial,$orderValid)}

    $descriptions=[ordered]@{
        AmeGetApiVersion=@('Versione dell interfaccia','Restituisce la versione ABI della nostra API.','Costante AME_RESOURCE_ABI_VERSION; nessuna operazione sui processi.')
        AmeGetLastWindowsError=@('Dettaglio dell errore Windows','Legge il codice Win32 conservato per il thread chiamante.','Variabile thread_local; non modifica un processo.')
        AmeCreateGroup=@('Creazione del gruppo','Crea un Job Object privato e la coda per ricevere eventi.','CreateJobObjectW; SetInformationJobObject; CreateIoCompletionPort. SILENT_BREAKAWAY_OK: i figli futuri non sono inclusi automaticamente.')
        AmeReadProcessIdentity=@('Identificazione del processo','Legge PID, tempo di creazione e percorso. Serve a distinguere un processo da un successivo riutilizzo del PID.','OpenProcess; GetProcessTimes; QueryFullProcessImageNameW.')
        AmeAttachProcess=@('Associazione esplicita','Ricontrolla identita, proprietario, sessione, criticita e job preesistenti. Associa solo se i controlli riescono.','OpenProcess; ProcessIdToSessionId; GetTokenInformation; IsProcessCritical; IsProcessInJob; AssignProcessToJobObject. Le ramificazioni eseguite dipendono dal risultato registrato.')
        AmeSetCommitNotice=@('Soglia di avviso','Imposta una notifica sulla memoria assegnata. Il processo puo continuare a superare la soglia. Zero disabilita l avviso.','SetInformationJobObject con JobObjectNotificationLimitInformation. Non usa JOB_OBJECT_LIMIT_JOB_MEMORY nella classe dei limiti rigidi.')
        AmeReadGroupSnapshot=@('Lettura dei consumi','Legge memoria dei membri, contatori del job e variazioni misurabili. Non esegue una riduzione.','QueryInformationJobObject con JobObjectBasicAndIoAccountingInformation; GetProcessMemoryInfo; calculate_rates.')
        AmePollGroupEvent=@('Lettura di un evento','Controlla la coda senza attendere un nuovo evento. Per gli avvisi legge la violazione e riconosce il messaggio.','GetQueuedCompletionStatus con timeout zero; QueryInformationJobObject con JobObjectLimitViolationInformation.')
        AmeCloseGroup=@('Fine del monitoraggio','Disabilita gli avvisi e rilascia gli handle del controller. Non termina i membri e non li stacca dal job.','set_notice(0); groups.erase; distruttori Handle con CloseHandle. Non viene impostato KILL_ON_JOB_CLOSE.')
        AmeRegisterInternalProcessHandler=@('Registrazione callback interna','Registra un gestore cooperativo interno al processo per il rilascio di cache applicative.','Puntatore a funzione protetto da mutex nella DLL.')
        AmeCompactCurrentProcess=@('Compattazione processo interno','Esegue la callback registrata e compatta tutti gli heap Win32 e CRT del processo corrente.','GetProcessHeaps; HeapCompact; _heapmin; GetProcessMemoryInfo.')
        AmeExecuteProcessReclaim=@('Intervento graduato sul processo','Verifica identita, sessione, assenza primo piano e applica Memory Priority, EcoQoS o Working Set Trim.','SetProcessInformation(ProcessMemoryPriority / ProcessPowerThrottling); EmptyWorkingSet.')
        AmeReclaimGroupBudget=@('Rilascio distribuito sul gruppo','Ordina i membri attivi per Working Set e distribuisce il budget richiesto fino al raggiungimento del target.','Iterazione ordinata sui membri del Job Object con esclusione della finestra in primo piano.')
    }
    $phases=@{setup='Preparazione';contract='Contratto e richieste errate';identity='Identita e associazione';memory_notice='Memoria e avviso Windows';lifecycle='Compatibilita e chiusura';capacity='Limiti dei gruppi'}
    $results=@{0='Eseguito';1='Argomento rifiutato';2='Gruppo non valido';3='Errore Windows';4='Identita cambiata / non corrispondente';5='Processo escluso';6='Gia gestito da un job';7='Capacita raggiunta';8='Nessun evento disponibile'}
    $operations=New-Object Text.StringBuilder
    foreach($name in $descriptions.Keys){
        $d=$descriptions[$name]
        [void]$operations.Append('<details class="operation" id="'+$name+'"><summary><strong>'+ (ConvertTo-ApiHtml $d[0])+'</strong> <code>'+ $name+'</code></summary><p>'+ (ConvertTo-ApiHtml $d[1])+'</p><p class="technical">'+(ConvertTo-ApiHtml $d[2])+'</p><p><a href="#source-api">Leggi il codice reale della DLL</a> · <a href="#source-demo">Leggi il client della demo</a></p></details>')
    }
    $rows=New-Object Text.StringBuilder
    foreach($r in $records){
        $phase=[string]$r.phase;if($phases.ContainsKey($phase)){$phase=$phases[$phase]}
        $time=([double]$r.elapsed_ms/1000).ToString('0.000',[Globalization.CultureInfo]::InvariantCulture)+' s'
        $title='';$detail='';$badge='';$class='neutral'
        switch([string]$r.type){
            'call' {
                $expression=[string]$r.expression
                $match=[regex]::Match($expression,'\b(Ame\w+)\(')
                $name=$match.Groups[1].Value
                $label=$name;if($descriptions.Contains($name)){$label=$descriptions[$name][0]}
                $title=ConvertTo-ApiHtml $label
                if($descriptions.Contains($name)){$title='<a href="#'+$name+'">'+$title+'</a>'}
                $detail='<code>'+ (ConvertTo-ApiHtml $expression)+'</code><br>Esito API: '+(ConvertTo-ApiHtml $r.result)+'; dettaglio Windows: '+(ConvertTo-ApiHtml $r.windows_error)
                $code=[int]$r.result;$badge=$results[$code];if(!$badge){$badge='Esito API non riconosciuto'}
                if($code -eq 0){$class='ok'}elseif($code -ne 8){$class='warn'}
            }
            'check' {
                $title='Controllo della demo'
                $detail='<span class="technical">'+(ConvertTo-ApiHtml $r.message)+'</span>'
                if($r.passed -eq $true){$badge='Verificato';$class='ok'}else{$badge='Non verificato';$class='bad'}
            }
            'snapshot' {
                $title='Misura dei consumi';$badge='Campione'
                $detail='Gruppo '+(ConvertTo-ApiHtml $r.group)+'; processi attivi '+(ConvertTo-ApiHtml $r.active_processes)+'; misurati '+(ConvertTo-ApiHtml $r.measured_processes)
                if([int]$r.flags -band 1){
                    $detail+='<br>Memoria privata assegnata: '+(Format-ApiMiB $r.private_commit_sum_bytes)+'; somma working set: '+(Format-ApiMiB $r.working_set_sum_bytes)
                }else{$detail+='<br>Misura memoria incompleta: i totali parziali non sono presentati come consumo completo.'}
                if([int]$r.flags -band 2){
                    $cpu=([double]$r.cpu_percent_machine).ToString('0.00',[Globalization.CultureInfo]::GetCultureInfo('it-IT'))
                    $faults=([double]$r.page_faults_per_second).ToString('0.0',[Globalization.CultureInfo]::GetCultureInfo('it-IT'))
                    $detail+='<br>CPU intero PC: '+$cpu+'%; fault totali/s: '+$faults+'; intervallo: '+(ConvertTo-ApiHtml $r.rate_interval_ms)+' ms'
                }else{$detail+='<br>Tassi di attivita non disponibili per questo campione.'}
            }
            'event' {
                $title='Evento ricevuto da Windows';$badge='Evento reale del registro'
                $detail='Messaggio '+(ConvertTo-ApiHtml $r.windows_message)+'; tipo AME '+(ConvertTo-ApiHtml $r.kind)+'; PID '+(ConvertTo-ApiHtml $r.pid)
                if($r.kind -eq 4){$detail+='<br>Avviso di memoria: '+(Format-ApiMiB $r.job_commit_bytes)+'; soglia '+(Format-ApiMiB $r.commit_notice_bytes);$class='ok'}
            }
            'process' {$title='Identita del processo letta';$badge='Identificato';$detail='PID '+(ConvertTo-ApiHtml $r.pid)+'; tempo di creazione FILETIME '+(ConvertTo-ApiHtml $r.creation_filetime)}
            'phase' {$title=ConvertTo-ApiHtml $phase;$badge='Inizio fase'}
            'session_start' {$title='Inizio della sessione';$badge='Registro aperto';$detail='ABI '+(ConvertTo-ApiHtml $r.api_abi)+'; origine '+(ConvertTo-ApiHtml $r.data_origin)}
            'session_end' {
                $title='Fine della sessione';$detail='Controlli eseguiti: '+(ConvertTo-ApiHtml $r.checks)
                if($r.passed -eq $true){$badge='Terminata';$class='ok'}else{$badge='Errore';$class='bad';$detail+='<br>'+(ConvertTo-ApiHtml $r.error)}
            }
            default {$title='Voce del registro';$badge=ConvertTo-ApiHtml $r.type}
        }
        [void]$rows.Append('<tr><td class="time">'+$time+'</td><td><small>'+ (ConvertTo-ApiHtml $phase)+'</small><br><strong>'+$title+'</strong><div class="detail">'+$detail+'</div></td><td><span class="badge '+$class+'">'+(ConvertTo-ApiHtml $badge)+'</span></td></tr>')
    }
    if(!$records.Count){[void]$rows.Append('<tr><td colspan="3">Nessuna chiamata nativa registrata. Consulta il messaggio di errore sopra.</td></tr>')}
    $sourceSections=New-Object Text.StringBuilder
    foreach($source in @(@('source-api','Implementazione della DLL','src/resource_api.cpp'),@('source-analysis','Calcolo degli andamenti','src/resource_analysis.hpp'),@('source-contract','Contratto pubblico C','sdk/ame_resource_api.h'),@('source-demo','Client ed esecuzione della demo','examples/resource_api_demo.cpp'),@('source-journal','Scrittura del registro','src/resource_trace.hpp'))){
        $listing=Get-ApiSourceListing (Join-Path $SourceRoot $source[2])
        [void]$sourceSections.Append('<details class="source" id="'+$source[0]+'"><summary>'+ (ConvertTo-ApiHtml $source[1])+' <code>'+(ConvertTo-ApiHtml $source[2])+'</code></summary><pre>'+ (ConvertTo-ApiHtml $listing)+'</pre></details>')
    }
    $errorBox='';if($failureText){$errorBox='<div class="notice warn">'+(ConvertTo-ApiHtml $failureText)+'</div>'}
    $originBox='';if($synthetic){$originBox='<div class="notice warn">Questa anteprima usa dati sintetici per verificare il resoconto. Non documenta una prova eseguita su Windows.</div>'}
    $traceName='Non creato';if($TracePath){$traceName=Split-Path -Path $TracePath -Leaf}
    $html=@"
<!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AME — Resoconto API nativa</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f1f5f9;color:#17283c;font:15px/1.55 Segoe UI,Arial,sans-serif}main{max-width:1120px;margin:auto;padding:32px 24px 60px}header{background:#132b45;color:white;padding:30px;border-radius:16px}header p{color:#dbe6f1;max-width:850px}h1{font-size:30px;line-height:1.2;margin:8px 0 16px}h2{font-size:21px;margin:30px 0 14px}h3{margin:0 0 8px}.eyebrow{font-size:12px;text-transform:uppercase;letter-spacing:1.5px}a{color:#145ca3}nav{display:flex;gap:20px;flex-wrap:wrap;padding:18px 0}section,.card{background:white;border:1px solid #dce4ee;border-radius:12px;padding:22px}section{margin:18px 0}.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin:20px 0}.metric{font-size:27px;font-weight:700;margin-top:10px}.muted,small{color:#566b80}small{font-size:12px}.notice{padding:14px 18px;border-radius:9px;margin:16px 0}.notice.warn{background:#fff4d9;color:#654914}.badge{display:inline-block;padding:5px 9px;border-radius:6px;font-size:12px;font-weight:600}.ok{background:#e3f3ec;color:#126244}.warn{background:#fff1d6;color:#7a5317}.bad{background:#fbe7e7;color:#9e2929}.neutral{background:#eaf0f7;color:#41586e}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:13px 12px;border-bottom:1px solid #e4eaf1;vertical-align:top}th{background:#edf3f9;font-size:12px;text-transform:uppercase;color:#496078}td.time{white-space:nowrap;width:90px;font-variant-numeric:tabular-nums}.detail{margin-top:6px;font-size:13px;color:#405870}.technical,code,pre{font-family:Consolas,monospace}code{font-size:12px;overflow-wrap:anywhere}details{border:1px solid #dde6f0;border-radius:8px;margin:10px 0;padding:13px 16px}summary{cursor:pointer;color:#214d78}summary code{margin-left:12px}.operation p{margin-bottom:6px}.operation .technical{font-size:13px;color:#48617b}pre{background:#102239;color:#dbe8f4;padding:18px;overflow:auto;font-size:12px;line-height:1.65;max-height:640px;border-radius:8px}.scroll{overflow:auto}.plain-list li{margin:8px 0}footer{font-size:12px;color:#61758a;margin-top:22px}@media(max-width:740px){main{padding:16px 12px}.cards{grid-template-columns:1fr}header{padding:22px}h1{font-size:25px}td{min-width:115px}}@media print{body{background:white}main{max-width:none}.source{break-inside:avoid}header{color:#17283c;background:#edf3f9}header p{color:#405870}}
</style></head><body><main>
<header><div class="eyebrow">AME Resource API · Registro della demo</div><h1>Cosa ha fatto la nostra API</h1><span class="badge $statusClass">$(ConvertTo-ApiHtml $status)</span><p>La nostra DLL C++ usa i Job Object di Windows per associare processi verificati, leggere i consumi e ricevere avvisi. Questa prova verifica il controllo e le misure; non applica una riduzione RAM.</p></header>
$originBox$errorBox
<nav><a href="#result">Risultato</a><a href="#steps">Operazioni eseguite</a><a href="#functions">Funzioni spiegate</a><a href="#code">Codice sorgente</a></nav>
<div class="cards" id="result"><div class="card"><small>Memoria privata assegnata al processo demo</small><div class="metric">$beforeText → $afterText</div><p class="muted">La demo richiede deliberatamente altri 64 MiB per verificare l'avviso.</p></div><div class="card"><small>Notifica di memoria</small><div class="metric" style="font-size:20px">$(ConvertTo-ApiHtml $noticeText)</div><p class="muted">Una notifica lascia continuare l'applicazione oltre la soglia.</p></div><div class="card"><small>Controlli dichiarati dalla sessione</small><div class="metric">$(ConvertTo-ApiHtml $checksText)</div><p class="muted">Chiamate API registrate: $($calls.Count). Include richieste errate intenzionali.</p></div></div>
<section><h3>Come leggere questi dati</h3><ul class="plain-list"><li>Nella prova prevista, circa 8 → 72 MiB indica una <strong>crescita voluta della memoria assegnata</strong>, non una riduzione. I valori osservati sono nelle schede sopra.</li><li>La memoria assegnata puo risiedere in RAM o avere altre forme di supporto. La somma dei working set puo contare piu volte pagine condivise.</li><li>Un rifiuto puo essere previsto: la demo prova identita false, gruppi chiusi e limiti di capacita. Il controllo successivo indica se il comportamento atteso e stato verificato.</li><li>CPU, I/O e fault sono misure di attivita. I fault totali non identificano da soli le letture dal disco e non dimostrano un rallentamento.</li><li>Il pannello R15 carica questa API con AVVIA e verifica le identita prima della richiesta e prima di avviare il motore R10. I Job Object restano nella demo; la DLL non applica la riduzione RAM.</li></ul></section>
<h2 id="steps">Operazioni eseguite, in ordine</h2><section class="scroll"><table><thead><tr><th>Tempo</th><th>Operazione e dati osservati</th><th>Esito</th></tr></thead><tbody>$($rows.ToString())</tbody></table></section>
<h2 id="functions">Dalla nostra API alle funzioni Windows</h2><section><p>Le righe del registro documentano le chiamate pubbliche eseguite dal client. Le spiegazioni sotto descrivono il codice della DLL, comprese le ramificazioni possibili: non sono una traccia interna di ogni chiamata Win32.</p>$($operations.ToString())</section>
<h2 id="code">Codice sorgente consultabile</h2><section><p>Questi sono i file presenti nella cartella dell'esecuzione, con numeri di riga. Puoi espanderli anche dopo aver copiato questo HTML. Il sorgente descrive l'implementazione; gli esiti effettivi sono nel registro sopra.</p>$($sourceSections.ToString())</section>
<footer>Registro: $(ConvertTo-ApiHtml $traceName). Resoconto generato localmente. Nessuna risorsa esterna e nessuno script vengono caricati.</footer>
</main></body></html>
"@
    $parent=Split-Path -Path $OutputPath -Parent
    if($parent){[void][IO.Directory]::CreateDirectory($parent)}
    [IO.File]::WriteAllText($OutputPath,$html,(New-Object Text.UTF8Encoding($true)))
    return [IO.Path]::GetFullPath($OutputPath)
}
if($TracePath -or $OutputPath){Write-ResourceApiReport -TracePath $TracePath -OutputPath $OutputPath -SourceRoot $SourceRoot -Failure $Failure -NativeExitCode $NativeExitCode}
