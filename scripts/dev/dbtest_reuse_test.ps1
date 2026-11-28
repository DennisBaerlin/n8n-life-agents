#Requires -Version 5.1
# dbtest_reuse_test.ps1 -- die Test-DB wird nur wiederverwendet, wenn sie aus genau diesem Baum gebaut ist. Mehrere Worktrees koennen
# denselben Container nutzen (ein Pre-Push-Lauf eines anderen Zweigs): der Bau-Stand muss darum an der Datenbank haengen, nicht an
# einer Datei des Checkouts. Faelle gegen scripts/bootstrap_test_db.ps1 in einem eigenen Wegwerf-Container:
#   1) erster Lauf baut; 2) zweiter Lauf im selben Baum = Reuse; 3) traegt die DB den Bau-Stand eines fremden Baums, wird neu gebaut.
# Voraussetzung: Docker laeuft und das Image pgvector/pgvector:pg17 ist lokal vorhanden (sonst [SKIP], Exit 0; es wird nie geladen),
# psql im PATH bzw. unter C:\Program Files\PostgreSQL\17\bin (wie bootstrap_test_db.ps1). Dauer: zwei Schema-Bauten.
# Eigener Container ta-dbreuse-<pid> auf einem freien, reservierten DB-Port; am Ende entfernt.
# Usage:  .\scripts\dev\dbtest_reuse_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '..\lib\test_common.ps1')
. (Join-Path $PSScriptRoot '..\lib\substrate_reservations.ps1')
$bootstrap = Join-Path $PSScriptRoot '..\bootstrap_test_db.ps1'
$failed = 0
function Assert-That([bool]$Cond, [string]$Name, [string]$Detail = '') {
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green } else { Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red; $script:failed++ }
}

Write-Host 'dbtest_reuse_test'
$image = 'pgvector/pgvector:pg17'
if ((Invoke-Native docker @('info', '--format', '{{.ServerVersion}}')).Code -ne 0 -or (Invoke-Native docker @('image', 'inspect', $image)).Code -ne 0) {
    Write-Host "  [SKIP] Docker nicht erreichbar oder Image $image lokal nicht vorhanden." -ForegroundColor Yellow
    exit 0
}

$container = "ta-dbreuse-$PID"
$port = Add-DbPortReservation -By $container -InUse @(Get-DockerHostPorts)
if (-not $port) { Write-Host '  [SKIP] kein freier DB-Port.' -ForegroundColor Yellow; exit 0 }
$saved = @{ c = $env:DBTEST_CONTAINER; p = $env:DBTEST_PG_PORT }
$env:DBTEST_CONTAINER = $container; $env:DBTEST_PG_PORT = [string]$port
# Eigener Prozess je Lauf: das Skript endet mit return/throw und setzt PG*-Variablen.
function Invoke-Bootstrap([string[]]$More = @()) {
    $shell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    return (Invoke-Native $shell (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bootstrap) + $More))
}
try {
    $r = Invoke-Bootstrap
    Assert-That ($r.Code -eq 0 -and ($r.Output -join "`n") -match 'gebaut') '1) erster Lauf baut die Test-DB' "(Exit $($r.Code)): $($r.Output | Select-Object -Last 3)"
    $r = Invoke-Bootstrap
    Assert-That ($r.Code -eq 0 -and ($r.Output -join "`n") -match 'Hash unveraendert') '2) zweiter Lauf im selben Baum verwendet sie wieder' "(Exit $($r.Code)): $($r.Output | Select-Object -Last 3)"
    # Ein anderer Baum hat die DB dieses Containers neu gebaut: sie traegt seinen Bau-Stand, die Dateien dieses Checkouts aendern sich nicht.
    $m = Invoke-Native docker @('exec', $container, 'psql', '-U', 'postgres', '-d', 'postgres', '-c', "COMMENT ON DATABASE lifeagents_dbtest IS 'lifeagents-dbtest-build:fremder-baum'")
    Assert-That ($m.Code -eq 0) 'Probe: fremder Bau-Stand an der DB gesetzt' ($m.Output -join ' ')
    $r = Invoke-Bootstrap
    $out = $r.Output -join "`n"
    Assert-That ($r.Code -eq 0 -and $out -match 'Baue Test-DB' -and $out -notmatch 'Hash unveraendert') '3) DB mit dem Bau-Stand eines fremden Baums wird neu gebaut, nicht wiederverwendet' "(Exit $($r.Code)): $($r.Output | Select-Object -Last 3)"
} finally {
    [void](Invoke-Bootstrap @('-Down'))
    [void](Remove-SlotReservation -Container (Get-DbPortEntryName $port))
    $env:DBTEST_CONTAINER = $saved.c; $env:DBTEST_PG_PORT = $saved.p
}
if ($failed -eq 0) { Write-Host 'dbtest_reuse_test: alle Pruefungen bestanden.' -ForegroundColor Green } else { Write-Host "dbtest_reuse_test: $failed Fehler." -ForegroundColor Red }
exit $failed
