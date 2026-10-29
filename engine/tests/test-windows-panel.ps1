param([switch]$NativeEngine)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'test-windows-model.ps1')
& (Join-Path $PSScriptRoot 'test-windows-events.ps1')
& (Join-Path $PSScriptRoot 'test-hub-lifecycle.ps1')
& (Join-Path $PSScriptRoot 'test-hub-inventory.ps1') -NativeGrid:$NativeEngine
& (Join-Path $PSScriptRoot 'test-hub-queue.ps1')
& (Join-Path $PSScriptRoot 'test-recovery-clicks.ps1')
& (Join-Path $PSScriptRoot 'test-recovery-benefit.ps1')
& (Join-Path $PSScriptRoot 'test-windows-launch.ps1') -NativeEngine:$NativeEngine
& (Join-Path $PSScriptRoot 'test-diagnostics.ps1')
& (Join-Path $PSScriptRoot 'test-panel-startup.ps1')
& (Join-Path $PSScriptRoot 'test-resource-api-client.ps1')
& (Join-Path $PSScriptRoot 'test-strategy.ps1')
& (Join-Path $PSScriptRoot 'test-browser-connection.ps1') -NativeGrid:$NativeEngine
& (Join-Path $PSScriptRoot 'test-comparison.ps1') -NativeWindows:$NativeEngine
& (Join-Path $PSScriptRoot 'test-auto-agent.ps1')
& (Join-Path $PSScriptRoot 'test-process-reduction-api.ps1')
Write-Host 'PASS R22 panel validation'
