#Requires -Version 5.1
# layout_lint.ps1 -- Repo-Layout-/Struktur-Lint (hartes Commit-Gate, Vorbild approval_lint.ps1 +
# core_literal_lint.ps1). Macht die Struktur-Aufraeumung (Plan greedy-roaming-falcon, WP-10) erstmals
# zur INVARIANTE statt zur Konvention: was S1-S5a von Hand aufgeraeumt haben, kann strukturell nicht
# mehr zurueckdriften. git-ls-files-basiert = platten-zustands-unabhaengig (transiente Agent-Worktrees
# unter .claude/** + gitignorte .local/** sind strukturell ausgeschlossen -- sie sind nicht getrackt).
#
# Sieben Checks (jeder mit synthetischen Selbst-Asserts VOR dem Scan -- unbedingt, kein Schalter; stirbt
# die Extraktion/Praedikat-Logik still, wird das Lint hart rot statt leise gruen):
#   L1 Top-Level-Allowlist: jeder getrackte Root-Eintrag (Dir bzw. Datei) steht in der In-Skript-Allowlist
#      -> re-committetes db/ o.ae. failt hart.
#   L2 Paket-Contract: je packages/<pkg>/ sind manifest.json + CLAUDE.md + build/ + workflows/ PFLICHT
#      (schliesst die Fail-Open-Luecke: command_lint/config_test ueberspringen manifest-lose Pakete still);
#      Subdirs subset {db,build,contexts,seed,workflows,onboarding,locales}; direkt unter dem Paket nur
#      manifest.json/CLAUDE.md; direkt unter packages/ nur CLAUDE.md.
#   L3 Tests-Contract: alles unter tests/ matcht tests/(db|agent)/(<pkg>|cross)/... | util/ | fixtures/ |
#      mock_*/ | CLAUDE.md. Die <pkg>-Alternation kommt zur Laufzeit aus L2 (keine Namensliste).
#   L4 Retired-Roots-Ratchet: verbotene Root-Tokens db//n8n/ in getrackten Textdateien (negative Lookbehind
#      INKL. @ -> kein FP auf @n8n/n8n-nodes-langchain; + ^/(db|n8n)/-Alternative fuer CODEOWNERS). Scope
#      deny-basiert (git ls-files minus generierte + Flyway-V-Migrations-Klassen). Zweistufige Suppression:
#      (a) 'lint-ignore' in der Zeile (Bestandsmechanik, fuer deliberate Meta-/Enforcement-Doku-Zeilen);
#      (b) scripts/build/retired_paths_allowlist.json (Ratchet nach core_literal-Muster: exakt
#      Found==Allowlist je (Datei, Token), Neues=FAIL, entferntes=count-schrumpfen, Orphan=FAIL).
#      -Baseline druckt das Allowlist-Geruest.
#   L5 CLAUDE.md-Titel-Konvention: Zeile 1 jeder Sub-CLAUDE.md traegt "(... beim Arbeiten in `<realer Pfad>/`)"
#      (Root-CLAUDE.md ausgenommen -- always-loaded, kein verzeichnisgebundener Auto-Load). Laengen-Gate
#      jeder CLAUDE.md = doc_lint Check 9 (eine Adresse; der fruehere weiche 400-Zeilen-Hinweis hier ist entfallen).
#   L6 (nur Haelfte 2) Pathspec-Listen-Check: die drei slashlosen Mirror-/Archiv-Listen (release.yml
#      git-archive-Pathspec, provision.sh install_cli-Mirror, bootstrap_test_n8n-foreach) -- jedes
#      Listen-Token loest als getracktes Root-Artefakt auf ODER ist ein bekanntes Release-Artefakt
#      (VERSION). Deckt die ZWEI schwersten realen Vorfaelle (release.yml-pathspec-BLOCKER + set-e-Bruch
#      im Mirror). Extraktion 0 Treffer = FAIL (Zeile verschoben/reformatiert = totes Gate).
#      Haelfte 1 (jeder .pre-commit-config-files:-Filter matcht >=1 Pfad) laeuft ueber die prek-nativen
#      repo:meta-Hooks check-hooks-apply + check-useless-excludes (arch-ADOPT S5a) -- NICHT hier.
#   L7 (SOLLTE) SQL-Selbst-/Tests-Header: jeder Repo-Pfad-Token im fuehrenden Kommentar-Block einer
#      tests/db/**- oder packages/*/db/**-SQL existiert (verschobene Datei -> alter Self-Header-Pfad ist
#      weg -> Fail); ein Token mit dem eigenen Dateinamen muss dem realen Pfad gleichen.
#
# Erweitern der L1/L2/L3-Allowlists oder des L4-Ban-Sets = bewusster reviewter Edit der In-Skript-Arrays
# (+ Begruendung), nie ad-hoc -> docs/reference/packages.md *Struktur-Invariante*.
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Substrat.
param([switch]$Baseline, [switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

# --- Konfig-Sets (In-Skript = bewusster Review-Diff bei Erweiterung; docs/reference/packages.md *Struktur-Invariante*) ---
$L1Dirs  = @('.claude', '.github', 'config', 'docs', 'packages', 'provisioning', 'scripts', 'tests')
$L1Files = @('.editorconfig', '.env.example', '.gitattributes', '.gitignore', '.pre-commit-config.yaml', '.worktreeinclude',
             'AGENTS.md', 'BACKLOG.md', 'CLAUDE.md', 'CONTRIBUTING.md', 'LICENSE', 'README.md', 'SECURITY.md')
$L2Subdirs     = @('db', 'build', 'contexts', 'seed', 'workflows', 'onboarding', 'locales')
$L2Required    = @('manifest.json', 'CLAUDE.md', 'build', 'workflows')   # je Paket Pflicht (Owner-Entscheid S5b)
$L2DirectFiles = @('manifest.json', 'CLAUDE.md')                         # einzige direkt-im-Paket erlaubten Dateien
$L6Generated   = @('VERSION')   # Release-Zeit-Artefakt, nicht getrackt (provision.sh install_cli-Mirror)
$placeholderRx = '[<>{}\*\$\s]|http|\.\.\.'
$L4Rx  = [regex]'((?<![\w./@-])(?:db|n8n)/)|(^/(?:db|n8n)/)'
$L7PathRx = [regex]'(?:packages/[^/\s<>]+/db|tests/db/[a-z]+|tests/(?:util|fixtures))/[A-Za-z0-9_./-]+\.(?:sql|md|json)'

function Test-L1TopLevel([string]$rel) {
    if ($rel -match '/') { return ($script:L1Dirs -contains (($rel -split '/', 2)[0])) }
    return ($script:L1Files -contains $rel)
}
function Test-L2Path([string]$rel) {
    $parts = $rel -split '/'
    if ($parts.Count -eq 2) { return ($parts[1] -eq 'CLAUDE.md') }                  # packages/<datei>
    if ($parts.Count -eq 3) { return ($script:L2DirectFiles -contains $parts[2]) }  # packages/<pkg>/<datei>
    return ($script:L2Subdirs -contains $parts[2])                                  # packages/<pkg>/<subdir>/...
}
function Test-L3Path([string]$rel, $pkgSet) {
    $parts = $rel -split '/'
    if ($parts.Count -eq 2) { return ($parts[1] -eq 'CLAUDE.md') }                  # tests/CLAUDE.md
    $top = $parts[1]
    if ($top -eq 'db' -or $top -eq 'agent') {
        if ($parts.Count -lt 4) { return $false }                                   # muss paket-/cross-bucketed sein
        return ($pkgSet -contains $parts[2]) -or ($parts[2] -eq 'cross')
    }
    if ($top -eq 'util' -or $top -eq 'fixtures') { return $true }
    if ($top -like 'mock_*') { return $true }
    return $false
}
function Get-L4Token([string]$val) { if ($val -match 'n8n') { return 'n8n/' } else { return 'db/' } }
# Tokens einer Zeile (leer, wenn 'lint-ignore' in der Zeile = Stage-1-Suppression). Als Funktion,
# damit der Scan UND der Selbst-Assert dieselbe Logik teilen (die lint-ignore-Wirkung ist so testbar).
function Get-L4LineTokens([string]$line) {
    if ($line -match 'lint-ignore') { return @() }
    return @($script:L4Rx.Matches($line) | ForEach-Object { Get-L4Token $_.Value })
}
function Test-L4Skip([string]$rel) {
    if ($rel -match '/migrations/V[0-9]+__') { return $true }                        # eingefrorene Flyway-V-Migrationen
    if ($rel -eq 'docs/fn_catalog.md') { return $true }                              # generiert (gen_fn_catalog)
    if ($rel -match '^docs/site/') { return $true }                                  # Showcase-Site (Site-Phase): public/ generiert (build_site.ps1 -Verify), Quellen = Nutzer-Prosa
    if ($rel -match '^packages/[^/]+/seed/capabilities_catalog') { return $true }    # generiert (build.ps1 -VerifyCatalog)
    if ($rel -match '^packages/[^/]+/workflows/.*\.json$') { return $true }          # generiert (build.ps1)
    if ($rel -eq 'scripts/layout_lint.ps1') { return $true }                         # self (eigenes Regex/Beispiele)
    if ($rel -eq 'scripts/build/retired_paths_allowlist.json') { return $true }      # die Allowlist-Daten selbst
    return $false
}
# L6-Sites: file + per-Zeile-Extraktions-Regex + Token-Split ('ws' = Whitespace; 'psarray' = 'a','b')
$L6Sites = @(
    @{ file = '.github/workflows/release.yml';      rx = '^\s*HEAD\s+(.+)$';                 split = 'ws' },
    @{ file = 'provisioning/provision.sh';          rx = 'for\s+d\s+in\s+(.+?);\s*do';       split = 'ws' },
    @{ file = 'scripts/dev/bootstrap_test_n8n.ps1'; rx = 'foreach\s*\(\s*\$d\s+in\s+(.+?)\)'; split = 'psarray' }
)
function Get-L6Tokens([string]$group, [string]$split) {
    if ($split -eq 'psarray') { return @([regex]::Matches($group, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
    return @(($group.Trim() -split '\s+') | Where-Object { $_ })
}
function Get-LeadingCommentTokens([string[]]$Lines) {
    $toks = New-Object System.Collections.Generic.List[string]
    foreach ($l in $Lines) {
        if ($l -match '^\s*$') { continue }                                          # Leerzeile im Header-Block: ueberspringen, nicht abbrechen
        if ($l -notmatch '^\s*--') { break }                                         # erst ein echtes Code-Statement (CREATE ...) beendet den Header-Block
        foreach ($mm in $script:L7PathRx.Matches($l)) {
            if ($mm.Value -notmatch $script:placeholderRx) { $toks.Add($mm.Value) }
        }
    }
    return $toks
}

# =====================================================================================================
# Selbst-Asserts: synthetische Fixtures je Check VOR dem Scan (unbedingt, kein Schalter -- Antwort auf "Waechter stirbt still")
# =====================================================================================================
$st = 0
# L1
if (-not (Test-L1TopLevel 'packages/x/y.ps1')) { $st++ }
if (-not (Test-L1TopLevel 'README.md'))        { $st++ }
if (Test-L1TopLevel 'db/x.sql')                { $st++ }
if (Test-L1TopLevel 'evil.md')                 { $st++ }
# L2
if (-not (Test-L2Path 'packages/CLAUDE.md'))              { $st++ }
if (-not (Test-L2Path 'packages/core/manifest.json'))     { $st++ }
if (-not (Test-L2Path 'packages/core/build/x.ps1'))       { $st++ }
if (-not (Test-L2Path 'packages/core/db/migrations/x.sql')) { $st++ }
if (Test-L2Path 'packages/core/stray.txt')                { $st++ }   # direkte Fremd-Datei
if (Test-L2Path 'packages/core/badsub/x.ps1')             { $st++ }   # Fremd-Subdir
if (Test-L2Path 'packages/evil.md')                       { $st++ }   # Fremd-Datei direkt unter packages/
# L3
if (-not (Test-L3Path 'tests/db/core/x.sql' @('core')))       { $st++ }
if (-not (Test-L3Path 'tests/agent/cross/y.json' @('core')))  { $st++ }
if (-not (Test-L3Path 'tests/util/z.sql' @('core')))          { $st++ }
if (-not (Test-L3Path 'tests/mock_llm/s.js' @('core')))       { $st++ }
if (-not (Test-L3Path 'tests/CLAUDE.md' @('core')))           { $st++ }
if (Test-L3Path 'tests/db/bogus/x.sql' @('core'))             { $st++ }   # unbekanntes Bucket
if (Test-L3Path 'tests/random/x.txt' @('core'))               { $st++ }   # unbekannter Top-Ordner
if (Test-L3Path 'tests/db/x.sql' @('core'))                   { $st++ }   # nicht paket-bucketed
# L4
if ($L4Rx.IsMatch('packages/core/db/x'))   { $st++ }   # innerhalb Pfad -> kein Treffer
if ($L4Rx.IsMatch('@n8n/n8n-nodes'))       { $st++ }   # @-praefixt -> kein Treffer (Verifier-Fund)
if ($L4Rx.IsMatch('foo-db/bar'))           { $st++ }   # bindestrich-praefixt -> kein Treffer
if (-not $L4Rx.IsMatch('vgl. `db/`'))      { $st++ }   # backtick-gequotet -> Treffer
if (-not $L4Rx.IsMatch('laeuft n8n/foo'))  { $st++ }   # freistehend -> Treffer
if (-not $L4Rx.IsMatch('/db/migrations @x')) { $st++ } # CODEOWNERS-Form (Zeilenanfang) -> Treffer
if ((Get-L4Token 'n8n/') -ne 'n8n/')       { $st++ }
if ((Get-L4Token 'db/')  -ne 'db/')        { $st++ }
if ((Get-L4LineTokens 'vgl. `db/` und n8n/foo').Count -ne 2)    { $st++ }   # zwei Tokens je Zeile
if ((Get-L4LineTokens 'vgl. `db/` -- lint-ignore').Count -ne 0) { $st++ }   # lint-ignore -> Zeile uebersprungen
if ((Get-L4LineTokens 'packages/core/db/x').Count -ne 0)        { $st++ }   # innerhalb Pfad -> nichts
# L5 (Titel-Substring, ASCII-Teil)
if (('# Scripts (laedt beim Arbeiten in `scripts/`)').IndexOf('beim Arbeiten in `scripts/`') -lt 0) { $st++ }
if (('# Ohne Titelmarker').IndexOf('beim Arbeiten in `scripts/`') -ge 0) { $st++ }
# L6
$st6a = Get-L6Tokens ((([regex]'^\s*HEAD\s+(.+)$').Match('            HEAD provisioning packages .gitattributes')).Groups[1].Value) 'ws'
if (($st6a -join ',') -ne 'provisioning,packages,.gitattributes') { $st++ }
$st6b = Get-L6Tokens ((([regex]'foreach\s*\(\s*\$d\s+in\s+(.+?)\)').Match("foreach (`$d in 'provisioning','packages') {")).Groups[1].Value) 'psarray'
if (($st6b -join ',') -ne 'provisioning,packages') { $st++ }
$st6c = Get-L6Tokens ((([regex]'for\s+d\s+in\s+(.+?);\s*do').Match('  for d in provisioning packages VERSION; do')).Groups[1].Value) 'ws'
if (($st6c -join ',') -ne 'provisioning,packages,VERSION') { $st++ }
# L7
$st7 = Get-LeadingCommentTokens @('-- packages/finance/db/migrations/R__fn_x.sql',
                                  '',                                                # Leerzeile mitten im Header -> NICHT abbrechen (sonst wird der Tests:-Token verpasst)
                                  '--   Tests: tests/db/finance/test_fn_x.sql',
                                  '-- siehe packages/<pkg>/db/migrations/R__x.sql (Platzhalter)',
                                  'CREATE FUNCTION finance.fn_x() ...')
if ($st7.Count -ne 2) { $st++ }   # 2 echte Pfade trotz Leerzeile; Platzhalter (<pkg>) verworfen; Break erst an CREATE
if ($st -gt 0) {
    Fail "Selbst-Assert fehlgeschlagen ($st) -- Praedikat-/Extraktions-Logik defekt, Scan abgebrochen."
    Write-Host "layout_lint: $fails Fehler (Selbst-Assert)." -ForegroundColor Red
    exit $fails
}

# =====================================================================================================
# Getrackte Datei-Liste + Paketnamen (L2/L3-Alternation zur Laufzeit)
# =====================================================================================================
$tracked = @(git -C $RepoRoot ls-files)
$pkgNames = @($tracked | Where-Object { $_ -match '^packages/[^/]+/' } | ForEach-Object { ($_ -split '/')[1] } | Sort-Object -Unique)

# =====================================================================================================
# L4 zuerst berechnen (fuer -Baseline UND Ratchet-Vergleich): Found je (relfile|token) -> count
# =====================================================================================================
$found = @{}
foreach ($rel in $tracked) {
    if (Test-L4Skip $rel) { continue }
    $full = Join-Path $RepoRoot ($rel -replace '/', '\')
    if (-not (Test-Path $full)) { continue }
    foreach ($line in [System.IO.File]::ReadAllLines($full, $u8)) {
        foreach ($tok in (Get-L4LineTokens $line)) {
            $key = "$rel|$tok"
            if ($found.ContainsKey($key)) { $found[$key]++ } else { $found[$key] = 1 }
        }
    }
}
if ($Baseline) {
    $entries = foreach ($k in ($found.Keys | Sort-Object)) {
        $p = $k -split '\|', 2
        [ordered]@{ file = $p[0]; token = $p[1]; count = $found[$k]; reason = 'TODO' }
    }
    [ordered]@{ _comment = 'Baseline -- Begruendung je Eintrag eintragen (retired-note|package-relative|prose-FP).'; allow = @($entries) } |
        ConvertTo-Json -Depth 6
    exit 0
}

# =====================================================================================================
# L1 -- Top-Level-Allowlist
# =====================================================================================================
foreach ($rel in $tracked) {
    if (-not (Test-L1TopLevel $rel)) {
        $seg = if ($rel -match '/') { (($rel -split '/', 2)[0]) + '/' } else { $rel }
        Fail "L1: Top-Level-Eintrag nicht in der Allowlist: '$seg' (aus $rel) -- Struktur-Invariante; Array in layout_lint.ps1 bewusst erweitern ODER Datei umziehen."
    }
}

# =====================================================================================================
# L2 -- Paket-Contract
# =====================================================================================================
$trackedSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($t in $tracked) { [void]$trackedSet.Add($t) }
foreach ($pkg in $pkgNames) {
    foreach ($req in $L2Required) {
        if ($req -eq 'manifest.json' -or $req -eq 'CLAUDE.md') {
            if (-not $trackedSet.Contains("packages/$pkg/$req")) {
                Fail "L2: packages/$pkg/ fehlt Pflicht-Datei '$req' (Fail-Open-Luecke: manifest-lose Pakete werden von command_lint/config_test still uebersprungen)."
            }
        } else {
            if (-not ($tracked | Where-Object { $_ -like "packages/$pkg/$req/*" } | Select-Object -First 1)) {
                Fail "L2: packages/$pkg/ fehlt Pflicht-Verzeichnis '$req/'."
            }
        }
    }
}
foreach ($rel in ($tracked | Where-Object { $_ -like 'packages/*' })) {
    if (-not (Test-L2Path $rel)) {
        Fail "L2: Paket-Pfad verletzt den Contract: '$rel' (erlaubt: packages/CLAUDE.md; je Paket manifest.json/CLAUDE.md + Subdirs {$($L2Subdirs -join ',')})."
    }
}

# =====================================================================================================
# L3 -- Tests-Contract
# =====================================================================================================
foreach ($rel in ($tracked | Where-Object { $_ -like 'tests/*' })) {
    if (-not (Test-L3Path $rel $pkgNames)) {
        Fail "L3: Tests-Pfad verletzt den Contract: '$rel' (erlaubt: tests/(db|agent)/(<pkg>|cross)/... | util/ | fixtures/ | mock_*/ | CLAUDE.md)."
    }
}

# =====================================================================================================
# L4 -- Retired-Roots-Ratchet: Found <-> retired_paths_allowlist.json (exakt je (Datei, Token))
# =====================================================================================================
$alPath = Join-Path $RepoRoot 'scripts\build\retired_paths_allowlist.json'
if (-not (Test-Path $alPath)) {
    Fail "L4: Allowlist fehlt: $alPath (mit -Baseline erzeugen + Begruendungen eintragen)."
} else {
    $al = [System.IO.File]::ReadAllText($alPath, $u8) | ConvertFrom-Json
    $allow = @{}
    foreach ($e in $al.allow) {
        $key = "$([string]$e.file)|$([string]$e.token)"
        if ([string]::IsNullOrWhiteSpace([string]$e.reason)) { Fail "L4-allowlist: Eintrag '$key' ohne reason (jede Ausnahme braucht eine Begruendung)." }
        if ($allow.ContainsKey($key)) { Fail "L4-allowlist: doppelter Eintrag '$key'."; continue }
        $allow[$key] = [int]$e.count
    }
    foreach ($key in ($found.Keys | Sort-Object)) {
        $p = $key -split '\|', 2
        if (-not $allow.ContainsKey($key)) {
            Fail "L4: NEUES Retired-Root-Token '$($p[1])' in $($p[0]) ($($found[$key])x) -- Root db//n8n/ ist verboten; umschreiben, 'lint-ignore' setzen ODER mit Begruendung in scripts/build/retired_paths_allowlist.json."
        } elseif ($allow[$key] -ne $found[$key]) {
            Fail "L4: Anzahl '$($p[1])' in $($p[0]): gefunden $($found[$key]), Allowlist $($allow[$key]) -- Allowlist-count anpassen (bei Entfernung schrumpfen)."
        }
    }
    foreach ($key in ($allow.Keys | Sort-Object)) {
        if (-not $found.ContainsKey($key)) {
            $p = $key -split '\|', 2
            Fail "L4: allowlist-ORPHAN '$($p[1])' in $($p[0]) -- Token nicht (mehr) vorhanden, Eintrag entfernen (Ratchet schrumpft)."
        }
    }
}

# =====================================================================================================
# L5 -- CLAUDE.md-Titel-Konvention (Sub-CLAUDE.mds; Root ausgenommen; Laengen-Gate = doc_lint Check 9)
# =====================================================================================================
foreach ($rel in ($tracked | Where-Object { $_ -match '(^|/)CLAUDE\.md$' -and $_ -ne 'CLAUDE.md' })) {
    $full  = Join-Path $RepoRoot ($rel -replace '/', '\')
    $lines = [System.IO.File]::ReadAllLines($full, $u8)
    $dir   = ($rel -replace '/CLAUDE\.md$', '')
    $needle = 'beim Arbeiten in `' + $dir + '/`'
    if ($lines.Count -eq 0 -or $lines[0].IndexOf($needle) -lt 0) {
        Fail "L5: $rel Zeile 1 traegt nicht die Titel-Konvention '(... beim Arbeiten in ``$dir/``)' -- verzeichnisgebundener Auto-Load-Hinweis fehlt/driftet."
    }
}

# =====================================================================================================
# L6 (Haelfte 2) -- Pathspec-/Mirror-Listen: jedes Token = getracktes Root-Artefakt oder Release-Artefakt
# =====================================================================================================
foreach ($site in $L6Sites) {
    $path = Join-Path $RepoRoot ($site.file -replace '/', '\')
    if (-not (Test-Path $path)) { Fail "L6: Pathspec-Listen-Site fehlt: $($site.file)"; continue }
    $rx = [regex]$site.rx
    $matched = $false
    foreach ($line in [System.IO.File]::ReadAllLines($path, $u8)) {
        $m = $rx.Match($line)
        if (-not $m.Success) { continue }
        $matched = $true
        foreach ($t in (Get-L6Tokens $m.Groups[1].Value $site.split)) {
            if (($script:L1Dirs -contains $t) -or ($script:L1Files -contains $t) -or ($script:L6Generated -contains $t)) { continue }
            Fail "L6: $($site.file): Pathspec-Token '$t' ist kein getracktes Top-Level-Artefakt (Root db/ o.ae. re-eingefuehrt? -> Release/Mirror braeche)."
        }
    }
    if (-not $matched) { Fail "L6: $($site.file): Pathspec-Liste nicht gefunden (Zeile verschoben/reformatiert = totes Gate)." }
}

# =====================================================================================================
# L7 (SOLLTE) -- SQL-Selbst-/Tests-Header: Pfad-Tokens im fuehrenden Kommentar-Block existieren
# =====================================================================================================
foreach ($rel in ($tracked | Where-Object { $_ -match '^(packages/[^/]+/db|tests/db)/.*\.sql$' })) {
    $full  = Join-Path $RepoRoot ($rel -replace '/', '\')
    $lines = [System.IO.File]::ReadAllLines($full, $u8)
    $base  = Split-Path $rel -Leaf
    foreach ($t in (Get-LeadingCommentTokens $lines)) {
        $tp = Join-Path $RepoRoot ($t -replace '/', '\')
        if (-not (Test-Path $tp)) {
            Fail "L7: ${rel}: Header-Pfad-Token existiert nicht: '$t' (verschoben/umbenannt -> Header nachziehen)."
        } elseif ((Split-Path $t -Leaf) -eq $base -and $t -ne $rel) {
            Fail "L7: ${rel}: Selbst-Header-Pfad '$t' != realer Pfad '$rel'."
        }
    }
}

# =====================================================================================================
if ($Verbose) { foreach ($k in ($found.Keys | Sort-Object)) { Write-Host "  L4 $k = $($found[$k])" -ForegroundColor DarkGray } }
Write-Host ""
if ($fails -eq 0) { Write-Host "layout_lint: OK (L1-L7 konsistent; $($tracked.Count) getrackte Pfade, $($pkgNames.Count) Pakete, $($found.Count) allowlistete Retired-Root-Stelle(n))." -ForegroundColor Green }
else              { Write-Host "layout_lint: $fails Fehler -- Layout/Struktur gegen die Invarianten abgleichen." -ForegroundColor Red }
exit $fails
