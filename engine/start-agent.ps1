param([switch]$Quiet)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'agent-state.ps1')

function Show-AgentLiveConsole {
    Clear-Host
    Write-Host '==========================================================================' -ForegroundColor Cyan
    Write-Host '  AME v0.5.0 R22 - CONSOLE LOG IN TEMPO REALE (MOTORE AUTOMATICO ATTIVO)' -ForegroundColor Cyan
    Write-Host '==========================================================================' -ForegroundColor Cyan
    Write-Host '  * Cooperazione attiva con STATO_AUTOMATICO.cmd (stesso motore e bus IPC)' -ForegroundColor Gray
    Write-Host '  * Chiudendo questa finestra (o premendo Ctrl+C), AME si ferma e' -ForegroundColor Gray
    Write-Host '    RIPRISTINA TUTTI I PROCESSI alle impostazioni originali di Windows.' -ForegroundColor Gray
    Write-Host '==========================================================================' -ForegroundColor Cyan
    Write-Host ''
    [void](Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        try { [void](Request-AgentStop) } catch {}
    })
    $seenLines = New-Object 'System.Collections.Generic.HashSet[string]'
    $lastSummary = ''
    try {
        while ($true) {
            $s = Get-AgentLiveStatus
            if (!$s -or !$s.identity_alive) {
                Write-Host ('[' + (Get-Date -Format 'HH:mm:ss') + '] AGENTE FERMO: ' + $(if($s){$s.status}else{'non attivo'})) -ForegroundColor Yellow
                break
            }
            foreach ($line in @($s.recent)) {
                $text = [string]$line
                if ($text -and $seenLines.Add($text)) {
                    if ($text -like '*API interna*' -or $text -like '*Ripristino*') {
                        Write-Host ('  [AZIONE] ' + $text) -ForegroundColor Green
                    } else {
                        Write-Host ('  [EVENTO] ' + $text) -ForegroundColor White
                    }
                }
            }
            $ramPct = if ($s.pressure -and $null -ne $s.pressure.Percent) { '{0:N1}% ({1:N0} MiB disp.)' -f [double]$s.pressure.Percent, ([double]$s.pressure.AvailableBytes/1MB) } else { 'in lettura...' }
            $dist = $s.distributed
            $restCount = if ($dist -and $null -ne $dist.restored_processes) { $dist.restored_processes } else { 0 }
            $summary = ('PID: ' + $s.process_id + ' | RAM: ' + $ramPct + ' | Processi: ' + $s.process_count + ' | Interventi [Browser: ' + $dist.browser_subprocess_reclaims + ' | Windows: ' + $dist.windows_reclaims + ' | Ripristinati: ' + $restCount + ']')
            if ($summary -cne $lastSummary) {
                Write-Host ('[' + (Get-Date -Format 'HH:mm:ss') + '] STATO -> ' + $summary) -ForegroundColor DarkCyan
                $lastSummary = $summary
            }
            Start-Sleep -Seconds 2
        }
    } finally {
        Write-Host ''
        Write-Host 'Ripristino di tutti i processi alle impostazioni originali di Windows in corso...' -ForegroundColor Yellow
        [void](Request-AgentStop)
        Write-Host 'Ripristino completato: tutto e tornato come prima.' -ForegroundColor Green
    }
}

$run=[guid]::NewGuid().ToString('D')
try{
    $live=Get-AgentLiveStatus
    if($live -and $live.identity_alive){
        if(!$Quiet){
            Show-AgentLiveConsole
        }
        return
    }
    $existing=$null
    try{$existing=[Threading.Mutex]::OpenExisting('Local\AME-Process-Hub')}catch [Threading.WaitHandleCannotBeOpenedException]{}
    if($existing){$existing.Dispose();throw 'Un pannello o agente AME e gia attivo nella sessione Windows. Chiudilo prima di avviare AUTOMATICO.cmd.'}
    & (Join-Path $PSScriptRoot 'avvia.ps1') -ValidateOnly
    $v=Read-AgentJson (Join-Path $PSScriptRoot 'build/windows-validation.json')
    if(!$v.browser_host_validated -or $v.browser_host_sha256 -ne (Get-FileHash (Join-Path $PSScriptRoot 'build/ame-browser-host.exe')).Hash){& (Join-Path $PSScriptRoot 'test-browser-windows.ps1')}
    & (Join-Path $PSScriptRoot 'install-chrome.ps1') | Out-Null
    & (Join-Path $PSScriptRoot 'install-firefox.ps1') | Out-Null
    Assert-AgentValidated
    $worker=Join-Path $PSScriptRoot 'agent.ps1'
    if($worker.Contains('"')){throw 'Percorso agente non valido.'}
    $psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $cmdLine="`"$psExe`" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$worker`" -RunId $run"
    $startup=New-CimInstance -ClassName Win32_ProcessStartup -Property @{ShowWindow=[uint16]0} -ClientOnly
    $wmiRes=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$cmdLine;CurrentDirectory=$PSScriptRoot;ProcessStartupInformation=$startup}
    if($wmiRes.ReturnValue -ne 0){throw ('Avvio processo background non riuscito (codice WMI '+$wmiRes.ReturnValue+').')}
    $wait=[Diagnostics.Stopwatch]::StartNew()
    $startedOk=$false
    while($wait.Elapsed.TotalSeconds -lt 20){
        $status=Get-AgentLiveStatus
        if($status -and $status.run_id -ceq $run -and $status.identity_alive -and $status.phase -eq 'monitoring'){
            $startedOk=$true
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if(!$startedOk){
        $failure=Read-AgentJson (Join-Path (Get-AgentDirectory) 'startup-error.json') 4096
        if($failure -and $failure.run_id -ceq $run){throw [string]$failure.message}
        $status=Read-AgentJson (Join-Path (Get-AgentDirectory) 'status.json') 256KB
        if($status -and $status.run_id -ceq $run){throw ('Agente non pronto: '+$status.status)}
        throw 'Avvio non confermato entro 20 secondi. Apri STATO_AUTOMATICO.cmd prima di riprovare.'
    }
    if(!$Quiet){
        Show-AgentLiveConsole
    }
}catch{
    $startupMessage=$_.Exception.Message
    try{
        $directory=Get-AgentDirectory;[void][IO.Directory]::CreateDirectory($directory)
        Write-AgentJson (Join-Path $directory 'startup-error.json') @{run_id=$run;utc=[DateTime]::UtcNow.ToString('o');message=$startupMessage} 4096
    }catch{}
    throw
}
