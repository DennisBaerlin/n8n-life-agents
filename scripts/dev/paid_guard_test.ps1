#Requires -Version 5.1
# Selbsttest der Abbruch-Absicherung der bezahlten Suiten (scripts/lib/paid_guard.ps1). Kein Substrat, keine Kosten, keine Suite wird gestartet.
#  1. Kostenrechnung und Grenze (Get-UsageCostUsd, Test-CostLimitExceeded, Test-RunCostExceeded) gegen erfundene usage-Zeilen.
#  2. Invoke-PaidRunCleanup: stoppt wartende und laufende Executions je Workflow, loest die Karten-Sperre, schluckt Fehler.
#  3. Statisch: jede scripts/*_test.ps1 mit echtem Gateway (-Expect real) parst fehlerfrei und traegt die Absicherung (Parameter -MaxCostUsd und
#     -ForceAbortId, Kostenpruefung, finally-Aufraeumen, Abbruch-Fall-Helfer). Eine neue bezahlte Suite ohne sie macht diesen Test rot.
# Usage:  .\scripts\dev\paid_guard_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $PSScriptRoot 'test_n8n_state.ps1')
. (Join-Path $PSScriptRoot '..\lib\paid_guard.ps1')

$failed = 0
function Assert-That([bool]$Cond, [string]$Name) {
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failed++ }
}

# --- 1. Kosten ---------------------------------------------------------------------------------------------------
Write-Host "Kosten und Grenze"
$prices = @{ 'm-test' = [pscustomobject]@{ input = 3.0; output = 15.0; cache_write_5m = 3.75; cache_write_1h = 6.0; cache_read = 0.3; web_search_usd_per_request = 0.01 } }
# 1 Mio Eingabe zu 3 USD + 1 Mio Ausgabe zu 15 USD = 18 USD
$row = [pscustomobject]@{ model = 'm-test'; input_tokens = 1000000; cache_creation_input_tokens = 0; cache_read_input_tokens = 0; output_tokens = 1000000; ephemeral_1h_input_tokens = 0; web_search_requests = 0 }
$unknown = [pscustomobject]@{ model = 'm-unbekannt'; input_tokens = 1000000; cache_creation_input_tokens = 0; cache_read_input_tokens = 0; output_tokens = 0; ephemeral_1h_input_tokens = 0; web_search_requests = 0 }
Assert-That ((Get-UsageCostUsd -Usage @($row) -Prices $prices) -eq 18.0) 'eine Zeile = 18 USD'
Assert-That ((Get-UsageCostUsd -Usage @($row, $row) -Prices $prices) -eq 36.0) 'zwei Zeilen summieren sich'
Assert-That ((Get-UsageCostUsd -Usage @($unknown) -Prices $prices) -eq 0.0) 'Modell ohne Preis zaehlt 0'
Assert-That ((Get-UsageCostUsd -Usage @() -Prices $prices) -eq 0.0) 'keine Zeilen = 0'
Assert-That (Test-CostLimitExceeded -CostUsd 10.5 -MaxCostUsd 10) 'ueber der Grenze'
Assert-That (-not (Test-CostLimitExceeded -CostUsd 10 -MaxCostUsd 10)) 'genau auf der Grenze ist noch erlaubt'
Assert-That (-not (Test-CostLimitExceeded -CostUsd 999 -MaxCostUsd 0)) 'Grenze 0 schaltet die Pruefung ab'

# Journal-Zugriff ersetzen (Get-LlmUsage liest sonst per docker exec).
function Get-LlmUsage { param([string]$Container, [string]$AfterCursor) $script:UsageRows }
$script:UsageRows = @($row, $row)
Assert-That (Test-RunCostExceeded -Container 'x' -Cursor 'c' -Prices $prices -MaxCostUsd 10 6>$null) 'Lauf ueber der Grenze wird gemeldet'
Assert-That (-not (Test-RunCostExceeded -Container 'x' -Cursor 'c' -Prices $prices -MaxCostUsd 100 6>$null)) 'Lauf unter der Grenze laeuft weiter'
function Get-LlmUsage { param([string]$Container, [string]$AfterCursor) throw 'Journal nicht lesbar' }
Assert-That (-not (Test-RunCostExceeded -Container 'x' -Cursor 'c' -Prices $prices -MaxCostUsd 10 6>$null)) 'Lesefehler des Journals bricht den Lauf nicht ab'

# --- 2. Aufraeumen -----------------------------------------------------------------------------------------------
Write-Host "Aufraeumen"
$script:Gets = @(); $script:Stops = @(); $script:HitlCleared = 0; $script:GetThrows = $false
function Invoke-N8nGet([string]$Path) { $script:Gets += $Path; if ($script:GetThrows) { throw 'n8n nicht erreichbar' }; [pscustomobject]@{ data = @([pscustomobject]@{ id = '7' }) } }
function Stop-Exec([string]$ExecId) { $script:Stops += $ExecId }
function Clear-HitlPending { param([string]$Container) $script:HitlCleared++ }
Invoke-PaidRunCleanup -Container 'x' -WorkflowId @('wfA', 'wfB', '', $null)
Assert-That ($script:Gets.Count -eq 4) 'je Workflow wartende und laufende Executions abgefragt (leere ids uebersprungen)'
Assert-That (@($script:Gets | Where-Object { $_ -like '*workflowId=wfA&status=waiting*' }).Count -eq 1 -and @($script:Gets | Where-Object { $_ -like '*workflowId=wfB&status=running*' }).Count -eq 1) 'Abfrage nennt Workflow und Status'
Assert-That ($script:Stops.Count -eq 4) 'jede gefundene Execution gestoppt'
Assert-That ($script:HitlCleared -eq 1) 'Karten-Sperre geloest'
$script:Gets = @(); $script:Stops = @(); $script:HitlCleared = 0; $script:GetThrows = $true
$threw = $false
try { Invoke-PaidRunCleanup -Container 'x' -WorkflowId @('wfA') } catch { $threw = $true }
Assert-That (-not $threw) 'Fehler beim Aufraeumen wirft nicht (laeuft im finally)'
Assert-That ($script:HitlCleared -eq 1) 'Karten-Sperre auch nach einem Fehler geloest'

# --- 3. Statisch: jede bezahlte Suite traegt die Absicherung -----------------------------------------------------
Write-Host "Bezahlte Suiten"
$paid = @(Get-ChildItem (Join-Path $repo 'scripts') -Filter '*_test.ps1' | Where-Object {
    [System.IO.File]::ReadAllText($_.FullName, $Utf8NoBom) -match 'Assert-LlmGatewayUpstream[^\r\n]*-Expect real' })
$expected = @('conversation_test.ps1', 'e2e_test.ps1', 'multiturn_test.ps1', 'n8n_test.ps1', 'orch_test.ps1')
foreach ($e in $expected) { Assert-That ($paid.Name -contains $e) "$e wird als bezahlte Suite erkannt" }
foreach ($f in $paid) {
    $text = [System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom)
    $errs = $null; $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errs)
    Assert-That (@($errs).Count -eq 0) "$($f.Name): parst fehlerfrei"
    $params = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    foreach ($p in 'MaxCostUsd', 'ForceAbortId') { Assert-That ($params -contains $p) "$($f.Name): Parameter -$p" }
    $needs = [ordered]@{
        'Kosten-Helfer geladen (lib/paid_guard.ps1)'    = 'lib\\paid_guard\.ps1'
        'Kostengrenze geprueft'                         = 'Test-RunCostExceeded|Test-CostLimitExceeded'
        'Aufraeumen im finally'                         = 'finally\s*\{[\s\S]*Invoke-PaidRunCleanup'
        'Abbruch-Fall markiert (Test-ForceAbort)'       = 'Test-ForceAbort'
        'Abbruch-Pruefung am Ende (Assert-ForceAbortFired)' = 'Assert-ForceAbortFired'
    }
    foreach ($k in $needs.Keys) { Assert-That ($text -match $needs[$k]) "$($f.Name): $k" }
}

Write-Host ""
if ($failed -eq 0) { Write-Host "paid_guard_test: alles gruen." -ForegroundColor Green } else { Write-Host "paid_guard_test: $failed Fehler." -ForegroundColor Red }
exit $failed
