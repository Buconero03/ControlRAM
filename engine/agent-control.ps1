param(
    [ValidateSet('Start','Stop','Restart','Status','EnableStartup','DisableStartup','Export','Clamp','Unclamp','SetMode')][string]$Action='Status',
    [string]$Process='',
    [int]$ThresholdMiB=1200,
    [ValidateSet('standard','multilane','clamp')][string]$Mode='clamp'
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'agent-state.ps1')
. (Join-Path $PSScriptRoot 'resource-api-bridge.ps1')
. (Join-Path $PSScriptRoot 'process-reduction-api.ps1')
switch($Action){
    'Start' {& (Join-Path $PSScriptRoot 'start-agent.ps1') -Quiet}
    'Stop' {
        if(Request-AgentStop){Write-Host 'Arresto richiesto all agente. Nessuna applicazione viene terminata.'}else{Write-Host 'Nessun agente attivo verificato in questa installazione.'}
    }
    'Restart' {
        try { [void](Request-AgentStop) } catch {}
        Start-Sleep -Seconds 2
        & (Join-Path $PSScriptRoot 'start-agent.ps1') -Quiet
        Write-Host 'Agente riavviato e memoria resettata.'
    }
    'SetMode' {
        $res = Invoke-AmeInternalApiCommand -Command @{command='set_mode';mode=$Mode;target_process=$Process;target_threshold_mib=$ThresholdMiB} -Root $PSScriptRoot
        if($res -and $res.ok){Write-Host ("Modalita impostata su "+$Mode.ToUpper()+" per "+$Process+" @ "+$ThresholdMiB+" MiB.")}
        else{Write-Host ("Errore impostazione modalita: "+$res.error)}
    }
    'Clamp' {
        if([string]::IsNullOrWhiteSpace($Process)){throw 'Specifica -Process "nomegioco.exe"'}
        $procClean = $Process.Replace('.exe','')
        $target = Get-Process -Name $procClean -ErrorAction SilentlyContinue | Select-Object -First 1
        if(!$target){
            Write-Host ("Processo "+$Process+" non attualmente in esecuzione. Configurato come target automatico della Modalita Clamp.");
            $res = Invoke-AmeInternalApiCommand -Command @{command='set_mode';mode='clamp';target_process=$Process;target_threshold_mib=$ThresholdMiB} -Root $PSScriptRoot
            return
        }
        $key = ($target.Id.ToString()+':'+$target.StartTime.ToFileTimeUtc().ToString())
        $res = Invoke-AmeInternalApiCommand -Command @{command='clamp_process';key=$key;path=$target.MainModule.FileName;name=$Process;target_mib=$ThresholdMiB} -Root $PSScriptRoot
        if($res -and $res.ok){Write-Host ("Processo "+$Process+" (PID "+$res.pid+") limitato con successo a "+$ThresholdMiB+" MiB (Mix Clamping + Compressione).")}
        else{Write-Host ("Errore clamping: "+$res.error)}
    }
    'Unclamp' {
        if([string]::IsNullOrWhiteSpace($Process)){throw 'Specifica -Process "nomegioco.exe"'}
        $procClean = $Process.Replace('.exe','')
        $target = Get-Process -Name $procClean -ErrorAction SilentlyContinue | Select-Object -First 1
        if($target){
            $key = ($target.Id.ToString()+':'+$target.StartTime.ToFileTimeUtc().ToString())
            $res = Invoke-AmeInternalApiCommand -Command @{command='unclamp_process';key=$key;path=$target.MainModule.FileName;name=$Process} -Root $PSScriptRoot
            Write-Host ("Clamping rimosso da "+$Process+".")
        }else{
            Write-Host ("Processo "+$Process+" non in esecuzione.")
        }
    }
    'Status' {
        $s=Get-AgentLiveStatus
        if(!$s){$failure=Read-AgentJson (Join-Path (Get-AgentDirectory) 'startup-error.json') 4096;Write-Host $(if($failure){'AVVIO NON RIUSCITO: '+$failure.message}else{'Agente non avviato. Usa AUTOMATICO.cmd.'});return}
        Write-Host $(if($s.identity_alive){if($s.responding){'AGENTE ATTIVO'}else{'AGENTE PRESENTE, RISPOSTA NON AGGIORNATA'}}else{'AGENTE FERMO'})
        Write-Host $s.status
        if($s.distributed -and $s.distributed.operation_mode){
            $cTarget = if($s.distributed.clamp_target_process){' | Target Clamping: '+$s.distributed.clamp_target_process+' (Soglia: '+$s.distributed.clamp_target_threshold_mib+' MiB)'}else{''}
            Write-Host ('Modalita Operativa: '+$s.distributed.operation_mode.ToUpper()+$cTarget)
        }
        if($s.last_result){Write-Host ('Ultimo risultato: '+$s.last_result.message)}
        Write-Host ('Processi nell ultimo inventario: '+$s.process_count+' | Scaricamenti confermati in questa apertura: '+$s.confirmed_discards)
        foreach($p in @($s.profiles)){Write-Host ($p.browser+': '+$(if($p.ready){'COLLEGATO'}else{'IN COLLEGAMENTO'})+' | Schede autorizzate: '+$p.authorized_tabs)}
    }
    'EnableStartup' {
        $startup=[Environment]::GetFolderPath('Startup');$shell=New-Object -ComObject WScript.Shell
        try{
            $shortcut=$shell.CreateShortcut((Join-Path $startup 'AME Automatico.lnk'))
            $path=Join-Path $PSScriptRoot 'start-agent.ps1';if($path.Contains('"')){throw 'Percorso non valido.'}
            $shortcut.TargetPath=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
            $shortcut.Arguments='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$path+'" -Quiet'
            $shortcut.WorkingDirectory=$PSScriptRoot;$shortcut.Description='Agente AME: soli siti autorizzati, con verifica del beneficio.';$shortcut.Save()
            Write-Host 'Avvio AME al prossimo accesso Windows abilitato per questo utente.'
        }finally{if($shortcut){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)};[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
    }
    'DisableStartup' {
        $path=Join-Path ([Environment]::GetFolderPath('Startup')) 'AME Automatico.lnk'
        if(Test-Path -LiteralPath $path){[IO.File]::Delete($path)}
        Write-Host 'Avvio AME all accesso disabilitato. Per fermare la sessione corrente usa FERMA_AUTOMATICO.cmd.'
    }
    'Export' {
        $folder=Get-AgentDirectory
        $files=@(Get-ChildItem -LiteralPath $folder -File -Filter '*.jsonl'|Where-Object {$_.Name -match '^(agent-events-[0-3]|inventory-[01])\.jsonl$'}|Sort-Object LastWriteTime -Descending|ForEach-Object {$_.FullName})
        if(!$files.Count){throw 'Nessun registro agente disponibile.'}
        $zip=& (Join-Path $PSScriptRoot 'export-diagnostics.ps1') -Report $files
        Write-Host ('Diagnosi agente: '+$zip.Path)
        return $zip
    }
}
