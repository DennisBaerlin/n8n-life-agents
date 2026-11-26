#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_propose_plan_topics (CROSS-AGENT, ohne Gate) --------------------------------------------------------
# Themen eines Plan-Teils als Karte der offenen Frage vorschlagen (Plan s4-berater-ux §5.2, Art topic). Ersetzt im Berater
# Vorlesen + "Ok" + Bestaetigungskarte: agent.fn_advisor_propose_topics prueft jedes Thema per Probelauf mit allen Gesetzen des
# Speicherns und legt die Karte(n) an (more_in_part: weitere Themen desselben Teils folgen); gespeichert wird erst beim Tipp [Übernehmen] (Karte und Wirkung aus derselben Zeile).
# Darum kein HITL-Gate: das Werkzeug aendert den Plan nicht. domain ist beim Aufrufer fixer Binding-Input (nie $fromAI),
# chat_id die Identitaet. Die Karte sendet der Orchestrator am Laufende (core.sub_send_chat_prompt).
function Build-ProposePlanTopics {
    $trig = Build-Trigger @('domain', 'section_key', 'topics', 'one_card', 'more_in_part')

    $S = "`$('Start').item.json"
    $run = Build-Pg 'Propose topics' @(220, 0) '=SELECT agent.fn_advisor_propose_topics($1::jsonb) AS r;' `
        ([ordered]@{
            domain      = "String($S.domain || '')"
            chat_id     = "String($S.chat_id || '')"
            section_key = "String($S.section_key || '')"
            topics      = "$S.topics"   # Array oder JSON-String; die fn prueft Form und Inhalt
            one_card    = "String($S.one_card === true || String($S.one_card).toLowerCase() === 'true')"
            # Weitere Themen desselben Teils folgen: nach dem letzten Tipp dieses Stapels bekommt der Berater den Auftrag, sie vorzuschlagen.
            more_in_part = "String($S.more_in_part === true || String($S.more_in_part).toLowerCase() === 'true')"
        })
    $ifOk = Build-If 'Proposed?' @(440, 0) '={{ ($json.r || {}).ok === true }}' 'true' 'equals' 'boolean'
    $ret = Build-Return @(660, -100) @(
        ,@('ok', 'true', 'boolean')
        ,@('cards', '={{ $json.r.cards }}', 'number')
        ,@('prompt_ids', '={{ $json.r.prompt_ids }}', 'array')
        ,@('deferred_entries', '={{ $json.r.deferred_entries || [] }}', 'array')
    )
    # Ablehnung als Daten (Code + Grund + Thema), der Berater korrigiert und ruft erneut; nichts wurde angelegt.
    $err = Build-ToolError 'Topics rejected' @(660, 100) `
        "={{ 'Not proposed (' + String((`$json.r || {}).code || 'error') + ')' + ((`$json.r || {}).topic_index ? ', topic ' + `$json.r.topic_index : '') + ': ' + String((`$json.r || {}).reason || '') }}"
    $sticky = Build-Sticky 'Doc Themen vorschlagen' @(120, -360) 'Themen als Karte vorschlagen (offene Frage, ohne Gate)' `
        'Propose topics ruft agent.fn_advisor_propose_topics: jedes Thema läuft als Probelauf durch agent.fn_advisor_save_section (Key, Länge, why, offene Punkte, Schriftzeichen, Aufgaben, Schreibrecht) und wird zurückgerollt; die erste Ablehnung kommt mit Code und Themen-Nummer zurück (Topics rejected), nichts wird angelegt. Sonst legt die fn je Thema eine Karte an (one_card: eine Karte für alle) und ersetzt offene oder wartende Themen-Karten desselben Beraters. Gespeichert wird erst beim Tipp [Übernehmen] (core.fn_answer_chat_prompt -> agent.fn_prompt_answer_topic), genau die Themen dieser Karte. Kein HITL-Gate, weil der Plan hier unverändert bleibt. Gesendet wird die Karte vom Orchestrator am Ende des Laufs (core.sub_send_chat_prompt); der Berater schreibt danach nichts mehr.' 340 360

    $nodes = @($trig, $run, $ifOk, $ret, $err, $sticky)
    $conns = [ordered]@{
        'Start'          = @{ main = @( ,@( E 'Propose topics' ) ) }
        'Propose topics' = @{ main = @( ,@( E 'Proposed?' ) ) }
        'Proposed?'      = @{ main = @( @( E 'Return' ), @( E 'Topics rejected' ) ) }
    }
    return Build-Workflow 'agent.tool_propose_plan_topics' $nodes $conns @{ Internal = $true }   # intern: Berater-Werkzeug, keine eigene Nutzer-Capability
}
