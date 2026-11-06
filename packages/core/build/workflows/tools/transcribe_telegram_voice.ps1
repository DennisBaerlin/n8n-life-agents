#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_transcribe_telegram_voice ------------------
# Wiederverwendbarer Baustein (tool = fokussierte Einzweck-Faehigkeit, Eingang->Ausgang):
# Telegram-file_id (Sprachnachricht ODER Audiodatei) -> Download -> Transkription -> { ok, text }.
# DUAL-USE: der Orchestrator ruft ihn INLINE (executeWorkflow) auf dem voice/audio-Zweig; ein Agent
# koennte ihn 1:1 als Tool binden (toolWorkflow, $fromAI) -- derselbe executeWorkflowTrigger-Eingang.
# Provider-Wahl runtime ueber core.config transcription.provider (Switch wie im alten Orchestrator);
# der deaktivierte Groq-Pfad ist 1:1 erhalten (Owner-Entscheid), aktiv ist Google-Gemini-Audio — der EINZIGE
# verbliebene Google-Sprachmodell-Aufruf (Claude versteht kein Audio; Google-Schluessel ist optional).
# Fehler (kein Google-Schluessel / Credential fehlt, Download- oder API-Fehler, unbekannter Anbieter) enden NICHT
# im Absturz, sondern als Daten { ok:false, error:'voice_unavailable', reason } (Build-ToolError-Vertrag) — der
# Orchestrator antwortet dann freundlich und informiert den Owner hoechstens 1x/Tag. Ein leeres Transkript (stille
# Aufnahme) endet als { ok:false, error:'voice_empty' } — kein Ausfall, der Orchestrator bittet nur um Wiederholung.
function Build-TranscribeTelegramVoice {
    $ID_LOAD_CFG = $LoadConfigId   # core.sub_load_config (build.ps1: per Name aus dem State)

    # Eingang: file_id (chat_id kommt via Build-Trigger automatisch dazu, hier ungenutzt).
    $trig = Build-Trigger @('file_id') @(-640, 0)

    # Config laden -> transcription.provider fuer den Switch.
    $loadCfg = Build-CallWorkflow 'Load core.config' @(-420, 0) $ID_LOAD_CFG 'core.sub_load_config' (@{})

    # Telegram-Download (resource=file). Node-Name bewusst 'Get Telegram voice file' (der deaktivierte
    # Groq-HTTP-Node referenziert ihn per Namen -> 1:1-Erhalt).
    $getFile = [ordered]@{
        parameters = [ordered]@{
            resource = 'file'
            fileId   = "={{ `$('Start').item.json.file_id }}"
            additionalFields = @{}
        }
        type = 'n8n-nodes-base.telegram'
        typeVersion = 1.2
        position = @(-200, 0)
        id = (New-Id)
        name = 'Get Telegram voice file'
        # onError -> Fehler-Ausgang [1] (Voice unavailable). maxTries=1 ist ERZWUNGEN: retryOnFail x onError=Continue
        # ist in n8n defekt (GH #10763, WP-2-Muster); retryOnFail bleibt fuers Retry-Gesetz von workflow_lint.
        retryOnFail = $true; maxTries = 1; waitBetweenTries = 3000
        onError = 'continueErrorOutput'
        credentials = @{ telegramApi = $CRED_TELEGRAM }
    }

    # Provider-Switch (string-equals; 1:1 aus dem Orchestrator: groq | google). Fallback [2] (unbekannter Anbieter)
    # -> Voice unavailable (vorher unverdrahtet = stilles Nicht-Antworten).
    $switch = Build-Switch 'Which transcription model' @(40, 0) @(
        @{ Left = "={{ `$('Load core.config').item.json.transcription.provider }}"; Type = 'string'; Op = 'equals'; Right = 'groq';   OutputKey = 'groq' }
        @{ Left = "={{ `$('Load core.config').item.json.transcription.provider }}"; Type = 'string'; Op = 'equals'; Right = 'google'; OutputKey = 'google' }
    )

    # --- Groq-Pfad (DEAKTIVIERT, 1:1 erhalten) -------------------------------------------------
    $groqCreds = Build-Set 'Groq credentials' @(280, -160) @(
        ,@('Groq_API',              'YOUR_GROQ_API_KEY',              'string')
        ,@('Telegram_access_token', 'YOUR_TELEGRAM_BOT_ACCESS_TOKEN', 'string')
    )
    $groqCreds['disabled'] = $true

    $httpGroq = [ordered]@{
        disabled = $true
        parameters = [ordered]@{
            method = 'POST'
            url = 'https://api.groq.com/openai/v1/audio/transcriptions'
            sendBody = $true
            sendHeaders = $true
            contentType = 'multipart-form-data'
            bodyParameters = [ordered]@{ parameters = @(
                ,[ordered]@{ name = 'url'; value = "=https://api.telegram.org/file/bot{{ `$('Groq credentials').item.json.Telegram_access_token }}/{{ `$('Get Telegram voice file').item.json.result.file_path }}" }
            ) }
            headerParameters = [ordered]@{ parameters = @(
                ,[ordered]@{ name = 'Authorization'; value = "=Bearer {{ `$('Groq credentials').item.json.Groq_API }}" }
            ) }
            options = @{}
        }
        type = 'n8n-nodes-base.httpRequest'
        typeVersion = 4.4
        position = @(500, -160)
        id = (New-Id)
        name = 'HTTP Request'
    }

    # --- Google-Pfad (AKTIV): Gemini-Audio-Transkription (binary) ------------------------------
    $transcribe = [ordered]@{
        parameters = [ordered]@{
            resource = 'audio'
            inputType = 'binary'
            modelId = [ordered]@{ '__rl' = $true; mode = 'list'; value = 'models/gemini-2.5-flash'; cachedResultName = 'models/gemini-2.5-flash' }
            options = @{}
        }
        type = '@n8n/n8n-nodes-langchain.googleGemini'
        typeVersion = 1.2
        position = @(280, 60)
        id = (New-Id)
        name = 'Transcribe via Gemini'
        onError = 'continueErrorOutput'   # fehlende/ungueltige Google-Credential oder API-Fehler -> [1] Voice unavailable
        credentials = @{ googlePalmApi = $CRED_GEMINI }
    }

    # Transkript aus der Anbieter-Antwort ziehen. Gemini (Simplify Output) liefert je Kandidat
    # { content: { parts: [{ text }] } } — KEIN Top-Level-.text (das las der Return frueher -> "null" als
    # Chat-Nachricht). Groq (OpenAI-Form) liefert .text direkt. Ergebnis getrimmt, leer = kein Transkript.
    $extract = Build-Set 'Extract transcript' @(500, 0) @(
        ,@('text', "={{ (typeof `$json.text === 'string' ? `$json.text : ((`$json.content && `$json.content.parts) || []).map(p => p.text || '').join('')).trim() }}", 'string')
    )
    # Leeres Transkript (stille/unverstaendliche Aufnahme) ist KEIN Erfolg (sonst bekaeme der Orchestrator einen
    # leeren Auftrag), aber auch KEIN Ausfall: eigener Code voice_empty -> der Orchestrator bittet um Wiederholung
    # und meldet dem Owner nichts (die 1x/Tag-Ausfallmeldung bleibt fuer echte Ausfaelle frei).
    $hasText = Build-If 'Transcript present?' @(620, 0) "={{ `$json.text }}" '' 'notEquals' 'string'
    $empty = Build-Set 'Transcript empty' @(860, -200) @(
        ,@('ok',     'false',           'boolean')
        ,@('error',  'voice_empty',     'string')
        ,@('reason', 'Transkript leer', 'string')
    )

    # Rueckgabe-Vertrag: { ok, text } bzw. { ok:false, error:'voice_unavailable'|'voice_empty', reason }. ok:true
    # NUR mit nicht-leerem Transkript.
    $ret = Build-Return @(860, 0) @(
        ,@('ok',   'true',                 'boolean')
        ,@('text', "={{ `$json.text }}",   'string')
    )
    # EIN Fehler-Sammelpunkt fuer Download-Fehler, Transkriptions-Fehler und unbekannten Anbieter. reason = der
    # n8n-Fehlertext (Fehler-Ausgang: $json.error als Text oder Objekt) bzw. der unbekannte Anbieter (Fallback).
    $unavailable = Build-Set 'Voice unavailable' @(860, 200) @(
        ,@('ok',     'false',             'boolean')
        ,@('error',  'voice_unavailable', 'string')
        # reason = roher (englischer) n8n-Fehlertext; fehlt er, ist kein Anbieter eingerichtet -> reason_code + provider
        # (der Orchestrator rendert daraus den Owner-Hinweis in Owner-Sprache, core.orch.reason_provider_missing).
        ,@('reason', "={{ (typeof `$json.error === 'string' ? `$json.error : ((`$json.error && `$json.error.message) || `$json.message || '')) || '' }}", 'string')
        ,@('reason_code', "={{ ((typeof `$json.error === 'string' ? `$json.error : ((`$json.error && `$json.error.message) || `$json.message || '')) || '') ? '' : 'provider_missing' }}", 'string')
        ,@('provider', "={{ `$('Load core.config').item.json.transcription.provider || '' }}", 'string')
    )

    $sticky = Build-Sticky 'Doc: Telegram-Voice-Transkription' @(-660, -300) `
        -Header 'Ablauf' `
        'agent.tool_transcribe_telegram_voice (Baustein, KEIN LLM-Agent)' `
        'Eingang file_id (Telegram voice ODER audio -- Orchestrator reicht message.voice.file_id bzw. message.audio.file_id durch). Load core.config -> Get Telegram voice file (Download) -> Which transcription model (core.config transcription.provider): google -> Transcribe via Gemini (Gemini-Audio, binary, gemini-2.5-flash; der EINZIGE verbliebene Google-Sprachmodell-Aufruf, Google-Schlüssel optional) -> Extract transcript (Gemini liefert den Text verschachtelt in content.parts[].text, Groq direkt als .text; getrimmt) -> Transcript present? -> Return { ok, text }; leeres Transkript (stille Aufnahme) -> Transcript empty { ok:false, error:voice_empty } (kein Ausfall: der Orchestrator bittet um Wiederholung, keine Owner-Meldung). FEHLERWEG: Download-Fehler, Transkriptions-Fehler (z. B. kein Google-Schlüssel) und unbekannter Anbieter (Switch-Fallback) -> Voice unavailable { ok:false, error:voice_unavailable, reason } (onError=continueErrorOutput, Download maxTries=1 wegen GH #10763) -> der Orchestrator antwortet freundlich + Owner-Info 1x/Tag. Groq-Pfad (HTTP Request) ist DEAKTIVIERT (Platzhalter-Key, 1:1 erhalten). DUAL-USE: inline per executeWorkflow (Orchestrator) ODER als Agent-Tool bindbar (gleicher executeWorkflowTrigger-Eingang).' 300 560

    $nodes = @($trig, $loadCfg, $getFile, $switch, $groqCreds, $httpGroq, $transcribe, $extract, $hasText, $empty, $ret, $unavailable, $sticky)

    $conns = [ordered]@{
        'Start'                      = @{ main = @( ,@( E 'Load core.config' ) ) }
        'Load core.config'           = @{ main = @( ,@( E 'Get Telegram voice file' ) ) }
        'Get Telegram voice file'    = @{ main = @(
            @( E 'Which transcription model' ),   # [0] Erfolg
            @( E 'Voice unavailable' )            # [1] Fehler-Ausgang (Download gescheitert)
        ) }
        'Which transcription model'  = @{ main = @(
            @( E 'Groq credentials' ),       # [0] groq (deaktiviert)
            @( E 'Transcribe via Gemini' ),  # [1] google (aktiv)
            @( E 'Voice unavailable' )       # [2] Fallback: unbekannter Anbieter
        ) }
        'Groq credentials'           = @{ main = @( ,@( E 'HTTP Request' ) ) }
        'HTTP Request'               = @{ main = @( ,@( E 'Extract transcript' ) ) }
        'Transcribe via Gemini'      = @{ main = @(
            @( E 'Extract transcript' ),     # [0] Erfolg
            @( E 'Voice unavailable' )       # [1] Fehler-Ausgang (Credential/API)
        ) }
        'Extract transcript'         = @{ main = @( ,@( E 'Transcript present?' ) ) }
        'Transcript present?'        = @{ main = @(
            @( E 'Return' ),                 # [0] true: Transkript da
            @( E 'Transcript empty' )        # [1] false: leeres Transkript (voice_empty)
        ) }
    }

    return Build-Workflow 'agent.tool_transcribe_telegram_voice' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
