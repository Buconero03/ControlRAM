$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'windows-model.ps1')
function Assert($ok,[string]$text){if(!$ok){throw $text}}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'hub.ps1'),[ref]$tokens,[ref]$errors)
foreach($progressFunction in @('Refresh-RecoveryProgress','Set-RecoveryTargetText','Show-RecoveryUpdate','Stop-RecoveryQueue')){
    $progressAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $progressFunction},$true)
    . ([scriptblock]::Create($progressAst.Extent.Text))
}
$script:queueStatus=[pscustomobject]@{Text=''};$script:progressTargets=@();$script:liveMeasurements=@{}

Assert (!$errors.Count) 'Parsing hub fallito'
foreach($name in @('Begin-Recovery','Request-Stop','Set-Paused','Show-TargetState','Stop-RecoveryQueue')){
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Assert ($null -ne $fn) ('Funzione mancante: '+$name)
    $definition=[Management.Automation.Language.Parser]::ParseInput($fn.Extent.Text,(Join-Path $root 'hub.ps1'),[ref]$tokens,[ref]$errors)
    . $definition.GetScriptBlock()
}
$script:messages=New-Object 'Collections.Generic.List[string]'
function Add-Log([string]$text){$script:messages.Add($text)}
function Write-PanelEvent {}
function Save-Selection {}
function Assert-ResourceApiTargets([object[]]$Targets) {}
$start=[pscustomobject]@{Enabled=$true};$single=[pscustomobject]@{Enabled=$true}
$stopButton=[pscustomobject]@{Enabled=$true};$pause=[pscustomobject]@{Enabled=$true;Text=''}
$clear=[pscustomobject]@{Enabled=$true};$duration=[pscustomobject]@{Enabled=$true}
$state=[pscustomobject]@{Text=''};$result=[pscustomobject]@{Text=''}
$cells=@{}
foreach($key in @('choose','state','idle','cpu','faults')){$cells[$key]=[pscustomobject]@{Value=$null;ReadOnly=$false;ToolTipText=''}}
$grid=[pscustomobject]@{Rows=@([pscustomobject]@{Tag=[pscustomobject]@{Key='123:456';Blocked=''};Cells=$cells})}
$script:engine=[pscustomobject]@{HasExited=$false}
$script:selection=@{'123:456'=[pscustomobject]@{Key='123:456';Path='D:\Apps\app.exe'};'124:789'=[pscustomobject]@{Key='124:789';Path='D:\Apps\app.exe'}}
$script:stopFile=Join-Path ([IO.Path]::GetTempPath()) ('ame-lifecycle-'+[guid]::NewGuid().ToString('N')+'.stop')
$script:lastComplete=[DateTime]::UtcNow;$script:restartMode=$null;$script:targetStates=@{}
$script:batchActive=$false;$script:mode='observe';$script:batchQueue=@()
try {
    $script:selection['125:1']=[pscustomobject]@{Key='125:1';Path='D:\Apps\app.exe'}
    $script:selection['126:1']=[pscustomobject]@{Key='126:1';Path='D:\Apps\app.exe'}
    $script:selection['127:1']=[pscustomobject]@{Key='127:1';Path='D:\Apps\app.exe'}
    $script:selection['128:1']=[pscustomobject]@{Key='128:1';Path='D:\Apps\app.exe'}
    Begin-Recovery 'recover-test'
    Assert (!(Test-Path $script:stopFile) -and !$script:restartMode) 'Una coda oltre cinque processi ha richiesto un intervento'
    Assert ($script:messages[-1] -like '*1 a 5 processi*') 'Errore selezione non visibile'
    $script:selection.Remove('125:1');$script:selection.Remove('126:1');$script:selection.Remove('127:1');$script:selection.Remove('128:1')
    $script:selection.Remove('124:789')
    Begin-Recovery 'recover-test'
    Assert ((Test-Path $script:stopFile) -and $script:restartMode -eq 'recover-test') 'Passaggio alla prova singola assente'
    Assert (!$single.Enabled -and !$start.Enabled -and !$pause.Enabled) 'Avvii ripetuti durante transizione'
    Show-TargetState ([pscustomobject]@{pid=123;creation_filetime='456';reason='low_activity_under_60_seconds';low_activity_seconds=22;single_test=$true;cpu_percent=0.03;page_faults_per_second=6})
    Assert ($cells.state.Value -like '*22/60*' -and $cells.faults.Value -like '6*') 'Stato della identita selezionata non aggiornato'
    Show-TargetState ([pscustomobject]@{pid=123;creation_filetime='999';reason='foreground_family';low_activity_seconds=0;single_test=$true})
    Assert ($cells.state.Value -like '*22/60*') 'PID riutilizzato ha alterato lo stato della vecchia identita'
    Set-Paused
    Assert ($script:mode -eq 'paused' -and !$script:lastComplete -and $start.Enabled -and $single.Enabled) 'Pausa non consente una richiesta con aggiornamento preventivo'
    Assert ($pause.Enabled -and $pause.Text -eq 'Riprendi monitoraggio') 'Ripresa monitoraggio non disponibile'
    Assert ((Get-RecoveryTargetStatus ([pscustomobject]@{reason='low_activity_under_60_seconds';low_activity_seconds=20;single_test=$false;pressure=$false})) -like '*20/60*pressione RAM*') 'Una condizione di attesa ha nascosto la pressione'
    Assert ((Get-RecoveryFeedbackStatus ([pscustomobject]@{phase='60s';private_resident_delta_bytes=32MB;system_available_delta_bytes=-10MB})) -like '*+32*-10*') 'Delta di ricrescita presentato come risparmio'
    Assert ((Get-RecoveryOutcomeStatus ([pscustomobject]@{reason='activity_or_fault_increase_stop_further_actions'})) -like '*non conclusivo*') 'Guardia presentata come beneficio'
    Assert ((Get-RecoveryStatus ([pscustomobject]@{single_test=$true;completed=0;feedback_pending=$false;foreground_known=$true})) -like '*Soglia RAM non richiesta*') 'La prova singola attende pressione'
    # Run the actual timer callback on a completed test; it must export and pause,
    # rather than start another observer or another recovery attempt.
    $tick=$ast.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith('$timer.Add_Tick(')},$true)
    Assert ($null -ne $tick) 'Timer callback mancante'
    $callback=$tick.Arguments[0].ScriptBlock.GetScriptBlock()
    function Read-WindowsEvents {}
    $script:startedModes=New-Object 'Collections.Generic.List[string]';$script:exported=0
    function Start-Engine([string]$mode){$script:startedModes.Add($mode)}
    function Export-Diagnosis([string]$report){$script:exported++;return $null}
    $script:engine=[pscustomobject]@{HasExited=$true;ExitCode=0;StandardError=[pscustomobject]@{}}
    $script:engine.StandardError|Add-Member ScriptMethod ReadToEnd {return ''}
    $script:engine|Add-Member ScriptMethod Dispose {}
    $script:tail=$null;$script:mode='recover-test';$script:restartMode=$null;$script:reportPath='recover-test-fixture.jsonl'
    & $callback
    Assert ($null -eq $script:engine -and $script:mode -eq 'paused' -and $script:exported -eq 1) 'Fine prova non ferma motore/esporta/pausa'
    Assert ($script:startedModes.Count -eq 0) 'Fine prova riavvia la raccolta o una mutazione'
    $created1=$false;$created2=$false
    $mutexName='AME-Test-Hub-'+[guid]::NewGuid().ToString('N')
    $m1=[Threading.Mutex]::new($false,$mutexName,[ref]$created1)
    $m2=[Threading.Mutex]::new($false,$mutexName,[ref]$created2)
    Assert ($created1 -and !$created2) 'Seconda istanza non individuata'
    $m2.Dispose();$m1.Dispose()
    $created3=$false;$m3=[Threading.Mutex]::new($false,$mutexName,[ref]$created3)
    Assert ($created3) 'Chiusura non libera il controllo istanza';$m3.Dispose()
    Write-Host 'PASS actual hub handlers: bounded selection, pause, identity reuse, per-process waits, signed outcome and mutex'
} finally {Remove-Item -LiteralPath $script:stopFile -Force -ErrorAction SilentlyContinue}
