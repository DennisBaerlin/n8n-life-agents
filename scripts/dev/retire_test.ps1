#Requires -Version 5.1
# retire_test.ps1 — GRATIS Test von `lifeagents retire` (Umzug: stilllegen, exportieren, zurueck) auf dem echten Weg im
# klassischen Substrat: echtes systemd, n8n, PostgreSQL; Telegram ist die Attrappe des Substrats (enable_mock_telegram.ps1), an der
# auch n8n haengt: so sieht der Test, dass n8n den Bot nach dem Rueckweg selbst wieder anmeldet.
# Kopiert provisioning/ + packages/ dieses Checkouts und den Fall-Runner (tests/backup/retire_cases.sh) in den Container und faehrt dort
# retire_cases.sh mit der CLI dieses Baums:
#   - Lauf: Bot geloest, n8n, Gateway und Timer aus und deaktiviert, PostgreSQL an, Umzugs-Ordner vollstaendig und pruefbar;
#   - Sperre: update/config set enden mit Satz, systemctl start n8n bleibt wirkungslos, doctor zeigt den Ruhezustand gruen;
#   - Rueckweg: fremder Webhook -> nichts; --undo --restore -> Daten, Gedaechtnis, Wasserstand zurueck, alles wieder an, Bot wieder hier.
# Haelt n8n im Substrat voruebergehend an -> nur im EIGENEN Container laufen lassen ($env:N8NTEST_CONTAINER/N8NTEST_PORT);
# am Ende laeuft alles wieder wie vorher. Voraussetzung: enable_mock_telegram.ps1 (aktuelle Attrappe). Kein LLM, kein echtes Telegram.
# N8NTEST_RUNTIME=compose: der Weg im Docker-Verbund (bootstrap_test_stack.ps1, Fall-Runner tests/backup/retire_stack_cases.sh im master):
#   retire -> `stack start --json` (der Aufruf der Start-App beim Anmelden: n8n bleibt aus, die uebrigen Container laufen; ob das Gateway
#   laeuft, ist nicht Gegenstand) -> retire --undo (n8n laeuft wieder). Die Tick-Schleife des master ruht waehrend des Laufs.
#   Braucht zusaetzlich $env:N8NTEST_STACK_PORTS; die Telegram-Attrappe startet der Runner selbst auf Port 8101.
# Usage:  $env:N8NTEST_CONTAINER='s4b1-n8ntest'; $env:N8NTEST_PORT='57900'; .\scripts\dev\retire_test.ps1 [-Verbose]
# Exit-Code = Anzahl Fehler.
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. "$PSScriptRoot\test_n8n_state.ps1"
. "$PSScriptRoot\..\lib\test_stack.ps1"
$suiteRuntime = Get-TestSuiteRuntime
$conn = Get-TestN8nConnection
$Container = $conn.Container
$state = Get-TestN8nState
Assert-TestSuiteStateRuntime -State $state
if ($suiteRuntime -eq 'classic') {
    if (-not $state.mock_telegram) { throw "Mock-Telegram nicht aktiv (kein mock_telegram-Block im State). Zuerst: .\scripts\dev\enable_mock_telegram.ps1" }
    $MockPort = "$($state.mock_telegram.port)"
    $MockLog = "$($state.mock_telegram.log)"
}

. "$PSScriptRoot\..\lib\test_common.ps1"

# --- Verbund (N8NTEST_RUNTIME=compose): retire -> `stack start` -> undo, Container von aussen geprueft -------------------------
if ($suiteRuntime -eq 'compose') {
    $Names = Get-TestStackNames $env:N8NTEST_CONTAINER
    $Ports = Get-TestStackPorts -Port $env:N8NTEST_PORT -CoreRange $env:N8NTEST_STACK_PORTS
    $LogDir = Get-TestStackLogDir $Names.Project
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    # `stack start` laeuft aus dem master-Abbild: der Arbeitsstand muss drin sein (gleicher Stand = Bau-Cache, ein Treffer in Sekunden).
    # Der laufende master bleibt auf seinem Abbild (gleicher Name, Container behaelt das alte); ein spaeteres -Reset installiert kalt.
    [void](New-TestStackImage -RepoRoot $RepoRoot -Names $Names -LogDir $LogDir)
    $TgPort = '8101'   # wie update_chat_test: Port+1 belegt der GitHub-Mock, 8088/8089/8092 die Attrappen des Pods
    $script:cFailed = 0; $script:cPassed = 0
    function Assert-Case([string]$Name, [bool]$Ok, [string]$Detail = '') {
        if ($Ok) { $script:cPassed++; if ($Verbose) { Write-Host "    [OK]   $Name" -ForegroundColor DarkGray } }
        else { $script:cFailed++; Write-Host "    [FAIL] $Name $Detail" -ForegroundColor Red }
    }
    function Get-ContainerState([string]$Name) {
        $r = Invoke-Native docker @('inspect', '-f', '{{.State.Status}}', $Name)
        if ($r.Code -ne 0) { return 'fehlt' }
        return (($r.Output -join '').Trim())
    }
    function Invoke-RunnerPhase([string]$Phase) {
        $r = Invoke-Native docker @('exec', $Container, 'bash', "$root/backup/retire_stack_cases.sh", $root, $Phase, $Names.Project, $TgPort)
        foreach ($l in @($r.Output)) {
            if ($l -match '^PASS ') { $script:cPassed++; if ($Verbose) { Write-Host "    [OK]   $($l.Substring(5))" -ForegroundColor DarkGray } }
            elseif ($l -match '^FAIL ') { $script:cFailed++; Write-Host "    [FAIL] $($l.Substring(5))" -ForegroundColor Red }
            elseif ($Verbose -or $l -match '^# ') { Write-Host "    $l" -ForegroundColor DarkGray }
        }
        if ($r.Code -ne 0 -and -not (@($r.Output) -match '^FAIL ')) { $script:cFailed++; Write-Host "    [FAIL] $Phase brach ab (exit $($r.Code)): $(@($r.Output) -join ' | ')" -ForegroundColor Red }
    }

    Write-Host ""
    Write-Host "Umzug im Docker-Verbund: lifeagents retire, stack start, retire --undo — Verbund $($Names.Project)"
    Write-Host ("-" * 64)
    $root = '/opt/retire_test'
    $r = Invoke-Native docker @('exec', $Container, 'sh', '-c', "rm -rf $root && mkdir -p $root && chmod 0700 $root")
    if ($r.Code -ne 0) { throw "Test-Verzeichnis im Container nicht anlegbar: $($r.Output -join ' | ')" }
    foreach ($pair in @(@('provisioning', 'provisioning'), @('packages', 'packages'), @('tests\backup', 'backup'), @('tests\mock_telegram', 'mock_telegram'))) {
        $r = Invoke-Native docker @('cp', (Join-Path $RepoRoot $pair[0]), "${Container}:$root/$($pair[1])")
        if ($r.Code -ne 0) { throw "docker cp $($pair[0]) fehlgeschlagen: $($r.Output -join ' | ')" }
    }
    $n8n = "$($Names.Project)-n8n"
    $others = @("$($Names.Project)-postgres", "$($Names.Project)-master")   # das Gateway gehoert nicht dazu: es haengt am Stand von sc_start, nicht an dieser Frage
    $retired = $false
    try {
        Suspend-TestStackTick -Master $Container
        Assert-Case 'V.vorher-n8n-laeuft' ((Get-ContainerState $n8n) -eq 'running') (Get-ContainerState $n8n)
        $retired = $true   # vor dem Lauf: bricht retire nach dem Anhalten von n8n ab, muss finally trotzdem zurueck
        Invoke-RunnerPhase 'retire'
        Assert-Case 'V.retire-n8n-angehalten' ((Get-ContainerState $n8n) -eq 'exited') (Get-ContainerState $n8n)
        # Die Start-App ruft beim Anmelden `stack start`: n8n bleibt aus, alles andere laeuft.
        $res = Invoke-TestStackCore -Names $Names -Ports $Ports -Verb start -LogDir $LogDir
        Assert-Case 'V.stack-start-ok' ($res.ok -eq $true) "reason=$($res.reason) $($res.detail)"
        Assert-Case 'V.stack-start-startet-n8n-nicht' (@($res.started) -notcontains 'n8n') "started=$(@($res.started) -join ',')"
        Assert-Case 'V.stack-start-n8n-bleibt-exited' ((Get-ContainerState $n8n) -eq 'exited') (Get-ContainerState $n8n)
        foreach ($c in $others) { Assert-Case "V.uebrige-laufen-$c" ((Get-ContainerState $c) -eq 'running') (Get-ContainerState $c) }
        Invoke-RunnerPhase 'undo'
        $retired = $false
        Assert-Case 'V.undo-n8n-laeuft' ((Get-ContainerState $n8n) -eq 'running') (Get-ContainerState $n8n)
    } finally {
        # Ein Abbruch mitten drin darf den Verbund nicht stillgelegt zuruecklassen.
        if ($retired) { Invoke-Native docker @('exec', $Container, 'bash', "$root/backup/retire_stack_cases.sh", $root, 'undo', $Names.Project, $TgPort) | Out-Null }
        Resume-TestStackTick -Master $Container
        Invoke-Native docker @('exec', $Container, 'rm', '-rf', $root) | Out-Null
    }
    Write-Host ("-" * 64)
    if ($script:cFailed -eq 0) { Write-Host "retire_test (Verbund): OK ($($script:cPassed) Faelle)" -ForegroundColor Green }
    else { Write-Host "retire_test (Verbund): $($script:cFailed) Fehler ($($script:cPassed) ok)" -ForegroundColor Red }
    exit $script:cFailed
}

Write-Host ""
Write-Host "Umzug: lifeagents retire (Stilllegen, Export, Rückweg) — Container $Container"
Write-Host ("-" * 64)

$root = '/opt/retire_test'
$r = Invoke-Native docker @('exec', $Container, 'sh', '-c', "rm -rf $root && mkdir -p $root && chmod 0700 $root")
if ($r.Code -ne 0) { throw "Test-Verzeichnis im Container nicht anlegbar: $($r.Output -join ' | ')" }
foreach ($pair in @(@('provisioning', 'provisioning'), @('packages', 'packages'), @('tests\backup', 'backup'))) {
    $r = Invoke-Native docker @('cp', (Join-Path $RepoRoot $pair[0]), "${Container}:$root/$($pair[1])")
    if ($r.Code -ne 0) { throw "docker cp $($pair[0]) fehlgeschlagen: $($r.Output -join ' | ')" }
}

$r = Invoke-Native docker @('exec', $Container, 'bash', "$root/backup/retire_cases.sh", $root, "$MockPort", "$MockLog")
$lines = @($r.Output)
foreach ($l in $lines) {
    if ($l -match '^PASS ') { if ($Verbose) { Write-Host "    [OK]   $($l.Substring(5))" -ForegroundColor DarkGray } }
    elseif ($l -match '^FAIL ') { Write-Host "    [FAIL] $($l.Substring(5))" -ForegroundColor Red }
    elseif ($Verbose) { Write-Host "    $l" -ForegroundColor DarkGray }
}
$passed = @($lines | Where-Object { $_ -match '^PASS ' }).Count
$failed = @($lines | Where-Object { $_ -match '^FAIL ' }).Count
# Abbruch des Runners ohne FAIL-Zeile (Setup, Syntax) zaehlt als Fehler.
if ($r.Code -ne 0 -and $failed -eq 0) { $failed = 1; Write-Host "    [FAIL] retire_cases.sh brach ab (exit $($r.Code)): $($lines -join ' | ')" -ForegroundColor Red }
if ($passed -eq 0 -and $failed -eq 0) { $failed = 1; Write-Host "    [FAIL] retire_cases.sh lieferte keine Faelle" -ForegroundColor Red }
Invoke-Native docker @('exec', $Container, 'rm', '-rf', $root) | Out-Null

Write-Host ("-" * 64)
if ($failed -eq 0) { Write-Host "retire_test: OK ($passed Faelle)" -ForegroundColor Green }
else { Write-Host "retire_test: $failed Fehler ($passed ok)" -ForegroundColor Red }
exit $failed
