param(
    [string[]]$Report,
    [string]$OutputDirectory,
    [ValidateRange(1,100)][int]$MaxReports=10,
    [ValidateRange(1048576,1073741824)][long]$MaxBytes=134217728
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if(!$OutputDirectory){$OutputDirectory=Join-Path $PSScriptRoot 'exports'}
if($Report){
    $files=@($Report|ForEach-Object {Get-Item -LiteralPath $_})
}else{
    $folder=Join-Path $PSScriptRoot 'reports'
    if(!(Test-Path -LiteralPath $folder)){throw 'Nessuna cartella reports: avvia prima il pannello.'}
    $files=@(Get-ChildItem -LiteralPath $folder -File -Filter '*.jsonl'|Where-Object {$_.Name -match '^(observe|recover|browser|panel|comparison)-'}|Sort-Object LastWriteTime -Descending|Select-Object -First $MaxReports)
}
if(!$files.Count){throw 'Nessun report Windows da raccogliere.'}
New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
$OutputDirectory=(Resolve-Path -LiteralPath $OutputDirectory).Path
$id=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$zipPath=Join-Path $OutputDirectory ('AME-diagnosi-'+$id+'.zip')
$stage=Join-Path ([IO.Path]::GetTempPath()) ('ame-diagnosi-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $stage 'reports'))
$items=New-Object 'Collections.Generic.List[object]'
$warnings=New-Object 'Collections.Generic.List[string]'
$text=New-Object 'Collections.Generic.List[string]'
$bytesIncluded=0L; $totalApplied=0
$browserConfirmedRequests=@{}
$browserOutcomes=New-Object 'Collections.Generic.List[object]'
$comparisonOutcomes=New-Object 'Collections.Generic.List[object]'
$agentOutcomes=New-Object 'Collections.Generic.List[object]'
$reasonLabels=@{foreground_family='App in primo piano o appartenente alla sua famiglia';telemetry_missing='Dati necessari mancanti';low_activity_under_60_seconds='Non ancora poco attivo per 60 secondi';waiting_pressure_85_percent_30_seconds='RAM non rimasta almeno all 85% per 30 secondi';selected_process_no_longer_running='Processo selezionato non piu presente';session_limit_or_already_attempted='Limite sessione, cooldown o processo gia tentato'}
function Get-MiB($value){if($null -eq $value){return 'N/D'};return ('{0:N1}' -f ([double]$value/1MB))}
function Copy-CompleteReport([string]$source,[string]$destination,[long]$limit){
    $inputStream=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $outputStream=$null
    try {
        $length=$inputStream.Length
        if($length -gt $limit){return [pscustomobject]@{Skipped=$true;Reason='limite dimensione raccolta';Bytes=0;TailBytes=0}}
        $outputStream=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $buffer=New-Object byte[] 65536
        $remaining=$length
        while($remaining -gt 0){
            $read=$inputStream.Read($buffer,0,[int][math]::Min($buffer.Length,$remaining))
            if(!$read){break};$outputStream.Write($buffer,0,$read);$remaining-=$read
        }
        $captured=$outputStream.Length;$position=$captured;$complete=0L
        while($position -gt 0){
            $count=[int][math]::Min($buffer.Length,$position);$position-=$count
            $outputStream.Position=$position
            $read=$outputStream.Read($buffer,0,$count)
            for($i=$read-1;$i -ge 0;$i--){if($buffer[$i] -eq 10){$complete=$position+$i+1;break}}
            if($complete){break}
        }
        $outputStream.SetLength($complete)
        return [pscustomobject]@{Skipped=$false;Bytes=$complete;TailBytes=$captured-$complete}
    }finally{if($outputStream){$outputStream.Dispose()};$inputStream.Dispose()}
}
try {
    $text.Add('AME - DIAGNOSI AUTOMATICA')
    $text.Add('Questa raccolta legge i report: non avvia recuperi, non cambia priorita e non termina applicazioni.')
    $text.Add('Le variazioni osservate non dimostrano risparmio causale; la latenza delle app non e misurata.')
    $text.Add('')
    $index=0
    foreach($file in $files){
        if($file.PSIsContainer){throw 'Report deve essere un file JSONL.'}
        $index++
        $name=('{0:D3}-' -f $index)+$file.Name
        $copy=Join-Path (Join-Path $stage 'reports') $name
        $snapshot=Copy-CompleteReport $file.FullName $copy ($MaxBytes-$bytesIncluded)
        if($snapshot.Skipped){$warnings.Add($file.Name+': escluso per '+$snapshot.Reason);continue}
        $bytesIncluded+=$snapshot.Bytes
        $counts=@{};$reasons=@{};$intents=@{};$feedback=New-Object 'Collections.Generic.List[object]'
        $browserDiscards=0
        $browserFeedback=New-Object 'Collections.Generic.List[object]'
        $guards=New-Object 'Collections.Generic.List[object]'
        $first=$null;$last=$null;$lastState=$null;$bad=0;$samples=0
        $reader=New-Object IO.StreamReader($copy,[Text.Encoding]::UTF8,$true)
        try {
            while($null -ne ($line=$reader.ReadLine())){
                if(!$line.Trim()){continue}
                try{$event=$line|ConvertFrom-Json -ErrorAction Stop}catch{$bad++;continue}
                if(!$event.type){$bad++;continue}
                $type=[string]$event.type
                if(!$counts.ContainsKey($type)){$counts[$type]=0};$counts[$type]++
                if($type -eq 'recover_intent'){$intents[[string]$event.pid]=$true}
                elseif($type -in @('recover_applied','recover_skipped')){$intents.Remove([string]$event.pid)}
                if($type -eq 'sample'){
                    $samples++
                    $sample=[pscustomobject]@{elapsed_seconds=$event.elapsed_seconds;physical_total_bytes=$event.physical_total_bytes;physical_available_bytes=$event.physical_available_bytes;commit_bytes=$event.commit_bytes}
                    if(!$first){$first=$sample};$last=$sample
                }elseif($type -eq 'recover_state'){
                    $lastState=$event
                    if($event.reasons){foreach($property in $event.reasons.PSObject.Properties){
                        if(!$reasons.ContainsKey($property.Name)){$reasons[$property.Name]=0L}
                        $reasons[$property.Name]+=[long]$property.Value
                    }}
                }elseif($type -eq 'recover_feedback'){$feedback.Add($event)}
                elseif($type -eq 'browser_visible_log'){
                    $text.Add('STATO COLLEGAMENTO: '+[string]$event.message)
                    if($event.log_failure){$text.Add('REGISTRO INCOMPLETO: '+[string]$event.log_failure)}
                    foreach($visibleLine in @($event.lines)){$text.Add([string]$visibleLine)}
                }
                elseif($type -eq 'browser_result'){
                    $browserName=if($event.browser -eq 'Firefox'){'Firefox'}else{'Chrome'}
                    if($event.outcome -eq 'discarded'){
                        $text.Add($browserName+': SCARICAMENTO SCHEDA CONFERMATO (richiesta '+$event.request+'). La riduzione RAM e ancora da misurare.')
                        $requestKey=[string]$event.request
                        if($requestKey -and !$browserConfirmedRequests.ContainsKey($requestKey)){$browserConfirmedRequests[$requestKey]=$true;$browserDiscards++}
                    }else{$text.Add($browserName+': SCHEDA NON SCARICATA. '+[string]$event.reason)}
                }
                elseif($type -eq 'agent_assessed'){
                    $agentOutcomes.Add($event)
                    $text.Add('ESITO AGENTE AUTOMATICO: '+[string]$event.message+' [ '+[string]$event.outcome+' ]')
                    if($null -ne $event.assessment.NetObservedDropBytes){$text.Add('RAM privata residente netta osservata, costo agente incluso: '+(Get-MiB $event.assessment.NetObservedDropBytes)+' MiB; non attribuita alla singola scheda.')}
                }
                elseif($type -in @('agent_start','agent_status','agent_connection','agent_request','agent_declined','agent_error','agent_end')){$text.Add('AGENTE ['+$type+']: '+[string]$event.message)}
                elseif($type -eq 'agent_reactivation'){$text.Add('RIAPERTURA AGENTE: caricamento osservato '+$event.load_observed_ms+' ms; prontezza dell app non misurata.')}
                elseif($type -eq 'comparison_assessed'){
                    $comparisonOutcomes.Add($event)
                    $text.Add('CONFRONTO BENEFICIO: '+[string]$event.status+' [ '+[string]$event.outcome.Code+' ]')
                    if($null -ne $event.outcome.NetObservedDropBytes){$text.Add('Differenza netta osservata di RAM privata residente (costo AME incluso): '+(Get-MiB $event.outcome.NetObservedDropBytes)+' MiB. Non prova risparmio causale sul PC o maggiore velocita.')}
                }
                elseif($type -eq 'comparison_reactivation'){$text.Add('RIAPERTURA BROWSER: '+$event.load_observed_ms+' ms fino al caricamento completato; prontezza dell app e latenza della fase 1 non misurate.')}
                elseif($type -eq 'browser_feedback'){
                    $browserFeedback.Add($event)
                    if($browserFeedback.Count -gt 100){$browserFeedback.RemoveAt(0)}
                }
                elseif($type -eq 'browser_assessed'){
                    $browserOutcomes.Add($event)
                    $text.Add('ESITO MEMORIA BROWSER: '+[string]$event.status+' [ '+[string]$event.outcome+' ]')
                }
                elseif($type -eq 'browser_connection'){$text.Add('COLLEGAMENTO ['+[string]$event.code+']: '+[string]$event.message)}
                elseif($type -in @('recover_guard','recover_assessed','recover_incomplete','recover_skipped')){$guards.Add($event)}
            }
        }finally{$reader.Dispose()}
        $applied=if($counts.ContainsKey('recover_applied')){[int]$counts['recover_applied']}else{0}
        $totalApplied+=$applied
        $items.Add([pscustomobject]@{source_name=$file.Name;archive_entry=('reports/'+$name);bytes=$snapshot.Bytes;incomplete_tail_bytes_omitted=$snapshot.TailBytes;invalid_complete_lines=$bad;
            browser_discard_confirmations=$browserDiscards;browser_feedback=@($browserFeedback.ToArray());event_counts=$counts;sample_count=$samples;first_sample=$first;last_sample=$last;applied_count=$applied;reason_process_sample_counts=$reasons;
            last_recover_state=$lastState;feedback=@($feedback.ToArray());outcomes=@($guards.ToArray());unresolved_intent_count=$intents.Count;has_end_event=($counts.ContainsKey('end') -or $counts.ContainsKey('comparison_end') -or $counts.ContainsKey('agent_end'))})
        $text.Add('REPORT: '+$file.Name)
        $text.Add('Campioni: '+$samples+' | Prove sui processi applicate: '+$applied+' | Schede scaricate confermate: '+$browserDiscards+' | Uscita ordinata presente: '+$counts.ContainsKey('end'))
        if($first -and $last){$text.Add('Disponibile sistema: '+(Get-MiB $first.physical_available_bytes)+' -> '+(Get-MiB $last.physical_available_bytes)+' MiB (osservazione, non risparmio attribuito).')}
        if(!$applied -and !$browserDiscards){$text.Add('NESSUN INTERVENTO APPLICATO REGISTRATO in questo report. I log di collegamento non dimostrano una riduzione RAM.')}
        elseif(!$applied){$text.Add('Gli scaricamenti sono confermati dal browser. Cerca ESITO MEMORIA BROWSER o ESITO AGENTE AUTOMATICO per valutare la RAM; il conteggio delle prove sui processi non include le schede.')}
        foreach($key in @($reasons.Keys|Sort-Object)){
            $label=if($reasonLabels.ContainsKey($key)){$reasonLabels[$key]}else{$key}
            $text.Add('Attesa: '+$label+' ('+$key+'): '+$reasons[$key]+' campioni-processo; non processi unici e non secondi.')
        }
        foreach($entry in $feedback){$text.Add('PID '+$entry.pid+' ['+$entry.phase+']: delta RAM privata '+(Get-MiB $entry.private_resident_delta_bytes)+' MiB; commit '+(Get-MiB $entry.private_commit_delta_bytes)+' MiB; disponibile sistema '+(Get-MiB $entry.system_available_delta_bytes)+' MiB.')}
        foreach($entry in $guards){$text.Add($entry.type+' PID '+$entry.pid+': '+$entry.reason)}
        if($snapshot.TailBytes){$text.Add('Ultima riga incompleta omessa: '+$snapshot.TailBytes+' byte. Il file sorgente non e modificato.')}
        if($bad){$warnings.Add($file.Name+': '+$bad+' righe complete non analizzabili, conservate nella copia.')}
        if($intents.Count){$warnings.Add($file.Name+': '+$intents.Count+' intenti senza esito registrato. Non si puo stabilire se l azione e avvenuta.')}
        $text.Add('')
    }
    if(!$items.Count){throw 'Nessun report incluso: i file superano il limite della raccolta.'}
    $text.Insert(4,'TOTALE NEI REPORT INCLUSI: '+$totalApplied+' prove sui processi applicate; '+$browserConfirmedRequests.Count+' scaricamenti schede confermati dal browser. Report: '+$items.Count+'.')
    $text.Insert(5,'COLLEGAMENTO = comunicazione. SCARICAMENTO = contenuto della scheda rilasciato. ESITO MEMORIA = variazione osservata del browser, non MB della singola scheda e non prova di prestazioni migliori.')
    foreach($warning in $warnings){$text.Add('ATTENZIONE: '+$warning)}
    $manifest=[pscustomobject]@{schema_version=1;created_utc=[DateTime]::UtcNow.ToString('o');report_count=$items.Count;applied_count=$totalApplied;browser_discard_confirmations=$browserConfirmedRequests.Count;browser_outcomes=@($browserOutcomes.ToArray());comparison_outcomes=@($comparisonOutcomes.ToArray());agent_outcomes=@($agentOutcomes.ToArray());
        bytes_included=$bytesIncluded;max_bytes=$MaxBytes;max_reports=$MaxReports;selection_scope=$(if($Report){'explicit_files'}else{'latest_ame_reports'});
        source_files_modified=$false;causation_established=$false;latency_measured=$false;warnings=@($warnings.ToArray());reports=@($items.ToArray())}
    [IO.File]::WriteAllText((Join-Path $stage 'RIEPILOGO.json'),($manifest|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText((Join-Path $stage 'LEGGIMI.txt'),($text -join "`r`n"),(New-Object Text.UTF8Encoding($true)))
    # .NET Framework may use backslashes in CreateFromDirectory entry names.
    # Keep the ZIP names identical to archive_entry on every supported runtime.
    $zipStream=[IO.File]::Open($zipPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $archive=$null
    try{
        $archive=New-Object IO.Compression.ZipArchive($zipStream,[IO.Compression.ZipArchiveMode]::Create,$true)
        $prefixLength=$stage.TrimEnd([char[]]@('\','/')).Length+1
        foreach($entryFile in Get-ChildItem -LiteralPath $stage -File -Recurse){
            $entryName=$entryFile.FullName.Substring($prefixLength).Replace('\','/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$entryFile.FullName,$entryName,[IO.Compression.CompressionLevel]::Optimal)
        }
    }finally{if($archive){$archive.Dispose()};$zipStream.Dispose()}
    Write-Host ('Diagnosi pronta: '+$zipPath)
    Write-Host ('Report inclusi: '+$items.Count+' | Prove sui processi applicate: '+$totalApplied+' | Schede scaricate confermate: '+$browserConfirmedRequests.Count)
    return [pscustomobject]@{Path=$zipPath;ReportCount=$items.Count;AppliedCount=$totalApplied;Warnings=@($warnings.ToArray())}
}finally{if([IO.Directory]::Exists($stage)){[IO.Directory]::Delete($stage,$true)}}
