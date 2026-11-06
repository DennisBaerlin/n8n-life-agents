#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_error_notify (globale Fehler-Sicherheitsleine) ----------------
# Jeder Prod-Workflow zeigt per settings.errorWorkflow auf diesen Sub; Build-Workflow loest dessen id
# per Name aus dem State auf ($ErrorNotifyId, kein ID-Literal). Eingang ist ein n8n errorTrigger (feuert NUR
# bei echten Fehlern automatischer Executions, nicht via executeWorkflow ansteuerbar). Loest die
# fruehere scripts/build/sync_error_notify.ps1 ab (geloescht 2026-06-17) -> jetzt voll build-generiert.
#
# Eigenheiten (inline konstruiert, Einzelfall — KEINE Lib-Helper):
#   * settings haben BEWUSST KEIN errorWorkflow (self-reference = Endlos-Alert-Schleife).
#   * Der Telegram-Send escapt den Text NICHT selbst (Allowlist in workflow_lint.ps1:
#     'core.sub_error_notify :: Send Telegram Alert') — das Escaping passiert UPSTREAM im
#     Format-Message-Code-Node (.replace der 4 Legacy-Markdown-Entities). Daher KEIN
#     New-TelegramSendNode (der wuerde doppelt escapen). Node-Name 'Send Telegram Alert' ist Pflicht
#     (workflow_lint-Allowlist + Verdrahtungs-Check).
#   * Format Message filtert Harness-getriggerte Executions (Root-Trigger 'Test Webhook') -> alerten
#     nie (Suite-Timeout-Stopps feuerten sonst Owner-Alerts, 2026-06-12).
function Build-CoreSubErrorNotify {
    $onError = [ordered]@{
        parameters  = @{}
        type        = 'n8n-nodes-base.errorTrigger'
        typeVersion = 1
        position    = @(0, 0)
        id          = (New-Id)
        name        = 'On Error'
    }

    # Textkatalog Phase C: die Alarm-Texte in Owner-Sprache + Owner-Locale (core.fn_ui_texts_for). Die Sicherheitsleine
    # haengt NIE an der DB: onError=continue, alwaysOutputData, KEIN Retry (ein toter DB-Server darf den Alarm nicht
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

    # Inline (NICHT New-TelegramSendNode): Text wird NICHT escapt (Format Message escapt upstream).
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

    $stickyOverview = [ordered]@{
        parameters  = [ordered]@{
            content = @'
## core.sub_error_notify

Globaler Fehler-Notifier. Wird von n8n automatisch aufgerufen wenn ein verlinkter Workflow faellt (settings.errorWorkflow in den Workflow-Einstellungen).

**Ablauf:** On Error (Error Trigger) -> Load alert texts (Owner-Sprache, core.fn_ui_texts_for; onError continue, kein Retry) -> Format Message (Texte aus dem Katalog, Zeit im Owner-Locale; DB weg -> englische Ersatztexte, der Alarm geht immer raus) -> Send Telegram Alert (an Owner-Chat). Zweiter Ast: Clear card lock (Karte-offen-Sperre eines gescheiterten Gate-Laufs loeschen). Erster Ast (liegt hoeher, laeuft vor dem Alarm): Clear thinking lease (Schalter der "Bot denkt nach"-Schleife eines gescheiterten Orchestrator-Laufs loeschen, agent.fn_delete_thinking_lease).

**Empfangene Daten (n8n Error Trigger):**
- execution.error.message - Fehlermeldung
- execution.lastNodeExecuted - letzter Node vor dem Fehler
- execution.url - Execution-Link (optional)
- workflow.name - Name des fehlgeschlagenen Workflows

**Einschraenkung:** Feuert nur bei automatischen Executions - nicht bei manuellen Tests im n8n-Editor.
'@
            height  = 360
            width   = 500
            color   = 4
        }
        type        = 'n8n-nodes-base.stickyNote'
        typeVersion = 1
        position    = @(-240, -380)
        id          = (New-Id)
        name        = 'Doc: Überblick'
    }

    $stickyFormat = [ordered]@{
        parameters  = [ordered]@{
            content = (@'
## Format Message

Baut plain-text Telegram-Nachricht aus den Error-Trigger-Daten.
Kein Markdown (Telegram rendert sonst inkonsistent bei Sonderzeichen).

Beispiel-Output:
__WARN__ n8n Fehler

Workflow: agent.monitor
Node: Monitor Agent
Fehler: connection refused
Zeit: 05.06.2026, 14:23:01
https://n8n.example.com/...
'@).Replace('__WARN__', $warn)
            height  = 240
            width   = 400
            color   = 4
        }
        type        = 'n8n-nodes-base.stickyNote'
        typeVersion = 1
        position    = @(220, -280)
        id          = (New-Id)
        name        = 'Doc: Format'
    }

    # Karte-offen-Sperre (Fix C): scheitert ein Gate-Lauf (z. B. Telegram-Send), laeuft dessen 'Close pending' nie ->
    # die Zeile in agent.hitl_pending dieser Execution hier sofort freigeben (Gnadenfrist 0; sonst sperrt ein Hinweis auf
    # eine NICHT existierende Karte den Chat bis zur TTL). Leerer/fremder Lauf = no-op in der fn. Zweiter Ast NACH dem
    # Alarm (v1-Reihenfolge), onError=continue: die Sicherheitsleine haengt nie an diesem Schritt.
    $clearLock = Build-Pg 'Clear card lock' @(110, 320) `
        "=SELECT agent.fn_set_hitl_pending_released(`$1::jsonb) AS r;" `
        ([ordered]@{ execution_id = 'String(($(''On Error'').first().json.execution || {}).id || '''')'; grace_minutes = '0' })
    $clearLock['onError'] = 'continueRegularOutput'

    $stickyLock = [ordered]@{
        parameters  = [ordered]@{
            content = @'
## Clear card lock

Scheitert ein Lauf des HITL-Gates (agent.tool_human_approval), bleibt seine Zeile in agent.hitl_pending (Karte-offen-Sperre) liegen, weil 'Close pending' nie laeuft. Dieser Ast gibt sie per execution.id sofort frei (agent.fn_set_hitl_pending_released, Gnadenfrist 0). Laeuft NACH dem Alarm, onError continue; fremde Workflows = no-op. Backstop bleibt die TTL (expires_at).
'@
            height  = 200
            width   = 400
            color   = 4
        }
        type        = 'n8n-nodes-base.stickyNote'
        typeVersion = 1
        position    = @(-240, 260)
        id          = (New-Id)
        name        = 'Doc: Clear card lock'
    }

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
    # KEIN errorWorkflow (sonst Endlos-Alert-Schleife); nur executionOrder.
    $wf.settings = [ordered]@{ executionOrder = 'v1' }
    return $wf
}
