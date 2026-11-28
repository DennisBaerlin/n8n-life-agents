#Requires -Version 5.1
# secret_stdin_test.ps1 -- ein Geheimnis erreicht das Programm mit genau seinen Bytes (Invoke-NativeStdinBytes, scripts/lib/native_process.ps1).
# Eine Pipe (`$wert | & programm`) haengt ein Zeilenende an, und Windows PowerShell 5.1 stellt bei UTF-8-Konsole ein BOM davor: ein so
# erzeugter gpg-Schluessel bekommt ein Passwort, das niemand tippen kann. Der Lauf erzwingt die UTF-8-Konsole mit BOM und prueft:
#   (A) Bytes, Exit-Code, Ausgabe, Argumente des Helfers; Gegenprobe, dass die Pipe die Bytes veraendert (sonst prueft der Test nichts),
#   (B) bootstrap_test_n8n.ps1 -Down (Wegwerf-Repo, erfundener Token, docker.cmd als Attrappe) gibt dem Container genau den Token,
#   (C) gpg mit Wegwerf-GNUPGHOME: Schluessel mit und ohne Passwort erzeugen und unterschreiben (die Aufrufe von new_release_key.ps1
#       und sign_release.ps1),
#   (D) `git credential fill` liest die Eingabe (ein BOM vorn macht daraus "missing protocol field").
# Nur Windows (docker.cmd, Konsolen-Kodierung). Kein Docker, kein Netz; gpg und git aus Git for Windows.
# Usage: .\scripts\dev\secret_stdin_test.ps1   Exit-Code = Anzahl fehlgeschlagener Pruefungen.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot '..\lib\native_process.ps1')
. (Join-Path $PSScriptRoot '..\lib\git_sandbox.ps1')
Clear-GitEnvironment   # sonst liest das Wegwerf-Repo in (B) die .env des echten Repos
$fails = 0
function Check([bool]$Ok, [string]$Name) {
    if ($Ok) { Write-Host "  PASS $Name" -ForegroundColor Green } else { Write-Host "  FAIL $Name" -ForegroundColor Red; $script:fails++ }
}
$u8 = New-Object System.Text.UTF8Encoding($false)
function ConvertTo-Hex([byte[]]$Bytes) { if (-not $Bytes) { return '' }; return [System.BitConverter]::ToString($Bytes) }
function Read-Hex([string]$Path) { if (-not (Test-Path -LiteralPath $Path)) { return '<keine Datei>' }; return ConvertTo-Hex ([System.IO.File]::ReadAllBytes($Path)) }

# Kurzer Ordnername: lange Pfade sprengen den Socket des gpg-agent in (C).
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ('ss_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$shell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$prevIn = [Console]::InputEncoding
$prevPath = $env:PATH
try {
    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($true)

    Write-Host '(A) Helfer' -ForegroundColor Cyan
    $echoFile = Join-Path $dir 'echo.bin'
    $env:SS_TEST_ECHO_FILE = $echoFile
    $child = Join-Path $dir 'child.ps1'
    [System.IO.File]::WriteAllText($child, '$o = [System.IO.File]::Create($env:SS_TEST_ECHO_FILE); [Console]::OpenStandardInput().CopyTo($o); $o.Dispose()')
    $childArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $child)

    'Erfunden-42' | & $shell @childArgs
    Check ((Read-Hex $echoFile) -ne (ConvertTo-Hex $u8.GetBytes('Erfunden-42'))) "Gegenprobe: eine Pipe veraendert die Bytes (angekommen $(Read-Hex $echoFile))"

    $umlaut = 'Erfunden ' + [char]0x00E4 + [char]0x20AC + ' 42'
    foreach ($case in @(@('Wert', 'Erfunden-42'), @('Umlaut und Leerzeichen', $umlaut), @('leer = 0 Bytes', ''))) {
        Remove-Item -LiteralPath $echoFile -ErrorAction SilentlyContinue
        $code = Invoke-NativeStdinBytes -FilePath $shell -ArgumentList $childArgs -InputText $case[1]
        Check ($code -eq 0 -and (Read-Hex $echoFile) -ceq (ConvertTo-Hex $u8.GetBytes([string]$case[1]))) "stdin = genau die Bytes: $($case[0]) (angekommen $(Read-Hex $echoFile))"
    }
    Check ([Console]::InputEncoding.GetPreamble().Length -eq 3) 'Konsolen-Kodierung ist nach dem Aufruf wieder wie vorher'

    $argsFile = Join-Path $dir 'args.txt'
    $argChild = Join-Path $dir 'args.ps1'
    [System.IO.File]::WriteAllText($argChild, "[System.IO.File]::WriteAllText('$argsFile', (`$args -join '|')); [Console]::Out.WriteLine('raus'); [Console]::Error.WriteLine('fehler'); exit 7")
    $want = @('zwei Woerter', 'Name <a@example.com>', 'mit "Zitat"', 'C:\Ein Ordner\', '')
    $r = Invoke-NativeStdinBytes -FilePath $shell -ArgumentList (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $argChild) + $want) -InputText 'x' -CaptureOutput
    Check ($r.Code -eq 7) "Exit-Code kommt an (ist $($r.Code))"
    Check (($r.Output -contains 'raus') -and ($r.Output -contains 'fehler')) "-CaptureOutput sammelt stdout und stderr ($($r.Output -join ' / '))"
    $got = [System.IO.File]::ReadAllText($argsFile)
    Check ($got -ceq ($want -join '|')) "Argumente kommen unveraendert an ($got)"

    $cwdChild = Join-Path $dir 'cwd.ps1'
    [System.IO.File]::WriteAllText($cwdChild, '[Console]::Out.Write((Get-Location).ProviderPath); [Console]::Error.Write(''warnung'')')
    Push-Location $dir
    try { $r = Invoke-NativeStdinBytes -FilePath $shell -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $cwdChild) -CaptureOutput } finally { Pop-Location }
    Check ((Split-Path $r.Output[0] -Leaf) -eq (Split-Path $dir -Leaf)) "das Programm laeuft im Ordner der Sitzung (ist $($r.Output[0]))"
    Check ($r.Output.Count -eq 2 -and $r.Output[1] -eq 'warnung') "stdout ohne Zeilenende klebt nicht an stderr ($($r.Output -join ' / '))"

    Write-Host '(B) bootstrap_test_n8n.ps1 -Down mit erfundenem Token' -ForegroundColor Cyan
    $repo = Join-Path $dir 'repo'
    New-Item -ItemType Directory -Path (Join-Path $repo 'scripts\dev') -Force | Out-Null
    Copy-Item (Join-Path $RepoRoot 'scripts\lib') (Join-Path $repo 'scripts\lib') -Recurse
    foreach ($f in 'bootstrap_test_n8n.ps1', 'test_n8n_state.ps1') { Copy-Item (Join-Path $RepoRoot "scripts\dev\$f") (Join-Path $repo "scripts\dev\$f") }
    Initialize-GitSandbox $repo
    $token = '123456:Erfunden-Test-Token'
    [System.IO.File]::WriteAllText((Join-Path $repo '.env'), "TEST_TELEGRAM_BOT_TOKEN=$token`n", $u8)
    $bin = Join-Path $dir 'bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $tokenFile = Join-Path $dir 'token.bin'
    $env:SS_TEST_TOKEN_FILE = $tokenFile
    [System.IO.File]::WriteAllText((Join-Path $bin 'docker.cmd'), "@`"$shell`" -NoProfile -ExecutionPolicy Bypass -File `"%~dp0docker_stub.ps1`" %*`r`n", $u8)
    [System.IO.File]::WriteAllText((Join-Path $bin 'docker_stub.ps1'), @'
if ($args[0] -eq 'ps') { 'abc123' }
if ($args[0] -eq 'exec' -and $args[1] -eq '-i') { $o = [System.IO.File]::Create($env:SS_TEST_TOKEN_FILE); [Console]::OpenStandardInput().CopyTo($o); $o.Dispose() }
exit 0
'@, $u8)
    $env:PATH = "$bin;$env:PATH"
    $prevContainer = $env:N8NTEST_CONTAINER
    $env:N8NTEST_CONTAINER = 'ss-attrappe'
    try { $out = (& $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\dev\bootstrap_test_n8n.ps1') -Down *>&1 | Out-String) }
    finally { $env:N8NTEST_CONTAINER = $prevContainer; $env:PATH = $prevPath }
    Check ((Read-Hex $tokenFile) -ceq (ConvertTo-Hex $u8.GetBytes($token))) "der Container bekommt genau den Token (angekommen $(Read-Hex $tokenFile))"
    Check ($out -match 'freigegeben' -and $out -match 'ss-attrappe entfernt') "-Down meldet Freigabe und Abbau ($($out.Trim()))"

    Write-Host '(C) gpg mit Wegwerf-Schluesseln' -ForegroundColor Cyan
    # Vom git.exe aufwaerts (cmd\, bin\ oder mingw64\bin\): auch eine Git-Installation ausserhalb von Program Files.
    $up = Split-Path @(Get-Command git -CommandType Application)[0].Source
    while ($up -and -not (Test-Path (Join-Path $up 'usr\bin\gpg.exe'))) { $up = Split-Path $up }
    if (-not $up) { throw 'gpg aus Git for Windows (usr\bin\gpg.exe) nicht gefunden.' }
    $gpg = Join-Path $up 'usr\bin\gpg.exe'
    # Das gpg aus Git for Windows nimmt fuer --homedir nur die Form /c/... (Grund: ConvertTo-GpgPath in sign_release.ps1).
    function ConvertTo-MsysPath([string]$Path) { return '/' + $Path.Substring(0, 1).ToLowerInvariant() + ($Path.Substring(2) -replace '\\', '/') }
    $gpgconf = Join-Path (Split-Path $gpg) 'gpgconf.exe'
    $gpgHome = Join-Path $dir 'g'
    New-Item -ItemType Directory -Path $gpgHome -Force | Out-Null
    $homeArg = @('--homedir', (ConvertTo-MsysPath $gpgHome))
    function Stop-Agent { $p = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; & $gpgconf @homeArg --kill gpg-agent *> $null; $ErrorActionPreference = $p }
    $probe = Join-Path $dir 'probe.txt'
    [System.IO.File]::WriteAllText($probe, "Probe`n", $u8)
    function Invoke-Sign([string]$Uid, [string]$Passphrase) {
        Stop-Agent   # der Agent merkt sich ein Passwort: ohne Neustart gelaenge danach auch ein falsches
        $sig = Join-Path $dir 'probe.sig'
        Remove-Item -LiteralPath $sig -ErrorAction SilentlyContinue
        $r = Invoke-GpgPassphrase -Gpg $gpg -Passphrase $Passphrase -Arguments ($homeArg + @('--yes', '--local-user', $Uid, '--detach-sign', '--output', $sig, $probe)) -CaptureOutput
        if ($r.Code -ne 0 -or -not (Test-Path $sig)) { return $false }
        $v = Invoke-NativeStdinBytes -FilePath $gpg -ArgumentList ($homeArg + @('--batch', '--verify', $sig, $probe)) -InputText '' -CaptureOutput
        return $v.Code -eq 0
    }
    try {
        $pass = 'Erfunden-Pass-123'
        foreach ($k in @(@('mit-passwort@example.com', $pass), @('ohne-passwort@example.com', ''))) {
            $r = Invoke-GpgPassphrase -Gpg $gpg -Passphrase $k[1] -Arguments ($homeArg + @('--quick-generate-key', $k[0], 'ed25519', 'sign', 'never')) -CaptureOutput
            Check ($r.Code -eq 0) "Schluessel $($k[0]) erzeugt ($($r.Output -join ' | '))"
        }
        Check (Invoke-Sign 'mit-passwort@example.com' $pass) 'mit genau dem getippten Passwort unterschrieben und geprueft'
        Check (-not (Invoke-Sign 'mit-passwort@example.com' "$pass`r")) 'Gegenprobe: Passwort mit CR dahinter wird abgelehnt (der Schluessel traegt kein Zeilenende)'
        Check (Invoke-Sign 'ohne-passwort@example.com' '') 'ohne Passwort unterschrieben (0 Bytes, Weg von -NoPassphrase)'
    } finally { Stop-Agent }

    Write-Host '(D) git credential fill' -ForegroundColor Cyan
    $env:GIT_TERMINAL_PROMPT = '0'
    $r = Invoke-NativeStdinBytes -FilePath git -ArgumentList @('-c', 'credential.helper=', '-c', 'core.askPass=', 'credential', 'fill') -InputText "protocol=https`nhost=example.invalid`n`n" -CaptureOutput
    $text = $r.Output -join ' | '
    Check ($text -notmatch 'missing protocol field' -and $text -match 'terminal prompts disabled') "git liest protocol/host und will erst dann nach Zugangsdaten fragen ($text)"
} finally {
    $env:PATH = $prevPath
    $env:SS_TEST_ECHO_FILE = $null; $env:SS_TEST_TOKEN_FILE = $null; $env:GIT_TERMINAL_PROMPT = $null
    [Console]::InputEncoding = $prevIn
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}

if ($fails -eq 0) { Write-Host 'PASS secret_stdin_test' -ForegroundColor Green } else { Write-Host "FAIL secret_stdin_test ($fails)" -ForegroundColor Red }
exit $fails
