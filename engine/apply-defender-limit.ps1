param(
    [int]$MaxCpu = 15,
    [string]$WorkspaceRoot = ''
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error 'Privilegi di Amministratore richiesti per modificare Windows Defender.'
    exit 2
}

if ($MaxCpu -lt 5) { $MaxCpu = 5 }
if ($MaxCpu -gt 100) { $MaxCpu = 100 }

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $WorkspaceRoot = Split-Path -Path $PSScriptRoot -Parent
}

# 1. Imposta i veri parametri CPU di Windows Defender (scansioni + priorita bassa)
Set-MpPreference -ScanAvgCPULoadFactor $MaxCpu `
                 -ThrottleForScheduledScanOnly $false `
                 -DisableCpuThrottleOnIdleScans $false `
                 -EnableLowCpuPriority $true `
                 -AllowSwitchToAsyncInspection $true `
                 -ErrorAction Stop

# 2. Esclusioni sicure sulle cartelle del workspace/build per ridurre i picchi Real-Time durante compilazioni/test
try {
    $buildPath = Join-Path $PSScriptRoot 'build'
    $reportsPath = Join-Path $PSScriptRoot 'reports'
    $toExclude = @($WorkspaceRoot, $buildPath, $reportsPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }
    if ($toExclude.Count -gt 0) {
        Add-MpPreference -ExclusionPath $toExclude -ErrorAction SilentlyContinue
    }
} catch {}

# 3. Svuota la cache firme dinamiche in memoria (MpCmdRun) per ridurre il Working Set di MsMpEng
try {
    $mpCmd = Get-ChildItem 'C:\ProgramData\Microsoft\Windows Defender\Platform\*\MpCmdRun.exe' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $mpCmd -and (Test-Path -LiteralPath 'C:\Program Files\Windows Defender\MpCmdRun.exe')) {
        $mpCmd = Get-Item -LiteralPath 'C:\Program Files\Windows Defender\MpCmdRun.exe'
    }
    if ($mpCmd) {
        $proc = Start-Process -FilePath $mpCmd.FullName -ArgumentList '-RemoveDefinitions', '-DynamicSignatures' -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
        if ($proc) {
            [void]$proc.WaitForExit(4000)
        }
    }
} catch {}

# 4. Verifica reale post-applicazione
$mp = Get-MpPreference -ErrorAction Stop
$applied = ($mp.ScanAvgCPULoadFactor -le $MaxCpu) -and (-not $mp.ThrottleForScheduledScanOnly) -and (-not $mp.DisableCpuThrottleOnIdleScans) -and ($mp.EnableLowCpuPriority -eq $true)
if (-not $applied) {
    Write-Error ("Verifica Windows Defender fallita: ScanAvgCPULoadFactor=$($mp.ScanAvgCPULoadFactor), ThrottleForScheduledScanOnly=$($mp.ThrottleForScheduledScanOnly), DisableCpuThrottleOnIdleScans=$($mp.DisableCpuThrottleOnIdleScans), EnableLowCpuPriority=$($mp.EnableLowCpuPriority)")
    exit 1
}

Write-Output ("OK|CPU=$($mp.ScanAvgCPULoadFactor)|LowPriority=$($mp.EnableLowCpuPriority)|ThrottleAll=$($(-not $mp.ThrottleForScheduledScanOnly))|ThrottleIdle=$($(-not $mp.DisableCpuThrottleOnIdleScans))")
exit 0
