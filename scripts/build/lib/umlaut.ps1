#Requires -Version 5.1
# umlaut.ps1 — die EINE Ersatz-Umlaut-Erkennung fuer nutzer-sichtbare deutsche Texte (Textkatalog-Feature).
# Dot-gesourct von locale_lint.ps1 (de-Katalog), workflow_lint.ps1 (sichtbare Telegram-Felder) und contract_lint.ps1
# (sichtbare Manifest-Felder + SQL-Literale der R__-fns). Owner-Entscheid 2026-10-21: sichtbare Texte mit echten
# Umlauten ("pruefen" -> "prüfen"); Kommentare/Stickies/Testbeschreibungen duerfen ASCII bleiben.
#
# Regel: ein Wort (Buchstabenfolge) mit 'ae'/'oe'/'ue' ist verdaechtig, AUSSER es passt auf ein Muster der gepflegten
# Ausnahme-Liste scripts/build/umlaut_allowlist.json (echte Woerter: neue/Steuer/Dauer/aktuell/Quelle/zuerst, englische
# Woerter wie value/true/queue/does, Eigennamen wie Michael). Bewusst Muster statt Stamm-Liste: eine Stamm-Liste
# (pruef/fuer/...) uebersieht jeden nicht gelisteten Stamm still (Plan-Review #14); eine neue echte Ausnahme ist eine
# Zeile in der JSON-Liste (reviewter Edit), ein uebersehener Ersatz ist ein roter Lint.
$script:UmlautAllow = $null
function Get-UmlautAllowPatterns {
    if ($null -eq $script:UmlautAllow) {
        $root = git -C $PSScriptRoot rev-parse --show-toplevel
        $f = Join-Path $root 'scripts\build\umlaut_allowlist.json'
        $j = [System.IO.File]::ReadAllText($f, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
        $script:UmlautAllow = @($j.patterns | ForEach-Object { [regex]::new("^(?:$_)$", 'IgnoreCase') }) +
                              @($j.contains | ForEach-Object { [regex]::new($_, 'IgnoreCase') })
    }
    $script:UmlautAllow
}
# Find-UmlautSubstitute <text> -> die verdaechtigen Woerter (eindeutig, in Fundreihenfolge).
function Find-UmlautSubstitute([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $allow = Get-UmlautAllowPatterns
    $hits = [System.Collections.Generic.List[string]]::new()
    # Token = Buchstaben, Ziffern, Unterstrich: ein Token mit Ziffer oder '_' ist ein Bezeichner/eine ID (Hex-UUID,
    # Config-Key, Slug) und nie ein sichtbares deutsches Wort -> nie melden (sonst wuerde "...31ae6f" ein "ae").
    foreach ($m in [regex]::Matches($Text, '[A-Za-z0-9_ÄÖÜäöüß]+')) {
        $w = $m.Value
        if ($w -match '[0-9_]') { continue }
        if ($w -cmatch '[a-zäöüß][A-ZÄÖÜ]') { continue }   # Grossbuchstabe mitten im Wort = ID/camelCase, kein deutsches Wort
        if ($w -notmatch '(?i)ae|oe|ue') { continue }
        $ok = $false
        foreach ($rx in $allow) { if ($rx.IsMatch($w)) { $ok = $true; break } }
        if (-not $ok -and -not $hits.Contains($w)) { $hits.Add($w) }
    }
    return @($hits)
}
# Get-JsStringLiteral <expr> -> die String-Literale eines n8n-/JS-Ausdrucks (Inhalt ohne Quotes); Knoten-Referenzen
# $('Name') zaehlen nicht (Knotennamen sind nicht sichtbar).
function Get-JsStringLiteral([string]$Expr) {
    $e = [regex]::Replace($Expr, "\$\(\s*'[^']*'\s*\)", '')
    $e = [regex]::Replace($e, '\$\(\s*"[^"]*"\s*\)', '')
    @([regex]::Matches($e, "'((?:[^'\\]|\\.)*)'|""((?:[^""\\]|\\.)*)""") | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } })
}
