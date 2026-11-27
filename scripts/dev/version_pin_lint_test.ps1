#Requires -Version 5.1
# Test von scripts/lib/version_pins.ps1 (doc_lint 11b): je Fall ein Wegwerf-Baum mit provision.sh (Quelle) und einer Datei.
# Rot: abweichende Version in Doku-Prosa, in einem Abbild-Namen im Code, in Workflow-YAML, Dockerfile und Installations-Pfad;
# veraltete oder unbegruendete Ausnahme; unlesbare Quelle. Gruen: gleiche Version, Kommentarzeile im Code, begruendete Ausnahme,
# Pruefstand in einem Kommentar, Modul-Name wie node:vm.
# Aufruf: .\scripts\dev\version_pin_lint_test.ps1     Exit-Code = Anzahl roter Faelle. Kein Docker, kein Netz.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '..\lib\version_pins.ps1')
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
$provision = "PG_VERSION=`"`${PG_VERSION:-17}`"`nN8N_VERSION=`"`${N8N_VERSION:-2.45.7}`"`nNODE_MAJOR=`"`${NODE_MAJOR:-24}`"`n"

# Run-Case <name> <Anzahl Meldungen> <Datei -> Inhalt> <Allowlist-Eintraege> <Teil der Meldung>
function Run-Case([string]$Name, [int]$Want, [hashtable]$Files, [string]$Allow = '', [string]$Says = '', [string]$Source = $provision) {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('vpl_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $all = @{ 'provisioning/provision.sh' = $Source; 'README.md' = "n8n 2.45.7 auf PostgreSQL 17 und Node.js 24`n"
              'scripts/ok.ps1' = "`$img = 'pgvector/pgvector:pg17'`n"; 'scripts/build/version_pin_allowlist.json' = "{ `"allow`": [ $Allow ] }" }   # lint-ignore: Fixture-Pfad
    foreach ($k in $Files.Keys) { $all[$k] = $Files[$k] }
    try {
        foreach ($rel in $all.Keys) {
            $p = Join-Path $dir $rel
            New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
            [System.IO.File]::WriteAllText($p, $all[$rel], $u8)
        }
        try { $got = @(Get-VersionPinIssues $dir) } catch { $got = @($_.Exception.Message) }
        $text = $got -join "`n"
        if ($got.Count -eq $Want -and (-not $Says -or $text.Contains($Says))) { Write-Host "  [PASS] $Name" }
        else { Write-Host "  [FAIL] $Name (erwartet $Want Meldung(en) '$Says', war $($got.Count)): $text" -ForegroundColor Red; $script:fails++ }
    } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
}

Run-Case 'alles auf dem Pin' 0 @{}
Run-Case 'Referenz-Doku nennt alte n8n-Version' 1 @{ 'docs/reference/x.md' = "laeuft auf n8n 2.44.4`n" } -Says "n8n-Version '2.44.4' != Pin '2.45.7'"   # lint-ignore: Fixture-Pfad
Run-Case 'CONTRIBUTING nennt altes PostgreSQL' 1 @{ 'CONTRIBUTING.md' = "winget (PostgreSQL 16, prek)`n" } -Says "PostgreSQL-Version '16'"
Run-Case 'Node in einer Sub-CLAUDE.md' 1 @{ 'packages/x/CLAUDE.md' = "Node 22 reicht`n" } -Says "Node.js-Version '22'"   # lint-ignore: Fixture-Pfad
Run-Case 'Node-Abbild eines Skripts' 1 @{ 'scripts/lint.ps1' = "`$img = 'node:20.18.0-alpine'`n" } -Says "scripts/lint.ps1:1: Node.js-Version '20'"   # lint-ignore: Fixture-Pfad
Run-Case 'psql-Pfad und winget-Paket' 1 @{ 'scripts/setup.ps1' = "`$bin = 'C:\Program Files\PostgreSQL\16\bin'`nInstall 'PostgreSQL.PostgreSQL.16'`n" } -Says "PostgreSQL-Version '16'"   # lint-ignore: Fixture-Pfad
Run-Case 'Test-Datenbank-Abbild' 1 @{ 'scripts/db.ps1' = "`$i = 'pgvector/pgvector:pg16'`n" } -Says "PostgreSQL-Version '16'"   # lint-ignore: Fixture-Pfad
Run-Case 'CI-Workflow mit altem Abbild' 1 @{ '.github/workflows/x.yml' = "      image: n8nio/n8n:2.44.4`n" } -Says "n8n-Version '2.44.4'"
Run-Case 'Dockerfile unter tests' 1 @{ 'tests/w/Dockerfile' = "FROM node:22-bookworm-slim`n" } -Says "Node.js-Version '22'"   # lint-ignore: Fixture-Pfad
Run-Case 'Kommentar im Code und Modul-Name zaehlen nicht' 0 @{ 'scripts/c.ps1' = "# frueher postgres:16 und node:20-alpine`nrequire('node:vm') # n8n 2.44.4`n" }   # lint-ignore: Fixture-Pfad
$entry = '{ "file": "docs/reference/x.md", "kind": "N8n", "version": "2.44.4", "count": 1, "reason": "Pruefstand" }'   # lint-ignore: Fixture-Pfad
Run-Case 'begruendeter frueherer Stand' 0 @{ 'docs/reference/x.md' = "geprueft auf 2.44.4`n" } -Allow $entry   # lint-ignore: Fixture-Pfad
Run-Case 'Ausnahme ohne Grund' 1 @{ 'docs/reference/x.md' = "geprueft auf 2.44.4`n" } -Allow ($entry -replace 'Pruefstand', '') -Says 'ohne Grund'   # lint-ignore: Fixture-Pfad
Run-Case 'zweite Nennung neben der Ausnahme' 1 @{ 'docs/reference/x.md' = "geprueft auf 2.44.4, laeuft auf 2.44.4`n" } -Allow $entry -Says '2x gefunden'   # lint-ignore: Fixture-Pfad
Run-Case 'veraltete Ausnahme' 1 @{} -Allow $entry -Says 'ORPHAN'
Run-Case 'neuer Pin: jede Nennung des alten wird gemeldet' 2 @{} -Source ($provision -replace 'PG_VERSION:-17', 'PG_VERSION:-18') -Says "PostgreSQL-Version '17' != Pin '18'"
Run-Case 'Quelle nicht lesbar' 1 @{} -Source "N8N_VERSION=2.45.7`n" -Says 'nicht lesbar'

if ($fails -eq 0) { Write-Host 'PASS version_pin_lint_test' -ForegroundColor Green } else { Write-Host "version_pin_lint_test: $fails rot" -ForegroundColor Red }
exit $fails
