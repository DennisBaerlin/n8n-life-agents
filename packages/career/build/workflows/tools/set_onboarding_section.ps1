#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.career.tool_set_onboarding_section (P1 Generisches Paket-Onboarding) ------
# Career-Onboarding-Fortschritts-Marker: setzt EINE career-Sektion auf completed/skipped/unknown.
# Spiegel des Guide-/Finance-Tools, aber package='career' -> schreibt career.onboarding_state ueber die
# Core-generische Schnittstelle core.fn_set_onboarding_section. KEIN HITL (kein Domaenen-/PII-Write, nur ein
# Status-Flag) -> ruft KEIN Gate -> KEIN approval_matrix-Eintrag (approval_lint greift nur fuer Gate-Aufrufer).
# Cred = Haupt-RW (Default Build-Pg) wie die anderen career-Tools (record_job_match) + das Guide-Tool; nur
# finance nutzt finance_rw (WS-B0). fn_set_onboarding_section ist SECURITY INVOKER -> der INVOKER-Write auf
# career.onboarding_state laeuft unter dem Haupt-RW-Owner/Host-Cred (der agent.* lesen darf -> fn_resolve_sender
# fuer den per_user-Scope; ein finance_rw-Aufruf scheiterte daran, deshalb Haupt-RW). P2b-1: career.onboarding_state
# ist PRO PERSON -> die fn loest die Person aus chat_id via fn_resolve_sender (NIE LLM) auf, materialisiert ihre
# Sektionszeilen lazy und setzt NUR ihre Zeile; unaufgeloeste/non-numerische chat_id -> {ok:false} (fail-closed).
function Build-CareerSetOnboardingSection {
    $trig = Build-Trigger @('section_key', 'status', 'chat_id')

    # package='career' hartkodiert (nie $fromAI; 'career' -> career.onboarding_state). chat_id ins jsonb-Payload
    # durchreichen (P2b-1: die fn loest daraus deterministisch die Person fuer den per_user-Scope auf).
    $set = Build-Pg 'Set section' @(220, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'section_key' AS section_key, r->>'status' AS status, (r->>'complete')::boolean AS complete, (r->>'area_completed_now')::boolean AS area_completed_now, (r->>'area_all_skipped')::boolean AS area_all_skipped FROM core.fn_set_onboarding_section(`$1::jsonb) AS r;" `
        ([ordered]@{
            package     = "'career'"
            section_key = '$(''Start'').item.json.section_key'
            status      = '$(''Start'').item.json.status'
            chat_id     = '$(''Start'').item.json.chat_id'
        })

    $ifOk = Build-If 'Set ok?' @(440, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $err = Build-ToolError 'Set failed' @(660, 200) "={{ `$('Set section').item.json.reason }}"
    # Roter Faden: hat der Schritt den Bereich geschlossen, schickt core.sub_onboarding_progress die Weiter-Karte
    # (fire-and-forget; die Entscheidung trifft die DB ueber area_completed_now + die Einmal-Latches).
    $progress = New-OnboardingProgressCallNode -Package 'career' -Pos @(660, 0)
    $ret = Build-Return @(880, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('section_key', "={{ `$('Set section').item.json.section_key }}", 'string')
        ,@('status', "={{ `$('Set section').item.json.status }}", 'string')
        ,@('onboarding_complete', "={{ `$('Set section').item.json.complete }}", 'boolean')
    )

    $sticky = Build-Sticky 'Onboarding-Fortschritt (Career)' @(220, -380) `
        'core.fn_set_onboarding_section (package=career): Tri-State-Marker pro Person (kein HITL)' `
        'P2b-1 Career-Onboarding PRO PERSON: Core-generische Schnittstelle (paket-schlüssel-parametrisiert), package=career hartkodiert. Der Payload reicht chat_id durch -> die fn leitet aus core.context_scopes ab, dass career per_user ist, löst die Person DETERMINISTISCH aus chat_id via agent.fn_resolve_sender auf (NIE LLM), materialisiert ihre 3 Sektionszeilen lazy und setzt NUR ihre Zeile (.status completed/skipped/unknown + skipped_at). Unaufgelöste/non-numerische chat_id -> {ok:false} (fail-closed, kein Write -> Set ok? false-Zweig). SECURITY INVOKER -> der Write + der fn_resolve_sender-Read laufen unter dem Haupt-RW-Owner/Host-Cred (der agent.* lesen darf; wie record_job_match, nur finance nutzt finance_rw, WS-B0). KEIN Gate: nur ein Fortschritts-Flag, kein Domänen-Write. Der career_advisor markiert hier eine seiner 3 Career-Sektionen (profile_basics/skills_overview/goals_targets). Core-household pflegt der Guide separat (household, unverändert). Roter Faden: nach erfolgreichem Set ruft Onboarding progress den Core-Dienst core:onboarding_progress (core.sub_onboarding_progress, fire-and-forget, onError continue); die fn meldet area_completed_now genau dann, wenn dieser Schritt den Bereich geschlossen hat -> Weiter-Karte auf den nächsten offenen Abschnitt (deterministisch statt LLM-Text). Reset: packages/core/db/util/util_reset_onboarding_state.sql.' 300 620

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
    return Build-Workflow 'agent.career.tool_set_onboarding_section' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
