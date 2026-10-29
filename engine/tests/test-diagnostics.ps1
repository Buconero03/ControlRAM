$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root=Split-Path $PSScriptRoot -Parent
$exporter=Join-Path $root 'export-diagnostics.ps1'
function Assert($ok,[string]$message){if(!$ok){throw $message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ame diagnostics test '+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$writer=$null
function Write-Events([string]$path,$events){
    $lines=@($events|ForEach-Object {$_|ConvertTo-Json -Compress -Depth 6})
    [IO.File]::WriteAllText($path,($lines -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
}
function Read-Zip([string]$path){
    $zip=[IO.Compression.ZipFile]::OpenRead($path)
    try{
        $result=@{}
        foreach($entry in $zip.Entries){$stream=$entry.Open();$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true);try{$result[$entry.FullName.Replace('\','/')]=$reader.ReadToEnd()}finally{$reader.Dispose()}}
        return $result
    }finally{$zip.Dispose()}
}
try{
    $observe=Join-Path $temp 'observe-first.jsonl';$recover=Join-Path $temp 'recover-second.jsonl'
    $samples=@(@{type='sample';elapsed_seconds=0;physical_total_bytes=8GB;physical_available_bytes=1GB;commit_bytes=3GB},
        @{type='sample';elapsed_seconds=2;physical_total_bytes=8GB;physical_available_bytes=2GB;commit_bytes=3GB},@{type='end'})
    Write-Events $observe $samples
    $events=@(@{type='recover_state';completed=0;reasons=@{low_activity_under_60_seconds=2}},
        @{type='recover_applied';pid=123},
        @{type='recover_feedback';pid=123;creation_filetime='456';phase='60s';private_resident_delta_bytes=-48MB;private_commit_delta_bytes=0;system_available_delta_bytes=20MB;causation_established=$false;latency_measured=$false},
        @{type='recover_guard';pid=123;reason='foreground_return_stop_further_actions'},
        @{type='recover_state';completed=1;disabled=$true;reasons=@{low_activity_under_60_seconds=2}},@{type='end'})
    Write-Events $recover $events
    [IO.File]::AppendAllText($recover,"INVALID COMPLETE LINE`n",(New-Object Text.UTF8Encoding($false)))
    $expectedSnapshot=[IO.File]::ReadAllBytes($recover)
    $tailFull=[Text.Encoding]::UTF8.GetBytes('{"type":"sample","note":"caff'+[char]0xe8)
    [byte[]]$tail=$tailFull[0..($tailFull.Length-2)]
    $writer=[IO.File]::Open($recover,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    $writer.Write($tail,0,$tail.Length);$writer.Flush()
    $result=& $exporter -Report @($observe,$recover) -OutputDirectory (Join-Path $temp 'exports with spaces')
    $writer.Dispose();$writer=$null
    $zip=Read-Zip $result.Path;$summary=$zip['RIEPILOGO.json']|ConvertFrom-Json
    Assert ($result.ReportCount -eq 2 -and $result.AppliedCount -eq 1) 'Conteggio report/interventi errato'
    Assert (!$summary.source_files_modified -and !$summary.causation_established -and !$summary.latency_measured) 'La raccolta dichiara mutazioni o beneficio non misurato'
    $r=@($summary.reports|Where-Object {$_.source_name -eq 'recover-second.jsonl'})[0]
    Assert ($r.incomplete_tail_bytes_omitted -eq $tail.Length -and $r.invalid_complete_lines -eq 1) 'Righe parziali/errate gestite male'
    Assert ($r.feedback[0].private_resident_delta_bytes -eq -48MB -and $r.feedback[0].private_commit_delta_bytes -eq 0) 'Delta alterati'
    Assert ($r.reason_process_sample_counts.low_activity_under_60_seconds -eq 4) 'Motivi di attesa non contati per campione'
    Assert ($r.outcomes[0].reason -eq 'foreground_return_stop_further_actions') 'Guardia persa'
    Assert ($zip[$r.archive_entry] -like '*INVALID COMPLETE LINE*' -and $zip[$r.archive_entry] -notlike '*caff*') 'Copia report non fedele o riga parziale inclusa'
    $archive=[IO.Compression.ZipFile]::OpenRead($result.Path)
    try{
        foreach($entry in $archive.Entries){Assert (!$entry.FullName.Contains('\')) 'Nome ZIP non canonico'}
        $entry=$archive.GetEntry($r.archive_entry)
        Assert ($null -ne $entry) 'Il percorso nel riepilogo non identifica la voce ZIP'
        $stream=$entry.Open();$bytes=New-Object IO.MemoryStream
        try{
            $stream.CopyTo($bytes)
            Assert ([Convert]::ToBase64String($bytes.ToArray()) -ceq [Convert]::ToBase64String($expectedSnapshot)) 'Byte del report esportato alterati'
        }finally{$stream.Dispose();$bytes.Dispose()}
    }finally{$archive.Dispose()}
    # Simulate the entry names produced by Windows PowerShell 5.1/.NET Framework.
    $legacyPath=Join-Path $temp 'legacy-windows.zip'
    $legacy=[IO.Compression.ZipFile]::Open($legacyPath,[IO.Compression.ZipArchiveMode]::Create)
    try{[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($legacy,$observe,'reports\observe-first.jsonl')}
    finally{$legacy.Dispose()}
    $legacyData=Read-Zip $legacyPath
    Assert ($legacyData['reports/observe-first.jsonl'] -ceq [IO.File]::ReadAllText($observe)) 'Lettura ZIP Windows con backslash errata'
    Assert ([IO.File]::ReadAllText($recover).EndsWith([Text.Encoding]::UTF8.GetString($tail))) 'Sorgente modificato'
    Assert ($zip['LEGGIMI.txt'] -like '*NESSUN INTERVENTO APPLICATO REGISTRATO*' -and $zip['LEGGIMI.txt'] -like '*non processi unici*') 'Riepilogo attribuisce recupero a observe o conteggi a PID unici'
    $only=& $exporter -Report $observe -OutputDirectory (Join-Path $temp 'exports with spaces')
    Assert ($only.AppliedCount -eq 0 -and $only.Path -ne $result.Path) 'Observe-only o esportazioni ripetute errate'
    $big=Join-Path $temp 'observe-big.jsonl';[IO.File]::WriteAllBytes($big,(New-Object byte[] 1048577))
    $limited=& $exporter -Report @($big,$observe) -OutputDirectory (Join-Path $temp 'exports with spaces') -MaxBytes 1048576
    Assert ($limited.ReportCount -eq 1 -and $limited.Warnings.Count -eq 1) 'Limite raccolta non segnalato'
    $uncertain=Join-Path $temp 'recover-incomplete.jsonl';Write-Events $uncertain @(@{type='recover_intent';pid=456})
    $unknown=& $exporter -Report $uncertain -OutputDirectory (Join-Path $temp 'exports with spaces')
    $unknownZip=Read-Zip $unknown.Path;$unknownData=$unknownZip['RIEPILOGO.json']|ConvertFrom-Json
    Assert ($unknownData.reports[0].unresolved_intent_count -eq 1 -and $unknown.Warnings.Count -eq 1) 'Esito incerto dichiarato come mancata azione certa'
    # Browser confirmations and measurements must not be confused with native trims.
    $browserReport=Join-Path $temp 'browser-firefox.jsonl';$request=[guid]::NewGuid().ToString()
    Write-Events $browserReport @(
        @{type='browser_connection';code='inventory_ready';message='Firefox collegato'},
        @{type='browser_result';browser='Firefox';request=$request;outcome='discarded'},
        @{type='browser_result';browser='Firefox';request=$request;outcome='discarded'},
        @{type='browser_feedback';browser='Firefox';request=$request;private_working_set_delta_bytes=-32MB;outcome='observing'},
        @{type='browser_assessed';browser='Firefox';request=$request;outcome='no_durable_aggregate_drop';status='Firefox: nessuna riduzione aggregata duratura confermata a 5 min.'}
    )
    $browserResult=& $exporter -Report $browserReport -OutputDirectory (Join-Path $temp 'exports with spaces')
    $browserZip=Read-Zip $browserResult.Path;$browserSummary=$browserZip['RIEPILOGO.json']|ConvertFrom-Json
    Assert ($browserSummary.applied_count -eq 0 -and $browserSummary.browser_discard_confirmations -eq 1) 'Browser discard confused with native trim or duplicated'
    Assert (@($browserSummary.browser_outcomes).Count -eq 1 -and @($browserSummary.reports[0].browser_feedback).Count -eq 1) 'Browser RAM assessment absent from exported evidence'
    Assert ($browserZip['LEGGIMI.txt'] -like '*SCARICAMENTO SCHEDA CONFERMATO*' -and $browserZip['LEGGIMI.txt'] -like '*nessuna riduzione aggregata duratura*') 'Browser diagnosis does not separate operation from lasting memory benefit'
    # Execute the GUI export handler with its real exporter and a light log substitute.
    Copy-Item -LiteralPath $exporter -Destination (Join-Path $temp 'export-diagnostics.ps1')
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'hub.ps1'),[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Export-Diagnosis'},$true)
    Assert ($null -ne $fn) 'Handler esportazione GUI assente'
    $definition=[Management.Automation.Language.Parser]::ParseInput($fn.Extent.Text,(Join-Path $temp 'hub.ps1'),[ref]$tokens,[ref]$errors)
    . $definition.GetScriptBlock()
    $script:messages=New-Object 'Collections.Generic.List[string]'
    function Add-Log([string]$message){$script:messages.Add($message)}
    $guiPath=Export-Diagnosis $observe
    Assert ((Test-Path -LiteralPath $guiPath) -and $script:messages[0] -like 'Diagnosi ZIP:*') 'GUI perde percorso/esito della raccolta'
    $failed=Export-Diagnosis (Join-Path $temp 'missing.jsonl')
    Assert ($null -eq $failed -and $script:messages[$script:messages.Count-1] -like 'Esportazione diagnosi fallita:*') 'Errore raccolta interrompe il pannello'
    Write-Host 'PASS diagnostics ZIP: canonical paths, legacy Windows paths, exact bytes, live snapshots, partial/invalid lines, signed metrics, reasons, no-action summary, size limit and unchanged sources'
}finally{if($writer){$writer.Dispose()};if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}}
