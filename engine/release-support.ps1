# Integrated in the ordinary hub. The optional bridge is initialized only after
# its existing Windows checks; the extension never discards without a tab choice.
function Show-ReleaseSetup([string]$Message='') {
    $browserTab.Controls.Clear()
    $script:browserLabel=$null;$script:browserLogBox=$null
    $script:releaseHelp=New-Object Windows.Forms.Label;$script:releaseHelp.Dock='Top';$script:releaseHelp.Height=130;$script:releaseHelp.Padding=New-Object Windows.Forms.Padding(16)
    $script:releaseHelp.Text="Chrome e Firefox possono rilasciare il contenuto di schede inattive tramite le proprie API.`r`nLa scheda resta aperta e si ricarica quando la riusi. Non posso promettere una riduzione permanente.`r`n`r`n1. Premi Prepara collegamento. 2. Chrome: carica browser/chrome; Firefox: about:debugging, carica browser/firefox/manifest.json.`r`n3. Apri l'estensione AME e premi Collega. Poi scegli qui una scheda ricaricabile."
    if($Message){$script:releaseHelp.Text+="`r`n"+$Message;$script:releaseHelp.Height=175}
    $prepare=New-Object Windows.Forms.Button;$prepare.Text='Prepara collegamento browser';$prepare.Width=270;$prepare.Height=38;$prepare.Location=New-Object Drawing.Point(16,190)
    $browserTab.Controls.Add($prepare);$browserTab.Controls.Add($script:releaseHelp)
    $exportSetup=New-Object Windows.Forms.Button;$exportSetup.Text='Esporta diagnosi';$exportSetup.Size=New-Object Drawing.Size(180,38);$exportSetup.Location=New-Object Drawing.Point(300,190)
    $exportSetup.Add_Click({Export-BrowserDiagnosis});$browserTab.Controls.Add($exportSetup)
    $script:browserLogBox=New-Object Windows.Forms.TextBox;$browserLogBox.Multiline=$true;$browserLogBox.ReadOnly=$true;$browserLogBox.ScrollBars='Vertical';$browserLogBox.Dock='Bottom';$browserLogBox.Height=180
    $browserTab.Controls.Add($browserLogBox)
    Set-BrowserConnectionStatus 'setup_required' $(if($Message){$Message}else{'Collegamento browser da preparare. Premi Prepara collegamento.'})

    $prepare.Add_Click({param($sender,$eventArgs)
        $sender.Enabled=$false
        try{
            $script:releaseHelp.Text='Verifico il bridge locale e registro il collegamento per questo utente...';$script:releaseHelp.Refresh();Set-BrowserConnectionStatus 'setup_started' 'Verifica del componente Windows e registrazione in corso.'
            & (Join-Path $PSScriptRoot 'test-browser-windows.ps1')
            & (Join-Path $PSScriptRoot 'install-chrome.ps1')
            & (Join-Path $PSScriptRoot 'install-firefox.ps1')
            Initialize-ReleaseSupport
            if(!$script:browserEnabled){throw 'Bridge non disponibile: consulta il messaggio nel pannello.'}
            Start-Process explorer.exe -ArgumentList ('"'+(Join-Path $PSScriptRoot 'browser/chrome')+'"')
            Add-Log 'In Chrome apri chrome://extensions > Modalita sviluppatore > Carica estensione non pacchettizzata. Seleziona browser/chrome; apri AME e premi Collega.'
        }catch{$script:releaseHelp.Text='Collegamento non completato: '+$_.Exception.Message;$sender.Enabled=$true;Set-BrowserConnectionStatus 'setup_failed' $script:releaseHelp.Text 0 'error'}
    })
}
function Initialize-ReleaseSupport {
    if($script:browserEnabled){return}
    try{
        $marker=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'build/windows-validation.json') -Raw|ConvertFrom-Json
        $hostPath=Join-Path $PSScriptRoot 'build/ame-browser-host.exe'
        if($marker.browser_revision -ne 'R19' -or !$marker.browser_host_validated -or !(Test-Path -LiteralPath $hostPath) -or
           $marker.browser_host_sha256 -ne (Get-FileHash -LiteralPath $hostPath).Hash){Show-ReleaseSetup;return}
        $browserTab.Controls.Clear()
        . (Join-Path $PSScriptRoot 'browser-panel.ps1')
        $script:browserEnabled=$true
        Add-Log 'Rilascio schede Chrome e Firefox disponibile. Attendo il collegamento dell estensione; nessuna azione automatica.'
    }catch{
        if($script:bridge){$script:bridge.Dispose();$script:bridge=$null}
        $script:browserEnabled=$false;Show-ReleaseSetup $_.Exception.Message
    }
}
function Request-Strategy {
    try{
        if($script:comparison -and (Test-ComparisonBusy)){throw 'Confronto beneficio in corso: annullalo prima di avviare altre richieste.'}
        if($script:batchActive -or $script:pendingRecoveryMode -or $script:restartMode -or $script:mode -in @('recover','recover-test') -or $script:pendingBrowser){throw 'Un intervento e gia in corso: attendi il risultato oppure ferma la prova corrente.'}
        Save-Selection
        if(!$script:selection.Count){throw 'Spunta da 1 a 5 processi da valutare.'}
        if($script:selection.Count -gt 5){throw 'Scegli al massimo 5 processi.'}
        Assert-ResourceApiTargets @($script:selection.Values)
        $script:strategyRecords=@(Read-StrategyHistory $script:strategyPath)
        $lines=@();$chrome=$false
        foreach($target in @($script:selection.Values|Sort-Object @{Expression={$_.PrivateBytes};Descending=$true})){
            $advice=Get-StrategyAdvice $target $script:strategyRecords
            $lines+=@($target.Name+' (PID '+$target.Pid+'): '+$advice.Method+'. '+$advice.Explanation)
            if($advice.CanReleaseTabs){$chrome=$true}
        }
        $script:queueStatus.Text=$lines -join "`r`n"
        $script:result.Text='Strategia pronta. Nessuna riduzione ancora eseguita.'
        $script:state.Text=if($chrome){'Apri Rilascio nelle app e scegli una scheda inattiva del browser interessato. La scelta riguarda la scheda; non conosco i MB del singolo PID renderer.'}else{'Per queste app non e integrata una API di rilascio interno. La Prova temporanea rimane un esperimento sul working set, con beneficio da verificare.'}
        Write-PanelEvent 'strategy' 'planned' ($lines -join ' | ')
        if($chrome){$script:hubTabs.SelectedTab=$script:releaseTab}
    }catch{$script:result.Text='Strategia non avviata.';$script:state.Text=$_.Exception.Message;Write-PanelEvent 'strategy' 'rejected' $_.Exception.Message}
}
