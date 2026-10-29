@echo off
setlocal
if not "%~1"=="" call "%~1"
if errorlevel 1 exit /b 1
pushd "%~dp0.."
if not exist build mkdir build
cl /nologo /std:c++17 /EHsc /W4 /WX /permissive- /utf-8 /D_WIN32_WINNT=0x0A00 /DWIN32_LEAN_AND_MEAN /DNOMINMAX /DUNICODE /D_UNICODE /DAME_RESOURCE_API_EXPORTS /LD src\resource_api.cpp /Fo:build\ /Fe:build\ame-resource-api.dll /link /IMPLIB:build\ame-resource-api.lib psapi.lib advapi32.lib
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /permissive- /utf-8 /D_WIN32_WINNT=0x0A00 /DWIN32_LEAN_AND_MEAN /DNOMINMAX /DUNICODE /D_UNICODE examples\resource_api_demo.cpp /Fo:build\ /Fe:build\ame-resource-demo.exe /link build\ame-resource-api.lib
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /permissive- /utf-8 tests\resource_analysis_tests.cpp /Fo:build\ /Fe:build\ame-resource-analysis-tests.exe
if errorlevel 1 exit /b 1
popd
exit /b 0
