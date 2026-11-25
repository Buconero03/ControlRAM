param([switch]$Elevated)
$ErrorActionPreference = 'Continue'
$report = Join-Path $PSScriptRoot 'reports\servicing-diagnosi.txt'
[void][IO.Directory]::CreateDirectory((Split-Path $report))

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        Start-Process -FilePath $psExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated" -WorkingDirectory $PSScriptRoot -Verb RunAs
        Write-Host 'Richiesta UAC inviata: conferma la finestra per proseguire.'
    } catch {
        Write-Host 'UAC annullata: la diagnosi non e stata eseguita.' -ForegroundColor Yellow
    }
    return
}

function Log([string]$t) { $t | Tee-Object -FilePath $report -Append | Out-Host }
Set-Content -LiteralPath $report -Value ("Diagnosi servicing Windows - " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

Log "`n=== 1. Stato servizi e processi ==="
Get-Service TrustedInstaller, wuauserv, UsoSvc, DoSvc | ForEach-Object { Log ("{0}: {1} ({2})" -f $_.Name, $_.Status, $_.StartType) }
Get-Process TiWorker -ErrorAction SilentlyContinue | ForEach-Object { Log ("TiWorker PID {0} handle {1}" -f $_.Id, $_.HandleCount) }

Log "`n=== 2. Aggiornamenti in sospeso ==="
$pending = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending += 'CBS RebootPending' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending') { $pending += 'CBS PackagesPending' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending += 'WindowsUpdate RebootRequired' }
if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' ) {
    $pf = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pf) { $pending += 'PendingFileRenameOperations' }
}
if ($pending.Count) { Log ("In sospeso: " + ($pending -join ', ')) } else { Log 'Nessun segnale di riavvio/pacchetti in sospeso.' }

Log "`n=== 3. DISM /ScanHealth ==="
$scan = & DISM.exe /Online /Cleanup-Image /ScanHealth 2>&1 | Out-String
Log $scan

if ($scan -match 'repairable|riparabile') {
    Log "`n=== 4. DISM /RestoreHealth (puo richiedere 10-30 minuti) ==="
    Log (& DISM.exe /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-String)
} else {
    Log "`n=== 4. RestoreHealth non necessario (store non riparabile non segnalato) ==="
}

Log "`n=== 5. SFC /scannow (puo richiedere 10-20 minuti) ==="
Log ((& sfc.exe /scannow 2>&1 | Out-String) -replace "`0", '')

Log "`n=== 6. Ultimi errori in CBS.log ==="
$cbs = 'C:\Windows\Logs\CBS\CBS.log'
if (Test-Path $cbs) {
    $errs = Select-String -Path $cbs -Pattern '\bError\b|Failed|0x800|0x8007' -ErrorAction SilentlyContinue | Select-Object -Last 25
    if ($errs) { $errs | ForEach-Object { Log $_.Line } } else { Log 'Nessun errore recente trovato in CBS.log.' }
} else { Log 'CBS.log non trovato.' }

Log "`n=== 7. Ultimi eventi servicing (Event Log) ==="
Get-WinEvent -FilterHashtable @{LogName='Setup'; Level=1,2,3; StartTime=(Get-Date).AddDays(-3)} -MaxEvents 15 -ErrorAction SilentlyContinue |
    ForEach-Object { Log ("{0} [{1}] {2}" -f $_.TimeCreated, $_.Id, ($_.Message -split "`n")[0]) }

Log "`n=== FINE. Report salvato in: $report ==="
