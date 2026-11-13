-- ============================================================
-- core.fn_check_next_step_tap(p) — ist ein getippter Vorschlags-Knopf noch der aktuelle Schritt? (WRITE: Zaehler zurueck)
--   Vorschlags-Knoepfe fuer Onboarding-Ziele tragen das Suffix ':next' (core.fn_get_next_step, Feld data); Menue-Knoepfe
--   ohne Suffix bleiben "Abschnitt erneut oeffnen". Veraltet heisst: der callback ist nicht mehr der aktuelle Schritt des
--   Tippenden (neu gerechnet), nicht "Status <> unknown" — ein Zuerst-Abschnitt eines Plans darf erledigt oder
--   uebersprungen sein. Rolle und for_roles sind damit mitgeprueft (ein Kind kann keinen fremden career-Knopf nutzen).
--   Eingabe p: { chat_id, data, order, plan_order } (order/plan_order wie core.fn_get_next_step, build-time).
--   Rueckgabe jsonb:
--     ohne Suffix                     -> { ok:true, data }                 (unveraendert)
--     aktuell                         -> { ok:true, data:<ohne Suffix> }   + Wiederholungs-Zaehler dieses Schritts zurueck
--                                        (core.fn_notify_resolve je Key: ein gueltiger Tipp ist kein ignoriertes Angebot)
--     veraltet / unbekannter Absender -> { ok:false, reason:'stale', toast } (core.toast.step_done, Sprache des Tippenden);
--                                        der Orchestrator sendet danach die Uebersicht.
--   Wirft nie. SECURITY DEFINER (schreibt core.notification_state), search_path gepinnt; Aufrufer: Orchestrator (Host-Cred).
--   Tests: tests/db/core/test_fn_check_next_step_tap.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_check_next_step_tap(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_data   text := COALESCE(p->>'data', '');
    v_base   text;
    v_chat   text := COALESCE(p->>'chat_id', '');
    v_sender jsonb;
    v_step   jsonb;
    v_keys   jsonb;
    v_k      text;
    v_lang   text;
BEGIN
    IF right(v_data, 5) <> ':next' THEN
        RETURN jsonb_build_object('ok', true, 'data', v_data);
    END IF;
    v_base := left(v_data, length(v_data) - 5);
    IF v_chat ~ '^[0-9]{1,18}$' THEN
        v_sender := agent.fn_resolve_sender(v_chat::bigint);
    END IF;
    v_lang := agent.fn_person_lang(v_sender->>'person_id')->>'lang';
    v_step := core.fn_get_next_step(jsonb_build_object('chat_id', v_chat, 'order', p->'order', 'plan_order', p->'plan_order'));
    IF COALESCE((v_sender->>'found')::boolean, false) AND v_step->>'callback' = v_base THEN
        v_keys := core.fn_next_step_offer_keys(v_sender->>'person_id', v_step->>'callback', v_step->>'state',
                                               (v_step->>'generation')::bigint);
        FOR v_k IN SELECT jsonb_array_elements_text(v_keys->'repeat') LOOP
            PERFORM core.fn_notify_resolve('next_step_offer', v_k);
        END LOOP;
        RETURN jsonb_build_object('ok', true, 'data', v_base);
    END IF;
    RETURN jsonb_build_object('ok', false, 'reason', 'stale', 'toast', core.fn_ui_text('core.toast.step_done', v_lang));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stale', 'toast', core.fn_ui_text('core.toast.step_done', NULL));
END;
$$;

REVOKE ALL ON FUNCTION core.fn_check_next_step_tap(jsonb) FROM public;
