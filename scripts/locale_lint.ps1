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
#       core.persona.name.<code>, ausser neutral Rahmensaetze (.1 ohne {name}) und die vier Tagesgruesse
#       core.persona.greet.<code>.<morning|day|evening|night> mit {name}; die in core:V031 vorab angelegten Codes sind Teil der Liste (V-Liste ⊆ Manifest).
#   (8) SQL-Text-Verweise: jedes Katalog-Key-Literal in packages/*/db/migrations/R__*.sql existiert im Katalog
#       (ebenso jeder Key im View-Modell-Beispiel tests/fixtures/app_view_model_v1.json).
#   (9) Mini-App-Laien-Test: keine Fachwoerter ($AppDeniedWords) in App-Texten; Ratchet-Ausnahmen je Key,
#       eine ueberfluessige Ausnahme ist ein Fehler.
#   (10) Mini-App-Texte: ein *.app.*-Key ohne Literal-Verwendung ist verwaist (Fehler; Tab-Titel ausgenommen).
#   (11) Karten-Laien-Test: Texte der Bestaetigungskarten kurz, ohne interne Begriffe, Datum statt Zeitspanne (Ratchet je Key).
# Warnung (kein Fehler): Keys, deren Literal nirgends in Build-Defs/Workflows/SQL vorkommt (dynamisch zusammengesetzte
#   Keys — .enum.*, .facts.*, .monitor_method.*, core.persona.{name,frame,greet}.* — sind ausgenommen).
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
Check 'Persona-Liste: Core-Manifest personas.list (Code/ord, eindeutig, V031 ⊆ Liste, Knopf-Name + Sticker-Set je Persona)' {
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
            "Datei packages/core/locales: kein core.persona.frame.$($p.code).<n> (fester Rahmensatz, agent.fn_claim_persona_frame; mindestens einer)"
        }
        if ($p.code -ne 'neutral' -and $cat['core'] -and $cat['core']['de']) {
            $de = $cat['core']['de']
            # .1 ist das Muster im Installer (provisioning/wizard/server.js, ui/art/art.js) und kennt dort keinen Namen
            $f1 = "core.persona.frame.$($p.code).1"
            if ($de.Contains($f1) -and ([string]$de[$f1]).Contains('{name}')) { "Datei packages/core/locales: '$f1' darf kein {name} tragen (Installer-Muster)" }
            # Tagesgruss je Tageszeit (core.fn_daypart); ohne {name} faellt agent.fn_claim_persona_frame nie auf den Gruss
            foreach ($dp in 'morning', 'day', 'evening', 'night') {
                $gk = "core.persona.greet.$($p.code).$dp"
                if (-not $de.Contains($gk)) { "Datei packages/core/locales: $gk fehlt (Tagesgruss, agent.fn_claim_persona_frame)" }
                elseif (-not ([string]$de[$gk]).Contains('{name}')) { "Datei packages/core/locales: '$gk' braucht den Platzhalter {name}" }
            }
        }
        # Sticker-Set je Persona (Bot mit Gesicht): die vier Ausdruecke, die agent.fn_claim_persona_sticker waehlt und der Gateway sendet
        foreach ($ex in 'hallo', 'top', 'hmm', 'yay') {
            if (-not (Test-Path (Join-Path $RepoRoot "packages\core\build\stickers\$($p.code)_$ex.webp"))) { "Datei packages/core/build/stickers/$($p.code)_$ex.webp fehlt (scripts/dev/render_stickers.ps1)" }
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
    # Form-Beispiel des View-Modells (§3.12): seine tpl-Keys und ui.t-Keys driften sonst still mit dem Katalog
    $fx = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'tests\fixtures\app_view_model_v1.json'), $Utf8NoBom)
    $fxKeys = @([regex]::Matches($fx, '"kind":\s*"tpl",\s*"value":\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) +
              @([regex]::Matches($fx, '"([a-z][a-z0-9_]*\.[a-z0-9_]+\.[a-z0-9_.]+)":\s*"') | ForEach-Object { $_.Groups[1].Value })
    foreach ($key in ($fxKeys | Sort-Object -Unique)) {
        $pkg = $key.Split('.')[0]
        if (-not $cat.Contains($pkg) -or -not $cat[$pkg]['de'].Contains($key)) { "app_view_model_v1.json: Text-Key '$key' fehlt in packages/$pkg/locales/de.json" }
    }
}

# (9) Laien-Test der Mini-App (UX-Gesamtkonzept 2026-10-31, P6; docs/package-contract.md §3.12 Design rules „words“):
#     kein Wort der Liste $AppDeniedWords im de-Text eines *.app.*-Keys oder eines Keys, dessen Praefix eine
#     R__fn_app_*.sql als Literal nennt (z. B. das Enum finance.enum.asset_bucket der Vermoegens-Seite). Gross/Klein egal,
#     Leerraum (auch geschuetztes Leerzeichen) normalisiert.
#     RATCHET: Ausnahmen stehen je EXAKTEM Key in $appWordExcept (seit dem UX-Umbau leer); wer eine Seite umbaut,
#     streicht seine Zeilen. Eine Ausnahme ohne Verstoss oder fuer einen Key, den es nicht mehr gibt, ist ein FEHLER
#     („Zeile streichen“) — so bleibt keine Ausnahme still stehen. Neue Ausnahmen nur mit Owner-Freigabe.
$AppDeniedWords = @('Kursminus', 'ermittelbar', 'Deckung', 'Verrechnungskonto', 'Projektion', 'Liquide', 'nicht in der Summe')
$appWordExcept = @(           # leer seit dem Umbau aller Bildschirme (UX-Gesamtkonzept B/C/D); neue Zeile = Owner-Freigabe
)
Check 'Mini-App-Laien-Test: keine Fachwoerter in App-Texten (Ratchet je Key)' {
    $prefixes = @()
    foreach ($f in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\db\migrations\R__fn_app_*.sql'))) {
        $sql = [regex]::Replace([System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom), '(?m)--.*$', '')
        foreach ($m in [regex]::Matches($sql, "'([a-z][a-z0-9_]*\.[a-z0-9_]+\.[a-z0-9_.]+)'")) { $prefixes += $m.Groups[1].Value }
    }
    $prefixes = @($prefixes | Sort-Object -Unique)
    $hit = @{}
    foreach ($pkg in $cat.Keys) {
        $de = $cat[$pkg]['de']; if ($null -eq $de) { continue }
        foreach ($k in $de.Keys) {
            $inScope = ($k -match '^[a-z0-9_]+\.app\.') -or @($prefixes | Where-Object { $k -eq $_ -or $k.StartsWith("$_.") }).Count -gt 0
            if (-not $inScope) { continue }
            $txt = ([regex]::Replace([string]$de[$k], '[\s ]+', ' ')).ToLowerInvariant()
            $words = @($AppDeniedWords | Where-Object { $txt.Contains($_.ToLowerInvariant()) })
            if ($words.Count) { $hit[$k] = $words }
        }
    }
    foreach ($k in ($hit.Keys | Sort-Object)) {
        if ($appWordExcept -notcontains $k) { "Datei packages/$($k.Split('.')[0])/locales/de.json: '$k' enthaelt '$($hit[$k] -join "', '")' (Laien-Test P6; Wort weglassen oder umformulieren)" }
    }
    foreach ($k in $appWordExcept) {
        if (-not $hit.ContainsKey($k)) { "Ausnahme '$k' in scripts/locale_lint.ps1 ist ueberfluessig (kein Verstoss mehr oder Key entfernt) -- Zeile streichen" }
    }
}

# (11) Laien-Test der Bestaetigungskarten (Regel E der Sprint-Probe; Gerüst packages/CLAUDE.md
#      *HITL-Bestätigungs-Format*). Dieselbe Mechanik wie (9), eigene Wortliste: Karten-Woerter treffen keine App-Texte.
#      UMFANG aus dem Code abgeleitet: jedes Key-Literal in Build-Defs, die eine Karte bauen (New-HitlSummary/-Line/-Note),
#      und in R__-Funktionen mit Kartenzeilen (card_lines / 'kind', 'note'), dazu die Gate-Texte core.hitl.*; ein Literal,
#      das Praefix von Keys ist (Enum), nimmt seine Wert-Keys mit. Nie *.app.* (App-Fenster), *.help.*, *.wf.*.
#      Regeln je Key: de hoechstens 3 Saetze, 20 Woerter je Satz ("• "-Zeilen = Zahlen-Zeilen, zaehlen nicht; keine
#      Zeichengrenze, Regel E kennt keine); en/ko hoechstens 3 Saetze (Uebersetzungen
#      wachsen, W3C). Keine Vorsilbe ACHTUNG:/Hinweis:/Aktion:; das Warnzeichen nur als Satzanfang "⚠️ " (E1, die Folge
#      steht in Worten dahinter). Keine Woerter aus $CardDeniedWords (die Meldung nennt den Ersatz), keine Zeitspanne
#      "<Zahl> Tage vor/nach" (ein Datum nennen). Satzzaehlung ignoriert Abkuerzungen (z. B.), Zahl- und Datumspunkte.
#      RATCHET wie (9): Ausnahmen je EXAKTEM Key mit Grund in $cardExcept; ueberfluessige Ausnahme = Fehler.
$CardDeniedWords = [ordered]@{
    'Entität' = 'Versicherung, Kredit, Sparziel …'; 'referenziert' = 'hängt dran'; 'Export' = 'Datei'
    'Sammelbetrag' = 'Summe der übrigen Posten'; 'Trigger' = 'Überwachung'; 'II. BV' = 'weglassen'; 'Turnus' = 'Rhythmus'
    'Prompt' = 'Anweisung'; 'SQL' = 'Abfrage'; 'das System' = 'ich'
    'verrechnet' = 'zählt nur einmal'
}
$cardExcept = [ordered]@{     # Key = Grund; neue Zeile = Owner-Freigabe (Termin 3 der Sprint-Probe)
}
function Get-CardTextFindings([string]$Text, [string]$Lang) {
    $out = @()
    $t = [regex]::Replace($Text, '\s+', ' ').Trim()
    # Zeilen mit "• " am Anfang sind Zahlen-Zeilen (Regel E: "drei kurze Saetze PLUS Zahlen"): kein Satz, nicht in der
    # Zeichengrenze; Wortliste und Warnzeichen gelten trotzdem fuer den ganzen Text ($t).
    $prose = [regex]::Replace((@($Text -split "`n" | Where-Object { -not $_.TrimStart().StartsWith('• ') }) -join ' '), '\s+', ' ').Trim()
    # Satzenden zaehlen: Abkuerzungen, Zahl-/Datumspunkte und Auslassung maskieren
    $m = [regex]::Replace($prose, '\b(z\.\s?B|d\.\s?h|u\.\s?a|e\.\s?g|i\.\s?e)\.', 'X')   # zweiteilige Abkuerzungen zuerst (sonst zaehlt "B." als Satzende)
    $m = [regex]::Replace($m, '\b(bzw|ca|Nr|ggf|inkl|evtl|bspw|etc)\.', 'X')
    $m = [regex]::Replace($m, '(?<=\d)\.(?=\s?\d)|(?<=\{\w+\})\.(?=\d)', '')
    $m = $m.Replace('…', '')
    $sentences = @([regex]::Split($m, '(?<=[.!?])\s+') | Where-Object { $_.Trim() -ne '' })
    if ($sentences.Count -gt 3) { $out += "$($sentences.Count) Sätze (höchstens 3)" }
    if ($Lang -eq 'de') {
        foreach ($s in $sentences) {
            $w = @($s.Trim() -split ' ' | Where-Object { $_ -match '[\p{L}\p{N}{]' }).Count
            if ($w -gt 20) { $out += "Satz mit $w Wörtern (höchstens 20): '$($s.Trim().Substring(0, [Math]::Min(40, $s.Trim().Length)))…'" }
        }
        foreach ($k in $CardDeniedWords.Keys) {
            if ([regex]::IsMatch($t, '(?<![\p{L}])' + [regex]::Escape($k), 'IgnoreCase')) { $out += "'$k' -> '$($CardDeniedWords[$k])'" }
        }
        if ($t -match '\d+\s+Tage?n?\s+(vor|nach)\b') { $out += "Zeitspanne '$($Matches[0])' -> ein Datum nennen" }
    }
    if ($t -match '^(ACHTUNG|Achtung|Hinweis|Aktion|WARNING|Note|Action)\s*:') { $out += "Vorsilbe '$($Matches[0])' -> Warnung mit '⚠️ ' beginnen, sonst ohne Vorsilbe" }
    $warn = [regex]::Matches($t, '⚠️?')
    if ($warn.Count -gt 1 -or ($warn.Count -eq 1 -and -not $t.StartsWith('⚠️ ', [StringComparison]::Ordinal))) { $out += "Warnzeichen nur als Satzanfang '⚠️ '" }
    $out
}
Check 'Karten-Laien-Test: kurze Kartentexte ohne interne Begriffe (Ratchet je Key)' {
    # Selbsttest der Regel (Positiv-/Negativfall), damit ein kaputter Regex nicht still alles durchwinkt
    $neg = @(Get-CardTextFindings 'ACHTUNG: Der Export wird gelöscht. Eins. Zwei. Drei. Fällig 10 Tage vor dem Stichtag.' 'de')
    if ($neg.Count -lt 4) { "Selbsttest: Negativfall meldet nur $($neg.Count) Funde (erwartet Vorsilbe, Sätze, Wort, Zeitspanne)" }
    $pos = @(Get-CardTextFindings '⚠️ Der Eintrag wird z. B. am 01.10.2026 endgültig gelöscht. Das gilt auch für Kopien. Falls falsch, abbrechen.' 'de')
    if ($pos.Count) { "Selbsttest: Positivfall meldet Funde: $($pos -join '; ')" }
    $bul = @(Get-CardTextFindings "Eins ist klar. Zwei ist klar.`n• Rat: höchstens 100 € im Depot und sonst nichts weiter, auch nicht mehr als das, was du sonst noch hast`n• Verlust: 50 €`nDrei ist klar." 'de')
    if ($bul.Count) { "Selbsttest: •-Zeilen zaehlen als Satz/Zeichen: $($bul -join '; ')" }
    $keys = @{}
    # Wildcard-Pfad + -Recurse liefert unter PS 5.1 nicht rekursiv -> je Paket-Ordner (wie der Corpus unten)
    $src = @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | ForEach-Object {
            Get-ChildItem (Join-Path $_.FullName 'build') -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue } | Where-Object {
            [System.IO.File]::ReadAllText($_.FullName, $Utf8NoBom) -match 'New-Hitl(Summary|Line|Note)' }) +
        @(Get-ChildItem (Join-Path $RepoRoot 'packages\*\db\migrations\R__fn_*.sql') | Where-Object {
            $s = [System.IO.File]::ReadAllText($_.FullName, $Utf8NoBom); $s -match 'card_lines' -or $s -match "'kind',\s*'note'" })
    foreach ($f in $src) {
        $cmt = if ($f.Extension -eq '.sql') { '(?m)--.*$' } else { '(?m)#.*$' }
        $txt = [regex]::Replace([System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom), $cmt, '')
        foreach ($m in [regex]::Matches($txt, "'([a-z][a-z0-9_]*\.[a-z0-9_]+\.[a-z0-9_.]+)'")) { $keys[$m.Groups[1].Value] = $true }
    }
    $hit = [ordered]@{}
    foreach ($pkg in $cat.Keys) {
        foreach ($l in $cat[$pkg].Keys) {
            $dict = $cat[$pkg][$l]
            foreach ($k in $dict.Keys) {
                # nur Karten-Bereiche: Chat-/Cron-Texte derselben Datei (offer, dialog, cron …) sind keine Karte
                if ($k -notmatch '^[a-z0-9_]+\.(hitl|note|label|tpl|value|enum|fmt)\.') { continue }
                $parts = $k.Split('.'); $inScope = $k -like 'core.hitl.*'
                for ($i = 3; -not $inScope -and $i -le $parts.Count; $i++) { $inScope = $keys.ContainsKey(($parts[0..($i - 1)] -join '.')) }
                if (-not $inScope) { continue }
                $f = @(Get-CardTextFindings ([string]$dict[$k]) $l)
                if ($f.Count) { $hit["$l|$k"] = $f }
            }
        }
    }
    foreach ($hk in $hit.Keys) {
        $l, $k = $hk.Split('|')
        if (-not $cardExcept.Contains($k)) { "Datei packages/$($k.Split('.')[0])/locales/$l.json: '$k': $($hit[$hk] -join '; ')" }
    }
    foreach ($k in $cardExcept.Keys) {
        if (-not @($hit.Keys | Where-Object { $_.EndsWith("|$k") }).Count) { "Ausnahme '$k' in scripts/locale_lint.ps1 ist ueberfluessig (kein Verstoss mehr oder Key entfernt) -- Zeile streichen" }
    }
}

# Warnung: ungenutzte Keys (Literal kommt nirgends vor). Dynamische Familien ausgenommen.
$corpus = New-Object System.Text.StringBuilder
$srcFiles = @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | ForEach-Object {
        Get-ChildItem (Join-Path $_.FullName 'build') -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue
        Get-ChildItem (Join-Path $_.FullName 'db\migrations') -File -Filter '*.sql' -ErrorAction SilentlyContinue }) +
    @(Get-ChildItem (Join-Path $RepoRoot 'scripts\build\lib') -File -Filter '*.ps1') +
    # Start-App: Seiten und Menue (ohne den erzeugten Text-Block, der jeden Schluessel nennt)
    @(Get-ChildItem (Join-Path $RepoRoot 'provisioning\desktop') -Recurse -File -Include '*.js', '*.rs' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](target|gen|preview)[\\/]' })
foreach ($f in $srcFiles) {
    $txt = [System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom)
    [void]$corpus.Append([regex]::Replace($txt, '/\* ui-locale:begin [\s\S]*?/\* ui-locale:end \*/', ''))
}
$corpusText = $corpus.ToString()
$unused = @()
foreach ($pkg in $cat.Keys) {
    $de = $cat[$pkg]['de']; if ($null -eq $de) { continue }
    foreach ($k in $de.Keys) {
        if ($k -match '\.(enum|facts|monitor_method|plan_section)\.' -or $k -match '\.plan\.name$' -or $k -match '^core\.persona\.(name|frame|greet)\.') { continue }
        # Start-App: zusammengesetzt aus Codes (Fehler, Docker-Art, Schritt der Leiste, Ergebnis-Zeilen, Haken beim Entfernen)
        if ($k -match '^core\.desktop\.(error|engine|result|uninstall|uninstalled|check)\.' -or $k -match '^core\.wizard\.step\.') { continue }
        if (-not $corpusText.Contains("'$k'") -and -not $corpusText.Contains("""$k""")) { $unused += $k }
    }
}
# (10) Mini-App-Texte (*.app.*) sind ausschliesslich SQL-Literale der Bildschirm-fns -> ein ungenutzter ist verwaist und
#      ein FEHLER (UX-Gesamtkonzept: wer eine Seite umbaut, raeumt ihre alten Keys ab). Ausgenommen die Tab-Titel
#      <pkg>.app.screen.<screen> (setzt core.fn_app_nav dynamisch aus dem Manifest zusammen) und Keys, die der Installer
#      (provisioning/**/*.sh, z. B. der Menue-Knopf core.app.menu_button) nennt.
Check 'Mini-App-Texte: kein verwaister *.app.*-Key' {
    $shText = (@(Get-ChildItem (Join-Path $RepoRoot 'provisioning') -Recurse -File -Filter '*.sh') |
        ForEach-Object { [System.IO.File]::ReadAllText($_.FullName, $Utf8NoBom) }) -join "`n"
    foreach ($k in $unused) {
        if ($shText.Contains($k)) { continue }
        if ($k -match '^[a-z0-9_]+\.app\.' -and $k -notmatch '^[a-z0-9_]+\.app\.screen\.') { "Datei packages/$($k.Split('.')[0])/locales/*.json: '$k' wird nirgends genutzt -- in allen Sprachen entfernen" }
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
