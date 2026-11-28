#Requires -Version 5.1
# Fehl- und Gutfaelle von scripts/backup_migration_lint.ps1 in einem Wegwerf-Baum (-Root): eine Migration, die in einer
# gesicherten Tabelle eine Spalte oder Tabelle entfernt oder umbenennt, muss ohne Manifest-Eintrag rot werden; mit Eintrag,
# in einer ausgeschlossenen oder ungesicherten Tabelle und auf der Altbestands-Liste gruen; ein verwaister Listen-Eintrag rot.
# Kein Docker, kein git.
# Usage: .\scripts\dev\backup_migration_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = Join-Path $PSScriptRoot '..\backup_migration_lint.ps1'
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0

function New-Tree([hashtable]$Files) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('bml_' + [guid]::NewGuid().ToString('N'))
    foreach ($rel in $Files.Keys) {
        $p = Join-Path $root $rel
        New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
        [System.IO.File]::WriteAllText($p, $Files[$rel], $u8)
    }
    return $root
}

function Test-Case([string]$Name, [hashtable]$Files, [bool]$ExpectRed, [string]$ExpectText) {
    $root = New-Tree $Files
    try {
        $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lint -Root $root) -join "`n"
        $red = $LASTEXITCODE -ne 0
        $ok = ($red -eq $ExpectRed) -and (-not $ExpectText -or $out -match [regex]::Escape($ExpectText))
        if ($ok) { Write-Host "  PASS $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL $Name (Exit $LASTEXITCODE): $out" -ForegroundColor Red; $script:fails++ }
    } finally { Remove-Item -Recurse -Force $root }
}

# Pfade zusammengesetzt: doc_lint liest ausgeschriebene Repo-Pfade als Verweise auf echte Dateien.
$P = 'packages'
$allow = 'scripts/build/backup_migration_allowlist.json'
function Mf([string]$Name, [string]$Schema, [string]$Backup) { return "{ `"name`": `"$Name`", `"schema`": `"$Schema`", `"backup`": $Backup }" }
$finDump = Mf 'fin' 'fin' '{ "schema_dump": true, "exclude_tables": ["staging"] }'
$core = Mf 'core' 'agent' '{ "full_tables": ["agent.plans"], "filtered_tables": { "agent.ctx": "true" } }'
$empty = '[]'

Test-Case 'Spalte entfernt ohne Eintrag ist rot' @{
    "$P/fin/manifest.json" = $finDump; "$P/core/manifest.json" = $core; $allow = $empty
    "$P/fin/db/migrations/V005__x.sql" = "ALTER TABLE fin.accounts DROP COLUMN IF EXISTS holder;`n"
} $true 'fin.accounts.holder'
Test-Case 'mehrere Spalten in einem ALTER, eine ohne Eintrag ist rot' @{
    "$P/fin/manifest.json" = (Mf 'fin' 'fin' '{ "schema_dump": true, "removed_columns": { "loans": { "a": "V005" } } }')
    "$P/core/manifest.json" = $core; $allow = $empty
    "$P/fin/db/migrations/V005__x.sql" = "ALTER TABLE fin.loans`n    DROP COLUMN IF EXISTS a,`n    DROP COLUMN IF EXISTS b;`n"
} $true 'fin.loans.b'
Test-Case 'Spalte entfernt mit Eintrag ist gruen' @{
    "$P/fin/manifest.json" = (Mf 'fin' 'fin' '{ "schema_dump": true, "removed_columns": { "accounts": { "holder": "V005" } } }')
    "$P/core/manifest.json" = $core; $allow = $empty
    "$P/fin/db/migrations/V005__x.sql" = "ALTER TABLE fin.accounts DROP COLUMN IF EXISTS holder;`n"
} $false ''
Test-Case 'Umbenennung ohne Eintrag ist rot' @{
    "$P/fin/manifest.json" = $finDump; "$P/core/manifest.json" = $core; $allow = $empty
    "$P/fin/db/migrations/V006__x.sql" = "DO `$`$ BEGIN`n  ALTER TABLE fin.loans RENAME COLUMN due TO period_end;`nEND `$`$;`n"
} $true 'fin.loans.due'
Test-Case 'Umbenennung mit Eintrag ist gruen' @{
    "$P/fin/manifest.json" = (Mf 'fin' 'fin' '{ "schema_dump": true, "renamed_columns": { "loans": { "due": "period_end" } } }')
    "$P/core/manifest.json" = $core; $allow = $empty
    "$P/fin/db/migrations/V006__x.sql" = "ALTER TABLE fin.loans RENAME COLUMN due TO period_end;`n"
} $false ''
Test-Case 'Tabelle entfernt ohne Eintrag ist rot' @{
    "$P/fin/manifest.json" = $finDump; "$P/core/manifest.json" = $core; $allow = $empty
    "$P/fin/db/migrations/V007__x.sql" = "DROP TABLE IF EXISTS fin.goal_holdings CASCADE;`n"
} $true 'fin.goal_holdings'
Test-Case 'Tabelle entfernt mit Eintrag ist gruen' @{
    "$P/fin/manifest.json" = (Mf 'fin' 'fin' '{ "schema_dump": true, "removed_tables": { "goal_holdings": "V007" } }')
    "$P/core/manifest.json" = $core; $allow = $empty
    "$P/fin/db/migrations/V007__x.sql" = "DROP TABLE IF EXISTS fin.goal_holdings CASCADE;`n"
} $false ''
Test-Case 'gesicherte Core-Tabelle (full_tables) ohne Eintrag ist rot' @{
    "$P/fin/manifest.json" = $finDump; "$P/core/manifest.json" = $core; $allow = $empty
    "$P/core/db/agent.plans_init.sql" = "ALTER TABLE agent.plans DROP COLUMN IF EXISTS old;`n"
} $true 'agent.plans.old'
Test-Case 'gefilterte Core-Tabelle ohne Eintrag ist rot' @{
    "$P/fin/manifest.json" = $finDump; "$P/core/manifest.json" = $core; $allow = $empty
    "$P/core/db/migrations/V009__x.sql" = "ALTER TABLE agent.ctx DROP COLUMN IF EXISTS old;`n"
} $true 'agent.ctx.old'
Test-Case 'ausgeschlossene Tabelle ist frei' @{
    "$P/fin/manifest.json" = $finDump; "$P/core/manifest.json" = $core; $allow = $empty
    "$P/fin/db/migrations/V005__x.sql" = "ALTER TABLE fin.staging DROP COLUMN IF EXISTS raw;`n"
} $false ''
Test-Case 'ungesicherte Tabelle ist frei' @{
    "$P/fin/manifest.json" = $finDump; "$P/core/manifest.json" = $core; $allow = $empty
    "$P/core/db/migrations/V010__x.sql" = "ALTER TABLE agent.ai_models DROP COLUMN IF EXISTS tier;`n"
} $false ''
Test-Case 'Kommentar zaehlt nicht' @{
    "$P/fin/manifest.json" = $finDump; "$P/core/manifest.json" = $core; $allow = $empty
    "$P/fin/db/migrations/V005__x.sql" = "-- ALTER TABLE fin.accounts DROP COLUMN holder;`nSELECT 1;`n"
} $false ''
Test-Case 'R__-Datei zaehlt nicht' @{
    "$P/fin/manifest.json" = $finDump; "$P/core/manifest.json" = $core; $allow = $empty
    "$P/fin/db/migrations/R__fn_x.sql" = "ALTER TABLE fin.accounts DROP COLUMN IF EXISTS holder;`n"
} $false ''
Test-Case 'Altbestand auf der Liste ist gruen' @{
    "$P/fin/manifest.json" = $finDump; "$P/core/manifest.json" = $core
    $allow = '[ { "file": "packages/fin/db/migrations/V005__x.sql", "object": "fin.accounts.holder", "reason": "test" } ]'
    "$P/fin/db/migrations/V005__x.sql" = "ALTER TABLE fin.accounts DROP COLUMN IF EXISTS holder;`n"
} $false ''
Test-Case 'verwaister Listen-Eintrag ist rot' @{
    "$P/fin/manifest.json" = $finDump; "$P/core/manifest.json" = $core
    $allow = '[ { "file": "packages/fin/db/migrations/V005__x.sql", "object": "fin.accounts.holder", "reason": "test" } ]'
} $true 'verwaist'

if ($fails -eq 0) { Write-Host 'PASS backup_migration_lint_test' -ForegroundColor Green } else { Write-Host "FAIL backup_migration_lint_test ($fails)" -ForegroundColor Red }
exit $fails
