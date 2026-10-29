$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
function Assert($ok,[string]$message){if(!$ok){throw $message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ame panel upgrade '+[guid]::NewGuid().ToString('N'))
$previous=Get-Location
try{
    foreach($folder in @('build','src','tests','browser/chrome','browser/firefox')){[void][IO.Directory]::CreateDirectory((Join-Path $temp $folder))}
    Copy-Item -LiteralPath (Join-Path $root 'avvia.ps1') -Destination (Join-Path $temp 'avvia.ps1')
    $utf8=New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllText((Join-Path $temp 'build/ame.exe'),'validated engine fixture',$utf8)
    [IO.File]::WriteAllText((Join-Path $temp 'src/hub-runtime.cs'),'validated runtime fixture',$utf8)
    [IO.File]::WriteAllText((Join-Path $temp 'windows-model.ps1'),'model fixture',$utf8)
    [IO.File]::WriteAllText((Join-Path $temp 'hub.ps1'),'[IO.File]::AppendAllText((Join-Path $PSScriptRoot "opened.txt"),"opened`n")',$utf8)
    [IO.File]::WriteAllText((Join-Path $temp 'tests/test-windows-panel.ps1'),'param([switch]$NativeEngine); if(!$NativeEngine){throw "Native launch check missing"};[IO.File]::AppendAllText((Join-Path (Split-Path $PSScriptRoot -Parent) "panel-checks.txt"),"checked`n")',$utf8)
    [IO.File]::WriteAllText((Join-Path $temp 'test-windows.ps1'),'throw "Full rebuild unexpectedly requested"',$utf8)
    [IO.File]::WriteAllText((Join-Path $temp 'resource-api-bridge.ps1'),'bridge fixture',$utf8)
    [IO.File]::WriteAllText((Join-Path $temp 'src/resource-api-client.cs'),'client fixture',$utf8)
    [IO.File]::WriteAllText((Join-Path $temp 'build-resource-api.ps1'),'[IO.File]::AppendAllText((Join-Path $PSScriptRoot "api-prepared.txt"),"checked`n")',$utf8)
    foreach($component in @('strategy-model.ps1','browser-model.ps1','release-support.ps1','browser-panel.ps1','browser-connection.ps1','comparison-model.ps1','comparison-controller.ps1','comparison-panel.ps1','src/comparison-metrics.cs','export-diagnostics.ps1','process-reduction-api.ps1','agent.ps1','agent-state.ps1','agent-model.ps1','agent-runtime.ps1','start-agent.ps1','agent-control.ps1','agent-dashboard.ps1','browser/chrome/background.js','browser/chrome/policy.js','browser/chrome/popup.js','browser/chrome/popup.html','browser/chrome/manifest.json','browser/firefox/background.js','browser/firefox/policy.js','browser/firefox/popup.js','browser/firefox/popup.html','browser/firefox/manifest.json')){[IO.File]::WriteAllText((Join-Path $temp $component),'support fixture',$utf8)}
    $marker=Join-Path $temp 'build/windows-validation.json'
    $initial=@{engine_revision='R10';browser_revision='R19';version='0.5.0';exe_sha256=(Get-FileHash (Join-Path $temp 'build/ame.exe')).Hash;runtime_sha256=(Get-FileHash (Join-Path $temp 'src/hub-runtime.cs')).Hash;tested_utc='original-validation'}
    $initial|ConvertTo-Json|Set-Content -LiteralPath $marker -Encoding Ascii
    & (Join-Path $temp 'avvia.ps1')
    $m=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json
    Assert ($m.panel_revision -eq 'R22' -and $m.tested_utc -eq 'original-validation' -and $m.exe_sha256 -eq $initial.exe_sha256) 'Aggiornamento perde la validazione nativa'
    Assert ($m.hub_sha256 -eq (Get-FileHash (Join-Path $temp 'hub.ps1')).Hash -and $m.model_sha256 -eq (Get-FileHash (Join-Path $temp 'windows-model.ps1')).Hash) 'Hash pannello non validati'
    & (Join-Path $temp 'avvia.ps1')
    Assert (@(Get-Content (Join-Path $temp 'panel-checks.txt')).Count -eq 1) 'Pannello invariato riverificato inutilmente'
    [IO.File]::AppendAllText((Join-Path $temp 'windows-model.ps1'),"`n# changed")
    & (Join-Path $temp 'avvia.ps1')
    Assert (@(Get-Content (Join-Path $temp 'panel-checks.txt')).Count -eq 2) 'Modello cambiato non riverificato'
    Assert (@(Get-Content (Join-Path $temp 'api-prepared.txt')).Count -eq 3) 'API non preparata a ogni AVVIA'
    Assert ($m.api_client_sha256 -eq (Get-FileHash (Join-Path $temp 'src/resource-api-client.cs')).Hash) 'Client API non validato'
    $openedValidate=@(Get-Content (Join-Path $temp 'opened.txt')).Count
    & (Join-Path $temp 'avvia.ps1') -ValidateOnly
    Assert (@(Get-Content (Join-Path $temp 'opened.txt')).Count -eq $openedValidate) 'ValidateOnly apre una finestra del pannello'
    foreach($bridgeFile in @('resource-api-bridge.ps1','src/resource-api-client.cs','strategy-model.ps1')){
        [IO.File]::AppendAllText((Join-Path $temp $bridgeFile),"`nchanged")
        $checks=@(Get-Content (Join-Path $temp 'panel-checks.txt')).Count
        & (Join-Path $temp 'avvia.ps1')
        Assert (@(Get-Content (Join-Path $temp 'panel-checks.txt')).Count -eq ($checks+1)) 'Bridge API cambiato non riverificato'
    }
    [IO.File]::WriteAllText((Join-Path $temp 'build-resource-api.ps1'),'throw "Expected API preparation failure"',$utf8)
    $openedBefore=@(Get-Content (Join-Path $temp 'opened.txt')).Count
    $previousWarningPreference=$WarningPreference
    try{$WarningPreference='SilentlyContinue';& (Join-Path $temp 'avvia.ps1')}
    finally{$WarningPreference=$previousWarningPreference}
    Assert (@(Get-Content (Join-Path $temp 'opened.txt')).Count -eq ($openedBefore+1)) 'API indisponibile impedisce anche l apertura del monitoraggio'
    # A failing panel check must neither update the marker nor open the panel.
    [IO.File]::AppendAllText((Join-Path $temp 'hub.ps1'),"`n# changed")
    [IO.File]::WriteAllText((Join-Path $temp 'tests/test-windows-panel.ps1'),'throw "Expected panel failure"',$utf8)
    $before=[IO.File]::ReadAllText($marker);$opened=@(Get-Content (Join-Path $temp 'opened.txt')).Count
    $failed=$false
    try{& (Join-Path $temp 'avvia.ps1')}catch{$failed=$_.Exception.Message -eq 'Expected panel failure'}
    Assert ($failed -and [IO.File]::ReadAllText($marker) -ceq $before -and @(Get-Content (Join-Path $temp 'opened.txt')).Count -eq $opened) 'Test fallito ha validato o aperto il pannello'
    # Previous engines have identical fixture hashes but lack the R10 foreground fix.
    foreach($oldRevision in @('R6','R8')){
        $old=@{engine_revision=$oldRevision;version='0.5.0';exe_sha256=$initial.exe_sha256;runtime_sha256=$initial.runtime_sha256;panel_revision='R9'}
        $old|ConvertTo-Json|Set-Content -LiteralPath $marker -Encoding Ascii
        $oldText=[IO.File]::ReadAllText($marker);$failed=$false
        try{& (Join-Path $temp 'avvia.ps1')}catch{$failed=$_.Exception.Message -eq 'Full rebuild unexpectedly requested'}
        Assert ($failed -and [IO.File]::ReadAllText($marker) -ceq $oldText -and @(Get-Content (Join-Path $temp 'opened.txt')).Count -eq $opened) ('Motore '+$oldRevision+' ha ereditato la validazione R10')
    }
    $initial|ConvertTo-Json|Set-Content -LiteralPath $marker -Encoding Ascii
    [IO.File]::AppendAllText((Join-Path $temp 'build/ame.exe'),'changed')
    $failed=$false
    try{& (Join-Path $temp 'avvia.ps1')}catch{$failed=$_.Exception.Message -eq 'Full rebuild unexpectedly requested'}
    Assert ($failed -and @(Get-Content (Join-Path $temp 'opened.txt')).Count -eq $opened) 'Build cambiata ha riusato la validazione nativa'
    Write-Host 'PASS actual launcher upgrade: validated native build reuse, panel/model hashes, failed checks block launch, changed binary requires full validation'
}finally{Set-Location -LiteralPath $previous.Path;if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}}
