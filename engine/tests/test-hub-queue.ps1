$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'windows-model.ps1')
if(!('AmeHub.ReportTail' -as [type])){Add-Type -Path (Join-Path $root 'src\hub-runtime.cs')}
function Assert($ok,[string]$message){if(!$ok){throw $message}}
function Assert-ResourceApiTargets([object[]]$Targets) {}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'hub.ps1'),[ref]$tokens,[ref]$errors)
foreach($progressFunction in @('Refresh-RecoveryProgress','Set-RecoveryTargetText','Show-RecoveryUpdate','Stop-RecoveryQueue')){
    $progressAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $progressFunction},$true)
    . ([scriptblock]::Create($progressAst.Extent.Text))
}
$script:queueStatus=[pscustomobject]@{Text=''};$script:progressTargets=@();$script:liveMeasurements=@{}

Assert (!$errors.Count) 'Parsing hub fallito'
foreach($name in @('Begin-Recovery','Request-Stop','Set-Paused','Show-TargetState','Read-WindowsEvents','Start-NextRecovery','Stop-RecoveryQueue','Finish-RecoveryProcess')){
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Assert ($null -ne $fn) ('Funzione mancante: '+$name)
    $definition=[Management.Automation.Language.Parser]::ParseInput($fn.Extent.Text,(Join-Path $root 'hub.ps1'),[ref]$tokens,[ref]$errors)
    . $definition.GetScriptBlock()
}
$tick=$ast.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith('$timer.Add_Tick(')},$true)
$callback=$tick.Arguments[0].ScriptBlock.GetScriptBlock()
$stop=$ast.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith('$stopButton.Add_Click(')},$true)
$stopCallback=$stop.Arguments[0].ScriptBlock.GetScriptBlock()
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ame-queue-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
function Add-Log([string]$message){$script:messages.Add($message)}
function Write-PanelEvent {}
function Complete-PendingRecovery {}
function Save-Selection {}
function Show-Snapshot($sample) {}
function Export-Diagnosis([string[]]$report){$script:exports.Add($report);return $null}
function New-FakeEngine {
    $p=[pscustomobject]@{HasExited=$false;ExitCode=0;StandardError=[pscustomobject]@{}}
    $p.StandardError|Add-Member ScriptMethod ReadToEnd {return ''}
    $p|Add-Member ScriptMethod Dispose {}
    return $p
}
function Start-Engine([string]$mode){
    Assert ($mode -eq 'recover-test') 'La coda ha avviato un osservatore o un recupero automatico'
    Assert ($script:runSelection.Count -eq 1) 'Il motore singolo ha ricevuto piu identita'
    $script:starts.Add($script:runSelection[0])
    $script:engine=New-FakeEngine;$script:mode=$mode;$script:trimmed=0;$script:userStopping=$false
    $script:reportPath=Join-Path $temp ('run-'+[guid]::NewGuid().ToString('N')+'.jsonl')
    $script:stopFile=$script:reportPath+'.stop';$script:ends=[DateTime]::UtcNow.AddSeconds(180)
    [IO.File]::WriteAllText($script:reportPath,'')
}
function Reset-Fixture([int]$count=3){
    if($script:tail){$script:tail.Dispose()};$script:tail=$null
    $script:starts=New-Object 'Collections.Generic.List[object]';$script:exports=New-Object 'Collections.Generic.List[object]'
    $script:messages=New-Object 'Collections.Generic.List[string]'
    $script:selection=@{};$script:targetStates=@{};$script:batchActive=$false;$script:batchQueue=@()
    $script:restartMode=$null;$script:mode='observe';$script:userStopping=$false;$script:trimmed=0
    $script:currentOutcome='';$script:currentFeedback='';$script:currentWait=''
    $script:lastComplete=[DateTime]::UtcNow;$script:engine=New-FakeEngine
    $script:reportPath=Join-Path $temp 'observe.jsonl';$script:stopFile=Join-Path $temp 'observe.stop'
    [IO.File]::WriteAllText($script:reportPath,'')
    $script:ends=[DateTime]::UtcNow.AddMinutes(10)
    $rows=@()
    foreach($i in 1..$count){
        $row=[pscustomobject]@{Key=([string]($i+100)+':'+$i);Pid=($i+100);Name=('app'+$i+'.exe');Path=('D:\Apps\app'+$i+'.exe');PrivateBytes=((7-$i)*128MB);Blocked=''}
        $script:selection[$row.Key]=$row
        $cells=@{};foreach($key in @('choose','state','idle','cpu','faults')){$cells[$key]=[pscustomobject]@{Value=$null;ReadOnly=$false;ToolTipText=''}}
        $rows+=[pscustomobject]@{Tag=$row;Cells=$cells}
    }
    $script:grid=[pscustomobject]@{Rows=$rows}
    foreach($button in @('start','single','stopButton','clear','duration')){Set-Variable -Scope Script -Name $button -Value ([pscustomobject]@{Enabled=$true})}
    $script:pause=[pscustomobject]@{Enabled=$true;Text=''}
    $script:state=[pscustomobject]@{Text=''};$script:result=[pscustomobject]@{Text=''};$script:ram=[pscustomobject]@{Text='Interventi: 0'}
}
function Complete-Current($events,[int]$code=0){
    $lines=@($events|ForEach-Object {$_|ConvertTo-Json -Compress -Depth 6})
    [IO.File]::WriteAllText($script:reportPath,($lines -join "`n")+"`n")
    $script:engine.HasExited=$true;$script:engine.ExitCode=$code
    & $callback
}
function Begin-Queue {
    Begin-Recovery 'recover-test'
    Assert ($script:batchActive -and $script:restartMode -eq 'recover-test') 'Coda non preparata'
    $script:engine.HasExited=$true
    & $callback
    Assert ($script:starts.Count -eq 1 -and $script:runSelection[0].Key -eq '101:1') 'Il primo processo non e quello con piu RAM'
}
try{
    Reset-Fixture 6
    Begin-Recovery 'recover-test'
    Assert (!$script:batchActive -and !$script:restartMode -and !$script:starts.Count) 'Limite oltre cinque aggirato'
    Reset-Fixture 3
    $script:lastComplete=[DateTime]::UtcNow.AddSeconds(-21)
    Begin-Recovery 'recover-test'
    Assert (!$script:batchActive -and !$script:starts.Count) 'Avvio su inventario vecchio'
    Reset-Fixture 3
    Begin-Queue
    Begin-Recovery 'recover-test'
    Assert ($script:starts.Count -eq 1 -and !$script:restartMode) 'Doppio avvio consentito'
    # A timeout may move to the next explicit identity; the former PID is never retried.
    Complete-Current @(@{type='recover_target';pid=101;creation_filetime='1';reason='foreground_family';single_test=$true},@{type='recover_no_action';pid=101;reason='stopped_or_timed_out_before_eligibility'})
    Assert ($script:starts.Count -eq 2 -and $script:runSelection[0].Key -eq '102:2') 'Timeout non passa al secondo processo'
    Assert ($script:targetStates['101:1'] -like '*Nessun intervento*primo piano*') 'Motivo del mancato intervento perso'
    # Changed display data cannot replace the identity authorized for a queued process.
    $grid.Rows[2].Tag=[pscustomobject]@{Key='103:999';Blocked='';Name='other.exe';Path='D:\Other\other.exe'}
    Complete-Current @(@{type='recover_state';completed=1;single_test=$true;feedback_pending=$false;reasons=@{}},@{type='recover_feedback';phase='300s';pid=102;private_resident_delta_bytes=-32MB;system_available_delta_bytes=20MB},@{type='recover_assessed';pid=102;reason='resident_reduction_retained_5m'})
    Assert ($script:starts.Count -eq 3 -and $script:runSelection[0].Key -eq '103:3' -and $script:runSelection[0].Path -eq 'D:\Apps\app3.exe') 'La coda ha seguito il riuso del PID o un percorso differente'
    Assert ($script:targetStates['102:2'] -like '*-32*RAM ridotta a 5 minuti*') 'Delta o esito del secondo processo persi'
    Complete-Current @(@{type='recover_no_action';pid=103;reason='stopped_or_timed_out_before_eligibility'})
    Assert (!$script:batchActive -and $script:mode -eq 'paused' -and $script:starts.Count -eq 3 -and $script:exports.Count -eq 1 -and $script:exports[0].Count -eq 3) 'Fine coda non ferma/esporta tutte le sessioni insieme'
    Assert ($result.Text -like '*3/3*Interventi applicati: 1*RAM ridotta a 5 minuti: 1*Misure incomplete: 0*') 'Totale coda non corretto'
    Assert ($pause.Enabled -and $single.Enabled -and !$script:lastComplete) 'Fine coda non richiede un nuovo inventario'
    Reset-Fixture 2
    Begin-Queue
    Complete-Current @(@{type='recover_state';completed=1;single_test=$true;reasons=@{}},@{type='recover_guard';pid=101;reason='activity_or_fault_increase_stop_further_actions'})
    Assert ($script:starts.Count -eq 1 -and $script:mode -eq 'paused' -and !$script:batchQueue.Count) 'Una guardia ha lasciato avviare un altro processo'
    Assert ($script:targetStates['102:2'] -like 'Annullato:*') 'Processo annullato mostrato come gestito'
    Reset-Fixture 2
    Begin-Queue
    & $stopCallback
    Assert ((Test-Path $script:stopFile) -and !$script:batchQueue.Count) 'Ferma e pausa non richiede stop e annulla coda'
    Complete-Current @(@{type='recover_no_action';pid=101;reason='stopped_or_timed_out_before_eligibility'})
    Assert ($script:starts.Count -eq 1 -and $script:mode -eq 'paused') 'Stop manuale ha avviato un altro processo'
    Reset-Fixture 2
    Begin-Queue
    Complete-Current @(@{type='end'}) 1
    Assert ($script:starts.Count -eq 1 -and !$script:batchActive -and $script:mode -eq 'paused') 'Errore motore non interrompe coda'
    Reset-Fixture 2
    Begin-Queue
    Complete-Current @(@{type='recover_assessed';pid=101;reason='no_sustained_observed_benefit'})
    Assert ($script:starts.Count -eq 1 -and $script:mode -eq 'paused') 'Assenza di beneficio persistente non ferma coda'
    # The activity warning stops mutations and the remaining queue, but keeps the engine for measurements.
    Reset-Fixture 2
    Begin-Queue
    $warning=@(@{type='recover_activity_warning';pid=101;reason='activity_or_fault_increase_stop_further_actions'},@{type='recover_state';completed=1;single_test=$true;feedback_pending=$true;disabled=$true;activity_warning=$true;disabled_reason='activity_or_fault_increase_stop_further_actions';feedback_seconds_remaining=58;reasons=@{}})
    [IO.File]::WriteAllText($script:reportPath,((@($warning|ForEach-Object {$_|ConvertTo-Json -Compress}) -join "`n")+"`n"))
    Read-WindowsEvents
    Assert ($script:cancelQueue -and !$script:engine.HasExited -and $script:mode -eq 'recover-test' -and $state.Text -like '*Continuo solo la misura*58 secondi*') 'Avviso di attivita interrompe la misura oppure non blocca la coda'
    $final=@(@{type='recover_feedback';pid=101;phase='300s';private_resident_delta_bytes=-304MB;system_available_delta_bytes=20MB;retained_percent=99;remaining_private_resident_reduction_bytes=304MB;activity_warning=$true},@{type='recover_assessed';pid=101;reason='resident_reduction_retained_5m_with_activity'})
    [IO.File]::AppendAllText($script:reportPath,((@($final|ForEach-Object {$_|ConvertTo-Json -Compress}) -join "`n")+"`n"))
    $script:engine.HasExited=$true
    & $callback
    Assert ($script:starts.Count -eq 1 -and $script:mode -eq 'paused' -and $script:targetStates['101:1'] -like '*RAM ridotta a 5 minuti*prestazioni non dimostrato*') 'Riduzione dopo avviso diventa successo prestazionale o avvia un altro processo'
    Reset-Fixture 2
    Begin-Queue
    $resumed=@(@{type='recover_usage_warning';pid=101;reason='foreground_return_observation_only'},@{type='recover_state';completed=1;single_test=$true;feedback_pending=$true;disabled=$true;usage_resumed=$true;disabled_reason='foreground_return_observation_only';feedback_seconds_remaining=120;reasons=@{}})
    [IO.File]::WriteAllText($script:reportPath,((@($resumed|ForEach-Object {$_|ConvertTo-Json -Compress}) -join "`n")+"`n"))
    Read-WindowsEvents
    Assert ($script:cancelQueue -and !$script:engine.HasExited -and !(Test-Path $script:stopFile) -and $state.Text -like '*primo piano*120 secondi*') 'Ritorno in primo piano ferma la misura o consente altre azioni'
    $assessment=@{type='recover_assessed';pid=101;reason='resident_reduction_retained_5m_after_resume';remaining_private_resident_reduction_bytes=80MB;minimum_private_resident_reduction_last_60s_bytes=64MB}
    [IO.File]::AppendAllText($script:reportPath,($assessment|ConvertTo-Json -Compress)+"`n")
    $script:engine.HasExited=$true
    & $callback
    Assert ($script:starts.Count -eq 1 -and $script:mode -eq 'paused' -and $result.Text -like '*RAM ridotta a 5 minuti: 1*Misure incomplete: 0*') 'Risultato dopo uso normale non conteggiato correttamente o avvia altra app'
    Assert ($script:targetStates['101:1'] -like '*minimo*64*Reattivita non misurata*') 'Risultato non mostra il minimo osservato o promette reattivita'
    Reset-Fixture 1
    Begin-Queue
    Complete-Current @(@{type='recover_state';completed=1;single_test=$true;reasons=@{}},@{type='recover_incomplete';pid=101;reason='stopped_before_full_feedback_no_rollback'})
    Assert ($result.Text -like '*RAM ridotta a 5 minuti: 0*Misure incomplete: 1*') 'Prova interrotta conteggiata come riduzione mantenuta'
    Reset-Fixture 1
    Begin-Queue
    Complete-Current @(@{type='recover_state';completed=1;single_test=$true;reasons=@{}},@{type='recover_assessed';pid=101;reason='resident_reduction_not_retained_5m'})
    Assert ($result.Text -like '*RAM ridotta a 5 minuti: 0*Misure incomplete: 0*' -and $script:targetStates['101:1'] -like '*non mantenuta stabilmente*') 'Esito negativo diventa successo o misura incompleta'
    Reset-Fixture 5
    Begin-Queue
    foreach($pidValue in 101..105){
        Assert ($script:runSelection[0].Pid -eq $pidValue) 'Coda da cinque segue ordine RAM o identita errati'
        Complete-Current @(@{type='recover_no_action';pid=$pidValue;reason='stopped_or_timed_out_before_eligibility'})
    }
    Assert ($script:starts.Count -eq 5 -and $script:runSelection.Count -eq 1 -and $script:mode -eq 'paused' -and !$script:batchActive) 'Cinque selezioni non producono esattamente cinque richieste seriali'
    Assert ($script:exports.Count -eq 1 -and $script:exports[0].Count -eq 5 -and $result.Text -like '*5/5*Interventi applicati: 0*') 'Coda da cinque perde report o conteggio finale'
    # Stream one event at a time through the real reader, as the user's screenshot
    # showed a queued process even after a warning had cancelled future actions.
    Reset-Fixture 3
    Begin-Queue
    function Feed-Progress($entry){[IO.File]::AppendAllText($script:reportPath,($entry|ConvertTo-Json -Compress)+"`n");Read-WindowsEvents}
    Feed-Progress @{type='recover_target';pid=101;creation_filetime='1';reason='low_activity_under_60_seconds';single_test=$true;elapsed_seconds=22;low_activity_seconds=22;private_resident_bytes=320MB;cpu_percent=0;page_faults_per_second=0}
    Assert ($result.Text -like '*app1.exe*PID 101*NESSUN INTERVENTO ANCORA*22/60*158 s*') 'Attesa non identifica il processo o lascia intendere un recupero eseguito'
    Assert ($queueStatus.Text -like '*app2.exe*NON ANCORA AVVIATO*PID 101*') 'Coda senza nome del processo corrente'
    Feed-Progress @{type='recover_applied';pid=101;elapsed_seconds=60}
    Assert ($result.Text -like '*INTERVENTO ESEGUITO*') 'Azione applicata non notificata immediatamente'
    Feed-Progress @{type='recover_feedback';pid=101;creation_filetime='1';elapsed_seconds=60;seconds_after_action=0;phase='immediate';private_resident_before_bytes=320MB;private_resident_after_bytes=1MB;private_resident_delta_bytes=-319MB}
    Assert ($result.Text -like '*RAM DIMINUITA*319*Prima 320*ora 1*Verifica della durata in corso*') 'Manca il risultato immediato prima/dopo o viene dichiarato definitivo'
    Feed-Progress @{type='recover_target';pid=101;creation_filetime='1';reason='feedback_pending';elapsed_seconds=62;private_resident_bytes=10MB;cpu_percent=0;low_activity_seconds=0}
    Assert ($result.Text -like '*310*ora 10*2 s*') 'RAM live non aggiornata dal campione intermedio'
    Feed-Progress @{type='recover_activity_warning';pid=101;elapsed_seconds=62}
    Assert ($script:batchQueue.Count -eq 0 -and $script:engine.HasExited -eq $false -and $queueStatus.Text -like '*app2.exe*Annullato:*Nessun intervento eseguito*' -and $queueStatus.Text -notlike '*NON ANCORA AVVIATO*') 'Avviso lascia falsa attesa o ferma la misura corrente'
    Feed-Progress @{type='recover_target';pid=101;creation_filetime='1';reason='feedback_pending';elapsed_seconds=64;private_resident_bytes=340MB;cpu_percent=0;low_activity_seconds=0}
    Assert ($result.Text -like '*RAM RISALITA*20*in piu*') 'Ricrescita live presentata come riduzione'
    Feed-Progress @{type='recover_target';pid=101;creation_filetime='1';reason='feedback_pending';elapsed_seconds=66;private_resident_bytes=$null;cpu_percent=0;low_activity_seconds=0}
    Assert ($result.Text -like '*Misura RAM attuale non disponibile*') 'Dato mancante trasformato in RAM zero'
    Feed-Progress @{type='recover_target';pid=101;creation_filetime='999';reason='feedback_pending';elapsed_seconds=68;private_resident_bytes=0}
    Assert ($result.Text -like '*Misura RAM attuale non disponibile*') 'PID riutilizzato altera misura dell identita originale'
    Feed-Progress @{type='recover_feedback';pid=101;creation_filetime='1';elapsed_seconds=70;seconds_after_action=10;phase='15s';private_resident_before_bytes=320MB;private_resident_after_bytes=24MB;private_resident_delta_bytes=-296MB}
    Feed-Progress @{type='recover_incomplete';pid=101;elapsed_seconds=72;reason='stopped_before_full_feedback_no_rollback'}
    Assert ($result.Text -like '*Misura incompleta*296*ultima misura*' -and $result.Text -notlike '*Verifica della durata in corso*') 'Stop perde la riduzione gia misurata o continua a dichiarare osservazione'
    $finishedText=$script:targetStates['101:1']
    Feed-Progress @{type='recover_target';pid=101;creation_filetime='1';reason='session_limit_or_already_attempted';elapsed_seconds=74;private_resident_bytes=300MB}
    Assert ($script:targetStates['101:1'] -eq $finishedText) 'Campione successivo cancella il risultato finale'
    Write-Host 'PASS actual recovery queue: 1-5 identities, ordered serial launch, no retry, exact identity/path, signed outcomes, export, cancellation, guard/failure stop and pause'
}finally{
    if($script:tail){$script:tail.Dispose()};if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}
}
