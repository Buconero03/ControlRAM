$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    try {
        Start-Process -FilePath $psExe -ArgumentList $argList -WorkingDirectory $PSScriptRoot -Verb RunAs
    } catch {
        Write-Host '[ControlRAM] Elevazione UAC annullata dall utente.' -ForegroundColor Yellow
    }
    return
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TiFixPerf {
    [StructLayout(LayoutKind.Sequential)]
    public struct PERFORMANCE_INFORMATION {
        public uint cb;
        public UIntPtr CommitTotal;
        public UIntPtr CommitLimit;
        public UIntPtr CommitPeak;
        public UIntPtr PhysicalTotal;
        public UIntPtr PhysicalAvailable;
        public UIntPtr SystemCache;
        public UIntPtr KernelTotal;
        public UIntPtr KernelPaged;
        public UIntPtr KernelNonpaged;
        public UIntPtr PageSize;
        public uint HandleCount;
        public uint ProcessCount;
        public uint ThreadCount;
    }
    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool GetPerformanceInfo(out PERFORMANCE_INFORMATION pPerformanceInformation, uint cb);
}
'@

function Get-MemSnap {
    $pi = New-Object TiFixPerf+PERFORMANCE_INFORMATION
    $pi.cb = [uint32][Runtime.InteropServices.Marshal]::SizeOf($pi)
    [void][TiFixPerf]::GetPerformanceInfo([ref]$pi, $pi.cb)
    $ps = [double]$pi.PageSize.ToUInt64()
    return [pscustomobject]@{
        AvailMiB = [math]::Round(($pi.PhysicalAvailable.ToUInt64() * $ps) / 1MB, 1)
        NonPagedMiB = [math]::Round(($pi.KernelNonpaged.ToUInt64() * $ps) / 1MB, 1)
        PagedMiB = [math]::Round(($pi.KernelPaged.ToUInt64() * $ps) / 1MB, 1)
        Handles = $pi.HandleCount
    }
}

$before = Get-MemSnap
$targets = @(Get-Process -Name 'TiWorker' -ErrorAction SilentlyContinue | Where-Object { $_.HandleCount -ge 50000 })
if ($targets.Count -eq 0) {
    $allTi = @(Get-Process -Name 'TiWorker' -ErrorAction SilentlyContinue)
    if ($allTi.Count -eq 0) {
        Write-Host 'Nessun processo TiWorker.exe attivo al momento.' -ForegroundColor Green
        return
    }
    Write-Host ("TiWorker.exe attivo ma sotto soglia leak ($($allTi[0].HandleCount) handle). Nessuna terminazione forzata.") -ForegroundColor Yellow
    return
}

Write-Host ('=== PRIMA DELLO SBLOCCO ===') -ForegroundColor Cyan
Write-Host ("  RAM Disponibile:       $($before.AvailMiB) MiB")
Write-Host ("  Kernel Non-Paged Pool: $($before.NonPagedMiB) MiB | Paged Pool: $($before.PagedMiB) MiB")
Write-Host ("  Handle Sistema:        $($before.Handles)")

foreach ($t in $targets) {
    Write-Host ("Termino TiWorker.exe (PID $($t.Id) con $($t.HandleCount) handle aperti)...") -ForegroundColor Yellow
    Stop-Process -Id $t.Id -Force
}

Start-Sleep -Seconds 2
$after = Get-MemSnap
$freedAvail = [math]::Round($after.AvailMiB - $before.AvailMiB, 1)
$freedNP = [math]::Round($before.NonPagedMiB - $after.NonPagedMiB, 1)

Write-Host ('=== DOPO LO SBLOCCO ===') -ForegroundColor Green
Write-Host ("  RAM Disponibile:       $($after.AvailMiB) MiB (+$freedAvail MiB liberati!)")
Write-Host ("  Kernel Non-Paged Pool: $($after.NonPagedMiB) MiB (-$freedNP MiB nel kernel!) | Paged Pool: $($after.PagedMiB) MiB")
Write-Host ("  Handle Sistema:        $($after.Handles)")
