$ErrorActionPreference='Stop'
Set-Location $PSScriptRoot
$marker=Join-Path $PSScriptRoot 'build\windows-validation.json'
if (!(Test-Path $marker)) { throw 'Esegui prima .\test-windows.ps1.' }
$validation=Get-Content $marker -Raw|ConvertFrom-Json
if($validation.browser_revision -ne 'R19'){throw 'Host precedente a Firefox: avvia AVVIA.cmd per compilare e verificare R19.'}
if ($validation.exe_sha256 -ne (Get-FileHash '.\build\ame.exe' -Algorithm SHA256).Hash) { throw 'Build cambiata: ripeti il test Windows.' }
& .\tests\test-hub-runtime.ps1 -Bridge
$validation|Add-Member -NotePropertyName browser_host_validated -NotePropertyValue $true -Force
$validation|Add-Member -NotePropertyName browser_host_sha256 -NotePropertyValue (Get-FileHash '.\build\ame-browser-host.exe' -Algorithm SHA256).Hash -Force
$validation|ConvertTo-Json|Set-Content $marker -Encoding Ascii
Write-Host 'PASS bridge opzionale. Installazione: .\install-chrome.ps1; pannello: .\hub-browser.ps1'
