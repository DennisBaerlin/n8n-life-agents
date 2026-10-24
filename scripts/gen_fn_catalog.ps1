#Requires -Version 5.1
# fn-Katalog-Generator (Hardening-Phase Session 2) -- nach dem Vorbild build.ps1 -CatalogOnly/-VerifyCatalog.
#
# Parst die packages/*/db/migrations/R__fn_*.sql (Header-Kommentar + CREATE FUNCTION-Signaturen + direkt
# gelesene jsonb-Keys) und generiert den tracked Katalog docs/fn_catalog.md -- EINE Datei
# fuer Kontrakt-Lookups statt Datei-Suche ueber alle fn-Dateien. Source of Truth bleiben die
# SQL-Dateien; der Katalog ist ein generierter Index (NIE hand-editieren).
#
# Deterministisch (ordinal sortiert, LF-normalisiert, keine Zeitstempel) -> Drift-Gate per
# String-Vergleich, analog dem Capabilities-Catalog:
#   .\scripts\gen_fn_catalog.ps1            # Katalog (neu) schreiben
#   .\scripts\gen_fn_catalog.ps1 -Verify    # kein Write; Exit 1 wenn tracked != frisch generiert
#                                           #   (hartes Gate: prek-Hook `fn-catalog`)
param([switch]$Verify)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot  = git -C $PSScriptRoot rev-parse --show-toplevel
# Flyway-Repeatables: die Tool-Functions liegen als R__fn_*.sql (R__ = repeatable, fn_ = Function),
# paket-bewusst unter packages/<pkg>/db/migrations/ (alle Pakete; kein flacher db/-Rest mehr).
# Der Katalog-Name = Dateiname ohne R__-Praefix (siehe ConvertFrom-FnFile/$byName);
# fn_catalog.md bleibt EIN global aggregiertes Artefakt.
$FnGlobs   = @((Join-Path $RepoRoot 'packages\*\db\migrations\R__fn_*.sql'))
$OutPath   = Join-Path $RepoRoot 'docs\fn_catalog.md'

# ORDINAL-Sort (kultur-unabhaengig -> stabiler Vergleich auf jeder Culture; analog lib/catalog.ps1)
function Sort-Ordinal([string[]]$Items) {
    if ($null -eq $Items -or $Items.Count -eq 0) { return @() }
    $a = [string[]]$Items
    [Array]::Sort($a, [System.StringComparer]::Ordinal)
    return $a
}

# --- Eine fn-Datei parsen: Header (Titel-Tag + Beschreibung), Signaturen, jsonb-Reads ---
function ConvertFrom-FnFile([string]$Path) {
    # R__-Praefix (Flyway-Repeatable) abstreifen -> Katalog-Name = fn_<name> (wie die Titelzeile im File).
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path) -replace '^R__', ''
    $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))

    # Fuehrender Kommentar-Block: Ruler-/Pfad-Zeilen droppen, Titelzeile "-- fn_x (TAG)" -> Tag,
    # Rest = Beschreibung (zum Einzeiler kollabiert).
    $tag = ''; $titleSeen = $false; $descLines = @()
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -notmatch '^\s*--') { break }
        if ($line -match '^\s*--\s*=+\s*$') { continue }
        if ($line -match '^\s*--\s*packages/[a-z0-9_]+/db/(functions|migrations)/') { continue }
        if (-not $titleSeen -and $descLines.Count -eq 0 -and
            $line -match ('^\s*--\s*' + [regex]::Escape($name) + '\b\s*(.*)$')) {
            $tag = $Matches[1].Trim(); $titleSeen = $true; continue
        }
        $descLines += ($line -replace '^\s*--\s?', '')
    }
    $desc = (($descLines -join ' ') -replace '\s+', ' ').Trim()

    # Signaturen: alle CREATE FUNCTION im File (Konvention: eine fn pro Datei; Overloads moeglich).
    $sigs = @()
    foreach ($m in [regex]::Matches($text, '(?is)CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+([a-z0-9_]+\.[a-z0-9_]+)\s*\((.*?)\)\s*RETURNS\s+(.+?)\s+(?:LANGUAGE|AS)\b')) {
        $fnArgs = ($m.Groups[2].Value -replace '\s+', ' ').Trim()
        $ret    = ($m.Groups[3].Value -replace '\s+', ' ').Trim()
        $ret    = ($ret -replace '\s+(IMMUTABLE|STABLE|VOLATILE|STRICT|SECURITY\s+DEFINER|PARALLEL\s+\w+)\b.*$', '').Trim()
        $sigs  += ('{0}({1}) -> {2}' -f $m.Groups[1].Value, $fnArgs, $ret)
    }
    $sigs = @($sigs | Select-Object -Unique)

    # Direkt im File gelesene jsonb-Keys (Ueberapproximation, gleiche Regexes wie contract_lint;
    # transitive fn-in-fn-Reads prueft contract_lint selbst).
    $keys = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in [regex]::Matches($text, "->>?\s*'([A-Za-z0-9_]+)'")) { [void]$keys.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($text, "\?\s*'([A-Za-z0-9_]+)'"))   { [void]$keys.Add($m.Groups[1].Value) }

    return @{ Name = $name; Tag = $tag; Desc = $desc; Sigs = $sigs; Keys = (Sort-Ordinal @($keys)) }
}

# --- Katalog generieren (deterministisch -> stabiler Vergleich) ---
$files = @(Get-ChildItem $FnGlobs -File -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) { throw "Keine R__fn_*.sql unter packages/*/db/migrations gefunden." }

# --- DEFINER-Hygiene-Gate (Post-WS3-Härtung, arch-challenge dünner-B): jede SECURITY-DEFINER-fn MUSS
#     (1) search_path pinnen (CVE-2018-1058) UND (2) REVOKE ... FROM PUBLIC haben (Least-Privilege).
#     NUR diese 2 Assertions (etablierter Standard: Splinter 0011 + CVE-2018-1058) — KEIN 5-Punkt-Protokoll,
#     kein Header-Marker (BACKLOG). Geprueft wird JE FUNKTIONSKOPF (CREATE … FUNCTION bis AS $), nach Entfernen der
#     Zeilen-Kommentare: nur ein Kopf mit SECURITY DEFINER zaehlt, und nur SEIN search_path (eine INVOKER-fn derselben
#     Datei bleibt unberuehrt).
#     (1b) der gepinnte search_path endet auf pg_temp — sonst durchsucht PostgreSQL das temporaere Schema der
#     Sitzung bei Tabellen ZUERST (PG-Doku CREATE FUNCTION, "Writing SECURITY DEFINER Functions Safely").
$hygiene = @()
foreach ($f in $files) {
    $t = [System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom)
    $code = [regex]::Replace($t, '--[^\r\n]*', '')
    $miss = @(); $hasDefiner = $false
    foreach ($hdr in [regex]::Matches($code, '(?is)\bCREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\b.*?\bAS\s+\$')) {
        if ($hdr.Value -notmatch '(?i)\bSECURITY\s+DEFINER\b') { continue }
        $hasDefiner = $true
        $pin = [regex]::Match($hdr.Value, '(?i)\bSET\s+search_path\s*=\s*([a-z_]+(?:\s*,\s*[a-z_]+)*)')
        if (-not $pin.Success) { $miss += 'SET search_path (CVE-2018-1058)' }
        elseif (($pin.Groups[1].Value -split '\s*,\s*')[-1] -ne 'pg_temp') { $miss += "pg_temp als letztes search_path-Element ($($pin.Groups[1].Value))" }
    }
    if ($hasDefiner -and $code -notmatch '(?im)\bREVOKE\b.*\bFROM\s+PUBLIC\b') { $miss += 'REVOKE ... FROM PUBLIC' }
    if ($miss.Count -gt 0) { $hygiene += ('  {0}: fehlt {1}' -f $f.Name, ($miss -join ' + ')) }
}
if ($hygiene.Count -gt 0) {
    Write-Host 'DEFINER-Hygiene-Verstoss (jede SECURITY DEFINER-fn braucht search_path-Pin mit pg_temp zuletzt + REVOKE FROM PUBLIC):' -ForegroundColor Red
    $hygiene | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
    Write-Host '  Fix: SET search_path = pg_catalog[,...], pg_temp in der fn + REVOKE ALL ON FUNCTION <fn> FROM PUBLIC; danach Grant an die Rolle.' -ForegroundColor Yellow
    exit 1
}

# Key = <name>|<paket> (Phase B): gleichnamige fns verschiedener Pakete (z. B. die per-Paket-Registry-fns
# fn_advisor_review / fn_clear_e2e_data) sind legitim und bekommen je einen eigenen Eintrag -- vorher keyte
# der Katalog nach Basename und verschluckte sie still.
$byName = @{}
foreach ($f in $files) {
    $pkg = Split-Path (Split-Path (Split-Path (Split-Path $f.FullName -Parent) -Parent) -Parent) -Leaf
    $byName[(($f.BaseName -replace '^R__', '') + '|' + $pkg)] = $f.FullName
}
if ($byName.Count -ne $files.Count) {
    throw "fn-Katalog: $($byName.Count) Eintraege fuer $($files.Count) Dateien -- Key-Kollision."
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# fn-Katalog (generiert)')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('> GENERIERT von `scripts/gen_fn_catalog.ps1` aus `packages/*/db/migrations/R__fn_*.sql` -- NIE hand-editieren.')
[void]$sb.AppendLine('> Je Function: Signatur(en), direkt im File gelesene jsonb-Keys (`->>`/`?`-Zugriffe;')
[void]$sb.AppendLine('> Ueberapproximation inkl. Reads auf jsonb-Spalten -- transitive fn-in-fn-Reads prueft')
[void]$sb.AppendLine('> `scripts/contract_lint.ps1`) und der Header-Kommentar als Einzeiler. Source of Truth')
[void]$sb.AppendLine('> bleibt die jeweilige SQL-Datei. Nach jeder fn-Aenderung neu generieren + committen;')
[void]$sb.AppendLine('> Drift ist hartes Gate (prek-Hook `fn-catalog` -> `gen_fn_catalog.ps1 -Verify`).')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("Umfang: $($files.Count) fn-Dateien.")
[void]$sb.AppendLine('')

foreach ($n in (Sort-Ordinal @($byName.Keys))) {
    $e = ConvertFrom-FnFile $byName[$n]
    # Titel schema-qualifiziert (Schema aus der ersten Signatur; Fallback Paketname).
    $schema = ($n -split '\|')[1]
    if ($e.Sigs.Count -gt 0 -and $e.Sigs[0] -match '^([a-z0-9_]+)\.') { $schema = $Matches[1] }
    $title = "$schema.$($e.Name)"
    if ($e.Tag) { $title = "$title $($e.Tag)" }
    [void]$sb.AppendLine("## $title")
    if ($e.Sigs.Count -gt 0) {
        foreach ($s in $e.Sigs) { [void]$sb.AppendLine(('- `{0}`' -f $s)) }
    } else {
        [void]$sb.AppendLine('- (keine CREATE FUNCTION-Signatur erkannt)')
    }
    $keyStr = '--'
    if ($e.Keys.Count -gt 0) { $keyStr = ($e.Keys -join ', ') }
    [void]$sb.AppendLine("- jsonb-Keys: $keyStr")
    if ($e.Desc) { [void]$sb.AppendLine("- $($e.Desc)") }
    [void]$sb.AppendLine('')
}

$md = ($sb.ToString() -replace "`r`n", "`n").TrimEnd() + "`n"

# --- Verify (Drift-Gate) oder Write ---
if ($Verify) {
    $onDisk = ''
    if (Test-Path $OutPath) {
        $onDisk = (([System.IO.File]::ReadAllText($OutPath, $Utf8NoBom)) -replace "`r`n", "`n").TrimEnd() + "`n"
    }
    if ($onDisk -cne $md) {
        Write-Host "DRIFT: docs/fn_catalog.md != frisch generiert ($($files.Count) fn-Dateien)." -ForegroundColor Red
        $a = $md -split "`n"; $b = $onDisk -split "`n"
        $max = [Math]::Min($a.Count, $b.Count)
        for ($i = 0; $i -lt $max; $i++) {
            if ($a[$i] -cne $b[$i]) {
                Write-Host ("  Zeile {0}:`n    generiert: {1}`n    tracked:   {2}" -f ($i + 1), $a[$i], $b[$i]) -ForegroundColor Yellow
                break
            }
        }
        if ($a.Count -ne $b.Count) { Write-Host "  (Zeilenzahl: generiert $($a.Count) vs. tracked $($b.Count))" -ForegroundColor Yellow }
        Write-Host "  Fix: .\scripts\gen_fn_catalog.ps1 ausfuehren + committen." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "fn-Katalog OK: docs/fn_catalog.md == frisch generiert ($($files.Count) fn-Dateien)." -ForegroundColor Green
    exit 0
}

[System.IO.File]::WriteAllText($OutPath, $md, $Utf8NoBom)
Write-Host "docs/fn_catalog.md generiert ($($files.Count) fn-Dateien)." -ForegroundColor Green
exit 0
