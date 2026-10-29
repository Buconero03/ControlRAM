# Loaded by hub.ps1: UI operations run on its WinForms thread.
$script:browserConfig = Get-Content (Join-Path $PSScriptRoot 'browser\config.json') -Raw | ConvertFrom-Json
$script:profiles = @{}
$script:pendingBrowser = $null
$script:browserConfirmed = 0
$script:browserRequests = @{}
$script:browserClosing=@{}
$script:browserDisconnectReasons=@{}
$script:bridge = New-Object AmeHub.BrowserBridge((Join-Path $PSScriptRoot 'build\ame-browser-host.exe'))

$script:browserCooldown=@{}
. (Join-Path $PSScriptRoot 'browser-model.ps1')
$browserLayout=New-Object Windows.Forms.TableLayoutPanel;$browserLayout.Dock='Fill';$browserLayout.ColumnCount=1;$browserLayout.RowCount=6;$browserLayout.Padding=New-Object Windows.Forms.Padding(16)
foreach($height in @(110,0,126,48,90,110)){
    $row=New-Object Windows.Forms.RowStyle
    if($height -eq 0){$row.SizeType='Percent';$row.Height=100}else{$row.SizeType='Absolute';$row.Height=$height}
    [void]$browserLayout.RowStyles.Add($row)
}
$browserTab.Controls.Add($browserLayout)
$script:browserLabel=New-Object Windows.Forms.Label;$browserLabel.Dock='Fill'
$browserLabel.Text="Apri l'estensione AME in Chrome o Firefox e premi Collega. Poi scegli una scheda ricaricabile.`r`nLa scheda si scarica tramite il browser scelto; il browser resta aperto. Nessuna selezione automatica."
$browserLayout.Controls.Add($browserLabel,0,0)
$script:browserGrid=New-Object Windows.Forms.DataGridView;$browserGrid.Dock='Fill'
$browserGrid.ReadOnly=$true;$browserGrid.AllowUserToAddRows=$false;$browserGrid.AllowUserToDeleteRows=$false
$browserGrid.MultiSelect=$false;$browserGrid.RowHeadersVisible=$false;$browserGrid.SelectionMode='FullRowSelect';$browserGrid.AutoSizeColumnsMode='Fill'
[void]$browserGrid.Columns.Add('profile','Profilo collegato');[void]$browserGrid.Columns.Add('title','Scheda');[void]$browserGrid.Columns.Add('decision','Disponibilita')
$browserGrid.Columns[0].FillWeight=22;$browserGrid.Columns[1].FillWeight=48;$browserGrid.Columns[2].FillWeight=40
$browserLayout.Controls.Add($browserGrid,0,1)
$browserToolbar=New-Object Windows.Forms.FlowLayoutPanel;$browserToolbar.Dock='Fill'
$browserLayout.Controls.Add($browserToolbar,0,2)
$script:discardButton=New-Object Windows.Forms.Button;$discardButton.Text='Scarica scheda inattiva';$discardButton.Size=New-Object Drawing.Size(215,36);$discardButton.Enabled=$false;$browserToolbar.Controls.Add($discardButton)
$script:browserRefresh=New-Object Windows.Forms.Button;$browserRefresh.Text='Aggiorna schede';$browserRefresh.Size=New-Object Drawing.Size(145,36);$browserToolbar.Controls.Add($browserRefresh)
$script:browserDisconnect=New-Object Windows.Forms.Button;$browserDisconnect.Text='Scollega profilo';$browserDisconnect.Size=New-Object Drawing.Size(145,36);$browserToolbar.Controls.Add($browserDisconnect)
$script:browserHelp=New-Object Windows.Forms.Button;$browserHelp.Text='Cartella Chrome';$browserHelp.Size=New-Object Drawing.Size(170,36);$browserToolbar.Controls.Add($browserHelp)
$browserFirefoxHelp=New-Object Windows.Forms.Button;$browserFirefoxHelp.Text='Cartella Firefox';$browserFirefoxHelp.Size=New-Object Drawing.Size(170,36);$browserToolbar.Controls.Add($browserFirefoxHelp)
$browserNote=New-Object Windows.Forms.Label;$browserNote.Dock='Fill'
$browserNote.Text="Al ritorno la pagina si ricarica: puoi perdere dati non salvati. Conferma solo schede sacrificabili.`r`nLe misure riguardano tutti i processi del browser scelto nella sessione, non i MB della singola scheda."
$browserLayout.Controls.Add($browserNote,0,3)
$script:browserState=New-Object Windows.Forms.TextBox;$browserState.Dock='Fill';$browserState.Multiline=$true;$browserState.ReadOnly=$true;$browserState.ScrollBars='Vertical'
$browserState.Text='Nessun intervento avviato. Dopo lo scaricamento confermato misuro RAM e commit per 5 minuti, ogni circa 5 secondi.'
$browserLayout.Controls.Add($browserState,0,4)
$script:browserLogBox=New-Object Windows.Forms.TextBox;$browserLogBox.Dock='Fill';$browserLogBox.Multiline=$true;$browserLogBox.ReadOnly=$true;$browserLogBox.ScrollBars='Vertical'
$browserLogBox.AccessibleName='Registro collegamento browser';$browserLayout.Controls.Add($browserLogBox,0,5)
$checkConnection=New-Object Windows.Forms.Button;$checkConnection.Text='Verifica collegamento';$checkConnection.Size=New-Object Drawing.Size(180,36);$browserToolbar.Controls.Add($checkConnection)
$repairConnection=New-Object Windows.Forms.Button;$repairConnection.Text='Ripara collegamento';$repairConnection.Size=New-Object Drawing.Size(180,36);$browserToolbar.Controls.Add($repairConnection)
$exportConnection=New-Object Windows.Forms.Button;$exportConnection.Text='Esporta diagnosi';$exportConnection.Size=New-Object Drawing.Size(170,36);$browserToolbar.Controls.Add($exportConnection)
$checkConnection.Add_Click({[void](Check-BrowserRegistration)})
$repairConnection.Add_Click({
    try{
        if($script:comparison -and (Test-ComparisonBusy)){throw 'Annulla il confronto prima di riparare il collegamento.'}
        if($script:pendingBrowser){throw 'Attendi la conclusione della misura corrente prima di riparare il collegamento.'}
        foreach($connectionId in @($script:profiles.Keys)){$script:bridge.Disconnect([int]$connectionId)}
        $script:profiles.Clear();Update-BrowserGrid
        & (Join-Path $PSScriptRoot 'install-chrome.ps1')
        & (Join-Path $PSScriptRoot 'install-firefox.ps1')
        if(Check-BrowserRegistration){Set-BrowserConnectionStatus 'registration_repaired' 'Registrazioni riparate. Carica AME 0.5.0 dalle cartelle di questa installazione; poi Collega. La registrazione da sola non e una connessione.'}
    }catch{Set-BrowserConnectionStatus 'repair_failed' ('Riparazione fallita: '+$_.Exception.Message) 0 'error'}
})
$exportConnection.Add_Click({Export-BrowserDiagnosis})
[void](Check-BrowserRegistration)


function script:Get-ChromeReading {
    $m = [AmeHub.Metrics]::Chrome()
    return @{ available_bytes=$m.AvailableBytes; private_commit_bytes=$m.PrivateCommitBytes;
        private_working_set_bytes=$m.PrivateWorkingSetBytes; processes=$m.Processes; unreadable=$m.Unreadable;
        utc=[DateTime]::UtcNow.ToString('o'); scope='all_chrome_processes_in_desktop_session' }
}
function script:Get-BrowserReading([string]$Browser='Chrome') {
    if($Browser -ne 'Firefox'){return Get-ChromeReading}
    $m=[AmeHub.Metrics]::Browser('firefox')
    return @{available_bytes=$m.AvailableBytes;private_commit_bytes=$m.PrivateCommitBytes;
        private_working_set_bytes=$m.PrivateWorkingSetBytes;processes=$m.Processes;unreadable=$m.Unreadable;
        utc=[DateTime]::UtcNow.ToString('o');scope='all_firefox_processes_in_desktop_session'}
}
function script:Update-BrowserGrid {
    $key = $null
    if ($browserGrid.SelectedRows.Count) { $key = $browserGrid.SelectedRows[0].Tag.Key }
    $browserGrid.Rows.Clear()
    foreach ($connection in @($script:profiles.Keys | Sort-Object)) {
        $p = $script:profiles[$connection]
        foreach ($tab in @($p.Tabs)) {
            $cooldownKey=$connection.ToString()+':'+$p.Session+':'+$tab.id
            $cooldown=if($script:browserCooldown.ContainsKey($cooldownKey) -and $script:browserCooldown[$cooldownKey] -gt [DateTime]::UtcNow){'Ritorno rapido: nuovo scaricamento sconsigliato per 30 min'}else{''}
            $decision = if ($tab.blocked) { [string]$tab.blocked }elseif($cooldown){$cooldown}else { 'Solo su tua conferma' }
            $index = $browserGrid.Rows.Add(($p.Browser+' #' + $connection),[string]$tab.title,$decision)
            $row = $browserGrid.Rows[$index]
            $row.Tag = @{ Connection=[int]$connection; Session=$p.Session; Browser=$p.Browser; Id=[long]$tab.id; Revision=[string]$tab.revision;
                Blocked=$(if($tab.blocked){[string]$tab.blocked}else{$cooldown}); Title=[string]$tab.title; Key=($connection.ToString() + ':' + $tab.id + ':' + $tab.revision) }
        }
    }
    $browserGrid.ClearSelection()
    if ($key) { foreach ($row in $browserGrid.Rows) { if ($row.Tag.Key -eq $key) { $row.Selected=$true; break } } }
    Update-BrowserConnectionDisplay
}
function script:Poll-Browser {
    foreach($closingId in @($script:browserClosing.Keys)){
        if([DateTime]::UtcNow -ge $script:browserClosing[$closingId]){$script:bridge.Disconnect([int]$closingId);$script:browserClosing.Remove($closingId)}
    }
    foreach ($entry in $script:bridge.Drain()) {
        $id = [int]$entry.Connection
        if ($entry.Error) {
            if($script:pendingBrowser -and $script:pendingBrowser.Connection -eq $id){$script:pendingBrowser.Incomplete=$true}
            $reason=[string]$entry.Error
            if($script:browserDisconnectReasons -and $script:browserDisconnectReasons.ContainsKey($id)){$reason=$script:browserDisconnectReasons[$id]+' Connessione chiusa.';$script:browserDisconnectReasons.Remove($id)}
            $script:browserClosing.Remove($id)
            Set-BrowserConnectionStatus 'transport_closed' $reason $id 'error'
            $script:profiles.Remove($id); Update-BrowserGrid
            continue
        }
        if($script:browserClosing.ContainsKey($id)){continue}
        $e=$null
        try {
            $e = $entry.Json | ConvertFrom-Json
            if ($e.type -eq 'hello') {
                $parsed = [guid]::Empty
                if($e.protocol -ne 4){throw 'Estensione precedente o protocollo incompatibile: carica AME 0.5.0 dalla cartella di questa installazione.'}
                if(($e.extension -cne $script:browserConfig.extension_id -and $e.extension -cne $script:browserConfig.firefox_extension_id) -or ![guid]::TryParse([string]$e.session,[ref]$parsed)){throw 'Identita estensione o sessione non valida.'}
                if ($script:profiles.ContainsKey($id)) { throw 'Presentazione duplicata.' }
                $browserName=if($e.extension -ceq $script:browserConfig.firefox_extension_id){'Firefox'}else{'Chrome'}
                if($e.browser -and $e.browser -cne $browserName){throw 'Identita browser incoerente'}
                $script:profiles[$id] = @{ Browser=$browserName; Version=[string]$e.version; Session=[string]$e.session; Tabs=@(); Seen=[DateTime]::UtcNow; Ready=$false; LastSequence=0L; SnapshotAt=$null }
                $reply = @{ type='welcome'; protocol=4; session=$e.session } | ConvertTo-Json -Compress
                if (!$script:bridge.Send($id,$reply)) { throw 'Connessione non disponibile.' }
                $origin=if($e.connectionReason -eq 'background'){'riconnessione in background'}else{'richiesta Collega ricevuta'}
                $extensionVersion=if([string]$e.version -match '^\d+\.\d+\.\d+$'){[string]$e.version}else{'non dichiarata'}
                Set-BrowserConnectionStatus 'awaiting_inventory' ($browserName+' #'+$id+': '+$origin+' (estensione '+$extensionVersion+'). Attendo l elenco schede.') $id
                Update-BrowserGrid
                continue
            }
            $profile = $script:profiles[$id]
            if (!$profile -or $e.session -ne $profile.Session) { throw 'Sessione browser non riconosciuta.' }
            if ($e.type -eq 'snapshot') {
                if($e.protocol -ne 4 -or $null -eq $e.sequence -or [double]$e.sequence -ne [long]$e.sequence -or [long]$e.sequence -le $profile.LastSequence){throw 'Sequenza elenco schede non valida.'}
                $tabs=@($e.tabs)
                if($null -eq $e.tabs -or $tabs.Count -gt 300){throw 'Elenco schede mancante o oltre il limite.'}
                $seenIds=@{}
                foreach($tab in $tabs){
                    $revision=[guid]::Empty
                    if($null -eq $tab.id -or $tab.id -lt 0 -or [double]$tab.id -ne [long]$tab.id -or
                       ![guid]::TryParse([string]$tab.revision,[ref]$revision) -or ([string]$tab.title).Length -gt 160 -or
                       ([string]$tab.blocked).Length -gt 240 -or $tab.discarded -isnot [bool] -or $seenIds.ContainsKey([long]$tab.id)){throw 'Scheda non valida o duplicata nell elenco.'}
                    $seenIds[[long]$tab.id]=$true
                }
                $wasReady=$profile.Ready
                $profile.Tabs=$tabs;$profile.LastSequence=[long]$e.sequence
                # Rendering must succeed before the extension is told the list is usable.
                Update-BrowserGrid
                $ack=@{type='inventory_ack';protocol=4;session=$profile.Session;sequence=$profile.LastSequence;count=$tabs.Count}|ConvertTo-Json -Compress
                if(!$script:bridge.Send($id,$ack)){throw 'Conferma elenco non inviata: collegamento chiuso.'}
                $profile.Ready=$true;$profile.Seen=[DateTime]::UtcNow;$profile.SnapshotAt=$profile.Seen
                if(!$wasReady){Set-BrowserConnectionStatus 'inventory_ready' ($profile.Browser+' #'+$id+': collegamento pronto. Ricevute '+$tabs.Count+' schede.') $id}
                else{Update-BrowserConnectionDisplay}
                Write-BrowserEvent @{type='browser_inventory';browser=$profile.Browser;connection=$id;snapshot_sequence=$profile.LastSequence;tab_count=$tabs.Count;truncated=[bool]$e.truncated;rendered=$true;ack_queued=$true}
                $pending=$script:pendingBrowser
                if($pending -and $pending.Ack -and $pending.Connection -eq $id){
                    $tabState=@($e.tabs|Where-Object {$_.id -eq $pending.Tab})
                    if($tabState.Count -eq 1 -and $tabState[0].discarded -eq $false){$pending.Returned=$true}
                }
                if ($e.truncated) { $browserLabel.Text += ' | Mostrate solo le prime 300 schede' }
            } elseif ($e.type -eq 'result') {
                if(!$profile.Ready){throw 'Risultato ricevuto prima della conferma dell elenco.'}
                if($script:comparison -and $script:comparison.Requests.ContainsKey([string]$e.request)){
                    try{[void](Receive-ComparisonResult $id $e)}catch{Stop-Comparison $_.Exception.Message}
                    continue
                }
                $pending = $script:pendingBrowser
                if (!$pending -or $pending.Connection -ne $id -or $pending.Request -ne $e.request -or $pending.Tab -ne $e.tab -or $pending.Ack) { continue }
                $pending.Ack = $true; $pending.Outcome = [string]$e.outcome; $pending.AckAt = [DateTime]::UtcNow
                Write-BrowserEvent @{type='browser_result';browser=$pending.Browser;request=$pending.Request;tab=$pending.Tab;connection=$id;outcome=$e.outcome;reason=$e.reason;operation_ms=$e.operation_ms}
                if ($e.outcome -eq 'discarded') {
                    $script:browserConfirmed++
                    $script:browserRequests[$pending.Request] = @{Connection=$id;Tab=$pending.Tab}
                    $browserState.Text=$pending.Browser+': scaricamento confermato dal browser selezionato. Verifico la durata per 5 minuti; il ritorno della scheda interrompe la valutazione.'
                    Add-HubLog ('Scheda ' + $pending.Tab + ': scaricamento confermato. Osservo il browser selezionato per 5 minuti.')
                    Update-BrowserGrid
                } else { $browserState.Text='Scheda non scaricata: '+$e.reason;Add-HubLog $browserState.Text;$script:pendingBrowser=$null }
            } elseif ($e.type -eq 'tab-return') {
                $known = $script:browserRequests[[string]$e.request]
                if ($known -and $known.Connection -eq $id -and $known.Tab -eq $e.tab) {
                    if($script:pendingBrowser -and $script:pendingBrowser.Request -eq $e.request){$script:pendingBrowser.Returned=$true}
                    Write-BrowserEvent @{type='browser_return';request=$e.request;tab=$e.tab;load_observed_ms=$e.load_observed_ms;application_ready_measured=$false;memory=(Get-BrowserReading $profile.Browser)}
                    if($script:comparison){Record-ComparisonReturn ([string]$e.request) $e.load_observed_ms}
                    Add-HubLog ('Scheda ' + $e.tab + ': caricamento completato osservato in ' + $e.load_observed_ms + ' ms; non misura la prontezza della app web.')
                    $script:browserRequests.Remove([string]$e.request)
                }
            } else { throw 'Evento browser non supportato.' }
        } catch {
            $failure=$_
            if($null -eq $script:browserDisconnectReasons){$script:browserDisconnectReasons=@{}}
            $script:browserDisconnectReasons[$id]=$failure.Exception.Message
            if($script:pendingBrowser -and $script:pendingBrowser.Connection -eq $id){$script:pendingBrowser.Incomplete=$true}
            Set-BrowserConnectionStatus 'message_rejected' ('Browser #'+$id+': '+$failure.Exception.Message) $id 'error'
            Write-BrowserEvent @{type='browser_error';connection=$id;event_type=[string]$e.type;message=$failure.Exception.Message;position=$failure.InvocationInfo.PositionMessage;stack=$failure.ScriptStackTrace}
            if($e.session){[void]$script:bridge.Send($id,(@{type='connection_error';session=[string]$e.session;code='message_rejected';reason=$failure.Exception.Message}|ConvertTo-Json -Compress))}
            $script:profiles.Remove($id);$script:browserClosing[$id]=[DateTime]::UtcNow.AddSeconds(2)
            try{Update-BrowserGrid}catch{Set-BrowserConnectionStatus 'render_failed' $_.Exception.Message $id 'error'}
        }
    }
    foreach($id in @($script:profiles.Keys)){
        $profile=$script:profiles[$id]
        $limit=if($profile.Ready){30}else{15}
        if(([DateTime]::UtcNow-$profile.Seen).TotalSeconds -ge $limit){
            $code=if($profile.Ready){'inventory_stale'}else{'inventory_missing'}
            $message=if($profile.Ready){'Aggiornamenti schede assenti da 30 secondi. Ricollega il profilo.'}else{'Elenco schede non ricevuto entro 15 secondi. Ricarica l estensione e ricollega.'}
            if($null -eq $script:browserDisconnectReasons){$script:browserDisconnectReasons=@{}}
            $script:browserDisconnectReasons[$id]=$message
            Set-BrowserConnectionStatus $code ('Browser #'+$id+': '+$message) $id 'error'
            [void]$script:bridge.Send([int]$id,(@{type='connection_error';session=$profile.Session;code=$code;reason=$message}|ConvertTo-Json -Compress))
            $script:browserClosing[$id]=[DateTime]::UtcNow.AddSeconds(2);$script:profiles.Remove($id)
            if($script:pendingBrowser -and $script:pendingBrowser.Connection -eq $id){$script:pendingBrowser.Incomplete=$true}
            Update-BrowserGrid
        }
    }
    $p = $script:pendingBrowser
    if ($p) {
        if (!$p.Ack -and ([DateTime]::UtcNow-$p.Sent).TotalSeconds -gt 20) {
            Write-BrowserEvent @{type='browser_unknown';request=$p.Request;tab=$p.Tab;reason='ack_timeout';retry_performed=$false}
            $browserState.Text='Conferma non ricevuta: esito sconosciuto. Nessun nuovo tentativo automatico.';Add-HubLog $browserState.Text
            $script:pendingBrowser=$null
        } elseif ($p.Ack) {
            $elapsed = ([DateTime]::UtcNow-$p.AckAt).TotalSeconds
            if(!$p.LastSample -or ([DateTime]::UtcNow-$p.LastSample).TotalSeconds -ge 5 -or $p.Returned -or $p.Incomplete){
                try{$after=Get-BrowserReading $p.Browser}catch{
                    $browserState.Text='Misura interrotta: lettura memoria del browser non disponibile. Nessun beneficio confermato.'
                    Add-HubLog $browserState.Text;$script:pendingBrowser=$null;$discardButton.Enabled=$false;return
                }
                $assessment=Get-BrowserObservation $p $after
                $browserState.Text=$assessment.Status
                Write-BrowserEvent @{type='browser_feedback';browser=$p.Browser;request=$p.Request;seconds_after_ack=$assessment.Seconds;before=$p.Before;after=$after;
                    private_working_set_delta_bytes=$(if($null -eq $assessment.Drop){$null}else{-$assessment.Drop});private_commit_delta_bytes=$(if($null -eq $assessment.CommitDrop){$null}else{-$assessment.CommitDrop});
                    outcome=$assessment.Outcome;measurement_complete=(!$p.Incomplete);causation_established=$false;per_tab_memory_measured=$false;latency_measured=$false}
                if($assessment.Finished){
                    Write-BrowserEvent @{type='browser_assessed';browser=$p.Browser;request=$p.Request;outcome=$assessment.Outcome;seconds_after_ack=$assessment.Seconds;status=$assessment.Status;causation_established=$false;per_tab_memory_measured=$false}
                    if($p.Returned -and $assessment.Seconds -lt 300){
                        $cooldownKey=$p.Connection.ToString()+':'+$p.Session+':'+$p.Tab
                        $script:browserCooldown[$cooldownKey]=[DateTime]::UtcNow.AddMinutes(30)
                    }
                    Add-HubLog $assessment.Status;$script:pendingBrowser=$null;Update-BrowserGrid
                }
            }
        }
    }
    $discardButton.Enabled = $false
    if($script:comparison -and (Test-ComparisonBusy)){return}
    if (!$script:pendingBrowser -and !$script:batchActive -and $script:mode -notin @('recover','recover-test') -and $browserGrid.SelectedRows.Count) {
        $choice=$browserGrid.SelectedRows[0].Tag; $profile=$script:profiles[$choice.Connection]
        $discardButton.Enabled = !$choice.Blocked -and $profile -and $profile.Ready -and (([DateTime]::UtcNow-$profile.Seen).TotalSeconds -lt 25)
    }
}
$discardButton.Add_Click({
    try {
        if($script:comparison -and (Test-ComparisonBusy)){throw 'Confronto beneficio in corso: usa Scarica e misura nella sezione Verifica beneficio, oppure annulla il confronto.'}
        if ($script:pendingBrowser -or $script:batchActive -or $script:pendingRecoveryMode -or $script:restartMode -or $script:mode -in @('recover','recover-test') -or !$browserGrid.SelectedRows.Count) { return }
        $choice=$browserGrid.SelectedRows[0].Tag
        if ($choice.Blocked) { return }
        if($script:browserLogFailure){throw 'Registro diagnostico non disponibile. Esporta la diagnosi prima di avviare un intervento.'}
        $cooldownKey=$choice.Connection.ToString()+':'+$choice.Session+':'+$choice.Id
        if($script:browserCooldown.ContainsKey($cooldownKey) -and $script:browserCooldown[$cooldownKey] -gt [DateTime]::UtcNow){throw 'Scheda gia tornata in uso: nuovo scaricamento sconsigliato per 30 minuti.'}
        $answer=[Windows.Forms.MessageBox]::Show(('Scaricare dalla memoria questa scheda?' + "`r`n`r`n" + $choice.Title + "`r`n`r`n" + 'Quando torni, la pagina si ricarica. Puoi perdere dati non salvati o operazioni in corso. Conferma solo se la pagina e sacrificabile.'),'Conferma per questa scheda',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning,[Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
        $profile=$script:profiles[$choice.Connection]
        if (!$profile -or !$profile.Ready -or ([DateTime]::UtcNow-$profile.Seen).TotalSeconds -ge 25 -or $profile.Session -ne $choice.Session -or $script:pendingBrowser) { throw 'Il collegamento e cambiato: aggiorna le schede.' }
        $request=[guid]::NewGuid().ToString('D')
        $before=Get-BrowserReading $profile.Browser
        $command=@{type='discard';session=$choice.Session;request=$request;tab=$choice.Id;revision=$choice.Revision;confirmed=$true;deadline=[DateTimeOffset]::UtcNow.AddSeconds(8).ToUnixTimeMilliseconds()}
        Write-BrowserEvent @{type='browser_request';browser=$profile.Browser;request=$request;tab=$choice.Id;connection=$choice.Connection;manual_confirmation=$true;before=$before}
        if($script:browserLogFailure){throw 'Richiesta non inviata: impossibile registrare la diagnosi.'}
        $script:pendingBrowser=@{Connection=$choice.Connection;Browser=$profile.Browser;Request=$request;Tab=$choice.Id;Session=$choice.Session;Before=$before;Sent=[DateTime]::UtcNow;Ack=$false;Returned=$false;Incomplete=$false;LastSample=$null;Samples=@();BestDrop=0}
        if (!$script:bridge.Send($choice.Connection,($command | ConvertTo-Json -Compress))) { $script:pendingBrowser=$null; throw 'Richiesta non inviata: collegamento chiuso.' }
        $discardButton.Enabled=$false
        $browserState.Text=$choice.Browser+': richiesta inviata. Attendo la conferma di scaricamento dal browser selezionato: nessun esito ancora confermato.'
        Add-HubLog ('Richiesta manuale inviata per la scheda ' + $choice.Id + '.')
    } catch {$browserState.Text='Richiesta non completata: '+$_.Exception.Message;Add-HubLog $browserState.Text}
})
$browserRefresh.Add_Click({
    if(!$script:profiles.Count){Set-BrowserConnectionStatus 'no_profile' 'Nessun profilo collegato. Apri l estensione AME in Chrome o Firefox e premi Collega.';return}
    foreach($id in @($script:profiles.Keys)){
        if($script:bridge.Send([int]$id,(@{type='refresh';session=$script:profiles[$id].Session}|ConvertTo-Json -Compress))){Set-BrowserConnectionStatus 'refresh_requested' ($script:profiles[$id].Browser+' #'+$id+': aggiornamento richiesto.') $id}
        else{Set-BrowserConnectionStatus 'refresh_failed' ($script:profiles[$id].Browser+' #'+$id+': richiesta non inviata. Ricollega il profilo.') $id 'error'}
    }
})
$browserDisconnect.Add_Click({
    $ids=if($browserGrid.SelectedRows.Count){@($browserGrid.SelectedRows[0].Tag.Connection)}else{@($script:profiles.Keys)}
    foreach($id in $ids){
        $session=$script:profiles[$id].Session
        [void]$script:bridge.Send([int]$id,(@{type='stop_connection';protocol=4;session=$session}|ConvertTo-Json -Compress))
        if($script:pendingBrowser -and $script:pendingBrowser.Connection -eq $id){$script:pendingBrowser.Incomplete=$true}
        $script:browserClosing[$id]=[DateTime]::UtcNow.AddSeconds(2)
        $script:browserDisconnectReasons[$id]='Scollegamento richiesto dal pannello.'
        $script:profiles.Remove($id)
    }
    Set-BrowserConnectionStatus 'manual_disconnect' 'Scollegamento richiesto, con arresto del background nell estensione 0.5.0. Le schede restano aperte.';Update-BrowserGrid
})
$browserHelp.Add_Click({
    $path=Join-Path $PSScriptRoot 'browser\chrome'
    [Windows.Forms.Clipboard]::SetText($path)
    Start-Process explorer.exe -ArgumentList ('"'+$path+'"')
    [void][Windows.Forms.MessageBox]::Show("Percorso copiato negli appunti: $path`r`n`r`nIn chrome://extensions rimuovi la vecchia AME, poi Modalita sviluppatore > Carica estensione non pacchettizzata. Incolla questo percorso.`r`nVerifica AME 0.5.0 prima di premere Collega. Ricaricare una vecchia cartella non la aggiorna.",'Installa la versione corretta di AME')
})
$browserFirefoxHelp.Add_Click({
    $path=Join-Path $PSScriptRoot 'browser\firefox\manifest.json'
    [Windows.Forms.Clipboard]::SetText($path)
    Start-Process explorer.exe -ArgumentList ('/select,"'+$path+'"')
    [void][Windows.Forms.MessageBox]::Show("Percorso copiato negli appunti: $path`r`n`r`nIn Firefox: about:debugging#/runtime/this-firefox > Carica componente aggiuntivo temporaneo. Scegli questo manifest.json, poi apri AME e premi Collega.`r`nQuesta installazione di prova termina al riavvio di Firefox.",'AME per Firefox - prova locale')
})
