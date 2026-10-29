$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
function Assert($ok,[string]$message){if(!$ok){throw $message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ame API build '+[guid]::NewGuid().ToString('N'))
$previous=Get-Location
$sources=@('sdk/ame_resource_api.h','src/resource_api.cpp','src/resource_analysis.hpp','src/resource_trace.hpp','examples/resource_api_demo.cpp','tests/resource_analysis_tests.cpp','scripts/build-resource-api-msvc.cmd','build-resource-api.ps1')
$artifacts=@('build/ame-resource-api.dll','build/ame-resource-demo.exe','build/ame-resource-analysis-tests.exe')
try{
    foreach($name in $sources){
        $destination=Join-Path $temp $name
        [void][IO.Directory]::CreateDirectory((Split-Path $destination -Parent))
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination $destination
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $temp 'build'))
    foreach($name in $artifacts){[IO.File]::WriteAllText((Join-Path $temp $name),'inert artifact fixture')}
    $sourceHashes=@{};$artifactHashes=@{}
    foreach($name in $sources){$sourceHashes[$name]=(Get-FileHash (Join-Path $temp $name)).Hash}
    foreach($name in $artifacts){$artifactHashes[$name]=(Get-FileHash (Join-Path $temp $name)).Hash}
    $marker=Join-Path $temp 'build/resource-api-validation.json'
    $build=Join-Path $temp 'build-resource-api.ps1'
    Assert (!(& $build -CheckOnly)) 'API senza marker viene dichiarata verificata'
    $valid=@{abi_version=1;api_revision='R1';source_hashes=$sourceHashes;artifact_hashes=$artifactHashes}
    $valid|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $marker -Encoding Ascii
    Assert (& $build -CheckOnly) 'API con sorgenti e artefatti validi non riutilizzata'
    Assert (!(& $build -Force -CheckOnly)) 'Force non invalida la compilazione'
    foreach($name in @('sdk/ame_resource_api.h','src/resource_analysis.hpp','src/resource_trace.hpp','examples/resource_api_demo.cpp','build/ame-resource-api.dll','build/ame-resource-demo.exe','build/ame-resource-analysis-tests.exe')){
        $path=Join-Path $temp $name;$bytes=[IO.File]::ReadAllBytes($path)
        [IO.File]::AppendAllText($path,'changed')
        Assert (!(& $build -CheckOnly)) ('File cambiato mantiene validazione: '+$name)
        [IO.File]::WriteAllBytes($path,$bytes)
        Assert (& $build -CheckOnly) ('File ripristinato non riutilizzato: '+$name)
    }
    $valid.abi_version=2
    $valid|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $marker -Encoding Ascii
    Assert (!(& $build -CheckOnly)) 'ABI diversa accettata'
    $valid.abi_version=1;$valid.api_revision='old'
    $valid|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $marker -Encoding Ascii
    Assert (!(& $build -CheckOnly)) 'Revisione diversa accettata'
    [IO.File]::WriteAllText($marker,'{broken')
    Assert (!(& $build -CheckOnly)) 'Marker danneggiato accettato'
    Write-Host 'PASS API build cache: paths with spaces, source and binary hashes, ABI, revision, force and damaged marker'
}finally{Set-Location -LiteralPath $previous.Path;if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}}
