#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_list_monitor_triggers (CROSS-AGENT, READ-ONLY) ----------------
# Listet die bestehenden Monitor-Trigger EINER Domain (Label + Typ + Status + kompakte
# Spec-Zeile) ueber das publizierte Core-Lesefenster core.fn_list_monitor_triggers.
# Binder: agent.finance_advisor (domain FIX 'finance') — der Advisor liest sie beim
# Plan-Publish, um Dubletten zu vermeiden und nur NEUE Trigger vorzuschlagen.
# GENERISCH: jeder Fach-Advisor bindet dasselbe Tool mit seiner domain (fixer Binding-Input).
# KEIN HITL (reiner Read). Die fn ist SECURITY DEFINER (publiziertes Lesefenster fuer die <pkg>_ro-Rollen,
# D10) + Content-Guard (spec_summary nur aus typisierten Spalten, kein Freitext-Echo).
function Build-ListMonitorTriggers {
    $trig = Build-Trigger @('domain')

    # Ein Aufruf des publizierten Lesefensters -> aggregiertes JSON-Array (leer = []).
    $list = Build-Pg 'List triggers' @(220, 0) `
        "=SELECT COALESCE(jsonb_agg(jsonb_build_object('label', t.label, 'trigger_type', t.trigger_type, 'status', t.status, 'spec', t.spec_summary)), '[]'::jsonb) AS triggers, COUNT(*)::int AS count FROM core.fn_list_monitor_triggers((`$1::jsonb)->>'domain') AS t;" `
        ([ordered]@{ domain = '$(''Start'').item.json.domain' })

    $ret = Build-Return @(420, 0) @(
        ,@('count',    '={{ $json.count }}',    'number')
        ,@('triggers', '={{ $json.triggers }}', 'array')
    )

    $sticky = Build-Sticky 'Doc List Trigger' @(120, -240) `
        'Read-only: core.fn_list_monitor_triggers (publiziertes Lesefenster)' `
        'Cross-agent Read-Tool für das Dubletten-Bewusstsein des Advisors beim Plan-Publish. KEIN HITL, KEIN Write. domain ist fixer Binding-Input (je Fach-Advisor seine Domain). Die fn core.fn_list_monitor_triggers ist SECURITY DEFINER (publiziertes Lesefenster, D10 — agent.monitor_triggers ist für die enge Binder-Rolle gesperrt; EXECUTE an JEDE <pkg>_ro zentral via fn_provision_package_roles) und baut spec_summary AUSSCHLIESSLICH aus typisierten Spalten (acquisition_method/comparator/threshold/drawdown/due_date) — NIE aus acquisition_spec/action_note (kein Prompt-Injection-Echo). Nur status armed/fired (disabled für Dedup irrelevant). Rückgabe: { count, triggers[] }.' 260 520

    $nodes = @($trig, $list, $ret, $sticky)
    $conns = [ordered]@{
        'Start'         = @{ main = @( ,@( E 'List triggers' ) ) }
        'List triggers' = @{ main = @( ,@( E 'Return' ) ) }
    }
    return Build-Workflow 'agent.tool_list_monitor_triggers' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
