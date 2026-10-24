#Requires -Version 5.1
# Workflow-Struktur-/Logik-Lint (A4a). Kein LLM, kein Live-Trigger -- prueft kritische Workflows,
# die NICHT bequem live testbar sind, gegen ihre getrackte Definition.
#
# Schwerpunkt core.sub_error_notify (die SYSTEMWEITE Sicherheitsleine: jeder Prod-Workflow zeigt per
# settings.errorWorkflow darauf). Bricht sie still (Node umbenannt, Telegram-Credential entfernt,
# Verdrahtung kaputt), fallen ALLE Workflows lautlos aus -- kein Alert kommt mehr an. Da der Eingang
# ein n8n errorTrigger ist (feuert nur bei echten Fehlern, nicht via executeWorkflow ansteuerbar),
# pruefen wir deterministisch die DEFINITION:
#   (1) Struktur: erwartete Nodes/Typen + Verdrahtung On Error -> Load alert texts -> Format Message -> Send Telegram Alert
#   (2) Send-Node: chatId gesetzt + Telegram-Credential + appendAttribution:false
#   (3) Format-Message-LOGIK: der JS-Code baut aus einem synthetischen Error-Payload korrekt die
#       Alert-Nachricht (via node ausgefuehrt: lokal installiert oder per Docker) -> faengt Code-Regressions.
#
# Zusaetzlich QUERSCHNITTS-GESETZE ueber ALLE getrackten Workflows (Fehlerklasse "Prod-Pfad
# crasht, alle Tests gruen" -- real getroffen 2026-06-12, Executions 3026-3030):
#   (4) chat_id-Typsicherheit: Telegram liefert message.chat.id als ZAHL, Test-Harnesses
#       uebergeben Strings ('test_...') -> typ-unsichere String-Ops auf chat_id crashen NUR
#       produktiv (strict-IF: NodeOperationError "Wrong type ... is a number"; Expression:
#       TypeError .startsWith auf Zahl). Gesetz: jede String-Condition (IF/Switch/Filter) und
#       jede .startsWith-Expression auf chat_id ist String()-gewrappt; der Orchestrator (die
#       Quelle) stringifiziert chat_id in JEDEM workflowInputs-Binding.
#   (5) Code-Node-Return-Shape: mode=runOnceForEachItem MUSS ein Einzel-Item { json: {...} }
#       returnen -- ein Array-Return [{...}] wirft "A 'json' property isn't an object"
#       (genau das machte die Fehler-Sicherheitsleine selbst von Anfang an kaputt).
#   (Stickies) jeder Workflow traegt >= 1 Sticky-Note -- Workflows sind die primaere Doku (Root-CLAUDE.md);
#       deterministischer Backstop der Prosa-Pflicht (Harness-Rightsizing 2026-10-20).
#   (Sprachmodelle) kein Gemini-Chat-Node; Google-Gemini (Node/Credential/URL) nur im Transkriptions-Tool
#       (Modell-Phase 2: Chat-Modelle laufen nur noch ueber Claude).
#   (Ausdrucks-Syntax) jeder {{ … }}-Ausdruck in Node-Parametern ist gueltiges JavaScript (via node lokal oder per Docker;
#       in der CI Pflicht — fehlt node dort, failt der Check statt still zu ueberspringen). n8n akzeptiert einen kaputten Ausdruck beim Publish und scheitert erst zur Laufzeit mit
#       "invalid syntax" (real 2026-10-20: tool_book_savings_plan_execution, Approval-Summary mit fehlender Klammer
#       -> das Werkzeug brach seit Langem vor jeder Bestaetigung ab, unbemerkt bis zum E2E-Lauf). Auch $fromAI(…)-Ausdruecke:
#       ein "}}" im Beschreibungstext beendet den Ausdruck vorzeitig (real 2026-10-20: tool_save_plan_section, JSON-Beispiel
#       in der section_data-Beschreibung -> jeder Speicher-Aufruf "invalid syntax"). Ausgenommen nur Code-Nodes (eigenes jsCode).
#
# Usage:  .\scripts\workflow_lint.ps1 [-Verbose]
# Exit-Code = Anzahl fehlgeschlagener Checks.
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot  = git -C $PSScriptRoot rev-parse --show-toplevel

# Node fuer die JS-Checks (Format-Message-Logik, Ausdrucks-Syntax): installiert (CI-Runner) -> direkt; sonst ueber
# Docker (lokal ohnehin Pflicht fuer db_test) mit gepinntem Image -> lokal laeuft DERSELBE Check wie in der CI statt
# still uebersprungen zu werden (2026-10-21/22: ein lokal uebersprungener Check war ~20 Pushes lang nur in der CI rot).
# Beide Wege arbeiten nur mit Dateien unter .local/lint_tmp und Repo-relativen Pfaden (im Container = /repo).
$LintNodeImage = 'node:20.18.0-alpine'
$LintTmpRel    = '.local/lint_tmp'
$LintNode = if (Get-Command node -CommandType Application -ErrorAction SilentlyContinue) { 'local' } else {
    # Probe darf den Lint nie abbrechen (EAP=Stop + stderr / fehlende docker-CLI) -> sonst greift der Fehl-Check unten.
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $null = & docker info --format '{{.ServerVersion}}' 2>$null; if ($LASTEXITCODE -eq 0) { 'docker' } else { $null } }
    catch { $null } finally { $ErrorActionPreference = $prevEap }
}
function Invoke-LintNode([string[]]$RelArgs) {
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        if ($LintNode -eq 'local') {
            Push-Location $RepoRoot
            try { & node @RelArgs 2>&1 | Out-String } finally { Pop-Location }
        } else {
            $null = & docker image inspect $LintNodeImage 2>$null
            if ($LASTEXITCODE -ne 0) { $null = & docker pull -q $LintNodeImage 2>$null }
            & docker run --rm -v "${RepoRoot}:/repo" -w /repo $LintNodeImage node @RelArgs 2>&1 | Out-String
        }
    } finally { $ErrorActionPreference = $prevEap }
}
function New-LintTmpFile([string]$Ext) {
    $dir = Join-Path $RepoRoot $LintTmpRel
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $name = 'wf_' + [guid]::NewGuid().ToString('N') + $Ext
    @{ Full = (Join-Path $dir $name); Rel = "$LintTmpRel/$name" }
}
. (Join-Path $RepoRoot 'scripts\build\lib\umlaut.ps1')   # Ersatz-Umlaut-Erkennung (Textkatalog)

# Paket-bewusste Workflow-Quellen: jedes Paket unter packages/<pkg>/workflows/. Get-WfDirs = Such-Liste;
# Resolve-WfPath findet '<id>-<name>.json' (id state-aufgeloest, KEIN hardcodiertes ID-Literal mehr)
# ueber alle Dirs.
function Get-WfDirs {
    $dirs = @()
    foreach ($p in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory -ErrorAction SilentlyContinue)) {
        $w = Join-Path $p.FullName 'workflows'; if (Test-Path $w) { $dirs += $w }
    }
    return @($dirs)
}
function Resolve-WfPath([string]$Name) {
    foreach ($d in (Get-WfDirs)) {
        $hit = Get-ChildItem (Join-Path $d "*-$Name.json") -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}
function Get-AllWfFiles {
    Get-WfDirs | ForEach-Object { Get-ChildItem (Join-Path $_ '*.json') -File -ErrorAction SilentlyContinue } |
        Where-Object { $_.Name -notlike '_*' }
}

$failed = 0
function Check([string]$Name, [scriptblock]$Test) {
    try {
        if (& $Test) { Write-Host "  [PASS] $Name" -ForegroundColor Green }
        else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failed++ }
    } catch { Write-Host "  [FAIL] $Name -- $($_.Exception.Message)" -ForegroundColor Red; $script:failed++ }
}

Write-Host ""
Write-Host "Workflow-Lint (kritische, nicht-live-testbare Workflows)"
Write-Host ("-" * 60)

# --- core.sub_error_notify ---
Write-Host "core.sub_error_notify (globale Fehler-Sicherheitsleine):"
$enPath = Resolve-WfPath 'core.sub_error_notify'
Check 'Workflow-Datei vorhanden' { [bool]$enPath -and (Test-Path $enPath) }
$en = $null
if ($enPath -and (Test-Path $enPath)) { $en = [System.IO.File]::ReadAllText($enPath, $Utf8NoBom) | ConvertFrom-Json }

if ($en) {
    $nodes = $en.nodes
    $onErr  = $nodes | Where-Object { $_.type -eq 'n8n-nodes-base.errorTrigger' } | Select-Object -First 1
    $fmt    = $nodes | Where-Object { $_.name -eq 'Format Message' } | Select-Object -First 1
    $send   = $nodes | Where-Object { $_.type -eq 'n8n-nodes-base.telegram' } | Select-Object -First 1

    Check 'Error-Trigger vorhanden (On Error)'      { $null -ne $onErr }
    Check 'Format-Message-Code-Node vorhanden'      { $null -ne $fmt -and $fmt.type -eq 'n8n-nodes-base.code' }
    Check 'Telegram-Send-Node vorhanden'            { $null -ne $send }
    Check 'Send: chatId gesetzt'                    { $null -ne $send -and -not [string]::IsNullOrWhiteSpace("$($send.parameters.chatId)") }
    Check 'Send: Telegram-Credential gebunden'      { $null -ne $send -and $null -ne $send.credentials.telegramApi.id }
    Check 'Send: appendAttribution=false'           { $null -ne $send -and $send.parameters.additionalFields.appendAttribution -eq $false }
    Check 'Send: Retry On Fail aktiv'               { $null -ne $send -and $send.retryOnFail -eq $true }

    # Verdrahtung On Error -> Load alert texts (Owner-Sprache, Textkatalog Phase C) -> Format Message -> Send. Der
    # Text-Read darf den Alarm nie aufhalten: onError=continue + alwaysOutputData, kein Retry.
    $c = $en.connections
    $lt = $nodes | Where-Object { $_.name -eq 'Load alert texts' } | Select-Object -First 1
    Check 'Verdrahtung: On Error -> Load alert texts -> Format Message' {
        $c.'On Error'.main[0][0].node -eq 'Load alert texts' -and $c.'Load alert texts'.main[0][0].node -eq 'Format Message'
    }
    Check 'Load alert texts: onError=continue, alwaysOutputData, kein Retry' {
        $null -ne $lt -and $lt.onError -eq 'continueRegularOutput' -and $lt.alwaysOutputData -eq $true -and -not $lt.retryOnFail
    }
    Check 'Verdrahtung: Format Message -> Send'     { $c.'Format Message'.main[0][0].node -eq $send.name }

    # Format-Message-Code referenziert die Error-Trigger-Felder (sonst leere/falsche Alerts)
    $js = "$($fmt.parameters.jsCode)"
    Check 'Code referenziert execution + workflow + error.message' {
        $js -match 'execution' -and $js -match 'workflow' -and $js -match 'error'
    }
    # Telegram parst legacy Markdown: rohe _/*/`/[ (Workflow-/Node-Namen!) fressen Underscores
    # oder crashen den Alert ("can't parse entities") -> der Formatter MUSS escapen.
    Check 'Code escapt Markdown-Entities (_ * ` [)' { $js -match 'replace\(/\[_\*' }
    # Suite-Rauschen: Harness-getriggerte Executions (Root-Trigger 'Test Webhook') duerfen nie
    # alerten (canceled Timeout-Stopps der Test-Skripte feuerten Owner-Alerts, 2026-06-12).
    Check 'Code filtert Harness-Executions (Test Webhook)' { $js -match 'Test Webhook' }

    # (3) LOGIK-Test: Format-Message-JS gegen synthetische Payloads ausfuehren (node lokal oder per Docker, Invoke-LintNode).
    if ($LintNode) {
        $tmpF = New-LintTmpFile '.js'; $tmp = $tmpF.Full
        $payload = '{"execution":{"error":{"message":"connection refused"},"lastNodeExecuted":"Finance Agent","url":"https://n8n.example/exec/1"},"workflow":{"name":"agent.finance"}}'
        # Harness-Payload: Root-Trigger = Test Webhook -> MUSS unterdrueckt werden (leeres Array).
        $payloadH = '{"execution":{"error":{"message":"This operation was aborted"},"lastNodeExecuted":"Finance Agent","executionContext":{"triggerNode":{"name":"Test Webhook","type":"n8n-nodes-base.webhook"}}},"workflow":{"name":"agent.finance"}}'
        # jsCode liest die Fehler-Daten ueber $('On Error').all() (seit Textkatalog Phase C; 'Load alert texts'
        # liefert die Owner-Texte) bzw. frueher $input.all() -> in Funktion wrappen; die Fakes liefern beides
        # (item UND all(); 'Load alert texts' leer -> englische Ersatztexte, wie bei einem DB-Ausfall).
        # Shape-tolerant, damit der Logik-Test auch bei Regression laeuft -- die Shape erzwingt Gesetz (5) unten.
        $script = "const __p = $payload;`nconst __h = $payloadH;`n" +
                  "const fn = (`$input, `$) => {`n$js`n};`n" +
                  "const mk = (p) => ({ item: { json: p }, all: () => [ { json: p } ], first: () => ({ json: p }) });`n" +
                  "const mkS = (p) => (n) => (n === 'On Error' ? mk(p) : { item: { json: {} }, all: () => [ { json: {} } ], first: () => ({ json: {} }) });`n" +
                  "const out = fn(mk(__p), mkS(__p));`nconst item = Array.isArray(out) ? out[0] : out;`nprocess.stdout.write(item.json.text);`n" +
                  "const outH = fn(mk(__h), mkS(__h));`nconst n = Array.isArray(outH) ? outH.length : 1;`nprocess.stdout.write('|HARNESS_SUPPRESSED=' + (n === 0 ? 'OK' : 'NO'));"
        [System.IO.File]::WriteAllText($tmp, $script, $Utf8NoBom)
        $out = ''
        try { $out = Invoke-LintNode @($tmpF.Rel) } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        if (-not ($out -match 'HARNESS_SUPPRESSED')) { Write-Host "    node-Ausgabe: $out" -ForegroundColor DarkGray }
        if ($Verbose) { Write-Host "    Format-Output:`n$out" -ForegroundColor DarkGray }
        Check 'Logik: Output enthaelt Workflow-Name'    { $out -match 'agent\.finance' }
        Check 'Logik: Output enthaelt Fehlermeldung'    { $out -match 'connection refused' }
        Check 'Logik: Output enthaelt fehlerhaften Node'{ $out -match 'Finance Agent' }
        Check 'Logik: Harness-Execution wird unterdrueckt' { $out -match 'HARNESS_SUPPRESSED=OK' }
    } else {
        Check 'Logik: node lokal oder Docker verfuegbar (sonst liefe der Format-Message-Logik-Test nicht)' { $false }
    }
}

# --- agent.tool_human_approval (HITL-Gate) ---
# Seit Teststrategie Phase 8 (Weg C) hat das Gate KEINEN Test-Bypass mehr; alle Tiers loesen das echte
# Send-and-Wait ueber das abgefangene Mock-Telegram auf (hitl_gate_test beweist Approve+Decline). Hier
# nur die statische Definition pruefen: parse_mode ist im n8n-sendAndWait HARTKODIERT 'Markdown' -> die
# Message MUSS die 4 Legacy-Entities (_ * ` [) escapen, sonst crasht jede Summary mit rohen Underscores
# (DB-Werte/Nutzerdaten) mit "can't parse entities".
Write-Host ""
Write-Host "agent.tool_human_approval (HITL-Gate):"
$gatePath = Resolve-WfPath 'agent.tool_human_approval'
Check 'Workflow-Datei vorhanden' { [bool]$gatePath -and (Test-Path $gatePath) }
if ($gatePath -and (Test-Path $gatePath)) {
    $gate = [System.IO.File]::ReadAllText($gatePath, $Utf8NoBom) | ConvertFrom-Json
    $askNode = $gate.nodes | Where-Object { $_.parameters.operation -eq 'sendAndWait' } | Select-Object -First 1
    Check 'sendAndWait-Node vorhanden (Ask Approval)' { $null -ne $askNode }
    Check 'Message escapt Markdown-Entities (_ * ` [)' {
        $null -ne $askNode -and "$($askNode.parameters.message)" -match 'replace\(/\[_\*'
    }
}

# --- Querschnitts-Gesetze (ALLE getrackten Workflows) ---
Write-Host ""
Write-Host "Querschnitt (alle Workflows): chat_id-Typsicherheit + Code-Node-Return-Shape:"

# Rekursive Walker: (a) alle Condition-Objekte (IF/Switch/Filter: leftValue+operator),
# (b) alle String-Werte der Node-Parameter.
function Get-ConditionObject($obj) {
    if ($null -eq $obj -or $obj -is [string] -or $obj -is [System.ValueType]) { return }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        if ($obj.PSObject.Properties['leftValue'] -and $obj.PSObject.Properties['operator']) { $obj }
        foreach ($p in $obj.PSObject.Properties) { Get-ConditionObject $p.Value }
        return
    }
    if ($obj -is [System.Collections.IEnumerable]) { foreach ($e in $obj) { Get-ConditionObject $e } }
}
function Get-StringValue($obj) {
    if ($null -eq $obj) { return }
    if ($obj -is [string]) { $obj; return }
    if ($obj -is [System.ValueType]) { return }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $obj.PSObject.Properties) { Get-StringValue $p.Value }
        return
    }
    if ($obj -is [System.Collections.IEnumerable]) { foreach ($e in $obj) { Get-StringValue $e } }
}

# (WP-5) Rohe (un-formatierte) Betraege/Daten in einer nutzer-sichtbaren Nachricht/Summary-Expression erkennen:
# Geld = eine Geld-Feld-Referenz (.amount/.balance/... — geschlossenes Vokabular, NICHT .shares/.count/IDs) OHNE
# die Formatter-Signatur toLocaleString( (Fmt-MoneyJs). Datum = eine *_date/period_*-Referenz OHNE die Signatur
# toLocaleDateString( (Fmt-DateJs, Intl im Empfaenger-Locale). Feld-Vokabular statt Blind-"+ zahl +" -> keine False-Positives auf Stueckzahlen/IDs;
# das 'EUR'-Fallback des Formatters ist gerade DURCH toLocaleString gedeckt (kippt den Geld-Flag nicht).
function Test-RawMoneyDate([string]$Text) {
    if ($Text -notmatch '\{\{') { return $false }
    $moneyRef = $Text -match '\.(?:amount|balance|annual_premium|premium|principal|monthly_annuity|annuity|target_amount|current_amount|monthly_savings_rate|savings_rate|market_value|net_worth|price_per_share|order_fee|opening_balance|plan_amount|computed|actual_amount|shortfall)\b'
    $rawMoney = ($moneyRef -and ($Text -notmatch 'toLocaleString\('))
    $rawDate  = (($Text -match '\.(?:\w+_date|period_end|period_start|value_date|due_date)\b') -and ($Text -notmatch 'toLocaleDateString\('))
    return ($rawMoney -or $rawDate)
}

$ORCH_ID = 'A6iPk9ezRzKzLbTj'
$vChatCond = @(); $vChatExpr = @(); $vExprProto = @(); $vCodeShape = @(); $vSrcBind = @()
$vTgAttr = @(); $vTgRetry = @(); $vTgEscape = @(); $vConnRef = @(); $vTgFmt = @(); $vNoSticky = @(); $vTgApprover = @(); $vStaleTap = @(); $vHitlStruct = @(); $vUmlaut = @(); $vTgWaitLimit = @(); $vTgEmptyParse = @()
# Ausnahmen vom Stale-Tap-Guard (10), je mit Grund:
$staleTapExempt = @(
    # HITL-Gate: je Empfaenger genau EIN Warte-Node pro Execution; die Owner-Stufe des Vier-Augen-Pfads hat andere
    # approverIds als die Member-Stufe -> ein wiederholter Member-Tipp prallt ab (hitl_gate_test hitlC2 beweist es).
    'agent.tool_human_approval'
)

# (6/7) Telegram-Gesetze: JEDER Send (nicht nur error_notify/Gate) braucht appendAttribution=false
# + retryOnFail; JEDER dynamische Text ({{...}}) muss die 4 Legacy-Markdown-Entities escapen
# (parse_mode: sendAndWait hartkodiert 'Markdown', sendMessage wirksamer Default -> "can't parse
# entities"-Klasse). Neue Sends entstehen nur noch via New-TelegramSendNode/-SendAndWaitNode
# (lib/build_helpers.ps1) -> erfuellen das strukturell; dieser Lint ist der Backstop.
# ESCAPE-ALLOWLIST (bewusst un-escapte dynamische Texte, je mit Grund):
$tgEscapeAllow = @(
    # LLM-Antwort-Relay des UI-verwalteten Orchestrators: zentrales Escape wuerde gewollte
    # Formatierung zerstoeren -> bewusst offen (BACKLOG "Markdown-Entity-Risiko bei LLM-Antworten").
    'agent.orchestrator.main_route :: Send a text message'
    # WS-1/WS-2/P1: dieselbe Klasse - die deterministischen onboarding:<package>:<key>-Callback-Arme relayen
    # den agent.<onboarding_agent>-LLM-Output ($json.output); zentrales Escape wuerde gewollte Formatierung
    # zerstoeren. 'Relay onboarding cb' (core/household) + 'Relay onboarding <pkg>' (P1 build-time pro Paket
    # generiert aus $OnboardingDispatchList) -> MUSTER-Allowlist $tgEscapeAllowLike unten, damit ein neues
    # Onboarding-Paket ohne workflow_lint-Edit andockt. (/onboarding selbst relayed nicht -> core.sub_send_onboarding_menu
    # sendet das Menue selbst.) Escape passiert UPSTREAM im Format-Message-Code-Node (eigener Check in der
    # error_notify-Sektion oben: "Code escapt Markdown-Entities").
    'core.sub_error_notify :: Send Telegram Alert'
)
# MUSTER-Allowlist (P1/WS-5): die build-time pro Paket generierten Relay-Nodes relayen LLM-Output un-escapt
# -> ein neues Paket dockt an, ohne dass diese Liste editiert werden muss. 'Relay onboarding *' = P1
# Onboarding-Dispatch-Arme; 'Relay command *' = WS-5 Command-Dispatch-Arme ($CommandDispatchList, /notfall).
$tgEscapeAllowLike = @(
    'agent.orchestrator.main_route :: Relay onboarding *'
    'agent.orchestrator.main_route :: Relay command *'
)
# WP-5 Formatter-Allowlist (bewusst un-formatierte Betraege/Daten in einer Nachricht/Summary, je mit Grund; Form +
# Key-Konvention 'wf :: node' wie $tgEscapeAllow). Leer = jede Geld-/Datums-Anzeige MUSS Fmt-MoneyJs/Fmt-DateJs nutzen.
$tgFmtAllow = @()
$tgFmtAllowLike = @()

foreach ($wfFile in (Get-AllWfFiles)) {
    $w = [System.IO.File]::ReadAllText($wfFile.FullName, $Utf8NoBom) | ConvertFrom-Json
    # (Stickies) Workflows sind die Doku: jeder Workflow traegt >= 1 Sticky-Note (Ueberblick) -- deterministischer
    # Backstop der Sticky-Pflicht (Root-CLAUDE.md, Arbeitsweise); Harness-Rightsizing 2026-10-20.
    if (@($w.nodes | Where-Object { $_.type -eq 'n8n-nodes-base.stickyNote' }).Count -eq 0) { $vNoSticky += "$($w.name)" }
    foreach ($n in $w.nodes) {
        if ($n.type -eq 'n8n-nodes-base.stickyNote') { continue }

        # (4a) String-Conditions auf chat_id ohne String()-Wrap (strict-IF crasht bei Zahl)
        foreach ($c in (Get-ConditionObject $n.parameters)) {
            $lv = "$($c.leftValue)"
            if ($c.operator.type -eq 'string' -and $lv -match 'chat_id|chat\.id' -and $lv -notmatch 'String\(') {
                $vChatCond += "$($w.name) :: $($n.name)"
            }
        }

        # (4b) .startsWith-Expressions auf chat_id ohne String()-Wrap (TypeError bei Zahl)
        foreach ($s in (Get-StringValue $n.parameters)) {
            if ($s -match 'chat_id' -and $s -match '\.startsWith\(' -and $s -notmatch 'String\(') {
                $vChatExpr += "$($w.name) :: $($n.name)"
            }
            # (4c) n8n-Ausdruecke ({{ }}) duerfen das Wort "prototype" nicht enthalten: n8n 2.x bricht sie zur Laufzeit
            # mit 'Cannot access "prototype" due to security concerns' ab (Code-Nodes sind nicht betroffen).
            if ($s.StartsWith('=') -and $s.Contains('{{') -and $s -match 'prototype') {
                $vExprProto += "$($w.name) :: $($n.name)"
            }
        }

        # (Textkatalog) sichtbare deutsche Texte mit echten Umlauten: jede Telegram-Textquelle (Literal bzw. die
        # String-Literale eines Ausdrucks; Knoten-Referenzen zaehlen nicht) — Nachricht, Caption, Toast, Knoepfe, Popup.
        if ($n.type -eq 'n8n-nodes-base.telegram') {
            $tp = $n.parameters
            $vis = @($tp.text, $tp.message, $tp.caption, $tp.additionalFields.caption, $tp.additionalFields.text,
                     $tp.unauthorizedReplyText, $tp.approvalOptions.values.approveLabel, $tp.approvalOptions.values.disapproveLabel)
            foreach ($row in @($tp.inlineKeyboard.rows)) { foreach ($b in @($row.row.buttons)) { $vis += $b.text } }
            foreach ($t in $vis) {
                if (-not $t) { continue }
                $s = [string]$t
                $parts = if ($s.StartsWith('=')) { Get-JsStringLiteral $s } else { @($s) }
                foreach ($x in $parts) {
                    $h = @(Find-UmlautSubstitute $x)
                    if ($h.Count) { $vUmlaut += "$($w.name) :: $($n.name) ($($h -join ', '))" }
                }
            }
        }

        # (5) runOnceForEachItem-Code-Node darf kein Array returnen
        if ($n.type -eq 'n8n-nodes-base.code' -and $n.parameters.mode -eq 'runOnceForEachItem' -and
            "$($n.parameters.jsCode)" -match 'return\s*\[') {
            $vCodeShape += "$($w.name) :: $($n.name)"
        }

        # (6) Telegram-Sends: appendAttribution=false (sendAndWait: options, sonst additionalFields)
        #     + retryOnFail; (7) dynamischer Text/Message escapt Markdown-Entities (oder Allowlist).
        #     resource 'file' (Vision-Download) und 'callback' (answerCallbackQuery: kein Message-Body,
        #     keine Attribution/kein parse_mode -> Toast-Text plain <=200 Zeichen) sind ausgenommen.
        #     operation 'sendMessageDraft' (New-TelegramDraftNode, "Bot denkt nach"-Platzhalter) ist NUR von Attribution
        #     und Retry ausgenommen (keine Nachricht, bewusst ohne Retry + onError=continue); Text-Escape/Formatter gelten.
        if ($n.type -eq 'n8n-nodes-base.telegram' -and "$($n.parameters.resource)" -notin @('file','callback')) {
            $key = "$($w.name) :: $($n.name)"
            $isSAW = ("$($n.parameters.operation)" -eq 'sendAndWait')
            $isDraft = ("$($n.parameters.operation)" -eq 'sendMessageDraft')
            # WS-5: sendDocument traegt seinen Text NICHT in .text, sondern in additionalFields.caption
            # (New-TelegramSendDocumentNode, Notfallmappe-Egress) -> sonst prueft der Escape-Check die
            # Caption gar nicht (stiller Durchlauf). Attribution/Retry sind node-unabhaengig.
            $isDoc = ("$($n.parameters.operation)" -eq 'sendDocument')
            $attr = if ($isSAW) { $n.parameters.options.appendAttribution } else { $n.parameters.additionalFields.appendAttribution }
            if ($attr -ne $false -and -not $isDraft) { $vTgAttr += $key }
            if ($n.retryOnFail -ne $true -and -not $isDraft) { $vTgRetry += $key }
            $txt = if ($isSAW) { "$($n.parameters.message)" } elseif ($isDoc) { "$($n.parameters.additionalFields.caption)" } else { "$($n.parameters.text)" }
            # WP-2: der Plain-Fallback sendet parse_mode='HTML' mit &/</> als Entities -> Legacy-Markdown-Entities
            # sind dort bedeutungslos, Escaping gegenstandslos -> ausgenommen. Ein LEERES parse_mode ist verboten:
            # n8n macht daraus still 'Markdown' (Exec 297, 2026-10-22) -> der "Plain"-Send crasht wie der Primary.
            $af = $n.parameters.additionalFields
            if ($af -and $af.PSObject.Properties['parse_mode'] -and "$($af.parse_mode)" -eq '') { $vTgEmptyParse += $key }
            $isPlain = ($af -and "$($af.parse_mode)" -eq 'HTML' -and $txt -match "replace\(/</g, '&lt;'\)")
            if ($txt -match '\{\{' -and $txt -notmatch 'replace\(/\[_\*' -and -not $isPlain -and $tgEscapeAllow -notcontains $key `
                -and -not ($tgEscapeAllowLike | Where-Object { $key -like $_ })) {
                $vTgEscape += $key
            }
            # (9) Bestaetigen im Chat: ein sendAndWait mit chatApproval (Deploy-Platzhalter oder true) braucht
            #     nicht-leere approverIds (leer = JEDER darf bestaetigen) und keinen .item-Ausdruck darin (im
            #     Webhook-Kontext ohne Item-Index ausgewertet) — Backstop zu New-TelegramSendAndWaitNode.
            if ($isSAW -and ($n.parameters.chatApproval -eq $true -or "$($n.parameters.chatApproval)" -eq '__HITL_CHAT_APPROVAL__')) {
                $ap = "$($n.parameters.approverIds)"
                if ([string]::IsNullOrWhiteSpace($ap) -or $ap -match '\.item\b') { $vTgApprover += $key }
            }
            # (11) Wartegrenze nur unter options: Telegram liest options.limitWaitTime (configureWaitTillDate), ein
            #      top-level limitWaitTime wird still ignoriert -> Karte wartet unbegrenzt — Backstop zu New-TelegramSendAndWaitNode.
            if ($isSAW -and $n.parameters.PSObject.Properties['limitWaitTime']) { $vTgWaitLimit += $key }
            # (WP-5) Formatter-Zwang: rohe Betraege/Daten in der Telegram-Nachricht -> Fmt-MoneyJs/Fmt-DateJs.
            if ((Test-RawMoneyDate $txt) -and $tgFmtAllow -notcontains $key `
                -and -not ($tgFmtAllowLike | Where-Object { $key -like $_ })) {
                $vTgFmt += $key
            }
        }

        # (WP-5 + Textkatalog) HITL-Summary-Set-Node 'Build Approval Summary': die Summary ist STRUKTURIERT (New-HitlSummary,
        # Zuweisung summary vom Typ object) — das Gate rendert sie je Empfaenger-Sprache, Betraege/Daten formatiert Intl.
        # (a) eine String-Summary (alte deutsche Form) ist verboten; (b) ein Geld-/Datums-Feld darf nicht als roher
        # kind 'text'-Wert stehen (dann fehlte die Formatierung) — Feld-Vokabular wie Test-RawMoneyDate.
        if ($n.type -eq 'n8n-nodes-base.set' -and "$($n.name)" -eq 'Build Approval Summary') {
            $skey = "$($w.name) :: $($n.name)"
            $asg = @($n.parameters.assignments.assignments | Where-Object { $_.name -eq 'summary' })
            if ($asg.Count -ne 1 -or "$($asg[0].type)" -ne 'object') { $vHitlStruct += $skey }
            foreach ($a in $asg) {
                # zwei Schreibweisen: New-HitlLine "kind: 'text', value: (<expr>)" und -LinesExpr-JS "kind: 'text', value: <expr>"
                $pat = "kind: 'text', value: (?:\(((?:[^()]|\((?:[^()]|\([^()]*\))*\))*)\)|([^,}\r\n]+))"
                foreach ($m in [regex]::Matches("$($a.value)", $pat)) {
                    $inner = '{{ ' + $(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }) + ' }}'
                    if ((Test-RawMoneyDate $inner) -and $tgFmtAllow -notcontains $skey `
                        -and -not ($tgFmtAllowLike | Where-Object { $skey -like $_ })) { $vTgFmt += $skey }
                }
            }
        }

        # (4c) Quelle: Orchestrator stringifiziert chat_id in JEDEM workflowInputs-Binding
        if ($w.id -eq $ORCH_ID -and $n.parameters.PSObject.Properties['workflowInputs']) {
            $bind = $n.parameters.workflowInputs.value
            if ($bind -and $bind.PSObject.Properties['chat_id'] -and $bind.chat_id -is [string] -and
                $bind.chat_id -match '^=\{\{' -and $bind.chat_id -notmatch 'String\(') {
                $vSrcBind += "$($w.name) :: $($n.name)"
            }
        }
    }

    # (10) Mehrere Chat-Bestaetigungs-Fragen in EINEM Workflow: n8n bindet einen Tipp an die Execution, nicht an die
    #      Nachricht -> ein Doppel-Tipp beantwortete die naechste wartende Frage. Jede Frage braucht dann den Guard
    #      New-StaleTapGuard (Folge-Node '<Frage> (tap check)'). Ausnahme mit Grund: $staleTapExempt.
    $chatAsks = @($w.nodes | Where-Object { $_.type -eq 'n8n-nodes-base.telegram' -and "$($_.parameters.operation)" -eq 'sendAndWait' -and `
        ($_.parameters.chatApproval -eq $true -or "$($_.parameters.chatApproval)" -eq '__HITL_CHAT_APPROVAL__') })
    if ($chatAsks.Count -ge 2 -and $staleTapExempt -notcontains "$($w.name)") {
        foreach ($a in $chatAsks) {
            $next = @(); try { $next = @($w.connections."$($a.name)".main | ForEach-Object { $_ } | ForEach-Object { $_.node }) } catch { }
            if ($next -notcontains "$($a.name) (tap check)") { $vStaleTap += "$($w.name) :: $($a.name)" }
        }
    }

    # (8) Connection-Konsistenz: jede Connection-Quelle UND jedes -Ziel referenziert einen existierenden Node.
    #     n8n import:workflow lehnt sonst den GANZEN Workflow ab (verifiziert P1: ein build-time generierter
    #     Dispatch-Arm, dessen Nodes nicht ins $nodes-Array gemerged wurden -> Deploy-Bruch; build.ps1 validiert
    #     das NICHT). Generisch ueber alle Workflows -> faengt die ganze Klasse pre-push (gratis) statt erst beim Deploy.
    $nodeNames = @($w.nodes | ForEach-Object { $_.name })
    if ($w.connections) {
        foreach ($srcProp in $w.connections.PSObject.Properties) {
            if ($nodeNames -notcontains $srcProp.Name) { $vConnRef += "$($w.name) :: Quelle '$($srcProp.Name)'" }
            foreach ($ctypeProp in $srcProp.Value.PSObject.Properties) {
                foreach ($outputs in $ctypeProp.Value) {
                    foreach ($c in $outputs) {
                        if ($c -and $c.node -and $nodeNames -notcontains $c.node) {
                            $vConnRef += "$($w.name) :: Ziel '$($c.node)' (von '$($srcProp.Name)')"
                        }
                    }
                }
            }
        }
    }
}

foreach ($v in ($vChatCond + $vChatExpr + $vExprProto + $vCodeShape + $vSrcBind + $vTgAttr + $vTgRetry + $vTgEscape + $vConnRef + $vTgFmt + $vNoSticky + $vTgApprover + $vStaleTap + $vHitlStruct + $vUmlaut + $vTgWaitLimit + $vTgEmptyParse | Sort-Object -Unique)) {
    Write-Host "    OFFENDER: $v" -ForegroundColor Yellow
}
Check 'Stickies: jeder Workflow traegt >= 1 Sticky-Note (Workflows sind die Doku)' { $vNoSticky.Count -eq 0 }
Check 'chat_id: String-Conditions String()-gewrappt (IF/Switch/Filter)' { $vChatCond.Count -eq 0 }
Check 'chat_id: .startsWith-Expressions String()-gewrappt'              { $vChatExpr.Count -eq 0 }
Check 'Ausdruecke: kein "prototype" (n8n sperrt es zur Laufzeit)'      { $vExprProto.Count -eq 0 }
Check 'chat_id: Orchestrator-Bindings stringifiziert (Quelle)'          { $vSrcBind.Count -eq 0 }
Check 'Code-Nodes: runOnceForEachItem returnt Einzel-Item (kein Array)' { $vCodeShape.Count -eq 0 }
Check 'Telegram: appendAttribution=false an JEDEM Send'                 { $vTgAttr.Count -eq 0 }
Check 'Telegram: retryOnFail an JEDEM Send'                             { $vTgRetry.Count -eq 0 }
Check 'Telegram: dynamischer Text escapt Markdown-Entities (_ * ` [)'   { $vTgEscape.Count -eq 0 }
Check 'Telegram/Summary: Betraege/Daten formatiert (Fmt-MoneyJs/Fmt-DateJs)' { $vTgFmt.Count -eq 0 }
Check 'HITL-Summary strukturiert (New-HitlSummary, je Empfaenger-Sprache gerendert)' { $vHitlStruct.Count -eq 0 }
Check 'Sichtbare Telegram-Texte: echte Umlaute statt Ersatzschreibweise' { $vUmlaut.Count -eq 0 }
Check 'Telegram: Bestaetigen im Chat nur mit approverIds (nie leer, kein .item)' { $vTgApprover.Count -eq 0 }
Check 'Telegram: mehrere Chat-Fragen je Workflow nur mit Doppel-Tipp-Schutz (tap check)' { $vStaleTap.Count -eq 0 }
Check 'Telegram: sendAndWait-Wartegrenze unter options (top-level limitWaitTime wird ignoriert)' { $vTgWaitLimit.Count -eq 0 }
Check "Telegram: kein leeres parse_mode (n8n macht daraus 'Markdown'; Plain = HTML + Escape)" { $vTgEmptyParse.Count -eq 0 }
Check 'Connections: jede Quelle/jedes Ziel referenziert einen Node'     { $vConnRef.Count -eq 0 }

# (Naht) Paket-Modularitaet (Install-UX-Phase 4): KEIN Core-Workflow traegt eine LITERALE Workflow-ID eines
# Paket-Workflows (executeWorkflow ODER toolWorkflow). n8n (geprueft 2.21.7 + 2.44.4) aktiviert einen Workflow nur, wenn alle literal
# referenzierten Ziele existieren + published sind -> ein solcher Verweis machte den Bot ohne das Paket taub
# (und `package uninstall` + Neustart ebenso). Paket-Agenten ruft der Core NUR ueber den Vermittler
# agent.sub_dispatch_agent (Ausdrucks-ID); die Ziel-ID darf dort als DATEN-Eingabe stehen, nie als workflowId.
# paperless Phase 2: dieselbe Naht gilt ZWISCHEN Paketen — ein Paket-Workflow traegt nie die literale ID eines Workflows
# eines FREMDEN Nicht-Core-Pakets (sonst aktiviert n8n ihn ohne das andere Paket nicht). Paket-Werkzeuge fuer fremde
# Agenten laufen ueber agent.sub_dispatch_tool (Laufzeit-Lookup der ID aus core.services).
$pkgWfIds = @{}   # id -> @{ File; Pkg } (nur Nicht-Core-Pakete)
foreach ($pf in (Get-AllWfFiles)) {
    if ($pf.Directory.Parent.Name -eq 'core') { continue }
    if ($pf.Name -match '^([A-Za-z0-9]{16})-') { $pkgWfIds[$Matches[1]] = @{ File = $pf.Name; Pkg = $pf.Directory.Parent.Name } }
}
$vSeam = @()
foreach ($cf in (Get-AllWfFiles)) {
    $callerPkg = $cf.Directory.Parent.Name
    $cw = [System.IO.File]::ReadAllText($cf.FullName, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
    foreach ($n in $cw.nodes) {
        $wid = $n.parameters.workflowId
        $val = if ($wid -is [string]) { $wid } elseif ($wid) { [string]$wid.value } else { '' }
        if ($val -and $pkgWfIds.ContainsKey($val) -and $pkgWfIds[$val].Pkg -ne $callerPkg) { $vSeam += "$($cw.name) :: $($n.name) -> $($pkgWfIds[$val].File)" }
    }
}
foreach ($v in $vSeam) { Write-Host "    OFFENDER: $v" -ForegroundColor Yellow }
Check 'Naht: kein Workflow referenziert einen Workflow eines fremden Pakets literal (nur via agent.sub_dispatch_agent/_tool)' { $pkgWfIds.Count -gt 0 -and $vSeam.Count -eq 0 }

# (Begruessung) Install-UX-Phase 6: die Owner-Begruessung hat ZWEI Sender mit EINER Textquelle
# (core.fn_render_welcome) — der Orchestrator bei /start (statische Knoepfe, n8n kann keine Ausdrucks-Tastatur,
# Issue #19955) und der Installer nach dem Pairing (Knoepfe aus der fn). Die Knopf-Ziele (callback_data) muessen
# deshalb in BEIDEN gleich sein: 'Send welcome new' im Orchestrator == die callback_data-Literale der fn (Reihenfolge).
$welcomeSql = Join-Path $RepoRoot 'packages/core/db/migrations/R__fn_render_welcome.sql'
$fnBtns = @()
if (Test-Path $welcomeSql) {
    $fnBtns = @([regex]::Matches([System.IO.File]::ReadAllText($welcomeSql, $Utf8NoBom), "'callback_data',\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
}
$wfBtns = @()
$orchPath = Resolve-WfPath 'agent.orchestrator.main_route'
if ($orchPath) {
    $ow = [System.IO.File]::ReadAllText($orchPath, $Utf8NoBom) | ConvertFrom-Json
    $wn = $ow.nodes | Where-Object { $_.name -eq 'Send welcome new' } | Select-Object -First 1
    if ($wn) {
        foreach ($r in @($wn.parameters.inlineKeyboard.rows)) {
            foreach ($b in @($r.row.buttons)) { $wfBtns += [string]$b.additionalFields.callback_data }
        }
    }
}
if ($Verbose -or (($fnBtns -join '|') -ne ($wfBtns -join '|'))) { Write-Host "    fn: $($fnBtns -join ', ')  |  Orchestrator: $($wfBtns -join ', ')" -ForegroundColor DarkGray }
Check 'Begruessung: Orchestrator-Knoepfe (Send welcome new) == Knopf-Vertrag von core.fn_render_welcome' { $fnBtns.Count -gt 0 -and (($fnBtns -join '|') -eq ($wfBtns -join '|')) }

# (Sprachmodelle) Modell-Phase 2 (Owner-Entscheid 2026-10-19): Chat-Modelle laufen nur noch ueber Claude. Ein
# Gemini-Chat-Node (lmChatGoogleGemini) ist ueberall verboten; ein Google-Gemini-Aufruf (googleGemini-Node,
# googlePalmApi-Credential, generativelanguage-URL) nur noch im Transkriptions-Tool (Claude versteht kein Audio).
$geminiAllow = @('agent.tool_transcribe_telegram_voice')
$vGemini = @()
foreach ($wfFile in (Get-AllWfFiles)) {
    $w = [System.IO.File]::ReadAllText($wfFile.FullName, $Utf8NoBom) | ConvertFrom-Json
    foreach ($n in $w.nodes) {
        if ($n.type -eq 'n8n-nodes-base.stickyNote') { continue }
        $raw = $n | ConvertTo-Json -Depth 30 -Compress
        if ($n.type -eq '@n8n/n8n-nodes-langchain.lmChatGoogleGemini') { $vGemini += "$($w.name) :: $($n.name) (Gemini-Chat-Node)" }
        elseif ($geminiAllow -notcontains $w.name -and $raw -match 'googleGemini|googlePalmApi|generativelanguage') {
            $vGemini += "$($w.name) :: $($n.name)"
        }
    }
}
if ($vGemini.Count) { $vGemini | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
Check 'Sprachmodelle: kein Gemini-Chat-Node; Google-Gemini nur im Transkriptions-Tool' { $vGemini.Count -eq 0 }

# (Frei-SQL) Live-Befund 2026-10-24: ein postgresTool ohne query-Argument liess n8n intern werfen ("reading 'match'").
# Jedes postgresTool, dessen query das LLM per $fromAI liefert, kommt aus New-PostgresSelectToolNode und traegt den
# Guard (leere query -> SELECT ... AS error). Nicht betroffen: load_context (query fest, $fromAI nur im Parameter).
$vSqlGuard = @()
foreach ($wfFile in (Get-AllWfFiles)) {
    $w = [System.IO.File]::ReadAllText($wfFile.FullName, $Utf8NoBom) | ConvertFrom-Json
    foreach ($n in @($w.nodes | Where-Object { $_.type -eq 'n8n-nodes-base.postgresTool' })) {
        $q = [string]$n.parameters.query
        if ($q -match '\$fromAI\(' -and $q -notmatch "\|\|\s*`"SELECT false AS ok") { $vSqlGuard += "$($w.name) :: $($n.name)" }
    }
}
if ($vSqlGuard.Count) { $vSqlGuard | ForEach-Object { Write-Host "    $_ (Frei-SQL ohne Guard -> New-PostgresSelectToolNode)" -ForegroundColor DarkGray } }
Check 'Frei-SQL: jedes postgresTool mit $fromAI-query traegt den Guard gegen fehlendes Argument' { $vSqlGuard.Count -eq 0 }

# --- Ausdrucks-Syntax: jeder {{ … }}-Ausdruck ist gueltiges JavaScript (node, falls verfuegbar) ---
if ($LintNode) {
    $exprJs = @'
const fs = require('fs');
const files = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const params = ['$', '$json', '$input', '$node', '$now', '$today', '$execution', '$workflow', '$vars', '$items', '$prevNode', '$runIndex', '$binary', '$env', '$fromAI'];
const visit = (v, cb) => { if (typeof v === 'string') cb(v); else if (Array.isArray(v)) v.forEach(x => visit(x, cb)); else if (v && typeof v === 'object') Object.values(v).forEach(x => visit(x, cb)); };
let checked = 0; const bad = [];
for (const f of files) {
  const wf = JSON.parse(fs.readFileSync(f, 'utf8'));
  for (const n of (wf.nodes || [])) {
    if (n.type === 'n8n-nodes-base.code' || n.type === 'n8n-nodes-base.stickyNote') continue;
    visit(n.parameters, (s) => {
      if (!s.startsWith('=') || !s.includes('{{')) return;
      // Zerlegt wie n8n: jeder Ausdruck endet am ERSTEN "}}" (auch innerhalb eines Strings).
      const re = /\{\{([\s\S]*?)\}\}/g; let m;
      while ((m = re.exec(s)) !== null) {
        checked++;
        try { new Function(...params, 'return (' + m[1] + '\n);'); }
        catch (e) { bad.push(wf.name + ' :: ' + n.name + ' :: ' + e.message); }
      }
    });
  }
}
process.stdout.write(JSON.stringify({ checked, bad }));
'@
    $tmpJs = New-LintTmpFile '.js'; $tmpList = New-LintTmpFile '.json'
    $rootLen = ([string]$RepoRoot).Replace('/', '\').TrimEnd('\').Length + 1
    [System.IO.File]::WriteAllText($tmpJs.Full, $exprJs, $Utf8NoBom)
    [System.IO.File]::WriteAllText($tmpList.Full, (ConvertTo-Json -InputObject @(Get-AllWfFiles | ForEach-Object { $_.FullName.Substring($rootLen).Replace('\', '/') }) -Compress), $Utf8NoBom)
    $exprRes = $null
    try {
        $exprOut = Invoke-LintNode @($tmpJs.Rel, $tmpList.Rel)
        try { $exprRes = $exprOut | ConvertFrom-Json } catch { Write-Host "    node-Ausgabe unlesbar: $exprOut" -ForegroundColor DarkGray }
    } finally { Remove-Item $tmpJs.Full, $tmpList.Full -ErrorAction SilentlyContinue }
    if ($exprRes) { @($exprRes.bad) | ForEach-Object { if ($_) { Write-Host "    $_" -ForegroundColor DarkGray } } }
    Check "Ausdruecke: jeder {{ }}-Ausdruck ist gueltiges JavaScript ($(if ($exprRes) { $exprRes.checked } else { '?' }) geprueft)" { $null -ne $exprRes -and @($exprRes.bad).Count -eq 0 }
} else {
    # Nie still ausfallen (CI-Runner bringen node mit, lokal laeuft er ueber Docker): fehlt beides, ist das ein Fehler.
    Check 'Ausdruecke: node lokal oder Docker verfuegbar (sonst liefe der Syntax-Check nicht)' { $false }
}

Write-Host ("-" * 60)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$failed Workflow-Lint-Check(s) fehlgeschlagen." -ForegroundColor $color
Write-Host ""
exit $failed
