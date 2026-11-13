#Requires -Version 5.1
# stop_test_containers.ps1 -- faehrt beide ephemeren Docker-Test-Substrate herunter, um RAM
# freizugeben, wenn die Test-Arbeit der Session erledigt ist. Ruft die -Down-Pfade der
# beiden Bootstraps (jeder raeumt seinen Container + Teardown idempotent):
#   * scripts/bootstrap_test_db.ps1 -Down       (db_test-Substrat: lifeagents-dbtest-Container)
#   * scripts/dev/bootstrap_test_n8n.ps1 -Down  (Integrations-Tier-Substrat: n8n-systemd-Container + Bruecken)
#
# Kein Auto-Stop nach jedem Testlauf: die Substrate werden absichtlich wiederverwendet
# (Staleness-Gate -> schnelle Re-Runs). Dieser Helfer ist der Aufraeumer fuers Session-Ende,
# nicht Teil des Inner-Loops. Der naechste Testlauf baut das jeweilige Substrat wieder frisch auf.
#
# Tolerant: laeuft ein Teardown ins Leere (kein Container / Docker-Daemon aus), fahrt der andere trotzdem.
# Kein LLM, kein Netz-Ziel ausser dem lokalen Docker-Daemon. Exit 0 (reines Aufraeum-Werkzeug).
param([switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'       # Geschwister-Muster (global Stop); die Toleranz je Ziel liefert das try/catch unten

Write-Host "Test-Substrate herunterfahren (RAM freigeben) ..." -ForegroundColor Cyan

$targets = @(
    @{ Name = 'db_test-Substrat (lifeagents-dbtest)'; Path = (Join-Path $PSScriptRoot '..\bootstrap_test_db.ps1') },
    @{ Name = 'n8n-Integrations-Substrat';            Path = (Join-Path $PSScriptRoot 'bootstrap_test_n8n.ps1') }
)

foreach ($t in $targets) {
    if (-not (Test-Path $t.Path)) {
        Write-Host "  [SKIP] $($t.Name): Skript nicht gefunden ($($t.Path))" -ForegroundColor DarkYellow
        continue
    }
    if ($Verbose) { Write-Host "  -> $($t.Path) -Down" -ForegroundColor DarkGray }
    Write-Host "  -> $($t.Name) -Down ..." -ForegroundColor Gray
    try {
        & $t.Path -Down
        Write-Host "  [OK] $($t.Name) heruntergefahren." -ForegroundColor Green
    } catch {
        Write-Host "  [WARN] $($t.Name): $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

Write-Host "Fertig. Der naechste Testlauf baut das jeweilige Substrat frisch (Staleness-Gate)." -ForegroundColor Cyan
exit 0
