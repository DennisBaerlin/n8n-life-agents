#Requires -Version 5.1
# core_literal_lint.ps1 -- Phase 0 (WS-0b) "kein neues Core-Paket-Literal" (hartes Gate, Vorbild approval_lint.ps1).
# Verankert STRUKTURELL die Owner-Direktive (2026-06-28): der Core haelt KEINE neuen paket-spezifischen Hardcodes
# (Routing/Domaenen-Branch auf 'finance'/'career'/...) -- ein zweites/N-tes Paket muss generisch andocken, nicht
# via Hand-Edit am Core. Mechanik = RATCHET (Baseline-Allowlist): jedes HEUTE vorhandene Paket-Literal ist in
# scripts/build/core_literal_allowlist.json mit Begruendung gelistet (legitimer finance-first-Default ODER Schuld,
# die WS-0c entfernt). Der Lint erzwingt EXAKTE Uebereinstimmung Found<->Allowlist je (Datei, Literal):
#   - Found > Allowlist  -> NEUES Paket-Literal (FAIL: generisch bauen oder mit Begruendung allowlisten);
#   - Found < Allowlist  -> ein Literal wurde entfernt (FAIL: Allowlist-Eintrag schrumpfen = WS-0c-Fortschritt);
#   - Allowlist-Eintrag ohne Fund -> Orphan (FAIL: entfernen).
# Erkannte Literale = EXAKT-Wert je Nicht-Core-Paket P (aus packages/<P>/): 'P', 'P_advisor', 'agent.P',
#   'agent.P_advisor' (Domaenen-/Agent-/Routing-Kopplung) PLUS (Phase A) jeder in packages/<P>/manifest.json
#   deklarierte Kontext-Name (z. B. 'finance_profile', 'financial_planning') -- KEIN Substring (so faellt
#   'finance_accounts' NICHT faelschlich rein). Single- ODER Double-Quote.
#   PLUS (Phase B) zwei UNGEQUOTETE Token-Klassen je Nicht-Core-Paket P: schema-qualifizierte Bezeichner
#   'P.<ident>' (z. B. finance.fx_rates — eine Core-fn, die Paket-Tabellen liest, war genau die fx_rate-Naht) und
#   die Paket-Rollen 'P_ro'/'P_rw' (z. B. die frueheren REVOKE ... FROM finance_ro). Wortgrenzen-genau mit negativem
#   Lookbehind (real_estate. != estate., agent.finance.cron_x != finance.<ident>).
#   PLUS (Phase C) die AGENT-NAMEN-Klasse: jeder in einem Nicht-Core-Manifest unter provides.agents[].name
#   deklarierte Agent als 'agent.<name>' (auch als Praefix von agent.<name>.tool_x) und — wenn der Name ein '_'
#   traegt — bar ('finance_advisor'); wortgrenzen-genau (agent.finance_chat_memory / finance_advisor_instructions
#   sind KEINE Treffer). Bares 'finance' bleibt der Quoted-Klasse (englisches Wort in Prosa). Ein Treffer INNERHALB
#   eines schon von der Quoted-Klasse gezaehlten Literals zaehlt nicht doppelt. Die Klasse existiert, weil der
#   Verteiler-Prompt alle Paket-Agenten als Prosa nannte, ohne dass ein Waechter es sah.
#   PLUS (Phase D) fuer die BAU-ENGINE scripts/build/**/*.ps1 eine STRENGE SEGMENT-Klasse statt der obigen: jedes
#   Identifier-Wort ([A-Za-z0-9_]+) wird an '_' und Klein->Gross-Wechseln zerlegt, jedes Segment case-insensitiv gegen
#   die Nicht-Core-Paketnamen verglichen (faengt Build-EstateCreateCase, $CRED_FINANCE_RW, 'finance\finance_cases.json',
#   tool_extract_finance_document). Die Engine kennt GAR kein Paket — Allowlist-Eintraege dort nur mit reason 'doc:…'.
#   Bewusst textbasiert ("bei uns anders" zu ESLint no-restricted-syntax/AST, arch-challenge Phase D): EIN Lint, EINE
#   Engine fuer .ps1/.sql/.json/.md; Import-Graph-Tools (Nx/import-linter) passen nicht (das Leck ist ein Literal).
#   Selbst-Asserts (synthetisches Paket 'zzp') laufen VOR jedem Scan — stirbt die Erkennung still, bricht der Lint.
#   PLUS (Phase E) dieselbe Segment-Klasse fuer die TEST-TREIBER (jedes scripts/- bzw. scripts/dev/-Skript, das
#   scripts/dev/test_n8n_state.ps1 dot-sourct, + der Helfer selbst + scripts/llm_suite_advice.ps1): Route-/Paket-/
#   per-user-Agenten leiten sie aus Manifest bzw. Substrat-DB ab (Get-TestRouteAgent). Allowlist-Eintraege dort nur
#   mit reason 'fixture:…' (Treiber-Default-Ziel, Fall-Szenario, Attrappe eines externen Paket-Dienstes) oder
#   'doc:…'. Scope-Selbst-Asserts brechen ab, wenn die Treiber-Erkennung nichts mehr findet.
# Scope: packages/core/build/**/*.ps1 + packages/core/db/**/*.sql (alle Klassen) + (Phase B) packages/core/manifest.json
#   (alle Klassen) + packages/core/contexts/*.md (nur die ungequoteten Klassen — Prosa-Prompts) + (Phase D)
#   scripts/build/**/*.ps1 (nur die Segment-Klasse; die Lint-Allowlist-JSONs dort sind Unterdrueckungs-Daten)
#   + (Phase E) die Test-Treiber (nur die Segment-Klasse; Erkennung s. o.).
#   AUSGENOMMEN: Kommentare (#-/--, quote-aware gestrippt), die unveraenderlichen Flyway-V-Migrationen
#   (**/migrations/V*__*.sql = einmalige historische Daten-Backfills), generierte Dateien.
# -Baseline: druckt die gefundenen (file,literal,count) als JSON-Geruest (reason:'TODO') -> Start fuer die Allowlist.
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Substrat.
param([switch]$Baseline, [switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

# --- Paketnamen entdecken (Verzeichnisse unter packages/ ausser 'core') ----------------------------------------
$pkgNames = @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'core' } | ForEach-Object { $_.Name })
# Exakt-Wert-Set der zu erkennenden Literale (ohne Quotes); Lookup case-sensitiv.
$litSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($p in $pkgNames) { foreach ($v in @($p, "${p}_advisor", "agent.$p", "agent.${p}_advisor")) { [void]$litSet.Add($v) } }
# Phase A (Fakten-Konsolidierung): zusaetzlich jeder KONTEXT-Name, den ein Nicht-Core-Manifest deklariert
# (context_validators/_scopes/_skeletons/_renderers-Keys, advisors.*.plan_context, protected_contexts)
# -- ein Core, der z. B. 'finance_profile' literal nennt, koppelt sich genauso an ein Paket wie an dessen Namen.
foreach ($p in $pkgNames) {
    $mfPath = Join-Path $RepoRoot "packages\$p\manifest.json"
    if (-not (Test-Path $mfPath)) { continue }
    $mj = [System.IO.File]::ReadAllText($mfPath, $u8) | ConvertFrom-Json
    foreach ($blk in 'context_validators', 'context_scopes', 'context_skeletons', 'context_renderers') {
        if ($mj.PSObject.Properties.Name -contains $blk -and $null -ne $mj.$blk) {
            foreach ($pr in $mj.$blk.PSObject.Properties) { if ($pr.Name -ne '_comment') { [void]$litSet.Add($pr.Name) } }
        }
    }
    if ($mj.PSObject.Properties.Name -contains 'advisors' -and $null -ne $mj.advisors) {
        foreach ($pr in $mj.advisors.PSObject.Properties) { if ($pr.Name -ne '_comment' -and $pr.Value.plan_context) { [void]$litSet.Add([string]$pr.Value.plan_context) } }
    }
    foreach ($n in @($mj.protected_contexts)) { if ($n) { [void]$litSet.Add([string]$n) } }
}
# Phase C: Agent-Namen der Nicht-Core-Pakete (Extraktion wie build.ps1/lib/agent_routing.ps1).
$agentNames = @()
foreach ($p in $pkgNames) {
    $mfPath = Join-Path $RepoRoot "packages\$p\manifest.json"
    if (-not (Test-Path $mfPath)) { continue }
    $mj = [System.IO.File]::ReadAllText($mfPath, $u8) | ConvertFrom-Json
    foreach ($a in @($mj.provides.agents)) {
        if ($null -eq $a) { continue }
        $n = if ($a -is [string]) { $a } else { [string]$a.name }
        if ($n -and $agentNames -notcontains $n) { $agentNames += $n }
    }
}

# --- Kommentar-Anteil quote-aware strippen (entfernt #-/--Kommentar, achtet auf '...'/"...") --------------------
function Get-CodePart {
    param([string]$Line, [string]$Kind)   # Kind = 'ps' (#) | 'sql' (--)
    $inS = $false; $inD = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($inS) { if ($c -eq "'") { $inS = $false }; continue }
        if ($inD) { if ($c -eq '"') { $inD = $false }; continue }
        if ($c -eq "'") { $inS = $true; continue }
        if ($c -eq '"') { $inD = $true; continue }
        if ($Kind -eq 'ps'  -and $c -eq '#') { return $Line.Substring(0, $i) }
        if ($Kind -eq 'sql' -and $c -eq '-' -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '-') { return $Line.Substring(0, $i) }
    }
    return $Line
}

# --- In-Scope-Dateien sammeln ----------------------------------------------------------------------------------
$targets = @()
$targets += Get-ChildItem (Join-Path $RepoRoot 'packages\core\build') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue
$targets += Get-ChildItem (Join-Path $RepoRoot 'packages\core\db')    -Recurse -Filter '*.sql' -ErrorAction SilentlyContinue
$targets += Get-Item (Join-Path $RepoRoot 'packages\core\manifest.json') -ErrorAction SilentlyContinue
$targets += Get-ChildItem (Join-Path $RepoRoot 'packages\core\contexts') -Filter '*.md' -ErrorAction SilentlyContinue
$targets += Get-ChildItem (Join-Path $RepoRoot 'scripts\build') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue   # Phase D: Bau-Engine
# Phase E: Test-Treiber = jedes Skript unter scripts/ bzw. scripts/dev/, das den gemeinsamen n8n-Test-Helfer
# scripts/dev/test_n8n_state.ps1 dot-sourct (jeder n8n-Tier muss das: Verbindung + Container-DB), plus der Helfer
# selbst und scripts/llm_suite_advice.ps1. Inhalts- statt Namens-Kriterium: Lints wie config_test.ps1 tragen
# andere Ratchets und gehoeren nicht hierher. Scope-Selbst-Asserts: der Helfer existiert und je Verzeichnis
# findet sich >= 1 Treiber — sonst stirbt der Schutz still beim Verschieben/Umbenennen.
$driverSet = @{}
$helperRel = 'scripts/dev/test_n8n_state.ps1'
if (-not (Test-Path (Join-Path $RepoRoot $helperRel))) { Fail "Scope-Selbst-Assert: $helperRel fehlt -- Treiber-Erkennung tot (Pfad anpassen)" }
else { $driverSet[$helperRel] = $true }
$driverSet['scripts/llm_suite_advice.ps1'] = $true
foreach ($dir in 'scripts', 'scripts\dev') {
    $n = 0
    foreach ($f in @(Get-ChildItem (Join-Path $RepoRoot $dir) -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
        $src = [System.IO.File]::ReadAllText($f.FullName, $u8)
        if ($src -match '(?m)^\s*\.\s+.*test_n8n_state\.ps1') {
            $driverSet[$f.FullName.Substring($RepoRoot.Length).TrimStart('\', '/').Replace('\', '/')] = $true; $n++
        }
    }
    if ($n -eq 0) { Fail "Scope-Selbst-Assert: unter $dir laedt kein Skript test_n8n_state.ps1 -- Treiber-Erkennung tot" }
}
foreach ($rel in $driverSet.Keys) { $p = Join-Path $RepoRoot $rel; if (Test-Path $p) { $targets += Get-Item $p } }
function Test-IsDriver([string]$Rel) { return $script:driverSet.ContainsKey($Rel) }
# Quoted-Literal-Regex: faengt '...'/"..." Inhalt; danach Exakt-Wert-Test gegen $litSet.
$quoteRx = [regex]"'([^']*)'|""([^""]*)"""
# Phase B: ungequotete Token-Klassen (schema-qualifizierte Paket-Bezeichner + Paket-Rollen), wortgrenzen-genau.
function New-TokenRx([string[]]$Pkgs) {
    $alt = ($Pkgs | ForEach-Object { [regex]::Escape($_) }) -join '|'
    if ($alt) { [regex]"(?<![A-Za-z0-9_.])(?:(?:$alt)\.[a-z_][a-z0-9_]*|(?:$alt)_(?:ro|rw)(?![A-Za-z0-9_]))" } else { $null }
}
# Phase C: Agent-Namen-Klasse (agent.<name> immer; bar nur Namen mit '_'), laengste Alternative zuerst.
function New-AgentRx([string[]]$Names) {
    $all = @($Names | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) })
    $bare = @($Names | Where-Object { $_ -match '_' } | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) })
    if ($all.Count -eq 0) { return $null }
    $pat = 'agent\.(?:' + ($all -join '|') + ')'
    if ($bare.Count -gt 0) { $pat = $pat + '|(?:' + ($bare -join '|') + ')' }
    [regex]('(?<![A-Za-z0-9_.])(?:' + $pat + ')(?![A-Za-z0-9_])')
}
$tokenRx = New-TokenRx $pkgNames
$agentRx = New-AgentRx $agentNames

# Phase D: Segment-Klasse der Bau-Engine. Liefert je Identifier-Wort, das ein Paket-Segment traegt, das Wort selbst.
function Get-SegmentHits([string]$Code, [string[]]$Pkgs) {
    $set = @{}; foreach ($p in $Pkgs) { $set[$p.ToLowerInvariant()] = $true }
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($w in ([regex]'[A-Za-z0-9_]+').Matches($Code)) {
        foreach ($seg in ($w.Value -split '_')) {
            $hit = $false
            foreach ($part in ([regex]::Split($seg, '(?<=[a-z0-9])(?=[A-Z])'))) { if ($part -and $set.ContainsKey($part.ToLowerInvariant())) { $hit = $true; break } }
            if ($hit) { $hits.Add($w.Value); break }
        }
    }
    return $hits.ToArray()
}

# Treffer EINER (bereits kommentar-gestrippten) Zeile -> Liste der Literal-Werte. Reihenfolge: Token-Klasse,
# Quoted-Klasse (nicht in md), Agent-Klasse (ohne Treffer innerhalb eines schon gezaehlten Quoted-Literals).
function Get-LineHits([string]$Code, [string]$Kind, $TokRx, $QRx, $Lits, $AgRx) {
    $hits = New-Object System.Collections.Generic.List[string]
    if ($TokRx) { foreach ($m in $TokRx.Matches($Code)) { $hits.Add($m.Value) } }
    $spans = New-Object System.Collections.Generic.List[int[]]
    if ($Kind -ne 'md' -and $Code -match '[''"]') {
        foreach ($m in $QRx.Matches($Code)) {
            $val = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
            if ($Lits.Contains($val)) { $hits.Add($val); $spans.Add([int[]]@($m.Index, ($m.Index + $m.Length))) }
        }
    }
    if ($AgRx) {
        foreach ($m in $AgRx.Matches($Code)) {
            $inside = $false
            foreach ($s in $spans) { if ($m.Index -ge $s[0] -and ($m.Index + $m.Length) -le $s[1]) { $inside = $true; break } }
            if (-not $inside) { $hits.Add($m.Value) }
        }
    }
    return $hits.ToArray()   # entrollt in die Pipeline; Aufrufer sammeln mit @(...) (leer = @())
}

# --- Selbst-Asserts (synthetisches Paket 'zzp' mit Agenten zzp + zzp_advisor) — unbedingt, vor dem Scan ---------
$tLits = New-Object System.Collections.Generic.HashSet[string]
foreach ($v in @('zzp', 'zzp_advisor', 'agent.zzp', 'agent.zzp_advisor')) { [void]$tLits.Add($v) }
$tTok = New-TokenRx @('zzp'); $tAg = New-AgentRx @('zzp', 'zzp_advisor')
$selfCases = @(
    @{ c = 'route to agent.zzp_advisor.';          k = 'md'; want = @('agent.zzp_advisor') },   # satzschliessender Punkt
    @{ c = 'the zzp_advisor_instructions context'; k = 'md'; want = @() },                      # laengerer Bezeichner
    @{ c = 'table agent.zzp_chat_memory';          k = 'md'; want = @() },
    @{ c = 'a zzp question for realzzp_advisor';   k = 'md'; want = @() },                      # bares Paketwort + Praefix
    @{ c = 'ask the zzp_advisor now';              k = 'md'; want = @('zzp_advisor') },
    @{ c = '$x = ''agent.zzp_advisor''';           k = 'ps'; want = @('agent.zzp_advisor') },   # Dedupe: nur 1x
    @{ c = '$s = ''Text mit agent.zzp.cron_x drin''';  k = 'ps'; want = @('agent.zzp') }        # Praefix, kein zzp.<ident>
)
foreach ($sc in $selfCases) {
    $got = @(Get-LineHits $sc.c $sc.k $tTok $quoteRx $tLits $tAg)
    if (($got -join '|') -ne (@($sc.want) -join '|')) {
        Fail "Selbst-Assert: '$($sc.c)' ($($sc.k)) -> erwartet [$(@($sc.want) -join ', ')], gefunden [$($got -join ', ')] -- Erkennung defekt, Lint-Ergebnis waere wertlos"
    }
}
# Phase D: Segment-Klasse (Bau-Engine) — inkl. Kommentar-Strip (ganze Zeile + angehaengt, quote-aware).
$segCases = @(
    @{ c = '${function:Build-ZzpCreateX}';                    want = @('ZzpCreateX') },
    @{ c = '$CRED_POSTGRES = $CRED_ZZP_RW';                    want = @('CRED_ZZP_RW') },
    @{ c = '$f = @(''zzp\zzp_cases.json'')';                   want = @('zzp', 'zzp_cases') },
    @{ c = 'tool_extract_zzp_document = @(';                   want = @('tool_extract_zzp_document') },
    @{ c = '$x = ''zzpx'' + $RealZzpy';                        want = @() },
    @{ c = '# Kommentar nennt zzp';                            want = @() },
    @{ c = '$a = 1   # z. B. ''model.zzp''';                   want = @() },
    @{ c = '$m = ''# kein Kommentar: zzp''';                   want = @('zzp') }
)
foreach ($sc in $segCases) {
    $got = @(Get-SegmentHits (Get-CodePart $sc.c 'ps') @('zzp'))
    if (($got -join '|') -ne (@($sc.want) -join '|')) {
        Fail "Selbst-Assert (Segment): '$($sc.c)' -> erwartet [$(@($sc.want) -join ', ')], gefunden [$($got -join ', ')] -- Engine-Erkennung defekt"
    }
}
if ($fails -gt 0) { Write-Host "core_literal_lint: $fails Fehler (Selbst-Asserts)" -ForegroundColor Red; exit $fails }

$found = @{}   # "relfile|literal" -> count
function Add-Found([string]$Rel, [string]$Val) {
    $key = "$Rel|$Val"
    if ($script:found.ContainsKey($key)) { $script:found[$key]++ } else { $script:found[$key] = 1 }
}
foreach ($f in ($targets | Sort-Object FullName -Unique)) {
    $rel = $f.FullName.Substring($RepoRoot.Length).TrimStart('\','/').Replace('\','/')
    if ($rel -match '/migrations/V[0-9]+__') { continue }   # unveraenderliche Flyway-V-Migrationen
    $kind = switch ($f.Extension) { '.ps1' { 'ps' } '.sql' { 'sql' } '.json' { 'json' } default { 'md' } }
    $isSegment = ($rel -like 'scripts/build/*') -or (Test-IsDriver $rel)
    foreach ($line in [System.IO.File]::ReadAllLines($f.FullName, $u8)) {
        $code = if ($kind -in 'ps', 'sql') { Get-CodePart $line $kind } else { $line }
        $lineHits = if ($isSegment) { Get-SegmentHits $code $pkgNames } else { Get-LineHits $code $kind $tokenRx $quoteRx $litSet $agentRx }
        foreach ($h in $lineHits) { Add-Found $rel $h }
    }
}

# --- Baseline-Modus: Allowlist-Geruest drucken ----------------------------------------------------------------
if ($Baseline) {
    $entries = foreach ($k in ($found.Keys | Sort-Object)) {
        $p = $k -split '\|', 2
        [ordered]@{ file = $p[0]; literal = $p[1]; count = $found[$k]; reason = 'TODO' }
    }
    [ordered]@{ _comment = 'Baseline -- Begruendung je Eintrag eintragen (default|debt:WS-0c#N|...)'; allow = @($entries) } |
        ConvertTo-Json -Depth 6
    exit 0
}

# --- Allowlist laden + selbst-konsistent pruefen ---------------------------------------------------------------
$alPath = Join-Path $RepoRoot 'scripts\build\core_literal_allowlist.json'
if (-not (Test-Path $alPath)) { Fail "Allowlist fehlt: $alPath (mit -Baseline erzeugen + Begruendungen eintragen)"; Write-Host "core_literal_lint: $fails Fehler" -ForegroundColor Red; exit $fails }
$al = [System.IO.File]::ReadAllText($alPath, $u8) | ConvertFrom-Json
$allow = @{}
foreach ($e in $al.allow) {
    $key = "$([string]$e.file)|$([string]$e.literal)"
    if ([string]::IsNullOrWhiteSpace([string]$e.reason)) { Fail "allowlist: Eintrag '$key' ohne reason (jede Ausnahme braucht eine Begruendung)" }
    if ([string]$e.file -like 'scripts/build/*' -and [string]$e.reason -notlike 'doc:*') { Fail "allowlist: Engine-Eintrag '$key' -- in scripts/build/ ist nur eine Doku-Erwaehnung erlaubt (reason 'doc:…'); Paket-Wissen gehoert ins Manifest/die Paket-Defs" }
    if ((Test-IsDriver ([string]$e.file)) -and [string]$e.reason -notlike 'fixture:*' -and [string]$e.reason -notlike 'doc:*') { Fail "allowlist: Treiber-Eintrag '$key' -- in Test-Treibern nur reason 'fixture:…' (Default-Ziel/Fall-Szenario) oder 'doc:…'; Agenten-Listen leitet Get-TestRouteAgent aus Manifest/DB ab" }
    if ($allow.ContainsKey($key)) { Fail "allowlist: doppelter Eintrag '$key'"; continue }
    $allow[$key] = [int]$e.count
}

# --- Abgleich Found <-> Allowlist (exakt je (Datei, Literal)) --------------------------------------------------
foreach ($key in ($found.Keys | Sort-Object)) {
    $p = $key -split '\|', 2
    if (-not $allow.ContainsKey($key)) {
        Fail "NEUES Core-Paket-Literal '$($p[1])' in $($p[0]) ($($found[$key])x) -- generisch bauen ODER mit Begruendung in scripts/build/core_literal_allowlist.json"
    } elseif ($allow[$key] -ne $found[$key]) {
        Fail "Anzahl '$($p[1])' in $($p[0]): gefunden $($found[$key]), Allowlist $($allow[$key]) -- Allowlist-count anpassen (bei Entfernung schrumpfen = WS-0c-Fortschritt)"
    }
}
foreach ($key in ($allow.Keys | Sort-Object)) {
    if (-not $found.ContainsKey($key)) {
        $p = $key -split '\|', 2
        Fail "allowlist-ORPHAN '$($p[1])' in $($p[0]) -- Literal nicht (mehr) vorhanden, Eintrag entfernen (Ratchet schrumpft)"
    }
}

if ($Verbose) { foreach ($k in ($found.Keys | Sort-Object)) { Write-Host "  $k = $($found[$k])" -ForegroundColor DarkGray } }
if ($fails -eq 0) { Write-Host "core_literal_lint: OK ($($found.Count) allowlistete Paket-Literal-Stelle(n), kein neues)" -ForegroundColor Green }
else { Write-Host "core_literal_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
