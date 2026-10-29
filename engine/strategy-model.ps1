function ConvertTo-StrategyDate($value) {
    if($value -is [DateTime]){return $value.ToUniversalTime()}
    return [DateTime]::Parse([string]$value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
function Read-StrategyHistory([string]$Path,[DateTime]$Now=[DateTime]::UtcNow) {
    if(!(Test-Path -LiteralPath $Path)){return @()}
    if((Get-Item -LiteralPath $Path).Length -gt 1MB){throw 'Storico strategia oltre 1 MiB.'}
    try{
        $data=[IO.File]::ReadAllText($Path)|ConvertFrom-Json
        if($data.schema_version -ne 1 -or @($data.records).Count -gt 512){throw 'Schema non valido'}
        foreach($r in @($data.records)){
            if($r.key -notmatch '^[1-9][0-9]{0,9}:[1-9][0-9]{0,19}$' -or !$r.image_path -or $r.image_path.Length -gt 32768 -or
               $r.classification -notin @('brief','small','retained','retained_with_activity') -or !$r.source -or $r.source.Length -gt 200){throw 'Record non valido'}
            $date=ConvertTo-StrategyDate $r.observed_utc
            if($date -gt $Now.AddMinutes(5)){throw 'Data futura non valida'}
            if($date -ge $Now.AddDays(-7)){Write-Output $r}
        }
    }catch{throw ('Storico strategia non leggibile: '+$_.Exception.Message)}
}
function Save-StrategyOutcome([string]$Path,$Event,[object[]]$Authorized,[string]$Source,[DateTime]$Now=[DateTime]::UtcNow,[DateTime]$Observed=$Now) {
    if($Event.type -ne 'recover_assessed'){return}
    $key=[string]$Event.pid+':'+[string]$Event.creation_filetime
    $match=@($Authorized|Where-Object {$_.Key -eq $key -and [string]::Equals([string]$_.Path,[string]$Event.image_path,[StringComparison]::OrdinalIgnoreCase)})
    if($match.Count -ne 1 -or !$Source -or $Source.Length -gt 200){return}
    $classification=switch([string]$Event.reason){
        'rapid_resident_rebound' {'brief'}
        'no_meaningful_resident_reduction' {'small'}
        'resident_reduction_not_retained_5m' {'brief'}
        'resident_reduction_retained_5m' {'retained'}
        'resident_reduction_retained_5m_with_activity' {'retained_with_activity'}
        'resident_reduction_retained_5m_after_resume' {'retained_with_activity'}
        default {''}
    }
    if(!$classification){return}
    $seconds=[double]$Event.seconds_after_action
    $best=[double]$Event.best_private_resident_reduction_bytes
    $remaining=[double]$Event.remaining_private_resident_reduction_bytes
    foreach($value in @($seconds,$best,$remaining)){if([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0){return}}
    if($null -eq $Event.seconds_after_action -or $null -eq $Event.best_private_resident_reduction_bytes -or
       $null -eq $Event.remaining_private_resident_reduction_bytes -or $best -gt 2GB -or $remaining -gt $best -or $seconds -gt 3600){return}
    if($classification -like 'retained*' -and ($seconds -lt 300 -or $remaining -lt 16MB -or
       $null -eq $Event.minimum_private_resident_reduction_last_60s_bytes -or [double]$Event.minimum_private_resident_reduction_last_60s_bytes -lt 16MB)){return}
    $records=@(Read-StrategyHistory $Path $Now|Where-Object {!($_.source -eq $Source -and $_.key -eq $key)}|Select-Object -Last 511)
    $records+=@([pscustomobject]@{key=$key;image_path=[string]$Event.image_path;classification=$classification;source=$Source;
        observed_utc=$Observed.ToString('o');seconds_observed=$seconds;best_resident_drop_bytes=$best;remaining_resident_drop_bytes=$remaining;
        allocation_release_measured=$false;latency_measured=$false})
    $directory=[IO.Path]::GetDirectoryName($Path);[void][IO.Directory]::CreateDirectory($directory)
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $json=@{schema_version=1;records=@($records)}|ConvertTo-Json -Depth 6
        if([Text.Encoding]::UTF8.GetByteCount($json) -gt 1MB){throw 'Storico strategia troppo grande.'}
        [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Import-StrategyReports([string]$Directory,[string]$HistoryPath) {
    # One-time bounded import; inspect only session/outcome lines in completed reports.
    if(Test-Path -LiteralPath $HistoryPath){return}
    $budget=32MB
    foreach($file in @(Get-ChildItem -LiteralPath $Directory -Filter 'recover*.jsonl' -File -ErrorAction SilentlyContinue|Where-Object {$_.LastWriteTimeUtc -ge [DateTime]::UtcNow.AddDays(-7)}|Sort-Object LastWriteTime -Descending|Select-Object -First 5)){
        if($file.Length -gt 8MB -or $file.Length -gt $budget){continue};$budget-=$file.Length
        $authorized=@();$outcomes=@();$complete=$false;$valid=$true
        $stream=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        $reader=New-Object IO.StreamReader -ArgumentList $stream
        try{
            while($null -ne ($line=$reader.ReadLine())){
                if($line.Substring(0,[math]::Min(1024,$line.Length)) -notmatch '"type"\s*:\s*"(recover_session|recover_assessed|end)"'){continue}
                if($line.Length -gt 65536){$valid=$false;break}
                try{$e=$line|ConvertFrom-Json}catch{$valid=$false;break}
                if($e.type -eq 'recover_session'){
                    if($authorized.Count -or @($e.selected).Count -ne 1 -or @($e.allowed_images).Count -ne 1){$valid=$false;break}
                    $authorized=@([pscustomobject]@{Key=([string]$e.selected[0].pid+':'+[string]$e.selected[0].creation_filetime);Path=[string]$e.allowed_images[0]})
                }elseif($e.type -eq 'recover_assessed'){$outcomes+=@($e);if($outcomes.Count -gt 1){$valid=$false;break}}
                elseif($e.type -eq 'end'){$complete=$e.feedback_pending -eq $false}
            }
            # A truncated final JSON record is never treated as a completed report.
            if($stream.Length -gt 0){$stream.Position=$stream.Length-1;if($stream.ReadByte() -ne 10){$complete=$false}}
        }finally{$reader.Dispose()}
        if($valid -and $complete){foreach($e in $outcomes){Save-StrategyOutcome $HistoryPath $e $authorized $file.Name -Observed $file.LastWriteTimeUtc}}
    }
}
function Get-StrategyAdvice($Target,[object[]]$Records) {
    $same=@($Records|Where-Object {[string]::Equals([string]$_.image_path,[string]$Target.Path,[StringComparison]::OrdinalIgnoreCase)})
    $bad=@($same|Where-Object {$_.classification -in @('brief','small')}).Count
    $good=@($same|Where-Object {$_.classification -eq 'retained'}).Count
    $cost=@($same|Where-Object {$_.classification -eq 'retained_with_activity'}).Count
    $chrome=[string]$Target.Name -in @('chrome.exe','firefox.exe')
    $browser=if([string]$Target.Name -ieq 'firefox.exe'){'Firefox'}else{'Chrome'}
    $method=if($chrome){('Scarica schede inattive tramite '+$browser)}else{'Nessun rilascio interno integrato'}
    $evidence=if($bad){'Storico: {0} prove con beneficio breve o piccolo; riduzione temporanea sconsigliata.' -f $bad}
        elseif($good){'Storico: {0} prove con riduzione residente osservata per 5 min. Non dimostra minori allocazioni.' -f $good}
        elseif($cost){'Riduzione osservata con ritorno dell app o aumento di attivita: prestazioni non verificate.'}
        else{'Nessun esito valido nello storico. Non stimo MB recuperabili.'}
    if($Target.Blocked){$method='Processo escluso: '+$Target.Blocked}
    return [pscustomobject]@{Method=$method;Explanation=$evidence;CanReleaseTabs=($chrome -and !$Target.Blocked);Bad=$bad;Good=$good}
}
