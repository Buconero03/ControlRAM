param([switch]$ValidateOnly)
$ErrorActionPreference='Stop'
Set-Location -LiteralPath $PSScriptRoot
$exe=Join-Path $PSScriptRoot 'build\ame.exe'
$marker=Join-Path $PSScriptRoot 'build\windows-validation.json'
$valid=$false
if((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $marker)){
    try {
        $m=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json
        $valid=$m.browser_revision -eq 'R19' -and $m.engine_revision -eq 'R10' -and $m.version -eq '0.5.0' -and $m.exe_sha256 -eq (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -and $m.runtime_sha256 -eq (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'src\hub-runtime.cs') -Algorithm SHA256).Hash
    }catch{$valid=$false}
}
if(!$valid){Write-Host 'Prima apertura: compilo e verifico la versione 0.5. Chiudi prima i vecchi pannelli AME.';& (Join-Path $PSScriptRoot 'test-windows.ps1')}
else{
    $panelValid=$m.api_bridge_sha256 -eq (Get-FileHash (Join-Path $PSScriptRoot 'resource-api-bridge.ps1')).Hash -and $m.api_client_sha256 -eq (Get-FileHash (Join-Path $PSScriptRoot 'src/resource-api-client.cs')).Hash -and $m.panel_revision -eq 'R22' -and $m.hub_sha256 -eq (Get-FileHash (Join-Path $PSScriptRoot 'hub.ps1') -Algorithm SHA256).Hash -and $m.model_sha256 -eq (Get-FileHash (Join-Path $PSScriptRoot 'windows-model.ps1') -Algorithm SHA256).Hash
    foreach($component in @('strategy-model.ps1','browser-model.ps1','release-support.ps1','browser-panel.ps1','browser-connection.ps1','comparison-model.ps1','comparison-controller.ps1','comparison-panel.ps1','src/comparison-metrics.cs','export-diagnostics.ps1','process-reduction-api.ps1','agent.ps1','agent-state.ps1','agent-model.ps1','agent-runtime.ps1','start-agent.ps1','agent-control.ps1','agent-dashboard.ps1','browser/chrome/background.js','browser/chrome/policy.js','browser/chrome/popup.js','browser/chrome/popup.html','browser/chrome/manifest.json','browser/firefox/background.js','browser/firefox/policy.js','browser/firefox/popup.js','browser/firefox/popup.html','browser/firefox/manifest.json')){
        $panelValid=$panelValid -and $m.support_hashes.$component -eq (Get-FileHash (Join-Path $PSScriptRoot $component)).Hash
    }
    if(!$panelValid){
        Write-Host 'Build nativa gia validata. Verifico il pannello aggiornato, senza ricompilare.'
        & (Join-Path $PSScriptRoot 'tests\test-windows-panel.ps1') -NativeEngine
        $support=@{};foreach($component in @('strategy-model.ps1','browser-model.ps1','release-support.ps1','browser-panel.ps1','browser-connection.ps1','comparison-model.ps1','comparison-controller.ps1','comparison-panel.ps1','src/comparison-metrics.cs','export-diagnostics.ps1','process-reduction-api.ps1','agent.ps1','agent-state.ps1','agent-model.ps1','agent-runtime.ps1','start-agent.ps1','agent-control.ps1','agent-dashboard.ps1','browser/chrome/background.js','browser/chrome/policy.js','browser/chrome/popup.js','browser/chrome/popup.html','browser/chrome/manifest.json','browser/firefox/background.js','browser/firefox/policy.js','browser/firefox/popup.js','browser/firefox/popup.html','browser/firefox/manifest.json')){$support[$component]=(Get-FileHash (Join-Path $PSScriptRoot $component)).Hash}
        $m|Add-Member NoteProperty support_hashes $support -Force
        $m|Add-Member NoteProperty api_bridge_sha256 (Get-FileHash (Join-Path $PSScriptRoot 'resource-api-bridge.ps1')).Hash -Force
        $m|Add-Member NoteProperty api_client_sha256 (Get-FileHash (Join-Path $PSScriptRoot 'src/resource-api-client.cs')).Hash -Force
        $m|Add-Member NoteProperty panel_revision 'R22' -Force
        $m|Add-Member NoteProperty hub_sha256 (Get-FileHash (Join-Path $PSScriptRoot 'hub.ps1') -Algorithm SHA256).Hash -Force
        $m|Add-Member NoteProperty model_sha256 (Get-FileHash (Join-Path $PSScriptRoot 'windows-model.ps1') -Algorithm SHA256).Hash -Force
        $m|Add-Member NoteProperty panel_tested_utc ([DateTime]::UtcNow.ToString('o')) -Force
        $m|ConvertTo-Json|Set-Content -LiteralPath $marker -Encoding Ascii
    }
}
try{& (Join-Path $PSScriptRoot 'build-resource-api.ps1')}
catch{Write-Warning ('API non pronta: '+$_.Exception.Message+' Apro il pannello per il monitoraggio.')}
if(!$ValidateOnly){& (Join-Path $PSScriptRoot 'hub.ps1')}
