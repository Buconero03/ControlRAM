param([switch]$NativeGrid)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'browser-connection.ps1')
. (Join-Path $root 'browser-model.ps1')
function Assert($ok,[string]$message){if(!$ok){throw $message}}
function Add-HubLog([string]$message){}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ame browser connection '+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$script:browserReportsDirectory=Join-Path $temp 'reports'
Initialize-BrowserDiagnostics
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'browser-panel.ps1'),[ref]$null,[ref]$null)
foreach($name in @('script:Poll-Browser','script:Update-BrowserGrid')){
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
if($NativeGrid){
    Add-Type -AssemblyName System.Windows.Forms
    $script:browserGrid=New-Object Windows.Forms.DataGridView
    $browserGrid.AllowUserToAddRows=$false;$browserGrid.SelectionMode='FullRowSelect'
    foreach($c in @('profile','title','decision')){[void]$browserGrid.Columns.Add($c,$c)}
    [void]$browserGrid.Handle
}else{
    if(!('AmeBrowserTests.Grid' -as [type])){Add-Type @'
using System.Collections.Generic;
namespace AmeBrowserTests {
 public class Row {public object Tag; public bool Selected;}
 public class Rows:List<Row> {public int Add(params object[] values){base.Add(new Row());return Count-1;}}
 public class Grid {public Rows Rows=new Rows(); public Row[] SelectedRows=new Row[0]; public void ClearSelection(){} public void Dispose(){} }
}
'@}
    $script:browserGrid=New-Object AmeBrowserTests.Grid
}
$script:mainBrowserLogBox=[pscustomobject]@{Text=''}
$script:browserLabel=[pscustomobject]@{Text=''};$script:browserLogBox=[pscustomobject]@{Text=''}
$script:browserState=[pscustomobject]@{Text=''};$script:discardButton=[pscustomobject]@{Enabled=$false}
$script:browserConfig=Get-Content (Join-Path $root 'browser/config.json') -Raw|ConvertFrom-Json
$script:bridge=[pscustomobject]@{Data=@();Sent=(New-Object 'Collections.Generic.List[object]');Closed=(New-Object 'Collections.Generic.List[int]');FailSend=$false}
$bridge|Add-Member ScriptMethod Drain {$d=$this.Data;$this.Data=@();return $d}
$bridge|Add-Member ScriptMethod Send {param($id,$json);if($this.FailSend){return $false};$this.Sent.Add(($json|ConvertFrom-Json));return $true}
$bridge|Add-Member ScriptMethod Disconnect {param($id);$this.Closed.Add($id)}
$script:profiles=@{};$script:browserClosing=@{};$script:browserCooldown=@{};$script:browserConfirmed=0
$script:pendingBrowser=$null;$script:mode='observe';$script:batchActive=$false
$script:testSession=[guid]::NewGuid().ToString()
function Receive([hashtable]$message,[int]$connection=1){
    $message.session=$script:testSession
    $bridge.Data=@([pscustomobject]@{Connection=$connection;Error='';Json=($message|ConvertTo-Json -Depth 8 -Compress)})
    Poll-Browser
}
function Hello([int]$connection=1){Receive @{type='hello';protocol=4;extension=$browserConfig.extension_id} $connection}
function Snapshot([long]$sequence=1,[object[]]$tabs=@(@{id=42;revision='12345678-1234-1234-1234-123456789012';title='Pagina di prova';blocked='';discarded=$false}),[int]$connection=1){Receive @{type='snapshot';protocol=4;sequence=$sequence;tabs=$tabs} $connection}
try{
    Set-BrowserConnectionStatus 'waiting' 'Attendo Chrome.'
    Assert (Test-Path -LiteralPath $script:browserReportPath) 'No diagnostic before a successful connection'
    Hello
    Assert ($profiles.Count -eq 1 -and !$profiles[1].Ready -and $browserLabel.Text -like '*Profili pronti: 0*') 'Hello falsely shown as ready'
    Assert (@($bridge.Sent|Where-Object type -eq inventory_ack).Count -eq 0) 'Acknowledgement sent before inventory'
    Assert ($mainBrowserLogBox.Text -like '*richiesta Collega ricevuta*') 'Main tab hides the connection request'
    Snapshot
    Assert ($mainBrowserLogBox.Text -like '*Profili pronti: 1*' -and $mainBrowserLogBox.Text -like '*collegamento pronto*') 'Main tab does not show confirmed connection'
    Assert ($profiles[1].Ready -and $browserGrid.Rows.Count -eq 1 -and $browserLabel.Text -like '*Profili pronti: 1*') 'Valid inventory not rendered and ready'
    Assert (@($bridge.Sent|Where-Object type -eq inventory_ack).Count -eq 1 -and $bridge.Sent[-1].count -eq 1) 'No matching inventory acknowledgement'
    Assert ($browserGrid.Rows[0].Tag.Id -eq 42 -and $browserGrid.Rows[0].Tag.Connection -eq 1) 'Rendered tab identity changed'
    Snapshot 2 @()
    Assert ($profiles[1].Ready -and $browserGrid.Rows.Count -eq 0 -and $bridge.Sent[-1].count -eq 0) 'Empty inventory incorrectly disconnected'
    # A duplicate update must not be acknowledged or allowed to act.
    $before=@($bridge.Sent|Where-Object type -eq inventory_ack).Count
    Snapshot 2
    Assert (!$profiles.ContainsKey(1) -and $browserConnectionCode -eq 'message_rejected' -and @($bridge.Sent|Where-Object type -eq inventory_ack).Count -eq $before) 'Duplicate sequence accepted'
    Assert ($browserLogBox.Text -like '*Sequenza elenco*' -and $bridge.Sent[-1].type -eq 'connection_error') 'Failure lacks visible reason or extension notification'
    # Real Update-BrowserGrid is exercised, with an intentional render failure.
    Hello 2
    $savedGrid=$script:browserGrid;$script:browserGrid=$null
    Snapshot 1 @(@{id=7;revision=[guid]::NewGuid().ToString();title='p';blocked='';discarded=$false}) 2
    $script:browserGrid=$savedGrid
    Assert (!$profiles.ContainsKey(2) -and @($bridge.Sent|Where-Object type -eq inventory_ack).Count -eq $before) 'Render failure acknowledged as connected'
    # Invalid tab and old extension receive explicit reasons, without mutation.
    Hello 3
    Snapshot 1 @(@{id=7;revision='bad';title='p';blocked='';discarded=$false}) 3
    Assert (!$profiles.ContainsKey(3) -and $browserLogBox.Text -like '*Scheda non valida*') 'Bad inventory accepted or hidden'
    Receive @{type='hello';protocol=3;extension=$browserConfig.extension_id} 4
    Assert (!$profiles.ContainsKey(4) -and $browserLogBox.Text -like '*Estensione precedente*') 'Previous extension silently accepted'
    Hello 5;$profiles[5].Seen=[DateTime]::UtcNow.AddSeconds(-16);Poll-Browser
    Assert (!$profiles.ContainsKey(5) -and $browserConnectionCode -eq 'inventory_missing') 'First inventory can wait indefinitely'
    Hello 6;Snapshot 1 @() 6;$profiles[6].Seen=[DateTime]::UtcNow.AddSeconds(-31);Poll-Browser
    Assert (!$profiles.ContainsKey(6) -and $browserConnectionCode -eq 'inventory_stale') 'Stale connection kept ready'
    Hello 7;$bridge.FailSend=$true;Snapshot 1 @() 7;$bridge.FailSend=$false
    Assert (!$profiles.ContainsKey(7)) 'Failed acknowledgement kept a ready profile'
    $bridge.Data=@([pscustomobject]@{Connection=0;Error='Host diverso da questa installazione';Json=$null});Poll-Browser
    Assert ($browserLogBox.Text -like '*Host diverso*') 'Native host path error hidden'
    Assert ($browserConfirmed -eq 0 -and !$discardButton.Enabled -and !$pendingBrowser) 'Connection checks triggered an intervention'
    # Refresh when disconnected used to silently do nothing.
    $callback=$ast.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith('$browserRefresh.Add_Click(')},$true)
    & $callback.Arguments[0].ScriptBlock.GetScriptBlock()
    Assert ($browserConnectionCode -eq 'no_profile') 'Refresh without connection has no feedback'
    # Browser identities and visible states remain separate with both open.
    Receive @{type='hello';protocol=4;extension=$browserConfig.firefox_extension_id;browser='Firefox';version='0.4.0'} 13
    Assert ($profiles[13].Browser -eq 'Firefox' -and $mainBrowserLogBox.Text -like '*Firefox: IN COLLEGAMENTO*') 'Firefox identity not visible before inventory'
    Snapshot 1 @(@{id=42;revision='12345678-1234-1234-1234-123456789013';title='Firefox page';blocked='';discarded=$false}) 13
    Assert ($mainBrowserLogBox.Text -like '*Firefox: COLLEGATO*' -and $profiles[13].Ready) 'Firefox never becomes ready'
    Assert ($browserGrid.Rows[$browserGrid.Rows.Count-1].Tag.Browser -eq 'Firefox') 'Browser lost in selection identity'
    Receive @{type='hello';protocol=4;extension=$browserConfig.extension_id;browser='Firefox'} 14
    Assert (!$profiles.ContainsKey(14)) 'Mismatched Chrome/Firefox identity accepted'
    Receive @{type='hello';protocol=4;extension='other@example.org';browser='Firefox'} 15
    Assert (!$profiles.ContainsKey(15)) 'Unknown Firefox extension accepted'
    $profiles[13].Seen=[DateTime]::UtcNow.AddSeconds(-31);Poll-Browser
    Assert ($mainBrowserLogBox.Text -like '*Firefox: NON COLLEGATO*') 'Firefox disconnected state remains falsely connected'
    # Actual Windows disconnect callback sends the opt-out before closing the transport.
    Hello 12;Snapshot 1 @() 12
    $callback=$ast.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith('$browserDisconnect.Add_Click(')},$true)
    & $callback.Arguments[0].ScriptBlock.GetScriptBlock()
    Assert ($bridge.Sent[-1].type -eq 'stop_connection' -and $bridge.Sent[-1].session -eq $testSession) 'Panel disconnect does not send the current session stop'
    Assert (!$profiles.ContainsKey(12) -and $browserClosing.ContainsKey(12)) 'Panel disconnect does not defer transport close for delivery'
    Assert ($mainBrowserLogBox.Text -like '*Scollegamento richiesto*') 'Main connection log hides manual disconnect'
    # Registration: relocated folder, corrupt manifest and wrong extension are distinguishable.
    [void][IO.Directory]::CreateDirectory((Join-Path $temp 'build'));[void][IO.Directory]::CreateDirectory((Join-Path $temp 'browser'))
    Copy-Item (Join-Path $root 'browser/config.json') (Join-Path $temp 'browser/config.json')
    $manifestPath=Join-Path $temp 'build/chrome-native-host.json';$exe=Join-Path $temp 'build/ame-browser-host.exe';[IO.File]::WriteAllText($exe,'fixture')
    $manifest=@{name=$browserConfig.host;path=$exe;type='stdio';allowed_origins=@('chrome-extension://'+$browserConfig.extension_id+'/')}
    [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json))
    Assert ((Get-BrowserManifestStatus $manifestPath $temp).Ready) 'Valid path with spaces rejected'
    Assert (!(Get-BrowserManifestStatus '' $temp).Ready -and !(Get-BrowserManifestStatus ($manifestPath+'.old') $temp).Ready) 'Missing or moved registration accepted'
    $manifest.allowed_origins=@('chrome-extension://wrong/');[IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json))
    Assert (!(Get-BrowserManifestStatus $manifestPath $temp).Ready) 'Wrong extension origin accepted'
    $firefoxManifest=Join-Path $temp 'build/firefox-native-host.json'
    $fm=@{name=$browserConfig.host;path=$exe;type='stdio';allowed_extensions=@($browserConfig.firefox_extension_id)}
    [IO.File]::WriteAllText($firefoxManifest,($fm|ConvertTo-Json))
    Assert ((Get-BrowserManifestStatus $firefoxManifest $temp Firefox).Ready) 'Firefox host manifest rejected'
    Assert (!(Get-BrowserManifestStatus $firefoxManifest $temp Chrome).Ready) 'Firefox manifest accepted as Chrome'
    $fm.allowed_extensions=@('other@example.org');[IO.File]::WriteAllText($firefoxManifest,($fm|ConvertTo-Json))
    Assert (!(Get-BrowserManifestStatus $firefoxManifest $temp Firefox).Ready) 'Wrong Firefox extension accepted in manifest'
    [IO.File]::WriteAllText($manifestPath,'{bad')
    Assert (!(Get-BrowserManifestStatus $manifestPath $temp).Ready) 'Invalid manifest accepted'
    # Export actual failure-only report, including the render error and connection reason.
    $records=@(Get-Content -LiteralPath $browserReportPath|ForEach-Object {$_|ConvertFrom-Json})
    Assert (@($records|Where-Object type -eq browser_error).Count -ge 3) 'Protocol/render error details not persisted'
    Assert (@($records|Where-Object code -eq inventory_missing).Count -eq 1) 'Timeout not persisted'
    $zip=& (Join-Path $root 'export-diagnostics.ps1') -Report @($browserReportPath) -OutputDirectory (Join-Path $temp 'exports')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($zip.Path)
    try{
        $entry=$archive.GetEntry('LEGGIMI.txt');$reader=New-Object IO.StreamReader($entry.Open());try{$summary=$reader.ReadToEnd()}finally{$reader.Dispose()}
        Assert ($summary -like '*COLLEGAMENTO*' -and $summary -like '*Scheda non valida*') 'Export hides connection failures'
    }finally{$archive.Dispose()}
    for($i=0;$i -lt 120;$i++){Set-BrowserConnectionStatus 'bounded' ('Evento '+$i)}
    Assert ($browserLogLines.Count -eq 100) 'Visible log grows without limit'
    $script:browserReportBytes=4MB;Set-BrowserConnectionStatus 'limit' 'Limite registro'
    Assert ($browserLogFailure -and $browserLabel.Text -like '*Diagnosi su file non disponibile*') 'Disk/size failure is silent'
    $fallback=Export-BrowserDiagnosis -OutputDirectory (Join-Path $temp 'fallback exports') -NoOpen
    Assert ($fallback -and (Test-Path -LiteralPath $fallback)) 'Cannot export visible log after report size/write failure'
    $archive=[IO.Compression.ZipFile]::OpenRead($fallback)
    try{
        $reader=New-Object IO.StreamReader($archive.GetEntry('LEGGIMI.txt').Open());try{$summary=$reader.ReadToEnd()}finally{$reader.Dispose()}
        Assert ($summary -like '*REGISTRO INCOMPLETO*' -and $summary -like '*Limite registro*') 'Fallback export lacks latest visible events or write error'
    }finally{$archive.Dispose()}
    Write-Host ('PASS connection handshake, actual inventory rendering, empty list, rejection, timeout, registration, visible errors and failure-only ZIP; native grid: '+[bool]$NativeGrid)
}finally{
    if($script:browserWriter){$script:browserWriter.Dispose()}
    if($script:browserGrid){$script:browserGrid.Dispose()}
    $script:browserReportsDirectory=$null
    if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}
}
