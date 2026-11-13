#Requires -Version 5.1
# Wendet .sql-Dateien (Schema-Init, V__-Migrationen, R__-Repeatables) auf das Docker-Test-Postgres an.
# Alle Dateien laufen mit ON_ERROR_STOP=1, der erste Fehler bricht ab.
# Mehrere Dateien laufen in einer psql-Session (\i-Driver); die Fehlerdatei steht in der
# psql:<datei>:<zeile>:-Zeile; -Sequential = ein psql-Spawn je Datei.
# Die SQL-Dateien sind idempotent (CREATE ... IF NOT EXISTS, CREATE OR REPLACE, ADD COLUMN IF NOT EXISTS),
# Re-Apply ist sicher.
#
# Usage:
#   .\scripts\db_apply.ps1                                  # applies packages\finance\db\finance.tables_init.sql by default
#   .\scripts\db_apply.ps1 -File packages\finance\db\finance.tables_init.sql
#   .\scripts\db_apply.ps1 -File packages\finance\db\migrations\R__fn_create_loan.sql   # eine Repeatable (ungated, Inner-Loop)
#   .\scripts\db_apply.ps1 -File packages\finance\db\migrations\R__fn_*.sql            # Glob -> alle Treffer (sortiert)
#   .\scripts\db_apply.ps1 -File 'packages\*\db\*.sql' -Migrations packages\core\db\migrations,packages\finance\db\migrations -Repeatable 'packages\*\db\migrations\R__*.sql'  # Full-Apply
#
# Jeder -File-Eintrag darf eine Datei, ein Verzeichnis (-> alle *.sql darin, nach Name sortiert)
# oder ein Wildcard-Glob (-> alle Treffer, sortiert) sein. Sortierung nach Name macht den
# Ziffern-Prefix (00_schema.sql) reihenfolge-stabil vor den fn_*.sql.
#
# Voraussetzung: das Test-Postgres laeuft (bootstrap_test_db.ps1). Exit: 0 = alles angewandt, ungleich 0 = throw
# (psql-Fehler, Datei/Glob nicht gefunden).
#
# Connection: ephemeres Docker-Test-Postgres (trust-Auth, Loopback, nicht-geheime Wegwerf-Defaults;
# Overrides $env:DBTEST_PG_*). Prod wird ueber den Installer (provisioning/lib/apply_schema.sh) provisioniert,
# nie ueber dieses Skript.

param(
    [string[]]$File = @('packages\finance\db\finance.tables_init.sql'),
    [switch]$Sequential,   # Debug-Fallback: 1 psql-Spawn je Datei statt Batch-Session
    # Versionierte Einmal-Migrationen (packages\<pkg>\db\migrations\V{NNN}__*.sql) nach den -File-Inits,
    # gated ueber core.schema_version (migration_should_apply) wie provisioning/lib/apply_schema.sh
    # (Dev<->Release-Konsistenz). Leer = aus. Verarbeitet nur V*.sql.
    # Ein Verzeichnis oder eine Liste (z. B. 'packages\core\db\migrations', 'packages\finance\db\migrations'),
    # je Verzeichnis name-sortiert, in der angegebenen Reihenfolge.
    [string[]]$Migrations = @(),
    # Flyway-Repeatables (packages\<pkg>\db\migrations\R__*.sql: Views + Tool-Functions) nach dem -Migrations-Block,
    # gated ueber core.repeatable_should_apply (relativer Pfad als Key + md5 -> laeuft nur neu bei
    # Inhalts-Aenderung). Glob(s) wie -File (Datei|Verzeichnis|Glob, komma-getrennt). Leer = aus.
    # Kanonischer Dev-Full-Apply = paket-bewusste Glob-Arrays, Core zuerst (Muster: bootstrap_test_db.ps1), je Paket:
    #   db_apply -File 'packages\<pkg>\db\*.sql' -Migrations 'packages\<pkg>\db\migrations' -Repeatable 'packages\<pkg>\db\migrations\R__*.sql'
    # Einzeldatei-Applies (db_apply -File packages\<pkg>\db\migrations\R__fn_x.sql) sind ungated -> Inner-Loop
    # nicht durch die Checksum gebremst; Gating greift nur ueber diesen -Repeatable-Pfad.
    [string[]]$Repeatable = @(),
    # Ledger-Eigentum (core.schema_version.package) fuer flache Dateien (kein packages/<pkg>/ im Pfad).
    # Dateien unter packages/<pkg>/ leiten ihr Paket aus dem Pfad ab (s. Get-LedgerPkg); dieser Wert ist
    # nur der Fallback. Gilt nur fuer die gegateten V__/R__-Bloecke (Inits treffen das Ledger nicht).
    [string]$Package = 'core'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

# Jeder psql-Aufruf laeuft hier durch. psql schreibt NOTICEs auf stderr; leitet ein Aufrufer die Ausgabe um
# (*> / 2>&1, z. B. run_free_gates.ps1), macht PS 5.1 daraus unter $ErrorActionPreference='Stop' einen
# terminierenden NativeCommandError. Daher EAP lokal 'Continue'; Pass/Fail allein ueber $LASTEXITCODE (ON_ERROR_STOP=1).
function Invoke-Psql {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & psql --no-psqlrc -v ON_ERROR_STOP=1 @args } finally { $ErrorActionPreference = $prev }
}

# Besitzendes Paket fuer den Ledger: packages/<pkg>/ -> <pkg>, sonst der -Package-Fallback. So traegt ein
# Aufruf gemischte Core-/Flach-Globs mit je korrektem Label (wie apply_schema.sh: Paket folgt dem Quell-Verzeichnis).
function Get-LedgerPkg([string]$path) {
    if ($path.Replace('\', '/') -match '/packages/([^/]+)/') { return $Matches[1] }
    return $Package
}

# Keine .env-DB-Keys (trust-Auth, s. bootstrap_test_db.ps1).
$PG_HOST     = if ($env:DBTEST_PG_HOST)     { $env:DBTEST_PG_HOST }     else { '127.0.0.1' }
$PG_PORT     = if ($env:DBTEST_PG_PORT)     { $env:DBTEST_PG_PORT }     else { '55432' }
$PG_USER     = if ($env:DBTEST_PG_USER)     { $env:DBTEST_PG_USER }     else { 'postgres' }
$PG_DATABASE = if ($env:DBTEST_PG_DATABASE) { $env:DBTEST_PG_DATABASE } else { 'lifeagents_dbtest' }
$PG_PASSWORD = ''

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    $pgBin = 'C:\Program Files\PostgreSQL\17\bin'
    if (Test-Path "$pgBin\psql.exe") {
        $env:PATH = "$pgBin;$env:PATH"
    } else {
        throw "psql.exe nicht gefunden. PostgreSQL-Client installieren oder Pfad in Skript anpassen ($pgBin)."
    }
}

$env:PGHOST          = $PG_HOST
$env:PGPORT          = $PG_PORT
$env:PGUSER          = $PG_USER
$env:PGPASSWORD      = $PG_PASSWORD
$env:PGDATABASE      = $PG_DATABASE
$env:PGCLIENTENCODING = 'UTF8'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Eine in Anfuehrungszeichen uebergebene Komma-Liste ('a.sql,b.sql') kommt als ein String an -> hier aufteilen.
$File = @($File | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$resolved = foreach ($f in $File) {
    $base = if ([System.IO.Path]::IsPathRooted($f)) { $f } else { Join-Path $RepoRoot $f }
    if ($f -match '[*?]') {
        $hits = @(Get-ChildItem -Path $base -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($hits.Count -eq 0) { throw "Keine Datei passt zum Glob: $f" }
        $hits.FullName
    } elseif (Test-Path $base -PathType Container) {
        $hits = @(Get-ChildItem -Path $base -Filter '*.sql' -File | Sort-Object Name)
        if ($hits.Count -eq 0) { throw "Keine *.sql im Verzeichnis: $f" }
        $hits.FullName
    } elseif (Test-Path $base -PathType Leaf) {
        $base
    } else {
        throw "SQL-Datei/Verzeichnis nicht gefunden: $base"
    }
}

$resolved = @($resolved)
$sw = [System.Diagnostics.Stopwatch]::StartNew()

if ($resolved.Count -gt 1 -and -not $Sequential) {
    # Batch: alle Dateien in einer psql-Session via generiertem \i-Driver (spart ~2 s Spawn je Datei).
    # ON_ERROR_STOP=1 wirkt session-weit ueber alle \i: Abbruch beim ersten Fehler, bereits applizierte
    # Dateien bleiben (idempotent). Die ERROR-Zeile traegt "psql:<datei>:<zeile>:".
    $driverPath = Join-Path $env:TEMP "db_apply_driver_$PID.sql"
    try {
        $driver = New-Object System.Collections.Generic.List[string]
        foreach ($path in $resolved) {
            $driver.Add("\i $($path.Replace('\', '/'))")   # psql \i will Forward-Slashes
        }
        [System.IO.File]::WriteAllLines($driverPath, $driver)

        # -q: Command-Tags (CREATE FUNCTION ...) unterdruecken; NOTICEs/ERRORs (stderr) bleiben sichtbar.
        Write-Host "==> psql Batch: $($resolved.Count) Datei(en) in einer Session ($($File -join ', ')) ..."
        Invoke-Psql -q -f $driverPath
        if ($LASTEXITCODE -ne 0) {
            throw "psql-Batch fehlgeschlagen (Exit $LASTEXITCODE) — Fehlerdatei steht in der psql:<datei>:<zeile>:-Zeile oben."
        }
    } finally {
        Remove-Item -Path $driverPath -Force -ErrorAction SilentlyContinue
    }
} else {
    foreach ($path in $resolved) {
        $rel = $path.Replace('\', '/').Replace("$RepoRoot/", '')   # Anzeige: Forward-Slashes, dann Root strippen
        Write-Host ""
        Write-Host "==> psql -f $rel ..."
        Invoke-Psql -f $path
        if ($LASTEXITCODE -ne 0) {
            throw "psql fehlgeschlagen bei: $rel (Exit $LASTEXITCODE)"
        }
        Write-Host "    OK: $rel"
    }
}

# =====================================================================
# Versionierte Migrationen (optional): packages/<pkg>/db/migrations/V{NNN}__*.sql, je genau einmal.
# Gated ueber core.schema_version (packages/core/db/core.schema_version_init.sql muss vorher angewandt
# sein, Teil der -File-Inits). Jede Migration laeuft in einer Transaktion: Reservierung
# (migration_should_apply) + Anwendung atomar; ein Fehler rollt die Reservierung mit zurueck ->
# beim naechsten Lauf erneut. Zweiter Lauf = No-op.
# =====================================================================
if ($Migrations.Count -gt 0) {
    # Je -Migrations-Verzeichnis in der gegebenen Reihenfolge V*.sql name-sortiert; Ledger-Eigentum je Datei via Get-LedgerPkg.
    $migFiles = @(foreach ($md in $Migrations) {
        $migBase = if ([System.IO.Path]::IsPathRooted($md)) { $md } else { Join-Path $RepoRoot $md }
        if (-not (Test-Path $migBase -PathType Container)) { throw "Migrations-Verzeichnis nicht gefunden: $migBase" }
        Get-ChildItem -Path $migBase -Filter 'V*.sql' -File -ErrorAction SilentlyContinue | Sort-Object Name
    })
    if ($migFiles.Count -eq 0) {
        Write-Host ""
        Write-Host "==> Keine Migrationen in $($Migrations -join ', ') (V*.sql) — uebersprungen."
    } else {
        Write-Host ""
        Write-Host "==> Migrationen ($($migFiles.Count)) aus $($Migrations -join ', ') (gated ueber core.schema_version) ..."
        $migDriver = New-Object System.Collections.Generic.List[string]
        $migDriver.Add('\set ON_ERROR_STOP on')
        foreach ($mf in $migFiles) {
            $ver = ($mf.Name -split '__')[0]                                  # 'V001__x.sql' -> 'V001'
            $sum = (Get-FileHash -Algorithm MD5 -LiteralPath $mf.FullName).Hash.ToLower()
            $fwd = $mf.FullName.Replace('\','/')
            $migDriver.Add("SET lifeagents.package = '$(Get-LedgerPkg $mf.FullName)';")   # Ledger-Eigentum
            $migDriver.Add('BEGIN;')
            $migDriver.Add("SELECT CASE WHEN core.migration_should_apply('$ver', '$($mf.Name)', '$sum') THEN 'true' ELSE 'false' END AS _mig \gset")
            $migDriver.Add('\if :_mig')
            $migDriver.Add("\echo '  [MIGRATION] anwenden: $($mf.Name)'")
            $migDriver.Add("\i $fwd")
            $migDriver.Add('\else')
            $migDriver.Add("\echo '  [MIGRATION] bereits angewandt: $($mf.Name)'")
            $migDriver.Add('\endif')
            $migDriver.Add('COMMIT;')
        }
        $migDriverPath = Join-Path $env:TEMP "db_apply_migrations_$PID.sql"
        try {
            [System.IO.File]::WriteAllLines($migDriverPath, $migDriver)
            Invoke-Psql -f $migDriverPath
            if ($LASTEXITCODE -ne 0) {
                throw "Migrations-Lauf fehlgeschlagen (Exit $LASTEXITCODE)."
            }
        } finally {
            Remove-Item -Path $migDriverPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# =====================================================================
# Repeatables (optional): packages/<pkg>/db/migrations/R__*.sql (Views + Tool-Functions), je per
# core.repeatable_should_apply(relpfad, md5) gegated -> laufen nur neu bei Inhalts-Aenderung.
# Nach dem -Migrations-Block (ein V-Rename muss vor dem View-Recreate liegen). Tracking-Key = relativer
# Pfad mit Forward-Slashes. Jede Datei in einer Transaktion: Reservierung/Update + Anwendung atomar.
# =====================================================================
if ($Repeatable.Count -gt 0) {
    $repResolved = foreach ($r in $Repeatable) {
        $base = if ([System.IO.Path]::IsPathRooted($r)) { $r } else { Join-Path $RepoRoot $r }
        if ($r -match '[*?]') {
            $hits = @(Get-ChildItem -Path $base -File -ErrorAction SilentlyContinue | Sort-Object Name)
            if ($hits.Count -eq 0) { throw "Keine Datei passt zum Repeatable-Glob: $r" }
            $hits.FullName
        } elseif (Test-Path $base -PathType Container) {
            $hits = @(Get-ChildItem -Path $base -Filter 'R__*.sql' -File | Sort-Object Name)
            if ($hits.Count -eq 0) { throw "Keine R__*.sql im Verzeichnis: $r" }
            $hits.FullName
        } elseif (Test-Path $base -PathType Leaf) {
            $base
        } else {
            throw "Repeatable-Datei/Verzeichnis nicht gefunden: $base"
        }
    }
    $repResolved = @($repResolved | Sort-Object)
    Write-Host ""
    Write-Host "==> Repeatables ($($repResolved.Count)) (gated ueber core.repeatable_should_apply) ..."
    $repDriver = New-Object System.Collections.Generic.List[string]
    $repDriver.Add('\set ON_ERROR_STOP on')
    foreach ($rf in $repResolved) {
        # Erst nach Forward-Slashes normalisieren, dann den Repo-Root strippen: $RepoRoot kommt aus
        # `git rev-parse` mit Forward-Slashes, der Pfad mit Backslashes (sonst absoluter Key).
        $rel = $rf.Replace('\', '/').Replace("$RepoRoot/", '')
        $sum = (Get-FileHash -Algorithm MD5 -LiteralPath $rf).Hash.ToLower()
        $fwd = $rf.Replace('\', '/')
        $name = [System.IO.Path]::GetFileName($rf)
        $repDriver.Add("SET lifeagents.package = '$(Get-LedgerPkg $rf)';")   # Ledger-Eigentum
        $repDriver.Add('BEGIN;')
        $repDriver.Add("SELECT CASE WHEN core.repeatable_should_apply('$rel', '$sum') THEN 'true' ELSE 'false' END AS _rep \gset")
        $repDriver.Add('\if :_rep')
        $repDriver.Add("\echo '  [REPEATABLE] anwenden: $name'")
        $repDriver.Add("\i $fwd")
        $repDriver.Add('\else')
        $repDriver.Add("\echo '  [REPEATABLE] unveraendert, uebersprungen: $name'")
        $repDriver.Add('\endif')
        $repDriver.Add('COMMIT;')
    }
    $repDriverPath = Join-Path $env:TEMP "db_apply_repeatables_$PID.sql"
    try {
        [System.IO.File]::WriteAllLines($repDriverPath, $repDriver)
        Invoke-Psql -f $repDriverPath
        if ($LASTEXITCODE -ne 0) {
            throw "Repeatable-Lauf fehlgeschlagen (Exit $LASTEXITCODE)."
        }
    } finally {
        Remove-Item -Path $repDriverPath -Force -ErrorAction SilentlyContinue
    }
}

$sw.Stop()
Write-Host ""
Write-Host "Fertig ($($resolved.Count) Datei(en), $([math]::Round($sw.Elapsed.TotalSeconds,1))s)."
