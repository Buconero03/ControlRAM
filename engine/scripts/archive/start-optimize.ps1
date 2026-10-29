param(
    [ValidateRange(1,86400)][int]$Seconds = 3600,
    [string[]]$AppName = @('chrome','firefox','claude','Antigravity'),
    [string[]]$ExecutablePath = @()
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (!(Test-Path '.\build\ame.exe')) { & .\build.ps1 }
$paths = @($ExecutablePath | ForEach-Object {
    if (![IO.Path]::IsPathRooted($_)) { throw 'ExecutablePath richiede un percorso completo.' }
    [IO.Path]::GetFullPath($_)
})
foreach ($name in $AppName) {
    foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
        try { if ($p.Path) { $paths += $p.Path } } catch { }
    }
}
$paths = @($paths | Sort-Object -Unique)
if (!$paths.Count) { throw 'Nessuna applicazione selezionata aperta. Apri Chrome, Firefox, Claude o Antigravity, oppure indica -ExecutablePath.' }
Write-Host 'Applicazioni selezionate per questa sessione:'
$paths | ForEach-Object { Write-Host "  $_" }
Write-Host 'Soglia: RAM >= 80% per 15 secondi; solo processi in background stabili per 30 secondi.'
$reports = Join-Path $PSScriptRoot 'reports'
New-Item -ItemType Directory -Path $reports -Force | Out-Null
$report = Join-Path $reports ('optimize-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.jsonl')
$arguments = @('--optimize','--seconds',"$Seconds",'--report',$report)
foreach ($path in $paths) { $arguments += @('--allow-exe',$path) }
& .\build\ame.exe @arguments
if ($LASTEXITCODE -ne 0) { throw "Controller terminato con errore. Vedi $report" }
Write-Host "Report: $report"
