@echo off
title ControlRAM - Diagnosi servicing Windows (DISM / SFC)
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Richiesta permessi di Amministratore: conferma la finestra UAC con "Si".
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo Diagnosi in corso con permessi di Amministratore.
echo Puo richiedere 20-50 minuti. NON chiudere questa finestra fino a "FINE".
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0engine\diagnose-servicing.ps1" -Elevated
echo.
echo Report salvato in: %~dp0engine\reports\servicing-diagnosi.txt
pause
