@echo off
title ControlRAM v0.5.0 R22 - Dashboard Stato
cd /d "%~dp0engine"

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0engine\agent-dashboard.ps1"
if errorlevel 1 (
  echo.
  echo Avvio o comando non riuscito. Leggi il motivo qui sopra.
  pause
  exit /b 1
)
