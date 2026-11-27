-- ============================================================
-- agent.fn_record_handoff_check(p) (ATOMIC WRITE) — Ergebnis "Eintrag pruefen" ohne Korrektur festhalten
--   Ein erledigter Altbestand-Eintrag, den der Pruef-Schritt an den Berater uebergeben hat, passt zum Plan (Berater-Werkzeug
--   agent.tool_record_handoff_check, outcome matches) oder der Nutzer hat die Korrektur-Karte abgebrochen (Abbruch-Zweig von
--   agent.tool_record_handoff_correction, outcome kept). Je Eintrag ein Merker '<domain>:<who>:check_done:<task_id>' (source
--   plan_rollout, ohne Ablauf; who = Person bei per_user, sonst household): core.fn_plan_rollout_next haelt den Schluss danach
--   fuer diesen Eintrag nicht mehr zurueck. Eine angenommene Korrektur braucht keinen Merker (follows_task_id).
--   p: {chat_id (Pflicht, nie vom LLM), domain (Pflicht, Binding-Input), handoff_task_ids (Array oder Text mit Zahlen, Komma-
--     getrennt; 1..20), outcome (matches|kept)}.
--   Alles oder nichts: jeder Eintrag gehoert der Person des Absenders (core.fn_handoff_person), ist done ohne close_reason, hat
--   keine Folge-Aufgabe und war beim Berater (Merker ...:checked:<id> aus core.fn_handle_plan_cb). Wiederholt = kein Fehler.
--   Rueckgabe {ok:true, recorded, task_ids} | {ok:false, code, reason}: invalid_outcome, handoff_task_invalid (leer, mehr als 20,
--     unbekannt, andere Domain oder Person), handoff_task_not_legacy, handoff_task_followed, handoff_not_checked.
--   INVOKER unter der Host-Cred. Tests: tests/db/core/test_fn_record_handoff_check.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_record_handoff_check(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_domain  text := btrim(COALESCE(p->>'domain', ''));
    v_pid     text := core.fn_handoff_person(p->>'chat_id');
    v_outcome text := btrim(COALESCE(p->>'outcome', ''));
    v_ids     int[];
    v_who     text;
    v_id      int;
    t         agent.handoff_tasks%ROWTYPE;
BEGIN
    IF v_outcome NOT IN ('matches', 'kept') THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_outcome', 'reason', 'outcome must be matches or kept');
    END IF;
    BEGIN
        v_ids := CASE WHEN jsonb_typeof(p->'handoff_task_ids') = 'array'
                      THEN ARRAY(SELECT DISTINCT (x #>> '{}')::int FROM jsonb_array_elements(p->'handoff_task_ids') x)
                      ELSE ARRAY(SELECT DISTINCT btrim(x)::int FROM unnest(string_to_array(trim(both '[] ' FROM COALESCE(p->>'handoff_task_ids', '')), ',')) x
                                  WHERE btrim(x) <> '') END;
    EXCEPTION WHEN invalid_text_representation THEN
        v_ids := NULL;
    END;
    IF v_pid IS NULL OR v_domain = '' OR v_ids IS NULL OR cardinality(v_ids) = 0 OR cardinality(v_ids) > 20 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid', 'reason', 'one to twenty entry ids of the entry check are required');
    END IF;
    v_who := CASE WHEN COALESCE((SELECT cs.scope FROM core.context_scopes cs JOIN core.advisors a ON a.plan_context = cs.context_name
                                  WHERE a.domain = v_domain), 'household') = 'per_user' THEN v_pid ELSE 'household' END;

    FOREACH v_id IN ARRAY v_ids LOOP
        SELECT * INTO t FROM agent.handoff_tasks h WHERE h.id = v_id AND h.domain = v_domain AND h.person_id = v_pid;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid', 'reason', format('entry %s is not one of yours in this plan', v_id));
        END IF;
        IF t.status <> 'done' OR t.close_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_not_legacy', 'reason', format('entry %s is not an old completed entry of the entry check', v_id));
        END IF;
        IF EXISTS (SELECT 1 FROM agent.handoff_tasks f WHERE f.follows_task_id = v_id) THEN
            RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_followed', 'reason', format('entry %s already has a correction', v_id));
        END IF;
        IF core.fn_plan_rollout_latch(v_domain || ':' || v_who || ':checked:' || v_id) <> 'done' THEN
            RETURN jsonb_build_object('ok', false, 'code', 'handoff_not_checked', 'reason', format('entry %s was not handed over for the entry check', v_id));
        END IF;
    END LOOP;

    FOREACH v_id IN ARRAY v_ids LOOP
        PERFORM core.fn_should_notify('plan_rollout', v_domain || ':' || v_who || ':check_done:' || v_id, NULL);
    END LOOP;
    RETURN jsonb_build_object('ok', true, 'recorded', cardinality(v_ids), 'task_ids', to_jsonb(v_ids));
END;
$$;
REVOKE ALL ON FUNCTION agent.fn_record_handoff_check(jsonb) FROM public;
