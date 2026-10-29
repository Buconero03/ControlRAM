param()
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSEdition -eq 'Core') { & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath; return }
if ([IntPtr]::Size -ne 8) { throw 'Usa PowerShell a 64 bit.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Avvia powershell.exe -STA -File .\hub.ps1' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'src\hub-runtime.cs')
. (Join-Path $PSScriptRoot 'browser-connection.ps1')
Initialize-BrowserDiagnostics
. (Join-Path $PSScriptRoot 'windows-model.ps1')
. (Join-Path $PSScriptRoot 'resource-api-bridge.ps1')
. (Join-Path $PSScriptRoot 'process-reduction-api.ps1')
. (Join-Path $PSScriptRoot 'strategy-model.ps1')
. (Join-Path $PSScriptRoot 'browser-model.ps1')
. (Join-Path $PSScriptRoot 'comparison-model.ps1')
. (Join-Path $PSScriptRoot 'comparison-controller.ps1')
. (Join-Path $PSScriptRoot 'release-support.ps1')
$exe=Join-Path $PSScriptRoot 'build\ame.exe'
$marker=Join-Path $PSScriptRoot 'build\windows-validation.json'
if (!(Test-Path $exe) -or !(Test-Path $marker)) { throw 'Esegui prima .\test-windows.ps1.' }
$validation=Get-Content $marker -Raw|ConvertFrom-Json
if ($validation.engine_revision -ne 'R10' -or $validation.version -ne '0.5.0' -or $validation.exe_sha256 -ne (Get-FileHash $exe -Algorithm SHA256).Hash -or $validation.runtime_sha256 -ne (Get-FileHash (Join-Path $PSScriptRoot 'src\hub-runtime.cs') -Algorithm SHA256).Hash) { throw 'Build cambiata: esegui .\test-windows.ps1.' }
if($validation.api_bridge_sha256 -ne (Get-FileHash (Join-Path $PSScriptRoot 'resource-api-bridge.ps1')).Hash -or $validation.api_client_sha256 -ne (Get-FileHash (Join-Path $PSScriptRoot 'src/resource-api-client.cs')).Hash -or $validation.panel_revision -ne 'R22' -or $validation.hub_sha256 -ne (Get-FileHash $PSCommandPath -Algorithm SHA256).Hash -or $validation.model_sha256 -ne (Get-FileHash (Join-Path $PSScriptRoot 'windows-model.ps1') -Algorithm SHA256).Hash){throw 'Pannello aggiornato: avvia AVVIA.cmd per verificarlo.'}
foreach($component in @('strategy-model.ps1','browser-model.ps1','release-support.ps1','browser-panel.ps1','browser-connection.ps1','comparison-model.ps1','comparison-controller.ps1','comparison-panel.ps1','src/comparison-metrics.cs','export-diagnostics.ps1','process-reduction-api.ps1','agent.ps1','agent-state.ps1','agent-model.ps1','agent-runtime.ps1','start-agent.ps1','agent-control.ps1','agent-dashboard.ps1','browser/chrome/background.js','browser/chrome/policy.js','browser/chrome/popup.js','browser/chrome/popup.html','browser/chrome/manifest.json','browser/firefox/background.js','browser/firefox/policy.js','browser/firefox/popup.js','browser/firefox/popup.html','browser/firefox/manifest.json')){
    if($validation.support_hashes.$component -ne (Get-FileHash (Join-Path $PSScriptRoot $component)).Hash){throw 'Strategia aggiornata: avvia AVVIA.cmd per verificarla.'}
}
$created=$false
$script:hubMutex=[Threading.Mutex]::new($false,'Local\AME-Process-Hub',[ref]$created)
if(!$created){
    $script:hubMutex.Dispose()
    . (Join-Path $PSScriptRoot 'agent-state.ps1')
    $activeAgent=Get-AgentLiveStatus
    if($activeAgent -and $activeAgent.identity_alive){& (Join-Path $PSScriptRoot 'agent-dashboard.ps1');return}
    [void][Windows.Forms.MessageBox]::Show('Un pannello o agente AME e gia aperto. Usa quello esistente.','AME');return
}
foreach($running in @(Get-Process -Name ame -ErrorAction SilentlyContinue)) {
    if($running.SessionId -eq [Diagnostics.Process]::GetCurrentProcess().SessionId){$script:hubMutex.Dispose();throw 'Un motore AME e gia attivo. Chiudi i vecchi pannelli AME prima di aprire questa versione.'}
}
$script:apiConnection=$null;$script:browserEnabled=$false;$script:bridge=$null;$script:pendingBrowser=$null
$script:comparison=$null;$script:comparisonSampler=$null;$script:comparisonClock=$null;$script:comparisonGuard=$null
$script:strategyPath=Join-Path $PSScriptRoot 'reports/strategy-history.json';$script:strategyRecords=@()
$script:progressTargets=@();$script:liveMeasurements=@{}
$script:targetStates=@{}; $script:resultText='Seleziona le caselle dei processi da gestire.'
$script:historyPath=Join-Path $PSScriptRoot 'reports\recovery-history.json'
$script:historyFailure=''
$script:batchActive=$false; $script:batchQueue=@(); $script:batchTotal=0; $script:batchIndex=0; $script:batchApplied=0;$script:batchRetained=0;$script:batchInconclusive=0; $script:cancelQueue=$false
$script:batchReports=New-Object 'Collections.Generic.List[string]'
$script:currentOutcome='';$script:currentReason=''; $script:currentFeedback=''; $script:currentWait=''
$script:pendingRecoveryMode=$null;$script:pendingSelection=@();$script:pendingDeadline=$null;$script:panelReport=$null
$script:engine=$null; $script:tail=$null; $script:stopFile=$null; $script:mode='observe'; $script:restartMode=$null
$script:selection=@{}; $script:runSelection=@(); $script:trimmed=0; $script:lastReasons=''; $script:lastComplete=$null
$script:inventoryRows=@();$script:renderingInventory=$false;$script:sortQueued=$false;$script:sortFocusKey=''
$script:remaining=0; $script:userStopping=$false; $script:closing=$false
$form=New-Object Windows.Forms.Form
$form.Text='Advanced Memory Engine 0.5 R22 - Gestione processi'
$area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$width=[math]::Min(1180,$area.Width-45); $height=[math]::Min(820,$area.Height-75)
$form.AutoScaleMode='None'; $form.ClientSize=New-Object Drawing.Size($width,$height); $form.StartPosition='CenterScreen'; $form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.MinimumSize=New-Object Drawing.Size([math]::Min(1000,$form.Width),[math]::Min(650,$form.Height))
$form.BackColor=[Drawing.Color]::FromArgb(241,245,249)
$layout=New-Object Windows.Forms.TableLayoutPanel
$layout.Dock='Fill';$layout.ColumnCount=1;$layout.RowCount=6;$layout.Padding=New-Object Windows.Forms.Padding(16)
[void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
foreach($rowSize in @(122,96,0,260,32,0)){
    $style=New-Object Windows.Forms.RowStyle
    if($rowSize -eq 0 -and $layout.RowStyles.Count -eq 2){$style.SizeType='Percent';$style.Height=100}
    else{$style.SizeType='Absolute';$style.Height=$rowSize}
    [void]$layout.RowStyles.Add($style)
}
$script:hubTabs=New-Object Windows.Forms.TabControl;$script:hubTabs.Dock='Fill'
$processTab=New-Object Windows.Forms.TabPage('Processi e strategia')
$browserTab=New-Object Windows.Forms.TabPage('Rilascio nelle app')
$script:releaseTab=$browserTab
[void]$script:hubTabs.TabPages.Add($processTab);[void]$script:hubTabs.TabPages.Add($browserTab)
$form.Controls.Add($script:hubTabs);$processTab.Controls.Add($layout)
$header=New-Object Windows.Forms.Panel;$header.Dock='Fill';$header.BackColor=[Drawing.Color]::FromArgb(20,37,60)
$layout.Controls.Add($header,0,0)
$ram=New-Object Windows.Forms.Label
$ram.Location=New-Object Drawing.Point(16,13); $ram.Size=New-Object Drawing.Size(($width-70),32);$ram.Anchor='Top, Left, Right';$ram.ForeColor=[Drawing.Color]::White
$ram.Font=New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Bold); $ram.Text='Avvio monitoraggio dei processi...'; $header.Controls.Add($ram)
$note=New-Object Windows.Forms.Label
$note.Location=New-Object Drawing.Point(16,50); $note.Size=New-Object Drawing.Size(($width-70),44);$note.Anchor='Top, Left, Right';$note.ForeColor=[Drawing.Color]::FromArgb(211,225,241)
$note.Text="Spunta 1-5 processi e premi Strategia RAM per scegliere un metodo supportato dall'app.`r`nProva temporanea resta un esperimento: svuota il working set e misura se la RAM torna."
$header.Controls.Add($note)
$apiStatus=New-Object Windows.Forms.Label
$apiStatus.Location=New-Object Drawing.Point(16,96);$apiStatus.Size=New-Object Drawing.Size(($width-70),22);$apiStatus.Anchor='Top, Left, Right'
$apiStatus.ForeColor=[Drawing.Color]::FromArgb(211,225,241);$apiStatus.AutoEllipsis=$true;$apiStatus.Text='Collegamento API AME...';$header.Controls.Add($apiStatus)
$toolbar=New-Object Windows.Forms.FlowLayoutPanel;$toolbar.Dock='Fill';$toolbar.WrapContents=$true;$toolbar.Padding=New-Object Windows.Forms.Padding(0,10,0,0)
$layout.Controls.Add($toolbar,0,1)
$grid=New-Object Windows.Forms.DataGridView
$grid.Dock='Fill';$grid.BackgroundColor=[Drawing.Color]::White;$grid.BorderStyle='None';$grid.CellBorderStyle='SingleHorizontal'
$grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.RowHeadersVisible=$false
$grid.AutoSizeColumnsMode='Fill'; $grid.SelectionMode='FullRowSelect';$grid.MultiSelect=$false;$grid.EnableHeadersVisualStyles=$false
$grid.ColumnHeadersHeightSizeMode='DisableResizing';$grid.ColumnHeadersHeight=36;$grid.RowTemplate.Height=29
$grid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(225,233,243)
$grid.ColumnHeadersDefaultCellStyle.ForeColor=[Drawing.Color]::FromArgb(20,37,60)
$grid.ColumnHeadersDefaultCellStyle.Font=New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold)
$grid.DefaultCellStyle.ForeColor=[Drawing.Color]::FromArgb(32,49,70)
$grid.DefaultCellStyle.SelectionBackColor=[Drawing.Color]::FromArgb(218,234,252)
$grid.DefaultCellStyle.SelectionForeColor=[Drawing.Color]::FromArgb(20,37,60)
$grid.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(247,249,252)
$checkbox=New-Object Windows.Forms.DataGridViewCheckBoxColumn; $checkbox.Name='choose'; $checkbox.HeaderText='Seleziona'; $checkbox.FillWeight=65;$checkbox.MinimumWidth=70
[void]$grid.Columns.Add($checkbox);$checkbox.SortMode='NotSortable'
foreach ($column in @(@('name','Processo'),@('pid','PID'),@('private','RAM privata MiB'),@('commit','Commit MiB'),@('cpu','CPU %'),@('idle','Bassa attivita s'),@('faults','Fault/s'),@('method','Metodo consigliato'),@('state','Stato / risultato'))) {
    [void]$grid.Columns.Add($column[0],$column[1]); $grid.Columns[$column[0]].ReadOnly=$true;$grid.Columns[$column[0]].SortMode='NotSortable'
}
$grid.Columns['method'].FillWeight=190;$grid.Columns['method'].MinimumWidth=165
$grid.Columns['state'].FillWeight=240;$grid.Columns['state'].MinimumWidth=250; $grid.Columns['name'].FillWeight=140
$grid.Columns['private'].SortMode='Programmatic';$grid.Columns['private'].HeaderCell.SortGlyphDirection='Descending'
$grid.Columns['private'].HeaderCell.ToolTipText='Clicca per ordinare dal maggiore consumo di RAM privata al minore.'
$grid.Columns['commit'].Visible=$false;$grid.Columns['faults'].Visible=$false
$layout.Controls.Add($grid,0,2)
function New-Button([string]$text,[int]$x,[int]$width) {
    $button=New-Object Windows.Forms.Button; $button.Text=$text
    $button.Size=New-Object Drawing.Size($width,34);$button.FlatStyle='Flat';$button.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(191,205,223)
    $button.BackColor=[Drawing.Color]::White;$button.ForeColor=[Drawing.Color]::FromArgb(20,37,60);$button.Margin=New-Object Windows.Forms.Padding(0,0,8,8)
    $toolbar.Controls.Add($button); return $button
}
$smart=New-Button 'Strategia RAM' 0 165
$smart.BackColor=[Drawing.Color]::FromArgb(25,92,179);$smart.ForeColor=[Drawing.Color]::White
$smart.Add_Click({Request-Strategy})
$single=New-Button 'Prova temporanea' 0 175
$single.BackColor=[Drawing.Color]::White;$single.ForeColor=[Drawing.Color]::FromArgb(20,37,60)
$actionTip=New-Object Windows.Forms.ToolTip
$actionTip.AutoPopDelay=15000
$actionTip.SetToolTip($single,'Verifica i processi spuntati, uno alla volta. Se idonei, prova una sola riduzione della RAM residente e ne misura la durata per 5 minuti. La riduzione puo essere temporanea.')
$start=New-Button 'Automatico con pressione' 0 210
$pause=New-Button 'Pausa monitoraggio' 0 175
$stopButton=New-Button 'Ferma e pausa' 0 140
$clear=New-Button 'Deseleziona' 0 115
$reports=New-Button 'Esporta diagnosi' 0 145
$durationLabel=New-Object Windows.Forms.Label; $durationLabel.Text='Automatico, minuti:'
$durationLabel.Size=New-Object Drawing.Size(145,30);$durationLabel.TextAlign='MiddleLeft';$toolbar.Controls.Add($durationLabel)
$duration=New-Object Windows.Forms.ComboBox; $duration.DropDownStyle='DropDownList'
$duration.Size=New-Object Drawing.Size(75,30)
[void]$duration.Items.AddRange(@('5','15','60')); $duration.SelectedIndex=0; $toolbar.Controls.Add($duration)
$footer=New-Object Windows.Forms.Panel;$footer.Dock='Fill';$footer.BackColor=[Drawing.Color]::White;$footer.Margin=New-Object Windows.Forms.Padding(0,12,0,0)
$layout.Controls.Add($footer,0,3)
$result=New-Object Windows.Forms.Label;$result.Location=New-Object Drawing.Point(12,9);$result.Size=New-Object Drawing.Size(($width-80),84);$result.Anchor='Top, Left, Right';$result.AutoEllipsis=$true
$result.Font=New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold);$result.ForeColor=[Drawing.Color]::FromArgb(20,37,60);$result.Text=$script:resultText;$footer.Controls.Add($result)
$state=New-Object Windows.Forms.Label; $state.Location=New-Object Drawing.Point(12,99); $state.Size=New-Object Drawing.Size(($width-80),50);$state.Anchor='Top, Left, Right';$state.AutoEllipsis=$true
$state.Text='Monitoraggio attivo. Nessun intervento avviato.'; $footer.Controls.Add($state)
$queueStatus=New-Object Windows.Forms.TextBox
$activityPanels=New-Object Windows.Forms.TableLayoutPanel
$activityPanels.Location=New-Object Drawing.Point(12,155);$activityPanels.Size=New-Object Drawing.Size(($width-80),90);$activityPanels.Anchor='Top, Left, Right';$activityPanels.ColumnCount=2;$activityPanels.RowCount=1
[void]$activityPanels.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,50)))
[void]$activityPanels.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,50)))
[void]$activityPanels.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
$footer.Controls.Add($activityPanels)
$processActivity=New-Object Windows.Forms.GroupBox;$processActivity.Text='Interventi sui processi';$processActivity.Dock='Fill';$activityPanels.Controls.Add($processActivity,0,0)
$chromeActivity=New-Object Windows.Forms.GroupBox;$chromeActivity.Text='Collegamento browser - registro';$chromeActivity.Dock='Fill';$activityPanels.Controls.Add($chromeActivity,1,0)
$script:mainBrowserLogBox=New-Object Windows.Forms.TextBox
$script:mainBrowserLogBox.Dock='Fill';$script:mainBrowserLogBox.Multiline=$true;$script:mainBrowserLogBox.ReadOnly=$true;$script:mainBrowserLogBox.ScrollBars='Vertical';$script:mainBrowserLogBox.BackColor=[Drawing.Color]::White;$script:mainBrowserLogBox.Font=New-Object Drawing.Font('Segoe UI',9)
$chromeActivity.Controls.Add($script:mainBrowserLogBox)
$queueStatus.Dock='Fill'
$queueStatus.Multiline=$true;$queueStatus.ReadOnly=$true;$queueStatus.ScrollBars='Vertical';$queueStatus.WordWrap=$true;$queueStatus.BorderStyle='FixedSingle'
$queueStatus.Font=New-Object Drawing.Font('Segoe UI',9);$queueStatus.BackColor=[Drawing.Color]::White
$queueStatus.Text='Qui compariranno avanzamento e risultati dei processi richiesti.';$processActivity.Controls.Add($queueStatus)
Update-BrowserConnectionDisplay
$details=New-Object Windows.Forms.CheckBox;$details.Text='Mostra dettagli tecnici (log, commit e fault)';$details.Dock='Fill';$details.ForeColor=[Drawing.Color]::FromArgb(74,94,118)
$layout.Controls.Add($details,0,4)
$log=New-Object Windows.Forms.TextBox
$log.Dock='Fill';$log.Visible=$false
$log.Multiline=$true; $log.ReadOnly=$true; $log.ScrollBars='Vertical'; $log.Font=New-Object Drawing.Font('Consolas',9)
$layout.Controls.Add($log,0,5)
$details.Add_CheckedChanged({$log.Visible=$details.Checked;$layout.RowStyles[5].Height=$(if($details.Checked){145}else{0});$grid.Columns['commit'].Visible=$details.Checked;$grid.Columns['faults'].Visible=$details.Checked})
$grid.Add_CurrentCellDirtyStateChanged({if($grid.IsCurrentCellDirty){[void]$grid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit)}})
function Add-HubLog([string]$message){Add-Log $message}
function Add-Log([string]$message) {
    if($log.IsDisposed){return}
    $log.AppendText((Get-Date -Format 'HH:mm:ss')+'  '+$message+"`r`n")
    if ($log.TextLength -gt 60000) { $log.Text=$log.Text.Substring($log.TextLength-40000) }
}
function Write-PanelEvent([string]$action,[string]$stage,[string]$detail='') {
    try{
        if(!$script:panelReport){
            $folder=Join-Path $PSScriptRoot 'reports';New-Item -ItemType Directory -Path $folder -Force|Out-Null
            $script:panelReport=Join-Path $folder ('panel-'+[guid]::NewGuid().ToString('N')+'.jsonl')
        }
        if((Test-Path -LiteralPath $script:panelReport) -and (Get-Item -LiteralPath $script:panelReport).Length -ge 1MB){return}
        $entry=@{type='panel_event';utc=[DateTime]::UtcNow.ToString('o');action=$action;stage=$stage;detail=$detail;mode=$script:mode;selected=@($script:selection.Keys)}
        [IO.File]::AppendAllText($script:panelReport,($entry|ConvertTo-Json -Compress)+"`n",(New-Object Text.UTF8Encoding($false)))
    }catch{Add-Log ('Registro comandi non disponibile: '+$_.Exception.Message)}
}
function Save-Selection {
    [void]$grid.EndEdit()
    foreach ($row in $grid.Rows) {
        if ($row.Cells['choose'].Value -and !$row.Tag.Blocked) { $script:selection[$row.Tag.Key]=$row.Tag }
        else { $script:selection.Remove($row.Tag.Key) }
    }
}
function Show-Inventory([object[]]$rows,[string]$focusKey='') {
    $existing=@{}; $grid.Rows.Clear()
    foreach ($rowData in $rows) {
        $existing[$rowData.Key]=$true
        if($script:selection.ContainsKey($rowData.Key) -and ![string]::Equals([string]$script:selection[$rowData.Key].Path,[string]$rowData.Path,[StringComparison]::OrdinalIgnoreCase)){$script:selection.Remove($rowData.Key)}
        $private=if($null -eq $rowData.PrivateBytes){'N/D'}else{'{0:N1}' -f ($rowData.PrivateBytes/1MB)}
        $cpu=if($null -eq $rowData.Cpu){'N/D'}else{'{0:N2}' -f $rowData.Cpu}
        $commit=if($null -eq $rowData.CommitBytes){'N/D'}else{'{0:N1}' -f ($rowData.CommitBytes/1MB)}
        $faults=if($null -eq $rowData.Faults){'N/D'}else{'{0:N1}' -f $rowData.Faults}
        $shownState=if($script:targetStates.ContainsKey($rowData.Key)){$script:targetStates[$rowData.Key]}else{$rowData.State}
        $advice=Get-StrategyAdvice $rowData $script:strategyRecords
        $index=$grid.Rows.Add($script:selection.ContainsKey($rowData.Key),$rowData.Name,$rowData.Pid,$private,$commit,$cpu,('{0:N0}' -f $rowData.Idle),$faults,$advice.Method,$shownState)
        $row=$grid.Rows[$index]; $row.Tag=$rowData; $row.Cells['choose'].ReadOnly=[bool]$rowData.Blocked -or $script:batchActive -or $script:mode -in @('recover','recover-test') -or [bool]$script:restartMode
        $row.Cells['method'].ToolTipText=$advice.Explanation
        $row.Cells['name'].ToolTipText=$rowData.Path;$row.Cells['state'].ToolTipText=$shownState
        if($rowData.Blocked){$row.DefaultCellStyle.ForeColor=[Drawing.Color]::DimGray}
        if($focusKey -eq $rowData.Key){$grid.CurrentCell=$row.Cells['choose']}
    }
    foreach ($key in @($script:selection.Keys)) { if(!$existing.ContainsKey($key)){$script:selection.Remove($key)} }
    $grid.Columns['private'].HeaderCell.SortGlyphDirection='Descending'
}
function Sort-RamInventory([string]$focusKey='') {
    if($script:renderingInventory){return}
    $script:renderingInventory=$true
    try{
        if(!$focusKey -and $grid.CurrentRow){$focusKey=[string]$grid.CurrentRow.Tag.Key}
        Save-Selection
        Show-Inventory @(Get-WindowsRamOrderedRows $script:inventoryRows) $focusKey
    }finally{$script:renderingInventory=$false}
}
function Request-RamSort([string]$focusKey='') {
    if($script:renderingInventory -or $grid.IsDisposed){return}
    $script:sortFocusKey=$focusKey
    if($script:sortQueued){return}
    $script:sortQueued=$true
    try{
        # Let the checkbox finish committing before rebuilding its row collection.
        [void]$grid.BeginInvoke([Action]{
            $script:sortQueued=$false
            if(!$grid.IsDisposed){Sort-RamInventory $script:sortFocusKey}
        })
    }catch{$script:sortQueued=$false;throw}
}
function On-InventorySelectionChanged([int]$rowIndex,[int]$columnIndex) {
    if($script:renderingInventory -or $rowIndex -lt 0 -or $columnIndex -ne $grid.Columns['choose'].Index){return}
    $row=$grid.Rows[$rowIndex];$key=[string]$row.Tag.Key
    $script:renderingInventory=$true
    try{
        Save-Selection
        if($row.Cells['choose'].Value -and $script:selection.Count -gt 5){
            $row.Cells['choose'].Value=$false;$script:selection.Remove($key)
            $result.Text='Puoi spuntare al massimo 5 processi. La sesta casella non e stata selezionata.'
        }
    }finally{$script:renderingInventory=$false}
    Request-RamSort $key
}
function Show-Snapshot($sample) {
    $script:renderingInventory=$true
    try{
        $focusKey=if($grid.CurrentRow){[string]$grid.CurrentRow.Tag.Key}else{''}
        Save-Selection
        $script:inventoryRows=@(Get-WindowsRows $sample $env:windir ([Diagnostics.Process]::GetCurrentProcess().SessionId))
        Show-Inventory @(Get-WindowsRamOrderedRows $script:inventoryRows) $focusKey
        $script:lastComplete=[DateTime]::UtcNow
    }finally{$script:renderingInventory=$false}
}
$grid.Add_CellValueChanged({param($sender,$eventArgs) On-InventorySelectionChanged $eventArgs.RowIndex $eventArgs.ColumnIndex})
$grid.Add_ColumnHeaderMouseClick({param($sender,$eventArgs) if($eventArgs.ColumnIndex -eq $grid.Columns['private'].Index){Request-RamSort}})
function Assert-ResourceApiTargets([object[]]$Targets) {
    if(!$script:apiConnection -or !$script:apiConnection.Ready -or !$script:apiConnection.Client){
        throw 'API AME non disponibile: riapri con AVVIA.cmd. Nessun intervento avviato.'
    }
    foreach($target in $Targets){
        try{
            $script:apiConnection.Client.Validate([string]$target.Key,[string]$target.Path)
            $apiStatus.Text=('API AME: identita PID '+$target.Pid+' verificata. Job Object: solo demo.')
            Write-PanelEvent 'resource_api' 'identity_verified' ('AmeReadProcessIdentity: '+$target.Key)
        }catch{
            $apiStatus.Text='API AME: verifica identita fallita. Richiesta bloccata.'
            Write-PanelEvent 'resource_api' 'identity_rejected' ($target.Key+': '+$_.Exception.Message)
            throw
        }
    }
}
function Start-Engine([string]$mode) {
    if($mode -in @('recover','recover-test') -and $script:comparison -and (Test-ComparisonBusy)){throw 'Confronto beneficio in corso: annullalo prima di avviare altre riduzioni.'}
    if($mode -in @('recover','recover-test')){Assert-ResourceApiTargets @($script:runSelection)}
    $folder=Join-Path $PSScriptRoot 'reports'; New-Item -ItemType Directory -Path $folder -Force|Out-Null
    $id=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $path=Join-Path $folder ($mode+'-'+$id+'.jsonl'); $script:stopFile=Join-Path $folder ($mode+'-'+$id+'.stop')
    $seconds=if($mode -eq 'recover-test'){180}elseif($mode -eq 'recover'){[int]$duration.SelectedItem*60}else{600}
    if($mode -in @('recover','recover-test')){
        $info=New-AmeReductionStartInfo -Root $PSScriptRoot -Targets @($script:runSelection) -Mode $mode -Seconds $seconds -Report $path -StopFile $script:stopFile
    }else{
        $argsList=@(('--'+$mode),'--inventory','--seconds',$seconds.ToString(),'--report',$path,'--stop-file',$script:stopFile)
        $quoted=foreach($argument in $argsList){if($argument.Contains('"') -or $argument.EndsWith('\')){throw 'Argomento non valido.'};'"'+$argument+'"'}
        $info=New-Object Diagnostics.ProcessStartInfo; $info.FileName=$exe; $info.Arguments=$quoted -join ' '
        $info.WorkingDirectory=$PSScriptRoot; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    }
    $candidate=New-Object Diagnostics.Process; $candidate.StartInfo=$info
    $candidateStarted=$false
    try{[void]$candidate.Start();$candidateStarted=$true;$candidate.BeginOutputReadLine()}
    catch{
        if($candidateStarted){[IO.File]::WriteAllText($script:stopFile,'stop')}
        $candidate.Dispose();throw
    }
    $script:engine=$candidate
    $script:mode=$mode; $script:reportPath=$path; $script:ends=[DateTime]::UtcNow.AddSeconds($seconds)
    if(!$script:batchActive){$script:targetStates=@{}}
    $script:trimmed=0; $script:lastReasons=''; $script:userStopping=$false
    foreach($row in $grid.Rows){$row.Cells['choose'].ReadOnly=($mode -in @('recover','recover-test')) -or [bool]$script:pendingRecoveryMode -or [bool]$row.Tag.Blocked}
    $start.Enabled=$mode -notin @('recover','recover-test'); $stopButton.Enabled=$mode -in @('recover','recover-test'); $duration.Enabled=$mode -notin @('recover','recover-test'); $clear.Enabled=$mode -notin @('recover','recover-test')
    $single.Enabled=$mode -eq 'observe';$pause.Enabled=$mode -eq 'observe';$pause.Text='Pausa monitoraggio'
    if($script:pendingRecoveryMode){$single.Enabled=$false;$start.Enabled=$false;$pause.Enabled=$false;$clear.Enabled=$false;$stopButton.Enabled=$true}
    Add-Log ('Modalita '+$mode+'; report: '+$path)
    $state.Text=if($mode -eq 'recover-test'){'Prova a ridurre RAM: verifico il processo e attendo 60 secondi di bassa attivita. Nessuna soglia RAM richiesta.'}elseif($mode -eq 'recover'){'Automatico: attendo RAM >=85% per 30 secondi e 60 secondi di bassa attivita.'}else{'Monitoraggio per massimo 10 minuti. Spunta le caselle dei processi da gestire.'}
}
function Refresh-RecoveryProgress {
    if(!$queueStatus){return}
    $lines=@();$position=0
    foreach($target in $script:progressTargets){
        $position++
        $message=if($script:targetStates.ContainsKey($target.Key)){$script:targetStates[$target.Key]}else{'Richiesta ricevuta. Nessun intervento ancora eseguito.'}
        $lines+=('{0}. {1} (PID {2}) - {3}' -f $position,$target.Name,$target.Pid,($message -replace '[\r\n]+',' '))
    }
    $queueStatus.Text=if($lines.Count){$lines -join "`r`n"}else{'Qui compariranno avanzamento e risultati dei processi richiesti.'}
}
function Set-RecoveryTargetText($target,[string]$text) {
    $script:targetStates[$target.Key]=$text
    foreach($row in $grid.Rows){if($row.Tag.Key -eq $target.Key){$row.Cells['state'].Value=$text;$row.Cells['state'].ToolTipText=$text}}
}
function Show-RecoveryUpdate($event) {
    $matches=@($script:runSelection|Where-Object {$_.Pid -eq $event.pid -and (!$event.creation_filetime -or $_.Key -eq ([string]$event.pid+':'+[string]$event.creation_filetime))})
    if($matches.Count -ne 1){return}
    $target=$matches[0];$key=$target.Key
    if(!$script:liveMeasurements){$script:liveMeasurements=@{}}
    $measurement=$script:liveMeasurements[$key]
    if($event.type -eq 'recover_applied'){
        $measurement=[pscustomobject]@{Before=$null;After=$null;Began=[double]$event.elapsed_seconds;Seconds=0;Note='';Finished=$false}
        $script:liveMeasurements[$key]=$measurement
        $text='INTERVENTO ESEGUITO. Attendo la misura della RAM prima/dopo.'
    }elseif($event.type -eq 'recover_feedback'){
        if($null -eq $event.private_resident_before_bytes -or $null -eq $event.private_resident_after_bytes){return}
        if(!$measurement){$measurement=[pscustomobject]@{Before=$null;After=$null;Began=([double]$event.elapsed_seconds-[double]$event.seconds_after_action);Seconds=0;Note='';Finished=$false};$script:liveMeasurements[$key]=$measurement}
        $measurement.Before=[double]$event.private_resident_before_bytes;$measurement.After=[double]$event.private_resident_after_bytes;$measurement.Seconds=[double]$event.seconds_after_action
        $text=Get-RecoveryLiveMeasurement $measurement
        $script:currentFeedback=$text
    }elseif($event.type -eq 'recover_target'){
        if($measurement -and !$measurement.Finished){
            $measurement.After=$event.private_resident_bytes;$measurement.Seconds=[math]::Max(0,([double]$event.elapsed_seconds-$measurement.Began))
            $text=Get-RecoveryLiveMeasurement $measurement
            $script:currentFeedback=$text
        }elseif($measurement -and $measurement.Finished){return}
        else{
            $text='NESSUN INTERVENTO ANCORA. '+(Get-RecoveryTargetStatus $event)
            if($event.single_test){$text+='; attesa massima residua: '+[math]::Max(0,[math]::Ceiling(180-[double]$event.elapsed_seconds))+' s.'}
        }
    }elseif($event.type -in @('recover_activity_warning','recover_usage_warning')){
        if(!$measurement){return}
        $measurement.Note=if($event.type -eq 'recover_usage_warning'){'App tornata in primo piano. Altri processi annullati.'}else{'Attivita aumentata. Altri processi annullati; prestazioni non verificate.'}
        $text=Get-RecoveryLiveMeasurement $measurement
        $script:currentFeedback=$text
    }else{
        $text=Get-RecoveryOutcomeStatus $event
        if($event.type -eq 'recover_no_action' -and $script:currentWait){$text+=' Ultimo motivo: '+$script:currentWait}
        if($measurement){$measurement.Finished=$true;$text+=' '+(Get-RecoveryLiveMeasurement $measurement -Final);$script:currentFeedback=''}
        $script:currentOutcome=$text
    }
    Set-RecoveryTargetText $target $text
    if($event.type -eq 'recover_target' -and !$measurement -and @($script:liveMeasurements.Values|Where-Object {!$_.Finished}).Count){Refresh-RecoveryProgress;return}
    $script:resultText=$(if($script:batchActive){'Processo '+$script:batchIndex+'/'+$script:batchTotal+' - '}else{''})+('{0} (PID {1})' -f $target.Name,$target.Pid)+"`r`n"+$text
    $result.Text=$script:resultText
    Refresh-RecoveryProgress
}

function Start-NextRecovery {
    if(!$script:batchActive -or $script:cancelQueue -or !$script:batchQueue.Count){return $false}
    $next=$script:batchQueue[0]
    $script:batchQueue=@($script:batchQueue|Select-Object -Skip 1)
    $script:batchIndex++
    $script:runSelection=@($next)
    $script:currentOutcome='';$script:currentReason='';$script:currentFeedback='';$script:currentWait=''
    $script:resultText=('Processo {0}/{1}: {2} (PID {3}). Nessun intervento ancora applicato.' -f $script:batchIndex,$script:batchTotal,$next.Name,$next.Pid)
    $result.Text=$script:resultText
    Set-RecoveryTargetText $next 'VERIFICA IN CORSO. Nessun intervento ancora eseguito.'
    foreach($queued in $script:batchQueue){Set-RecoveryTargetText $queued ('NON ANCORA AVVIATO. Prima completo '+$next.Name+' (PID '+$next.Pid+'). Nessun intervento su questo processo.')}
    Refresh-RecoveryProgress
    Start-Engine 'recover-test'
    return $true
}
function Stop-RecoveryQueue([string]$reason='Richiesta fermata.') {
    $notStarted=@($script:pendingSelection)+@($script:batchQueue)
    $script:pendingRecoveryMode=$null;$script:pendingSelection=@();$script:pendingDeadline=$null
    $script:cancelQueue=$true
    foreach($queued in $notStarted){if($null -ne $queued){$script:targetStates[$queued.Key]='Annullato: '+$reason+' Nessun intervento eseguito su questo processo.'}}
    foreach($row in $grid.Rows){if($script:targetStates.ContainsKey($row.Tag.Key)){$row.Cells['state'].Value=$script:targetStates[$row.Tag.Key];$row.Cells['state'].ToolTipText=$script:targetStates[$row.Tag.Key]}}
    $script:batchQueue=@()
    Refresh-RecoveryProgress
}
function Finish-RecoveryProcess([int]$exitCode) {
    $target=$script:runSelection[0]
    $script:batchApplied+=$script:trimmed
    if($exitCode -eq 0 -and $script:currentReason -in @('resident_reduction_retained_5m','resident_reduction_retained_5m_with_activity','resident_reduction_retained_5m_after_resume')){$script:batchRetained++}
    elseif($script:trimmed -gt 0 -and ($exitCode -ne 0 -or $script:currentReason -notin @('rapid_resident_rebound','no_meaningful_resident_reduction','resident_reduction_not_retained_5m'))){$script:batchInconclusive++}
    $outcome=if($exitCode -ne 0){'Errore del motore; coda interrotta.'}elseif($script:currentOutcome){$script:currentOutcome}else{'Esito finale mancante; coda interrotta.'}
    if(!$script:currentOutcome -or $exitCode -ne 0){$script:cancelQueue=$true}
    if(($exitCode -ne 0 -or !$script:currentOutcome) -and $script:liveMeasurements -and $script:liveMeasurements.ContainsKey($target.Key)){$measurement=$script:liveMeasurements[$target.Key];$measurement.Finished=$true;$script:currentFeedback=Get-RecoveryLiveMeasurement $measurement -Final}
    if($script:currentFeedback){$outcome=$script:currentFeedback+' '+$outcome}
    $script:targetStates[$target.Key]=$outcome
    foreach($row in $grid.Rows){if($row.Tag.Key -eq $target.Key){$row.Cells['state'].Value=$outcome;$row.Cells['state'].ToolTipText=$outcome}}
    if($script:cancelQueue -or $script:userStopping){Stop-RecoveryQueue}
    Refresh-RecoveryProgress
    if($script:batchQueue.Count -and !$script:cancelQueue){return (Start-NextRecovery)}
    $script:batchActive=$false
    $script:resultText=('Coda {0}. Processi esaminati: {1}/{2}. Interventi applicati: {3}. Risultati nella colonna Stato.' -f $(if($script:cancelQueue){'interrotta'}else{'completata'}),$script:batchIndex,$script:batchTotal,$script:batchApplied)
    $script:resultText+=(' RAM ridotta a 5 minuti: {0}. Misure incomplete: {1}.' -f $script:batchRetained,$script:batchInconclusive)
    $result.Text=$script:resultText
    return $false
}
function Request-Stop {
    if($script:engine -and !$script:engine.HasExited){[IO.File]::WriteAllText($script:stopFile,'stop')}
}
function Export-Diagnosis([string[]]$report=@()) {
    try {
        $exporter=Join-Path $PSScriptRoot 'export-diagnostics.ps1'
        if($script:panelReport -and (Test-Path -LiteralPath $script:panelReport)){
            if(!$report){$report=@(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'reports') -File -Filter '*.jsonl'|Where-Object {$_.Name -match '^(observe|recover)-'}|Sort-Object LastWriteTime -Descending|Select-Object -First 9|ForEach-Object {$_.FullName})}
            $report=@($report)+@($script:panelReport)
        }
        if($script:browserReportPath -and (Test-Path -LiteralPath $script:browserReportPath)){$report=@($report)+@($script:browserReportPath)}
        $result=if($report){& $exporter -Report $report}else{& $exporter}
        Add-Log ('Diagnosi ZIP: '+$result.Path+' | Report: '+$result.ReportCount+' | Interventi: '+$result.AppliedCount)
        foreach($warning in $result.Warnings){Add-Log ('Diagnosi parziale: '+$warning)}
        return $result.Path
    }catch{Add-Log ('Esportazione diagnosi fallita: '+$_.Exception.Message);return $null}
}
function Set-Paused {
    if($script:batchActive){
        Stop-RecoveryQueue;$script:batchActive=$false
        if(!$script:batchIndex){$script:resultText='Coda annullata prima del primo recupero. Nessun intervento applicato.';$result.Text=$script:resultText}
    }
    $script:mode='paused';$script:restartMode=$null
    $start.Enabled=$true;$single.Enabled=$true;$stopButton.Enabled=$false
    $clear.Enabled=$true;$duration.Enabled=$true;$pause.Enabled=$true;$pause.Text='Riprendi monitoraggio'
    $script:lastComplete=$null
    $state.Text='In pausa. Prova a ridurre RAM aggiorna l elenco e avvia la richiesta; Riprendi monitoraggio aggiorna soltanto i dati.'
    foreach($row in $grid.Rows){$row.Cells['choose'].ReadOnly=[bool]$row.Tag.Blocked}
}
function Show-TargetState($event) {
    $key=[string]$event.pid+':'+[string]$event.creation_filetime
    if($script:liveMeasurements -and $script:liveMeasurements.ContainsKey($key) -and $script:liveMeasurements[$key].Finished){return}
    $text=Get-RecoveryTargetStatus $event
    $script:currentWait=$text
    $script:targetStates[$key]=$text
    foreach($row in $grid.Rows){if($row.Tag.Key -eq $key){
        $row.Cells['state'].Value=$text;$row.Cells['state'].ToolTipText=$text
        $row.Cells['idle'].Value='{0:N0}' -f $event.low_activity_seconds
        $row.Cells['cpu'].Value=if($null -eq $event.cpu_percent){'N/D'}else{'{0:N2}' -f $event.cpu_percent}
        $row.Cells['faults'].Value=if($null -eq $event.page_faults_per_second){'N/D'}else{'{0:N1}' -f $event.page_faults_per_second}
    }}
}
function Read-WindowsEvents {
    if(!$script:tail -and (Test-Path $script:reportPath)){$script:tail=New-Object AmeHub.ReportTail($script:reportPath)}
    if(!$script:tail){return}
    foreach($line in $script:tail.ReadLines()) {
        if(!$line.Trim()){continue}; $event=$line|ConvertFrom-Json
        if($event.type -eq 'sample') {
            $used=100*(1-$event.physical_available_bytes/[double]$event.physical_total_bytes)
            $count=$script:trimmed+$(if($script:batchActive){$script:batchApplied}else{0})
            $ram.Text='RAM {0:N1}% | Disponibile {1:N0} MiB | Interventi: {2}' -f $used,($event.physical_available_bytes/1MB),$count
            if($event.process_snapshot_complete){Show-Snapshot $event;Complete-PendingRecovery}
        } elseif($event.type -eq 'recover_target') {
            Show-TargetState $event
            Show-RecoveryUpdate $event
        } elseif($event.type -eq 'recover_state') {
            $script:trimmed=[int]$event.completed
            $count=$script:trimmed+$(if($script:batchActive){$script:batchApplied}else{0})
            $ram.Text=[regex]::Replace($ram.Text,'Interventi: [0-9]+',('Interventi: '+$count))
            $timeText=if($event.feedback_pending -and $null -ne $event.feedback_seconds_remaining){'Misura: circa '+[math]::Ceiling($event.feedback_seconds_remaining)+' secondi rimanenti.'}else{'Sessione: circa '+[math]::Max(0,[math]::Ceiling(($script:ends-[DateTime]::UtcNow).TotalMinutes))+' minuti rimanenti.'}
            $state.Text=(Get-RecoveryStatus $event)+"`r`n"+'Modalita: '+$(if($event.single_test){'Prova a ridurre RAM'}else{'Automatico con pressione'})+'. '+$timeText
            $reasons=$event.reasons|ConvertTo-Json -Compress
            if($reasons -ne '{}' -and $reasons -ne $script:lastReasons){Add-Log ('Motivi di attesa: '+$reasons);$script:lastReasons=$reasons}
        } elseif($event.type -eq 'recover_applied') {
            Show-RecoveryUpdate $event
            Add-Log ('Intervento eseguito su PID '+$event.pid+'; attendo misure prima/dopo.')
        } elseif($event.type -eq 'recover_feedback') {
            $script:resultText=Get-RecoveryFeedbackStatus $event;$result.Text=$script:resultText
            $script:currentFeedback=$script:resultText
            Show-RecoveryUpdate $event
            Add-Log ('PID {0} [{1}]: RAM privata {2:+0.0;-0.0;0.0} MiB; commit {3:+0.0;-0.0;0.0} MiB; disponibile sistema {4:+0.0;-0.0;0.0} MiB; fault/s {5:N1}. Variazioni osservate.' -f $event.pid,$event.phase,($event.private_resident_delta_bytes/1MB),($event.private_commit_delta_bytes/1MB),($event.system_available_delta_bytes/1MB),$event.page_faults_per_second)
        } elseif($event.type -in @('recover_activity_warning','recover_usage_warning')){
            Stop-RecoveryQueue $(if($event.type -eq 'recover_usage_warning'){'App corrente tornata in primo piano.'}else{'Attivita aumentata durante la misura del processo corrente.'})
            $script:resultText=$(if($event.type -eq 'recover_usage_warning'){'App tornata in primo piano: solo osservazione fino a 5 minuti. Nessun altro intervento.'}else{'Attivita/fault aumentati: nuovi interventi bloccati. Continuo a misurare quanta RAM rimane ridotta.'});$result.Text=$script:resultText
            Show-RecoveryUpdate $event
            Add-Log ('PID '+$event.pid+': avviso durante la misura; sola osservazione, nessuna ulteriore azione.')
        } elseif($event.type -in @('recover_guard','recover_assessed','recover_skipped','recover_no_action','recover_incomplete')){
            try{
                Save-RecoveryOutcome $script:historyPath $event $script:runSelection
                if($script:strategyPath){
                    Save-StrategyOutcome $script:strategyPath $event $script:runSelection ([IO.Path]::GetFileName($script:reportPath))
                    $script:strategyRecords=@(Read-StrategyHistory $script:strategyPath)
                }
            }catch{
                $script:cancelQueue=$true;$script:historyFailure='Storico non salvato: nuove richieste bloccate in questa apertura. '+$_.Exception.Message
                Add-Log $script:historyFailure;Write-PanelEvent $script:mode 'benefit_history_failed' $script:historyFailure
            }
            $outcome=Get-RecoveryOutcomeStatus $event
            if($event.type -eq 'recover_no_action' -and $script:currentWait){$outcome+=' Ultimo stato: '+$script:currentWait}
            $script:currentOutcome=$outcome;$script:currentReason=[string]$event.reason
            if($event.type -in @('recover_guard','recover_skipped','recover_incomplete') -or ($event.type -eq 'recover_assessed' -and $event.reason -ne 'resident_reduction_retained_5m')){$script:cancelQueue=$true}
            if($event.type -eq 'recover_assessed'){$script:resultText+=' '+$outcome}else{$script:resultText=$outcome};$result.Text=$script:resultText
            Show-RecoveryUpdate $event
            Add-Log ($event.type+' PID '+$event.pid+': '+$event.reason+'; errore Win32 '+$event.win32_error)
        } elseif($event.type -like 'recover_*'){Add-Log ($event.type+' PID '+$event.pid+': '+$event.reason+'; errore Win32 '+$event.win32_error)}
    }
}
function Begin-Recovery([string]$mode) {try{
    if($script:historyFailure){throw $script:historyFailure}
    if($script:batchActive -or $script:mode -in @('recover','recover-test') -or $script:restartMode){throw 'Una sessione e gia in corso: attendi oppure premi Ferma e pausa.'}
    Save-Selection
    if(!$script:selection.Count){throw 'Seleziona almeno un processo gestibile.'}
    if(!$script:lastComplete -or ([DateTime]::UtcNow-$script:lastComplete).TotalSeconds -gt 20){throw 'Elenco non aggiornato: attendi il prossimo campione.'}
    if($mode -eq 'recover-test' -and $script:selection.Count -gt 5){throw 'Per Prova a ridurre RAM scegli da 1 a 5 processi per coda.'}
    foreach($target in @($script:selection.Values)){
        $blocked=Get-RecoveryRepeatBlock $script:historyPath $target
        if($blocked){$script:targetStates[$target.Key]=$blocked;foreach($row in $grid.Rows){if($row.Tag.Key -eq $target.Key){$row.Cells['state'].Value=$blocked}};throw $blocked}
    }
    Assert-ResourceApiTargets @($script:selection.Values)
    $script:resultText='Recupero in attesa: nessun intervento applicato.';$result.Text=$script:resultText
    $script:runSelection=@($script:selection.Values)
    $script:progressTargets=@($script:selection.Values|Sort-Object @{Expression={$_.PrivateBytes};Descending=$true},Key);$script:liveMeasurements=@{}
    $script:cancelQueue=$false;$script:currentOutcome='';$script:currentReason='';$script:currentFeedback='';$script:currentWait=''
    $script:batchReports=New-Object 'Collections.Generic.List[string]'
    if($mode -eq 'recover-test'){
        $script:batchActive=$true;$script:batchIndex=0;$script:batchApplied=0;$script:batchRetained=0;$script:batchInconclusive=0
        $script:batchQueue=@($script:selection.Values|Sort-Object @{Expression={$_.PrivateBytes};Descending=$true},Key)
        $script:batchTotal=$script:batchQueue.Count
        $position=0;foreach($queued in $script:batchQueue){$position++;Set-RecoveryTargetText $queued ('RICHIESTA RICEVUTA - posizione '+$position+'/'+$script:batchTotal+'. Nessun intervento ancora eseguito.')}
        Refresh-RecoveryProgress
    }
    $script:restartMode=$mode; Request-Stop
    $state.Text='Avvio del recupero dei processi selezionati. Attendi la verifica delle condizioni.'
    $start.Enabled=$false;$single.Enabled=$false;$pause.Enabled=$false
    $stopButton.Enabled=$true;$clear.Enabled=$false;$duration.Enabled=$false
    foreach($row in $grid.Rows){$row.Cells['choose'].ReadOnly=$true}
    Write-PanelEvent $mode 'accepted' 'Selezione verificata; arresto observe e avvio della richiesta.'
}catch{
    if(!$script:batchActive -and $script:mode -notin @('recover','recover-test') -and !$script:restartMode -and !$script:pendingRecoveryMode){
        $start.Enabled=$true;$single.Enabled=$true;$pause.Enabled=$true;$clear.Enabled=$true;$duration.Enabled=$true;$stopButton.Enabled=$false
        foreach($row in $grid.Rows){$row.Cells['choose'].ReadOnly=[bool]$row.Tag.Blocked}
    }
    $state.Text=$_.Exception.Message;$result.Text='Richiesta non avviata.';Write-PanelEvent $mode 'rejected' $_.Exception.Message;Add-Log $_.Exception.Message
}}
function Request-Recovery([string]$requestedMode) {
    $ownsRefresh=$false
    try{
        if($script:comparison -and (Test-ComparisonBusy)){throw 'Confronto beneficio in corso: annullalo prima di avviare altre riduzioni.'}
        if($script:pendingBrowser){throw 'Scaricamento scheda o misura Chrome in corso: attendi la conclusione.'}
        Save-Selection
        Write-PanelEvent $requestedMode 'clicked'
        if($script:pendingRecoveryMode -or $script:batchActive -or $script:restartMode -or $script:mode -in @('recover','recover-test')){throw 'Recupero gia in corso. Premi Ferma e pausa prima di avviare una nuova richiesta.'}
        if(!$script:selection.Count){throw 'Spunta almeno un processo nella colonna Seleziona.'}
        if($requestedMode -eq 'recover-test' -and $script:selection.Count -gt 5){throw 'Seleziona al massimo 5 processi per la coda.'}
        if($script:engine -and $script:lastComplete -and ([DateTime]::UtcNow-$script:lastComplete).TotalSeconds -le 20){Begin-Recovery $requestedMode;return}
        $script:pendingRecoveryMode=$requestedMode;$script:pendingSelection=@($script:selection.Values);$script:pendingDeadline=[DateTime]::UtcNow.AddSeconds(20)
        $ownsRefresh=$true
        $script:progressTargets=@($script:pendingSelection);$script:liveMeasurements=@{}
        foreach($target in $script:progressTargets){Set-RecoveryTargetText $target 'AGGIORNO I DATI. Richiesta ricevuta; nessun intervento ancora eseguito.'}
        Refresh-RecoveryProgress
        if(!$script:engine){Start-Engine 'observe'}
        $single.Enabled=$false;$start.Enabled=$false;$pause.Enabled=$false;$clear.Enabled=$false;$stopButton.Enabled=$true
        $result.Text=$(if($requestedMode -eq 'recover-test'){'Prova a ridurre RAM: richiesta ricevuta.'}else{'Automatico con pressione: richiesta ricevuta.'})
        $state.Text='Aggiorno l elenco e verifico le identita selezionate. Nessun intervento ancora avviato.'
        Write-PanelEvent $requestedMode 'refreshing'
    }catch{
        $message=$_.Exception.Message
        if($ownsRefresh){Stop-RecoveryQueue;if($script:engine){$script:restartMode='paused';Request-Stop}else{Set-Paused}}
        $result.Text='Richiesta non avviata.';$state.Text=$message
        Write-PanelEvent $requestedMode 'rejected' $message;Add-Log $message
    }
}
function Complete-PendingRecovery {
    if(!$script:pendingRecoveryMode){return}
    if([DateTime]::UtcNow -ge $script:pendingDeadline){
        $requested=$script:pendingRecoveryMode;Stop-RecoveryQueue;$script:restartMode='paused';Request-Stop
        $result.Text='Richiesta annullata: elenco aggiornato non disponibile entro 20 secondi.'
        Write-PanelEvent $requested 'refresh_timeout';return
    }
    $requested=$script:pendingRecoveryMode;$fresh=@{}
    foreach($target in $script:pendingSelection){
        $match=@($grid.Rows|Where-Object {$_.Tag.Key -eq $target.Key -and $_.Tag.Path -eq $target.Path -and !$_.Tag.Blocked})
        if($match.Count -ne 1){
            $message='Un processo selezionato non e piu disponibile o gestibile. Aggiorna la selezione e riprova.'
            Stop-RecoveryQueue;$result.Text='Richiesta annullata: nessun recupero avviato.';$state.Text=$message
            $single.Enabled=$true;$start.Enabled=$true;$pause.Enabled=$true;$clear.Enabled=$true;$stopButton.Enabled=$false
            Write-PanelEvent $requested 'rejected' $message;return
        }
        $fresh[$target.Key]=$match[0].Tag
    }
    $script:pendingRecoveryMode=$null;$script:pendingSelection=@();$script:pendingDeadline=$null;$script:selection=$fresh
    Begin-Recovery $requested
}
$start.Add_Click({Request-Recovery 'recover'})
$single.Add_Click({Request-Recovery 'recover-test'})
$stopButton.Add_Click({Stop-RecoveryQueue;$script:restartMode='paused';$script:userStopping=$true;Request-Stop;$stopButton.Enabled=$false;$state.Text='Arresto richiesto. Coda annullata; attendo la chiusura del motore.'})
$pause.Add_Click({try{
    if(!$script:engine){Start-Engine 'observe'}else{$script:restartMode='paused';Request-Stop;$pause.Enabled=$false;$start.Enabled=$false;$single.Enabled=$false;$state.Text='Pausa richiesta: attendo l arresto del motore.'}
}catch{$state.Text=$_.Exception.Message;Add-Log $_.Exception.Message}})
$clear.Add_Click({$script:selection.Clear();foreach($row in $grid.Rows){$row.Cells['choose'].Value=$false}})
$reports.Add_Click({$path=Export-Diagnosis;if($path){Start-Process explorer.exe -ArgumentList ('/select,"'+$path+'"')}})
. (Join-Path $PSScriptRoot 'comparison-panel.ps1')
$timer=New-Object Windows.Forms.Timer; $timer.Interval=1000
$timer.Add_Tick({try{
    if($script:browserEnabled){try{Poll-Browser}catch{Set-BrowserConnectionStatus 'poll_failed' ('Aggiornamento Chrome fallito: '+$_.Exception.Message) 0 'error'}}
    if($script:comparison){Invoke-ComparisonTick}
    if(!$script:engine){return};Read-WindowsEvents
    if($script:pendingRecoveryMode -and [DateTime]::UtcNow -ge $script:pendingDeadline){
        $requested=$script:pendingRecoveryMode;Stop-RecoveryQueue;$script:restartMode='paused';Request-Stop
        $result.Text='Richiesta annullata: elenco aggiornato non disponibile entro 20 secondi.'
        Write-PanelEvent $requested 'refresh_timeout'
    }
    if($script:engine.HasExited){
        while($script:tail -and $script:tail.HasUnreadBytes){Read-WindowsEvents}
        $code=$script:engine.ExitCode; $errorText=$script:engine.StandardError.ReadToEnd()
        if($script:tail){$script:tail.Dispose();$script:tail=$null}
        $script:engine.Dispose();$script:engine=$null
        Remove-Item -LiteralPath $script:stopFile -Force -ErrorAction SilentlyContinue
        Add-Log ('Motore terminato: codice '+$code+'. '+$errorText)
        if($script:mode -in @('recover','recover-test')){
            if($script:batchActive -and $script:mode -eq 'recover-test'){$script:batchReports.Add($script:reportPath)}
            else{[void](Export-Diagnosis $script:reportPath)}
        }
        if($script:batchActive -and $script:mode -eq 'recover-test'){
            if(Finish-RecoveryProcess $code){return}
            [void](Export-Diagnosis $script:batchReports.ToArray())
        }
        if($script:restartMode -and $script:restartMode -ne 'paused' -and $code -eq 0){
            $nextMode=$script:restartMode;$script:restartMode=$null
            if($script:batchActive -and $nextMode -eq 'recover-test'){[void](Start-NextRecovery)}else{Start-Engine $nextMode}
        }
        else{Set-Paused;Add-Log 'Motore fermo. Raccolta in pausa; i risultati restano visibili.';if($code -ne 0){$state.Text='Errore motore: '+$errorText+' Raccolta in pausa.'}}
    }
}catch{
    $message=$_.Exception.Message;Stop-RecoveryQueue;Add-Log ('Errore: '+$message);$start.Enabled=$false
    if($script:engine){Request-Stop}else{Set-Paused;$result.Text='Recupero interrotto: avvio o lettura del motore non riusciti.'}
    $state.Text='Errore: '+$message
}})
$form.Add_FormClosing({if($script:comparison){Stop-Comparison 'Finestra chiusa prima della conclusione.'};Stop-RecoveryQueue;$script:closing=$true;$script:restartMode=$null;Request-Stop})
try {
    try{
        Import-StrategyReports (Join-Path $PSScriptRoot 'reports') $script:strategyPath
        $script:strategyRecords=@(Read-StrategyHistory $script:strategyPath)
    }catch{Add-Log ('Strategia: '+$_.Exception.Message);$script:historyFailure=$_.Exception.Message}
    Initialize-ReleaseSupport
    $script:apiConnection=Initialize-ResourceApi $PSScriptRoot
    $apiStatus.Text=$script:apiConnection.Message
    Add-Log $script:apiConnection.Message
    Write-PanelEvent 'resource_api' $(if($script:apiConnection.Ready){'ready'}else{'unavailable'}) $script:apiConnection.Message
    Start-Engine 'observe';$timer.Start();[void]$form.ShowDialog()}
finally{
    Release-ComparisonGuard
    $timer.Stop();$timer.Dispose();Request-Stop
    if($script:apiConnection -and $script:apiConnection.Client){$script:apiConnection.Client.Dispose()}
    if($script:bridge){$script:bridge.Dispose()}
    if($script:browserWriter){
        try{Write-BrowserEvent @{type='browser_end';feedback_complete=(!$script:pendingBrowser);confirmed=$script:browserConfirmed}}finally{$script:browserWriter.Dispose()}
    }
    if($script:engine -and $script:mode -in @('recover','recover-test')){
        if(!$script:engine.HasExited){[void]$script:engine.WaitForExit(5000)}
        $closingReports=@($script:reportPath)
        if($script:batchReports.Count){$closingReports+=@($script:batchReports.ToArray())}
        [void](Export-Diagnosis @($closingReports|Sort-Object -Unique))
    }
    if($script:tail){$script:tail.Dispose()};if($script:engine -and !$script:engine.HasExited){[void]$script:engine.WaitForExit(5000)}
    if($script:engine){$script:engine.Dispose()};$actionTip.Dispose();$form.Dispose();$script:hubMutex.Dispose()
}
