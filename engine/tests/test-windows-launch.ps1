param([switch]$NativeEngine,[string]$HubScript)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'process-reduction-api.ps1')
if(!$HubScript){$HubScript=Join-Path $root 'hub.ps1'}
function Assert($ok,[string]$message){if(!$ok){throw $message}}
function Assert-ResourceApiTargets([object[]]$Targets) {}
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($HubScript,[ref]$tokens,[ref]$errors)
Assert (!$errors.Count) 'Pannello non analizzabile'
$fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-Engine'},$true)
Assert ($null -ne $fn) 'Avvio del motore assente'
$definition=[Management.Automation.Language.Parser]::ParseInput($fn.Extent.Text,$HubScript,[ref]$tokens,[ref]$errors)
. $definition.GetScriptBlock()
# Execute the actual GUI launcher with a process substitute, then pass its
# exact Arguments string through a real native PowerShell child process.
$script:fakeEngine=[pscustomobject]@{StartInfo=$null}
$script:fakeEngine|Add-Member ScriptMethod Start { return $true }
$script:fakeEngine|Add-Member ScriptMethod BeginOutputReadLine {}
function New-Object([string]$TypeName) {
    if($TypeName -eq 'Diagnostics.Process'){return $script:fakeEngine}
    return Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName
}
$grid=[pscustomobject]@{Rows=@()}
$single=[pscustomobject]@{Enabled=$false};$pause=[pscustomobject]@{Enabled=$false;Text=''}
$start=[pscustomobject]@{Enabled=$false};$stopButton=[pscustomobject]@{Enabled=$false}
$clear=[pscustomobject]@{Enabled=$false};$state=[pscustomobject]@{Text=''}
$duration=[pscustomobject]@{SelectedItem='5';Enabled=$true}
$script:runSelection=@([pscustomobject]@{Key='123:456';Path='D:\Apps with spaces\app.exe'},[pscustomobject]@{Key='124:789';Path='D:\Apps with spaces\app.exe'})
$exe=Join-Path $root 'build\ame.exe'
function Add-Log([string]$message) {}
$probe=Join-Path ([IO.Path]::GetTempPath()) ('ame launch probe '+[guid]::NewGuid().ToString('N')+'.ps1')
$native=$null; $nativeStarted=$false; $created=@()
function Read-ReceivedArguments([string]$arguments) {
    $info=Microsoft.PowerShell.Utility\New-Object Diagnostics.ProcessStartInfo
    $childName=if($env:OS -eq 'Windows_NT'){if($PSVersionTable.PSEdition -eq 'Desktop'){'powershell.exe'}else{'pwsh.exe'}}else{'pwsh'}
    $info.FileName=Join-Path $PSHOME $childName
    $info.Arguments='-NoProfile -File "'+$probe+'" '+$arguments
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $child=Microsoft.PowerShell.Utility\New-Object Diagnostics.Process
    $child.StartInfo=$info
    $childStarted=$false
    try {
        [void]$child.Start()
        $childStarted=$true
        Assert ($child.WaitForExit(10000)) 'Probe argomenti non terminata'
        $output=$child.StandardOutput.ReadToEnd();$stderr=$child.StandardError.ReadToEnd()
        Assert ($child.ExitCode -eq 0) ('Probe argomenti fallita: '+$stderr)
        # Windows PowerShell 5.1 can emit a JSON array as one pipeline object.
        # Enumerate it explicitly instead of counting the wrapper as one argument.
        $parsed=$output|ConvertFrom-Json
        foreach($argument in $parsed){Write-Output ([string]$argument)}
    } finally {if($childStarted -and !$child.HasExited){$child.Kill()};$child.Dispose()}
}
try {
    [IO.File]::WriteAllText($probe,'ConvertTo-Json -InputObject @($args) -Compress',(Microsoft.PowerShell.Utility\New-Object Text.UTF8Encoding -ArgumentList $true))
    Start-Engine 'observe'
    $observeInfo=$script:fakeEngine.StartInfo
    $observeReport=$script:reportPath;$observeStop=$script:stopFile
    $created+=@($observeReport,$observeStop)
    $received=@(Read-ReceivedArguments $observeInfo.Arguments)
    $expected=@('--observe','--inventory','--seconds','600','--report',$observeReport,'--stop-file',$observeStop)
    Assert ($received.Count -eq $expected.Count) ('Numero argomenti observe errato: ottenuti '+$received.Count+', attesi '+$expected.Count)
    for($i=0;$i -lt $expected.Count;$i++){Assert ($received[$i] -eq $expected[$i]) ('Argomento observe '+$i+' alterato: <'+$received[$i]+'> invece di <'+$expected[$i]+'>')}
    Start-Engine 'recover'
    $created+=@($script:reportPath,$script:stopFile)
    $received=@(Read-ReceivedArguments $script:fakeEngine.StartInfo.Arguments)
    Assert ($received.Count -eq 14) 'Identita o immagini selezionate accorpate/perse'
    Assert ($received[0] -eq '--recover' -and $received[3] -eq '300') 'Modo o durata del recupero errati'
    Assert ($received[8] -eq '--allow-process' -and $received[9] -eq '123:456' -and $received[11] -eq '124:789') 'Identita selezionate alterate'
    Assert ($received[12] -eq '--allow-exe' -and $received[13] -eq 'D:\Apps with spaces\app.exe') 'Percorso con spazi alterato o duplicato'
    $script:runSelection=@($script:runSelection[0])
    Start-Engine 'recover-test'
    $created+=@($script:reportPath,$script:stopFile)
    $received=@(Read-ReceivedArguments $script:fakeEngine.StartInfo.Arguments)
    Assert ($received.Count -eq 12 -and $received[0] -eq '--recover-test' -and $received[3] -eq '180') 'Prova singola: argomenti o limite errati'
    Assert ($received[9] -eq '123:456' -and $received[11] -eq 'D:\Apps with spaces\app.exe') 'Prova singola: selezione errata'
    Write-Host 'PASS actual GUI launch arguments: observe, recover, identities and paths with spaces'
    if($NativeEngine) {
        if($env:OS -ne 'Windows_NT'){throw 'Il motore nativo richiede Windows.'}
        $native=Microsoft.PowerShell.Utility\New-Object Diagnostics.Process
        $native.StartInfo=$observeInfo
        [void]$native.Start()
        $nativeStarted=$true
        $stdout=$native.StandardOutput.ReadToEndAsync();$stderr=$native.StandardError.ReadToEndAsync()
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while(!$native.HasExited -and [DateTime]::UtcNow -lt $deadline){
            if((Test-Path -LiteralPath $observeReport) -and (Get-Item -LiteralPath $observeReport).Length -gt 0){break}
            Start-Sleep -Milliseconds 100
        }
        [IO.File]::WriteAllText($observeStop,'stop')
        Assert ($native.WaitForExit(6000)) 'Arresto observe avviato dal pannello non riuscito'
        Assert ($native.ExitCode -eq 0) ('Avvio nativo dal pannello fallito: '+$stderr.Result)
        $events=@(Get-Content -LiteralPath $observeReport|ForEach-Object {$_|ConvertFrom-Json})
        $samples=@($events|Where-Object {$_.type -eq 'sample' -and $_.process_snapshot_complete})
        Assert ($samples.Count -ge 1 -and @($samples[0].processes).Count -gt 0) 'Inventario reale del pannello vuoto'
        Assert (!@($events|Where-Object {$_.type -in @('recover_intent','recover_applied','priority_applied','cooperative_release')}).Count) 'Mutazione durante il test di avvio observe'
        Write-Host 'PASS actual GUI arguments launch Windows engine, populate inventory and stop without mutations'
    }
} finally {
    if($native){if($nativeStarted -and !$native.HasExited){$native.Kill()};$native.Dispose()}
    Remove-Item Function:New-Object -ErrorAction SilentlyContinue
    foreach($file in @($probe)+$created){Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue}
}
