#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_set_onboarding_section (WS-1 estate, Plan groovy-watching-wave) ------
# Estate-Onboarding-Fortschritts-Marker: setzt EINE estate-Sektion auf completed/skipped/unknown.
# Spiegel des Finance-Tools (agent.finance.tool_set_onboarding_section, household-Form), aber
# package='estate' -> schreibt estate.onboarding_state ueber die Core-generische Schnittstelle
# core.fn_set_onboarding_section. KEIN HITL (kein Domaenen-/PII-Write, nur ein Status-Flag) ->
# ruft KEIN Gate -> KEIN approval_matrix-Eintrag (approval_lint greift nur fuer Gate-Aufrufer).
# Cred = estate_rw (finance_rw-Paritaet, Plan-Kontext-Update: bewusst NICHT die career-Haupt-RW-
# Abweichung — estate ist household, die fn braucht KEINEN fn_resolve_sender-Read auf agent.*;
# estate.onboarding_state liegt im eigenen Schema, die INVOKER-fn traegt die Isolation ueber die
# Caller-Grants; EXECUTE auf core.fn_set_onboarding_section grantet fn_provision_package_roles).
# estate hat keine core.context_scopes-Zeile -> household-Form (PK section_key, anders als career per_user);
# die chat_id im Payload dient nur dem owner_only-Riegel der fn (Haushalts-Fortschritt setzt nur der Owner).
function Build-EstateSetOnboardingSection {
    $CRED_POSTGRES = $CRED_ESTATE_RW   # funktions-lokal (Dynamic-Scope -> Build-Pg sieht es), WS-B0-Muster

    $trig = Build-Trigger @('section_key', 'status', 'chat_id')

    # package='estate' hartkodiert (nie $fromAI; 'estate' -> estate.onboarding_state).
    $set = Build-Pg 'Set section' @(220, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'section_key' AS section_key, r->>'status' AS status, (r->>'complete')::boolean AS complete, (r->>'area_completed_now')::boolean AS area_completed_now, (r->>'area_all_skipped')::boolean AS area_all_skipped FROM core.fn_set_onboarding_section(`$1::jsonb) AS r;" `
        ([ordered]@{
            package     = "'estate'"
            section_key = '$(''Start'').item.json.section_key'
            status      = '$(''Start'').item.json.status'
            chat_id     = '$(''Start'').item.json.chat_id'   # owner_only-Riegel der fn (build-fix, nie LLM)
        })

    $ifOk = Build-If 'Set ok?' @(440, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $err = Build-ToolError 'Set failed' @(660, 200) "={{ `$('Set section').item.json.reason }}"
    # Roter Faden: hat der Schritt den Bereich geschlossen, schickt core.sub_onboarding_progress die Weiter-Karte
    # (fire-and-forget; die Entscheidung trifft die DB ueber area_completed_now + die Einmal-Latches).
    $progress = New-OnboardingProgressCallNode -Package 'estate' -Pos @(660, 0)
    $ret = Build-Return @(880, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('section_key', "={{ `$('Set section').item.json.section_key }}", 'string')
        ,@('status', "={{ `$('Set section').item.json.status }}", 'string')
        ,@('onboarding_complete', "={{ `$('Set section').item.json.complete }}", 'boolean')
    )

    $sticky = Build-Sticky 'Onboarding-Fortschritt (Estate)' @(220, -380) `
        'core.fn_set_onboarding_section (package=estate): Tri-State-Marker (kein HITL)' `
        'WS-1 estate: Core-generische Schnittstelle (paket-schlüssel-parametrisiert), package=estate hartkodiert -> setzt estate.onboarding_state.status (completed/skipped/unknown) + skipped_at. HOUSEHOLD-Form (PK section_key, byte-gleich finance/guide — estate hat KEINE core.context_scopes-Zeile, anders als career per_user) -> chat_id im Payload nur für den owner_only-Riegel der fn (Mitglied -> {ok:false, owner_only}, kein Write). SECURITY INVOKER -> der Write läuft unter estate_rw (eigenes Schema; Isolation via Caller-Grants, finance_rw-Parität). KEIN Gate: nur ein Fortschritts-Flag, kein Register-Write (Register-Erfassungs-Tools kommen mit WS-2). Der Estate-Advisor markiert hier eine der 6 Sektionen (documents/insurance_check/contracts/digital_accounts/contacts/wishes) nach dem Durchgehen im Self-Onboarding-Modus. Roter Faden: nach erfolgreichem Set ruft Onboarding progress den Core-Dienst core:onboarding_progress (core.sub_onboarding_progress, fire-and-forget, onError continue); die fn meldet area_completed_now genau dann, wenn dieser Schritt den Bereich geschlossen hat -> Weiter-Karte auf den nächsten offenen Abschnitt (deterministisch statt LLM-Text). Reset: packages/core/db/util/util_reset_onboarding_state.sql.' 300 620

    $nodes = @($trig, $set, $ifOk, $err, $progress, $ret, $sticky)
    $conns = [ordered]@{
        'Start'       = @{ main = @( ,@( E 'Set section' ) ) }
        'Set section' = @{ main = @( ,@( E 'Set ok?' ) ) }
        'Set ok?'     = @{ main = @(
            @( E 'Onboarding progress' ),
            @( E 'Set failed' )
        ) }
        'Onboarding progress' = @{ main = @( ,@( E 'Return' ) ) }
    }
    return Build-Workflow 'agent.estate.tool_set_onboarding_section' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
