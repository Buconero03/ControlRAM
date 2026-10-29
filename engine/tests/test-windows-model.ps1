$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'windows-model.ps1')
function Assert($ok,[string]$text){if(!$ok){throw $text}}
$base=@{pid=123;creation_filetime='456';name='app.exe';image_path='D:\Apps\app.exe';same_user=$true;session_id=1;critical=$false;memory_available=$true;working_set_bytes=256MB;private_working_set_bytes=200MB;private_commit_bytes=500MB;cpu_percent=0.01;low_activity_seconds=70;foreground_window_owner=$false}
function Row($changes){$values=$base.Clone();foreach($key in $changes.Keys){$values[$key]=$changes[$key]};return [pscustomobject]$values}
$samples=@((Row @{}),(Row @{pid=124;image_path='C:\Windows\system.exe'}),(Row @{pid=125;same_user=$false}),(Row @{pid=126;critical=$null}),(Row @{pid=127;private_working_set_bytes=$null}),(Row @{pid=128;session_id=2}),(Row @{pid=129;memory_available=$false}),(Row @{pid=130;working_set_bytes=3GB}),(Row @{pid=131;foreground_window_owner=$true}))
$rows=@(Get-WindowsRows ([pscustomobject]@{processes=$samples}) 'C:\Windows' 1)
Assert ($rows.Count -eq 9) 'Inventario incompleto'
Assert (!$rows[0].Blocked -and $rows[0].Key -eq '123:456') 'Identita selezionabile errata'
foreach($i in 1..7){Assert ([bool]$rows[$i].Blocked) 'Processo non gestibile selezionabile'}
Assert ($null -eq $rows[4].PrivateBytes) 'Memoria privata mancante trasformata in zero'
Assert ($null -eq $rows[6].CommitBytes) 'Commit mancante trasformato in zero'
Assert ($rows[8].State -like 'Primo piano*') 'Protezione foreground non mostrata'
foreach($creation in @($null,'0','bad')) {
    $unknown=@(Get-WindowsRows ([pscustomobject]@{processes=@((Row @{creation_filetime=$creation}))}) 'C:\Windows' 1)
    Assert ([bool]$unknown[0].Blocked) 'Identita non verificabile selezionabile'
}
Assert ((Get-RecoveryStatus ([pscustomobject]@{feedback_pending=$true})) -like 'Intervento applicato*') 'Stato feedback errato'
Assert ((Get-RecoveryStatus ([pscustomobject]@{disabled=$true;disabled_reason='faults'})) -like '*faults') 'Blocco non mostrato'
Assert ((Get-RecoveryStatus ([pscustomobject]@{completed=3;foreground_known=$true})) -like 'Raggiunto*') 'Limite sessione non mostrato'
Write-Host 'PASS Windows inventory identity, exclusions, missing metrics, foreground and controller states'
