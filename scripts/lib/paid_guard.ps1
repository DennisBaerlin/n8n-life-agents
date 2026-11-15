#Requires -Version 5.1
# Gemeinsame Abbruch-Absicherung der bezahlten Suiten (n8n_test, orch_test, e2e_test, multiturn_test, conversation_test):
# Kostengrenze je Lauf + sauberes Ende (laufende/wartende Executions stoppen, Karten-Sperre loesen, Kostenbericht auch beim Abbruch).
# Dot-sourcen NACH scripts/dev/test_n8n_state.ps1 (nutzt Get-LlmUsage, Get-LlmRequestCost, Stop-Exec, Invoke-N8nGet, Clear-HitlPending).
# Vertrag je Suite: Parameter -MaxCostUsd; vor jedem Fall/jeder Runde Test-RunCostExceeded; Fallschleife in try { } finally { Invoke-PaidRunCleanup };
# Kostenbericht im finally, falls der Lauf nicht regulaer endete. paid_guard_test.ps1 prueft statisch, dass keine Suite das verliert.

# Get-UsageCostUsd -> Summe der usage-Zeilen in USD (Modelle ohne Preis zaehlen 0; $Prices aus Get-LlmPriceTable).
function Get-UsageCostUsd {
    param([AllowEmptyCollection()][object[]]$Usage = @(), [Parameter(Mandatory)][hashtable]$Prices)
    $sum = 0.0
    foreach ($row in @($Usage | Where-Object { $_ })) {
        $c = Get-LlmRequestCost -Row $row -Prices $Prices
        if ($c) { $sum += $c.Cost }
    }
    return $sum
}

# Test-CostLimitExceeded -> $true, wenn $CostUsd die Grenze ueberschreitet (Grenze <= 0 schaltet die Pruefung ab).
function Test-CostLimitExceeded {
    param([Parameter(Mandatory)][double]$CostUsd, [Parameter(Mandatory)][double]$MaxCostUsd)
    return ($MaxCostUsd -gt 0 -and $CostUsd -gt $MaxCostUsd)
}

# Test-RunCostExceeded -> $true (und FAIL-Zeile), sobald die Kosten seit $Cursor die Grenze ueberschreiten. Aufrufer zaehlt
# den Fehler und bricht die Schleife ab. Ein Lesefehler des Journals gilt als "noch unter der Grenze" (Warnung, kein Abbruch):
# die Absicherung darf einen Lauf nicht an einem Messfehler scheitern lassen.
function Test-RunCostExceeded {
    param([Parameter(Mandatory)][string]$Container, [string]$Cursor, [Parameter(Mandatory)][hashtable]$Prices, [Parameter(Mandatory)][double]$MaxCostUsd)
    try { $cost = Get-UsageCostUsd -Usage (Get-LlmUsage -Container $Container -AfterCursor $Cursor) -Prices $Prices }
    catch { Write-Host "    [WARN] Kosten nicht lesbar ($($_.Exception.Message)) - Grenze nicht geprueft." -ForegroundColor Yellow; return $false }
    if (-not (Test-CostLimitExceeded -CostUsd $cost -MaxCostUsd $MaxCostUsd)) { return $false }
    Write-Host "    [FAIL] Kostengrenze $MaxCostUsd USD ueberschritten ($([Math]::Round($cost, 3)) USD) - Lauf angehalten." -ForegroundColor Red
    return $true
}

# Invoke-PaidRunCleanup -> stoppt wartende/laufende Executions der genannten Workflows und loest die Karten-Sperre.
# Best-Effort (laeuft im finally, auch nach Ctrl-C): jeder Schritt schluckt seinen Fehler, damit der naechste noch laeuft.
function Invoke-PaidRunCleanup {
    param([Parameter(Mandatory)][string]$Container, [string[]]$WorkflowId = @())
    foreach ($wf in @($WorkflowId | Where-Object { $_ })) {
        foreach ($st in 'waiting', 'running') {
            try { (Invoke-N8nGet "executions?workflowId=$wf&status=$st&limit=20").data | ForEach-Object { Stop-Exec $_.id } } catch { }
        }
    }
    try { Clear-HitlPending -Container $Container } catch { }
}
