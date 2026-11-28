#Requires -Version 5.1
# backup_migration_lint.ps1 -- Schema-Aenderungen an gesicherten Tabellen brechen aeltere Sicherungen nicht still (hartes Gate).
# Eine Sicherung ist ein reiner Daten-Abzug (pg_dump -a) im Aufbau ihrer Version. Entfernt oder benennt eine spaetere Version
# eine Spalte oder Tabelle um, lehnt der Restore (provisioning/lib/backup_cli.sh, _bkp_schema_check) die aeltere Sicherung ab,
# ausser das Manifest des Pakets erklaert die Aenderung im backup-Block:
#   removed_columns {"<tabelle>": {"<spalte>": "<Migration>"}}  -> der Restore laesst die Spalte weg;
#   renamed_columns {"<tabelle>": {"<alt>": "<neu>"}}           -> der Restore spielt den Wert in die neue Spalte;
#   removed_tables  {"<tabelle>": "<Migration>"}               -> der Restore laesst die Tabelle weg.
# (<tabelle> ohne Schema = Schema des Pakets.) Der Lint findet in packages/*/db/*.sql und packages/*/db/migrations/V*.sql jedes
# ALTER TABLE … DROP COLUMN / RENAME COLUMN / RENAME TO und DROP TABLE auf einer gesicherten Tabelle (schema_dump-Schema
# ohne exclude_tables, full_tables, filtered_tables) und verlangt den passenden Eintrag. Daten verschieben (neue Spalte
# fuellen, alte entfernen) erklaert ein Eintrag nicht: Regel in .claude/rules/sql.md *Schema-Aenderungs-Regeln*.
# Altbestand vor dieser Regel steht in scripts/build/backup_migration_allowlist.json (nur schrumpfen; aeltere Sicherungen
# brechen dort weiter fail-closed ab). Nicht erkannt: DDL per EXECUTE format(…).
# Aufruf: .\scripts\backup_migration_lint.ps1 [-Root <Baum>] [-Verbose]   (-Root nur fuer scripts/dev/backup_migration_lint_test.ps1)
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Docker.
param([string]$Root, [switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = git -C $PSScriptRoot rev-parse --show-toplevel }
$Root = (Resolve-Path $Root).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }
function Rel([string]$p) { return $p.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/') }
function Get-Prop($o, [string]$n) { if ($null -ne $o -and $o.PSObject.Properties[$n]) { return $o.PSObject.Properties[$n].Value }; return $null }
function Get-Keys($o) { if ($null -eq $o) { return @() }; return @($o.PSObject.Properties | Where-Object { $_.Name -ne '_comment' } | ForEach-Object { $_.Name }) }

# --- Manifeste: gesicherte Tabellen und erklaerte Aenderungen ---
$dumpSchemas = @{}; $excluded = @{}; $backed = @{}; $removedCols = @{}; $renamedCols = @{}; $removedTabs = @{}
function Qual([string]$t, [string]$schema) { if ($t.Contains('.')) { return $t }; return "$schema.$t" }
foreach ($mf in @(Get-ChildItem (Join-Path $Root 'packages') -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'manifest.json' } | Where-Object { Test-Path $_ })) {
    $m = [System.IO.File]::ReadAllText($mf, $u8) | ConvertFrom-Json
    $b = Get-Prop $m 'backup'; if ($null -eq $b) { continue }
    $schema = [string](Get-Prop $m 'schema')
    if ((Get-Prop $b 'schema_dump') -eq $true -and $schema) { $dumpSchemas[$schema] = $true }
    foreach ($t in @(Get-Prop $b 'exclude_tables')) { if ($t) { $excluded[(Qual $t $schema)] = $true } }
    foreach ($t in @(Get-Prop $b 'full_tables')) { if ($t) { $backed[(Qual $t $schema)] = $true } }
    foreach ($t in Get-Keys (Get-Prop $b 'filtered_tables')) { $backed[(Qual $t $schema)] = $true }
    $rc = Get-Prop $b 'removed_columns'
    foreach ($t in Get-Keys $rc) { foreach ($c in Get-Keys (Get-Prop $rc $t)) { $removedCols["$(Qual $t $schema).$c"] = $true } }
    $rn = Get-Prop $b 'renamed_columns'
    foreach ($t in Get-Keys $rn) { $tm = Get-Prop $rn $t; foreach ($c in Get-Keys $tm) { $renamedCols["$(Qual $t $schema).$c"] = [string](Get-Prop $tm $c) } }
    foreach ($t in Get-Keys (Get-Prop $b 'removed_tables')) { $removedTabs[(Qual $t $schema)] = $true }
}
function Test-Backed([string]$q) {
    if ($excluded.ContainsKey($q)) { return $false }
    if ($backed.ContainsKey($q)) { return $true }
    return $dumpSchemas.ContainsKey($q.Split('.')[0])
}

# --- Altbestand ---
$allowPath = Join-Path $Root 'scripts/build/backup_migration_allowlist.json'
$allow = @{}
if (Test-Path $allowPath) {
    # ForEach-Object rollt aus: PS 5.1 liefert ein JSON-Array aus ConvertFrom-Json als ein Objekt, '[]' sonst als ein leerer Eintrag.
    foreach ($e in @([System.IO.File]::ReadAllText($allowPath, $u8) | ConvertFrom-Json | ForEach-Object { $_ })) {
        if (-not $e.reason) { Fail "backup_migration_allowlist.json: Eintrag $($e.file) $($e.object) ohne reason" }
        $allow["$($e.file)|$($e.object)"] = $false
    }
}

# --- Scan ---
$id = '[a-z_][a-z0-9_]*'
$rxAlter = [regex]"(?is)\bALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?($id)\.($id)\b(.*)$"
$rxDropCol = [regex]"(?i)\bDROP\s+COLUMN\s+(?:IF\s+EXISTS\s+)?($id)"
$rxRenCol = [regex]"(?i)\bRENAME\s+COLUMN\s+($id)\s+TO\s+($id)"
$rxRenTab = [regex]"(?i)\bRENAME\s+TO\s+($id)"
$rxDropTab = [regex]"(?is)\bDROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?((?:$id\.$id\s*,\s*)*$id\.$id)"
$files = @()
foreach ($pkg in @(Get-ChildItem (Join-Path $Root 'packages') -Directory -ErrorAction SilentlyContinue)) {
    $db = Join-Path $pkg.FullName 'db'
    if (Test-Path $db) { $files += @(Get-ChildItem $db -File -Filter '*.sql') }
    $mig = Join-Path $db 'migrations'
    if (Test-Path $mig) { $files += @(Get-ChildItem $mig -File -Filter 'V*.sql') }
}
$found = 0
function Check([string]$rel, [string]$obj, [bool]$declared, [string]$need) {
    $script:found++
    $k = "$rel|$obj"
    if ($script:allow.ContainsKey($k)) { $script:allow[$k] = $true; return }
    if ($declared) { if ($Verbose) { Write-Host "    [OK] $rel $obj" -ForegroundColor DarkGray }; return }
    Fail "${rel}: $obj in einer gesicherten Tabelle ohne Manifest-Eintrag. Aeltere Sicherungen liessen sich sonst nicht mehr einspielen -> im backup-Block des Pakets $need eintragen (Kopf von scripts/backup_migration_lint.ps1)."
}
foreach ($f in $files) {
    $rel = Rel $f.FullName
    $sql = [System.IO.File]::ReadAllText($f.FullName, $u8)
    $sql = [regex]::Replace($sql, '(?s)/\*.*?\*/', ' ')
    $sql = [regex]::Replace($sql, '--[^\r\n]*', ' ')
    foreach ($stmt in $sql.Split(';')) {
        $a = $rxAlter.Match($stmt)
        if ($a.Success) {
            $q = "$($a.Groups[1].Value.ToLower()).$($a.Groups[2].Value.ToLower())"
            if (Test-Backed $q) {
                $rest = $a.Groups[3].Value
                foreach ($m in $rxDropCol.Matches($rest)) {
                    $o = "$q.$($m.Groups[1].Value.ToLower())"
                    Check $rel $o $removedCols.ContainsKey($o) "removed_columns"
                }
                foreach ($m in $rxRenCol.Matches($rest)) {
                    $o = "$q.$($m.Groups[1].Value.ToLower())"; $new = $m.Groups[2].Value.ToLower()
                    Check $rel $o ($renamedCols.ContainsKey($o) -and $renamedCols[$o] -eq $new) "renamed_columns (-> $new)"
                }
                if (-not $rxRenCol.IsMatch($rest) -and $rxRenTab.IsMatch($rest)) { Check $rel $q $removedTabs.ContainsKey($q) "removed_tables" }
            }
        }
        $d = $rxDropTab.Match($stmt)
        if ($d.Success) {
            foreach ($t in ($d.Groups[1].Value -split '\s*,\s*')) {
                $q = $t.Trim().ToLower()
                if (Test-Backed $q) { Check $rel $q $removedTabs.ContainsKey($q) "removed_tables" }
            }
        }
    }
}
foreach ($k in @($allow.Keys)) { if (-not $allow[$k]) { Fail "backup_migration_allowlist.json: Eintrag $k verwaist (kein Fund mehr) -> entfernen" } }

if ($fails -eq 0) { Write-Host "backup_migration_lint: OK ($found Aenderung(en) an gesicherten Tabellen, $($allow.Count) Altbestand)" -ForegroundColor Green }
else { Write-Host "backup_migration_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
