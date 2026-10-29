param([uint32]$ProcessId=0)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or [IntPtr]::Size -ne 8){throw 'Usa RIDUCI_PROCESSO.cmd su Windows x64.'}
$existing=$null
try{$existing=[Threading.Mutex]::OpenExisting('Local\AME-Process-Hub')}catch [Threading.WaitHandleCannotBeOpenedException]{}
if($existing){$existing.Dispose();throw 'Un pannello o agente AME e gia attivo. Usa Prova temporanea nel pannello, oppure fermalo prima del comando esterno.'}
& (Join-Path $PSScriptRoot 'avvia.ps1') -ValidateOnly
. (Join-Path $PSScriptRoot 'windows-model.ps1')
. (Join-Path $PSScriptRoot 'resource-api-bridge.ps1')
. (Join-Path $PSScriptRoot 'process-reduction-api.ps1')
$connection=Initialize-ResourceApi $PSScriptRoot
if(!$connection.Ready){throw $connection.Message}
$request=$null
try{
    if(!$ProcessId){
        Write-Host 'Inserisci il PID di un applicazione che puoi lasciare inattiva. Nessuna app viene chiusa.'
        $answer=Read-Host 'PID';if(![uint32]::TryParse($answer,[ref]$ProcessId) -or $ProcessId -le 4){throw 'PID non valido.'}
    }
    $target=Get-AmeProcessTarget -Connection $connection -ProcessId $ProcessId
    Write-Host ('AME - Richiesta di riduzione residente: '+$target.Name+' | PID '+$target.Pid)
    Write-Host 'Lascia l app inattiva; puoi tenere questa console in primo piano. Attesa massima 3 min, poi misura fino a 5 min dall azione.'
    Write-Host 'Ctrl+C richiede lo stop del controller. Un azione gia applicata non puo essere annullata.'
    $request=Start-AmeProcessReduction -Target $target -Connection $connection
    $last=''
    do{
        $state=Get-AmeProcessReduction $request
        if($state.Message -cne $last){Write-Host ((Get-Date -Format 'HH:mm:ss')+' '+$state.Message);$last=$state.Message}
        if(!$state.Final){Start-Sleep -Milliseconds 250}
    }while(!$state.Final)
    Write-Host ('ESITO: '+$state.Phase+' | Intervento confermato: '+$state.Applied)
    Write-Host 'Misura del processo, senza prova di risparmio causale sul PC o maggiore velocita. Cache interne non verificate.'
    Write-Host ('Report: '+$request.Report)
}finally{
    try{if($request){Close-AmeProcessReduction $request}}finally{$connection.Client.Dispose()}
}
