#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.guide.tool_set_onboarding_section (Phase 5a) ------
# Fortschritts-Marker des Onboardings: setzt EINE Sektion auf completed/skipped/unknown.
# KEIN HITL (kein Finanz-Write, nur ein Status-Flag) — die eigentlichen Onboarding-Writes laufen
# ueber die gebundenen HITL-Tools (tool_set_household_facts, tool_commit_import, tool_save_plan_section).
# 'skipped' = bewusst uebersprungen (Plan §1b) und zaehlt fuers Gate als aufgeloest.
function Build-SetOnboardingSection {
    # chat_id: owner_only-Riegel der fn (Mitglied darf household nicht setzen) + Ziel der Weiter-Karte (core.sub_onboarding_progress).
    $trig = Build-Trigger @('section_key', 'status', 'chat_id')

    # KEIN Test-Bypass mehr (Teststrategie Phase 8 — Weg C): der frühere `Is Test?`/`Return Test`-Zweig
    # (chat_id-Prefix test_ → ok:true OHNE Write) ist ENTFERNT. Er sollte verhindern, dass Routing-Tests
    # den PERSISTENTEN Onboarding-Zustand mutieren — das ist gegenstandslos, seit die Tiers gegen die
    # EPHEMERE Container-DB laufen (per Lauf frisch). Routing-Tests durchlaufen jetzt den ECHTEN Write
    # (mock_route guide bleibt grün: gc03 prüft den Tool-Call, den der reale Pfad ebenso registriert).

    # WS-B3: Core-generische Schnittstelle core.fn_set_onboarding_section; der Guide besitzt NUR das
    # Core-Onboarding -> package='core' ist hartkodiert (nie $fromAI; 'core' -> agent.guide_onboarding_state).
    $set = Build-Pg 'Set section' @(220, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'section_key' AS section_key, r->>'status' AS status, (r->>'complete')::boolean AS complete, (r->>'area_completed_now')::boolean AS area_completed_now, (r->>'area_all_skipped')::boolean AS area_all_skipped FROM core.fn_set_onboarding_section(`$1::jsonb) AS r;" `
        ([ordered]@{
            package     = "'core'"
            section_key = '$(''Start'').item.json.section_key'
            status      = '$(''Start'').item.json.status'
            chat_id     = '$(''Start'').item.json.chat_id'   # build-fix aus dem Agenten, nie LLM
        })

    $ifOk = Build-If 'Set ok?' @(440, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $err = Build-ToolError 'Set failed' @(660, 200) "={{ `$('Set section').item.json.reason }}"

    # Roter Faden: hat der Schritt den Haushalt geschlossen, schickt core.sub_onboarding_progress die Weiter-Karte
    # (naechster Bereich) und den Mitgliedern "Es kann losgehen". Das Lern-Angebot (frueher HIER nach dem Haushalt
    # und bei jedem erneuten complete) kommt jetzt dort genau einmal, wenn ALLE Bereiche eingerichtet sind.
    $progress = New-OnboardingProgressCallNode -Package 'core' -Pos @(660, 0)

    # Return liest die Felder EXPLIZIT aus 'Set section' (zwischen Set ok? und Return liegt der Fortschritts-Aufruf).
    $ret = Build-Return @(880, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('section_key', "={{ `$('Set section').item.json.section_key }}", 'string')
        ,@('status', "={{ `$('Set section').item.json.status }}", 'string')
        ,@('onboarding_complete', "={{ `$('Set section').item.json.complete }}", 'boolean')
    )

    $sticky = Build-Sticky 'Onboarding-Fortschritt' @(220, -380) `
        'core.fn_set_onboarding_section (package=core): Tri-State-Marker (kein HITL)' `
        'WS-B3: Core-generische Schnittstelle (paket-schlüssel-parametrisiert), package=core hartkodiert -> setzt agent.guide_onboarding_state.status (completed/skipped/unknown) + status_changed_at (SECURITY INVOKER, Owner/Host-Cred schreibt agent.*). KEIN HITL-Gate: nur ein Fortschritts-Flag, kein Domänen-Write; die fn lässt aber nur den Owner schreiben (chat_id im Payload, Mitglied -> {ok:false, owner_only}). onboarding_complete im Return = ob im Core jetzt KEINE Sektion mehr unknown ist. Plan §1b: skipped ist ein bewusster Beratungsfakt, kein Fehler. Der Guide besitzt NUR household; die 5 Finanz-Sektionen pflegt der Finance-Agent selbst (finance.onboarding_state). Roter Faden: nach erfolgreichem Set ruft Onboarding progress den Core-Dienst core:onboarding_progress (core.sub_onboarding_progress, fire-and-forget, onError continue); die fn meldet area_completed_now genau dann, wenn dieser Schritt den Haushalt geschlossen hat -> Weiter-Karte auf den nächsten Bereich + einmalig Es kann losgehen an die Mitglieder. Das Lern-Angebot kommt dort am Ende ALLER Bereiche (nicht mehr hier). Reset: packages/core/db/util/util_reset_onboarding_state.sql.' 260 600

    $nodes = @($trig, $set, $ifOk, $err, $progress, $ret, $sticky)
    $conns = [ordered]@{
        'Start'               = @{ main = @( ,@( E 'Set section' ) ) }
        'Set section'         = @{ main = @( ,@( E 'Set ok?' ) ) }
        'Set ok?'             = @{ main = @(
            @( E 'Onboarding progress' ),
            @( E 'Set failed' )
        ) }
        'Onboarding progress' = @{ main = @( ,@( E 'Return' ) ) }
    }
    return Build-Workflow 'agent.guide.tool_set_onboarding_section' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
