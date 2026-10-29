param([switch]$NoOpen)
$ErrorActionPreference='Stop'
Set-Location -LiteralPath $PSScriptRoot
. (Join-Path $PSScriptRoot 'export-resource-api-report.ps1')
$id=([DateTime]::Now.ToString('yyyyMMdd-HHmmss'))+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$folder=Join-Path $PSScriptRoot ('reports/api/API-'+$id)
[void][IO.Directory]::CreateDirectory($folder)
$validationTrace=Join-Path $folder 'verifica-compilazione.jsonl'
$tracePath=Join-Path $folder 'esecuzione.jsonl'
$htmlPath=Join-Path $folder 'resoconto.html'
$failure='';$nativeExitCode=-1
try{
    & (Join-Path $PSScriptRoot 'build-resource-api.ps1') -ValidationTrace $validationTrace
    & (Join-Path $PSScriptRoot 'build/ame-resource-demo.exe') --trace-json $tracePath
    $nativeExitCode=$LASTEXITCODE
    if($nativeExitCode -ne 0){throw ('Demo API non completata. Codice uscita: '+$nativeExitCode)}
}catch{
    $failure=$_.Exception.Message
    if(!(Test-Path -LiteralPath $tracePath) -and (Test-Path -LiteralPath $validationTrace)){$tracePath=$validationTrace}
}
$report=Write-ResourceApiReport -TracePath $tracePath -OutputPath $htmlPath -SourceRoot $PSScriptRoot -Failure $failure -NativeExitCode $nativeExitCode
Write-Host ('Resoconto API con operazioni e codice: '+$report)
if(!$NoOpen){
    try{Start-Process -FilePath $report|Out-Null}
    catch{Write-Host 'Apertura automatica non riuscita. Apri resoconto.html nel percorso indicato.'}
}
if($failure){throw $failure}
