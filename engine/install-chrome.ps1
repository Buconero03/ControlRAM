param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Questo collegamento richiede Windows.' }
$config = Get-Content (Join-Path $PSScriptRoot 'browser\config.json') -Raw | ConvertFrom-Json
$key = 'Software\Google\Chrome\NativeMessagingHosts\' + $config.host
$target = Join-Path $PSScriptRoot 'build\chrome-native-host.json'
# Chrome checks the 32-bit view first: keep both views pointed to the same manifest.
foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,$view)
    try {
        if ($Uninstall) {
            $existing = $base.OpenSubKey($key)
            try { $owned = $existing -and ($existing.GetValue('') -eq $target) } finally { if ($existing) { $existing.Dispose() } }
            if ($owned) { $base.DeleteSubKey($key,$false) }
        } else {
            $exe = Join-Path $PSScriptRoot 'build\ame-browser-host.exe'
            if (!(Test-Path -LiteralPath $exe)) { throw 'Esegui prima .\test-windows.ps1.' }
            $manifest = @{ name=$config.host; description='AME 0.3 - Collegamento locale Chrome'; path=$exe; type='stdio'; allowed_origins=@('chrome-extension://' + $config.extension_id + '/') }
            [IO.File]::WriteAllText($target,($manifest | ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
            $entry = $base.CreateSubKey($key)
            try { $entry.SetValue('',$target,[Microsoft.Win32.RegistryValueKind]::String) } finally { $entry.Dispose() }
        }
    } finally { $base.Dispose() }
}
if ($Uninstall) { Write-Host 'Collegamento rimosso per questa installazione. Puoi rimuovere anche la estensione da Chrome.' }
else {
    Write-Host 'Collegamento Chrome installato per il tuo utente.'
    Write-Host 'In chrome://extensions: Modalita sviluppatore > Carica estensione non pacchettizzata.'
    Write-Host ('Seleziona: ' + (Join-Path $PSScriptRoot 'browser\chrome'))
    Write-Host ('ID previsto: ' + $config.extension_id)
    Write-Host 'Apri .\hub.ps1, poi la estensione AME e premi Collega alil pannello Windows.'
}
