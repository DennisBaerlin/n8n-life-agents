#Requires -Version 5.1
# Bausteine von scripts/prop_test_lint.ps1 (dot-sourced, auch vom Selbsttest scripts/dev/prop_test_lint_test.ps1):
# welche fn aendert eine Tabelle, aus der Termine, Fristen oder Betraege abgeleitet werden, und welche davon ruft ein
# Eigenschafts-Test (tests/db/**/test_prop_*.sql) auf; dazu Get-FnDefinitionDuplicates (derselbe fn-Name in mehreren
# SQL-Dateien, die nicht immer zusammen laufen). Alle Funktionen nehmen -Root, damit der Selbsttest sie in einem
# Wegwerf-Baum fahren kann.

# Tabellen, deren Zeilen eine lesende Sicht in Termine, Fristen oder Summen umrechnet. Eine fn, die eine davon per
# UPDATE aendert, kann fuer sich richtig schreiben und trotzdem die Vorschau verfaelschen.
$script:PropWatchedTables = @(
    'finance.recurring_payments',
    'finance.savings_goals',
    'finance.loans',
    'finance.account_interest_rates',
    'estate.cases'
)

function Get-PropCodeText([string]$Sql) {
    # Zeilenkommentare zaehlen nicht: ein fn-Name oder UPDATE im Kopf-Kommentar ist kein Aufruf.
    return (($Sql -split "`r?`n") | ForEach-Object { $_ -replace '--.*$', '' }) -join "`n"
}

function Get-PropWatchedFns([string]$Root) {
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $out = @{}
    $pkgRoot = Join-Path $Root 'packages'
    if (-not (Test-Path $pkgRoot)) { return $out }
    foreach ($f in (Get-ChildItem -Path $pkgRoot -Recurse -File -Filter 'R__fn_*.sql' | Where-Object { $_.FullName -match '[\\/]db[\\/]migrations[\\/]' })) {
        $code = Get-PropCodeText ([System.IO.File]::ReadAllText($f.FullName, $u8))
        $tables = @($script:PropWatchedTables | Where-Object { $code -match ('(?i)\bUPDATE\s+(ONLY\s+)?' + [regex]::Escape($_) + '\b') })
        if ($tables.Count -eq 0) { continue }
        foreach ($m in [regex]::Matches($code, '(?i)CREATE\s+(OR\s+REPLACE\s+)?FUNCTION\s+([a-z_]+\.fn_[a-z0-9_]+)\s*\(')) {
            $out[$m.Groups[2].Value.ToLowerInvariant()] = ($tables -join ', ')
        }
    }
    return $out
}

function Get-FnDefinitionDuplicates([string]$Root) {
    # Derselbe Funktionsname in zwei SQL-Dateien: Init laeuft bei jedem Einspielen, eine R__ nur bei geaendertem Inhalt.
    # Zwei Dateien mit derselben Signatur ueberschreiben sich deshalb je nach Reihenfolge still. Ueberladungen in einer
    # Datei sind erlaubt (ein Name, eine Datei).
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $byName = @{}
    $pkgRoot = Join-Path $Root 'packages'
    if (-not (Test-Path $pkgRoot)) { return @() }
    foreach ($f in (Get-ChildItem -Path $pkgRoot -Recurse -File -Filter '*.sql' | Where-Object { $_.FullName -match '[\\/]db[\\/]' })) {
        $code = Get-PropCodeText ([System.IO.File]::ReadAllText($f.FullName, $u8))
        foreach ($m in [regex]::Matches($code, '(?i)CREATE\s+(OR\s+REPLACE\s+)?FUNCTION\s+([a-z_]+\.[a-z0-9_]+)\s*\(')) {
            $name = $m.Groups[2].Value.ToLowerInvariant()
            if (-not $byName.ContainsKey($name)) { $byName[$name] = @{} }
            $byName[$name][$f.Name] = $true
        }
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($name in ($byName.Keys | Sort-Object)) {
        # Mehrere Init-Dateien laufen immer alle und in fester Reihenfolge (gleicher Trigger-Helfer je Init): kein Fehler.
        $files = @($byName[$name].Keys | Sort-Object)
        $rep = @($files | Where-Object { $_ -like 'R__*' }).Count
        if ($rep -ge 2 -or ($rep -ge 1 -and $files.Count -gt $rep)) {
            $out.Add("$name ist in mehreren Dateien definiert, die nicht immer zusammen laufen: $($files -join ', ') (ein Name, eine Datei)")
        }
    }
    return @($out)
}

function Get-PropTestedFns([string]$Root) {
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $set = @{}
    $testRoot = Join-Path $Root 'tests\db'
    if (-not (Test-Path $testRoot)) { return @() }
    foreach ($f in (Get-ChildItem -Path $testRoot -Recurse -File -Filter 'test_prop_*.sql')) {
        $code = Get-PropCodeText ([System.IO.File]::ReadAllText($f.FullName, $u8))
        foreach ($m in [regex]::Matches($code, '(?i)\b([a-z_]+\.fn_[a-z0-9_]+)\s*\(')) { $set[$m.Groups[1].Value.ToLowerInvariant()] = $true }
    }
    return @($set.Keys | Sort-Object)
}

function Compare-PropGap([hashtable]$Watched, [string[]]$Tested, [hashtable]$Allow) {
    $errors = New-Object System.Collections.Generic.List[string]
    $testedSet = @{}
    foreach ($t in $Tested) { $testedSet[$t] = $true }
    foreach ($fn in ($Watched.Keys | Sort-Object)) {
        if ($testedSet.ContainsKey($fn)) { continue }
        if ($Allow.ContainsKey($fn)) {
            if ([string]::IsNullOrWhiteSpace([string]$Allow[$fn])) { $errors.Add("$fn steht ohne Grund auf der Ausnahmeliste") }
            continue
        }
        $errors.Add("$fn aendert $($Watched[$fn]) und kommt in keinem tests/db/**/test_prop_*.sql vor: Eigenschafts-Test ergaenzen, der die lesende Seite vor und nach der Aenderung vergleicht (oder Eintrag mit Grund in tests/util/prop_test_allowlist.json)")
    }
    foreach ($fn in ($Allow.Keys | Sort-Object)) {
        if (-not $Watched.ContainsKey($fn)) { $errors.Add("Ausnahmeliste: $fn aendert keine beobachtete Tabelle mehr oder existiert nicht (Eintrag streichen)") }
        elseif ($testedSet.ContainsKey($fn)) { $errors.Add("Ausnahmeliste: $fn hat inzwischen einen Eigenschafts-Test (Eintrag streichen, die Liste schrumpft nur)") }
    }
    return [pscustomobject]@{ Errors = @($errors) }
}
