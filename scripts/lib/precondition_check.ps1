#Requires -Version 5.1
# =====================================================================================================
# precondition_check.ps1 — Regel "Fall mit setup_sql braucht precondition_sql" (mock_lint C7)
#
# Ein Fall mit `setup_sql` legt Zustand an, auf den sich seine Erwartung stuetzt; `precondition_sql` (Mechanik:
# docs/reference/tests.md) belegt kostenlos, dass die Vorbereitung ihn auch wirklich herstellt. Ohne das Feld zeigt eine
# unvollstaendige Vorbereitung erst im bezahlten Lauf als Agent-Fehler. Die Regel ist fail-closed: jeder Fall mit
# `setup_sql` traegt eine Vorbedingung, die den DB-Zustand liest (SELECT/EXISTS); `true` oder `1 = 1` belegt nichts und zaehlt
# nicht. Ausnahmen nur ueber tests/util/precondition_allowlist.json (Schluessel <Datei>|<Fall-id>, Wert = Grund); die Liste
# darf nur schrumpfen (ein Eintrag fuer einen Fall mit Feld oder ohne setup_sql ist ein Fehler).
# Rein statisch (kein Docker, kein Netz); dot-gesourced von scripts/mock_lint.ps1, Selbsttest scripts/dev/precondition_lint_test.ps1.
# =====================================================================================================

# Get-PreconditionFinding -Cases <Fall-Objekte> -File <rel. Pfad> -Allow <Hashtable Schluessel -> Grund>
# -> Liste von Fehlertexten (leer = sauber). Die Allowlist-Stale-Pruefung macht Get-PreconditionAllowlistStale.
function Get-PreconditionFinding {
    param([Parameter(Mandatory)][object[]]$Cases, [Parameter(Mandatory)][string]$File, [hashtable]$Allow = @{})
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($c in $Cases) {
        if (-not $c.PSObject.Properties['setup_sql'] -or -not "$($c.setup_sql)".Trim()) { continue }
        $key = "$File|$($c.id)"
        if ($Allow.ContainsKey($key)) { continue }
        $pre = if ($c.PSObject.Properties['precondition_sql']) { "$($c.precondition_sql)".Trim() } else { '' }
        if (-not $pre) { $out.Add("$key hat setup_sql, aber kein precondition_sql (belegt, dass die Vorbereitung den Zustand der Erwartung herstellt)."); continue }
        if ($pre -notmatch '(?i)\b(SELECT|EXISTS)\b') { $out.Add("$key precondition_sql liest keinen DB-Zustand (kein SELECT/EXISTS): '$pre'.") }
    }
    return $out.ToArray()
}

# Get-PreconditionAllowlistStale -Entries <alle Faelle als Liste von @{File;Case}> -Allow <Hashtable> -> Fehlertexte fuer Eintraege, die entfallen koennen.
function Get-PreconditionAllowlistStale {
    param([Parameter(Mandatory)][object[]]$Entries, [hashtable]$Allow = @{})
    $needs = @{}
    foreach ($e in $Entries) {
        $c = $e.Case
        $hasSetup = $c.PSObject.Properties['setup_sql'] -and "$($c.setup_sql)".Trim()
        $hasPre = $c.PSObject.Properties['precondition_sql'] -and "$($c.precondition_sql)".Trim()
        if ($hasSetup -and -not $hasPre) { $needs["$($e.File)|$($c.id)"] = $true }
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($k in ($Allow.Keys | Sort-Object)) {
        if (-not $needs.ContainsKey($k)) { $out.Add("Allowlist-Eintrag '$k' ist ueberholt (Fall hat precondition_sql oder kein setup_sql mehr). Eintrag aus tests/util/precondition_allowlist.json entfernen (Ratchet).") }
    }
    return $out.ToArray()
}
