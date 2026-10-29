# Integrated into the ordinary Windows hub; no separate program to launch.
$comparisonTab=New-Object Windows.Forms.TabPage('Verifica beneficio')
[void]$script:hubTabs.TabPages.Add($comparisonTab)
$comparisonLayout=New-Object Windows.Forms.TableLayoutPanel
$comparisonLayout.Dock='Fill';$comparisonLayout.Padding=New-Object Windows.Forms.Padding(16);$comparisonLayout.ColumnCount=1;$comparisonLayout.RowCount=7
foreach($height in @(85,65,0,65,48,50,0)){
    $row=New-Object Windows.Forms.RowStyle
    if($height){$row.SizeType='Absolute';$row.Height=$height}else{$row.SizeType='Percent';$row.Height=50}
    [void]$comparisonLayout.RowStyles.Add($row)
}
$comparisonTab.Controls.Add($comparisonLayout)
$comparisonIntro=New-Object Windows.Forms.Label;$comparisonIntro.Dock='Fill'
$comparisonIntro.Text="Verifica se AME aggiunge un beneficio al risparmio memoria del browser.`r`n1. Collega Chrome o Firefox e scegli 1-5 schede ricaricabili. 2. Misura 15 min senza interventi.`r`n3. Conferma lo scaricamento e misura altri 15 min. Mantieni uguali app e attivita nelle due fasi.`r`nLe pagine si ricaricano al ritorno. Sono esclusi siti protetti, schede attive, private e con audio."
$comparisonLayout.Controls.Add($comparisonIntro,0,0)
$comparisonSetup=New-Object Windows.Forms.FlowLayoutPanel;$comparisonSetup.Dock='Fill';$comparisonSetup.WrapContents=$true
$comparisonProfile=New-Object Windows.Forms.ComboBox;$comparisonProfile.DropDownStyle='DropDownList';$comparisonProfile.Width=260;$comparisonProfile.DisplayMember='Display'
$comparisonRefresh=New-Object Windows.Forms.Button;$comparisonRefresh.Text='Aggiorna profili e schede';$comparisonRefresh.Size=New-Object Drawing.Size(220,30)
$comparisonWorkload=New-Object Windows.Forms.TextBox;$comparisonWorkload.Width=440;$comparisonWorkload.MaxLength=240
$comparisonWorkload.AccessibleName='Descrivi le attivita da ripetere nelle due fasi';$comparisonWorkload.Text=''
$comparisonWorkloadLabel=New-Object Windows.Forms.Label;$comparisonWorkloadLabel.Text='Attivita da ripetere:';$comparisonWorkloadLabel.AutoSize=$true;$comparisonWorkloadLabel.Padding=New-Object Windows.Forms.Padding(0,5,0,0)
$comparisonSetup.Controls.Add($comparisonProfile);$comparisonSetup.Controls.Add($comparisonRefresh);$comparisonSetup.Controls.Add($comparisonWorkloadLabel);$comparisonSetup.Controls.Add($comparisonWorkload)
$comparisonLayout.Controls.Add($comparisonSetup,0,1)
$comparisonChoices=New-Object Windows.Forms.CheckedListBox;$comparisonChoices.Dock='Fill';$comparisonChoices.CheckOnClick=$true;$comparisonChoices.DisplayMember='Display';$comparisonChoices.HorizontalScrollbar=$true
$comparisonLayout.Controls.Add($comparisonChoices,0,2)
$comparisonOptions=New-Object Windows.Forms.FlowLayoutPanel;$comparisonOptions.Dock='Fill';$comparisonOptions.FlowDirection='TopDown';$comparisonOptions.WrapContents=$false
$comparisonNative=New-Object Windows.Forms.CheckBox;$comparisonNative.AutoSize=$true;$comparisonNative.Text='Risparmio nativo attivo in Chrome / gestione nativa invariata in Firefox: confermo le impostazioni.'
$comparisonSacrificial=New-Object Windows.Forms.CheckBox;$comparisonSacrificial.AutoSize=$true;$comparisonSacrificial.Text='Le schede scelte sono ricaricabili, senza lavoro da salvare: autorizzo lo scaricamento solo nella fase 2.'
$comparisonOptions.Controls.Add($comparisonNative);$comparisonOptions.Controls.Add($comparisonSacrificial);$comparisonLayout.Controls.Add($comparisonOptions,0,3)
$comparisonButtons=New-Object Windows.Forms.FlowLayoutPanel;$comparisonButtons.Dock='Fill'
$comparisonBaselineButton=New-Object Windows.Forms.Button;$comparisonBaselineButton.Text='1. Misura senza interventi';$comparisonBaselineButton.Size=New-Object Drawing.Size(240,36)
$comparisonAmeButton=New-Object Windows.Forms.Button;$comparisonAmeButton.Text='2. Scarica e misura';$comparisonAmeButton.Size=New-Object Drawing.Size(195,36);$comparisonAmeButton.Enabled=$false
$comparisonCancelButton=New-Object Windows.Forms.Button;$comparisonCancelButton.Text='Annulla confronto';$comparisonCancelButton.Size=New-Object Drawing.Size(165,36);$comparisonCancelButton.Enabled=$false
$comparisonExportButton=New-Object Windows.Forms.Button;$comparisonExportButton.Text='Esporta confronto';$comparisonExportButton.Size=New-Object Drawing.Size(165,36);$comparisonExportButton.Enabled=$false
foreach($button in @($comparisonBaselineButton,$comparisonAmeButton,$comparisonCancelButton,$comparisonExportButton)){$comparisonButtons.Controls.Add($button)}
$comparisonLayout.Controls.Add($comparisonButtons,0,4)
$comparisonProgress=New-Object Windows.Forms.Label;$comparisonProgress.Dock='Fill';$comparisonProgress.Font=New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold)
$comparisonProgress.Text='Nessun confronto avviato. I 30 minuti servono a verificare la durata, non a eseguire il comando.';$comparisonLayout.Controls.Add($comparisonProgress,0,5)
$comparisonSummary=New-Object Windows.Forms.TextBox;$comparisonSummary.Dock='Fill';$comparisonSummary.Multiline=$true;$comparisonSummary.ReadOnly=$true;$comparisonSummary.ScrollBars='Vertical';$comparisonSummary.BackColor=[Drawing.Color]::White
$comparisonSummary.Text="Il confronto usa la RAM privata residente di tutti i processi del browser nella sessione Windows.`r`nIl costo RAM misurato di AME viene sottratto per intero. L'estensione e gia inclusa nelle misure del browser in entrambe le fasi.`r`nUn singolo confronto mostra variazioni osservate: non prova causalita o maggiore velocita. Per ChatGPT e Claude desktop non e integrato un rilascio interno."
$comparisonLayout.Controls.Add($comparisonSummary,0,6)
function Refresh-ComparisonChoices {
    if(Test-ComparisonBusy){return}
    $comparisonChoices.Items.Clear()
    $item=$comparisonProfile.SelectedItem
    if(!$item){return}
    $p=$script:profiles[$item.Connection]
    if(!$p){return}
    foreach($tab in @($p.Tabs)){
        $reason=if($tab.discarded){'Gia scaricata'}elseif($tab.blocked){[string]$tab.blocked}else{'Disponibile'}
        [void]$comparisonChoices.Items.Add([pscustomobject]@{Display=('['+$reason+'] '+$tab.title);Tab=$tab})
    }
}
function Refresh-ComparisonProfiles {
    if(Test-ComparisonBusy){return}
    $script:comparisonUiError=''
    $comparisonProfile.Items.Clear()
    foreach($id in @($script:profiles.Keys|Sort-Object)){
        $p=$script:profiles[$id]
        if($p.Ready -and ([DateTime]::UtcNow-$p.Seen).TotalSeconds -lt 25){[void]$comparisonProfile.Items.Add([pscustomobject]@{Display=($p.Browser+' - profilo collegato #'+$id);Connection=[int]$id})}
    }
    if($comparisonProfile.Items.Count){$comparisonProfile.SelectedIndex=0}
    else{$comparisonChoices.Items.Clear();$comparisonProgress.Text='Nessun profilo pronto. Collega AME in Rilascio nelle app, poi premi Aggiorna profili e schede.'}
}
function Update-ComparisonDisplay {
    if(!$comparisonProgress){return}
    $s=$script:comparison;$busy=Test-ComparisonBusy
    foreach($control in @($comparisonProfile,$comparisonRefresh,$comparisonWorkload,$comparisonChoices,$comparisonNative,$comparisonSacrificial)){$control.Enabled=!$busy}
    $comparisonBaselineButton.Enabled=!$busy;$comparisonAmeButton.Enabled=$s -and $s.Phase -eq 'ready'
    $comparisonCancelButton.Enabled=$busy;$comparisonExportButton.Enabled=$s -and [bool]$s.ReportPath
    if(!$s){return}
    $phase=if($s.Phase -eq 'baseline'){'Fase 1/2: nessun intervento AME'}elseif($s.Phase -eq 'ame'){'Fase 2/2: sola misura dopo gli scaricamenti'}else{''}
    if($phase){$left=[math]::Max(0,[math]::Ceiling(900-$s.LastElapsed));$comparisonProgress.Text=$phase+' | '+[TimeSpan]::FromSeconds($left).ToString('mm\:ss')+' rimanenti | '+$s.Applied+' scaricamenti confermati.'}
    else{$comparisonProgress.Text=$s.Status}
    $lines=@($s.Status)
    $a=$null;$b=$null
    if($s.Baseline.Count){$a=$s.Baseline[$s.Baseline.Count-1];$lines+=('Ultimo campione fase 1: browser {0:N1} MiB; AME {1:N1} MiB.' -f ($a.AppPrivateBytes/1MB),($a.OwnPrivateBytes/1MB))}
    if($s.Ame.Count){$b=$s.Ame[$s.Ame.Count-1];$lines+=('Ultimo campione fase 2: browser {0:N1} MiB; AME {1:N1} MiB.' -f ($b.AppPrivateBytes/1MB),($b.OwnPrivateBytes/1MB))}
    if($a -and $b){$lines+=('Differenza corrente con costo AME incluso: {0:+0.0;-0.0;0.0} MiB in meno (valore negativo = piu RAM).' -f (($a.AppPrivateBytes-$b.AppPrivateBytes-$b.OwnPrivateBytes)/1MB))}
    if($s.Outcome -and $s.Outcome.Complete){
        $o=$s.Outcome
        $lines+=('Mediane ultimi 5 min: browser {0:N1} -> {1:N1} MiB; costo AME {2:N1} MiB; differenza netta {3:+0.0;-0.0;0.0} MiB in meno.' -f ($o.BaselinePrivateBytes/1MB),($o.AmePrivateBytes/1MB),($o.AmeOverheadBytes/1MB),($o.NetObservedDropBytes/1MB))
        $lines+=('Riduzione minima osservata nei 15 min rispetto al minimo finale della fase 1, costo incluso: {0:+0.0;-0.0;0.0} MiB.' -f ($o.ConservativeDropBytes/1MB))
        $lines+=('Commit browser: {0:+0.0;-0.0;0.0} MiB in meno. RAM disponibile PC: {1:+0.0;-0.0;0.0} MiB di variazione, influenzata dalle altre app.' -f ($o.AppCommitDropBytes/1MB),($o.SystemAvailableDeltaBytes/1MB))
        foreach($metric in @(@('CpuDeltaPercentagePoints','CPU: differenza in punti percentuali'),@('FaultRateDelta','Page fault: differenza al secondo'),@('IoReadRateDelta','Letture I/O: differenza byte al secondo'))){
            $value=$o.PSObject.Properties[$metric[0]].Value
            $lines+=$metric[1]+': '+$(if($null -eq $value){'N/D: campioni confrontabili insufficienti'}else{'{0:+0.0;-0.0;0.0}' -f $value})
        }
        $lines+='Ora puoi riaprire le schede: registro il tempo fino al caricamento completato, quando segnalato dal browser. La prontezza dell app web non e misurata.'
    }
    foreach($load in $s.ReturnLoads){$lines+=('Riapertura osservata: {0:N0} ms. Nessun confronto con la latenza della fase 1.' -f $load.Milliseconds)}
    $lines+='CPU, picchi e page fault riguardano i campioni delle due fasi. I fault includono soft e hard; le letture I/O includono altre operazioni, non solo disco. Nessuna promessa di velocita.'
    $lines+='La configurazione nativa e dichiarata dall utente, non verificata automaticamente. Un solo confronto richiede ripetizione con le stesse attivita.'
    $comparisonSummary.Text=$lines -join "`r`n"
    if($script:comparisonUiError){$comparisonProgress.Text=$script:comparisonUiError}
}
$comparisonProfile.Add_SelectedIndexChanged({Refresh-ComparisonChoices})
$comparisonRefresh.Add_Click({Refresh-ComparisonProfiles})
$comparisonChoices.Add_ItemCheck({param($sender,$eventArgs)
    if($eventArgs.NewValue -eq [Windows.Forms.CheckState]::Checked){
        $tab=$comparisonChoices.Items[$eventArgs.Index].Tab
        if($tab.blocked -or $tab.discarded -or $comparisonChoices.CheckedItems.Count -ge 5){$eventArgs.NewValue=[Windows.Forms.CheckState]::Unchecked;$comparisonProgress.Text='Scegli al massimo 5 schede disponibili, senza protezioni e ancora caricate.'}
    }
})
$comparisonBaselineButton.Add_Click({try{
    if(!$comparisonProfile.SelectedItem){throw 'Collega un browser e premi Aggiorna profili e schede.'}
    if(!$comparisonSacrificial.Checked){throw 'Conferma che le schede sono ricaricabili e senza lavoro da salvare.'}
    $tabs=@($comparisonChoices.CheckedItems|ForEach-Object {$_.Tab})
    Start-ComparisonBaseline $comparisonProfile.SelectedItem.Connection $tabs $comparisonWorkload.Text $comparisonNative.Checked
}catch{$script:comparisonUiError=$_.Exception.Message;$comparisonProgress.Text=$script:comparisonUiError;if(Test-ComparisonBusy){Stop-Comparison $_.Exception.Message}}})
$comparisonAmeButton.Add_Click({try{$script:comparisonUiError='';Start-ComparisonAme $comparisonSacrificial.Checked}catch{$script:comparisonUiError=$_.Exception.Message;$comparisonProgress.Text=$script:comparisonUiError}})
$comparisonCancelButton.Add_Click({Stop-Comparison})
$comparisonExportButton.Add_Click({try{
    $paths=@($script:comparison.ReportPath)
    $export=& (Join-Path $PSScriptRoot 'export-diagnostics.ps1') -Report $paths
    Start-Process explorer.exe -ArgumentList ('/select,"'+$export.Path+'"')
}catch{$script:comparisonUiError='Esportazione non riuscita: '+$_.Exception.Message;$comparisonProgress.Text=$script:comparisonUiError}})
