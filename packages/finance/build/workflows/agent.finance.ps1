#Requires -Version 5.1
# Build-Def fuer agent.finance (Finance-Paket). Generiert das volle agent.finance-Workflow-JSON;
# Ziel-Datei + ID loest Save-WorkflowFile per Name aus dem State auf (Output: packages/finance/workflows/).
$ErrorActionPreference = 'Stop'

$ID_LOAD_AGENT_CONTEXT  = $LoadContextId   # agent.tool_load_context (build.ps1: per Name aus dem State)
$ID_LOAD_CONFIG         = $LoadConfigId    # core.sub_load_config (build.ps1: per Name aus dem State)
# Credentials: $CRED_POSTGRES (Schreibpfad: Chat-Memory + tool_* fn-Nodes) und $CRED_CONTEXT_RO (load_context) sind
# Host-Deskriptoren aus build.ps1; die enge Leserolle finance_ro ($CRED_FINANCE_RO) erzeugt die Engine aus dem Manifest.

# Tool-IDs kommen NICHT mehr aus einer Registry, sondern werden in New-ToolWorkflowNode per
# Get-WorkflowIdByName aus dem State (packages/*/workflows) aufgeloest. $WorkflowsDir setzt der Orchestrator.
# Das Modell-Register (packages/core/seed/ai_models.json) liest New-ModelSelectorBundle selbst.

# Flexible Doku-Sticky (Farbe 4, freier Markdown-Content) — Workflows sind die Doku (CLAUDE.md).
function New-Sticky {
    param([string]$Name, [int[]]$Pos, [string]$Content, [int]$Width = 360, [int]$Height = 160)
    [ordered]@{
        parameters = [ordered]@{ content = $Content; height = $Height; width = $Width; color = 4 }
        type = 'n8n-nodes-base.stickyNote'
        typeVersion = 1
        position = $Pos
        id = (New-Id)
        name = $Name
    }
}

# Build a toolWorkflow node that exposes a tool sub-workflow as an AI tool.
# $InputSpec is an array of @(name, description, type) tuples; type is 'string' or 'number'.
# Optional 4th element = default value -> emits the 4-arg $fromAI(key, desc, type, default),
# which makes the field OPTIONAL for the LLM (it may omit it; the default is used).
# Without a 4th element the field is required (LLM must provide it).
function New-ToolWorkflowNode {
    param(
        [string]$ToolKey,           # e.g. 'tool_book_dividend'
        [string]$Description,          # tool description for the LLM
        [array] $InputSpec,            # @( @('isin','ISIN','string'), @('amount','EUR amount','number'), ... )
        [int[]] $Position
    )
    # ID aus dem State (getrackte Dateien), nicht aus einer Registry. Fehlt sie -> hartes throw
    # (nicht still skippen): entweder echter Fehler oder ein noch nicht angelegtes Tool (dann zuerst
    # das Tool via build.ps1 -Only anlegen + ID im Dateinamen vergeben, siehe Bootstrap-Doku in packages/CLAUDE.md *Workflow-Bau*).
    $id = Get-RequiredWorkflowId "agent.finance.$ToolKey" 'agent.finance'
    Assert-FromAiSpec $InputSpec "New-ToolWorkflowNode '$ToolKey'"

    # value-mapping with $fromAI per input
    $valueMap = [ordered]@{}
    $schema   = @()
    foreach ($spec in $InputSpec) {
        $name = $spec[0]; $desc = $spec[1]; $type = $spec[2]
        if ($spec.Count -ge 4) {
            $def = $spec[3]
            if ($type -eq 'number') {
                $valueMap[$name] = "={{ `$fromAI('$name', '$desc', '$type', $def) }}"
            } else {
                $valueMap[$name] = "={{ `$fromAI('$name', '$desc', '$type', '$def') }}"
            }
        } else {
            $valueMap[$name] = "={{ `$fromAI('$name', '$desc', '$type') }}"
        }
        $schema += [ordered]@{
            id            = $name
            displayName   = $name
            required      = $false
            defaultMatch  = $false
            display       = $true
            canBeUsedToMatch = $true
            type          = $type
            removed       = $false
        }
    }

    # Fixer (nicht-$fromAI) Input: chat_id aus dem agent.finance-Trigger an JEDES Tool durchreichen.
    # Das Gate braucht chat_id fuer den Test-Bypass (chat_id=='test_9999' -> kein Telegram-Send).
    # Statische Expression => das LLM fuellt den Wert NICHT (anders als $fromAI-Felder).
    $valueMap['chat_id'] = "={{ `$('Start agent.finance').item.json.chat_id }}"
    $schema += [ordered]@{
        id = 'chat_id'; displayName = 'chat_id'; required = $false; defaultMatch = $false
        display = $true; canBeUsedToMatch = $true; type = 'string'; removed = $false
    }

    [ordered]@{
        parameters = [ordered]@{
            name = $ToolKey
            description = $Description
            workflowId = [ordered]@{
                __rl = $true
                value = $id
                mode = 'list'
                cachedResultUrl = "/workflow/$id"
                cachedResultName = "agent.finance.$ToolKey"
            }
            workflowInputs = [ordered]@{
                mappingMode = 'defineBelow'
                value = $valueMap
                matchingColumns = @()
                schema = @($schema)
                attemptToConvertTypes = $false
                convertFieldsToString = $false
            }
        }
        type = '@n8n/n8n-nodes-langchain.toolWorkflow'
        typeVersion = 2.2
        position = $Position
        id = (New-Id)
        name = $ToolKey
    }
}

function Build-AgentFinance {
$CRED_POSTGRES_RO = $CRED_FINANCE_RO   # nur postgres_select + Gate-Reads (Least-Privilege finance_ro)
# --- main pipeline ---
# Trigger: typed inputs (n8n 2.x — schema lives here, not in the caller's toolWorkflow node)
$nTrigger = [ordered]@{
    parameters = [ordered]@{
        workflowInputs = [ordered]@{
            values = @(
                [ordered]@{ name = 'task' }
                [ordered]@{ name = 'chat_id' }
                [ordered]@{ name = 'call_depth' }
            )
        }
    }
    type = 'n8n-nodes-base.executeWorkflowTrigger'
    typeVersion = 1.1
    position = @(-1600, 0)
    id = (New-Id)
    name = 'Start agent.finance'
}

# Anti-Loop-Backstop: lehnt einen Aufruf mit call_depth >= 2 VOR jedem LLM-Call ab.
# Number(...)||0 castet den evtl. als String ankommenden Wert (typeValidation:strict) + Default 0
# bei fehlend/leer. largerEqual -> gte (Build-If-Alias; kanonischer n8n-Operator).
$nDepthGate = Build-If 'Depth gate' @(-1480, 0) `
    "={{ Number(`$json.call_depth) || 0 }}" '2' 'largerEqual' 'number'

$nDepthDeny = Build-ToolError 'Max call depth' @(-1300, 200) 'max_call_depth'

# WS-B8 Routing-Status-Gate: bricht VOR dem LLM ab, wenn das finance-Paket nicht 'active' ist.
# Liest core.fn_package_active('finance') unter finance_ro (publiziertes SECURITY-DEFINER-Read-Window,
# D10 — finance_ro hat kein direktes SELECT auf core.package_registry). Status kippt zur Laufzeit per
# CLI active<->inactive OHNE Redeploy -> dieses Gate kappt den deaktivierten Pfad strukturell (analog
# Depth-Gate, kein LLM-Cost; NICHT per LLM-Prompt, der "nur Komfort und driftet"). Build-Pg emittiert
# default die WRITE-Cred -> post-construction auf finance_ro umstellen (wie 'Onboarding status read').
# onError=continue + IF prueft '=== false': ein DB-Lesefehler faellt fail-open durch (Normalfall finance
# aktiv), nur ein expliziter Nicht-active-Status (installing/installed/inactive) sperrt.
$nPkgRead = Build-Pg 'Package active read' @(-1480, 360) `
    "SELECT core.fn_package_active('finance') AS active;"
$nPkgRead.credentials = @{ postgres = $CRED_POSTGRES_RO }
$nPkgRead.onError = 'continueRegularOutput'
$nPkgGate = Build-If 'Package active gate' @(-1360, 360) `
    "={{ `$('Package active read').item.json.active === false }}" 'true' 'equals' 'boolean'
$nPkgDeny = Build-ToolError 'Package inactive' @(-1360, 540) 'package_inactive'

# WS-3 Core-first Hard-Gate (immer-an Onboarding-Invariante): bricht VOR dem LLM ab, wenn das CORE-Onboarding
# (Haushalt) nicht abgeschlossen ist -> kein Paket vor dem Core-Onboarding. Geteilte Naht New-CoreOnboardingGate
# (lib/build_helpers.ps1, auch in New-AdvisorGateChain): Read unter finance_ro (Status + Umleitungs-Text in der Sprache
# des Absenders), fail-open bei Lesefehler. Der weiche Finance-Self-Onboard (unten, Onboarding status read) greift erst
# NACH diesem Gate -> mid-CORE blockt hart, mid-PAKET (Core fertig, Finanz-Sektionen offen) laeuft.
$coreGate = New-CoreOnboardingGate -StartNode 'Start agent.finance' -CredPgRo $CRED_POSTGRES_RO `
    -ReadPos @(-1240, 360) -GatePos @(-1120, 360) -RedirectPos @(-1120, 540)
$nCoreRead = $coreGate.Read; $nCoreGate = $coreGate.Gate; $nCoreRedirect = $coreGate.Redirect

$nLoadConfig = [ordered]@{
    parameters = [ordered]@{
        workflowId = [ordered]@{
            __rl = $true
            value = $ID_LOAD_CONFIG
            mode = 'list'
            cachedResultUrl = "/workflow/$ID_LOAD_CONFIG"
            cachedResultName = 'core.sub_load_config'
        }
        workflowInputs = [ordered]@{
            mappingMode = 'defineBelow'
            value = @{}
            matchingColumns = @()
            schema = @()
            attemptToConvertTypes = $false
            convertFieldsToString = $true
        }
        options = @{}
    }
    type = 'n8n-nodes-base.executeWorkflow'
    typeVersion = 1.2
    position = @(-1376, 0)
    id = (New-Id)
    name = 'Load Config'
}

$nLoadCtx = [ordered]@{
    parameters = [ordered]@{
        workflowId = [ordered]@{
            __rl = $true
            value = $ID_LOAD_AGENT_CONTEXT
            mode = 'list'
            cachedResultUrl = "/workflow/$ID_LOAD_AGENT_CONTEXT"
            cachedResultName = 'core.load_agent_context'
        }
        workflowInputs = [ordered]@{
            mappingMode = 'defineBelow'
            value = [ordered]@{ agent_name = 'finance'; include_manifest = 'true' }
            matchingColumns = @()
            schema = @()
            attemptToConvertTypes = $false
            convertFieldsToString = $true
        }
        options = @{}
    }
    type = 'n8n-nodes-base.executeWorkflow'
    typeVersion = 1.2
    position = @(-1152, 0)
    id = (New-Id)
    name = 'Load Agent Context'
}

# WS-B3 Self-Onboarding: liest die kombinierte Core-Schnittstelle (unter finance_ro = das publizierte
# SECURITY-DEFINER-Lesefenster) und reicht die offenen Finanz-Sektionen unten in den System-Prompt. Kein
# Hard-Redirect (anders als das Advisor-Gate): der Finance-Agent onboardet proaktiv mit seinen EIGENEN
# Tools. onError=continue -> ein Lese-Hiccup bricht den Agenten nicht (dann nur kein Onboarding-Nudge). Nur fuer den Owner:
# Haushalts-Bereiche richtet allein der Owner ein (fn_set_onboarding_section lehnt ein Mitglied ab) -> ein Mitglied bekaeme
# sonst ein Angebot, das an owner_only scheitert (viewer_is_member aus der chat_id, nie LLM).
$nOnboardRead = Build-Pg 'Onboarding status read' @(-1040, 0) `
    "=SELECT (s.st->>'complete')::boolean AS complete, COALESCE((s.st->>'viewer_is_member')::boolean, false) AS viewer_is_member, COALESCE((SELECT string_agg(e->>'label', ', ' ORDER BY ord) FROM jsonb_array_elements(s.st->'open') WITH ORDINALITY AS x(e, ord)), '') AS open_labels FROM (SELECT core.fn_onboarding_status('finance', (`$1::jsonb)->>'chat_id') AS st) s;" `
    ([ordered]@{ chat_id = "String(`$('Start agent.finance').item.json.chat_id || '')" })
$nOnboardRead.credentials = @{ postgres = $CRED_POSTGRES_RO }
$nOnboardRead.onError = 'continueRegularOutput'

$nBuildInput = [ordered]@{
    parameters = [ordered]@{
        assignments = @{
            assignments = @(
                [ordered]@{ id = (New-Id); name = 'task';          value = "={{ `$('Start agent.finance').item.json.task }}";       type = 'string' }
                [ordered]@{ id = (New-Id); name = 'system_prompt'; value = "={{ `$('Load Agent Context').item.json.system_prompt + (`$('Onboarding status read').item.json.complete === false && `$('Onboarding status read').item.json.viewer_is_member !== true ? ('\n\n## Onboarding ausstehend\nThe finance onboarding is not complete yet. Open areas: ' + (`$('Onboarding status read').item.json.open_labels || '-') + '. Follow the Onboarding section of your instructions (what belongs to each area, when to offer it, when an area is done).') : '') }}";             type = 'string' }
                [ordered]@{ id = (New-Id); name = 'chat_id';       value = "={{ `$('Start agent.finance').item.json.chat_id }}";    type = 'string' }
            )
        }
        options = @{}
    }
    type = 'n8n-nodes-base.set'
    typeVersion = 3.4
    position = @(-928, 0)
    id = (New-Id)
    name = 'Build Agent Input'
}

$nAgent = [ordered]@{
    parameters = [ordered]@{
        promptType = 'define'
        text = '={{ $json.task }}'
        # maxIterations: Safety-Cap gegen Retry-Stuerme (ein fehlschlagendes Tool darf nicht
        # beliebig oft teure LLM-Calls ausloesen). Default waere 10.
        options = [ordered]@{ systemMessage = '={{ $json.system_prompt }}'; maxIterations = 8 }
    }
    type = '@n8n/n8n-nodes-langchain.agent'
    typeVersion = 3.1
    position = @(-560, 0)
    id = (New-Id)
    name = 'Finance Agent'
}

# --- model selector + model nodes (gemeinsamer Builder, ueberall identisch) ---
# New-ModelSelectorBundle (lib/build_helpers.ps1) liefert je Chat-Modell des Registers einen Node (Name = model_key,
# Thinking, kein Tier-Schema) + Model Selector (eine Regel je Modell, leftValue = model.finance).
# Nodes + Connections werden unten in den Graphen gemischt.
$mb = New-ModelSelectorBundle -ConfigField 'model.finance' -ConfigNodeName 'Load Config' `
    -AgentNodeName 'Finance Agent' -SelectorPos @(-688, 208) -ModelRowPos @(-848, 416) -Effort medium

# --- chat memory ---
# Eigenes Konversationsgedaechtnis fuer Multi-Turn-Finance-Dialoge (z. B. Versicherung ueber
# mehrere Nachrichten erfassen). Eigene Tabelle agent.finance_chat_memory (vom Memory-Node
# automatisch angelegt) -> keine Kollision mit agent.orchestrator_chat_memory. sessionKey =
# chat_id (gleicher Key wie Orchestrator, aber getrennte Tabelle). Damit muss der Orchestrator
# den Kontext NICHT mehr zusammenfassen; er reicht die Nutzernachricht durch, Finance erinnert sich.
$nMemory = [ordered]@{
    parameters = [ordered]@{
        sessionIdType = 'customKey'
        sessionKey = "={{ `$('Start agent.finance').item.json.chat_id }}"
        tableName = 'agent.finance_chat_memory'
        # Fenster 15 (wie Advisor/Guide): n8n 2.x speichert auch Tool-Calls + Tool-Results im Gedaechtnis,
        # das Fenster zaehlt also nicht nur Nutzer-/Antwort-Paare. Das fruehere Fenster 5 (Flash-Aera) reichte
        # bei einer Konto-Anlage ueber mehrere Nachrichten oft nur 1-2 Runden zurueck -> erfasste Werte
        # (Saldo, Inhaber) gingen verloren (Owner-Fall 2026-10-22).
        contextWindowLength = 15
    }
    type = '@n8n/n8n-nodes-langchain.memoryPostgresChat'
    typeVersion = 1.4
    position = @(-1008, 416)
    id = (New-Id)
    name = 'Postgres Chat Memory'
    credentials = @{ postgres = $CRED_POSTGRES }
}

# --- tools ---
$descSelect = 'Run read-only SELECT queries against schema `finance` (role finance_ro). Prefer views over raw table joins. Views: finance.account_overview, finance.active_recurring_payments, finance.active_insurances, finance.loan_overview, finance.loan_summary, finance.monthly_cashflow_overview, finance.monthly_cashflow_summary, finance.savings_goal_progress, finance.account_reserve_status, finance.depot_reserve_status, finance.savings_goal_reserve_breakdown, finance.real_estate_overview, finance.maintenance_reserve_status, finance.depot_holdings_overview, finance.savings_plan_overview, finance.depot_performance. DEPOT RETURN: for the return or performance of a depot (or all depots, or a depot comparison) read ONLY finance.depot_performance - one row per depot plus one is_total row (household depots without child depots): return_pa_pct = money-weighted return per year (XIRR, only from 365 days on), return_since_start_pct = return since start_date for less than a year (NOT per year - say so), missing_reason instead of a number (no_price, no_fx, no_flows, no_result - say what is missing), price_stale = the figure rests on an outdated price (say so), takeover_start_date = transferred positions count from that date. Never compute or annualise a return yourself. SAVINGS PLANS AND RHYTHMS: read savings plans ONLY from finance.savings_plan_overview (amount_per_execution, rhythm in plain words, monthly_amount, next_execution, starts_on, linked goal, a scheduled change); in recurring payments `amount` is PER EXECUTION and the rhythm is the `rhythm` column of finance.active_recurring_payments - a plan with fixed bank days (e.g. weekly = 4 times a month) costs amount x executions; quote monthly_amount, never work out a monthly amount or a rhythm yourself. finance.account_reserve_status shows per cash account whether its balance still covers the savings reserve tagged on it (breach/shortfall); finance.depot_reserve_status does the same per depot (market value vs reserved); finance.savings_goal_reserve_breakdown shows per goal where its reserve sits (cash accounts + depots). Raw tables (only when views are insufficient): finance.accounts, finance.account_balances, finance.transactions, finance.depot_holdings, finance.loans, finance.insurances, finance.recurring_payments, finance.savings_goals, finance.savings_goal_reserve_entries, finance.real_estate, finance.account_interest_rates. When reporting the worth of a depot position or portfolio, use finance.depot_holdings_overview.market_value_eur (live market value = shares x latest price) and mention the price date (price_as_of); if market_value/price_as_of is NULL there is no live price yet, so fall back to book_value and say so. Always quote ENUMs (account_type, transaction_category etc.) as strings. Views are narrow and curated: if you are unsure of the exact column names, SELECT * from the view instead of guessing column names; you may also query information_schema.columns to inspect a table or view. If a query fails you receive the database error back - read it and retry with a corrected query.'
$descLoad   = 'Fetch the full content of a lazy context document by name (see manifest in your system prompt). Use sparingly; only when the document is clearly relevant to the user task.'

# Frei-SQL-Lesewerkzeug: geteilter Builder (Guard gegen fehlendes query-Argument, onError continue).
$nToolSelect = New-PostgresSelectToolNode -Description $descSelect -Cred $CRED_POSTGRES_RO

# NOTE: postgres_execute (raw INSERT/UPDATE/DELETE tool) wurde entfernt.
# Schreibzugriff laeuft jetzt ausschliesslich ueber dedizierte tool_* Sub-Workflows.
# Wenn der Agent eine Aktion nicht abbilden kann, soll er das dem Nutzer melden
# statt heimlich SQL abzusetzen.

# fn_fetch_context = DIE gemeinsame Lazy-Fetch-Stelle (render-at-fetch: family/finance_profile
# werden zur Ladezeit mit berechneten Ableitungen gerendert; sonst stored content).
# jsonb-Param (Build-Gotcha-Standard, kein String-Splice) + onError: ein halluzinierter
# Context-Name killt nicht die Execution, sondern geht als korrigierbarer Tool-Fehler zurueck.
$loadQuery = "=SELECT content FROM core.fn_fetch_context((`$1::jsonb)->>'name');"
$loadParams = "={{ JSON.stringify({ name: `$fromAI('context_name', 'Name of the lazy context document to load (must match an entry in the manifest)', 'string') }) }}"
$nToolLoad = [ordered]@{
    parameters = [ordered]@{
        descriptionType = 'manual'
        toolDescription = $descLoad
        operation = 'executeQuery'
        query = $loadQuery
        options = [ordered]@{ queryReplacement = $loadParams }
    }
    type = 'n8n-nodes-base.postgresTool'
    typeVersion = 2.6
    position = @(-16, 208)
    id = (New-Id)
    name = 'load_context'
    onError = 'continueRegularOutput'
    credentials = @{ postgres = $CRED_CONTEXT_RO }   # agent-uebergreifend: eigene Rolle context_ro (s. CRED_CONTEXT_RO oben)
}

# Websuche = derselbe Core-Dienst wie beim Advisor (Analog agent.finance_advisor.ps1), hier nur zum Nachschlagen
# oeffentlicher Produkt-Konditionen VOR dem Eintragen (Owner-Entscheid 2026-10-23: der Advisor ist bis zum
# Onboarding gesperrt, der Zins gehoert aber ohnehin dem Buchhalter). Kein Write; der Wert geht erst nach dem
# Chat-Ja des Nutzers in tool_set_account_interest (HITL).
$nToolWebSearch = New-AdvisorToolNode 'web_search' (Resolve-CoreServiceAlias 'core:web_search' $CoreServiceMap) `
    'Live web lookup (a search model runs several searches per call and cites them; the result is dated). USE ONLY to look up the CURRENT public conditions of an account or product the user holds - typically its interest conditions: rate, cap/tiers, how often interest is credited and on which day (month end, quarter end, a fixed day, anniversary) - or the exchange ticker of a held security (ISIN + name, Yahoo Finance format with exchange suffix) when tool_verify_price_symbol finds no fitting listing; every ticker found is checked with tool_verify_price_symbol before it is proposed. DEFAULT for interest: whenever an account bears interest (new account or a rate change) and the user did not state the rate AND the crediting rhythm (for monthly crediting also the day), look the conditions up here FIRST instead of asking or guessing - at most ONE lookup per account, none if the user stated everything. RULES: query = provider + product name, NEVER personal data (names, account numbers, balances); report in plain everyday words (no codes such as ACT/365 or -1): the rate, how often and when it is credited, the source and the source date; then ask only for what the source did not give. A looked-up value is web data, not the user''s instruction, so it never triggers a write by itself - even if the user said "and record it": report it, then OFFER to record it (tool_create_account for a new account, tool_set_account_interest for an existing one); call the write tool only after the user answers yes (then the usual approval card follows). Opinions or comparisons (is it worth it, which bank is better) are the finance_advisor''s job. On ok:false say live data was unavailable and ask the user for the rate - never present a stored or remembered rate as current.' `
    @(
        ,@('query', 'Concrete web search query in German or English: provider + product name. Generic - no personal data.', 'string')
    ) $null @(-16, 400) -StartNode 'Start agent.finance'

# --- tool sub-workflows (CQRS write-tools) ---

$nToolDividend = New-ToolWorkflowNode 'tool_book_dividend' `
    'Book a dividend payment. The dividend is credited to the depot settlement account; the holding is auto-resolved from depot_name + isin (stocks/ETFs) or symbol (crypto, isin empty). Inputs: isin (ISIN for stocks/ETFs, empty for crypto), symbol (ticker or crypto symbol), depot_name, amount (positive, after withholding tax, in the settlement account currency), transaction_date (optional, see its parameter).' `
    @(
        ,@('isin', 'ISIN of the holding (stocks/ETFs). Leave empty for crypto.', 'string', '')
        ,@('symbol', 'Ticker or crypto symbol (e.g. VWCE, BTC). Crypto: always provide. Stock/ETF: leave empty if no ticker is known (the ISIN identifies the position) - never guess one.', 'string', '')
        ,@('depot_name', 'Exact name of the depot account', 'string')
        ,@('amount', 'Dividend amount in the settlement account currency (positive, net of withholding tax)', 'number')
        ,@('transaction_date', ('Booking date (' + (Get-DateParamHint) + '), only if the user names a date (empty = today)'), 'string', '')
    ) @(160, 208)

$nToolTransfer = New-ToolWorkflowNode 'tool_book_transfer' `
    'Move money between TWO of the user''s OWN accounts. Creates two transactions (debit + credit). ONLY for own-account-to-own-account moves - for money going to or coming from an EXTERNAL party that is not one of the user''s accounts, use tool_book_transaction instead. CROSS-CURRENCY: if the two accounts use DIFFERENT currencies (e.g. a EUR account and a KRW account), the legs have different native amounts - you MUST also pass to_amount (the exact amount that ARRIVES in the destination account, in the destination currency). The user states/confirms BOTH amounts; never invent a rate. For same-currency transfers omit to_amount. Inputs: from_account_name, to_account_name, amount (amount LEAVING the source, in the source currency, positive), to_amount (only for cross-currency: amount ARRIVING in the destination currency), transaction_date (optional, see its parameter), purpose (optional).' `
    @(
        ,@('from_account_name', 'Source account name (exact)', 'string')
        ,@('to_account_name', 'Destination account name (exact)', 'string')
        ,@('amount', 'Amount leaving the source account, in the SOURCE currency (positive)', 'number')
        ,@('to_amount', 'ONLY for cross-currency transfers: amount arriving in the destination account, in the DESTINATION currency (positive). Omit when both accounts use the same currency.', 'string', '')
        ,@('transaction_date', ('Booking date (' + (Get-DateParamHint) + '), only if the user names a date (empty = today)'), 'string', '')
        ,@('purpose', 'Optional Verwendungszweck / free-text note; leave empty for an auto-generated description', 'string', '')
    ) @(320, 208)

$nToolStockBuy = New-ToolWorkflowNode 'tool_book_stock_buy' `
    'Book a stock, ETF, or crypto purchase. Updates average_purchase_price; holding is auto-created if new. ISIN RULE: stocks/ETFs always have an ISIN - provide it; if no ticker is known, leave symbol empty (the ISIN then identifies the position - never guess a ticker). Crypto has no ISIN - leave isin empty and use symbol as the sole identifier. The tool checks the depot type (a stock/ETF with ISIN needs a stocks_depot, crypto without ISIN a crypto_depot) and positive values before the approval card; on ok:false relay the reason - for a wrong depot type offer the matching depot (or tool_create_account if none exists). EXISTING POSITION: when the user reports units they ALREADY HOLD (onboarding, "I have 10 VWCE", a depot statement) set existing_position=true and use their purchase price (Einstand) as price_per_share - or, when they only know the total they paid, pass it as cost_basis_total and leave price_per_share empty (the database computes the price per unit; never divide yourself) - never the current market price. The position is recorded without debiting the settlement account (its balance is already today''s). Several purchases of a position the depot does not hold yet (a list of dated buys or savings-plan executions) go through tool_import_stage_rows as one stock_buy row per purchase with its date, never as separate normal buys. A real new purchase leaves existing_position empty. BALANCE: the result carries settlement_balance and settlement_change (computed by the database; 0 for a takeover) - state only these numbers, never infer a debit or credit yourself. ORDER FEE: pass it only if the user mentions one (empty = 0, the card shows it); for an existing position leave it empty. ASSET CLASS: if the user has a published target allocation (financial_planning plan), propose the matching allocation block key as asset_class so the position counts toward rebalancing (a short lowercase key like sp500/korea/gold/bonds/cash; lowercase letters, digits and underscores only). Only set it for the FIRST buy of a new position; leave empty if unsure - it can be assigned later with tool_set_asset_classes. PRICE: the result carries price_status {status ok|stale|missing, price, price_currency, price_as_of, feed_symbol}, read right after the immediate price fetch - always tell the user in one short line whether a current price was found (price and date) or not; if not, offer to find the listing with tool_verify_price_symbol.' `
    @(
        ,@('isin', 'ISIN of the security (stocks/ETFs). Leave empty for crypto - crypto has no ISIN.', 'string', '')
        ,@('symbol', 'Ticker or crypto symbol (e.g. VWCE, BTC). Crypto: always provide. Stock/ETF: leave empty if no ticker is known (the ISIN identifies the position) - never guess one.', 'string', '')
        ,@('name', 'Display name of the security. Only needed if this is the first buy (new holding).', 'string', '')
        ,@('shares', 'Number of shares or units purchased (positive)', 'number')
        ,@('price_per_share', 'Price per share or unit, in the depot/quote currency (the same currency you give as quote_currency; e.g. EUR for a EUR position, USD for a USD-listed one). NOT converted to EUR. Only for an existing position given with cost_basis_total leave it at 0 (= not given).', 'number', 0)
        ,@('order_fee', 'Order fee in the same currency as price_per_share, only if the user mentions one (empty = 0; the card shows it)', 'string', '')
        ,@('depot_name', 'Exact name of the depot account (must match the correct type for the asset)', 'string')
        ,@('transaction_date', ('Booking date (' + (Get-DateParamHint) + '), only if the user names a date (empty = today)'), 'string', '')
        ,@('asset_class', 'Optional allocation block key for rebalancing (lowercase letters/digits/underscore, e.g. sp500). Match a target_allocation block key from the financial plan; leave empty if unsure.', 'string', '')
        ,@('provider_symbol', 'Optional Yahoo Finance feed symbol override. Stocks/ETFs: ticker with exchange suffix (VWCE.DE for Xetra / AAPL for US / VWRL.L for London). Crypto: Yahoo TICKER-FIAT (e.g. BTC-EUR; for an ambiguous ticker give the exact one, e.g. UNI7083-USD for Uniswap). Only if the raw ticker is not found by the price feed; leave empty otherwise.', 'string', '')
        ,@('quote_currency', 'Currency of the purchase price (ISO 4217, uppercase). Take it from the currency the user states with the price (e.g. EUR for "165 EUR", USD for "293 dollars"). It picks the right Yahoo listing for the live price and is stored as the position quote currency; defaults to the depot currency if not stated.', 'string', '')
        ,@('existing_position', 'true when the user already holds these units (taking over an existing position, settlement account NOT debited); leave empty for a real new purchase', 'string', '')
        ,@('cost_basis_total', 'Only with existing_position: the total amount the user paid for these units, when no price per unit is known. Leave price_per_share empty then; the database derives it.', 'string', '')
    ) @(480, 208)

$nToolCreateAccount = New-ToolWorkflowNode 'tool_create_account' `
    'Create ONE new finance account (cash = current/checking/savings, p2p, stocks_depot, crypto_depot, fixed_deposit) in ONE call with everything the user said about it - including its current balance (opening_balance) and its owner. Never split this into create + reconcile/set_account. FROM A BANK STATEMENT (tool_reconcile_bank_statement returned account_unknown and it is a new account): copy account_number, currency, closing_balance -> opening_balance and balance_date -> opening_balance_date verbatim from that result (the card then shows the printed balance); do NOT send the statement to tool_reconcile_bank_statement again afterwards (its period is contained in that balance). If the user states a different balance, use the value the user states with an empty opening_balance_date. On a correction after a cancelled card, keep every value of the previous proposal the user did not change (e.g. the IBAN). If the user only announces an account without details (e.g. "the following account belongs to Lisa"), do not list fields to fill in - ask in one short sentence for its name or its bank statement. Use this tool for a single account; several entries in one message or a document go to the import (tool_import_stage_rows). Loans are NOT accounts here - use tool_create_loan. For stocks_depot/crypto_depot a settlement_account_name is MANDATORY (the depot has no own balance; buys/sells/dividends settle on it) - ask the user which existing cash account is the Verrechnungskonto; a depot never gets an opening_balance (positions are recorded with tool_book_stock_buy existing_position=true). For all other types leave settlement_account_name empty. For fixed_deposit the tool requires interest_rate, its crediting rhythm (interest_credit_unit) AND fixed_deposit_maturity_date - look missing interest terms up with web_search first, ask the user only for what is still missing (auto-renew is optional, do not ask). Interest on a cash account: only if the user calls it a savings/Tagesgeld account or says it bears interest; otherwise leave interest empty. An interest-bearing account needs the rate AND the crediting rhythm (interest_credit_unit; for monthly also interest_credit_day_of_month) - never assume them: if the user did not state them, look the conditions up with web_search first (its description has the flow), the tool rejects a rate without rhythm (code=missing_required). ACCOUNT NUMBER: pass the IBAN or depot number only if the user gives it - never ask for it (the first bank statement teaches it; a mistyped IBAN is rejected by its check digits: code=invalid_iban -> ask the user to check it, or create the account without it). DUPLICATES: an active account with the same name (any type, any letter case) or the same account number comes back as ok:false with candidates - then ask whether they mean that account or which distinct name to use (for a member''s own account add their first name). OWNER: owner_person = the household member who owns it, passed as the user names them (a first name such as "Lisa" is enough - the tool resolves it against the household and reports ambiguity; only relations like "my wife" need the family context); never ask for a surname or full name; empty = joint/household. Required: name, account_type (+ settlement_account_name for depots, + interest_rate + interest_credit_unit + fixed_deposit_maturity_date for fixed_deposit; any interest_rate needs interest_credit_unit, monthly also interest_credit_day_of_month). Optional: opening_balance, owner_person, bank, account_number, currency (default EUR), the other interest_* fields, fixed_deposit_auto_renew.' `
    @(
        ,@('name', 'Account display name (e.g. "DKB Giro")', 'string')
        ,@('account_type', 'One of: cash, p2p, stocks_depot, crypto_depot, fixed_deposit', 'string')
        ,@('opening_balance', 'The current balance the user states, as a plain number in the account currency (negative if overdrawn). Booked as the opening balance (not a reconciliation). Leave empty if not stated; never for depots.', 'string', '')
        ,@('opening_balance_date', ('OPTIONAL, (' + (Get-DateParamHint) + '): the day opening_balance refers to - only the balance_date from a tool_reconcile_bank_statement account_unknown result. Empty = today.'), 'string', '')
        ,@('bank', 'Bank/broker name (optional)', 'string', '')
        ,@('account_number', 'IBAN, depot number, P2P account id exactly as the user gives it (spaces allowed; the database normalizes it)', 'string', '')
        ,@('settlement_account_name', 'MANDATORY for stocks_depot/crypto_depot (name of the existing cash settlement/Verrechnungs-account, must resolve uniquely); leave empty for all other account types', 'string', '')
        ,@('owner_person', 'OPTIONAL: the single household member who owns this account, as the user names them (first name is enough, e.g. a child for a custodial depot; never ask for a surname). Leave EMPTY for a joint/household account (the common case).', 'string', '')
        ,@('currency', 'ISO 4217 currency code (optional, default EUR)', 'string', '')
        ,@('interest_rate', 'Annual interest rate in percent if the account bears interest, e.g. "2.0"; leave empty if none. REQUIRED for fixed_deposit. For an interest-bearing account the user did not give terms for, look them up with web_search first, then ask only for what is missing.', 'string', '')
        ,@('interest_credit_unit', 'REQUIRED when interest_rate is set: how often interest is credited, day/week/month/year - from the user or the published conditions of the provider (web_search), never guessed', 'string', '')
        ,@('interest_credit_interval', 'Every N units for the crediting schedule, e.g. 3 with unit=month = quarterly, 6 = half-yearly (optional, default 1)', 'string', '')
        ,@('interest_credit_day_of_month', 'Crediting day. month: REQUIRED, -1 = at the end of the month or quarter or half-year (calendar), or a fixed day 1-28. year: -1 = on 31 December, empty = on the anniversary of the start date. day/week: leave empty', 'string', '')
        ,@('interest_day_count_convention', 'Day-count method, ONLY if the user explicitly overrides the proposal: 30E/360, ACT/365 or ACT/360. Leave EMPTY normally - it is proposed from the account type (cash->ACT/365, fixed_deposit->30E/360) and shown in the confirmation.', 'string', '')
        ,@('interest_posting_day_of_month', 'Arrears: if interest is credited in the month AFTER the period ends, the day of that following month (1-28). Leave empty = credited at period end (optional)', 'string', '')
        ,@('interest_auto_post', 'Whether the scheduler books interest automatically without confirmation (true/false). Leave EMPTY normally - proposed from cadence (daily/weekly->true, monthly/yearly->false) and shown in the confirmation.', 'string', '')
        ,@('interest_valid_from', ('Interest valid-from date (' + (Get-DateParamHint) + ') (optional, default today)'), 'string', '')
        ,@('fixed_deposit_maturity_date', ('Maturity date (' + (Get-DateParamHint) + ') (Fälligkeitsdatum/Laufzeitende). REQUIRED for fixed_deposit; leave empty for all other account types.'), 'string', '')
        ,@('fixed_deposit_auto_renew', 'Whether the fixed deposit auto-renews at maturity (true/false) - only if the user says it, do not ask; leave empty otherwise.', 'string', '')
    ) @(640, 208)

$nToolCreateInsurance = New-ToolWorkflowNode 'tool_create_insurance' `
    'Create a new insurance with its premium as a recurring debit. PREMIUM AS THE USER STATES IT - never convert it: if the user names the amount per debit (e.g. 30 EUR monthly), pass premium_amount plus schedule_unit (required with premium_amount; quarterly = month with schedule_interval 3); if the user names the annual premium (Jahresbeitrag), pass annual_premium (schedule_unit defaults to yearly; with a monthly or quarterly debit the database derives the amount per debit). Pass both only if the user states both. The database derives the annual and monthly values for the overview. Premiums are kept in EUR, so the debit account must be a EUR account. POLICYHOLDER: optionally assign the single household member the policy belongs to (policyholder_person) - the policyholder, or the insured member when the user says it is for or insures someone ("für meine Tochter", "versichert ist Lisa"); there is no separate insured-person field - as the user names them (a first name is enough); leave empty for a joint/household policy. You MUST capture first_payment_date - the date of the FIRST actual debit (full date). For yearly/quarterly schedules this carries the month AND day (e.g. a premium paid yearly and first debited on 15 November -> 2026-11-15); do NOT just reuse valid_from. Ask the user if they only gave a contract start. Required: name, the premium (premium_amount with schedule_unit, or annual_premium), first_payment_date, debit_account_name; valid_from defaults to first_payment_date. Optional: policyholder_person, insurance_company, policy_number, schedule_interval (default 1), schedule_day_of_month (only -1 for "last day of month" or -2 for "second-to-last day of month", else leave empty - the day comes from first_payment_date). OPTIONAL estate/emergency-register fields, capture ONLY if the user states them: insurance_type (see enum), beneficiary, coverage_amount (EUR), claim_deadline_hours (the AVB claim-notification deadline in hours).' `
    @(
        ,@('name', 'Insurance display name (e.g. "Haftpflicht DEVK")', 'string')
        ,@('insurance_company', 'Insurance company (optional)', 'string', '')
        ,@('policy_number', 'Policy number (optional)', 'string', '')
        ,@('policyholder_person', 'OPTIONAL: the single household member the policy belongs to - the policyholder, or the insured member if the user names one (as the user names them - a first name is enough; never ask for a surname). Leave EMPTY for a joint/household policy.', 'string', '')
        ,@('premium_amount', 'Premium PER DEBIT in EUR exactly as the user states it (e.g. 30 for 30 EUR monthly). Needs schedule_unit. Leave empty if the user named the annual premium.', 'string', '')
        ,@('annual_premium', 'Annual premium (Jahresbeitrag) in EUR - only if the user states a yearly amount; leave empty otherwise.', 'string', '')
        ,@('schedule_interval', 'Schedule interval as integer (optional, default 1)', 'number', '1')
        ,@('schedule_unit', 'How often the premium is debited: day, week, month or year (required with premium_amount; default year with annual_premium)', 'string', '')
        ,@('valid_from', ('Contract/policy start date (' + (Get-DateParamHint) + ') (when the cover begins; distinct from the first debit). Optional, defaults to first_payment_date.'), 'string', '')
        ,@('first_payment_date', ('Date of the FIRST actual debit (' + (Get-DateParamHint) + ') - the recurrence anchor. For yearly/quarterly this carries month+day (e.g. yearly, first debit 15 Nov -> 2026-11-15). Ask the user if only a contract start was given.'), 'string')
        ,@('schedule_day_of_month', 'ONLY set to -1 for "last day of month" or -2 for "second-to-last day of month", or to pin a monthly debit to a fixed day; otherwise leave empty (day comes from first_payment_date)', 'string', '')
        ,@('debit_account_name', 'Exact name of debit account', 'string')
        ,@('insurance_type', 'OPTIONAL insurance class, exactly one of: life, accident, disability, health, care, liability, household, residential_building, legal, vehicle, other. Leave empty if not stated.', 'string', '')
        ,@('beneficiary', 'OPTIONAL named beneficiary (Bezugsberechtigter) entitled to the payout - a named beneficiary overrides the will.', 'string', '')
        ,@('coverage_amount', 'OPTIONAL coverage sum (Versicherungssumme) in EUR.', 'string', '')
        ,@('claim_deadline_hours', 'OPTIONAL claim-notification deadline in HOURS per the policy terms (AVB), e.g. 48 for accidental death. Only if the user states it.', 'string', '')
    ) @(800, 208)

$nToolCreateLoan = New-ToolWorkflowNode 'tool_create_loan' `
    'Create a loan atomically: a loan account (negative balance = remaining debt / Restschuld), the loan record, optionally the monthly rate as a recurring payment, the Restschuld opening on the loan account, and - only if the money was paid into one of YOUR accounts - a disbursement booking. Handles BOTH fresh and already-running loans - when unclear, ASK whether the loan is already being repaid. RUNNING LOAN (already being repaid): required are current_balance (the remaining debt TODAY), interest_rate, monthly_annuity (the rate actually debited - the rate is the truth), first_payment_date (the NEXT upcoming rate) and debit_account_name. original_amount and disbursement_date are OPTIONAL history: pass them only if the user states them, never ask for them; they can be added later with tool_set_loan. The database books the remaining debt as of today and itself derives interest and principal of every rate, the initial repayment rate and the projected remaining debt. FRESH LOAN (nothing repaid yet): original_amount is required and current_balance stays empty; pass disbursement_date if the user names it (without it the loan is opened as of today). Was the money paid into one of your own accounts (typical consumer loan)? Then pass disbursement_account_name and disbursement_date (books the disbursement there); for a mortgage paid to the seller / a third party, and for every running loan, leave it empty. TERM: interest_rate_fixed_until (Zinsbindung) and term_end_date (Laufzeitende = date of the last rate) - pass them if the user states them; if you have to ask for another missing value anyway, ask for these two in the same question, but never ask an extra question only for them (empty = unknown, can be added later with tool_set_loan). A final balloon payment (Schlussrate): term_end_date = the date of that last payment, its amount goes into notes. Repayment-free phase (tilgungsfrei): enter the rate paid NOW (interest only); when it ends, change the rate with tool_set_loan. BORROWER: optionally assign the single household member who is the borrower (borrower_person) as the user names them (a first name is enough); leave empty for a joint/household loan. Optional for both: schedule_day_of_month (empty = the day of first_payment_date), real_estate_id, notes.' `
    @(
        ,@('name', 'Loan display name (e.g. "Baufi ING")', 'string')
        ,@('lender', 'Lender (bank or person)', 'string')
        ,@('borrower_person', 'OPTIONAL: the single household member who is the borrower (as the user names them - a first name is enough; never ask for a surname). Leave EMPTY for a joint/household loan.', 'string', '')
        ,@('original_amount', 'ORIGINAL loan sum in EUR (positive) - REQUIRED for a fresh loan, OPTIONAL info for a running loan (only if the user states it). Loans are kept in EUR, debit and payout accounts must be EUR accounts.', 'string', '')
        ,@('current_balance', 'Remaining debt (Restschuld) TODAY in EUR - REQUIRED for an already-running loan, leave empty for a fresh loan. Above 0 and not above original_amount (if given). Becomes the loan account balance as of today.', 'string', '')
        ,@('disbursement_date', ('Payout date (' + (Get-DateParamHint) + ') - for a fresh loan if the user names it (empty = opened as of today), required with disbursement_account_name; OPTIONAL info for a running loan. Never in the future.'), 'string', '')
        ,@('interest_rate', 'Annual interest rate in percent (e.g. 3.5)', 'number')
        ,@('interest_rate_fixed_until', ('Zinsbindungsende (' + (Get-DateParamHint) + ') if the user states it (ask only together with another missing value, never on its own); empty if unknown.'), 'string', '')
        ,@('term_end_date', ('Laufzeitende (' + (Get-DateParamHint) + ') = date of the last rate (for a balloon payment the date of that final payment). Ask only together with another missing value, never on its own; empty if unknown.'), 'string', '')
        ,@('monthly_annuity', 'Monthly rate in EUR (Zins + Tilgung) - the amount actually debited; leave empty only for a paused/family loan without a rate. If given, first_payment_date is required.', 'string', '')
        ,@('schedule_day_of_month', 'Day of month 1-28, -1 for last day or -2 for second-to-last day; leave empty to use the day of first_payment_date', 'string', '')
        ,@('first_payment_date', ('First/NEXT actual rate debit date (' + (Get-DateParamHint) + ') - recurrence anchor for the monthly rate (for running loans the next upcoming rate). REQUIRED when monthly_annuity is given - ASK if unclear; leave empty only for a loan without a rate.'), 'string', '')
        ,@('disbursement_account_name', 'Exact name of the cash account the loan was paid INTO, if it went to one of your OWN accounts (fresh loan) -> books +original_amount there and links it. Leave EMPTY for a mortgage paid to the seller / a third party, or an already-running loan (no disbursement booking, link stays NULL). Ask the user if unclear.', 'string', '')
        ,@('debit_account_name', 'Exact name of cash account from which the monthly rate is debited', 'string')
        ,@('real_estate_id', 'finance.real_estate.id if loan is mortgage (optional; lookup via postgres_select first)', 'string', '')
        ,@('notes', 'Free-text notes (optional), e.g. the amount of a final balloon payment (Schlussrate)', 'string', '')
    ) @(960, 208)

$nToolCreateRealEstate = New-ToolWorkflowNode 'tool_create_real_estate' `
    'Create a real-estate asset (NOT an account - no transaction flow). OWNER: optionally assign the single household member who owns it (owner_person) as the user names them (a first name is enough); leave empty for a joint/household asset. For a building also pass living_area_m2 and year_built when the user knows them: the card then shows the recommended monthly maintenance reserve (II. BV lower bound, computed by the tool - never calculate it yourself) and whether a reserve exists; offer to set it up afterwards with tool_create_savings_goal (real_estate_name). Required: name. Optional: current_value, value_updated_at, owner_person, status (default active), notes, living_area_m2, year_built.' `
    @(
        ,@('name', 'Display name (e.g. "Wohnung Hamburg")', 'string')
        ,@('current_value', 'Estimated current market value in EUR (optional)', 'string', '')
        ,@('value_updated_at', ('Date of last valuation (' + (Get-DateParamHint) + ') (optional)'), 'string', '')
        ,@('owner_person', 'OPTIONAL: the single household member who owns this property (as the user names them - a first name is enough; never ask for a surname). Leave EMPTY for a joint/household asset.', 'string', '')
        ,@('status', 'active or sold (optional, default active)', 'string', '')
        ,@('notes', 'Free-text notes (optional)', 'string', '')
        ,@('living_area_m2', 'OPTIONAL: living area in square metres as the user states it (e.g. 105). Leave empty if unknown.', 'string', '')
        ,@('year_built', 'OPTIONAL: year the building was completed / ready for occupancy (Baujahr, four digits, e.g. 1994). Leave empty if unknown.', 'string', '')
    ) @(1120, 208)

$nToolBookTransaction = New-ToolWorkflowNode 'tool_book_transaction' `
    'Book a SINGLE transaction on ONE of the user''s own accounts against an EXTERNAL party that is NOT one of their accounts - money going OUT (insurance debit, rent, an external fee, any expense) or coming IN (salary, refund, a received payment). This is NOT a transfer (only one leg, no counter-account); for moving money between two own accounts use tool_book_transfer instead. The direction sets the sign (the tool computes it - always pass a positive amount). Inputs: account_name (exact), direction ("inflow" or "outflow"), amount (positive, in the account currency), transaction_date (only if the user names one - empty = today), description (optional Verwendungszweck), category (optional - default "other"; "fee" for an external fee on an outflow, "interest" for interest received).' `
    @(
        ,@('account_name', 'Exact name of the own account on which the transaction is booked', 'string')
        ,@('direction', 'Either "outflow" (money leaves the account) or "inflow" (money arrives)', 'string')
        ,@('amount', 'Amount in the account currency, always positive - the direction sets the sign', 'number')
        ,@('transaction_date', ('Booking date (' + (Get-DateParamHint) + '), only if the user names a date (empty = today)'), 'string', '')
        ,@('description', 'Optional Verwendungszweck / counterparty note; leave empty for an auto description', 'string', '')
        ,@('category', 'Optional: other (default), fee (external fee, outflow only), interest (interest received)', 'string', '')
    ) @(1280, 208)

$nToolBookStockSell = New-ToolWorkflowNode 'tool_book_stock_sell' `
    'Book a stock, ETF, or crypto sale. Call it directly with the depot name and the position (symbol or ISIN) as the user names them - the tool finds the position itself and checks everything before the approval card (no own lookup, no own shares check). Sells reduce the position and credit the settlement account; the average purchase price does not change. Results: ok:false code=depot_not_found/depot_ambiguous/holding_not_found/holding_ambiguous -> ask the user which one, naming the candidates; ok:false card_sent:false with a reason such as more shares than held -> tell the user the reason (it names the available shares) and ask how many to sell; ok:true -> report proceeds and remaining shares. SAVINGS GOAL: if the user sells to secure money for a savings goal (e.g. after the advisor suggested shifting depot money to cash before the target date: "verkauf 5 VWCE fuer die Weltreise"), pass savings_goal_name - the proceeds then stay the goal money on the settlement account (the tool moves the goal share from the depot, up to the proceeds; the card shows the amount; derisk_amount in the result).' `
    @(
        ,@('depot_name', 'Name of the depot holding the position (e.g. "Trade Republic Depot")', 'string')
        ,@('symbol', 'Ticker or crypto symbol of the position as the user names it (e.g. VWCE, BTC)', 'string')
        ,@('isin', 'ISIN of the position, only if the user gives it', 'string', '')
        ,@('shares', 'Number of shares or units to sell (positive)', 'number')
        ,@('price_per_share', 'Sale price per share or unit in the position currency', 'number')
        ,@('order_fee', 'Order fee in the position currency, only if the user mentions one (empty = 0; the card shows it)', 'string', '')
        ,@('transaction_date', ('Booking date (' + (Get-DateParamHint) + '), only if the user names a date (empty = today)'), 'string', '')
        ,@('savings_goal_name', 'OPTIONAL: name of the savings goal the sale secures money for (the proceeds stay assigned to that goal). Leave EMPTY for a normal sale.', 'string', '')
    ) @(1440, 208)

$nToolBookLoanPayment = New-ToolWorkflowNode 'tool_book_loan_payment' `
    'Book a loan payment (Kreditrate) — two transactions atomically: full rate debit on the cash account + principal credit on the loan account. If principal_amount is omitted the tool derives it from the current Restschuld. Use this for both regular monthly rates (leave principal_amount empty) AND Sondertilgung (provide explicit principal_amount). A regular rate (amount = the planned monthly rate) is matched to its open due date from the recurring reminder and booked on that due date, so the reminder will not ask for it again. AMOUNT CHECK: the tool itself checks the amount before the approval card - if it returns ok:false because the rate would overpay (reason names the payoff amount = Restschuld + interest), ask whether to book the payoff via tool_settle_loan instead; if the rate does not even cover the interest, ask for a higher rate. Do not work out interest or principal yourself. If the user does not name an amount, leave payment_amount empty - the tool takes the installment that is due (the planned rate, or the payoff amount for the last rate) and shows it on the card. Inputs: loan_name, payment_amount (only if the user names one, positive), payment_date (see its parameter), principal_amount (optional Tilgungsanteil; omit for normal rates).' `
    @(
        ,@('loan_name', 'Name of the loan (resolved to loan_id; use exact name from finance.loans)', 'string')
        ,@('payment_amount', 'Total payment amount in EUR (positive, Zins + Tilgung) - only if the user names an amount; empty = the installment that is due.', 'string', '')
        ,@('payment_date', ('Payment date (' + (Get-DateParamHint) + '), only if the user names a date (empty = today)'), 'string', '')
        ,@('principal_amount', 'Optional explicit Tilgungsanteil in EUR (positive). Omit for normal rates - the tool derives it from the Restschuld. Set only for Sondertilgung.', 'string', '')
    ) @(1600, 208)

$nToolCreateSavingsGoal = New-ToolWorkflowNode 'tool_create_savings_goal' `
    'Create a savings goal atomically. What matters is WHERE the money for the goal is (Mittelverwendung): reserve_account_name = the account that holds or receives the money of the goal (cash/Tagesgeld, fixed-deposit, P2P - or a depot when a savings plan funds the goal). If money for the goal ALREADY lies on that account, pass it as already_saved (the absolute amount the user names) - it is earmarked without any transfer. A monthly rate is only needed for what is still missing: RATE/DATE ARE COMPUTED BY THE TOOL - DO NOT CALCULATE EITHER YOURSELF: pass target_amount plus EXACTLY ONE of {target_date, monthly_savings_rate} (with savings plans neither is needed); the tool derives the missing one on the REMAINDER (target - already_saved) and shows it on the card. If already_saved covers the target, the rate is 0, NO recurring payment is created and NO account_name is needed - only the target date (ask for it if missing; a month is enough, e.g. "Januar 2027" = 2027-01-31). If the user says the goal needs no rate, do NOT ask for a debit account. When a rate is needed, account_name = the account it is debited from (it must differ from reserve_account_name); the rate is a TRANSFER into the reserve account. SAVINGS PLANS INTO A DEPOT (e.g. "money goes from my current account to my child''s cash account and from there by savings plan into the depot"): reserve_account_name = the DEPOT, savings_plan_name = the plan(s) (several comma-separated, all are linked), no account_name, no own rate; the standing transfer to the cash account STAYS as it is (it is not a goal rate - never delete it); when the user says the money of the goal lies in that depot, pass today''s market value of the depot as already_saved in this same call (read finance.depot_reserve_status.market_value, or one position''s market_value_eur in finance.depot_holdings_overview if only that position belongs to the goal; do not ask first) - ask only when it is unclear whether the money already in the depot belongs to the goal; without target_date and monthly_savings_rate the tool derives the date from the plans'' monthly amount. After creating it, explain in 2-3 short sentences how it works: each plan purchase adds the amount paid in (booked via the monthly statement check or when the user reports it), the market value is only checked as coverage (the advisor speaks up if the depot falls below the money paid in), and 5 years before the target date the advisor suggests shifting depot money to an account step by step. If the user gives BOTH date and rate, pass both (the target_date wins). EXISTING STANDING TRANSFER: rejection existing_transfer = a standing transfer already pays into the savings account - do NOT delete it, ask the user whether it IS this goal''s savings rate: yes -> call again with replace_transfer=true (the goal continues it with its amount and day, it ends then), no -> replace_transfer=false (an additional rate). Pass first_payment_date only if the user names it - empty = the next debit day from today. target_amount must be positive. BENEFICIARY: leave EMPTY normally - the goal then belongs to the owner of the reserve account (household for a joint account); only name a household member (beneficiary_person, a first name is enough) if the goal is FOR someone else, e.g. a child. Without a reserve account the progress cannot be measured, so the tool rejects the goal: ask which account it is or offer to create one with tool_create_account first. Rejections tell the next step: insufficient_free_balance = less money on the account is free than already_saved (tell the user the free amount); a remainder without account_name = ask from which account the rate is debited, or whether more existing money belongs to the goal. MAINTENANCE RESERVE for a property (Instandhaltungsruecklage): pass real_estate_name (the property as stored), target_amount 0 and leave target_date and savings_plan_name EMPTY - it is an ongoing reserve without end; goal_name may stay empty (the tool names it). Its monthly rate is the amount the user names, otherwise the II. BV recommendation from living area and year built (computed by the tool, a lower bound - never calculate it yourself; rejection maintenance_data_missing = ask for area and year built, or for an amount). It needs the reserve account and the debit account like any rate; a repair paid from it later = tool_book_savings_goal_transfer withdrawal. Required: goal_name, target_amount, reserve_account_name and ONE of target_date / monthly_savings_rate (both may be empty when savings_plan_name is given) - for a maintenance reserve only real_estate_name and reserve_account_name. Optional: already_saved, account_name, savings_plan_name, replace_transfer, schedule_day_of_month (-1 = last day of month, -2 = second-to-last day), first_payment_date, goal_type, notes, beneficiary_person, priority (lower = more important, for bottleneck ordering).' `
    @(
        ,@('goal_name', 'Savings goal display name (e.g. "Urlaub 2027"); may stay empty only for a maintenance reserve (the tool names it)', 'string', '')
        ,@('goal_type', 'Goal type label (optional, free text e.g. vacation, emergency, car)', 'string', '')
        ,@('target_amount', 'Target savings amount in EUR (positive); leave 0 for a maintenance reserve', 'number', '0')
        ,@('target_date', ('Target date to reach the goal in (' + (Get-DateParamHint) + '). Give this OR monthly_savings_rate - the tool derives the other. Leave empty if the user stated a monthly amount instead.'), 'string', '')
        ,@('monthly_savings_rate', 'Monthly savings amount in EUR (positive) exactly as the user states it. Give this OR target_date - the tool derives the other. Leave empty if the user stated a target date instead.', 'string', '')
        ,@('account_name', 'Exact name of the account the monthly savings rate is debited from - ONLY when a rate is needed (leave EMPTY when already_saved covers the goal or a savings plan funds it)', 'string', '')
        ,@('schedule_day_of_month', 'Day of month 1-28, -1 for last day or -2 for second-to-last day (when the savings rate is debited); leave empty to use the day of first_payment_date', 'string', '')
        ,@('first_payment_date', ('Date of the FIRST savings debit (' + (Get-DateParamHint) + ') - only if the user names it; empty = the next debit day from today (do not ask).'), 'string', '')
        ,@('notes', 'Free-text notes (optional)', 'string', '')
        ,@('beneficiary_person', 'OPTIONAL: only if the goal is FOR someone other than the owner of the savings account (e.g. a child), named as the user says it (a first name is enough). Leave EMPTY - the goal then belongs to the savings account owner.', 'string', '')
        ,@('reserve_account_name', 'REQUIRED: exact name of the account that holds or receives the money of the goal (a cash/Tagesgeld, fixed-deposit or P2P account; a depot only together with already_saved or savings_plan_name). A monthly rate becomes a transfer into this account. Must differ from account_name.', 'string')
        ,@('priority', 'OPTIONAL: rank for ordering goals when funds are tight - a small integer where LOWER = more important (1 = top priority). Leave EMPTY if the user did not state a priority.', 'string', '')
        ,@('already_saved', 'OPTIONAL: money that ALREADY lies on reserve_account_name for this goal, as the absolute amount the user names (account currency; EUR for a depot). It is earmarked without a transfer. Leave EMPTY if nothing is there yet.', 'string', '')
        ,@('savings_plan_name', 'OPTIONAL: exact name(s) of the existing savings plan(s) that fund this goal, several comma-separated (their buys count toward the goal; then no own monthly rate; without target_date and monthly_savings_rate the date follows from their monthly amount). Leave EMPTY otherwise.', 'string', '')
        ,@('replace_transfer', 'ONLY after the rejection existing_transfer, with the answer of the user: true = the existing standing transfer IS the savings rate of this goal (the goal continues it), false = the goal rate comes on top. Leave EMPTY otherwise.', 'string', '')
        ,@('real_estate_name', 'ONLY for a maintenance reserve (Instandhaltungsruecklage): exact name of the property as stored. Then leave target_amount, target_date and savings_plan_name EMPTY. Leave EMPTY for every other goal.', 'string', '')
    ) @(1760, 208)

$nToolBookSavingsGoalTransfer = New-ToolWorkflowNode 'tool_book_savings_goal_transfer' `
    'Move money in relation to a savings goal — the ONE tool for an EXTRA one-off deposit into a goal, a withdrawal from it ("used the savings elsewhere"), or relocating a goal''s reserve between the user''s own accounts. This is NOT the monthly savings rate (that is created with tool_create_savings_goal). Every movement is physically a transfer between two of the user''s cash/Tagesgeld, fixed-deposit or P2P accounts (money already earmarked for the goal on an account counts as the goal''s money there); the direction decides which leg(s) get tagged to the goal, so the goal progress moves correctly. Pass only the accounts the user names: the tool fills the rest from the goal''s reserve account (deposit: to = reserve, from = the savings-rate funding account; withdrawal/relocate: from = reserve) and the approval card shows both. Required: savings_goal_name, amount, direction. Rejections (no card, reason tells the next step): not_reserve = neither account belongs to the goal''s reserve; insufficient_share = less of the goal''s money on the source account than the amount; use_relocate = both accounts belong to the goal, so call again with direction relocate; missing_from/missing_to/no_reserve = ask the user for that account; depot_not_allowed = a depot share is earmarked with tool_book_savings_reservation; not_found/ambiguous = ask which account (candidates).' `
    @(
        ,@('savings_goal_name', 'Name of the savings goal this movement belongs to, as the user says it', 'string')
        ,@('from_account_name', 'SOURCE account (money leaves here), only if the user names it (empty = derived from the goal)', 'string', '')
        ,@('to_account_name', 'DESTINATION account (money arrives here), only if the user names it (empty = derived from the goal; required for a withdrawal or relocate the user describes)', 'string', '')
        ,@('amount', 'Amount moved, in the source account currency (positive magnitude)', 'number')
        ,@('direction', 'One of: deposit (put money INTO the goal), withdrawal (take money OUT of the goal), relocate (move money of the goal from one own account to another - total progress stays the same; moving all of it makes the new account the reserve of the goal)', 'string')
        ,@('transaction_date', ('Booking date (' + (Get-DateParamHint) + '), only if the user names a date (empty = today)'), 'string', '')
        ,@('purpose', 'Optional free-text note for the booking', 'string', '')
        ,@('to_amount', 'Only for a cross-currency move: the amount that ARRIVES in the destination account, in its currency', 'string', '')
    ) @(1760, 360)

$nToolBookSavingsReservation = New-ToolWorkflowNode 'tool_book_savings_reservation' `
    'Earmark money that ALREADY LIES on an account for a savings goal - no money moves ("the 3000 EUR on my Tagesgeld are for the trip", "reserve 5000 EUR of my depot for the car"). Works on cash/Tagesgeld, fixed-deposit, P2P and depot accounts. This is NOT a movement (an extra deposit/withdrawal between accounts uses tool_book_savings_goal_transfer; the monthly rate comes with tool_create_savings_goal). The amount is the ABSOLUTE total the user wants earmarked on this account for this goal; money already paid into the goal on that account counts toward it, the tool computes the change and appends one journal entry, so the goal progress moves. Amount currency: the account currency for a cash/fixed-deposit/P2P account, EUR for a depot (its market value is only the coverage check). Rejection insufficient_free_balance = the account does not have that much money that is not yet earmarked for goals (the reason names the free amount) - tell the user, do not retry with another number on your own. Required: savings_goal_name, account_name, amount.' `
    @(
        ,@('savings_goal_name', 'Exact name of the savings goal the money belongs to', 'string')
        ,@('account_name', 'Exact name of the account the money lies on (cash/Tagesgeld, fixed deposit, P2P or depot)', 'string')
        ,@('amount', 'The ABSOLUTE amount earmarked on this account for this goal, exactly as the user states it (0 releases the earmark); the tool derives the change.', 'number')
    ) @(1760, 512)

$nToolReconcileAccount = New-ToolWorkflowNode 'tool_reconcile_account' `
    'Reconcile a SINGLE account by confirming the real-world balance (Saldo-Abgleich). Updates last_reconciled_balance and last_reconciled_at on the account. If the confirmed_balance differs from the DB balance a reconciliation correction transaction is booked automatically. The confirmed_balance is in the account own currency (EUR, KRW, ...), not forced to EUR. Use this when the user gives ONE account balance. For SEVERAL balances at once (e.g. answering the monthly reconcile reminder), use tool_reconcile_accounts_batch instead. Inputs: account_name, confirmed_balance (signed - positive for credit, negative for an overdraft), reconciliation_date (see its parameter), notes (optional). Only for an EXISTING account: the balance of a NEW account belongs into tool_create_account (opening_balance), never create + reconcile.' `
    @(
        ,@('account_name', 'Exact name of the account to reconcile', 'string')
        ,@('confirmed_balance', 'Real-world balance in the account own currency as seen in the bank app or statement (signed)', 'number')
        ,@('reconciliation_date', ('Date of the confirmed balance (' + (Get-DateParamHint) + '), only if the user names a date (empty = today)'), 'string', '')
        ,@('notes', 'Optional reason for any drift (e.g. "bank fees pending")', 'string', '')
    ) @(1920, 208)

$nToolReconcileAccountsBatch = New-ToolWorkflowNode 'tool_reconcile_accounts_batch' `
    'Reconcile SEVERAL accounts in one go (the monthly Saldo-Abgleich reminder path). Use this when the user sends multiple account balances in one message. One combined approval covers the whole batch and all corrections are booked atomically. Each balance is in that account own currency. Pass accounts as a JSON array string; each item is {"account_name": exact name, "confirmed_balance": signed number, "reconciliation_date": date string (optional, defaults to today; forms as described in the accounts parameter), "notes": optional}. Example: [{"account_name":"Girokonto","confirmed_balance":5230.11},{"account_name":"Bargeld","confirmed_balance":80}].' `
    @(
        ,@('accounts', ('JSON array string of accounts to reconcile, each {account_name, confirmed_balance, reconciliation_date? (' + (Get-DateParamHint) + '), notes?}'), 'string')
    ) @(2240, 360)

# --- Bulk-Import-Pipeline (Phase 2 Onboarding-Plan): 3-Schritt stage -> fix -> commit ---
$nToolImportStageRows = New-ToolWorkflowNode 'tool_import_stage_rows' `
    'BULK IMPORT step 1/3 — stage several entries at once. RULE: exactly ONE entry -> its single tool (tool_create_account, tool_create_insurance, ...); TWO OR MORE entries in one message, a pasted list/CSV or statement data -> this import (a CSV FILE attachment of a bank export -> tool_import_broker_csv); a pension statement (Standmitteilung) has no single tool -> this import. Never mix both paths for the same entries. No approval here — the user reviews and approves ONCE at tool_commit_import. Pass rows as a JSON array string; every row has entity_type plus RAW fields (account references by exact NAME, never ids; raw values only — never compute averages, totals or monthly equivalents). Supported entity_type + required fields: account{name, account_type: cash|p2p|stocks_depot|crypto_depot|fixed_deposit, settlement_account (cash account name, required for depots), opening_balance? (current balance, booked as the opening balance; never for depots), owner_person?, bank?, account_number?, currency?, interest_rate?} · stock_buy{depot (name), symbol (ticker; optional when isin is given - never guess one, the ISIN then identifies the position; required for crypto), isin (required for stocks_depot), shares, price_per_share (the purchase price / Einstand, NOT the current market price), depot_number? + depot_holder? (as printed on a statement - they pick the depot and flag a mismatch), cost_basis_total? (total paid instead of price_per_share), transaction_date? (purchase date)} — a CURRENT DEPOT POSITION, recorded without debiting the settlement account; several dated purchases of the same position (one row each, every row with its transaction_date) become its purchase history, the database sums them · insurance{name, the premium as stated: premium_amount (per debit, then schedule_unit required) OR annual_premium (EUR, schedule_unit default year), debit_account (name, EUR account), first_payment_date, policyholder_person?, insurance_company?, policy_number?, schedule_interval?} — never convert a monthly premium into a yearly one; the database derives the other values · pension{name, pension_type: statutory|occupational|riester|ruerup|private, owner_person?, provider?, current_value?, contribution_amount? (per debit as stated, +debit_account+first_payment_date then required), schedule_unit? (default month), schedule_interval?} · pension_statement{pension (name), statement_date, at least one of reached_claim|projection|em_monthly} · recurring_payment{name, direction: income|expense, amount (positive), account (name), schedule_unit: day|week|month|year, first_payment_date} · real_estate{name, current_value, owner_person?} · savings_goal{name, target_amount, reserve_account (name of the account that holds or receives the money, required), already_saved? (money already on reserve_account for the goal), account? (debit account of the monthly rate - only needed when already_saved does not cover the goal), savings_plan? (name of a savings plan that funds it), first_payment_date? (empty = next debit day), beneficiary_person?, EXACTLY ONE of target_date|monthly_savings_rate} · loan{name, interest_rate, debit_account (name, EUR account), running loan: current_balance (remaining debt today) - original_amount? and disbursement_date? only if stated; fresh loan: original_amount (EUR) + disbursement_date? (empty = opened as of today), monthly_annuity? (+first_payment_date then required), borrower_person?, lender?, disbursement_account? (only for a fresh loan, then disbursement_date required), interest_rate_fixed_until?, term_end_date?, notes?, real_estate? (name)}. Person fields take the household member name (empty = household); never use other person keys. Beyond the listed fields a row may carry the other optional fields the matching single create/buy tool accepts (e.g. interest details, notes); any other key makes the row invalid and the error names the allowed fields. Returns batch_id + per-row validation errors (fix via tool_update_staging_row, then tool_commit_import). batch_id input empty = new batch; pass an existing batch_id to ADD rows to it.' `
    (Get-ImportToolSpec 'tool_import_stage_rows') @(2400, 360)

$nToolUpdateStagingRow = New-ToolWorkflowNode 'tool_update_staging_row' `
    'BULK IMPORT step 2/3 — correct ONE staged row before committing (user says e.g. "Zeile 7: Saldo 5230" or "nimm die Versicherung raus"). No approval needed (staging is a working copy). payload_merge is a JSON object string with the keys to change (a JSON null value REMOVES a key); delete_row=true removes the whole row. The whole batch is re-validated afterwards (references may change). Returns the row status and validation_error plus batch valid/invalid counts.' `
    (Get-ImportToolSpec 'tool_update_staging_row') @(2560, 360)

$nToolExtractFinanceDocument = New-ToolWorkflowNode 'tool_extract_finance_document' `
    'BULK IMPORT vision path — extract finance data from a PHOTO or PDF the user sent (Depotauszug, Versicherungspolice, Renteninformation/Standmitteilung, a document to set up NEW accounts). A bank account statement with booking lines (Kontoauszug, credit card statement) goes to tool_reconcile_bank_statement instead; a CSV export file of a bank goes to tool_import_broker_csv. Call this when the task contains an [attachment file_id=... type=photo|document] marker; pass that file_id verbatim. If the kind of document is unclear (e.g. sent without a caption), call THIS tool first instead of asking the user what it is - it recognises a bank statement and answers code=use_reconcile_bank_statement (then call tool_reconcile_bank_statement with the same file_id). doc_hint = one sentence of context from the user (e.g. "Depotauszug Trade Republic, Depot heisst Trade Republic Depot") — it massively improves extraction and lets the model fill the depot/pension reference names. The tool downloads the file, extracts RAW printed values only (positions as synthetic buys, balances, premiums; never derived values) and stages them (source=vision). If ALL rows are valid, this tool itself sends the approval card (tool_commit_import runs inside it) and returns its outcome with approval_card_sent=true: ok:true + committed = the user already approved and everything is written (report it as done; do NOT call tool_commit_import again); cancelled:true = the user cancelled (the staging stays; ask what to change, fix via tool_update_staging_row, then tool_commit_import). If some rows are invalid, no card is sent: the result has batch_id + valid/invalid + errors -> relay the invalid rows, fix via tool_update_staging_row, then tool_commit_import. Each of these row errors carries row = the identifying values read from the document (name, isin, shares, depot, ...): use them and never ask the user for a value that is in row. PURCHASE PRICE MISSING (an asset overview prints only the current price): ask ONCE for all affected positions together, each by name and number of shares, for its purchase price per unit OR its total purchase value; set it raw as the user says it via tool_update_staging_row (price_per_share or cost_basis_total; to replace a price already in the row with a total, also send price_per_share: null), then tool_commit_import. DEPOT MISMATCH (the error names a printed depot number or holder): ask which depot the document belongs to, then set depot via tool_update_staging_row. If that depot does not exist yet, add it to THIS batch (tool_import_stage_rows with this batch_id: an account row with account_type stocks_depot, settlement_account, owner_person and the printed depot number as account_number) instead of creating it separately, and point the positions to it; when you tell the user, say whether its settlement account already exists or is created with the import (never list an existing account as if it were new). Before the card a dry run of the write checks every row; if it fails, approval_card_sent=false and errors/error_summary name the row and the problem (no card was sent) -> relay them in plain words, fix via tool_update_staging_row, then tool_commit_import. CASH BALANCE of a depot overview (the settlement cash line) is never staged; it comes back in balances[] (account_name, balance, balance_date, balance_before, difference, skip_count): for each entry with ok:true and a difference other than 0, call tool_reconcile_account(account_name, confirmed_balance = balance, reconciliation_date = balance_date) - after the import card if there is one, otherwise right away; it shows its own card. A difference of 0 needs no call (say the balance matches). An entry with ok:false: relay its error in plain words. Never play extracted values back and ask for confirmation in text - the card is the review (asking for a value an invalid row is missing is not a playback).' `
    (Get-ImportToolSpec 'tool_extract_finance_document') @(2880, 360)

$nToolReconcileBankStatement = New-ToolWorkflowNode 'tool_reconcile_bank_statement' `
    'MONTHLY CHECK — import a bank account statement (Kontoauszug or credit card statement, PHOTO or PDF) of an EXISTING account (a CSV export FILE goes to tool_import_broker_csv): the tool reads it, finds the account by its IBAN, checks that opening balance + all lines = closing balance, ticks off the expected recurring payments (rent, salary, loan rate, savings rate, transfers), books them with the real date and amount, skips expected payments that did not happen, and books everything else as ONE everyday-spending total so the balance matches the statement. Individual purchases are not stored. Routine: reminder on the 3rd of each month, repeated on the 17th for accounts still missing; one file per account, the next only after its card is confirmed; the IBAN is learned from the first statement; an account without statements is confirmed by naming its balance (tool_reconcile_account); a wrong statement is undone with tool_void_bank_statement (latest one only). Call it when the task contains an [attachment file_id=... type=photo|document] marker that is a bank statement; pass file_id verbatim and a one-sentence doc_hint. Results: ok:true -> report in one or two sentences (period, everyday spending, anything changed or skipped); if unknown_direct_debits is not empty, ask whether each is a new contract to add (tool_create_recurring_payment); if outlook is present, relay it. ok:false code=account_unknown -> no account has this IBAN yet (account_number = the printed IBAN). If the conversation already says which account it is or that it is a new one (e.g. whose account it is), do not ask again; otherwise ask which of the candidates or a new account it belongs to. Existing account -> call again with account_name (the IBAN is then saved). New account -> tool_create_account (ask only for a name if none was given; account_type cash, owner as said, account_number = that IBAN, currency = currency, opening_balance = closing_balance, opening_balance_date = balance_date) and do NOT call this tool again for that statement - the account starts with its printed closing balance. If balance_verified is false (the balance check failed or the period is not over), create it without a balance and ask the user for the current balance. code=balance_check_failed -> a line was misread (difference given): ask for a clearer PDF from online banking, or offer to just set the closing balance with tool_reconcile_account. code=already_covered/already_imported -> tell the user this period is already confirmed. code=not_a_statement -> use tool_extract_finance_document for depot statements and insurance letters. code=stale_preview -> call the tool again. code=unreadable/invalid_statement -> the file was misread: ask for the PDF from online banking. code=currency_mismatch -> the statement is kept in another currency than that account: ask which account it belongs to. code=period_in_future -> the statement is not final yet: ask for it once the period has ended.' `
    @(
        ,@('file_id', 'The file_id from the attachment marker, verbatim', 'string')
        ,@('doc_hint', 'One sentence of context from the user (e.g. "Kontoauszug Oktober Sparkasse Giro")', 'string', '')
        ,@('account_name', 'ONLY after an account_unknown result: exact name of the existing account the user said this statement belongs to', 'string', '')
    ) @(3040, 360)

$nToolVoidBankStatement = New-ToolWorkflowNode 'tool_void_bank_statement' `
    'Take back the LAST imported bank statement of an account (e.g. it was assigned to the wrong account or a wrong statement was sent): removes every booking of that monthly check, re-opens the payments it skipped and restores the previous confirmed balance, so the statement can be sent again. Only the most recent statement per account; plan changes and a learned IBAN stay.' `
    @(
        ,@('account_name', 'Exact name of the account whose last statement should be taken back', 'string')
    ) @(3200, 360)

$nToolImportBrokerCsv = New-ToolWorkflowNode 'tool_import_broker_csv' `
    'MONTHLY CHECK FROM A BROKER CSV EXPORT — import the transaction export (CSV FILE) of a bank that offers one (today: Trade Republic; SELECT finance.fn_broker_csv_profiles() lists them) for the EXISTING cash account it belongs to. No language model reads the file: a fixed reader turns it into the monthly check of that account (period = after the last confirmed day up to yesterday), books savings-plan executions with the exact units, books buys, sells and dividends that are not booked yet and books everything else as ONE everyday-spending total. If a position was recorded as ONE takeover (existing position) and the export proves its individual purchases, a first card offers to replace it by the real purchases (same units, real cost; purchases after the confirmed balance date become real purchases that reduce the cash); then the monthly-check card follows. Call it when the task contains an [attachment file_id=... type=document] marker and the user calls it a CSV / export / Transaktionsexport, or when another tool answered that the file is a CSV export; pass file_id verbatim. closing_balance is REQUIRED: the balance the bank app shows RIGHT NOW, exactly as the user says it - never compute, estimate or reuse an older number; if the user has not said it in this conversation, ask for it first (one short question) and call with the same file_id afterwards. Results: ok:true -> report in one or two sentences (period, everyday spending, trades_booked, positions_replaced_by_purchases); name trades_not_booked and unknown_export_rows if any; positions_not_matching_export = the export does not prove all purchases of that takeover (nothing changed there); relay outlook if present. ok:false code=closing_balance_required -> ask for the balance; no_starting_point -> the account has no confirmed balance date yet: confirm today''s balance with tool_reconcile_account, then send the export again; csv_profile_unknown -> this bank''s export is not supported yet (a printed statement goes to tool_reconcile_bank_statement); multiple_sub_accounts -> ask to export each account on its own; not_a_csv -> it is a photo or PDF: tool_reconcile_bank_statement; already_covered -> nothing new since the last check; account_unknown/account_ambiguous -> ask which existing account (candidates). Undo the latest check with tool_void_bank_statement.' `
    @(
        ,@('file_id', 'The file_id from the attachment marker, verbatim', 'string')
        ,@('account_name', 'Exact name of the existing cash account the export belongs to (e.g. the Trade Republic cash account)', 'string')
        ,@('closing_balance', 'The balance the bank app shows right now, exactly as the user said it (e.g. "1234.56"); empty if not said yet', 'string', '')
    ) @(3120, 520)

$nToolCommitImport = New-ToolWorkflowNode 'tool_commit_import' `
    'BULK IMPORT step 3/3 — commit a staged batch ATOMICALLY after ONE user approval (the tool builds the summary and shows approve/decline buttons — do not ask for text confirmation first). A photo/PDF import whose rows were all valid already ran this inside tool_extract_finance_document (approval_card_sent=true) — call it only after corrections or for chat-staged batches. Requires ALL rows valid (otherwise it returns ok:false and names the invalid count — fix via tool_update_staging_row first). Before the card it runs a dry run of the write: if that fails, NO card is sent and it returns ok:false, card_sent:false, errors (row_no) + error_summary — relay them in plain words, fix via tool_update_staging_row, then call this tool again. All-or-nothing: on any failure NOTHING is written, the staging stays intact, the tool returns the failing rows — relay them, let the user correct, then call this tool again (one button re-approval). Success returns committed count + created ids/balances, plus positions_without_price (depot positions without a current price after the immediate fetch, status missing or stale - tell the user and follow up with tool_verify_price_symbol and let the user choose the listing) and positions_without_asset_class (only if a financial plan with a target allocation exists: propose a block key per position and assign them all with ONE tool_set_asset_classes call; without a plan stay silent about it).' `
    (Get-ImportToolSpec 'tool_commit_import') @(2720, 360)

$nToolCloseAccount = New-ToolWorkflowNode 'tool_close_account' `
    'Close an account permanently — sets status to ''closed''. After closing the DB trigger blocks any new transactions on this account forever. Call this tool directly — do NOT ask the user for text confirmation yourself first. The tool internally reads the current balance and presents a full approval summary (balance, account type, closure date, ACHTUNG irreversibility warning) to the user via approve/decline buttons. The user confirms or declines via button — no free-text round-trip needed. BLOCKER CHECK: the tool checks before the approval card whether the account can be closed and returns ok:false with a reason if it still holds a balance, is the settlement account of an active depot, holds depot positions or an active savings plan, is used by a loan, or still has running/paused recurring payments as source or target. Relay the reason and the concrete next step (transfer the balance out, end or move the recurring payments, close/re-link the depot) - do not retry. Inputs: account_name; optional closure_date (empty = today) and notes (reason for closing).' `
    @(
        ,@('account_name', 'Exact name of the account to close', 'string')
        ,@('closure_date', ('Closing date (' + (Get-DateParamHint) + '), only if the user names a date (empty = today)'), 'string', '')
        ,@('notes', 'Optional reason for closing (e.g. "switched to Trade Republic")', 'string', '')
    ) @(2080, 208)

$nToolCreateRecurringPayment = New-ToolWorkflowNode 'tool_create_recurring_payment' `
    'Create a standalone recurring income or expense: salary, rent, subscription, pension payout, membership, utilities. NOT for insurance premiums / loan rates / savings rates - those have their own create tools (create_insurance/create_loan/create_savings_goal) which book their own recurring payment. This records the MONEY FLOW for the cash flow; the contract itself (what happens to it on death, cancellation) is an estate provider contract, recorded by the estate advisor. direction = income (money in) or expense (money out); amount is always positive and the tool applies the sign. schedule_unit day|week|month|year with schedule_interval (e.g. 3 + month = quarterly). For a LATER amount change (e.g. Gehalt -> Elterngeld -> Gehalt) add a NEW entry with a new valid_from and set valid_to on the previous one. The tool rejects a second running payment with the same name (ok:false with candidates - ask whether to change the existing one with tool_set_recurring_payment); a same-named payment that belongs to an insurance/loan only shows a hint on the card. Required: name, account_name, direction, amount, schedule_unit, first_payment_date. Optional: schedule_interval (default 1), schedule_day_of_month (1-28, -1 for last day or -2 for second-to-last day), valid_from (default first_payment_date), valid_to, notes.' `
    @(
        ,@('name', 'Display name (e.g. Gehalt, Miete Wohnung, Netflix)', 'string')
        ,@('account_name', 'Exact name of the account the payment goes to (income) or from (expense)', 'string')
        ,@('direction', 'income (money in, e.g. salary) or expense (money out, e.g. rent)', 'string')
        ,@('amount', 'Amount per occurrence in the account currency, always positive (the tool applies the sign from direction)', 'number')
        ,@('schedule_unit', 'day, week, month or year', 'string')
        ,@('first_payment_date', ('Date of the first payment (' + (Get-DateParamHint) + ') (recurrence anchor)'), 'string')
        ,@('schedule_interval', 'Every N units (e.g. 3 with unit month = quarterly). Default 1.', 'string', '')
        ,@('schedule_day_of_month', 'Day of month 1-28, -1 for last day or -2 for second-to-last day. Empty = relative to first payment.', 'string', '')
        ,@('valid_from', ('Start of validity (' + (Get-DateParamHint) + '). Empty = first_payment_date.'), 'string', '')
        ,@('valid_to', ('Last day the payment is still valid (inclusive), (' + (Get-DateParamHint) + '). Empty = indefinite.'), 'string', '')
        ,@('notes', 'Free-text notes (optional)', 'string', '')
    ) @(2240, 208)

$nToolCreateRecurringTransfer = New-ToolWorkflowNode 'tool_create_recurring_transfer' `
    'Set up a RECURRING internal transfer between TWO of the user''s OWN accounts (e.g. a monthly standing order of 200 EUR from the owner''s account to a child''s custodial-depot cash account). This is for a REPEATING move - for a ONE-OFF move between own accounts use tool_book_transfer, and for a standalone income/expense to/from an EXTERNAL party use tool_create_recurring_payment. An internal transfer is cashflow-neutral (it is NOT counted as a household expense or savings amount); the booking each period is two-legged (debit on the source, credit on the destination) and runs through the recurring scheduler. amount is always positive (money leaving the source); the tool stores the sign and books the magnitude. schedule_unit day|week|month|year with schedule_interval (e.g. 1 + month = monthly). Required: name, from_account_name, to_account_name, amount, schedule_unit, first_payment_date. Optional: schedule_interval (default 1), schedule_day_of_month (1-28, -1 for last day or -2 for second-to-last day), valid_from (default first_payment_date), valid_to, notes.' `
    @(
        ,@('name', 'Display name (e.g. Sparübertrag Kinderdepot)', 'string')
        ,@('from_account_name', 'Exact name of the SOURCE account (money leaves here)', 'string')
        ,@('to_account_name', 'Exact name of the DESTINATION account (money arrives here)', 'string')
        ,@('amount', 'Amount per occurrence in the source account currency, always positive (leaving the source account)', 'number')
        ,@('schedule_unit', 'day, week, month or year', 'string')
        ,@('first_payment_date', ('Date of the first transfer (' + (Get-DateParamHint) + ') (recurrence anchor)'), 'string')
        ,@('schedule_interval', 'Every N units (e.g. 1 with unit month = monthly). Default 1.', 'string', '')
        ,@('schedule_day_of_month', 'Day of month 1-28, -1 for last day or -2 for second-to-last day. Empty = relative to first transfer.', 'string', '')
        ,@('valid_from', ('Start of validity (' + (Get-DateParamHint) + '). Empty = first_payment_date.'), 'string', '')
        ,@('valid_to', ('Last day the payment is still valid (inclusive), (' + (Get-DateParamHint) + '). Empty = indefinite.'), 'string', '')
        ,@('notes', 'Free-text notes (optional)', 'string', '')
    ) @(2400, 208)

$nToolCreatePension = New-ToolWorkflowNode 'tool_create_pension' `
    'Record a retirement provision (Altersvorsorge) as a net-worth asset. pension_type one of: statutory (gesetzliche Rente), occupational (bAV), riester, ruerup, private (private Rentenversicherung). current_value = current accumulated value (Rückkaufswert/Deckungskapital). FIGURES FROM A STATEMENT of ANY pension type (Renteninformation, bAV/VBL/Riester/Ruerup Standmitteilung or Versorgungskonto, also pasted as text: a claim earned so far as of a reference date = Anwartschaft/erreichter Anspruch, Hochrechnung, Erwerbsminderungsrente) are a DATED pension statement, never fields of this tool: PDF/photo -> tool_extract_finance_document; pasted text -> tool_import_stage_rows with a pension row (only if the provision does not exist yet) plus a pension_statement row (pension = its name, statement_date = the printed reference date, reached_claim/projection/em_monthly as printed, other printed details such as Versorgungspunkte in notes). guaranteed_monthly_pension is ONLY a payout the contract guarantees at retirement (e.g. the garantierte Rente of a private Rentenversicherung), never an Anwartschaft earned so far. STATUTORY (gesetzliche Rente): leave current_value and guaranteed_monthly_pension empty, and a person has at most one active statutory pension (a second one -> ok:false naming the existing one). Optionally record a contribution (Beitrag) as the user states it: the amount per debit (contribution_amount, positive), how often it is debited (schedule_unit/schedule_interval, default monthly - never convert it to a monthly value) AND debit_account_name (the cash account it is paid from) - it is booked as a recurring expense in the cashflow. If contribution_amount is given without a debit account the tool returns ok:false and asks for the account - relay that and ask. OWNER: optionally assign the single household member this provision belongs to (owner_person) as the user names them (a first name is enough); leave empty for joint/household. Required: name, pension_type. Optional: provider, contract_number, owner_person, current_value, value_updated_at, guaranteed_monthly_pension, retirement_start_date, contribution_amount, schedule_unit, schedule_interval, debit_account_name, schedule_day_of_month, first_payment_date, notes.' `
    @(
        ,@('name', 'Display name (e.g. Allianz Ruerup, DRV gesetzlich)', 'string')
        ,@('pension_type', 'One of: statutory, occupational, riester, ruerup, private', 'string')
        ,@('provider', 'Provider/insurer (Anbieter/Versorgungsträger)', 'string', '')
        ,@('contract_number', 'Contract or policy number', 'string', '')
        ,@('owner_person', 'OPTIONAL: the single household member this provision belongs to (as the user names them - a first name is enough; never ask for a surname). Leave EMPTY for a joint/household provision.', 'string', '')
        ,@('current_value', 'Current accumulated value in EUR (Rückkaufswert/Deckungskapital). Empty if unknown.', 'string', '')
        ,@('value_updated_at', ('Date the value is as of, (' + (Get-DateParamHint) + ')'), 'string', '')
        ,@('guaranteed_monthly_pension', 'Monthly payout in EUR the contract GUARANTEES at retirement (optional). Never an Anwartschaft or claim earned so far - that is a pension_statement via the import', 'string', '')
        ,@('retirement_start_date', ('Expected start of payout (' + (Get-DateParamHint) + ') (optional)'), 'string', '')
        ,@('contribution_amount', 'Contribution PER DEBIT in EUR as the user states it, positive. If set, debit_account_name is required.', 'string', '')
        ,@('schedule_unit', 'How often the contribution is debited: month (default), or year; quarterly = month with schedule_interval 3', 'string', '')
        ,@('schedule_interval', 'Every N units (optional, default 1)', 'string', '')
        ,@('debit_account_name', 'Cash account the contribution is paid from (required if contribution_amount set)', 'string', '')
        ,@('schedule_day_of_month', 'Contribution debit day 1-28, -1 for last day or -2 for second-to-last day (optional)', 'string', '')
        ,@('first_payment_date', ('First contribution debit date (' + (Get-DateParamHint) + ') (optional)'), 'string', '')
        ,@('notes', 'Free-text notes (optional)', 'string', '')
    ) @(2400, 208)

# --- set_* tools (update existing entities; verb class set_*) ---

$nToolSetAccount = New-ToolWorkflowNode 'tool_set_account' `
    'Update the master data (Stammdaten) of an EXISTING account: rename, bank, account number/IBAN, owner person, notes, and fixed-deposit fields (maturity date, auto-renew). Use this to assign/retag the owning household member of an existing account (owner_person). Does NOT change account_type or currency (not editable - they would corrupt history), does NOT change status (use tool_close_account to close), and never touches the balance. Only the fields you pass are changed; omit a field to leave it unchanged (you cannot clear the owner back to household here). Resolve the account by exact name; if ambiguous the tool returns candidates - ask the user which one. Required: account_name. Optional: new_name, bank, account_number, owner_person, notes, fixed_deposit_maturity_date, fixed_deposit_auto_renew. OPTIONAL estate/emergency-register fields, capture ONLY if the user states them: ownership (legal account ownership), has_transmortal_poa (whether a transmortal bank power of attorney exists).' `
    @(
        ,@('account_name', 'Exact name of the account to change', 'string')
        ,@('new_name', 'New display name (only if renaming)', 'string', '')
        ,@('bank', 'New bank/broker name', 'string', '')
        ,@('account_number', 'New IBAN / depot number / P2P id', 'string', '')
        ,@('owner_person', 'Assign the single household member who owns this account (as the user names them - a first name is enough; never ask for a surname). Omit to leave unchanged.', 'string', '')
        ,@('notes', 'New free-text notes', 'string', '')
        ,@('fixed_deposit_maturity_date', ('New maturity date (' + (Get-DateParamHint) + ') (fixed_deposit only)'), 'string', '')
        ,@('fixed_deposit_auto_renew', 'Whether the fixed deposit auto-renews (true/false, fixed_deposit only)', 'string', '')
        ,@('ownership', 'OPTIONAL legal account ownership, exactly one of: single (Einzelkonto), joint_or (Oder-Konto - survivor keeps full access), joint_and (Und-Konto - restricted after death). Leave empty if not stated.', 'string', '')
        ,@('has_transmortal_poa', 'OPTIONAL whether a transmortal bank power of attorney (transmortale Bankvollmacht, valid beyond death) exists (true/false).', 'string', '')
    ) @(2560, 208)

$nToolSetAccountInterest = New-ToolWorkflowNode 'tool_set_account_interest' `
    'Set or change the interest rate of an EXISTING account. The create flow only captures the FIRST rate; use this to add a rate later or change it. It inserts a new validity row and automatically ENDS the currently open rate at the new valid_from (no overlap). Use for savings/cash/fixed-deposit accounts whose rate changes. Resolve the account by exact name (ambiguity -> candidates). Required: account_name, annual_rate (percent per year, e.g. 2.0). Optional: schedule_interval, schedule_unit (day/week/month/year), schedule_day_of_month (1-28 or -1 for last day), posting_day_of_month (arrears - credited in the following month), day_count_convention and auto_post - leave ALL of these EMPTY for a plain rate change (the current crediting schedule is kept); fill them only if the user changes how often or when interest is credited. A FIRST rate (no rate yet) or a changed schedule needs the crediting rhythm (schedule_unit; for monthly also schedule_day_of_month) - never assume it: if the user did not state it, look the conditions up with web_search first. valid_from defaults to today. Returns ok:false if the rate is negative, the rhythm or day is missing (code=missing_required), valid_from is not after the current rate start date or lies before interest already credited - relay and ask the user.' `
    @(
        ,@('account_name', 'Exact name of the account', 'string')
        ,@('annual_rate', 'Annual interest rate in percent (e.g. 2.0)', 'string')
        ,@('schedule_interval', 'Every N units, ONLY if the user changes the crediting schedule (leave empty to keep the current one)', 'string', '')
        ,@('schedule_unit', 'How often interest is credited: day/week/month/year. REQUIRED for a first rate (from the user or the published conditions via web_search, never guessed); for a later change ONLY if the user changes it (leave empty to keep the current schedule)', 'string', '')
        ,@('schedule_day_of_month', 'Crediting day. month: -1 = at the end of the month or quarter or half-year (calendar), or a fixed day 1-28. year: -1 = on 31 December, empty = on the anniversary. day/week: empty. Leave empty to keep the current day', 'string', '')
        ,@('posting_day_of_month', 'Arrears: if interest is credited in the month AFTER the period ends, the day of that following month (1-28). Leave empty = credited at period end (optional)', 'string', '')
        ,@('day_count_convention', 'Day-count method, ONLY if the user explicitly overrides: 30E/360, ACT/365 or ACT/360. Leave EMPTY normally - it carries the previous rate method, else is proposed from the account type, and is shown in the confirmation.', 'string', '')
        ,@('auto_post', 'Whether the scheduler books interest automatically without confirmation (true/false). Leave EMPTY normally - proposed from cadence and shown in the confirmation.', 'string', '')
        ,@('valid_from', ('Date the new rate is valid from (' + (Get-DateParamHint) + ') (optional, default today). Must be after the current rate start.'), 'string', '')
    ) @(2720, 208)

$nToolSetRealEstate = New-ToolWorkflowNode 'tool_set_real_estate' `
    'Update an EXISTING real-estate asset: revalue it (current_value; if you change the value without a date the tool stamps today as value_updated_at), assign/retag the owner (owner_person), rename, set status to sold, or edit notes. Only the fields you pass change (you cannot clear the owner back to household here). Resolve by exact name (ambiguity -> candidates). NOTE: marking it sold does NOT settle any linked mortgage - handle the loan separately. Also records living_area_m2 / year_built (the card then shows the recommended monthly maintenance reserve per II. BV - never calculate it yourself). Required: real_estate_name. Optional: new_name, current_value, value_updated_at, owner_person, status (active/sold), notes, living_area_m2, year_built. Returns ok:false if current_value is negative or the area/year is invalid.' `
    @(
        ,@('real_estate_name', 'Exact name of the property to update', 'string')
        ,@('new_name', 'New display name (only if renaming)', 'string', '')
        ,@('current_value', 'New estimated market value in EUR', 'string', '')
        ,@('value_updated_at', ('Valuation date (' + (Get-DateParamHint) + ') (optional; defaults to today when current_value changes)'), 'string', '')
        ,@('owner_person', 'Assign the single household member who owns this property (as the user names them - a first name is enough; never ask for a surname). Omit to leave unchanged.', 'string', '')
        ,@('status', 'active or sold', 'string', '')
        ,@('notes', 'New free-text notes', 'string', '')
        ,@('living_area_m2', 'Living area in square metres as the user states it (e.g. 105). Omit to leave unchanged.', 'string', '')
        ,@('year_built', 'Year the building was completed / ready for occupancy (Baujahr, four digits). Omit to leave unchanged.', 'string', '')
    ) @(2880, 208)

$nToolSetPension = New-ToolWorkflowNode 'tool_set_pension' `
    'Update an EXISTING retirement provision (Altersvorsorge): update its accumulated value (current_value = Rückkaufswert/Deckungskapital; date auto-stamped today if omitted), guaranteed monthly pension, retirement start date, provider/contract, assign/retag the owner (owner_person), rename, set status (active/paused/paid_out), or notes. Setting status to paused or paid_out also pauses the linked monthly contribution so it leaves the cashflow; active re-activates it. This tool does NOT change the contribution AMOUNT. A NEW STATEMENT of ANY pension type (Renteninformation, bAV/VBL Standmitteilung, also pasted as text: Anwartschaft/erreichter Anspruch as of a reference date, Hochrechnung, Erwerbsminderungsrente) is never an update here - it is kept with its date: PDF/photo -> tool_extract_finance_document; pasted text -> tool_import_stage_rows with one pension_statement row (pension = the existing name, statement_date = the printed reference date). guaranteed_monthly_pension is ONLY a payout the contract guarantees at retirement, never an Anwartschaft earned so far. STATUTORY pension: no current_value and no guaranteed_monthly_pension (ok:false). Only passed fields change (you cannot clear the owner back to household here). Resolve by exact name (ambiguity -> candidates). Required: pension_name. Optional: new_name, current_value, value_updated_at, guaranteed_monthly_pension, retirement_start_date, provider, contract_number, owner_person, status, notes. Returns ok:false if current_value is negative.' `
    @(
        ,@('pension_name', 'Exact name of the provision to update', 'string')
        ,@('new_name', 'New display name (only if renaming)', 'string', '')
        ,@('current_value', 'New accumulated value in EUR (Rückkaufswert/Deckungskapital)', 'string', '')
        ,@('value_updated_at', ('Valuation date (' + (Get-DateParamHint) + ') (optional; defaults to today when current_value changes)'), 'string', '')
        ,@('guaranteed_monthly_pension', 'Monthly payout in EUR the contract GUARANTEES at retirement. Never an Anwartschaft or claim earned so far - that is a pension_statement via the import', 'string', '')
        ,@('retirement_start_date', ('Expected start of payout (' + (Get-DateParamHint) + ')'), 'string', '')
        ,@('provider', 'Provider/insurer (Anbieter/Versorgungsträger)', 'string', '')
        ,@('contract_number', 'Contract or policy number', 'string', '')
        ,@('owner_person', 'Assign the single household member this provision belongs to (as the user names them - a first name is enough; never ask for a surname). Omit to leave unchanged.', 'string', '')
        ,@('status', 'active, paused or paid_out', 'string', '')
        ,@('notes', 'New free-text notes', 'string', '')
    ) @(3040, 208)

$nToolSetInsurance = New-ToolWorkflowNode 'tool_set_insurance' `
    'Update an EXISTING insurance: change the premium AS THE USER STATES IT - premium_amount (per debit) or annual_premium (if they name the yearly amount), never convert it; the new premium takes effect from effective_from (if the user names a date) or else from the next due debit, and the old premium stays in the history. Change the payment rhythm (schedule_unit/schedule_interval) only together with the new amount per debit (insurers charge installment surcharges) - ask for it if missing. Cancel it (status=cancelled or expired plus valid_to as the last contract day -> the premium leaves the cashflow from that day), edit policy details, assign/retag the policyholder (policyholder_person), or rename (the premium debit is renamed too). Only passed fields change; a field cannot be cleared here. Resolve by exact name (ambiguity -> candidates). Required: insurance_name. Optional: new_name, premium_amount, annual_premium, schedule_interval, schedule_unit (day/week/month/year), schedule_day_of_month, effective_from, valid_to, status (active/cancelled/expired), insurance_company, policy_number, policyholder_person, notes. OPTIONAL estate/emergency-register fields, set ONLY if the user states them: insurance_type (see enum), beneficiary, coverage_amount (EUR), claim_deadline_hours (AVB claim-notification deadline in hours). Returns ok:false if the premium is non-positive or inconsistent, or a new rhythm comes without an amount.' `
    @(
        ,@('insurance_name', 'Exact name of the insurance to update', 'string')
        ,@('new_name', 'New display name (only if renaming)', 'string', '')
        ,@('premium_amount', 'New premium PER DEBIT in EUR exactly as the user states it (positive)', 'string', '')
        ,@('annual_premium', 'New annual premium in EUR - only if the user names a yearly amount', 'string', '')
        ,@('schedule_interval', 'Every N units (optional)', 'string', '')
        ,@('schedule_unit', 'day, week, month or year (only together with the new amount per debit)', 'string', '')
        ,@('schedule_day_of_month', 'Debit day 1-28, -1 for last day or -2 for second-to-last day', 'string', '')
        ,@('effective_from', ('First debit with the new premium (' + (Get-DateParamHint) + ') - only if the user names it (empty = next due debit)'), 'string', '')
        ,@('valid_to', ('Last day the contract is still valid (inclusive), (' + (Get-DateParamHint) + ') (set when cancelling)'), 'string', '')
        ,@('status', 'active, cancelled or expired', 'string', '')
        ,@('insurance_company', 'New insurance company', 'string', '')
        ,@('policy_number', 'New policy number', 'string', '')
        ,@('policyholder_person', 'Assign the single household member the policy belongs to - the policyholder or the insured member (as the user names them - a first name is enough; never ask for a surname). Omit to leave unchanged.', 'string', '')
        ,@('notes', 'New free-text notes', 'string', '')
        ,@('insurance_type', 'OPTIONAL insurance class, exactly one of: life, accident, disability, health, care, liability, household, residential_building, legal, vehicle, other. Leave empty to leave unchanged.', 'string', '')
        ,@('beneficiary', 'OPTIONAL named beneficiary (Bezugsberechtigter) entitled to the payout - a named beneficiary overrides the will.', 'string', '')
        ,@('coverage_amount', 'OPTIONAL coverage sum (Versicherungssumme) in EUR.', 'string', '')
        ,@('claim_deadline_hours', 'OPTIONAL claim-notification deadline in HOURS per the policy terms (AVB), e.g. 48 for accidental death.', 'string', '')
    ) @(3200, 208)

$nToolSetLoan = New-ToolWorkflowNode 'tool_set_loan' `
    'Update the terms or status of an EXISTING loan, e.g. when the fixed-interest period Zinsbindung ends (new interest_rate / monthly_annuity), or to add the original loan amount / payout date of a loan that was recorded with its remaining debt. A new monthly_annuity or debit day takes effect from effective_from (the first debit with the new rate, if the user names it) or else from the next due rate - the old rate stays in the history. For a loan without a rate (family loan), monthly_annuity needs effective_from (its first debit). original_amount and disbursement_date can only be added to a loan that was recorded with its remaining debt (otherwise ok:false - relay the reason). term_end_date = Laufzeitende (date of the last rate; for a balloon the date of the final payment). Interest, principal and the projected remaining debt are derived by the database. Renaming also renames the rate and the loan account. Setting status to paused/paid_off/refinanced pauses the rate. Only passed fields change; a field cannot be cleared here (also not the borrower back to household). Resolve by exact name across ALL statuses (ambiguity -> candidates). Does NOT perform the multi-step refinancing flow (new account + settlement booking + new loan). Required: loan_name. Optional: new_name, lender, borrower_person, interest_rate, interest_rate_fixed_until, term_end_date, monthly_annuity, schedule_day_of_month, effective_from, original_amount, disbursement_date, status (active/paused/paid_off/refinanced), notes. Returns ok:false if a rate is negative, the annuity is non-positive or does not cover the monthly interest, a loan would be active without a rate, the term ends before the fixed-interest period, or original values cannot be changed; ok:false with no_change = the loan already has exactly these values (the earlier change is saved) - tell the user so, never call again.' `
    @(
        ,@('loan_name', 'Exact name of the loan to update', 'string')
        ,@('new_name', 'New display name (only if renaming)', 'string', '')
        ,@('lender', 'New lender', 'string', '')
        ,@('borrower_person', 'Assign the single household member who is the borrower (as the user names them - a first name is enough; never ask for a surname). Omit to leave unchanged.', 'string', '')
        ,@('interest_rate', 'New annual interest rate in percent (e.g. 3.5)', 'string', '')
        ,@('interest_rate_fixed_until', ('New Zinsbindungsende (' + (Get-DateParamHint) + ')'), 'string', '')
        ,@('term_end_date', ('Laufzeitende (' + (Get-DateParamHint) + ') = date of the last rate'), 'string', '')
        ,@('monthly_annuity', 'New monthly rate in EUR (Zins + Tilgung) as the user states it', 'string', '')
        ,@('schedule_day_of_month', 'New debit day 1-28, -1 for last day or -2 for second-to-last day', 'string', '')
        ,@('effective_from', ('First debit with the new rate/day (' + (Get-DateParamHint) + ') - only if the user names it (empty = next due rate); required when the loan has no rate yet'), 'string', '')
        ,@('original_amount', 'Original loan sum in EUR - only to add it to a loan recorded with its remaining debt', 'string', '')
        ,@('disbursement_date', ('Payout date (' + (Get-DateParamHint) + ') - only to add it to a loan recorded with its remaining debt'), 'string', '')
        ,@('status', 'active, paused, paid_off or refinanced', 'string', '')
        ,@('notes', 'New free-text notes', 'string', '')
    ) @(3360, 208)

$nToolSetRecurringPayment = New-ToolWorkflowNode 'tool_set_recurring_payment' `
    'Update a STANDALONE recurring income or expense (salary, rent, subscription, pension payout) - NOT one owned by an insurance/loan/savings goal/pension (those have their own set tools; this returns ok:false for them). Changing the amount performs a history-preserving split: the current entry ends at the effective date and a NEW entry starts from it (sign preserved) - use this for a salary raise or an Elterngeld switch. Without an amount it edits in place: pause/resume (status), end it (valid_to), rename, change the debit day, or notes. Resolve by exact name across all statuses (ambiguity -> candidates incl. valid_from/status so the user can pick the current one). Required: payment_name. Optional: amount (positive magnitude -> triggers the split; the sign comes from the existing entry), valid_from (effective date of the split, default today), status (active/paused), valid_to, schedule_day_of_month, new_name, notes. Returns ok:false if it belongs to an entity, the amount is non-positive, the effective date is not after the current entry start or not after the last booked/skipped payment (last_booked), the entry already ended, or the end date lies before the effective date. A split keeps the debit/target account, status, end date and payment rhythm of the old entry. When you tell the user an end date read from the database, use last_valid_day (valid_to is stored as the first day no longer valid).' `
    @(
        ,@('payment_name', 'Exact name of the recurring payment to update', 'string')
        ,@('amount', 'New amount per occurrence in the account currency (positive magnitude); applies from valid_from on. Leave empty for pause/resume/end/rename.', 'string', '')
        ,@('valid_from', ('Effective date of the amount change (' + (Get-DateParamHint) + ') (default today). Must be after the current entry start.'), 'string', '')
        ,@('status', 'active or paused (pause/resume)', 'string', '')
        ,@('valid_to', ('Last day the payment is still valid (inclusive), (' + (Get-DateParamHint) + ') - pass the date the user names, e.g. runs until 2026-12-31 -> 2026-12-31'), 'string', '')
        ,@('schedule_day_of_month', 'New debit day 1-28, -1 for last day or -2 for second-to-last day', 'string', '')
        ,@('new_name', 'New display name (only if renaming)', 'string', '')
        ,@('notes', 'New free-text notes', 'string', '')
    ) @(3520, 208)

$nToolSetSavingsGoal = New-ToolWorkflowNode 'tool_set_savings_goal' `
    'Update an EXISTING savings goal: change the target amount, target date, rename, or notes. To CLOSE a goal - mark it completed (the reserve was spent) or cancelled (abandoned) - use tool_close_savings_goal instead (it enforces the reserve check and frees the allocations); only use status=active here to RE-OPEN a previously closed goal. When you change the target amount or date, the monthly savings rate is recomputed over the REMAINING amount and REMAINING time (not total/total) and the linked recurring savings rate is updated; a goal that is already covered can still change its date or amount (covered=true, no rate change). If the goal has NO running rate and money is still missing, the result says code no_rate_running with required_monthly_rate - tell the user and, if they want a rate, call again with account_name (the debit account; the rate goes into the reserve account); if a standing transfer from that account already pays into the reserve account the result is existing_transfer - do NOT delete it, ask whether it IS the goal rate and call again with replace_transfer=true (the goal continues it) or false (additional rate). Only passed fields change. You can also assign/retag the beneficiary (beneficiary_person, e.g. a child) as the user names them (a first name is enough); omit to leave unchanged. You can also set/change the reserve account (reserve_account_name): the monthly rate then becomes a transfer into that Topf and future rates land there - already tagged bookings stay assigned to the goal and keep counting (nothing is reset). You can also LINK or UNLINK a savings plan as a funding source of this goal (link_savings_plan_name / unlink_savings_plan_name): once a savings plan is linked, each of its automated stock/ETF/crypto buys feeds the depot share of this goal reserve (recorded in the goal reserve journal; money that already belonged to the goal on the settlement account is moved, new money counts as saved). A goal can have several linked savings plans. Use this when the user says e.g. "fund my Auto goal with my MSCI-World savings plan". Resolve by exact name (ambiguity -> candidates). You can also set the priority (a small integer, lower = more important) used to order goals when funds are tight. You can also STOP all contributions to this goal (stop_funders=true) when the goal is reached but NOT yet spent: this pauses the cash savings rate AND every linked savings plan, while the goal and its reserve stay untouched (reached is not spent). Required: goal_name. Optional: new_name, target_amount, target_date, status, notes, beneficiary_person, reserve_account_name, priority, link_savings_plan_name, unlink_savings_plan_name, stop_funders, account_name. Returns ok:false if the target is non-positive, the target date is not in the future, the reserve account equals the funding account, a new rate has no reserve account, or a savings plan to link/unlink is not found / not linked to this goal. Money that already lies on an account for the goal is earmarked with tool_book_savings_reservation, not here. MAINTENANCE RESERVE (a goal linked to a property, no target amount or date): target_amount, target_date and link_savings_plan_name are rejected; change its rate with monthly_savings_rate (with no rate running, pass account_name to start one - empty monthly_savings_rate = the II. BV recommendation computed by the tool).' `
    @(
        ,@('goal_name', 'Exact name of the savings goal to update', 'string')
        ,@('new_name', 'New display name (only if renaming)', 'string', '')
        ,@('target_amount', 'New target amount in EUR', 'string', '')
        ,@('target_date', ('New target date (' + (Get-DateParamHint) + ')'), 'string', '')
        ,@('status', 'Set to active to RE-OPEN a previously closed goal. To complete (reserve spent) or cancel a goal, use tool_close_savings_goal instead - do not set those here.', 'string', '')
        ,@('notes', 'New free-text notes', 'string', '')
        ,@('beneficiary_person', 'Assign the household member this goal is FOR (the beneficiary, named as the user says it (a first name is enough)). Omit to leave unchanged.', 'string', '')
        ,@('reserve_account_name', 'OPTIONAL: name of the reserve account (Topf: a cash/Tagesgeld, fixed-deposit or P2P account) the monthly rate should transfer into. Must differ from the funding account. Omit to leave unchanged.', 'string', '')
        ,@('priority', 'OPTIONAL: rank for ordering goals when funds are tight - a small integer where LOWER = more important (1 = top priority). Omit to leave unchanged.', 'string', '')
        ,@('link_savings_plan_name', 'OPTIONAL: exact name of a savings plan to LINK as a funding source of this goal (its automated buys then feed the goal depot reserve). Omit if not linking.', 'string', '')
        ,@('unlink_savings_plan_name', 'OPTIONAL: exact name of a savings plan to UNLINK from this goal (it stops feeding the reserve; existing journal entries stay). Omit if not unlinking.', 'string', '')
        ,@('stop_funders', 'OPTIONAL: set to true to STOP all contributions to this goal (pauses the cash savings rate AND every linked savings plan; the goal and its reserve stay untouched). Use when the goal is reached but not yet spent. Omit to leave funding running.', 'string', '')
        ,@('replace_transfer', 'ONLY after the rejection existing_transfer, with the answer of the user: true = the existing standing transfer IS the savings rate of this goal (the goal continues it), false = an additional rate. Leave EMPTY otherwise.', 'string', '')
        ,@('account_name', 'OPTIONAL: debit account to START a monthly rate for a goal that has none (only after the user agreed to a rate). Omit otherwise.', 'string', '')
        ,@('monthly_savings_rate', 'ONLY for a maintenance reserve (a goal linked to a property): the new monthly amount exactly as the user states it. Omit for other goals (their rate follows from amount and date).', 'string', '')
    ) @(3680, 208)

$nToolSetHolding = New-ToolWorkflowNode 'tool_set_holding' `
    'Edit the METADATA of an existing depot position (display name, ticker symbol, ISIN, currency, asset_class, provider_symbol, quote_currency) - e.g. after a ticker change from a corporate action, or to fix a position whose price is not being fetched. It does NOT change shares or average purchase price (those are derived from the transactions; to fix those, correct the underlying transactions, not here). Identify the position by depot_name + position (its CURRENT symbol or ISIN as the user names it) - the tool finds it itself (no own lookup); unknown/ambiguous -> ok:false with candidates, ask the user which one. Only passed fields change. Required: depot_name, position. Optional (the NEW values): new_name, symbol, isin, currency, asset_class, provider_symbol, quote_currency. asset_class is the allocation block key for rebalancing (lowercase letters/digits/underscore, e.g. sp500); to tag positions to the plan (one or several) use tool_set_asset_classes instead. provider_symbol/quote_currency fix the live price feed when a position shows no current price. Returns ok:false if the change would duplicate another holding identity (ISIN/symbol) in the same depot, or if asset_class/quote_currency has an invalid format. On success price_status {status ok|stale|missing, price, price_currency, price_as_of, feed_symbol} tells whether the position now has a current price - say so in one short line (price and date, or that it is still missing).' `
    @(
        ,@('depot_name', 'Name of the depot holding the position (e.g. "Trade Republic Depot")', 'string')
        ,@('position', 'The position as it is CURRENTLY stored: its symbol or ISIN as the user names it (e.g. VWCE or IE00BK5BQT80)', 'string')
        ,@('new_name', 'New display name', 'string', '')
        ,@('symbol', 'New ticker or crypto symbol', 'string', '')
        ,@('isin', 'New ISIN', 'string', '')
        ,@('currency', 'New ISO 4217 currency code', 'string', '')
        ,@('asset_class', 'Allocation block key for rebalancing (lowercase letters/digits/underscore, e.g. sp500). Match a target_allocation block key from the financial plan.', 'string', '')
        ,@('provider_symbol', 'Yahoo Finance feed symbol override. Stocks/ETFs: ticker with exchange suffix (VWCE.DE for Xetra, AAPL for US (no suffix), VWRL.L for London). Crypto: Yahoo TICKER-FIAT (e.g. BTC-EUR; for an ambiguous ticker give the exact one, e.g. UNI7083-USD for Uniswap). Set this ONLY when a position shows no current price (the raw ticker is not found by the feed). Leave empty otherwise.', 'string', '')
        ,@('quote_currency', 'Currency the live price is quoted in (ISO 4217, uppercase, e.g. EUR or USD). Set it to fix which Yahoo listing/currency the position uses for live prices.', 'string', '')
    ) @(3840, 208)

$nToolSetAssetClasses = New-ToolWorkflowNode 'tool_set_asset_classes' `
    'Assign the ASSET CLASS (allocation block key) of one or SEVERAL depot positions with ONE approval card - the way to tag positions for the target allocation. Changes nothing else (no shares, price or bookings). Use it when positions have no asset class (positions_without_asset_class from an import, a data-quality hint) AND a financial plan with a target allocation exists: propose the matching block key per position from the plan facts (each block shows its key in brackets, e.g. [sp500]) and send ALL open positions in ONE call. Reserved key outside_plan = deliberately outside the household plan (e.g. a child depot): such positions stay visible in net worth but are never reported as unmapped - propose it for positions in a depot whose other positions already carry outside_plan, otherwise ask. Without a published plan do not tag. Identify each position by depot_name + position (its symbol or ISIN as stored). The tool checks every row before the card (unknown/ambiguous position, invalid key, duplicate) - one bad row -> ok:false with reason and candidates, NO card, nothing written; fix and call again. Pass assignments as a JSON array string, e.g. [{"depot_name":"Trade Republic Depot","position":"IE00B5BMR087","asset_class":"sp500"},{"depot_name":"Depot Lisa","position":"BTC","asset_class":"outside_plan"}].' `
    @(
        ,@('assignments', 'JSON array string, each {depot_name, position (symbol or ISIN as stored), asset_class (lowercase block key from the plan, or outside_plan)}', 'string')
    ) @(3840, 400)

$nToolVerifyPriceSymbol = New-ToolWorkflowNode 'tool_verify_price_symbol' `
    'READ-ONLY, no approval. Look up where a security is listed so its live price can be fetched: give the ISIN (returns up to 4 listings {symbol, exchange, currency, price}) or a feed symbol the user named (checks just that one). Use it whenever a depot position has no current price - e.g. the import or a buy reports positions_without_price, or the user asks why a position shows no value. Then let the user choose: name the candidates in plain words (exchange, currency, current price; prefer the depot currency), or - if there are none - ask for the ticker as shown on their broker or a Yahoo Finance / justETF link and check that symbol with this tool. Apply the chosen listing with tool_set_holding (provider_symbol = the candidate symbol, quote_currency = its currency). Never leave a position without a price silently: say so and offer this. verified means listed in the wanted currency AND its price fits the position (last price, else purchase price) - a listing whose price does not fit is never verified; name it only as a doubtful match. If there is no fitting candidate, look the ticker up with web_search (query: ISIN + security name + Yahoo Finance ticker with exchange suffix such as .DE) and check EVERY ticker found with this tool (provider_symbol = that ticker) before proposing it - never propose an unchecked ticker. Returns {verified, plausible, adoptable, provider_symbol (only when adoptable = safe to set as price source), candidates}.' `
    @(
        ,@('isin', 'ISIN of the security (12 characters), if known', 'string', '')
        ,@('provider_symbol', 'Feed symbol the user named, e.g. SXR8.DE or CSPX.L', 'string', '')
        ,@('price_currency', 'Wanted price currency (ISO 4217), normally the depot currency, e.g. EUR', 'string', '')
    ) @(4000, 208)

$nToolVoidTransaction = New-ToolWorkflowNode 'tool_void_transaction' `
    'Undo/void a wrongly booked transaction by HARD-DELETE (balances, holding shares/avg and the loan Restschuld recompute automatically from the remaining rows). Identify it by transaction_id: first postgres_select the relevant recent transactions (e.g. SELECT id, transaction_date, amount, category, description FROM finance.transactions WHERE account_id = ... ORDER BY transaction_date DESC, id DESC) and pick the exact id - NEVER guess by description (several can share a Verwendungszweck). For "undo what I just did", read the most recent transaction(s) and void them. MULTI-LEG events (a transfer = two legs, a loan disbursement/payment = pair, a position takeover = buy + counter-booking, an imported purchase history = all its dated purchases) are booked as a GROUP and share a group_id; voiding ANY one leg removes the whole group automatically - you do NOT need to void each leg yourself. Before voiding one purchase of an imported purchase history, tell the user that the whole takeover of that position is removed; to fix one purchase price or the unit count use tool_set_holding instead. The depot holding row (its ISIN) is NEVER deleted, only its shares go to 0, so later dividends still work. Returns ok:false if voiding would make a depot holding go negative (a later sell depends on this buy) - void the later sell first. RESULT: accounts[{account_id, name, balance, change}] (change = database delta of that account) and holdings[{holding_id, symbol, shares, avg_purchase_price}] - tell the user only these numbers and never infer a credit or debit yourself (voiding a position takeover removes the buy AND its position_takeover counter-booking, so the settlement account change is 0). Input: transaction_id (integer, taken from postgres_select).' `
    @(
        # 'string' statt 'number': vom LLM aufgeloeste Integer-IDs werden gelegentlich gequotet ("42"),
        # n8n rejected das bei type number strikt; das fn-SQL castet ohnehin (Gotcha "IDs als string").
        ,@('transaction_id', 'Integer id of the transaction to void (from postgres_select on finance.transactions). Multi-leg events (transfer/loan) are removed as a whole group automatically.', 'string')
    ) @(4000, 208)

$nToolCreateSavingsPlan = New-ToolWorkflowNode 'tool_create_savings_plan' `
    'Create a new savings plan (Sparplan): links a depot to a recurring cash debit on the depot settlement account. Each broker execution is later recorded via tool_book_savings_plan_execution. DEPOT TYPE: stocks_depot requires an isin; crypto_depot has no isin (leave empty and use symbol only). Capture first_payment_date = the date of the FIRST broker execution (see its parameter). RHYTHM: pass the rhythm exactly as the user names it - weekly = week/1, every two weeks or twice a month = week/2, monthly = month/1, quarterly = month/3 - and NEVER work out execution days yourself: the database knows the bank execution calendar of the depot (e.g. a bank that runs weekly plans on 4 fixed days of the month) and derives the stored schedule and the monthly amount; the approval card shows the result. Always create ONE plan and call this tool directly, also when the user describes the bank pattern (e.g. weekly on 4 fixed days a month): never split it into several plans per day and never ask beforehand whether every 7 days or fixed days are meant. If the tool answers needs_calendar, ask the user ONCE which next execution dates their bank app shows and call again with depot_execution_days (the days of the month, or "none" if the plan really runs every 7 days); it is remembered for the depot. If it rejects the first date and names the next possible date, ask the user. BENEFICIARY: leave EMPTY normally - the plan then belongs to the depot owner (household for a joint depot), shown on the card; only name a household member (beneficiary_person, a first name is enough) if the plan is FOR someone else, e.g. a child. Required: plan_name, depot_name, symbol, security_name, amount (per execution, positive), first_payment_date. Optional for stocks/ETFs: isin. Optional: schedule_interval (default 1), schedule_unit (default month), schedule_day_of_month (1-28, -1 for last day or -2 for second-to-last day), depot_execution_days, notes, beneficiary_person, asset_class (allocation block key; every execution tags the position with it).' `
    @(
        ,@('plan_name', 'Unique display name for the savings plan (e.g. "VWCE Monatsplan")', 'string')
        ,@('depot_name', 'Exact name of the depot account (stocks_depot or crypto_depot)', 'string')
        ,@('isin', 'ISIN of the security (required for stocks/ETFs; leave empty for crypto)', 'string', '')
        ,@('symbol', 'Ticker or crypto symbol (e.g. VWCE, BTC). Crypto: always provide. Stock/ETF: leave empty if no ticker is known (the ISIN identifies the position) - never guess one.', 'string', '')
        ,@('security_name', 'Display name of the security (e.g. "Vanguard FTSE All-World")', 'string')
        ,@('amount', 'Plan amount per execution in the settlement account currency (positive; debited from the depot settlement account)', 'number')
        ,@('schedule_interval', 'Every N units (optional, default 1)', 'string', '')
        ,@('schedule_unit', 'Recurrence unit: day/week/month/year (optional, default month)', 'string', '')
        ,@('schedule_day_of_month', 'Fixed debit day 1-28, -1 for last day or -2 for second-to-last day (optional; leave empty to anchor to first_payment_date)', 'string', '')
        ,@('first_payment_date', ('Date of the FIRST broker execution (' + (Get-DateParamHint) + ') - recurrence anchor'), 'string')
        ,@('depot_execution_days', 'ONLY after a needs_calendar answer: the raw answer of the user which days of the month the bank executes savings plans (e.g. "2,9,16,23"), or "none" if it runs every 7 days. Leave EMPTY otherwise.', 'string', '')
        ,@('notes', 'Free-text notes (optional)', 'string', '')
        ,@('beneficiary_person', 'OPTIONAL: only if the plan is FOR someone other than the depot owner (e.g. a child), named as the user says it (a first name is enough). Leave EMPTY - the plan then belongs to the depot owner.', 'string', '')
        ,@('asset_class', 'Optional allocation block key for rebalancing (lowercase letters/digits/underscore, e.g. sp500). Match a target_allocation block key from the financial plan; leave empty if unsure.', 'string', '')
    ) @(4160, 208)

$nToolBookSavingsPlanExecution = New-ToolWorkflowNode 'tool_book_savings_plan_execution' `
    'Record the broker execution of a savings plan for the current due period (Sparplan ausführen). The due date is detected automatically from the open occurrence - do NOT ask the user for a date. Presents a summary (plan amount vs. actual cost, variance warning if >5%) for confirmation; the user approves or declines via button. Returns ok:false if the plan is paused, already booked this period, or not yet due. shares and price_per_share must be positive. ORDER FEE: only if the user mentions one (empty = 0). Inputs: savings_plan_name, shares (fractional OK, e.g. 0.8234), price_per_share (EUR), order_fee (0 or more). The first execution often creates the position: price_status {status ok|stale|missing, price, price_currency, price_as_of, feed_symbol} tells whether its live price was found - say so in one short line; if missing, offer tool_verify_price_symbol.' `
    @(
        ,@('savings_plan_name', 'Exact name of the savings plan to execute', 'string')
        ,@('shares', 'Number of shares or units purchased (fractional OK, positive)', 'number')
        ,@('price_per_share', 'Execution price per share or unit in the depot currency', 'number')
        ,@('order_fee', 'Order fee in the same currency as price_per_share, only if the user mentions one (empty = 0; the card shows it)', 'string', '')
    ) @(4320, 208)

$nToolBookRecurringOccurrence = New-ToolWorkflowNode 'tool_book_recurring_occurrence' `
    'Book a due recurring payment occurrence (standing order, salary, insurance, loan rate) with an ADJUSTED amount for the current period. The due date is detected automatically from the open occurrence - do NOT ask for a date. Shows planned vs. actual amount (variance warning if >5%) for confirmation. Use this when the user states the real amount of a recurring item this period (e.g. the electricity standing order was 95 instead of 80). Returns ok:false if the payment is not found, has no open occurrence (already booked or not yet due), the amount is non-positive, or it is an internal transfer (those book the planned amount only). Inputs: recurring_payment_name, actual_amount (positive magnitude in EUR; the income/expense direction is kept from the plan).' `
    @(
        ,@('recurring_payment_name', 'Exact name of the recurring payment whose due occurrence to book', 'string')
        ,@('actual_amount', 'The actual amount for this period in the account currency (positive magnitude; direction kept from the plan)', 'number')
    ) @(4480, 360)

$nToolBookInterest = New-ToolWorkflowNode 'tool_book_interest' `
    'Book a due interest credit (Zinsgutschrift) on an interest-bearing cash or fixed-deposit account. The covered period and credit date are detected automatically from the open interest occurrence - do NOT ask for a date. The system proposes the DB-computed interest (balance x rate x day-count fraction of the period); the user may provide the actual credited amount to override it. Use when the user states an interest credit (e.g. I received 42 EUR interest on the Tagesgeld) or asks to book the due interest. Returns ok:false if the account is not found, has no open interest occurrence (already credited or not yet due), or the amount is non-positive. Inputs: account_name, actual_amount (OPTIONAL - leave empty to book the computed interest).' `
    @(
        ,@('account_name', 'Exact name of the interest-bearing account to credit', 'string')
        ,@('actual_amount', 'Actual interest amount in the account currency. OPTIONAL - leave empty to book the DB-computed interest.', 'string', '')
    ) @(4640, 360)

$nToolSetSavingsPlan = New-ToolWorkflowNode 'tool_set_savings_plan' `
    'Update an EXISTING savings plan: change the monthly amount and/or the cadence (schedule_unit/schedule_interval, e.g. switch a "50 EUR weekly" plan to monthly) — both trigger a validity-split on the linked recurring payment (old entry ends at valid_from, new one starts from it; fields you do not pass are carried over, so a pure cadence change keeps the amount), pause/resume execution, or update notes. Changing the amount or cadence requires valid_from (effective date; default today; must be after the current entry start). Before changing anything, read the plan in finance.savings_plan_overview: when the user only states how the plan already runs (e.g. "it is 50 per week" and rhythm already says weekly), there is nothing to change - just correct your understanding; the tool also rejects an unchanged rhythm/amount with code no_change (tell the user it already runs that way). RHYTHM: pass the new cadence exactly as the user names it (weekly = week/1, every two weeks or twice a month = week/2, monthly = month/1) and never work out execution days yourself - the database derives them from the depot bank calendar; for a bank with fixed execution days valid_from must be such a day (a rejection names the next possible date - ask the user). needs_calendar or a wrong bank calendar: pass depot_execution_days (the raw answer of the user, days of the month or "none") together with the cadence. Pausing stops the cash debit; resuming restarts it. You can also assign/retag the beneficiary (beneficiary_person, e.g. a child) as the user names them (a first name is enough); omit to leave unchanged. Resolve by exact name including paused plans (ambiguity -> candidates). Required: savings_plan_name. Optional: new_amount (positive; triggers split), schedule_unit (day/week/month/year), schedule_interval (positive integer), depot_execution_days, status (active/paused), valid_from, notes, beneficiary_person, asset_class (retag the allocation block key for future executions). Returns ok:false if new_amount is non-positive or valid_from is not after the current recurring entry start.' `
    @(
        ,@('savings_plan_name', 'Exact name of the savings plan to update', 'string')
        ,@('new_amount', 'New plan amount per interval in the settlement account currency (positive; applies from valid_from on). Leave empty for pause/resume/notes/cadence-only change.', 'string', '')
        ,@('schedule_unit', 'New cadence unit: day, week, month or year (triggers a validity-split; the amount is kept if you do not also pass new_amount). Leave empty to keep the cadence.', 'string', '')
        ,@('schedule_interval', 'New cadence interval, a positive integer (e.g. 2 with unit week = every two weeks). Leave empty to keep it.', 'string', '')
        ,@('depot_execution_days', 'ONLY after needs_calendar or when the user corrects the bank execution days: the raw answer of the user which days of the month the bank executes savings plans (e.g. "2,9,16,23"), or "none" if it runs every 7 days. Requires schedule_unit. Leave EMPTY otherwise.', 'string', '')
        ,@('status', 'active (resume) or paused (pause execution)', 'string', '')
        ,@('valid_from', ('Effective date of amount/cadence change (' + (Get-DateParamHint) + ') (default today). Must be after current entry start.'), 'string', '')
        ,@('notes', 'New free-text notes', 'string', '')
        ,@('beneficiary_person', 'Assign the household member this plan is FOR (the beneficiary, named as the user says it (a first name is enough)). Omit to leave unchanged.', 'string', '')
        ,@('asset_class', 'Allocation block key for rebalancing (lowercase letters/digits/underscore, e.g. sp500). Match a target_allocation block key from the financial plan. Omit to leave unchanged.', 'string', '')
    ) @(4480, 208)

$nToolCloseSavingsPlan = New-ToolWorkflowNode 'tool_close_savings_plan' `
    'Close a savings plan permanently. Smart-close guard based on execution history: no executions booked -> Hard-DELETE (plan + recurring payment removed completely, Karteileiche cleanup); executions exist -> Soft-Close (recurring payment ends today, plan status=paused, history preserved). Call this tool directly — the tool reads the execution count and shows the user a precise approval summary before acting. Input: savings_plan_name.' `
    @(
        ,@('savings_plan_name', 'Exact name of the savings plan to close', 'string')
    ) @(4640, 208)

# --- close_*/delete_* tools (end or remove an entity; verb class close_*/delete_*) ---

$nToolCloseInsurance = New-ToolWorkflowNode 'tool_close_insurance' `
    'Close/remove an insurance policy. Smart-close guard based on payment history: NO premium payments booked -> Hard-DELETE (policy + linked recurring premium removed completely, Karteileiche cleanup); payments exist -> Soft-Close (status=cancelled, valid_to=today, the linked recurring premium is ended, history preserved). Use this to remove a wrongly-created policy OR to cancel a real one - the tool decides automatically from the booking history. To only change attributes (premium, schedule, policyholder) WITHOUT ending it, use tool_set_insurance instead. Call this tool directly - it reads the payment count and shows a precise approve/decline summary first. Input: insurance_name.' `
    @(
        ,@('insurance_name', 'Exact name of the insurance to close/remove', 'string')
    ) @(4800, 208)

$nToolClosePension = New-ToolWorkflowNode 'tool_close_pension' `
    'Close/remove a retirement provision (Altersvorsorge). Smart-close guard: NO contributions booked -> Hard-DELETE (provision + any linked recurring contribution removed completely); contributions exist -> Soft-Close (status=paused, the linked monthly contribution ended, history preserved). Use to remove a wrongly-created provision OR wind down a real one. To only change its value/status/details WITHOUT removing it, use tool_set_pension. Call this tool directly - it shows an approve/decline summary first. Input: pension_name.' `
    @(
        ,@('pension_name', 'Exact name of the pension/provision to close/remove', 'string')
    ) @(4960, 208)

$nToolCloseSavingsGoal = New-ToolWorkflowNode 'tool_close_savings_goal' `
    'Close a savings goal with a clear OUTCOME (reached is not the same as spent). outcome="completed" = the reserve was SPENT (e.g. the car was bought) and the goal is fulfilled; this is only allowed when the reserve is ~0 (already withdrawn) - otherwise it returns ok:false asking you to withdraw/spend first (set force=true only if the user explicitly confirms closing despite a remaining balance). outcome="cancelled" (the default) = the goal is abandoned; its allocations are freed (the tagged bookings are untagged so the money becomes reassignable, the depot reserve is released, history is kept) - offer to reassign the freed amount to another goal. Smart-close: a goal with NO booked movements is Hard-DELETEd; movements exist -> Soft-Close. The holdings/shares ALWAYS stay (only the goal allocation is released). To only stop contributions while keeping a reached goal full, use tool_set_savings_goal with stop_funders. Call this tool directly - it shows an approve/decline summary first. Required: savings_goal_name. Optional: outcome, force.' `
    @(
        ,@('savings_goal_name', 'Exact name of the savings goal to close/remove', 'string')
        ,@('outcome', 'completed (the reserve was spent, goal fulfilled - only with reserve ~0) or cancelled (the goal is abandoned, allocations freed). Defaults to cancelled.', 'string', '')
        ,@('force', 'Set to true ONLY when the user explicitly confirms completing the goal despite a remaining unspent reserve. Omit otherwise.', 'string', '')
    ) @(5120, 208)

$nToolDeleteRealEstate = New-ToolWorkflowNode 'tool_delete_real_estate' `
    'Delete a real-estate asset that was created BY MISTAKE. Hard-DELETE only when it has NO linked loans; if a loan references the property the tool returns ok:false (pay off / unlink the loan first) - relay that to the user and do NOT retry. There is no soft-close here: to mark a property as actually SOLD use tool_set_real_estate (status=sold) instead. Call this tool directly - it shows an approve/decline summary (incl. the linked-loan count) first. Input: real_estate_name.' `
    @(
        ,@('real_estate_name', 'Exact name of the property to delete', 'string')
    ) @(5280, 208)

$nToolDeleteHolding = New-ToolWorkflowNode 'tool_delete_holding' `
    'Delete a depot position (holding) that was created BY MISTAKE or left empty (shares=0) after voiding all its trades. Hard-DELETE only when it has NO trade transactions; if trades reference it the tool returns ok:false (void the trades first via tool_void_transaction) - relay that and do NOT retry. Identify it by depot_name + position (its symbol or ISIN as the user names it) - the tool finds it itself; unknown/ambiguous -> ok:false with candidates. Call this tool directly - it shows an approve/decline summary first. Input: holding_id.' `
    @(
        ,@('depot_name', 'Name of the depot holding the position', 'string')
        ,@('position', 'Symbol or ISIN of the position as the user names it', 'string')
    ) @(5440, 208)

$nToolDeleteAccount = New-ToolWorkflowNode 'tool_delete_account' `
    'Delete an account that was created BY MISTAKE. Hard-DELETE only when it is completely unused; if ANY transaction, holding, recurring payment, insurance, savings-goal allocation, savings plan, loan or depot-settlement link references it the tool returns ok:false (relay that and do NOT retry). For a real account that simply should no longer be used, use tool_close_account instead (soft-close). Call this tool directly - it shows an approve/decline summary first. Input: account_name.' `
    @(
        ,@('account_name', 'Exact name of the account to delete', 'string')
    ) @(5600, 208)

$nToolDeleteRecurringPayment = New-ToolWorkflowNode 'tool_delete_recurring_payment' `
    'Delete a STANDALONE recurring payment (salary, rent, subscription, pension income) that was created BY MISTAKE. Hard-DELETE only when nothing references it; if it belongs to an entity (insurance/loan/pension/savings goal/savings plan) the tool returns ok:false - change or end it via that entity tool (set_/close_) instead. If it has booked occurrences the tool returns ok:false (void those first). A standing transfer that fills the settlement account of a savings plan or the account of a savings goal is NOT a duplicate of a goal rate - code feeds_savings: keep it; only if the user explicitly says the transfer itself no longer exists at the bank, call again with confirm_feeds_savings=true (to make it the rate of a goal, use tool_create_savings_goal / tool_set_savings_goal with replace_transfer instead). Otherwise relay an ok:false and do NOT retry. Call this tool directly - it shows an approve/decline summary first. Input: recurring_payment_name, confirm_feeds_savings.' `
    @(
        ,@('recurring_payment_name', 'Exact name of the standalone recurring payment to delete', 'string')
        ,@('confirm_feeds_savings', 'ONLY after the rejection feeds_savings and only if the user explicitly said the transfer no longer exists at the bank: true. Leave EMPTY otherwise.', 'string', '')
    ) @(5760, 208)

$nToolDeleteLoan = New-ToolWorkflowNode 'tool_delete_loan' `
    'Delete a loan that was created BY MISTAKE (the inverse of creating it: removes the loan, its loan account, the opening/disbursement bookings and the rate). Hard-DELETE only when NO repayments have been booked yet; if repayments exist the tool returns ok:false - to pay a real loan off use tool_settle_loan, to mark it refinanced use tool_set_loan. The debit/disbursement accounts are kept. Relay an ok:false and do NOT retry. Call this tool directly - it shows an approve/decline summary first. Input: loan_name.' `
    @(
        ,@('loan_name', 'Exact name of the loan to delete', 'string')
    ) @(5920, 208)

$nToolSettleLoan = New-ToolWorkflowNode 'tool_settle_loan' `
    'Pay off a loan early (full settlement). Books the payoff in one transaction (debit account out, remaining debt to zero), sets the loan to paid_off and ends the rate. Provide loan_name and debit_account_name (the cash account the money comes from). settlement_amount is optional - default is the exact remaining debt; pass a higher amount only if there is an early-repayment fee/interest (the difference is recorded as interest). For a normal monthly instalment use tool_book_loan_payment instead. The tool shows an approve/decline summary first.' `
    @(
        ,@('loan_name', 'Exact name of the loan to settle', 'string')
        ,@('debit_account_name', 'Exact name of the cash account the payoff is debited from', 'string')
        ,@('settlement_date', ('Settlement date (' + (Get-DateParamHint) + ') (default today)'), 'string', '')
        ,@('settlement_amount', 'Total amount paid (EUR). Omit to settle exactly the remaining debt; higher = includes early-repayment interest/fee.', 'string', '')
    ) @(6080, 208)

$nToolSellRealEstate = New-ToolWorkflowNode 'tool_sell_real_estate' `
    'Record the SALE of a property: credits the sale proceeds to a cash account and marks the property as sold. Provide real_estate_name, proceeds_account_name (where the money lands), sale_date and sale_price. Linked active loans are NOT paid off automatically - the tool returns them (name + remaining debt) so you can tell the user to settle them separately via tool_settle_loan. (To merely re-value a property without a sale use tool_set_real_estate.) The tool shows an approve/decline summary first.' `
    @(
        ,@('real_estate_name', 'Exact name of the property being sold', 'string')
        ,@('proceeds_account_name', 'Exact name of the cash account the sale proceeds are credited to', 'string')
        ,@('sale_date', ('Sale date (' + (Get-DateParamHint) + '), only if the user names one (empty = today)'), 'string', '')
        ,@('sale_price', 'Sale price in EUR (positive)', 'number')
    ) @(6240, 208)

# WS-B3: Finanz-Onboarding-Fortschritts-Marker (kein HITL; package=finance, finance_rw). Der Agent
# markiert hier eine der Finanz-Sektionen completed/skipped, sobald er sie erfasst hat (Self-Onboarding).
# Key-Liste aus onboarding/sections.json (Get-OnboardingSectionKeys), nie abgetippt.
$financeSectionKeys = (Get-OnboardingSectionKeys $RepoRoot 'finance') -join ', '
$nToolSetOnboarding = New-ToolWorkflowNode 'tool_set_onboarding_section' `
    "Mark a finance onboarding section as captured or deliberately skipped - a PROGRESS MARKER ONLY (no financial write, no confirmation). Call this only after the user confirmed nothing is missing in that area (completed), or when the user explicitly wants to leave it out (skipped). section_key is one of: $financeSectionKeys. status is ""completed"" or ""skipped""." `
    @(
        ,@('section_key', "One of: $financeSectionKeys", 'string')
        ,@('status', 'completed (area captured) or skipped (user deliberately omits it)', 'string')
    ) @(6400, 208)

# --- Doku-Stickies (Workflows sind die Doku, CLAUDE.md) ---
$stickyOverview = New-Sticky 'Doc: Überblick' @(-1640, -340) @"
## agent.finance — Finance-Agent (Sub-Workflow)
Eingang: task, chat_id, call_depth (vom Orchestrator als Tool aufgerufen).
Pipeline (y=0): **Depth gate** (Anti-Loop) -> **Package-Gate** (R4/WS-B8: nur wenn finance aktiv, sonst package_inactive) -> Config laden (core.sub_load_config) -> System-Prompt + Lazy-Manifest laden (agent.tool_load_context, static-concat global+finance) -> Agent-Input bauen -> **Finance Agent** (AI).
**CQRS:** Reads frei via postgres_select / load_context (+ web_search fuer oeffentliche Produkt-Konditionen); Writes NUR ueber die tool_*-Sub-Workflows (jeweils HITL-Gate + atomar via agent.fn_*). Antwort geht zurueck an den Orchestrator.
"@ 560 250

$stickyDepth = New-Sticky 'Doc: Anti-Loop' @(-1560, 120) @"
## Anti-Loop-Backstop (Depth gate)
call_depth >= 2 -> strukturierte Ablehnung ``{ok:false, error:'max_call_depth'}`` VOR jedem LLM-Call (kein Cost, kein Owner-Alert). call_depth = Tiefe dieses Workflows (Orchestrator=0, Finance=1). Einziger noetiger Gate-Punkt: Tools koennen keinen Agenten aufrufen (n8n Bound-Tool-Closure) -> Rekursion strukturell ausgeschlossen; der Gate ist Backstop fuer kuenftige Agent->Agent-Pfade. Details: Root-CLAUDE.md *Anti-Loop-Konvention*.
"@ 420 200

$stickyPkg = New-Sticky 'Doc: Package-Gate' @(-2000, 320) @"
## Routing-Status-Gate (WS-B8)
Bricht VOR dem LLM ab, wenn das finance-Paket nicht ``status='active'`` ist: **Package active read** liest ``core.fn_package_active('finance')`` unter **finance_ro** (publiziertes SECURITY-DEFINER-Read-Window, D10 — kein direktes SELECT auf core.package_registry). **Package active gate** (``active === false``) -> **Package inactive** ``{ok:false, error:'package_inactive'}`` (kein LLM-Cost), sonst weiter zu Load Config. Status kippt per CLI active<->inactive OHNE Redeploy -> Laufzeit-Gate kappt den deaktivierten Pfad **strukturell** (kein Prompt-Vertrauen). onError=continue + ``=== false`` => DB-Lesefehler faellt **fail-open** durch (Normalfall finance aktiv); nur expliziter Nicht-active-Status (installing/installed/inactive) sperrt. Per-Paket generisch (Paketname im SQL); Crons sind hier NICHT gegatet (Lifecycle Phase 4/5, BACKLOG).
"@ 660 340

$stickyCore = New-Sticky 'Doc: Core-first-Gate' @(-1120, 660) @"
## Core-first Hard-Gate (WS-3, immer-an Onboarding-Invariante)
**Core onboarding read** liest ``core.fn_onboarding_status('core')->>'complete'`` unter **finance_ro** (publiziertes SECURITY-DEFINER-Window; EXECUTE via fn_provision_package_roles). **Core onboarding gate** (``core_complete === false``) -> **Core onboarding required** ``{ok:false, output:'... /onboarding ...'}`` (relaybarer DE-Hinweis, KEIN LLM-Cost), sonst weiter zu Load Config. **Invariante:** kein Paket vor dem Core-Onboarding (Haushalt). Sitzt NACH dem Package-active-Gate, VOR Load Config. onError=continue + ``=== false`` => DB-Lesefehler faellt **fail-open** durch (null !== false). Abgrenzung: nur Core-Haushalt; der weiche Finance-Self-Onboard (Onboarding status read, weiter rechts) nudged die Finanz-Sektionen erst NACH diesem Gate -> mid-CORE blockt hart, mid-PAKET laeuft. Muster generisch (jeder Paket-Agent erbt es).
"@ 540 240

$stickyModel = New-Sticky 'Doc: Modellwahl' @(-900, 560) @"
## Modellwahl (Config-gesteuert)
Je Claude-Modell des Registers ein Modell-Node (Haiku/Sonnet/Opus, Name = model_key) + Model Selector — generiert vom gemeinsamen Builder New-ModelSelectorBundle (lib/build_helpers.ps1), UEBERALL identisch (finance/advisor/orchestrator). Der Selector liest **core.config** ueber `Load Config` (core.sub_load_config): `model.finance` = model_key; eine Regel je Modell (model_key -> selector_index) aus packages/core/seed/ai_models.json. Standard `claude-sonnet-latest` (zuverlaessiges Function-Calling, Denk-Tiefe medium). Adaptives Thinking an, KEINE Sampling-Parameter (5.5-Generation -> 400). Modell wechseln = model.*-Wert im .config-Block eines packages/*/manifest.json + re-seed (provision.sh / Substrat -Reset), kein Workflow-Edit.
"@ 480 200

$stickyMemory = New-Sticky 'Doc: Chat-Memory' @(-1380, 416) @"
## Chat-Memory
Eigene Tabelle agent.finance_chat_memory (sessionKey = chat_id, Fenster 15, zaehlt inkl. Tool-Nachrichten) fuer Multi-Turn-Dialoge. Getrennt von agent.orchestrator_chat_memory.
"@ 340 150

$stickyTools = New-Sticky 'Doc: Tools (CQRS)' @(150, 100) @"
## Write-Tools (CQRS) — je HITL-Gate + atomar
Booking: book_dividend/transfer/transaction/stock_buy/stock_sell/loan_payment
Create: create_account/insurance/loan/real_estate/savings_goal/recurring_payment/pension
Set (Update bestehender Entitaeten): set_account/set_account_interest/set_real_estate/set_pension/set_insurance/set_loan/set_recurring_payment/set_savings_goal/set_holding/set_asset_classes (Anlageklassen mehrerer Positionen, eine Karte; auch beim Berater gebunden)
Reconcile: reconcile_account (ein Konto) / reconcile_accounts_batch (mehrere Staende auf einmal -> Monats-Reminder, ein Sammel-Approval). Close: close_account
Void: void_transaction (Hard-DELETE einer Fehlbuchung; Kredit-Paar zusammen; Holding-Zeile bleibt)
Sparplan: create_savings_plan/book_savings_plan_execution/set_savings_plan/close_savings_plan (Depot + monatlicher Cash-Debit + Broker-Ausfuehrung; Cron fn_recurring_due_open erkennt Ausfuehrung via rp_id+due_date auf buy-Tx automatisch)
Datumsfelder: das Modell gibt relative Angaben roh weiter ("yesterday", "in 2 weeks"; Text = Get-DateParamHint), die Write-fn rechnet sie (core.fn_resolve_input_dates), unlesbar -> ok:false invalid_date, keine Karte. Die Karte zeigt das aufgeloeste Datum aus dem Probelauf (effective).
Write-Logik in agent.fn_*. transfer = nur zwischen EIGENEN Konten; book_transaction = externe Ausgabe/Einnahme (1 Bein). set_* aendert NUR Bestehendes (partielles UPDATE, Resolve per Name); set_insurance synct den verknuepften Beitrag, set_pension kaskadiert Status auf den Beitrag, set_account_interest schliesst die offene Zinszeile. Reads: postgres_select (Views bevorzugt) + load_context (lazy) + web_search (nur oeffentliche Produkt-Konditionen nachschlagen, z. B. Kontozins; eintragen erst nach Chat-Ja via set_account_interest).

postgres_select (geteilter Builder New-PostgresSelectToolNode): onError=continueRegularOutput -> fehlerhafte SELECT gibt DB-Fehler an Agent zurueck (selbst korrigieren); fehlt das query-Argument, liefert der Guard {ok:false, error} statt eines n8n-Absturzes. Views sind stabiles Schema-Interface.
"@ 760 230

# --- assemble ---
$allNodes = @(
    $nTrigger, $nDepthGate, $nDepthDeny, $nPkgRead, $nPkgGate, $nPkgDeny,
    $nCoreRead, $nCoreGate, $nCoreRedirect,
    $nLoadConfig, $nLoadCtx, $nOnboardRead, $nBuildInput, $nAgent,
    $nMemory,
    $nToolSelect, $nToolLoad, $nToolWebSearch,
    $nToolDividend, $nToolTransfer, $nToolStockBuy, $nToolBookTransaction,
    $nToolCreateAccount, $nToolCreateInsurance, $nToolCreateLoan, $nToolCreateRealEstate,
    $nToolBookStockSell, $nToolBookLoanPayment, $nToolCreateSavingsGoal, $nToolBookSavingsGoalTransfer,
    $nToolBookSavingsReservation,
    $nToolReconcileAccount, $nToolReconcileAccountsBatch, $nToolCloseAccount,
    $nToolCreateRecurringPayment, $nToolCreateRecurringTransfer, $nToolCreatePension,
    $nToolSetAccount, $nToolSetAccountInterest, $nToolSetRealEstate, $nToolSetPension, $nToolSetInsurance,
    $nToolSetLoan, $nToolSetRecurringPayment, $nToolSetSavingsGoal, $nToolSetHolding, $nToolSetAssetClasses, $nToolVerifyPriceSymbol, $nToolVoidTransaction,
    $nToolCreateSavingsPlan, $nToolBookSavingsPlanExecution, $nToolBookRecurringOccurrence, $nToolBookInterest,
    $nToolSetSavingsPlan, $nToolCloseSavingsPlan,
    $nToolCloseInsurance, $nToolClosePension, $nToolCloseSavingsGoal, $nToolDeleteRealEstate, $nToolDeleteHolding,
    $nToolDeleteAccount, $nToolDeleteRecurringPayment, $nToolDeleteLoan, $nToolSettleLoan, $nToolSellRealEstate,
    $nToolImportStageRows, $nToolUpdateStagingRow, $nToolCommitImport, $nToolExtractFinanceDocument,
    $nToolReconcileBankStatement, $nToolVoidBankStatement, $nToolImportBrokerCsv,
    $nToolSetOnboarding,
    $stickyOverview, $stickyDepth, $stickyPkg, $stickyCore, $stickyModel, $stickyMemory, $stickyTools
) + $mb.Nodes | Where-Object { $_ -ne $null }

# Paket-Werkzeuge aus consumes.services (paperless:* — Dokumente lesen) ueber den Core-Vermittler
# agent.sub_dispatch_tool; optional (ohne das Paket antworten sie {ok:false, package_unavailable}).
# DEFER-Trigger (Plan Phase 2): kippen Finance-Goldens, hier -Exclude 'ask_documents' setzen.
$svc = Add-ServiceTools -Package 'finance' -AgentNode 'Finance Agent' -StartNode 'Start agent.finance' `
    -Position @(-336, 1400) -ExistingNodes $allNodes
$allNodes = @($allNodes) + $svc.Nodes

# connections
function E([string]$node, [string]$type, [int]$index = 0) {
    return @{ node = $node; type = $type; index = $index }
}

$connections = [ordered]@{
    'Start agent.finance'               = @{ main = @(,@( E 'Depth gate'            'main' 0 )) }
    'Depth gate'                        = @{ main = @(
        @( E 'Max call depth'      'main' 0 ),   # true: call_depth >= 2 -> structured decline
        @( E 'Package active read' 'main' 0 )    # false: -> WS-B8 Routing-Status-Gate
    ) }
    'Package active read'               = @{ main = @(,@( E 'Package active gate' 'main' 0 )) }
    'Package active gate'               = @{ main = @(
        @( E 'Package inactive'      'main' 0 ),  # true: status != active -> structured decline (no LLM)
        @( E 'Core onboarding read'  'main' 0 )   # false: active OR read error (fail-open) -> WS-3 Core-first-Gate
    ) }
    'Core onboarding read'              = @{ main = @(,@( E 'Core onboarding gate' 'main' 0 )) }
    'Core onboarding gate'              = @{ main = @(
        @( E 'Core onboarding required' 'main' 0 ),  # true: Core-Haushalt offen -> Redirect (kein LLM)
        @( E 'Load Config'              'main' 0 )    # false: Core fertig OR read error (fail-open) -> proceed
    ) }
    'Load Config'                       = @{ main = @(,@( E 'Load Agent Context'    'main' 0 )) }
    'Load Agent Context'                = @{ main = @(,@( E 'Onboarding status read' 'main' 0 )) }
    'Onboarding status read'            = @{ main = @(,@( E 'Build Agent Input'     'main' 0 )) }
    'Build Agent Input'                 = @{ main = @(,@( E 'Finance Agent'         'main' 0 )) }

    'Postgres Chat Memory'              = @{ ai_memory = @(,@( E 'Finance Agent' 'ai_memory' 0 )) }
    # Model Selector + Modell-Node-Connections kommen aus dem gemeinsamen Bundle (unten gemerged).

    'postgres_select'          = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'load_context'             = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'web_search'               = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_book_dividend'       = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_book_transfer'       = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_book_transaction'    = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_book_stock_buy'      = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_create_account'      = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_create_insurance'    = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_create_loan'         = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_create_real_estate'  = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_book_stock_sell'     = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_book_loan_payment'   = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_create_savings_goal' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_book_savings_goal_transfer' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_book_savings_reservation' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_reconcile_account'   = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_reconcile_accounts_batch' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_import_stage_rows'   = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_update_staging_row'  = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_commit_import'       = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_extract_finance_document' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_reconcile_bank_statement' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_import_broker_csv' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_void_bank_statement' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_close_account'       = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_create_recurring_payment' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_create_recurring_transfer' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_create_pension'      = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_set_account'         = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_set_account_interest' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_set_real_estate'     = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_set_pension'         = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_set_insurance'       = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_set_loan'            = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_set_recurring_payment' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_set_savings_goal'    = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_set_holding'         = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_set_asset_classes'   = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_verify_price_symbol' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_void_transaction'    = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_create_savings_plan' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_book_savings_plan_execution' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_book_recurring_occurrence' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_book_interest'       = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_set_savings_plan'    = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_close_savings_plan'  = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_close_insurance'     = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_close_pension'       = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_close_savings_goal'  = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_delete_real_estate'  = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_delete_holding'      = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_delete_account'      = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_delete_recurring_payment' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_delete_loan'         = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_settle_loan'         = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_sell_real_estate'    = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
    'tool_set_onboarding_section' = @{ ai_tool = @(,@( E 'Finance Agent' 'ai_tool' 0 )) }
}

# Paket-Werkzeug-Kanten (ai_tool -> Finance Agent) mergen.
foreach ($k in $svc.Connections.Keys) { $connections[$k] = $svc.Connections[$k] }

# Bundle-Connections (Model Selector -> Finance Agent + Modell-Nodes -> Model Selector) mergen.
foreach ($k in $mb.Connections.Keys) { $connections[$k] = $mb.Connections[$k] }

# Alle Tools werden in New-ToolWorkflowNode hart aufgeloest (throw bei fehlender ID) -> keine
# null-Nodes, keine zu entfernenden Connections mehr (die alte $ToolIds-Skip-Schleife entfaellt).

    # Workflow-Objekt OHNE id zurueckgeben — Save-WorkflowFile (build.ps1) backt die State-ID ein.
    return [ordered]@{
        name        = 'agent.finance'
        active      = $false
        nodes       = $allNodes
        connections = $connections
        settings    = [ordered]@{ executionOrder = 'v1'; binaryMode = 'separate'; errorWorkflow = $ErrorNotifyId }
        staticData  = $null
        pinData     = @{}
        triggerCount = 0
        tags        = @()
    }
}
