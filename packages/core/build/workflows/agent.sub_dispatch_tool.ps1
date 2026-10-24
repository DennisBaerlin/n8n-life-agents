#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- agent.sub_dispatch_tool (Core-Vermittler zu Paket-WERKZEUGEN, paperless Phase 2) -----------
# WARUM: ein Nicht-Core-Paket (zuerst paperless) stellt Werkzeuge fuer FREMDE Agenten bereit (finance,
# finance_advisor, career_advisor, estate_advisor; docs/package-contract.md §5 Cross-package tool services).
# Der Konsument darf die Paket-Workflow-ID NIE literal tragen (workflow_lint-Naht; n8n wuerde ihn sonst ohne das
# Paket nicht aktivieren) -> er bindet NUR diesen Core-Sub (Build-Helper Add-ServiceTools), mit FESTEM
# service = '<pkg>:<alias>' + args (JSON-String aus den $fromAI-Feldern) + chat_id.
# Ablauf: Start -> Resolve service (core.fn_resolve_service = die EINE Pruefstelle: Service bekannt? Paket
#   nutzbar? Absender darf? -> workflow_id) -> erlaubt?
#   ja   -> Run tool (AUSDRUCKS-ID aus der DB = keine Aktivierungspruefung, Laufzeit-Lookup statt Build-ID)
#           -> Ensure result (Werkzeug-Ergebnis 1:1; fehlt ok -> {ok:false, error:'tool_failed'})
#   nein -> Not available: {ok:false, error, hint} — generischer Hinweis fuer das Modell (kein Paket-Literal).
# Geschwister (nicht Merge) von agent.sub_dispatch_agent: Werkzeuge tragen KEIN call_depth (Anti-Loop: Tools
# rufen nie Agenten) und liefern {ok,...}-Daten statt .output-Text. FAIL-CLOSED: ein DB-Fehler beim Pruefen
# verweigert (anders als der Agent-Vermittler — ein Werkzeug prueft nicht selbst nach).
function Build-AgentSubDispatchTool {
    $start = Build-Trigger @('service', 'args') @(-900, 300)

    $resolve = Build-Pg 'Resolve service' @(-680, 300) 'SELECT core.fn_resolve_service($1::jsonb) AS r;' ([ordered]@{
        service = "String(`$('Start').item.json.service || '')"
        chat_id = "String(`$('Start').item.json.chat_id || '')"
    })
    $resolve['onError'] = 'continueRegularOutput'

    $allowed = Build-If 'Allowed?' @(-460, 300) `
        "={{ !!(`$json.r && `$json.r.ok === true) }}" 'true' 'equals' 'boolean'

    $run = [ordered]@{
        parameters = [ordered]@{
            workflowId = [ordered]@{ __rl = $true; value = "={{ `$('Resolve service').item.json.r.workflow_id }}"; mode = 'id' }
            workflowInputs = [ordered]@{
                mappingMode = 'defineBelow'
                value = [ordered]@{
                    args    = "={{ String(`$('Start').item.json.args || '') }}"
                    chat_id = "={{ String(`$('Start').item.json.chat_id || '') }}"
                }
                matchingColumns = @(); schema = @(); attemptToConvertTypes = $false; convertFieldsToString = $true
            }
            options = [ordered]@{ waitForSubWorkflow = $true }
        }
        type = 'n8n-nodes-base.executeWorkflow'; typeVersion = 1.2; position = @(-220, 200)
        id = (New-Id); name = 'Run tool'; onError = 'continueRegularOutput'
    }

    $ensureJs = @'
// Werkzeug-Ergebnis unveraendert durchreichen ({ok:true|false, ...}). Kam KEIN ok-Feld (Laufzeitfehler im
// Paket-Werkzeug -> onError liefert {error}), einen strukturierten Fehler als DATEN liefern (kein Retry-Sturm).
const out = [];
for (const item of $input.all()) {
  const j = item.json || {};
  if (typeof j.ok === 'boolean') { out.push({ json: j }); continue; }
  out.push({ json: { ok: false, error: 'tool_failed',
    hint: 'The tool failed without a result. Retry at most once; if it fails again, tell the user it is currently not working.' } });
}
return out.length ? out : [{ json: { ok: false, error: 'tool_failed', hint: 'The tool returned nothing. Do not retry; tell the user it is currently not working.' } }];
'@
    $ensure = [ordered]@{
        parameters = [ordered]@{ jsCode = $ensureJs; mode = 'runOnceForAllItems' }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(0, 200); id = (New-Id); name = 'Ensure result'
    }

    # Ablehnung: generischer Modell-Hinweis aus error/reason/package_label (KEIN Paket-Literal im Core). Englisch
    # (Werkzeug-Ausgabe = Modell-Schicht); das Modell antwortet dem Nutzer in dessen Sprache.
    $denyJs = @'
const r = ($('Resolve service').first().json || {}).r || null;
const svc = String($('Start').first().json.service || '');
if (!r) {
  return [{ json: { ok: false, error: 'dispatch_unavailable',
    hint: 'The tool could not be checked right now. Do not retry; tell the user the feature is temporarily unavailable.' } }];
}
const label = r.package_label || r.package || svc.split(':')[0];
let hint;
if (r.error === 'package_unavailable') {
  const what = r.reason === 'inactive' ? 'is switched off'
             : r.reason === 'incomplete' ? 'is not completely installed'
             : 'is not installed';
  hint = 'The "' + label + '" feature ' + what + '. Do not retry. Tell the user it is currently not available.';
  if (r.is_owner) {
    const cmd = r.reason === 'inactive' ? 'lifeagents package activate ' : 'lifeagents package install ';
    hint += ' The owner can fix it on the server with: ' + cmd + r.package;
  }
} else if (r.error === 'not_permitted') {
  const who = r.reason === 'adults_only' ? 'only adult household members'
            : r.reason === 'owner_only' ? 'only the household owner'
            : 'only recognised household members';
  hint = 'This tool is not available to this person (' + who + ' may use it). Do not retry and do not try to get the information another way; tell the user politely.';
} else {
  hint = 'The tool "' + svc + '" is not registered on this installation. Do not retry; tell the user the feature is currently not available.';
}
return [{ json: { ok: false, error: r.error || 'unknown_service', reason: r.reason || null, hint } }];
'@
    $deny = [ordered]@{
        parameters = [ordered]@{ jsCode = $denyJs; mode = 'runOnceForAllItems' }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-220, 420); id = (New-Id); name = 'Not available'
    }

    $sticky = Build-Sticky 'Doc: Überblick' @(-900, -80) 'agent.sub_dispatch_tool — Core-Vermittler zu Paket-Werkzeugen' (@'
Fremde Agenten (finance, Advisor …) rufen Werkzeuge eines Nicht-Core-Pakets (z. B. paperless:search_documents) NUR hierueber — gebunden vom Build-Helper Add-ServiceTools. Grund: keine fremde Paket-Workflow-ID im Konsumenten (sonst aktiviert n8n ihn ohne das Paket nicht).

**Eingaben:** service ('<pkg>:<alias>', fest), args (JSON-String der Modell-Felder), chat_id.
**Pruefstelle (DB ist Gesetz):** core.fn_resolve_service — Service in core.services? Paket aktiv? Absender darf (permission je Service, z. B. adults_only; Identitaet aus chat_id, nie vom Modell)? -> workflow_id.
**Ja:** Run tool per AUSDRUCKS-ID (Laufzeit-Lookup) -> Ensure result (fehlt ok -> tool_failed).
**Nein:** Not available -> {ok:false, error, hint} mit generischem Hinweis (DB-Fehler = fail-closed).
**Anti-Loop:** Werkzeug-Pfad, kein call_depth; Geschwister von agent.sub_dispatch_agent.
'@) 300 560 'Ablauf'

    $nodes = @($start, $resolve, $allowed, $run, $ensure, $deny, $sticky)
    $conns = [ordered]@{
        'Start'           = @{ main = @( ,@( E 'Resolve service' ) ) }
        'Resolve service' = @{ main = @( ,@( E 'Allowed?' ) ) }
        'Allowed?'        = @{ main = @( @( E 'Run tool' ), @( E 'Not available' ) ) }
        'Run tool'        = @{ main = @( ,@( E 'Ensure result' ) ) }
    }
    return (Build-Workflow 'agent.sub_dispatch_tool' $nodes $conns)
}
