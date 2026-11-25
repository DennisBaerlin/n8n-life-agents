#Requires -Version 5.1
# seed_reconcile_lint.ps1 -- die Tabellen, die der Seed per _seed_reconcile bzw. _seed_reconcile_unowned aufraeumt, sind genau die
# Tabellen, die der DB-Test test_seed_reconcile_registry_unreferenced prueft (hartes Gate). Eine Tabelle, die der Seeder neu
# aufraeumt und der Test nicht kennt, bekaeme einen Fremdschluessel oder DELETE-Trigger unbemerkt und kippte den ganzen Seed.
# Quelle der Wahrheit sind die Aufrufe in provisioning/lib/seed_data.sh; die Liste im Test wird dagegen gelesen.
# Aufruf: .\scripts\seed_reconcile_lint.ps1 [-Root <Baum>]   (-Root nur fuer scripts/dev/seed_reconcile_lint_test.ps1)
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Docker.
param([string]$Root)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = git -C $PSScriptRoot rev-parse --show-toplevel }
$Root = (Resolve-Path $Root).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

$seed = Join-Path $Root 'provisioning/lib/seed_data.sh'
$test = Join-Path $Root 'tests/db/core/test_seed_reconcile_registry_unreferenced.sql'
foreach ($f in $seed, $test) { if (-not (Test-Path $f)) { Fail "fehlt: $f"; Write-Host "seed_reconcile_lint: $fails Fehler" -ForegroundColor Red; exit $fails } }

# Aufrufe im Seeder: die Definitionen (`_seed_reconcile() {`) und Kommentarzeilen zaehlen nicht.
$called = New-Object 'System.Collections.Generic.SortedSet[string]'
foreach ($line in [System.IO.File]::ReadAllLines($seed, $u8)) {
    if ($line.TrimStart().StartsWith('#')) { continue }
    $m = [regex]::Match($line, '^\s*_seed_reconcile(?:_unowned)?\s+(core\.[a-z_]+)\s')
    if ($m.Success) { [void]$called.Add($m.Groups[1].Value) }
}

# Liste im Test: die Zeichenketten 'core.<name>' im ARRAY[...] der Deklaration v_tabs.
$sql = [System.IO.File]::ReadAllText($test, $u8)
$decl = [regex]::Match($sql, '(?s)v_tabs\s+REGCLASS\[\]\s*:=\s*ARRAY\[(.*?)\]')
$listed = New-Object 'System.Collections.Generic.SortedSet[string]'
if (-not $decl.Success) { Fail "Liste v_tabs im Test nicht gefunden: $test" }
else { foreach ($m in [regex]::Matches($decl.Groups[1].Value, "'(core\.[a-z_]+)'")) { [void]$listed.Add($m.Groups[1].Value) } }

if ($called.Count -eq 0) { Fail 'keine _seed_reconcile-Aufrufe in seed_data.sh gefunden (Muster geaendert?)' }
foreach ($t in $called) { if (-not $listed.Contains($t)) { Fail "$t wird vom Seeder aufgeraeumt, fehlt aber in der Liste des DB-Tests (test_seed_reconcile_registry_unreferenced.sql)." } }
foreach ($t in $listed) { if (-not $called.Contains($t)) { Fail "$t steht in der Liste des DB-Tests, der Seeder raeumt sie aber nicht mehr auf -> aus der Liste nehmen." } }

if ($fails -eq 0) { Write-Host "seed_reconcile_lint: OK ($($called.Count) Tabelle(n))" -ForegroundColor Green }
else { Write-Host "seed_reconcile_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
