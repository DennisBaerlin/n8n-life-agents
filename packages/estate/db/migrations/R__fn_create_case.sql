-- ============================================================
-- estate.fn_create_case (ATOMIC WRITE — WS-3, Break-Glass owner_info)
--   Legt einen Ereignisfall (death/incapacity) an und instanziiert die Fristen-Checkliste. Validierung
--   + Preview kommen aus DERSELBEN fn (estate.fn_preview_case) — re-validiert zur Write-Zeit (eine
--   Quelle, kein TOCTOU). Bei {ok:false} wird das Preview-Verdikt durchgereicht (korrigierbar, kein
--   RAISE -> kein Owner-Alert).
--   AUTO-SUPERSEDE: ein offener incapacity-Fall derselben Person wird beim Anlegen eines death-Falls in
--   DERSELBEN Tx auf 'superseded' gesetzt, BEVOR der death-Fall einfuegt (sonst blockte der
--   partial-UNIQUE(subject) WHERE open) — die Todesnachricht scheitert nie am Doppelfall.
--   adults_only-DB-Backstop (im Preview). Eingabe jsonb: chat_id, subject_person_id (Slug, vom Tool
--   aufgeloest), case_type, event_date, knowledge_date (optional), bundesland (optional), flags (jsonb).
--   RUECKGABE: {ok:true, case_id, case_type, status, superseded_case_id, phase_counts, total_open}
--     | {ok:false, reason} (das Preview-Verdikt).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_create_case.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_create_case(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_prev   JSONB;
    v_super  BIGINT;
    v_id     BIGINT;
    v_counts JSONB;
    v_total  INT;
BEGIN
    v_prev := estate.fn_preview_case(p);
    IF NOT COALESCE((v_prev->>'ok')::boolean, false) THEN
        RETURN v_prev;
    END IF;

    v_super := NULLIF(v_prev->>'supersede_case_id', '')::bigint;
    IF v_super IS NOT NULL THEN
        UPDATE estate.cases SET status = 'superseded', closed_at = now()
         WHERE id = v_super AND status = 'open';
    END IF;

    INSERT INTO estate.cases (case_type, subject_person_id, event_date, knowledge_date, bundesland, flags)
    VALUES (v_prev->>'case_type', v_prev->>'subject_person_id',
            (v_prev->>'event_date')::date, (v_prev->>'knowledge_date')::date, v_prev->>'bundesland',
            COALESCE(p->'flags', '{}'::jsonb))
    RETURNING id INTO v_id;

    PERFORM estate.fn_instantiate_case_tasks(v_id);

    SELECT COALESCE(jsonb_object_agg(phase, cnt), '{}'::jsonb), COALESCE(sum(cnt), 0)::int
      INTO v_counts, v_total
      FROM (SELECT phase, count(*) AS cnt FROM estate.case_tasks
             WHERE case_id = v_id AND status = 'open' GROUP BY phase) s;

    RETURN jsonb_build_object(
        'ok', true,
        'case_id', v_id,
        'case_type', v_prev->>'case_type',
        'status', 'open',
        'superseded_case_id', v_super,
        'phase_counts', v_counts,
        'total_open', v_total);
END;
$$;
