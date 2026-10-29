$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'windows-model.ps1')
if (!('AmeHub.ReportTail' -as [type])) { Add-Type -Path (Join-Path $root 'src\hub-runtime.cs') }
function Assert($ok,[string]$message){if(!$ok){throw $message}}
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'hub.ps1'),[ref]$tokens,[ref]$errors)
foreach($progressFunction in @('Refresh-RecoveryProgress','Set-RecoveryTargetText','Show-RecoveryUpdate','Stop-RecoveryQueue')){
    $progressAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $progressFunction},$true)
    . ([scriptblock]::Create($progressAst.Extent.Text))
}
$script:queueStatus=[pscustomobject]@{Text=''};$script:progressTargets=@();$script:liveMeasurements=@{}

Assert (!$errors.Count) 'Pannello non analizzabile'
$fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-WindowsEvents'},$true)
Assert ($null -ne $fn) 'Lettore eventi Windows assente'
Set-Item Function:Read-WindowsEvents -Value $fn.Body.GetScriptBlock()
$script:messages=New-Object 'Collections.Generic.List[string]'
$script:snapshots=New-Object 'Collections.Generic.List[object]'
function Add-Log([string]$message){$script:messages.Add($message)}
function Show-Snapshot($sample){$script:snapshots.Add($sample)}
function Complete-PendingRecovery {}
$result=[pscustomobject]@{Text=''};$script:targetStates=@{}
function Show-TargetState($event){$script:targetStates[([string]$event.pid+':'+[string]$event.creation_filetime)]=Get-RecoveryTargetStatus $event}
$ram=[pscustomobject]@{Text=''}; $state=[pscustomobject]@{Text=''}
$script:trimmed=0; $script:lastReasons=''; $script:ends=[DateTime]::UtcNow.AddMinutes(5)
$script:reportPath=Join-Path ([IO.Path]::GetTempPath()) ('ame-windows-events-'+[guid]::NewGuid().ToString('N'))
$script:tail=$null
try {
    $events=@(
        @{type='sample';physical_total_bytes=8GB;physical_available_bytes=1GB;process_snapshot_complete=$true;processes=@(@{pid=123;creation_filetime='456'})},
        @{type='recover_target';pid=123;creation_filetime='456';reason='low_activity_under_60_seconds';low_activity_seconds=20;single_test=$true},
        @{type='recover_state';completed=2;feedback_pending=$true;foreground_known=$true;reasons=@{}},
        @{type='sample';physical_total_bytes=8GB;physical_available_bytes=1GB;process_snapshot_complete=$false;processes=@()},
        @{type='recover_feedback';pid=123;phase='60s';private_resident_delta_bytes=-32MB;private_commit_delta_bytes=0;system_available_delta_bytes=20MB;page_faults_per_second=3},
        @{type='recover_guard';pid=123;reason='foreground_return_stop_further_actions';win32_error=0},
        @{type='recover_state';completed=2;disabled=$true;disabled_reason='foreground_return_stop_further_actions';reasons=@{selected_process_no_longer_running=1}}
    )
    $lines=@($events|ForEach-Object {$_|ConvertTo-Json -Compress -Depth 5})
    [IO.File]::WriteAllText($script:reportPath,($lines -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
    Read-WindowsEvents
    Assert ($script:snapshots.Count -eq 1) 'Un campione parziale ha cancellato l inventario'
    Assert ($script:snapshots[0].processes[0].creation_filetime -eq '456') 'Identita inventario alterata'
    Assert ($script:trimmed -eq 2 -and $ram.Text -like '*Interventi: 2') 'Contatore interventi errato'
    Assert ($state.Text -like 'Nuovi interventi bloccati:*') 'Guardia non mostrata'
    Assert (@($script:messages|Where-Object {$_ -like '*RAM privata -32*Variazioni osservate.*'}).Count -eq 1) 'Segno del delta o descrizione delle misure errato'
    Assert (@($script:messages|Where-Object {$_ -like '*recover_guard*'}).Count -eq 1) 'Guardia persa nel registro'
    Assert ($script:targetStates['123:456'] -like '*20/60*') 'Attesa non associata alla identita selezionata'
    Assert ($result.Text -like '*primo piano*non conclusivo*') 'Esito della misura non visibile'
    Write-Host 'PASS actual Windows panel events, complete inventory, identity, signed feedback and guard status'
} finally {
    if($script:tail){$script:tail.Dispose();$script:tail=$null}
    Remove-Item -LiteralPath $script:reportPath -Force -ErrorAction SilentlyContinue
}
