@echo off
title ControlRAM v0.5.0 R22 - Launcher Amministratore
cd /d "%~dp0engine"

:: Controllo elevazione automatica con richiesta UAC
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ControlRAM] Richiesta elevazione Amministratore (UAC)...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -STA -ExecutionPolicy Bypass -File \"\"%~dp0engine\start-agent.ps1\"\"' -Verb RunAs"
    exit /b
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0engine\start-agent.ps1"
if errorlevel 1 (
  echo Avvio o comando non riuscito. Leggi il motivo qui sopra.
  pause
  exit /b 1
)
