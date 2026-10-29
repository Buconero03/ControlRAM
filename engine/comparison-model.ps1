# Observational paired comparison. No process or browser mutations in this model.
function Test-ComparisonBusy {
    return ($script:comparison -and $script:comparison.Phase -in @('baseline','ready','applying','ame'))
}
function Get-ComparisonInventoryKey($Profile) {
    return (@($Profile.Tabs | Sort-Object id | ForEach-Object { [string]$_.id+':'+[string]$_.revision }) -join '|')
}
function New-ComparisonSession($Profile,[int]$Connection,[object[]]$Tabs,[string]$Workload) {
    if($Profile.Browser -notin @('Chrome','Firefox') -or !$Profile.Ready){throw 'Collega prima un profilo Chrome o Firefox.'}
    if($Tabs.Count -lt 1 -or $Tabs.Count -gt 5){throw 'Scegli da 1 a 5 schede ricaricabili.'}
    if([string]::IsNullOrWhiteSpace($Workload) -or $Workload.Length -gt 240){throw 'Descrivi brevemente le attivita da mantenere uguali nelle due fasi (massimo 240 caratteri).'}
    $ids=@{}
    foreach($tab in $Tabs){
        $match=@($Profile.Tabs|Where-Object {$_.id -eq $tab.id -and $_.revision -ceq $tab.revision})
        if($match.Count -ne 1 -or $tab.blocked -or $tab.discarded -or $match[0].blocked -or $match[0].discarded -or $ids.ContainsKey([long]$tab.id)){throw 'La selezione contiene schede protette, gia scaricate, duplicate o cambiate. Aggiorna.'}
        $ids[[long]$tab.id]=$true
    }
    return @{
        Id=[guid]::NewGuid().ToString('D');Phase='baseline';Browser=[string]$Profile.Browser;Connection=$Connection;Session=[string]$Profile.Session
        Tabs=@($Tabs|ForEach-Object {@{id=[long]$_.id;revision=[string]$_.revision;title=[string]$_.title}})
        InventoryKey=(Get-ComparisonInventoryKey $Profile);Workload=$Workload;NativeSaverUserConfirmed=$true;NativeSaverVerified=$false
        DurationSeconds=900;IntervalSeconds=5;MaxGapSeconds=12;ThresholdBytes=500MB
        Baseline=(New-Object 'Collections.Generic.List[object]');Ame=(New-Object 'Collections.Generic.List[object]')
        LastSeconds=$null;LastReadAt=$null;LastSampleUtc=$null;PhaseStarted=0.0;LastElapsed=0.0;Requests=@{};Queue=@();Applied=0;Skipped=0
        Returned=$false;ReturnLoads=(New-Object 'Collections.Generic.List[object]');ReportPath=$null;ReportBytes=0L
        Outcome=$null;Failure='';EndWritten=$false;Status='Fase 1/2: misuro il browser senza interventi AME. Nessuna scheda viene scaricata da AME.'
    }
}
function Add-ComparisonSample($Session,$Sample,[double]$Seconds) {
    if($Session.Phase -notin @('baseline','ame')){throw 'Nessuna fase di misura attiva.'}
    foreach($field in @('AppPrivateBytes','AppCommitBytes','OwnPrivateBytes','AvailableBytes','TotalBytes')){
        if($null -eq $Sample.$field -or [double]::IsNaN([double]$Sample.$field) -or [double]::IsInfinity([double]$Sample.$field) -or [double]$Sample.$field -lt 0){throw ('Metrica mancante o non valida: '+$field)}
    }
    if($Sample.TotalBytes -le 0 -or $Sample.AvailableBytes -gt $Sample.TotalBytes -or $Sample.AppProcesses -lt 1 -or !$Sample.Complete){throw 'Lettura incompleta della memoria o browser non piu presente.'}
    if([string]::IsNullOrWhiteSpace([string]$Sample.IdentityKey)){throw 'Identita dei processi non disponibile.'}
    if([double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds) -or $Seconds -lt 0 -or
       ($null -ne $Session.LastSeconds -and ($Seconds -le $Session.LastSeconds -or $Seconds-$Session.LastSeconds -gt $Session.MaxGapSeconds))){throw 'Misura interrotta: campioni mancanti, sospensione del PC o tempo non valido.'}
    $list=$Session.Baseline
    if($Session.Phase -eq 'ame'){$list=$Session.Ame}
    if($list.Count -ge 220){throw 'Limite dei campioni del confronto raggiunto.'}
    $row=[pscustomobject]@{
        Seconds=$Seconds;AppPrivateBytes=[double]$Sample.AppPrivateBytes;AppCommitBytes=[double]$Sample.AppCommitBytes
        OwnPrivateBytes=[double]$Sample.OwnPrivateBytes;AvailableBytes=[double]$Sample.AvailableBytes;TotalBytes=[double]$Sample.TotalBytes
        AppProcesses=[int]$Sample.AppProcesses;IdentityKey=[string]$Sample.IdentityKey
        CpuPercent=$Sample.CpuPercent;PageFaultsPerSecond=$Sample.PageFaultsPerSecond;IoReadBytesPerSecond=$Sample.IoReadBytesPerSecond
        CounterCoverageComplete=[bool]$Sample.CounterCoverageComplete
    }
    $list.Add($row);$Session.LastSeconds=$Seconds;$Session.LastElapsed=$Seconds
    if($Seconds -ge $Session.DurationSeconds){
        if($Session.Phase -eq 'baseline'){$Session.Phase='ready';$Session.Status='Fase 1 conclusa. Nessun intervento AME. Premi Avvia fase 2 per scaricare le sole schede ancora idonee.'}
        else{$Session.Phase='done';$Session.Outcome=Get-ComparisonAssessment $Session;$Session.Status=$Session.Outcome.Status}
    }
    return $row
}
function Get-ComparisonMedian([object[]]$Values) {
    if(!$Values.Count){return $null}
    $sorted=@($Values|Sort-Object);$n=$sorted.Count
    if($n%2){return [double]$sorted[[int][math]::Floor($n/2)]}
    return ([double]$sorted[$n/2-1]+[double]$sorted[$n/2])/2
}
function Get-ComparisonAssessment($Session) {
    $result=[ordered]@{
        Code='incomplete';Status='Confronto incompleto: nessun beneficio duraturo dichiarato.';Complete=$false;Applied=$Session.Applied
        BaselinePrivateBytes=$null;AmePrivateBytes=$null;AmeOverheadBytes=$null;NetObservedDropBytes=$null;ConservativeDropBytes=$null
        AppCommitDropBytes=$null;SystemAvailableDeltaBytes=$null;CpuDeltaPercentagePoints=$null;FaultRateDelta=$null;IoReadRateDelta=$null
        BaselinePeakCpu=$null;AmePeakCpu=$null;BaselinePeakFaults=$null;AmePeakFaults=$null;BaselinePeakIoReads=$null;AmePeakIoReads=$null
        ProcessChanges=$false;CostWarning=$false;CausationEstablished=$false;HardFaultsMeasured=$false;ApplicationLatencyMeasured=$false;CanRecommendAutomaticOptimization=$false
        DurationSeconds=$Session.DurationSeconds;ThresholdBytes=$Session.ThresholdBytes;NativeSaverVerified=$false;ComparisonCount=1
    }
    if($Session.Failure){$result.Status+=' '+$Session.Failure;return [pscustomobject]$result}
    $a=@($Session.Baseline.ToArray());$b=@($Session.Ame.ToArray())
    foreach($series in @(@{Rows=$a},@{Rows=$b})){
        $rows=$series.Rows
        if($rows.Count -lt 150 -or $rows[0].Seconds -gt 6 -or $rows[-1].Seconds -lt 900 -or $Session.DurationSeconds -lt 900){return [pscustomobject]$result}
        for($i=1;$i -lt $rows.Count;$i++){if($rows[$i].Seconds-$rows[$i-1].Seconds -gt 12 -or $rows[$i].Seconds -le $rows[$i-1].Seconds){return [pscustomobject]$result}}
    }
    if($Session.Returned -or $Session.Applied -lt 1){return [pscustomobject]$result}
    $lateA=@($a|Where-Object {$_.Seconds -ge ($Session.DurationSeconds-300)})
    $lateB=@($b|Where-Object {$_.Seconds -ge ($Session.DurationSeconds-300)})
    if($lateA.Count -lt 45 -or $lateB.Count -lt 45){return [pscustomobject]$result}
    $result.Complete=$true
    $result.BaselinePrivateBytes=Get-ComparisonMedian @($lateA.AppPrivateBytes)
    $result.AmePrivateBytes=Get-ComparisonMedian @($lateB.AppPrivateBytes)
    # Charge the full measured AME resident overhead, even though the observer
    # was also open during baseline. This is a conservative budget, not a causal estimate.
    $result.AmeOverheadBytes=Get-ComparisonMedian @($lateB.OwnPrivateBytes)
    $result.NetObservedDropBytes=$result.BaselinePrivateBytes-$result.AmePrivateBytes-$result.AmeOverheadBytes
    $lowBaseline=($lateA.AppPrivateBytes|Measure-Object -Minimum).Minimum
    $peakAme=($b|ForEach-Object {$_.AppPrivateBytes+$_.OwnPrivateBytes}|Measure-Object -Maximum).Maximum
    $result.ConservativeDropBytes=$lowBaseline-$peakAme
    $result.AppCommitDropBytes=(Get-ComparisonMedian @($lateA.AppCommitBytes))-(Get-ComparisonMedian @($lateB.AppCommitBytes))
    $result.SystemAvailableDeltaBytes=(Get-ComparisonMedian @($lateB.AvailableBytes))-(Get-ComparisonMedian @($lateA.AvailableBytes))
    $result.ProcessChanges=@(@($a+$b|Select-Object -ExpandProperty IdentityKey -Unique)).Count -gt 1
    foreach($metric in @(@('CpuPercent','CpuDeltaPercentagePoints'),@('PageFaultsPerSecond','FaultRateDelta'),@('IoReadBytesPerSecond','IoReadRateDelta'))){
        $av=@($lateA|Where-Object {$_.CounterCoverageComplete -and $null -ne $_.($metric[0])}|ForEach-Object {$_.PSObject.Properties[$metric[0]].Value})
        $bv=@($lateB|Where-Object {$_.CounterCoverageComplete -and $null -ne $_.($metric[0])}|ForEach-Object {$_.PSObject.Properties[$metric[0]].Value})
        if($av.Count -ge 40 -and $bv.Count -ge 40){$result[$metric[1]]=(Get-ComparisonMedian $bv)-(Get-ComparisonMedian $av)}
    }
    foreach($metric in @(@('CpuPercent','PeakCpu'),@('PageFaultsPerSecond','PeakFaults'),@('IoReadBytesPerSecond','PeakIoReads'))){
        $av=@($a|Where-Object {$_.CounterCoverageComplete -and $null -ne $_.($metric[0])}|ForEach-Object {$_.PSObject.Properties[$metric[0]].Value})
        $bv=@($b|Where-Object {$_.CounterCoverageComplete -and $null -ne $_.($metric[0])}|ForEach-Object {$_.PSObject.Properties[$metric[0]].Value})
        if($av.Count){$result['Baseline'+$metric[1]]=($av|Measure-Object -Maximum).Maximum}
        if($bv.Count){$result['Ame'+$metric[1]]=($bv|Measure-Object -Maximum).Maximum}
    }
    $result.CostWarning=($null -ne $result.CpuDeltaPercentagePoints -and $result.CpuDeltaPercentagePoints -gt 1) -or
        ($null -ne $result.FaultRateDelta -and $result.FaultRateDelta -gt 100) -or ($null -ne $result.IoReadRateDelta -and $result.IoReadRateDelta -gt 1MB)
    $result.CostWarning=$result.CostWarning -or
        ($null -ne $result.AmePeakCpu -and $null -ne $result.BaselinePeakCpu -and $result.AmePeakCpu -gt $result.BaselinePeakCpu+5) -or
        ($null -ne $result.AmePeakFaults -and $null -ne $result.BaselinePeakFaults -and $result.AmePeakFaults -gt $result.BaselinePeakFaults+1000) -or
        ($null -ne $result.AmePeakIoReads -and $null -ne $result.BaselinePeakIoReads -and $result.AmePeakIoReads -gt $result.BaselinePeakIoReads+4MB)
    if($result.ConservativeDropBytes -ge $Session.ThresholdBytes){
        $result.Code='observed_threshold_met';$result.Status='Riduzione privata residente sopra 500 MiB in tutti i campioni dei 15 minuti, incluso il costo privato residente misurato di AME.'
    }elseif($result.NetObservedDropBytes -gt 0){
        $result.Code='observed_below_threshold';$result.Status='RAM osservata in meno, ma la soglia di 500 MiB mantenuti per 15 minuti non e raggiunta.'
    }else{$result.Code='no_net_observed_benefit';$result.Status='Nessun beneficio RAM netto osservato dopo aver incluso il consumo di AME.'}
    if($result.ProcessChanges){$result.Status+=' Sono cambiate identita dei processi: le variazioni richiedono cautela.'}
    if($result.CostWarning){$result.Status+=' Attivita aumentata: possibile costo da verificare.'}
    $result.Status+=' Singolo confronto osservazionale; causalita, hard fault e reattivita dell app non verificati.'
    return [pscustomobject]$result
}
