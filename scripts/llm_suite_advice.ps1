#Requires -Version 5.1
# Dirty-Surface-Analyse (aus pre_push_check.ps1 extrahiert) -- WEICHE Empfehlung, blockt NIE.
# Laeuft als pre-push-Hook (.pre-commit-config.yaml, id llm-suite-advice). Nennt die LLM-kostenden
# Suiten (n8n_test/orch_test/e2e_test), die laut Blast-Radius-Matrix fuer den zu pushenden Diff
# laufen sollten, plus semantische Doku-Touchpoints. Exit immer 0 (rein informativ).

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

Write-Host "Dirty-Surface-Analyse (LLM-Suiten-Empfehlung; NICHT erzwungen) ..." -ForegroundColor Cyan

# Bereich bestimmen: gegen Upstream, sonst origin/main, sonst HEAD~1.
$range = $null
try { $up = (git -C $RepoRoot rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null); if ($LASTEXITCODE -eq 0 -and $up) { $range = "$up..HEAD" } } catch { }
if (-not $range) { try { git -C $RepoRoot rev-parse --verify origin/main 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $range = 'origin/main..HEAD' } } catch { } }
if (-not $range) { $range = 'HEAD~1..HEAD' }

$changed = @()
try { $changed = git -C $RepoRoot diff --name-only $range 2>$null } catch { }
if (-not $changed) { $changed = @() }

$recs = @()
$docTouchpoints = @()
# Agenten je Paket aus den Manifesten (geteilte lib wie build.ps1 — dieses Skript kennt kein Paket).
# Der Orchestrator hat seine eigene Suite (orch_test, unten) und zaehlt hier nicht.
. (Join-Path $PSScriptRoot 'build\lib\agent_routing.ps1')
$agentsByPkg = @{}
foreach ($m in (Get-PackageManifest $RepoRoot)) {
    $names = @(@($m.Json.provides.agents) | Where-Object { $_ -and $_ -isnot [string] -and $_.name -and $_.name -ne 'orchestrator' } |
        ForEach-Object { "agent.$($_.name)" })
    if ($names.Count -gt 0) { $agentsByPkg[[string]$m.Json.name] = $names }
}
$toolPkgs = @($changed | ForEach-Object { if ($_ -match '^packages/([^/]+)/build/workflows/(tools/|agent\.(?!orchestrator))') { $Matches[1] } } | Select-Object -Unique)
foreach ($p in $toolPkgs) {
    if (-not $agentsByPkg.ContainsKey($p)) { continue }   # Paket ohne Agenten: kein Agent-Routing zu pruefen
    $recs += "n8n_test.ps1 (+ judge_eval.ps1) je Agent von '$p' ($($agentsByPkg[$p] -join ', '); -TargetWorkflow/-WebhookPath/-CasesFile): Tool-Descriptions/Bindings geaendert -> Routing-/Verhaltens-Regress moeglich."
    $recs += "e2e_test.ps1: Tool-Payload-Pfad in '$p' geaendert -> Schema-Fidelity gegen die DB pruefen."
    $docTouchpoints += "Tool in '$p' beruehrt -> Write-Tools-Katalog (docs/reference/packages.md), Golden-Case (tests/agent/$p/*_cases.json), 'Not yet available'-Liste im Prompt pruefen."
}
if ($changed | Where-Object { $_ -match '^packages/[^/]+/manifest\.json$' -or $_ -match '^packages/core/seed/ai_models\.json$' }) {
    $recs += "n8n_test.ps1 + orch_test.ps1: Manifest-/Modell-/Config-Wechsel -> Routing kann still kippen (Config lebt seit WS4a in den Manifesten)."
}
if ($changed | Where-Object { $_ -match 'orchestrator' }) {
    $recs += "orch_test.ps1: Orchestrator-Workflow geaendert -> Routing-Entscheidung pruefen."
}
# Case-Dateien -> die Suite, die sie faehrt (Zuordnung nach Dateiname; docs/reference/tests.md fuehrt die Tabelle).
foreach ($cf in @($changed | Where-Object { $_ -match '^tests/agent/[^/]+/[^/]+_cases\.json$' })) {
    switch -Regex (Split-Path $cf -Leaf) {
        '^orch_cases\.json$'                 { $recs += "orch_test.ps1: Routing-Cases geaendert ($cf) -> neuen/geaenderten Golden gegenpruefen." }
        'e2e_cases\.json$'                   { $recs += "e2e_test.ps1 -CasesFile $cf : E2E-Cases geaendert -> Schreibpfad gegenpruefen." }
        '^multiturn_cases\.json$'            { $recs += "multiturn_test.ps1: Multi-Turn-Cases geaendert ($cf)." }
        '^(infra|real_ingress)_cases\.json$' { }   # gratis Tiers (infra_test/real_ingress_test) -> keine LLM-Empfehlung
        default                              { $recs += "n8n_test.ps1 -CasesFile $cf (+ judge_eval.ps1): Agent-Cases geaendert -> neuen/geaenderten Golden gegenpruefen." }
    }
}
if ($changed | Where-Object { $_ -match '^packages/[^/]+/db/.*\.sql$' }) {
    $docTouchpoints += "Paket-SQL beruehrt -> packages/<pkg>/CLAUDE.md-Sync pruefen (Tabellen/Views/Invarianten); neue fn_* -> test_fn_*.sql Pflicht."
}
if ($changed | Where-Object { $_ -match '^scripts/build/' -or $_ -match '^packages/[^/]+/build/' }) {
    $docTouchpoints += "Build-Generator/Engine beruehrt -> Sticky-Notes des Workflows gegen den neuen Graphen gegenlesen (vor dem Substrat-Deploy via bootstrap_test_n8n.ps1 -Reset)."
}
# Site-Touchpoint (Site-Phase): nutzer-sichtbare Oberflaechen -> Showcase-Site mitziehen.
# Befehls-Tabelle ist HART geprueft (doc_lint Check 10); Prosa/Beispiele bleiben semantisch -> Erinnerung.
if ($changed | Where-Object { $_ -match '^packages/[^/]+/(manifest\.json$|contexts/|onboarding/|build/workflows/(tools/|agent\.))' }) {
    $docTouchpoints += "Nutzer-sichtbare Oberflaeche beruehrt -> Showcase-Site pruefen: passende Docs-Seite (docs/site/content/docs/), beispiele.md, ggf. Landing-Sektion (docs/site/layouts/index.html); danach scripts/build_site.ps1 + Output committen."
}

if ($recs.Count -gt 0) {
    Write-Host "  EMPFEHLUNG (LLM-kostend, NICHT erzwungen) fuer Bereich $range :" -ForegroundColor Yellow
    foreach ($r in ($recs | Select-Object -Unique)) { Write-Host "    - $r" -ForegroundColor Yellow }
} else {
    Write-Host "  Keine LLM-relevante Oberflaeche im Diff ($range) beruehrt." -ForegroundColor Green
}
if ($docTouchpoints.Count -gt 0) {
    Write-Host "  DOKU-TOUCHPOINTS (semantisch, kein Lint prueft das -- kurz checken):" -ForegroundColor DarkYellow
    foreach ($d in ($docTouchpoints | Select-Object -Unique)) { Write-Host "    - $d" -ForegroundColor DarkYellow }
}

# ---------------------------------------------------------------------------
# Zwei zusaetzliche, rein informative Signale (blocken NIE, Exit bleibt 0):
#   (B) Neue Pattern-Paritaets-Oberflaeche (package-contract Abschnitt 8) -> Paritaets-Checkliste im Review-Pass faellig.
#   (A) Neues Paket / neuer Route-Agent gelandet -> Owner-Doku (README + Showcase-Site) geschuldet.
# Beide werten NUR git-ADDED Pfade (--diff-filter=A) bzw. NEU hinzugefuegte provides.agents-Zeilen aus
# = selten + hoch-signalhaft; ein blosser Config-/Bestands-Edit triggert sie NICHT.
$added = @()
try { $added = git -C $RepoRoot diff --diff-filter=A --name-only $range 2>$null } catch { }
if (-not $added) { $added = @() }

# (B) PARITAETS-TRIGGER: neu gelandete Pattern-Paritaets-Oberflaechen (package-contract Abschnitt 8) -> die
#     Paritaets-Checkliste gegen das Referenz-Analog fahren (Skill /feature, Schritt 4; Core-Single-Paket-Naht
#     suchen). Rein hinweisend.
#     Oberflaechen = neues Write-Tool, neuer agent.*/cron.*-Build-Def, neues Paket (manifest.json) ODER
#     eine neue Abschnitt-8-foermige Registry-/Window-/Enumerator-fn (R__fn_*). Nur git-ADDED = high-signal.
$genSurfaces = @()
$genSurfaces += @($added | Where-Object { $_ -match '^packages/[^/]+/build/workflows/tools/[^/]+\.ps1$' })
$genSurfaces += @($added | Where-Object { $_ -match '^packages/[^/]+/build/workflows/agent\.[^/]+\.ps1$' })
$genSurfaces += @($added | Where-Object { $_ -match '^packages/[^/]+/build/workflows/cron\.[^/]+\.ps1$' })
$genSurfaces += @($added | Where-Object { $_ -match '^packages/[^/]+/manifest\.json$' })
$genSurfaces += @($added | Where-Object { $_ -match '/R__fn_.*(registr|window|scope|handler|catalog|dispatch|enumerat|search_path|context_persons).*\.sql$' })
$genSurfaces = @($genSurfaces | Select-Object -Unique)
if ($genSurfaces.Count -gt 0) {
    Write-Host "  Paritaets-Check faellig fuer: $($genSurfaces -join ', ')" -ForegroundColor DarkCyan
    Write-Host "    -> neue Pattern-Paritaets-Oberflaeche gelandet; Paritaets-Checkliste (package-contract Abschnitt 8) gegen das Referenz-Analog pruefen (Core-Single-Paket-Naht?)." -ForegroundColor DarkCyan
}

# (A) NEW-PACKAGE-/AGENT-LANDING -> Owner-Doku-Schuld. LAUT (rot), weil ein neues Paket / ein neuer
#     Route-Agent nach aussen sichtbar ist und KEIN Lint die Prosa-Seiten (README/Site) prueft.
#     Landing = neue packages/<pkg>/manifest.json ODER eine neu hinzugefuegte provides.agents-Objektzeile
#     (eine +Zeile mit "name" UND "router_description" -> reine Config-Edits matchen nicht). Feuert nur,
#     wenn der Diff WEDER ^README\.md$ NOCH ^docs/site/ beruehrt (sonst ist die Schuld schon adressiert).
$addedManifests = @($added | Where-Object { $_ -match '^packages/[^/]+/manifest\.json$' })
$addedAgentLines = @()
try {
    $addedAgentLines = @(git -C $RepoRoot diff $range -- 'packages/*/manifest.json' 2>$null |
        Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+' -and $_ -match '"name"\s*:' -and $_ -match '"router_description"\s*:' })
} catch { }
$landing = ($addedManifests.Count -gt 0) -or ($addedAgentLines.Count -gt 0)
$docsOwedTouched = @($changed | Where-Object { $_ -match '^README\.md$' -or $_ -match '^docs/site/' }).Count -gt 0
if ($landing -and -not $docsOwedTouched) {
    Write-Host ""
    Write-Host "  ####################################################################" -ForegroundColor Red
    Write-Host "  ##  NEUES PAKET / NEUER AGENT GELANDET -- OWNER-DOKU FEHLT         ##" -ForegroundColor Red
    Write-Host "  ####################################################################" -ForegroundColor Red
    if ($addedManifests.Count -gt 0) {
        Write-Host "    Neue manifest.json: $($addedManifests -join ', ')" -ForegroundColor Red
    }
    if ($addedAgentLines.Count -gt 0) {
        Write-Host "    Neue provides.agents-Zeile(n) im Diff (neuer Route-Agent)." -ForegroundColor Red
    }
    Write-Host "    Der Diff beruehrt WEDER README.md NOCH docs/site/ -> GESCHULDET:" -ForegroundColor Red
    Write-Host "      - README.md   (Agenten-/Paket-Uebersicht aktualisieren)" -ForegroundColor Red
    Write-Host "      - docs/site/  (Showcase-Site: Docs-Seite + ggf. Landing; danach scripts/build_site.ps1 + Output committen)" -ForegroundColor Red
    Write-Host "  ####################################################################" -ForegroundColor Red
}

exit 0
