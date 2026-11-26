-- ============================================================
-- core.fn_handoff_task_check(p) — darf dieser Write die vereinbarte Plan-Aufgabe abschliessen?
--   p: { handoff_task_id, chat_id }. Gueltig nur, wenn die Aufgabe existiert, der Person des Absenders gehoert
--   (core.fn_handoff_person) und working ist (per [Jetzt eintragen] beansprucht). Erfolg {ok:true, task_id, kind, text, part:false}.
--   Weiterer Teil: eine Vormerkung kann mehrere Eintraege brauchen (zwei jaehrliche Uebertraege fuer eine Vereinbarung);
--   eine in dieser Runde erledigte Aufgabe (done, Abschluss nach dem Claim und juenger als advisor.handoff_claim_ttl_minutes)
--   gilt deshalb weiter -> {ok:true, …, part:true}. Sonst {ok:false, code:'handoff_task_invalid', reason} (korrigierbar,
--   kein RAISE). Nur lesend.
--   Konsumenten: finance.fn_with_handoff (Probelauf und Write der Ziel-fn), core.fn_complete_handoff_task.
--   SECURITY DEFINER (die Paket-Schreibrolle sieht agent.* nicht), EXECUTE an <pkg>_rw via core.fn_provision_package_roles.
--   Tests: tests/db/core/test_fn_handoff_tasks.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_task_check(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_id  text := btrim(COALESCE(p->>'handoff_task_id', ''));
    v_pid text := core.fn_handoff_person(p->>'chat_id');
    v_t   record;
    v_ttl int := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'handoff_claim_ttl_minutes'), '')::int, 120);
BEGIN
    IF v_id !~ '^[0-9]{1,9}$' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'handoff_task_id must be the numeric id from the handoff task list.');
    END IF;
    SELECT id, kind, text, status, person_id, claimed_at, closed_at INTO v_t FROM agent.handoff_tasks WHERE id = v_id::int;
    IF NOT FOUND OR v_t.person_id IS DISTINCT FROM v_pid THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'Handoff task ' || v_id || ' does not exist for this user. Re-read the task list or leave handoff_task_id empty.');
    END IF;
    IF v_t.status = 'done' AND v_t.closed_at >= v_t.claimed_at AND v_t.closed_at > now() - make_interval(mins => v_ttl) THEN
        RETURN jsonb_build_object('ok', true, 'task_id', v_t.id, 'kind', v_t.kind, 'text', v_t.text, 'part', true);
    END IF;
    IF v_t.status <> 'working' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'Handoff task ' || v_id || ' is ' || v_t.status || ', not in progress. Do not book it again; leave handoff_task_id empty for a new entry.');
    END IF;
    RETURN jsonb_build_object('ok', true, 'task_id', v_t.id, 'kind', v_t.kind, 'text', v_t.text, 'part', false);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_task_check(jsonb) FROM public;
