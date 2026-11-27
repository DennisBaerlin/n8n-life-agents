#Requires -Version 5.1
# Mock-Szenario-Lint. Kein LLM, kein Substrat, kein Netz: rein statisch ueber tests/mock_llm/scenarios.json
# und die *_cases.json. Haelt den Mock-LLM-Tier (scripts/dev/mock_route_test.ps1) als hartes Gate ehrlich: faengt Drift
# zwischen den Szenarien und den echten Test-Cases commit-time, bevor ein vergessenes/umbenanntes Szenario den
# Gratis-Tier still loechrig macht.
#
# Geprueft wird (alle = hartes Gate):
#   C0 (eindeutige Case-ids): in jeder *_cases.json (auch E2E/NULL-Suiten) kommt jede id nur einmal vor.
#   C1 (Coverage): jeder Nicht-NULL-Case (expected_route/expected_tool gesetzt) hat ein Szenario, das
#      der Mock fuer seinen Task waehlen wuerde (laengster `match`-Substring, wie pickScenario in
#      server.js) und dessen calls den erwarteten Call enthalten. NULL-Cases (expected=null) sind
#      ausgenommen: sie brauchen kein Szenario (kein Match -> finaler Text -> kein Tool -> PASS).
#   C2 (kein Orphan): jeder Szenario-`match` ist Substring mindestens eines echten Case-Tasks, oder das Szenario
#      nennt per `driver` das Test-Skript, das den Task selbst schickt (das Skript muss den match woertlich enthalten).
#   C3 (eligible>0 / Tool-Namens-Drift): jeder Call-`tool` eines Szenarios ist ein echter erwarteter
#      Call irgendeines Cases (Orchestrator-Route sanitisiert zu Call_agent_<route>_, sonst der
#      Tool-Name). Faengt umbenannte/vertippte Tools im Szenario, bevor der Live-Lauf rot wird.
#      Leere calls (NULL-Pfad-Szenarien wie "Wetter") sind ausgenommen.
#   C4 (Datums-Platzhalter): jeder {{date:..}} in scenarios.json und den *_cases.json hat gueltige Grammatik; Beinahe-Schreibweisen
#      ({{ date:..}}, {date:..}, fehlendes }}) sind Fehler statt stiller Nicht-Treffer (Grammatik + Selbsttest: scripts/lib/date_placeholder.ps1).
#   C5 (keine festen Zukunfts-Daten): woertliches Datum (ISO oder TT.MM.JJJJ) in task/turns/expected_tool_args/expected_behavior bzw. Szenario-match/calls,
#      das in der Zukunft liegt oder weniger als zwei Jahre zurueckliegt, ist ein Fehler, ausser der Fall traegt fixed_date_reason oder steht
#      im Ratchet tests/util/fixed_dates_allowlist.json (nur sinkend). notes/name/_comment/setup_sql bleiben frei.
#   C6 (bekannter Absender): eine numerische chat_id eines Agent-Falls muss der Owner oder eine Person aus TestSenderUids (dev/test_n8n_state.ps1) sein,
#      sonst laeuft der Fall als nicht erkannter Absender. Nicht numerische chat_ids bleiben der Owner.
#   C7 (Vorbedingung): jeder Fall mit setup_sql traegt ein precondition_sql, das DB-Zustand liest (SELECT/EXISTS); Ausnahmen nur ueber das
#      sinkende Ratchet tests/util/precondition_allowlist.json (Logik + Selbsttest: scripts/lib/precondition_check.ps1).
#   C8 (Laien-Regeln): final/final_router jedes Szenarios halten L1-L3, L9, L12 aus scripts/lib/lay_metrics.ps1; Ausnahme nur mit
#      "lay": "off" und Begruendung in notes.
#   C9 (Durchspiel-Ausnahmen): eine Runde in conversation_cases.json mit "lay": "off" traegt eine Begruendung in notes.
#   C10 (Daten-Reife): ein Fall, dessen setup_sql einen Plan einer Domain mit readiness_fn (Manifest advisors) anlegt oder aendert, prueft diese fn im precondition_sql
#      (sonst fragt der Berater nach fehlenden Pflichtdaten statt den Fall zu spielen); Ausnahme plan_readiness_reason am Fall.
#
# tool_publish_plan pruefen die Szenarien ac31, ac33 und ac-pub-1 (nur der Werkzeug-Pfad).
#
# Usage:  .\scripts\mock_lint.ps1 [-Verbose]
# Exit-Code = Anzahl Fehler.
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot  = git -C $PSScriptRoot rev-parse --show-toplevel

# Case-Dateien per Glob ueber scripts/build/lib/agent_cases.ps1 (keine Paket-Liste). Ein Mock-Tier-Case
# hat einen `task`, kein `kind` (Real-Ingress-Cases haben ihren eigenen Runner) und einen Erwartungs-Schluessel; die
# Form folgt dem Schluessel: expected_route = Orchestrator (sanitisierter Call-Name), expected_tool = Agent (Tool-Name
# 1:1). Eine Datei zaehlt nur mit, wenn mindestens ein Case eine konkrete (nicht-NULL) Erwartung traegt; eine reine
# NULL-Suite (z. B. Angriffs-Cases) hat fuer den Mock nichts zu pruefen. Multi-Turn (`turns` statt `task`) und E2E
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
# (Call 'agent.finance' -> Call_agent_finance_, mit Unterstrich am Ende). Quelle: scripts/CLAUDE.md *Mock-LLM*.
function ConvertTo-RouteCall([string]$Route) { "Call_agent_${Route}_" }

function Read-Json([string]$RelPath) {
    $full = Join-Path $RepoRoot $RelPath
    $raw  = [System.IO.File]::ReadAllText($full, $Utf8NoBom)
    return ($raw | ConvertFrom-Json)
}

# --- Cases einlesen + erwarteten Call je Case ableiten ---
$cases = @()   # @{ Id; Task; Expected (string|$null); File }
$mockFiles = @()
$sentTexts = @()   # C2: auch die Nachrichten der Ingress-/node_ran-Faelle (Feld text) treiben Szenarien (z. B. ri62/ri63)
foreach ($cf in (Get-AgentCaseFile $RepoRoot)) {
    $fileCases = @()
    foreach ($c in $cf.Cases) {
        if ($c.PSObject.Properties['text'] -and $c.text) { $sentTexts += [string]$c.text }
        if ($c.PSObject.Properties['before']) { foreach ($b in @($c.before)) { if ($b.PSObject.Properties['text'] -and $b.text) { $sentTexts += [string]$b.text } } }
        # Ablauf-Faelle (kind sequence): jede Bildunterschrift eines Schritts ist eine gesendete Nachricht
        if ($c.PSObject.Properties['steps']) { foreach ($s in @($c.steps)) { if ($s.PSObject.Properties['caption'] -and $s.caption) { $sentTexts += [string]$s.caption } } }
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

# --- Szenarien einlesen ---
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

# --- C0: Case-IDs je Datei eindeutig (alle *_cases.json, auch E2E/NULL-Suiten) ---
# Die Tiers melden Ergebnisse je id und das Judge-Bundle ueberschriebe bei Doppelung still einen Case.
foreach ($cf in (Get-AgentCaseFile $RepoRoot)) {
    $dups = @($cf.Cases | Where-Object { $_.PSObject.Properties['id'] -and $_.id } | Group-Object { [string]$_.id } |
              Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    foreach ($d in $dups) {
        Write-Host "  [FAIL] C0 $($cf.Rel): Case-id '$d' kommt mehrfach vor (naechste freie id vergeben)." -ForegroundColor Red
        $failed++
    }
}

# --- C1: Coverage (jeder Nicht-NULL-Case hat ein passendes Szenario) ---
# Kein Namespace-Filter noetig (anders als server.js eligible = offered ∩ calls): der erwartete Call
# ist per Konstruktion der Tool/Route dieses Cases, wird der Ziel-Agentin also immer angeboten; der
# Filter entfernt nur fremde Namespaces. Die Laengster-Match-Auswahl (wie pickScenario) faengt zugleich
# Shadowing: waehlt der Mock ein laengeres Szenario ohne den erwarteten Call, schlaegt C1 an, wie der
# Live-Lauf dann finalen Text statt des Tools liefert.
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

# --- C2: kein Orphan-Szenario (jeder match ist Substring eines echten Tasks) ---
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

# --- C3: eligible>0 / Tool-Namens-Drift (jeder Szenario-Call ist ein echter erwarteter Call) ---
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

# --- C4: Datums-Platzhalter ({{date:+30d@2}}, scripts/lib/date_placeholder.ps1) in scenarios.json und allen *_cases.json gueltig ---
# Ein Tippfehler loest sonst nicht auf: der Harness sendet den Rohtext, der Mock matcht nicht, der Fall wird rot ohne erkennbaren Grund.
. (Join-Path $RepoRoot 'scripts\lib\date_placeholder.ps1')
$placeholderFiles = @('tests\mock_llm\scenarios.json') + @(Get-AgentCaseFile $RepoRoot | ForEach-Object { $_.Rel })
foreach ($rel in ($placeholderFiles | Select-Object -Unique)) {
    foreach ($e in @(Get-DatePlaceholderError ([System.IO.File]::ReadAllText((Join-Path $RepoRoot $rel), $Utf8NoBom)))) {
        Write-Host "  [FAIL] C4 ${rel}: $e" -ForegroundColor Red
        $failed++
    }
}

# --- C5: keine festen Zukunfts-/Naehe-Daten (Get-FixedDateFinding in scripts/lib/date_placeholder.ps1) ---
# Ein woertliches Datum, das heute in der Zukunft liegt oder weniger als zwei Jahre zurueckliegt, kippt mit der Zeit (Plan-Beginn vergangen,
# Fenster verschoben). Ratchet: tests/util/fixed_dates_allowlist.json haelt den Bestand je Fall; er darf nur sinken. Neue Daten als
# {{date:..}} schreiben oder (bewusst fest) mit fixed_date_reason im Fall begruenden. Weil das Heute eingeht, kann der Lint ohne Edit rot werden.
$fixedAllow = @{}
$allowObj = Read-Json 'tests/util/fixed_dates_allowlist.json'
foreach ($p in $allowObj.entries.PSObject.Properties) { $fixedAllow[$p.Name] = [int]$p.Value }
$fixedSeen = @{}
foreach ($f in (Get-AgentCaseFile $RepoRoot)) {
    foreach ($c in $f.Cases) {
        $n = @(Get-FixedDateFinding $c).Count
        if ($n) { $k = "$($f.Rel)|$($c.id)"; $fixedSeen[$k] = [int]$fixedSeen[$k] + $n }
    }
}
foreach ($s in @(Read-Json 'tests/mock_llm/scenarios.json')) {
    $n = @(Get-FixedDateFinding $s).Count
    if ($n) { $k = "tests/mock_llm/scenarios.json|$($s.match)"; $fixedSeen[$k] = [int]$fixedSeen[$k] + $n }
}
foreach ($k in ($fixedSeen.Keys | Sort-Object)) {
    $allowed = if ($fixedAllow.ContainsKey($k)) { $fixedAllow[$k] } else { 0 }
    if ($fixedSeen[$k] -gt $allowed) {
        Write-Host "  [FAIL] C5 ${k}: $($fixedSeen[$k]) festes Datum (erlaubt $allowed). Als {{date:..}} schreiben oder fixed_date_reason setzen." -ForegroundColor Red
        $failed++
    }
}
foreach ($k in ($fixedAllow.Keys | Sort-Object)) {
    $seen = if ($fixedSeen.ContainsKey($k)) { $fixedSeen[$k] } else { 0 }
    if ($seen -lt $fixedAllow[$k]) {
        Write-Host "  [FAIL] C5 ${k}: Allowlist erlaubt $($fixedAllow[$k]), gefunden $seen. Eintrag in tests/util/fixed_dates_allowlist.json senken oder entfernen (Ratchet)." -ForegroundColor Red
        $failed++
    }
}

# --- C6: numerische chat_id eines Agent-Falls ist ein bekannter Absender (TestSenderUids in dev/test_n8n_state.ps1) ---
# n8n_test und mock_route_test paaren nur diese Personen; eine andere Zahl liefe als nicht erkannter Absender (Knock-Zweig) statt als gemeinte Person.
# Nicht numerische Werte (z. B. 'test_ac01') bedeuten bewusst den Owner. Faelle mit `kind` (Real-Ingress/Infra) haben eigene Treiber und eigene uids.
. (Join-Path $RepoRoot 'scripts\dev\test_n8n_state.ps1')
$knownSenders = @{ "$($script:TestOwnerTelegramUid)" = $true }
foreach ($u in $script:TestSenderUids.Keys) { $knownSenders[$u] = $true }
foreach ($f in (Get-AgentCaseFile $RepoRoot)) {
    foreach ($c in $f.Cases) {
        if (-not $c.PSObject.Properties['task'] -or $c.PSObject.Properties['kind'] -or -not $c.PSObject.Properties['chat_id']) { continue }
        $v = "$($c.chat_id)"
        if ($v -match '^\d+$' -and -not $knownSenders.ContainsKey($v)) {
            Write-Host "  [FAIL] C6 $($f.Rel)|$($c.id): chat_id $v ist kein bekannter Absender (bekannt: $(($knownSenders.Keys | Sort-Object) -join ', ')). In TestSenderUids ergaenzen oder die chat_id aendern." -ForegroundColor Red
            $failed++
        }
    }
}

# --- C7: Fall mit setup_sql braucht precondition_sql (scripts/lib/precondition_check.ps1) ---
# Fail-closed: die Vorbedingung belegt gratis, dass die Vorbereitung den Zustand der Erwartung herstellt. Ausnahmen nur in
# tests/util/precondition_allowlist.json (Ratchet, nur schrumpfend). Selbsttest: scripts/dev/precondition_lint_test.ps1.
. (Join-Path $RepoRoot 'scripts\lib\precondition_check.ps1')
$preAllow = @{}
foreach ($p in (Read-Json 'tests/util/precondition_allowlist.json').entries.PSObject.Properties) { $preAllow[$p.Name] = "$($p.Value)" }
$preEntries = @()
foreach ($f in (Get-AgentCaseFile $RepoRoot)) {
    foreach ($e in @(Get-PreconditionFinding -Cases $f.Cases -File $f.Rel -Allow $preAllow)) { Write-Host "  [FAIL] C7 $e" -ForegroundColor Red; $failed++ }
    foreach ($c in $f.Cases) { $preEntries += [pscustomobject]@{ File = $f.Rel; Case = $c } }
}
foreach ($e in @(Get-PreconditionAllowlistStale -Entries $preEntries -Allow $preAllow)) { Write-Host "  [FAIL] C7 $e" -ForegroundColor Red; $failed++ }

# --- C8: Antwort-Texte der Szenarien halten die Laien-Regeln (scripts/lib/lay_metrics.ps1; Selbsttest dev/lay_metrics_test.ps1) ---
# final_router 'FRAME' ist ein Signal an den Relay, kein Text. Ausnahme nur je Szenario mit "lay": "off" und begruendendem "notes".
. (Join-Path $RepoRoot 'scripts\lib\lay_metrics.ps1')
$layNeg = @(Measure-BotText -Text 'Passt das? Oder anders?')
if ($layNeg.Count -ne 1) { Write-Host "  [FAIL] C8 Selbsttest: zwei Fragen ergeben $($layNeg.Count) Funde statt einem." -ForegroundColor Red; $failed++ }
foreach ($s in $scenarios) {
    $label = if ($s.PSObject.Properties['match']) { [string]$s.match } else { '(ohne match)' }
    $off = $s.PSObject.Properties['lay'] -and "$($s.lay)" -eq 'off'
    if ($s.PSObject.Properties['lay'] -and -not $off) { Write-Host "  [FAIL] C8 Szenario '$label': 'lay' kennt nur den Wert off." -ForegroundColor Red; $failed++ }
    if ($off) {
        if (-not ($s.PSObject.Properties['notes'] -and "$($s.notes)".Trim())) { Write-Host "  [FAIL] C8 Szenario '$label': lay off braucht eine Begruendung in notes." -ForegroundColor Red; $failed++ }
        continue
    }
    foreach ($field in @('final', 'final_router')) {
        if (-not $s.PSObject.Properties[$field]) { continue }
        $text = "$($s.$field)"
        if ($field -eq 'final_router' -and $text -ceq 'FRAME') { continue }
        foreach ($f in @(Measure-BotText -Text $text)) {
            Write-Host "  [FAIL] C8 Szenario '$label' ($field): Laien-Regel $($f.rule): $($f.detail) ('$($f.excerpt)')" -ForegroundColor Red
            $failed++
        }
    }
}

# --- C9: eine Durchspiel-Runde ohne Laien-Messung ("lay": "off") nennt in notes den Grund ---
foreach ($c in @(Read-Json 'tests\agent\cross\conversation_cases.json')) {
    if (-not $c.PSObject.Properties['turns']) { continue }
    $n = 0
    foreach ($t in @($c.turns)) {
        $n++
        if (-not $t.PSObject.Properties['lay']) { continue }
        if ("$($t.lay)" -ne 'off' -or -not ($t.PSObject.Properties['notes'] -and "$($t.notes)".Trim())) {
            Write-Host "  [FAIL] C9 $($c.id) Runde ${n}: erlaubt ist nur ""lay"": ""off"" zusammen mit einer Begruendung in notes." -ForegroundColor Red
            $failed++
        }
    }
}

# --- C10: Plan-Fall belegt die Daten-Reife (advisors.<domain>.readiness_fn im Paket-Manifest) ---
# Meldet die Reife fehlende Pflichtdaten (beim Finanzplan Konto, Einnahme, Ausgabe), erfasst der Berater sie laut Prompt vor jeder
# Plan-Arbeit: ein Fall ohne diese Daten im setup_sql fragt dann danach, statt das Gepruefte zu tun (roter Fall ohne Modellfehler).
# Ein Fall, dessen setup_sql einen Plan einer Domain mit readiness_fn (Entwurf oder aktiv, auch die Test-Domain __e2e_<domain>__)
# anlegt oder aendert, prueft die Reife darum im precondition_sql; ein Fall, der fehlende Plan-Daten selbst prueft, nennt den Grund
# in plan_readiness_reason. Geprueft werden die Faelle im Ordner des Pakets der Domain und in tests/agent/cross; Router-Faelle
# (expected_route) beruehrt die Reife nicht.
$readiness = @{}   # domain -> @{ Fn; Pkg }
foreach ($mf in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | ForEach-Object { Join-Path $_.FullName 'manifest.json' } | Where-Object { Test-Path $_ })) {
    $man = [System.IO.File]::ReadAllText($mf, $Utf8NoBom) | ConvertFrom-Json
    if (-not $man.PSObject.Properties['advisors']) { continue }
    foreach ($ap in $man.advisors.PSObject.Properties) {
        if ($ap.Name -like '_*' -or -not $ap.Value.PSObject.Properties['readiness_fn']) { continue }
        $readiness[$ap.Name] = @{ Fn = [string]$ap.Value.readiness_fn; Pkg = [string]$man.name }
    }
}
foreach ($f in (Get-AgentCaseFile $RepoRoot)) {
    foreach ($c in $f.Cases) {
        if ($c.PSObject.Properties['expected_route']) { continue }
        $setup = if ($c.PSObject.Properties['setup_sql']) { [string]$c.setup_sql } else { '' }
        if ($setup -notmatch '(INSERT INTO|UPDATE) agent\.advisor_plans|fn_advisor_save_section') { continue }
        if ($c.PSObject.Properties['plan_readiness_reason'] -and "$($c.plan_readiness_reason)".Trim()) { continue }
        $pre = if ($c.PSObject.Properties['precondition_sql']) { [string]$c.precondition_sql } else { '' }
        foreach ($dom in $readiness.Keys) {
            $r = $readiness[$dom]
            if ($f.Rel -notlike "tests/agent/$($r.Pkg)/*" -and $f.Rel -notlike 'tests/agent/cross/*') { continue }
            if ($setup -notmatch ("'(__e2e_)?" + [regex]::Escape($dom) + "(__)?'")) { continue }
            if ($pre -notmatch [regex]::Escape($r.Fn)) {
                Write-Host "  [FAIL] C10 $($f.Rel)|$($c.id): setup_sql legt einen Plan der Domain $dom an oder aendert ihn, precondition_sql prueft die Daten-Reife nicht (AND ($($r.Fn)(NULL, NULL)->>'ready')::boolean, Pflichtdaten im setup_sql) oder plan_readiness_reason setzen." -ForegroundColor Red
                $failed++
            }
        }
    }
}

Write-Host ("-" * 64)
$color =if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$failed Mock-Szenario-Check(s) fehlgeschlagen." -ForegroundColor $color
Write-Host ""
exit $failed
