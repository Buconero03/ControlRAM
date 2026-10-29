param([Parameter(Mandatory=$true)][string]$Session)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$resolved = (Resolve-Path $Session).Path
if (Get-Command py.exe -ErrorAction SilentlyContinue) {
    & py.exe -3 .\agents\demo_reclaim.py --session $resolved
} elseif (Get-Command python.exe -ErrorAction SilentlyContinue) {
    & python.exe .\agents\demo_reclaim.py --session $resolved
} else { throw 'Serve Python 3.10 o successivo.' }
if ($LASTEXITCODE -ne 0) { throw 'Test recupero cooperativo fallito.' }
