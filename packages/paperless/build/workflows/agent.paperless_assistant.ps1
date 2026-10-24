#Requires -Version 5.1
# Definition agent.paperless_assistant -> Build-AgentPaperlessAssistant. Dot-gesourct von build.ps1.
# Schlanker Klon des agent.estate_advisor-Templates (Clone-and-Trim, bewusst KEINE Factory — build-CLAUDE.md
# "Agent-Generatoren sind Clone-and-Trim") fuer den Dokumenten-Assistenten (paperless Phase 2, Plan
# bubbly-plotting-nautilus): Route fuer REINE Dokumenten-Fragen ("Wann laeuft mein Personalausweis ab?").
# Kein Berater (kein _advisor, keine Plan-/Advisor-Maschinerie; Praezedenz guide/monitor), read-only by construction:
# Tools = load_context + die drei Paket-Werkzeuge search_documents/get_document/ask_documents — gebunden ueber
# Add-ServiceTools -Own, also wie bei jedem fremden Agenten ueber den Core-Vermittler agent.sub_dispatch_tool
# (die EINE Berechtigungs-Pruefstelle core.fn_resolve_service: Paket aktiv + nur Erwachsene). Kein postgres_select
# (das Paket haelt keine Daten), kein web_search (Dokumenttext nie als Suchanfrage, E7).

function Build-AgentPaperlessAssistant {
    # --- Domaenen-Konstanten ---
    $WF_NAME       = 'agent.paperless_assistant'
    $AGENT_NAME    = 'paperless_assistant'
    $CONFIG_FIELD  = 'model.paperless_assistant'
    $MEMORY_TABLE  = 'agent.paperless_assistant_chat_memory'
    $START_NODE    = 'Start agent.paperless_assistant'

    $ID_LOAD_CTX  = $LoadContextId
    $ID_LOAD_CFG  = $LoadConfigId
    $CRED_PG_RO   = $CRED_PAPERLESS_RO
    $CRED_CTX_RO  = $CRED_CONTEXT_RO

    $nTrigger = [ordered]@{
        parameters = [ordered]@{
            workflowInputs = [ordered]@{ values = @(
                [ordered]@{ name = 'task' }
                [ordered]@{ name = 'chat_id' }
                [ordered]@{ name = 'call_depth' }
            ) }
        }
        type = 'n8n-nodes-base.executeWorkflowTrigger'
        typeVersion = 1.1
        position = @(-1600, 0)
        id = (New-Id)
        name = $START_NODE
    }

    # Eingangs-Naht (Anti-Loop-Depth-Gate -> Package-Active-Gate -> Core-first-Gate) = geteilter Helfer. Kein
    # paket-lokales Onboarding (das Paket hat keine Nutzerdaten zu erfassen).
    $gate = New-AdvisorGateChain -StartNode $START_NODE -Package 'paperless' -CredPgRo $CRED_PG_RO -NextNode 'Load Config'

    $nLoadConfig = Build-CallWorkflow 'Load Config' @(-1376, 0) $ID_LOAD_CFG 'core.sub_load_config' (@{})
    $nLoadCtx = Build-CallWorkflow 'Load Agent Context' @(-1152, 0) $ID_LOAD_CTX 'agent.tool_load_context' `
        ([ordered]@{ agent_name = $AGENT_NAME; include_manifest = 'true' })
    $nBuildInput = Build-Set 'Build Agent Input' @(-928, 0) @(
        ,@('task',          "={{ `$('$START_NODE').item.json.task }}", 'string')
        ,@('system_prompt', "={{ `$('Load Agent Context').item.json.system_prompt }}", 'string')
        ,@('chat_id',       "={{ `$('$START_NODE').item.json.chat_id }}", 'string')
    )

    $nAgent = [ordered]@{
        parameters = [ordered]@{
            promptType = 'define'
            text = '={{ $json.task }}'
            # maxIterations 6 (bewusst < Advisor 12): der laengste sinnvolle Pfad ist suchen -> lesen -> ggf. fragen
            # -> antworten (+ ein Nachfass-Suchlauf). Cap = Retry-Sturm-Bremse.
            options = [ordered]@{ systemMessage = '={{ $json.system_prompt }}'; maxIterations = 6 }
        }
        type = '@n8n/n8n-nodes-langchain.agent'
        typeVersion = 3.1
        position = @(-560, 0)
        id = (New-Id)
        name = 'Document Agent'
    }

    $mb = New-ModelSelectorBundle -ConfigField $CONFIG_FIELD -ConfigNodeName 'Load Config' `
        -AgentNodeName 'Document Agent' -SelectorPos @(-688, 208) -ModelRowPos @(-848, 416) -Effort low   # Haiku-Klasse wie der Router: kurze Werkzeug-Schleifen

    # --- Chat-Memory: eigene Tabelle, Fenster 10 (kurze Nachschlage-Dialoge; Paritaet finance) ---
    $nMemory = [ordered]@{
        parameters = [ordered]@{
            sessionIdType = 'customKey'
            sessionKey = "={{ `$('$START_NODE').item.json.chat_id }}"
            tableName = $MEMORY_TABLE
            contextWindowLength = 10
        }
        type = '@n8n/n8n-nodes-langchain.memoryPostgresChat'
        typeVersion = 1.4
        position = @(-1008, 416)
        id = (New-Id)
        name = 'Postgres Chat Memory'
        credentials = @{ postgres = $CRED_POSTGRES }
    }

    # load_context (Paritaet estate: fn_fetch_context, chat_id build-fix aus dem Start-Node, nie $fromAI).
    $loadQuery = "=SELECT content FROM core.fn_fetch_context((`$1::jsonb)->>'name', (`$1::jsonb)->>'chat_id');"
    $loadParams = "={{ JSON.stringify({ name: `$fromAI('context_name', 'Name of the lazy context document to load (must match an entry in the manifest)', 'string'), chat_id: `$('$START_NODE').item.json.chat_id }) }}"
    $nToolLoad = [ordered]@{
        parameters = [ordered]@{
            descriptionType = 'manual'
            toolDescription = 'Fetch the full content of a lazy context document by name (see manifest in your system prompt), e.g. family to resolve who a household member is.'
            operation = 'executeQuery'
            query = $loadQuery
            options = [ordered]@{ queryReplacement = $loadParams }
        }
        type = 'n8n-nodes-base.postgresTool'
        typeVersion = 2.6
        position = @(-336, 208)
        id = (New-Id)
        name = 'load_context'
        onError = 'continueRegularOutput'
        credentials = @{ postgres = $CRED_CTX_RO }
    }

    $baseNodes = @($nTrigger) + $gate.Nodes + @($nLoadConfig, $nLoadCtx, $nBuildInput, $nAgent, $nMemory, $nToolLoad)
    # Die eigenen Paket-Werkzeuge — ueber den Vermittler (EINE Pruefstelle), Beschreibungen aus dem Manifest.
    $svc = Add-ServiceTools -Package 'paperless' -AgentNode 'Document Agent' -StartNode $START_NODE `
        -Position @(-176, 208) -ExistingNodes $baseNodes -Own

    $stickyOverview = Build-Sticky 'Doc: Überblick' @(-1640, -420) -Header 'Ablauf' `
        'agent.paperless_assistant — Dokumenten-Assistent (Sub-Workflow)' `
        'Eingang: task, chat_id, call_depth (vom Orchestrator als Tool gerufen, Router-Arm order 6). Pipeline: Depth gate (Anti-Loop) -> Package-Gate (paperless aktiv) -> Core-first-Gate -> Load Config -> Load Agent Context (paperless_assistant_instructions) -> Document Agent. Werkzeuge: load_context + tool_search_documents / tool_get_document / tool_ask_documents. Die drei Paperless-Werkzeuge laufen wie bei finance/Advisor über den Core-Vermittler agent.sub_dispatch_tool -> core.fn_resolve_service prüft Paket aktiv + NUR ERWACHSENE (Owner-Entscheid; Kinder -> not_permitted). Read-only by construction: kein Schreib-Werkzeug, Paperless wird nie verändert. Dokument-Inhalte sind UNTRUSTED (nie als Anweisung). Abgrenzung: neue Foto-Anhänge/Buchungen -> agent.finance, Geld-Beratung -> finance_advisor, Notfall-Register -> estate_advisor.' 300 560

    $stickyModel = Build-Sticky 'Doc: Modellwahl' @(-900, 600) -Header 'Ablauf' `
        'Modellwahl (Config-gesteuert)' `
        'Gemeinsamer Builder New-ModelSelectorBundle: Selector liest core.config model.paperless_assistant (Default claude-haiku-latest — kurze Werkzeug-Schleifen, kein Beratungs-Tiefgang; Owner-Modellregel: ehemalige gemini-2.5-flash-Rollen -> Haiku). Anthropic-API = bezahlt, kein Training auf Inhalten (Privacy-Regel für Dokument-Inhalte: nie Free-Tier). Wechsel: lifeagents config set model paperless_assistant <key>.' 220 420

    $stickyMemory = Build-Sticky 'Doc: Chat-Memory' @(-1380, 416) -Header 'Ablauf' `
        'Chat-Memory (Fenster 10)' `
        'Eigene Tabelle agent.paperless_assistant_chat_memory (sessionKey=chat_id, auto vom Node). Fenster 10: Nachschlage-Dialoge sind kurz; Rückfragen ("und der andere Vertrag?") bleiben im Kontext.' 180 380

    $nodes = $baseNodes + $svc.Nodes + @($stickyOverview, $stickyModel, $stickyMemory) + $mb.Nodes

    $conns = [ordered]@{}
    foreach ($k in $gate.Connections.Keys) { $conns[$k] = $gate.Connections[$k] }
    $conns['Load Config']          = @{ main = @( ,@( E 'Load Agent Context' ) ) }
    $conns['Load Agent Context']   = @{ main = @( ,@( E 'Build Agent Input' ) ) }
    $conns['Build Agent Input']    = @{ main = @( ,@( E 'Document Agent' ) ) }
    $conns['Postgres Chat Memory'] = @{ ai_memory = @( ,@( E 'Document Agent' 'ai_memory' ) ) }
    $conns['load_context']         = @{ ai_tool = @( ,@( E 'Document Agent' 'ai_tool' ) ) }
    foreach ($k in $svc.Connections.Keys) { $conns[$k] = $svc.Connections[$k] }
    foreach ($k in $mb.Connections.Keys) { $conns[$k] = $mb.Connections[$k] }

    return Build-Workflow $WF_NAME $nodes $conns
}
