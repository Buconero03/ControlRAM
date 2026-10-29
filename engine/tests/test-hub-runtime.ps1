param([switch]$Bridge)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (!('AmeHub.Frames' -as [type])) { Add-Type -Path (Join-Path $root 'src\hub-runtime.cs') }
function Assert($ok,[string]$message) { if (!$ok) { throw $message } }
try{[void][AmeHub.Metrics]::Browser('other');throw 'Unsupported browser accepted'}catch{Assert ($_.Exception.Message -like '*Browser non supportato*') 'Memory reader accepts arbitrary process names'}
$m = New-Object IO.MemoryStream
[AmeHub.Frames]::Write($m,'{"type":"prova","value":"caffè ☕"}')
[AmeHub.Frames]::Write($m,'{"type":"secondo"}')
$m.Position=0
Assert ([AmeHub.Frames]::Read($m) -eq '{"type":"prova","value":"caffè ☕"}') 'UTF8 frame corrotto'
Assert ([AmeHub.Frames]::Read($m) -eq '{"type":"secondo"}') 'Secondo frame corrotto'
Assert ($null -eq [AmeHub.Frames]::Read($m)) 'EOF non riconosciuto'
$m.Dispose()
foreach ($bytes in @([byte[]](0,0,0,0),[byte[]](1,0,4,0),[byte[]](2,0,0,0,123))) {
    $bad=New-Object IO.MemoryStream(,$bytes)
    $rejected=$false
    try { [void][AmeHub.Frames]::Read($bad) } catch { $rejected=$true } finally { $bad.Dispose() }
    Assert $rejected 'Frame malformato accettato'
}
$path=Join-Path ([IO.Path]::GetTempPath()) ('ame-tail-'+[guid]::NewGuid().ToString('N'))
$writer=$null; $tail=$null
try {
    $writer=New-Object IO.FileStream($path,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    $tail=New-Object AmeHub.ReportTail($path)
    $text='{"type":"native_state","active_leases":2,"note":"caffè"}' + "`r`n"
    $bytes=[Text.Encoding]::UTF8.GetBytes($text)
    # Split inside a multibyte UTF8 character and inside a JSON line.
    $split=[Array]::IndexOf($bytes,[byte]0xc3)+1
    $writer.Write($bytes,0,$split); $writer.Flush()
    Assert (@($tail.ReadLines()).Count -eq 0) 'Riga parziale pubblicata'
    Assert (@($tail.ReadLines()).Count -eq 0) 'EOF temporaneo non gestito'
    $writer.Write($bytes,$split,$bytes.Length-$split); $writer.Flush()
    $lines=@($tail.ReadLines()); Assert ($lines.Count -eq 1) 'Riga completa persa'
    Assert (($lines[0]|ConvertFrom-Json).active_leases -eq 2) 'Contatore alterato'
    Assert ($lines[0] -eq $text.TrimEnd("`r","`n")) 'Unicode o CRLF alterati'
    $large='{"type":"sample","padding":"'+('x'*300000)+'"}' + "`n" + '{"type":"priority_applied","pid":123}' + "`n"
    $bytes=[Text.Encoding]::UTF8.GetBytes($large); $writer.Write($bytes,0,$bytes.Length); $writer.Flush()
    $all=@(); do { $all+=@($tail.ReadLines()) } while ($tail.HasUnreadBytes)
    Assert ($all.Count -eq 2) 'Evento dopo riga grande perso'
    Assert (($all[1]|ConvertFrom-Json).type -eq 'priority_applied') 'Ordine eventi alterato'
    Write-Host 'PASS frame bounds/UTF8 + incremental report after EOF/partial/large lines'
} finally {
    if ($tail) { $tail.Dispose() }; if ($writer) { $writer.Dispose() }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}
$path=Join-Path ([IO.Path]::GetTempPath()) ('ame-counters-'+[guid]::NewGuid().ToString('N'))
try {
    # Execute the actual GUI event handler with light UI substitutes.
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'hub-browser.ps1'),[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-HubReport'},$true)
    Assert ($null -ne $fn) 'Handler eventi non trovato'
    Set-Item -Path Function:Read-HubReport -Value $fn.Body.GetScriptBlock()
    $script:testLog=New-Object 'Collections.Generic.List[string]'
    function Add-HubLog([string]$value) { $script:testLog.Add($value) }
    $state=[pscustomobject]@{Text=''}
    $script:appliedCount=0; $script:finishedCount=0; $script:runEnds=[DateTime]::UtcNow.AddMinutes(5)
    $events=@('{"type":"priority_applied","pid":10,"reason":"test"}',
        '{"type":"native_state","active_leases":1,"pressure":true,"disabled":false}',
        '{"type":"priority_finished","pid":10,"result_code":0}',
        '{"type":"native_state","active_leases":0,"pressure":false,"disabled":false}')
    [IO.File]::WriteAllText($path,($events -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
    $script:reportReader=New-Object AmeHub.ReportTail($path)
    Read-HubReport
    Assert ($script:appliedCount -eq 1 -and $script:finishedCount -eq 1) 'Contatori pannello errati'
    Assert ($script:testLog.Count -eq 2) 'Eventi operativi non mostrati'
    Assert ($script:lastNative -match 'Applicate: 1.*Concluse: 1') 'Riepilogo pannello errato'
    Assert ($state.Text -like 'In attesa di pressione*') 'Stato pannello non aggiornato'
    Write-Host 'PASS actual panel event counters and pressure status'
} finally {
    if ($script:reportReader) { $script:reportReader.Dispose(); $script:reportReader=$null }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}
if ($Bridge) {
    if ($env:OS -ne 'Windows_NT') { throw 'Il test del bridge richiede Windows.' }
    $exe=Join-Path $root 'build\ame-browser-host.exe'
    $config=Get-Content (Join-Path $root 'browser\config.json') -Raw | ConvertFrom-Json
    foreach($browser in @('Chrome','Firefox')){
    $server=New-Object AmeHub.BrowserBridge($exe)
    $process=$null
    try {
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$exe; $info.Arguments=if($browser -eq 'Firefox'){'"'+(Join-Path $root 'build\firefox-native-host.json')+'" '+$config.firefox_extension_id}else{'chrome-extension://'+$config.extension_id+'/'}
        $info.UseShellExecute=$false; $info.CreateNoWindow=$true
        $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
        $process=New-Object Diagnostics.Process; $process.StartInfo=$info; [void]$process.Start()
        [AmeHub.Frames]::Write($process.StandardInput.BaseStream,'{"type":"fixture","value":"caffè"}')
        $deadline=[DateTime]::UtcNow.AddSeconds(8); $entry=$null
        do {
            foreach ($e in $server.Drain()) { if ($e.Error) { throw $e.Error }; if ($e.Json) { $entry=$e } }
            if (!$entry) { Start-Sleep -Milliseconds 40 }
        } while (!$entry -and [DateTime]::UtcNow -lt $deadline)
        Assert ($null -ne $entry) 'Host non collegato'
        Assert (($entry.Json|ConvertFrom-Json).value -eq 'caffè') 'Host ha corrotto il frame'
        Assert ($server.Send($entry.Connection,'{"type":"reply"}')) 'Invio bridge fallito'
        # Native reader has a deadline: a broken bridge must not hang the test.
        $reply=[AmeHub.Frames]::ReadWithTimeout($process.StandardOutput.BaseStream,5000)
        Assert ($reply -eq '{"type":"reply"}') 'Risposta bridge alterata'
        for($cycle=1;$cycle -le 8;$cycle++){
            # A small input fits the redirected stdin buffer even when the native host is blocked.
            # Reply timeout therefore catches a stalled native writer without hanging this test.
            Start-Sleep -Milliseconds 80
            $frame='{"type":"inventory-probe","cycle":'+$cycle+',"payload":"'+('x'*1024)+'"}'
            [AmeHub.Frames]::Write($process.StandardInput.BaseStream,$frame)
            $deadline=[DateTime]::UtcNow.AddSeconds(5);$next=$null
            do{
                foreach($e in $server.Drain()){if($e.Error){throw $e.Error};if($e.Json){$next=$e}}
                if(!$next){Start-Sleep -Milliseconds 20}
            }while(!$next -and [DateTime]::UtcNow -lt $deadline)
            Assert ($next -and $next.Json -ceq $frame) ('Native pipe stalled after welcome, cycle '+$cycle)
            $ack='{"type":"inventory_ack","cycle":'+$cycle+'}'
            Assert ($server.Send($next.Connection,$ack)) 'Repeat bridge send failed'
            Assert ([AmeHub.Frames]::ReadWithTimeout($process.StandardOutput.BaseStream,5000) -ceq $ack) 'Repeat native reply failed'
        }
        $process.StandardInput.Close()
        Assert ($process.WaitForExit(5000)) 'Host non termina con EOF'
        Write-Host ('PASS '+$browser+' Windows native-host identity + 8 post-welcome exchanges + bidirectional framing + EOF shutdown')
    } finally {
        $server.Dispose()
        if ($process) { if (!$process.HasExited) { $process.Kill() }; $process.Dispose() }
    }
}
}
