param([switch]$NativeGrid)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'windows-model.ps1')
. (Join-Path $root 'strategy-model.ps1')
function Assert($ok,[string]$message){if(!$ok){throw $message}}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'hub.ps1'),[ref]$tokens,[ref]$errors)
Assert (!$errors.Count) 'Parsing hub fallito'
foreach($name in @('Save-Selection','Show-Inventory','Sort-RamInventory','Request-RamSort','On-InventorySelectionChanged','Show-Snapshot')){
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Assert ($null -ne $fn) ('Funzione mancante: '+$name)
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Callback([string]$prefix){
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith($prefix)},$true)
    Assert ($null -ne $fn) ('Callback mancante: '+$prefix)
    return $fn.Arguments[0].ScriptBlock.GetScriptBlock()
}
$changed=Callback '$grid.Add_CellValueChanged('
$header=Callback '$grid.Add_ColumnHeaderMouseClick('
if($NativeGrid){
    Assert ($env:OS -eq 'Windows_NT') 'La variante NativeGrid richiede Windows'
    Add-Type -AssemblyName System.Windows.Forms
    $grid=New-Object Windows.Forms.DataGridView
    $grid.AllowUserToAddRows=$false
    $choose=New-Object Windows.Forms.DataGridViewCheckBoxColumn;$choose.Name='choose';$choose.SortMode='NotSortable'
    [void]$grid.Columns.Add($choose)
    foreach($name in @('name','pid','private','commit','cpu','idle','faults','method','state')){[void]$grid.Columns.Add($name,$name);$grid.Columns[$name].SortMode='NotSortable'}
    $grid.Columns['private'].SortMode='Programmatic'
    [void]$grid.Handle
    $grid.Add_CellValueChanged($changed)
}else{
    if(!('AmeInventoryTests.Grid' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
namespace AmeInventoryTests {
    public class Cell { public object Value; public bool ReadOnly; public string ToolTipText; }
    public class Style { public object ForeColor; }
    public class Header { public string SortGlyphDirection; }
    public class Column { public int Index; public Header HeaderCell=new Header(); }
    public class Row {
        public object Tag;
        public Dictionary<string,Cell> Cells=new Dictionary<string,Cell>();
        public Style DefaultCellStyle=new Style();
    }
    public class Rows : List<Row> {
        public int Add(bool selected,string name,int pid,string privateRam,string commit,string cpu,string idle,string faults,string method,string state){
            var row=new Row();
            string[] names={"choose","name","pid","private","commit","cpu","idle","faults","method","state"};
            object[] values={selected,name,pid,privateRam,commit,cpu,idle,faults,method,state};
            for(int i=0;i<names.Length;i++)row.Cells[names[i]]=new Cell {Value=values[i]};
            base.Add(row);return Count-1;
        }
    }
    public class Grid {
        public Rows Rows=new Rows();
        public Dictionary<string,Column> Columns=new Dictionary<string,Column>();
        public List<Action> Pending=new List<Action>();
        public Cell CurrentCell;
        public bool IsDisposed;
        public int EndEditCalls;
        public Action EndEditNotification;
        public Row CurrentRow {get {foreach(var row in Rows)if(row.Cells.ContainsValue(CurrentCell))return row;return null;}}
        public Grid(){string[] names={"choose","name","pid","private","commit","cpu","idle","faults","method","state"};for(int i=0;i<names.Length;i++)Columns[names[i]]=new Column {Index=i};}
        public bool EndEdit(){EndEditCalls++;if(EndEditNotification!=null)EndEditNotification();return true;}
        public object BeginInvoke(Action action){Pending.Add(action);return null;}
        public void Dispose(){IsDisposed=true;}
    }
}
'@
    }
    $grid=New-Object AmeInventoryTests.Grid
}
$result=[pscustomobject]@{Text=''}
$script:selection=@{};$script:targetStates=@{};$script:inventoryRows=@()
$script:renderingInventory=$false;$script:sortQueued=$false;$script:sortFocusKey=''
$script:batchActive=$false;$script:mode='observe';$script:restartMode=$null
$previousWindir=$env:windir;$env:windir='C:\Windows'
[int]$session=[Diagnostics.Process]::GetCurrentProcess().SessionId
function Process-Row([int]$pidValue,$privateBytes){
    [pscustomobject]@{pid=$pidValue;creation_filetime=([string](1000+$pidValue));name=('app'+$pidValue+'.exe');image_path=('D:\Apps\app'+$pidValue+'.exe');same_user=$true;session_id=$session;critical=$false;memory_available=($null -ne $privateBytes);private_working_set_bytes=$privateBytes;working_set_bytes=$(if($null -eq $privateBytes){0}else{$privateBytes+32MB});private_commit_bytes=2GB;cpu_percent=0.01;low_activity_seconds=70;page_faults_per_second=0;foreground_window_owner=$false}
}
$sample=[pscustomobject]@{processes=@((Process-Row 101 512MB),(Process-Row 102 1536MB),(Process-Row 103 999MB),(Process-Row 104 128MB),(Process-Row 105 1024MB),(Process-Row 106 1299MB),(Process-Row 107 $null))}
function Flush-RamSort {
    if($NativeGrid){[Windows.Forms.Application]::DoEvents()}
    else{while($grid.Pending.Count){$action=$grid.Pending[0];$grid.Pending.RemoveAt(0);$action.Invoke()}}
    Assert (!$script:sortQueued) 'Ordinamento rinviato non completato'
}
function Mark([int]$pidValue,[bool]$value=$true){
    $row=@($grid.Rows|Where-Object {$_.Tag.Pid -eq $pidValue})[0]
    $index=$grid.Rows.IndexOf($row)
    $row.Cells['choose'].Value=$value
    if(!$NativeGrid){& $changed $grid ([pscustomobject]@{RowIndex=$index;ColumnIndex=$grid.Columns['choose'].Index})}
    Flush-RamSort
}
try{
    Show-Snapshot $sample
    Assert ((@($grid.Rows|ForEach-Object {$_.Tag.Pid}) -join ',') -eq '102,106,105,103,101,104,107') 'RAM ordinata come testo o dati mancanti in cima'
    Assert ($grid.Columns['private'].HeaderCell.SortGlyphDirection.ToString() -eq 'Descending') 'Direzione RAM non visibile'
    Assert (!(@($grid.Rows|Where-Object {$_.Tag.Pid -eq 101})[0].Tag.Blocked)) 'Fixture selezionabile esclusa prima dei clic'
    $oldStamp=[DateTime]::UtcNow.AddMinutes(-1);$script:lastComplete=$oldStamp
    foreach($pidValue in @(101,102,103,105,106)){Mark $pidValue}
    Assert ($script:selection.Count -eq 5 -and @($grid.Rows|Where-Object {$_.Cells['choose'].Value}).Count -eq 5) 'Cinque caselle non conservate durante il riordino'
    Mark 104
    Assert ($script:selection.Count -eq 5 -and !(@($grid.Rows|Where-Object {$_.Tag.Pid -eq 104})[0].Cells['choose'].Value) -and $result.Text -like '*massimo 5*') 'Sesta selezione accettata o senza spiegazione'
    Assert ($script:lastComplete -eq $oldStamp) 'Spuntare o ordinare rende nuova una telemetria vecchia'
    $before=@($script:selection.Keys|Sort-Object) -join ','
    & $header $grid ([pscustomobject]@{ColumnIndex=$grid.Columns['private'].Index})
    Assert ($script:sortQueued) 'Clic RAM non richiede ordinamento'
    Flush-RamSort
    Assert ((@($script:selection.Keys|Sort-Object) -join ',') -eq $before -and $script:lastComplete -eq $oldStamp) 'Clic RAM cambia identita o freschezza'
    & $header $grid ([pscustomobject]@{ColumnIndex=$grid.Columns['name'].Index})
    Assert (!$script:sortQueued) 'Clic su altra colonna avvia il riordino RAM'
    if(!$NativeGrid){
        $script:notifications=0
        $grid.EndEditNotification=[Action]{$script:notifications++;On-InventorySelectionChanged 0 0}
        Request-RamSort '101:1101'
        Flush-RamSort
        Assert ($script:notifications -eq 1 -and !$script:renderingInventory) 'Commit reentrante provoca un altro riordino'
        $grid.EndEditNotification=$null
    }
    $sample.processes[0].private_working_set_bytes=1800MB;$sample.processes[0].working_set_bytes=1832MB
    Show-Snapshot $sample
    Assert ($grid.Rows[0].Tag.Pid -eq 101 -and $grid.Rows[0].Cells['choose'].Value -and $script:selection.Count -eq 5) 'Nuove metriche spostano la casella a un altro processo'
    $sample.processes[1].image_path='D:\Other\app102.exe'
    Show-Snapshot $sample
    Assert (!$script:selection.ContainsKey('102:1102') -and !(@($grid.Rows|Where-Object {$_.Tag.Pid -eq 102})[0].Cells['choose'].Value)) 'Percorso cambiato eredita la selezione'
    $sample.processes[0].creation_filetime='9000'
    Show-Snapshot $sample
    Assert (!$script:selection.ContainsKey('101:1101') -and !$grid.Rows[0].Cells['choose'].Value) 'PID riutilizzato eredita la selezione'
    Mark 103 $false
    Assert (!$script:selection.ContainsKey('103:1103')) 'Deselezione persa nel riordino'
    $script:renderingInventory=$true
    & $changed $grid ([pscustomobject]@{RowIndex=0;ColumnIndex=0})
    Assert (!$script:sortQueued) 'Rendering programmatico genera un riordino ricorsivo'
    $script:renderingInventory=$false
    Write-Host ('PASS inventory RAM order: numeric bytes, 5 selections, sixth rejected, header/checkbox callbacks, deferred commit, identity/path and unchanged telemetry time; native grid: '+[bool]$NativeGrid)
}finally{$grid.Dispose();$env:windir=$previousWindir}
