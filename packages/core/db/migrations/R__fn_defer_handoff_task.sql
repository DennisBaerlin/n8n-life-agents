-- ============================================================
-- core.fn_defer_handoff_task(p) — vereinbarte Plan-Aufgabe zurueckstellen: so noch nicht eintragbar
--   p: { handoff_task_id, chat_id, blocked_code }. open|working -> deferred mit blocked_code. Gueltige Codes = die Liste
--   des Pakets der Aufgabe, und die ist sein Textkatalog: Key <package>.handoff.blocked.<code> (de) muss existieren (der
--   Satz "geht noch nicht, weil ..." steht dort). Statt einen vereinbarten Wert in Notizen zu parken, wartet die Aufgabe
--   auf ein Update; der Korrektur-Schritt der Abfolge (core.fn_plan_rollout_next, step fix) bietet sie wieder an, sobald
--   die Vorpruefung durchlaeuft. Nur Aufgaben der Person des Absenders (core.fn_handoff_person).
--   Erfolg {ok:true, task_id, status:'deferred', blocked_code, text}; korrigierbar {ok:false, code: unknown_blocked_code
--   (+ valid_codes) | handoff_task_invalid | handoff_task_closed, reason}.
--   Aufrufer: die Paket-fn hinter dem Zurueckstellen-Werkzeug des Pakets. SECURITY DEFINER, EXECUTE an <pkg>_rw via
--   core.fn_provision_package_roles. Tests: tests/db/core/test_fn_defer_handoff_task.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_defer_handoff_task(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_id    text := btrim(COALESCE(p->>'handoff_task_id', ''));
    v_code  text := btrim(COALESCE(p->>'blocked_code', ''));
    v_pid   text := core.fn_handoff_person(p->>'chat_id');
    v_t     record;
    v_valid jsonb;
BEGIN
    IF v_id !~ '^[0-9]{1,9}$' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'handoff_task_id must be the numeric id from the handoff task list.');
    END IF;
    SELECT id, text, status, person_id, package INTO v_t FROM agent.handoff_tasks WHERE id = v_id::int FOR UPDATE;
    IF NOT FOUND OR v_t.person_id IS DISTINCT FROM v_pid THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'Handoff task ' || v_id || ' does not exist for this user.');
    END IF;
    v_valid := core.fn_handoff_blocked_codes(v_t.package);
    IF NOT (v_valid ? v_code) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'unknown_blocked_code', 'valid_codes', v_valid,
            'reason', format('blocked_code "%s" is not known: use one of valid_codes', left(v_code, 60)));
    END IF;
    IF v_t.status NOT IN ('open', 'working') THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_closed',
            'reason', 'Handoff task ' || v_id || ' is ' || v_t.status || ' and cannot be deferred.');
    END IF;
    UPDATE agent.handoff_tasks SET status = 'deferred', blocked_code = v_code WHERE id = v_t.id;
    RETURN jsonb_build_object('ok', true, 'task_id', v_t.id, 'status', 'deferred', 'blocked_code', v_code, 'text', v_t.text);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_defer_handoff_task(jsonb) FROM public;

-- core.fn_handoff_blocked_codes(p_package) — gueltige blocked_code eines Pakets (sortiert): die Codes seiner Katalog-Keys
--   <package>.handoff.blocked.<code> (de). Eine Adresse fuer core.fn_defer_handoff_task und agent.fn_advisor_save_section.
CREATE OR REPLACE FUNCTION core.fn_handoff_blocked_codes(p_package text)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT COALESCE(jsonb_agg(substr(t.key, length(p_package) + 18) ORDER BY t.key), '[]'::jsonb)
      FROM core.ui_texts t
     WHERE t.lang = 'de' AND t.key ~ ('^' || p_package || '\.handoff\.blocked\.[a-z][a-z0-9_]{1,40}$')
       AND p_package ~ '^[a-z][a-z0-9_]*$';
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_blocked_codes(text) FROM public;
