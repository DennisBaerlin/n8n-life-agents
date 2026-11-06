#Requires -Version 5.1
# Mock-Szenario-Lint (Teststrategie Phase 6b Item 3 Teil B). Kein LLM, kein Substrat, kein Netz --
# rein statisch ueber tests/mock_llm/scenarios.json + die *_cases.json. Haelt den Mock-LLM-Tier
# (scripts/dev/mock_route_test.ps1) als HARTES Gate ehrlich: faengt Drift zwischen den Szenarien und
# den echten Test-Cases FRUEH (commit-time), bevor ein vergessenes/umbenanntes Szenario den
# Gratis-Tier still loechrig macht (Step-8-Charter-A-Hinweis aus Phase 6).
#
# Geprueft wird (alle = hartes Gate):
#   C0 (eindeutige Case-ids): in jeder *_cases.json (auch E2E/NULL-Suiten) kommt jede id nur einmal vor.
#   C1 (Coverage): jeder NICHT-NULL-Case (expected_route/expected_tool gesetzt) hat ein Szenario, das
#      der Mock fuer seinen Task waehlen wuerde (laengster `match`-Substring, wie pickScenario in
#      server.js) UND dessen calls den erwarteten Call enthalten. NULL-Cases (expected=null) sind
#      ausgenommen -- sie brauchen kein Szenario (kein Match -> finaler Text -> kein Tool -> PASS).
#   C2 (kein Orphan): jeder Szenario-`match` ist Substring mindestens EINES echten Case-Tasks — oder das Szenario
#      nennt per `driver` das Test-Skript, das den Task selbst schickt (das Skript muss den match woertlich enthalten).
#   C3 (eligible>0 / Tool-Namens-Drift): jeder Call-`tool` eines Szenarios ist ein echter erwarteter
#      Call IRGENDEINES Cases (Orchestrator-Route SANITISIERT zu Call_agent_<route>_, sonst der
#      Tool-Name). Faengt umbenannte/vertippte Tools im Szenario, bevor der Live-Lauf rot wird.
#      Leere calls (NULL-Pfad-Szenarien wie "Wetter") sind ausgenommen.
#
# tool_publish_plan ist bewusst OHNE Szenario (kein Case erwartet es) -> taucht in keiner der drei Pruefungen
# auf (weder Case-expected noch Szenario-Call) -> kein False-Positive, kein Sonderfall noetig.
#
# Usage:  .\scripts\mock_lint.ps1 [-Verbose]
# Exit-Code = Anzahl Fehler -> CI-/prek-Gate-faehig (Vorbild config_test.ps1 / doc_lint.ps1).
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot  = git -C $PSScriptRoot rev-parse --show-toplevel

# Case-Dateien (Phase D: per Glob ueber scripts/build/lib/agent_cases.ps1 statt einer Paket-Liste). Ein Mock-Tier-Case
# hat einen `task`, KEIN `kind` (Real-Ingress-Cases haben ihren eigenen Runner) und einen Erwartungs-Schluessel; die
# Form folgt dem Schluessel: expected_route = Orchestrator (sanitisierter Call-Name), expected_tool = Agent (Tool-Name
# 1:1). Eine Datei zaehlt nur mit, wenn mindestens EIN Case eine konkrete (nicht-NULL) Erwartung traegt — eine reine
# NULL-Suite (z. B. Angriffs-Cases) hat fuer den Mock nichts zu pruefen. Multi-Turn (`turns` statt `task`) + E2E
# (kein Erwartungs-Schluessel) fallen heraus.
. (Join-Path $RepoRoot 'scripts\build\lib\agent_cases.ps1')
function Get-CaseExpected([object]$Case) {
    if ($Case.PSObject.Properties['expected_route']) {
        if ($null -ne $Case.expected_route -and "$($Case.expected_route)" -ne '') { return ConvertTo-RouteCall ([string]$Case.expected_route) }
        return $null
    }
    if ($Case.PSObject.Properties['expected_tool'] -and $null -ne $Case.expected_tool -and "$($Case.expected_tool)" -ne '') { return [string]$Case.expected_tool }
    return $null
}

# Orchestrator-Routen-Name -> sanitisierter Tool-Function-Name, wie n8n ihn der LLM anbietet
# (Call 'agent.finance' -> Call_agent_finance_; Trailing-Underscore!). Quelle: scripts/CLAUDE.md
# *Mock-LLM* + Discovery-Empirie.
function ConvertTo-RouteCall([string]$Route) { "Call_agent_${Route}_" }

function Read-Json([string]$RelPath) {
    $full = Join-Path $RepoRoot $RelPath
    $raw  = [System.IO.File]::ReadAllText($full, $Utf8NoBom)
    return ($raw | ConvertFrom-Json)
}

# --- Cases einlesen + erwarteten Call je Case ableiten -------------------------------------------
$cases = @()   # @{ Id; Task; Expected (string|$null); File }
$mockFiles = @()
$sentTexts = @()   # C2: auch die Nachrichten der Ingress-/node_ran-Faelle (Feld text) treiben Szenarien (z. B. ri62/ri63)
foreach ($cf in (Get-AgentCaseFile $RepoRoot)) {
    $fileCases = @()
    foreach ($c in $cf.Cases) {
        if ($c.PSObject.Properties['text'] -and $c.text) { $sentTexts += [string]$c.text }
        if (-not $c.task -or $c.PSObject.Properties['kind']) { continue }
        if (-not ((Test-CaseHasKey $c 'expected_tool') -or (Test-CaseHasKey $c 'expected_route'))) { continue }
        $fileCases += @{ Id = [string]$c.id; Task = [string]$c.task; Expected = (Get-CaseExpected $c); File = $cf.Rel }
    }
    if (@($fileCases | Where-Object { $_.Expected }).Count -eq 0) { continue }   # reine NULL-Suite / keine Mock-Cases
    $cases += $fileCases; $mockFiles += $cf.Rel
}
if ($mockFiles.Count -eq 0) { throw 'mock_lint: keine Mock-Tier-Case-Datei gefunden (Glob/Schema kaputt?).' }
if ($Verbose) { Write-Host "Mock-Case-Dateien: $($mockFiles -join ', ')" -ForegroundColor DarkGray }

# Menge aller erwarteten Calls (fuer C3 = Tool-Namens-Drift).
$allExpected = @{}
foreach ($c in $cases) { if ($c.Expected) { $allExpected[$c.Expected] = $true } }

# --- Szenarien einlesen --------------------------------------------------------------------------
$scenarios = @(Read-Json 'tests\mock_llm\scenarios.json')

# Das Szenario, das der Mock fuer einen Task waehlt: laengster `match`-Substring gewinnt (pickScenario
# in server.js, strikt > -> erster bei Gleichstand). $null wenn keines matcht.
function Select-Scenario([string]$Task) {
    $t = $Task.ToLower()
    $best = $null
    foreach ($s in $scenarios) {
        if (-not $s.PSObject.Properties['match']) { continue }
        $m = [string]$s.match
        if ($m -ne '' -and $t.Contains($m.ToLower())) {
            if (-not $best -or $m.Length -gt ([string]$best.match).Length) { $best = $s }
        }
    }
    return $best
}

function Get-ScenarioTools([object]$Scenario) {
    $out = @()
    if ($Scenario -and $Scenario.PSObject.Properties['calls'] -and $Scenario.calls) {
        foreach ($call in $Scenario.calls) { if ($call.PSObject.Properties['tool'] -and $call.tool) { $out += [string]$call.tool } }
    }
    return $out
}

Write-Host ""
Write-Host "Mock-Szenario-Lint -- $($cases.Count) Case(s), $($scenarios.Count) Szenario(en)"
Write-Host ("-" * 64)
$failed = 0

# --- C0: Case-IDs je Datei eindeutig (alle *_cases.json, auch E2E/NULL-Suiten) ------------------
# Anlass 2026-10-30: parallele Sessions vergaben tc80/tc81 und e2e42/e2e43 doppelt; die Tiers melden
# Ergebnisse je id, das Judge-Bundle ueberschrieb dann still einen Case. Hier faellt es commit-time auf.
foreach ($cf in (Get-AgentCaseFile $RepoRoot)) {
    $dups = @($cf.Cases | Where-Object { $_.PSObject.Properties['id'] -and $_.id } | Group-Object { [string]$_.id } |
              Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    foreach ($d in $dups) {
        Write-Host "  [FAIL] C0 $($cf.Rel): Case-id '$d' kommt mehrfach vor (naechste freie id vergeben)." -ForegroundColor Red
        $failed++
    }
}

# --- C1: Coverage (jeder Nicht-NULL-Case hat ein passendes Szenario) -----------------------------
# Kein Namespace-Filter noetig (anders als server.js eligible = offered ∩ calls): der erwartete Call
# IST per Konstruktion der Tool/Route DIESES Cases -> er wird der Ziel-Agentin immer angeboten, der
# Filter entfernt nur FREMDE Namespaces, nie den erwarteten Call. Die Laengster-Match-Auswahl (wie
# pickScenario) faengt zugleich Shadowing: waehlt der Mock ein laengeres Szenario ohne den erwarteten
# Call, schlaegt C1 hier an -- genau wie der Live-Lauf dann finalen Text statt des Tools liefert.
foreach ($c in $cases) {
    if (-not $c.Expected) { continue }   # NULL-Case ausgenommen
    $s = Select-Scenario $c.Task
    if (-not $s) {
        Write-Host "  [FAIL] C1 $($c.Id) ($($c.File)): kein Szenario matcht den Task (erwartet Call '$($c.Expected)')." -ForegroundColor Red
        $failed++; continue
    }
    $tools = Get-ScenarioTools $s
    if ($tools -notcontains $c.Expected) {
        Write-Host "  [FAIL] C1 $($c.Id): gewaehltes Szenario '$($s.match)' enthaelt '$($c.Expected)' nicht (calls: [$($tools -join ', ')])." -ForegroundColor Red
        $failed++; continue
    }
    if ($Verbose) { Write-Host "  [PASS] C1 $($c.Id) -> '$($s.match)' -> $($c.Expected)" -ForegroundColor Green }
}

# --- C2: kein Orphan-Szenario (jeder match ist Substring eines echten Tasks) ---------------------
foreach ($s in $scenarios) {
    if (-not $s.PSObject.Properties['match']) { continue }
    $m = [string]$s.match
    $hit = $false
    foreach ($c in $cases) { if ($c.Task.ToLower().Contains($m.ToLower())) { $hit = $true; break } }
    if (-not $hit) { foreach ($t in $sentTexts) { if ($t.ToLower().Contains($m.ToLower())) { $hit = $true; break } } }
    # Treiber-eigenes Szenario (`driver` = Repo-Pfad des Test-Skripts, das den Task selbst schickt, z. B. die
    # "Bot denkt nach"-Faelle in mock_route_test): zaehlt, wenn das Skript den match-Text woertlich enthaelt.
    if (-not $hit -and $s.PSObject.Properties['driver']) {
        $drv = Join-Path $RepoRoot ([string]$s.driver)
        $hit = (Test-Path $drv) -and ([System.IO.File]::ReadAllText($drv, $Utf8NoBom).ToLower().Contains($m.ToLower()))
    }
    if (-not $hit) {
        Write-Host "  [FAIL] C2 Orphan-Szenario: match '$m' ist in keinem Case-Task enthalten." -ForegroundColor Red
        $failed++
    } elseif ($Verbose) { Write-Host "  [PASS] C2 match '$m'" -ForegroundColor Green }
}

# --- C3: eligible>0 / Tool-Namens-Drift (jeder Szenario-Call ist ein echter erwarteter Call) -----
foreach ($s in $scenarios) {
    foreach ($tool in (Get-ScenarioTools $s)) {
        # Treiber-eigenes Szenario: ein Call, den der Treiber selbst prueft (Tool-Name woertlich im Skript, z. B.
        # [sql-guard] postgres_select ohne query in mock_route_test), ist kein Drift.
        if (-not $allExpected.ContainsKey($tool) -and $s.PSObject.Properties['driver']) {
            $drv = Join-Path $RepoRoot ([string]$s.driver)
            if ((Test-Path $drv) -and [System.IO.File]::ReadAllText($drv, $Utf8NoBom).Contains($tool)) { continue }
        }
        if (-not $allExpected.ContainsKey($tool)) {
            $label = if ($s.PSObject.Properties['match']) { [string]$s.match } else { '(ohne match)' }
            Write-Host "  [FAIL] C3 Szenario '$label': Call '$tool' ist kein erwarteter Call irgendeines Cases (Tool-Namens-Drift?)." -ForegroundColor Red
            $failed++
        }
    }
}

Write-Host ("-" * 64)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$failed Mock-Szenario-Check(s) fehlgeschlagen." -ForegroundColor $color
Write-Host ""
exit $failed
