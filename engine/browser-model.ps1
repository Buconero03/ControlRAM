function Get-BrowserObservation($Pending,$Reading,[DateTime]$Now=[DateTime]::UtcNow) {
    $browser=if($Pending.Browser -eq 'Firefox'){'Firefox'}else{'Chrome'}
    $seconds=($Now-$Pending.AckAt).TotalSeconds
    if($seconds -lt 0 -or ($Pending.LastSample -and ($Now-$Pending.LastSample).TotalSeconds -gt 12)){$Pending.Incomplete=$true}
    $Pending.LastSample=$Now
    $comparable=$null -ne $Pending.Before.private_working_set_bytes -and $null -ne $Reading.private_working_set_bytes -and
        $Reading.scope -eq $Pending.Before.scope -and $Pending.Before.unreadable -eq 0 -and $Reading.unreadable -eq 0 -and $Reading.processes -eq $Pending.Before.processes -and $Reading.processes -gt 0
    if(!$comparable){$Pending.Incomplete=$true}
    $drop=$null;$commit=$null
    if($comparable){
        $drop=[double]$Pending.Before.private_working_set_bytes-[double]$Reading.private_working_set_bytes
        $commit=[double]$Pending.Before.private_commit_bytes-[double]$Reading.private_commit_bytes
        if($drop -gt $Pending.BestDrop){$Pending.BestDrop=$drop}
        $Pending.Samples=@($Pending.Samples|Where-Object {$_.Seconds -ge ($seconds-60)})+@([pscustomobject]@{Seconds=$seconds;Drop=$drop})
    }
    $finished=$Pending.Returned -or $seconds -ge 300 -or $Pending.Incomplete
    $status=if($null -eq $drop){($browser+': confronto RAM non disponibile (lettura incompleta o processi cambiati).')}else{
        ($browser+', tutti i profili: {0:N1} MiB {1} rispetto a prima; commit {2:+0.0;-0.0;0.0} MiB. Variazioni osservate.') -f
            ([math]::Abs($drop)/1MB),$(if($drop -ge 0){'in meno'}else{'in piu'}),(-$commit/1MB)
    }
    $outcome='observing'
    if($Pending.Returned){$outcome='page_returned';$status+=' Scheda tornata in uso: beneficio fino al ritorno, durata rilevata circa '+[math]::Floor($seconds)+' s. Nessun risparmio stabile dichiarato.'}
    elseif($Pending.Incomplete){$outcome='incomplete';$status+=' Misura interrotta: continuita non verificata.'}
    elseif($seconds -ge 300){
        $last=@($Pending.Samples);$minimum=($last|Measure-Object -Property Drop -Minimum).Minimum
        if($last.Count -ge 10 -and $last[0].Seconds -le ($seconds-50) -and $minimum -ge 16MB -and $minimum -gt ($Pending.BestDrop*0.2)){
            $outcome='aggregate_drop_observed_5m';$status+=' Riduzione aggregata osservata per 5 min; non attribuita alla singola scheda.'
        }else{$outcome='no_durable_aggregate_drop';$status+=' Nessuna riduzione aggregata duratura confermata a 5 min.'}
    }else{$status+=' Verifico la durata: '+[math]::Floor($seconds)+'/300 s. Il ritorno della scheda puo far risalire la memoria.'}
    return [pscustomobject]@{Finished=$finished;Status=$status;Outcome=$outcome;Seconds=$seconds;Drop=$drop;CommitDrop=$commit}
}
