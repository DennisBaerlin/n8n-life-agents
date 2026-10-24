#Requires -Version 5.1
# Auto-Judge -- automatisierte Bewertung der Verhaltens-Rubrics (Layer 2, Judge-Schritt).
# Liest tests\agent\judge_bundle.json (von n8n_test.ps1 erzeugt) und bewertet jede Rubric
# per LLM. Der finale Verdikt ist KOMBINIERT:
#
#   OVERALL PASS  <=>  det_pass (deterministisches Routing+Args) UND Judge-Verdikt == PASS
#
# det_pass kommt aus dem Bundle (n8n_test.ps1 schreibt es mit); der Judge bewertet nur das
# Verhalten/die Parameter (z. B. fragt nach Zinssatz, nennt Saldo, erklaert Mismatch).
#
# --- A1: Judge-KALIBRIERUNG (gegen menschliche Labels) ---
#   .\scripts\judge_eval.ps1 -Calibrate
#   Misst den Judge gegen tests\agent\cross\judge_labels.json (hand-gelabelte Faelle): Agreement-Rate
#   + Cohen's kappa (binaer PASS vs. nicht-PASS). Ein ungemessener LLM-Judge ist ein ungemessenes
#   Messinstrument -> diese Eichung validiert, dass ein "PASS" etwas wert ist. Bei jedem
#   Judge-Modell-/Provider-Wechsel neu laufen lassen. Exit != 0 wenn kappa < Schwelle.
#
# --- Judge-Modell (Modell-Phase 2) ---
#   Claude Haiku 5.5 ueber die Anthropic-Messages-API (wie die Agenten seit Modell-Phase 2 nur noch Claude;
#   der fruehere Google-Zweig ist entfernt). Das Urteil kommt per Structured Output (output_config.format,
#   JSON-Schema verdict+reason), Denk-Tiefe low, KEINE Sampling-Parameter (die 5.5-Generation lehnt
#   temperature mit 400 ab). -Model ueberschreibt die gepinnte Version (z. B. claude-sonnet-5-5).
#
# --- C2: ERROR != FAIL ---
#   Ein API-Timeout/Parse-Fehler des Judges (verdict=ERROR) ist Infra-Flake, KEIN inhaltliches FAIL.
#   ERROR wird einmal ge-retry-t und im Summary getrennt ausgewiesen (nicht als Rubric-FAIL).
#
# Exit-Code = Anzahl OVERALL FAILs + nicht-aufloesbare ERRORs (Gate bleibt ehrlich: unjudged != gruen).
# Voraussetzungen: .env mit ANTHROPIC_API_KEY.
#   Scripts-Only-Policy: offizielles Skript, nur auf explizite Aufforderung (kostet LLM-Calls).
param(
    [string]$Model = 'claude-haiku-5-5',
    [switch]$Calibrate,
    [double]$KappaThreshold = 0.6,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot  = git -C $PSScriptRoot rev-parse --show-toplevel

# .env laden (gleicher Mechanismus wie die uebrigen Skripte)
Get-Content "$RepoRoot\.env" | ForEach-Object {
    if ($_ -match '^\s*([^#\s][^=]*)=(.*)$') {
        Set-Variable -Name $Matches[1].Trim() -Value $Matches[2].Trim() -Scope Script
    }
}

# Key kommt IMMER als Header (nie im URI) -> der Key landet nie in URL-basierten Fehlermeldungen.
if ([string]::IsNullOrEmpty((Get-Variable 'ANTHROPIC_API_KEY' -ValueOnly -ErrorAction SilentlyContinue))) {
    throw "ANTHROPIC_API_KEY ist nicht gesetzt in .env (der Judge laeuft ueber Claude)."
}
$script:Endpoint = 'https://api.anthropic.com/v1/messages'
$script:ApiKey   = $ANTHROPIC_API_KEY
$Provider = 'anthropic'   # nur fuer die Ausgabe-Zeilen
# Kostenuebersicht (gleiche Ausgabe wie die Agent-Suiten): der Judge ruft Anthropic DIREKT (nicht ueber den
# LLM-Gateway des Substrats) -> usage je Antwort lokal mitzaehlen. Bewusst KEIN Prompt-Caching (System ~120 Token
# < 512-Minimum) und KEINE Batch-API (~40 Haiku-Aufrufe ~ 0,01 $/Lauf -> -50 % spart < 1 Cent).
. "$PSScriptRoot\dev\test_n8n_state.ps1"
$script:JudgeUsage = New-Object System.Collections.ArrayList

# System-Instruction: knapp, erzwingt parsebares JSON.
$SystemText = @'
Du bewertest, ob das Verhalten eines Finanz-Agenten eine vorgegebene Erwartungs-Rubric erfuellt.
Beruecksichtige sowohl den Antworttext als auch den tatsaechlichen Tool-Aufruf inkl. seiner
Argumente; die eigentliche Entscheidung steht oft in ACTUAL_TOOL_INPUT.

So arbeitet das Testsystem (das ist KEIN Fehler des Agenten):
- Jede Bestaetigungs-Karte eines Schreib-Werkzeugs wird im Test absichtlich ABGELEHNT. Das Werkzeug
  meldet dann "abgebrochen" (cancelled). Meldet der Agent danach den Abbruch oder fragt, was er aendern
  soll, ist das korrekt. Bewerte, ob der Tool-Aufruf davor richtig war.
- Schreib-Werkzeuge machen vor der Karte einen Probelauf in der Datenbank. ok:false (ohne Karte) heisst:
  die Datenbank hat den Vorgang sachlich abgelehnt; der Agent soll das sachlich melden, nichts erfinden.
- READ_TOOLS ist unvollstaendig protokolliert. Ein fehlender Lese-Aufruf ist nie allein ein Grund fuer
  PARTIAL/FAIL. Die Werkzeuge loesen Namen selbst auf; ein Lese-Aufruf vorher ist kein Muss.
- Zahlen, ids und Wahrheitswerte als Text ("1", "2.0", "true") sind gleichwertig zu Zahl/Boolean.
- Optionale Felder mit Datenbank-Standard (Datum = heute, Ordergebuehr = 0, Gueltig-ab = heute) darf der
  Agent leer lassen; "heute" ergibt ein leeres Datum. Ein ERFUNDENES anderes Datum ist dagegen falsch.
- Ein optionales Angebot ("wenn du magst, trage ich die IBAN nach") ist keine Rueckfrage; eine
  Rueckfrage, die den Vorgang blockiert, schon.

Antworte AUSSCHLIESSLICH als JSON ohne Markdown-Fences in der Form:
{"verdict":"PASS|FAIL|PARTIAL","reason":"kurze Begruendung"}.
PASS nur, wenn die Rubric vollstaendig erfuellt ist; PARTIAL bei teilweiser Erfuellung; sonst FAIL.
'@

# Baut den User-Prompt-Text aus einem Bundle-/Label-Eintrag.
function Format-JudgeUserText([object]$Entry) {
    return @"
TASK:
$($Entry.task)

EXPECTED_BEHAVIOR (Rubric):
$($Entry.expected_behavior)

ACTUAL_TOOL: $($Entry.actual_tool)
ACTUAL_TOOL_INPUT: $($Entry.actual_tool_input)
READ_TOOLS: $($Entry.read_tools)
$(if ($Entry.specialist_output) { "`nSPECIALIST_OUTPUT (the specialist's reply the orchestrator relayed):`n$($Entry.specialist_output)`n" })
ACTUAL_OUTPUT:
$($Entry.actual_output)
"@
}

# Urteils-Schema (Structured Output): die API garantiert parsebares JSON mit genau diesen Feldern.
$VerdictSchema = [ordered]@{
    type                 = 'object'
    properties           = [ordered]@{
        verdict = [ordered]@{ type = 'string'; enum = @('PASS', 'FAIL', 'PARTIAL') }
        reason  = [ordered]@{ type = 'string' }
    }
    required             = @('verdict', 'reason')
    additionalProperties = $false
}

# Ein Judge-Call. Liefert @{ verdict; reason }. verdict in PASS|FAIL|PARTIAL|ERROR.
function Invoke-JudgeOnce([object]$Entry) {
    $userText = Format-JudgeUserText $Entry
    try {
        # max_tokens grosszuegig: die 5.5-Generation denkt immer mit, das Denken zaehlt zu max_tokens.
        $body = [ordered]@{
            model         = $Model
            max_tokens    = 16000
            system        = $SystemText
            messages      = @(@{ role = 'user'; content = $userText })
            output_config = [ordered]@{ effort = 'low'; format = [ordered]@{ type = 'json_schema'; schema = $VerdictSchema } }
        } | ConvertTo-Json -Depth 12
        $resp = Invoke-RestMethod -Uri $Endpoint -Method Post `
            -Headers @{ 'x-api-key' = $script:ApiKey; 'anthropic-version' = '2023-06-01' } `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
        if ($resp.usage) {
            [void]$script:JudgeUsage.Add([pscustomobject]@{ model = $Model; input_tokens = $resp.usage.input_tokens
                cache_creation_input_tokens = $resp.usage.cache_creation_input_tokens; cache_read_input_tokens = $resp.usage.cache_read_input_tokens
                output_tokens = $resp.usage.output_tokens; web_search_requests = 0; fallback = $false })
        }
        if ($resp.stop_reason -in @('max_tokens', 'refusal', 'pause_turn')) {
            return @{ verdict = 'ERROR'; reason = "Judge-Antwort unvollstaendig (stop_reason $($resp.stop_reason))" }
        }
        # Alle text-Bloecke ohne Trenner zusammenfuegen (Muster anthropicText in Get-AnthropicResultJs).
        $raw = (@($resp.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ''
    } catch {
        # NUR Statuszeile ausgeben -- niemals $_ roh (koennte Request-Header/-Body spiegeln).
        $msg = "$Provider-API-Call fehlgeschlagen"
        try { if ($_.Exception.Response.StatusCode) { $msg += " (HTTP $([int]$_.Exception.Response.StatusCode))" } } catch { }
        return @{ verdict = 'ERROR'; reason = $msg }
    }

    if ([string]::IsNullOrWhiteSpace($raw)) { return @{ verdict = 'ERROR'; reason = 'Leere Judge-Antwort' } }
    $raw = ($raw -replace '^\s*```(json)?', '' -replace '```\s*$', '').Trim()
    try {
        $parsed = $raw | ConvertFrom-Json
        $v = "$($parsed.verdict)".ToUpper()
        if ($v -notin @('PASS','FAIL','PARTIAL')) { $v = 'ERROR' }
        return @{ verdict = $v; reason = "$($parsed.reason)" }
    } catch {
        return @{ verdict = 'ERROR'; reason = 'Judge-Antwort nicht als JSON parsebar' }
    }
}

# C2: ERROR ist Infra-Flake -> einmal retryen, bevor wir aufgeben.
function Invoke-Judge([object]$Entry) {
    $r = Invoke-JudgeOnce $Entry
    if ($r.verdict -eq 'ERROR') {
        Start-Sleep -Milliseconds 800
        $r2 = Invoke-JudgeOnce $Entry
        if ($r2.verdict -ne 'ERROR') { return $r2 }
    }
    return $r
}

# =======================================================================
# A1: Kalibrierungs-Modus -- Judge gegen menschliche Labels messen.
# =======================================================================
if ($Calibrate) {
    $labelPath = Join-Path $RepoRoot 'tests\agent\cross\judge_labels.json'
    if (-not (Test-Path $labelPath)) {
        throw "judge_labels.json nicht gefunden ($labelPath). Lege hand-gelabelte Faelle an (human_verdict je Eintrag)."
    }
    $labels = [System.IO.File]::ReadAllText($labelPath, $Utf8NoBom) | ConvertFrom-Json
    if ($labels -isnot [System.Array]) { $labels = @($labels) }

    Write-Host ""
    Write-Host "Judge-Kalibrierung ($Provider/$Model) -- $($labels.Count) Label-Case(s)"
    Write-Host ("-" * 64)

    # Binaer: human/judge auf PASS vs. nicht-PASS (PARTIAL/FAIL = nicht-PASS) reduzieren -- so wird
    # auch das OVERALL-Gate gefahren (nur PASS zaehlt). Confusion-Matrix-Zellen:
    $tp = 0; $tn = 0; $fp = 0; $fn = 0; $errc = 0
    foreach ($e in $labels) {
        $human = "$($e.human_verdict)".ToUpper()
        if ($human -notin @('PASS','FAIL','PARTIAL')) { throw "Case '$($e.id)': human_verdict fehlt/ungueltig ('$human')." }
        $j = Invoke-Judge $e
        if ($j.verdict -eq 'ERROR') {
            $errc++
            Write-Host ("  [{0}] human={1}  judge=ERROR  ({2})" -f $e.id, $human, $j.reason) -ForegroundColor Yellow
            continue
        }
        $hPass = ($human -eq 'PASS')
        $jPass = ($j.verdict -eq 'PASS')
        if ($hPass -and $jPass)       { $tp++ }
        elseif (-not $hPass -and -not $jPass) { $tn++ }
        elseif (-not $hPass -and $jPass)      { $fp++ }   # Judge zu nachsichtig (gefaehrlich)
        else                                   { $fn++ }   # Judge zu streng
        $mark = if ($hPass -eq $jPass) { 'agree' } else { 'DISAGREE' }
        $col  = if ($hPass -eq $jPass) { 'Green' } else { 'Red' }
        Write-Host ("  [{0}] human={1}  judge={2}  -> {3}" -f $e.id, $human, $j.verdict, $mark) -ForegroundColor $col
        if (($Verbose -or $mark -eq 'DISAGREE')) { Write-Host "      reason: $($j.reason)" -ForegroundColor DarkGray }
    }

    $n = $tp + $tn + $fp + $fn
    Write-Host ""
    Write-Host ("-" * 64)
    if ($n -eq 0) { Write-Host "Keine auswertbaren Faelle (alle ERROR?)." -ForegroundColor Red; exit 1 }

    $po = ($tp + $tn) / $n                                  # beobachtete Uebereinstimmung
    $pPassH = ($tp + $fn) / $n; $pPassJ = ($tp + $fp) / $n  # Randverteilungen
    $pe = ($pPassH * $pPassJ) + ((1 - $pPassH) * (1 - $pPassJ))  # erwartete Zufalls-Uebereinstimmung
    $kappa = if ((1 - $pe) -eq 0) { 1.0 } else { ($po - $pe) / (1 - $pe) }

    Write-Host ("Confusion (PASS vs. nicht-PASS):  TP={0}  TN={1}  FP={2}  FN={3}  (ERROR={4})" -f $tp,$tn,$fp,$fn,$errc)
    Write-Host ("Agreement (po): {0:P1}    Cohen's kappa: {1:N3}    Schwelle: {2:N2}" -f $po, $kappa, $KappaThreshold)
    if ($fp -gt 0) { Write-Host ("  WARNUNG: {0}x Judge zu NACHSICHTIG (FP) -- laesst echte Fehler durch." -f $fp) -ForegroundColor Yellow }
    Write-LlmCostReport -Usage @($script:JudgeUsage) -Label 'judge_eval -Calibrate' -RepoRoot $RepoRoot
    if ($kappa -ge $KappaThreshold) {
        Write-Host "[KALIBRIERUNG OK] Judge ist ausreichend mit den Labels aligned." -ForegroundColor Green
        exit 0
    } else {
        Write-Host "[KALIBRIERUNG UNGENUEGEND] kappa < Schwelle -> Judge-Urteil ist nicht vertrauenswuerdig (Rubrics schaerfen / Judge-Modell wechseln)." -ForegroundColor Red
        exit 1
    }
}

# =======================================================================
# Normalbetrieb: Bundle bewerten.
# =======================================================================
$bundlePath = Join-Path $RepoRoot 'tests\agent\judge_bundle.json'
if (-not (Test-Path $bundlePath)) {
    throw "judge_bundle.json nicht gefunden ($bundlePath). Erst .\scripts\n8n_test.ps1 ausfuehren."
}
$bundle = [System.IO.File]::ReadAllText($bundlePath, $Utf8NoBom) | ConvertFrom-Json
if (-not $bundle) { Write-Host "Bundle ist leer -- nichts zu bewerten."; exit 0 }
if ($bundle -isnot [System.Array]) { $bundle = @($bundle) }

Write-Host ""
Write-Host "Auto-Judge ($Provider/$Model) -- $($bundle.Count) Rubric-Case(s)"
Write-Host ("-" * 64)

$overallFail = 0
$errorCount  = 0
foreach ($e in $bundle) {
    Write-Host ""
    Write-Host "  [$($e.id)] $($e.name)"
    $detPass = [bool]$e.det_pass
    Write-Host "    det_pass (Routing+Args): $detPass   (erwartet tool=$($e.expected_tool), tatsaechlich=$($e.actual_tool))"

    $j = Invoke-Judge $e
    Write-Host "    Judge: $($j.verdict)"
    if ($Verbose -or $j.verdict -ne 'PASS') { Write-Host "      reason: $($j.reason)" -ForegroundColor DarkGray }

    # C2: ERROR (auch nach Retry) ist KEIN inhaltliches FAIL -> separat ausweisen.
    if ($j.verdict -eq 'ERROR') {
        $errorCount++
        Write-Host "    [JUDGE ERROR] -> Infra/Parsing (nicht als Rubric-FAIL gewertet, aber Gate nicht gruen)" -ForegroundColor Yellow
        continue
    }

    $overall = if ($detPass -and $j.verdict -eq 'PASS') { 'PASS' } else { 'FAIL' }
    if ($overall -eq 'PASS') {
        Write-Host "    [OVERALL PASS]" -ForegroundColor Green
    } else {
        $overallFail++
        $why = if (-not $detPass) { 'Routing/Args (det_pass=false)' } elseif ($j.verdict -ne 'PASS') { "Rubric ($($j.verdict))" } else { '?' }
        Write-Host "    [OVERALL FAIL] -> $why" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host ("-" * 64)
$passed = $bundle.Count - $overallFail - $errorCount
$color  = if ($overallFail -eq 0 -and $errorCount -eq 0) { 'Green' } else { 'Red' }
Write-Host "$passed/$($bundle.Count) Cases OVERALL PASS (det AND Rubric), $overallFail inhaltliche FAILs, $errorCount Judge-ERROR (Infra)." -ForegroundColor $color
if ($errorCount -gt 0) { Write-Host "Hinweis: ERROR = Judge nicht auswertbar (API/Parsing), NICHT inhaltlich durchgefallen -- erneut laufen lassen." -ForegroundColor Yellow }
Write-Host ""

# Gate bleibt ehrlich: unjudged (ERROR) zaehlt in den Exit-Code (Gruen nur wenn alles wirklich PASS),
# wird im Summary aber klar von echten Rubric-FAILs getrennt (nicht mehr als FAIL fehl-etikettiert).
Write-LlmCostReport -Usage @($script:JudgeUsage) -Label 'judge_eval' -RepoRoot $RepoRoot
exit ($overallFail + $errorCount)
