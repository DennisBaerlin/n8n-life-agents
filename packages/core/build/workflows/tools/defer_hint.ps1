#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_defer_hint (CROSS-AGENT, ohne Gate) -----------------------------------------------------------------
# "Bitte nicht mehr danach fragen": der Berater legt einen Kontohinweis still, statt ihn im Gespraech
# zu wiederholen. agent.fn_advisor_defer_hint setzt den Merker "spaeter" (core.notification_state, 30 Tage bzw. bis sich der
# Hinweis in den Daten erledigt); stillgelegte Hinweise liefert der Snapshot nicht mehr. Kein Gate: es aendert keine Daten des
# Nutzers, nur ob ein Hinweis noch angesprochen wird. domain ist fixer Binding-Input, key kommt aus warnings[].key.
function Build-DeferHint {
    $trig = Build-Trigger @('domain', 'key')

    $S = "`$('Start').item.json"
    $run = Build-Pg 'Defer hint' @(220, 0) '=SELECT agent.fn_advisor_defer_hint($1::jsonb) AS r;' `
        ([ordered]@{
            domain  = "String($S.domain || '')"
            chat_id = "String($S.chat_id || '')"
            key     = "String($S.key || '')"
        })
    $ifOk = Build-If 'Deferred?' @(440, 0) '={{ ($json.r || {}).ok === true }}' 'true' 'equals' 'boolean'
    $ret = Build-Return @(660, -100) @(
        ,@('ok', 'true', 'boolean')
        ,@('key', '={{ $json.r.key }}', 'string')
    )
    # unknown_hint nennt die gueltigen Keys, damit der Berater den richtigen waehlt.
    $err = Build-ToolError 'Hint not deferred' @(660, 100) `
        "={{ 'Not deferred (' + String((`$json.r || {}).code || 'error') + ')' + (((`$json.r || {}).keys || []).length ? ', known keys: ' + `$json.r.keys.join(', ') : '') }}"
    $sticky = Build-Sticky 'Doc Hinweis später' @(120, -340) 'Kontohinweis stilllegen (ohne Gate)' `
        'Defer hint ruft agent.fn_advisor_defer_hint: prüft Schreibrecht am Plan und dass es den Hinweis gibt, und setzt den Merker später (core.notification_state, Quelle advisor_hint, 30 Tage oder bis sich der Hinweis in den Daten erledigt). Danach liefert der Snapshot den Hinweis nicht mehr, der Berater spricht ihn nicht wieder an. Derselbe Merker entsteht beim Knopf [Später] auf einer Hinweis-Karte. Ablehnung als Daten (unknown_hint mit den bekannten Keys, no_permission, invalid_input). Kein Gate: es ändert keine Daten des Nutzers.' 320 300

    $nodes = @($trig, $run, $ifOk, $ret, $err, $sticky)
    $conns = [ordered]@{
        'Start'      = @{ main = @( ,@( E 'Defer hint' ) ) }
        'Defer hint' = @{ main = @( ,@( E 'Deferred?' ) ) }
        'Deferred?'  = @{ main = @( @( E 'Return' ), @( E 'Hint not deferred' ) ) }
    }
    return Build-Workflow 'agent.tool_defer_hint' $nodes $conns @{ Internal = $true }   # intern: Berater-Werkzeug
}