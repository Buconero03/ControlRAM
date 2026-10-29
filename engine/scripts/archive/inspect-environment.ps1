$ErrorActionPreference = 'Stop'
Write-Host '=== Stato memoria Windows (sola lettura) ==='
try {
    Get-MMAgent | Select-Object MemoryCompression, PageCombining | Format-List
} catch { Write-Host ('Get-MMAgent non disponibile/accessibile: ' + $_.Exception.Message) }
Write-Host '=== Configurazione WSL (file esistente, sola lettura) ==='
$config = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.wslconfig'
if (Test-Path $config) { Get-Content $config } else { Write-Host '.wslconfig non presente; WSL usa le impostazioni predefinite della versione installata.' }
Write-Host '=== Strumenti visibili nel PATH ==='
foreach ($name in @('cl.exe', 'g++.exe', 'cmake.exe', 'python.exe', 'py.exe')) {
    $tool = Get-Command $name -ErrorAction SilentlyContinue
    if ($tool) { Write-Host "$name : $($tool.Source)" } else { Write-Host "$name : non nel PATH (Visual Studio puo comunque essere rilevato da build.ps1)" }
}
