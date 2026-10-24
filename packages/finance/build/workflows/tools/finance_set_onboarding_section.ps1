#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.finance.tool_set_onboarding_section (WS-B3 DRY-Onboarding) ------
# Finanz-Onboarding-Fortschritts-Marker: setzt EINE finance-Sektion auf completed/skipped/unknown.
# Spiegel des Guide-Tools (agent.guide.tool_set_onboarding_section), aber package='finance' -> schreibt
# finance.onboarding_state ueber die Core-generische Schnittstelle core.fn_set_onboarding_section. KEIN HITL
# (kein Finanz-Write, nur ein Status-Flag) — die eigentlichen Onboarding-Writes laufen ueber die HITL-Tools
# (create_*/book_*/import). Laeuft unter finance_rw (eigenes Schema, INVOKER-fn → Isolation via Caller-Grants).
function Build-FinanceSetOnboardingSection {
    $CRED_POSTGRES = $CRED_FINANCE_RW   # funktions-lokal (Dynamic-Scope -> Build-Pg sieht es), WS-B0-Muster

    $trig = Build-Trigger @('section_key', 'status', 'chat_id')

    # WS-B3: package='finance' hartkodiert (nie $fromAI; 'finance' -> finance.onboarding_state).
    $set = Build-Pg 'Set section' @(220, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'section_key' AS section_key, r->>'status' AS status, (r->>'complete')::boolean AS complete, (r->>'area_completed_now')::boolean AS area_completed_now, (r->>'area_all_skipped')::boolean AS area_all_skipped FROM core.fn_set_onboarding_section(`$1::jsonb) AS r;" `
        ([ordered]@{
            package     = "'finance'"
            section_key = '$(''Start'').item.json.section_key'
            status      = '$(''Start'').item.json.status'
            chat_id     = '$(''Start'').item.json.chat_id'   # owner_only-Riegel der fn fuer Haushalts-Sektionen (build-fix, nie LLM)
        })

    $ifOk = Build-If 'Set ok?' @(440, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $err = Build-ToolError 'Set failed' @(660, 200) "={{ `$('Set section').item.json.reason }}"
    # Roter Faden: hat der Schritt den Bereich geschlossen, schickt core.sub_onboarding_progress die Weiter-Karte
    # (fire-and-forget; die Entscheidung trifft die DB ueber area_completed_now + die Einmal-Latches).
    $progress = New-OnboardingProgressCallNode -Package 'finance' -Pos @(660, 0)
    $ret = Build-Return @(880, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('section_key', "={{ `$('Set section').item.json.section_key }}", 'string')
        ,@('status', "={{ `$('Set section').item.json.status }}", 'string')
        ,@('onboarding_complete', "={{ `$('Set section').item.json.complete }}", 'boolean')
    )

    $sticky = Build-Sticky 'Onboarding-Fortschritt (Finanz)' @(220, -380) `
        'core.fn_set_onboarding_section (package=finance): Tri-State-Marker (kein HITL)' `
        'WS-B3 DRY-Onboarding: Core-generische Schnittstelle (paket-schlüssel-parametrisiert), package=finance hartkodiert -> setzt finance.onboarding_state.status (completed/skipped/unknown) + skipped_at. SECURITY INVOKER -> der Write läuft unter finance_rw (eigenes Schema; die Isolation hält durch die Caller-Grants). KEIN HITL-Gate: nur ein Fortschritts-Flag, kein Domänen-Write; die fn lässt nur den Owner schreiben (chat_id im Payload, Mitglied -> {ok:false, owner_only}). Der Finance-Agent markiert hier eine der 5 Finanz-Sektionen (accounts/investments/liabilities/protection/goals), sobald er sie erfasst (oder der Nutzer sie bewusst überspringt). Core-household pflegt der Guide separat. Roter Faden: nach erfolgreichem Set ruft Onboarding progress den Core-Dienst core:onboarding_progress (core.sub_onboarding_progress, fire-and-forget, onError continue); die fn meldet area_completed_now genau dann, wenn dieser Schritt den Bereich geschlossen hat -> Weiter-Karte auf den nächsten offenen Abschnitt (deterministisch statt LLM-Text). Reset: packages/core/db/util/util_reset_onboarding_state.sql.' 280 540

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
    return Build-Workflow 'agent.finance.tool_set_onboarding_section' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
