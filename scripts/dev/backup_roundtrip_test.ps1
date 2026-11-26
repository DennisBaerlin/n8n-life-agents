#Requires -Version 5.1
# backup_roundtrip_test.ps1 -- "alles wie vorher": Sicherung eines Docker-Verbunds mit erfundenen Daten in jedem Teil (Fachdaten,
# Einstellungen, Gespraech, KI-Kosten, Hinweis-Merker, Sperrliste, Paket-Zugang), dann derselbe Verbund frisch (Schnappschuss
# „frisch installiert“, bootstrap_test_stack.ps1 -Reset), Sicherung einspielen und den Fingerabdruck (lifeagents backup fingerprint)
# vorher/nachher vergleichen. Schritte im master: tests/backup/roundtrip_cases.sh.
# Gegenlauf (-AgainstRef <git-ref>, z. B. der Stand vor dem Bau): dieselbe Sicherung spielt die CLI jenes Stands auf einem frischen
# Verbund ein; der Vergleich muss dann rot sein (sonst prueft der Test nichts).
# Voraussetzung: ein Test-Verbund aus diesem Arbeitsstand (bootstrap_test_stack.ps1; $env:N8NTEST_CONTAINER, N8NTEST_PORT,
# N8NTEST_STACK_PORTS wie dort). Laeuft zweimal (-AgainstRef: dreimal) -Reset; danach ist der Verbund frisch.
# Usage:
#   $env:N8NTEST_CONTAINER='s4bfrt'; $env:N8NTEST_PORT='58140'; $env:N8NTEST_STACK_PORTS='58150-58159'
#   .\scripts\dev\backup_roundtrip_test.ps1 [-AgainstRef 48f823d9] [-Verbose]
# Exit-Code = Anzahl Fehler.
param([string]$AgainstRef, [switch]$Verbose)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = ([string](git -C $PSScriptRoot rev-parse --show-toplevel)).Trim()
. "$PSScriptRoot\..\lib\test_common.ps1"
. "$PSScriptRoot\..\lib\test_stack.ps1"
if (-not $env:N8NTEST_CONTAINER) { throw 'N8NTEST_CONTAINER setzen (eigener Test-Verbund, bootstrap_test_stack.ps1).' }
$Master = (Get-TestStackNames $env:N8NTEST_CONTAINER).Master
$Local = Join-Path ([System.IO.Path]::GetTempPath()) ("rt_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Local | Out-Null
$failed = 0
function Fail([string]$m) { Write-Host "    [FAIL] $m" -ForegroundColor Red; $script:failed++ }
function Step([string[]]$CaseArgs, [hashtable]$Env = @{}) {
    $envArgs = @(); foreach ($k in $Env.Keys) { $envArgs += @('-e', "$k=$($Env[$k])") }
    $r = Invoke-Native docker (@('exec') + $envArgs + @($Master, 'bash', '/opt/rt/roundtrip_cases.sh') + $CaseArgs)
    foreach ($l in @($r.Output)) {
        if ("$l" -match '^FAIL ') { Fail "$("$l".Substring(5))" }
        elseif ($Verbose -or "$l" -match '^SKIP ') { Write-Host "    $l" -ForegroundColor DarkGray }
    }
    return $r
}
# Die geseedeten Wechselkurse samt Waehrungen stehen mit genauem Wert in der Datenbank (Fall fx: Soll 3/2), und der Kurs-Abruf des
# Crons ist nicht faellig (Fall fxdue: false/false). Der Fingerabdruck zaehlt bei den Kursen nur Zeilen, weil das Ziel eigene schreiben
# darf; faellig hiesse: der n8n-Start-Eingang des Crons holt 30 s nach dem Start echte Kurse, und je nachdem, ob vor oder nach dem
# Einspielen, unterscheiden sich Quelle und Ziel.
function Assert-Kurse([string]$Name, $Fx, $Due) {
    $v = @($Fx.Output) | Where-Object { "$_" -match '^\d+/\d+$' } | Select-Object -Last 1
    if ("$v" -ne '3/2') { Fail "${Name}: Wechselkurse/Waehrungen der Sicherung: '$v' statt 3/2" }
    $d = @($Due.Output) | Where-Object { "$_" -match '^(true|false)/(true|false)$' } | Select-Object -Last 1
    if ("$d" -ne 'false/false') { Fail "${Name}: Kurs-Abruf faellig (Feed/EZB): '$d' statt false/false -- der Cron holte echte Kurse in den Vergleich" }
}
function Fresh {
    # Der laufende PowerShell-Host, nicht powershell.exe: das gibt es unter Linux nicht (dort pwsh).
    $r = Invoke-Native (Get-Process -Id $PID).Path @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'bootstrap_test_stack.ps1'), '-Reset')
    if ($r.Code -ne 0) { throw "bootstrap_test_stack.ps1 -Reset scheiterte: $(@($r.Output)[-5..-1] -join ' | ')" }
    $r = Invoke-Native docker @('exec', $Master, 'sh', '-c', 'rm -rf /opt/rt /tmp/rt && mkdir -p /opt/rt /tmp/rt && chmod 0700 /tmp/rt')
    $r = Invoke-Native docker @('cp', (Join-Path $RepoRoot 'tests\backup\roundtrip_cases.sh'), "${Master}:/opt/rt/roundtrip_cases.sh")
    if ($r.Code -ne 0) { throw "docker cp roundtrip_cases.sh: $($r.Output -join ' | ')" }
}
function Compare-Fp([string]$Name, [bool]$ExpectEqual) {
    $a = @(Get-Content -LiteralPath (Join-Path $Local 'a.fp') -Encoding UTF8)
    $b = @(Get-Content -LiteralPath (Join-Path $Local "$Name.fp") -Encoding UTF8)
    $diff = @(Compare-Object $a $b)
    if ($ExpectEqual -and $diff.Count -gt 0) { Fail "${Name}: Fingerabdruck weicht ab: $(($diff | Select-Object -First 8 | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join ' | ')" }
    elseif (-not $ExpectEqual -and $diff.Count -eq 0) { Fail "${Name}: Gegenlauf gleich (der Vergleich prueft nichts)" }
    else { Write-Host "  ${Name}: $(if ($ExpectEqual) { 'gleich' } else { "$($diff.Count) Abweichung(en), wie erwartet" })" }
}

Write-Host ""
Write-Host "Roundtrip der Sicherung (Docker-Verbund $($env:N8NTEST_CONTAINER))"
Write-Host ("-" * 64)
try {
    Fresh
    Suspend-TestStackTick -Master $Master
    [void](Step @('seed'))
    [void](Step @('fp', '/tmp/rt/a.fp'))
    Assert-Kurse 'a' (Step @('fx')) (Step @('fxdue'))
    [void](Step @('export'))
    Resume-TestStackTick -Master $Master
    foreach ($f in 'rt.nla.enc', 'rt.key', 'a.fp') {
        $r = Invoke-Native docker @('cp', "${Master}:/tmp/rt/$f", (Join-Path $Local $f))
        if ($r.Code -ne 0) { throw "docker cp $f aus dem master: $($r.Output -join ' | ')" }
    }

    # Frischer Verbund, Sicherung dieses Stands einspielen: Fingerabdruck gleich, KI-Kosten und Merker der Quelle enthalten.
    Fresh
    foreach ($f in 'rt.nla.enc', 'rt.key') { [void](Invoke-Native docker @('cp', (Join-Path $Local $f), "${Master}:/tmp/rt/$f")) }
    Suspend-TestStackTick -Master $Master
    [void](Step @('restore'))
    [void](Step @('fp', '/tmp/rt/b.fp'))
    $c = Step @('subset')
    $fx = Step @('fx'); $due = Step @('fxdue')
    Resume-TestStackTick -Master $Master
    [void](Invoke-Native docker @('cp', "${Master}:/tmp/rt/b.fp", (Join-Path $Local 'b.fp')))
    Compare-Fp 'b' $true
    Assert-Kurse 'b' $fx $due
    if ((@($c.Output) | Where-Object { "$_" -match '^\d+$' } | Select-Object -Last 1) -ne '2') { Fail "b: KI-Kosten oder Merker der Quelle fehlen nach dem Einspielen" }

    if ($AgainstRef) {
        # Gegenlauf: dieselbe Sicherung mit der CLI des Stands $AgainstRef einspielen (Baum wie backup_test.ps1 nach /opt/rt_old).
        Fresh
        $old = Join-Path $Local 'old'; New-Item -ItemType Directory -Path $old | Out-Null
        $tar = Join-Path $Local 'old.tar'
        & git -C $RepoRoot archive --format=tar -o $tar $AgainstRef provisioning packages
        if ($LASTEXITCODE -ne 0) { throw "git archive $AgainstRef scheiterte" }
        [void](Invoke-Native docker @('cp', $tar, "${Master}:/tmp/rt/old.tar"))
        # sed-Ausdruck ohne doppelte Anfuehrungszeichen: PowerShell 5.1 zerlegt sie beim Aufruf von docker (sed: unterminated s).
        $r = Invoke-Native docker @('exec', $Master, 'sh', '-c', 'rm -rf /opt/rt_old && mkdir -p /opt/rt_old && tar -xf /tmp/rt/old.tar -C /opt/rt_old && sed s,@@LIBDIR@@,/opt/rt_old, /opt/rt_old/provisioning/templates/lifeagents.tpl > /opt/rt_old/lifeagents && chmod 0700 /opt/rt_old/lifeagents')
        if ($r.Code -ne 0) { throw "alter Baum im master: $($r.Output -join ' | ')" }
        foreach ($f in 'rt.nla.enc', 'rt.key') { [void](Invoke-Native docker @('cp', (Join-Path $Local $f), "${Master}:/tmp/rt/$f")) }
        Suspend-TestStackTick -Master $Master
        # Ergebnis des alten Restores zaehlt nicht (er darf scheitern, etwa an einer neuen Tabelle), nur der Vergleich danach.
        $r = Invoke-Native docker @('exec', '-e', 'LIFEAGENTS_CLI=/opt/rt_old/lifeagents', $Master, 'bash', '/opt/rt/roundtrip_cases.sh', 'restore')
        if ($Verbose) { @($r.Output) | ForEach-Object { Write-Host "    alt: $_" -ForegroundColor DarkGray } }
        [void](Step @('fp', '/tmp/rt/old.fp'))
        Resume-TestStackTick -Master $Master
        [void](Invoke-Native docker @('cp', "${Master}:/tmp/rt/old.fp", (Join-Path $Local 'old.fp')))
        Compare-Fp 'old' $false
        Fresh
    }
} finally {
    try { Resume-TestStackTick -Master $Master } catch { }
    Remove-Item -Recurse -Force $Local -ErrorAction SilentlyContinue
}
if ($failed -eq 0) { Write-Host "backup_roundtrip_test: OK" -ForegroundColor Green } else { Write-Host "backup_roundtrip_test: $failed Fehler" -ForegroundColor Red }
exit $failed
