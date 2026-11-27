-- ============================================================
-- core.fn_reopen_handoff_task(p) — eine nicht bestaetigte Eintrags-Karte gibt ihre Vormerkung sofort frei
--   Abbrechen, Ablauf oder Ablehnung der Karte eines Werkzeugs mit handoff_task_id: ohne diese Freigabe bliebe die Aufgabe
--   bis advisor.handoff_claim_ttl_minutes working und fehlte so lange in Liste und Menue, obwohl sie offen ist.
--   p: { handoff_task_id, chat_id, missing? [{tool, input}] }.
--     working -> open; claimed_at bleibt (Stelle "k von n" der Runde, und core.fn_handoff_task_check laesst sie in
--                derselben Runde weiter eintragen).
--     done    -> mit missing (die vereinbarten Aufrufe, die noch nicht eingetragen sind; das Paket leitet sie aus seinem
--                Unterschied ab) entsteht eine neue Aufgabe open mit follows_task_id und wanted = missing (ein Aufruf als
--                Objekt, mehrere als Liste); hoechstens eine je Aufgabe (UNIQUE), ein zweiter Aufruf nennt dieselbe.
--                Ohne missing unveraendert.
--     open, deferred, cancelled -> unveraendert.
--   Nur Aufgaben der Person des Absenders (core.fn_handoff_person). Erfolg {ok:true, task_id, status, follow_task_id?};
--   sonst {ok:false, code:'handoff_task_invalid', reason} (kein RAISE).
--   Aufgerufen ueber die Paket-fn im Abbruch-Zweig der Karten (finance.fn_reopen_handoff_task).
--   SECURITY DEFINER, EXECUTE an <pkg>_rw via core.fn_provision_package_roles. Tests: tests/db/core/test_fn_reopen_handoff_task.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_reopen_handoff_task(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_id      text := btrim(COALESCE(p->>'handoff_task_id', ''));
    v_pid     text := core.fn_handoff_person(p->>'chat_id');
    v_missing jsonb := CASE WHEN jsonb_typeof(p->'missing') = 'array' AND jsonb_array_length(p->'missing') > 0 THEN p->'missing' END;
    v_t       agent.handoff_tasks%ROWTYPE;
    v_follow  int;
BEGIN
    IF v_id !~ '^[0-9]{1,9}$' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'handoff_task_id must be the numeric id from the handoff task list.');
    END IF;
    SELECT * INTO v_t FROM agent.handoff_tasks WHERE id = v_id::int FOR UPDATE;
    IF NOT FOUND OR v_t.person_id IS DISTINCT FROM v_pid THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'Handoff task ' || v_id || ' does not exist for this user.');
    END IF;

    IF v_t.status = 'working' THEN
        UPDATE agent.handoff_tasks SET status = 'open' WHERE id = v_t.id;
        RETURN jsonb_build_object('ok', true, 'task_id', v_t.id, 'status', 'open');
    END IF;
    IF v_t.status = 'done' AND v_missing IS NOT NULL THEN
        INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, payload, text, why, wanted,
                                         open_point_id, follows_task_id)
        VALUES (v_t.domain, v_t.package, v_t.person_id, v_t.section_key, v_t.topic, v_t.kind, v_t.payload, v_t.text, v_t.why,
                CASE WHEN jsonb_array_length(v_missing) = 1 THEN v_missing->0 ELSE v_missing END, v_t.open_point_id, v_t.id)
        ON CONFLICT (follows_task_id) WHERE follows_task_id IS NOT NULL DO NOTHING
        RETURNING id INTO v_follow;
        IF v_follow IS NULL THEN
            SELECT f.id INTO v_follow FROM agent.handoff_tasks f WHERE f.follows_task_id = v_t.id;
        END IF;
        RETURN jsonb_build_object('ok', true, 'task_id', v_t.id, 'status', 'done', 'follow_task_id', v_follow);
    END IF;
    RETURN jsonb_build_object('ok', true, 'task_id', v_t.id, 'status', v_t.status);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_reopen_handoff_task(jsonb) FROM public;
