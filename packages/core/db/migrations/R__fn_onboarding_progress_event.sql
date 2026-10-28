-- ============================================================
-- core.fn_onboarding_progress_event (Roter Faden 2026-10-23) — die Einmal-Ereignisse NACH einem Onboarding-Schritt
--   Aufgerufen von JEDEM tool_set_onboarding_section (geteilter Build-Schwanz New-OnboardingProgressTail) direkt
--   nach core.fn_set_onboarding_section. Entscheidet deterministisch, welche Karten der Schritt ausloest:
--     * send_all_done    — der Schritt hat den LETZTEN fuer die Person offenen Bereich geschlossen ("alles
--                          eingerichtet"); genau EINMAL je Person (Latch source 'onboarding', key 'all_done:<pid>'),
--                          re-armt, sobald fuer die Person wieder etwas offen ist (z. B. neues Paket installiert).
--     * send_learn_offer — das Lern-Angebot (cron_on:learn_context ist owner-only): nur Owner, nur zusammen mit
--                          send_all_done, nur wenn core cron_enable.learn_context AUS ist.
--     * member_chats     — "Es kann losgehen": der Core-Haushalt ist mit DIESEM Schritt fertig geworden -> die
--                          Telegram-ids der gepairten Nicht-Owner; genau EINMAL ueberhaupt (Latch 'household_ready',
--                          bewusst KEIN Re-Arm: ein erneutes Abschliessen ist keine Neuigkeit fuer Mitglieder).
--     * members_have_areas — ob ein aktives per_user-Paket existiert (Knopf "deine Bereiche" auf der Mitglieder-Karte).
--   p: { chat_id (build-fix, nie LLM), package, area_completed_now (Rueckgabe von fn_set_onboarding_section) }
--   Ohne area_completed_now sendet die fn NIE etwas (kein Ueberraschungs-Send auf Bestandsinstallationen, deren
--   Onboarding laengst fertig ist); sie re-armt dann nur den all_done-Latch, falls wieder etwas offen ist.
--   "Fuer die Person relevant" = genau die Sicht von core.fn_onboarding_overview(chat_id): Owner = alle Sektionen,
--   Mitglied = nur per_user-Sektionen (Haushalts-Bereiche richtet der Owner ein). Ohne relevante Sektion nie all_done.
--   RUECKGABE: {ok:true, all_complete, household_ready, send_all_done, send_learn_offer, member_chats[], members_have_areas}
--     Unaufgeloester Sender -> {ok:true, ... alles false/leer} (fail-closed: keine Karte an Unbekannte). Nie RAISE.
--
--   D10 / Auth: SECURITY DEFINER, gerufen nur von core.sub_onboarding_progress unter der Core-Cred (KEIN Paket-Grant:
--   die Paket-Tools rufen den Core-Dienst, nicht die fn). Liest agent.* (Personen, Haushalt), core.notification_state
--   (ueber die Latch-fns) und ueber fn_onboarding_overview alle <pkg>.onboarding_state. search_path gepinnt, Body
--   schema-qualifiziert, kein Caller-Input in dynamischem SQL; person_id nur aus agent.fn_resolve_sender (nie LLM).
--   Tests: tests/db/core/test_fn_onboarding_progress_event.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_onboarding_progress_event(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_chat        text    := NULLIF(p->>'chat_id', '');
    v_pkg         text    := COALESCE(NULLIF(p->>'package', ''), 'core');
    v_now         boolean := COALESCE((p->>'area_completed_now')::boolean, false);
    v_sender      jsonb;
    v_pid         text;
    v_owner       boolean;
    v_ov          jsonb;
    v_relevant    int;
    v_open        int;
    v_all         boolean := false;
    v_household   boolean;
    v_all_done    boolean := false;
    v_learn       boolean := false;
    v_members     jsonb   := '[]'::jsonb;
    v_have_areas  boolean;
BEGIN
    v_household := NOT EXISTS (SELECT 1 FROM agent.guide_onboarding_state WHERE status = 'unknown');
    v_have_areas := core.fn_has_personal_onboarding_areas();

    IF v_chat ~ '^[0-9]{1,18}$' THEN
        v_sender := agent.fn_resolve_sender(v_chat::bigint);
    END IF;
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE THEN
        RETURN jsonb_build_object('ok', true, 'all_complete', false, 'household_ready', v_household,
            'send_all_done', false, 'send_learn_offer', false, 'member_chats', '[]'::jsonb,
            'members_have_areas', v_have_areas);
    END IF;
    v_pid   := v_sender->>'person_id';
    v_owner := (v_sender->>'role') IS NOT DISTINCT FROM 'owner';

    -- Relevante Sektionen aus DERSELBEN Sicht wie das Menue (Owner alles, Mitglied nur per_user).
    v_ov := core.fn_onboarding_overview(v_chat);
    SELECT count(*), count(*) FILTER (WHERE s->>'status' = 'unknown')
      INTO v_relevant, v_open
      FROM jsonb_array_elements(COALESCE(v_ov->'sections', '[]'::jsonb)) s
     WHERE v_owner OR (s->>'per_user')::boolean;
    v_all := v_relevant > 0 AND v_open = 0;

    IF NOT v_all THEN
        PERFORM core.fn_notify_resolve('onboarding', 'all_done:' || v_pid);   -- wieder offen -> naechstes Ende meldet neu
    ELSE
        -- Review-Fund: ein spaeter installiertes Paket kann geoeffnet UND wieder geschlossen werden, ohne dass je ein
        -- Aufruf mit offenem Stand kam (die Tools rufen nur beim Schliessen). Ein relevanter Abschnitt, der sich NACH der
        -- letzten "alles eingerichtet"-Karte geaendert hat, re-armt deshalb ebenfalls.
        IF EXISTS (SELECT 1 FROM core.notification_state ns
                    WHERE ns.source = 'onboarding' AND ns.key = 'all_done:' || v_pid AND ns.state = 'fired'
                      AND EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_ov->'sections', '[]'::jsonb)) s
                                   WHERE (v_owner OR (s->>'per_user')::boolean)
                                     AND (s->>'changed_at')::timestamptz > ns.last_fired_at)) THEN
            PERFORM core.fn_notify_resolve('onboarding', 'all_done:' || v_pid);
        END IF;
    END IF;

    IF v_now THEN
        IF v_all THEN
            v_all_done := core.fn_should_notify('onboarding', 'all_done:' || v_pid);
        END IF;
        v_learn := v_all_done AND v_owner
                   AND COALESCE(core.fn_config_get('core', 'cron_enable', 'learn_context'), 'false') <> 'true';
        IF v_pkg = 'core' AND v_household AND v_owner AND core.fn_should_notify('onboarding', 'household_ready') THEN
            SELECT COALESCE(jsonb_agg(c.chat ORDER BY c.chat), '[]'::jsonb) INTO v_members
              FROM (SELECT agent.fn_person_chat_id(ap.person_id) AS chat
                      FROM agent.persons ap
                     WHERE ap.role IS DISTINCT FROM 'owner') c
             WHERE c.chat IS NOT NULL;
        END IF;
    END IF;

    RETURN jsonb_build_object('ok', true, 'all_complete', v_all, 'household_ready', v_household,
        'send_all_done', v_all_done, 'send_learn_offer', v_learn, 'member_chats', v_members,
        'members_have_areas', v_have_areas);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_onboarding_progress_event(jsonb) FROM public;
