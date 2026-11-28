-- ============================================================
-- core.fn_handoff_task_check(p) — darf dieser Write die vereinbarte Plan-Aufgabe abschliessen?
--   p: { handoff_task_id, chat_id }. Gueltig nur, wenn die Aufgabe existiert, der Person des Absenders gehoert
--   (core.fn_handoff_person) und working ist (per [Jetzt eintragen] beansprucht) oder in dieser Runde wieder freigegeben wurde
--   (open mit Claim juenger als advisor.handoff_claim_ttl_minutes: Karte nicht bestaetigt, core.fn_reopen_handoff_task, oder uebersprungen, core.fn_cancel_handoff_task skipped; so traegt ein "doch
--   eintragen" im selben Gespraech ohne neuen Tipp auf die Liste ein; ebenso die Folge-Aufgabe einer in dieser Runde
--   beanspruchten). Erfolg {ok:true, task_id (= handoff_task_id), kind, text, part:false}.
--   Weiterer Teil: eine Vormerkung kann mehrere Eintraege brauchen (zwei jaehrliche Uebertraege fuer eine Vereinbarung);
--   eine in dieser Runde erledigte Aufgabe (done mit einem Eintrag, nicht close_reason done_elsewhere; Abschluss nach dem Claim
--   und juenger als advisor.handoff_claim_ttl_minutes) gilt deshalb weiter -> {ok:true, …, part:true}, ausser ihr Rest ist schon als
--   Folge-Aufgabe abgespalten (die Ablehnung nennt deren id). Sonst {ok:false, code:'handoff_task_invalid', reason}
--   (korrigierbar, kein RAISE). Nur lesend.
--   Konsumenten: finance.fn_with_handoff (Probelauf und Write der Ziel-fn), core.fn_complete_handoff_task.
--   SECURITY DEFINER (die Paket-Schreibrolle sieht agent.* nicht), EXECUTE an <pkg>_rw via core.fn_provision_package_roles.
--   Tests: tests/db/core/test_fn_handoff_tasks.sql, tests/db/core/test_fn_reopen_handoff_task.sql
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
    v_follow int;
    v_ttl int := core.fn_handoff_claim_ttl();
BEGIN
    IF v_id !~ '^[0-9]{1,9}$' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'handoff_task_id must be the numeric id from the handoff task list.');
    END IF;
    SELECT id, kind, text, status, person_id, claimed_at, closed_at, close_reason, follows_task_id INTO v_t FROM agent.handoff_tasks WHERE id = v_id::int;
    IF NOT FOUND OR v_t.person_id IS DISTINCT FROM v_pid THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'Handoff task ' || v_id || ' does not exist for this user. Re-read the task list or leave handoff_task_id empty.');
    END IF;
    -- eine Folge-Aufgabe wird ohne eigenen Claim eingetragen (claimed_at leer): ihr Abschluss zaehlt dann selbst als Runde
    IF v_t.status = 'done' AND v_t.close_reason IS DISTINCT FROM 'done_elsewhere' AND v_t.closed_at >= COALESCE(v_t.claimed_at, v_t.closed_at) AND v_t.closed_at > now() - make_interval(mins => v_ttl) THEN
        -- was noch fehlt, laeuft ueber die Folge-Aufgabe (core.fn_reopen_handoff_task); unter der alten stuende es sonst doppelt da
        SELECT f.id INTO v_follow FROM agent.handoff_tasks f WHERE f.follows_task_id = v_t.id;
        IF v_follow IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
                'reason', 'Handoff task ' || v_id || ' is done; what is left of it continues as handoff task ' || v_follow || '. Use handoff_task_id ' || v_follow || ' for it.');
        END IF;
        RETURN jsonb_build_object('ok', true, 'task_id', v_t.id, 'kind', v_t.kind, 'text', v_t.text, 'part', true);
    END IF;
    IF v_t.status = 'open' AND (v_t.claimed_at > now() - make_interval(mins => v_ttl)
                                OR EXISTS (SELECT 1 FROM agent.handoff_tasks o WHERE o.id = v_t.follows_task_id
                                              AND o.claimed_at > now() - make_interval(mins => v_ttl))) THEN
        RETURN jsonb_build_object('ok', true, 'task_id', v_t.id, 'kind', v_t.kind, 'text', v_t.text, 'part', false);
    END IF;
    IF v_t.status = 'open' THEN
        -- ohne handoff_task_id eingetragen bliebe die Aufgabe offen und kaeme spaeter ein zweites Mal
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'Handoff task ' || v_id || ' is open but not started: the user starts it with the button on the list of agreed entries. Do not enter it without that.');
    END IF;
    IF v_t.status <> 'working' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'Handoff task ' || v_id || ' is ' || v_t.status || ', not in progress. Do not book it again; leave handoff_task_id empty for a new entry.');
    END IF;
    RETURN jsonb_build_object('ok', true, 'task_id', v_t.id, 'kind', v_t.kind, 'text', v_t.text, 'part', false);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_task_check(jsonb) FROM public;
