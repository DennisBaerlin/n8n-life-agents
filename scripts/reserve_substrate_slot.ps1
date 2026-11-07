#Requires -Version 5.1
# Reserviert einen n8n-Test-Substrat-Platz fuer einen Container, den eine wartende Session noch starten wird (Leitung).
# Bis zum Start (oder 60 Min Frist, Begruendung in scripts/lib/substrate_reservations.ps1) zaehlt die Reservierung in
# Wait-SubstrateSlot (scripts/dev/bootstrap_test_n8n.ps1) wie ein laufendes Substrat -- fuer jeden ANDEREN Container. Startet der
# reservierte Container, loest der Bootstrap die Reservierung selbst ein. Liste: gitignored im Haupt-Checkout
# (.claude/substrate_reservations.txt).
#
# Der Name ist der Container, den die Session setzt ($env:N8NTEST_CONTAINER); ein -Parallel-Lauf von run_free_gates.ps1 braucht
# zusaetzlich <Name>-b (zweiter Platz, bei Limit 2 sperrt er alles andere). Die Leitung sagt zu, die wartende Session darf mit
# demselben Kommando selbst reservieren (-By = ihr Name) -- aber erst nach der Zusage. -List zeigt neben den Reservierungen die
# laufenden Substrate (nur `docker ps`, lesend). Sonst wird Docker nicht angefasst.
#
# Usage:  .\scripts\reserve_substrate_slot.ps1 -Container n8ntest-xx [-By "Sprint-Leitung"]   # reservieren (erneut = Frist neu)
#         .\scripts\reserve_substrate_slot.ps1 -Release n8ntest-xx                              # Zusage zurueckziehen
#         .\scripts\reserve_substrate_slot.ps1 -DbPort 55433 -By lifeagents-dbtest-xx          # DB-Test-Port reservieren (Eintrag dbport-55433)
#         .\scripts\reserve_substrate_slot.ps1 -FreeDbPort -By lifeagents-dbtest-xx             # naechsten freien DB-Port nennen und reservieren
#         .\scripts\reserve_substrate_slot.ps1 -List                                            # gueltige Reservierungen
# DB-Ports (DBTEST_PG_PORT) laufen ueber dieselbe Liste; bootstrap_test_db.ps1 prueft und traegt den Port beim Start selbst ein.
param(
    [string]$Container,
    [string]$Release,
    [int]$DbPort,
    [switch]$FreeDbPort,
    [switch]$List,
    [string]$By,
    [string]$ListFile
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\substrate_reservations.ps1"
if (-not $ListFile) { $ListFile = Get-SlotReservationFile }
$namePattern = '^[A-Za-z0-9][A-Za-z0-9_.-]*$'

if ($FreeDbPort -or $DbPort) {
    if (-not $By) { $By = if ($env:DBTEST_CONTAINER) { $env:DBTEST_CONTAINER } else { $env:USERNAME } }
    $res = @(Read-SlotReservations -File $ListFile)
    $used = @(Get-DockerHostPorts)
    if ($FreeDbPort) {
        $DbPort = Find-FreeDbPort -Reservations $res -InUse $used -Own $By
        if (-not $DbPort) { throw 'Kein freier DB-Port in 55432..55471.' }
    } elseif (-not (Test-DbPortFree -Port $DbPort -Reservations $res -InUse $used -Own $By)) {
        throw "DB-Port $DbPort ist belegt oder von einer anderen Session reserviert (-FreeDbPort nennt einen freien)."
    }
    Add-SlotReservation -File $ListFile -Container (Get-DbPortEntryName $DbPort) -By $By
    Write-Host ("DB-Port {0} reserviert (von {1}): `$env:DBTEST_PG_PORT='{0}'; verfaellt nach {2} Min." -f $DbPort, $By, $SlotReservationTtlMin) -ForegroundColor Green
    exit 0
}
if ($Container) {
    if ($Container -notmatch $namePattern) { throw "Unerwarteter Container-Name '$Container' (erlaubt: Buchstaben, Ziffern, _ . -)." }
    if (-not $By) { $By = if ($env:CLAUDE_CODE_HOST_SESSION_ID) { $env:CLAUDE_CODE_HOST_SESSION_ID } else { $env:USERNAME } }
    Add-SlotReservation -File $ListFile -Container $Container -By $By
    Write-Host ("Platz fuer {0} reserviert (von {1}); verfaellt nach {2} Min, wenn der Container nicht startet." -f $Container, $By, $SlotReservationTtlMin) -ForegroundColor Green
    exit 0
}
if ($Release) {
    if ($Release -notmatch $namePattern) { throw "Unerwarteter Container-Name '$Release'." }
    if (Remove-SlotReservation -File $ListFile -Container $Release) { Write-Host "Reservierung fuer $Release freigegeben." -ForegroundColor Green }
    else { Write-Host "Keine gueltige Reservierung fuer $Release." }
    exit 0
}
if ($List) {
    $all = @(Read-SlotReservations -File $ListFile)
    Write-Host 'Reservierungen:'
    if (-not $all.Count) { Write-Host '  keine' }
    foreach ($r in $all) {
        Write-Host ('  {0}  von {1}  seit {2:HH:mm} UTC, laeuft ab {3:HH:mm} UTC' -f $r.Container, $r.By, $r.Since, $r.Since.AddMinutes($SlotReservationTtlMin))
    }
    Write-Host 'Laufende Substrate:'
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Write-Host '  Docker nicht verfuegbar'; exit 0 }
    $running = @(Get-RunningSubstrates)
    if (-not $running.Count) { Write-Host '  keine' }
    foreach ($s in $running) { Write-Host ('  {0}  {1}  {2}' -f $s.Name, $s.Status, $s.Worktree) }
    exit 0
}
throw 'Aufruf: -Container <name> | -Release <name> | -List  (Beschreibung im Skript-Kopf).'
