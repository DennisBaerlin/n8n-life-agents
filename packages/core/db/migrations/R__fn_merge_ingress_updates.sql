-- ============================================================
-- fn_merge_ingress_updates (READ-ONLY) — mehrere Telegram-Updates eines Absenders zu einem Update zusammenfuehren
--   Die eine Regel fuer die Eingangs-Buendelung (agent.fn_claim_ingress_burst) und das Nachspielen gemerkter Nachrichten
--   nach einer KI-Pause (core.fn_handle_llm_cb): Primaer = frueheste Datei (message.photo | message.document), sonst das
--   erste Update; weitere Dateien in Reihenfolge -> message.extra_files [{file_id, type photo|document, file_name?}] (Foto:
--   groesste Aufloesung; schon vorhandene extra_files eines Eingangs-Updates bleiben an ihrer Stelle erhalten);
--   Texte/Bildunterschriften in Reihenfolge mit Leerzeile -> caption (mit Datei) bzw. text;
--   entities/caption_entities fallen weg (ihre Offsets passten nicht mehr).
--   Eingabe: p_updates jsonb = Array der Updates in Nachrichten-Reihenfolge (der Aufrufer sortiert).
--   Rueckgabe: das zusammengefuehrte Update; ein Element -> unveraendert; leer/kein Array -> NULL.
--   Tests: tests/db/core/test_fn_ingress_buffer.sql, tests/db/core/test_fn_handle_llm_cb.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_merge_ingress_updates(p_updates jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_n       int;
    v_file    int;     -- Index der fruehesten Datei
    v_primary jsonb;
    v_msg     jsonb;
    v_text    text;
    v_extra   jsonb;
BEGIN
    IF jsonb_typeof(p_updates) IS DISTINCT FROM 'array' OR jsonb_array_length(p_updates) = 0 THEN
        RETURN NULL;
    END IF;
    v_n := jsonb_array_length(p_updates);
    IF v_n = 1 THEN
        RETURN p_updates->0;
    END IF;
    SELECT min(i) INTO v_file
      FROM generate_series(0, v_n - 1) i
     WHERE jsonb_typeof(p_updates->i->'message'->'photo') = 'array' OR jsonb_typeof(p_updates->i->'message'->'document') = 'object';
    v_primary := p_updates->COALESCE(v_file, 0);
    SELECT string_agg(t, E'\n\n' ORDER BY i) INTO v_text
      FROM (SELECT i, NULLIF(btrim(COALESCE(p_updates->i->'message'->>'text', p_updates->i->'message'->>'caption', '')), '') AS t
              FROM generate_series(0, v_n - 1) i) s
     WHERE t IS NOT NULL;
    v_msg := (v_primary->'message') - 'text' - 'caption' - 'entities' - 'caption_entities' - 'extra_files';
    IF v_text IS NOT NULL THEN
        v_msg := v_msg || jsonb_build_object(CASE WHEN v_file IS NULL THEN 'text' ELSE 'caption' END, v_text);
    END IF;
    -- je Update in Reihenfolge: seine eigene Datei (ausser der primaeren) und seine schon vorhandenen extra_files (ein gemerktes
    -- Update kann selbst ein Buendel sein; sonst gingen dessen weitere Dateien beim Nachspielen verloren)
    SELECT jsonb_agg(f ORDER BY i, j) INTO v_extra FROM (
        SELECT i, 0 AS j, jsonb_strip_nulls(jsonb_build_object(
                   'file_id', COALESCE(m->'photo'->(jsonb_array_length(m->'photo') - 1)->>'file_id', m->'document'->>'file_id'),
                   'type', CASE WHEN m ? 'photo' THEN 'photo' ELSE 'document' END,
                   'file_name', m->'document'->>'file_name')) AS f
          FROM (SELECT i, p_updates->i->'message' AS m FROM generate_series(0, v_n - 1) i) x
         WHERE (jsonb_typeof(m->'photo') = 'array' OR jsonb_typeof(m->'document') = 'object') AND i IS DISTINCT FROM v_file
        UNION ALL
        SELECT i, t.ord AS j, t.e AS f
          FROM generate_series(0, v_n - 1) i,
               jsonb_array_elements(CASE WHEN jsonb_typeof(p_updates->i->'message'->'extra_files') = 'array'
                                         THEN p_updates->i->'message'->'extra_files' ELSE '[]'::jsonb END) WITH ORDINALITY AS t(e, ord)) s;
    IF v_extra IS NOT NULL THEN
        v_msg := v_msg || jsonb_build_object('extra_files', v_extra);
    END IF;
    RETURN jsonb_set(v_primary, '{message}', v_msg);
END;
$$;
