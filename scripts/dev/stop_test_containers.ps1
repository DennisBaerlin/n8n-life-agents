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
#
# Docker-Verbund (compose-Unterbau): zusaetzlich raeumt der Lauf Container, Netze, Volumes und Schnappschuesse dieses Worktrees ab
# (Etikett lifeagents.worktree, Auswahl in scripts/lib/substrate_reservations.ps1 -- dieselbe Funktion wie der SessionEnd-Hook).
# Im Haupt-Checkout teilen sich mehrere Sessions das Etikett: dort wird der Verbund nicht gewaehlt, sondern der eigene mit
# bootstrap_test_stack.ps1 -Down abgebaut.
#   -ComposeOnly  nur den Verbund-Zweig (die beiden klassischen -Down-Pfade laufen nicht)
#   -Worktree     Checkout-Pfad statt des eigenen (Test); -StateDir Ordner der State-Dateien statt Haupt-Checkout/.local
param([switch]$Verbose, [switch]$ComposeOnly, [string]$Worktree, [string]$StateDir)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'       # Geschwister-Muster (global Stop); die Toleranz je Ziel liefert das try/catch unten
. (Join-Path $PSScriptRoot '..\lib\substrate_reservations.ps1')

Write-Host "Test-Substrate herunterfahren (RAM freigeben) ..." -ForegroundColor Cyan

$targets = @(
    @{ Name = 'db_test-Substrat (lifeagents-dbtest)'; Path = (Join-Path $PSScriptRoot '..\bootstrap_test_db.ps1') },
    @{ Name = 'n8n-Integrations-Substrat';            Path = (Join-Path $PSScriptRoot 'bootstrap_test_n8n.ps1') }
)
if ($ComposeOnly) { $targets = @() }

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

try {
    $explicit = [bool]$Worktree
    if (-not $Worktree) { $Worktree = "$(git -C $PSScriptRoot rev-parse --show-toplevel)".Trim() }
    $isMain = "$(git -C $PSScriptRoot rev-parse --absolute-git-dir)".Trim() -eq "$(git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir)".Trim()
    if ($isMain -and -not $explicit) {
        Write-Host "  [SKIP] Docker-Verbund: Haupt-Checkout (Etikett wird von mehreren Sessions geteilt) -> bootstrap_test_stack.ps1 -Down mit eigenem Namen" -ForegroundColor DarkYellow
    } else {
        Write-Host "  -> Docker-Verbund dieses Worktrees abbauen ($Worktree) ..." -ForegroundColor Gray
        $removeArgs = @{ Worktree = $Worktree }
        if ($StateDir) { $removeArgs.StateDir = $StateDir }
        $gone = Remove-WorktreeComposeSubstrates @removeArgs
        $n = @($gone.Projects).Count
        Write-Host "  [OK] Docker-Verbund: $n Projekt(e), $(@($gone.Containers).Count) Container, $(@($gone.Volumes).Count) Volume(s) entfernt." -ForegroundColor Green
    }
} catch {
    Write-Host "  [WARN] Docker-Verbund: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

Write-Host "Fertig. Der naechste Testlauf baut das jeweilige Substrat frisch (Staleness-Gate)." -ForegroundColor Cyan
exit 0
