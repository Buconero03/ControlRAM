$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'windows-model.ps1')
function Assert($ok,[string]$message){if(!$ok){throw $message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ame-benefit-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$path=Join-Path $temp 'recovery-history.json'
$now=[DateTime]::UtcNow
$target=[pscustomobject]@{Key='101:123';Name='app.exe';Path='D:\Apps\app.exe'}
$negative=[pscustomobject]@{type='recover_assessed';pid=101;creation_filetime='123';image_path='d:\apps\APP.exe';reason='rapid_resident_rebound'}
try{
    Assert (!(Get-RecoveryRepeatBlock $path $target $now)) 'Processo mai provato bloccato'
    Save-RecoveryOutcome $path $negative @($target) $now
    Assert ((Get-RecoveryRepeatBlock $path $target $now.AddSeconds(10)) -like '*30 minuti*') 'Esito negativo non blocca una nuova richiesta'
    Assert (@(Read-RecoveryHistory $path $now).Count -eq 1) 'Storico non persistente'
    # Simulate Windows PowerShell 5.1 leaving ISO dates as strings.
    $jsonCommand=Get-Command ConvertFrom-Json -CommandType Cmdlet
    function ConvertFrom-Json {
        param([Parameter(ValueFromPipeline=$true)][string]$InputObject)
        process{
            $parsed=& $jsonCommand -InputObject $InputObject
            foreach($record in @($parsed.records)){if($record.until_utc -is [DateTime]){$record.until_utc=$record.until_utc.ToUniversalTime().ToString('o')}}
            Write-Output $parsed
        }
    }
    try{Assert ((Get-RecoveryRepeatBlock $path $target $now) -like '*30 minuti*') 'Date UTC come stringhe perdono il blocco'}
    finally{Remove-Item Function:ConvertFrom-Json}
    $reuse=[pscustomobject]@{Key='101:999';Name='other.exe';Path=$target.Path}
    Assert (!(Get-RecoveryRepeatBlock $path $reuse $now)) 'Blocco ereditato da PID riutilizzato'
    $different=[pscustomobject]@{Key=$target.Key;Name='other.exe';Path='D:\Other\app.exe'}
    Assert (!(Get-RecoveryRepeatBlock $path $different $now)) 'Blocco applicato a percorso diverso'
    Assert (!(Get-RecoveryRepeatBlock $path $target $now.AddMinutes(30))) 'Blocco oltre la scadenza di 30 minuti'
    $before=[IO.File]::ReadAllText($path)
    foreach($reason in @('resident_reduction_retained_5m','resident_reduction_retained_5m_with_activity','resident_reduction_retained_5m_after_resume','sustained_observation_not_causal_proof','resident_reduction_observed_after_activity_warning','stopped_or_timed_out_before_eligibility','foreground_return_stop_further_actions','stopped_before_full_feedback_no_rollback')){
        $e=[pscustomobject]@{type='recover_assessed';pid=101;creation_filetime='123';image_path=$target.Path;reason=$reason}
        Save-RecoveryOutcome $path $e @($target) $now
    }
    Assert ([IO.File]::ReadAllText($path) -ceq $before) 'Esito positivo o non conclusivo altera lo storico negativo'
    Save-RecoveryOutcome $path $negative @($reuse) $now
    Assert ([IO.File]::ReadAllText($path) -ceq $before) 'Identita non autorizzata salvata'
    Save-RecoveryOutcome $path $negative @($different) $now
    Assert ([IO.File]::ReadAllText($path) -ceq $before) 'Percorso non autorizzato salvato'
    foreach($reason in @('no_meaningful_resident_reduction','resident_reduction_not_retained','no_sustained_observed_benefit','resident_reduction_not_retained_5m')){
        $negative.reason=$reason;Save-RecoveryOutcome $path $negative @($target) $now
        Assert (@(Read-RecoveryHistory $path $now).Count -eq 1) 'Duplicati per stessa identita'
        Assert ((Get-RecoveryRepeatBlock $path $target $now) -like '*sconsigliato*') 'Esito negativo non conservato'
    }
    $second=[pscustomobject]@{Key='102:456';Name='second.exe';Path='D:\Apps\second.exe'}
    $e=[pscustomobject]@{type='recover_assessed';pid=102;creation_filetime='456';image_path=$second.Path;reason='rapid_resident_rebound'}
    Save-RecoveryOutcome $path $e @($second) $now.AddMinutes(31)
    Assert (@(Read-RecoveryHistory $path $now.AddMinutes(31)).Count -eq 1) 'Record scaduti non eliminati durante il salvataggio'
    [IO.File]::WriteAllText($path,'{broken')
    $failed=$false;try{Get-RecoveryRepeatBlock $path $target $now}catch{$failed=$true}
    Assert ($failed -and [IO.File]::ReadAllText($path) -ceq '{broken') 'Storico danneggiato ignorato o sovrascritto'
    $failed=$false;try{Save-RecoveryOutcome $path $negative @($target) $now}catch{$failed=$true}
    Assert ($failed -and [IO.File]::ReadAllText($path) -ceq '{broken') 'Salvataggio sovrascrive storico danneggiato'
    [IO.File]::WriteAllText($path,('x'*(1MB+1)))
    $failed=$false;try{Read-RecoveryHistory $path $now}catch{$failed=$true}
    Assert $failed 'Limite byte non applicato'
    $feedback=[pscustomobject]@{phase='5s';private_resident_delta_bytes=-32MB;system_available_delta_bytes=20MB;retained_percent=25;remaining_private_resident_reduction_bytes=32MB}
    Assert ((Get-RecoveryFeedbackStatus $feedback) -like '*25%*32,0*' -or (Get-RecoveryFeedbackStatus $feedback) -like '*25%*32.0*') 'Percentuale/riduzione trattenuta non visibile'
    Assert ((Get-RecoveryStatus ([pscustomobject]@{disabled=$true;disabled_reason='rapid_resident_rebound'})) -like '*RAM quasi tutta tornata*') 'Motivo negativo non tradotto nello stato principale'
    Write-Host 'PASS benefit history: persistent 30-minute block, expiry, exact identity/path, authorized outcomes, duplicate pruning, inconclusive exclusions, corrupt/oversized history and retained feedback'
}finally{if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}}
