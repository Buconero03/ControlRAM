$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
& .\build.ps1
if (!(Test-Path '.\build\ame.exe')) { throw 'Build mancante.' }
$tempReport = Join-Path ([System.IO.Path]::GetTempPath()) ('ame-smoke-' + [guid]::NewGuid().ToString('N') + '.jsonl')
try {
    & .\build\ame.exe --observe --seconds 6 --report $tempReport
    if ($LASTEXITCODE -ne 0) { throw 'Windows smoke test fallito.' }
    $events = @(Get-Content $tempReport | ForEach-Object { $_ | ConvertFrom-Json })
    $samples = @($events | Where-Object { $_.type -eq 'sample' })
    if ($samples.Count -lt 2) { throw 'Campioni insufficienti.' }
    foreach ($s in $samples) {
        if ($s.physical_total_bytes -le 0 -or $s.physical_available_bytes -gt $s.physical_total_bytes -or $s.commit_limit_bytes -le 0) { throw 'Metriche sistema non valide.' }
        if (@($s.processes).Count -eq 0) { throw 'Lista processi vuota.' }
    }
    if (@($events | Where-Object { $_.type -in @('cooperative_release','priority_applied','recover_applied','recover_intent') }).Count) { throw 'Mutazione in observe.' }
    Write-Host 'PASS Windows telemetry + observe smoke test'
} finally { Remove-Item $tempReport -Force -ErrorAction SilentlyContinue }
& .\build\ame.exe --test-recovery
if ($LASTEXITCODE -ne 0) { throw 'Test recupero sul solo processo di test fallito.' }
& .\tests\test-recovery-options.ps1
& .\tests\test-windows-panel.ps1 -NativeEngine
& .\build\ame.exe --test-priority-lease
if ($LASTEXITCODE -ne 0) { throw 'Ripristino priorita Windows fallito.' }
if (Get-Command py.exe -ErrorAction SilentlyContinue) {
    & py.exe -3 .\tests\test_agent.py
} elseif (Get-Command python.exe -ErrorAction SilentlyContinue) {
    & python.exe .\tests\test_agent.py
} else { Write-Host 'Test agente Python non eseguiti: Python non disponibile.' }
if ($LASTEXITCODE -ne 0) { throw 'Test agente falliti.' }

& .\tests\test-hub-runtime.ps1
if (Get-Command node.exe -ErrorAction SilentlyContinue) {
    & node.exe --test .\tests\browser-tests.mjs .\tests\browser-popup-tests.mjs
    if ($LASTEXITCODE -ne 0) { throw 'Test estensione falliti.' }
} else { Write-Host 'Test JavaScript non eseguiti su questo PC: Node non disponibile.' }

$validation = @{ browser_revision='R19'; browser_host_validated = $false; browser_host_sha256 = (Get-FileHash '.\build\ame-browser-host.exe' -Algorithm SHA256).Hash; runtime_sha256 = (Get-FileHash '.\src\hub-runtime.cs' -Algorithm SHA256).Hash; exe_sha256 = (Get-FileHash '.\build\ame.exe' -Algorithm SHA256).Hash; tested_utc = [DateTime]::UtcNow.ToString('o'); version = '0.5.0' }
$validation.engine_revision='R10'
$validation.panel_revision='R22'
$validation.support_hashes=@{};foreach($component in @('strategy-model.ps1','browser-model.ps1','release-support.ps1','browser-panel.ps1','browser-connection.ps1','comparison-model.ps1','comparison-controller.ps1','comparison-panel.ps1','src/comparison-metrics.cs','export-diagnostics.ps1','process-reduction-api.ps1','agent.ps1','agent-state.ps1','agent-model.ps1','agent-runtime.ps1','start-agent.ps1','agent-control.ps1','agent-dashboard.ps1','browser/chrome/background.js','browser/chrome/policy.js','browser/chrome/popup.js','browser/chrome/popup.html','browser/chrome/manifest.json','browser/firefox/background.js','browser/firefox/policy.js','browser/firefox/popup.js','browser/firefox/popup.html','browser/firefox/manifest.json')){$validation.support_hashes[$component]=(Get-FileHash $component).Hash}
$validation.api_bridge_sha256=(Get-FileHash './resource-api-bridge.ps1').Hash
$validation.api_client_sha256=(Get-FileHash './src/resource-api-client.cs').Hash
$validation.hub_sha256=(Get-FileHash '.\hub.ps1' -Algorithm SHA256).Hash
$validation.model_sha256=(Get-FileHash '.\windows-model.ps1' -Algorithm SHA256).Hash
$validation.panel_tested_utc=[DateTime]::UtcNow.ToString('o')
$validation | ConvertTo-Json | Set-Content '.\build\windows-validation.json' -Encoding Ascii
Write-Host 'PASS controller validation. Avvio pannello: .\hub.ps1'
