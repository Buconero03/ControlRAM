param(
    [string]$TargetScript = 'start-agent.ps1'
)

$ErrorActionPreference = 'Stop'
$engineDir = $PSScriptRoot
$targetPath = Join-Path $engineDir $TargetScript

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    # Già in esecuzione come Amministratore, avvia direttamente lo script nel contesto corrente
    & $targetPath
} else {
    # Richiesta UAC ed avvio con elevazione in nuova console PowerShell
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = "-NoExit -NoProfile -STA -ExecutionPolicy Bypass -File `"$targetPath`""
    try {
        Start-Process -FilePath $psExe -ArgumentList $argList -WorkingDirectory $engineDir -Verb RunAs
    } catch {
        Write-Host ''
        Write-Host '[ControlRAM] Richiesta permessi di Amministratore (UAC) annullata o non concessa.' -ForegroundColor Yellow
        Write-Host 'Puoi comunque avviare il programma con doppio click su AUTOMATICO.cmd in modalita standard.' -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'Premi un tasto per chiudere...' -ForegroundColor Gray
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch {}
    }
}
