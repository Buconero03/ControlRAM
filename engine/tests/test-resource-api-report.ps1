param([string]$FixtureTrace='')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'export-resource-api-report.ps1')
function Assert($ok,[string]$message){if(!$ok){throw $message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ame API report '+[guid]::NewGuid().ToString('N'))
try{
    [void][IO.Directory]::CreateDirectory($temp)
    $trace=Join-Path $temp 'actual trace fixture.jsonl'
    if($FixtureTrace){Copy-Item -LiteralPath $FixtureTrace -Destination $trace}
    else{
        $records=@(
            @{seq=1;type='session_start';elapsed_ms=0;phase='setup';trace_version=1;api_abi=1;data_origin='synthetic_test'},
            @{seq=2;type='call';elapsed_ms=1;phase='identity';expression='AmeAttachProcess(group, identity) <script>alert("x")</script>';result=4;windows_error=0},
            @{seq=3;type='snapshot';elapsed_ms=2;phase='identity';label='before_growth';flags=1;group=1;active_processes=1;measured_processes=1;private_commit_sum_bytes=8388608;working_set_sum_bytes=10485760},
            @{seq=4;type='snapshot';elapsed_ms=3;phase='memory_notice';label='after_growth';flags=3;group=1;active_processes=1;measured_processes=1;private_commit_sum_bytes=75497472;working_set_sum_bytes=77594624;rate_interval_ms=2000;cpu_percent_machine=1.25;page_faults_per_second=2.5},
            @{seq=5;type='event';elapsed_ms=4;phase='memory_notice';kind=4;windows_message=11;pid=0;job_commit_bytes=75497472;commit_notice_bytes=33554432},
            @{seq=6;type='session_end';elapsed_ms=5;phase='capacity';passed=$true;checks=1;error=''}
        )
        $lines=@($records|ForEach-Object {$_|ConvertTo-Json -Compress})
        [IO.File]::WriteAllText($trace,($lines -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
    }
    $report=Join-Path $temp 'report with spaces.html'
    [void](Write-ResourceApiReport -TracePath $trace -OutputPath $report -SourceRoot $root -NativeExitCode 0)
    $html=[IO.File]::ReadAllText($report)
    Assert ($html.Contains('ANTEPRIMA CON DATI SINTETICI')) 'Dati sintetici dichiarati come prova Windows'
    Assert ($html.Contains('8,0 MiB') -and $html.Contains('72,0 MiB') -and $html.Contains('32,0 MiB')) 'Misure o soglia non riportate'
    Assert ($html.Contains('CPU intero PC: 1,25%') -and $html.Contains('Tassi di attivita non disponibili')) 'Tassi mancanti trasformati in zero valido'
    Assert ($html.Contains('&lt;script&gt;') -and !$html.Contains('<script>')) 'Contenuto del registro eseguibile nel resoconto'
    Assert ($html.Contains('AssignProcessToJobObject') -and $html.Contains('QueryInformationJobObject') -and $html.Contains('Codice sorgente consultabile')) 'Spiegazione Windows o sorgenti mancanti'
    Assert ($html.Contains('I Job Object restano nella demo') -and $html.Contains('non applica una riduzione RAM')) 'Resoconto promette riduzioni non eseguite'
    # Missing terminal record must not be interpreted as a successful session.
    $text=[IO.File]::ReadAllText($trace)
    $lines=@($text.Split([char]10)|Where-Object {$_})
    $incomplete=Join-Path $temp 'incomplete.jsonl'
    $withoutEnd=@($lines|Where-Object {($_|ConvertFrom-Json).type -ne 'session_end'})
    $withoutEnd=@($withoutEnd|ForEach-Object {$_ -replace 'synthetic_test','windows_demo'})
    [IO.File]::WriteAllText($incomplete,($withoutEnd -join "`n")+"`n")
    [void](Write-ResourceApiReport -TracePath $incomplete -OutputPath $report -SourceRoot $root -NativeExitCode 0)
    $html=[IO.File]::ReadAllText($report)
    Assert ($html.Contains('OSSERVAZIONE INCOMPLETA') -and !$html.Contains('>DEMO COMPLETATA<')) 'Sessione senza esito dichiarata completa'
    # A partial final line cannot count as a completion record.
    [IO.File]::WriteAllText($incomplete,($withoutEnd -join "`n")+"`n"+'{"seq":99,"type":"session_end"')
    [void](Write-ResourceApiReport -TracePath $incomplete -OutputPath $report -SourceRoot $root -NativeExitCode 0)
    Assert ([IO.File]::ReadAllText($report).Contains('riga finale parziale True')) 'Riga parziale non indicata'
    # An incomplete memory sample is not shown as a complete observed total.
    $missing=@(
        @{seq=1;type='session_start';elapsed_ms=0;phase='setup';trace_version=1;api_abi=1;data_origin='windows_demo'},
        @{seq=2;type='snapshot';elapsed_ms=1;phase='memory_notice';label='after_growth';flags=0;active_processes=1;measured_processes=0;private_commit_sum_bytes=0;working_set_sum_bytes=0},
        @{seq=3;type='session_end';elapsed_ms=2;phase='capacity';passed=$true;checks=1;error=''}
    )
    [IO.File]::WriteAllText($incomplete,(@($missing|ForEach-Object {$_|ConvertTo-Json -Compress}) -join "`n")+"`n")
    [void](Write-ResourceApiReport -TracePath $incomplete -OutputPath $report -SourceRoot $root -NativeExitCode 0)
    $html=[IO.File]::ReadAllText($report)
    Assert ($html.Contains('Misura memoria incompleta') -and $html.Contains('Non disponibile → Non disponibile')) 'Dati mancanti presentati come memoria zero'
    [void](Write-ResourceApiReport -TracePath '' -OutputPath $report -SourceRoot $root -Failure 'Compiler failed <script>' -NativeExitCode -1)
    $html=[IO.File]::ReadAllText($report)
    Assert ($html.Contains('DEMO NON COMPLETATA') -and $html.Contains('Nessuna chiamata nativa registrata') -and $html.Contains('Compiler failed &lt;script&gt;')) 'Errore di compilazione senza registro non spiegato'
    [void](Write-ResourceApiReport -TracePath $incomplete -OutputPath $report -SourceRoot $root -NativeExitCode 1)
    Assert ([IO.File]::ReadAllText($report).Contains('DEMO NON COMPLETATA')) 'Codice di uscita fallito ignorato'
    Write-Host 'PASS API report: actual producer fixture or synthetic records, escaping, source code, missing measurements, incomplete trace and failure status'
}finally{if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}}
