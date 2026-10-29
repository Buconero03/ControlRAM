# Connection status is separate from memory intervention outcomes.
function Initialize-BrowserDiagnostics {
    $script:browserLogLines=New-Object 'Collections.Generic.List[string]'
    $script:browserConnectionMessage='Apri Cartella Chrome o Cartella Firefox per caricare l estensione 0.5.0 di questa installazione.'
    $script:browserConnectionCode='waiting'
    $script:browserReportSequence=0L
    $script:browserReportBytes=0L
    $script:browserLogFailure=''
    $script:browserWriter=$null
    $script:browserReportPath=$null
}
function Write-BrowserEvent($event) {
    if($script:browserLogFailure){return}
    try {
        if(!$script:browserWriter){
            $folder=if($script:browserReportsDirectory){$script:browserReportsDirectory}else{Join-Path $PSScriptRoot 'reports'}
            [void][IO.Directory]::CreateDirectory($folder)
            $script:browserReportPath=Join-Path $folder ('browser-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.jsonl')
            $script:browserWriter=New-Object IO.StreamWriter($script:browserReportPath,$false,(New-Object Text.UTF8Encoding($false)))
            $script:browserWriter.AutoFlush=$true
        }
        $event.utc=[DateTime]::UtcNow.ToString('o');$event.sequence=++$script:browserReportSequence
        $line=$event|ConvertTo-Json -Depth 8 -Compress
        $bytes=[Text.Encoding]::UTF8.GetByteCount($line)+2
        if($script:browserReportBytes+$bytes -gt 4MB){throw 'Registro arrivato al limite di 4 MiB: esporta la diagnosi e riapri AME.'}
        $script:browserWriter.WriteLine($line);$script:browserReportBytes+=$bytes
    } catch {
        $script:browserLogFailure='Diagnosi su file non disponibile: '+$_.Exception.Message
        Add-HubLog $script:browserLogFailure
        Update-BrowserConnectionDisplay
    }
}
function Get-BrowserConnectionSummary {
    $lines=@()
    foreach($name in @('Chrome','Firefox')){
        $all=@($script:profiles.Values|Where-Object {($_.Browser -eq $name) -or ($name -eq 'Chrome' -and !$_.Browser)})
        $ready=@($all|Where-Object {$_.Ready -and $_.Seen -ge [DateTime]::UtcNow.AddSeconds(-30)})
        $waiting=@($all|Where-Object {!$_.Ready})
        if($ready.Count){
            $tabs=0;foreach($p in $ready){$tabs+=@($p.Tabs).Count}
            $lines+=($name+': COLLEGATO | '+$ready.Count+' profili | '+$tabs+' schede ricevute')
        }elseif($waiting.Count){$lines+=($name+': IN COLLEGAMENTO - attendo le schede (massimo 15 secondi)')}
        else{$lines+=($name+': NON COLLEGATO - nessun elenco confermato')}
    }
    return $lines -join "`r`n"
}
function Update-BrowserConnectionDisplay {
    if($script:browserLabel){
        $ready=@($script:profiles.Values|Where-Object {$_.Ready}).Count
        $waiting=@($script:profiles.Values|Where-Object {!$_.Ready}).Count
        $script:browserLabel.Text=(Get-BrowserConnectionSummary)+"`r`n"+$script:browserConnectionMessage+"`r`n"+'Profili pronti: '+$ready+' | In sincronizzazione: '+$waiting+' | Schede scaricate: '+$script:browserConfirmed
        if($script:browserLogFailure){$script:browserLabel.Text+="`r`n"+$script:browserLogFailure}
    }
    if($script:browserLogBox){$script:browserLogBox.Text=$script:browserLogLines -join "`r`n"}
    if($script:mainBrowserLogBox){
        $ready=@($script:profiles.Values|Where-Object {$_.Ready}).Count
        $waiting=@($script:profiles.Values|Where-Object {!$_.Ready}).Count
        $summary=Get-BrowserConnectionSummary
        $summary+="`r`n"+'Profili pronti: '+$ready+' | In sincronizzazione: '+$waiting
        $lines=@($script:browserLogLines)
        [array]::Reverse($lines)
        $visible=$summary+"`r`n"+$script:browserConnectionMessage
        if($script:browserLogFailure){$visible+="`r`n"+$script:browserLogFailure}
        if($lines.Count){$visible+="`r`n"+($lines -join "`r`n")}
        if($script:mainBrowserLogBox.Text -ne $visible){$script:mainBrowserLogBox.Text=$visible}
    }
}
function Set-BrowserConnectionStatus([string]$Code,[string]$Message,[int]$Connection=0,[string]$Level='info') {
    $script:browserConnectionCode=$Code;$script:browserConnectionMessage=$Message
    if(!$script:browserLogLines){$script:browserLogLines=New-Object 'Collections.Generic.List[string]'}
    $line=(Get-Date -Format 'HH:mm:ss')+' ['+$Code+'] '+$Message
    $script:browserLogLines.Add($line)
    while($script:browserLogLines.Count -gt 100){$script:browserLogLines.RemoveAt(0)}
    Add-HubLog $line
    Write-BrowserEvent @{type='browser_connection';code=$Code;message=$Message;connection=$Connection;level=$Level}
    Update-BrowserConnectionDisplay
}
function Get-BrowserManifestStatus([string]$RegisteredPath,[string]$Root,[ValidateSet('Chrome','Firefox')][string]$Browser='Chrome') {
    $expected=[IO.Path]::GetFullPath((Join-Path $Root ('build/'+$Browser.ToLowerInvariant()+'-native-host.json')))
    if(!$RegisteredPath){return [pscustomobject]@{Ready=$false;Reason='Registrazione assente';Path=''}}
    if(![string]::Equals($RegisteredPath,$expected,[StringComparison]::OrdinalIgnoreCase)){
        return [pscustomobject]@{Ready=$false;Reason='Registrazione rivolta a un altra cartella';Path=$RegisteredPath}
    }
    try {
        if((Get-Item -LiteralPath $RegisteredPath).Length -gt 64KB){throw 'Manifest troppo grande'}
        $m=Get-Content -LiteralPath $RegisteredPath -Raw|ConvertFrom-Json
        $config=Get-Content -LiteralPath (Join-Path $Root 'browser/config.json') -Raw|ConvertFrom-Json
        $exe=[IO.Path]::GetFullPath((Join-Path $Root 'build/ame-browser-host.exe'))
        $allowed=if($Browser -eq 'Firefox'){@($m.allowed_extensions).Count -eq 1 -and $m.allowed_extensions[0] -ceq $config.firefox_extension_id}else{@($m.allowed_origins).Count -eq 1 -and $m.allowed_origins[0] -ceq ('chrome-extension://'+$config.extension_id+'/')}
        if($m.name -ne $config.host -or $m.type -ne 'stdio' -or ![string]::Equals([string]$m.path,$exe,[StringComparison]::OrdinalIgnoreCase) -or
           !$allowed -or !(Test-Path -LiteralPath $exe)){
            throw 'Manifest, ID estensione o eseguibile non corrispondono a questa installazione'
        }
        return [pscustomobject]@{Ready=$true;Reason='Registrazione corretta';Path=$RegisteredPath}
    }catch{return [pscustomobject]@{Ready=$false;Reason=$_.Exception.Message;Path=$RegisteredPath}}
}
function Get-BrowserRegistration([string]$Root=$PSScriptRoot,[ValidateSet('Chrome','Firefox')][string]$Browser='Chrome') {
    if($env:OS -ne 'Windows_NT'){throw 'La registrazione del browser richiede Windows.'}
    $config=Get-Content -LiteralPath (Join-Path $Root 'browser/config.json') -Raw|ConvertFrom-Json
    $results=@()
    foreach($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)){
        $registryPath=if($Browser -eq 'Firefox'){'Software\Mozilla\NativeMessagingHosts\'}else{'Software\Google\Chrome\NativeMessagingHosts\'}
        $base=$null;$entry=$null
        try {
            $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,$view)
            $entry=$base.OpenSubKey($registryPath+$config.host)
            $path=if($entry){[string]$entry.GetValue('')}else{''}
            $state=Get-BrowserManifestStatus $path $Root $Browser
            $results+=@([pscustomobject]@{View=$view.ToString();Ready=$state.Ready;Reason=$state.Reason;Path=$state.Path})
        }finally{if($entry){$entry.Dispose()};if($base){$base.Dispose()}}
    }
    return [pscustomobject]@{Browser=$Browser;Ready=(@($results|Where-Object {!$_.Ready}).Count -eq 0);Views=$results}
}
function Check-BrowserRegistration {
    try {
        $results=@((Get-BrowserRegistration -Browser Chrome),(Get-BrowserRegistration -Browser Firefox))
        $r=[pscustomobject]@{Ready=(@($results|Where-Object {!$_.Ready}).Count -eq 0);Views=$results}
        Write-BrowserEvent @{type='browser_registration';ready=$r.Ready;views=$r.Views}
        if($r.Ready){Set-BrowserConnectionStatus 'registration_ok' 'Registrazione Windows pronta. NON significa che il browser e collegato: attendi COLLEGATO sopra. Estensione richiesta: 0.5.0.'}
        else{Set-BrowserConnectionStatus 'registration_mismatch' 'Registrazione Chrome o Firefox assente/diversa. Premi Ripara collegamento; poi carica le estensioni dalle cartelle aperte da questo pannello.' 0 'warning'}
        return $r.Ready
    }catch{Set-BrowserConnectionStatus 'registration_error' ('Verifica collegamento fallita: '+$_.Exception.Message) 0 'error';return $false}
}
function Export-BrowserDiagnosis([string]$OutputDirectory=(Join-Path $PSScriptRoot 'exports'),[switch]$NoOpen) {
    $temporary=$null
    try {
        Write-BrowserEvent @{type='browser_diagnostic_export';connection_state=$script:browserConnectionCode;profiles=@($script:profiles.Keys);log_failure=$script:browserLogFailure}
        # Include the visible log even when the ordinary report could not be written.
        $temporary=Join-Path ([IO.Path]::GetTempPath()) ('browser-visible-'+[guid]::NewGuid().ToString('N')+'.jsonl')
        $snapshot=@{type='browser_visible_log';utc=[DateTime]::UtcNow.ToString('o');connection_state=$script:browserConnectionCode;message=$script:browserConnectionMessage;log_failure=$script:browserLogFailure;lines=@($script:browserLogLines.ToArray())}
        [IO.File]::WriteAllText($temporary,(($snapshot|ConvertTo-Json -Depth 5 -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))
        $report=@($temporary)
        if($script:browserReportPath -and (Test-Path -LiteralPath $script:browserReportPath)){$report+=@($script:browserReportPath)}
        $output=& (Join-Path $PSScriptRoot 'export-diagnostics.ps1') -Report $report -OutputDirectory $OutputDirectory
        Set-BrowserConnectionStatus 'diagnostic_exported' ('Diagnosi salvata: '+$output.Path)
        if(!$NoOpen){Start-Process explorer.exe -ArgumentList ('/select,"'+$output.Path+'"')}
        return $output.Path
    }catch{Set-BrowserConnectionStatus 'export_failed' ('Esportazione fallita: '+$_.Exception.Message) 0 'error'}
    finally{if($temporary -and (Test-Path -LiteralPath $temporary)){Remove-Item -LiteralPath $temporary -Force}}
}
