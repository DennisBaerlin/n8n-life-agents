#Requires -Version 5.1
# prop_test_lint.ps1 -- hartes Commit-Gate: jede fn, die per UPDATE eine Tabelle aendert, aus der Termine, Fristen oder
# Betraege abgeleitet werden (Liste in scripts/lib/prop_test_coverage.ps1), wird in mindestens einem Eigenschafts-Test
# tests/db/**/test_prop_*.sql aufgerufen. Grund: ein Test, der nach dem Schreiben nur die geschriebene Spalte prueft,
# sieht keinen Fehler zwischen einer schreibenden und einer lesenden fn (verlorener oder doppelter Termin, falsche Summe
# der Vorschau). Der Eigenschafts-Test aendert den Datensatz und fragt danach die lesende Seite, ueber mehrere
# Kombinationen.
#
# Zweite Regel, gleiche Fehlerklasse: ein Funktionsname steht in genau einer Datei. Init-Dateien laufen bei jedem Einspielen,
# eine R__ nur bei geaendertem Inhalt; derselbe Name in einer Init und einer R__ (oder in zwei R__) ueberschreibt sich je
# nach Reihenfolge still, und eine der lesenden Sichten rechnet dann mit der falschen Definition.
#
# Geprueft wird der Aufruf, nicht die Guete des Tests: ob der Test wirklich vorher/nachher vergleicht, liest das Review.
# Ausnahmeliste tests/util/prop_test_allowlist.json [{fn, reason}]: nur schrumpfend. Ein Eintrag ohne Grund, fuer eine fn
# mit Test oder fuer eine fn ohne beobachtetes UPDATE ist ein Fehler.
#
# Aufruf: .\scripts\prop_test_lint.ps1 [-Verbose] [-Root <Baum>]   (-Root nur fuer den Selbsttest)
# Selbsttest: scripts/dev/prop_test_lint_test.ps1. Kein Docker, kein Netz. Exit-Code = Anzahl Fehler.
param([switch]$Verbose, [string]$Root)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = git -C $PSScriptRoot rev-parse --show-toplevel }
. (Join-Path $PSScriptRoot 'lib\prop_test_coverage.ps1')
$u8 = New-Object System.Text.UTF8Encoding($false)

$watched = Get-PropWatchedFns -Root $Root
$tested = @(Get-PropTestedFns -Root $Root)
$allow = @{}
$allowPath = Join-Path $Root 'tests\util\prop_test_allowlist.json'
if (Test-Path $allowPath) {
    foreach ($e in @(([System.IO.File]::ReadAllText($allowPath, $u8) | ConvertFrom-Json))) {
        if ($e.fn) { $allow[([string]$e.fn).ToLowerInvariant()] = [string]$e.reason }
    }
}
$gap = Compare-PropGap -Watched $watched -Tested $tested -Allow $allow
$r = [pscustomobject]@{ Errors = @(@($gap.Errors) + @(Get-FnDefinitionDuplicates -Root $Root)) }
foreach ($m in $r.Errors) { Write-Host "  [FAIL] $m" -ForegroundColor Red }
$covered = @($watched.Keys | Where-Object { $tested -contains $_ }).Count
if ($Verbose) {
    foreach ($fn in ($watched.Keys | Sort-Object)) {
        $state = if ($tested -contains $fn) { 'Test' } elseif ($allow.ContainsKey($fn)) { 'Ausnahme' } else { 'fehlt' }
        Write-Host ("  {0,-9} {1}  ({2})" -f $state, $fn, $watched[$fn])
    }
}
if ($r.Errors.Count -eq 0) {
    Write-Host "prop_test_lint OK ($($watched.Count) aendernde fns: $covered mit Eigenschafts-Test, $($allow.Count) auf der Ausnahmeliste)" -ForegroundColor Green
} else {
    Write-Host "prop_test_lint: $($r.Errors.Count) Fehler" -ForegroundColor Red
}
exit $r.Errors.Count
