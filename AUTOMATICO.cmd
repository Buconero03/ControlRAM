@echo off
title AME v0.5.0 R22 - Console Log Automatico
cd /d "%~dp0engine"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0engine\start-agent.ps1"
if errorlevel 1 (
  echo Avvio o comando non riuscito. Leggi il motivo qui sopra.
  pause
  exit /b 1
)
