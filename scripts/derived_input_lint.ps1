#Requires -Version 5.1
# derived_input_lint.ps1 -- Wächter für „Das LLM rechnet nicht“ (Root-CLAUDE.md *Arbeitsweise*, .claude/rules/sql.md
# *Keine ableitbaren Spalten*): kein Schreib-Werkzeug nimmt eine abgeleitete Größe als Modell-Eingang ($fromAI).
# Geprüft werden die GEBAUTEN Agent-Workflows packages/*/workflows/*.json (dort steht jedes gebundene Feld jedes Binders,
# auch Core-Dienste über Add-ServiceTools): jeder toolWorkflow-Knoten, dessen KI-Name ein Schreib-Verb der einen Verb-Map
# (scripts/build/lib/approval_matrix.ps1 $ApprovalVerbFloor) trägt, und dessen $fromAI-Felder:
#   (N) Feldname einer abgeleiteten Größe (Höchststand/Referenz, Alarm-Wert, Saldo, Durchschnittskurs, Monatswert,
#       Restschuld, Euro-Umrechnung, Alter) -> rot;
#   (D) Beschreibung beauftragt das Modell zu rechnen (calculate/compute/sum of/convert to/monthly equivalent/
#       negative if ...), ohne Verneinung oder Verweis auf die Datenbank im selben Satzteil -> rot.
# Ausnahmen: scripts/build/derived_input_allowlist.json [{tool, field, rule, reason}] -- nur mit Begründung, warum der
# Wert ein Roh-Wert ist (z. B. Zahl laut Vertrag); ein Eintrag ohne Treffer ist rot (Liste schrumpft nur).
# Aufruf: .\scripts\derived_input_lint.ps1 [-Root <Baum>]   (-Root für scripts/dev/derived_input_lint_test.ps1)
# Exit-Code = Anzahl Fehler. Kein Docker, kein Netz.
param([string]$Root)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
if (-not $Root) { $Root = $repo }
$Root = (Resolve-Path $Root).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $repo 'scripts\build\lib\approval_matrix.ps1')
$writeVerbs = @($ApprovalVerbFloor.Keys)

$nameRules = @(
    @{ re = '^(reference_value|reference|peak|peak_(value|price|as_of)|running_peak|high_water.*)$'; why = 'Höchststand/Referenz: berechnet die DB aus der Reihe (agent.fn_monitor_drawdown_reference)' }
    @{ re = '^(alarm_value|alert_value|trigger_level)$';                       why = 'Alarm-Wert: folgt aus Referenz und Prozent' }
    @{ re = '^(balance|.*_balance_after|average_purchase_price|avg_price)$';   why = 'Ledger-Aggregat: pflegt ein Trigger' }
    @{ re = '^(monthly_equivalent|.*_per_month_equivalent|annualized_.*)$';    why = 'Monats-/Jahres-Normalisierung: fn_monthly_equivalent' }
    @{ re = '^(remaining_debt|outstanding_.*|interest_share|principal_share)$'; why = 'Restschuld/Zins-Tilgungs-Anteil: fn_loan_*' }
    @{ re = '^(.*_eur|eur_.*|.*_in_eur)$';                                     why = 'Euro-Umrechnung: fn_to_eur / fn_fx_rate' }
    @{ re = '^(age|.*_age|years_since_.*|years_to_.*)$';                       why = 'Alter/Jahresabstand: aus Datum + heute' }
)
$computeRe = '(?i)\b(calculate[ds]?|calculating|compute[ds]?\s+(with|from|as|by\s+you)|computing|sum\s+of|add\s+up|convert(ed)?\s+(it\s+)?(to|into)|monthly\s+equivalent|negative\s+(if|for|when))\b'
$guardRe   = '(?i)\b(never|do\s+not|don.t|not\s+yourself|the\s+database|the\s+tool\s+(derives|computes)|db\s+derives)\b'

$allowPath = Join-Path $Root 'scripts\build\derived_input_allowlist.json'
$allow = @()
if (Test-Path $allowPath) {
    # PS 5.1: ConvertFrom-Json gibt ein JSON-Array als EIN Objekt in die Pipeline; erst zuweisen, dann aufzaehlen.
    $parsed = [System.IO.File]::ReadAllText($allowPath, $u8) | ConvertFrom-Json
    $allow = @($parsed | ForEach-Object { $_ })
}
$used = @{}
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }
foreach ($a in $allow) {
    if ([string]::IsNullOrWhiteSpace([string]$a.reason) -or -not $a.tool -or -not $a.field -or $a.rule -notin @('N', 'D')) {
        Fail "Allowlist-Eintrag unvollständig (tool, field, rule N|D, reason): $($a | ConvertTo-Json -Compress)"
    }
}
function Test-Allowed([string]$tool, [string]$field, [string]$rule) {
    foreach ($a in $allow) {
        if ($a.tool -eq $tool -and $a.field -eq $field -and $a.rule -eq $rule) { $script:used["$tool|$field|$rule"] = $true; return $true }
    }
    return $false
}

$fromAiRe = [regex]"\`$fromAI\('([A-Za-z0-9_]+)'\s*,\s*'([^']*)'"
$checked = 0
foreach ($f in (Get-ChildItem (Join-Path $Root 'packages\*\workflows\*.json') -File | Sort-Object FullName)) {
    $wf = [System.IO.File]::ReadAllText($f.FullName, $u8) | ConvertFrom-Json
    if (-not $wf.nodes) { continue }
    foreach ($n in $wf.nodes) {
        if ($n.type -ne '@n8n/n8n-nodes-langchain.toolWorkflow') { continue }
        $tool = [string]$n.parameters.name
        if ($tool -notmatch '^tool_([a-z]+)_') { continue }
        if ($writeVerbs -notcontains $Matches[1]) { continue }
        $params = $n.parameters | ConvertTo-Json -Depth 20 -Compress
        $params = [regex]::Unescape($params)
        foreach ($m in $fromAiRe.Matches($params)) {
            $field = $m.Groups[1].Value; $desc = $m.Groups[2].Value; $checked++
            foreach ($r in $nameRules) {
                if ($field -match $r.re -and -not (Test-Allowed $tool $field 'N')) {
                    Fail "$($f.Name) :: $tool.$field (N) -- $($r.why). Feld streichen, die fn rechnet; Roh-Wert -> Allowlist mit Grund."
                }
            }
            # Die Verneinung zaehlt nur im selben Satzteil wie das Rechen-Wort ("calculate it ...; never negative" bleibt rot).
            $hit = @($desc -split '[.;:!?]|\s-\s' | Where-Object { $_ -match $computeRe -and $_ -notmatch $guardRe } | Select-Object -First 1)
            if ($hit.Count -gt 0 -and -not (Test-Allowed $tool $field 'D')) {
                $null = $hit[0] -match $computeRe
                Fail "$($f.Name) :: $tool.$field (D) -- Beschreibung lässt das Modell rechnen ('$($Matches[0])'). Roh-Wert verlangen, die fn rechnet."
            }
        }
    }
}
foreach ($a in $allow) {
    if (-not $used.ContainsKey("$($a.tool)|$($a.field)|$($a.rule)")) {
        Fail "Allowlist-Eintrag ohne Treffer (entfernen): $($a.tool).$($a.field) ($($a.rule))"
    }
}
if ($fails -eq 0) { Write-Host "derived_input_lint: OK ($checked Modell-Felder in Schreib-Werkzeugen geprüft, $($allow.Count) begründete Ausnahme(n))" }
exit $fails
