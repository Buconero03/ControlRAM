param()
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -eq 'Core'){& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath;return}
. (Join-Path $PSScriptRoot 'agent-state.ps1')
. (Join-Path $PSScriptRoot 'process-reduction-api.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Modulo Nativo Misurazione CPU ad Altissima Efficienza (Zero Overhead) ---
try {
    Add-Type @'
    using System;
    using System.Runtime.InteropServices;

    public static class AmeCpuMeter {
        [StructLayout(LayoutKind.Sequential)]
        public struct FILETIME {
            public uint dwLowDateTime;
            public uint dwHighDateTime;
            public ulong ToUInt64() {
                return ((ulong)dwHighDateTime << 32) | (ulong)dwLowDateTime;
            }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetSystemTimes(out FILETIME lpIdleTime, out FILETIME lpKernelTime, out FILETIME lpUserTime);

        private static ulong _prevIdle = 0;
        private static ulong _prevKernel = 0;
        private static ulong _prevUser = 0;

        public static double GetSystemCpuUsage() {
            FILETIME idle, kernel, user;
            if (!GetSystemTimes(out idle, out kernel, out user)) return 0.0;
            ulong idleVal = idle.ToUInt64();
            ulong kernelVal = kernel.ToUInt64();
            ulong userVal = user.ToUInt64();

            if (_prevKernel == 0 && _prevUser == 0) {
                _prevIdle = idleVal;
                _prevKernel = kernelVal;
                _prevUser = userVal;
                return 0.0;
            }
            ulong deltaIdle = idleVal - _prevIdle;
            ulong deltaKernel = kernelVal - _prevKernel;
            ulong deltaUser = userVal - _prevUser;

            _prevIdle = idleVal;
            _prevKernel = kernelVal;
            _prevUser = userVal;

            ulong total = deltaKernel + deltaUser;
            if (total <= 0) return 0.0;
            if (deltaIdle > total) return 0.0;

            double pct = (double)(total - deltaIdle) * 100.0 / (double)total;
            if (pct < 0.0) pct = 0.0;
            if (pct > 100.0) pct = 100.0;
            return pct;
        }
    }
'@ -ErrorAction SilentlyContinue
} catch {}

# --- Palette Colori Professionale (Theme: Deep Cyber Slate) ---
$cBg = [Drawing.Color]::FromArgb(15, 23, 42)          # #0F172A Deep Slate Background
$cCardBg = [Drawing.Color]::FromArgb(30, 41, 59)      # #1E293B Card/Panel Background
$cCardAlt = [Drawing.Color]::FromArgb(22, 32, 51)     # #162033 Darker Slate Alternate
$cConsoleBg = [Drawing.Color]::FromArgb(10, 14, 23)   # #0A0E17 Terminal Console Background
$cText = [Drawing.Color]::FromArgb(248, 250, 252)     # #F8FAFC Bright White
$cTextDim = [Drawing.Color]::FromArgb(148, 163, 184)  # #94A3B8 Dim Muted Slate Text
$cCyanLight = [Drawing.Color]::FromArgb(56, 189, 248) # #38BDF8 Sky Cyan Accent
$cGreen = [Drawing.Color]::FromArgb(16, 185, 129)     # #10B981 Emerald Green
$cRed = [Drawing.Color]::FromArgb(239, 68, 68)        # #EF4444 Vibrant Coral Red
$cAmber = [Drawing.Color]::FromArgb(245, 158, 11)     # #F59E0B Amber Orange
$cViolet = [Drawing.Color]::FromArgb(139, 92, 246)    # #8B5CF6 Neon Violet

# --- Stili Pulsanti Professionali (Design Coerente Slate & Action Focus) ---
$cBtnBaseBg            = [Drawing.Color]::FromArgb(30, 41, 59)      # #1E293B Slate Base
$cBtnBaseBorder        = [Drawing.Color]::FromArgb(51, 65, 85)      # #334155 Slate 1px Border
$cBtnBaseText          = [Drawing.Color]::FromArgb(226, 232, 240)  # #E2E8F0 Clean Slate Text
$cBtnBaseHover         = [Drawing.Color]::FromArgb(51, 65, 85)      # #334155 Slate Hover

$cBtnPrimaryBg         = [Drawing.Color]::FromArgb(2, 132, 199)     # #0284C7 Blue/Cyan Primary CTA
$cBtnPrimaryBorder     = [Drawing.Color]::FromArgb(14, 165, 233)    # #0EA5E9
$cBtnPrimaryText       = [Drawing.Color]::White
$cBtnPrimaryHover      = [Drawing.Color]::FromArgb(3, 105, 161)     # #0369A1

$cBtnDangerBg          = [Drawing.Color]::FromArgb(45, 24, 30)       # #2D181E Muted Deep Burgundy
$cBtnDangerBorder      = [Drawing.Color]::FromArgb(127, 29, 29)      # #7F1D1D Crimson Border
$cBtnDangerText        = [Drawing.Color]::FromArgb(252, 165, 165)    # #FCA5A5 Soft Coral Text
$cBtnDangerHover       = [Drawing.Color]::FromArgb(127, 29, 29)      # #7F1D1D

$cBtnGreenActiveBg     = [Drawing.Color]::FromArgb(6, 78, 59)       # #064E3B Deep Emerald Active
$cBtnGreenActiveBorder = [Drawing.Color]::FromArgb(16, 185, 129)    # #10B981
$cBtnGreenActiveText   = [Drawing.Color]::FromArgb(209, 250, 229)   # #D1FAE5
$cBtnGreenActiveHover  = [Drawing.Color]::FromArgb(4, 120, 87)      # #047857

$cBtnVioletActiveBg    = [Drawing.Color]::FromArgb(76, 29, 149)     # #4C1D95 Royal Violet Active
$cBtnVioletActiveBorder= [Drawing.Color]::FromArgb(139, 92, 246)    # #8B5CF6
$cBtnVioletActiveText  = [Drawing.Color]::FromArgb(237, 233, 254)   # #EDE9FE
$cBtnVioletActiveHover = [Drawing.Color]::FromArgb(109, 40, 217)    # #6D28D9

# --- Finestra Principale ---
$view = New-Object Windows.Forms.Form
$view.Text = 'AME v0.5.0 R22 - Advanced Memory Engine Dashboard'
$view.Size = New-Object Drawing.Size(1120, 820)
$view.MinimumSize = New-Object Drawing.Size(940, 680)
$view.StartPosition = 'CenterScreen'
$view.Font = New-Object Drawing.Font('Segoe UI', 9.5)
$view.BackColor = $cBg
$view.ForeColor = $cText
$dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
if ($dbProp) { $dbProp.SetValue($view, $true, $null) }

# Layout verticale a 5 righe
$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.Padding = New-Object Windows.Forms.Padding(16, 14, 16, 14)
$layout.RowCount = 5
$layout.ColumnCount = 1
$layout.BackColor = $cBg

# Altezze righe: [Hero/KPI: 105px, Pulsanti: 82px, Info/Stato: 94px, Griglia: 100%, Console: 145px]
foreach($h in @(105, 82, 94, 0, 145)){
    $row = New-Object Windows.Forms.RowStyle
    if($h){$row.SizeType = 'Absolute'; $row.Height = $h}else{$row.SizeType = 'Percent'; $row.Height = 100}
    [void]$layout.RowStyles.Add($row)
}
$view.Controls.Add($layout)

# --- RIGA 0: KPI & Hero Cards (5 Riquadri Monitoraggio Vivaci) ---
$kpiTable = New-Object Windows.Forms.TableLayoutPanel
$kpiTable.Dock = 'Fill'
$kpiTable.ColumnCount = 5
$kpiTable.RowCount = 1
$kpiTable.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 8)
for($i=0; $i -lt 5; $i++){
    $col = New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 20)
    [void]$kpiTable.ColumnStyles.Add($col)
}
$layout.Controls.Add($kpiTable, 0, 0)

function New-KpiCard([string]$title, [string]$val, [string]$sub, [Drawing.Color]$valColor) {
    $p = New-Object Windows.Forms.Panel
    $p.Dock = 'Fill'
    $p.Margin = New-Object Windows.Forms.Padding(4, 0, 4, 0)
    $p.BackColor = $cCardBg
    $p.Padding = New-Object Windows.Forms.Padding(12, 8, 12, 8)

    $lblTitle = New-Object Windows.Forms.Label
    $lblTitle.Dock = 'Top'
    $lblTitle.Height = 20
    $lblTitle.Text = $title.ToUpper()
    $lblTitle.Font = New-Object Drawing.Font('Segoe UI', 8.5, [Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = $cTextDim

    $lblVal = New-Object Windows.Forms.Label
    $lblVal.Dock = 'Top'
    $lblVal.Height = 36
    $lblVal.Text = $val
    $lblVal.Font = New-Object Drawing.Font('Segoe UI', 13.5, [Drawing.FontStyle]::Bold)
    $lblVal.ForeColor = $valColor

    $lblSub = New-Object Windows.Forms.Label
    $lblSub.Dock = 'Fill'
    $lblSub.Text = $sub
    $lblSub.Font = New-Object Drawing.Font('Segoe UI', 8.5)
    $lblSub.ForeColor = $cTextDim

    [void]$p.Controls.Add($lblSub)
    [void]$p.Controls.Add($lblVal)
    [void]$p.Controls.Add($lblTitle)
    $p.Tag = @{Title=$lblTitle; Value=$lblVal; Sub=$lblSub}
    return $p
}

$cardStatus = New-KpiCard 'Stato Agente AME' 'INIZIALIZZAZIONE...' 'Controllo in corso' $cCyanLight
$cardRam    = New-KpiCard 'Pressione RAM' '...' 'Telemetria in acquisizione' $cCyanLight
$cardCpu    = New-KpiCard 'Attivita CPU' '...' 'EcoQoS: rilevamento...' $cCyanLight
$cardMode   = New-KpiCard 'Modalita Operativa' 'STANDARD' 'Multi-Lane Automatico' $cGreen
$cardSaving = New-KpiCard 'Memoria e Risparmio' '0.0 MiB' 'Compressione: N/D' $cGreen

$kpiTable.Controls.Add($cardStatus, 0, 0)
$kpiTable.Controls.Add($cardRam, 1, 0)
$kpiTable.Controls.Add($cardCpu, 2, 0)
$kpiTable.Controls.Add($cardMode, 3, 0)
$kpiTable.Controls.Add($cardSaving, 4, 0)

# --- RIGA 1: Barra Pulsanti di Controllo (Stile Professionale Slate & Focus) ---
$buttons = New-Object Windows.Forms.FlowLayoutPanel
$buttons.Dock = 'Fill'
$buttons.Margin = New-Object Windows.Forms.Padding(0, 2, 0, 4)
$buttons.BackColor = $cBg
$layout.Controls.Add($buttons, 0, 1)

function New-StyledButton(
    [string]$text,
    [Drawing.Size]$size,
    [Drawing.Color]$bg,
    [Drawing.Color]$border,
    [Drawing.Color]$textCol,
    [Drawing.Color]$hover
) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.Size = $size
    $b.Margin = New-Object Windows.Forms.Padding(3, 4, 3, 4)
    $b.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = $border
    $b.FlatAppearance.MouseOverBackColor = $hover
    $b.BackColor = $bg
    $b.ForeColor = $textCol
    $b.Font = New-Object Drawing.Font('Segoe UI', 9.25, [Drawing.FontStyle]::Bold)
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    return $b
}

function Set-ButtonStyle(
    [Windows.Forms.Button]$b,
    [Drawing.Color]$bg,
    [Drawing.Color]$border,
    [Drawing.Color]$textCol,
    [Drawing.Color]$hover
) {
    $b.BackColor = $bg
    $b.FlatAppearance.BorderColor = $border
    $b.ForeColor = $textCol
    $b.FlatAppearance.MouseOverBackColor = $hover
}

$startBtn     = New-StyledButton 'Avvia Agente'             (New-Object Drawing.Size(125, 32)) $cBtnBaseBg        $cBtnBaseBorder        $cTextDim              $cBtnBaseHover
$stop         = New-StyledButton 'Ferma e Ripristina'      (New-Object Drawing.Size(155, 32)) $cBtnDangerBg      $cBtnDangerBorder      $cBtnDangerText        $cBtnDangerHover
$restartBtn   = New-StyledButton 'Riavvia e Resetta'       (New-Object Drawing.Size(145, 32)) $cBtnBaseBg        $cBtnBaseBorder        $cBtnBaseText          $cBtnBaseHover
$optimizeBtn  = New-StyledButton 'Ottimizza Ora'           (New-Object Drawing.Size(135, 32)) $cBtnPrimaryBg     $cBtnPrimaryBorder     $cBtnPrimaryText       $cBtnPrimaryHover
$flushCompBtn = New-StyledButton 'Svuota Compressione'     (New-Object Drawing.Size(170, 32)) $cBtnBaseBg        $cBtnBaseBorder        $cBtnBaseText          $cBtnBaseHover
$clampBtn     = New-StyledButton 'Modalita Gioco (Clamp)'  (New-Object Drawing.Size(190, 32)) $cBtnBaseBg        $cBtnBaseBorder        $cBtnBaseText          $cBtnBaseHover
$startupBtn   = New-StyledButton 'Avvio Windows: OFF'      (New-Object Drawing.Size(155, 32)) $cBtnBaseBg        $cBtnBaseBorder        $cTextDim              $cBtnBaseHover
$export       = New-StyledButton 'Esporta Diagnosi'        (New-Object Drawing.Size(145, 32)) $cBtnBaseBg        $cBtnBaseBorder        $cBtnBaseText          $cBtnBaseHover
$folder       = New-StyledButton 'Regole Config'           (New-Object Drawing.Size(125, 32)) $cBtnBaseBg        $cBtnBaseBorder        $cBtnBaseText          $cBtnBaseHover

foreach($btn in @($startBtn, $stop, $restartBtn, $optimizeBtn, $flushCompBtn, $clampBtn, $startupBtn, $export, $folder)){ [void]$buttons.Controls.Add($btn) }

# --- RIGA 2: Card Dettaglio Interventi & Telemetria ---
$infoPanel = New-Object Windows.Forms.Panel
$infoPanel.Dock = 'Fill'
$infoPanel.BackColor = $cCardBg
$infoPanel.Padding = New-Object Windows.Forms.Padding(14, 10, 14, 10)
$infoPanel.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 6)
$layout.Controls.Add($infoPanel, 0, 2)

$infoLayout = New-Object Windows.Forms.TableLayoutPanel
$infoLayout.Dock = 'Fill'
$infoLayout.RowCount = 2
$infoLayout.ColumnCount = 1
$infoLayout.BackColor = $cCardBg
$r0 = New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 56); [void]$infoLayout.RowStyles.Add($r0)
$r1 = New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 44); [void]$infoLayout.RowStyles.Add($r1)
$infoPanel.Controls.Add($infoLayout)

$lblIntervention = New-Object Windows.Forms.Label
$lblIntervention.Dock = 'Fill'
$lblIntervention.Font = New-Object Drawing.Font('Segoe UI', 9.5, [Drawing.FontStyle]::Bold)
$lblIntervention.ForeColor = $cCyanLight
$lblIntervention.Text = 'Inizializzazione telemetria in tempo reale...'
$infoLayout.Controls.Add($lblIntervention, 0, 0)

$lblDetails = New-Object Windows.Forms.Label
$lblDetails.Dock = 'Fill'
$lblDetails.Font = New-Object Drawing.Font('Segoe UI', 9.0)
$lblDetails.ForeColor = $cTextDim
$lblDetails.Text = 'Sistema Multi-Lane in ascolto automatico (Chrome, Firefox, Processi Interni e Processi Windows).'
$infoLayout.Controls.Add($lblDetails, 0, 1)

# --- RIGA 3: Tabella Processi Stilizzata (Dark Slate con Accenti) ---
$grid = New-Object Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = [Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$grid.AutoSizeColumnsMode = 'Fill'
$grid.BackgroundColor = $cBg
$grid.BorderStyle = [Windows.Forms.BorderStyle]::None
$grid.CellBorderStyle = [Windows.Forms.DataGridViewCellBorderStyle]::SingleHorizontal
$grid.GridColor = [Drawing.Color]::FromArgb(40, 53, 75)
$grid.EnableHeadersVisualStyles = $false
$grid.Font = New-Object Drawing.Font('Segoe UI', 9.25)
$grid.Margin = New-Object Windows.Forms.Padding(0, 2, 0, 6)

# Header stile Cyber Dark
$grid.ColumnHeadersDefaultCellStyle.BackColor = $cCardBg
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $cCyanLight
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font('Segoe UI', 9.5, [Drawing.FontStyle]::Bold)
$grid.ColumnHeadersDefaultCellStyle.Padding = New-Object Windows.Forms.Padding(6, 4, 6, 4)
$grid.ColumnHeadersHeight = 32
$grid.ColumnHeadersHeightSizeMode = [Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::DisableResizing

# Default e Alternating Rows
$grid.DefaultCellStyle.BackColor = $cBg
$grid.DefaultCellStyle.ForeColor = $cText
$grid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(37, 99, 235)
$grid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::White
$grid.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding(4, 2, 4, 2)
$grid.RowTemplate.Height = 28

$grid.AlternatingRowsDefaultCellStyle.BackColor = $cCardAlt
$grid.AlternatingRowsDefaultCellStyle.ForeColor = $cText
$grid.AlternatingRowsDefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(37, 99, 235)
$grid.AlternatingRowsDefaultCellStyle.SelectionForeColor = [Drawing.Color]::White

# Double-buffered per eliminare ogni sfarfallio
$prop = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
if ($prop) { $prop.SetValue($grid, $true, $null) }

# Colonne con larghezze e allineamenti dedicati
$colName = New-Object Windows.Forms.DataGridViewTextBoxColumn; $colName.Name = 'name'; $colName.HeaderText = '  Applicazione'; $colName.FillWeight = 190
$colCount = New-Object Windows.Forms.DataGridViewTextBoxColumn; $colCount.Name = 'count'; $colCount.HeaderText = 'Processi'; $colCount.FillWeight = 75; $colCount.DefaultCellStyle.Alignment = [Windows.Forms.DataGridViewContentAlignment]::MiddleCenter
$colMem = New-Object Windows.Forms.DataGridViewTextBoxColumn; $colMem.Name = 'memory'; $colMem.HeaderText = 'RAM Privata MiB'; $colMem.FillWeight = 115; $colMem.DefaultCellStyle.Alignment = [Windows.Forms.DataGridViewContentAlignment]::MiddleRight
$colMethod = New-Object Windows.Forms.DataGridViewTextBoxColumn; $colMethod.Name = 'method'; $colMethod.HeaderText = 'Strategia di Ottimizzazione'; $colMethod.FillWeight = 260
foreach($col in @($colName, $colCount, $colMem, $colMethod)){ [void]$grid.Columns.Add($col) }
$layout.Controls.Add($grid, 0, 3)

# --- RIGA 4: Console Log / Event Terminal ---
$logPanel = New-Object Windows.Forms.Panel
$logPanel.Dock = 'Fill'
$logPanel.BackColor = $cConsoleBg
$logPanel.Padding = New-Object Windows.Forms.Padding(10, 6, 10, 6)
$layout.Controls.Add($logPanel, 0, 4)

$logTitle = New-Object Windows.Forms.Label
$logTitle.Dock = 'Top'
$logTitle.Height = 20
$logTitle.Text = 'EVENTI E TELEMETRIA AGENTE IN TEMPO REALE'
$logTitle.Font = New-Object Drawing.Font('Segoe UI', 8.5, [Drawing.FontStyle]::Bold)
$logTitle.ForeColor = $cCyanLight
$logPanel.Controls.Add($logTitle)

$log = New-Object Windows.Forms.TextBox
$log.Dock = 'Fill'
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.BackColor = $cConsoleBg
$log.ForeColor = [Drawing.Color]::FromArgb(167, 243, 208)
$log.Font = New-Object Drawing.Font('Consolas', 9.0)
$log.BorderStyle = [Windows.Forms.BorderStyle]::None
$logPanel.Controls.Add($log)
$log.BringToFront()

# --- Funzioni di Supporto ---
function Test-StartupEnabled {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'AME Automatico.lnk'
    return (Test-Path -LiteralPath $lnk)
}

function Show-ClampDialog {
    $s = Get-AgentLiveStatus
    $dist = if($s){$s.distributed}else{$null}
    $curProc = if($dist -and $dist.clamp_target_process){$dist.clamp_target_process}else{''}
    if($grid.SelectedRows.Count -gt 0 -and $grid.SelectedRows[0].Cells['name'].Value){
        $curProc = [string]$grid.SelectedRows[0].Cells['name'].Value
    }
    if(!$curProc){$curProc = 'gioco.exe'}
    $curThresh = if($dist -and $dist.clamp_target_threshold_mib){[int]$dist.clamp_target_threshold_mib}else{1200}
    $curMode = if($dist -and $dist.operation_mode){[string]$dist.operation_mode}else{'standard'}

    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Modalita Gioco / App - RAM Clamping (Mix A + B)'
    $dlg.Size = New-Object Drawing.Size(510, 290)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = $cBg
    $dlg.ForeColor = $cText
    $dlg.Font = New-Object Drawing.Font('Segoe UI', 9.5)

    $lblInfo = New-Object Windows.Forms.Label
    $lblInfo.Location = New-Object Drawing.Point(20, 14); $lblInfo.Size = New-Object Drawing.Size(460, 42)
    $lblInfo.Text = 'Combina Hard Working Set Quota (Tecnica A) e In-Memory Compression (Tecnica B) per limitare la RAM fisica del processo senza scatti ne stuttering.'
    $lblInfo.ForeColor = $cCyanLight

    $lblProc = New-Object Windows.Forms.Label
    $lblProc.Location = New-Object Drawing.Point(20, 68); $lblProc.Size = New-Object Drawing.Size(190, 24)
    $lblProc.Text = 'Processo (es. gioco.exe):'
    $lblProc.ForeColor = $cText

    $txtProc = New-Object Windows.Forms.TextBox
    $txtProc.Location = New-Object Drawing.Point(215, 65); $txtProc.Size = New-Object Drawing.Size(250, 26)
    $txtProc.BackColor = $cCardBg
    $txtProc.ForeColor = [Drawing.Color]::White
    $txtProc.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
    $txtProc.Text = $curProc

    $lblThresh = New-Object Windows.Forms.Label
    $lblThresh.Location = New-Object Drawing.Point(20, 106); $lblThresh.Size = New-Object Drawing.Size(190, 24)
    $lblThresh.Text = 'Soglia RAM massima (MiB):'
    $lblThresh.ForeColor = $cText

    $numThresh = New-Object Windows.Forms.NumericUpDown
    $numThresh.Location = New-Object Drawing.Point(215, 103); $numThresh.Size = New-Object Drawing.Size(130, 26)
    $numThresh.BackColor = $cCardBg
    $numThresh.ForeColor = $cCyanLight
    $numThresh.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
    $numThresh.Minimum = 64; $numThresh.Maximum = 65536
    $numThresh.Value = [math]::Max(64, [math]::Min(65536, $curThresh))

    $lblCur = New-Object Windows.Forms.Label
    $lblCur.Location = New-Object Drawing.Point(20, 142); $lblCur.Size = New-Object Drawing.Size(460, 22)
    $lblCur.Text = ('Stato attuale: ' + $curMode.ToUpper() + $(if($dist -and $dist.clamp_target_process){' | Target: ' + $dist.clamp_target_process + ' @ ' + $dist.clamp_target_threshold_mib + ' MiB'}else{''}))
    $lblCur.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Italic)
    $lblCur.ForeColor = $cTextDim

    $btnActivate = New-Object Windows.Forms.Button
    $btnActivate.Location = New-Object Drawing.Point(20, 184); $btnActivate.Size = New-Object Drawing.Size(170, 38)
    $btnActivate.Text = 'Attiva Modalita Clamp'
    $btnActivate.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $btnActivate.FlatAppearance.BorderSize = 1
    $btnActivate.FlatAppearance.BorderColor = $cBtnVioletActiveBorder
    $btnActivate.FlatAppearance.MouseOverBackColor = $cBtnVioletActiveHover
    $btnActivate.BackColor = $cBtnVioletActiveBg
    $btnActivate.ForeColor = [Drawing.Color]::White
    $btnActivate.Font = New-Object Drawing.Font('Segoe UI', 9.5, [Drawing.FontStyle]::Bold)
    $btnActivate.Cursor = [Windows.Forms.Cursors]::Hand
    $btnActivate.DialogResult = [Windows.Forms.DialogResult]::OK
    $btnActivate.Add_Click({
        $dlg.Tag = @{Action='clamp'; Process=$txtProc.Text.Trim(); Threshold=[int]$numThresh.Value}
        $dlg.Close()
    })

    $btnDeactivate = New-Object Windows.Forms.Button
    $btnDeactivate.Location = New-Object Drawing.Point(200, 184); $btnDeactivate.Size = New-Object Drawing.Size(155, 38)
    $btnDeactivate.Text = 'Ripristina Standard'
    $btnDeactivate.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $btnDeactivate.FlatAppearance.BorderSize = 1
    $btnDeactivate.FlatAppearance.BorderColor = $cBtnBaseBorder
    $btnDeactivate.FlatAppearance.MouseOverBackColor = $cBtnBaseHover
    $btnDeactivate.BackColor = $cBtnBaseBg
    $btnDeactivate.ForeColor = $cBtnBaseText
    $btnDeactivate.Font = New-Object Drawing.Font('Segoe UI', 9.5, [Drawing.FontStyle]::Bold)
    $btnDeactivate.Cursor = [Windows.Forms.Cursors]::Hand
    $btnDeactivate.Add_Click({
        $dlg.Tag = @{Action='standard'}
        $dlg.Close()
    })

    $btnCancel = New-Object Windows.Forms.Button
    $btnCancel.Location = New-Object Drawing.Point(365, 184); $btnCancel.Size = New-Object Drawing.Size(105, 38)
    $btnCancel.Text = 'Annulla'
    $btnCancel.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $btnCancel.FlatAppearance.BorderSize = 1
    $btnCancel.FlatAppearance.BorderColor = $cBtnBaseBorder
    $btnCancel.FlatAppearance.MouseOverBackColor = $cBtnBaseHover
    $btnCancel.BackColor = $cCardBg
    $btnCancel.ForeColor = $cTextDim
    $btnCancel.Font = New-Object Drawing.Font('Segoe UI', 9.5)
    $btnCancel.Cursor = [Windows.Forms.Cursors]::Hand
    $btnCancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $btnCancel.Add_Click({
        $dlg.Tag = $null
        $dlg.Close()
    })

    foreach($ctrl in @($lblInfo, $lblProc, $txtProc, $lblThresh, $numThresh, $lblCur, $btnActivate, $btnDeactivate, $btnCancel)){ [void]$dlg.Controls.Add($ctrl) }
    [void]$dlg.ShowDialog($view)
    return $dlg.Tag
}

function Update-AgentView {
    try{
        $startupOn = Test-StartupEnabled
        if($startupOn){
            $startupBtn.Text = 'Avvio Windows: ATTIVO'
            Set-ButtonStyle $startupBtn $cBtnGreenActiveBg $cBtnGreenActiveBorder $cBtnGreenActiveText $cBtnGreenActiveHover
        }else{
            $startupBtn.Text = 'Avvio Windows: OFF'
            Set-ButtonStyle $startupBtn $cBtnBaseBg $cBtnBaseBorder $cTextDim $cBtnBaseHover
        }

        $s = Get-AgentLiveStatus
        if(!$s){
            $failure = Read-AgentJson (Join-Path (Get-AgentDirectory) 'startup-error.json') 4096
            $cardStatus.Tag.Value.Text = 'NON ATTIVO'
            $cardStatus.Tag.Value.ForeColor = $cRed
            $cardStatus.Tag.Sub.Text = if($failure){'Errore: '+$failure.message}else{'Premi "Avvia Agente"'}
            $stop.Enabled = $true; $optimizeBtn.Enabled = $false; $flushCompBtn.Enabled = $false; $clampBtn.Enabled = $false; $startBtn.Enabled = $true; $restartBtn.Enabled = $true
            Set-ButtonStyle $startBtn $cBtnGreenActiveBg $cBtnGreenActiveBorder $cBtnGreenActiveText $cBtnGreenActiveHover
            return
        }

        $alive = $s.identity_alive
        $stop.Enabled = $true
        $optimizeBtn.Enabled = ($alive -and $s.responding)
        $flushCompBtn.Enabled = ($alive -and $s.responding)
        $clampBtn.Enabled = ($alive -and $s.responding)
        $startBtn.Enabled = (!$alive)
        $restartBtn.Enabled = $true

        if(!$alive){
            Set-ButtonStyle $startBtn $cBtnGreenActiveBg $cBtnGreenActiveBorder $cBtnGreenActiveText $cBtnGreenActiveHover
        }else{
            Set-ButtonStyle $startBtn $cBtnBaseBg $cBtnBaseBorder $cTextDim $cBtnBaseHover
        }

        # Aggiornamento Card 0: Stato Agente
        if(!$alive){
            $cardStatus.Tag.Value.Text = 'AGENTE FERMO'
            $cardStatus.Tag.Value.ForeColor = $cRed
            $cardStatus.Tag.Sub.Text = 'Processi ripristinati'
        }elseif(!$s.responding){
            $cardStatus.Tag.Value.Text = 'IN ATTESA'
            $cardStatus.Tag.Value.ForeColor = $cAmber
            $cardStatus.Tag.Sub.Text = 'Aggiornamenti in coda'
        }else{
            $cardStatus.Tag.Value.Text = 'ATTIVO'
            $cardStatus.Tag.Value.ForeColor = $cGreen
            $own = if($null -eq $s.own_private_bytes){'N/D'}else{'{0:N1} MiB' -f ($s.own_private_bytes/1MB)}
            $cardStatus.Tag.Sub.Text = ('PID: ' + $s.process_id + ' | Costo: ' + $own)
        }

        # Aggiornamento Card 1: Pressione RAM Sistema
        if($s.pressure -and $null -ne $s.pressure.Percent){
            $pct = [double]$s.pressure.Percent
            $dispMiB = [double]$s.pressure.AvailableBytes / 1MB
            $totMiB = [double]$s.pressure.TotalBytes / 1MB
            $cardRam.Tag.Value.Text = ('{0:N1}%' -f $pct)
            $cardRam.Tag.Value.ForeColor = if($pct -ge 85){$cRed}elseif($pct -ge 75){$cAmber}else{$cCyanLight}
            $cardRam.Tag.Sub.Text = ('Liberi: {0:N0} MiB su {1:N0} MiB' -f $dispMiB, $totMiB)
        }else{
            $cardRam.Tag.Value.Text = 'Acquisizione...'
            $cardRam.Tag.Sub.Text = 'Telemetria in arrivo'
        }

        # Aggiornamento Card 2: Attivita CPU Sistema & EcoQoS
        try {
            $sysCpu = [AmeCpuMeter]::GetSystemCpuUsage()
            $cardCpu.Tag.Value.Text = ('{0:N1}%' -f $sysCpu)
            $cardCpu.Tag.Value.ForeColor = if($sysCpu -ge 85){$cRed}elseif($sysCpu -ge 65){$cAmber}else{$cCyanLight}
            $ecoStr = if($s.configuration -and $s.configuration.background_cpu_priority_demotion){'EcoQoS: Attivo'}else{'EcoQoS: Off'}
            $ameCpuStr = if($null -ne $s.own_cpu_percent){'{0:N1}%' -f $s.own_cpu_percent}else{'0.0%'}
            $cardCpu.Tag.Sub.Text = ('AME: ' + $ameCpuStr + ' | ' + $ecoStr)
        } catch {
            $cardCpu.Tag.Value.Text = 'N/D'
            $cardCpu.Tag.Sub.Text = 'Misura CPU non disp.'
        }

        $dist = $s.distributed
        $modeTag = if($dist -and $dist.operation_mode){$dist.operation_mode.ToUpper()}else{'STANDARD'}

        # Aggiornamento Card 3: Modalita Operativa
        if($dist -and $dist.operation_mode -eq 'clamp'){
            $cardMode.Tag.Value.Text = 'GIOCO (CLAMP)'
            $cardMode.Tag.Value.ForeColor = $cViolet
            $cardMode.Tag.Sub.Text = ($dist.clamp_target_process + ' limitato a ' + $dist.clamp_target_threshold_mib + ' MiB')
            $clampBtn.Text = 'Gioco: ATTIVO'
            Set-ButtonStyle $clampBtn $cBtnVioletActiveBg $cBtnVioletActiveBorder $cBtnVioletActiveText $cBtnVioletActiveHover
        }else{
            $cardMode.Tag.Value.Text = $modeTag
            $cardMode.Tag.Value.ForeColor = $cGreen
            $cardMode.Tag.Sub.Text = 'Multi-Lane Automatico'
            $clampBtn.Text = 'Modalita Gioco (Clamp)'
            Set-ButtonStyle $clampBtn $cBtnBaseBg $cBtnBaseBorder $cBtnBaseText $cBtnBaseHover
        }

        # Aggiornamento Card 4: Risparmio & Compressione
        $compStr = if($dist -and $null -ne $dist.compression_mib){$dist.compression_mib.ToString()+' MiB (Flush: '+$dist.compression_flushes+')'}else{'N/D'}
        $winReclaims = if($dist){$dist.windows_reclaims}else{0}
        $browserReclaims = if($dist){$dist.browser_subprocess_reclaims}else{0}
        $cardSaving.Tag.Value.Text = ('Windows: ' + $winReclaims + ' | Web: ' + $browserReclaims)
        $cardSaving.Tag.Value.ForeColor = $cGreen
        $cardSaving.Tag.Sub.Text = ('Compressione: ' + $compStr)

        # Pannello Telemetria / Ultimo Intervento
        if($s.last_result){
            $diffStr = if($s.last_result.assessment){' [Differenza netta: {0:+0.0;-0.0;0.0} MiB]' -f ($s.last_result.assessment.NetObservedDropBytes/1MB)}else{''}
            $lblIntervention.Text = ('ULTIMO INTERVENTO: ' + $s.last_result.message + $diffStr)
        }else{
            $lblIntervention.Text = 'IN ASCOLTO: Monitoraggio dinamico della memoria attivo su tutti i processi di sistema.'
        }
        $lblDetails.Text = ('Processi osservati: ' + $s.process_count + ' | Scaricamenti schede: ' + $s.confirmed_discards + ' | Ripristinati al risveglio: ' + $(if($dist){$dist.restored_processes}else{0}))

        # Popolamento Tabella Processi
        $grid.Rows.Clear()
        foreach($p in @($s.processes)){
            $methodCol = if($p.distributed_api -and $p.distributed_api -ne 'Non attiva'){$p.distributed_api}else{$p.method}
            $memStr = if($null -eq $p.private_bytes){'N/D'}else{'{0:N1}' -f ($p.private_bytes/1MB)}
            $idx = $grid.Rows.Add('  ' + $p.name, $p.count, $memStr, $methodCol)
            $rowObj = $grid.Rows[$idx]

            # Evidenziazione colore per tipo processo
            if($methodCol -like '*RAM Clamping*'){
                $rowObj.DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(216, 180, 254)
                $rowObj.DefaultCellStyle.Font = New-Object Drawing.Font('Segoe UI', 9.25, [Drawing.FontStyle]::Bold)
            }elseif($methodCol -like '*browser*'){
                $rowObj.DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(125, 211, 252)
            }elseif($methodCol -like '*Windows*'){
                $rowObj.DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(167, 243, 208)
            }
        }

        # Aggiornamento Console Eventi
        $connections = @($s.profiles|ForEach-Object {$_.browser+': '+$(if($_.ready){'COLLEGATO'}else{'IN COLLEGAMENTO'})+'; schede autorizzate '+$_.authorized_tabs})
        $log.Text = ($connections + @($s.recent)) -join "`r`n"
        $log.SelectionStart = $log.Text.Length
        $log.ScrollToCaret()

    }catch{
        $cardStatus.Tag.Value.Text = 'ERRORE LETTURA'
        $cardStatus.Tag.Value.ForeColor = $cRed
        $cardStatus.Tag.Sub.Text = $_.Exception.Message
    }
}

# --- Gestione Eventi Click ---
$startBtn.Add_Click({
    try{
        $cardStatus.Tag.Value.Text = 'AVVIO IN CORSO...'
        $cardStatus.Tag.Value.ForeColor = $cAmber
        $view.Refresh()
        & (Join-Path $PSScriptRoot 'agent-control.ps1') -Action Start | Out-Null
        Update-AgentView
    }catch{$cardStatus.Tag.Sub.Text = 'Errore avvio: '+$_.Exception.Message}
})

$stop.Add_Click({
    try{
        $res = Request-AgentStop
        $cardStatus.Tag.Value.Text = 'ARRESTATO'
        $cardStatus.Tag.Value.ForeColor = $cRed
        $cardStatus.Tag.Sub.Text = 'Tutti i processi ripristinati alle priorita normali'
        Update-AgentView
    }catch{$cardStatus.Tag.Sub.Text = $_.Exception.Message}
})

$restartBtn.Add_Click({
    try{
        $cardStatus.Tag.Value.Text = 'RIAVVIO IN CORSO...'
        $cardStatus.Tag.Value.ForeColor = $cAmber
        $view.Refresh()
        & (Join-Path $PSScriptRoot 'agent-control.ps1') -Action Restart | Out-Null
        Update-AgentView
    }catch{$cardStatus.Tag.Sub.Text = 'Errore riavvio: '+$_.Exception.Message}
})

$optimizeBtn.Add_Click({
    try{
        $cRes = Invoke-AmeInternalApiCommand -Command @{command='compact_internal'} -Root $PSScriptRoot
        $dRes = Invoke-AmeInternalApiCommand -Command @{command='distribute_budget'} -Root $PSScriptRoot
        $freedMiB = if($cRes -and $null -ne $cRes.freed_bytes){[math]::Round([double]$cRes.freed_bytes/1MB,1)}else{0.0}
        $lblIntervention.Text = ('OTTIMIZZAZIONE ESEGUITA: Compattazione interna ' + $freedMiB + ' MiB liberati.')
        Update-AgentView
    }catch{$lblIntervention.Text = 'Errore ottimizzazione: '+$_.Exception.Message}
})

$flushCompBtn.Add_Click({
    try{
        $lblIntervention.Text = 'Esecuzione Memory Pulse Flush: svuotamento memoria compressa di Windows...'
        $view.Refresh()
        $fRes = Invoke-AmeInternalApiCommand -Command @{command='flush_compression'} -Root $PSScriptRoot
        $freedMiB = if($fRes -and $null -ne $fRes.freed_bytes){[math]::Round([double]$fRes.freed_bytes/1MB,1)}else{0.0}
        if($freedMiB -gt 0){
            $lblIntervention.Text = ('MEMORY PULSE FLUSH COMPLETATO: Svuotati ' + $freedMiB + ' MiB dalla memoria compressa.')
        }elseif($fRes -and $fRes.message){
            $lblIntervention.Text = $fRes.message
        }else{
            $lblIntervention.Text = 'MEMORY PULSE FLUSH: 0 MiB rilasciati. Con RAM satura (>88%), Windows protegge la memoria compressa per evitare crash.'
        }
        Update-AgentView
    }catch{$lblIntervention.Text = 'Errore svuotamento compressione: '+$_.Exception.Message}
})

$clampBtn.Add_Click({
    try{
        $res = Show-ClampDialog
        if($res){
            if($res.Action -eq 'clamp'){
                if(!$res.Process){throw 'Inserire il nome del processo target.'}
                $cRes = Invoke-AmeInternalApiCommand -Command @{command='set_mode';mode='clamp';target_process=$res.Process;target_threshold_mib=$res.Threshold} -Root $PSScriptRoot
                $lblIntervention.Text = ('MODALITA CLAMP ATTIVATA per "' + $res.Process + '" limitato a ' + $res.Threshold + ' MiB (Mix A+B).')
            }elseif($res.Action -eq 'standard'){
                $cRes = Invoke-AmeInternalApiCommand -Command @{command='set_mode';mode='standard'} -Root $PSScriptRoot
                $lblIntervention.Text = 'MODALITA STANDARD RIPRISTINATA (clamping rimosso).'
            }
            Update-AgentView
        }
    }catch{$lblIntervention.Text = 'Errore clamping: '+$_.Exception.Message}
})

$startupBtn.Add_Click({
    try{
        $act = if(Test-StartupEnabled){'DisableStartup'}else{'EnableStartup'}
        & (Join-Path $PSScriptRoot 'agent-control.ps1') -Action $act | Out-Null
        Update-AgentView
    }catch{$lblIntervention.Text = $_.Exception.Message}
})

$export.Add_Click({
    try{
        $zip = & (Join-Path $PSScriptRoot 'agent-control.ps1') -Action Export
        if($zip){ Start-Process explorer.exe -ArgumentList ('/select,"'+$zip.Path+'"') }
    }catch{$lblIntervention.Text = $_.Exception.Message}
})

$folder.Add_Click({
    Start-Process notepad.exe -ArgumentList ('"'+(Join-Path $PSScriptRoot 'agent-config.json')+'"')
})

# --- Timer di Aggiornamento Telemetrico (Ogni 2 Secondi) ---
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-AgentView })

try{
    Update-AgentView
    $timer.Start()
    [void]$view.ShowDialog()
}finally{
    $timer.Stop()
    $timer.Dispose()
    $view.Dispose()
}