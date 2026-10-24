#Requires -Version 5.1
# bootstrap_test_db.ps1 — ephemere, hermetische Test-DB fuer db_test.ps1 (raus aus Prod).
#
# Faehrt ein WEGWERF-Postgres als Docker-Container (pgvector/pgvector:pg17 = das offizielle
# postgres:17-Debian-Image + pgvector — dieselben PGDG-Pakete wie install_pg.sh, plus pgvector nur
# fuer den paperless:V001-Rueckbau-Test, s. $Image) und baut darin das Schema
# aus DENSELBEN getrackten packages/*/db-Quellen, in der 4-Phasen-Sequenz von provisioning/lib/apply_schema.sh:
#   1-3) db_apply.ps1  (Baseline-Inits -> V__-Migrationen -> R__-Repeatables; db_apply zielt
#        immer auf dieses Docker-Test-Postgres — Prod laeuft ueber den Installer apply_schema.sh)
#     4) util-Haertung + Host-Read-Only-Rollen (core_ro/context_ro inkl. core.backup_key-REVOKE;
#        + per-Paket finance_rw/finance_ro via fn_provision_package_roles, s. 3b unten)
#   + Config-Store-Seed (ai_models -> config; einzige harte Seed-Abhaengigkeit der db-Tests:
#     test_config_model_selector joint core.config x agent.ai_models). Persona-Fixtures + Instruktions-
#     Contexts braucht das Baseline-DB NICHT — die db-Tests sind self-seedend (BEGIN..ROLLBACK).
#
# trust-Auth (POSTGRES_HOST_AUTH_METHOD=trust) -> KEIN Passwort, Loopback-Port -> keine .env-DB-Keys.
# Verbindungswerte sind nicht-geheime Wegwerf-Defaults (Overrides $env:DBTEST_PG_{HOST,PORT,USER,DATABASE}),
# identisch zu db_apply.ps1.
#
# STALENESS-Gate: MD5 ueber das Quell-Set (packages/*/db/*.sql + V__/R__ + die 3 util-Dateien + ai_models.json + alle Manifeste)
# in .local/dbtest_state.json. Unveraendert + DB existiert + selber Container -> Reuse (nur Container warm
# halten). Geaendert / DB fehlt / Container neu / -Reset -> Schema neu bauen. -> kein falsches Gruen.
#
# Usage:
#   .\scripts\bootstrap_test_db.ps1            # Container hoch + Schema (hash-gegated; Reuse wenn aktuell)
#   .\scripts\bootstrap_test_db.ps1 -Reset     # Container + DB verwerfen und frisch bauen
#   .\scripts\bootstrap_test_db.ps1 -Down      # Container entfernen (Teardown), State loeschen
#
# Vorbedingung: Docker (Desktop) installiert + Daemon laeuft. db_test.ps1 ruft dieses Skript selbst.

param(
    [switch]$Reset,
    [switch]$Down
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

# --- Test-DB-Verbindung (nicht-geheime Wegwerf-Defaults; mit db_apply -Target test identisch) ---
# Override $env:DBTEST_CONTAINER (+ $env:DBTEST_PG_PORT): ein zweiter Git-Worktree faehrt seine eigene Test-DB parallel
# (Paritaet N8NTEST_CONTAINER), statt die geteilte bei abweichendem Schema-Hash neu zu bauen (gegenseitiges Zuruecksetzen).
$Container = if ($env:DBTEST_CONTAINER) { $env:DBTEST_CONTAINER } else { 'lifeagents-dbtest' }
# pgvector/pgvector:pg17 = das offizielle postgres:17-Image + vorinstallierte pgvector-Extension.
# Kein Paket braucht pgvector mehr (paperless v0.3.0, install_pg.sh installiert es nicht mehr) — das Image
# bleibt, damit tests/db/paperless/test_paperless_retire.sql den Extension-Drop von paperless:V001 auf
# einem nachgebauten Altbestand BEWEIST (ohne Extension liefe der Teil still als No-op).
$Image     = 'pgvector/pgvector:pg17'
$DbHost = if ($env:DBTEST_PG_HOST)     { $env:DBTEST_PG_HOST }     else { '127.0.0.1' }
$DbPort = if ($env:DBTEST_PG_PORT)     { $env:DBTEST_PG_PORT }     else { '55432' }
$DbUser = if ($env:DBTEST_PG_USER)     { $env:DBTEST_PG_USER }     else { 'postgres' }
$DbName = if ($env:DBTEST_PG_DATABASE) { $env:DBTEST_PG_DATABASE } else { 'lifeagents_dbtest' }
$StateFile = Join-Path $RepoRoot '.local\dbtest_state.json'

# psql-Pfad-Fallback (wie die anderen db_*-Skripte)
if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    $pgBin = 'C:\Program Files\PostgreSQL\17\bin'
    if (Test-Path "$pgBin\psql.exe") { $env:PATH = "$pgBin;$env:PATH" }
    else { throw "psql.exe nicht gefunden ($pgBin)." }
}

# Invoke-Native — natives Tool aufrufen, stdout+stderr + Exit-Code einsammeln. EAP lokal auf 'Continue'
# (PS-5.1-Quirk: native stderr unter 'Stop' + 2>&1 wuerde als terminierender NativeCommandError werfen).
function Invoke-Native {
    param([string]$Exe, [string[]]$CmdArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @CmdArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Output = @($out) }
}

function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker nicht im PATH. Vorbedingung: Docker Desktop installieren + starten (die Test-DB laeuft als $Image-Container)."
    }
    $r = Invoke-Native docker @('info','--format','{{.ServerVersion}}')
    if ($r.Code -ne 0) { throw "Docker-Daemon nicht erreichbar — Docker Desktop starten. ($($r.Output -join ' '))" }
}

function Get-ContainerId {
    param([switch]$RunningOnly)
    $a = @('ps'); if (-not $RunningOnly) { $a += '-a' }
    $a += @('--filter', "name=^/$Container$", '--format', '{{.ID}}')
    $r = Invoke-Native docker $a
    return (($r.Output -join "`n").Trim())
}

# --- Teardown ---
if ($Down) {
    Assert-Docker
    if (Get-ContainerId) {
        Invoke-Native docker @('rm','-f',$Container) | Out-Null
        Write-Host "Container $Container entfernt."
    } else {
        Write-Host "Kein Container $Container vorhanden."
    }
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
    return
}

# --- Container sicherstellen ---
Assert-Docker

if ($Reset -and (Get-ContainerId)) {
    Write-Host "Verwerfe Container $Container (-Reset) ..."
    Invoke-Native docker @('rm','-f',$Container) | Out-Null
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
}

if (-not (Get-ContainerId)) {
    Write-Host "Starte $Image als $Container (127.0.0.1:$DbPort, trust-Auth) ..."
    $r = Invoke-Native docker @('run','-d','--name',$Container,
        '-e','POSTGRES_HOST_AUTH_METHOD=trust',
        '-p',"127.0.0.1:${DbPort}:5432",$Image)
    if ($r.Code -ne 0) { throw "docker run fehlgeschlagen: $($r.Output -join "`n")" }
} elseif (-not (Get-ContainerId -RunningOnly)) {
    $r = Invoke-Native docker @('start',$Container)
    if ($r.Code -ne 0) { throw "docker start fehlgeschlagen: $($r.Output -join "`n")" }
}

# Readiness abwarten (frischer Cluster braucht einen Moment)
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    $r = Invoke-Native docker @('exec',$Container,'pg_isready','-U',$DbUser,'-d','postgres','-q')
    if ($r.Code -eq 0) { $ready = $true; break }
    Start-Sleep -Milliseconds 500
}
if (-not $ready) { throw "Postgres im Container $Container wurde nicht bereit (Timeout)." }

# Ein bestehender Container behaelt den Port seines ersten Starts. Passt DBTEST_PG_PORT nicht dazu, schlug psql
# frueher erst spaeter mit "Connection refused" fehl (2026-10-23: Port geraten) -> hier frueh und mit dem richtigen Wert.
$mapped = ((Invoke-Native docker @('port', $Container, '5432/tcp')).Output -join "`n").Trim()
if ($mapped -match ':(\d+)\s*$' -and $Matches[1] -ne [string]$DbPort) {
    throw "Container $Container lauscht auf Port $($Matches[1]), nicht auf $DbPort -> `$env:DBTEST_PG_PORT='$($Matches[1])' setzen (oder -Reset fuer einen neuen Container mit Port $DbPort)."
}

# --- Staleness-Hash ueber das Quell-Set ---
function Get-BuildHash {
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    # Paket-generisch (WS-0 career): ALLE packages/*/db in den Hash -> ein neues Paket bustet den Cache.
    foreach ($pkgDir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory)) {
        $d = Join-Path $pkgDir.FullName 'db'
        if (-not (Test-Path $d)) { continue }
        Get-ChildItem $d -Filter '*.sql' -File -ErrorAction SilentlyContinue | ForEach-Object { $files.Add($_) }
        Get-ChildItem (Join-Path $d 'migrations') -Filter 'V*.sql' -File -ErrorAction SilentlyContinue | ForEach-Object { $files.Add($_) }
        Get-ChildItem (Join-Path $d 'migrations') -Filter 'R__*.sql' -File -ErrorAction SilentlyContinue | ForEach-Object { $files.Add($_) }
    }
    # Das Skript selbst: CREATE DATABASE (Kodierung/Locale = Prod-Paritaet, install_pg.sh) aendert die Test-DB mit.
    foreach ($rel in 'scripts\bootstrap_test_db.ps1','packages\core\db\util\util_harden_db_security.sql','packages\core\db\util\util_create_core_ro.sql','packages\core\db\util\util_create_context_ro.sql','packages\core\seed\ai_models.json') {
        $p = Join-Path $RepoRoot $rel
        if (Test-Path $p) { $files.Add((Get-Item $p)) }
    }
    # Config lebt paket-besessen in den manifest.json (.config) -> generisch ALLE Manifeste in den Hash
    # (ein neues Paket triggert so automatisch einen Rebuild; spiegelt seed_data.sh _seed_package_config).
    Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | ForEach-Object {
        $mf = Join-Path $_.FullName 'manifest.json'
        if (Test-Path $mf) { $files.Add((Get-Item $mf)) }
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in ($files | Sort-Object FullName)) {
        $r = $f.FullName.Replace('\','/').Replace("$RepoRoot/", '')
        $h = (Get-FileHash -Algorithm MD5 -LiteralPath $f.FullName).Hash.ToLower()
        [void]$sb.AppendLine("${r}:${h}")
    }
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sb.ToString()))
    return ([System.BitConverter]::ToString($bytes) -replace '-','').ToLower()
}

$containerId = ((Invoke-Native docker @('inspect','-f','{{.Id}}',$Container)).Output -join '').Trim()
$currentHash = Get-BuildHash

# DB im Container vorhanden?
$env:PGHOST = $DbHost; $env:PGPORT = $DbPort; $env:PGUSER = $DbUser
$env:PGPASSWORD = ''; $env:PGDATABASE = 'postgres'; $env:PGCLIENTENCODING = 'UTF8'
$r = Invoke-Native psql @('--no-psqlrc','-tAc',"SELECT 1 FROM pg_database WHERE datname='$DbName'")
$dbExists = ($r.Code -eq 0 -and (($r.Output -join '').Trim() -eq '1'))

$needRebuild = $true
if (-not $Reset -and $dbExists -and (Test-Path $StateFile)) {
    try {
        $state = [System.IO.File]::ReadAllText($StateFile, $Utf8NoBom) | ConvertFrom-Json
        if ($state.hash -eq $currentHash -and $state.container_id -eq $containerId) { $needRebuild = $false }
    } catch { $needRebuild = $true }
}

if (-not $needRebuild) {
    $env:PGDATABASE = $DbName   # Reuse-Pfad: Env sauber auf die Test-DB lassen (nicht 'postgres')
    Write-Host "Test-DB $DbName aktuell (Hash unveraendert) — Reuse."
    Write-Host "Bereit: $Container @ 127.0.0.1:$DbPort, DB $DbName."
    return
}

# --- Rebuild: DROP/CREATE -> Schema (1-3) -> util (4) -> Seed ---
Write-Host "Baue Test-DB $DbName neu (Schema + Config-Seed) ..."

# (1) DROP/CREATE gegen die Maintenance-DB 'postgres'
$env:PGDATABASE = 'postgres'
$maintPath = Join-Path $env:TEMP "dbtest_maint_$PID.sql"
try {
    $maint = @"
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DbName' AND pid<>pg_backend_pid();
DROP DATABASE IF EXISTS $DbName;
CREATE DATABASE $DbName ENCODING 'UTF8' LOCALE 'C.UTF-8' TEMPLATE template0;
"@
    [System.IO.File]::WriteAllText($maintPath, $maint, $Utf8NoBom)
    $r = Invoke-Native psql @('--no-psqlrc','-v','ON_ERROR_STOP=1','-f',$maintPath)
    if ($r.Code -ne 0) { throw "Neuanlage der Test-DB (DROP/CREATE) fehlgeschlagen:$($r.Output -join "`n")" }
} finally {
    Remove-Item $maintPath -Force -ErrorAction SilentlyContinue
}

# (2) Phasen 1-3 (Baseline-Inits -> V__ -> R__) via db_apply (zielt auf dieses Docker-Test-Postgres).
#     Paket-generisch (WS-0 career): Core ZUERST (Inits/V/R), dann jedes Nicht-Core-Paket alphabetisch;
#     so existieren alle Core-Tabellen vor den paket-R__-Functions (phase-major, kein check_function_bodies-Bruch).
#     Ledger-Eigentum leitet db_apply aus dem Pfad ab (packages/<pkg>/...). Spiegelt provision.sh/seed_data.sh.
#     Nur Globs aufnehmen, die wirklich Dateien matchen (career hat z. B. keine V/R -> nicht in -Migrations/-Repeatable).
$applyFiles = [System.Collections.ArrayList]@('packages\core\db\*.sql')
$applyMigs  = [System.Collections.ArrayList]@('packages\core\db\migrations')
$applyReps  = [System.Collections.ArrayList]@('packages\core\db\migrations\R__*.sql')
foreach ($pkgDir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | Where-Object { $_.Name -ne 'core' } | Sort-Object Name)) {
    $n   = $pkgDir.Name
    $dbd = Join-Path $pkgDir.FullName 'db'
    if (-not (Test-Path $dbd)) { continue }
    if (Get-ChildItem $dbd -Filter '*.sql' -File -ErrorAction SilentlyContinue) { [void]$applyFiles.Add("packages\$n\db\*.sql") }
    $migd = Join-Path $dbd 'migrations'
    if (Get-ChildItem $migd -Filter 'V*.sql'   -File -ErrorAction SilentlyContinue) { [void]$applyMigs.Add("packages\$n\db\migrations") }
    if (Get-ChildItem $migd -Filter 'R__*.sql' -File -ErrorAction SilentlyContinue) { [void]$applyReps.Add("packages\$n\db\migrations\R__*.sql") }
}
& "$PSScriptRoot\db_apply.ps1" -File $applyFiles.ToArray() -Migrations $applyMigs.ToArray() -Repeatable $applyReps.ToArray()

# (3) Phase 4: util-Haertung + Read-Only-Rollen (NACH den R__-Views/Functions)
& "$PSScriptRoot\db_apply.ps1" -File 'packages\core\db\util\util_harden_db_security.sql','packages\core\db\util\util_create_core_ro.sql','packages\core\db\util\util_create_context_ro.sql'

# (3b) Per-Paket-Rollen + Isolation (D10): fuer JEDES Nicht-Core-Paket die engen <pkg>_rw/<pkg>_ro
#      (schema-scoped) + das core_ro-Lesefenster auf <pkg> — NACH allen Paket-Objekten (P10) UND NACH
#      util_create_core_ro. Paket-generisch (WS-0 career), spiegelt provision.sh/apply_schema.sh Phase 4.
$rolesPath = Join-Path $env:TEMP "dbtest_roles_$PID.sql"
try {
    $roleTpl = @'
DO $$ DECLARE r jsonb; BEGIN
  r := core.fn_provision_package_roles(jsonb_build_object('package','__PKG__'));
  IF NOT (r->>'ok')::bool THEN RAISE EXCEPTION 'fn_provision_package_roles(__PKG__) failed: %', r; END IF;
END $$;
'@
    $roleBlocks = New-Object System.Collections.Generic.List[string]
    foreach ($pkgDir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | Where-Object { $_.Name -ne 'core' } | Sort-Object Name)) {
        if (-not (Test-Path (Join-Path $pkgDir.FullName 'manifest.json'))) { continue }
        $roleBlocks.Add($roleTpl.Replace('__PKG__', $pkgDir.Name))
    }
    $rolesSql = "\set ON_ERROR_STOP on`n" + ($roleBlocks -join "`n")
    [System.IO.File]::WriteAllText($rolesPath, $rolesSql, $Utf8NoBom)
    $env:PGDATABASE = $DbName
    $r = Invoke-Native psql @('--no-psqlrc','-v','ON_ERROR_STOP=1','-f',$rolesPath)
    if ($r.Code -ne 0) { throw "Paket-Rollen-Provisioning fehlgeschlagen: $($r.Output -join "`n")" }
} finally {
    Remove-Item $rolesPath -Force -ErrorAction SilentlyContinue
}

# (4) Config-Store-Seed (ai_models ZUERST -> der core.config-Modell-Trigger referenziert model_key).
#     Pure-SQL-UPSERT mit derselben Semantik wie seed_data.sh _seed_ai_models/_seed_package_config (driftfrei;
#     core.config ueber DIESELBE fn core.fn_config_seed wie der Installer — conffile-Regel an EINER Stelle).
$aiJson  = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\seed\ai_models.json'), $Utf8NoBom)
# WS4a: Config lebt jetzt paket-besessen in den manifest.json .config-Bloecken (config.json retired).
# Flach in {category,key,value,description,summary,package}-Zeilen ueber ALLE Manifeste (driftfrei zu seed_data.sh _seed_package_config).
$cfgRows = New-Object System.Collections.ArrayList
foreach ($pkgDir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory)) {
    $mfPath = Join-Path $pkgDir.FullName 'manifest.json'
    if (-not (Test-Path $mfPath)) { continue }
    $mf = [System.IO.File]::ReadAllText($mfPath, $Utf8NoBom) | ConvertFrom-Json
    if ($null -eq $mf.config) { continue }
    foreach ($cat in $mf.config.PSObject.Properties) {
        if ($cat.Name -eq '_comment') { continue }
        foreach ($k in $cat.Value.PSObject.Properties) {
            if ($k.Name -eq '_comment') { continue }
            # type/minimum/maximum/managed_by wie seed_data.sh (fehlend -> '' -> fn_config_seed-Default)
            [void]$cfgRows.Add([ordered]@{ category = $cat.Name; key = $k.Name; value = [string]$k.Value.value; description = [string]$k.Value.description; summary = [string]$k.Value.summary; package = $mf.name
                type = [string]$k.Value.type; minimum = [string]$k.Value.minimum; maximum = [string]$k.Value.maximum; managed_by = [string]$k.Value.managed_by })
        }
    }
}
$cfgJson = ConvertTo-Json -InputObject @($cfgRows) -Depth 6 -Compress
$seedPath = Join-Path $env:TEMP "dbtest_seed_$PID.sql"
try {
    $seedSql = @"
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode)
SELECT e->>'model_key', e->>'provider', e->>'n8n_model_id', (e->>'selector_index')::int, e->>'mode'
FROM jsonb_array_elements(`$__boot_ai__`$$aiJson`$__boot_ai__`$::jsonb) e
ON CONFLICT (model_key) DO UPDATE SET provider=EXCLUDED.provider, n8n_model_id=EXCLUDED.n8n_model_id, selector_index=EXCLUDED.selector_index, mode=EXCLUDED.mode;
SELECT core.fn_config_seed(e)
FROM jsonb_array_elements(`$__boot_cfg__`$$cfgJson`$__boot_cfg__`$::jsonb) e;
COMMIT;
"@
    [System.IO.File]::WriteAllText($seedPath, $seedSql, $Utf8NoBom)
    $env:PGDATABASE = $DbName
    $r = Invoke-Native psql @('--no-psqlrc','-v','ON_ERROR_STOP=1','-f',$seedPath)
    if ($r.Code -ne 0) { throw "Config-Store-Seed (ai_models/config) fehlgeschlagen: $($r.Output -join "`n")" }
} finally {
    Remove-Item $seedPath -Force -ErrorAction SilentlyContinue
}

# (5) State speichern
New-Item -ItemType Directory -Force -Path (Split-Path $StateFile) | Out-Null
$state = [ordered]@{ hash = $currentHash; container_id = $containerId; built_at = (Get-Date -Format 'o') }
[System.IO.File]::WriteAllText($StateFile, ($state | ConvertTo-Json), $Utf8NoBom)

Write-Host "Test-DB $DbName gebaut. Bereit: $Container @ 127.0.0.1:$DbPort."
