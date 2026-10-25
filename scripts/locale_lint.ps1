#Requires -Version 5.1
# locale_lint.ps1 — Textkatalog fester Nutzertexte (packages/<pkg>/locales/<lang>.json, docs/package-contract.md §3.11).
# Vorbild i18n-tasks `health` (Rails): ein Katalog je Sprache, der CI-Lauf haelt sie vollstaendig und konsistent.
# Gepruefte Gesetze (hart, Exit-Code = Anzahl fehlgeschlagener Checks):
#   (1) Sprachliste: Core-Manifest languages.list — Code ^[a-z]{2}$, eindeutig, Eigenname + Intl-Locale + date_pattern gesetzt;
#       die in core:V027 vorab angelegten Codes sind Teil der Liste (V-Liste ⊆ Manifest).
#   (2) Je Paket mit locales/: GENAU eine <code>.json je Sprache der Liste (keine fehlt, keine fremde).
#   (3) Jede Datei ist ein flaches JSON-Objekt; Keys (ohne '_'-Kommentare) folgen <pkg>.<bereich>.<name>, Prefix ==
#       Paket; Werte sind nicht-leere Strings.
#   (4) Key-Paritaet: alle Sprachen eines Pakets haben exakt dieselben Keys.
#   (5) Platzhalter-Paritaet: je Key dieselbe Menge {name}-Platzhalter in allen Sprachen.
#   (6) Deutsch ohne Ersatz-Umlaute (scripts/build/lib/umlaut.ps1 + umlaut_allowlist.json).
#   (7) Pflicht-Keys aus Manifesten: je context_validators-Kontext <pkg>.facts.<ctx>.title (Titel der Fakten-Karte),
#       je monitor_acquisition_methods-Methode <pkg>.monitor_method.<m>; Core-Builtins core.monitor_method.{web_search,sql,none}.
#   (7b) Persona-Liste: Core-Manifest personas.list — Code ^[a-z_]+$, eindeutig, neutral enthalten, ord gesetzt; je Persona
#       core.persona.name.<code>; die in core:V031 vorab angelegten Codes sind Teil der Liste (V-Liste ⊆ Manifest).
#   (8) SQL-Text-Verweise: jedes Katalog-Key-Literal in packages/*/db/migrations/R__*.sql existiert im Katalog.
# Warnung (kein Fehler): Keys, deren Literal nirgends in Build-Defs/Workflows/SQL vorkommt (dynamisch zusammengesetzte
#   Keys — .enum.*, .facts.*, .monitor_method.*, core.persona.name.* — sind ausgenommen).
# Usage: .\scripts\locale_lint.ps1 [-Verbose]
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot  = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $RepoRoot 'scripts\build\lib\umlaut.ps1')

$script:failed = 0
function Check([string]$Name, [scriptblock]$Body) {
    $errs = @(& $Body)
    if ($errs.Count -eq 0) { Write-Host "  [PASS] $Name" -ForegroundColor Green; return }
    $script:failed++
    Write-Host "  [FAIL] $Name" -ForegroundColor Red
    foreach ($e in $errs) { Write-Host "    $e" -ForegroundColor Yellow }
}
function Read-Json([string]$Path) { [System.IO.File]::ReadAllText($Path, $Utf8NoBom) | ConvertFrom-Json }
function Get-Placeholders([string]$s) { @([regex]::Matches($s, '\{(\w+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) }

Write-Host ''
Write-Host 'locale_lint — Textkatalog (packages/<pkg>/locales/<lang>.json)'
Write-Host ('-' * 64)

$core  = Read-Json (Join-Path $RepoRoot 'packages\core\manifest.json')
$langs = @($core.languages.list)
$codes = @($langs | ForEach-Object { [string]$_.code })

Check 'Sprachliste: Core-Manifest languages.list (Code/Name/Locale, eindeutig, V027 ⊆ Liste)' {
    if ($langs.Count -eq 0) { 'Datei packages/core/manifest.json: languages.list fehlt oder ist leer' }
    foreach ($l in $langs) {
        if ("$($l.code)" -notmatch '^[a-z]{2}$') { "Code '$($l.code)' ist kein ISO-639-1-Code" }
        if ([string]::IsNullOrWhiteSpace("$($l.name)")) { "Sprache '$($l.code)': name (Eigenname) fehlt" }
        if ("$($l.locale)" -notmatch '^[a-z]{2}-[A-Z]{2}$') { "Sprache '$($l.code)': locale '$($l.locale)' ist kein Intl-Tag (z. B. de-DE)" }
        # Textkatalog Phase C: to_char-Muster fuer SQL-Dokumente (core.fn_fmt_date; Seed + CHECK in core.ui_languages)
        if ("$($l.date_pattern)" -notmatch '^(YYYY|MM|DD|[./ -])+$') { "Sprache '$($l.code)': date_pattern '$($l.date_pattern)' fehlt oder ist kein Datumsmuster (nur YYYY/MM/DD + Trenner)" }
        if ($null -eq $l.ord) { "Sprache '$($l.code)': ord fehlt" }
    }
    foreach ($d in @($codes | Group-Object | Where-Object Count -gt 1)) { "Code '$($d.Name)' doppelt" }
    $v = Get-ChildItem (Join-Path $RepoRoot 'packages\core\db\migrations') -Filter 'V*__ui_languages*.sql' -ErrorAction SilentlyContinue
    foreach ($f in $v) {
        foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom), "\(\s*'([a-z]{2})'\s*,")) {
            if ($codes -notcontains $m.Groups[1].Value) { "$($f.Name) legt '$($m.Groups[1].Value)' an, das nicht in languages.list steht" }
        }
    }
}

# Kataloge laden: $cat[pkg][lang] = hashtable key->text
$cat = [ordered]@{}
$loadErr = @()
foreach ($pdir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | Sort-Object Name)) {
    $ldir = Join-Path $pdir.FullName 'locales'
    if (-not (Test-Path $ldir)) { continue }
    $cat[$pdir.Name] = [ordered]@{}
    foreach ($f in (Get-ChildItem $ldir -File)) {
        $lang = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        if ($f.Extension -ne '.json') { $loadErr += "Datei packages/$($pdir.Name)/locales/$($f.Name): nur <code>.json erlaubt"; continue }
        try { $obj = Read-Json $f.FullName } catch { $loadErr += "Datei packages/$($pdir.Name)/locales/$($f.Name): kein gueltiges JSON ($_)"; continue }
        $h = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) {
            if ($p.Name.StartsWith('_')) { continue }
            $h[$p.Name] = $p.Value
        }
        $cat[$pdir.Name][$lang] = $h
    }
}

Check 'Dateien: je Paket mit locales/ genau eine <code>.json je Sprache der Liste' {
    $loadErr
    foreach ($pkg in $cat.Keys) {
        foreach ($c in $codes) { if (-not $cat[$pkg].Contains($c)) { "Datei packages/$pkg/locales/$c.json fehlt" } }
        foreach ($l in $cat[$pkg].Keys) { if ($codes -notcontains $l) { "Datei packages/$pkg/locales/$l.json: Sprache '$l' steht nicht in languages.list" } }
    }
}

Check 'Keys/Werte: Form <pkg>.<bereich>.<name>, Prefix == Paket, Werte nicht-leere Strings' {
    foreach ($pkg in $cat.Keys) {
        foreach ($l in $cat[$pkg].Keys) {
            foreach ($k in $cat[$pkg][$l].Keys) {
                if ($k -notmatch '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){2,}$') { "Datei packages/$pkg/locales/$l.json: Key '$k' hat nicht die Form <pkg>.<bereich>.<name>" }
                elseif ($k.Split('.')[0] -ne $pkg) { "Datei packages/$pkg/locales/$l.json: Key '$k' gehoert nicht zum Paket '$pkg'" }
                $v = $cat[$pkg][$l][$k]
                if ($v -isnot [string] -or [string]::IsNullOrWhiteSpace($v)) { "Datei packages/$pkg/locales/$l.json: '$k' ist leer oder kein Text" }
            }
        }
    }
}

Check 'Key-Paritaet: alle Sprachen eines Pakets haben dieselben Keys' {
    foreach ($pkg in $cat.Keys) {
        $all = @($cat[$pkg].Values | ForEach-Object { $_.Keys } | Sort-Object -Unique)
        foreach ($l in $cat[$pkg].Keys) {
            foreach ($k in $all) { if (-not $cat[$pkg][$l].Contains($k)) { "Datei packages/$pkg/locales/$l.json: '$k' fehlt" } }
        }
    }
}

Check 'Platzhalter-Paritaet: je Key dieselben {platzhalter} in allen Sprachen' {
    foreach ($pkg in $cat.Keys) {
        $ref = $cat[$pkg]['de']
        if ($null -eq $ref) { continue }
        foreach ($k in $ref.Keys) {
            $want = (Get-Placeholders ([string]$ref[$k])) -join ','
            foreach ($l in $cat[$pkg].Keys) {
                if (-not $cat[$pkg][$l].Contains($k)) { continue }
                $got = (Get-Placeholders ([string]$cat[$pkg][$l][$k])) -join ','
                if ($got -ne $want) { "Datei packages/$pkg/locales/$l.json: '$k' Platzhalter {$got} statt {$want} (de)" }
            }
        }
    }
}

Check 'Deutsch: echte Umlaute statt Ersatzschreibweise (ae/oe/ue)' {
    foreach ($pkg in $cat.Keys) {
        $de = $cat[$pkg]['de']
        if ($null -eq $de) { continue }
        foreach ($k in $de.Keys) {
            $hits = Find-UmlautSubstitute ([string]$de[$k])
            if ($hits.Count) { "Datei packages/$pkg/locales/de.json: '$k' enthaelt Ersatzschreibweise: $($hits -join ', ')" }
        }
    }
}

Check 'Pflicht-Keys: Fakten-Titel je context_validators-Kontext, Bezeichnung je Monitor-Methode' {
    foreach ($m in @('web_search', 'sql', 'none')) {
        if (-not ($cat['core'] -and $cat['core']['de'] -and $cat['core']['de'].Contains("core.monitor_method.$m"))) { "Datei packages/core/locales: core.monitor_method.$m fehlt" }
    }
    foreach ($mf in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json'))) {
        $mj = Read-Json $mf.FullName
        $pkg = [string]$mj.name
        $de = if ($cat.Contains($pkg)) { $cat[$pkg]['de'] } else { $null }
        if ($null -ne $mj.context_validators) {
            foreach ($p in $mj.context_validators.PSObject.Properties) {
                if ($p.Name -eq '_comment') { continue }
                if ($null -eq $de -or -not $de.Contains("$pkg.facts.$($p.Name).title")) { "Datei packages/$pkg/locales: $pkg.facts.$($p.Name).title fehlt (Titel der Fakten-Karte)" }
            }
        }
        if ($null -ne $mj.monitor_acquisition_methods) {
            foreach ($p in $mj.monitor_acquisition_methods.PSObject.Properties) {
                if ($p.Name -eq '_comment') { continue }
                if ($null -eq $de -or -not $de.Contains("$pkg.monitor_method.$($p.Name)")) { "Datei packages/$pkg/locales: $pkg.monitor_method.$($p.Name) fehlt (Bezeichnung der Monitor-Methode)" }
            }
        }
    }
}

# (7b) Bot-Persona: die EINE Liste (Core-Manifest personas.list) ist wohlgeformt, core:V031 legt nur Codes aus ihr an,
#      und jede Persona hat ihren Knopf-Namen core.persona.name.<code> (die Paritaet je Sprache sichert Check 4).
Check 'Persona-Liste: Core-Manifest personas.list (Code/ord, eindeutig, V031 ⊆ Liste, Knopf-Name je Persona)' {
    $pers = @($core.personas.list)
    $pcodes = @($pers | ForEach-Object { [string]$_.code })
    if ($pers.Count -eq 0) { 'Datei packages/core/manifest.json: personas.list fehlt oder ist leer' }
    if ($pcodes -notcontains 'neutral') { "personas.list: 'neutral' fehlt (Standard = keine Persona)" }
    foreach ($p in $pers) {
        if ("$($p.code)" -notmatch '^[a-z_]+$') { "Persona-Code '$($p.code)' passt nicht zu ^[a-z_]+$ (CHECK in core.ui_personas)" }
        if ($null -eq $p.ord) { "Persona '$($p.code)': ord fehlt" }
        if (-not ($cat['core'] -and $cat['core']['de'] -and $cat['core']['de'].Contains("core.persona.name.$($p.code)"))) { "Datei packages/core/locales: core.persona.name.$($p.code) fehlt (Knopf-Name im Persona-Picker)" }
        if ($p.code -ne 'neutral' -and $cat['core'] -and $cat['core']['de'] -and
            @($cat['core']['de'].Keys | Where-Object { $_ -like "core.persona.frame.$($p.code).*" }).Count -eq 0) {
            "Datei packages/core/locales: kein core.persona.frame.$($p.code).<n> (fester Rahmensatz im Relay, agent.orchestrator; mindestens einer)"
        }
    }
    foreach ($d in @($pcodes | Group-Object | Where-Object Count -gt 1)) { "Persona-Code '$($d.Name)' doppelt" }
    $v = Get-ChildItem (Join-Path $RepoRoot 'packages\core\db\migrations') -Filter 'V*__ui_personas*.sql' -ErrorAction SilentlyContinue
    foreach ($f in $v) {
        foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom), "\(\s*'([a-z_]+)'\s*,")) {
            if ($pcodes -notcontains $m.Groups[1].Value) { "$($f.Name) legt '$($m.Groups[1].Value)' an, das nicht in personas.list steht" }
        }
    }
}

# (8) Textkatalog Phase C: DB-Funktionen liefern Text-Verweise (core.fn_ui_tpl / core.fn_ui_text / Key-Listen) —
#     db_test laedt den Katalog nicht, ein Tippfehler zeigte in Prod den rohen Key. Jedes key-foermige SQL-Literal
#     '<pkg>.<bereich>.<name>' eines Pakets mit Katalog, dessen <bereich> im Katalog dieses Pakets vorkommt, MUSS als
#     Key existieren (de). Andere Punkt-Literale (Tabellen, fns, Konfig) haben keinen Katalog-Bereich -> unberuehrt.
#     Dynamisch zusammengesetzte Keys ('x.' || code) sind keine vollstaendigen Literale -> SQL darf Keys nur ganz nennen.
Check 'SQL-Text-Verweise: jedes Katalog-Key-Literal in R__-Funktionen existiert im Katalog' {
    $areas = @{}
    foreach ($pkg in $cat.Keys) {
        $de = $cat[$pkg]['de']; if ($null -eq $de) { continue }
        $areas[$pkg] = @{}
        foreach ($k in $de.Keys) { $areas[$pkg][$k.Split('.')[1]] = $true }
    }
    foreach ($f in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\db\migrations\R__*.sql'))) {
        $sql = [System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom)
        $sql = [regex]::Replace($sql, '(?m)--.*$', '')   # Kommentare raus (Beispiel-Keys in Koepfen)
        foreach ($m in [regex]::Matches($sql, "'([a-z][a-z0-9_]*)\.([a-z0-9_]+)\.([a-z0-9_.]+)'")) {
            $pkg = $m.Groups[1].Value; $area = $m.Groups[2].Value
            if (-not $areas.ContainsKey($pkg) -or -not $areas[$pkg].ContainsKey($area)) { continue }
            $key = "$pkg.$area.$($m.Groups[3].Value)"
            if ($cat[$pkg]['de'].Contains($key)) { continue }
            # ein Enum-Prefix ({kind:'enum', enum:'<pkg>.<bereich>.<typ>'}) ist kein Key, aber Praefix seiner Wert-Keys
            if (@($cat[$pkg]['de'].Keys | Where-Object { $_.StartsWith("$key.") }).Count -gt 0) { continue }
            "$($f.Name): Text-Key '$key' fehlt in packages/$pkg/locales/de.json"
        }
    }
}

# Warnung: ungenutzte Keys (Literal kommt nirgends vor). Dynamische Familien ausgenommen.
$corpus = New-Object System.Text.StringBuilder
$srcFiles = @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | ForEach-Object {
        Get-ChildItem (Join-Path $_.FullName 'build') -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue
        Get-ChildItem (Join-Path $_.FullName 'db\migrations') -File -Filter '*.sql' -ErrorAction SilentlyContinue }) +
    @(Get-ChildItem (Join-Path $RepoRoot 'scripts\build\lib') -File -Filter '*.ps1')
foreach ($f in $srcFiles) { [void]$corpus.Append([System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom)) }
$corpusText = $corpus.ToString()
$unused = @()
foreach ($pkg in $cat.Keys) {
    $de = $cat[$pkg]['de']; if ($null -eq $de) { continue }
    foreach ($k in $de.Keys) {
        if ($k -match '\.(enum|facts|monitor_method)\.' -or $k -match '^core\.persona\.(name|frame)\.') { continue }
        if (-not $corpusText.Contains("'$k'") -and -not $corpusText.Contains("""$k""")) { $unused += $k }
    }
}
if ($unused.Count) {
    Write-Host "  [WARN] $($unused.Count) Key(s) ohne Literal-Verwendung (pruefen, ob noch gebraucht):" -ForegroundColor DarkYellow
    if ($Verbose) { $unused | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
}

Write-Host ('-' * 64)
if ($script:failed -gt 0) { Write-Host "$($script:failed) locale_lint-Check(s) fehlgeschlagen." -ForegroundColor Red }
else { Write-Host 'locale_lint: alle Checks bestanden.' -ForegroundColor Green }
exit $script:failed
