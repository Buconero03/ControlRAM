$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
function Assert($ok,[string]$message){if(!$ok){throw $message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ame API launch '+[guid]::NewGuid().ToString('N'))
$previous=Get-Location
$global:AME_API_LAUNCH_TEST_OPENED=New-Object 'Collections.Generic.List[string]'
function Start-Process {param([string]$FilePath);[void]$global:AME_API_LAUNCH_TEST_OPENED.Add($FilePath)}
try{
    foreach($folder in @('build','src','sdk','examples')){[void][IO.Directory]::CreateDirectory((Join-Path $temp $folder))}
    foreach($name in @('demo-resource-api.ps1','export-resource-api-report.ps1','src/resource_api.cpp','src/resource_analysis.hpp','src/resource_trace.hpp','sdk/ame_resource_api.h','examples/resource_api_demo.cpp')){
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $temp $name)
    }
    $builder=Join-Path $temp 'build-resource-api.ps1'
    [IO.File]::WriteAllText($builder,'param([string]$ValidationTrace); if(!$ValidationTrace){throw "Missing validation trace argument"}',(New-Object Text.UTF8Encoding($true)))
    if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
        foreach($name in @('ame-resource-demo.exe','ame-resource-api.dll')){
            $source=Join-Path $root ('build/'+$name)
            if(!(Test-Path -LiteralPath $source)){throw 'Compila prima l API per il test di avvio Windows.'}
            Copy-Item -LiteralPath $source -Destination (Join-Path $temp ('build/'+$name))
        }
    }else{
        # An actual child executable checks argv on Linux; it performs no Windows operations.
        $shim=@'
#!/usr/bin/env python3
import json, pathlib, sys
assert len(sys.argv) == 3 and sys.argv[1] == "--trace-json", sys.argv
path = pathlib.Path(sys.argv[2])
assert " " in str(path), path
records = [
 {"seq":1,"type":"session_start","elapsed_ms":0,"phase":"setup","trace_version":1,"api_abi":1,"data_origin":"synthetic_test"},
 {"seq":2,"type":"session_end","elapsed_ms":1,"phase":"capacity","passed":True,"checks":0,"error":""}
]
path.write_text("".join(json.dumps(x)+"\n" for x in records), encoding="utf-8")
print("PASS synthetic CLI fixture: trace argument with spaces")
'@
        $exe=Join-Path $temp 'build/ame-resource-demo.exe'
        [IO.File]::WriteAllText($exe,$shim+"`n",(New-Object Text.UTF8Encoding($false)))
        & chmod 700 $exe
        if($LASTEXITCODE -ne 0){throw 'Cannot enable test fixture executable'}
    }
    $launcher=Join-Path $temp 'demo-resource-api.ps1'
    & $launcher
    Assert ($global:AME_API_LAUNCH_TEST_OPENED.Count -eq 1 -and (Test-Path -LiteralPath $global:AME_API_LAUNCH_TEST_OPENED[0])) 'Il launcher non apre il resoconto creato'
    $first=$global:AME_API_LAUNCH_TEST_OPENED[0]
    $json=Join-Path (Split-Path $first -Parent) 'esecuzione.jsonl'
    Assert ((Test-Path -LiteralPath $json) -and [IO.File]::ReadAllText($first).Contains('Codice sorgente consultabile')) 'Registro o codice mancanti nel resoconto'
    & $launcher -NoOpen
    Assert ($global:AME_API_LAUNCH_TEST_OPENED.Count -eq 1) 'NoOpen ignorato'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $temp 'reports/api') -Directory).Count -eq 2) 'Una nuova esecuzione sovrascrive il registro precedente'
    [IO.File]::WriteAllText($builder,'param([string]$ValidationTrace); throw "Expected build failure"',(New-Object Text.UTF8Encoding($true)))
    $failed=$false
    try{& $launcher}catch{$failed=$_.Exception.Message -eq 'Expected build failure'}
    Assert ($failed -and $global:AME_API_LAUNCH_TEST_OPENED.Count -eq 2) 'Errore di compilazione non mostrato nel resoconto'
    $last=[IO.File]::ReadAllText($global:AME_API_LAUNCH_TEST_OPENED[1])
    Assert ($last.Contains('Expected build failure') -and $last.Contains('Nessuna chiamata nativa registrata') -and $last.Contains('DEMO NON COMPLETATA')) 'Errore senza chiamate presentato come prova eseguita'
    Write-Host 'PASS actual API launcher: child arguments with spaces, automatic report opening, NoOpen, separate sessions and build-failure report'
}finally{Remove-Variable -Name AME_API_LAUNCH_TEST_OPENED -Scope Global -ErrorAction SilentlyContinue;Set-Location -LiteralPath $previous.Path;if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}}
