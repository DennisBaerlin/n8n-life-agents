#Requires -Version 5.1
# =====================================================================================================
# run_free_gates.ps1 — ALLE kostenlosen Gates auf dem laufenden (oder frisch gebauten) Substrat in EINEM Lauf
#
# Anlass (2026-10-23, Schluss-Gates des gemeinsamen Release): die Leitung setzte die Reihe von Hand zusammen und
# verlor Zeit an drei Fallen — fehlende Mock-Vorbedingung (infra_test braucht mock_paperless), ein aus Bash
# uebergebenes -WriteTools kam als EIN String an, und eine psql-NOTICE brach unter *>-Umleitung ab. Dieses Skript
# ist die EINE Adresse fuer "freie Gates auf dem Gesamtstand" (/coordinate): richtige Reihenfolge, alle Mocks,
# jede Suite einzeln geloggt, Zusammenfassung am Ende. Bezahlte Suiten laufen hier NIE (Owner-Fenster).
#
# Usage (eigene Container, Pflicht — nie die geteilten Defaults):
#   $env:N8NTEST_CONTAINER='n8ntest-xx'; $env:N8NTEST_PORT='57xx'; $env:DBTEST_CONTAINER='dbtest-xx'; $env:DBTEST_PG_PORT='554xx'
#   .\scripts\dev\run_free_gates.ps1              # gegen das laufende Substrat
#   .\scripts\dev\run_free_gates.ps1 -Reset       # Substrat vorher frisch (Basis-Image)
#   .\scripts\dev\run_free_gates.ps1 -Reset -Cold # vorher kalt (Install-Kern geaendert, vor einem Release)
# Exit-Code = Anzahl roter Suiten (0 = alles gruen). Logs: $env:TEMP\free_gate_<N8NTEST_CONTAINER>_<suite>.log
# (je Container benannt: den TEMP-Ordner teilen alle Sessions desselben Windows-Nutzers).
# =====================================================================================================
param(
    [switch]$Reset,
    [switch]$Cold
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
Set-Location $RepoRoot

# Eigene Container sind Pflicht (Root-CLAUDE.md *Scripts*): ohne die vier Variablen liefe alles gegen die geteilten
# Defaults und risse fremde Substrate ab.
$missing = @('N8NTEST_CONTAINER', 'N8NTEST_PORT', 'DBTEST_CONTAINER', 'DBTEST_PG_PORT') |
    Where-Object { [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_)) }
if ($missing) { throw "Eigene Test-Container setzen, fehlt: $($missing -join ', ') (siehe Usage im Skript-Kopf)." }

# Sperre gegen parallele Laeufe auf DENSELBEN Containern (2026-10-23: ein git push lief waehrend dieses Skripts;
# Pre-Push-db_test und infra-softcheck kollidierten mit den Suiten). db_test.ps1 prueft dieselbe Datei.
$lock = Join-Path $RepoRoot '.local\run_free_gates.lock'
if (Test-Path $lock) {
    $held = Get-Content $lock -Raw | ConvertFrom-Json
    if (Get-Process -Id $held.pid -ErrorAction SilentlyContinue) {
        throw "run_free_gates laeuft bereits (PID $($held.pid), Container $($held.n8n)/$($held.db)) -- abwarten statt parallel starten."
    }
}
New-Item -ItemType Directory -Force (Split-Path $lock) | Out-Null
@{ pid = $PID; n8n = $env:N8NTEST_CONTAINER; db = $env:DBTEST_CONTAINER } | ConvertTo-Json -Compress |
    Set-Content -Path $lock -Encoding UTF8

$results = New-Object System.Collections.Generic.List[object]
function Invoke-Gate {
    param([string]$Name, [string]$Script, [hashtable]$Params = @{})
    $log = Join-Path $env:TEMP "free_gate_$($env:N8NTEST_CONTAINER)_$Name.log"
    Write-Host ("==> {0,-12} {1}" -f $Name, $Script) -ForegroundColor Cyan
    $start = Get-Date
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # native stderr der Suiten nicht als Abbruch werten
    try { & (Join-Path $RepoRoot $Script) @Params *> $log; $code = $LASTEXITCODE }
    catch { $_ | Out-File -FilePath $log -Append -Encoding utf8; $code = 99 }
    finally { $ErrorActionPreference = $prevEAP }
    if ($null -eq $code) { $code = 0 }
    $summary = (Select-String -Path $log -Pattern 'bestanden|FAIL' -ErrorAction SilentlyContinue | Select-Object -Last 1).Line
    $results.Add([pscustomobject]@{ Suite = $Name; Ok = ($code -eq 0); Exit = $code; Minuten = [math]::Round(((Get-Date) - $start).TotalMinutes, 1); Ergebnis = "$summary".Trim() })
    $color = if ($code -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("    exit={0}  {1}" -f $code, "$summary".Trim()) -ForegroundColor $color
}

if ($Reset) {
    $boot = @{ Reset = $true }; if ($Cold) { $boot['Cold'] = $true }
    Invoke-Gate 'substrat' 'scripts\dev\bootstrap_test_n8n.ps1' $boot
    if (-not $results[-1].Ok) { Write-Host "Substrat-Aufbau rot -> Abbruch (Log: $env:TEMP\free_gate_$($env:N8NTEST_CONTAINER)_substrat.log)" -ForegroundColor Red; exit 1 }
}

Invoke-Gate 'db' 'scripts\db_test.ps1'
# Release-Download (install.sh + lifeagents update) gegen Mock-GitHub — braucht nur den Container, keine Mocks.
Invoke-Gate 'release_fetch' 'scripts\dev\release_fetch_test.ps1'

# Alle Mocks VOR den Substrat-Suiten (infra_test-Faelle verlangen mock_paperless/mock_llm/mock_telegram im State;
# ein Substrat-Redeploy setzt sie zurueck -> hier immer neu einschalten).
foreach ($m in 'enable_mock_llm', 'enable_mock_telegram', 'enable_mock_paperless') {
    Invoke-Gate ($m -replace '^enable_', '') "scripts\dev\$m.ps1"
}

Invoke-Gate 'infra' 'scripts\infra_test.ps1'
Invoke-Gate 'hitl_gate' 'scripts\dev\hitl_gate_test.ps1'
Invoke-Gate 'cron_text' 'scripts\dev\cron_text_test.ps1'
Invoke-Gate 'bot_menu' 'scripts\dev\bot_menu_test.ps1'
# Update im Chat (Release-Karte, Runner, Fehler-Hilfe, Signatur) gegen Mock-GitHub + Mock-Telegram.
Invoke-Gate 'update_chat' 'scripts\dev\update_chat_test.ps1'
Invoke-Gate 'llm_gateway' 'scripts\dev\llm_gateway_test.ps1'

# Mock-Routing je Agent-Ziel (Default-Erkennung tool_* deckt alle Write-Tools; -WriteTools wuerde nur verengen).
$routes = @(
    @{ Name = 'mr_orch' }
    @{ Name = 'mr_finance';   TargetWorkflow = 'agent.finance';             WebhookPath = 'finance-test';   CasesFile = 'tests\agent\finance\finance_cases.json' }
    @{ Name = 'mr_advisor';   TargetWorkflow = 'agent.finance_advisor';     WebhookPath = 'advisor-test';   CasesFile = 'tests\agent\finance\advisor_cases.json' }
    @{ Name = 'mr_guide';     TargetWorkflow = 'agent.guide';               WebhookPath = 'guide-test';     CasesFile = 'tests\agent\core\guide_cases.json' }
    @{ Name = 'mr_monitor';   TargetWorkflow = 'agent.monitor';             WebhookPath = 'monitor-test';   CasesFile = 'tests\agent\core\monitor_cases.json' }
    @{ Name = 'mr_career';    TargetWorkflow = 'agent.career_advisor';      WebhookPath = 'career-test';    CasesFile = 'tests\agent\career\career_cases.json' }
    @{ Name = 'mr_estate';    TargetWorkflow = 'agent.estate_advisor';      WebhookPath = 'estate-test';    CasesFile = 'tests\agent\estate\estate_cases.json' }
    @{ Name = 'mr_paperless'; TargetWorkflow = 'agent.paperless_assistant'; WebhookPath = 'paperless-test'; CasesFile = 'tests\agent\paperless\paperless_cases.json'; AgentNode = 'Document Agent' }
)
foreach ($r in $routes) {
    $p = @{}; foreach ($k in $r.Keys) { if ($k -ne 'Name') { $p[$k] = $r[$k] } }
    Invoke-Gate $r.Name 'scripts\dev\mock_route_test.ps1' $p
}

Invoke-Gate 'real_ingress' 'scripts\dev\real_ingress_test.ps1'

Remove-Item $lock -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "================ Freie Gates ================"
$results | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
$red = @($results | Where-Object { -not $_.Ok }).Count
if ($red -gt 0) { Write-Host "$red Suite(n) rot -- Logs: $env:TEMP\free_gate_$($env:N8NTEST_CONTAINER)_<suite>.log" -ForegroundColor Red }
else { Write-Host "Alle freien Gates gruen." -ForegroundColor Green }
exit $red
