#Requires -Version 5.1
# DB Smoke Tests — Layer 1 der TDD-Infrastruktur.
# Fuehrt alle tests\db\**\test_*.sql (rekursiv, ein Unterordner je Paket + cross)
# gegen eine EPHEMERE, hermetische Docker-Test-DB aus (NIE Prod):
# bootstrap_test_db.ps1 faehrt pgvector/pgvector:pg17 (= postgres:17 + pgvector) als Wegwerf-Container hoch + baut das Schema aus den
# packages/*/db-Quellen (hash-gegated). fn_*-Writes, Resolve/Verify, Hard-Guarantee-CHECKs/Trigger, View-Smoke.
# Jede SQL-Datei laeuft in BEGIN/DO-Block/ROLLBACK — immer clean, kein Residual-State.
#
# Default = BATCH-Modus: ALLE Tests in EINER psql-Session (Driver-File aus \warn-Markern
# + \i + Guard-ROLLBACK/RESET) — eliminiert den Spawn-Overhead pro Datei. Gegen das lokale
# Docker-Test-Postgres (kein Netz-RTT mehr) laeuft die Voll-Suite in wenigen Sekunden.
# Mechanik-Invarianten (nicht "vereinfachen"):
#   - Marker via \warn (stderr!), NICHT \echo: psql-stdout ist im Pipe-Modus block-gepuffert,
#     ERROR: geht auf stderr -> nur im selben Stream ist die Marker<->ERROR-Ordnung garantiert.
#   - ON_ERROR_STOP MUSS aus sein: es wirkt session-weit ueber alle \i und wuerde beim ersten
#     FAIL die ganze Kette beenden. Pass/Fail kommt komplett aus dem stderr-Parsing.
#   - Guard "ROLLBACK; RESET ALL;" nach jedem \i faengt vergessene/aborted Transaktionen +
#     Session-State-Leakage; sein "WARNING: there is no transaction in progress" ist normal.
# FAIL je Test = >=1 "ERROR:"-Zeile zwischen seinen Markern (RAISE EXCEPTION -> ERROR).
#
# Usage:
#   .\scripts\db_test.ps1                        # alle Tests (Batch, eine Session)
#   .\scripts\db_test.ps1 -Filter "*transfer*"   # nur Matching-Tests (mehrere: "*transfer*,*reconcile*")
#   .\scripts\db_test.ps1 -Verbose               # NOTICE-Messages (PASS-Details) anzeigen
#   .\scripts\db_test.ps1 -Sequential            # alter Pfad: 1 psql-Spawn je Datei (Debug)
#   .\scripts\db_test.ps1 -Reset                 # Test-Container + DB verwerfen und frisch bauen
#
# Vorbedingung: Docker (Desktop) laeuft (die Test-DB ist ein pgvector/pgvector:pg17-Wegwerf-Container).
# Exit-Code = Anzahl fehlgeschlagener Tests (0 = alle gruen, >0 = CI-Fehler).
param(
    [string[]]$Filter = @('test_*.sql'),
    [switch]$Verbose,
    [switch]$Sequential,
    [switch]$Reset
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

# Hermetische Test-DB sicherstellen (ephemeres Docker-Postgres, NIE Prod): Container hoch + Schema
# hash-gegated bauen (-Reset erzwingt Neubau). db_test liest die Prod-PG_*-Keys GAR NICHT —
# struktureller Schutz gegen Prod-Kontamination.
# Kollisionsschutz: laeuft scripts/dev/run_free_gates.ps1 in einem ANDEREN Prozess auf derselben Test-DB (z. B. ein
# git push mit Pre-Push-db_test waehrenddessen, 2026-10-23), wuerden sich beide die DB gegenseitig neu bauen.
$freeGatesLock = Join-Path $RepoRoot '.local\run_free_gates.lock'
if (Test-Path $freeGatesLock) {
    $held = Get-Content $freeGatesLock -Raw | ConvertFrom-Json
    $myDb = if ($env:DBTEST_CONTAINER) { $env:DBTEST_CONTAINER } else { 'lifeagents-dbtest' }
    if ($held.pid -ne $PID -and $held.db -eq $myDb -and (Get-Process -Id $held.pid -ErrorAction SilentlyContinue)) {
        throw "run_free_gates.ps1 (PID $($held.pid)) nutzt gerade die Test-DB $myDb -- erst abwarten (oder eigene DBTEST_CONTAINER/DBTEST_PG_PORT)."
    }
}

$bootstrapArgs = @{}
if ($Reset) { $bootstrapArgs['Reset'] = $true }
& "$PSScriptRoot\bootstrap_test_db.ps1" @bootstrapArgs

# Test-DB-Verbindung (identisch zu db_apply.ps1; trust-Auth -> kein Passwort)
$PG_HOST     = if ($env:DBTEST_PG_HOST)     { $env:DBTEST_PG_HOST }     else { '127.0.0.1' }
$PG_PORT     = if ($env:DBTEST_PG_PORT)     { $env:DBTEST_PG_PORT }     else { '55432' }
$PG_USER     = if ($env:DBTEST_PG_USER)     { $env:DBTEST_PG_USER }     else { 'postgres' }
$PG_DATABASE = if ($env:DBTEST_PG_DATABASE) { $env:DBTEST_PG_DATABASE } else { 'lifeagents_dbtest' }
$PG_PASSWORD = ''

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    $pgBin = 'C:\Program Files\PostgreSQL\17\bin'
    if (Test-Path "$pgBin\psql.exe") { $env:PATH = "$pgBin;$env:PATH" }
    else { throw "psql.exe nicht gefunden ($pgBin)." }
}

$env:PGHOST           = $PG_HOST
$env:PGPORT           = $PG_PORT
$env:PGUSER           = $PG_USER
$env:PGPASSWORD       = $PG_PASSWORD
$env:PGDATABASE       = $PG_DATABASE
$env:PGCLIENTENCODING = 'UTF8'

# Test-Dateien entdecken
$testDir = Join-Path $RepoRoot 'tests\db'
if (-not (Test-Path $testDir)) {
    throw "Test-Verzeichnis nicht gefunden: $testDir"
}
# -File: der Filter darf nie ein VERZEICHNIS treffen (tests/db/<pkg> matcht sonst z. B. '*estate*'
# und crasht Get-TestKey mit DirectoryInfo — latent seit den Paket-Unterordnern, estate-WS-0a getroffen).
# Mehrere Muster komma-getrennt ("*transfer*,*reconcile*" oder als PS-Liste) -> Vereinigung (frueher: kein Treffer).
$filters = @($Filter | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$tests = @($filters | ForEach-Object { Get-ChildItem -Path $testDir -Filter $_ -Recurse -File }) |
    Sort-Object FullName -Unique
if ($tests.Count -eq 0) {
    Write-Host "Keine Test-Dateien gefunden (Filter: $Filter in $testDir)"
    exit 0
}

# Report-Key = Relativpfad zu tests\db (Forward-Slash, ohne .sql), NICHT BaseName:
# finance/ und career/ tragen je eine test_fn_advisor_review.sql — BaseName-Keys wuerden
# die Marker-Bloecke der beiden Dateien lautlos ineinander maskieren.
function Get-TestKey([System.IO.FileInfo]$File) {
    $rel = $File.FullName.Substring($testDir.Length).TrimStart('\', '/')
    return ($rel -replace '\.sql$', '').Replace('\', '/')
}

Write-Host ""
$mode = if ($Sequential) { 'sequentiell' } else { 'Batch, 1 Session' }
Write-Host "DB Smoke Tests — $($tests.Count) Datei(en) gegen $PG_DATABASE@${PG_HOST}:$PG_PORT (Docker, $mode)"
Write-Host ("-" * 60)

$sw       = [System.Diagnostics.Stopwatch]::StartNew()
$passed   = 0
$failed   = 0

if (-not $Sequential) {
    # ---------- BATCH-Modus: ein psql, Driver-File, stderr-Marker-Parsing ----------
    $driverPath = Join-Path $env:TEMP "db_test_driver_$PID.sql"
    $outPath    = Join-Path $env:TEMP "db_test_stdout_$PID.txt"
    $errPath    = Join-Path $env:TEMP "db_test_stderr_$PID.txt"
    try {
        $driver = New-Object System.Collections.Generic.List[string]
        foreach ($test in $tests) {
            $p = $test.FullName.Replace('\', '/')   # psql \i will Forward-Slashes
            $key = Get-TestKey $test
            $driver.Add("\warn === BEGIN $key ===")
            $driver.Add("\i $p")
            $driver.Add('ROLLBACK;')                 # Guard: aborted/vergessene Transaktion raeumen
            $driver.Add('RESET ALL;')                # Guard: Session-GUC-Leakage zwischen Tests
            $driver.Add("\warn === END $key ===")
        }
        [System.IO.File]::WriteAllLines($driverPath, $driver)

        # KEIN ON_ERROR_STOP (siehe Kopf-Kommentar). Redirect via cmd /c: stdout/stderr je
        # eigene Datei -> garantierte Zeilen-Ordnung im stderr-Stream, kein PS-5.1-
        # NativeCommandError-Quirk (stderr beruehrt die PS-Pipeline nie).
        & cmd /c "psql --no-psqlrc -P pager=off --no-align -t -q -f `"$driverPath`" >`"$outPath`" 2>`"$errPath`""
        $psqlExit = $LASTEXITCODE

        $errLines = if (Test-Path $errPath) { [System.IO.File]::ReadAllLines($errPath) } else { @() }

        # Marker-Bloecke zuordnen (alles im selben Stream -> Ordnung garantiert).
        # $ended trackt den END-Marker: stirbt psql MITTEN in einem Test (FATAL/Connection-Abriss
        # produziert kein "ERROR:"), darf der angefangene Block nicht still PASSen.
        $blocks  = @{}
        $ended   = @{}
        $current = $null
        foreach ($line in $errLines) {
            if ($line -match '^=== BEGIN (.+) ===$') {
                $current = $Matches[1]
                $blocks[$current] = New-Object System.Collections.Generic.List[string]
            } elseif ($line -match '^=== END (.+) ===$') {
                $ended[$Matches[1]] = $true
                $current = $null
            } elseif ($null -ne $current) {
                $blocks[$current].Add($line)
            }
        }

        if ($blocks.Count -eq 0) {
            # Kein einziger Marker -> psql kam gar nicht bis zum Driver (Connection o. ae.)
            $errLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
            throw "psql-Batch lieferte keine Test-Marker (Exit $psqlExit) — Verbindung/Driver pruefen."
        }

        foreach ($test in $tests) {
            $name  = Get-TestKey $test
            $lines = $blocks[$name]
            if ($null -eq $lines) {
                # BEGIN-Marker fehlt -> Session starb vor diesem Test (z. B. fataler Abbruch)
                $failed++
                Write-Host "  [FAIL] $name" -ForegroundColor Red
                Write-Host "         (kein Marker-Block — psql-Session endete vorzeitig, Exit $psqlExit)" -ForegroundColor Red
                continue
            }
            # ERROR als Severity-Token ankern: Zeilenstart ODER nach "psql:<datei>:<zeile>: "
            # (\i-Praefix) — ein "ERROR:" mitten in einer NOTICE-Message zaehlt NICHT als FAIL.
            $errorHits = @($lines | Where-Object { $_ -match '^(?:psql:.*:\d+: +)?ERROR:' })
            if (-not $ended[$name]) {
                $failed++
                Write-Host "  [FAIL] $name" -ForegroundColor Red
                Write-Host "         (END-Marker fehlt — psql-Session starb in diesem Test, Exit $psqlExit)" -ForegroundColor Red
                $lines | Select-Object -Last 3 | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
            } elseif ($errorHits.Count -eq 0) {
                $passed++
                Write-Host "  [PASS] $name"
                if ($Verbose) {
                    $lines | Where-Object { $_ -match 'PASS' } | ForEach-Object { Write-Host "         $_" }
                }
            } else {
                $failed++
                Write-Host "  [FAIL] $name" -ForegroundColor Red
                $lines | Where-Object { $_ -match 'ERROR:|DETAIL:|CONTEXT:|HINT:|FAIL' } |
                    ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
            }
        }
    } finally {
        Remove-Item -Path $driverPath, $outPath, $errPath -Force -ErrorAction SilentlyContinue
    }
} else {
    # ---------- Sequentieller Modus (Debug-Fallback): 1 psql-Spawn je Datei ----------
    foreach ($test in $tests) {
        $name = Get-TestKey $test

        # psql-Flags:
        #   --no-psqlrc           : kein User-psqlrc
        #   -v ON_ERROR_STOP=1    : bricht bei RAISE EXCEPTION ab (Exit != 0)
        #   -P pager=off          : kein Pager
        #   --no-align -t         : plain output (nur NOTICE-Zeilen, kein Tabellenrahmen)
        #   -q                    : quiet (kein "DO" / "ROLLBACK"-Echo) ausser -Verbose
        $psqlArgs = @(
            '--no-psqlrc'
            '-v', 'ON_ERROR_STOP=1'
            '-P', 'pager=off'
            '--no-align', '-t'
            '-f', $test.FullName
        )
        if (-not $Verbose) { $psqlArgs += '-q' }

        # psql schreibt RAISE NOTICE/EXCEPTION auf stderr. 2>&1 wuerde unter
        # $ErrorActionPreference='Stop' jede stderr-Zeile als terminierenden
        # NativeCommandError werfen (PS-5.1-Quirk) -> hier lokal auf 'Continue'.
        # Pass/Fail kommt allein aus $LASTEXITCODE (ON_ERROR_STOP=1).
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $output = & psql @psqlArgs 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP

        if ($exitCode -eq 0) {
            $passed++
            $noticeLines = ($output | Where-Object { $_ -match 'PASS' }) -join "`n"
            if ($Verbose -and $noticeLines) {
                Write-Host "  [PASS] $name"
                $noticeLines -split "`n" | Where-Object { $_ } | ForEach-Object { Write-Host "         $_" }
            } else {
                Write-Host "  [PASS] $name"
            }
        } else {
            $failed++
            Write-Host "  [FAIL] $name" -ForegroundColor Red
            # Fehler-Output direkt ausgeben (RAISE EXCEPTION-Meldung ist hier enthalten)
            $output | Where-Object { $_ } | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
        }
    }
}

$sw.Stop()
Write-Host ("-" * 60)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
$secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
Write-Host "$passed/$($tests.Count) Tests bestanden, $failed fehlgeschlagen ($($tests.Count) Tests, ${secs}s)." -ForegroundColor $color
Write-Host ""

exit $failed
