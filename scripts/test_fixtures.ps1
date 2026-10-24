#Requires -Version 5.1
# Fixture-Verifikation der Routing-Suite (Tier 2) aus der Single-Source tests/fixtures/fixtures.json.
#
# Die Routing-Cases (finance_cases.json) referenzieren benannte Entitaeten (DKB Giro, VWCE,
# Baufinanzierung ING, ...). Fehlen sie (z. B. nach util_reset_user_data), failen ~23 Cases "leer",
# obwohl der Agent korrekt nachfragt. Dieses Skript ist die EINE Existenz-Pruefung der Suite:
# scripts/n8n_test.ps1 ruft '-Verify' als Pre-Flight, statt eine zweite Namensliste zu fuehren.
# Den vollen fn_create_*-Payload haelt der Seed tests/fixtures/util_seed_test_fixtures.sql; doc_lint
# erzwingt Manifest-subset-Seed (jede hier gepruefte Entitaet wird dort auch angelegt).
#
# Usage:
#   .\scripts\test_fixtures.ps1 -Verify    # (Default) prueft Existenz in der DB
#   .\scripts\test_fixtures.ps1 -List      # druckt die Manifest-Namen
#
# Exit-Code (-Verify):  0 = alle vorhanden  ·  1 = welche fehlen (Liste + Seed-Hinweis)
#                       2 = nicht pruefbar (kein Test-Substrat — bootstrap_test_n8n.ps1 zuerst)
param([switch]$List, [switch]$Verify)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot  = git -C $PSScriptRoot rev-parse --show-toplevel

$manifestPath = Join-Path $RepoRoot 'tests\fixtures\fixtures.json'
$manifest = [System.IO.File]::ReadAllText($manifestPath, $Utf8NoBom) | ConvertFrom-Json

if ($List) {
    foreach ($f in $manifest.fixtures) { Write-Host $f.name }
    exit 0
}

# Default = Verify
# --- SQL aus dem Manifest bauen (EINE Existenz-Pruefung; gibt fehlende Labels als CSV zurueck) ---
function Esc([string]$s) { return ($s -replace "'", "''") }
$clauses = @()
foreach ($f in $manifest.fixtures) {
    $label = Esc $f.name
    switch ($f.check.type) {
        'name' {
            $tbl = $f.check.table; $col = $f.check.column; $val = Esc $f.check.value
            $clauses += "SELECT '$label' AS name WHERE NOT EXISTS (SELECT 1 FROM $tbl t WHERE lower(t.$col)=lower('$val'))"
        }
        'isin' {
            $tbl = $f.check.table; $col = $f.check.column; $val = Esc $f.check.value
            $clauses += "SELECT '$label' AS name WHERE NOT EXISTS (SELECT 1 FROM $tbl t WHERE t.$col='$val')"
        }
        'family_person' {
            $fn = Esc $f.check.first_name
            $clauses += "SELECT '$label' AS name WHERE NOT EXISTS (SELECT 1 FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') p WHERE c.name='family' AND lower(p->>'first_name')='$fn')"
        }
        default { throw "Unbekannter check.type '$($f.check.type)' fuer Fixture '$($f.name)'." }
    }
}
$sql = "SELECT string_agg(m.name, ', ') FROM (`n" + ($clauses -join "`n  UNION ALL ") + "`n) m"

# --- Pruefung gegen die DB der ephemeren n8n-Test-Instanz (raus aus Prod) ---
# Die Fixtures liegen in der Container-DB (von n8n_test, mock_route_test und e2e_test ueber Initialize-AgentTestState -> util_seed_test_fixtures.sql geseedet);
# der Zugriff laeuft ueber docker exec runuser-psql (Invoke-TestN8nPsql) statt Prod-PG_*.
. "$PSScriptRoot\dev\test_n8n_state.ps1"
$conn = Get-TestN8nConnection -AllowMissing
if (-not $conn) {
    Write-Host "[WARN] Fixture-Verify nicht pruefbar (kein Test-Substrat — bootstrap_test_n8n.ps1 zuerst)." -ForegroundColor Yellow
    exit 2
}
$res = Invoke-TestN8nPsql -Container $conn.Container -PsqlArgs @('-q', '-t', '-A', '-c', $sql)
$missing = ($res.Output | Where-Object { $_ -is [string] -and $_ -ne '' } | Select-Object -Last 1)
if ($res.Code -ne 0) {
    Write-Host "[WARN] Fixture-Verify: psql-Fehler: $($res.Output -join ' ')" -ForegroundColor Yellow
    exit 2
}
if (-not [string]::IsNullOrWhiteSpace("$missing")) {
    Write-Host "Routing-Fixtures fehlen: $missing" -ForegroundColor Red
    Write-Host "  -> Substrat neu bauen (seedet automatisch): .\scripts\dev\bootstrap_test_n8n.ps1 -Reset" -ForegroundColor Yellow
    exit 1
}
Write-Host "Fixture-Verify: alle $($manifest.fixtures.Count) Routing-Fixtures vorhanden." -ForegroundColor Green
exit 0
