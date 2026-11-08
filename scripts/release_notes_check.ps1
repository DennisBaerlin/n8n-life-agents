#Requires -Version 5.1
# release_notes_check.ps1 - prueft die Tag-Nachricht eines Releases, BEVOR das Tag gesetzt wird (ein von CI abgelehntes
# Tag verbraucht die Versionsnummer: Tags sind per Ruleset unverrueckbar). release.yml ruft dasselbe Skript - die EINE
# Fassung der Regel.
#
# Regel (Gegenstueck zur Anzeige: core.fn_release_intro(body, lang), die Update-Karte im Chat):
#   - Einleitungsabsatz (englisch, = Kurzfassung fuer 'en'): vorhanden, <= 300 Zeichen, ohne '<!--'.
#   - Fuer JEDE Systemsprache ausser 'en' ein Marker  <!-- summary:<code> ... -->  (nach einer Leerzeile, hinter dem
#     Einleitungsabsatz), nicht leer, <= 300 Zeichen. Die Sprachen kommen aus dem Core-Manifest (languages.list, dieselbe
#     Quelle wie core.ui_languages) - kommt eine Sprache dazu, verlangt das Skript sie automatisch.
#   - Jeder Marker: bekannter Code, hoechstens einmal, kein '-->' im Text, vollstaendig in den ersten 4000 Zeichen
#     (der jq-Auszug in update_runner.sh kuerzt den Text dort).
# Zeichen werden als Codepoints gezaehlt (wie length() in PostgreSQL), nicht als UTF-16-Einheiten.
# Zwei Parser, ein Massstab: die Bereinigung bildet die Reihenfolge der DB-fn nach; gemeinsame Faelle liegen in
# tests/fixtures/release_notes/ (scripts/dev/release_notes_check_test.ps1) und inline in tests/db/core/test_fn_release_card.sql.
#
# Usage:
#   .\scripts\release_notes_check.ps1 -File <tag-nachricht.md>          # vor `git tag -a --cleanup=whitespace -F <datei>`
#   .\scripts\release_notes_check.ps1 -File <datei> -Print de           # nur die bereinigte Kurzfassung ausgeben (en = Intro)
# Exit-Code: 0 = in Ordnung, 1 = Regel verletzt (deutsche Meldung samt Beispiel).
param(
    [Parameter(Mandatory = $true)][string]$File,
    [string]$Print,
    [string]$Manifest
)

$ErrorActionPreference = 'Stop'
$MaxChars = 300
$ExtractChars = 4000

if (-not $Manifest) { $Manifest = Join-Path (Join-Path $PSScriptRoot '..') 'packages/core/manifest.json' }

function Get-CodepointCount([string]$s) {
    return $s.Length - [regex]::Matches($s, '[\uDC00-\uDFFF]').Count
}

# Bereinigung wie core.fn_release_intro: Link-Syntax -> Text, Hervorhebung raus, Leerraum zusammenfassen.
function Clear-Markdown([string]$s) {
    $s = [regex]::Replace($s, '\[([^\]]*)\]\([^)]*\)', '$1')
    $s = [regex]::Replace($s, '(\*\*|__|`)', '')
    return ([regex]::Replace($s, '\s+', ' ')).Trim()
}

# Einleitungsabsatz wie in der DB-fn: fuehrende Leerzeilen weg, Ende bei Leerzeile / '#' / '---'.
function Get-IntroRaw([string]$body) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($body -split "`n")) {
        $line = $l.Trim(" ")
        if ($line -eq '') { if ($parts.Count -gt 0) { break } else { continue } }
        if ($line -match '^#' -or $line -match '^-{3,}$') { break }
        $parts.Add($line)
    }
    return ($parts -join ' ')
}

$bytes = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $File).ProviderPath, [Text.UTF8Encoding]::new($false))
$body = $bytes.Replace("`r", '')

$markerRx = [regex]'(?s)<!--\s*?summary:([a-z]{2,3})\s+?(.*?)-->'
$markers = @{}
foreach ($m in $markerRx.Matches($body)) {
    $code = $m.Groups[1].Value
    if (-not $markers.ContainsKey($code)) { $markers[$code] = @() }
    $markers[$code] += , $m
}

if ($Print) {
    $txt = ''
    if ($Print -ne 'en' -and $markers.ContainsKey($Print)) { $txt = Clear-Markdown $markers[$Print][0].Groups[2].Value }
    if ($txt -eq '') { $txt = Clear-Markdown (Get-IntroRaw $body) }   # wie die DB-fn: leerer/fehlender Marker -> Einleitungsabsatz
    if ((Get-CodepointCount $txt) -gt $MaxChars) {
        # Kuerzen wie die DB-fn: 299 Codepoints, rechts trimmen, '…'
        $cut = New-Object System.Text.StringBuilder
        $cp = 0
        for ($i = 0; $i -lt $txt.Length -and $cp -lt ($MaxChars - 1); $i++) {
            [void]$cut.Append($txt[$i])
            if (-not [char]::IsHighSurrogate($txt[$i])) { $cp++ }
        }
        $txt = $cut.ToString().TrimEnd() + [string][char]0x2026
    }
    Write-Output $txt
    exit 0
}

$errors = New-Object System.Collections.Generic.List[string]
$example = @'
Beispiel (Aufbau der Tag-Nachricht):

    English intro, 1-3 sentences: what changes for users.

    <!-- summary:de
    Deutsche Kurzfassung, 1-3 Saetze.
    -->

    <!-- summary:ko
    ... (eine Kurzfassung je Systemsprache ausser en)
    -->

    ## Changes
    - ...
'@

# Sprachen aus dem Manifest (dieselbe Quelle wie core.ui_languages).
$langs = @((Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json).languages.list | ForEach-Object { $_.code })
if ($langs.Count -eq 0) { Write-Host "release_notes_check: keine Sprachen in $Manifest gefunden."; exit 1 }

# Einleitungsabsatz
$introRaw = Get-IntroRaw $body
$intro = Clear-Markdown $introRaw
if ($intro -eq '') { $errors.Add('Die Tag-Nachricht braucht einen englischen Einleitungsabsatz (1-3 Saetze vor der ersten Ueberschrift).') }
elseif ($introRaw.Contains('<!--')) { $errors.Add('Der Einleitungsabsatz enthaelt "<!--". Marker stehen NACH einer Leerzeile hinter dem Absatz.') }
elseif ((Get-CodepointCount $intro) -gt $MaxChars) { $errors.Add("Der Einleitungsabsatz ist $(Get-CodepointCount $intro) Zeichen lang (max. $MaxChars).") }

# Klammern: ein '-->' im Kommentartext beendet den Marker zu frueh -> mehr '-->' als '<!--'.
$open = [regex]::Matches($body, '<!--').Count
$close = [regex]::Matches($body, '-->').Count
if ($open -ne $close) { $errors.Add('Anzahl von "<!--" und "-->" passt nicht (ein "-->" im Marker-Text beendet den Kommentar zu frueh).') }

foreach ($code in ($markers.Keys | Sort-Object)) {
    if ($markers[$code].Count -gt 1) { $errors.Add("Marker summary:$code kommt mehrfach vor.") }
    if ($langs -notcontains $code) { $errors.Add("Marker summary:$code - Sprachcode nicht im Manifest (languages: $($langs -join ', ')).") }
    $m = $markers[$code][0]
    if ($m.Groups[2].Value.Contains('<!--')) { $errors.Add("Marker summary:$code enthaelt ein weiteres `"<!--`".") }
    $endIdx = Get-CodepointCount $body.Substring(0, $m.Index + $m.Length)
    if ($endIdx -gt $ExtractChars) { $errors.Add("Marker summary:$code endet nach Zeichen $ExtractChars - der Update-Check sieht nur die ersten $ExtractChars Zeichen. Marker direkt hinter den Einleitungsabsatz setzen.") }
}

foreach ($code in $langs) {
    if ($code -eq 'en') { continue }
    if (-not $markers.ContainsKey($code)) { $errors.Add("Marker summary:$code fehlt (Pflicht fuer jede Systemsprache ausser en).") ; continue }
    $txt = Clear-Markdown $markers[$code][0].Groups[2].Value
    $n = Get-CodepointCount $txt
    if ($txt -eq '') { $errors.Add("Marker summary:$code ist leer.") }
    elseif ($n -gt $MaxChars) { $errors.Add("Marker summary:$code ist $n Zeichen lang (max. $MaxChars).") }
}

if ($errors.Count -gt 0) {
    Write-Host "release_notes_check: $($errors.Count) Fund(e) in $File"
    foreach ($e in $errors) { Write-Host "  - $e" }
    Write-Host ''
    Write-Host $example
    exit 1
}
Write-Host "release_notes_check: in Ordnung (Sprachen: $($langs -join ', '))."
exit 0
