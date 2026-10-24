#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- agent.sub_dispatch_agent (Core-Vermittler zu Paket-Agenten, Install-UX-Phase 4) ------------
# WARUM: der Core-Verteiler (agent.orchestrator.main_route) rief Paket-Agenten (finance, career, estate …)
# mit FEST eingetragener Workflow-ID. n8n (geprueft 2.21.7 + 2.44.4) aktiviert einen Workflow nur, wenn jedes LITERAL
# referenzierte Execute-Workflow-Ziel existiert + published ist (workflow-validation.service.ts) -> ohne
# installierte Pakete blieb der Bot taub, und `package uninstall` + Neustart brach ihn. Der Verteiler ruft
# Paket-Agenten jetzt NUR noch ueber diesen Core-Sub: Ziel-ID und Paket bekommt er vom Aufrufer
# als FESTE Build-Zeit-Eingaben (Get-WorkflowIdByName wie bisher), der eigentliche Aufruf nutzt eine
# AUSDRUCKS-ID (n8n ueberspringt sie bei der Aktivierungspruefung; zur Laufzeit muss das Ziel published sein —
# genau dann, wenn das Paket installiert ist).
# Ablauf: Start -> Package status (core.fn_package_status) -> nutzbar?
#   ja   -> Run agent (Ausdrucks-ID, wartet auf den Agenten) -> Ensure output (Agent-Ergebnis 1:1; nur ein
#           fehlendes output — z. B. das Eingangs-Gate des Agenten {ok:false,error} oder ein Laufzeitfehler —
#           wird durch einen freundlichen Text ergaenzt, die Relays lesen .output)
#   nein -> Not available: Owner bekommt den CLI-Hinweis (install/activate), Mitglieder "nicht verfuegbar".
#   thinking='loop' (Paket-Befehle/-Onboarding-Tipps): eigene "Bot denkt nach"-Schleife um Run agent (Schalter
#           agent.thinking_lease, vor der Rueckgabe geloescht); der KI-Weg laesst thinking leer.
# Anti-Loop: Orchestrator -> Vermittler (Sub, KEIN Agent) -> Agent -> Tool -> Gate; call_depth wird nur
# durchgereicht (das Depth-Gate sitzt weiter am Agent-Eingang). DB-Fehler beim Status-Lesen = fail-open
# (der Agent prueft am Eingang selbst noch einmal fn_package_active).
# Textkatalog Phase B: der Anzeigename des Pakets (<pkg>.package.name) und die Hinweise (core.dispatch.*) kommen zur
# Laufzeit in der Sprache des Absenders (chat_id -> Person -> agent.fn_person_lang; unbekannt -> Owner-Sprache) — der
# Aufrufer reicht nur noch die Paket-id durch (kein build-time deutscher Anzeigename mehr).
function Build-AgentSubDispatchAgent {
    $start = Build-Trigger @('workflow_id', 'package', 'task', 'call_depth', 'thinking') @(-900, 300)

    $dispatchKeys = @('core.dispatch.no_answer', 'core.dispatch.unavailable', 'core.dispatch.inactive',
                      'core.dispatch.incomplete', 'core.dispatch.not_installed')
    $status = Build-Pg 'Package status' @(-680, 300) `
        ("SELECT core.fn_package_status(`$1::jsonb) AS r, core.fn_ui_texts(y.lang, $(Get-UiKeysSql $dispatchKeys)) AS t, " +
         "COALESCE(NULLIF(core.fn_ui_text((`$1::jsonb)->>'package' || '.package.name', y.lang), (`$1::jsonb)->>'package' || '.package.name'), (`$1::jsonb)->>'package') AS pkg_name " +
         "FROM (SELECT agent.fn_person_lang(agent.fn_resolve_sender(CASE WHEN (`$1::jsonb)->>'chat_id' ~ '^[0-9]{1,18}$' " +
         "THEN ((`$1::jsonb)->>'chat_id')::bigint END)->>'person_id')->>'lang' AS lang) y;") ([ordered]@{
        package = "`$('Start').item.json.package"
        chat_id = "String(`$('Start').item.json.chat_id || '')"
    })
    $status['onError'] = 'continueRegularOutput'

    $usable = Build-If 'Package usable?' @(-460, 300) `
        "={{ !`$json.r || `$json.r.ok === true }}" 'true' 'equals' 'boolean'

    $run = [ordered]@{
        parameters = [ordered]@{
            workflowId = [ordered]@{ __rl = $true; value = "={{ `$('Start').item.json.workflow_id }}"; mode = 'id' }
            workflowInputs = [ordered]@{
                mappingMode = 'defineBelow'
                value = [ordered]@{
                    task       = "={{ `$('Start').item.json.task }}"
                    chat_id    = "={{ String(`$('Start').item.json.chat_id || '') }}"
                    call_depth = "={{ String(`$('Start').item.json.call_depth || '1') }}"
                }
                matchingColumns = @(); schema = @(); attemptToConvertTypes = $false; convertFieldsToString = $true
            }
            options = [ordered]@{ waitForSubWorkflow = $true }
        }
        type = 'n8n-nodes-base.executeWorkflow'; typeVersion = 1.2; position = @(-220, 200)
        id = (New-Id); name = 'Run agent'; onError = 'continueRegularOutput'
    }

    # "Bot denkt nach ..." NUR fuer Aufrufer ohne eigene Anzeige (thinking='loop': Paket-Befehle, Paket-Onboarding-Tipps
    # im Orchestrator). Der KI-Weg (Router-Tool) hat schon die Schleife des Orchestrator-Laufs -> hier nichts.
    # Schalter (agent.thinking_lease, dieser Lauf) synchron anlegen -> core.sub_show_thinking (fire-and-forget) erneuert
    # bis 'Close thinking lease' ihn VOR der Rueckgabe loescht (die Antwort sendet der Aufrufer erst danach). Der Zweig
    # haengt hoeher als 'Run agent' -> v1 fuehrt ihn zuerst aus. Nur private Chats (positive chat_id).
    $thinkingGate = Build-If 'Thinking private?' @(-300, 20) `
        "={{ (Number(`$('Start').item.json.chat_id) || 0) > 0 && `$('Start').item.json.thinking === 'loop' }}" 'true' 'equals' 'boolean'
    $openThinking = Build-Pg 'Open thinking lease' @(-100, 20) "SELECT agent.fn_create_thinking_lease(`$1::jsonb) AS r;" ([ordered]@{
        chat_id      = "String(`$('Start').first().json.chat_id || '')"
        execution_id = "`$execution.id"
        ttl_minutes  = '15'
    })
    $openThinking['onError'] = 'continueRegularOutput'
    $thinking = New-ShowThinkingCallNode 'Show thinking' @(120, 20) "={{ String(`$('Start').first().json.chat_id || '') }}" -ExecutionIdExpr '={{ $execution.id }}'
    # Vor der Rueckgabe (= vor der Antwort des Aufrufers): Schalter loeschen + ein evtl. laufendes Draft-Fenster abwarten.
    # Ohne Schalter (KI-Weg) ein No-op. onError continue.
    $closeThinking = Build-Pg 'Close thinking lease' @(-20, 200) "SELECT agent.fn_delete_thinking_lease(`$1::jsonb) AS r;" ([ordered]@{
        execution_id   = "`$execution.id"
        wait_for_draft = 'true'
    })
    $closeThinking['onError'] = 'continueRegularOutput'

    $ensureJs = @'
// Agent-Ergebnis unveraendert durchreichen. Nur wenn KEIN Text (output) kam — Eingangs-Gate des Agenten
// ({ok:false,error}), Laufzeitfehler (onError -> {error}) — einen freundlichen Text ergaenzen, damit der
// Telegram-Relay (liest .output) und das Router-Modell nie leer ausgehen.
// Der Text kommt aus dem Textkatalog (core.dispatch.no_answer, Sprache des Absenders, geladen in 'Package status').
// Ergebnis aus 'Run agent' selbst (davor liegt 'Close thinking lease', dessen Ausgabe die DB-Antwort ist).
const T = ($('Package status').first().json || {}).t || {};
const NO_ANSWER = T['core.dispatch.no_answer'] || 'core.dispatch.no_answer';
const out = [];
for (const item of $('Run agent').all()) {
  const j = item.json || {};
  if (typeof j.output === 'string' && j.output.trim() !== '') { out.push({ json: j }); continue; }
  out.push({ json: Object.assign({}, j, { output: NO_ANSWER }) });
}
return out.length ? out : [{ json: { output: NO_ANSWER } }];
'@
    $ensure = [ordered]@{
        parameters = [ordered]@{ jsCode = $ensureJs; mode = 'runOnceForAllItems' }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(180, 200); id = (New-Id); name = 'Ensure output'
    }

    $msgExpr = @'
={{ (() => {
  const s = $('Package status').item.json || {};
  const r = s.r || {};
  const T = s.t || {};
  const pkg = $('Start').item.json.package;
  const name = s.pkg_name || pkg;
  const k = !r.is_owner ? 'core.dispatch.unavailable' : (r.reason === 'inactive' ? 'core.dispatch.inactive' : (r.reason === 'incomplete' ? 'core.dispatch.incomplete' : 'core.dispatch.not_installed'));
  return String(T[k] || k).split('{name}').join(name).split('{package}').join(pkg);
})() }}
'@
    $notAvail = Build-Set 'Not available' @(-220, 420) @(
        ,@('ok', 'false', 'boolean')
        ,@('error', "={{ (`$('Package status').item.json.r || {}).reason || 'unavailable' }}", 'string')
        ,@('output', $msgExpr.Trim(), 'string')
    )

    $sticky = Build-Sticky 'Doc: Überblick' @(-900, -60) 'agent.sub_dispatch_agent — Core-Vermittler zu Paket-Agenten' (@'
Der Verteiler (agent.orchestrator.main_route) ruft Paket-Agenten NUR hierueber. Grund: n8n aktiviert einen Workflow nur, wenn alle FEST eingetragenen Execute-Workflow-Ziele existieren -> ohne installiertes Paket war der Bot taub.

**Eingaben (fest vom Aufrufer, Build-Zeit):** workflow_id, package + task, chat_id, call_depth, thinking ('loop' = Paket-Befehle/-Onboarding-Tipps ohne eigene Anzeige; leer = KI-Weg, dort zeigt der Orchestrator die Anzeige). Anzeigename + Hinweise aus dem Textkatalog in der Sprache des Absenders (Package status).
**Ablauf:** core.fn_package_status -> aktiv? [thinking='loop' + privater Chat: Open thinking lease (agent.thinking_lease) -> Show thinking (core.sub_show_thinking, fire-and-forget, Erneuerung alle 5 s)] + Run agent (AUSDRUCKS-ID = keine Aktivierungspruefung) -> Close thinking lease (Schalter weg + Draft-Fenster abwarten, VOR der Rückgabe = vor der Antwort; ohne Schalter No-op) -> Ensure output. Sonst Not available: Owner sieht `lifeagents package install|activate <pkg>`, Mitglieder "nicht verfügbar".
**Rueckgabe:** immer ein Item mit .output (Relays + Router-Modell lesen es).
**Anti-Loop:** Sub, kein Agent; call_depth nur durchgereicht. Naht-Lint: kein Core-Workflow traegt eine literale Paket-Workflow-ID.
'@) 300 520 'Ablauf'

    $nodes = @($start, $status, $usable, $thinkingGate, $openThinking, $thinking, $run, $closeThinking, $ensure, $notAvail, $sticky)
    $conns = [ordered]@{
        'Start'               = @{ main = @( ,@( E 'Package status' ) ) }
        'Package status'      = @{ main = @( ,@( E 'Package usable?' ) ) }
        'Package usable?'     = @{ main = @( @( (E 'Thinking private?'), (E 'Run agent') ), @( E 'Not available' ) ) }
        'Thinking private?'   = @{ main = @( ,@( E 'Open thinking lease' ) ) }   # [0] Schleife; [1] KI-Weg/Gruppe -> nichts
        'Open thinking lease' = @{ main = @( ,@( E 'Show thinking' ) ) }
        'Run agent'           = @{ main = @( ,@( E 'Close thinking lease' ) ) }
        'Close thinking lease' = @{ main = @( ,@( E 'Ensure output' ) ) }
    }
    return (Build-Workflow 'agent.sub_dispatch_agent' $nodes $conns)
}
