#Requires -Version 5.1
# native_process_test.ps1 -- Invoke-NativeStdinFile (scripts/lib/native_process.ps1) reicht eine Datei byte-genau an stdin. Der Bau-Kontext
# des master-Abbilds ist ein Tar; Start-Process -RedirectStandardInput liest die Datei unter Linux als Text, das Tar kam dort als
# "invalid tar" an. Der Test schickt 8 MB Binaerdaten (alle Byte-Werte, ungueltiges UTF-8, ein BOM, Zeilenenden) an ein Kind, das stdin
# unveraendert in eine Datei kopiert (die laufende PowerShell selbst; stdout taugt nicht: Windows PowerShell 5.1 stellt ihm ein BOM
# voran), und vergleicht die Pruefsumme. Dazu: der Exit-Code kommt an, und ein Prozess, der nichts liest, haengt den Aufruf nicht auf.
# Eine Gegenprobe zeigt, dass ein Text-Weg die Probedaten veraendert (sonst prueft der Test nichts).
# Kein Docker. Laeuft im pre-commit (Windows) und als erster Schritt des Linux-Jobs backup-roundtrip in free-gates.yml.
# Usage: .\scripts\dev\native_process_test.ps1   Exit-Code = Anzahl fehlgeschlagener Pruefungen.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '..\lib\native_process.ps1')
. (Join-Path $PSScriptRoot '..\lib\hash.ps1')   # Get-FileSha256 statt Get-FileHash (Grund dort)
$fails = 0
function Check([bool]$Ok, [string]$Name) {
    if ($Ok) { Write-Host "  PASS $Name" -ForegroundColor Green } else { Write-Host "  FAIL $Name" -ForegroundColor Red; $script:fails++ }
}

$dir = Join-Path ([System.IO.Path]::GetTempPath()) ('np_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$pwsh = (Get-Process -Id $PID).Path
try {
    # Probedaten: Block aus allen Byte-Werten und Stolpersteinen, per BlockCopy auf 8 MB verdoppelt.
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($i in 0..255) { $bytes.Add([byte]$i) }
    $bytes.AddRange([byte[]](0xEF, 0xBB, 0xBF, 0x0D, 0x0A, 0x0D, 0x0A, 0xC3, 0x28, 0xE2, 0x82, 0xFF, 0xFE, 0x00, 0x00))
    $block = $bytes.ToArray()
    $big = New-Object 'byte[]' (8MB)
    [System.Buffer]::BlockCopy($block, 0, $big, 0, $block.Length)
    $filled = $block.Length
    while ($filled -lt $big.Length) {
        $c = [Math]::Min($filled, $big.Length - $filled)
        [System.Buffer]::BlockCopy($big, 0, $big, $filled, $c)
        $filled += $c
    }
    $inFile = Join-Path $dir 'probe.bin'
    [System.IO.File]::WriteAllBytes($inFile, $big)
    $inHash = Get-FileSha256 $inFile

    $txtFile = Join-Path $dir 'probe.text'
    $rd = New-Object System.IO.StreamReader($inFile)
    try { [System.IO.File]::WriteAllText($txtFile, $rd.ReadToEnd() + "`n", (New-Object System.Text.UTF8Encoding($false))) } finally { $rd.Dispose() }
    Check ((Get-FileSha256 $txtFile) -ne $inHash) 'Gegenprobe: ein Text-Weg veraendert die Probedaten (die Probe taugt)'

    # stdin aus einer Datei, stdout und stderr in Dateien.
    $echoFile = Join-Path $dir 'echo.bin'
    $env:NP_TEST_ECHO_FILE = $echoFile
    $child = Join-Path $dir 'child.ps1'
    [System.IO.File]::WriteAllText($child, '$o = [System.IO.File]::Create($env:NP_TEST_ECHO_FILE); [Console]::OpenStandardInput().CopyTo($o); $o.Dispose()')
    $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $child)
    $code = Invoke-NativeStdinFile -FilePath $pwsh -ArgumentList $argv -StdinFile $inFile -StdoutFile (Join-Path $dir 'o.txt') -StderrFile (Join-Path $dir 'e.txt')
    Check ($code -eq 0) "Programm endet mit 0 (ist $code)"
    Check ((Test-Path $echoFile) -and (Get-FileSha256 $echoFile) -eq $inHash) 'stdin aus einer Datei kommt byte-genau an (Pruefsumme von 8 MB gleich)'

    # Ohne Ausgabe-Dateien (Konsole geerbt) und mit Exit-Code des Kindes.
    $exit = Join-Path $dir 'exit.ps1'
    [System.IO.File]::WriteAllText($exit, '[Console]::OpenStandardInput().CopyTo([System.IO.Stream]::Null); exit 7')
    $code = Invoke-NativeStdinFile -FilePath $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $exit) -StdinFile $inFile
    Check ($code -eq 7) "Exit-Code des Programms kommt an (ist $code)"

    # Ein Programm, das stdin nie liest, darf den Aufruf nicht aufhaengen (8 MB passen in keinen Pipe-Puffer).
    $noread = Join-Path $dir 'noread.ps1'
    [System.IO.File]::WriteAllText($noread, 'exit 3')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $code = Invoke-NativeStdinFile -FilePath $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $noread) -StdinFile $inFile
    Check ($code -eq 3 -and $sw.Elapsed.TotalSeconds -lt 60) "Programm ohne stdin-Lesen: Exit-Code kommt an, kein Haengen (ist $code, $([int]$sw.Elapsed.TotalSeconds) s)"
} finally { $env:NP_TEST_ECHO_FILE = $null; Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }

if ($fails -eq 0) { Write-Host 'PASS native_process_test' -ForegroundColor Green } else { Write-Host "FAIL native_process_test ($fails)" -ForegroundColor Red }
exit $fails
