$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'windows-model.ps1')
if(!('AmeHub.ReportTail' -as [type])){Add-Type -Path (Join-Path $root 'src\hub-runtime.cs')}
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Assert($ok,[string]$message){if(!$ok){throw $message}}
function Assert-ResourceApiTargets([object[]]$Targets) {}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ame-clicks-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
Copy-Item (Join-Path $root 'export-diagnostics.ps1') (Join-Path $temp 'export-diagnostics.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'hub.ps1'),[ref]$tokens,[ref]$errors)
foreach($progressFunction in @('Refresh-RecoveryProgress','Set-RecoveryTargetText','Show-RecoveryUpdate','Stop-RecoveryQueue')){
    $progressAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $progressFunction},$true)
    . ([scriptblock]::Create($progressAst.Extent.Text))
}
$script:queueStatus=[pscustomobject]@{Text=''};$script:progressTargets=@();$script:liveMeasurements=@{}

foreach($name in @('Request-Recovery','Complete-PendingRecovery','Begin-Recovery','Request-Stop','Stop-RecoveryQueue','Set-Paused','Start-NextRecovery','Finish-RecoveryProcess','Read-WindowsEvents','Show-TargetState','Write-PanelEvent','Export-Diagnosis')){
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Assert ($null -ne $fn) ('Funzione mancante: '+$name)
    $parsed=[Management.Automation.Language.Parser]::ParseInput($fn.Extent.Text,(Join-Path $temp 'hub.ps1'),[ref]$tokens,[ref]$errors)
    . $parsed.GetScriptBlock()
}
function Callback([string]$prefix){
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith($prefix)},$true)
    return $fn.Arguments[0].ScriptBlock.GetScriptBlock()
}
$manual=Callback '$single.Add_Click(';$automatic=Callback '$start.Add_Click(';$stop=Callback '$stopButton.Add_Click(';$tick=Callback '$timer.Add_Tick('
function Save-Selection {}
function Add-Log([string]$message){}
function Fake-Engine {
    $p=[pscustomobject]@{HasExited=$false;ExitCode=0;StandardError=[pscustomobject]@{}}
    $p.StandardError|Add-Member ScriptMethod ReadToEnd {return ''};$p|Add-Member ScriptMethod Dispose {}
    return $p
}
function Start-Engine([string]$mode){
    $script:starts.Add($mode);$script:engine=Fake-Engine;$script:mode=$mode;$script:trimmed=0
    $script:reportPath=Join-Path $temp ('run-'+[guid]::NewGuid().ToString('N')+'.jsonl');$script:stopFile=$script:reportPath+'.stop'
    $script:ends=[DateTime]::UtcNow.AddMinutes(3);[IO.File]::WriteAllText($script:reportPath,'')
}
function Show-Snapshot($sample){$script:lastComplete=[DateTime]::UtcNow}
function Reset-Fixture {
    if($script:tail){$script:tail.Dispose()};$script:tail=$null
    $script:starts=New-Object 'Collections.Generic.List[string]';$script:panelReport=Join-Path $temp ('panel-'+[guid]::NewGuid().ToString('N')+'.jsonl')
    $script:historyPath=Join-Path $temp ('history-'+[guid]::NewGuid().ToString('N')+'.json');$script:historyFailure=''
    $script:mode='paused';$script:engine=$null;$script:lastComplete=$null;$script:restartMode=$null
    $script:batchActive=$false;$script:batchQueue=@();$script:batchIndex=0;$script:pendingRecoveryMode=$null;$script:pendingSelection=@();$script:pendingDeadline=$null
    $script:selection=@{};$script:targetStates=@{};$script:userStopping=$false
    $target=[pscustomobject]@{Key='101:123';Pid=101;Name='app.exe';Path='D:\Apps\app.exe';PrivateBytes=256MB;Blocked=''}
    $script:selection[$target.Key]=$target
    $cells=@{};foreach($key in @('choose','state','idle','cpu','faults')){$cells[$key]=[pscustomobject]@{Value=$true;ReadOnly=$false;ToolTipText=''}}
    $script:grid=[pscustomobject]@{Rows=@([pscustomobject]@{Tag=$target;Cells=$cells})}
    foreach($button in @('start','single','stopButton','pause','clear','duration')){Set-Variable -Scope Script -Name $button -Value ([pscustomobject]@{Enabled=$true;Text=''})}
    $script:result=[pscustomobject]@{Text=''};$script:state=[pscustomobject]@{Text=''};$script:ram=[pscustomobject]@{Text=''}
}
function Fresh-Snapshot {
    $sample=@{type='sample';physical_total_bytes=8GB;physical_available_bytes=1GB;process_snapshot_complete=$true}
    [IO.File]::WriteAllText($script:reportPath,($sample|ConvertTo-Json -Compress)+"`n")
    Read-WindowsEvents
}
try{
    Reset-Fixture
    Set-Paused
    Assert ($single.Enabled) 'Pulsante manuale disabilitato in pausa'
    & $manual
    Assert ($script:starts.Count -eq 1 -and $script:starts[0] -eq 'observe' -and $script:pendingRecoveryMode -eq 'recover-test') 'Click manuale dalla pausa non aggiorna prima i dati'
    Assert ($result.Text -like '*richiesta ricevuta*' -and !$single.Enabled) 'Click senza risposta visibile o con doppio avvio abilitato'
    Fresh-Snapshot
    Assert ($script:batchActive -and $script:restartMode -eq 'recover-test' -and (Test-Path $script:stopFile)) 'Snapshot fresco non prepara il recupero manuale'
    $script:engine.HasExited=$true
    & $tick
    Assert ($script:starts.Count -eq 2 -and $script:starts[1] -eq 'recover-test' -and $script:runSelection.Count -eq 1 -and $script:runSelection[0].Key -eq '101:123') 'Click manuale avvia la modalita automatica o una identita diversa'
    $events=@(Get-Content $script:panelReport|ForEach-Object {$_|ConvertFrom-Json})
    Assert (@($events|Where-Object {$_.action -eq 'recover-test' -and $_.stage -eq 'clicked'}).Count -eq 1) 'Click non registrato'
    Assert (@($events|Where-Object {$_.stage -eq 'accepted'}).Count -eq 1) 'Avvio verificato non registrato'
    # Export must preserve the panel command log alongside the requested native report.
    [IO.File]::WriteAllText($script:reportPath,"{`"type`":`"end`"}`n")
    $zipPath=Export-Diagnosis $script:reportPath
    $zip=[IO.Compression.ZipFile]::OpenRead($zipPath)
    try{Assert (@($zip.Entries|Where-Object {$_.FullName -like '*panel-*'}).Count -eq 1) 'Diagnosi senza registro dei clic'}finally{$zip.Dispose()}
    # Read actual native negative outcome, then reject a new manual AND automatic request after reopening state.
    $outcome=@{type='recover_assessed';pid=101;creation_filetime='123';image_path='D:\Apps\app.exe';reason='rapid_resident_rebound';win32_error=0}
    [IO.File]::AppendAllText($script:reportPath,($outcome|ConvertTo-Json -Compress)+"`n")
    Read-WindowsEvents
    Assert ((Test-Path $script:historyPath) -and $script:cancelQueue -and $result.Text -like '*RAM quasi tutta tornata*') 'Esito negativo senza storico o messaggio visibile'
    $script:engine.HasExited=$true
    & $tick
    Assert ($script:mode -eq 'paused' -and !$script:batchActive) 'Ritorno RAM non ferma la coda'
    & $manual
    Fresh-Snapshot
    Assert (!$script:batchActive -and !$script:restartMode -and $result.Text -like '*non avviata*' -and $state.Text -like '*sconsigliato*') 'Richiesta manuale ignora esito negativo precedente'
    Assert ($single.Enabled -and $start.Enabled -and $pause.Enabled -and !$stopButton.Enabled) 'Rifiuto per storico lascia comandi inutilizzabili'
    & $automatic
    Assert ($script:mode -eq 'observe' -and !$script:restartMode -and $state.Text -like '*sconsigliato*') 'Richiesta automatica ignora esito negativo precedente'
    Reset-Fixture
    & $manual
    & $stop
    Fresh-Snapshot
    Assert (!$script:pendingRecoveryMode -and !$script:batchActive -and $script:starts.Count -eq 1) 'Stop durante aggiornamento ha lasciato avviare un recupero'
    Reset-Fixture
    & $manual
    $grid.Rows[0].Tag=[pscustomobject]@{Key='101:999';Path='D:\Other\app.exe';Blocked=''}
    Fresh-Snapshot
    Assert (!$script:batchActive -and !$script:pendingRecoveryMode -and $script:starts.Count -eq 1 -and $result.Text -like '*annullata*') 'PID riutilizzato ha ereditato il click'
    Reset-Fixture
    $script:selection=@{}
    & $manual
    Assert (!$script:starts.Count -and $state.Text -like '*Spunta almeno*' -and $result.Text -like '*non avviata*') 'Selezione vuota senza messaggio'
    Reset-Fixture
    & $automatic
    Fresh-Snapshot
    Assert ($script:restartMode -eq 'recover' -and !$script:batchActive) 'Pulsante automatico confuso con manuale'
    Reset-Fixture
    & $manual
    $script:pendingDeadline=[DateTime]::UtcNow.AddSeconds(-1)
    & $tick
    Assert (!$script:pendingRecoveryMode -and (Test-Path $script:stopFile) -and $result.Text -like '*20 secondi*') 'Attesa inventario non ha un limite visibile'
    Write-Host 'PASS actual button callbacks: manual from pause, refresh before mutation, exact identity, automatic routing, stop, timeout, visible rejections and command log export'
}finally{if($script:tail){$script:tail.Dispose()};if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}}
