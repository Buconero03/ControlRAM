$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if ([IntPtr]::Size -ne 8) { throw 'Usa PowerShell a 64 bit.' }
foreach ($name in @('ame','ame-browser-host')) {
    foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
        try { if ($p.Path -eq (Join-Path $PSScriptRoot ('build\' + $name + '.exe'))) { throw ('Build occupata: chiudi il pannello e scollega la estensione AME prima di ricompilare (' + $name + ').') } }
        catch { if ($_.Exception.Message -like 'Build occupata:*') { throw } }
    }
}
if (Get-Command cl.exe -ErrorAction SilentlyContinue) {
    & "$PSScriptRoot\scripts\build-msvc.cmd"
    if ($LASTEXITCODE -ne 0) { throw 'Build o test MSVC falliti.' }
} else {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $install = $null
    if (Test-Path $vswhere) {
        $install = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
    if ($install) {
        $vcvars = Join-Path $install 'VC\Auxiliary\Build\vcvars64.bat'
        & "$PSScriptRoot\scripts\build-msvc.cmd" $vcvars
        if ($LASTEXITCODE -ne 0) { throw 'Build o test MSVC falliti.' }
    } elseif (Get-Command g++.exe -ErrorAction SilentlyContinue) {
        New-Item -ItemType Directory -Path build -Force | Out-Null
        & g++.exe -std=c++17 -O2 -Wall -Wextra -Wpedantic -D_WIN32_WINNT=0x0A00 -DWIN32_LEAN_AND_MEAN -DNOMINMAX -DUNICODE -D_UNICODE src/main.cpp -municode -lpsapi -lws2_32 -luser32 -ladvapi32 -o build/ame.exe
        if ($LASTEXITCODE -ne 0) { throw 'Build MinGW fallita.' }
        & g++.exe -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -D_WIN32_WINNT=0x0A00 -DWIN32_LEAN_AND_MEAN -DNOMINMAX -DUNICODE -D_UNICODE src/browser_host.cpp -municode -ladvapi32 -o build/ame-browser-host.exe
        if ($LASTEXITCODE -ne 0) { throw 'Build host Chrome fallita.' }
        & g++.exe -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror tests/policy_tests.cpp -o build/ame-policy-tests.exe
        if ($LASTEXITCODE -ne 0) { throw 'Build test fallita.' }
        & .\build\ame-policy-tests.exe
        if ($LASTEXITCODE -ne 0) { throw 'Test falliti.' }
        & g++.exe -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror tests/recover_policy_tests.cpp -o build/ame-recover-tests.exe
        if ($LASTEXITCODE -ne 0) { throw 'Build policy recupero fallita.' }
        & .\build\ame-recover-tests.exe
        if ($LASTEXITCODE -ne 0) { throw 'Policy recupero fallita.' }
        & g++.exe -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror tests/recover_controller_replay_tests.cpp -o build/ame-recover-replay-tests.exe
        if ($LASTEXITCODE -ne 0) { throw 'Build replay recupero fallita.' }
        & .\build\ame-recover-replay-tests.exe
        if ($LASTEXITCODE -ne 0) { throw 'Replay recupero fallito.' }
    } else {
        throw 'Serve un compilatore C++ Windows x64: Visual Studio Build Tools con Sviluppo desktop con C++ e Windows SDK, oppure MinGW-w64. .NET SDK e GCC dentro WSL non compilano da soli questa build Windows. Vedi README.md.'
    }
}
Write-Host 'Build completata. Avvio osservazione: .\start.ps1'
