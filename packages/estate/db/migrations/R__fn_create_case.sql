-- ============================================================
-- estate.fn_create_case (ATOMIC WRITE — Break-Glass owner_info)
--   Legt einen Ereignisfall (death/incapacity) an und instanziiert die Fristen-Checkliste. Validierung
--   + Preview kommen aus derselben fn (estate.fn_preview_case) — re-validiert zur Write-Zeit (eine
--   Quelle, kein TOCTOU). Bei {ok:false} wird das Preview-Verdikt durchgereicht (korrigierbar, kein
--   RAISE -> kein Owner-Alert).
--   Auto-Supersede: ein offener incapacity-Fall derselben Person wird beim Anlegen eines death-Falls in
--   derselben Tx auf 'superseded' gesetzt, bevor der death-Fall einfuegt (sonst blockte der
--   partial-UNIQUE(subject) WHERE open) — die Todesnachricht scheitert nie am Doppelfall.
--   adults_only-DB-Backstop (im Preview). Eingabe jsonb: chat_id, subject_person_id (Slug, vom Tool
--   aufgeloest), case_type, event_date, knowledge_date (optional), bundesland (optional), flags (jsonb).
--   flags = nur Nutzer-Aussagen (true/false, null faellt weg); der Rest kommt live aus dem Register.
--   special_assets (optional, Array von {asset_type, description}) = im Gespraech genannte Sonderfaelle (Waffe, Tier,
--   Fahrzeug, Firma): die Stubs entstehen in derselben Tx (Besitzer = betroffene Person), danach erzeugt fan_out die
--   Pflicht-Aufgaben. Validierung/Dubletten/"Typ ohne Vorlage im Falltyp" kommen aus fn_preview_case. Eine Absage
--   des Falls (fn_cancel_case) laesst die Stubs stehen: der Gegenstand existiert real; irrtuemlich angelegte Eintraege
--   entfernt tool_delete_special_asset.
--   Rueckgabe: {ok:true, case_id, case_type, status, superseded_case_id, phase_counts, total_open, intake_facts,
--     unknown_flags, special_asset_ids (neu angelegte Stubs, [] wenn keine)}
--     | {ok:false, reason} (das Preview-Verdikt).
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_create_case(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_prev   JSONB;
    v_super  BIGINT;
    v_id     BIGINT;
    v_counts JSONB;
    v_total  INT;
    v_asset_ids JSONB;
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
            -- nur Nutzer-Aussagen (true/false); Unbeantwortetes leitet fn_case_template_rows aus dem Register ab
            CASE WHEN jsonb_typeof(p->'flags') = 'object' THEN jsonb_strip_nulls(p->'flags') ELSE '{}'::jsonb END)
    RETURNING id INTO v_id;

    -- Genannte Sonderfaelle: exakt die Stubs, die die Preview als neu gemeldet hat (Dubletten sind dort schon raus),
    -- vor der Instanziierung, damit fan_out die Pflicht-Aufgaben in derselben Tx anlegt. Besitzer = betroffene Person.
    WITH ins AS (
        INSERT INTO estate.special_assets (owner_person_id, asset_type, description)
        SELECT v_prev->>'subject_person_id', e->>'asset_type', e->>'description'
          FROM jsonb_array_elements(COALESCE(v_prev->'special_assets', '[]'::jsonb)) WITH ORDINALITY x(e, ord)
         ORDER BY ord
        RETURNING id)
    SELECT COALESCE(jsonb_agg(id ORDER BY id), '[]'::jsonb) INTO v_asset_ids FROM ins;

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
        'total_open', v_total,
        'intake_facts', v_prev->'intake_facts',
        'unknown_flags', v_prev->'unknown_flags',
        'special_asset_ids', v_asset_ids);
END;
$$;
