function Initialize-ResourceApi([string]$Root) {
    $client=$null
    try {
        $valid=& (Join-Path $Root 'build-resource-api.ps1') -CheckOnly
        if(!$valid){throw 'DLL mancante o cambiata: riapri con AVVIA.cmd.'}
        if(!('AmeHub.ResourceApiClient' -as [type])){Add-Type -Path (Join-Path $Root 'src/resource-api-client.cs')}
        $client=New-Object AmeHub.ResourceApiClient -ArgumentList (Join-Path $Root 'build/ame-resource-api.dll')
        $self=$client.Read([uint32][Diagnostics.Process]::GetCurrentProcess().Id)
        if(!$self.Creation -or !$self.Path){throw 'Verifica iniziale della API fallita.'}
        return [pscustomobject]@{Client=$client;Ready=$true;Message='API AME pronta: verifica identita prima degli interventi. Job Object: solo demo.'}
    }catch{
        if($client){$client.Dispose()}
        return [pscustomobject]@{Client=$null;Ready=$false;Message=('API AME non disponibile: '+$_.Exception.Message+' Riduzione bloccata; monitoraggio disponibile.')}
    }
}
