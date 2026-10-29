param([ValidateRange(1,512)][int]$CacheMB = 128)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$sessions = Join-Path $PSScriptRoot 'sessions'
New-Item -ItemType Directory -Path $sessions -Force | Out-Null
$session = Join-Path $sessions ('session-' + [guid]::NewGuid().ToString('N'))
Write-Host 'Lascia aperta questa finestra. Copia il percorso della sessione per la seconda finestra:'
Write-Host $session
if (Get-Command py.exe -ErrorAction SilentlyContinue) {
    & py.exe -3 .\agents\demo_cache.py --session $session --cache-mb $CacheMB
} elseif (Get-Command python.exe -ErrorAction SilentlyContinue) {
    & python.exe .\agents\demo_cache.py --session $session --cache-mb $CacheMB
} else { throw 'Serve Python 3.10 o successivo nel PATH, oppure il launcher py.exe.' }
if ($LASTEXITCODE -ne 0) { throw 'Avvio agente fallito.' }
