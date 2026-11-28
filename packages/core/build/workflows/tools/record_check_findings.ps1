#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_record_check_findings (CROSS-AGENT, ohne Gate) ------------------------------------------------------
# Schlussprüfung: der Berater liest den Entwurf einmal je Durchgang und legt alle echten Funde ab;
# die DB ergaenzt ihre eigenen Punkte (noch offen, Teil fehlt), baut den Stapel (Übersicht + je Punkt eine Karte) und führt
# Punkt für Punkt. Arbeitsnotiz, ändert den Plan nicht -> kein HITL-Gate (ein Vorschlag wird erst beim Tipp gespeichert).
# domain ist beim Aufrufer fixer Binding-Input, chat_id die Identitaet.
function Build-RecordCheckFindings {
    $trig = Build-Trigger @('domain', 'findings')

    $S = "`$('Start').item.json"
    $run = Build-Pg 'Record findings' @(220, 0) '=SELECT agent.fn_advisor_record_check_findings($1::jsonb) AS r;' `
        ([ordered]@{
            domain   = "String($S.domain || '')"
            chat_id  = "String($S.chat_id || '')"
            findings = "$S.findings"   # Array oder JSON-String; Zitate prueft die fn woertlich gegen das genannte Thema
        })
    $ifOk = Build-If 'Recorded?' @(440, 0) '={{ ($json.r || {}).ok === true }}' 'true' 'equals' 'boolean'
    $ret = Build-Return @(660, -100) @(
        ,@('ok', 'true', 'boolean')
        ,@('pass', '={{ $json.r.pass }}', 'number')
        ,@('last_pass', '={{ $json.r.last_pass }}', 'boolean')
        ,@('counts', '={{ $json.r.counts }}', 'object')
    )
    $err = Build-ToolError 'Findings rejected' @(660, 100) `
        "={{ 'Not recorded (' + String((`$json.r || {}).code || 'error') + ')' + (((`$json.r || {}).index !== undefined && (`$json.r || {}).index !== null) ? ', finding ' + `$json.r.index : '') + ': ' + String((`$json.r || {}).reason || '') }}"
    $sticky = Build-Sticky 'Doc Schlussprüfung' @(120, -360) 'Funde der Schlussprüfung ablegen (offene Frage, ohne Gate)' `
        'Record findings ruft agent.fn_advisor_record_check_findings: prüft jeden Fund (Zitat wörtlich im genannten Thema, Vorschlag per Probelauf wie ein Thema), ergänzt die eigenen Punkte der DB (noch offene Punkte, fehlende Teile) und legt den Stapel an: erst die Übersicht (Abschluss in drei Schritten, Knöpfe Los/Pause), dann je Punkt eine Karte. Höchstens advisor.check_max_passes Durchgänge (Config), der letzte heißt letzter Durchgang. Ablehnung als Daten mit Code (quote_not_found, invalid_finding, proposal_rejected, check_passes_exhausted, no_draft), nichts angelegt. Kein HITL-Gate: der Plan ändert sich erst beim Tipp auf einen Vorschlag. Senden macht der Orchestrator am Laufende.' 340 340

    $nodes = @($trig, $run, $ifOk, $ret, $err, $sticky)
    $conns = [ordered]@{
        'Start'           = @{ main = @( ,@( E 'Record findings' ) ) }
        'Record findings' = @{ main = @( ,@( E 'Recorded?' ) ) }
        'Recorded?'       = @{ main = @( @( E 'Return' ), @( E 'Findings rejected' ) ) }
    }
    return Build-Workflow 'agent.tool_record_check_findings' $nodes $conns @{ Internal = $true }   # intern: Berater-Werkzeug
}
