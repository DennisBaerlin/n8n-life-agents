#Requires -Version 5.1
# Selbsttest der Abbruch-Absicherung der bezahlten Suiten (scripts/lib/paid_guard.ps1). Kein Substrat, keine Kosten, keine Suite wird gestartet.
#  1. Kostenrechnung und Grenze (Get-UsageCostUsd, Test-CostLimitExceeded, Test-RunCostExceeded) gegen erfundene usage-Zeilen.
#  2. Invoke-PaidRunCleanup: stoppt wartende und laufende Executions je Workflow, loest die Karten-Sperre, schluckt Fehler.
#  3. Statisch: jede scripts/*_test.ps1 mit echtem Gateway (-Expect real) parst fehlerfrei und traegt die Absicherung (Parameter -MaxCostUsd und
#     -ForceAbortId, Kostenpruefung, finally-Aufraeumen, Abbruch-Fall-Helfer). Eine neue bezahlte Suite ohne sie macht diesen Test rot.
#  4. Bewerter-Urteile (lib/judge_record.ps1): Schreibweg mit Attrappe in einem Temp-Ordner (Zeilenformat, Dateiname, Kalibrier-Zeile, Schreibfehler),
#     Ablageort im Haupt-Checkout, Verdrahtung in judge_eval und den drei Bundle-Schreibern (Suite).
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
# Bezahlt = echtes Gateway (-Expect real) oder direkter Anthropic-Aufruf (judge_eval); alle scripts/*.ps1, nicht nur *_test.
$paid = @(Get-ChildItem (Join-Path $repo 'scripts') -Filter '*.ps1' | Where-Object {
    [System.IO.File]::ReadAllText($_.FullName, $Utf8NoBom) -match 'Assert-LlmGatewayUpstream[^\r\n]*-Expect real|api\.anthropic\.com/v1/messages' })
$expected = @('conversation_test.ps1', 'e2e_test.ps1', 'multiturn_test.ps1', 'n8n_test.ps1', 'orch_test.ps1', 'monitor_probe.ps1', 'judge_eval.ps1')
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
        'Abbruch-Fall markiert (Test-ForceAbort)'       = 'Test-ForceAbort'
        'Abbruch-Pruefung am Ende (Assert-ForceAbortFired)' = 'Assert-ForceAbortFired'
    }
    foreach ($k in $needs.Keys) { Assert-That ($text -match $needs[$k]) "$($f.Name): $k" }
    # finally per AST: der Block selbst muss das Aufraeumen enthalten (ein spaeterer Aufruf ausserhalb zaehlt nicht). Ohne Container
    # (judge_eval spricht nur die API an) gibt es nichts aufzuraeumen: dort genuegt ein finally (Kostenbericht beim Abbruch).
    $finals = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Finally }, $true))
    if ($text -match 'Get-TestN8nConnection') { Assert-That (@($finals | Where-Object { $_.Finally.Extent.Text -match 'Invoke-PaidRunCleanup' }).Count -gt 0) "$($f.Name): Aufraeumen im finally-Block" }
    else { Assert-That ($finals.Count -gt 0) "$($f.Name): finally-Block (Kostenbericht beim Abbruch)" }
}

# --- 4. Urteile des Bewerters bleiben erhalten (lib/judge_record.ps1) --------------------------------------------
Write-Host "Bewerter-Urteile"
. (Join-Path $PSScriptRoot '..\lib\judge_record.ps1')
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("judge_record_test_" + [guid]::NewGuid().ToString('N'))
try {
    $file = Get-JudgeRunFile -RepoRoot $repo -Suite 'n8n_test:demo cases' -Now ([datetime]'2026-11-15T10:20:30') -LocalRoot $tmpRoot
    Assert-That ($file -eq (Join-Path $tmpRoot '.local\judge_runs\20261115-102030-n8n_test-demo-cases.jsonl')) 'Dateiname: Zeit und Suite, Sonderzeichen ersetzt, unter .local/judge_runs'
    $e1 = [pscustomobject]@{ id = 'tc01'; suite = 'n8n_test-demo_cases'; det_pass = $true }
    $e2 = [pscustomobject]@{ id = 'tc02'; suite = 'n8n_test-demo_cases'; det_pass = $false }
    Add-JudgeRunRecord -Path $file -Entry $e1 -Verdict 'PASS' -Reason 'nennt den Saldo, "mit Anfuehrung" und Umlaut ae' -Model 'm-test' -Overall 'PASS' -Commit 'abc1234' -Dirty $false
    Add-JudgeRunRecord -Path $file -Entry $e2 -Verdict 'ERROR' -Reason '' -Model 'm-test' -Overall 'ERROR' -Commit 'abc1234' -Dirty $true
    $lines = @([System.IO.File]::ReadAllLines($file, $Utf8NoBom))
    Assert-That ($lines.Count -eq 2) 'eine Zeile je Fall, angehaengt'
    $r1 = $lines[0] | ConvertFrom-Json; $r2 = $lines[1] | ConvertFrom-Json
    Assert-That ($r1.case_id -eq 'tc01' -and $r1.suite -eq 'n8n_test-demo_cases' -and $r1.verdict -eq 'PASS' -and $r1.overall -eq 'PASS' -and $r1.det_pass -eq $true) 'Zeile 1: Fall-ID, Suite, Urteil, Gesamturteil, det_pass'
    Assert-That ($r1.reason -eq 'nennt den Saldo, "mit Anfuehrung" und Umlaut ae' -and $r1.model -eq 'm-test' -and $r1.commit -eq 'abc1234' -and $r1.dirty -eq $false) 'Zeile 1: Begruendung unveraendert (auch mit Anfuehrungszeichen), Modell, Commit'
    Assert-That ($r2.verdict -eq 'ERROR' -and $r2.det_pass -eq $false -and $r2.dirty -eq $true) 'Zeile 2: auch ein Judge-ERROR wird festgehalten'
    Assert-That ($null -ne ($r1.ts -as [datetime])) 'Zeitstempel lesbar'
    $fileC = Get-JudgeRunFile -RepoRoot $repo -Suite 'calibrate' -LocalRoot $tmpRoot
    Add-JudgeRunRecord -Path $fileC -Entry ([pscustomobject]@{ id = 'jl1'; human_verdict = 'FAIL' }) -Verdict 'PASS' -Reason 'x' -Model 'm-test' -Mode 'calibrate'
    $rc = ([System.IO.File]::ReadAllLines($fileC, $Utf8NoBom) | Select-Object -First 1) | ConvertFrom-Json
    Assert-That ($rc.mode -eq 'calibrate' -and $rc.human_verdict -eq 'FAIL' -and $null -eq $rc.PSObject.Properties['det_pass']) 'Kalibrierung: human_verdict statt det_pass'
    # Schreibfehler stoert den Lauf nicht: ein Ordner an der Stelle der Datei.
    $blocked = Join-Path $tmpRoot 'blocked.jsonl'; New-Item -ItemType Directory -Path $blocked -Force | Out-Null
    $threw = $false; try { Add-JudgeRunRecord -Path $blocked -Entry $e1 -Verdict 'PASS' -Reason 'x' -Model 'm' 3>$null } catch { $threw = $true }
    Assert-That (-not $threw) 'Schreibfehler wirft nicht (nur Warnung)'
    Assert-That ((Get-JudgeRunSuite @($e1, $e2)) -eq 'n8n_test-demo_cases' -and (Get-JudgeRunSuite @($e1, [pscustomobject]@{ id = 'x'; suite = 'orch_test' })) -eq 'gemischt' -and (Get-JudgeRunSuite @([pscustomobject]@{ id = 'x' })) -eq 'unbekannt') 'Suite des Laufs: gemeinsame, gemischt, unbekannt'
} finally { Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue }
Assert-That ((Resolve-MainCheckoutRoot -RepoRoot 'C:\repo\wt' -CommonDir 'C:/repo/.git') -eq 'C:\repo') 'Worktree: Ort ist der Haupt-Checkout (absolutes git-common-dir)'
Assert-That ((Resolve-MainCheckoutRoot -RepoRoot 'C:\repo' -CommonDir '.git') -eq 'C:\repo') 'Haupt-Checkout: relatives .git bleibt im Repo'
Assert-That ((Resolve-MainCheckoutRoot -RepoRoot 'C:\repo' -CommonDir '') -eq 'C:\repo') 'ohne git-common-dir: Repo-Root'
Assert-That ((Resolve-MainCheckoutRoot -RepoRoot 'C:\repo' -CommonDir 'C:/bare/repo.git') -eq 'C:\repo') 'ohne .git-Ordner (bare): Repo-Root'
$realFile = Get-JudgeRunFile -RepoRoot $repo -Suite 'x'
Assert-That ($realFile -match '\\\.local\\judge_runs\\' -and (Test-Path (Split-Path (Split-Path (Split-Path $realFile -Parent) -Parent) -Parent))) 'echtes Repo: Ablageort liegt unter einem vorhandenen Checkout'
$tmpB = Join-Path ([System.IO.Path]::GetTempPath()) ("judge_bundle_test_" + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $tmpB 'tests\agent') -Force | Out-Null
    Write-JudgeBundle -Entries @([ordered]@{ id = 'a1' }, [ordered]@{ id = 'a2'; suite = 'eigene' }) -RepoRoot $tmpB -Suite 'orch_test' 6>$null
    $bd = [System.IO.File]::ReadAllText((Join-Path $tmpB 'tests\agent\judge_bundle.json'), $Utf8NoBom) | ConvertFrom-Json
    Assert-That ($bd[0].suite -eq 'orch_test' -and $bd[1].suite -eq 'eigene') 'Write-JudgeBundle stempelt die Suite, eine vorhandene bleibt'
} finally { Remove-Item -Recurse -Force $tmpB -ErrorAction SilentlyContinue }
# Verdrahtung: judge_eval speichert je Urteil, die Bundle-Schreiber stempeln die Suite.
$je = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\judge_eval.ps1'), $Utf8NoBom)
Assert-That ($je -match 'lib\\judge_record\.ps1' -and ([regex]::Matches($je, 'Save-JudgeVerdict \$e \$j')).Count -eq 2) 'judge_eval speichert in beiden Modi (Bundle und Kalibrierung) jedes Urteil'
foreach ($s in 'n8n_test', 'orch_test', 'conversation_test') {
    $st = [System.IO.File]::ReadAllText((Join-Path $repo "scripts\$s.ps1"), $Utf8NoBom)
    Assert-That ($st -match 'Write-JudgeBundle [^\r\n]*-Suite ') "${s}: Write-JudgeBundle stempelt die Suite"
}

Write-Host ""
if ($failed -eq 0) { Write-Host "paid_guard_test: alles gruen." -ForegroundColor Green } else { Write-Host "paid_guard_test: $failed Fehler." -ForegroundColor Red }
exit $failed
