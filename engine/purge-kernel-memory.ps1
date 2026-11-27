param(
    [switch]$CleanLogs,
    [string]$ResultPath = ''
)

$ErrorActionPreference = 'Continue'
$engineRoot = $PSScriptRoot
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Output (@{
        ok = $false
        requires_admin = $true
        message = 'Permessi Amministratore (UAC) richiesti per svuotare Kernel Standby/Modified Lists e System Cache.'
    } | ConvertTo-Json -Compress)
    exit 2
}

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class AmeKernelPurgeNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES {
        public uint PrivilegeCount;
        public LUID Luid;
        public uint Attributes;
    }

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

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetSystemFileCacheSize(IntPtr MinimumFileCacheSize, IntPtr MaximumFileCacheSize, uint Flags);

    [DllImport("ntdll.dll")]
    private static extern int NtSetSystemInformation(int SystemInformationClass, ref int SystemInformation, int SystemInformationLength);

    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool GetPerformanceInfo(out PERFORMANCE_INFORMATION pPerformanceInformation, uint cb);

    public static bool EnablePrivilege(string name) {
        IntPtr token = IntPtr.Zero;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0028 /* TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY */, out token))
            return false;
        try {
            LUID luid;
            if (!LookupPrivilegeValue(null, name, out luid))
                return false;
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES {
                PrivilegeCount = 1,
                Luid = luid,
                Attributes = 0x00000002 /* SE_PRIVILEGE_ENABLED */
            };
            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                return false;
            return Marshal.GetLastWin32Error() == 0;
        } finally {
            if (token != IntPtr.Zero) CloseHandle(token);
        }
    }

    public static int PurgeMemoryLists(out int cacheTrimmed) {
        EnablePrivilege("SeProfileSingleProcessPrivilege");
        EnablePrivilege("SeIncreaseQuotaPrivilege");

        int okCount = 0;
        int cmdEmptyWs = 2;       // MemoryEmptyWorkingSets
        int cmdFlushMod = 3;      // MemoryFlushModifiedList
        int cmdPurgeStandby = 4;  // MemoryPurgeStandbyList
        int cmdPurgeLow = 5;      // MemoryPurgeLowPriorityStandbyList

        if (NtSetSystemInformation(80, ref cmdEmptyWs, sizeof(int)) == 0) okCount++;
        if (NtSetSystemInformation(80, ref cmdFlushMod, sizeof(int)) == 0) okCount++;
        if (NtSetSystemInformation(80, ref cmdPurgeStandby, sizeof(int)) == 0) okCount++;
        if (NtSetSystemInformation(80, ref cmdPurgeLow, sizeof(int)) == 0) okCount++;

        cacheTrimmed = SetSystemFileCacheSize(new IntPtr(-1), new IntPtr(-1), 0) ? 1 : 0;
        return okCount;
    }
}
'@

function Get-KernelSnap {
    $pi = New-Object AmeKernelPurgeNative+PERFORMANCE_INFORMATION
    $pi.cb = [uint32][Runtime.InteropServices.Marshal]::SizeOf($pi)
    [void][AmeKernelPurgeNative]::GetPerformanceInfo([ref]$pi, $pi.cb)
    $ps = [double]$pi.PageSize.ToUInt64()
    return [pscustomobject]@{
        AvailMiB    = [math]::Round(($pi.PhysicalAvailable.ToUInt64() * $ps) / 1MB, 1)
        SysCacheMiB = [math]::Round(($pi.SystemCache.ToUInt64() * $ps) / 1MB, 1)
        NonPagedMiB = [math]::Round(($pi.KernelNonpaged.ToUInt64() * $ps) / 1MB, 1)
        PagedMiB    = [math]::Round(($pi.KernelPaged.ToUInt64() * $ps) / 1MB, 1)
        Handles     = [int]$pi.HandleCount
    }
}

$before = Get-KernelSnap

# 1. Svuotamento liste memoria kernel (WorkingSets -> Modified -> Standby -> LowPriorityStandby) e FileCache
$cacheTrimmed = 0
$listsPurged = [AmeKernelPurgeNative]::PurgeMemoryLists([ref]$cacheTrimmed)

# 2. Se TiWorker.exe ha un handle leak (>= 50k), terminalo in sicurezza
$tiKilled = 0
try {
    $leakingTi = @(Get-Process -Name 'TiWorker' -ErrorAction SilentlyContinue | Where-Object { $_.HandleCount -ge 50000 })
    foreach ($t in $leakingTi) {
        Stop-Process -Id $t.Id -Force -ErrorAction SilentlyContinue
        $tiKilled++
    }
} catch {}

# 3. Pulizia file di log vecchi/diagnostici locali se richiesta
$logsRemoved = 0
$logsFreedKB = 0.0
if ($CleanLogs) {
    $reportsDir = Join-Path $engineRoot 'reports'
    $agentDir = Join-Path $reportsDir 'agent'
    $targets = @()
    if (Test-Path -LiteralPath $reportsDir) {
        $targets += @(Get-ChildItem -LiteralPath $reportsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.txt','.log') })
    }
    if (Test-Path -LiteralPath $agentDir) {
        $targets += @(Get-ChildItem -LiteralPath $agentDir -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '^agent-events-[1-3]\.jsonl$' -or
            $_.Name -match '^inventory-[0-1]\.jsonl$' -or
            $_.Extension -eq '.tmp'
        })
    }
    foreach ($f in $targets) {
        try {
            $sz = [double]$f.Length
            [IO.File]::Delete($f.FullName)
            $logsRemoved++
            $logsFreedKB += ($sz / 1KB)
        } catch {}
    }
}

Start-Sleep -Milliseconds 500
$after = Get-KernelSnap

$availGain = [math]::Round($after.AvailMiB - $before.AvailMiB, 1)
$cacheDrop = [math]::Round($before.SysCacheMiB - $after.SysCacheMiB, 1)
$npDrop    = [math]::Round($before.NonPagedMiB - $after.NonPagedMiB, 1)
$pgDrop    = [math]::Round($before.PagedMiB - $after.PagedMiB, 1)
$logsFreedKB = [math]::Round($logsFreedKB, 1)

$resObj = @{
    ok = ($listsPurged -gt 0 -or $cacheTrimmed -gt 0 -or $tiKilled -gt 0 -or $logsRemoved -gt 0)
    requires_admin = $false
    lists_purged = $listsPurged
    cache_trimmed = ($cacheTrimmed -gt 0)
    tiworker_killed = $tiKilled
    logs_removed = $logsRemoved
    logs_freed_kb = $logsFreedKB
    avail_before_mib = $before.AvailMiB
    avail_after_mib = $after.AvailMiB
    avail_gain_mib = $availGain
    syscache_drop_mib = $cacheDrop
    nonpaged_before_mib = $before.NonPagedMiB
    nonpaged_after_mib = $after.NonPagedMiB
    nonpaged_drop_mib = $npDrop
    paged_drop_mib = $pgDrop
    message = ("SVUOTAMENTO KERNEL & LOG: RAM disp. {0:N1} -> {1:N1} MiB ({2:+0.0;-0.0;0.0} MiB) | SysCache {3:+0.0;-0.0;0.0} MiB | NP {4:N1} -> {5:N1} MiB | Log rimossi: {6}." -f $before.AvailMiB, $after.AvailMiB, $availGain, (-$cacheDrop), $before.NonPagedMiB, $after.NonPagedMiB, $logsRemoved)
}

$jsonOut = $resObj | ConvertTo-Json -Compress
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    try {
        [IO.File]::WriteAllText($ResultPath, $jsonOut, (New-Object Text.UTF8Encoding($false)))
    } catch {}
}
Write-Output $jsonOut
exit 0
