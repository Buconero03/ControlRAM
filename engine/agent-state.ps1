function Get-AgentDirectory {return Join-Path $PSScriptRoot 'reports/agent'}
function Read-AgentJson([string]$Path,[long]$Limit=1MB) {
    if(!(Test-Path -LiteralPath $Path)){return $null}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try{
        if($stream.Length -gt $Limit){throw 'File stato oltre il limite.'}
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        try{return $reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
    }finally{$stream.Dispose()}
}
function Write-AgentJson([string]$Path,$Value,[long]$Limit=1MB) {
    $encoding=New-Object Text.UTF8Encoding($false);$json=$Value|ConvertTo-Json -Depth 12
    if($encoding.GetByteCount($json) -gt $Limit){throw 'File stato oltre il limite.'}
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,$json,$encoding)
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Get-AgentLiveStatus {
    $s=Read-AgentJson (Join-Path (Get-AgentDirectory) 'status.json') 256KB
    if(!$s){return $null}
    $s|Add-Member NoteProperty identity_alive $false -Force
    $s|Add-Member NoteProperty responding $false -Force
    try{
        if(![string]::Equals([IO.Path]::GetFullPath([string]$s.root),[IO.Path]::GetFullPath($PSScriptRoot),[StringComparison]::OrdinalIgnoreCase)){return $s}
        $p=[Diagnostics.Process]::GetProcessById([int]$s.process_id)
        try{
            $expected=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
            if(([string]($p.StartTime.ToFileTimeUtc())) -ceq [string]$s.creation_filetime -and [string]::Equals($p.MainModule.FileName,$expected,[StringComparison]::OrdinalIgnoreCase)){
                $s.identity_alive=$true
                $heartbeat=if($s.heartbeat_utc -is [DateTime]){$s.heartbeat_utc.ToUniversalTime()}else{[DateTimeOffset]::Parse([string]$s.heartbeat_utc).UtcDateTime}
                $age=([DateTime]::UtcNow-$heartbeat).TotalSeconds
                $s.responding=$age -ge 0 -and $age -le 20
            }
        }finally{$p.Dispose()}
    }catch{}
    return $s
}
function Invoke-FullSystemRestore {
    try{
        if(!('AmeHub.ResourceApiClient' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'src/resource-api-client.cs')}
        return [AmeHub.ResourceApiClient]::RestoreAllUserSessionProcesses()
    }catch{return 0}
}
function Request-AgentStop {
    $s=Get-AgentLiveStatus
    $wasAlive=($null -ne $s -and $s.identity_alive)
    if($wasAlive){
        $run=[guid]::Empty
        if([guid]::TryParse([string]$s.run_id,[ref]$run)){
            Write-AgentJson (Join-Path (Get-AgentDirectory) 'stop.json') @{run_id=$run.ToString('D');requested_utc=[DateTime]::UtcNow.ToString('o')} 4096
            for($i=0;$i -lt 12;$i++){
                Start-Sleep -Milliseconds 200
                $chk=Get-AgentLiveStatus
                if(!$chk -or !$chk.identity_alive){break}
            }
        }
    }
    [void](Invoke-FullSystemRestore)
    return $wasAlive
}
function Assert-AgentValidated {
    $path=Join-Path $PSScriptRoot 'build/windows-validation.json'
    $v=Read-AgentJson $path
    if(!$v -or $v.panel_revision -ne 'R22' -or $v.engine_revision -ne 'R10' -or $v.browser_revision -ne 'R19' -or !$v.browser_host_validated){throw 'Avvia prima AUTOMATICO.cmd: build e collegamento devono essere verificati.'}
    foreach($pair in @(@('build/ame.exe','exe_sha256'),@('src/hub-runtime.cs','runtime_sha256'),@('build/ame-browser-host.exe','browser_host_sha256'))){
        if($v.($pair[1]) -ne (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $pair[0])).Hash){throw 'Build modificata: avvia AUTOMATICO.cmd per verificarla.'}
    }
    foreach($file in @('agent.ps1','agent-state.ps1','agent-model.ps1','agent-runtime.ps1','start-agent.ps1','agent-control.ps1','agent-dashboard.ps1','comparison-controller.ps1','src/comparison-metrics.cs','browser/chrome/background.js','browser/chrome/policy.js','browser/firefox/background.js','browser/firefox/policy.js')){
        if($v.support_hashes.$file -ne (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $file)).Hash){throw 'Agente aggiornato: avvia AUTOMATICO.cmd per verificarlo.'}
    }
}
