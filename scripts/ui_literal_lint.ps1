#Requires -Version 5.1
# ui_literal_lint.ps1 -- Textkatalog Phase B: "kein NEUER fest deutscher Nutzertext" (hartes Gate, Vorbild
# scripts/core_literal_lint.ps1). Feste Nutzertexte kommen aus dem Textkatalog (packages/<pkg>/locales/<lang>.json,
# docs/package-contract.md §3.11) in der Sprache des Empfaengers; ein deutsches Literal in einem Telegram-Send, Code-/
# Set-Node oder einer R__-fn waere ein Rueckfall. Mechanik = RATCHET (Baseline-Allowlist): jede HEUTE vorhandene Stelle
# steht in scripts/build/ui_literal_allowlist.json mit Begruendung (seit Phase C ist jeder Nutzertext im Katalog -> nur
# noch model:<warum> = Text fuers Sprachmodell, kein Nutzertext;
# admin:<warum> = RAISE/Konsolen-Meldung fuer den Betreiber; data:<warum> = gespeicherter Inhalt, Originalsprache nach
# Sprachpolitik). Exakt je (Ort, Literal):
#   - Found > Allowlist  -> NEUER deutscher Text (FAIL: Katalog-Key nutzen ODER mit Begruendung allowlisten);
#   - Found < Allowlist  -> eine Stelle wurde umgestellt (FAIL: Allowlist schrumpfen = Phase-C-Fortschritt);
#   - Allowlist-Eintrag ohne Fund -> Orphan (FAIL: entfernen).
# Scan:
#   (a) gebaute Workflows packages/*/workflows/*.json (die Deploy-Vertraege): Telegram-Nodes (alle Text-Parameter inkl.
#       Knopf-Texte und Toasts; callback_data/chatId/... nicht), Code-Nodes (String-Literale im jsCode, Kommentare
#       gestrippt), Set-Nodes (Zuweisungs-Werte). Bei n8n-Ausdruecken ('=...') zaehlen der Text ausserhalb {{ }} und die
#       JS-String-Literale darin. Ort = "<workflow> / <node>".
#   (b) packages/*/db/migrations/R__*.sql: String-Literale im Code-Anteil (Kommentare quote-aware gestrippt). Ort = Pfad.
# Treffer = Literal mit deutscher Signatur (Umlaut/ß oder ein typisches deutsches Funktionswort) und mindestens einem
# Wort aus >= 3 Buchstaben; Katalog-Keys, englische Gruende/Codes und Identifier fallen so heraus.
# Selbst-Asserts laufen VOR jedem Scan — stirbt die Erkennung still, bricht der Lint.
# -Baseline: druckt die gefundenen (where,literal,count) als JSON-Geruest (reason:'TODO').
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Substrat.
param([switch]$Baseline, [switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

# --- Erkennung -------------------------------------------------------------------------------------------------
$germanRx = [regex]::new('[äöüÄÖÜß]|(?<![A-Za-z])(und|oder|nicht|bitte|danke|hallo|willkommen|der|das|den|dem|des|ein|eine|einen|einem|ist|sind|wird|wurde|werden|kein|keine|mit|für|von|zum|zur|auf|du|dein|deine|deinen|dich|dir|ich|mich|mir|wir|euer|eure|jetzt|noch|schon|gerade|heute|hier|auch|bei|bereich|nutzer|haushalt|erledigt|gespeichert|verworfen|aktiv)(?![A-Za-z])', 'IgnoreCase')
function Test-GermanText([string]$S) {
    if ($S -notmatch '[A-Za-zÄÖÜäöüß]{3,}') { return $false }
    if ($S -match '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){2,}$') { return $false }   # Katalog-Key
    return $germanRx.IsMatch($S)
}
# JS-/SQL-String-Literale ('...' | "..." | `...`) einer Code-Zeile (Kommentar-Anteil vorher gestrippt).
$jsLitRx  = [regex]"'((?:[^'\\]|\\.)*)'|""((?:[^""\\]|\\.)*)""|``((?:[^``\\]|\\.)*)``"
$sqlLitRx = [regex]"'((?:[^']|'')*)'"
function Get-JsLiterals([string]$Code) {
    foreach ($m in $jsLitRx.Matches($Code)) {
        foreach ($g in 1, 2, 3) { if ($m.Groups[$g].Success) { $m.Groups[$g].Value } }
    }
}
# JS-Zeilenkommentar quote-aware strippen.
function Get-JsCode([string]$Line) {
    $q = $null
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($q) { if ($c -eq '\') { $i++; continue }; if ($c -eq $q) { $q = $null }; continue }
        if ($c -eq "'" -or $c -eq '"' -or $c -eq '`') { $q = $c; continue }
        if ($c -eq '/' -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '/') { return $Line.Substring(0, $i) }
    }
    return $Line
}
function Get-SqlCode([string]$Line) {
    $inS = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($inS) { if ($c -eq "'") { $inS = $false }; continue }
        if ($c -eq "'") { $inS = $true; continue }
        if ($c -eq '-' -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '-') { return $Line.Substring(0, $i) }
    }
    return $Line
}
# Texte eines n8n-Parameter-Werts: Ausdruck ('=...') -> Text ausserhalb {{ }} + JS-Literale darin; sonst der Wert.
function Get-ParamTexts([string]$V) {
    if (-not $V.StartsWith('=')) { return , $V }
    $body = $V.Substring(1)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($seg in [regex]::Split($body, '\{\{[\s\S]*?\}\}')) { if ($seg.Trim()) { $out.Add($seg) } }
    foreach ($m in [regex]::Matches($body, '\{\{([\s\S]*?)\}\}')) {
        foreach ($l in (Get-JsLiterals $m.Groups[1].Value)) { $out.Add($l) }
    }
    return $out.ToArray()
}
# Alle String-Blaetter eines Parameter-Baums (ohne nicht-textuelle Schluessel).
$skipKeys = @('chatId', 'callback_data', 'url', 'resource', 'operation', 'chatApproval', 'approverIds', 'parse_mode',
              'parseMode', 'draftId', 'queryId', 'callbackQueryId', 'fileId', 'messageId', 'replyToMessageId', 'webhookId')
function Get-StringLeaves($Obj, [string]$Key = '') {
    if ($null -eq $Obj) { return }
    if ($skipKeys -contains $Key) { return }
    if ($Obj -is [string]) { $Obj; return }
    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) { foreach ($x in $Obj) { Get-StringLeaves $x $Key }; return }
    if ($Obj -is [psobject]) { foreach ($p in $Obj.PSObject.Properties) { Get-StringLeaves $p.Value $p.Name } }
}

# --- Selbst-Asserts ---------------------------------------------------------------------------------------------
$selfCases = @(
    @{ k = 'param'; c = '=Hallo {{ $json.x }}, willkommen!';                         want = @('Hallo ', ', willkommen!') }
    @{ k = 'param'; c = "={{ 'Nicht verfügbar' }}";                                   want = @('Nicht verfügbar') }
    @{ k = 'param'; c = "={{ ((`$json.t || {})['core.orch.x'] || 'core.orch.x') }}";   want = @() }
    @{ k = 'param'; c = 'Danke! Deine Anfrage wurde gesendet.';                        want = @('Danke! Deine Anfrage wurde gesendet.') }
    @{ k = 'js';    c = "const a = 'Bitte prüfen'; // und noch ein Kommentar";          want = @('Bitte prüfen') }
    @{ k = 'js';    c = "const b = 'unknown action'; const u = 'https://x.y/z';";      want = @() }
    @{ k = 'sql';   c = "RETURN jsonb_build_object('toast', 'Absender nicht erkannt'); -- der Kommentar"; want = @('Absender nicht erkannt') }
    @{ k = 'sql';   c = "RAISE EXCEPTION 'unknown est action %', v;";                   want = @() }
)
foreach ($sc in $selfCases) {
    $cands = switch ($sc.k) {
        'param' { @(Get-ParamTexts $sc.c) }
        'js'    { @(Get-JsLiterals (Get-JsCode $sc.c)) }
        'sql'   { @($sqlLitRx.Matches((Get-SqlCode $sc.c)) | ForEach-Object { $_.Groups[1].Value }) }
    }
    $got = @($cands | Where-Object { Test-GermanText $_ })
    if (($got -join '|') -ne (@($sc.want) -join '|')) {
        Fail "Selbst-Assert ($($sc.k)): '$($sc.c)' -> erwartet [$(@($sc.want) -join ', ')], gefunden [$($got -join ', ')] -- Erkennung defekt"
    }
}
if ($fails -gt 0) { Write-Host "ui_literal_lint: $fails Fehler (Selbst-Asserts)" -ForegroundColor Red; exit $fails }

# --- Scan -------------------------------------------------------------------------------------------------------
$found = @{}   # "where|literal" -> count
function Add-Found([string]$Where, [string]$Val) {
    $k = "$Where|$Val"
    if ($script:found.ContainsKey($k)) { $script:found[$k]++ } else { $script:found[$k] = 1 }
}
$wfCount = 0
foreach ($wfDir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | ForEach-Object { Join-Path $_.FullName 'workflows' } | Where-Object { Test-Path $_ })) {
    foreach ($file in (Get-ChildItem $wfDir -Filter '*.json')) {
        $wf = [System.IO.File]::ReadAllText($file.FullName, $u8) | ConvertFrom-Json
        if (-not $wf.nodes) { continue }
        $wfCount++
        foreach ($n in $wf.nodes) {
            $where = "$($wf.name) / $($n.name)"
            switch ([string]$n.type) {
                'n8n-nodes-base.telegram' {
                    foreach ($v in (Get-StringLeaves $n.parameters)) { foreach ($t in (Get-ParamTexts $v)) { if (Test-GermanText $t) { Add-Found $where $t } } }
                }
                'n8n-nodes-base.code' {
                    foreach ($line in ([string]$n.parameters.jsCode -split "`n")) {
                        foreach ($t in (Get-JsLiterals (Get-JsCode $line))) { if (Test-GermanText $t) { Add-Found $where $t } }
                    }
                }
                'n8n-nodes-base.set' {
                    foreach ($a in @($n.parameters.assignments.assignments)) {
                        if ($null -eq $a -or -not ($a.value -is [string])) { continue }
                        foreach ($t in (Get-ParamTexts $a.value)) { if (Test-GermanText $t) { Add-Found $where $t } }
                    }
                }
            }
        }
    }
}
if ($wfCount -eq 0) { Fail 'Scope-Selbst-Assert: keine gebauten Workflows gefunden -- Scan tot (Pfad?)' }
$sqlCount = 0
foreach ($f in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\db\migrations\R__*.sql'))) {
    $sqlCount++
    $rel = $f.FullName.Substring($RepoRoot.Length).TrimStart('\', '/').Replace('\', '/')
    foreach ($line in [System.IO.File]::ReadAllLines($f.FullName, $u8)) {
        foreach ($m in $sqlLitRx.Matches((Get-SqlCode $line))) {
            $t = $m.Groups[1].Value -replace "''", "'"
            if (Test-GermanText $t) { Add-Found $rel $t }
        }
    }
}
if ($sqlCount -eq 0) { Fail 'Scope-Selbst-Assert: keine R__-Dateien gefunden -- Scan tot (Pfad?)' }

# --- Baseline-Modus ---------------------------------------------------------------------------------------------
if ($Baseline) {
    $entries = foreach ($k in ($found.Keys | Sort-Object)) {
        $p = $k -split '\|', 2
        [ordered]@{ where = $p[0]; literal = $p[1]; count = $found[$k]; reason = 'TODO' }
    }
    [ordered]@{ _comment = 'Baseline -- Begruendung je Eintrag (model:<warum> | admin:<warum> | data:<warum>)'; allow = @($entries) } | ConvertTo-Json -Depth 6
    exit 0
}

# --- Allowlist laden + Abgleich ---------------------------------------------------------------------------------
$alPath = Join-Path $RepoRoot 'scripts\build\ui_literal_allowlist.json'
if (-not (Test-Path $alPath)) { Fail "Allowlist fehlt: $alPath (mit -Baseline erzeugen + Begruendungen eintragen)"; Write-Host "ui_literal_lint: $fails Fehler" -ForegroundColor Red; exit $fails }
$al = [System.IO.File]::ReadAllText($alPath, $u8) | ConvertFrom-Json
$allow = @{}
foreach ($e in $al.allow) {
    $key = "$([string]$e.where)|$([string]$e.literal)"
    $r = [string]$e.reason
    if ($r -notmatch '^(model|admin|data):\S') { Fail "allowlist: Eintrag '$key' -- reason muss 'model:<warum>', 'admin:<warum>' oder 'data:<warum>' sein (ist '$r'); ein Nutzertext gehoert in den Katalog (seit Phase C keine phase-c-Ausnahme mehr)" }
    if ($allow.ContainsKey($key)) { Fail "allowlist: doppelter Eintrag '$key'"; continue }
    $allow[$key] = [int]$e.count
}
foreach ($key in ($found.Keys | Sort-Object)) {
    $p = $key -split '\|', 2
    if (-not $allow.ContainsKey($key)) {
        Fail "NEUER fest deutscher Text in $($p[0]): '$($p[1])' ($($found[$key])x) -- Katalog-Key nutzen (§3.11) ODER mit Begruendung in scripts/build/ui_literal_allowlist.json"
    } elseif ($allow[$key] -ne $found[$key]) {
        Fail "Anzahl '$($p[1])' in $($p[0]): gefunden $($found[$key]), Allowlist $($allow[$key]) -- Allowlist-count anpassen (bei Umstellung schrumpfen)"
    }
}
foreach ($key in ($allow.Keys | Sort-Object)) {
    if (-not $found.ContainsKey($key)) {
        $p = $key -split '\|', 2
        Fail "allowlist-ORPHAN in $($p[0]): '$($p[1])' -- nicht (mehr) vorhanden, Eintrag entfernen (Ratchet schrumpft)"
    }
}
if ($Verbose) { foreach ($k in ($found.Keys | Sort-Object)) { Write-Host "  $k = $($found[$k])" -ForegroundColor DarkGray } }
if ($fails -eq 0) { Write-Host "ui_literal_lint: OK ($($found.Count) allowlistete Stelle(n) aus $wfCount Workflows + $sqlCount R__-Dateien, kein neuer deutscher Text)" -ForegroundColor Green }
else { Write-Host "ui_literal_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
