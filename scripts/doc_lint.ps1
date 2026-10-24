#Requires -Version 5.1
# Doku-Drift-Lint (AP4 des Repo-Audits 2026-06-10) -- hartes Gate als prek-Hook doc-lint (commit-stage).
#
# Prinzip "Constraint > Appell": Appell-Regeln ("Counts nicht hart fuehren") sind nachweislich
# 4x gedriftet; dieses Lint macht Drift deterministisch sichtbar. DESIGN-AUFLAGE: extraktions-
# basiert, KEINE hand-gepflegten Namenslisten (sonst driftet das Lint selbst -- Beweis war der
# tote Pfad-Regex '^scripts/build/tools/' in pre_push_check.ps1).
#
# Checks (Nummern eindeutig -- S5a-Hygiene, vorher war "6" doppelt vergeben; die Nummern sind
# stabile IDs, KEINE Lesereihenfolge -- im Code liegt Block 6 historisch vor Block 5):
#   1) Backtick-Tokens mit Pfad-Gestalt in **/CLAUDE.md + BACKLOG.md -> muessen auf Platte existieren.
#   2) Bare Dateinamen-Tokens (*.ps1/*.sql) in der Doku -> muessen irgendwo unter scripts/db/tests/packages/docs liegen.
#   3) Harte Case-Counts / ID-Ranges im GESAMTEN Doku-Korpus (alle CLAUDE.md + BACKLOG.md) -> Verstoss
#      (Counts via .Count verifizieren; S2-Haertung: vorher nur tests/CLAUDE.md).
#   4) Set-Gleichheit: Write-Tools-Tabelle (korpus-weit aus ALLEN CLAUDE.mds extrahiert, mit
#      Fehlt-Guard statt Crash -- S3-Doku-Split-fest) <-> packages/*/build/workflows/tools/*.ps1
#      (Ausnahmen = Core-Host-Tools + als intern markierte Tools, siehe $InternalToolMarker).
#   5) Pfad-Literale in scripts/**/*.ps1 + packages/*/build/**/*.ps1 (gequotete Strings/Anker-Regexes auf
#      scripts|db|tests|packages|docs) -> muessen existieren (haette den pre_push_check-Bug gefangen).
#   6) Fixture-Single-Source: fixtures.json subset util_seed_test_fixtures.sql.
#   7) Env-Template-Konvention (genau .env.example; envMap-Keys TEST_-praefixt + dokumentiert).
#   8) Sektions-Anker: Prosa-Pointer `datei.md` *Sektion* (Datei-Token auch als Markdown-Link
#      [x](datei.md), Separator auch '->') -> Ziel-Datei existiert UND traegt eine Ueberschrift/
#      einen Fett-Lead, der die Sektion (normalisiert, an Wort-/Kompositum-Grenze) enthaelt;
#      Nested-Form *A -> B* segment-weise. 8b) interne Anker (s./siehe/-> *X*, *X* oben|unten)
#      -> Sektion in DERSELBEN Datei (WP-10: beide realen Anker-Fossile des S3-Doku-Splits waren
#      8b-Faelle). Korpus fuer 8/8b zusaetzlich README/AGENTS/CONTRIBUTING/SECURITY/docs (ohne
#      generierte Kataloge) + .claude/skills/*/SKILL.md. Selbst-Asserts VOR dem Scan (synthetische
#      Positiv-/Negativ-Beispiele) gegen stilles Waechter-Sterben: schlagen sie fehl, bricht das Lint hart ab.
#   9) Laengen-Gate fuer JEDE CLAUDE.md (hart > 200 Zeilen ODER > 16 KB; Root > 12 KB; Hinweis Root > 150 Zeilen).
#  10) Site-Befehls-Paritaet (Site-Phase): Befehls-Tabelle der Showcase-Site
#      (docs/site/content/docs/befehle.md) <-> Manifest-commands (packages/*/manifest.json
#      .commands.list[].cmd) + Hidden-Allowlist (extrahiert aus scripts/command_lint.ps1 $hidden --
#      KEINE zweite Handliste). Der einzige mechanisch ableitbare Site-Fakt; Prosa-Aktualitaet der
#      Site bleibt Prozess (Entwicklungszyklus Schritt 7 + llm_suite_advice-Touchpoint).
#  11) Pin-Anti-Drift (Muster Check 5, extraktions-basiert): die gepinnten Tool-Versionen in
#      scripts/lib/devenv.ps1 ($DevEnvPins, SoT der Dev-Setup-Downloads) == ihre externen Zweitquellen
#      -- gitleaks/squawk gegen .github/workflows/ci.yml, Hugo gegen scripts/build_site.ps1
#      ($PinnedHugoVersion), plus die Copy-paste-Versions-Literale in CONTRIBUTING.md *Setup*.
#      dotenv-linter ist local-only (CI: SKIP) -> keine Zweitquelle, nicht geprueft.
#
# Suppression: Zeile mit 'lint-ignore' wird uebersprungen. Exit-Code = Anzahl Fails (CI-/Gate-faehig).

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$fails = 0

function Fail([string]$File, [string]$Msg) {
    Write-Host ("  FAIL  {0}: {1}" -f $File, $Msg) -ForegroundColor Red
    $script:fails++
}

# Doku-Korpus: alle CLAUDE.md + BACKLOG.md (ableitbar, keine Liste pflegen).
# .claude ausgeschlossen: dort liegen u. a. transiente Agent-Worktrees (.claude/worktrees/**) --
# ohne den Ausschluss scannt das Lint fremde Repo-Kopien und blockt Commits waehrend
# Multi-Agent-Laeufen (real getroffen S5a). Der Ausschluss matcht RELATIV zu $RepoRoot (nicht den
# absoluten Pfad): laeuft das Lint IN einem Worktree unter .claude/worktrees/<x>, wuerde der
# absolute Match sonst das ganze eigene Repo ausschliessen (0-Dateien-Korpus, real getroffen
# CLI-Menue-Phase 2026-07).
$docFiles = @(Get-ChildItem -Path $RepoRoot -Recurse -Filter 'CLAUDE.md' |
              Where-Object { $_.FullName.Substring($RepoRoot.Length) -notmatch '\\(\.local|\.claude|node_modules|\.git)\\' })
$backlog = Join-Path $RepoRoot 'BACKLOG.md'
if (Test-Path $backlog) { $docFiles += Get-Item $backlog }
# Skills (.claude/skills/*/SKILL.md) sind Claude-Code-Prozeduren mit Pfad-/Sektions-Zeigern -> derselbe Korpus
# (Harness-Rightsizing 2026-10-20: vorher veralteten Skill-Zeiger still). Nur der Skills-Ordner, relativ zu
# $RepoRoot -- die transienten Worktrees unter .claude/worktrees/** bleiben draussen.
$docFiles += @(Get-ChildItem -Path (Join-Path $RepoRoot '.claude\skills') -Recurse -Filter 'SKILL.md' -ErrorAction SilentlyContinue)
# Referenz-Doku (docs/reference/*.md, on-demand gelesen) + pfad-gebundene Regeln (.claude/rules/*.md) tragen seit dem
# Rightsizing (Phase 3, 2026-10-20) den aus den Sub-CLAUDE.mds ausgelagerten Text -> derselbe Korpus: Pfad-Tokens,
# Counts, Write-Tools-Tabelle (Check 4) und Sektions-Zeiger (Check 8) gelten dort genauso.
$docFiles += @(Get-ChildItem -Path (Join-Path $RepoRoot 'docs\reference') -Filter '*.md' -ErrorAction SilentlyContinue)
$docFiles += @(Get-ChildItem -Path (Join-Path $RepoRoot '.claude\rules') -Recurse -Filter '*.md' -ErrorAction SilentlyContinue)

Write-Host "=== doc_lint: $($docFiles.Count) Doku-Dateien ===" -ForegroundColor Cyan

# ---------------------------------------------------------------
# 1+2) Backtick-Tokens: Pfade + bare .ps1/.sql-Dateinamen muessen existieren
# ---------------------------------------------------------------
# Platzhalter/Globs/Expressions ausschliessen: <>, {}, *, $, Leerzeichen, http
$placeholderRx = '[<>{}\*\$\s]|http|\.\.\.'

foreach ($doc in $docFiles) {
    $rel = $doc.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/'
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadAllLines($doc.FullName)) {
        $lineNo++
        if ($line -match 'lint-ignore') { continue }
        foreach ($m in [regex]::Matches($line, '`([^`]+)`')) {
            $tok = $m.Groups[1].Value.Trim()
            if ($tok -match $placeholderRx) { continue }

            # 1) Pfad-Gestalt: enthaelt '/', beginnt mit bekanntem Root-Segment (.claude seit Phase 3: Zeiger
            #    auf .claude/rules/*.md und .claude/hooks/*.ps1 sollen beim Umbenennen genauso rot werden).
            if ($tok -match '^(scripts|tests|packages|docs|\.claude)/[\w./\\-]+$') {
                $p = Join-Path $RepoRoot ($tok.TrimEnd('/') -replace '/', '\')
                if (-not (Test-Path $p)) {
                    # Gitignorte Pfade (z. B. tests/agent/judge_bundle.json, .local/**) fehlen in einem
                    # frischen Checkout (CI) BEWUSST -> kein Drift. check-ignore nur im Nicht-Existenz-
                    # Fall aufrufen (selten); exit 0 = ignoriert = ok.
                    & git -C $RepoRoot check-ignore -q -- $tok
                    if ($LASTEXITCODE -ne 0) { Fail "$rel`:$lineNo" "Pfad existiert nicht: ``$tok``" }
                }
                continue
            }
            # 2) Bare Dateiname .ps1/.sql (keine Pfadtrenner): muss unter scripts/ tests/ packages/ docs/ existieren.
            #    Erste Stelle alphanumerisch -- Suffix-Fragmente wie `_functions.sql` (Naming-Pattern) sind keine Dateien.
            if ($tok -match '^[A-Za-z0-9][\w.-]*\.(ps1|sql)$') {
                $found = $false
                foreach ($root in @('scripts', 'tests', 'packages', 'docs')) {
                    if (Get-ChildItem -Path (Join-Path $RepoRoot $root) -Recurse -Filter $tok -ErrorAction SilentlyContinue | Select-Object -First 1) { $found = $true; break }
                }
                if (-not $found) { Fail "$rel`:$lineNo" "Datei nirgends gefunden: ``$tok``" }
            }
        }
    }
}

# ---------------------------------------------------------------
# 3) Harte Counts / ID-Ranges im gesamten Doku-Korpus verboten (S2-Haertung: korpus-weit
#    statt nur tests/CLAUDE.md -- die Regel gilt fuer JEDE Doku, der Scan galt nur einer Datei)
# ---------------------------------------------------------------
foreach ($doc in $docFiles) {
    $rel = $doc.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/'
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadAllLines($doc.FullName)) {
        $lineNo++
        if ($line -match 'lint-ignore') { continue }
        # Suite-Counts wie "38 Finance-Agent-Cases" (Bindestrich-Kompositum) -- NICHT Prosa wie "2 Cases".
        # Token vor '-Cases' muss mit Wortzeichen beginnen: schliesst Klammer-Prosa wie
        # "Recherche-Pass 2 (Edge-Cases: ...)" aus (falsch-positiv der \S+-Form).
        if ($line -match '\b\d+\s+\w[\w-]*-[Cc]ases\b') {
            Fail "$rel`:$lineNo" "Harter Case-Count in Prosa (driftet -- via .Count verifizieren statt dokumentieren)."
        }
        if ($line -match '\((tc|e2e|oc|ic|ac|ae|sec)\d+\s*[–-]\s*(tc|e2e|oc|ic|ac|ae|sec)?\d+\)') {
            Fail "$rel`:$lineNo" "Erschoepfender ID-Range (driftet -- markante Beispiele als 'u. a.' statt Range)."
        }
    }
}

# ---------------------------------------------------------------
# 4) Set-Gleichheit: Write-Tools-Tabelle <-> packages/*/build/workflows/tools/*.ps1
# ---------------------------------------------------------------
# Bewusst NICHT in der Write-Tools-Tabelle (Phase D generisch, keine Namensliste): (a) Core-Host-Tools
# (packages/core/: Gate, Advisor-/Monitor-/Guide-Cross-Agent-Tools, Infra-Bausteine) und (b) jedes als intern
# markierte Tool (`Build-Workflow ... @{ Internal = $true }`, derselbe co-located Marker wie im Capabilities-Katalog).
$InternalToolMarker = '@\{\s*Internal\s*=\s*\$true\s*\}'

# Tabellen-Extraktion KORPUS-WEIT ueber alle CLAUDE.mds (S2-Haertung: vorher las der Check
# scripts/build/CLAUDE.md hart + ungeguardet -> ein Doku-Move haette das ganze Lint gecrasht statt
# gefailt; korpus-weit ist er S3-Doku-Split-fest). Streu-Zeilen-Risiko verifiziert: '| `tool_'-Zeilen
# existieren nur in der EINEN Katalog-Tabelle. Tool-Build-Defs liegen paket-uniform unter
# packages/*/build/workflows/tools/ (WS-B5); Core- + interne Tools filtert die Regel oben heraus.
$tableTools = @(); $tableDocRel = $null
foreach ($doc in $docFiles) {
    $docText = [System.IO.File]::ReadAllText($doc.FullName)
    $hits = [regex]::Matches($docText, '(?m)^\|\s*`tool_([a-z0-9_]+)`') | ForEach-Object { $_.Groups[1].Value }
    if ($hits) {
        $tableTools += $hits
        if (-not $tableDocRel) { $tableDocRel = $doc.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/' }
    }
}
$tableTools = $tableTools | Sort-Object -Unique
if (-not $tableTools) {
    Fail 'CLAUDE.md-Korpus' "Write-Tools-Tabelle in KEINER CLAUDE.md gefunden (Zeilen ``| tool_...``) -- Tabelle verschoben/geloescht ohne Lint-Nachzug."
}
$fileTools  = Get-ChildItem (Join-Path $RepoRoot 'packages\*\build\workflows\tools\*.ps1') |
              Where-Object { ($_.FullName -replace '\\', '/') -notmatch '/packages/core/build/' -and
                             [System.IO.File]::ReadAllText($_.FullName) -notmatch $InternalToolMarker } |
              ForEach-Object { $_.BaseName } | Sort-Object -Unique

foreach ($t in $fileTools)  { if ($tableTools -notcontains $t) { Fail $tableDocRel "Tool ``tool_$t`` (packages/*/build/workflows/tools/$t.ps1) fehlt in der Write-Tools-Tabelle." } }
foreach ($t in $tableTools) { if ($fileTools  -notcontains $t) { Fail $tableDocRel "Tabellen-Zeile ``tool_$t`` hat keine Build-Datei packages/*/build/workflows/tools/$t.ps1." } }

# ---------------------------------------------------------------
# 10) Site-Befehls-Paritaet: befehle.md-Tabelle <-> Manifest-commands + Hidden-Allowlist
# ---------------------------------------------------------------
# Fail statt Silent-Skip (Muster Check 6): bewegt sich eine der Quellen, muss das Lint schreien.
$siteCmdPage = Join-Path $RepoRoot 'docs\site\content\docs\befehle.md'
$cmdLintFile = Join-Path $RepoRoot 'scripts\command_lint.ps1'
if (-not (Test-Path $siteCmdPage)) { Fail 'docs/site/content/docs/befehle.md' 'Site-Befehlsseite fehlt (bewegt/geloescht ohne Lint-Nachzug?) -- Check 10 kann nicht greifen.' }
if (-not (Test-Path $cmdLintFile)) { Fail 'scripts/command_lint.ps1' 'command_lint.ps1 fehlt -- Hidden-Allowlist fuer Check 10 nicht extrahierbar.' }
if ((Test-Path $siteCmdPage) -and (Test-Path $cmdLintFile)) {
    # SOLL = Manifest-commands aller Pakete + Hidden-Allowlist ($hidden in command_lint.ps1).
    $sollCmds = @()
    foreach ($mfFile in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json'))) {
        $mf10 = [System.IO.File]::ReadAllText($mfFile.FullName, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
        if ($mf10.PSObject.Properties.Name -contains 'commands' -and $mf10.commands.PSObject.Properties.Name -contains 'list') {
            $sollCmds += @($mf10.commands.list | ForEach-Object { $_.cmd })
        }
    }
    $hiddenM = [regex]::Match([System.IO.File]::ReadAllText($cmdLintFile), '\$hidden\s*=\s*@\(([^\)]+)\)')
    if ($hiddenM.Success) { $sollCmds += @([regex]::Matches($hiddenM.Groups[1].Value, "'(/[a-z]+)'") | ForEach-Object { $_.Groups[1].Value }) }
    $sollCmds = $sollCmds | Sort-Object -Unique
    # Waechter-stirbt-still-Guard: leeres SOLL = Extraktion kaputt, nie "alles gruen".
    if (-not $sollCmds) { Fail 'packages/*/manifest.json' 'Check 10: KEIN Befehl aus Manifesten/Hidden-Allowlist extrahiert -- Extraktion gebrochen.' }
    # IST = Befehls-Tokens in Tabellen-Zeilen der Site-Seite (nur '|'-Zeilen, nicht Prosa).
    $siteText = [System.IO.File]::ReadAllText($siteCmdPage, (New-Object System.Text.UTF8Encoding($false)))
    $istCmds = @([regex]::Matches($siteText, '(?m)^\|\s*`(/[a-z]+)`') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
    foreach ($c in $sollCmds) { if ($istCmds -notcontains $c) { Fail 'docs/site/content/docs/befehle.md' "Befehl ``$c`` (Manifest/Hidden-Allowlist) fehlt in der Site-Befehlstabelle -- Seite nachziehen." } }
    foreach ($c in $istCmds)  { if ($sollCmds -notcontains $c) { Fail 'docs/site/content/docs/befehle.md' "Site-Tabelle nennt ``$c``, aber kein Manifest/keine Hidden-Allowlist deklariert ihn -- Geister-Befehl entfernen." } }
}

# ---------------------------------------------------------------
# 6) Fixture-Single-Source: jede Entitaet aus tests/fixtures/fixtures.json kommt im Seed
#    tests/fixtures/util_seed_test_fixtures.sql vor (Manifest subset Seed -> der Pre-Flight prueft nie
#    eine Entitaet, die der Seed nicht anlegt). EINE Namensliste der Routing-Suite statt zweier.
# ---------------------------------------------------------------
$fixManifest = Join-Path $RepoRoot 'tests\fixtures\fixtures.json'
$fixSeed     = Join-Path $RepoRoot 'tests\fixtures\util_seed_test_fixtures.sql'
# S2-Haertung: Fail statt Silent-Skip -- bewegt sich eine der beiden Dateien, wurde der ganze
# Check vorher still uebersprungen (genau die Drift-Klasse, die dieses Lint fangen soll).
if (-not (Test-Path $fixManifest)) { Fail 'tests/fixtures/fixtures.json' 'Fixture-Manifest fehlt (bewegt/geloescht ohne Lint-Nachzug?) -- Check 6 kann nicht greifen.' }
if (-not (Test-Path $fixSeed))     { Fail 'tests/fixtures/util_seed_test_fixtures.sql' 'Fixture-Seed fehlt (bewegt/geloescht ohne Lint-Nachzug?) -- Check 6 kann nicht greifen.' }
if ((Test-Path $fixManifest) -and (Test-Path $fixSeed)) {
    $mf = [System.IO.File]::ReadAllText($fixManifest, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
    $seedText = [System.IO.File]::ReadAllText($fixSeed)
    foreach ($f in $mf.fixtures) {
        # Bezug = der diskriminierende Wert (Name/ISIN/Vorname), den der Seed als Literal traegt.
        $needle = if ($f.check.type -eq 'family_person') { $f.check.first_name } else { $f.check.value }
        if ($seedText.IndexOf("$needle", [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            Fail 'tests/fixtures/util_seed_test_fixtures.sql' "Fixture '$($f.name)' (Bezug '$needle') aus tests/fixtures/fixtures.json fehlt im Seed."
        }
    }
}

# ---------------------------------------------------------------
# 5) Pfad-Literale in scripts/**/*.ps1 muessen existieren
# ---------------------------------------------------------------
# Scannt scripts/**/*.ps1 (Engine + Skripte) UND die paket-uniformen Build-Defs packages/*/build/**/*.ps1
# (WS-B5: sonst verlieren die verschobenen Defs die Pfad-Literal-Pruefung -> Coverage-Regress).
$psScanDirs = @((Join-Path $RepoRoot 'scripts')) +
              @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'build' } | Where-Object { Test-Path $_ })
foreach ($ps in (Get-ChildItem -Path $psScanDirs -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
    if ($ps.Name -eq 'doc_lint.ps1' -or $ps.Name -eq 'layout_lint.ps1') { continue }   # Lint-eigene Beispiel-/Fixture-Strings + Pfad-Regex-Tokens nicht gegen sich selbst linten (synthetische Pfade; layout_lint validiert seine echten Pfade zur Laufzeit via L4/L6)
    $rel = $ps.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/'
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadAllLines($ps.FullName)) {
        $lineNo++
        if ($line -match 'lint-ignore' -or $line -match '^\s*#') { continue }
        foreach ($m in [regex]::Matches($line, "['""]([^'""]+)['""]")) {
            $tok = $m.Groups[1].Value
            # Anker-Regex- oder Plain-Form auf Repo-Verzeichnisse; komplexe Regexes (Klassen/Alternation) skippen
            if ($tok -notmatch '^\^?(scripts|db|tests|packages|docs)/') { continue }
            if ($tok -match '[\[\]\(\)\|\+\*\?\{\}]') { continue }
            $isPrefix = $tok.StartsWith('^') -and -not $tok.EndsWith('$')
            $clean = $tok.TrimStart('^').TrimEnd('$').TrimEnd('/') -replace '\\\.', '.'
            if ($clean -match '[<>]') { continue }
            if ($isPrefix) {
                # Anker-Regex ohne $ = Praefix-Semantik: irgendein Repo-Pfad muss damit beginnen
                $dir = Split-Path $clean -Parent
                $leaf = Split-Path $clean -Leaf
                $hit = (Test-Path (Join-Path $RepoRoot ($clean -replace '/', '\'))) -or
                       ((Test-Path (Join-Path $RepoRoot $dir)) -and
                        (Get-ChildItem -Path (Join-Path $RepoRoot $dir) -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -like "$leaf*" } | Select-Object -First 1))
                if (-not $hit) { Fail "$rel`:$lineNo" "Pfad-Praefix matcht nichts: '$tok'" }
            } else {
                $p = Join-Path $RepoRoot ($clean -replace '/', '\')
                if (-not (Test-Path $p)) { Fail "$rel`:$lineNo" "Pfad-Literal zeigt ins Leere: '$tok'" }
            }
        }
    }
}

# ---------------------------------------------------------------
# 7) Env-Template-Konvention: genau EINE Vorlagen-Datei (.env.example); jeder
#    $envMap-Quell-Key im Docker-Test-Substrat-Treiber (bootstrap_test_n8n.ps1) ist TEST_-praefixt
#    UND in .env.example dokumentiert. Grund: ein zweites Template (.env.template) driftet still;
#    un-praefixte Test-Keys sind von den Kern-Prozess-Env-Namen (OWNER_*) nicht unterscheidbar.
# ---------------------------------------------------------------
# 7a) Genau eine Env-Vorlage, und das ist .env.example (kein .env.template/.sample/.dist-Duplikat).
$tmplFiles = @(Get-ChildItem -Path $RepoRoot -File -Force |
               Where-Object { $_.Name -match '^\.env\.(example|template|sample|dist)$' } |
               ForEach-Object { $_.Name } | Sort-Object)
if (($tmplFiles -join ',') -ne '.env.example') {
    if ($tmplFiles.Count -eq 0) {
        Fail '.env.example' "Keine Env-Vorlage gefunden (erwartet genau .env.example)."
    } else {
        Fail ($tmplFiles -join ', ') "Es muss genau EINE Env-Vorlage geben (.env.example). Gefunden: $($tmplFiles -join ', ')."
    }
}

# 7b) $envMap-Quell-Keys aus dem [ordered]@{...}-Literal in bootstrap_test_n8n.ps1: TEST_-praefixt + dokumentiert.
$driver     = Join-Path $RepoRoot 'scripts\dev\bootstrap_test_n8n.ps1'
$exampleEnv = Join-Path $RepoRoot '.env.example'
if ((Test-Path $driver) -and (Test-Path $exampleEnv)) {
    $driverText  = [System.IO.File]::ReadAllText($driver)
    $exampleText = [System.IO.File]::ReadAllText($exampleEnv)
    # Nur das ordered-Hashtable-Literal betrachten -- TEST_HARNESS_HEADER wird ausserhalb mit festem
    # Wert ($envLines.Add(...)) gesetzt und ist als Nicht-TEST_-Input bewusst ausgenommen.
    $m = [regex]::Match($driverText, '\$envMap\s*=\s*\[ordered\]@\{(.+?)\}', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) {
        Fail 'scripts/dev/bootstrap_test_n8n.ps1' "envMap-Literal ([ordered]@{ ... }) nicht gefunden -- Env-Konventions-Check kann nicht greifen."
    } else {
        $srcKeys = [regex]::Matches($m.Groups[1].Value, "(?m)^\s*'([A-Za-z0-9_]+)'\s*=") | ForEach-Object { $_.Groups[1].Value }
        # + MANIFEST-ABGELEITETE Paket-Secret-Keys (paperless-WS-0 Naht 3): der Treiber ergaenzt die Map
        # zur Laufzeit generisch um TEST_<envKey> je packages/*/manifest.json credentials.*.env-Property
        # (Property-NAME = Kern-Env-Key). Dieselbe Ableitung hier — jeder Paket-Secret-Key muss in
        # .env.example dokumentiert sein (frueher: statische career-Zeilen im Literal).
        $pkgKeys = New-Object System.Collections.Generic.List[string]
        foreach ($mfPath in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | ForEach-Object { Join-Path $_.FullName 'manifest.json' })) {
            if (-not (Test-Path $mfPath)) { continue }
            $mfObj = [System.IO.File]::ReadAllText($mfPath) | ConvertFrom-Json
            if ($null -eq $mfObj.credentials) { continue }
            foreach ($credProp in ($mfObj.credentials.PSObject.Properties | Where-Object { $_.Name -notlike '_*' })) {
                if ($null -eq $credProp.Value.env) { continue }
                foreach ($envKeyProp in $credProp.Value.env.PSObject.Properties) { $pkgKeys.Add("TEST_$($envKeyProp.Name)") }
            }
        }
        # Selbst-Assert: die Ableitung darf nicht still leerlaufen, solange ein credentials-Block existiert
        # (career traegt heute 3 Keys — 0 Treffer hiesse Extraktions-Bruch, nicht "keine Pakete").
        $hasCredBlock = @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | Where-Object {
            $p = Join-Path $_.FullName 'manifest.json'
            (Test-Path $p) -and (([System.IO.File]::ReadAllText($p) | ConvertFrom-Json).PSObject.Properties.Name -contains 'credentials')
        }).Count -gt 0
        if ($hasCredBlock -and $pkgKeys.Count -eq 0) {
            Fail 'scripts/doc_lint.ps1' 'Selbst-Assert 7b: credentials-Block vorhanden, aber 0 abgeleitete TEST_*-Paket-Keys (Manifest-Ableitung gebrochen).'
        }
        foreach ($k in (@($srcKeys) + @($pkgKeys) | Select-Object -Unique)) {
            if ($k -notmatch '^TEST_') {
                Fail 'scripts/dev/bootstrap_test_n8n.ps1' "envMap-Quell-Key '$k' ist nicht TEST_-praefixt (Substrat-Test-Input -> TEST_*; Kern-Zielname bleibt rechts unveraendert)."
            }
            if ($exampleText -notmatch ("(?m)^\s*#?\s*" + [regex]::Escape($k) + "=")) {
                Fail '.env.example' "envMap-Quell-Key '$k' fehlt in .env.example (Vorlage muss jeden Test-Substrat-Schluessel dokumentieren)."
            }
        }
    }
}

# ---------------------------------------------------------------
# 8) Sektions-Anker-Validierung (WP-10): Prosa-Pointer `datei.md` *Sektion* muessen aufloesen --
#    Ziel-Datei existiert UND traegt eine Ueberschrift (#..####) oder einen Fett-Lead (**X** am
#    Zeilen-/Bullet-Anfang), der die Sektion normalisiert (Backticks/Marker strippen, Umlaut-
#    Faltung, Substring) enthaelt. Nested-Form *A -> B* wird segment-weise geprueft.
# 8b) Interne Anker (s./siehe *X* bzw. *X* oben|unten) muessen in DERSELBEN Datei aufloesen --
#    genau die Fossil-Klasse, die der S3-Doku-Split real erzeugte (beide 791e727-Anker-Fossile).
#    Cross-File-Verweise gehoeren als Datei-Pointer geschrieben (`datei.md` *Sektion*), nie als
#    nackter interner Anker.
# ---------------------------------------------------------------

# Anker-Normalisierung: Markdown-Marker raus, lowercase, Umlaut-Faltung, Whitespace kollabieren.
function ConvertTo-AnchorNorm([string]$s) {
    $t = $s -replace '[`*_]', ''
    $t = $t.ToLowerInvariant()
    $t = $t -replace 'ä', 'ae' -replace 'ö', 'oe' -replace 'ü', 'ue' -replace 'ß', 'ss'
    $t = ($t -replace '\s+', ' ').Trim()
    return $t.TrimEnd(':', '.').Trim()
}

# Sektions-Kandidaten einer Datei: ATX-Ueberschriften + Fett-Leads (erste **...**-Gruppe einer
# Zeile, die -- ggf. nach Bullet/Blockquote/Tabellen-Pipe -- mit ** beginnt; hart umbrochene
# Leads, deren ** erst auf einer Folgezeile schliesst, zaehlen mit dem Zeilenrest). Normalisiert.
function Get-SectionsFromLines([string[]]$Lines) {
    $secs = New-Object System.Collections.Generic.List[string]
    foreach ($l in $Lines) {
        if ($l -match '^\s{0,3}#{1,6}\s+(.+)$') { $secs.Add((ConvertTo-AnchorNorm $Matches[1])); continue }
        if ($l -match '^\s*(?:[-*+]\s+|\d+\.\s+|>\s*|\|\s*)*\*\*(.+?)\*\*') { $secs.Add((ConvertTo-AnchorNorm $Matches[1])); continue }
        if ($l -match '^\s*(?:[-*+]\s+|\d+\.\s+|>\s*|\|\s*)*\*\*([^*]+)$') { $secs.Add((ConvertTo-AnchorNorm $Matches[1])) }
    }
    return $secs
}
$script:sectionCache = @{}
function Get-DocSections([string]$Path) {
    if ($script:sectionCache.ContainsKey($Path)) { return $script:sectionCache[$Path] }
    $secs = Get-SectionsFromLines ([System.IO.File]::ReadAllLines($Path))
    $script:sectionCache[$Path] = $secs
    return $secs
}

# Anker gegen die Sektions-Liste testen; Nested-Form 'A -> B' (Pfeil) segment-weise.
# Match nur an Wort-Anfaengen (Lookbehind auf \w UND '-'): der Anker 'Verb-Taxonomie' darf NICHT
# still im anderen Kompositum 'fn-Verb-Taxonomie' aufloesen (Coverage-Audit C2: sonst maskiert
# ein Substring-Doppeltreffer kuenftige Renames der gemeinten Sektion). Bewusste Rest-Grenze:
# gleich-thematische Doppel-Treffer an Wortgrenzen (z. B. Ankuendigungs-Zeile + Ziel-Lead)
# unterscheidet Substring-Matching nicht -- Ambiguitaets-Fail erst bei realem Fossil-Beleg.
function Test-AnchorResolves($Sections, [string]$Anchor) {
    foreach ($seg in ($Anchor -split '→|->')) {
        $n = ConvertTo-AnchorNorm $seg
        if (-not $n) { continue }
        $rx = '(?<![\w-])' + [regex]::Escape($n)
        $hit = $false
        foreach ($s in $Sections) { if ([regex]::IsMatch($s, $rx)) { $hit = $true; break } }
        if (-not $hit) { return $false }
    }
    return $true
}

# Pointer-Extraktion: Datei-Token als `datei.md` ODER Markdown-Link [x](datei.md), danach
# optional '->'/Klammer, dann *Sektion* [/ *Sektion2* ...] (Coverage-Audit C1: AGENTS.md
# verweist per [CLAUDE.md](CLAUDE.md) -> *Sektion*).
$anchorPointerRx = [regex]'(?:`(?<file>[^`]+\.md)`|\[[^\]]*\]\((?<file>[^)\s]+\.md)\))\s*(?:(?:→|->)\s*)?\(?\s*(?<secs>\*[^*]+\*(?:\s*/\s*\*[^*]+\*)*)'
# Interne Anker: s./siehe/-> *X* (kursiv, nicht **fett**) bzw. *X* oben|unten. Der Pfeil gilt in
# BEIDEN Schreibweisen (typografisch + ASCII) -- sonst wuerde die ASCII-Form still uebersprungen.
$innerAnchorRxA = [regex]'(?:\bs\.|\bsiehe\b|\bSiehe\b|→|->)\s*(?<!\*)\*([^*]+)\*(?!\*)'
$innerAnchorRxB = [regex]'(?<!\*)\*([^*]+)\*(?!\*)\s+(?:oben|unten)\b'

# --- Selbst-Asserts (Positiv-/Negativ-Beispiele) VOR dem Scan: stirbt die Extraktion oder das
# --- Matching still (Regex-Edit, PS-Verhalten), wird das Lint hart rot statt leise gruen.
$selfTestFails = 0
$stSecs = Get-SectionsFromLines @('## Zins-Gutschrift (Beispiel)', '- **Fett-Lead (`code`) mit Zusatz:** Prosa',
                                  '**Mehrzeilen-Lead hart umbrochen, schliesst', 'erst hier.**', 'kein Anker')
if ($stSecs.Count -ne 3)                                        { $selfTestFails++ }
if (-not (Test-AnchorResolves $stSecs 'Zins-Gutschrift'))       { $selfTestFails++ }
if (-not (Test-AnchorResolves $stSecs 'fett-lead'))             { $selfTestFails++ }   # Case-Faltung
if (-not (Test-AnchorResolves $stSecs 'Mehrzeilen-Lead'))       { $selfTestFails++ }   # Wrap-Lead
if (Test-AnchorResolves $stSecs 'Nicht-Existent')               { $selfTestFails++ }   # Negativ
$stSecs2 = Get-SectionsFromLines @('- **fn-Verb-Taxonomie:** Lese-Verben')
if (Test-AnchorResolves $stSecs2 'Verb-Taxonomie')              { $selfTestFails++ }   # Kompositum-Grenze (C2)
if (-not (Test-AnchorResolves $stSecs2 'fn-Verb-Taxonomie'))    { $selfTestFails++ }   # Positiv am Wort-Anfang
$stM = $anchorPointerRx.Matches('vgl. `packages/CLAUDE.md` *Alpha* / *Beta* dazu')
if ($stM.Count -ne 1 -or ([regex]::Matches($stM[0].Groups['secs'].Value, '\*([^*]+)\*').Count -ne 2)) { $selfTestFails++ }
$stM2 = $anchorPointerRx.Matches('root [CLAUDE.md](CLAUDE.md) → *Alpha*')
if ($stM2.Count -ne 1 -or $stM2[0].Groups['file'].Value -ne 'CLAUDE.md') { $selfTestFails++ }   # MD-Link-Form (C1)
if ($innerAnchorRxA.Matches('… s. *Gamma* …').Count -ne 1)      { $selfTestFails++ }
if ($innerAnchorRxA.Matches('State ignoriert → *Gamma* …').Count -ne 1) { $selfTestFails++ }   # Pfeil-Form (C1)
if ($innerAnchorRxA.Matches('State ignoriert -> *Gamma* …').Count -ne 1) { $selfTestFails++ }  # ASCII-Pfeil (Cold-Eyes A)
if ((Test-AnchorResolves $stSecs 'Zins-Gutschrift -> fett-lead') -ne $true) { $selfTestFails++ }   # Nested-Split ASCII
$stM3 = $anchorPointerRx.Matches('vgl. `packages/CLAUDE.md` -> *Alpha*')
if ($stM3.Count -ne 1)                                          { $selfTestFails++ }   # Pointer-Separator ASCII
if ($innerAnchorRxB.Matches('… *Delta* oben …').Count -ne 1)    { $selfTestFails++ }
if ($innerAnchorRxB.Matches('… **Fett** oben …').Count -ne 0)   { $selfTestFails++ }   # fett != Anker
if ($selfTestFails -gt 0) {
    Fail 'doc_lint.ps1' "Check-8-Selbst-Assert fehlgeschlagen ($selfTestFails) -- Anker-Extraktion/-Matching defekt, Scan abgebrochen."
    Write-Host ""; Write-Host "doc_lint: $fails Drift-Befund(e)." -ForegroundColor Red
    exit $fails
}

# Korpus fuer 8/8b: CLAUDE.mds + BACKLOG + Onboarding-Doku + docs/ (ohne generierte Kataloge).
$anchorDocs = @($docFiles)
foreach ($extra in @('README.md', 'AGENTS.md', 'CONTRIBUTING.md', 'SECURITY.md')) {
    $p = Join-Path $RepoRoot $extra
    if (Test-Path $p) { $anchorDocs += Get-Item $p }
}
$anchorDocs += @(Get-ChildItem (Join-Path $RepoRoot 'docs') -Filter '*.md' -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -ne 'fn_catalog.md' })

foreach ($doc in $anchorDocs) {
    $rel = $doc.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/'
    $ownSections = $null
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadAllLines($doc.FullName)) {
        $lineNo++
        if ($line -match 'lint-ignore') { continue }

        # 8) Datei-Pointer `x.md` *Sektion*
        $pointerSpans = @()
        foreach ($m in $anchorPointerRx.Matches($line)) {
            $pointerSpans += , @($m.Index, ($m.Index + $m.Length))
            $tok = $m.Groups['file'].Value.Trim()
            if ($tok -match $placeholderRx) { continue }
            $target = Join-Path $RepoRoot ($tok -replace '/', '\')
            if (-not (Test-Path $target)) {
                & git -C $RepoRoot check-ignore -q -- $tok
                if ($LASTEXITCODE -ne 0) { Fail "$rel`:$lineNo" "Sektions-Pointer-Ziel existiert nicht: ``$tok``" }
                continue
            }
            $secs = Get-DocSections $target
            foreach ($sm in [regex]::Matches($m.Groups['secs'].Value, '\*([^*]+)\*')) {
                $anchor = $sm.Groups[1].Value
                if (-not (Test-AnchorResolves $secs $anchor)) {
                    Fail "$rel`:$lineNo" "Sektions-Anker loest nicht auf: ``$tok`` *$anchor* (keine passende Ueberschrift/Fett-Lead im Ziel)."
                }
            }
        }

        # 8b) interne Anker -- nur ausserhalb der Check-8-Pointer-Spans
        $cands = @{}
        foreach ($m in $innerAnchorRxA.Matches($line)) { $cands[$m.Groups[1].Index] = $m.Groups[1].Value }
        foreach ($m in $innerAnchorRxB.Matches($line)) { $cands[$m.Groups[1].Index] = $m.Groups[1].Value }
        foreach ($idx in $cands.Keys) {
            $inPointer = $false
            foreach ($span in $pointerSpans) { if ($idx -ge $span[0] -and $idx -lt $span[1]) { $inPointer = $true; break } }
            if ($inPointer) { continue }
            if ($null -eq $ownSections) { $ownSections = Get-DocSections $doc.FullName }
            $anchor = $cands[$idx]
            if (-not (Test-AnchorResolves $ownSections $anchor)) {
                Fail "$rel`:$lineNo" "Interner Anker *$anchor* loest in $rel nicht auf -- Sektion umbenannt/verschoben? Cross-File-Verweis als ``datei.md`` *Sektion* schreiben."
            }
        }
    }
}

# ---------------------------------------------------------------
# 9) Laengen-Gate fuer JEDE CLAUDE.md (Anthropic-Guidance: "target under 200 lines per CLAUDE.md;
#    longer files reduce adherence"). Hart > 200 Zeilen ODER > 16 KB (Root > 12 KB), Hinweis Root > 150 Zeilen.
#    Bytes sind der ehrliche Massstab fuer geladenen Kontext (Harness-Rightsizing 2026-10-20: 199 absatz-lange
#    Zeilen waren 45 KB); eine Sub-CLAUDE.md laedt komplett, sobald irgendeine Datei ihres Ordners geoeffnet wird
#    (Phase 3: 470 KB in zehn Sub-Dateien). Zweck + Regeln + Zeiger bleiben; Mechanik/Historie -> docs/reference/,
#    ordner-uebergreifende Regeln -> .claude/rules/.
# ---------------------------------------------------------------
foreach ($cf in ($docFiles | Where-Object { $_.Name -eq 'CLAUDE.md' })) {
    $cfRel  = $cf.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/'
    $isRoot = ($cfRel -eq 'CLAUDE.md')
    $cfLines = (Get-Content $cf.FullName).Count
    $cfMaxKb = if ($isRoot) { 12 } else { 16 }
    if ($cfLines -gt 200) {
        Fail "${cfRel}:$cfLines" "> 200 Zeilen (Anthropic: 'target under 200; longer reduces adherence') -- Mechanik/Historie nach docs/reference/, Prozeduren in Skills, kurze Regelzeilen."
    } elseif ($isRoot -and $cfLines -gt 150) {
        Write-Host "  [Hinweis] Root-CLAUDE.md = $cfLines Zeilen (> 150; Anthropic-Optimum ~150) -- bei Wachstum verschlanken." -ForegroundColor Yellow
    }
    if ($cf.Length -gt ($cfMaxKb * 1KB)) {
        Fail $cfRel ("{0:N1} KB (> {1} KB): Zweck + Regeln + Zeiger bleiben, Mechanik/Fallgeschichten nach docs/reference/<bereich>.md -- kurze Zeilen." -f ($cf.Length / 1KB), $cfMaxKb)
    }
}

# Get-Pin <text> <regex> <was> -> erste Gruppe des Treffers; kein Treffer = Fail (Extraktion tot). Geteilt von Check 11 + 11b.
function Get-Pin([string]$Text, [string]$Rx, [string]$What) {
    $m = [regex]::Match($Text, $Rx)
    if (-not $m.Success) { Fail 'doc_lint.ps1' "Pin-Check: $What nicht extrahierbar (Regex traf nichts) -- Quelle umgeschrieben?"; return $null }
    return $m.Groups[1].Value
}

# ---------------------------------------------------------------
# 11) Pin-Anti-Drift: $DevEnvPins (scripts/lib/devenv.ps1) == externe Zweitquellen. Fail statt
#     Silent-Skip (Muster Check 6/10): bewegt sich eine Quelle, muss das Lint schreien.
# ---------------------------------------------------------------
$devenvLib = Join-Path $RepoRoot 'scripts\lib\devenv.ps1'
$ciYml     = Join-Path $RepoRoot '.github\workflows\ci.yml'
$siteDrv   = Join-Path $RepoRoot 'scripts\build_site.ps1'
if (-not (Test-Path $devenvLib)) { Fail 'scripts/lib/devenv.ps1' 'Pin-SoT fehlt (bewegt/geloescht?) -- Check 11 kann nicht greifen.' }
if (-not (Test-Path $ciYml))     { Fail '.github/workflows/ci.yml' 'CI-Workflow fehlt -- gitleaks/squawk-Pins fuer Check 11 nicht extrahierbar.' }
if (-not (Test-Path $siteDrv))   { Fail 'scripts/build_site.ps1' 'build_site.ps1 fehlt -- Hugo-Pin fuer Check 11 nicht extrahierbar.' }
if ((Test-Path $devenvLib) -and (Test-Path $ciYml) -and (Test-Path $siteDrv)) {
    $libText  = [System.IO.File]::ReadAllText($devenvLib)
    $ciText   = [System.IO.File]::ReadAllText($ciYml)
    $siteText11 = [System.IO.File]::ReadAllText($siteDrv)
    # SoT-Pins aus $DevEnvPins.
    $pinGitleaks = Get-Pin $libText "gitleaks\s*=\s*'([0-9][0-9.]+)'"      'devenv.ps1 gitleaks-Pin'
    $pinSquawk   = Get-Pin $libText "squawk\s*=\s*'([0-9][0-9.]+)'"        'devenv.ps1 squawk-Pin'
    $pinHugo     = Get-Pin $libText "hugo\s*=\s*'([0-9][0-9.]+)'"          'devenv.ps1 hugo-Pin'
    # Externe Zweitquellen. gitleaks = die bare bash-Zuweisung am Zeilenanfang (kein '$'); squawk hat
    # DIESELBE '$ver'-Form wie der prek-Pin daneben -> auf den "Install squawk"-Block skopen (lazy, (?s)).
    $ciGitleaks  = Get-Pin $ciText  "(?m)^\s*ver=([0-9][0-9.]+)"                            'ci.yml gitleaks-Pin'
    $ciSquawk    = Get-Pin $ciText  "(?s)Install squawk.*?\`$ver\s*=\s*'v([0-9][0-9.]+)'"    'ci.yml squawk-Pin'
    $siteHugo    = Get-Pin $siteText11 "\`$PinnedHugoVersion\s*=\s*'([0-9][0-9.]+)'"         'build_site.ps1 Hugo-Pin'
    if ($pinGitleaks -and $ciGitleaks -and ($pinGitleaks -ne $ciGitleaks)) { Fail 'scripts/lib/devenv.ps1' "gitleaks-Pin '$pinGitleaks' != ci.yml '$ciGitleaks' -- Pins synchron halten." }
    if ($pinSquawk   -and $ciSquawk   -and ($pinSquawk   -ne $ciSquawk))   { Fail 'scripts/lib/devenv.ps1' "squawk-Pin '$pinSquawk' != ci.yml 'v$ciSquawk' -- Pins synchron halten." }
    if ($pinHugo     -and $siteHugo   -and ($pinHugo     -ne $siteHugo))   { Fail 'scripts/lib/devenv.ps1' "hugo-Pin '$pinHugo' != build_site.ps1 '$siteHugo' -- Pins synchron halten." }

    # CONTRIBUTING.md-Copy-paste-Download-Befehle (Muster Check 5): jedes gepinnte Download-Artefakt
    # == der SoT-Pin (ALLE Vorkommen -> ein vergessener Teil-Bump faellt auf; Fail bei 0 = Extraktion tot).
    $contribPath = Join-Path $RepoRoot 'CONTRIBUTING.md'
    if (-not (Test-Path $contribPath)) { Fail 'CONTRIBUTING.md' 'CONTRIBUTING.md fehlt -- Check-11-Copy-paste-Pin-Abgleich nicht moeglich.' }
    else {
        $contribText = [System.IO.File]::ReadAllText($contribPath)
        function Assert-DocPins([string]$Text, [string]$Rx, [string]$Pin, [string]$What) {
            if (-not $Pin) { return }   # SoT-Extraktion oben schon gefailt
            $ms = [regex]::Matches($Text, $Rx)
            if ($ms.Count -eq 0) { Fail 'CONTRIBUTING.md' "Check 11: $What (Regex '$Rx') traf nichts -- Download-Befehl umgeschrieben?"; return }
            foreach ($mm in $ms) { if ($mm.Groups[1].Value -ne $Pin) { Fail 'CONTRIBUTING.md' "$What '$($mm.Groups[1].Value)' != Pin '$Pin' (scripts/lib/devenv.ps1) -- Download-Befehl nachziehen." } }
        }
        Assert-DocPins $contribText 'gitleaks_([0-9][0-9.]+)_windows'          $pinGitleaks 'CONTRIBUTING gitleaks-Download'
        Assert-DocPins $contribText 'squawk/releases/download/v([0-9][0-9.]+)' $pinSquawk   'CONTRIBUTING squawk-Download'
        Assert-DocPins $contribText 'hugo_([0-9][0-9.]+)_windows'             $pinHugo     'CONTRIBUTING hugo-Download'
    }
}

# ---------------------------------------------------------------
# 11b) Laufzeit-Pins (n8n / PostgreSQL / Node.js): SoT = die Defaults in provisioning/provision.sh. Jede
#      Versions-Nennung in den Owner-/Contributor-Docs muss gleich sein (vorher 9 Stellen per Hand -> Drift).
#      n8n: jedes 2.x.y-Token der Datei (die Dateien nennen keine anderen 2.x.y-Versionen); mind. 1 Treffer je
#      Datei, sonst ist die Extraktion tot. PostgreSQL/Node.js: jede "PostgreSQL <n>"/"Node.js <n>"-Nennung.
# ---------------------------------------------------------------
$provSh = Join-Path $RepoRoot 'provisioning\provision.sh'
if (-not (Test-Path $provSh)) { Fail 'provisioning/provision.sh' 'provision.sh fehlt -- Laufzeit-Pins fuer Check 11b nicht extrahierbar.' }
else {
    $provText = [System.IO.File]::ReadAllText($provSh)
    $pinN8n  = Get-Pin $provText '(?m)^N8N_VERSION="\$\{N8N_VERSION:-([0-9.]+)\}"' 'provision.sh N8N_VERSION'
    $pinPg   = Get-Pin $provText '(?m)^PG_VERSION="\$\{PG_VERSION:-([0-9]+)\}"'    'provision.sh PG_VERSION'
    $pinNode = Get-Pin $provText '(?m)^NODE_MAJOR="\$\{NODE_MAJOR:-([0-9]+)\}"'    'provision.sh NODE_MAJOR'
    $verDocs = @('CLAUDE.md', 'AGENTS.md', 'README.md', 'SECURITY.md',
                 'docs\site\layouts\partials\footer.html', 'docs\site\content\docs\installation.md', 'packages\CLAUDE.md')
    foreach ($vd in $verDocs) {
        $vdPath = Join-Path $RepoRoot $vd
        $vdRel  = $vd -replace '\\', '/'
        if (-not (Test-Path $vdPath)) { Fail $vdRel 'Check 11b: Datei fehlt (bewegt?) -- Liste in doc_lint.ps1 nachziehen.'; continue }
        $vdText = [System.IO.File]::ReadAllText($vdPath)
        if ($pinN8n) {
            $ms = [regex]::Matches($vdText, '(?<![\d.v])(2\.\d{1,2}\.\d{1,2})(?![\d.])')
            if ($ms.Count -eq 0) { Fail $vdRel "Check 11b: keine n8n-Versionsnennung gefunden -- Datei aus der Liste nehmen oder Nennung wiederherstellen." }
            foreach ($mm in $ms) { if ($mm.Groups[1].Value -ne $pinN8n) { Fail $vdRel "n8n-Version '$($mm.Groups[1].Value)' != Pin '$pinN8n' (provisioning/provision.sh)." } }
        }
        if ($pinPg) {
            foreach ($mm in [regex]::Matches($vdText, 'PostgreSQL\s+(?:to\s+)?\*{0,2}(\d{2})\b')) {
                if ($mm.Groups[1].Value -ne $pinPg) { Fail $vdRel "PostgreSQL-Version '$($mm.Groups[1].Value)' != Pin '$pinPg' (provisioning/provision.sh)." }
            }
            $mPg = [regex]::Match($vdText, '(?s)id:\s*pg-version.*?value:\s*"?(\d+)"?')
            if ($mPg.Success -and $mPg.Groups[1].Value -ne $pinPg) { Fail $vdRel "PostgreSQL-Vorgabe '$($mPg.Groups[1].Value)' != Pin '$pinPg' (provisioning/provision.sh)." }
        }
        if ($pinNode) {
            foreach ($mm in [regex]::Matches($vdText, 'Node\.js\s+\*{0,2}(\d{2})\b')) {
                if ($mm.Groups[1].Value -ne $pinNode) { Fail $vdRel "Node.js-Version '$($mm.Groups[1].Value)' != Pin '$pinNode' (provisioning/provision.sh)." }
            }
        }
    }
}

# ---------------------------------------------------------------
Write-Host ""
if ($fails -eq 0) { Write-Host "doc_lint: alles konsistent (0 Fails)." -ForegroundColor Green }
else              { Write-Host "doc_lint: $fails Drift-Befund(e) -- Doku gegen den Datei-Bestand abgleichen." -ForegroundColor Red }
exit $fails
