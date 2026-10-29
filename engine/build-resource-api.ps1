param([switch]$Force,[switch]$CheckOnly,[string]$ValidationTrace='')
$ErrorActionPreference='Stop'
Set-Location -LiteralPath $PSScriptRoot
if([IntPtr]::Size -ne 8){throw 'L API nativa AME richiede PowerShell Windows a 64 bit.'}
$names=@('sdk/ame_resource_api.h','src/resource_api.cpp','src/resource_analysis.hpp','src/resource_trace.hpp','examples/resource_api_demo.cpp','tests/resource_analysis_tests.cpp','scripts/build-resource-api-msvc.cmd','build-resource-api.ps1')
$hashes=@{}
foreach($name in $names){$hashes[$name]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash}
$artifacts=@('build/ame-resource-api.dll','build/ame-resource-demo.exe','build/ame-resource-analysis-tests.exe')
$marker=Join-Path $PSScriptRoot 'build/resource-api-validation.json'
$valid=$false
if(!$Force -and (Test-Path -LiteralPath $marker)){
    try{
        $m=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json
        $valid=$m.abi_version -eq 1 -and $m.api_revision -eq 'R1'
        foreach($name in $names){$valid=$valid -and $m.source_hashes.$name -eq $hashes[$name]}
        foreach($name in $artifacts){
            $valid=$valid -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name))
            if($valid){$valid=$m.artifact_hashes.$name -eq (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash}
        }
    }catch{$valid=$false}
}
if($CheckOnly){return [bool]$valid}
if($valid){Write-Host 'API nativa AME R1 gia compilata e verificata.';return}
Write-Host 'Compilo l API nativa AME e verifico i Job Object su soli processi della demo.'
if(Get-Command cl.exe -ErrorAction SilentlyContinue){
    & (Join-Path $PSScriptRoot 'scripts/build-resource-api-msvc.cmd')
    if($LASTEXITCODE -ne 0){throw 'Compilazione API MSVC fallita. Chiudi eventuali demo AME aperte.'}
}else{
    $install=$null
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if(Test-Path -LiteralPath $vswhere){$install=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath}
    if($install){
        & (Join-Path $PSScriptRoot 'scripts/build-resource-api-msvc.cmd') (Join-Path $install 'VC/Auxiliary/Build/vcvars64.bat')
        if($LASTEXITCODE -ne 0){throw 'Compilazione API MSVC fallita. Chiudi eventuali demo AME aperte.'}
    }elseif(Get-Command g++.exe -ErrorAction SilentlyContinue){
        [void][IO.Directory]::CreateDirectory((Join-Path $PSScriptRoot 'build'))
        $flags=@('-std=c++17','-O2','-Wall','-Wextra','-Wpedantic','-Werror','-D_WIN32_WINNT=0x0A00','-DWIN32_LEAN_AND_MEAN','-DNOMINMAX','-DUNICODE','-D_UNICODE')
        & g++.exe @flags -DAME_RESOURCE_API_EXPORTS -shared src/resource_api.cpp -lpsapi -ladvapi32 '-Wl,--out-implib,build/libame-resource-api.a' -o build/ame-resource-api.dll
        if($LASTEXITCODE -ne 0){throw 'Compilazione DLL API MinGW fallita.'}
        & g++.exe @flags examples/resource_api_demo.cpp -municode -Lbuild -lame-resource-api -o build/ame-resource-demo.exe
        if($LASTEXITCODE -ne 0){throw 'Compilazione demo API MinGW fallita.'}
        & g++.exe @flags tests/resource_analysis_tests.cpp -o build/ame-resource-analysis-tests.exe
        if($LASTEXITCODE -ne 0){throw 'Compilazione analisi API MinGW fallita.'}
    }else{throw 'Serve Visual Studio Build Tools con C++ e Windows SDK, oppure MinGW-w64 x64.'}
}
& (Join-Path $PSScriptRoot 'build/ame-resource-analysis-tests.exe')
if($LASTEXITCODE -ne 0){throw 'Verifica analisi API fallita.'}
if($ValidationTrace){& (Join-Path $PSScriptRoot 'build/ame-resource-demo.exe') --self-test --trace-json $ValidationTrace}
else{& (Join-Path $PSScriptRoot 'build/ame-resource-demo.exe') --self-test}
if($LASTEXITCODE -ne 0){throw 'Verifica Job Object API fallita. Il pannello ordinario AME resta avviabile con AVVIA.cmd.'}
$artifactHashes=@{}
foreach($name in $artifacts){$artifactHashes[$name]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash}
@{abi_version=1;api_revision='R1';source_hashes=$hashes;artifact_hashes=$artifactHashes;tested_utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $marker -Encoding Ascii
Write-Host 'API AME pronta: build/ame-resource-api.dll. Esempio: DEMO_API.cmd.'
