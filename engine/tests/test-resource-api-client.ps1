param([switch]$NativeWindows)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'process-reduction-api.ps1')
function Assert($ok,[string]$message){if(!$ok){throw $message}}
if(!('AmeHub.ResourceApiClientTests' -as [type])){
    $sources=@((Join-Path $root 'src/resource-api-client.cs'),(Join-Path $PSScriptRoot 'resource_api_client_tests.cs'))
    Add-Type -Path $sources
}
Write-Host ('PASS '+[AmeHub.ResourceApiClientTests]::Run()+' managed API bridge checks')

# Run the actual panel gate with the real managed client and an injected native read.
# These are synthetic identities, not evidence of Windows calls on Linux.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'hub.ps1'),[ref]$tokens,[ref]$errors)
Assert (!$errors.Count) 'Hub parse failure'
foreach($name in @('Assert-ResourceApiTargets','Start-Engine','Begin-Recovery')){
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Assert ($null -ne $fn) ('Missing handler '+$name)
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:apiEvents=New-Object 'Collections.Generic.List[string]'
function Write-PanelEvent([string]$action,[string]$stage,[string]$detail=''){$script:apiEvents.Add($stage)}
function Save-Selection {}
function Get-RecoveryRepeatBlock {return ''}
function Add-Log([string]$message) {}
$script:apiStatus=[pscustomobject]@{Text=''}
$script:apiConnection=[pscustomobject]@{Ready=$true;Client=[AmeHub.ResourceApiClientTests]::ValidClient()}
$target=[pscustomobject]@{Key='22452:134362770626194055';Pid=22452;Path=('D:\Apps con spazi\caff'+[char]0x00e8+'.exe');Blocked=$false}
try{
    Assert-ResourceApiTargets @($target)
    Assert ($apiStatus.Text -like '*22452*verificata*' -and $script:apiEvents[0] -eq 'identity_verified') 'Success not visible or logged'
    $target.Key='22452:134362770626194054'
    $failed=$false;try{Assert-ResourceApiTargets @($target)}catch{$failed=$true}
    Assert ($failed -and $apiStatus.Text -like '*fallita*' -and $script:apiEvents[-1] -eq 'identity_rejected') 'Changed identity accepted'
    $script:runSelection=@($target)
    foreach($mode in @('recover','recover-test')){
        $script:apiEvents.Clear();$failed=$false
        try{Start-Engine $mode}catch{$failed=$true}
        Assert ($failed -and $script:apiEvents.Count -eq 1 -and $script:apiEvents[0] -eq 'identity_rejected') 'Engine dispatched before API identity check'
    }
    $script:apiConnection.Ready=$false
    $failed=$false;try{Assert-ResourceApiTargets @($target)}catch{$failed=$_.Exception.Message -like '*API AME non disponibile*'}
    Assert ($failed) 'Missing API permits mutation'
    # Real click handler must refuse before stopping the observation engine.
    $script:selection=@{$target.Key=$target};$script:lastComplete=[DateTime]::UtcNow
    $script:historyFailure='';$script:batchActive=$false;$script:mode='observe';$script:restartMode=$null;$script:pendingRecoveryMode=$null
    $script:result=[pscustomobject]@{Text=''};$script:state=[pscustomobject]@{Text=''};$script:grid=[pscustomobject]@{Rows=@()}
    foreach($name in @('start','single','pause','clear','duration','stopButton')){Set-Variable -Scope Script -Name $name -Value ([pscustomobject]@{Enabled=$true})}
    Begin-Recovery 'recover-test'
    Assert (!$script:batchActive -and !$script:restartMode -and $result.Text -eq 'Richiesta non avviata.' -and $state.Text -like '*API AME non disponibile*') 'Click accepted without API'
    Write-Host 'PASS actual hub API gates: ready state, selection mismatch, unavailable API, rejection before engine start'
}finally{$script:apiConnection.Client.Dispose()}

. (Join-Path $root 'windows-model.ps1')
$text=Get-RecoveryTargetStatus ([pscustomobject]@{reason='low_activity_under_60_seconds';single_test=$true;low_activity_seconds=0;cpu_percent=0.133;page_faults_per_second=0})
Assert ($text -like '*conteggio ripartito*CPU*') 'Activity reset not explained'
$text=Get-RecoveryTargetStatus ([pscustomobject]@{reason='low_activity_under_60_seconds';single_test=$true;low_activity_seconds=42;cpu_percent=0;page_faults_per_second=0})
Assert ($text -like '*42/60*consecutivi*' -and $text -notlike '*ripartito*') 'Quiet count misrepresented'
Write-Host 'PASS consecutive low-activity wait explanations'

# Initialization reports a missing/unvalidated DLL without exposing a live client.
. (Join-Path $root 'resource-api-bridge.ps1')
$fakeRoot=Join-Path ([IO.Path]::GetTempPath()) ('ame missing api '+[guid]::NewGuid().ToString('N'))
try{
    [void][IO.Directory]::CreateDirectory($fakeRoot)
    [IO.File]::WriteAllText((Join-Path $fakeRoot 'build-resource-api.ps1'),'param([switch]$CheckOnly); return $false')
    $missing=Initialize-ResourceApi $fakeRoot
    Assert (!$missing.Ready -and !$missing.Client -and $missing.Message -like '*Riduzione bloccata*monitoraggio disponibile*') 'Failed API initialization presented as ready'
    Write-Host 'PASS missing API initialization remains observable and blocks recovery'
}finally{if([IO.Directory]::Exists($fakeRoot)){[IO.Directory]::Delete($fakeRoot,$true)}}

if($NativeWindows){
    Assert ($env:OS -eq 'Windows_NT') 'Native API test requires Windows'
    . (Join-Path $root 'resource-api-bridge.ps1')
    $connection=Initialize-ResourceApi $root
    Assert ($connection.Ready) $connection.Message
    try{
        $self=$connection.Client.Read([uint32]$PID)
        $connection.Client.Validate(($PID.ToString()+':'+$self.Creation.ToString()),$self.Path)
        $failed=$false;try{$connection.Client.Validate(($PID.ToString()+':'+($self.Creation-1).ToString()),$self.Path)}catch{$failed=$true}
        Assert ($failed -and $self.Creation -gt 0) 'Real DLL identity check failed'
        $compacted=$connection.Client.CompactCurrentProcess(16MB)
        Assert ($null -ne $compacted) 'Native + Managed internal process compaction failed'
        $pipeName='AME-Internal-Test-'+[guid]::NewGuid().ToString('N')
        $bus=New-Object AmeHub.InternalApiBusServer($pipeName)
        try{
            $job=[AmeHub.InternalApiBusClient]::SendRequestAsync('{"command":"status"}',3000,$pipeName)
            $deadline=[Diagnostics.Stopwatch]::StartNew()
            $handled=$false
            while($deadline.ElapsedMilliseconds -lt 2500 -and !$handled){
                foreach($req in $bus.DrainRequests()){
                    $bus.CompleteRequest($req.Id,'{"ok":true,"mode":"distributed"}')
                    $handled=$true
                }
                if(!$handled){Start-Sleep -Milliseconds 20}
            }
            $reply=$job.GetAwaiter().GetResult()|ConvertFrom-Json
            Assert ($handled -and $reply.ok -eq $true -and $reply.mode -eq 'distributed') 'Internal Named Pipe API Bus roundtrip failed'
        }finally{$bus.Dispose()}
        Write-Host 'PASS real Windows DLL bridge: load, ABI, current process identity, internal compaction, Named Pipe API bus and changed creation refusal'
    }finally{$connection.Client.Dispose()}
}
