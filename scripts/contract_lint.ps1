#Requires -Version 5.1
# Cross-Layer-Kontrakt-Lint (Hardening-Phase Session 1) -- hartes Pre-Push-Gate.
#
# Der Feld-Kontrakt EINES Write-Tools lebt in mehreren Schichten (fn-SQL, Tool-Trigger,
# Agent-InputSpec); bisher prueften das nur Tests zur LAUFZEIT (oder gar nichts). Dieser Lint
# prueft die Schichten STATISCH gegeneinander -- auf den generierten/getrackten Workflow-JSONs
# (robuster als PS1-Parsing) + den fn-SQL-Dateien:
#
#   (1) TOTE fn-REFERENZEN: jeder agent./core.fn_*-Aufruf in einem Workflow-JSON muss eine
#       definierte Function treffen (packages/*/db/migrations/R__fn_*.sql ODER CREATE FUNCTION in packages/*/db/**/*.sql).
#   (2) TOOL->fn PAYLOAD-KEYS: jeder Key im JSON.stringify({...})-queryReplacement eines
#       Postgres-Nodes muss ENTWEDER in der Query selbst (->>'key') ODER in einer der
#       aufgerufenen fn-Dateien gelesen werden. Ein nie gelesener Key wird von Postgres STILL
#       ignoriert -- genau die "Verweis auf nicht existentes Datenfeld"-Klasse.
#   (3) AGENT->TOOL INPUTS: jeder Input, den ein toolWorkflow-/executeWorkflow-Node bindet,
#       muss im executeWorkflowTrigger des Ziel-Workflows DEKLARIERT sein -- nicht deklarierte
#       Felder verwirft n8n still (Build-Gotcha "Neuer Tool-Input muss an ZWEI Stellen rein").
#   (4) $fromAI-HYGIENE: (a) ein $fromAI-Ausdruck, der nicht dem kanonischen Muster entspricht
#       (z. B. Apostroph in der Description -> "Unbalanced parentheses"), (b) *_id-Felder mit
#       Typ 'number' (LLM quotet IDs -> Schema-Reject; Gotcha: IDs immer als 'string').
#   (5) jsonb-STANDARD: queryReplacement, das nicht ={{ JSON.stringify({...}) }} ist, ist
#       Altlast (positionale Parameter -> Leer-Drop/Parameter-Shift-Klasse).
#   (6) SERVICE-ALIAS (D9/SC1): provides/consumes.services-Integritaet (jeder provides.services-Wert
#       trifft einen Workflow; consumes ⊆ provides) + Referenz-Scan der Build-Defs (jedes Nicht-Core-Paket
#       nutzt nur Aliase aus seiner consumes.services). Paket eines Defs = physischer Ort (packages/<pkg>/build/).
#       Scannt .ps1 (Tokens werden build-time aufgeloest).
#   (7) CRON-ENABLE (F9/R1-MINOR): jeder gegatete Cron liest sein Enable-Flag ueber
#       core.fn_config_get('<pkg>','cron_enable','<key>'); dieses Literal MUSS im Manifest
#       (.config.cron_enable.<key>) deklariert sein (sonst seedet der Host die Zeile nicht ->
#       fail-closed schaltet den Cron STILL ab). Umgekehrt = Orphan (deklariertes Flag, das kein Gate liest).
#   (8) BACKUP-BLOCK-HYGIENE (Phase 5, arch-3 Obj 3 + M4): der manifest-`backup`-Block darf den
#       Backup-Key und Code-Seeds nie in ein Bundle ziehen. (8a) Schema `core` NIE in einem backup-Block
#       (kein `core.<tabelle>` in full_tables/filtered_tables; kein schema_dump auf einem Paket, das Schema
#       core besitzt) -> sonst rutschte core.backup_key ins Bundle (der Restore-Schluessel selbst). (8b)
#       eine code-geseedete Tabelle (agent.ai_models/core.config) gehoert in KEIN Bundle -> der Installer
#       seedet sie neu; im Dump wuerde ein Restore Code mit altem Stand ueberschreiben (M4, --no-seed-Vertrag).
#   (9) CRON-CONTEXT-WRITE (M1, Phase C): ein Cron (scheduleTrigger-Workflow) schreibt NIE agent.core_contexts
#       -- weder direkt (INSERT/UPDATE/DELETE) noch ueber eine fn, die es transitiv tut. Der einzige
#       core_contexts-Schreibpfad ist die owner-gegatete Approve-fn (Orchestrator-Callback learn:ok), NIE ein Cron.
#   (12) CREDENTIALS-BLOCK (Install-UX, §3.8): (a) Schema + type-/validator-Enum + env-Key-Bezeichner-
#       Pin (^[A-Z_][A-Z0-9_]*$ — der Name fliesst in eval/grep) + httpHeaderAuth=genau-1-env-Key,
#       (b) bidirektionale Paritaet manifest-credentials <-> __CRED_*__-Referenzen der Paket-Workflows
#       (Host-Map + Rollen-Konvention allowlisted), (c) NAHT-GUARD (kein Paket-Credential-Literal/-env-Key
#       im provisioning-Host-Code -- der career-Sonderlocken-Rueckfall failt beim Commit), (d) PROMPT-GATE-
#       GUARD (Eingabe-Primitive nur sanktioniert, JEDE read-Form mit /dev/tty-Redirect +
#       ui_interactive/UNATTENDED-Gate-Asserts).
#   (13) CLI-HELP-PARITAET (Install-UX, Owner-Direktive "Help = die EINE Befehls-Referenz"): je
#       Dispatcher (lifeagents.tpl/pkg_lifecycle/config_cli/household_cli/backup_cli) bidirektional
#       Verb-Arm <-> Help-Heredoc; Flags parse_args <-> usage() (provision.sh bidirektional,
#       install.sh geparst ⊆ dokumentiert — Passthrough pauschal). Selbst-Asserts bei Extraktions-Drift.
#   (14) ADVISOR metric_key-NAMING (Pattern-Paritaet -> finance-Standard "schlicht"): ein alert-metric_key
#       in packages/<pkg>/db/migrations/R__fn_advisor_review.sql darf NIE mit dem eigenen Domaenen-Praefix
#       '<pkg>_' beginnen -- die Domaene traegt bereits die core.notification_state.source-Spalte
#       ('advisor:<domain>[:pid]'), ein Praefix im Key ist redundant (finance = schlicht; career/estate
#       harmonisiert). Deckt BEIDE Emit-Formen (jsonb 'metric_key','...' + fn_staleness_alert('...')).
#       Rezidiv-Guard des Naming-Drifts (Owner-Befund).
#   (15)/(16) FAKTEN-SCHICHT — s. die Bloecke unten.
#   (17) E2E-HOOK (Phase B, docs/package-contract.md §6): jedes Nicht-Core-Paket mit eigenem Schema definiert den
#       Konventions-Hook <pkg>.fn_clear_e2e_data(text) (der Core-Dispatcher RAISEt sonst zur Laufzeit).
#   (18) MONITOR-METHODEN-BLOCK (Phase B, §3.9): monitor_acquisition_methods — Methoden-Name (Form, kein Builtin,
#       global eindeutig), acquire_fn/validate_fn im eigenen Schema UND in den Paket-R__ definiert, label +
#       params_description nicht leer, keine Backticks/'${' (beides wird in Workflow-Texte gebacken).
#   (19) AGENTEN-ROUTING (Phase C): provides.agents aller Manifeste inkl. core ueber die mit build.ps1 GETEILTE
#       Funktion scripts/build/lib/agent_routing.ps1 — Pflicht-router_description (kein Agent ausser orchestrator
#       ohne Routing-Wissen), agent.<x>-Verweise in Beschreibungen sind deklarierte Agenten, fallback_for
#       (Liste, erlaubte Art, nicht am orchestrator, je Art hoechstens ein Agent). Selbst-Asserts.
#   (19b) ONBOARDING-REIHENFOLGE: die aus consumes abgeleitete Paket-Reihenfolge (Get-OnboardingPackageOrder, geteilt mit
#       build.ps1) laesst sich bilden (kein Zyklus). Selbst-Asserts (Konsument nach Lieferant, Tie-Break, Zyklus).
#   (20) UTF-8-PFLICHT BEI DB-ANLAGE (v0.4.1): jede createdb / CREATE DATABASE / pg_createcluster / initdb-Anweisung
#       in provisioning/ + packages/ + scripts/ (Test-DBs = Prod-Paritaet) nennt UTF8 ausdruecklich — sonst erbt sie
#       die Systemsprache (Proxmox: LANG="C" -> SQL_ASCII). SQL-Anweisungen bis `;`, Shell mit `\`-Fortsetzung.
#       Selbst-Asserts.
#   (21) ECHTE UMLAUTE IN SICHTBAREN TEXTEN (Textkatalog-Feature): nutzer-sichtbare Manifest-Felder (display_name,
#       summary, cron_labels.*, commands.list[].description, catalog.categories[].description, catalog.tail[].title/body,
#       config.*.*.summary), onboarding/sections.json-Labels und die SQL-String-Literale der R__-fns (ausserhalb von
#       Kommentaren; nur Literale mit Leerzeichen oder Grossbuchstabe = Text, nicht Identifier/Enum-Wert) tragen keine
#       Ersatzschreibweise (scripts/build/lib/umlaut.ps1 + umlaut_allowlist.json). Workflow-Texte prueft workflow_lint,
#       den Katalog locale_lint.
#   (22) JQ-BOOL-DEFAULT: kein `// true` in provisioning/scripts-Shell (ersetzt ein gesetztes false).
#   (23) GH-DOWNLOAD-SPIEGEL: der `# >>> gh-download`-Block (Release-Download) ist in provisioning/install.sh und
#       provisioning/lib/fetch_release.sh byte-gleich.
#   (24) RELEASE-KEY-SPIEGEL: RELEASE_KEY_B64 in provisioning/install.sh = base64 von provisioning/keys/release-signing.gpg.
#   (25) PERSONA-STIL-PARITAET: je Persona aus personas.list (ausser neutral) genau ein '### <code>'-Abschnitt in
#       packages/core/contexts/persona_styles.md und umgekehrt.
#   (26) LLM-RECHNET-HINWEIS (Warnung): $fromAI-Descriptions mit Rechen-Verben (compute/calculate/convert/...) — das
#       Modell soll Roh-Werte liefern, die fn rechnet (.claude/rules/sql.md "Keine ableitbaren Spalten").
#   (27) ROHER DATUMS-CAST IM TOOL-SQL: kein Tool-Build (packages/*/build/workflows/**/*.ps1) castet ein Feld des
#       Tool-Payloads ($1::jsonb->>'k') direkt nach date — das Feld kann relativ sein ("yesterday"); aufloesen ueber
#       core.fn_resolve_date bzw. die Write-fn (core.fn_resolve_input_dates). Spiegel des DB-Guards
#       tests/db/finance/test_fn_relative_dates.sql fuer Inline-SQL. Selbst-Asserts.
#
# Gerichtete Checks (Payload SUBSET-OF fn-Reads), bewusst KEINE Gleichheit: fns lesen auch
# berechnete/aufgeloeste Keys, die kein Tool sendet. Umgekehrte Luecken (deklarierter
# Trigger-Input, den KEIN Aufrufer liefert) sind nur WARNUNG (mehrere Aufrufer, optionale Felder).
#
# Usage:  .\scripts\contract_lint.ps1 [-Verbose]
# Exit-Code = Anzahl Errors (Warnungen zaehlen nicht).
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot  = git -C $PSScriptRoot rev-parse --show-toplevel

$errors = New-Object System.Collections.Generic.List[string]
$warns  = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------
# Quellen laden
# ---------------------------------------------------------------
# Paket-bewusst: jedes Paket besitzt seine Workflows unter packages/<pkg>/workflows/.
$wfGlobs = @((Join-Path $RepoRoot 'packages\*\workflows\*.json'))
$wfFiles = Get-ChildItem $wfGlobs -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '_*' }
$workflows = @{}   # id -> @{ Name; Json; File }
$wfIdDupes = @()   # Check 16(d): dieselbe id in zwei Dateien (z. B. Rename ohne git mv) -> import:workflow nimmt eine still
foreach ($f in $wfFiles) {
    $j = [System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom) | ConvertFrom-Json
    if ($j.id -and $workflows.ContainsKey($j.id)) { $wfIdDupes += "$($j.id): $($workflows[$j.id].File) + $($f.Name)" }
    if ($j.id) { $workflows[$j.id] = @{ Name = $j.name; Json = $j; File = $f.Name } }
}

# Bekannte Functions: eine Datei pro fn (packages/*/db/migrations/R__fn_*.sql, Flyway-Repeatable) +
# CREATE FUNCTION in allen packages/*/db/**/*.sql.
# fnBodies: nur fuer fns mit EIGENER Datei (1 fn = 1 Datei -> Datei-Inhalt = Read-Quelle).
# Key = fn_<name> (R__-Praefix abgestreift), damit fn-in-fn-Aufrufe (fn_x(…)) matchen.
$fnKnown  = New-Object System.Collections.Generic.HashSet[string]
$fnBodies = @{}
$rFnGlobs = @((Join-Path $RepoRoot 'packages\*\db\migrations\R__fn_*.sql'))
foreach ($f in (Get-ChildItem $rFnGlobs -File -ErrorAction SilentlyContinue)) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($f.Name) -replace '^R__', ''
    [void]$fnKnown.Add($name)
    $fnBodies[$name] = [System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom)
}
# CREATE FUNCTION in allen *.sql: packages/*/db/ rekursiv.
$sqlScanDirs = @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'db' } | Where-Object { Test-Path $_ })
foreach ($f in (Get-ChildItem $sqlScanDirs -Recurse -Filter '*.sql' -ErrorAction SilentlyContinue)) {
    $sql = [System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom)
    foreach ($m in [regex]::Matches($sql, '(?im)CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:[a-z0-9_]+)\.([a-z0-9_]+)')) {
        [void]$fnKnown.Add($m.Groups[1].Value)
    }
}

# schema-Praefixe fuer die fn-Referenz- (Check 1) + Cron-Context-Write- (Check 9) Regexes: die Host-Schemas
# agent/core PLUS die Domaenen-Paket-Schemas (manifest.schema) -> generisch, damit finance./career.-fn-Aufrufe
# sichtbar sind (frueher hartkodiert nur agent|core -> ~113 Domaenen-Aufrufe unsichtbar). Muster wie $pkgBySchema
# (weiter unten fuer Check 6b), hier nur die Schema-NAMEN vorab, da Check 1 im ersten Workflow-Loop laeuft.
$schemaSet = New-Object System.Collections.Generic.HashSet[string]
[void]$schemaSet.Add('agent'); [void]$schemaSet.Add('core')
foreach ($pdir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory -ErrorAction SilentlyContinue)) {
    $mfPath = Join-Path $pdir.FullName 'manifest.json'
    if (Test-Path $mfPath) {
        $mfJson = [System.IO.File]::ReadAllText($mfPath, $Utf8NoBom) | ConvertFrom-Json
        if ($mfJson.schema) { [void]$schemaSet.Add([string]$mfJson.schema) }
    }
}
$schemaPrefixAlt = (@($schemaSet) -join '|')   # z. B. agent|core|finance|career
# Konkatenation (nicht String-Interpolation): PSScriptAnalyzer erkennt die $schemaPrefixAlt-Nutzung so verlaesslich.
$fnRefRe = '(?:' + $schemaPrefixAlt + ')\.(fn_[a-z0-9_]+)\s*\('

# ---------------------------------------------------------------
# Helper
# ---------------------------------------------------------------
# Top-Level-Keys aus dem Inneren von JSON.stringify({ ... }) extrahieren.
# Depth-/String-aware Scan: Werte sind JS-Ausdruecke (enthalten :, Klammern, Strings).
function Get-StringifyKey([string]$Inner) {
    $keys = @()
    $depth = 0; $inStr = $null; $token = ''
    for ($i = 0; $i -lt $Inner.Length; $i++) {
        $c = $Inner[$i]
        if ($inStr) {
            if ($c -eq '\') { $i++; continue }
            if ($c -eq $inStr) { $inStr = $null }
            continue
        }
        switch -regex ([string]$c) {
            "[`"'``]"   { $inStr = $c; $token = ''; continue }
            '[\(\[\{]'  { $depth++; $token = ''; continue }
            '[\)\]\}]'  { $depth--; $token = ''; continue }
        }
        if ($depth -gt 0) { continue }
        if ($c -eq ',') { $token = ''; continue }
        if ($c -eq ':') {
            $t = $token.Trim()
            if ($t -match '^[A-Za-z_][A-Za-z0-9_]*$') { $keys += $t }
            $token = ''
            continue
        }
        $token += $c
    }
    return $keys
}

# Alle in einem SQL-/Query-Text GELESENEN jsonb-Keys (Ueberapproximation ist ok: der Check ist
# gerichtet, mehr erkannte Reads koennen nur False-Negatives ergeben, nie False-Positives).
function Get-JsonbReadKey([string]$Text) {
    $r = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in [regex]::Matches($Text, "->>?\s*'([A-Za-z0-9_]+)'"))   { [void]$r.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($Text, "\?\s*'([A-Za-z0-9_]+)'"))     { [void]$r.Add($m.Groups[1].Value) }
    return ,$r   # Komma-Operator: PS 5.1 wuerde das HashSet sonst beim Return enumerieren
}

# Reads eines SQL-Texts INKLUSIVE transitiv aufgerufener fn_*-Bodies (fn delegiert p oft an
# Helper-fns, z. B. fn_create_savings_goal -> fn_savings_rate_schedule). $null = nicht
# entscheidbar (eine beteiligte fn hat keine eigene Datei in packages/*/db/migrations/R__fn_*.sql).
function Get-TransitiveReadKey([string]$Text) {
    $reads = Get-JsonbReadKey $Text
    $visited = New-Object System.Collections.Generic.HashSet[string]
    $queue = New-Object System.Collections.Generic.Queue[string]
    foreach ($m in [regex]::Matches($Text, '\b(fn_[a-z0-9_]+)\s*\(')) { $queue.Enqueue($m.Groups[1].Value) }
    while ($queue.Count -gt 0) {
        $fn = $queue.Dequeue()
        if (-not $visited.Add($fn)) { continue }
        if (-not $fnBodies.ContainsKey($fn)) { return $null }   # Body unbekannt (init.sql/UI) -> Check ueberspringen
        $body = $fnBodies[$fn]
        # Dynamischer Payload-Forwarder (z. B. core.fn_dispatch_callback: EXECUTE format('... %s($1)', v_fn) USING p):
        # reicht das GANZE jsonb-Payload an einen registry-aufgeloesten Handler weiter -> welche Keys der Handler
        # liest, ist statisch NICHT entscheidbar (der Handler-Name ist Daten, kein Literal) -> Check ueberspringen
        # (wie ein unbekannter Body, $null = undecidable). Verhindert einen False-Positive auf durchgereichte Keys.
        # Signal = dyn. `EXECUTE format(...)` (fn-Name ist Daten) + `USING p` (das Payload-jsonb heisst per
        # Projekt-Konvention exakt `p`; \bp\b matcht NICHT `p_domain` o. Ae. -> nur echte Voll-Payload-Forwarder).
        if ($body -match 'EXECUTE\s+format\s*\(' -and $body -match '\bUSING\s+p\b') { return $null }
        $reads.UnionWith((Get-JsonbReadKey $body))
        foreach ($m in [regex]::Matches($body, '\b(fn_[a-z0-9_]+)\s*\(')) {
            if (-not $visited.Contains($m.Groups[1].Value)) { $queue.Enqueue($m.Groups[1].Value) }
        }
    }
    return ,$reads
}

# Paket-Tool-Service '<pkg>:<alias>' -> Objekt-Form-Spezifikation aus packages/<pkg>/manifest.json provides.services
# ({workflow, description, permission, inputs}) oder $null (fehlt / String-Form / kein Manifest). Gecacht.
$script:svcSpecCache = @{}
function Get-ServiceSpec([string]$Ref) {
    if ($script:svcSpecCache.ContainsKey($Ref)) { return $script:svcSpecCache[$Ref] }
    $spec = $null
    if ($Ref -match '^([a-z][a-z0-9_]*):([a-z][a-z0-9_]*)$') {
        $mfp = Join-Path $RepoRoot "packages\$($Matches[1])\manifest.json"
        $alias = $Matches[2]
        if (Test-Path $mfp) {
            $mj = [System.IO.File]::ReadAllText($mfp, $Utf8NoBom) | ConvertFrom-Json
            $s = if ($mj.provides -and $mj.provides.services) { $mj.provides.services.$alias } else { $null }
            if ($null -ne $s -and $s -isnot [string] -and $s.workflow) { $spec = $s }
        }
    }
    $script:svcSpecCache[$Ref] = $spec
    return $spec
}

function Get-TriggerInput($WfJson) {
    $trig = $WfJson.nodes | Where-Object { $_.type -eq 'n8n-nodes-base.executeWorkflowTrigger' } | Select-Object -First 1
    if (-not $trig) { return $null }
    return @($trig.parameters.workflowInputs.values | ForEach-Object { $_.name })
}

# ---------------------------------------------------------------
# Checks je Workflow
# ---------------------------------------------------------------
# Caller-Abdeckung sammeln fuer die Reverse-Warnung: targetId -> Set gelieferter Input-Keys
$supplied = @{}

foreach ($id in $workflows.Keys) {
    $wf = $workflows[$id].Json
    $wfName = $workflows[$id].Name

    foreach ($n in $wf.nodes) {
        if ($n.type -eq 'n8n-nodes-base.stickyNote') { continue }

        # --- Postgres-Nodes: (1) tote fn-Refs, (2) Payload-Keys, (5) jsonb-Standard ---
        if ($n.type -in @('n8n-nodes-base.postgres', 'n8n-nodes-base.postgresTool')) {
            $query = "$($n.parameters.query)"
            foreach ($m in [regex]::Matches($query, $fnRefRe)) {
                $fn = $m.Groups[1].Value
                if (-not $fnKnown.Contains($fn)) {
                    $errors.Add("TOTE fn-REFERENZ: $wfName :: $($n.name) ruft '$fn' -- keine Definition in packages/*/db/ gefunden.")
                }
            }
            $qr = "$($n.parameters.options.queryReplacement)"
            if ($qr) {
                if ($qr -match '(?s)^=\{\{\s*JSON\.stringify\(\{(.*)\}\)\s*\}\}\s*$') {
                    $payloadKeys = Get-StringifyKey $Matches[1]
                    $reads = Get-TransitiveReadKey $query
                    if ($null -ne $reads) {
                        foreach ($k in $payloadKeys) {
                            if (-not $reads.Contains($k)) {
                                $errors.Add("UNGELESENER PAYLOAD-KEY: $wfName :: $($n.name) sendet '$k', aber weder Query noch aufgerufene fn (transitiv) liest ihn (still ignoriert).")
                            }
                        }
                    }
                } else {
                    $errors.Add("jsonb-STANDARD VERLETZT: $wfName :: $($n.name) hat queryReplacement, das kein ={{ JSON.stringify({...}) }} ist (positionale Parameter = Leer-Drop/Shift-Klasse).")
                }
            }
        }

        # --- Aufrufer-Nodes: (3) Inputs gegen Ziel-Trigger, (4) $fromAI-Hygiene ---
        $isToolWf = ($n.type -eq '@n8n/n8n-nodes-langchain.toolWorkflow')
        $isExecWf = ($n.type -eq 'n8n-nodes-base.executeWorkflow')
        if ($isToolWf -or $isExecWf) {
            $targetId = "$($n.parameters.workflowId.value)"
            $bind = $n.parameters.workflowInputs.value
            $bindKeys = @()
            if ($bind) { $bindKeys = @($bind.PSObject.Properties | ForEach-Object { $_.Name }) }

            # Vermittler-Kante (Install-UX-Phase 4): ruft ein Core-Workflow agent.sub_dispatch_agent mit einer festen
            # workflow_id-DATEN-Eingabe, ist das ECHTE Ziel dieser Agent — sein Trigger muss die Eingaben kennen, die
            # der Vermittler durchreicht (task/chat_id/call_depth). Ersetzt die statische Kante, die durch den
            # Ausdrucks-Aufruf im Vermittler sonst verloren ginge (dort nur "ZIEL NICHT IM STATE"). Eine Ausdrucks-
            # workflow_id (Test-Harness: Ziel kommt aus dem Request-Body) ist statisch nicht aufloesbar -> uebersprungen.
            if ($targetId -and $workflows.ContainsKey($targetId) -and $workflows[$targetId].Name -eq 'agent.sub_dispatch_agent' -and $bind -and $bind.workflow_id -and -not "$($bind.workflow_id)".StartsWith("=")) {
                $realId = "$($bind.workflow_id)"
                if (-not $workflows.ContainsKey($realId)) {
                    $errors.Add("VERMITTLER-ZIEL FEHLT: $wfName :: $($n.name) uebergibt workflow_id '$realId', die im State nicht existiert.")
                } else {
                    $rtin = Get-TriggerInput $workflows[$realId].Json
                    foreach ($k in @('task', 'chat_id', 'call_depth')) {
                        if ($null -ne $rtin -and $rtin -notcontains $k) {
                            $errors.Add("VERMITTLER-INPUT GEHT INS LEERE: $wfName :: $($n.name) -> '$($workflows[$realId].Name)' deklariert '$k' nicht im Start-Trigger (der Vermittler reicht es durch).")
                        }
                    }
                }
            }
            if ($wfName -eq 'agent.sub_dispatch_agent' -and $n.name -eq 'Run agent') { $targetId = '' }   # Ausdrucks-Ziel: geprueft ueber die Vermittler-Kante oben

            # Werkzeug-Vermittler-Kante (paperless Phase 2): ruft ein Agent agent.sub_dispatch_tool mit FESTEM
            # service='<pkg>:<alias>', ist das echte Ziel das Paket-Werkzeug aus dem Provider-Manifest — es muss
            # existieren, dem Provider-Paket gehoeren und genau args + chat_id im Start-Trigger deklarieren.
            $isDispatchTool = ($targetId -and $workflows.ContainsKey($targetId) -and $workflows[$targetId].Name -eq 'agent.sub_dispatch_tool' -and $bind -and $bind.service -and -not "$($bind.service)".StartsWith('='))
            $svcSpec = $null
            if ($isDispatchTool) {
                $svcSpec = Get-ServiceSpec "$($bind.service)"
                if ($null -eq $svcSpec) {
                    $errors.Add("WERKZEUG-VERMITTLER: $wfName :: $($n.name) bindet service '$($bind.service)', den kein Provider-Manifest (provides.services, Objekt-Form) deklariert.")
                } else {
                    $realName = "$($svcSpec.workflow)"
                    $real = @($workflows.Values | Where-Object { $_.Name -eq $realName })
                    if ($real.Count -ne 1) {
                        $errors.Add("WERKZEUG-VERMITTLER-ZIEL FEHLT: $wfName :: $($n.name) -> service '$($bind.service)' zeigt auf '$realName' ($($real.Count) Workflows im State).")
                    } else {
                        $rtin = @(Get-TriggerInput $real[0].Json)
                        if (($rtin | Sort-Object) -join ',' -ne 'args,chat_id') {
                            $errors.Add("WERKZEUG-VERMITTLER-INPUT: '$realName' muss genau args + chat_id im Start-Trigger deklarieren (hat: $($rtin -join ', ')) — der Vermittler reicht nur diese durch.")
                        }
                    }
                }
            }
            if ($wfName -eq 'agent.sub_dispatch_tool' -and $n.name -eq 'Run tool') { $targetId = '' }    # Ausdrucks-Ziel aus core.services: geprueft ueber die Werkzeug-Vermittler-Kante oben

            if ($targetId -and $workflows.ContainsKey($targetId)) {
                $tin = Get-TriggerInput $workflows[$targetId].Json
                if ($null -ne $tin) {
                    foreach ($k in $bindKeys) {
                        if ($tin -notcontains $k) {
                            $errors.Add("INPUT GEHT INS LEERE: $wfName :: $($n.name) bindet '$k', aber Ziel '$($workflows[$targetId].Name)' deklariert es nicht im Start-Trigger (n8n verwirft es still).")
                        }
                    }
                    if (-not $supplied.ContainsKey($targetId)) { $supplied[$targetId] = New-Object System.Collections.Generic.HashSet[string] }
                    foreach ($k in $bindKeys) { [void]$supplied[$targetId].Add($k) }
                }
            } elseif ($targetId) {
                $warns.Add("ZIEL NICHT IM STATE: $wfName :: $($n.name) -> Workflow-Id '$targetId' nicht im State packages/*/workflows (UI-only/Infra?).")
            }

            if ($bind) {
                foreach ($p in $bind.PSObject.Properties) {
                    $v = "$($p.Value)"
                    if ($v -notmatch '\$fromAI\(') { continue }
                    # Werkzeug-Vermittler: args = JSON.stringify({ k: $fromAI('k', …), … }) — JEDER Treffer wird geprueft
                    # (Key == Objekt-Schluessel, Key in den Provider-inputs, Identitaetsfelder verboten, *_id nie number).
                    if ($isDispatchTool -and $p.Name -eq 'args') {
                        # Kanonisch: <obj>: $fromAI('<key>', '<desc>', '<type>'[, '<default>' | <zahl>]) — Description in '…'
                        # (Klammern darin erlaubt); ein Apostroph in der Description bricht das Muster -> Zaehl-Abgleich schlaegt an.
                        $hits = [regex]::Matches($v, "(?<obj>[A-Za-z0-9_]+):\s*\`$fromAI\('(?<key>[A-Za-z0-9_]+)',\s*'[^']*',\s*'(?<type>[a-z]+)'(?:,\s*(?:'[^']*'|-?[0-9.]+))?\s*\)")
                        if ($hits.Count -ne ([regex]::Matches($v, '\$fromAI\(')).Count) {
                            $errors.Add("\$fromAI NICHT KANONISCH: $wfName :: $($n.name) Feld 'args' -- jedes \$fromAI muss als '<key>: \$fromAI(''key'', ''desc'', ''type''[, default])' stehen (Apostroph in einer Description?).")
                        }
                        foreach ($h in $hits) {
                            $key = $h.Groups['key'].Value; $type = $h.Groups['type'].Value
                            if ($key -ne $h.Groups['obj'].Value) { $errors.Add("\$fromAI-KEY-MISMATCH: $wfName :: $($n.name) args.$($h.Groups['obj'].Value) nutzt \$fromAI-Key '$key'.") }
                            if ($key -in @('person_id', 'chat_id')) { $errors.Add("SPOOFBARES IDENTITAETS-FELD: $wfName :: $($n.name) exponiert args.$key als \$fromAI -- Identitaet kommt aus der chat_id des Start-Nodes, nie vom LLM.") }
                            if ($key -match '_id$' -and $type -eq 'number') { $errors.Add("ID ALS NUMBER: $wfName :: $($n.name) args.$key ist \$fromAI-Typ 'number' -- IDs immer als 'string'.") }
                            if ($null -ne $svcSpec -and -not ($svcSpec.inputs.PSObject.Properties.Name -contains $key)) {
                                $errors.Add("WERKZEUG-INPUT UNBEKANNT: $wfName :: $($n.name) args.$key ist kein inputs-Feld von '$($bind.service)' im Provider-Manifest.")
                            }
                        }
                        continue
                    }
                    # P2b-2 Spoof-Enforcement: Identitaets-/Trusted-only-Felder duerfen NIE als $fromAI-Tool-Input
                    # exponiert werden — sonst koennte das LLM eine FREMDE person_id spoofen. person_id wird IMMER
                    # server-seitig aufgeloest (fn_resolve_sender aus chat_id ODER trusted Cron, R__fn_record_job_match
                    # "-- TRUSTED CRON ONLY") — nie vom Modell geliefert. Strukturelle Absicherung des Kommentar-Vertrags.
                    if ($p.Name -in @('person_id')) {
                        $errors.Add("SPOOFBARES IDENTITAETS-FELD: $wfName :: $($n.name) exponiert '$($p.Name)' als \$fromAI-Tool-Input -- Identitaet wird server-seitig aufgeloest (chat_id/trusted cron), NIE vom LLM. Feld aus dem Tool-Schema entfernen.")
                        continue
                    }
                    # Description darf '...'-quoted (Builder) ODER backtick-quoted (n8n-UI-Override) sein.
                    if ($v -notmatch "\`$fromAI\('(?<key>[A-Za-z0-9_]+)',\s*('(?<desc>[^']*)'|``[^``]*``),\s*'(?<type>[a-z]+)'") {
                        $errors.Add("\$fromAI NICHT KANONISCH: $wfName :: $($n.name) Feld '$($p.Name)' -- vermutlich Apostroph in der Description (bricht den \$fromAI-Parser).")
                        continue
                    }
                    $key = $Matches['key']; $type = $Matches['type']; $desc = "$($Matches['desc'])"
                    if ($key -ne $p.Name) {
                        $errors.Add("\$fromAI-KEY-MISMATCH: $wfName :: $($n.name) Feld '$($p.Name)' nutzt \$fromAI-Key '$key'.")
                    }
                    # (26) LLM-RECHNET-HINWEIS (nur Warnung, Ratchet-Kandidat): eine Description, die das Modell zum Rechnen/
                    # Umrechnen auffordert, verletzt "Das LLM rechnet nicht" (.claude/rules/sql.md) -> Roh-Wert nehmen, die fn rechnet.
                    # Verneinte Form ("never compute a date yourself", Get-DateParamHint) ist das Gegenteil -> keine Warnung.
                    if ($desc -match '(?i)(?<!\b(?:never|not|don''t|do not)\s+)\b(compute|calculate|convert|multiply|annuali[sz]e|work out|sum up|add up)\b') {
                        $warns.Add("LLM-RECHNET?: $wfName :: $($n.name) Feld '$key' -- Description fordert das Modell zum Rechnen auf ('$($Matches[1])'); Roh-Wert annehmen und in der fn ableiten.")
                    }
                    if ($key -match '_id$' -and $type -eq 'number') {
                        $errors.Add("ID ALS NUMBER: $wfName :: $($n.name) Feld '$key' ist \$fromAI-Typ 'number' -- LLM-quotierte IDs werden vom Schema rejected; IDs immer als 'string' (fn castet).")
                    }
                }
            }
        }
    }
}

# --- Reverse-Warnung: deklarierte Trigger-Inputs, die KEIN Aufrufer liefert ---
foreach ($targetId in $supplied.Keys) {
    $tin = Get-TriggerInput $workflows[$targetId].Json
    if ($null -eq $tin) { continue }
    foreach ($t in $tin) {
        if ($t -eq 'chat_id') { continue }   # wird strukturell immer mitgefuehrt (Build-Trigger)
        if (-not $supplied[$targetId].Contains($t)) {
            $warns.Add("UNBELIEFERTER TRIGGER-INPUT: '$($workflows[$targetId].Name)' deklariert '$t', kein getrackter Aufrufer bindet es (kommt als undefined an, falls genutzt).")
        }
    }
}

# ---------------------------------------------------------------
# (6) SERVICE-ALIAS (D9 / SC1): Pakete referenzieren Core-Dienste ueber den logischen Alias
#     'core:<name>'. Der Build-Resolver (Resolve-CoreServiceAlias) loest ihn aus dem core-Manifest
#     (provides.services) auf. Dieser Lint haelt den Vertrag statisch ehrlich:
#       - Provider-Integritaet: jeder provides.services-Wert trifft einen existierenden Core-Workflow.
#       - Consumer-Integritaet: jeder consumes.services-Eintrag (Form 'core:<alias>') ist ein realer Dienst.
#       - Referenz-Scan: jedes 'core:<alias>'-Token in den Build-Defs ist deklariert; ein Nicht-Core-Paket darf
#         nur Aliase nutzen, die sein manifest.json consumes.services fuehrt (Allow-Liste; Paket = physischer Ort).
#     Anders als (1)-(5) scannt dies die .ps1-Build-Defs (die core:-Tokens werden build-time wegaufgeloest,
#     erscheinen also NICHT im generierten JSON).
#     Paket-Tool-Services (paperless Phase 2): ein Nicht-Core-Paket deklariert Werkzeuge in Objekt-Form, Konsumenten
#     abonnieren '<paket>:<alias>' (gegen das Provider-Manifest geprueft, nie das eigene Paket); gebunden werden sie
#     nur ueber agent.sub_dispatch_tool (Add-ServiceTools) — die literale Bindung ist als Pruefstellen-Bypass verboten.
# ---------------------------------------------------------------
$pkgDir = Join-Path $RepoRoot 'packages'
function Read-Manifest([string]$Pkg) {
    $mf = Join-Path $pkgDir "$Pkg\manifest.json"
    if (-not (Test-Path $mf)) { return $null }
    return ([System.IO.File]::ReadAllText($mf, $Utf8NoBom) | ConvertFrom-Json)
}
$coreMf = Read-Manifest 'core'
if ($null -eq $coreMf) {
    $errors.Add("SERVICE-ALIAS: packages/core/manifest.json nicht lesbar -- D9-Lint kann nicht laufen.")
} else {
    # Provider-Aliase + ihre Workflow-Namen aus provides.services.
    $providerAliases = @{}   # alias -> workflow-name
    if ($coreMf.provides.PSObject.Properties.Name -contains 'services') {
        foreach ($p in $coreMf.provides.services.PSObject.Properties) { $providerAliases[$p.Name] = $p.Value }
    }
    # Zaehlung der Workflow-Namen (ROH, aus den geparsten JSONs per .name) fuer die Provider-Integritaet.
    # Nicht dedupliziert (HashSet) -> ein doppelter .name ist erkennbar (WS-B6: _seed_services loest
    # provides.services-Wert -> .name -> .id auf; Mehrdeutigkeit = id-Kollision).
    $wfNameCounts = @{}
    foreach ($w in $workflows.Values) {
        if ($w.Name) { if ($wfNameCounts.ContainsKey($w.Name)) { $wfNameCounts[$w.Name]++ } else { $wfNameCounts[$w.Name] = 1 } }
    }

    # Provider-Integritaet (WS-B6: GENAU EINS): jeder deklarierte Dienst zeigt auf genau einen Core-Workflow.
    #   0 Treffer = tote Referenz; >1 = mehrdeutige name->id-Aufloesung (core.services-Seed waere nicht eindeutig).
    foreach ($alias in $providerAliases.Keys) {
        $wn = $providerAliases[$alias]
        $cnt = if ($wfNameCounts.ContainsKey($wn)) { $wfNameCounts[$wn] } else { 0 }
        if ($cnt -eq 0) {
            $errors.Add("SERVICE-ALIAS Provider: core provides.services['$alias'] -> '$wn' trifft keinen getrackten Workflow.")
        } elseif ($cnt -gt 1) {
            $errors.Add("SERVICE-ALIAS Provider: core provides.services['$alias'] -> '$wn' ist MEHRDEUTIG ($cnt Workflows gleichen Namens) -- _seed_services-Aufloesung waere nicht eindeutig.")
        }
    }

    # Consumer-Integritaet: jeder consumes.services-Eintrag jedes Pakets ist 'core:<alias>' mit realem alias.
    # Zugleich je Paket die erlaubte Alias-Menge (Allow-Liste) fuer den Referenz-Scan aufbauen.
    $consumesByPkg = @{}   # pkg -> HashSet der erlaubten 'core:<alias>'-Tokens
    foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue)) {
        $pkg = $pdir.Name
        $mf  = Read-Manifest $pkg
        $allow = New-Object System.Collections.Generic.HashSet[string]
        if ($null -ne $mf -and $mf.consumes -and ($mf.consumes.PSObject.Properties.Name -contains 'services')) {
            foreach ($entry in @($mf.consumes.services)) {
                if ($entry -notmatch '^([a-z][a-z0-9_]*):([a-z][a-z0-9_]*)$') {
                    $errors.Add("SERVICE-ALIAS Consumer: $pkg consumes.services-Eintrag '$entry' hat nicht die Form '<paket>:<name>'.")
                    continue
                }
                $prov = $Matches[1]; $alias = $Matches[2]
                if ($prov -eq 'core') {
                    if (-not $providerAliases.ContainsKey($alias)) {
                        $errors.Add("SERVICE-ALIAS Consumer: $pkg consumes.services fuehrt '$entry', aber core provides.services kennt '$alias' nicht.")
                    }
                } elseif ($prov -eq $pkg) {
                    $errors.Add("SERVICE-ALIAS Consumer: $pkg consumes.services nennt das eigene Paket ('$entry') -- eigene Werkzeuge bindet Add-ServiceTools -Own.")
                } elseif ($null -eq (Get-ServiceSpec $entry)) {
                    $errors.Add("SERVICE-ALIAS Consumer: $pkg consumes.services fuehrt '$entry', aber packages/$prov/manifest.json provides.services deklariert '$alias' nicht in Objekt-Form.")
                }
                [void]$allow.Add($entry)
            }
        }
        $consumesByPkg[$pkg] = $allow
    }

    # Paket-Tool-Services (Nicht-Core, Objekt-Form; docs/package-contract.md §5): Provider-Integritaet je Eintrag —
    # Ziel ist GENAU EIN Workflow DES EIGENEN Pakets (agent.<pkg>.*), permission ist eine der drei Stufen (DB-CHECK
    # core.services), jede inputs-Beschreibung ist $fromAI-tauglich (kein ' / Backtick), Typ string|number, *_id nie
    # number, keine Identitaetsfelder. Core bleibt String-Form.
    $serviceWorkflows = @{}   # Workflow-Name -> '<pkg>:<alias>' (fuer den Umgehungs-Check unten)
    foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue)) {
        $pkg = $pdir.Name
        if ($pkg -eq 'core') { continue }
        $mf = Read-Manifest $pkg
        if ($null -eq $mf -or -not $mf.provides -or -not ($mf.provides.PSObject.Properties.Name -contains 'services')) { continue }
        if ($mf.provides.services -is [array]) {
            if (@($mf.provides.services).Count -gt 0) { $errors.Add("SERVICE-PROVIDER: $pkg provides.services muss ein Objekt { <alias>: {...} } sein.") }
            continue
        }
        foreach ($sp in $mf.provides.services.PSObject.Properties) {
            if ($sp.Name -like '_*') { continue }
            $ref = "${pkg}:$($sp.Name)"; $s = $sp.Value
            if ($s -is [string] -or -not $s.workflow) { $errors.Add("SERVICE-PROVIDER: $ref muss Objekt-Form {workflow, description, permission, inputs} haben (String-Form nur fuer core)."); continue }
            $wn = "$($s.workflow)"
            if ($wn -notlike "agent.$pkg.*") { $errors.Add("SERVICE-PROVIDER: $ref zeigt auf '$wn' -- ein Paket-Service muss ein eigener Workflow agent.$pkg.* sein.") }
            $cnt = if ($wfNameCounts.ContainsKey($wn)) { $wfNameCounts[$wn] } else { 0 }
            if ($cnt -ne 1) { $errors.Add("SERVICE-PROVIDER: $ref -> '$wn' trifft $cnt getrackte Workflows (erwartet genau 1).") }
            $serviceWorkflows[$wn] = $ref
            if ([string]::IsNullOrWhiteSpace("$($s.description)")) { $errors.Add("SERVICE-PROVIDER: $ref ohne description (wird die Tool-Description im Agenten).") }
            if ("$($s.permission)" -notin @('all_members', 'adults_only', 'owner_only')) { $errors.Add("SERVICE-PROVIDER: $ref permission '$($s.permission)' ist nicht all_members|adults_only|owner_only.") }
            $inProps = @(if ($s.inputs) { $s.inputs.PSObject.Properties })
            if ($inProps.Count -eq 0) { $errors.Add("SERVICE-PROVIDER: $ref ohne inputs.") }
            foreach ($ip in $inProps) {
                $d = "$($ip.Value.description)"; $t = "$($ip.Value.type)"
                if ([string]::IsNullOrWhiteSpace($d) -or $d -match "['``]") { $errors.Add("SERVICE-PROVIDER: $ref inputs.$($ip.Name): description leer oder mit ' / Backtick (bricht das \$fromAI-Literal).") }
                if ($t -notin @('string', 'number')) { $errors.Add("SERVICE-PROVIDER: $ref inputs.$($ip.Name): type '$t' (erlaubt string|number).") }
                if ($ip.Name -match '_id$' -and $t -eq 'number') { $errors.Add("ID ALS NUMBER: $ref inputs.$($ip.Name) -- IDs immer als string.") }
                if ($ip.Name -in @('person_id', 'chat_id')) { $errors.Add("SPOOFBARES IDENTITAETS-FELD: $ref inputs.$($ip.Name) -- Identitaet kommt aus der chat_id, nie vom LLM.") }
            }
        }
    }

    # Kein Umgehen der Pruefstelle: ein Paket-Service-Workflow wird NUR ueber agent.sub_dispatch_tool (Laufzeit-
    # Lookup in core.services, Pruefung in core.fn_resolve_service) erreicht — eine literale Bindung ausserhalb der
    # Test-Harnesses waere ein Bypass von Paket-Status + Berechtigung.
    $serviceIds = @{}
    foreach ($wid in $workflows.Keys) { if ($serviceWorkflows.ContainsKey($workflows[$wid].Name)) { $serviceIds[$wid] = $workflows[$wid].Name } }
    foreach ($wid in $workflows.Keys) {
        $callerName = $workflows[$wid].Name
        if ($callerName -like '*.test_harness') { continue }
        foreach ($n in $workflows[$wid].Json.nodes) {
            if ($n.type -notin @('@n8n/n8n-nodes-langchain.toolWorkflow', 'n8n-nodes-base.executeWorkflow')) { continue }
            $tid = "$($n.parameters.workflowId.value)"
            if ($serviceIds.ContainsKey($tid)) {
                $errors.Add("PRUEFSTELLE UMGANGEN: $callerName :: $($n.name) bindet den Paket-Service-Workflow '$($serviceIds[$tid])' literal -- nur ueber agent.sub_dispatch_tool (Add-ServiceTools).")
            }
        }
    }

    # Referenz-Scan der Build-Defs: 'core:<alias>'-Tokens als gequotetes String-Argument. Paket-uniform:
    # gescannt werden die Engine (scripts/build/: build.ps1 nutzt core:-Aliase als Orchestrator) UND die
    # paket-eigenen Build-Defs (packages/*/build/...). Die Resolver-Definitionsdatei ausschliessen (ihre
    # Regex-/Fehlertext-Literale sind keine Referenzen).
    $buildScanDirs = @((Join-Path $RepoRoot 'scripts\build')) +
                     @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory -ErrorAction SilentlyContinue |
                       ForEach-Object { Join-Path $_.FullName 'build' } | Where-Object { Test-Path $_ })
    foreach ($f in (Get-ChildItem $buildScanDirs -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
        if ($f.Name -eq 'workflow_lifecycle.ps1') { continue }
        $txt = [System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom)
        # Paket eines Build-Defs = sein physischer Ort (packages/<pkg>/build/... -> <pkg>; Engine in
        # scripts/build/ -> core, unconstrained). Ersetzt die alte agent.finance*-Heuristik UND den Core-Sonderfall.
        $pkg = if (($f.FullName -replace '\\','/') -match 'packages/([^/]+)/build/') { $Matches[1] } else { 'core' }
        foreach ($m in [regex]::Matches($txt, "['""]core:([a-z][a-z0-9_]*)['""]")) {
            $alias = $m.Groups[1].Value
            $token = "core:$alias"
            if (-not $providerAliases.ContainsKey($alias)) {
                $errors.Add("SERVICE-ALIAS Referenz: $($f.Name) nutzt '$token', aber core provides.services kennt den Dienst nicht.")
                continue
            }
            if ($pkg -ne 'core') {
                $allow = $consumesByPkg[$pkg]
                if ($null -eq $allow -or -not $allow.Contains($token)) {
                    $errors.Add("SERVICE-ALIAS SC1: $($f.Name) ($pkg) nutzt '$token', aber $pkg/manifest.json consumes.services deklariert ihn nicht.")
                }
            }
        }
    }
}

# ---------------------------------------------------------------
# (6b) CROSS-PACKAGE READS (WS-5): ein Paket darf eine FREMDE Paket-Lese-fn nur konsumieren, wenn der
#     PROVIDER sie in provides.reads veroeffentlicht (Spiegel zu consumes.reads). Optional-Dependency-
#     Konvention (docs/package-contract.md "Cross-package reads"): jeder consumes.reads-Eintrag, der NICHT
#     'core.*' ist, MUSS einen passenden provides.reads-Eintrag im Manifest des benannten Provider-Pakets
#     haben (fail-closed). 'core.*' ist exempt (Host-Lesefenster; Liveness deckt Check (1) toter-fn-Refs ab).
#     null-safe fuer Pakete OHNE provides.reads-Key. Die LAUFZEIT-Optionalitaet (Provider evtl. nicht
#     installiert) traegt der Doppel-Guard in der Consumer-fn (fn_package_active + to_regprocedure); hier
#     wird nur die statische Deklarations-Paritaet erzwungen (der Quellbaum hat alle Pakete).
# ---------------------------------------------------------------
# schema-Praefix -> Paketname (Domaenen-Paket: package == schema; robust aus dem Manifest-schema-Feld).
$pkgBySchema = @{}
foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue)) {
    $mf = Read-Manifest $pdir.Name
    if ($null -ne $mf -and $mf.schema) { $pkgBySchema[[string]$mf.schema] = $pdir.Name }
}
foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue)) {
    $pkg = $pdir.Name
    $mf  = Read-Manifest $pkg
    if ($null -eq $mf -or -not $mf.consumes -or -not ($mf.consumes.PSObject.Properties.Name -contains 'reads')) { continue }
    foreach ($entry in @($mf.consumes.reads)) {
        $e = [string]$entry
        if ($e -match '^core\.') { continue }   # core.* exempt (Host-Fenster; Check (1) deckt Liveness)
        if ($e -notmatch '^([a-z][a-z0-9_]*)\.') {
            $errors.Add("CROSS-PACKAGE-READS: $pkg consumes.reads-Eintrag '$e' ist nicht schema-qualifiziert (<schema>.fn...).")
            continue
        }
        $schema  = $Matches[1]
        $provPkg = $pkgBySchema[$schema]
        if ($null -eq $provPkg) {
            $errors.Add("CROSS-PACKAGE-READS: $pkg consumes.reads '$e' -> kein Paket besitzt Schema '$schema' (Provider/provides.reads fehlt).")
            continue
        }
        $provMf    = Read-Manifest $provPkg
        $provReads = @()
        if ($null -ne $provMf -and $provMf.provides -and ($provMf.provides.PSObject.Properties.Name -contains 'reads')) {
            $provReads = @($provMf.provides.reads | ForEach-Object { [string]$_ })
        }
        if ($provReads -notcontains $e) {
            $errors.Add("CROSS-PACKAGE-READS SC1: $pkg consumes.reads '$e', aber $provPkg/manifest.json provides.reads deklariert ihn nicht (fail-closed).")
        }
    }
}

# ---------------------------------------------------------------
# (7) CRON-ENABLE INTEGRITY (F9 / R1-MINOR): das Cron-Gate liest sein Enable-Flag build-time als
#     Literal core.fn_config_get('<pkg>','cron_enable','<key>'); der Seeder legt die Zeile nur an,
#     wenn das Paket-Manifest den Key deklariert (.config.cron_enable.<key>). Drift in eine Richtung
#     (Gate liest nicht-deklariertes Flag) -> stiller fail-closed; Drift andersrum (deklariertes Flag,
#     das kein Gate liest) -> tote Config. Scannt die Postgres-Node-Queries der getrackten Workflows
#     (das Literal ist eingebacken -> die provides.crons<->config-Namensentkopplung ist hier egal).
# ---------------------------------------------------------------
$cronEnableRefs = New-Object System.Collections.Generic.HashSet[string]   # "<pkg>|<key>" aus den Gate-Queries
foreach ($w in $workflows.Values) {
    foreach ($n in $w.Json.nodes) {
        if ($n.type -notin @('n8n-nodes-base.postgres', 'n8n-nodes-base.postgresTool')) { continue }
        $q = "$($n.parameters.query)"
        foreach ($m in [regex]::Matches($q, "fn_config_get\(\s*'([a-z][a-z0-9_]*)'\s*,\s*'cron_enable'\s*,\s*'([a-z][a-z0-9_]*)'\s*\)")) {
            [void]$cronEnableRefs.Add("$($m.Groups[1].Value)|$($m.Groups[2].Value)")
        }
    }
}
$cronEnableDeclared = New-Object System.Collections.Generic.HashSet[string]   # "<pkg>|<key>" aus den Manifesten
foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue)) {
    $mf = Read-Manifest $pdir.Name
    if ($null -eq $mf -or -not $mf.config -or -not ($mf.config.PSObject.Properties.Name -contains 'cron_enable')) { continue }
    foreach ($k in $mf.config.cron_enable.PSObject.Properties) {
        if ($k.Name -eq '_comment') { continue }
        [void]$cronEnableDeclared.Add("$($pdir.Name)|$($k.Name)")
    }
}
foreach ($ref in $cronEnableRefs) {
    if (-not $cronEnableDeclared.Contains($ref)) {
        $p = $ref -split '\|', 2
        $errors.Add("CRON-ENABLE FEHLT: ein Cron-Gate liest core.fn_config_get('$($p[0])','cron_enable','$($p[1])'), aber packages/$($p[0])/manifest.json .config.cron_enable.$($p[1]) ist nicht deklariert -- der Seeder legt die Zeile nicht an, das fail-closed-Gate schaltet den Cron STILL ab.")
    }
}
foreach ($decl in $cronEnableDeclared) {
    if (-not $cronEnableRefs.Contains($decl)) {
        $p = $decl -split '\|', 2
        $errors.Add("CRON-ENABLE ORPHAN: packages/$($p[0])/manifest.json deklariert .config.cron_enable.$($p[1]), aber kein Cron-Gate liest es (tote Config -- Cron umbenannt/entfernt?).")
    }
}

# ---------------------------------------------------------------
# (9) CALLBACK-PREFIX-KOLLISION (Phase 0 WS-0c CB): ein Manifest-callback_handlers-Prefix darf KEINEN der
#     hartkodierten 'Callback action'-Switch-Arme doppeln -- sonst faengt der Switch-Arm zuerst und die
#     core.callback_handlers-Zeile feuert NIE (tote Handler-Bindung, da der generische Dispatch nur die
#     extra-Fallback-Ausgabe sieht). SoT der hartkodierten Arme = der gebaute Orchestrator-Switch (rightValue
#     je Bedingung, wie command_lint den Command-Router liest), SoT der Registry-Prefixes = die Manifest-
#     callback_handlers-Bloecke. Zusaetzlich: das NESTED-Schema { "<prefix>": { handler_fn, member_permeable } }
#     validieren (der flat-Handler-fn-String ist retired; member_permeable steuert die Member-Callback-Route).
# ---------------------------------------------------------------
#     AUSNAHME (Mitglieder-Pfad): eine Kollision ist erlaubt, wenn die Registry-Zeile member_permeable=true traegt --
#     dann ist sie NICHT tot: der Owner nimmt den Switch-Arm, aufgeloeste Mitglieder gehen am Switch vorbei direkt in
#     den Registry-Dispatch (Orchestrator 'Callback member?'). Erster Fall: 'onboarding' (core.fn_handle_onboarding_cb).
function Test-CbCollisionAllowed($Value) {
    return ($Value -is [System.Management.Automation.PSCustomObject]) -and ($Value.member_permeable -is [bool]) -and $Value.member_permeable
}
foreach ($sa in @(@{ v = ('{"handler_fn":"core.x","member_permeable":true}' | ConvertFrom-Json); want = $true },
                  @{ v = ('{"handler_fn":"core.x","member_permeable":false}' | ConvertFrom-Json); want = $false },
                  @{ v = ('{"handler_fn":"core.x","member_permeable":"true"}' | ConvertFrom-Json); want = $false },
                  @{ v = ('{"handler_fn":"core.x"}' | ConvertFrom-Json); want = $false })) {
    if ((Test-CbCollisionAllowed $sa.v) -ne $sa.want) { $errors.Add("CALLBACK-PREFIX-KOLLISION SELBST-ASSERT: Test-CbCollisionAllowed defekt fuer $($sa.v | ConvertTo-Json -Compress)") }
}
$hardcodedCbPrefixes = New-Object System.Collections.Generic.HashSet[string]
$cbSwitchCount = 0
foreach ($id in $workflows.Keys) {
    foreach ($n in $workflows[$id].Json.nodes) {
        if ($n.type -eq 'n8n-nodes-base.switch' -and [string]$n.name -eq 'Callback action') {
            $cbSwitchCount++
            foreach ($r in $n.parameters.rules.values) {
                foreach ($cond in $r.conditions.conditions) {
                    $rv = [string]$cond.rightValue
                    if ($rv) { [void]$hardcodedCbPrefixes.Add($rv) }
                }
            }
        }
    }
}
if ($cbSwitchCount -ne 1) {
    $errors.Add("CALLBACK-DISPATCH: genau EIN 'Callback action'-Switch erwartet, $cbSwitchCount gefunden (Rename/Build-Drift -- Prefix-Kollisionscheck kann nicht laufen).")
}
foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue)) {
    $pkg = $pdir.Name
    $mf  = Read-Manifest $pkg
    if ($null -eq $mf -or -not $mf.callback_handlers) { continue }
    foreach ($p in $mf.callback_handlers.PSObject.Properties) {
        if ($p.Name -eq '_comment') { continue }
        if ($hardcodedCbPrefixes.Contains($p.Name) -and -not (Test-CbCollisionAllowed $p.Value)) {
            $errors.Add("CALLBACK-PREFIX-KOLLISION: packages/$pkg/manifest.json deklariert callback_handlers-Prefix '$($p.Name)', der bereits ein hartkodierter 'Callback action'-Switch-Arm ist -- der Switch faengt ihn zuerst, die Registry-Zeile feuert NIE (tote Bindung). Anderes Prefix waehlen (oder bewusst member_permeable=true: Owner nimmt den Switch, Mitglieder die Registry).")
        }
        # Nested-Schema { handler_fn, member_permeable } erzwingen (flat-String retired -> seed_data
        # laese .value.handler_fn=null; member_permeable steuert die fail-closed Member-Route).
        $cbVal = $p.Value
        if ($cbVal -isnot [System.Management.Automation.PSCustomObject]) {
            $errors.Add("CALLBACK-SCHEMA: packages/$pkg/manifest.json callback_handlers '$($p.Name)' muss ein Objekt { handler_fn, member_permeable } sein (nested-Schema; flat handler_fn-String ist retired).")
        } else {
            if (-not $cbVal.handler_fn -or [string]$cbVal.handler_fn -notmatch '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$') {
                $errors.Add("CALLBACK-SCHEMA: packages/$pkg/manifest.json callback_handlers '$($p.Name)': handler_fn fehlt/ungueltig (schema.fn kleingeschrieben erwartet).")
            }
            if ($null -ne $cbVal.member_permeable -and $cbVal.member_permeable -isnot [bool]) {
                $errors.Add("CALLBACK-SCHEMA: packages/$pkg/manifest.json callback_handlers '$($p.Name)': member_permeable muss boolean (true/false) sein, got '$($cbVal.member_permeable)'.")
            }
        }
    }
}

# ---------------------------------------------------------------
# (8) BACKUP-BLOCK-HYGIENE (Phase 5, arch-3 Obj 3 + M4): kein Paket darf den Backup-Key oder einen
#     Code-Seed in ein Export-Bundle ziehen. Geprueft wird der manifest-`backup`-Block (von backup_cli.sh
#     gelesen): die GEDUMPTEN Tabellen (full_tables + filtered_tables-Keys; exclude_tables ist die
#     entgegengesetzte Absicht = aus dem Dump nehmen, daher nicht geprueft) duerfen weder Schema `core`
#     noch eine code-geseedete Tabelle nennen, und schema_dump darf kein core-besitzendes Paket treffen.
# ---------------------------------------------------------------
# Code-geseedete Tabellen (managed_by<>'agent' = Repo-Code, vom Installer neu geseedet): gehoeren nie
# in ein Bundle. core.* faengt schon (8a) ab; agent.ai_models ist der einzige Code-Seed ausserhalb core.
$codeSeedTables = @('agent.ai_models', 'core.config')
foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue)) {
    $pkg = $pdir.Name
    $mf  = Read-Manifest $pkg
    if ($null -eq $mf -or -not $mf.backup) { continue }
    $bk = $mf.backup

    # Besitzt das Paket Schema 'core'? (schemas[] ODER schema)
    $ownsCore = ($mf.schema -eq 'core') -or ($mf.schemas -and (@($mf.schemas) -contains 'core'))

    # Die GEDUMPTEN Tabellen-Referenzen (full_tables + filtered_tables-Keys).
    $dumped = New-Object System.Collections.Generic.List[string]
    if ($bk.full_tables) { foreach ($t in @($bk.full_tables)) { $dumped.Add("$t") } }
    if ($bk.filtered_tables) { foreach ($p in $bk.filtered_tables.PSObject.Properties) { $dumped.Add($p.Name) } }

    foreach ($t in $dumped) {
        if ($t -match '^core\.') {
            $errors.Add("BACKUP-BLOCK core-SCHEMA: $pkg/manifest.json backup-Block dumpt '$t' (Schema core) -- Schema core darf NIE in einem backup-Block stehen, sonst rutscht core.backup_key (der Restore-Schluessel selbst) ins Bundle (arch-3 Obj 3).")
        }
        if ($codeSeedTables -contains $t) {
            $errors.Add("BACKUP-BLOCK CODE-SEED: $pkg/manifest.json backup-Block dumpt die code-geseedete Tabelle '$t' -- Code-Seeds gehoeren in KEIN Bundle (der Installer seedet sie neu; im Dump ueberschriebe ein Restore Code mit altem Stand; M4 --no-seed-Vertrag).")
        }
    }

    # schema_dump auf einem core-besitzenden Paket zoege Schema core (inkl. core.backup_key) in den Dump.
    if (($bk.schema_dump -eq $true) -and $ownsCore) {
        $errors.Add("BACKUP-BLOCK schema_dump core: $pkg/manifest.json setzt schema_dump=true und besitzt Schema 'core' -- das zoege Schema core (inkl. core.backup_key) in den Dump; verboten (arch-3 Obj 3).")
    }
}

# ---------------------------------------------------------------
# (9) CRON-CONTEXT-WRITE (M1, Phase C): ein CRON (scheduleTrigger-Workflow) darf NIE agent.core_contexts
#     schreiben -- weder DIREKT (INSERT/UPDATE/DELETE) noch ueber eine fn, die es (transitiv) tut. Strukturelle
#     Leitplanke gegen das hoechste Roadmap-Risiko (Auto-Memory-Writes): der EINZIGE core_contexts-Schreibpfad
#     ist die owner-gegatete Approve-fn, ausgeloest vom Orchestrator-Callback (learn:ok) -- NIE von einem Cron.
#     (Phase C Stufe 2 / S2-1 vertieft das per BEFORE-UPDATE-Trigger auf agent.core_contexts.)
# ---------------------------------------------------------------
$ctxWriteRe = '(?im)(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+agent\.core_contexts\b'
# Closure ueber fnBodies: eine fn mit direktem DML ist Writer; eine fn, die eine Writer-fn (statisch
# sichtbar, kein dynamisches EXECUTE) aufruft, ist selbst Writer. Konservativ (folgt KEINEM dyn. Dispatch)
# -> nie False-Positive, faengt aber die realistische Regression (direktes DML / fn_set_context_facts & Co).
$ctxWriters = New-Object System.Collections.Generic.HashSet[string]
foreach ($fn in $fnBodies.Keys) { if ($fnBodies[$fn] -match $ctxWriteRe) { [void]$ctxWriters.Add($fn) } }
$ctxChanged = $true
while ($ctxChanged) {
    $ctxChanged = $false
    foreach ($fn in $fnBodies.Keys) {
        if ($ctxWriters.Contains($fn)) { continue }
        foreach ($m in [regex]::Matches($fnBodies[$fn], '\b(fn_[a-z0-9_]+)\s*\(')) {
            if ($ctxWriters.Contains($m.Groups[1].Value)) { [void]$ctxWriters.Add($fn); $ctxChanged = $true; break }
        }
    }
}
foreach ($w in $workflows.Values) {
    # CRON = ENABLED scheduleTrigger als Eingang UND kein telegram-/executeWorkflow-Trigger. Schliesst
    # den Orchestrator (telegramTrigger + DEAKTIVIERTER Compression-Schedule -> seine Pairing/Knock-Callbacks
    # schreiben legitim core_contexts) sowie Agenten/Tools (executeWorkflowTrigger) aus.
    $hasEnabledSchedule = @($w.Json.nodes | Where-Object { $_.type -eq 'n8n-nodes-base.scheduleTrigger' -and -not ($_.disabled -eq $true) }).Count -gt 0
    $hasOtherTrigger    = @($w.Json.nodes | Where-Object { $_.type -in @('n8n-nodes-base.telegramTrigger', 'n8n-nodes-base.executeWorkflowTrigger') }).Count -gt 0
    if (-not $hasEnabledSchedule -or $hasOtherTrigger) { continue }
    foreach ($n in $w.Json.nodes) {
        if ($n.type -notin @('n8n-nodes-base.postgres', 'n8n-nodes-base.postgresTool')) { continue }
        $q = "$($n.parameters.query)"
        if ($q -match $ctxWriteRe) {
            $errors.Add("CRON-CONTEXT-WRITE (M1): $($w.Name) :: $($n.name) schreibt DIREKT agent.core_contexts -- ein Cron darf das NIE (einziger Schreibpfad = owner-gegatete Approve-fn via Orchestrator-Callback).")
        }
        foreach ($m in [regex]::Matches($q, $fnRefRe)) {
            if ($ctxWriters.Contains($m.Groups[1].Value)) {
                $errors.Add("CRON-CONTEXT-WRITE (M1): $($w.Name) :: $($n.name) ruft '$($m.Groups[1].Value)', die (transitiv) agent.core_contexts schreibt -- ein Cron darf das NIE (einziger Schreibpfad = owner-gegatete Approve-fn).")
            }
        }
    }
}

# ---------------------------------------------------------------
# (10) CONTEXT-SCOPE PARITAET (P0a): jeder facts-Context mit einem context_validators-Eintrag MUSS eine
#     context_scopes-Deklaration haben (fail-closed, "kein Default" — sonst faellt agent.fn_set_context_facts auf
#     den owner_only-Backstop und die deklarierte scope/write_permission-Absicht waere still verloren).
#     Bidirektional (Paritaet zu Check 7 cron_enable FEHLT/ORPHAN): ein context_scopes-Eintrag OHNE Validator ist
#     eine tote Deklaration (ORPHAN), die der Seeder still upsertet. SoT je Achse = die Manifest-Bloecke; per-Paket
#     gekeyt (ein Paket besitzt seine Contexts, PK context_name) — die Durchsetzung lebt in core.context_scopes.
# ---------------------------------------------------------------
$validatorCtx = New-Object System.Collections.Generic.HashSet[string]   # "<pkg>|<context>"
$scopeCtx     = New-Object System.Collections.Generic.HashSet[string]
foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue)) {
    $pkg = $pdir.Name
    $mf  = Read-Manifest $pkg
    if ($null -eq $mf) { continue }
    if ($mf.PSObject.Properties.Name -contains 'context_validators' -and $null -ne $mf.context_validators) {
        foreach ($p in $mf.context_validators.PSObject.Properties) { if ($p.Name -ne '_comment') { [void]$validatorCtx.Add("$pkg|$($p.Name)") } }
    }
    if ($mf.PSObject.Properties.Name -contains 'context_scopes' -and $null -ne $mf.context_scopes) {
        foreach ($p in $mf.context_scopes.PSObject.Properties) { if ($p.Name -ne '_comment') { [void]$scopeCtx.Add("$pkg|$($p.Name)") } }
    }
}
foreach ($v in $validatorCtx) {
    if (-not $scopeCtx.Contains($v)) {
        $p = $v -split '\|', 2
        $errors.Add("CONTEXT-SCOPE FEHLT: packages/$($p[0])/manifest.json context_validators deklariert '$($p[1])', aber context_scopes hat keine Zeile -- fn_set_context_facts faellt auf den owner_only-Backstop, die scope/write_permission-Absicht waere still verloren (fail-closed, kein Default).")
    }
}
foreach ($s in $scopeCtx) {
    if (-not $validatorCtx.Contains($s)) {
        $p = $s -split '\|', 2
        $errors.Add("CONTEXT-SCOPE ORPHAN: packages/$($p[0])/manifest.json context_scopes deklariert '$($p[1])', aber kein context_validators-Eintrag dazu -- tote Scope-Deklaration (Context umbenannt/entfernt?).")
    }
}

# ---------------------------------------------------------------
# (11) ONBOARDING PARITAET (P1 Generisches Paket-Onboarding): ein Nicht-Core-Paket mit provides.onboarding.agent
#     MUSS eine nicht-leere packages/<pkg>/onboarding/sections.json haben — UND umgekehrt (bidirektional,
#     fail-closed). Das ist der D3-Backstop der "Konvention statt sections_file"-Entscheidung (arch-challenge D3):
#     der Sektions-Pfad ist abgeleitet (kein Manifest-Feld) -> dieser Lint sichert, dass die Konvention nicht still
#     bricht. Plus: der deklarierte onboarding.agent MUSS ein provides.agents-Name desselben Pakets sein (der
#     Orchestrator-Dispatch ruft agent.<agent>; Tippfehler-Schutz). Core ausgenommen: der Core-Haushalt onboardet
#     ueber agent.guide_onboarding_state (kein packages/core/onboarding, kein provides.onboarding) = Sonderfall.
# ---------------------------------------------------------------
foreach ($mf in (Get-ChildItem (Join-Path $pkgDir '*\manifest.json'))) {
    $mj  = [System.IO.File]::ReadAllText($mf.FullName, $Utf8NoBom) | ConvertFrom-Json
    $pkg = [string]$mj.name
    if ($pkg -eq 'core') { continue }   # Core-Haushalt = hartkodierter Sonderfall
    $hasOnb = ($null -ne $mj.provides.onboarding) -and -not [string]::IsNullOrEmpty([string]$mj.provides.onboarding.agent)
    $secFile = Join-Path $pkgDir "$pkg\onboarding\sections.json"
    $hasSecs = $false
    if (Test-Path $secFile) {
        try { $secs = [System.IO.File]::ReadAllText($secFile, $Utf8NoBom) | ConvertFrom-Json; $hasSecs = (@($secs).Count -gt 0) } catch { $hasSecs = $false }
    }
    if ($hasOnb -and -not $hasSecs) {
        $errors.Add("ONBOARDING PARITAET: packages/$pkg/manifest.json deklariert provides.onboarding.agent, aber packages/$pkg/onboarding/sections.json fehlt/ist leer/ungueltig -- Menue-Builder + Seeder finden keine Sektionen (fail-closed).")
    }
    if ($hasSecs -and -not $hasOnb) {
        $errors.Add("ONBOARDING PARITAET: packages/$pkg/onboarding/sections.json existiert, aber packages/$pkg/manifest.json deklariert kein provides.onboarding.agent -- die Sektionen werden geseedet, aber der Knopf-Tap ist nicht routbar (kein Orchestrator-Dispatch-Arm).")
    }
    if ($hasOnb) {
        $onbAgent   = [string]$mj.provides.onboarding.agent
        $agentNames = @($mj.provides.agents | ForEach-Object { if ($_ -is [string]) { $_ } else { [string]$_.name } })
        if ($agentNames -notcontains $onbAgent) {
            $errors.Add("ONBOARDING AGENT: packages/$pkg/manifest.json provides.onboarding.agent='$onbAgent' ist kein provides.agents-Name dieses Pakets ($($agentNames -join ', ')) -- der Orchestrator-Dispatch riefe agent.$onbAgent ins Leere (Tippfehler?).")
        }
    }
}

# ---------------------------------------------------------------
# (12) CREDENTIALS-BLOCK (Install-UX-Phase, docs/package-contract.md §3.8) — die Absicherungs-Schicht
#     gegen den career-Credentials-Fall (Owner-Direktive: "nie wieder Paket-Secret als Host-Sonderlocke,
#     Installationsprozess nie umgangen/gebrochen"). Teil-Checks (12e/12f = Manifest-`.config`-Eintraege, s. dort):
#     (12a) SCHEMA: jeder manifest-`credentials`-Eintrag traegt placeholder (__CRED_*__-Form), name, type
#           (∈ Assembler-Enum aus inject_credentials.sh::_cred_assemble_data — Fail beim Commit statt
#           Install-die) + >=1 env-Key; validator ∈ geschlossenem Enum (none|url|email|live_check:<name>).
#     (12b) PARITAET (bidirektional, Vorlage Check 7): jedes __CRED_*__-Token in den gebauten Workflows
#           eines Pakets ist Host-Map ∪ Rollen-Konvention (__CRED_POSTGRES_<PKG>_RW/RO__) ∪ deklariert
#           (FEHLT = inject legt die Cred nie an -> dangling Platzhalter beim Deploy); jeder deklarierte
#           placeholder wird von >=1 Paket-Workflow referenziert (ORPHAN = tote Deklaration).
#     (12c) NAHT-GUARD: provisioning/ traegt KEINE Paket-Credential-Literale — kein __CRED_*__ ausserhalb
#           der Host-Map-SoT und keinen deklarierten Paket-env-Key als Wort (der praezise career-Rueckfall:
#           inject_credentials Stufen 8/9 + _INSTALL_ENV_KEYS).
#     (12d) PROMPT-GATE-GUARD: die interaktiven Eingabe-Primitive (ui_input/_read_tty + rohe
#           read</dev/tty) leben NUR an den sanktionierten Stellen (Datei-Allowlist), und
#           _prompt_validated/ui_input tragen das ui_interactive-Gate (TTY ∧ ¬UNATTENDED) — kein neuer
#           Prompt kann den unattended-Pfad erreichen. Selbst-Asserts: Map/Enum/Gate nicht extrahierbar
#           -> harter Fail (nie still gruen).
#     (12e) CONFIG-FRAGE: Typisierung der fragbaren `.config`-Eintraege (prompt/help/validator/choices).
#     (12f) OWNER-ANZEIGE: jeder `.config`-Eintrag traegt ein einzeiliges deutsches `summary` (<= 100 Zeichen).
#     (12g) LAUFZEIT-FRAGE: ein `.config`-Eintrag, den ein Workflow zur Laufzeit liest (core.fn_config_get) und der leer
#           ausgeliefert wird, traegt `prompt` (Installer fragt ihn) — dazu: jeder credentials.env-Key traegt `prompt`.
# ---------------------------------------------------------------
$provDir    = Join-Path $RepoRoot 'provisioning'
$injectFile = Join-Path $provDir 'lib\inject_credentials.sh'
$hostPlaceholders = New-Object System.Collections.Generic.HashSet[string]
$assemblerTypes   = New-Object System.Collections.Generic.HashSet[string]
if (-not (Test-Path $injectFile)) {
    $errors.Add("CREDENTIALS Selbst-Assert: provisioning/lib/inject_credentials.sh fehlt -- Check 12 kann nicht laufen.")
} else {
    $injTxt = [System.IO.File]::ReadAllText($injectFile, $Utf8NoBom)
    if ($injTxt -match '(?s)_cred_host_placeholder_names\(\)\s*\{(.*?)\r?\n\}') {
        foreach ($m in [regex]::Matches($Matches[1], '__CRED_[A-Z0-9_]+__')) { [void]$hostPlaceholders.Add($m.Value) }
    }
    if ($hostPlaceholders.Count -eq 0) {
        $errors.Add("CREDENTIALS Selbst-Assert: Host-Platzhalter-Map (_cred_host_placeholder_names) nicht extrahierbar -- Regex/Struktur-Drift in inject_credentials.sh.")
    }
    if ($injTxt -match '(?s)_cred_assemble_data\(\)\s*\{(.*?)\r?\n\}') {
        foreach ($m in [regex]::Matches($Matches[1], '(?m)^\s*([A-Za-z][A-Za-z0-9]*)\)')) { [void]$assemblerTypes.Add($m.Groups[1].Value) }
    }
    if ($assemblerTypes.Count -eq 0) {
        $errors.Add("CREDENTIALS Selbst-Assert: Assembler-Typ-Enum (_cred_assemble_data case-Labels) nicht extrahierbar -- Regex/Struktur-Drift in inject_credentials.sh.")
    }
}

# (12a) Schema + Deklarations-Sammlung je Paket.
$credDeclared   = @{}   # pkg -> HashSet placeholder
$credEnvKeys    = New-Object System.Collections.Generic.HashSet[string]   # alle deklarierten env-Keys (12c)
$validatorEnumRe = '^(none|url|email|live_check:(telegram|google|anthropic))$'
# (12e) Install-UX-Phase 4: `.config`-Eintraege mit `prompt` fragt der Paket-Wizard (pkg_lifecycle.sh
#       _pkg_settings_wizard) — gleiches Vokabular wie credentials.env: prompt (Text), validator (dasselbe
#       geschlossene Enum), help (Text), optional choices [{value,label}] (Auswahlliste; Wert nicht-leer und nicht
#       `__later__` — reserviert fuer die Wizard-Option „Spaeter festlegen"). Typfehler -> Commit-Fail.
foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue)) {
    $pkg = $pdir.Name
    $mf  = Read-Manifest $pkg
    if ($null -eq $mf -or -not ($mf.PSObject.Properties.Name -contains 'config') -or $null -eq $mf.config) { continue }
    foreach ($cat in $mf.config.PSObject.Properties) {
        if ($cat.Name -eq '_comment') { continue }
        foreach ($k in $cat.Value.PSObject.Properties) {
            $e = $k.Value
            if ($e -isnot [System.Management.Automation.PSCustomObject]) { continue }
            $names = @($e.PSObject.Properties.Name)
            $where = "packages/$pkg config.$($cat.Name).$($k.Name)"
            $askable = $names -contains 'prompt'
            if (-not $askable) {
                foreach ($f in 'validator', 'help', 'choices') {
                    if ($names -contains $f) { $errors.Add("CONFIG-FRAGE: $where traegt '$f', aber kein 'prompt' -- ohne prompt fragt der Wizard nie, das Feld waere tot.") }
                }
                continue
            }
            if ($e.prompt -isnot [string] -or [string]::IsNullOrWhiteSpace($e.prompt)) { $errors.Add("CONFIG-FRAGE: $where.prompt muss ein nicht-leerer Text sein.") }
            if ($names -contains 'help' -and ($e.help -isnot [string] -or [string]::IsNullOrWhiteSpace($e.help))) { $errors.Add("CONFIG-FRAGE: $where.help muss ein nicht-leerer Text sein.") }
            if ($names -contains 'validator' -and ([string]$e.validator) -notmatch $validatorEnumRe) { $errors.Add("CONFIG-FRAGE: $where.validator='$($e.validator)' ist nicht im geschlossenen Enum none|url|email|live_check:(telegram|google|anthropic).") }
            if ($names -contains 'choices') {
                $ch = @($e.choices)
                if ($ch.Count -eq 0) { $errors.Add("CONFIG-FRAGE: $where.choices ist leer.") }
                foreach ($c in $ch) {
                    if ([string]::IsNullOrWhiteSpace([string]$c.value) -or [string]::IsNullOrWhiteSpace([string]$c.label)) { $errors.Add("CONFIG-FRAGE: $where.choices-Eintrag ohne value/label: $($c | ConvertTo-Json -Compress).") }
                    # __later__ = Wert der "Spaeter festlegen"-Option des Wizards (_PKG_SETTING_LATER, pkg_lifecycle.sh) -- reserviert.
                    if ([string]$c.value -eq '__later__') { $errors.Add("CONFIG-FRAGE: $where.choices-Wert '__later__' ist reserviert (Wizard-Option 'Spaeter festlegen').") }
                }
                if ($names -contains 'validator') { $errors.Add("CONFIG-FRAGE: $where traegt choices UND validator -- eine Auswahlliste braucht keinen Validator (eins von beiden).") }
            }
        }
    }
}
# (12f) Jeder `.config`-Eintrag traegt `summary` = deutscher Owner-Einzeiler fuer `lifeagents config list`/`config set`
#       (docs/package-contract.md §3.6; `description` bleibt englischer Entwickler-Text). Nicht leer, ohne Steuerzeichen
#       (die DB-CHECK config_summary_single_line ist der Backstop), <= 100 Zeichen (die Liste zeigt ihn als eine Zeile).
#       `_comment` auf Kategorie- UND Key-Ebene wird wie im Seeder (seed_data.sh _seed_package_config) uebersprungen;
#       ein Nicht-Objekt-Eintrag ist ein Fehler (der Seeder wuerde ihn als leere Zeile anlegen).
foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue)) {
    $pkg = $pdir.Name
    $mf  = Read-Manifest $pkg
    if ($null -eq $mf -or -not ($mf.PSObject.Properties.Name -contains 'config') -or $null -eq $mf.config) { continue }
    foreach ($cat in $mf.config.PSObject.Properties) {
        if ($cat.Name -eq '_comment') { continue }
        foreach ($k in $cat.Value.PSObject.Properties) {
            if ($k.Name -eq '_comment') { continue }
            $where = "packages/$pkg config.$($cat.Name).$($k.Name)"
            $e = $k.Value
            if ($e -isnot [System.Management.Automation.PSCustomObject]) { $errors.Add("OWNER-ANZEIGE: $where ist kein Objekt {value, description, summary}."); continue }
            $sum = if ($e.PSObject.Properties.Name -contains 'summary') { $e.summary } else { $null }
            if ($sum -isnot [string] -or [string]::IsNullOrWhiteSpace($sum)) {
                $errors.Add("OWNER-ANZEIGE: $where hat kein nicht-leeres 'summary' (deutscher Einzeiler fuer lifeagents config list, docs/package-contract.md §3.6).")
            } elseif ($sum -match '[\x00-\x1f\x7f]') {
                $errors.Add("OWNER-ANZEIGE: $where.summary enthaelt ein Steuerzeichen (Zeilenumbruch/Tab) -- muss EINE Zeile sein.")
            } elseif ($sum.Length -gt 100) {
                $errors.Add("OWNER-ANZEIGE: $where.summary ist $($sum.Length) Zeichen lang (max. 100).")
            }
        }
    }
}
# (12g) paperless Phase 2 (E10): ein `.config`-Eintrag, den ein gebauter Workflow ZUR LAUFZEIT liest
#       (core.fn_config_get('<pkg>','<cat>','<key>')) und der LEER ausgeliefert wird, muss fragbar sein (`prompt`) —
#       sonst liefe das Feature nach jeder Installation ins Leere, bis jemand die Konsole bemueht.
$runtimeCfg = @{}
foreach ($w in $workflows.Values) {
    foreach ($n in $w.Json.nodes) {
        $q = "$($n.parameters.query)"
        foreach ($m in [regex]::Matches($q, "fn_config_get\(\s*'([a-z_]+)'\s*,\s*'([a-z_]+)'\s*,\s*'([a-z_]+)'")) {
            $runtimeCfg["$($m.Groups[1].Value)|$($m.Groups[2].Value)|$($m.Groups[3].Value)"] = $w.Name
        }
    }
}
foreach ($rk in $runtimeCfg.Keys) {
    $rp, $rc, $rkey = $rk.Split('|')
    $mf = Read-Manifest $rp
    $e = if ($null -ne $mf -and $mf.config -and $mf.config.$rc) { $mf.config.$rc.$rkey } else { $null }
    if ($null -eq $e) { continue }   # Laufzeit-Zeile ohne Manifest-Deklaration faengt (12f)/der Seeder nicht — hier nur die Frage-Pflicht
    if ([string]::IsNullOrEmpty([string]$e.value) -and -not ($e.PSObject.Properties.Name -contains 'prompt')) {
        $errors.Add("LAUFZEIT-FRAGE: packages/$rp config.$rc.$rkey wird zur Laufzeit gelesen ($($runtimeCfg[$rk])), ist leer ausgeliefert und hat kein 'prompt' -- der Installer muss den Wert erfragen.")
    }
}

foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue)) {
    $pkg = $pdir.Name
    $mf  = Read-Manifest $pkg
    $decl = New-Object System.Collections.Generic.HashSet[string]
    if ($null -ne $mf -and ($mf.PSObject.Properties.Name -contains 'credentials') -and $null -ne $mf.credentials) {
        foreach ($c in $mf.credentials.PSObject.Properties) {
            if ($c.Name -eq '_comment') { continue }
            $v = $c.Value
            if ([string]::IsNullOrEmpty([string]$v.placeholder) -or ([string]$v.placeholder) -notmatch '^__CRED_[A-Z0-9_]+__$') {
                $errors.Add("CREDENTIALS SCHEMA: packages/$pkg credentials.$($c.Name).placeholder fehlt/hat nicht die __CRED_*__-Form.")
            } else { [void]$decl.Add([string]$v.placeholder) }
            if ([string]::IsNullOrEmpty([string]$v.name)) { $errors.Add("CREDENTIALS SCHEMA: packages/$pkg credentials.$($c.Name).name fehlt (n8n-Credential-Name = Deploy-NAME-Aufloesung).") }
            if ([string]::IsNullOrEmpty([string]$v.type)) {
                $errors.Add("CREDENTIALS SCHEMA: packages/$pkg credentials.$($c.Name).type fehlt.")
            } elseif ($assemblerTypes.Count -gt 0 -and -not $assemblerTypes.Contains([string]$v.type)) {
                $errors.Add("CREDENTIALS TYPE-ENUM: packages/$pkg credentials.$($c.Name).type='$($v.type)' ist nicht im Assembler-Enum ($(@($assemblerTypes) -join '|')) von _cred_assemble_data -- wuerde erst beim Install sterben (die).")
            }
            $envProps = @()
            if ($null -ne $v.env) { $envProps = @($v.env.PSObject.Properties) }
            if ($envProps.Count -eq 0) {
                $errors.Add("CREDENTIALS SCHEMA: packages/$pkg credentials.$($c.Name).env ist leer (mindestens ein env-Key noetig).")
            }
            if (([string]$v.type) -eq 'httpHeaderAuth' -and $envProps.Count -gt 1) {
                # Cold-Eyes A3: der Assembler nimmt to_entries[0] — ein 2. env-Key ginge STILL verloren.
                $errors.Add("CREDENTIALS SCHEMA: packages/$pkg credentials.$($c.Name) (httpHeaderAuth) deklariert $($envProps.Count) env-Keys — der Typ traegt genau EIN Name/Value-Paar, weitere Keys wuerden still verworfen.")
            }
            foreach ($e in $envProps) {
                # Cold-Eyes A1: der Key-Name fliesst in bash-`eval` + grep-Regex (inject/wizard/env_has_key)
                # -> beim Commit auf Bash-Identifier-Form pinnen (Env-Konvention UPPER_SNAKE), sonst wird ein
                # Sonderzeichen erst als kryptischer Laufzeit-/eval-Fehler sichtbar.
                if ($e.Name -notmatch '^[A-Z_][A-Z0-9_]*$') {
                    $errors.Add("CREDENTIALS SCHEMA: packages/$pkg credentials.$($c.Name).env-Key '$($e.Name)' ist kein gueltiger Env-Bezeichner (^[A-Z_][A-Z0-9_]*$) — er fliesst in eval/grep (inject/wizard).")
                    continue
                }
                [void]$credEnvKeys.Add($e.Name)
                if ([string]::IsNullOrEmpty([string]$e.Value.field)) {
                    $errors.Add("CREDENTIALS SCHEMA: packages/$pkg credentials.$($c.Name).env.$($e.Name).field fehlt (Binding-Slot je Typ).")
                }
                $val = [string]$e.Value.validator
                if (-not [string]::IsNullOrEmpty($val) -and $val -notmatch $validatorEnumRe) {
                    $errors.Add("CREDENTIALS VALIDATOR-ENUM: packages/$pkg credentials.$($c.Name).env.$($e.Name).validator='$val' ist nicht im geschlossenen Enum none|url|email|live_check:(telegram|google|anthropic).")
                }
                # Der Installer-Wizard fragt jeden env-Key ab (Install + lifeagents reconfigure) — ohne prompt waere der
                # Zugang nur per Hand-Edit der <pkg>.env setzbar (paperless E10: Adresse + Token werden gefragt).
                if ([string]::IsNullOrWhiteSpace([string]$e.Value.prompt)) {
                    $errors.Add("CREDENTIALS SCHEMA: packages/$pkg credentials.$($c.Name).env.$($e.Name).prompt fehlt -- der Wizard koennte den Zugang nicht abfragen.")
                }
            }
        }
    }
    $credDeclared[$pkg] = $decl
}

# (12b) Paritaet Manifest <-> gebaute Paket-Workflows (Platzhalter in node.credentials.*.id).
foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue)) {
    $pkg = $pdir.Name
    $up  = $pkg.ToUpperInvariant()
    $refs = New-Object System.Collections.Generic.HashSet[string]
    foreach ($f in (Get-ChildItem (Join-Path $pdir.FullName 'workflows\*.json') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '_*' })) {
        $txt = [System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom)
        foreach ($m in [regex]::Matches($txt, '__CRED_[A-Z0-9_]+__')) { [void]$refs.Add($m.Value) }
    }
    $allowed = New-Object System.Collections.Generic.HashSet[string]
    foreach ($h in $hostPlaceholders) { [void]$allowed.Add($h) }
    [void]$allowed.Add("__CRED_POSTGRES_${up}_RW__"); [void]$allowed.Add("__CRED_POSTGRES_${up}_RO__")
    foreach ($d in $credDeclared[$pkg]) { [void]$allowed.Add($d) }
    if ($pkg -ne 'core') {
        foreach ($r in $refs) {
            if (-not $allowed.Contains($r)) {
                $errors.Add("CREDENTIALS FEHLT: packages/$pkg/workflows referenziert '$r', aber weder Host-Map noch Rollen-Konvention noch packages/$pkg/manifest.json credentials deklarieren ihn -- inject legt die Credential NIE an, der Platzhalter bleibt beim Deploy dangling (genau der fruehere career-Fall).")
            }
        }
    }
    foreach ($d in $credDeclared[$pkg]) {
        if (-not $refs.Contains($d)) {
            $errors.Add("CREDENTIALS ORPHAN: packages/$pkg/manifest.json deklariert credentials-placeholder '$d', aber kein Paket-Workflow referenziert ihn (tote Deklaration -- Workflow umgebaut/entfernt?).")
        }
    }
}

# (12c) NAHT-GUARD: provisioning/ ohne Paket-Credential-Literale. __CRED_*__ ausserhalb der Host-Map nur
#       aus der Host-Map selbst (inject_credentials.sh ist die SoT-Datei und darf sie tragen); deklarierte
#       Paket-env-Keys duerfen NIRGENDS in provisioning/ als Wort auftauchen (der Wizard/Inject liest sie
#       GENERISCH aus dem Manifest -- ein Literal waere die Rueckkehr der Sonderlocke).
foreach ($f in (Get-ChildItem $provDir -Recurse -Include '*.sh','*.tpl' -File -ErrorAction SilentlyContinue)) {
    $txt = [System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom)
    $rel = $f.FullName.Substring($RepoRoot.Length + 1) -replace '\\','/'
    if ($f.Name -ne 'inject_credentials.sh') {
        foreach ($m in [regex]::Matches($txt, '__CRED_[A-Z0-9_]+__')) {
            if (-not $hostPlaceholders.Contains($m.Value)) {
                $errors.Add("CREDENTIALS NAHT-GUARD: $rel traegt Nicht-Host-Platzhalter '$($m.Value)' -- Paket-Creds sind manifest-deklariert (§3.8), Host-Code bleibt paket-literal-frei.")
            }
        }
    }
    foreach ($k in $credEnvKeys) {
        if ($txt -match "\b$([regex]::Escape($k))\b") {
            $errors.Add("CREDENTIALS NAHT-GUARD: $rel referenziert den paket-deklarierten Secret-Key '$k' -- genau der fruehere career-Rueckfall (inject-Stufen/_INSTALL_ENV_KEYS); der Key gehoert NUR ins Paket-Manifest + /etc/lifeagents/<pkg>.env.")
        }
    }
}

# (12d) PROMPT-GATE-GUARD: Eingabe-Primitive nur an sanktionierten Stellen + Gate-Assert.
$promptAllow = @{  # Datei -> erlaubte Primitive (Definition/Delegat/sanktionierte Wrapper)
    'provisioning/lib/common.sh'         = @('ui_input-def', 'ui_choose-def', 'ui_wait_key-def')
    'provisioning/lib/release_inputs.sh' = @('_read_tty-def', 'ui_input', '_read_tty', 'ui_choose')  # + Proxy-Ort-Frage (Install-UX-Phase 5)
    'provisioning/lib/proxy_cli.sh'      = @('ui_input', 'ui_choose')  # `lifeagents proxy set`: Adresse + Netz-Bestaetigung
    'provisioning/lib/pkg_lifecycle.sh'  = @('ui_input', 'ui_choose', 'rawtty')  # Wizard-reask + _pkg_confirm (--yes-Achse) + Verb-/Missing-Arg-Picker
    'provisioning/lib/fetch_release.sh'  = @()                       # Download immer anonym: keine Frage (Public-Repo)
    'provisioning/lib/uninstall.sh'      = @('rawtty')               # _u_confirm (--yes-Achse, bewusst nicht UNATTENDED)
    'provisioning/lib/backup_cli.sh'     = @('rawtty', 'ui_choose')  # Restore-Confirm 'ja' (--yes-Achse) + Restore-/Verb-Picker
    'provisioning/lib/config_cli.sh'     = @('ui_input', 'ui_choose') # config-set-Picker (Key/Modell) + Wert-Prompt
    'provisioning/lib/household_cli.sh'  = @('ui_choose')            # Personen-/Unblock-/Rollen-/Verb-Picker
    'provisioning/lib/reconfigure_cli.sh' = @('ui_choose')           # `lifeagents reconfigure`: Ziel-/Aktions-Picker (Werte fragt _prompt_validated)
    'provisioning/templates/lifeagents.tpl' = @('ui_choose')         # Hauptmenue bei nacktem Aufruf (E4)
    'provisioning/lib/upgrade_guard.sh'  = @('ui_choose')            # `lifeagents rollback`: Bestaetigung (Daten seit der Sicherung gehen verloren)
    'provisioning/install.sh'            = @()                       # self-contained Bootstrap: fragt nichts (anonymer Download)
    'provisioning/lib/bootstrap_owner.sh' = @()
    'provisioning/lib/owner_connect.sh' = @('ui_choose', 'ui_wait_key')  # Gefuehrtes Ende: 'Erneut pruefen/Spaeter' + Pairing-Warten (Install-UX-Phase 3)
}
foreach ($f in (Get-ChildItem $provDir -Recurse -Include '*.sh','*.tpl' -File -ErrorAction SilentlyContinue)) {
    $rel = $f.FullName.Substring($RepoRoot.Length + 1) -replace '\\','/'
    $lines = [System.IO.File]::ReadAllLines($f.FullName, $Utf8NoBom)
    $allow = if ($promptAllow.ContainsKey($rel)) { $promptAllow[$rel] } else { @() }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        if ($ln -match '^\s*#') { continue }
        $isDef = $ln -match '^\s*(ui_input|ui_choose|ui_wait_key|_read_tty)\s*\(\)'
        if ($isDef) { continue }   # Definitionen selbst prueft der Gate-Assert unten
        if ($ln -match '(^|[^A-Za-z0-9_])(ui_input|ui_choose|ui_wait_key|_read_tty)\b' -and $allow -notcontains $Matches[2]) {
            $errors.Add("PROMPT-GATE-GUARD: $rel Zeile $($i+1) ruft '$($Matches[2])' ausserhalb der sanktionierten Wrapper -- neue Prompts laufen NUR ueber _prompt_validated/den Stage-4-Wizard (ui_interactive-Gate, unattended-sicher).")
        }
        # Cold-Eyes A2: JEDE read-Form mit /dev/tty-Redirect fangen (nicht nur `read -r`) — die Gefahr
        # ist der Redirect selbst, nicht die gewaehlten read-Flags.
        if ($ln -match '\bread\b[^<]*<\s*/dev/tty' -and $allow -notcontains 'rawtty' -and $rel -ne 'provisioning/lib/common.sh') {
            $errors.Add("PROMPT-GATE-GUARD: $rel Zeile $($i+1) liest roh von /dev/tty -- Eingaben laufen ueber ui_input (gum+plain, ui_interactive-Gate); rohe Reads sind nur den --yes-Confirms/dem Bootstrap erlaubt.")
        }
    }
}
# Gate-Asserts: ui_input gatet ueber ui_interactive; ui_interactive prueft UNATTENDED; _prompt_validated nutzt beide.
$commonTxt = [System.IO.File]::ReadAllText((Join-Path $provDir 'lib\common.sh'), $Utf8NoBom)
if ($commonTxt -notmatch '(?s)ui_input\(\)\s*\{.{0,200}?ui_interactive') {
    $errors.Add("PROMPT-GATE-GUARD Selbst-Assert: common.sh ui_input() traegt kein ui_interactive-Gate (Befund-1-Haertung verloren?).")
}
if ($commonTxt -notmatch 'ui_interactive\(\)\s*\{[^\n]*UNATTENDED') {
    $errors.Add("PROMPT-GATE-GUARD Selbst-Assert: common.sh ui_interactive() prueft UNATTENDED nicht (unattended-Garantie verloren?).")
}
if ($commonTxt -notmatch '(?s)ui_choose\(\)\s*\{.{0,200}?ui_interactive') {
    $errors.Add("PROMPT-GATE-GUARD Selbst-Assert: common.sh ui_choose() traegt kein ui_interactive-Gate (Picker wuerde den unattended-Pfad erreichen).")
}
if ($commonTxt -notmatch '(?s)ui_wait_key\(\)\s*\{.{0,200}?ui_interactive') {
    $errors.Add("PROMPT-GATE-GUARD Selbst-Assert: common.sh ui_wait_key() traegt kein ui_interactive-Gate (Tasten-Warten wuerde den unattended-Pfad erreichen).")
}
$relTxt = [System.IO.File]::ReadAllText((Join-Path $provDir 'lib\release_inputs.sh'), $Utf8NoBom)
if ($relTxt -notmatch '(?s)_prompt_validated\(\)\s*\{.*?ui_interactive') {
    $errors.Add("PROMPT-GATE-GUARD Selbst-Assert: release_inputs.sh _prompt_validated() nutzt ui_interactive nicht (Prompt-Gate-Kette gebrochen?).")
}

# ---------------------------------------------------------------
# (13) CLI-HELP-PARITAET (Install-UX, Owner-Direktive "die Help-Ausgabe MUSS abgesichert sein"):
#     die CLI-Hilfe ist die EINE Befehls-Referenz (Site/README verweisen nur darauf, keine zweite
#     Adresse) — also darf sie nie driften. Bidirektional je Dispatcher: jeder case-Verb-Arm ist im
#     help-Heredoc dokumentiert UND jeder dokumentierte Verb hat einen Arm (Aliasse mit '-'-Praefix +
#     help/* exempt). Flags: provision.sh parse_args <-> usage() bidirektional; install.sh armed ⊆
#     usage (Passthrough-Launcher: dokumentiert mehr als er selbst parst — erlaubt). Selbst-Asserts
#     bei leerer Extraktion (nie still gruen).
# ---------------------------------------------------------------
function Get-CliCaseBlock([string]$Txt, [string]$Header) {
    $i = $Txt.IndexOf($Header)
    if ($i -lt 0) { return $null }
    $m = [regex]::Match($Txt.Substring($i), '(?m)^\s*esac\b')   # esac darf eingerueckt sein (Funktions-Body)
    if (-not $m.Success) { return $null }
    return $Txt.Substring($i, $m.Index)
}
function Get-CliArmVerbs([string]$Block) {
    $verbs = New-Object System.Collections.Generic.HashSet[string]
    # Nur lowercase-Tokens: Dispatcher-Verben sind per Konvention klein — Prosa-Woerter in
    # Meldungs-Strings ("... Abbruch)") beginnen gross und fallen so heraus.
    foreach ($m in [regex]::Matches($Block, '(?m)^\s*([a-z*][A-Za-z0-9|_*-]*)\)')) {
        $first = ($m.Groups[1].Value -split '\|')[0]
        if ($first -in @('help', '*')) { continue }
        if ($first.StartsWith('-')) { continue }   # reine Flag-Aliasse (--update, -V) sind exempt
        [void]$verbs.Add($first)
    }
    return $verbs
}
function Get-CliHelpVerbs([string]$Txt, [string]$HelpStart) {
    $i = $Txt.IndexOf($HelpStart)
    if ($i -lt 0) { return $null }
    $h = $Txt.IndexOf("<<'EOF'", $i)   # erst AB dem Heredoc-Start lesen (sonst zaehlt `cat >&2 <<'EOF'` als Verb)
    if ($h -lt 0) { return $null }
    $j = $Txt.IndexOf("`nEOF", $h)
    if ($j -lt 0) { return $null }
    $block = $Txt.Substring($h, $j - $h)
    $verbs = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in [regex]::Matches($block, '(?m)^  ([a-z][a-z-]*)\b')) {
        if ($m.Groups[1].Value -ne 'help') { [void]$verbs.Add($m.Groups[1].Value) }   # help = exempter Arm
    }
    return $verbs
}
$cliTargets = @(
    @{ Rel = 'provisioning/templates/lifeagents.tpl'; Case = 'case "$cmd" in';  Help = 'usage() {' },
    @{ Rel = 'provisioning/lib/pkg_lifecycle.sh';     Case = 'case "$verb" in'; Help = 'help|--help|-h)' },
    @{ Rel = 'provisioning/lib/config_cli.sh';        Case = 'case "$verb" in'; Help = 'help|--help|-h)' },
    @{ Rel = 'provisioning/lib/household_cli.sh';     Case = 'case "$verb" in'; Help = 'help|--help|-h)' },
    @{ Rel = 'provisioning/lib/backup_cli.sh';        Case = 'case "$verb" in'; Help = 'help|--help|-h)' }
)
foreach ($t in $cliTargets) {
    $p = Join-Path $RepoRoot ($t.Rel -replace '/', '\')
    if (-not (Test-Path $p)) { $errors.Add("CLI-HELP Selbst-Assert: $($t.Rel) fehlt."); continue }
    $txt = [System.IO.File]::ReadAllText($p, $Utf8NoBom)
    $block = Get-CliCaseBlock $txt $t.Case
    $arms  = if ($null -ne $block) { Get-CliArmVerbs $block } else { $null }
    $docs  = Get-CliHelpVerbs $txt $t.Help
    if ($null -eq $arms -or $arms.Count -lt 2) { $errors.Add("CLI-HELP Selbst-Assert: $($t.Rel) Dispatcher-Arme nicht extrahierbar (Struktur-Drift?)."); continue }
    if ($null -eq $docs -or $docs.Count -lt 2) { $errors.Add("CLI-HELP Selbst-Assert: $($t.Rel) Help-Text nicht extrahierbar (Struktur-Drift?)."); continue }
    foreach ($v in $arms) {
        if (-not $docs.Contains($v)) {
            $errors.Add("CLI-HELP FEHLT: $($t.Rel) hat den Verb-Arm '$v', aber die Hilfe dokumentiert ihn nicht -- niemand erfaehrt, dass der Befehl existiert (Owner-Direktive: Help = die eine Referenz).")
        }
    }
    foreach ($v in $docs) {
        if (-not $arms.Contains($v)) {
            $errors.Add("CLI-HELP ORPHAN: $($t.Rel) Hilfe dokumentiert '$v', aber der Dispatcher hat keinen Arm dazu (toter Doku-Eintrag/Tippfehler).")
        }
    }
}
# Flag-Paritaet: provision.sh bidirektional; install.sh armed ⊆ usage (Passthrough dokumentiert mehr).
function Get-CliFlags([string]$Txt, [string]$Start, [string]$End) {
    $i = $Txt.IndexOf($Start); if ($i -lt 0) { return $null }
    $j = $Txt.IndexOf($End, $i); if ($j -lt 0) { $j = $Txt.Length }
    $flags = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in [regex]::Matches($Txt.Substring($i, $j - $i), '--[a-z][a-z-]+')) { [void]$flags.Add($m.Value) }
    return $flags
}
$provTxt = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'provisioning\provision.sh'), $Utf8NoBom)
$provArm = Get-CliFlags $provTxt 'parse_args() {' "`n}"
$provDoc = Get-CliFlags $provTxt 'usage() {' "`nEOF"
if ($null -eq $provArm -or $provArm.Count -lt 3 -or $null -eq $provDoc -or $provDoc.Count -lt 3) {
    $errors.Add("CLI-HELP Selbst-Assert: provision.sh Flags nicht extrahierbar (parse_args/usage-Struktur-Drift?).")
} else {
    foreach ($f in $provArm) { if (-not $provDoc.Contains($f)) { $errors.Add("CLI-HELP FEHLT: provision.sh parse_args kennt '$f', aber usage() dokumentiert es nicht.") } }
    foreach ($f in $provDoc) { if (-not $provArm.Contains($f)) { $errors.Add("CLI-HELP ORPHAN: provision.sh usage() dokumentiert '$f', aber parse_args kennt es nicht.") } }
}
$instTxt = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'provisioning\install.sh'), $Utf8NoBom)
$instDoc = Get-CliFlags $instTxt 'usage() {' "`nEOF"
$instArm = New-Object System.Collections.Generic.HashSet[string]
foreach ($m in [regex]::Matches($instTxt, '(?m)^\s*(--[a-z][a-z-]+)[^)]*\)')) { [void]$instArm.Add($m.Groups[1].Value) }
if ($null -eq $instDoc -or $instDoc.Count -lt 2 -or $instArm.Count -lt 1) {
    $errors.Add("CLI-HELP Selbst-Assert: install.sh Flags nicht extrahierbar (usage/Arg-Loop-Struktur-Drift?).")
} else {
    foreach ($f in $instArm) { if (-not $instDoc.Contains($f)) { $errors.Add("CLI-HELP FEHLT: install.sh parst '$f', aber usage() dokumentiert es nicht (Passthrough-Flags sind pauschal dokumentiert, selbst geparste MUESSEN einzeln stehen).") } }
}

# ---------------------------------------------------------------
# (14) ADVISOR metric_key-NAMING (Pattern-Paritaet -> finance-Standard "schlicht"): ein alert-metric_key in
#     packages/<pkg>/db/migrations/R__fn_advisor_review.sql darf NIE mit dem eigenen Domaenen-Praefix '<pkg>_'
#     beginnen. Die Domaene lebt bereits in core.notification_state.source ('advisor:<domain>[:pid]', vom
#     Wrapper fn_advisor_review_evaluate gesetzt) -- ein Domaenen-Praefix im metric_key ist redundant. finance
#     macht es schlicht (plan_staleness/emergency_reserve/...); career/estate wurden darauf harmonisiert. Deckt
#     BEIDE Emit-Formen: die jsonb_build_object-Form ('metric_key','<val>') UND die Helfer-Form
#     core.fn_staleness_alert('<val>',...) (erstes Argument). pkg = physischer Ort (== advisor-domain).
# ---------------------------------------------------------------
foreach ($f in (Get-ChildItem (Join-Path $pkgDir '*\db\migrations\R__fn_advisor_review.sql') -File -ErrorAction SilentlyContinue)) {
    $pkg = if (($f.FullName -replace '\\','/') -match 'packages/([^/]+)/db/') { $Matches[1] } else { $null }
    if (-not $pkg) { continue }
    $sql = [System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom)
    # metric_key-Emit-Positionen mit dem eigenen '<pkg>_'-Praefix (String-Konkatenation statt Interpolation,
    # damit '$pfx_' nicht als Variable gelesen wird):
    $re = "(?:'metric_key'\s*,\s*|fn_staleness_alert\s*\(\s*)'" + [regex]::Escape($pkg) + "_"
    if ([regex]::IsMatch($sql, $re)) {
        $errors.Add("ADVISOR metric_key-NAMING: packages/$pkg/db/migrations/R__fn_advisor_review.sql emittiert einen metric_key mit dem eigenen Domaenen-Praefix '${pkg}_' -- die Domaene traegt bereits core.notification_state.source ('advisor:$pkg'); der Praefix ist redundant. Schlicht benennen (finance-Standard, s. packages/core/CLAUDE.md Advisor-Registry).")
    }
}

# ---------------------------------------------------------------
# (15) OWNER-ANZEIGE + FAKTEN-SKELETTE (Install-UX-Phase 6, docs/package-contract.md §2):
#     (a) jedes Paket traegt Anzeigename + Einzeiler im Textkatalog (<pkg>.package.name|summary in locales/de.json;
#         Recap, Picker, /help, Begruessung, Onboarding-Menue — Textkatalog Phase B, §3.11). Die frueheren Manifest-
#         Felder (display_name/summary, cron_labels-Texte, commands.description, catalog-Texte, sections.json label)
#         sind retired (Muster facts_display, 16b) -> ein Rueckfall ist ein Fehler (sonst zwei Adressen fuer einen Fakt).
#     (b) jeder `context_skeletons`-Key ist auch ein `context_validators`-Key desselben Pakets (ein Skelett ohne
#         Validator waere vom Haushalts-Schreibpfad core.fn_facts_context_allowed nie beschreibbar = tote Zeile)
#         und traegt ein `facts`-Objekt (der Seeder schreibt es als Start-Sidecar); er ist NICHT per_user (das
#         unsuffigierte Basis-Skelett wuerde nie beschrieben, docs/package-contract.md §3.3).
# ---------------------------------------------------------------
foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue)) {
    $pkg = $pdir.Name
    $mf  = Read-Manifest $pkg
    if ($null -eq $mf) { continue }
    $deF  = Join-Path $pdir.FullName 'locales\de.json'
    $deLc = if (Test-Path $deF) { [System.IO.File]::ReadAllText($deF, $Utf8NoBom) | ConvertFrom-Json } else { [pscustomobject]@{} }
    foreach ($sfx in 'name', 'summary') {
        if ([string]::IsNullOrWhiteSpace([string]$deLc."$pkg.package.$sfx")) {
            $errors.Add("OWNER-ANZEIGE: packages/$pkg/locales/de.json hat keinen Text '$pkg.package.$sfx' (Anzeigename/Einzeiler fuer Recap/Picker/Begruessung/Menue, docs/package-contract.md §3.11).")
        }
    }
    foreach ($fld in 'display_name', 'summary') {
        if ($mf.PSObject.Properties.Name -contains $fld) { $errors.Add("RETIRED: packages/$pkg/manifest.json traegt noch '$fld' — der Text steht im Katalog ($pkg.package.*, §3.11).") }
    }
    if ($mf.cron_labels) {
        foreach ($p in $mf.cron_labels.PSObject.Properties) {
            if ($p.Name -notin @('_comment', 'list', 'person', 'mandatory')) { $errors.Add("RETIRED: packages/$pkg/manifest.json cron_labels.$($p.Name) — nur noch cron_labels.list (Haushalt) + .person (je Person) + .mandatory (Pflicht, nur Anzeige), Texte im Katalog ($pkg.cron.<key>.*).") }
        }
    }
    if ($mf.catalog) {
        foreach ($c in @($mf.catalog.categories) + @($mf.catalog.tail)) {
            if ($null -eq $c) { continue }
            foreach ($fld in 'key', 'title', 'description', 'body') {
                if ($c.PSObject.Properties.Name -contains $fld) { $errors.Add("RETIRED: packages/$pkg/manifest.json catalog-Eintrag traegt noch '$fld' — Struktur {id, ord}, Texte im Katalog ($pkg.help.<id>.*).") }
            }
            if ([string]::IsNullOrEmpty([string]$c.id)) { $errors.Add("CATALOG: packages/$pkg/manifest.json catalog-Eintrag ohne 'id'.") }
        }
        if ($mf.catalog.PSObject.Properties.Name -contains 'fragment') { $errors.Add("RETIRED: packages/$pkg/manifest.json catalog.fragment — der Fragment-Pfad ist Konvention (seed/capabilities_catalog/<lang>.fragment.md).") }
    }
    $secF = Join-Path $pdir.FullName 'onboarding\sections.json'
    if (Test-Path $secF) {
        $secs = [System.IO.File]::ReadAllText($secF, $Utf8NoBom) | ConvertFrom-Json   # PS 5.1: Array kommt als EIN Objekt -> foreach direkt
        foreach ($s in $secs) {
            if ($s.PSObject.Properties.Name -contains 'label') { $errors.Add("RETIRED: packages/$pkg/onboarding/sections.json '$($s.key)' traegt noch 'label' — der Text steht im Katalog ($pkg.onboarding.$($s.key)).") }
            elseif ([string]::IsNullOrWhiteSpace([string]$deLc."$pkg.onboarding.$($s.key)")) { $errors.Add("ONBOARDING: packages/$pkg/locales/de.json hat keinen Text '$pkg.onboarding.$($s.key)'.") }
        }
    }
    if ($mf.PSObject.Properties.Name -contains 'context_skeletons' -and $null -ne $mf.context_skeletons) {
        $vals = @()
        if ($mf.PSObject.Properties.Name -contains 'context_validators' -and $null -ne $mf.context_validators) {
            $vals = @($mf.context_validators.PSObject.Properties | Where-Object { $_.Name -ne '_comment' } | ForEach-Object { $_.Name })
        }
        foreach ($p in $mf.context_skeletons.PSObject.Properties) {
            if ($p.Name -eq '_comment') { continue }
            if ($vals -notcontains $p.Name) {
                $errors.Add("FACTS-SKELETT: packages/$pkg/manifest.json context_skeletons '$($p.Name)' hat keinen context_validators-Eintrag -- das Skelett waere ueber den Haushalts-Schreibpfad nie beschreibbar.")
            }
            $scope = if ($mf.PSObject.Properties.Name -contains 'context_scopes' -and $null -ne $mf.context_scopes -and $mf.context_scopes.PSObject.Properties.Name -contains $p.Name) { [string]$mf.context_scopes.($p.Name).scope } else { '' }
            if ($scope -eq 'per_user') {
                $errors.Add("FACTS-SKELETT: packages/$pkg/manifest.json context_skeletons '$($p.Name)' ist per_user -- ein Skelett ohne Personen-Suffix wuerde nie beschrieben (per_user legt fn_set_context_facts beim ersten Schreiben als <base>__<person_id> an).")
            }
            if ($null -eq $p.Value.facts -or $p.Value.facts -isnot [System.Management.Automation.PSCustomObject]) {
                $errors.Add("FACTS-SKELETT: packages/$pkg/manifest.json context_skeletons '$($p.Name)' braucht ein 'facts'-Objekt (Start-Sidecar).")
            }
        }
    }
}

# ---------------------------------------------------------------
# (16) FAKTEN-SCHICHT (Phase A, docs/package-contract.md §2/§3.3):
#     (a) Gegenrichtung zu 15b: jeder household-skopierte context_validators-Key braucht ein context_skeletons-
#         Eintrag — agent.fn_set_context_facts legt household-Zeilen NIE selbst an (Sichtbarkeit agent_name ist
#         paket-deklariert); ohne Skelett waere der Kontext im Betrieb nie beschreibbar.
#     (b) kein facts_display-Block mehr: die HITL-Beschriftungen der Fakten-Kontexte stehen im Textkatalog des
#         Pakets (<pkg>.facts.<ctx>.title/.<feld>; locale_lint prueft den Titel je context_validators-Kontext).
#     (c) advisors.<domain>.learn_notes=true nur fuer einen household-Plan-Kontext (per_user-Plan-Dokumente
#         sind suffigiert, core.fn_note_context_allowed vergleicht exakt -> ein Opt-in waere tot).
#     (d) keine Workflow-id in zwei Dateien (Rename ohne git mv -> import:workflow nimmt eine der beiden still).
#     (e) retired_workflows: eine stillgelegte id liegt nicht mehr im Baum und kein getrackter Workflow verweist
#         auf sie (sonst loeschte retire_workflows einen lebenden Pfad).
#     (f) retired_credentials: jeder Eintrag traegt name + type (Typ-Abgleich beim Loeschen) + env_keys-Liste; ein
#         stillgelegter Name steht NICHT im aktuellen credentials-Block und ein stillgelegter env-Key gehoert keinem
#         aktuellen Credential (sonst loeschte retire_credentials eine lebende Credential / einen lebenden Schluessel).
#     (Der Ratchet "Core nennt keinen Paket-Kontext-Namen" lebt in scripts/core_literal_lint.ps1 — Phase A hat
#      dessen Literal-Set um die manifest-deklarierten Kontext-Namen erweitert, kein zweiter Mechanismus.)
# ---------------------------------------------------------------
foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue)) {
    $pkg = $pdir.Name
    $mf  = Read-Manifest $pkg
    if ($null -eq $mf) { continue }
    $prop = { param($o, $n) if ($o.PSObject.Properties.Name -contains $n -and $null -ne $o.$n) { $o.$n } else { $null } }
    $vals   = @(); $v = & $prop $mf 'context_validators'; if ($v) { $vals = @($v.PSObject.Properties | Where-Object { $_.Name -ne '_comment' } | ForEach-Object { $_.Name }) }
    $scopes = & $prop $mf 'context_scopes'
    $skels  = @(); $s = & $prop $mf 'context_skeletons'; if ($s) { $skels = @($s.PSObject.Properties | Where-Object { $_.Name -ne '_comment' } | ForEach-Object { $_.Name }) }
    $scopeOf = { param($n) if ($scopes -and $scopes.PSObject.Properties.Name -contains $n) { [string]$scopes.$n.scope } else { 'household' } }
    # (a)
    foreach ($n in $vals) {
        if ((& $scopeOf $n) -eq 'household' -and $skels -notcontains $n) {
            $errors.Add("FACTS-SKELETT FEHLT: packages/$pkg/manifest.json context_validators '$n' ist household-skopiert, hat aber kein context_skeletons-Eintrag -- agent.fn_set_context_facts legt household-Zeilen nie selbst an (Kontext waere nie beschreibbar).")
        }
    }
    # (b) facts_display ist abgeloest: die Beschriftungen leben im Textkatalog (<pkg>.facts.<ctx>.*, locale_lint)
    if ($null -ne (& $prop $mf 'facts_display')) {
        $errors.Add("FACTS-DISPLAY: packages/$pkg/manifest.json traegt noch einen facts_display-Block -- die Beschriftungen gehoeren in packages/$pkg/locales/*.json ($pkg.facts.<kontext>.title / .<feld>).")
    }
    # (c)
    $adv = & $prop $mf 'advisors'
    if ($adv) {
        foreach ($p in $adv.PSObject.Properties) {
            if ($p.Name -eq '_comment') { continue }
            # Typ-Check (Muster CALLBACK-SCHEMA member_permeable): der Seeder liest learn_notes STRIKT boolean -> ein
            # "true"-String/1 wuerde still als false geseedet; hier laut melden.
            if ($p.Value.PSObject.Properties.Name -contains 'learn_notes' -and $p.Value.learn_notes -isnot [bool]) {
                $errors.Add("LEARN-NOTES: packages/$pkg/manifest.json advisors '$($p.Name)'.learn_notes muss boolean sein (true/false), nicht '$($p.Value.learn_notes)' -- der Seeder wertet sonst still false.")
            }
            # Roter Faden: own_review_cron (eigener Review-Cron -> die geteilten Advisor-Crons lassen die Domaene aus)
            # liest der Seeder ebenso STRIKT boolean.
            if ($p.Value.PSObject.Properties.Name -contains 'own_review_cron' -and $p.Value.own_review_cron -isnot [bool]) {
                $errors.Add("OWN-REVIEW-CRON: packages/$pkg/manifest.json advisors '$($p.Name)'.own_review_cron muss boolean sein (true/false), nicht '$($p.Value.own_review_cron)' -- der Seeder wertet sonst still false.")
            }
            if ($p.Value.PSObject.Properties.Name -contains 'learn_notes' -and $p.Value.learn_notes -eq $true -and (& $scopeOf ([string]$p.Value.plan_context)) -ne 'household') {
                $errors.Add("LEARN-NOTES: packages/$pkg/manifest.json advisors '$($p.Name)' setzt learn_notes=true fuer den per_user-Plan-Kontext '$($p.Value.plan_context)' -- core.fn_note_context_allowed vergleicht exakt (suffigierte Plan-Dokumente) -> wirkungslos.")
            }
        }
    }
    # (e)
    $rw = & $prop $mf 'retired_workflows'
    if ($rw -and $rw.PSObject.Properties.Name -contains 'list') {
        foreach ($r in @($rw.list)) {
            $rid = [string]$r.id
            if ([string]::IsNullOrEmpty($rid) -or [string]::IsNullOrEmpty([string]$r.name)) { $errors.Add("RETIRED-WORKFLOW: packages/$pkg/manifest.json retired_workflows-Eintrag ohne id/name."); continue }
            if ($workflows.ContainsKey($rid)) { $errors.Add("RETIRED-WORKFLOW: packages/$pkg/manifest.json retired id '$rid' ($($r.name)) liegt noch im Baum ($($workflows[$rid].File)) -- retire_workflows wuerde einen ausgelieferten Workflow loeschen.") }
            foreach ($w in $workflows.Values) {
                if ((ConvertTo-Json $w.Json -Depth 50 -Compress) -match [regex]::Escape($rid)) {
                    $errors.Add("RETIRED-WORKFLOW: $($w.Name) verweist auf die stillgelegte id '$rid' ($($r.name)) -- erst den Verweis entfernen.")
                }
            }
        }
    }
    # (f)
    $rc = & $prop $mf 'retired_credentials'
    if ($rc -and $rc.PSObject.Properties.Name -contains 'list') {
        $liveNames = @(); $liveKeys = @()
        $cr = & $prop $mf 'credentials'
        if ($cr) {
            foreach ($c in @($cr.PSObject.Properties | Where-Object { $_.Name -ne '_comment' })) {
                $liveNames += [string]$c.Value.name
                if ($null -ne $c.Value.env) { $liveKeys += @($c.Value.env.PSObject.Properties | ForEach-Object { $_.Name }) }
            }
        }
        foreach ($r in @($rc.list)) {
            $rn = [string]$r.name
            if ([string]::IsNullOrEmpty($rn) -or [string]::IsNullOrEmpty([string]$r.type) -or
                -not ($r.PSObject.Properties.Name -contains 'env_keys') -or $r.env_keys -isnot [array]) {
                $errors.Add("RETIRED-CREDENTIAL: packages/$pkg/manifest.json retired_credentials-Eintrag braucht name, type und eine env_keys-Liste (ggf. leer).")
                continue
            }
            if ($liveNames -contains $rn) { $errors.Add("RETIRED-CREDENTIAL: packages/$pkg/manifest.json '$rn' ist stillgelegt UND im aktuellen credentials-Block -- retire_credentials wuerde eine lebende Credential loeschen.") }
            foreach ($k in @($r.env_keys)) {
                if ($liveKeys -contains [string]$k) { $errors.Add("RETIRED-CREDENTIAL: packages/$pkg/manifest.json env-Key '$k' ('$rn') ist stillgelegt, gehoert aber einem aktuellen Credential -- retire_credentials wuerde einen lebenden Schluessel loeschen.") }
            }
        }
    }
}
# (d)
foreach ($d in $wfIdDupes) { $errors.Add("WORKFLOW-ID DOPPELT: $d -- eine id gehoert genau einer Datei (Rename per git mv, nicht kopieren).") }

# ---------------------------------------------------------------
# (17) E2E-HOOK + (18) MONITOR-METHODEN-BLOCK (Phase B — Core kennt kein Paket)
# ---------------------------------------------------------------
$seenMethods = @{}
foreach ($pdir in (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'core' })) {
    $pkg = $pdir.Name
    $mf  = Read-Manifest $pkg
    if ($null -eq $mf) { continue }
    $migDir = Join-Path $pdir.FullName 'db\migrations'
    $fnText = ''
    if (Test-Path $migDir) {
        $fnText = (Get-ChildItem $migDir -Filter 'R__*.sql' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName, $Utf8NoBom) }) -join "`n"
    }
    # (17) eigenes Schema = eine Baseline-Init legt CREATE SCHEMA <pkg> an
    $ownsSchema = @(Get-ChildItem (Join-Path $pdir.FullName 'db') -Filter '*_init.sql' -ErrorAction SilentlyContinue |
        Where-Object { [System.IO.File]::ReadAllText($_.FullName, $Utf8NoBom) -match "(?im)CREATE\s+SCHEMA\s+IF\s+NOT\s+EXISTS\s+$([regex]::Escape($pkg))\s*;" }).Count -gt 0
    if ($ownsSchema -and $fnText -notmatch "(?is)CREATE\s+(OR\s+REPLACE\s+)?FUNCTION\s+$([regex]::Escape($pkg))\.fn_clear_e2e_data\s*\(\s*p_runid\s+text") {
        $errors.Add("E2E-HOOK FEHLT: packages/$pkg hat ein eigenes Schema, aber keinen Konventions-Hook $pkg.fn_clear_e2e_data(p_runid text) in packages/$pkg/db/migrations/R__*.sql -- agent.fn_clear_e2e_data bricht sonst ab (paperless-Muster: expliziter No-op, wenn das Paket keine E2E-Daten hat).")
    }
    # (18)
    if ($mf.PSObject.Properties.Name -contains 'monitor_acquisition_methods' -and $null -ne $mf.monitor_acquisition_methods) {
        foreach ($p in $mf.monitor_acquisition_methods.PSObject.Properties) {
            if ($p.Name -eq '_comment') { continue }
            $m = $p.Name
            if ($p.Value -isnot [PSCustomObject]) {
                $errors.Add("MONITOR-METHODE-SCHEMA: packages/$pkg/manifest.json monitor_acquisition_methods '$m' muss ein Objekt {acquire_fn, validate_fn, params_description} sein.")
                continue
            }
            if ($m -notmatch '^[a-z][a-z0-9_]*$' -or $m -in 'web_search', 'sql', 'none') {
                $errors.Add("MONITOR-METHODE: packages/$pkg/manifest.json monitor_acquisition_methods '$m' -- Name muss ^[a-z][a-z0-9_]*`$ sein und darf kein Core-Builtin (web_search|sql|none) ueberschreiben.")
            }
            if ($seenMethods.ContainsKey($m)) { $errors.Add("MONITOR-METHODE: '$m' von zwei Paketen deklariert ($($seenMethods[$m]), $pkg) -- Methoden sind global eindeutig (PK).") } else { $seenMethods[$m] = $pkg }
            foreach ($k in 'acquire_fn', 'validate_fn') {
                $fn = [string]$p.Value.$k
                if ($fn -notmatch "^$([regex]::Escape($pkg))\.fn_[a-z0-9_]+$") {
                    $errors.Add("MONITOR-METHODE: packages/$pkg/manifest.json '$m'.$k='$fn' muss eine fn im eigenen Schema sein ($pkg.fn_...).")
                } elseif ($fnText -notmatch "(?is)CREATE\s+(OR\s+REPLACE\s+)?FUNCTION\s+$([regex]::Escape($fn))\s*\(\s*p\s+jsonb\s*\)") {
                    $errors.Add("MONITOR-METHODE: packages/$pkg/manifest.json '$m'.$k -> $fn(p jsonb) ist in packages/$pkg/db/migrations/R__*.sql nicht definiert (tote Registry-Zeile).")
                }
            }
            # Die nutzer-sichtbare Bezeichnung steht im Textkatalog (<pkg>.monitor_method.<methode>, locale_lint prueft
            # die Vollstaendigkeit); im Manifest nur die LLM-Beschreibung (wird in die Monitor-Tool-Beschreibungen gebacken).
            $t = [string]$p.Value.params_description
            if ([string]::IsNullOrWhiteSpace($t) -or $t.Contains('`') -or $t.Contains('${')) {
                $errors.Add("MONITOR-METHODE: packages/$pkg/manifest.json '$m'.params_description leer oder mit Backtick/'`${' -- wird in die Tool-Beschreibung gebacken.")
            }
            if ($p.Value.PSObject.Properties.Name -contains 'label') {
                $errors.Add("MONITOR-METHODE: packages/$pkg/manifest.json '$m'.label -- die Bezeichnung gehoert in den Textkatalog ($pkg.monitor_method.$m in packages/$pkg/locales/*.json), nicht ins Manifest.")
            }
        }
    }
}
# (18b) core deklariert KEINEN Block: Core-Methoden sind Builtin-Zeilen in core.monitor_acquisition_methods_init.sql
# (der Seed wuerde einen core-Block sonst ungeprueft annehmen).
$coreMf = Read-Manifest 'core'
if ($null -ne $coreMf -and $coreMf.PSObject.Properties.Name -contains 'monitor_acquisition_methods') {
    $errors.Add("MONITOR-METHODE: packages/core/manifest.json darf keinen Block monitor_acquisition_methods tragen -- Core-Methoden sind Builtin-Zeilen in packages/core/db/core.monitor_acquisition_methods_init.sql.")
}

# ---------------------------------------------------------------
# (19) AGENTEN-ROUTING (Phase C — Core-Prompt kennt kein Paket): provides.agents ALLER Manifeste inkl. core
#      durch DIESELBE Pruef-Funktion wie build.ps1 (scripts/build/lib/agent_routing.ps1 -> erlaubte
#      fallback_for-Arten an EINER Adresse): (a) Pflicht-router_description, (b) agent.<x> in einer Beschreibung
#      ist deklariert (Verweis auf ein im Repo ABWESENDES Paket = Warnung; Beinahe-Treffer = Fehler), (c) fallback_for Liste/erlaubte Art/nicht am orchestrator/hoechstens ein Agent je Art.
#      Der Build bricht bei denselben Verstoessen ab; hier die fruehere Commit-Meldung + Selbst-Asserts.
# ---------------------------------------------------------------
. (Join-Path $RepoRoot 'scripts\build\lib\agent_routing.ps1')
$routingMfs = @(Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $mfr = Read-Manifest $_.Name
    if ($null -ne $mfr) { @{ Path = "packages/$($_.Name)/manifest.json"; Json = $mfr } }
})
$routingRes = Get-AgentRouting $routingMfs
foreach ($re in $routingRes.Errors)   { $errors.Add("AGENTEN-ROUTING: $re") }
foreach ($rw in $routingRes.Warnings) { $warns.Add("AGENTEN-ROUTING: $rw") }
# Selbst-Asserts: jeder synthetische Verstoss MUSS genau als Fehler erkannt werden (stirbt die Pruefung still,
# waere Check 19 wertlos); der saubere Fall MUSS fehlerfrei bleiben.
function New-SynthMf([string]$Agents) { @{ Path = 'synthetic'; Json = ('{"name":"zzp","provides":{"agents":[' + $Agents + ']}}' | ConvertFrom-Json) } }
$synthOk = 'ok sentence. NOT for x -> agent.zzb.'
$synth = @(
    @{ n = 'sauber';                 mfs = @((New-SynthMf ('{"name":"zza","router_description":"' + $synthOk + '","order":1,"fallback_for":["attachment"]},{"name":"zzb","router_description":"b","order":2}'))); want = 0 },
    @{ n = 'leere Beschreibung';     mfs = @((New-SynthMf '{"name":"zza","router_description":"","order":1}')); want = 1 },
    @{ n = 'Tippfehler (Paket vorhanden)'; mfs = @((New-SynthMf '{"name":"zza","router_description":"NOT -> agent.zzp_advisr.","order":1}')); want = 1 },
    @{ n = 'Verweis auf abwesendes Paket'; mfs = @((New-SynthMf '{"name":"zza","router_description":"NOT -> agent.qqqqqq_advisor.","order":1}')); want = 0; warn = 1 },
    @{ n = 'Beinahe-Treffer (Tippfehler Agent)'; mfs = @((New-SynthMf '{"name":"zza","router_description":"x","order":1},{"name":"zzb","router_description":"NOT -> agent.zzaa.","order":2}')); want = 1 },
    @{ n = 'fallback_for als String'; mfs = @((New-SynthMf '{"name":"zza","router_description":"a","order":1,"fallback_for":"attachment"}')); want = 1 },
    @{ n = 'fallback_for unbekannt';  mfs = @((New-SynthMf '{"name":"zza","router_description":"a","order":1,"fallback_for":["voice"]}')); want = 1 },
    @{ n = 'fallback_for doppelt beansprucht'; mfs = @((New-SynthMf '{"name":"zza","router_description":"a","order":1,"fallback_for":["attachment"]},{"name":"zzb","router_description":"b","order":2,"fallback_for":["attachment"]}')); want = 1 },
    @{ n = 'fallback_for am orchestrator'; mfs = @((New-SynthMf '{"name":"orchestrator","router_description":"","order":0,"fallback_for":["attachment"]}')); want = 1 }
)
foreach ($sc in $synth) {
    $res = Get-AgentRouting $sc.mfs
    $got = @($res.Errors).Count
    if ($got -ne $sc.want) { $errors.Add("AGENTEN-ROUTING SELBST-ASSERT '$($sc.n)': erwartet $($sc.want) Fehler, gefunden $got -- die Pruefung in lib/agent_routing.ps1 ist defekt.") }
    $wantW = if ($sc.ContainsKey('warn')) { $sc.warn } else { 0 }
    if (@($res.Warnings).Count -ne $wantW) { $errors.Add("AGENTEN-ROUTING SELBST-ASSERT '$($sc.n)': erwartet $wantW Warnung(en), gefunden $(@($res.Warnings).Count) -- lib/agent_routing.ps1 defekt.") }
}

# ---------------------------------------------------------------
# (19b) ONBOARDING-REIHENFOLGE (Menue/Weiter-Knopf): abgeleitet aus consumes (lib/agent_routing.ps1
#      Get-OnboardingPackageOrder, dieselbe Funktion wie build.ps1). Live: die Repo-Manifeste muessen sich ordnen
#      lassen (kein Zyklus). Selbst-Asserts: Konsument nach Lieferant, Gleichstand haushaltsweit vor per_user, dann
#      Name; Zyklus wirft.
# ---------------------------------------------------------------
try { $null = Get-OnboardingPackageOrder $RepoRoot } catch { $errors.Add("ONBOARDING-REIHENFOLGE: $($_.Exception.Message)") }
function New-SynthOnbMf([string]$Name, [string]$Body) { @{ Path = "synthetic/$Name"; Json = ('{"name":"' + $Name + '"' + $Body + '}' | ConvertFrom-Json) } }
$onbSynth = @(
    @{ n = 'Konsument nach Lieferant'; want = 'zza,zzb'
       mfs = @((New-SynthOnbMf 'zzb' ',"consumes":{"reads":["zza.fn_x()"]}'), (New-SynthOnbMf 'zza' '')) },
    @{ n = 'Dienst-Konsum zaehlt';     want = 'zzb,zza'
       mfs = @((New-SynthOnbMf 'zza' ',"consumes":{"services":["zzb:svc"]}'), (New-SynthOnbMf 'zzb' '')) },
    @{ n = 'haushaltsweit vor per_user'; want = 'zzb,zza'
       mfs = @((New-SynthOnbMf 'zza' ',"context_scopes":{"c":{"scope":"per_user"}}'), (New-SynthOnbMf 'zzb' '')) },
    @{ n = 'Gleichstand nach Name';    want = 'zza,zzb'
       mfs = @((New-SynthOnbMf 'zzb' ''), (New-SynthOnbMf 'zza' '')) }
)
foreach ($sc in $onbSynth) {
    $got = (@(Get-OnboardingOrderFromManifests $sc.mfs) | ForEach-Object { $_.Package }) -join ','
    if ($got -ne $sc.want) { $errors.Add("ONBOARDING-REIHENFOLGE SELBST-ASSERT '$($sc.n)': erwartet $($sc.want), gefunden $got -- lib/agent_routing.ps1 defekt.") }
}
$cycThrown = $false
try { $null = Get-OnboardingOrderFromManifests @((New-SynthOnbMf 'zza' ',"consumes":{"reads":["zzb.f()"]}'), (New-SynthOnbMf 'zzb' ',"consumes":{"reads":["zza.f()"]}')) } catch { $cycThrown = $true }
if (-not $cycThrown) { $errors.Add("ONBOARDING-REIHENFOLGE SELBST-ASSERT 'Zyklus': kein Abbruch -- lib/agent_routing.ps1 defekt.") }

# ---------------------------------------------------------------
# (20) UTF-8-PFLICHT BEI DB-ANLAGE: postgresql-common/initdb/createdb erben sonst die Systemsprache — auf einer
# Proxmox-Debian-Vorlage (LANG="C") wird daraus SQL_ASCII, Umlaute sind nur noch Bytes (v0.4.0-Abbruch am
# config_summary_single_line-CHECK). Fortsetzungszeilen (`\` am Ende) werden zu einer Anweisung verbunden.
# ---------------------------------------------------------------
#   Anweisungs-Grenzen: Shell/PS = Zeile (+ `\`-Fortsetzung), SQL = bis `;` (mehrzeiliges CREATE DATABASE … ENCODING).
#   pg_restore --create matcht die Stichwoerter nicht -> braucht keine Ausnahme (uebernimmt die Kodierung der Sicherung).
function Get-NonUtf8DbCreate([string[]]$Lines, [switch]$Sql) {
    $stmts = New-Object System.Collections.Generic.List[string]
    $buf = ''
    foreach ($l in $Lines) {
        $t = $l.Trim()
        if ($buf -eq '' -and ($t.StartsWith('#') -or $t.StartsWith('--'))) { continue }
        if ($Sql) {
            $buf += $t + ' '
            if ($t.EndsWith(';')) { $stmts.Add($buf); $buf = '' }
            continue
        }
        if ($t.EndsWith('\')) { $buf += $t.TrimEnd('\') + ' '; continue }
        $stmts.Add($buf + $t); $buf = ''
    }
    if ($buf) { $stmts.Add($buf) }
    @($stmts | Where-Object { $_ -match '(?i)\b(createdb|pg_createcluster|initdb)\b|\bCREATE\s+DATABASE\b' -and $_ -notmatch '(?i)UTF-?8' })
}
$utf8Files = @(git -C $RepoRoot ls-files -- 'provisioning' 'packages' 'scripts' | Where-Object { $_ -match '\.(sh|sql|tpl|conf|ps1)$' -and $_ -ne 'scripts/contract_lint.ps1' })
foreach ($f in $utf8Files) {
    $lines = [System.IO.File]::ReadAllLines((Join-Path $RepoRoot $f), $Utf8NoBom)
    foreach ($s in (Get-NonUtf8DbCreate $lines -Sql:($f -like '*.sql'))) {
        $errors.Add("UTF-8-PFLICHT: $f legt eine Datenbank/einen Cluster ohne ausdrueckliches UTF8 an -- '$($s.Substring(0, [Math]::Min(120, $s.Length)))'. Encoding UTF8 + Locale C.UTF-8 angeben (sonst erbt sie die Systemsprache).")
    }
}
$utf8Synth = @(
    @{ n = 'createdb ohne Kodierung';      l = @('  _pg_super createdb -O "$U" "$DB"');                                   want = 1 },
    @{ n = 'createdb mit UTF8';            l = @('  _pg_super createdb -O "$U" -E UTF8 --locale=C.UTF-8 -T template0 "$DB"'); want = 0 },
    @{ n = 'Fortsetzungszeile ohne UTF8';  l = @('createdb -O u \', '  -T template0 db');                                 want = 1 },
    @{ n = 'Fortsetzungszeile mit UTF8';   l = @('createdb -O u \', '  -E UTF8 -T template0 db');                         want = 0 },
    @{ n = 'CREATE DATABASE ohne';         l = @("psql -c 'CREATE DATABASE x'");                                          want = 1 },
    @{ n = 'pg_createcluster ohne';        l = @('pg_createcluster 17 main --start');                                     want = 1 },
    @{ n = 'Fortsetzung mit pg_restore';   l = @('createdb -O u db \', '  && pg_restore -d db dump');                    want = 1 },
    @{ n = 'Kommentar frei';               l = @('# createdb legt die DB an');                                            want = 0 },
    @{ n = 'SQL mehrzeilig mit UTF8';      l = @('CREATE DATABASE x', "  ENCODING 'UTF8' TEMPLATE template0;");          want = 0; sql = $true },
    @{ n = 'SQL mehrzeilig ohne';          l = @('CREATE DATABASE x', '  TEMPLATE template0;');                           want = 1; sql = $true }
)
foreach ($sc in $utf8Synth) {
    $got = @(Get-NonUtf8DbCreate $sc.l -Sql:([bool]$sc.sql)).Count
    if ($got -ne $sc.want) { $errors.Add("UTF-8-PFLICHT SELBST-ASSERT '$($sc.n)': erwartet $($sc.want) Treffer, gefunden $got -- Check 20 ist defekt.") }
}

# (21) ECHTE UMLAUTE IN SICHTBAREN TEXTEN (Manifest-config-summary, SQL-Text-Literale der R__-fns). Die festen
#      Nutzertexte (Paketnamen, Menues, Toasts, /help, Onboarding-Labels) stehen seit Phase B im Textkatalog -> dort
#      prueft locale_lint die Umlaute.
. (Join-Path $RepoRoot 'scripts\build\lib\umlaut.ps1')
foreach ($mfFile in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json'))) {
    $mj = [System.IO.File]::ReadAllText($mfFile.FullName, $Utf8NoBom) | ConvertFrom-Json
    $pkg = [string]$mj.name
    $vis = @()
    if ($mj.config) { foreach ($cat in $mj.config.PSObject.Properties) { if ($cat.Value -is [psobject]) {
        foreach ($k in $cat.Value.PSObject.Properties) { if ($k.Value -is [psobject] -and $k.Value.summary) { $vis += ,@("config.$($cat.Name).$($k.Name).summary", $k.Value.summary) } } } } }
    foreach ($v in $vis) {
        $h = @(Find-UmlautSubstitute ([string]$v[1]))
        if ($h.Count) { $errors.Add("UMLAUTE: packages/$pkg/manifest.json $($v[0]) -- Ersatzschreibweise statt echter Umlaute: $($h -join ', ')") }
    }
}
foreach ($f in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\db\migrations\R__*.sql'))) {
    $ln = 0
    foreach ($l in [System.IO.File]::ReadAllLines($f.FullName, $Utf8NoBom)) {
        $ln++
        $code = ($l -replace '--.*$', '')
        foreach ($m in [regex]::Matches($code, "'((?:[^']|'')*)'")) {
            if ($m.Groups[1].Value -cnotmatch '[A-Z ]') { continue }
            $h = @(Find-UmlautSubstitute $m.Groups[1].Value)
            if ($h.Count) { $errors.Add("UMLAUTE: $($f.Directory.Parent.Parent.Name)/$($f.Name):$ln -- Ersatzschreibweise im Text-Literal: $($h -join ', ')") }
        }
    }
}

# (22) JQ-BOOL-DEFAULT: `.x // true` ersetzt auch ein GESETZTES false (jq-`//` greift bei null UND false). So wurde
#      cron_labels.person.score_jobs.default_enabled=false still zu true (Substrat-Befund 2026-10-23). Boolesche
#      Defaults mit true per `if has("x") then .x else true end`; `// false` ist harmlos (false bleibt false).
function Get-JqTrueDefault([string[]]$Lines) {
    @($Lines | Where-Object { -not $_.Trim().StartsWith('#') -and $_ -match '//\s*true\b' })
}
foreach ($f in @(git -C $RepoRoot ls-files -- 'provisioning' 'scripts' | Where-Object { $_ -match '\.sh$' })) {
    foreach ($l in (Get-JqTrueDefault ([System.IO.File]::ReadAllLines((Join-Path $RepoRoot $f), $Utf8NoBom)))) {
        $errors.Add("JQ-BOOL-DEFAULT: $f -- '$($l.Trim())': jq '// true' macht aus einem gesetzten false ein true. Stattdessen: if has(""<feld>"") then .<feld> else true end.")
    }
}
foreach ($sc in @(
    @{ n = 'true-Default';   l = @('jq -r ''.value.default_enabled // true'' f'); want = 1 },
    @{ n = 'false-Default';  l = @('jq -r ''.value.required // false'' f');       want = 0 },
    @{ n = 'has-Form';       l = @('jq -r ''if has("x") then .x else true end'''); want = 0 },
    @{ n = 'Kommentar frei'; l = @('  # jq: `// true` waere falsch');              want = 0 })) {
    $got = @(Get-JqTrueDefault $sc.l).Count
    if ($got -ne $sc.want) { $errors.Add("JQ-BOOL-DEFAULT SELBST-ASSERT '$($sc.n)': erwartet $($sc.want) Treffer, gefunden $got -- Check 22 ist defekt.") }
}

# (23) GH-DOWNLOAD-SPIEGEL: der Release-Download (Status-Erfassung, Abbruch-/Limit-/404-Meldungen, Redirect nur https,
#      Tag-Sanity) steht zweimal — im self-contained Bootstrap provisioning/install.sh und in der Runtime
#      provisioning/lib/fetch_release.sh (`lifeagents update`), bewusste rustup-Doppelung. Der Block zwischen
#      `# >>> gh-download` und `# <<< gh-download` muss in beiden Dateien byte-gleich sein, sonst verhalten sich
#      Erstinstallation und Update verschieden (ein Fix nur in einer Kopie).
function Get-GhDownloadBlock([string]$Text) {
    # Marker am Zeilenanfang: Kopf-Kommentare erwaehnen `# >>> gh-download` mitten in der Zeile.
    $m = [regex]::Match($Text, '(?ms)^# >>> gh-download.*?^# <<< gh-download')
    if ($m.Success) { $m.Value } else { $null }
}
$ghBlocks = @{}
foreach ($f in 'provisioning/install.sh', 'provisioning/lib/fetch_release.sh') {
    $p = Join-Path $RepoRoot $f
    $b = if (Test-Path $p) { Get-GhDownloadBlock ([System.IO.File]::ReadAllText($p, $Utf8NoBom)) } else { $null }
    if ($null -eq $b) { $errors.Add("GH-DOWNLOAD-SPIEGEL: $f -- Block '# >>> gh-download' ... '# <<< gh-download' fehlt.") } else { $ghBlocks[$f] = $b }
}
if ($ghBlocks.Count -eq 2 -and $ghBlocks['provisioning/install.sh'] -cne $ghBlocks['provisioning/lib/fetch_release.sh']) {
    $errors.Add("GH-DOWNLOAD-SPIEGEL: der gh-download-Block in provisioning/install.sh und provisioning/lib/fetch_release.sh weicht ab -- beide Kopien byte-gleich halten (Aenderung in beide uebernehmen).")
}
foreach ($sc in @(
    @{ n = 'Block da';    t = "x`n# >>> gh-download`nf() { :; }`n# <<< gh-download`ny"; want = $true },
    @{ n = 'Block fehlt'; t = "x`nf() { :; }`n";                                         want = $false },
    @{ n = 'nur Erwaehnung'; t = "# siehe ``# >>> gh-download`` und ``# <<< gh-download```n";  want = $false })) {
    if (($null -ne (Get-GhDownloadBlock $sc.t)) -ne $sc.want) { $errors.Add("GH-DOWNLOAD-SPIEGEL SELBST-ASSERT '$($sc.n)' -- Check 23 ist defekt.") }
}

# (24) RELEASE-KEY-SPIEGEL: der oeffentliche Release-Signierschluessel steht zweimal — als Schluesselbund
#      provisioning/keys/release-signing.gpg (install_release_keyring legt ihn nach /etc) und base64-eingebettet in
#      provisioning/install.sh (RELEASE_KEY_B64, Erstinstallation). Beide muessen gleich sein (leer = das Projekt signiert
#      noch nicht, dann darf es auch keine Datei geben); scripts/new_release_key.ps1 schreibt beide.
$instTxt = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'provisioning\install.sh'), $Utf8NoBom)
$mKey = [regex]::Match($instTxt, "(?m)^RELEASE_KEY_B64='([A-Za-z0-9+/=]*)'$")
$keyPath = Join-Path $RepoRoot 'provisioning\keys\release-signing.gpg'
if (-not $mKey.Success) {
    $errors.Add("RELEASE-KEY-SPIEGEL: provisioning/install.sh -- Zeile RELEASE_KEY_B64='<base64>' fehlt.")
} else {
    $want = if (Test-Path $keyPath) { [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($keyPath)) } else { '' }
    if ($mKey.Groups[1].Value -cne $want) {
        $errors.Add("RELEASE-KEY-SPIEGEL: RELEASE_KEY_B64 in provisioning/install.sh passt nicht zu provisioning/keys/release-signing.gpg -- beide ueber scripts/new_release_key.ps1 setzen.")
    }
}

# ---------------------------------------------------------------
# (25) PERSONA-STIL-PARITAET
# ---------------------------------------------------------------
# Jede Persona aus dem Core-Manifest personas.list (ausser neutral = keine Persona) hat genau einen Abschnitt
# '### <code>' in packages/core/contexts/persona_styles.md, und jeder Abschnitt dort ist eine Persona der Liste —
# sonst waehlte der Picker eine Persona ohne Stil-Regeln (Haiku erfaende sie) bzw. laege toter Stil-Text im Prompt.
$personaMf = ([System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\manifest.json'), $Utf8NoBom) | ConvertFrom-Json).personas
$personaCodes = @(@($personaMf.list) | ForEach-Object { [string]$_.code } | Where-Object { $_ -ne 'neutral' })
$styleFile = Join-Path $RepoRoot 'packages\core\contexts\persona_styles.md'
if (-not (Test-Path $styleFile)) {
    if ($personaCodes.Count) { $errors.Add("PERSONA-STIL: packages/core/contexts/persona_styles.md fehlt, personas.list nennt $($personaCodes -join ', ').") }
} else {
    $styleSections = @([regex]::Matches([System.IO.File]::ReadAllText($styleFile, $Utf8NoBom), '(?m)^### ([a-z_]+)\s*$') | ForEach-Object { $_.Groups[1].Value })
    foreach ($c in $personaCodes) {
        $n = @($styleSections | Where-Object { $_ -eq $c }).Count
        if ($n -ne 1) { $errors.Add("PERSONA-STIL: Persona '$c' (personas.list) hat $n Abschnitt(e) '### $c' in persona_styles.md (erwartet genau 1).") }
    }
    foreach ($s in ($styleSections | Sort-Object -Unique)) {
        if ($personaCodes -notcontains $s) { $errors.Add("PERSONA-STIL: Abschnitt '### $s' in persona_styles.md ist keine Persona aus personas.list (neutral hat keinen Abschnitt).") }
    }
}

# ---------------------------------------------------------------
# (27) ROHER DATUMS-CAST IM TOOL-SQL
# ---------------------------------------------------------------
$rawDateRe = '\$1::jsonb\)\s*->>\s*''([a-z_]+)''\s*(?:,\s*''''\s*\))?\)*\s*::\s*date\b'
foreach ($sc in @(
    @{ n = 'NULLIF-Cast';  t = 'NULLIF((`$1::jsonb)->>''reconciliation_date'', '''')::date'; want = 1 },
    @{ n = 'nackter Cast'; t = '((`$1::jsonb)->>''due_date'')::date';                        want = 1 },
    @{ n = 'aufgeloest';   t = 'core.fn_resolve_date(NULLIF((`$1::jsonb)->>''d'', ''''))';  want = 0 })) {
    $got = [regex]::Matches($sc.t, $rawDateRe).Count
    if ($got -ne $sc.want) { $errors.Add("ROHER-DATUMS-CAST SELBST-ASSERT '$($sc.n)': erwartet $($sc.want), gefunden $got -- Check 27 ist defekt.") }
}
Get-ChildItem -Path (Join-Path $RepoRoot 'packages') -Recurse -Filter '*.ps1' |
    Where-Object { $_.FullName -match '[\\/]build[\\/]workflows[\\/]' } | ForEach-Object {
        $rel = $_.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/'
        foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($_.FullName, $Utf8NoBom), $rawDateRe)) {
            $errors.Add("ROHER-DATUMS-CAST: $rel castet das Tool-Feld '$($m.Groups[1].Value)' direkt nach date -- relative Angaben (""yesterday"") brechen; core.fn_resolve_date nutzen bzw. der Write-fn ueberlassen (core.fn_resolve_input_dates).")
        }
    }

# ---------------------------------------------------------------
# (28) BERATER-INTERVIEW-KATALOG (Plan-Luecken 2026-10-27): finance.fn_plan_gaps traegt den Katalog der Interview-
#     Sektionen + ihrer Pflicht-Bloecke als Konstante (die DB meldet daraus die Luecken), der Berater-Prompt nennt
#     dieselben Keys unter "### Interview catalog" ("N. `key` ... **-> emits the `block` ...**"). Beide muessen in
#     Keys, Reihenfolge und Bloecken gleich sein — sonst gilt eine im Prompt umbenannte Sektion fuer immer als offen.
#     Dazu: "gates_advisor" in onboarding/sections.json ist, falls vorhanden, ein Boolean (fehlt = sperrt).
# ---------------------------------------------------------------
$gapFn  = Join-Path $pkgDir 'finance\db\migrations\R__fn_plan_gaps.sql'
$advCtx = Join-Path $pkgDir 'finance\contexts\finance_advisor_instructions.md'
if ((Test-Path $gapFn) -and (Test-Path $advCtx)) {
    $fnCat = @([regex]::Matches([System.IO.File]::ReadAllText($gapFn, $Utf8NoBom), '\{"key":"([a-z_]+)",\s*"blocks":\[([^\]]*)\]\}') |
        ForEach-Object { $_.Groups[1].Value + '=' + ((@([regex]::Matches($_.Groups[2].Value, '"([a-z_]+)"') | ForEach-Object { $_.Groups[1].Value })) -join '+') })
    $ctxText = [System.IO.File]::ReadAllText($advCtx, $Utf8NoBom)
    $catBody = (($ctxText -split '(?m)^### Interview catalog', 2)[-1] -split '(?m)^### ', 2)[0]
    $mdCat = @([regex]::Matches($catBody, '(?m)^\d+\. `([a-z_]+)`(.*)$') | ForEach-Object {
        $em = [regex]::Match($_.Groups[2].Value, 'emits the (.+?) blocks?\.')
        $_.Groups[1].Value + '=' + ((@(if ($em.Success) { [regex]::Matches($em.Groups[1].Value, '`([a-z_]+)`') | ForEach-Object { $_.Groups[1].Value } })) -join '+') })
    if ($fnCat.Count -eq 0 -or $mdCat.Count -eq 0) {
        $errors.Add("BERATER-KATALOG: Katalog nicht lesbar (fn_plan_gaps: $($fnCat.Count), Prompt: $($mdCat.Count) Eintraege) -- Check 28 ist defekt oder das Format hat sich geaendert.")
    } elseif (($fnCat -join ',') -ne ($mdCat -join ',')) {
        $errors.Add("BERATER-KATALOG: finance.fn_plan_gaps [$($fnCat -join ', ')] != finance_advisor_instructions.md 'Interview catalog' [$($mdCat -join ', ')] -- Keys, Reihenfolge und emittierte Bloecke muessen gleich sein.")
    }
}
foreach ($sf in (Get-ChildItem (Join-Path $pkgDir '*\onboarding\sections.json') -ErrorAction SilentlyContinue)) {
    foreach ($s in @([System.IO.File]::ReadAllText($sf.FullName, $Utf8NoBom) | ConvertFrom-Json)) {
        if ($s.PSObject.Properties.Name -contains 'gates_advisor' -and $s.gates_advisor -isnot [bool]) {
            $errors.Add("ONBOARDING gates_advisor: $($sf.Directory.Parent.Name)/onboarding/sections.json '$($s.key)' -- gates_advisor muss true/false sein (fehlt = sperrt den Berater).")
        }
    }
}

# ---------------------------------------------------------------
# Report
# ---------------------------------------------------------------
Write-Host ""
Write-Host "Contract-Lint (fn-SQL <-> Tool-Payload <-> Agent-Inputs, statisch)"
Write-Host ("-" * 60)
foreach ($e in ($errors | Sort-Object -Unique)) { Write-Host "  [FAIL] $e" -ForegroundColor Red }
if ($Verbose -or $errors.Count -eq 0) {
    foreach ($w in ($warns | Sort-Object -Unique)) { Write-Host "  [WARN] $w" -ForegroundColor Yellow }
} elseif ($warns.Count -gt 0) {
    Write-Host "  ($($warns.Count) Warnung(en) unterdrueckt -- mit -Verbose anzeigen)" -ForegroundColor DarkGray
}
Write-Host ("-" * 60)
$color = if ($errors.Count -eq 0) { 'Green' } else { 'Red' }
Write-Host "$($errors.Count) Contract-Lint-Error(s), $($warns.Count) Warnung(en)." -ForegroundColor $color
Write-Host ""
exit $errors.Count
