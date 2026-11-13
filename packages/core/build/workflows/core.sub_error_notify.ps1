#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_error_notify (globale Fehler-Sicherheitsleine) ----------------
# Jeder Prod-Workflow zeigt per settings.errorWorkflow auf diesen Sub; Build-Workflow loest dessen id
# per Name aus dem State auf ($ErrorNotifyId, kein ID-Literal). Eingang ist ein n8n errorTrigger (feuert NUR
# bei echten Fehlern automatischer Executions, nicht via executeWorkflow ansteuerbar).
#
# Eigenheiten (inline konstruiert, Einzelfall, keine Lib-Helper):
#   * settings haben bewusst kein errorWorkflow (self-reference = Endlos-Alert-Schleife).
#   * Der Telegram-Send escapt den Text nicht selbst (Allowlist in workflow_lint.ps1:
#     'core.sub_error_notify :: Send Telegram Alert'); das Escaping passiert upstream im
#     Format-Message-Code-Node (.replace der 4 Legacy-Markdown-Entities). Daher kein
#     New-TelegramSendNode (der wuerde doppelt escapen). Node-Name 'Send Telegram Alert' ist Pflicht
#     (workflow_lint-Allowlist + Verdrahtungs-Check).
#   * Format Message filtert Harness-getriggerte Executions (Root-Trigger 'Test Webhook') -> alerten
#     nie (sonst loesten Suite-Timeout-Stopps Owner-Alerts aus).
function Build-CoreSubErrorNotify {
    $onError = [ordered]@{
        parameters  = @{}
        type        = 'n8n-nodes-base.errorTrigger'
        typeVersion = 1
        position    = @(0, 0)
        id          = (New-Id)
        name        = 'On Error'
    }

    # Textkatalog: die Alarm-Texte in Owner-Sprache + Owner-Locale (core.fn_ui_texts_for). Die Sicherheitsleine
    # haengt nie an der DB: onError=continue, alwaysOutputData, kein Retry (ein toter DB-Server darf den Alarm nicht
    # verzoegern) -> Format Message faellt dann auf englische Ersatztexte zurueck (bewusste Ausnahme vom Katalog).
    $loadTexts = Build-Pg 'Load alert texts' @(110, 160) `
        ("SELECT core.fn_ui_texts_for(jsonb_build_object('keys', to_jsonb(" + (Get-UiKeysSql @(
            'core.error.title', 'core.error.workflow', 'core.error.node', 'core.error.error', 'core.error.time',
            'core.error.unknown')) + "))) AS r;")
    $loadTexts['onError'] = 'continueRegularOutput'
    $loadTexts['alwaysOutputData'] = $true

    # __WARN__ -> echtes Warn-Emoji (U+26A0 U+FE0F); kein Emoji-Literal im .ps1 (PS-5.1-Encoding-Falle).
    $fmtJs = @'
// Texte aus 'Load alert texts' (Owner-Sprache); DB weg/Fehler -> englische Ersatztexte (der Alarm geht immer raus).
let ui = {};
try { ui = ($('Load alert texts').first().json || {}).r || {}; } catch (e) { ui = {}; }
const T = ui.t || {};
const EN = { 'core.error.title': 'n8n error', 'core.error.workflow': 'Workflow', 'core.error.node': 'Node',
  'core.error.error': 'Error', 'core.error.time': 'Time', 'core.error.unknown': 'Unknown error' };
const t = (k) => (T[k] && T[k] !== k) ? T[k] : EN[k];
const loc = ui.locale || 'en-GB';
const out = [];
for (const item of $('On Error').all()) {
  const e = item.json.execution;
  const w = item.json.workflow;
  // Suite-Rauschen unterdruecken: Harness-getriggerte Executions (Root-Trigger = Test Webhook)
  // alerten nie -- die Test-Skripte berichten Fehler/Timeout-Stopps selbst.
  const trig = e && e.executionContext && e.executionContext.triggerNode;
  if (trig && trig.type === 'n8n-nodes-base.webhook' && trig.name === 'Test Webhook') continue;
  let ts;
  try { ts = new Date().toLocaleString(loc, { timeZone: $now.zoneName }); } catch (x) { ts = new Date().toISOString(); }
  const lines = [
    '__WARN__ ' + t('core.error.title'), '',
    t('core.error.workflow') + ': ' + w.name,
    t('core.error.node') + ': ' + (e.lastNodeExecuted || '?'),
    t('core.error.error') + ': ' + ((e.error && e.error.message) || t('core.error.unknown')),
    t('core.error.time') + ': ' + ts
  ];
  if (e.url) lines.push(e.url);
  out.push({ json: { text: lines.join(String.fromCharCode(10)).replace(/[_*`[]/g, '\\$&') } });
}
return out;
'@
    $warn  = ([string][char]0x26A0 + [string][char]0xFE0F)
    $fmtJs = $fmtJs.Replace('__WARN__', $warn)
    $format = [ordered]@{
        parameters  = [ordered]@{ jsCode = $fmtJs; mode = 'runOnceForAllItems' }
        type        = 'n8n-nodes-base.code'
        typeVersion = 2
        position    = @(220, 0)
        id          = (New-Id)
        name        = 'Format Message'
    }

    # Inline (nicht New-TelegramSendNode): Text wird nicht escapt (Format Message escapt upstream).
    # chatId = Platzhalter -> deploy_workflows.sh re-injiziert die echte Owner-chat_id.
    $send = [ordered]@{
        parameters  = [ordered]@{
            additionalFields = [ordered]@{ appendAttribution = $false }
            chatId           = '__OWNER_CHAT_ID__'
            text             = "={{ `$json.text }}"
        }
        type        = 'n8n-nodes-base.telegram'
        typeVersion = 1.2
        position    = @(440, 0)
        id          = (New-Id)
        name        = 'Send Telegram Alert'
        retryOnFail = $true
        maxTries    = 3
        waitBetweenTries = 2000
        webhookId   = (New-Id)
        credentials = @{ telegramApi = $CRED_TELEGRAM }
    }

    $stickyOverview = Build-Sticky 'Doc: Überblick' @(-240, -380) -Header 'Ablauf' `
        'core.sub_error_notify' `
        ("Globaler Fehler-Notifier: n8n ruft ihn automatisch, wenn ein Workflow mit settings.errorWorkflow auf ihn fällt (nur automatische Executions, nicht manuelle Tests im Editor).`n`n" +
         "On Error (Error Trigger) -> Load alert texts (Owner-Sprache, core.fn_ui_texts_for; onError continue, kein Retry) -> Format Message (Texte aus dem Katalog, Zeit im Owner-Locale; DB weg -> englische Ersatztexte, der Alarm geht immer raus) -> Send Telegram Alert (an den Owner-Chat). Zweiter Ast: Clear card lock (Karte-offen-Sperre eines gescheiterten Gate-Laufs löschen). Erster Ast (liegt höher, läuft vor dem Alarm): Clear thinking lease (Schalter der 'Bot denkt nach'-Schleife eines gescheiterten Orchestrator-Laufs löschen, agent.fn_delete_thinking_lease).`n`n" +
         "Genutzte Felder des Error Triggers: execution.error.message, execution.lastNodeExecuted, execution.url (optional), workflow.name.") `
        -Height 360 -Width 500

    $stickyFormat = Build-Sticky 'Doc: Format' @(220, -280) -Header 'Ablauf' `
        'Format Message' `
        ("Baut den Alarm-Text aus den Error-Trigger-Daten (Zeilen: Titel, Workflow, Node, Fehler, Zeit, optional Link; Beschriftungen aus dem Katalog in der Owner-Sprache).`n" +
         "Der Send hat kein parse_mode, Telegram liest also Legacy-Markdown: Format Message escapt darum die vier Entities (Unterstrich, Stern, Backtick, eckige Klammer auf) per Backslash (der Send escapt nicht selbst). Harness-getriggerte Läufe (Root-Trigger 'Test Webhook') alerten nie.") `
        -Height 240 -Width 400

    # Karte-offen-Sperre: scheitert ein Gate-Lauf (z. B. Telegram-Send), laeuft dessen 'Close pending' nie ->
    # die Zeile in agent.hitl_pending dieser Execution hier sofort freigeben (Gnadenfrist 0; sonst sperrt ein Hinweis auf
    # eine nicht existierende Karte den Chat bis zur TTL). Leerer/fremder Lauf = no-op in der fn. Zweiter Ast nach dem
    # Alarm (v1-Reihenfolge), onError=continue: die Sicherheitsleine haengt nie an diesem Schritt.
    $clearLock = Build-Pg 'Clear card lock' @(110, 320) `
        "=SELECT agent.fn_set_hitl_pending_released(`$1::jsonb) AS r;" `
        ([ordered]@{ execution_id = 'String(($(''On Error'').first().json.execution || {}).id || '''')'; grace_minutes = '0' })
    $clearLock['onError'] = 'continueRegularOutput'

    $stickyLock = Build-Sticky 'Doc: Clear card lock' @(-240, 260) -Header 'Ablauf' `
        'Clear card lock' `
        "Scheitert ein Lauf des HITL-Gates (agent.tool_human_approval), bleibt seine Zeile in agent.hitl_pending (Karte-offen-Sperre) liegen, weil 'Close pending' nie läuft. Dieser Ast gibt sie per execution.id sofort frei (agent.fn_set_hitl_pending_released, Gnadenfrist 0). Läuft NACH dem Alarm, onError continue; fremde Workflows = no-op. Backstop bleibt die TTL (expires_at)." `
        -Height 200 -Width 400

    # "Bot denkt nach"-Schalter (agent.thinking_lease): scheitert ein Orchestrator-Lauf, loescht ihn niemand vor einer
    # Antwort -> die Draft-Schleife (core.sub_show_thinking) zeigte bis zur TTL "Thinking..." ohne Antwort. Hier per
    # execution.id loeschen (ohne Warten; fremde Workflows = no-op). Liegt HOEHER als der Alarm-Ast -> laeuft (v1) VOR
    # dem Telegram-Alarm, der sporadisch Minuten haengt. onError=continue.
    $clearThinking = Build-Pg 'Clear thinking lease' @(110, -140) `
        "=SELECT agent.fn_delete_thinking_lease(`$1::jsonb) AS r;" `
        ([ordered]@{ execution_id = 'String(($(''On Error'').first().json.execution || {}).id || '''')' })
    $clearThinking['onError'] = 'continueRegularOutput'

    $nodes = @($onError, $loadTexts, $format, $send, $clearLock, $clearThinking, $stickyOverview, $stickyFormat, $stickyLock)
    $conns = [ordered]@{
        # Ausfuehrungs-Reihenfolge (v1) folgt der Leinwand-Position, nicht dieser Liste: Clear thinking lease (oben) zuerst.
        'On Error'         = @{ main = @( ,@( (E 'Load alert texts'), (E 'Clear card lock'), (E 'Clear thinking lease') ) ) }
        'Load alert texts' = @{ main = @( ,@( E 'Format Message' ) ) }
        'Format Message' = @{ main = @( ,@( E 'Send Telegram Alert' ) ) }
    }

    $wf = Build-Workflow 'core.sub_error_notify' $nodes $conns
    # Kein errorWorkflow (sonst Endlos-Alert-Schleife); nur executionOrder.
    $wf.settings = [ordered]@{ executionOrder = 'v1' }
    return $wf
}
