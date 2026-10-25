#Requires -Version 5.1
# approval_lint.ps1 — WS-5b Auth-Matrix-Lint (hartes Gate). Prueft die GEBAUTEN Workflow-JSONs
# (packages/*/workflows/*.json = getrackte SoT) gegen die `approval_matrix`-Bloecke der Paket-Manifeste
# (Phase D; gelesen + vertrags-geprueft ueber scripts/build/lib/approval_matrix.ps1, dieselbe lib wie build.ps1) — fail-closed:
#   (a) jeder Gate-Aufruf-Node (executeWorkflow -> cachedResultName == agent.tool_human_approval) traegt
#       einen approval_tier-Input, und der Wert == Matrix-Eintrag des Workflows;
#   (b) kein Orphan: jeder Matrix-Eintrag entspricht einem real gebauten Gate-Aufrufer;
#   (c) Matrix-Selbstkonsistenz (lib): gueltiger tier-Enum, kein Doppel-Eintrag, Verb-Praefix-Strictness;
#   (d) Besitz: der Eintrag steht im Manifest des Pakets, in dessen workflows/-Verzeichnis die gebaute Datei liegt.
# Harnesses (*.test_harness) liefern approval_tier ueber den Test-Webhook -> ausgenommen.
# Exit-Code = Anzahl Fehler (CI-/Pre-Push-tauglich). Kein LLM, kein Netz, kein Substrat.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$u8 = New-Object System.Text.UTF8Encoding($false)
$GATE = 'agent.tool_human_approval'
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

# --- Matrix laden + selbst-konsistent pruefen (c) -----------------------------------------------------
. (Join-Path $RepoRoot 'scripts\build\lib\approval_matrix.ps1')
$am = Get-ApprovalMatrix $RepoRoot
foreach ($e in $am.Errors) { Fail "matrix: $e" }
$matrix = @{}; foreach ($k in $am.Entries.Keys) { $matrix[$k] = $am.Entries[$k].Tier }

# --- gebaute JSONs scannen (a) — paket-bewusst: jedes Paket unter packages/*/workflows
$wfDirs = @()
foreach ($p in (Get-ChildItem -Path (Join-Path $RepoRoot 'packages') -Directory -ErrorAction SilentlyContinue)) {
    $w = Join-Path $p.FullName 'workflows'; if (Test-Path $w) { $wfDirs += $w }
}
$seen  = @{}
foreach ($file in (Get-ChildItem $wfDirs -Filter '*.json')) {
    $wf = [System.IO.File]::ReadAllText($file.FullName, $u8) | ConvertFrom-Json
    $name = [string]$wf.name
    if ($name -like '*.test_harness') { continue }
    foreach ($n in $wf.nodes) {
        if ($n.type -ne 'n8n-nodes-base.executeWorkflow') { continue }
        if ([string]$n.parameters.workflowId.cachedResultName -ne $GATE) { continue }
        $val = $n.parameters.workflowInputs.value
        $tier = if ($val.PSObject.Properties.Name -contains 'approval_tier') { [string]$val.approval_tier } else { $null }
        if (-not $tier) { Fail "${name} / Node '$($n.name)': Gate-Aufruf OHNE approval_tier (fail-closed)"; continue }
        if (-not $matrix.ContainsKey($name)) { Fail "${name}: Gate-Aufrufer fehlt im approval_matrix-Block seines Paket-Manifests"; continue }
        if ($tier -ne $matrix[$name]) { Fail "${name}: approval_tier='$tier' != Matrix '$($matrix[$name])'" }
        $filePkg = if (($file.FullName -replace '\\', '/') -match '/packages/([^/]+)/workflows/') { $Matches[1] } else { '' }
        if ($filePkg -ne $am.Entries[$name].Package) { Fail "${name}: im Manifest von '$($am.Entries[$name].Package)' getiert, die gebaute Datei liegt aber in packages/$filePkg/workflows (Besitz)" }
        $seen[$name] = $true
    }
    # (e) Stufe self: der Workflow darf NUR ueber die selbst-beschraenkende fn schreiben ($ApprovalSelfFn, per_user fest)
    #     und keinen scope-Eingang haben — sonst waere self ein Owner-Bypass fuer Haushalts-Kontexte.
    if ($matrix.ContainsKey($name) -and $matrix[$name] -eq 'self') {
        # GENAU ein Postgres-Node, und der ruft $ApprovalSelfFn (kein zweiter Write daneben); ausser dem Gate kein
        # executeWorkflow (sonst liefe ein anderes Werkzeug hinter einer reinen Selbst-Bestaetigung).
        # Einzige Ausnahme: der reine Lese-Knoten "Resolve dates" (core.fn_resolve_fact_dates ist eine Funktion ohne
        # Tabellenzugriff, WP3: Karte = Speicher bei relativen Daten) — exakt diese Query-Form, sonst zaehlt er mit.
        $queries = @($wf.nodes | Where-Object { $_.type -like 'n8n-nodes-base.postgres*' } | ForEach-Object { [string]$_.parameters.query } |
                     Where-Object { $_ -notmatch "^=SELECT core\.fn_resolve_fact_dates\(\(\`$1::jsonb\)->'facts'\)::text AS facts_resolved;$" })
        if ($queries.Count -ne 1 -or $queries[0] -notmatch [regex]::Escape($ApprovalSelfFn)) { Fail "${name}: Stufe self braucht GENAU einen Postgres-Node, der $ApprovalSelfFn ruft (gefunden: $($queries.Count))" }
        foreach ($q in $queries) { if ($q -match 'fn_set_context_facts') { Fail "${name}: Stufe self ruft agent.fn_set_context_facts direkt (nur $ApprovalSelfFn erlaubt)" } }
        $otherCalls = @($wf.nodes | Where-Object { $_.type -eq 'n8n-nodes-base.executeWorkflow' -and [string]$_.parameters.workflowId.cachedResultName -ne $GATE })
        if ($otherCalls.Count -gt 0) { Fail "${name}: Stufe self darf ausser dem Gate keine Workflows aufrufen ($(($otherCalls | ForEach-Object { $_.name }) -join ', '))" }
        $start = $wf.nodes | Where-Object { $_.type -eq 'n8n-nodes-base.executeWorkflowTrigger' } | Select-Object -First 1
        $inputs = @($start.parameters.workflowInputs.values | ForEach-Object { [string]$_.name })
        if ($inputs -contains 'scope') { Fail "${name}: Stufe self darf keinen scope-Eingang haben" }
    }
}

# --- Orphan-Check (b): jeder Matrix-Eintrag muss ein real gebauter Gate-Aufrufer sein ----------------
foreach ($tool in $matrix.Keys) {
    if (-not $seen.ContainsKey($tool)) { Fail "matrix: Eintrag '$tool' entspricht KEINEM gebauten Gate-Aufrufer (Orphan/Tippfehler)" }
}

if ($fails -eq 0) { Write-Host "approval_lint: OK ($($matrix.Count) Gate-Aufrufer, alle approval_tier konsistent)" -ForegroundColor Green }
else { Write-Host "approval_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
