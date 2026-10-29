param([string]$Report)
$ErrorActionPreference = 'Stop'
if (!$Report) {
    $latest = Get-ChildItem (Join-Path $PSScriptRoot 'reports') -Filter 'optimize-*.jsonl' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (!$latest) { throw 'Nessun report operativo trovato.' }
    $Report = $latest.FullName
}
$events = @(Get-Content -LiteralPath $Report | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
$applied = @($events | Where-Object { $_.type -eq 'priority_applied' })
$finished = @($events | Where-Object { $_.type -eq 'priority_finished' })
$feedback = @($events | Where-Object { $_.type -eq 'priority_feedback' })
Write-Host "Report: $Report"
Write-Host "Interventi applicati: $($applied.Count)"
Write-Host "Interventi terminati: $($finished.Count)"
if ($finished.Count) { $finished | Select-Object pid,reason,result_code | Format-Table -AutoSize }
if ($feedback.Count) {
    $feedback | Select-Object pid,@{n='WS_delta_MB';e={[math]::Round($_.working_set_delta_bytes/1MB,1)}},
        @{n='Available_delta_MB';e={[math]::Round($_.system_available_delta_bytes/1MB,1)}},page_faults_per_second | Format-Table -AutoSize
}
Write-Host 'Le variazioni in MB includono il lavoro delle applicazioni; non provano da sole il beneficio del controller.'
Write-Host 'Esiti: 0 ripristinato; 2 priorita cambiata dall app e rispettata; 3 errore; 4 processo uscito; 5 non applicato; 6 attesa scaduta.'
