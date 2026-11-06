#Requires -Version 5.1
# THE Build-Orchestrator (ersetzt die alten build_*-Entrypoints). Generiert ALLE Workflow-JSONs
# nach packages/<pkg>/workflows/ — KEINE API-Calls (Deploy ins Substrat = bootstrap_test_n8n.ps1 -Reset; Prod = provision.sh).
#
# Einheitlicher Lifecycle: jede Build-Funktion liefert ein Workflow-Objekt OHNE id; Save-WorkflowFile
# (lib/workflow_lifecycle.ps1) loest die ID per Name aus dem State (getrackte <id>-name.json) auf und
# backt sie ein (bzw. schreibt eine id-lose Datei; eine neue ID vergibt der Autor selbst im Dateinamen,
# import:workflow erhaelt sie). ALLE Workflow-Cross-Refs (Tool-IDs, Harness-Ziele, Gate, errorWorkflow,
# load_config, load_context) werden per Get-WorkflowIdByName aus dem State aufgeloest — KEINE
# hardcodierten Workflow-ID-Literale. Credentials referenzieren die Defs ueber LESBARE Platzhalter-Tokens
# (__CRED_*__, analog __OWNER_CHAT_ID__), die der Deploy (inject_credentials/deploy_workflows) gegen die
# frisch geminteten ids tauscht.
#
# Usage:
#   .\scripts\build\build.ps1                       # alle Workflows bauen
#   .\scripts\build\build.ps1 -Only '*stock_sell*'  # nur passende (Glob auf den Workflow-Namen)
#   danach: .\scripts\dev\bootstrap_test_n8n.ps1 -Reset   # ins Docker-Substrat deployen (Prod: provision.sh)
#   .\scripts\build\build.ps1 -VerifyCatalog          # Drift-Check: getrackter Katalog == frisch generiert
#                                                       # (kein File-Write; Exit 1 bei Drift/Example-ohne-Case)
#   .\scripts\build\build.ps1 -CatalogOnly            # NUR den /help-Katalog neu schreiben (packages/core/seed/capabilities_catalog/<lang>.md + Paket-Fragmente)
#                                                       # (keine Workflow-JSONs anfassen)
param([string]$Only = '*', [switch]$VerifyCatalog, [switch]$CatalogOnly)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot     = git -C $PSScriptRoot rev-parse --show-toplevel
$Utf8NoBom    = New-Object System.Text.UTF8Encoding($false)
# $WorkflowsDir wird NACH dem Dot-Sourcen gesetzt (Get-WorkflowDirs lebt in workflow_lifecycle.ps1) —
# paket-bewusst: Such-Liste packages/*/workflows.

# --- env ---
Get-Content "$RepoRoot\.env" | ForEach-Object {
    if ($_ -match '^\s*([^#\s][^=]*)=(.*)$') { Set-Variable -Name $Matches[1].Trim() -Value $Matches[2].Trim() -Scope Script }
}
if ([string]::IsNullOrEmpty($OWNER_CHAT_ID))      { throw "OWNER_CHAT_ID nicht in .env" }

# --- Credentials: LESBARE Platzhalter-Tokens (__CRED_*__, analog __OWNER_CHAT_ID__), KEINE echten
#     ids/Secrets. inject_credentials.sh legt die Credential beim Deploy frisch an (Secret aus .env/
#     Installer) und deploy_workflows.sh tauscht den Platzhalter gegen die frische echte id. ---
# Host-Credentials (Core = Host; gleiche Namen wie inject_credentials.sh::_cred_host_placeholder_names).
$CRED_POSTGRES    = @{ id = '__CRED_POSTGRES_WRITE__'; name = 'Postgres account' }
$CRED_CORE_RO     = @{ id = '__CRED_POSTGRES_CORE_RO__'; name = 'Postgres core_ro (read-only)' }      # breiter Host-Lesepfad (monitor/guide/Gate-Resolve)
$CRED_CONTEXT_RO  = @{ id = '__CRED_POSTGRES_CONTEXT_RO__'; name = 'agent.core_contexts read-only' }   # nur core_contexts (load_context)
$CRED_TELEGRAM    = @{ id = '__CRED_TELEGRAM__'; name = 'Telegram account' }
$CRED_ANTHROPIC   = @{ id = '__CRED_ANTHROPIC__'; name = 'Anthropic account' }
$CRED_GEMINI      = @{ id = '__CRED_GEMINI__'; name = 'Google Gemini(PaLM) Api account' }
$CRED_HARNESS     = @{ id = '__CRED_HARNESS__'; name = 'lifeagents test harness auth' }   # nur Test-Harnesses (lib/harness.ps1)
$CRED_TELEGRAM_RELAY = @{ id = '__CRED_TELEGRAM_RELAY__'; name = 'Telegram relay (gateway)' }   # Bot-Token als Header fuer den Gateway-Relay (New-TelegramRelayNode)
$HostCredentialVars = @('CRED_POSTGRES', 'CRED_CORE_RO', 'CRED_CONTEXT_RO', 'CRED_TELEGRAM', 'CRED_ANTHROPIC', 'CRED_GEMINI', 'CRED_HARNESS', 'CRED_TELEGRAM_RELAY')

# Paket-Credentials (Phase D): aus den Manifesten abgeleitet (lib/credentials.ps1 — Rollen-Konvention
# <pkg>_rw/_ro + `credentials`-Block, dieselbe Formel wie der Installer). Enge Paket-Rollen (D10): ein
# Paket-Write-Tool setzt funktions-lokal $CRED_POSTGRES = $CRED_<PKG>_RW (Dynamic Scope -> Build-Pg sieht es),
# Lese-Nodes haengen $CRED_<PKG>_RO post-construction an. Script-Scope -> die dot-gesourcten Defs sehen sie.
. "$PSScriptRoot\lib\credentials.ps1"
$PackageCredentials = @(Get-PackageCredentialDescriptor $RepoRoot)
foreach ($c in $PackageCredentials) {
    if ($HostCredentialVars -contains $c.Var) { throw "credentials: Paket '$($c.Package)' leitet die Host-Variable `$$($c.Var) ab — Paketname/Platzhalter kollidiert mit dem Host." }
    Set-Variable -Name $c.Var -Value @{ id = $c.Id; name = $c.Name } -Scope Script
}

# --- Libs dot-sourcen (Helper + Cred-Sichtbarkeit im Script-Scope; Workflow-Defs erst NACH der
#     Cross-Ref-Aufloesung, weil manche Def (agent.finance) Infra-IDs schon im File-Scope liest) ---
. "$PSScriptRoot\lib\build_helpers.ps1"
. "$PSScriptRoot\lib\monitor_helpers.ps1"
. "$PSScriptRoot\lib\workflow_lifecycle.ps1"
. "$PSScriptRoot\lib\agent_cases.ps1"   # Test-Case-Dateien per Glob (Katalog-Example-Pool; auch mock_lint)
. "$PSScriptRoot\lib\catalog.ps1"
. "$PSScriptRoot\lib\harness.ps1"   # init $script:Harnesses=@() + Build-Harness/Get-HarnessWorkflow; Pakete appenden ihre Eintraege

# Paket-bewusste Workflow-Such-Liste (packages/*/workflows). Cross-Ref-Aufloesung
# (Get-WorkflowIdByName unten + in den Build-Defs) spannt damit alle Pakete; geschrieben wird je Workflow
# in seine Home-Dir (Get-WorkflowHomeDir, in Save-AndReport).
$WorkflowsDir = Get-WorkflowDirs $RepoRoot

# --- Core-Service-Alias-Map (D9) aus dem Provider-Manifest laden (script-scope, dynamic-scope -> die
# dot-gesourcten Build-Defs sehen $CoreServiceMap wie $WorkflowsDir). ConvertFrom-Json liefert ein
# PSCustomObject -> explizit in eine Hashtable pivotieren (sonst kein .ContainsKey im Resolver).
$coreManifest   = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\manifest.json'), $Utf8NoBom) | ConvertFrom-Json
$CoreServiceMap = @{}
foreach ($p in $coreManifest.provides.services.PSObject.Properties) { $CoreServiceMap[$p.Name] = $p.Value }
# Unterstuetzte Sprachen fester Texte (Textkatalog) als 'de|en|ko' fuer Modell-Texte (Tool-Beschreibungen) — die EINE
# Liste ist der Core-Manifest-Block languages.list, nie abtippen.
$LanguageCodes = (@($coreManifest.languages.list | Sort-Object { [int]$_.ord } | ForEach-Object { [string]$_.code })) -join '|'
if (-not $LanguageCodes) { throw 'packages/core/manifest.json: languages.list fehlt (Textkatalog).' }

# --- Agenten-Routing-Liste (Phase 0 WS-0c #4, Phase C) aus den Manifest-provides.agents-Objekten {name,
# router_description, order, fallback_for?} ALLER Pakete (Union), 'orchestrator' ausgeschlossen (der Router routet
# nicht zu sich selbst), nach order (dann name) sortiert. Der Orchestrator-Build-Def (agent.orchestrator.ps1)
# generiert daraus je Agent einen Call-Node + ai_tool-Binding -> ein neues Paket dockt einen Route-Agenten ohne
# Orchestrator-Edit an. Lesen + Vertrags-Pruefung (Pflicht-Beschreibung, agent.<x>-Referenzen, fallback_for)
# teilen sich Build und contract_lint 19 in lib/agent_routing.ps1; ein Verstoss bricht den Build ab.
# Script-scope -> der dot-gesourcte Build-Def sieht $AgentRoutingList wie $CoreServiceMap.
. "$PSScriptRoot\lib\agent_routing.ps1"
$routing = Get-AgentRouting (Get-PackageManifest $RepoRoot)
if ($routing.Errors.Count -gt 0) { throw ("provides.agents-Vertrag verletzt:`n  " + ($routing.Errors -join "`n  ")) }
foreach ($rw in $routing.Warnings) { Write-Warning "provides.agents: $rw" }   # Verweis auf ein im Repo abwesendes Paket (optional)
$AgentRoutingList = $routing.List

# --- Onboarding-Dispatch-Liste (P1 Generisches Paket-Onboarding) aus den Manifest-provides.onboarding-Objekten
# {agent} ALLER Pakete (Paritaet $AgentRoutingList). Der Orchestrator-Build-Def (agent.orchestrator.ps1) generiert
# daraus je Paket einen Onboarding-Callback-Dispatch-Arm (Run/Answer/Relay -> agent.<agent>) + den Switch-Case auf
# das <package>-Glied von callback_data 'onboarding:<package>:<key>' -> kein agent.<pkg>-Literal im Core (core_literal
# #1) und kein Orchestrator-Edit fuer ein neues Onboarding-Paket. Core-Haushalt ist der hartkodierte Sonderfall (kein
# provides.onboarding -> nicht in dieser Liste). Reihenfolge = $OnboardingPackageOrder (abgeleitet aus den
# consumes-Abhaengigkeiten, Get-OnboardingPackageOrder in lib/agent_routing.ps1) = die Menue-Reihenfolge.
# Script-scope -> der dot-gesourcte Build-Def sieht $OnboardingDispatchList/$OnboardingPackageOrder wie $AgentRoutingList.
$OnboardingPackageOrder = @(Get-OnboardingPackageOrder $RepoRoot)
$OnboardingDispatchList = @($OnboardingPackageOrder | Where-Object { $_.Agent } | ForEach-Object {
    [pscustomobject]@{ Package = $_.Package; Agent = $_.Agent }
})
# Onboarding-Plan-Schritt: Berater-Domaenen mit advisors.<domain>.plan_step (Menue-Plan-Zeile + Orchestrator-Arm plan:<domain>).
$AdvisorPlanStepList = @(Get-AdvisorPlanStepList $RepoRoot)

# --- Command-Dispatch-Liste (WS-5 Command-Router-Generalisierung) aus den Manifest-`commands`-Bloecken
# ALLER Pakete (Paritaet $OnboardingDispatchList). Nur Eintraege MIT einem `dispatch`-Feld {agent, task}:
# das sind CODE-PFAD-Commands, die einen Agenten starten (erster: estate `/notfall`). Die Core-Commands
# (/help, /onboarding, /start) haben KEIN dispatch = Host-bespoke Handler und bleiben aussen. Der
# Orchestrator-Build-Def generiert daraus je Command einen Switch-Case im `Command router` + einen
# Run/Relay-Dispatch-Arm -> agent.<agent> INLINE (message.text-Pfad) -> kein Orchestrator-Edit fuer ein
# neues Paket-Command. Discriminant (docs/package-contract.md): Code-Pfad-Command -> Build-Zeit-Switch;
# reiner Text-/Callback-Prefix -> Laufzeit-core.callback_handlers.
$CommandDispatchList = @()
foreach ($mf in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json'))) {
    $mj = [System.IO.File]::ReadAllText($mf.FullName, $Utf8NoBom) | ConvertFrom-Json
    $cmds = $mj.commands
    if ($null -eq $cmds) { continue }
    foreach ($c in @($cmds.list)) {
        if ($null -eq $c -or $null -eq $c.dispatch) { continue }
        $cmd   = [string]$c.cmd
        $agent = [string]$c.dispatch.agent
        if ([string]::IsNullOrEmpty($cmd) -or [string]::IsNullOrEmpty($agent)) { continue }
        $CommandDispatchList += [pscustomobject]@{
            Package     = [string]$mj.name
            Command     = $cmd
            CommandSlug = ($cmd -replace '^/', '')
            Agent       = $agent
            Task        = [string]$c.dispatch.task
        }
    }
}
$CommandDispatchList = @($CommandDispatchList | Sort-Object Command)

# --- Fakten-Kontext -> besitzendes Paket + household-Fakten-Kontexte (Phase A) aus den Manifest-Bloecken
# `context_validators` und `context_scopes` ALLER Pakete (Paritaet $AgentRoutingList). Der Tool-Build-Def
# agent.tool_set_context_facts backt $FactsDisplayJson ({ctx: pkg}) in die HITL-Summary: die Beschriftungen liegen im
# Textkatalog des besitzenden Pakets (<pkg>.facts.<ctx>.title / <pkg>.facts.<ctx>.<feld>, je Sprache; der Core kennt
# keine Paket-Labels); agent.guide.ps1 nennt dem Modell die household-Kontexte aus $HouseholdFactsContexts statt eines
# Paket-Beispiels. Script-scope -> die dot-gesourcten Build-Defs sehen beides.
$FactsDisplay = [ordered]@{}
$HouseholdFactsContexts = @()
foreach ($mf in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json') | Sort-Object FullName)) {
    $mj = [System.IO.File]::ReadAllText($mf.FullName, $Utf8NoBom) | ConvertFrom-Json
    if ($null -ne $mj.context_validators) {
        foreach ($p in $mj.context_validators.PSObject.Properties) {
            if ($p.Name -ne '_comment') { $FactsDisplay[$p.Name] = [string]$mj.name }
        }
    }
    if ($null -ne $mj.context_scopes) {
        foreach ($p in $mj.context_scopes.PSObject.Properties) {
            if ($p.Name -ne '_comment' -and [string]$p.Value.scope -eq 'household') { $HouseholdFactsContexts += $p.Name }
        }
    }
}
$HouseholdFactsContexts = @($HouseholdFactsContexts | Sort-Object)
# Kompakt serialisiert. Die Summary ist ein n8n-Ausdruck ={{ … }} -> eine '}}'-Folge im eingebetteten JSON wuerde den
# Ausdruck vorzeitig beenden -> '} }' erzwingen (gueltiges JSON). Selbst-Assert gegen beide Fallen.
$FactsDisplayJson = (ConvertTo-Json -InputObject $FactsDisplay -Depth 5 -Compress) -replace '\}\}', '} }' -replace '\}\}', '} }'
if ($FactsDisplayJson -match 'System\.' -or $FactsDisplayJson -match '\}\}') { throw "facts_display: Serialisierung fehlerhaft ($FactsDisplayJson)." }

# --- Phase B (Core kennt kein Paket): Monitor-Beschaffungs-Methoden, Paket-Lesefenster und Advisor-Domaenen aus den
# Manifest-Bloecken `monitor_acquisition_methods` / `read_surface` / `advisors` ALLER Pakete (Paritaet $HouseholdFactsContexts).
# Die Core-Build-Defs (agent.monitor + die Monitor-Tools + der Monitor-Cron) backen daraus ihre LLM-Beschreibungen, die
# Methoden-Labels der HITL-Summary und die Advisor-Hinweise — vorher standen finance-Views/-Domain/fx-Felder fest im Core.
# Repo-Baum = Build-Menge (nicht die installierte Menge): ein nicht installiertes Paket faellt zur Laufzeit graceful aus
# (Methode nicht verfuegbar -> {ok:false}; View nicht lesbar -> der Dry-Run meldet den Fehler). Script-scope.
$MonitorAcquisitionMethodList = @()
$ReadSurfaceList = @()
$AdvisorDomainList = @()
foreach ($mf in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json') | Sort-Object FullName)) {
    $mj = [System.IO.File]::ReadAllText($mf.FullName, $Utf8NoBom) | ConvertFrom-Json
    if ($null -ne $mj.monitor_acquisition_methods) {
        foreach ($p in $mj.monitor_acquisition_methods.PSObject.Properties) {
            if ($p.Name -eq '_comment') { continue }
            $MonitorAcquisitionMethodList += [pscustomobject]@{
                Method = $p.Name; Package = [string]$mj.name
                ParamsDescription = [string]$p.Value.params_description }
        }
    }
    if ($null -ne $mj.read_surface -and $mj.name -ne 'core') {
        $views = @($mj.read_surface.preferred_views | Where-Object { $_ })
        if ($views.Count -gt 0) { $ReadSurfaceList += [pscustomobject]@{ Package = [string]$mj.name; Views = $views } }
    }
    if ($null -ne $mj.advisors) {
        foreach ($p in $mj.advisors.PSObject.Properties) {
            if ($p.Name -eq '_comment') { continue }
            $AdvisorDomainList += [pscustomobject]@{ Domain = $p.Name; Package = [string]$mj.name }   # Paketname zur Laufzeit aus dem Katalog (<pkg>.package.name)
        }
    }
}
$MonitorAcquisitionMethodList = @($MonitorAcquisitionMethodList | Sort-Object Method)
$AdvisorDomainList = @($AdvisorDomainList | Sort-Object Domain)
foreach ($m in $MonitorAcquisitionMethodList) {
    if (-not $m.ParamsDescription) { throw "monitor_acquisition_methods.$($m.Method) ($($m.Package)): params_description fehlt." }
}
# Doppelte Namen (zwei Pakete deklarieren dieselbe Methode/Domaene) -> doppelte Enum-Eintraege/Map-Keys im LLM-Text.
foreach ($dup in @($MonitorAcquisitionMethodList | Group-Object Method | Where-Object { $_.Count -gt 1 })) {
    throw "monitor_acquisition_methods.$($dup.Name) mehrfach deklariert: $((@($dup.Group | ForEach-Object { $_.Package })) -join ', ')."
}
foreach ($dup in @($AdvisorDomainList | Group-Object Domain | Where-Object { $_.Count -gt 1 })) {
    throw "advisors.$($dup.Name) mehrfach deklariert: $((@($dup.Group | ForEach-Object { $_.Package })) -join ', ')."
}
# Methode -> besitzendes Paket fuer die HITL-Summary der Monitor-Tools: die Bezeichnung steht im Textkatalog unter
# <pkg>.monitor_method.<methode> (Core-Builtins web_search/sql/none unter core.monitor_method.*).
$MonitorMethodPkgJson = '{' + (($MonitorAcquisitionMethodList | ForEach-Object { (ConvertTo-Json $_.Method) + ': ' + (ConvertTo-Json $_.Package) }) -join ', ') + ' }'

# --- WS-5b Auth-Matrix: Maker-Checker-Stufe je Gate-Aufrufer, je Paket im manifest.json-Block `approval_matrix`
# (Phase D; docs/package-contract.md §3.10). lib/approval_matrix.ps1 vereint + prueft die Bloecke (tier-Enum, Doppel,
# Verb-Praefix-Strenge: SCHWAECHER als das Verb verlangt = Build-Fehler, strenger erlaubt). build.ps1 injiziert den
# tier in jeden agent.tool_human_approval-Aufruf-Node (Set-ApprovalTier, unten in Save-AndReport); ein Gate-Aufrufer
# ohne Eintrag -> Build-Fehler (Deny-by-Default, fail-closed). Besitz: das deklarierende Paket muss das Paket des
# Workflow-Namens (Get-WorkflowPackage) UND des erzeugenden Build-Defs sein (Set-ApprovalTier).
. "$PSScriptRoot\lib\approval_matrix.ps1"
$ApprovalGateName = 'agent.tool_human_approval'
$am = Get-ApprovalMatrix $RepoRoot
foreach ($wfName in $am.Entries.Keys) {
    $owner = Get-WorkflowPackage $wfName $RepoRoot
    if ($owner -ne $am.Entries[$wfName].Package) {
        $am.Errors += "'$wfName' ist im Manifest von '$($am.Entries[$wfName].Package)' deklariert, gehoert aber zu '$owner' (Workflow-Name-Scope)."
    }
}
if ($am.Errors.Count -gt 0) { throw ("approval_matrix-Vertrag verletzt:`n  " + ($am.Errors -join "`n  ")) }
$script:ApprovalMatrix = $am.Entries

# Set-ApprovalTier <wf> <def> — injiziert approval_tier in jeden Gate-Aufruf-Node (executeWorkflow ->
# cachedResultName == agent.tool_human_approval). Harnesses (*.test_harness) liefern approval_tier selbst
# ueber den Test-Webhook -> uebersprungen. Bereits gesetztes approval_tier (explizit) wird nie ueberschrieben.
function Set-ApprovalTier([object]$Wf, [object]$Def) {
    if ($Wf.name -like '*.test_harness') { return }
    foreach ($n in $Wf.nodes) {
        if ($n.type -ne 'n8n-nodes-base.executeWorkflow') { continue }
        if ($n.parameters.workflowId.cachedResultName -ne $ApprovalGateName) { continue }
        $val = $n.parameters.workflowInputs.value
        if ($val -is [System.Collections.IDictionary] -and $val.Contains('approval_tier')) { continue }
        $e = $script:ApprovalMatrix[[string]$Wf.name]
        if ($null -eq $e) {
            throw "approval_matrix: Gate-Aufrufer '$($Wf.name)' fehlt im approval_matrix-Block seines Paket-Manifests (fail-closed; jeder Gate-Aufrufer braucht eine bewusste Stufe)."
        }
        if ($null -ne $Def -and $Def.Package -ne $e.Package) {
            throw "approval_matrix: '$($Wf.name)' wird von $($Def.File) (Paket '$($Def.Package)') erzeugt, aber im Manifest von '$($e.Package)' getiert."
        }
        $val['approval_tier'] = $e.Tier
    }
}

# --- Cross-Ref-ID(s), die mehrere Workflows brauchen, einmal aus dem State (Dateinamen) aufloesen ---
# KEINE hartkodierten Workflow-ID-Literale mehr: Name = Single-Source, die ID kommt aus dem getrackten
# <id>-<name>.json. Vor dem Dot-Sourcen der Defs, damit File-Scope-Refs sie sehen.
# Die Core-Dienste werden ueber den Alias-Resolver (core:<name> -> physischer Name) aufgeloest, damit die
# physischen Core-Workflow-Namen NUR im core-Manifest leben (D9; provides.services = SSOT). Paket-INTERNE
# Cross-Refs loest der jeweilige Build-Def selbst auf (Get-RequiredWorkflowId im Funktionskoerper).
$GateId        = Get-RequiredWorkflowId (Resolve-CoreServiceAlias 'core:human_approval' $CoreServiceMap) 'build.ps1'   # genutzt von allen Write-Tools
# Infra-Subs: Build-Workflow nutzt $ErrorNotifyId; die Agent-/Voice-Defs $LoadConfigId/$LoadContextId.
$ErrorNotifyId = Get-RequiredWorkflowId (Resolve-CoreServiceAlias 'core:error_notify' $CoreServiceMap) 'build.ps1'    # settings.errorWorkflow JEDES Prod-Workflows (in Build-Workflow)
$LoadConfigId  = Get-RequiredWorkflowId (Resolve-CoreServiceAlias 'core:load_config' $CoreServiceMap) 'build.ps1'     # 'Load Config' erster Schritt jedes Agenten + Voice-Tool
$LoadContextId = Get-RequiredWorkflowId (Resolve-CoreServiceAlias 'core:load_context' $CoreServiceMap) 'build.ps1'    # System-Prompt-Bauer, von jedem Agenten gerufen

# --- Workflow-Definitionen finden + dot-sourcen (NACH der Cross-Ref-Aufloesung, paket-uniform; Phase D) ---
# JEDES Paket haelt seine Build-Defs unter packages/<pkg>/build/workflows/{,tools}/ (Core wie jedes Domaenen-Paket,
# strukturell identisch; Core nur per Manifest als Host deklariert). Die Engine (build.ps1 + lib/) bleibt in
# scripts/build/ und kennt KEINE Builder-Liste: lib/builder_discovery.ps1 parst jede Def-Datei (PowerShell-AST,
# ohne Ausfuehrung) und leitet die Top-Level-Build-*-Funktionen ab -> ein neues Paket dockt ohne Engine-Edit an.
# Reihenfolge (Tools, dann uebrige Defs, je nach Pfad) ist fuer das Ergebnis wirkungslos: IDs kommen nur aus den
# gespeicherten <id>-<name>.json (ein im selben Lauf neu gebauter Workflow ist ohnehin id-los -> 2-Pass-Bootstrap).
# harnesses.ps1 appendet beim Dot-Sourcen an $script:Harnesses (lib/harness.ps1 hat initialisiert).
. "$PSScriptRoot\lib\builder_discovery.ps1"
$Discovery = Find-WorkflowBuilder $RepoRoot
# Netz gegen still leere Credentials: jede $CRED_*-Variable in Defs + Engine-libs ist ein bekannter Deskriptor
# (Host + aus den Manifesten erzeugt) oder in derselben Datei zugewiesen (lokaler Alias).
$libFiles = foreach ($lf in (Get-ChildItem "$PSScriptRoot\lib\*.ps1")) {
    $t = $null; $e = $null
    [pscustomobject]@{ Path = $lf.FullName; Rel = "scripts/build/lib/$($lf.Name)"; Ast = [System.Management.Automation.Language.Parser]::ParseFile($lf.FullName, [ref]$t, [ref]$e) }
}
Assert-CredentialReference -Files (@($Discovery.Files) + @($libFiles)) -Known (@($HostCredentialVars) + @($PackageCredentials | ForEach-Object { $_.Var }))
foreach ($df in $Discovery.Files) { . $df.Path }

Write-Host ""
Write-Host "Build-Orchestrator -> $WorkflowsDir   (Filter: $Only)"
Write-Host ("-" * 64)

$built = 0; $new = 0
$script:catalog   = [ordered]@{}   # Phase 4: name -> _manifest @{Category;Examples} NUR user-facing (Build-Zeit, nie serialisiert)
$script:wfPackage = @{}            # Workflow-Name -> Paket des erzeugenden Build-Defs (Katalog-Segmentierung)
$script:toolDefs  = [ordered]@{}   # Tool-Workflow-Name -> @{Def; Manifest} (Vollstaendigkeits-Check im Katalog-Teil)
function Save-AndReport([object]$Wf, [object]$Def = $null) {
    if ($null -ne $Def) {
        if ($null -eq $Wf -or $Wf -is [array] -or [string]::IsNullOrEmpty([string]$Wf.name) -or $null -eq $Wf.nodes) {
            throw "$($Def.Function) ($($Def.File)) liefert kein einzelnes Workflow-Objekt mit .name/.nodes."
        }
        $script:wfPackage[[string]$Wf.name] = $Def.Package
        if ($Def.IsTool) { $script:toolDefs[[string]$Wf.name] = @{ Def = $Def; Manifest = $Wf._manifest } }
    }
    # Katalog IMMER sammeln (auch bei -Only/-Verify/-CatalogOnly) — interne Werkzeuge (_manifest.Internal) filtert
    # die Sammelstelle heraus, sie erreichen nie Kategorie-/Example-Check oder Fragment-Renderer.
    if ($Wf._manifest -and -not $Wf._manifest.Internal) { $script:catalog[$Wf.name] = $Wf._manifest }
    if ($VerifyCatalog -or $CatalogOnly) { return }                    # In-Memory-only: keine Workflow-File-Writes
    if ($Wf.name -notlike $Only) { return }
    Set-ApprovalTier $Wf $Def                           # WS-5b: approval_tier aus dem approval_matrix-Block in jeden Gate-Aufruf injizieren (fail-closed)
    $wfHome = Get-WorkflowHomeDir $Wf.name $RepoRoot    # paket-bewusste Ziel-Dir ($home ist PS-Automatik-Var -> nicht shadowen)
    $res = Save-WorkflowFile $Wf $Wf.name $wfHome $OWNER_CHAT_ID
    $tag = if ($res.IsNew) { '[NEU id-los -> ID selbst im Dateinamen vergeben]' } else { "[id=$($res.Id)]" }
    Write-Host ("  {0,-44} {1}" -f $res.Name, $tag) -ForegroundColor $(if ($res.IsNew) { 'Yellow' } else { 'Green' })
    $script:built++; if ($res.IsNew) { $script:new++ }
}

foreach ($d in $Discovery.Builders) { Save-AndReport (& $d.Function) $d }
foreach ($wf in (Get-HarnessWorkflow)) { Save-AndReport $wf }

# --- Phase 4 + WS-B7 + Textkatalog Phase B: Per-Fragment-Capabilities-Catalog je Sprache ------------------------
# Generierung nur bei VOLLEM Build (-Only '*') oder -Verify/-CatalogOnly (sonst fehlen Manifeste -> falscher
# Hash; $script:catalog wird in Save-AndReport IMMER voll gesammelt, auch bei -Only). Jedes Paket BESITZT
# seine Katalog-STRUKTUR im manifest.json-`catalog`-Block (ord/categories/tail), die TEXTE im Textkatalog
# (<pkg>.help.*). build.ps1 rendert je Paket UND Katalogsprache ein Fragment
# (packages/<pkg>/seed/capabilities_catalog/<lang>.fragment.md) + composet sie je Sprache nach Paket-`ord` in die
# getrackte packages/core/seed/capabilities_catalog/<lang>.md (Kopf-Quelle des Install-Compose, seed_data.sh).
# Drift-Lint PER-FRAGMENT (nennt Paket + Sprache) + Compose-Integritaet je Sprache.
$catDir = "$RepoRoot\packages\core\seed\capabilities_catalog"
if ($VerifyCatalog -or $CatalogOnly -or $Only -eq '*') {
    # (1) Manifest-Vollstaendigkeit (Review A1) auf den GEBAUTEN Tool-Workflows: jedes Werkzeug aus einer tools/-Def
    #     traegt genau eins von Category (user-facing Capability) oder Internal = $true (Infra/Agent-intern,
    #     co-located am Tool, Muster OpenAPI x-internal) — keins oder beides = Fehler.
    $nameToPkg = $script:wfPackage
    $missingManifest = @()
    foreach ($tn in $script:toolDefs.Keys) {
        $td  = $script:toolDefs[$tn]; $m = $td.Manifest
        $cat = ($null -ne $m) -and -not [string]::IsNullOrEmpty([string]$m.Category)
        $int = ($null -ne $m) -and ($m.Internal -eq $true)
        if ($cat -and $int) { $missingManifest += "$($td.Def.File) ($tn): Category UND Internal — genau eins" }
        elseif (-not $cat -and -not $int) { $missingManifest += "$($td.Def.File) ($tn)" }
    }

    # (2) Per-Paket catalog-Struktur (manifest.json-`catalog`-Block: .ord/.categories/.tail).
    $pkgCatalogs = @{}
    foreach ($mf in (Get-ChildItem "$RepoRoot\packages\*\manifest.json")) {
        if (-not ((($mf.FullName) -replace '\\','/') -match 'packages/([^/]+)/manifest.json')) { continue }
        $mpkg  = $Matches[1]
        $mjson = [System.IO.File]::ReadAllText($mf.FullName, $Utf8NoBom) | ConvertFrom-Json
        if ($mjson.catalog) { $pkgCatalogs[$mpkg] = $mjson.catalog }
    }

    # (3) $script:catalog nach Paket segmentieren (unbekannter Name -> 'core'-Fallback, sollte nie greifen).
    $byPkg = @{}
    foreach ($n in $script:catalog.Keys) {
        $p = if ($nameToPkg.ContainsKey($n)) { $nameToPkg[$n] } else { 'core' }
        if (-not $byPkg.ContainsKey($p)) { $byPkg[$p] = @{} }
        $byPkg[$p][$n] = $script:catalog[$n]
    }

    # (4) Undeklarierte Kategorien + fehlende Pflicht-Texte sammeln (m3 = harter Verify-FAIL): ein Paket mit
    #     Katalog-Tools aber ohne catalog-Block faellt sonst still aus dem Katalog -> ebenfalls Fehler.
    $undeclared = @()
    foreach ($p in ($byPkg.Keys | Where-Object { -not $pkgCatalogs.ContainsKey($_) } | Sort-Object)) {
        $undeclared += "${p}: hat Katalog-Tools, aber keinen manifest.json-catalog-Block"
    }
    $missingTexts = @()
    foreach ($p in ($pkgCatalogs.Keys | Sort-Object)) {
        $pm = if ($byPkg.ContainsKey($p)) { $byPkg[$p] } else { @{} }
        $undeclared   += (Find-UndeclaredCategories $pm @(@($pkgCatalogs[$p].categories) | ForEach-Object { [string]$_.id }) | ForEach-Object { "${p} -> $_" })
        $missingTexts += (Find-MissingCatalogTexts $RepoRoot $p $pkgCatalogs[$p])
    }

    # (5) Je Sprache: Fragmente rendern + composen (Laengen-Assert im Compose). Fehlende Texte -> kein Render (Verify meldet sie).
    $fragments = @()
    $composed  = @()
    if ($missingTexts.Count -eq 0) {
        foreach ($lang in (Get-CatalogLanguages $RepoRoot)) {
            $langFrags = @()
            foreach ($p in ($pkgCatalogs.Keys | Sort-Object)) {
                $pm = if ($byPkg.ContainsKey($p)) { $byPkg[$p] } else { @{} }
                $body = Build-CatalogFragment $p $pkgCatalogs[$p] $pm $lang $RepoRoot
                $langFrags += @{ Package = $p; Lang = $lang; Ord = [int]$pkgCatalogs[$p].ord; Body = $body
                                 Path = "$RepoRoot\packages\$p\seed\capabilities_catalog\$lang.fragment.md" }
            }
            $fragments += $langFrags
            $composed  += @{ Lang = $lang; Md = (Build-ComposedCatalog $langFrags $lang $RepoRoot); Path = "$catDir\$lang.md" }
        }
    }
    $missing = Find-CatalogExamplesWithoutCase $RepoRoot

    if ($VerifyCatalog) {
        $fail = 0
        if ($missing.Count -gt 0) {
            Write-Host "DRIFT: $($missing.Count) deutsche Katalog-Beispiel(e) ohne Routing-Case:" -ForegroundColor Red
            foreach ($m in $missing) { Write-Host "    - $m" -ForegroundColor Red }
            $fail = 1
        }
        if ($missingManifest.Count -gt 0) {
            Write-Host "DRIFT: $($missingManifest.Count) user-facing Tool(s) OHNE _manifest (Build-Workflow 4. Param fehlt):" -ForegroundColor Red
            foreach ($m in $missingManifest) { Write-Host "    - $m" -ForegroundColor Red }
            $fail = 1
        }
        if ($undeclared.Count -gt 0) {
            Write-Host "DRIFT: $($undeclared.Count) Tool-Category/ies ohne catalog-Block-Deklaration ihres Pakets:" -ForegroundColor Red
            foreach ($u in $undeclared) { Write-Host "    - $u" -ForegroundColor Red }
            $fail = 1
        }
        if ($missingTexts.Count -gt 0) {
            Write-Host "DRIFT: $($missingTexts.Count) Katalog-Text(e) der /help-Struktur fehlen im Textkatalog:" -ForegroundColor Red
            foreach ($u in $missingTexts) { Write-Host "    - $u" -ForegroundColor Red }
            $fail = 1
        }
        # Per-Fragment-Drift (nennt Paket + Sprache) ...
        foreach ($f in $fragments) {
            $onDisk = if (Test-Path $f.Path) { (([System.IO.File]::ReadAllText($f.Path, $Utf8NoBom)) -replace "`r`n","`n").TrimEnd() + "`n" } else { '' }
            if ($onDisk -ne $f.Body) {
                Write-Host "DRIFT: Fragment packages/$($f.Package)/seed/capabilities_catalog/$($f.Lang).fragment.md != frisch generiert. 'build.ps1' (voll) + commit." -ForegroundColor Red
                $fail = 1
            }
        }
        # ... und Compose-Integritaet je Sprache (komponierte .md == compose(on-disk-Fragmente)).
        foreach ($c in $composed) {
            $onDiskCat = if (Test-Path $c.Path) { (([System.IO.File]::ReadAllText($c.Path, $Utf8NoBom)) -replace "`r`n","`n").TrimEnd() + "`n" } else { '' }
            if ($onDiskCat -ne $c.Md) {
                Write-Host "DRIFT: packages/core/seed/capabilities_catalog/$($c.Lang).md != compose(Fragmente). 'build.ps1' (voll) + commit." -ForegroundColor Red
                $fail = 1
            }
        }
        if ($fail) { Write-Host "Catalog-Verify FEHLGESCHLAGEN." -ForegroundColor Red; exit 1 }
        Write-Host "Catalog-Verify OK ($($composed.Count) Sprachen, $($fragments.Count) Fragmente, Compose stimmt, jedes deutsche Beispiel hat einen Case)." -ForegroundColor Green
        exit 0
    } else {
        if ($missing.Count -gt 0) {
            Write-Host ("-" * 64)
            Write-Host "WARNUNG: $($missing.Count) deutsche Katalog-Beispiel(e) ohne Routing-Case (Pre-Push-Lint wird blocken):" -ForegroundColor Yellow
            foreach ($m in $missing) { Write-Host "    - $m" -ForegroundColor Yellow }
        }
        if ($missingManifest.Count -gt 0) {
            Write-Host "WARNUNG: $($missingManifest.Count) user-facing Tool(s) OHNE _manifest (Pre-Push-Lint wird blocken):" -ForegroundColor Yellow
            foreach ($m in $missingManifest) { Write-Host "    - $m" -ForegroundColor Yellow }
        }
        if ($undeclared.Count -gt 0) {
            Write-Host "WARNUNG: $($undeclared.Count) Tool-Category/ies ohne catalog-Block (Pre-Push-Lint wird blocken):" -ForegroundColor Yellow
            foreach ($u in $undeclared) { Write-Host "    - $u" -ForegroundColor Yellow }
        }
        if ($missingTexts.Count -gt 0) {
            Write-Host "FEHLER: $($missingTexts.Count) Katalog-Text(e) fehlen — /help nicht generiert:" -ForegroundColor Red
            foreach ($u in $missingTexts) { Write-Host "    - $u" -ForegroundColor Red }
            exit 1
        }
        foreach ($f in $fragments) {
            $fragDir = Split-Path $f.Path -Parent
            if (-not (Test-Path $fragDir)) { New-Item -ItemType Directory -Path $fragDir -Force | Out-Null }
            [System.IO.File]::WriteAllText($f.Path, $f.Body, $Utf8NoBom)
        }
        if (-not (Test-Path $catDir)) { New-Item -ItemType Directory -Path $catDir -Force | Out-Null }
        foreach ($c in $composed) { [System.IO.File]::WriteAllText($c.Path, $c.Md, $Utf8NoBom) }
        Write-Host "  capabilities_catalog: $($composed.Count) Sprache(n) + $($fragments.Count) Fragment(e) generiert ($($script:catalog.Count) Tool-Manifeste)" -ForegroundColor Green
        if ($CatalogOnly) { exit 0 }
    }
}

Write-Host ("-" * 64)
Write-Host "$built Workflow(s) gebaut + gespeichert ($new neu/id-los)."
Write-Host "Naechster Schritt: .\scripts\dev\bootstrap_test_n8n.ps1  (spielt nur geaenderte Workflows ins laufende Substrat; frisch: -Reset; Prod: provision.sh)."
Write-Host ""
