@echo off
setlocal
if not "%~1"=="" call "%~1"
if errorlevel 1 exit /b 1
pushd "%~dp0.."
if not exist build mkdir build
cl /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 /D_WIN32_WINNT=0x0A00 /DWIN32_LEAN_AND_MEAN /DNOMINMAX /DUNICODE /D_UNICODE src\main.cpp /Fe:build\ame.exe /Fo:build\ /link psapi.lib ws2_32.lib user32.lib advapi32.lib
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 /D_WIN32_WINNT=0x0A00 /DWIN32_LEAN_AND_MEAN /DNOMINMAX /DUNICODE /D_UNICODE src\browser_host.cpp /Fe:build\ame-browser-host.exe /Fo:build\ /link advapi32.lib
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 tests\policy_tests.cpp /Fe:build\ame-policy-tests.exe /Fo:build\
if errorlevel 1 exit /b 1
build\ame-policy-tests.exe
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 tests\recover_policy_tests.cpp /Fe:build\ame-recover-tests.exe /Fo:build\
if errorlevel 1 exit /b 1
build\ame-recover-tests.exe
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 tests\recover_controller_replay_tests.cpp /Fe:build\ame-recover-replay-tests.exe /Fo:build\
if errorlevel 1 exit /b 1
build\ame-recover-replay-tests.exe
if errorlevel 1 exit /b 1
popd
exit /b 0
