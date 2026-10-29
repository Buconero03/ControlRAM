param()
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core') {
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath
    return
}
if ([IntPtr]::Size -ne 8) { throw 'Usa PowerShell a 64 bit.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Avvia con powershell.exe -STA -File .\hub.ps1' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'src\hub-runtime.cs')
. (Join-Path $PSScriptRoot 'browser-connection.ps1')
Initialize-BrowserDiagnostics
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AmeHubMemory {
    [StructLayout(LayoutKind.Sequential)] public struct Status {
        public uint length, load;
        public ulong total, available, totalPageFile, availablePageFile, totalVirtual, availableVirtual, extended;
    }
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GlobalMemoryStatusEx(ref Status s);
    public static Status Read() {
        var s = new Status(); s.length = (uint)Marshal.SizeOf(typeof(Status));
        if (!GlobalMemoryStatusEx(ref s)) throw new System.ComponentModel.Win32Exception();
        return s;
    }
}
'@
$exe = Join-Path $PSScriptRoot 'build\ame.exe'
if (!(Test-Path -LiteralPath $exe)) { throw 'Esegui prima .\test-windows.ps1 per compilare e verificare il controller.' }
$marker = Join-Path $PSScriptRoot 'build\windows-validation.json'
if (!(Test-Path $marker)) { throw 'Esegui prima .\test-windows.ps1: il nuovo controller deve superare il test di ripristino su Windows.' }
$validation = Get-Content $marker -Raw | ConvertFrom-Json
if ($validation.exe_sha256 -ne (Get-FileHash $exe -Algorithm SHA256).Hash -or $validation.browser_host_sha256 -ne (Get-FileHash (Join-Path $PSScriptRoot 'build\ame-browser-host.exe') -Algorithm SHA256).Hash -or $validation.runtime_sha256 -ne (Get-FileHash (Join-Path $PSScriptRoot 'src\hub-runtime.cs') -Algorithm SHA256).Hash) { throw 'La build e cambiata: esegui .\test-windows.ps1 prima di usare il pannello.' }
if (!$validation.browser_host_validated) { throw 'Il browser e opzionale: esegui .\test-browser-windows.ps1 prima di aprire questo pannello.' }
$script:engineProcess = $null
$script:reportPath = $null
$script:stopPath = $null
$script:reportReader = $null
$script:partialLine = ''
$script:lastNative = 'Priorita attive: 0'
$script:appliedCount = 0
$script:finishedCount = 0

$form = New-Object Windows.Forms.Form
$form.Text = 'Advanced Memory Engine 0.4 - Browser opzionale'
$form.ClientSize = New-Object Drawing.Size(920,720)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI',10)
$form.MinimumSize = $form.Size
$ram = New-Object Windows.Forms.Label
$ram.Location = New-Object Drawing.Point(20,15)
$ram.Size = New-Object Drawing.Size(875,30)
$ram.Font = New-Object Drawing.Font('Segoe UI',14,[Drawing.FontStyle]::Bold)
$form.Controls.Add($ram)
$note = New-Object Windows.Forms.Label
$note.Location = New-Object Drawing.Point(20,55)
$note.Size = New-Object Drawing.Size(760,60)
$note.Text = "Seleziona le applicazioni da gestire. Il controller protegge l'app in primo piano.`r`nInterviene con RAM >= 80% per 15 s, su processi poco attivi da almeno 30 s.`r`nLe priorita originali vengono ripristinate; ogni intervento dura al massimo 120 s."
$form.Controls.Add($note)
$apps = New-Object Windows.Forms.CheckedListBox
$apps.Location = New-Object Drawing.Point(20,125)
$apps.Size = New-Object Drawing.Size(760,110)
$apps.CheckOnClick = $true
$apps.HorizontalScrollbar = $true
$paths = @()
foreach ($name in @('chrome','firefox','claude','Antigravity')) {
    foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
        try { if ($p.Path) { $paths += $p.Path } } catch { }
    }
}
foreach ($path in @($paths | Sort-Object -Unique)) { [void]$apps.Items.Add($path,$true) }
$form.Controls.Add($apps)
$observe = New-Object Windows.Forms.Button
$observe.Text = 'Osserva'
$observe.Location = New-Object Drawing.Point(20,250)
$observe.Size = New-Object Drawing.Size(120,36)
$form.Controls.Add($observe)
$optimize = New-Object Windows.Forms.Button
$optimize.Text = 'Avvia controller'
$optimize.Location = New-Object Drawing.Point(150,250)
$optimize.Size = New-Object Drawing.Size(160,36)
$form.Controls.Add($optimize)
$stopButton = New-Object Windows.Forms.Button
$stopButton.Text = 'Ferma e ripristina'
$stopButton.Location = New-Object Drawing.Point(320,250)
$stopButton.Size = New-Object Drawing.Size(160,36)
$stopButton.Enabled = $false
$form.Controls.Add($stopButton)
$reportsButton = New-Object Windows.Forms.Button
$reportsButton.Text = 'Apri report'
$reportsButton.Location = New-Object Drawing.Point(640,250)
$reportsButton.Size = New-Object Drawing.Size(140,36)
$form.Controls.Add($reportsButton)
$refresh = New-Object Windows.Forms.Button
$refresh.Text = 'Aggiorna app'
$refresh.Location = New-Object Drawing.Point(490,250)
$refresh.Size = New-Object Drawing.Size(140,36)
$form.Controls.Add($refresh)
$refresh.Add_Click({
    if ($script:engineProcess -and !$script:engineProcess.HasExited) { return }
    $apps.Items.Clear()
    $fresh = @()
    foreach ($name in @('chrome','firefox','claude','Antigravity')) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try { if ($p.Path) { $fresh += $p.Path } } catch { }
        }
    }
    foreach ($path in @($fresh | Sort-Object -Unique)) { [void]$apps.Items.Add($path,$true) }
})
$state = New-Object Windows.Forms.Label
$state.Location = New-Object Drawing.Point(20,300)
$state.Size = New-Object Drawing.Size(760,30)
$state.Text = 'Pronto. La selezione riguarda i percorsi mostrati.'
$form.Controls.Add($state)
$log = New-Object Windows.Forms.TextBox
$log.Location = New-Object Drawing.Point(20,475)
$log.Size = New-Object Drawing.Size(880,225)
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.Font = New-Object Drawing.Font('Consolas',9)
$form.Controls.Add($log)
$tabs = New-Object Windows.Forms.TabControl
$tabs.Location = New-Object Drawing.Point(20,60)
$tabs.Size = New-Object Drawing.Size(880,400)
$browserTab = New-Object Windows.Forms.TabPage('Schede Chrome')
$nativeTab = New-Object Windows.Forms.TabPage('Priorita memoria (facoltative)')
$tabs.TabPages.Add($browserTab); $tabs.TabPages.Add($nativeTab)
$form.Controls.Add($tabs)
foreach ($control in @($note,$apps,$observe,$optimize,$stopButton,$reportsButton,$refresh,$state)) {
    $nativeTab.Controls.Add($control); $control.Top -= 45
}
$note.Text = "Modulo facoltativo: cambia le priorita, senza eliminare cache interne.`r`nI tuoi report non dimostrano un risparmio significativo con questo modulo.`r`nOgni modifica dura al massimo 120 s e viene ripristinata."
$durationLabel = New-Object Windows.Forms.Label
$durationLabel.Text = 'Durata sessione (minuti):'; $durationLabel.Location = New-Object Drawing.Point(20,300)
$durationLabel.Size = New-Object Drawing.Size(210,25); $nativeTab.Controls.Add($durationLabel)
$durationBox = New-Object Windows.Forms.ComboBox
$durationBox.Location = New-Object Drawing.Point(235,297); $durationBox.Size = New-Object Drawing.Size(100,30)
$durationBox.DropDownStyle = 'DropDownList'; [void]$durationBox.Items.AddRange(@('5','15','60')); $durationBox.SelectedIndex=1
$nativeTab.Controls.Add($durationBox)

function Add-HubLog([string]$message) {
    $log.AppendText((Get-Date -Format 'HH:mm:ss') + '  ' + $message + "`r`n")
    if ($log.TextLength -gt 50000) { $log.Text = $log.Text.Substring($log.TextLength - 30000) }
}
function Start-HubEngine([bool]$operative) {
    if ($script:engineProcess -and !$script:engineProcess.HasExited) { return }
    $selected = @($apps.CheckedItems | ForEach-Object { [string]$_ })
    if ($operative -and !$selected.Count) { throw 'Seleziona almeno una applicazione aperta.' }
    $reports = Join-Path $PSScriptRoot 'reports'
    New-Item -ItemType Directory -Path $reports -Force | Out-Null
    $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $prefix = if ($operative) { 'optimize-' } else { 'observe-' }
    $script:reportPath = Join-Path $reports ($prefix + $id + '.jsonl')
    $script:stopPath = Join-Path $reports ($prefix + $id + '.stop')
    $duration = if ($operative) { ([int]$durationBox.SelectedItem * 60).ToString() } else { '120' }
    $script:runEnds = [DateTime]::UtcNow.AddSeconds([int]$duration)
    $script:operative = $operative
    $script:appliedCount=0; $script:finishedCount=0
    $arguments = @('--seconds',$duration,'--report',$script:reportPath,'--stop-file',$script:stopPath)
    if ($operative) {
        $arguments += '--optimize'
        foreach ($path in $selected) { $arguments += @('--allow-exe',$path) }
    } else { $arguments += '--observe' }
    # All arguments are file paths or fixed values; reject embedded quotes.
    $quoted = foreach ($arg in $arguments) {
        if ($arg.Contains('"') -or $arg.EndsWith('\')) { throw 'Argomento non valido.' }
        '"' + $arg + '"'
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = $quoted -join ' '
    $info.WorkingDirectory = $PSScriptRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $script:engineProcess = New-Object Diagnostics.Process
    $script:engineProcess.StartInfo = $info
    [void]$script:engineProcess.Start()
    $script:engineProcess.BeginOutputReadLine()
    $script:partialLine = ''
    $script:lastNative = "Priorita attive: 0 | Applicate: $script:appliedCount | Concluse: $script:finishedCount"
    $observe.Enabled = $false; $optimize.Enabled = $false; $apps.Enabled = $false; $refresh.Enabled = $false; $stopButton.Enabled = $true
    $state.Text = if ($operative) { 'Controller avviato. Attendo la prima telemetria.' } else { 'Osservazione attiva per 2 minuti.' }
    Add-HubLog $state.Text
    Add-HubLog ('Report: ' + $script:reportPath)
}
function Stop-HubEngine {
    if ($script:engineProcess -and !$script:engineProcess.HasExited) {
        [IO.File]::WriteAllText($script:stopPath,'stop')
        $state.Text = 'Arresto richiesto. Ripristino delle priorita in corso...'
        $stopButton.Enabled = $false
    }
}
$observe.Add_Click({ try { Start-HubEngine $false } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'AME') } })
$optimize.Add_Click({ try { Start-HubEngine $true } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'AME') } })
$stopButton.Add_Click({ try { Stop-HubEngine } catch { Add-HubLog $_.Exception.Message } })
$reportsButton.Add_Click({
    $reports = Join-Path $PSScriptRoot 'reports'
    New-Item -ItemType Directory -Path $reports -Force | Out-Null
    Start-Process explorer.exe -ArgumentList ('"' + $reports + '"')
})
function Read-HubReport {
    if (!$script:reportReader) { return }
    foreach ($line in $script:reportReader.ReadLines()) {
        if ($line -notmatch '^\s*\{\s*"type"\s*:\s*"(native_state|priority_[^"]+|end)"') { continue }
        $event = $line | ConvertFrom-Json
        if ($event.type -eq 'native_state') {
            $script:lastNative = "Priorita attive: $($event.active_leases) | Applicate: $script:appliedCount | Concluse: $script:finishedCount"
            $remaining = [math]::Max(0,[math]::Ceiling(($script:runEnds-[DateTime]::UtcNow).TotalMinutes))
            if ($event.disabled) { $state.Text = 'Nuovi interventi disabilitati dopo un errore. Consulta il report.' }
            elseif ($event.active_leases -gt 0) { $state.Text = "Priorita temporanee attive: $($event.active_leases). Sessione: circa $remaining minuti rimanenti." }
            elseif ($event.pressure) { $state.Text = "Pressione rilevata; attendo candidati idonei. Sessione: circa $remaining minuti rimanenti." }
            else { $state.Text = "In attesa di pressione persistente sulla memoria. Sessione: circa $remaining minuti rimanenti." }
        } elseif ($event.type -eq 'priority_feedback') {
            Add-HubLog ("PID {0}: variazione WS {1:N1} MiB; disponibile {2:N1} MiB (variazioni osservate)." -f $event.pid,($event.working_set_delta_bytes/1MB),($event.system_available_delta_bytes/1MB))
        } elseif ($event.type -ne 'end') {
            if ($event.type -eq 'priority_applied') { $script:appliedCount++ }
            if ($event.type -eq 'priority_finished') { $script:finishedCount++ }
            Add-HubLog ("$($event.type) PID $($event.pid): $($event.reason), esito $($event.result_code)")
        }
    }
}
. (Join-Path $PSScriptRoot 'browser-panel.ps1')
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        $memory = [AmeHubMemory]::Read()
        $ram.Text = 'RAM: {0:N1}%  |  Disponibile: {1:N0} MB  |  {2}' -f (100*(1-$memory.available/[double]$memory.total)),($memory.available/1MB),$script:lastNative
        Poll-Browser
        if (!$script:engineProcess) { return }
        if (!$script:reportReader -and (Test-Path -LiteralPath $script:reportPath)) {
            $script:reportReader = New-Object AmeHub.ReportTail($script:reportPath)
        }
        Read-HubReport
        if ($script:engineProcess.HasExited) {
            while ($script:reportReader -and $script:reportReader.HasUnreadBytes) { Read-HubReport }
            $errorText = $script:engineProcess.StandardError.ReadToEnd()
            Add-HubLog ("Controller terminato: codice $($script:engineProcess.ExitCode). " + $errorText)
            if ($script:engineProcess.ExitCode -ne 0) {
                $state.Text = 'Controller terminato con errore. Il motivo e nel registro qui sotto.'
            } else {
                $state.Text = 'Sessione terminata. Gli eventuali esiti del ripristino sono nel report.'
            }
            if ($script:reportReader) { $script:reportReader.Dispose(); $script:reportReader = $null }
            Remove-Item -LiteralPath $script:stopPath -Force -ErrorAction SilentlyContinue
            $script:engineProcess.Dispose(); $script:engineProcess = $null
            $observe.Enabled = $true; $optimize.Enabled = $true; $apps.Enabled = $true; $refresh.Enabled = $true; $stopButton.Enabled = $false
            $script:lastNative = "Controller terminato | Applicate: $script:appliedCount | Concluse: $script:finishedCount"
        }
    } catch { Add-HubLog $_.Exception.Message }
})
$form.Add_FormClosing({ try { Stop-HubEngine } catch { } })
$timer.Start()
try { [void]$form.ShowDialog() }
finally {
    $timer.Stop(); $timer.Dispose()
    if ($script:reportReader) { $script:reportReader.Dispose() }
    if ($script:bridge) { $script:bridge.Dispose() }
    if ($script:browserWriter) {
        try {
            $pending = $script:pendingBrowser
            Write-BrowserEvent @{type='browser_end';confirmed=$script:browserConfirmed;pending_request=$pending.Request;pending_outcome=$pending.Outcome;feedback_complete=(!$pending)}
        } finally { $script:browserWriter.Dispose() }
    }
    $form.Dispose()
}
