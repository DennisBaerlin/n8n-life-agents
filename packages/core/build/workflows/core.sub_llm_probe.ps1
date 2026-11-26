#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_llm_probe (Nachschau waehrend einer KI-Pause) ----------------------------------------------------------
# Halb-offener Schutzschalter: core.fn_llm_probe_due entscheidet, ob jetzt nachgeschaut wird (Plan und Sperre in der DB).
# Hat der Gateway seit Beginn der Pause schon einen Erfolg gesehen (GET /__llm_status), zaehlt das ohne eigene Anfrage;
# sonst eine winzige Anfrage an Claude (Router-Modell, max_tokens 1, kein Wiederholen). core.fn_llm_probe_result schliesst
# die Pause oder plant die naechste Nachschau und baut die Nachrichten; core.sub_send_messages sendet sie.
# Aufrufer: core.cron_llm_probe (trigger cron) und der Orchestrator nach dem Knopf [Erledigt – jetzt nachschauen] (button).
function Build-CoreSubLlmProbe {
    $trig = Build-Trigger @('trigger') @(-1320, 0)

    # trigger geht mit: der Knopf schaut sofort nach (Regel: core.fn_llm_probe_due).
    $due = Build-Pg 'Probe due' @(-1100, 0) "=SELECT core.fn_llm_probe_due(`$1::jsonb)::text AS r;" ([ordered]@{
        trigger = "String(`$('Start').first().json.trigger || 'cron')" })
    $D = "JSON.parse(`$('Probe due').first().json.r || '{}')"
    $ifDue = Build-If 'Due?' @(-880, 0) "={{ $D.due === true }}" 'true' 'equals' 'boolean'

    $status = New-LlmStatusNode -Position @(-660, 0)
    # Ein Erfolg des Gateways, der NACH dem letzten Fehler und nach Beginn der Pause begann (last_ok_started_at), = die KI antwortet
    # wieder (eine echte Nachricht war die Probe); ein vorher gestarteter langer Stream zaehlt nicht. Vergleich ueber Date.parse.
    $S = "(`$('Read LLM status').first().json || {})"
    $seenOk = "!!$S.last_ok_started_at && (!$S.last_error || Date.parse($S.last_ok_started_at) > Date.parse($S.last_error.at)) && Date.parse($S.last_ok_started_at) > Date.parse($D.opened_at)"
    $ifSeen = Build-If 'Seen ok?' @(-440, 0) "={{ $seenOk }}" 'true' 'equals' 'boolean'

    $model = New-ModelConfigNode -Position @(-220, 160) -Keys @( ,@('core', 'orchestrator') )
    $probe = New-AnthropicMessagesNode -Name 'Probe Claude' -Position @(0, 160) -ConfigModelKey 'orchestrator' `
        -System 'Reply with the single word ok.' -ContentJs "'ping'" -Effort low -MaxTokens 1 -TimeoutMs 30000
    $probe.retryOnFail = $false
    $probe.maxTries = 1

    $result = Build-Pg 'Probe result' @(220, 0) "=SELECT core.fn_llm_probe_result(`$1::jsonb)::text AS r;" ([ordered]@{
        incident_id = "$D.incident_id"
        ok          = "($seenOk) || (`$('Probe Claude').isExecuted && Array.isArray(`$('Probe Claude').first().json.content))"
        trigger     = "String(`$('Start').first().json.trigger || 'cron')"
    })
    $R = "JSON.parse(`$('Probe result').first().json.r || '{}')"
    $ifMsgs = Build-If 'Messages?' @(440, 0) "={{ ($R.messages || []).length > 0 }}" 'true' 'equals' 'boolean'
    $idSend = Get-RequiredWorkflowId 'core.sub_send_messages' -Caller 'Build-CoreSubLlmProbe'
    $send = Build-CallWorkflow 'Send messages' @(660, 0) $idSend 'core.sub_send_messages' ([ordered]@{
        messages = "={{ JSON.stringify($R.messages || []) }}"; chat_id = '' })

    $sticky = Build-Sticky 'Überblick' @(-1340, -460) -Header 'Ablauf' `
        'core.sub_llm_probe — Nachschau während einer KI-Pause (Limit, Guthaben, Schlüssel, Störung)' `
        'Start (trigger cron|button) -> Probe due (core.fn_llm_probe_due: offene Pause, Zeitpunkt erreicht, keine andere Nachschau läuft; Plan und Sperre in der DB) -> Due? -> Read LLM status (Gateway GET /__llm_status) -> Seen ok? = der Gateway sah nach dem letzten Fehler und nach Beginn der Pause schon einen Erfolg (eine echte Nachricht war die Probe) -> direkt Probe result; sonst Load model config -> Probe Claude (Router-Modell, max_tokens 1, ein Versuch; eine Ablehnung wegen Limit oder Guthaben kostet nichts) -> Probe result (core.fn_llm_probe_result: Erfolg = Antwort mit content; schließt die Pause und baut die Nachrichten, sonst nächste Nachschau nach Plan; Knopf: Satz „noch gesperrt“) -> Messages? -> Send messages (core.sub_send_messages). Kein Stop and Error: eine Probe, die scheitert, ist der erwartete Fall.' 460 460

    $nodes = @($trig, $due, $ifDue, $status, $ifSeen, $model, $probe, $result, $ifMsgs, $send, $sticky)
    $conns = [ordered]@{
        'Start'             = @{ main = @( ,@( E 'Probe due' ) ) }
        'Probe due'         = @{ main = @( ,@( E 'Due?' ) ) }
        'Due?'              = @{ main = @( @( E 'Read LLM status' ), @() ) }
        'Read LLM status'   = @{ main = @( ,@( E 'Seen ok?' ) ) }
        'Seen ok?'          = @{ main = @( @( E 'Probe result' ), @( E 'Load model config' ) ) }
        'Load model config' = @{ main = @( ,@( E 'Probe Claude' ) ) }
        'Probe Claude'      = @{ main = @( ,@( E 'Probe result' ) ) }
        'Probe result'      = @{ main = @( ,@( E 'Messages?' ) ) }
        'Messages?'         = @{ main = @( @( E 'Send messages' ), @() ) }
    }
    $wf = Build-Workflow 'core.sub_llm_probe' $nodes $conns
    # Laeuft alle 2 Minuten (meist ohne offene Pause): nur Fehler speichern.
    $wf.settings['saveDataSuccessExecution'] = 'none'
    return $wf
}
