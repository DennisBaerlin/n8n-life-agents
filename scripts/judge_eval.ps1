#Requires -Version 5.1
# Auto-Judge -- automatisierte Bewertung der Verhaltens-Rubrics (Layer 2, Judge-Schritt).
# Liest tests\agent\judge_bundle.json (von n8n_test.ps1 erzeugt) und bewertet jede Rubric
# per LLM. Das finale Verdikt ist kombiniert:
#
#   OVERALL PASS  <=>  det_pass (deterministisches Routing+Args) UND Judge-Verdikt == PASS
#
# det_pass kommt aus dem Bundle (n8n_test.ps1 schreibt es mit); der Judge bewertet nur das
# Verhalten/die Parameter (z. B. fragt nach Zinssatz, nennt Saldo, erklaert Mismatch).
#
# Usage:
#   .\scripts\judge_eval.ps1                  # Bundle bewerten
#   .\scripts\judge_eval.ps1 -Calibrate       # Judge gegen Labels eichen
#   .\scripts\judge_eval.ps1 -Model <id>      # gepinnte Judge-Version ueberschreiben (z. B. claude-sonnet-5-5)
#
# --- A1: Judge-Kalibrierung (gegen menschliche Labels) ---
#   Misst den Judge gegen tests\agent\cross\judge_labels.json (hand-gelabelte Faelle): Agreement-Rate
#   + Cohen's kappa (binaer PASS vs. nicht-PASS). Ein ungemessener LLM-Judge ist ein ungemessenes
#   Messinstrument -> diese Eichung validiert, dass ein "PASS" etwas wert ist. Bei jedem
#   Judge-Modell-/Provider-Wechsel neu laufen lassen. Exit != 0 wenn kappa < Schwelle.
#
# --- Judge-Modell ---
#   Claude Haiku 5.5 ueber die Anthropic-Messages-API. Das Urteil kommt per Structured Output
#   (output_config.format, JSON-Schema verdict+reason), Denk-Tiefe low, keine Sampling-Parameter
#   (die 5.5-Generation lehnt temperature mit 400 ab).
#
# --- C2: ERROR != FAIL ---
#   Ein API-Timeout/Parse-Fehler des Judges (verdict=ERROR) ist Infra-Flake, kein inhaltliches FAIL.
#   ERROR wird einmal ge-retry-t und im Summary getrennt ausgewiesen (nicht als Rubric-FAIL).
#
# --- Urteile bleiben erhalten ---
#   Je Lauf eine Datei .local/judge_runs/<zeit>-<suite>.jsonl im Haupt-Checkout (gitignored), eine Zeile je Fall: Suite, Fall-ID, Urteil,
#   Begruendung, det_pass, Gesamturteil, Modell, Commit (+ dirty). Das Bundle ist nach dem Lauf leer; Format und Schreibweg: lib/judge_record.ps1.
#
# Exit-Code = Anzahl OVERALL FAILs + nicht-aufloesbare ERRORs (Gate bleibt ehrlich: unjudged != gruen).
# Voraussetzungen: .env mit ANTHROPIC_API_KEY; der Lauf kostet LLM-Calls und braucht das Owner-Fenster.
param(
    [string]$Model = 'claude-haiku-5-5',
    [switch]$Calibrate,
    [double]$KappaThreshold = 0.6,
    [double]$MaxCostUsd = 1.0,   # haelt den Lauf vor dem naechsten Eintrag an (lib/paid_guard.ps1); ein Lauf kostet ~0,01 $, 0 = aus
    [string]$ForceAbortId,       # wirft am Anfang dieses Eintrags: zeigt den Abbruch-Pfad ohne API-Aufruf
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot  = git -C $PSScriptRoot rev-parse --show-toplevel

. "$PSScriptRoot\lib\dotenv.ps1"
Read-DotEnvLines "$RepoRoot\.env" | ForEach-Object {
    if ($_ -match '^\s*([^#\s][^=]*)=(.*)$') {
        Set-Variable -Name $Matches[1].Trim() -Value $Matches[2].Trim() -Scope Script
    }
}

# Der Key geht immer als Header, nie im URI -> er landet nie in URL-basierten Fehlermeldungen.
if ([string]::IsNullOrEmpty((Get-Variable 'ANTHROPIC_API_KEY' -ValueOnly -ErrorAction SilentlyContinue))) {
    throw "ANTHROPIC_API_KEY ist nicht gesetzt in .env (der Judge laeuft ueber Claude)."
}
$script:Endpoint = 'https://api.anthropic.com/v1/messages'
$script:ApiKey   = $ANTHROPIC_API_KEY
$Provider = 'anthropic'   # nur fuer die Ausgabe-Zeilen
# Der Judge ruft Anthropic direkt (nicht ueber den LLM-Gateway des Substrats) -> usage je Antwort lokal
# mitzaehlen fuer die Kostenuebersicht. Bewusst kein Prompt-Caching (System ~120 Token < 512-Minimum)
# und keine Batch-API (~40 Haiku-Aufrufe ~ 0,01 $/Lauf -> -50 % spart < 1 Cent).
. "$PSScriptRoot\dev\test_n8n_state.ps1"
$script:JudgeUsage = New-Object System.Collections.ArrayList
. "$PSScriptRoot\lib\paid_guard.ps1"
$JudgePrices = Get-LlmPriceTable -RepoRoot $RepoRoot
$script:CostReported = $false
# Kostengrenze: die Judge-Aufrufe laufen direkt gegen die API, die Kosten stehen lokal in $script:JudgeUsage (kein Gateway-Journal).
function Test-JudgeBudget {
    $cost = Get-UsageCostUsd -Usage @($script:JudgeUsage) -Prices $JudgePrices
    if (-not (Test-CostLimitExceeded -CostUsd $cost -MaxCostUsd $MaxCostUsd)) { return $false }
    Write-Host "    [FAIL] Kostengrenze $MaxCostUsd USD ueberschritten ($([Math]::Round($cost, 3)) USD) - Lauf angehalten." -ForegroundColor Red
    return $true
}
# Ein Eintrag, bei dem der Judge-Aufruf selbst wirft (oder -ForceAbortId trifft), zaehlt als ERROR; der Lauf geht weiter.
function Invoke-JudgeGuarded([object]$Entry) {
    try { Test-ForceAbort ([string]$Entry.id) $ForceAbortId; return (Invoke-Judge $Entry) }
    catch { Write-CaseAbort -ErrorRecord $_ -CaseId ([string]$Entry.id); return @{ verdict = 'ERROR'; reason = 'Abbruch (Ausnahme)' } }
}
function Write-JudgeCostReport([string]$Label) {
    $script:CostReported = $true
    Write-LlmCostReport -Usage @($script:JudgeUsage) -Label $Label -RepoRoot $RepoRoot
}

. "$PSScriptRoot\lib\judge_prompt.ps1"   # Get-JudgeSystemText, Format-JudgeUserText (Karten-Entscheid je Eintrag)
. "$PSScriptRoot\lib\http_json.ps1"      # Invoke-JsonPostUtf8: API-Antwort als UTF-8 (sonst Mojibake in der Begruendung)
. "$PSScriptRoot\lib\judge_record.ps1"   # Urteile je Fall dauerhaft nach .local/judge_runs (das Bundle ist nach dem Lauf leer)
$script:RunStamp = Get-JudgeRunStamp -RepoRoot $RepoRoot
$script:RunFile  = $null
function Save-JudgeVerdict([object]$Entry, [hashtable]$Verdict, [string]$Mode, [string]$Overall) {
    Add-JudgeRunRecord -Path $script:RunFile -Entry $Entry -Verdict $Verdict.verdict -Reason $Verdict.reason -Model $Model -Mode $Mode -Overall $Overall -Commit $script:RunStamp.commit -Dirty $script:RunStamp.dirty
}
# Structured Output: die API garantiert parsebares JSON mit genau diesen Feldern.
$VerdictSchema = [ordered]@{
    type                 = 'object'
    properties           = [ordered]@{
        verdict = [ordered]@{ type = 'string'; enum = @('PASS', 'FAIL', 'PARTIAL') }
        reason  = [ordered]@{ type = 'string' }
    }
    required             = @('verdict', 'reason')
    additionalProperties = $false
}

# Liefert @{ verdict; reason }, verdict in PASS|FAIL|PARTIAL|ERROR.
function Invoke-JudgeOnce([object]$Entry) {
    $userText = Format-JudgeUserText $Entry
    try {
        # max_tokens grosszuegig: die 5.5-Generation denkt immer mit, das Denken zaehlt zu max_tokens.
        $body = [ordered]@{
            model         = $Model
            max_tokens    = 16000
            system        = (Get-JudgeSystemText (Get-JudgeCardDecision $Entry))
            messages      = @(@{ role = 'user'; content = $userText })
            output_config = [ordered]@{ effort = 'low'; format = [ordered]@{ type = 'json_schema'; schema = $VerdictSchema } }
        } | ConvertTo-Json -Depth 12
        $resp = Invoke-JsonPostUtf8 -Uri $Endpoint -Body $body `
            -Headers @{ 'x-api-key' = $script:ApiKey; 'anthropic-version' = '2023-06-01' }
        if ($resp.usage) {
            [void]$script:JudgeUsage.Add([pscustomobject]@{ model = $Model; input_tokens = $resp.usage.input_tokens
                cache_creation_input_tokens = $resp.usage.cache_creation_input_tokens; cache_read_input_tokens = $resp.usage.cache_read_input_tokens
                output_tokens = $resp.usage.output_tokens; web_search_requests = 0; fallback = $false })
        }
        if ($resp.stop_reason -in @('max_tokens', 'refusal', 'pause_turn')) {
            return @{ verdict = 'ERROR'; reason = "Judge-Antwort unvollstaendig (stop_reason $($resp.stop_reason))" }
        }
        # Alle text-Bloecke ohne Trenner zusammenfuegen (wie anthropicText in Get-AnthropicResultJs).
        $raw = (@($resp.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ''
    } catch {
        # Nur die Statuszeile ausgeben, nie $_ roh (koennte Request-Header/-Body spiegeln).
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

# C2: ERROR ist Infra-Flake -> einmal retryen.
function Invoke-Judge([object]$Entry) {
    $r = Invoke-JudgeOnce $Entry
    if ($r.verdict -eq 'ERROR') {
        Start-Sleep -Milliseconds 800
        $r2 = Invoke-JudgeOnce $Entry
        if ($r2.verdict -ne 'ERROR') { return $r2 }
    }
    return $r
}

try {   # finally am Dateiende: Kostenbericht auch bei Ctrl-C oder Ausnahme
# A1: Kalibrierungs-Modus
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

    # Binaer: human/judge auf PASS vs. nicht-PASS (PARTIAL/FAIL = nicht-PASS) reduzieren, wie das OVERALL-Gate
    # (nur PASS zaehlt).
    $tp = 0; $tn = 0; $fp = 0; $fn = 0; $errc = 0
    $script:RunFile = Get-JudgeRunFile -RepoRoot $RepoRoot -Suite 'calibrate'
    foreach ($e in $labels) {
        if (Test-JudgeBudget) { $errc++; break }
        $human = "$($e.human_verdict)".ToUpper()
        if ($human -notin @('PASS','FAIL','PARTIAL')) { throw "Case '$($e.id)': human_verdict fehlt/ungueltig ('$human')." }
        $j = Invoke-JudgeGuarded $e
        Save-JudgeVerdict $e $j 'calibrate' ''
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

    $po = ($tp + $tn) / $n
    $pPassH = ($tp + $fn) / $n; $pPassJ = ($tp + $fp) / $n
    $pe = ($pPassH * $pPassJ) + ((1 - $pPassH) * (1 - $pPassJ))
    $kappa = if ((1 - $pe) -eq 0) { 1.0 } else { ($po - $pe) / (1 - $pe) }

    Write-Host ("Confusion (PASS vs. nicht-PASS):  TP={0}  TN={1}  FP={2}  FN={3}  (ERROR={4})" -f $tp,$tn,$fp,$fn,$errc)
    Write-Host ("Agreement (po): {0:P1}    Cohen's kappa: {1:N3}    Schwelle: {2:N2}" -f $po, $kappa, $KappaThreshold)
    if ($fp -gt 0) { Write-Host ("  WARNUNG: {0}x Judge zu NACHSICHTIG (FP) -- laesst echte Fehler durch." -f $fp) -ForegroundColor Yellow }
    $failedForce = Assert-ForceAbortFired $ForceAbortId
    if ($script:RunFile -and (Test-Path $script:RunFile)) { Write-Host "Urteile gespeichert: $script:RunFile" -ForegroundColor Cyan }
    Write-AbortedCases
    Write-JudgeCostReport 'judge_eval -Calibrate'
    if ($failedForce -gt 0) { exit 1 }
    if ($kappa -ge $KappaThreshold) {
        Write-Host "[KALIBRIERUNG OK] Judge ist ausreichend mit den Labels aligned." -ForegroundColor Green
        exit 0
    } else {
        Write-Host "[KALIBRIERUNG UNGENUEGEND] kappa < Schwelle -> Judge-Urteil ist nicht vertrauenswuerdig (Rubrics schaerfen / Judge-Modell wechseln)." -ForegroundColor Red
        exit 1
    }
}

# Normalbetrieb: Bundle bewerten.
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
$script:RunFile = Get-JudgeRunFile -RepoRoot $RepoRoot -Suite (Get-JudgeRunSuite $bundle)
foreach ($e in $bundle) {
    if (Test-JudgeBudget) { $errorCount++; break }
    Write-Host ""
    Write-Host "  [$($e.id)] $($e.name)"
    $detPass = [bool]$e.det_pass
    Write-Host "    det_pass (Routing+Args): $detPass   (erwartet tool=$($e.expected_tool), tatsaechlich=$($e.actual_tool))"

    $j = Invoke-JudgeGuarded $e
    $ov = if ($j.verdict -eq 'ERROR') { 'ERROR' } elseif ($detPass -and $j.verdict -eq 'PASS') { 'PASS' } else { 'FAIL' }
    Save-JudgeVerdict $e $j 'bundle' $ov
    Write-Host "    Judge: $($j.verdict)"
    if ($Verbose -or $j.verdict -ne 'PASS') { Write-Host "      reason: $($j.reason)" -ForegroundColor DarkGray }

    # C2: ERROR (auch nach Retry) ist kein inhaltliches FAIL -> separat ausweisen.
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

# Gate bleibt ehrlich: unjudged (ERROR) zaehlt in den Exit-Code (gruen nur, wenn alles wirklich PASS),
# wird im Summary aber von echten Rubric-FAILs getrennt.
if (Test-Path $script:RunFile) { Write-Host "Urteile gespeichert: $script:RunFile" -ForegroundColor Cyan }
Write-AbortedCases
$errorCount += Assert-ForceAbortFired $ForceAbortId
Write-JudgeCostReport 'judge_eval'
exit ($overallFail + $errorCount)
} finally {
    if (-not $script:CostReported) { Write-JudgeCostReport 'judge_eval (abgebrochen)' }
}
