#Requires -Version 5.1
# gate: manual (laeuft nur gegen einen eigenen Docker-Verbund mit zweimaligem Reset, nicht im freien Gate; nach Aenderungen am Sicherungsformat von Hand)
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
function Fresh {
    $r = Invoke-Native powershell.exe @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'bootstrap_test_stack.ps1'), '-Reset')
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
    Resume-TestStackTick -Master $Master
    [void](Invoke-Native docker @('cp', "${Master}:/tmp/rt/b.fp", (Join-Path $Local 'b.fp')))
    Compare-Fp 'b' $true
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
