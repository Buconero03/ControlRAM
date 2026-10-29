# Public AME controller API. The native R10 controller performs the Windows action.
# Dot-source windows-model.ps1 and resource-api-bridge.ps1 before starting a request.
function New-AmeReductionStartInfo {
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][object[]]$Targets,
        [ValidateSet('recover-test','recover')][string]$Mode='recover-test',
        [ValidateRange(1,3600)][int]$Seconds=180,[Parameter(Mandatory=$true)][string]$Report,[Parameter(Mandatory=$true)][string]$StopFile)
    if(!$Targets.Count -or $Targets.Count -gt 5 -or ($Mode -eq 'recover-test' -and ($Targets.Count -ne 1 -or $Seconds -gt 180))){throw 'Richiesta AME: numero di identita o durata non validi.'}
    $keys=@{}
    foreach($target in $Targets){
        $parts=([string]$target.Key).Split(':');$processNumber=[uint32]0;$creation=[uint64]0
        if($parts.Count -ne 2 -or ![uint32]::TryParse($parts[0],[ref]$processNumber) -or $processNumber -le 4 -or
           ![uint64]::TryParse($parts[1],[ref]$creation) -or !$creation -or $keys.ContainsKey([string]$target.Key) -or
           !$target.Path -or ([string]$target.Path).Length -gt 32767 -or [string]$target.Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\)') {throw 'Richiesta AME: identita completa e percorso Windows assoluto richiesti.'}
        $keys[[string]$target.Key]=$true
    }
    $argsList=@(('--'+$Mode),'--inventory','--seconds',$Seconds.ToString([Globalization.CultureInfo]::InvariantCulture),'--report',$Report,'--stop-file',$StopFile)
    foreach($target in $Targets){$argsList+=@('--allow-process',[string]$target.Key)}
    foreach($image in @($Targets|ForEach-Object {[string]$_.Path}|Sort-Object -Unique)){$argsList+=@('--allow-exe',$image)}
    $quoted=foreach($argument in $argsList){
        if(!$argument -or $argument.IndexOfAny([char[]]@([char]0,[char]10,[char]13,[char]34)) -ge 0 -or $argument.EndsWith('\')){throw 'Richiesta AME: argomento non rappresentabile in modo sicuro.'}
        '"'+$argument+'"'
    }
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $Root 'build/ame.exe';$info.WorkingDirectory=$Root;$info.Arguments=$quoted -join ' '
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    return $info
}
function New-AmeReductionState($Target) {
    return [pscustomobject]@{ApiVersion=1;RequestId=[guid]::NewGuid().ToString('D');Target=$Target;Phase='requested';Message='Richiesta ricevuta: nessun intervento ancora eseguito.';
        SessionVerified=$false;Intent=$false;Applied=$false;Assessed=$false;EndSeen=$false;Final=$false;Cancelled=$false;Reason='';Outcome=$null;
        BeforeBytes=$null;AfterBytes=$null;ResidentDropBytes=$null;ActionElapsed=$null;PrivateCommitDeltaBytes=$null;SecondsAfterAction=$null;LastElapsed=$null;
        CausationEstablished=$false;ApplicationLatencyMeasured=$false;InternalCacheReleaseVerified=$false;Error=''}
}
function Update-AmeReductionState($State,$Event) {
    $type=[string]$Event.type
    if($State.EndSeen){throw 'Evento dopo la fine del controller.'}
    if($type -eq 'recover_session'){
        $chosen=@($Event.selected);$images=@($Event.allowed_images)
        if($State.SessionVerified -or $Event.engine_revision -ne 'R10' -or $Event.single_test -ne $true -or $chosen.Count -ne 1 -or $images.Count -ne 1 -or
           ([string]$chosen[0].pid+':'+[string]$chosen[0].creation_filetime) -cne [string]$State.Target.Key -or
           ![string]::Equals([string]$images[0],[string]$State.Target.Path,[StringComparison]::OrdinalIgnoreCase) -or $Event.observation_target_seconds -ne 300){throw 'Controller o identita della sessione diversi dalla richiesta.'}
        $State.SessionVerified=$true;$State.Phase='waiting';$State.Message='Controller avviato. Attendo idoneita e 60 secondi consecutivi di bassa attivita.';return
    }
    if(!$State.SessionVerified){throw 'Evento prima della verifica della sessione nativa.'}
    if($type -eq 'sample' -or $type -eq 'recover_state'){return}
    if($type -eq 'end'){$State.EndSeen=$true;return}
    if($type -notmatch '^recover_'){throw 'Evento non previsto per questa operazione.'}
    if([string]$Event.pid -cne ([string]$State.Target.Key).Split(':')[0]){throw 'Evento di un processo diverso dalla richiesta.'}
    if($null -ne $Event.creation_filetime -and ([string]$Event.pid+':'+[string]$Event.creation_filetime) -cne [string]$State.Target.Key){throw 'Identita cambiata nel risultato.'}
    if($null -ne $Event.elapsed_seconds){
        $at=[double]$Event.elapsed_seconds
        if([double]::IsNaN($at) -or [double]::IsInfinity($at) -or $at -lt 0 -or ($null -ne $State.LastElapsed -and $at -lt $State.LastElapsed)){throw 'Tempo del controller non valido.'}
        $State.LastElapsed=$at
    }
    if($type -eq 'recover_target'){
        if(!$State.Applied){$State.Phase='waiting';$State.Reason=[string]$Event.reason;$State.Message=Get-RecoveryTargetStatus $Event}
        elseif(!$State.Assessed -and $null -ne $Event.private_resident_bytes -and $null -ne $State.BeforeBytes){
            if([double]::IsNaN([double]$Event.private_resident_bytes) -or [double]::IsInfinity([double]$Event.private_resident_bytes) -or [double]$Event.private_resident_bytes -lt 0){throw 'RAM residente negativa.'}
            $State.AfterBytes=$Event.private_resident_bytes;$State.ResidentDropBytes=[double]$State.BeforeBytes-[double]$State.AfterBytes
            $State.SecondsAfterAction=[double]$Event.elapsed_seconds-[double]$State.ActionElapsed
            $State.Message=('RAM privata: {0:N1} -> {1:N1} MiB; {2:+0.0;-0.0;0.0} MiB in meno, dopo {3:N0} s. Verifica fino a 300 s.' -f ($State.BeforeBytes/1MB),($State.AfterBytes/1MB),($State.ResidentDropBytes/1MB),$State.SecondsAfterAction)
        }
    }elseif($type -eq 'recover_intent'){
        if($State.Intent -or $State.Applied){throw 'Secondo tentativo non consentito.'};$State.Intent=$true;$State.Message='Tentativo registrato. Attendo l esito Windows.'
    }elseif($type -eq 'recover_applied'){
        if(!$State.Intent -or $State.Applied -or $State.Assessed){throw 'Conferma azione duplicata o senza intento.'}
        $State.Applied=$true;$State.ActionElapsed=$Event.elapsed_seconds;$State.Phase='measuring';$State.Message='Intervento Windows applicato. La riduzione della RAM deve ancora essere misurata.'
    }elseif($type -eq 'recover_feedback'){
        if(!$State.Applied){throw 'Misura senza intervento confermato.'}
        foreach($name in @('private_resident_before_bytes','private_resident_after_bytes','seconds_after_action')){
            $v=$Event.$name;if($null -eq $v -or [double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v) -or $v -lt 0){throw 'Misura RAM incompleta o non valida.'}
        }
        if($Event.seconds_after_action -gt 600){throw 'Durata feedback non valida.'}
        if($null -ne $State.BeforeBytes -and [double]$State.BeforeBytes -ne [double]$Event.private_resident_before_bytes){throw 'Baseline RAM cambiata.'}
        $State.BeforeBytes=$Event.private_resident_before_bytes;$State.AfterBytes=$Event.private_resident_after_bytes
        $State.ResidentDropBytes=[double]$State.BeforeBytes-[double]$State.AfterBytes;$State.PrivateCommitDeltaBytes=$Event.private_commit_delta_bytes;$State.SecondsAfterAction=$Event.seconds_after_action
        $State.Message=('RAM privata: {0:N1} -> {1:N1} MiB; {2:+0.0;-0.0;0.0} MiB in meno, dopo {3:N0} s. Verifica fino a 300 s.' -f ($State.BeforeBytes/1MB),($State.AfterBytes/1MB),($State.ResidentDropBytes/1MB),$State.SecondsAfterAction)
    }elseif($type -eq 'recover_assessed'){
        if(!$State.Applied -or $State.Assessed -or ![string]::Equals([string]$Event.image_path,[string]$State.Target.Path,[StringComparison]::OrdinalIgnoreCase)){throw 'Valutazione senza azione o per percorso diverso.'}
        foreach($name in @('seconds_after_action','remaining_private_resident_reduction_bytes','minimum_private_resident_reduction_last_60s_bytes')){
            $v=$Event.$name;if($null -eq $v -or [double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v) -or $v -lt 0){throw 'Valutazione con metriche mancanti o non valide.'}
        }
        $reason=[string]$Event.reason
        $positive=@('resident_reduction_retained_5m','resident_reduction_retained_5m_with_activity','resident_reduction_retained_5m_after_resume')
        $negative=@('rapid_resident_rebound','no_meaningful_resident_reduction','resident_reduction_not_retained_5m')
        if($reason -notin ($positive+$negative)){throw 'Valutazione finale non riconosciuta.'}
        if($reason -in $positive -and ($null -eq $Event.seconds_after_action -or [double]$Event.seconds_after_action -lt 300 -or
           $null -eq $Event.minimum_private_resident_reduction_last_60s_bytes -or [double]$Event.minimum_private_resident_reduction_last_60s_bytes -lt 16MB)){throw 'Riduzione mantenuta dichiarata senza misura sufficiente.'}
        $State.Assessed=$true;$State.Phase='assessed';$State.Reason=$reason;$State.Outcome=$Event;$State.Message=Get-RecoveryOutcomeStatus $Event
    }elseif($type -eq 'recover_no_action'){
        if($State.Applied -or $State.Intent){throw 'Nessuna azione incoerente con la richiesta.'};$State.Phase='no_action';$State.Message='Nessun intervento eseguito entro il tempo previsto. Ultima attesa: '+$State.Message
    }elseif($type -eq 'recover_incomplete'){
        $State.Phase='incomplete';$State.Reason=[string]$Event.reason;$State.Message='Osservazione incompleta: nessun beneficio mantenuto confermato.'
    }elseif($type -in @('recover_usage_warning','recover_activity_warning')){
        $State.Message='Intervento gia applicato: attivita o primo piano cambiati, continuo soltanto la misura.'
    }elseif($type -in @('recover_skipped','recover_guard')){
        $State.Reason=[string]$Event.reason;$State.Message='Controller: '+[string]$Event.reason
    }else{throw 'Evento di recupero non previsto.'}
}
function Complete-AmeReductionState($State,[int]$ExitCode) {
    $State.Final=$true
    if($ExitCode -ne 0 -or $State.Error){$State.Phase='error';$State.Message='Controller terminato con errore. '+$State.Error}
    elseif(!$State.SessionVerified -or !$State.EndSeen -or ($State.Applied -and !$State.Assessed) -or ($State.Intent -and !$State.Applied)){$State.Phase='incomplete';$State.Message='Misura incompleta. Intervento confermato: '+$State.Applied+'. Nessun risultato duraturo verificato.'}
    elseif(!$State.Applied){$State.Phase='no_action';$State.Message='Nessun intervento applicato. '+$State.Message}
}
function Get-AmeProcessTarget {
    param([Parameter(Mandatory=$true)]$Connection,[Parameter(Mandatory=$true)][uint32]$ProcessId)
    if(!$Connection.Ready -or !$Connection.Client){throw 'API nativa AME non disponibile.'}
    $identity=$Connection.Client.Read($ProcessId)
    return [pscustomobject]@{Pid=$identity.Pid;Key=([string]$identity.Pid+':'+[string]$identity.Creation);Path=$identity.Path;Name=[IO.Path]::GetFileName($identity.Path)}
}
function Start-AmeProcessReduction {
    param([Parameter(Mandatory=$true)]$Target,[Parameter(Mandatory=$true)]$Connection,[string]$Root=$PSScriptRoot)
    if($env:OS -ne 'Windows_NT' -or [IntPtr]::Size -ne 8){throw 'Il comando richiede Windows x64.'}
    if(!$Connection.Ready -or !$Connection.Client){throw 'API nativa AME non disponibile.'}
    $validation=Get-Content -LiteralPath (Join-Path $Root 'build/windows-validation.json') -Raw|ConvertFrom-Json
    if($validation.engine_revision -ne 'R10' -or $validation.panel_revision -ne 'R22' -or
       $validation.exe_sha256 -ne (Get-FileHash -LiteralPath (Join-Path $Root 'build/ame.exe')).Hash -or
       $validation.support_hashes.'process-reduction-api.ps1' -ne (Get-FileHash -LiteralPath (Join-Path $Root 'process-reduction-api.ps1')).Hash){throw 'Comando AME da verificare: apri prima RIDUCI_PROCESSO.cmd.'}
    $history=Join-Path $Root 'reports/recovery-history.json';$blocked=Get-RecoveryRepeatBlock $history $Target
    if($blocked){throw $blocked}
    $Connection.Client.Validate([string]$Target.Key,[string]$Target.Path)
    $created=$false;$guard=[Threading.Mutex]::new($false,'Local\AME-Process-Hub',[ref]$created)
    if(!$created){$guard.Dispose();throw 'Un pannello o agente AME e gia attivo. Usa quel pannello oppure fermalo prima del comando esterno.'}
    $process=$null
    try{
        $state=New-AmeReductionState $Target;$folder=Join-Path $Root 'reports';[void][IO.Directory]::CreateDirectory($folder)
        $path=Join-Path $folder ('recover-api-'+$state.RequestId+'.jsonl');$stop=$path+'.stop'
        if((Test-Path -LiteralPath $path) -or (Test-Path -LiteralPath $stop)){throw 'Percorso richiesta gia presente.'}
        $info=New-AmeReductionStartInfo -Root $Root -Targets @($Target) -Report $path -StopFile $stop
        $Connection.Client.Validate([string]$Target.Key,[string]$Target.Path)
        if(!('AmeHub.ReportTail' -as [type])){Add-Type -Path (Join-Path $Root 'src/hub-runtime.cs')}
        $process=New-Object Diagnostics.Process;$process.StartInfo=$info
        [void]$process.Start();$process.BeginOutputReadLine();$stderr=$process.StandardError.ReadToEndAsync()
        return [pscustomobject]@{State=$state;Process=$process;ErrorTask=$stderr;Report=$path;StopFile=$stop;Tail=$null;Guard=$guard;History=$history;Clock=[Diagnostics.Stopwatch]::StartNew();Closed=$false}
    }catch{if($process){try{if(!$process.HasExited){[IO.File]::WriteAllText($stop,'stop')}}catch{};$process.Dispose()};$guard.Dispose();throw}
}
function Stop-AmeProcessReduction($Request) {
    if($Request.Closed -or $Request.State.Final){return}
    [IO.File]::WriteAllText($Request.StopFile,'stop');$Request.State.Cancelled=$true
    $Request.State.Message='Arresto richiesto al controller. Un intervento gia applicato non viene annullato.'
}
function Get-AmeProcessReduction($Request) {
    if($Request.Closed){throw 'Richiesta AME gia chiusa.'}
    if($Request.State.Final){return $Request.State}
    try{
        if($Request.Clock.Elapsed.TotalSeconds -gt 490){Stop-AmeProcessReduction $Request;throw 'Tempo massimo della richiesta superato.'}
        if(Test-Path -LiteralPath $Request.Report){
            if((Get-Item -LiteralPath $Request.Report).Length -gt 32MB){throw 'Report oltre il limite previsto.'}
            if(!$Request.Tail){$Request.Tail=New-Object AmeHub.ReportTail($Request.Report)}
            for($chunk=0;$chunk -lt 16 -and $Request.Tail.HasUnreadBytes;$chunk++){
                foreach($line in $Request.Tail.ReadLines()){
                    $event=$line|ConvertFrom-Json
                    Update-AmeReductionState $Request.State $event
                    if($event.type -eq 'recover_assessed'){Save-RecoveryOutcome $Request.History $event @($Request.State.Target)}
                }
            }
        }
        if($Request.Process.HasExited -and (!$Request.Tail -or !$Request.Tail.HasUnreadBytes) -and $Request.ErrorTask.IsCompleted){
            if($Request.Process.ExitCode -ne 0){$detail=[string]$Request.ErrorTask.Result;$Request.State.Error=$detail.Substring(0,[math]::Min(2000,$detail.Length))}
            Complete-AmeReductionState $Request.State $Request.Process.ExitCode
        }
    }catch{
        $Request.State.Error=$_.Exception.Message;$Request.State.Phase='error';$Request.State.Message=$_.Exception.Message
        Stop-AmeProcessReduction $Request
        $Request.State.Phase='error';$Request.State.Message='Errore di verifica, esito non conclusivo: '+$Request.State.Error;$Request.State.Final=$true
    }
    return $Request.State
}
function Close-AmeProcessReduction($Request) {
    if($Request.Closed){return}
    try{
        if(!$Request.Process.HasExited){
            [IO.File]::WriteAllText($Request.StopFile,'stop')
            if(!$Request.Process.WaitForExit(6000)){
                if($Request.Process.Id -eq $Request.State.Target.Pid){throw 'Identita del controller non valida: nessun arresto forzato.'}
                # Only the engine child created by Start-AmeProcessReduction, never the target app.
                $Request.Process.Kill();[void]$Request.Process.WaitForExit(1000)
                $Request.State.Error='Controller AME non risponde allo stop; sola osservazione interrotta.'
            }
        }
        [void](Get-AmeProcessReduction $Request)
    }finally{
        if($Request.Tail){$Request.Tail.Dispose()};$Request.Process.Dispose();$Request.Guard.Dispose();$Request.Clock.Stop();$Request.Closed=$true
    }
}
function Invoke-AmeInternalApiCommand {
    param([Parameter(Mandatory=$true)][hashtable]$Command,[int]$TimeoutMs=3000,[string]$PipeName='AME-Internal-Api-v1',[string]$Root=$PSScriptRoot)
    if(!('AmeHub.InternalApiBusClient' -as [type])){Add-Type -Path (Join-Path $Root 'src/resource-api-client.cs')}
    $payload=$Command|ConvertTo-Json -Depth 6 -Compress
    $raw=[AmeHub.InternalApiBusClient]::SendRequest($payload,$TimeoutMs,$PipeName)
    if(!$raw){throw 'Nessuna risposta dal bus API interno AME.'}
    return $raw|ConvertFrom-Json
}
function Invoke-AmeInternalCompaction {
    param([Parameter(Mandatory=$true)]$Connection,[uint64]$RequestedBytes=64MB)
    if(!$Connection.Ready -or !$Connection.Client){throw 'API nativa AME non disponibile.'}
    $freed=$Connection.Client.CompactCurrentProcess($RequestedBytes)
    return [pscustomobject]@{FreedBytes=$freed;FreedMiB=[math]::Round($freed/1MB,2)}
}
function Invoke-AmeDirectProcessReclaim {
    param([Parameter(Mandatory=$true)]$Connection,[Parameter(Mandatory=$true)]$Target,[uint32]$StageFlags=14)
    if(!$Connection.Ready -or !$Connection.Client){throw 'API nativa AME non disponibile.'}
    $res=$Connection.Client.ExecuteProcessReclaim([string]$Target.Key,[string]$Target.Path,$StageFlags)
    return [pscustomobject]@{
        Pid=$res.Pid
        Name=$Target.Name
        AppliedStages=$res.AppliedStages
        WorkingSetBeforeBytes=$res.WorkingSetBeforeBytes
        WorkingSetAfterBytes=$res.WorkingSetAfterBytes
        WorkingSetDeltaBytes=$res.WorkingSetDeltaBytes
        PrivateCommitBeforeBytes=$res.PrivateCommitBeforeBytes
        PrivateCommitAfterBytes=$res.PrivateCommitAfterBytes
    }
}
function Invoke-AmeDistributedGroupReclaim {
    param([Parameter(Mandatory=$true)]$Connection,[Parameter(Mandatory=$true)][object[]]$Targets,[uint64]$TargetBytes=256MB,[uint32]$StageFlags=14)
    if(!$Connection.Ready -or !$Connection.Client){throw 'API nativa AME non disponibile.'}
    $keys=@($Targets|ForEach-Object {[string]$_.Key})
    $paths=@($Targets|ForEach-Object {[string]$_.Path})
    return $Connection.Client.ExecuteDistributedGroupReclaim($keys,$paths,$TargetBytes,$StageFlags)
}
