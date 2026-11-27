-- ============================================================
-- core.fn_handoff_register(p_domain, p_chat_id) — Ersatzweg-Register: was vereinbart, aber nicht so eingetragen ist
--   Abgeleitet bei jedem Aufruf (keine gepflegte Liste, beliebig wiederholbar): die Vormerkungen der Person des Absenders
--   (core.fn_handoff_person) in dieser Domain, die
--     deferred   -> zurueckgestellt sind (blocked_code);
--     deviation  -> mit Werkzeug abgeschlossen (close_reason entered), ein Soll tragen (wanted) und deren heutiger Stand
--                   davon abweicht: Paket-fn core.advisors.handoff_diff_fn(task_id) liefert einen nicht leeren Unterschied.
--                   Korrigiert der Nutzer die Sache spaeter selbst, ist der Unterschied leer und die Zeile verschwindet;
--     legacy     -> vor der Spalte close_reason abgeschlossen sind (Altbestand ohne Provenienz) und deren Abschnitt (und
--                   Thema, ohne Gross-/Kleinschreibung) im gueltigen Plan noch steht.
--   Nie dabei: eine Aufgabe, der schon eine Korrektur folgt (follows_task_id).
--   possible_now/call = jetzt nachholbar: Vorpruefung core.advisors.handoff_check_fn im Modus recheck ({mode, domain, chat_id,
--   task_id, status, kind, payload, text, wanted}); wahr, wenn sie jetzt einen Aufruf liefert (call bzw. calls).
--   deviation ist nur nachholbar, wenn ihr ganzer Unterschied aus vereinbarten Aufrufen besteht, die nie eingetragen wurden
--   (jedes Element mit call); vorgeprueft wird dann genau dieser Rest (wanted = der eine Aufruf bzw. die Liste), nie das
--   ganze Soll. Ein abweichendes Feld oder eine wieder geloeschte Sache ist eine spaetere Aenderung des Nutzers: die Zeile
--   bleibt mit diff sichtbar, wird aber nie nachgeholt, auch nicht ihr fehlender Rest (die Vereinbarung gilt so nicht mehr).
--   legacy done bleibt falsch: ohne Soll weiss nur der Berater, was gemeint war. Fehlt eine Registry-fn oder wirft sie,
--   gilt neutral: possible_now=false bzw. keine deviation.
--   Rueckgabe jsonb-Array in id-Reihenfolge [{task_id, kind, text, why, section_key, topic, status, row_kind, blocked_code,
--   wanted, entered_refs, diff, possible_now, call}]; unaufgeloester Absender -> [].
--   Konsumenten: core.fn_plan_rollout_next (step fix, check), core.fn_advisor_progress (rollout_next), core.fn_handle_handoff_cb
--   (Knopf ...:fix), Berater-Lesefenster.
--   STABLE, SECURITY DEFINER (liest agent.handoff_tasks + agent.advisor_plans), EXECUTE an <pkg>_ro/_rw via
--   core.fn_provision_package_roles. Tests: tests/db/core/test_fn_handoff_register.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_register(p_domain text, p_chat_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_pid    text := core.fn_handoff_person(p_chat_id);
    v_adv    record;
    v_chkfn  regprocedure;
    v_difffn regprocedure;
    v_state  jsonb;
    t        record;
    v_kind   text;
    v_diff   jsonb;
    v_chk    jsonb;
    v_call   jsonb;
    v_want   jsonb;
    v_out    jsonb := '[]'::jsonb;
BEGIN
    IF v_pid IS NULL OR COALESCE(p_domain, '') = '' THEN RETURN v_out; END IF;
    SELECT a.handoff_check_fn, a.handoff_diff_fn, a.plan_context INTO v_adv FROM core.advisors a WHERE a.domain = p_domain;
    v_chkfn := to_regprocedure(v_adv.handoff_check_fn || '(jsonb)');
    v_difffn := to_regprocedure(v_adv.handoff_diff_fn || '(integer)');
    SELECT ap.interview_state INTO v_state FROM agent.advisor_plans ap
     WHERE ap.domain = p_domain AND ap.status = 'active'
       AND ap.person_id IS NOT DISTINCT FROM CASE WHEN COALESCE((SELECT cs.scope FROM core.context_scopes cs
                                                                  WHERE cs.context_name = v_adv.plan_context), 'household') = 'per_user'
                                                  THEN v_pid END;

    FOR t IN
        SELECT h.* FROM agent.handoff_tasks h
         WHERE h.domain = p_domain AND h.person_id = v_pid
           AND (h.status = 'deferred' OR (h.status IN ('done', 'cancelled')
                AND (h.close_reason IS NULL OR (h.close_reason = 'entered' AND h.wanted IS NOT NULL))))
           AND NOT EXISTS (SELECT 1 FROM agent.handoff_tasks f WHERE f.follows_task_id = h.id)
         ORDER BY h.id
    LOOP
        v_diff := NULL;
        IF t.status = 'deferred' THEN
            v_kind := 'deferred';
        ELSIF t.close_reason = 'entered' THEN
            CONTINUE WHEN v_difffn IS NULL;
            BEGIN
                EXECUTE format('SELECT %s($1)', v_difffn::regproc) INTO v_diff USING t.id;
            EXCEPTION WHEN OTHERS THEN
                v_diff := NULL;
            END;
            CONTINUE WHEN jsonb_typeof(v_diff) IS DISTINCT FROM 'array' OR jsonb_array_length(v_diff) = 0;
            v_kind := 'deviation';
        ELSE
            CONTINUE WHEN jsonb_typeof(v_state->t.section_key) IS DISTINCT FROM 'object'
                       OR (t.topic IS NOT NULL AND NOT EXISTS (
                               SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_state->t.section_key->'topics') = 'array'
                                                                       THEN v_state->t.section_key->'topics' ELSE '[]'::jsonb END) x
                                WHERE lower(btrim(x->>'topic')) = lower(btrim(t.topic))));
            v_kind := 'legacy';
        END IF;

        v_call := NULL;
        v_want := t.wanted;
        IF v_kind = 'deviation' THEN
            v_want := CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(v_diff) x WHERE jsonb_typeof(x->'call') IS DISTINCT FROM 'object')
                           THEN NULL
                           WHEN jsonb_array_length(v_diff) = 1 THEN v_diff->0->'call'
                           ELSE (SELECT jsonb_agg(x->'call' ORDER BY n) FROM jsonb_array_elements(v_diff) WITH ORDINALITY AS d(x, n)) END;
        END IF;
        IF v_chkfn IS NOT NULL AND NOT (v_kind = 'legacy' AND t.status = 'done') AND NOT (v_kind = 'deviation' AND v_want IS NULL) THEN
            BEGIN
                EXECUTE format('SELECT %s($1)', v_chkfn::regproc) INTO v_chk USING jsonb_build_object(
                    'mode', 'recheck', 'domain', p_domain, 'chat_id', p_chat_id, 'task_id', t.id, 'status', t.status,
                    'kind', t.kind, 'payload', t.payload, 'text', t.text, 'wanted', v_want);
            EXCEPTION WHEN OTHERS THEN
                v_chk := NULL;
            END;
            IF v_chk->'ok' = 'true'::jsonb AND v_chk->'unsupported' IS DISTINCT FROM 'true'::jsonb THEN
                v_call := CASE WHEN jsonb_typeof(v_chk->'calls') = 'array' THEN NULLIF(v_chk->'calls', '[]'::jsonb)
                               WHEN jsonb_typeof(v_chk->'call') = 'object' THEN v_chk->'call' END;
            END IF;
        END IF;

        v_out := v_out || jsonb_build_array(jsonb_build_object(
            'task_id', t.id, 'kind', t.kind, 'text', t.text, 'why', t.why, 'section_key', t.section_key, 'topic', t.topic,
            'status', t.status, 'row_kind', v_kind, 'blocked_code', t.blocked_code, 'wanted', t.wanted,
            'entered_refs', t.entered_refs, 'diff', v_diff, 'possible_now', v_call IS NOT NULL, 'call', v_call));
    END LOOP;
    RETURN v_out;
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_register(text, text) FROM public;
