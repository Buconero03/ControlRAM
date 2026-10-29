$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$engine=Join-Path $root 'build\ame.exe'
function Assert($ok,[string]$message){if(!$ok){throw $message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ame-options-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$report=Join-Path $temp 'must-not-be-created.jsonl'
$cases=@(
    @('--recover-test','--allow-exe','D:\Apps\app.exe'),
    @('--recover-test','--allow-exe','D:\Apps\app.exe','--allow-process','123:456','--allow-process','124:789'),
    @('--recover-test','--allow-exe','D:\Apps\app.exe','--allow-exe','D:\Apps\other.exe','--allow-process','123:456'),
    @('--recover-test','--allow-exe','D:\Apps\app.exe','--allow-process','123:456','--seconds','181'),
    @('--observe','--recover-test','--allow-exe','D:\Apps\app.exe','--allow-process','123:456'),
    @('--recover','--recover-test','--allow-exe','D:\Apps\app.exe','--allow-process','123:456'),
    @('--recover-test','--recover','--allow-exe','D:\Apps\app.exe','--allow-process','123:456'),
    @('--recover-test','--allow-exe','D:\Apps\app.exe','--allow-process','123:bad')
)
try{
    foreach($case in $cases){
        $p=New-Object Diagnostics.Process
        $p.StartInfo.FileName=$engine
        $quoted=foreach($arg in (@($case)+@('--report',$report))){'"'+[string]$arg+'"'}
        $p.StartInfo.Arguments=$quoted -join ' '
        $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true
        $p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
        try{
            [void]$p.Start()
            $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
            Assert ($p.WaitForExit(5000)) 'Parser non termina'
            Assert ($p.ExitCode -ne 0 -and $stderr.Result -like '*ERROR:*') 'Selezione multipla/non valida o durata eccessiva accettata'
            Assert (!(Test-Path -LiteralPath $report)) 'Richiesta non valida ha aperto la sessione'
        }finally{if(!$p.HasExited){$p.Kill()};$p.Dispose()}
    }
    Write-Host 'PASS Windows native CLI: invalid single-test selections/modes/limits rejected before opening a report'
}finally{[IO.Directory]::Delete($temp,$true)}
