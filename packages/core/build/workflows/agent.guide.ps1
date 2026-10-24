#Requires -Version 5.1
# Definition agent.guide -> Build-AgentGuide. Dot-gesourct von build.ps1.
# Clone-and-Trim des Advisor-Templates (KEINE Factory — vierter Agent; eine Template-Extraktion bliebe YAGNI).
# Der Guide ist Help + Core-Onboarding: er erfasst die Haushalts-Fakten und zeigt auf die naechsten
# Onboarding-Bereiche; die Paket-Bereiche onboardet jeder Paket-Agent selbst mit seinen eigenen Tools
# (keine Guide->Paket-Delegation, packages/core/CLAUDE.md *Onboarding-Zustand*). Reads: postgres_select
# (core_ro) + load_context (context_ro). Writes (HITL): tool_set_household_facts; tool_set_onboarding_section
# ist nur der Fortschritts-Marker (kein Gate). Bewusst NICHT gebunden: tool_save_plan_section (Micro-Goals
# -> Advisor-Draft + Pin-Praezedenz = BACKLOG) und alle Paket-Schreib-Tools.

# New-AdvisorToolNode (CROSS-AGENT-Tool-Builder) lebt seit Phase 0 WS-0c AT geteilt in
# scripts/build/lib/build_helpers.ps1 (loest die lokale Duplikat-Def New-GuideToolNode ab). Der Guide bindet
# keine FixedInputs -> die Calls uebergeben $null an dieser Stelle + -StartNode 'Start agent.guide' (PFLICHT).

function Build-AgentGuide {
    $WF_NAME      = 'agent.guide'
    $AGENT_NAME   = 'guide'
    $CONFIG_FIELD = 'model.guide'
    $MEMORY_TABLE = 'agent.guide_chat_memory'
    $START_NODE   = 'Start agent.guide'

    # Infra-IDs (build-generierte Subs; per Name aus dem State aufgeloest in build.ps1 — kein ID-Literal)
    $ID_LOAD_CTX  = $LoadContextId   # agent.tool_load_context (build.ps1: per Name aus dem State)
    $ID_LOAD_CFG  = $LoadConfigId    # core.sub_load_config (build.ps1: per Name aus dem State)
    # CORE-Agent: Frei-SQL-Lesepfad laeuft unter core_ro (agent+core+finance read-only) — NICHT
    # finance_ro, das nach der Paket-Isolation eng auf `finance` skopiert ist (B3/Owner-Lock).
    $CRED_PG_RO   = $CRED_CORE_RO
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

    # Anti-Loop-Backstop (Pflicht fuer jeden AGENT-Workflow)
    $nDepthGate = Build-If 'Depth gate' @(-1480, 0) `
        "={{ Number(`$json.call_depth) || 0 }}" '2' 'largerEqual' 'number'
    $nDepthDeny = Build-ToolError 'Max call depth' @(-1300, 200) 'max_call_depth'

    $nLoadConfig = Build-CallWorkflow 'Load Config' @(-1376, 0) $ID_LOAD_CFG 'core.sub_load_config' (@{})
    $nLoadCtx = Build-CallWorkflow 'Load Agent Context' @(-1152, 0) $ID_LOAD_CTX 'agent.tool_load_context' `
        ([ordered]@{ agent_name = $AGENT_NAME; include_manifest = 'true' })

    # Install-UX-Phase 6 (Muster finance 'Onboarding status read' -> 'Build Agent Input'): der Guide KENNT den
    # Haushalt, bevor er fragt — Name/Geburtsdatum des Owners stehen seit der Installation in family.facts.persons
    # (util_seed_owner_skeleton). Deterministisch per Read-Node statt Prompt-Bitte "lade family zuerst" (Prompt
    # driftet). Nur Namen/Rolle + "Geburtsdatum vorhanden ja/nein" + Namen weiterer gespeicherter Fakten — NIE die
    # Werte selbst (kein Geburtsdatum im Prompt). core_ro liest agent.* (dokumentierte Rolle des Core-Lesepfads).
    # onError=continue -> ein Lese-Hiccup bricht den Guide nicht; dann fehlt household_status und der Block wird
    # GANZ weggelassen (Muster finance: bei Fehler nichts anhaengen — nie faelschlich "niemand gespeichert").
    $nHouseholdRead = Build-Pg 'Household status read' @(-1040, 0) `
        "=SELECT COALESCE((SELECT status FROM agent.guide_onboarding_state WHERE section_key = 'household'), 'unknown') AS household_status, COALESCE((SELECT string_agg(format('- %s %s (role %s; birth date %s%s)', pp->>'first_name', pp->>'last_name', pp->>'role', CASE WHEN NULLIF(pp->>'birth_date', '') IS NULL THEN 'missing' ELSE 'stored' END, COALESCE('; also stored: ' || (SELECT string_agg(k, ', ' ORDER BY k) FROM jsonb_object_keys(pp) AS k WHERE k NOT IN ('person_id','first_name','last_name','role','birth_date','as_of','telegram_user_id','aliases')), '')), E'\n' ORDER BY x.ord) FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) WITH ORDINALITY AS x(pp, ord) WHERE c.name = 'family'), '') AS persons;"
    $nHouseholdRead.credentials = @{ postgres = $CRED_PG_RO }
    $nHouseholdRead.onError = 'continueRegularOutput'

    $nBuildInput = Build-Set 'Build Agent Input' @(-928, 0) @(
        ,@('task',          "={{ `$('$START_NODE').item.json.task }}", 'string')
        ,@('system_prompt', "={{ `$('Load Agent Context').item.json.system_prompt + (`$('Household status read').item.json.household_status ? ('\n\n## Household so far (from the installation and earlier onboarding - authoritative)\n' + (`$('Household status read').item.json.persons ? (`$('Household status read').item.json.persons + '\nDo NOT ask again for the name or birth date of anyone listed here - confirm briefly instead (e.g. Dich kenne ich schon aus der Installation). Ask only for what is still missing (e.g. partner, children, employment).') : 'No household members stored yet.') + '\nHousehold onboarding status: ' + `$('Household status read').item.json.household_status) : '') }}", 'string')
        ,@('chat_id',       "={{ `$('$START_NODE').item.json.chat_id }}", 'string')
    )

    $nAgent = [ordered]@{
        parameters = [ordered]@{
            promptType = 'define'
            text = '={{ $json.task }}'
            # maxIterations 12: Onboarding ist tool-lastig (Resume-Read + staging + commit + Marker).
            options = [ordered]@{ systemMessage = '={{ $json.system_prompt }}'; maxIterations = 12 }
        }
        type = '@n8n/n8n-nodes-langchain.agent'
        typeVersion = 3.1
        position = @(-560, 0)
        id = (New-Id)
        name = 'Guide Agent'
    }

    $mb = New-ModelSelectorBundle -ConfigField $CONFIG_FIELD -ConfigNodeName 'Load Config' `
        -AgentNodeName 'Guide Agent' -SelectorPos @(-688, 208) -ModelRowPos @(-848, 416) -Effort medium

    # Chat-Memory: eigene Tabelle, Fenster 15 (Onboarding ist ein langer Dialog wie das Interview)
    $nMemory = [ordered]@{
        parameters = [ordered]@{
            sessionIdType = 'customKey'
            sessionKey = "={{ `$('$START_NODE').item.json.chat_id }}"
            tableName = $MEMORY_TABLE
            contextWindowLength = 15
        }
        type = '@n8n/n8n-nodes-langchain.memoryPostgresChat'
        typeVersion = 1.4
        position = @(-1008, 416)
        id = (New-Id)
        name = 'Postgres Chat Memory'
        credentials = @{ postgres = $CRED_POSTGRES }
    }

    # --- Read-Tools ---
    $descSelect = 'Run read-only SELECT queries (role core_ro: schemas `agent` + `core`, plus the schema of every ACTIVE package). Use it to check which package areas still need onboarding (SELECT core.fn_onboarding_pending_packages()) and to look up details before capturing (dedup). The household onboarding status and the stored household members are already in your system prompt (Household so far). Views are narrow: SELECT * if unsure of columns. On a query error you receive it back - correct and retry. No write access.'
    # Frei-SQL-Lesewerkzeug: geteilter Builder (Guard gegen fehlendes query-Argument, onError continue).
    $nToolSelect = New-PostgresSelectToolNode -Description $descSelect -Cred $CRED_PG_RO

    $loadQuery = "=SELECT content FROM core.fn_fetch_context((`$1::jsonb)->>'name');"
    $loadParams = "={{ JSON.stringify({ name: `$fromAI('context_name', 'Name of the lazy context document to load (e.g. family, capabilities_catalog)', 'string') }) }}"
    $nToolLoad = [ordered]@{
        parameters = [ordered]@{
            descriptionType = 'manual'
            toolDescription = 'Fetch the full content of a lazy context document by name (see manifest in your system prompt). Load `family` for the full household facts and prose (the member list is already in your prompt); load `capabilities_catalog` for the feature overview incl. the section of functions that can still be added on the server.'
            operation = 'executeQuery'; query = $loadQuery
            options = [ordered]@{ queryReplacement = $loadParams }
        }
        type = 'n8n-nodes-base.postgresTool'; typeVersion = 2.6
        position = @(-16, 208); id = (New-Id); name = 'load_context'
        onError = 'continueRegularOutput'; credentials = @{ postgres = $CRED_CTX_RO }
    }

    # --- Guide-Write-Tools (Section 0 + Fortschritt) ---
    # Phase A: der KI-Name bleibt tool_set_household_facts (LLM-Vertrag unveraendert), der Workflow ist der EINE
    # Fakten-Schreibweg agent.tool_set_context_facts (Muster career: 1 Workflow, mehrere Bindings). scope FEST
    # 'household' (nie $fromAI) -> die fn lehnt einen per_user-Kontext ab. Die household-Kontexte der Pakete nennt
    # der $fromAI-Text build-time aus den Manifest-context_scopes ($HouseholdFactsContexts, build.ps1).
    $ctxHint = 'family (default)'
    if ($HouseholdFactsContexts.Count -gt 0) {
        $ctxHint += '; or a package household profile (' + ($HouseholdFactsContexts -join ', ') + ') only if that package is active per installed_packages'
    }
    $nToolHousehold = New-AdvisorToolNode 'tool_set_household_facts' 'agent.tool_set_context_facts' `
        ('SECTION 0 (household) — capture household members and facts into the family context. Pass persons as a JSON ARRAY string and household as a JSON OBJECT string. Each person needs person_id (a stable slug, e.g. erika), first_name AND last_name (always both), birth_date (YYYY-MM-DD), role (owner|partner|child), and employment/insurance facts if known (free text stored verbatim in the words the user used, never translated). language = the code of the language for the bot fixed messages, ONLY one of __LANG_CODES__ and ONLY if the user states it - do not ask for it (after a new person is saved the owner gets a language button card automatically). Persons already listed in Household so far exist: to add facts to them, pass ONLY their existing person_id + the new keys (never re-create them under a new id). Play back values you assembled over several turns before calling; if the user just gave the values with an explicit save instruction, call directly - the tool shows a short button confirmation and merges atomically (ok:false with a reason = rejected, fix and ask).').Replace('__LANG_CODES__', $LanguageCodes) `
        @(
            ,@('persons', 'JSON array string of person objects, each {person_id, first_name, last_name, birth_date, role, ...}', 'string', '')
            ,@('household', 'JSON object string of household-level facts (e.g. {"joint_finances": true})', 'string', '')
            ,@('context_name', $ctxHint, 'string', 'family')
            ,@('content', 'Optional prose body to replace the context document text', 'string', '')
        ) ([ordered]@{ scope = 'household' }) @(160, 208) -StartNode $START_NODE

    $nToolMarkSection = New-AdvisorToolNode 'tool_set_onboarding_section' 'agent.guide.tool_set_onboarding_section' `
        'Mark the household onboarding section done. Call AFTER you finished (or the user chose to skip) the household. section_key is ALWAYS "household" (the sections of installed packages belong to those packages agents, which mark their own). status = completed (captured) or skipped (user consciously declined - legitimate, recorded) or unknown (reset). Returns onboarding_complete = whether the core (household) part is now resolved.' `
        @(
            ,@('section_key', 'always "household" (the only section the guide owns)', 'string')
            ,@('status', 'completed | skipped | unknown', 'string')
        ) $null @(320, 208) -StartNode $START_NODE

    # WS-5a: Owner-only Member-Einladung. chat_id wird wie bei allen guide-Tools deterministisch aus
    # 'Start agent.guide' durchgereicht (NICHT $fromAI) -> die fn leitet die Owner-Identitaet daraus ab.
    $nToolInvite = New-AdvisorToolNode 'tool_invite_household_member' 'agent.guide.tool_invite_household_member' `
        'Issue a member invitation (OWNER ONLY). When the household owner wants an EXISTING family member to use the bot from their own Telegram ("invite my daughter Lisa", "lade meine Tochter ein", "Partner einladen"), call this with the person name. Returns a one-time deep link the owner shares out-of-band; the member redeems it and the owner confirms by button before access becomes active. NOT for capturing NEW people (that is onboarding via tool_set_household_facts), and the tool itself rejects non-owner callers.' `
        @(
            ,@('person_name', 'Name of the existing household member to invite (first name or full name as stored in the family facts)', 'string')
        ) $null @(480, 208) -StartNode $START_NODE

    # WS-B3 (O3): Paket-Onboarding-Sektionen sind paket-besessen -> der provides.onboarding-Agent des Pakets
    # erfasst sie selbst (Self-Onboarding + eigene Staging-Pipeline + <pkg>.onboarding_state). Der Guide bindet
    # keine Paket-Staging-/Vision-Tools; er macht nur household + verweist fuer Paket-Bereiche auf deren Agenten.
    # NOTE: der Orchestrator routet einen Anhang nie an den Guide (der Guide nimmt laut router_description keine
    # Dokumentarten an; Onboarding-Pin gilt nicht fuer Anhaenge, Phase C) -> keine Vision-Bindung hier.

    # --- Doku-Stickies ---
    $stickyOverview = Build-Sticky 'Doc: Überblick' @(-1640, -380) `
        'agent.guide — Help + Household-Onboarding (Sub-Workflow)' `
        'Eingang: task, chat_id, call_depth (vom Orchestrator als Tool gerufen). Pipeline: Depth gate -> Load Config -> System-Prompt+Manifest (agent.tool_load_context, agent_name=guide; enthält den statischen Context installed_packages = welche Pakete aktiv/aus/nicht installiert sind) -> Household status read (core_ro: family-Personen mit Rolle + Geburtsdatum vorhanden ja/nein + Haushalts-Status; Install-UX-Phase 6: der bei der Installation angelegte Owner wird nicht erneut nach Name/Geburtsdatum gefragt) -> Build Agent Input (hängt Household so far an) -> Guide Agent. WS-B3 (O3): der Guide onboardet NUR den Haushalt (Section household) -> tool_set_household_facts (HITL) + tool_set_onboarding_section(household, Tri-State, kein Gate). Die Paket-Onboarding-Sektionen sind paket-besessen und werden vom provides.onboarding-Agenten des jeweiligen Pakets selbst erfasst (Self-Onboarding + eigene Staging-Pipeline + <pkg>.onboarding_state) -> der Guide bindet keine Paket-Staging-/Vision-Tools und verweist für Paket-Bereiche auf /onboarding bzw. den zuständigen Paket-Agenten (nur wenn das Paket laut installed_packages aktiv ist; sonst nennt er den Server-Befehl lifeagents package install). Reads: postgres_select (core_ro) + load_context (context_ro, family/capabilities_catalog). Fachfragen der Pakete gehen über den Orchestrator an deren Agenten; Trigger -> agent.monitor.' 320 600

    $stickyModel = Build-Sticky 'Doc: Modellwahl' @(-900, 600) `
        'Modellwahl (Config-gesteuert)' `
        'Gemeinsamer Builder New-ModelSelectorBundle: je Claude-Modell ein Node (Haiku/Sonnet/Opus), Selector liest core.config model.guide. Default claude-sonnet-latest, Denk-Tiefe medium (Onboarding ist tool-lastig -> zuverlässiges Function-Calling). Wechsel: lifeagents config set model guide <key>, kein Build.' 220 460

    $nodes = @(
        $nTrigger, $nDepthGate, $nDepthDeny, $nLoadConfig, $nLoadCtx, $nHouseholdRead, $nBuildInput, $nAgent, $nMemory,
        $nToolSelect, $nToolLoad, $nToolHousehold, $nToolMarkSection, $nToolInvite,
        $stickyOverview, $stickyModel
    ) + $mb.Nodes

    $conns = [ordered]@{
        $START_NODE          = @{ main = @( ,@( E 'Depth gate' ) ) }
        'Depth gate'         = @{ main = @(
            @( E 'Max call depth' ),
            @( E 'Load Config' )
        ) }
        'Load Config'        = @{ main = @( ,@( E 'Load Agent Context' ) ) }
        'Load Agent Context' = @{ main = @( ,@( E 'Household status read' ) ) }
        'Household status read' = @{ main = @( ,@( E 'Build Agent Input' ) ) }
        'Build Agent Input'  = @{ main = @( ,@( E 'Guide Agent' ) ) }
        'Postgres Chat Memory' = @{ ai_memory = @( ,@( E 'Guide Agent' 'ai_memory' ) ) }
        'postgres_select'        = @{ ai_tool = @( ,@( E 'Guide Agent' 'ai_tool' ) ) }
        'load_context'           = @{ ai_tool = @( ,@( E 'Guide Agent' 'ai_tool' ) ) }
        'tool_set_household_facts'     = @{ ai_tool = @( ,@( E 'Guide Agent' 'ai_tool' ) ) }
        'tool_set_onboarding_section'  = @{ ai_tool = @( ,@( E 'Guide Agent' 'ai_tool' ) ) }
        'tool_invite_household_member' = @{ ai_tool = @( ,@( E 'Guide Agent' 'ai_tool' ) ) }
    }
    foreach ($k in $mb.Connections.Keys) { $conns[$k] = $mb.Connections[$k] }

    return Build-Workflow $WF_NAME $nodes $conns
}
