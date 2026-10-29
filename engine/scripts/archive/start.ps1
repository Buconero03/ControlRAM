param(
    [ValidateRange(1, 86400)][int]$Seconds = 120,
    [switch]$Cooperative,
    [string]$Session
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (!(Test-Path '.\build\ame.exe')) { & .\build.ps1 }
if (!(Test-Path '.\build\ame.exe')) { throw 'ame.exe non disponibile.' }
$reports = Join-Path $PSScriptRoot 'reports'
New-Item -ItemType Directory -Path $reports -Force | Out-Null
$report = Join-Path $reports ('ame-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.jsonl')
$arguments = @('--seconds', "$Seconds", '--report', $report)
if ($Cooperative) {
    if (!$Session) { throw 'Indica -Session con la cartella generata da start-demo-agent.ps1.' }
    $arguments += '--cooperative'
} else { $arguments += '--observe' }
if ($Session) {
    $resolved = (Resolve-Path $Session).Path
    $descriptor = Get-Content (Join-Path $resolved 'agent.json') -Raw | ConvertFrom-Json
    if ($descriptor.version -ne 1 -or $descriptor.port -lt 1 -or $descriptor.port -gt 65535) { throw 'Descrittore agente non valido.' }
    $arguments += @('--agent-port', "$($descriptor.port)", '--token-file', (Join-Path $resolved 'token.txt'))
}
& .\build\ame.exe @arguments
if ($LASTEXITCODE -ne 0) { throw 'Il motore ha segnalato un errore.' }
Write-Host "Report: $report"
