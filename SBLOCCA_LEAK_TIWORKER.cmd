@echo off
title ControlRAM - Sblocco Leak TiWorker / Kernel Pool
cd /d "%~dp0engine"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0engine\fix-tiworker-leak.ps1"
if errorlevel 1 (
  echo.
  echo Operazione non riuscita. Leggi il motivo qui sopra.
  pause
)
