-- ============================================================
-- fn_record_recurring_suggestions_sent (idempotent) -- Versand der Vorschlags-Nachrichten stempeln
--   Laeuft nach dem Senden in tool_send_recurring_suggestions: sent[] = erfolgreich gesendete {id, version} ->
--   sent_version = version (nur, wenn die Fassung noch dieselbe ist und die Zeile dem Chat gehoert); rejected[] = Zeilen,
--   deren Probelauf ablehnte -> declined mit Grund (validation_error). Eine nicht gesendete Zeile (z. B. Telegram 429)
--   bleibt ungestempelt und geht beim naechsten Aufruf erneut.
--   Eingabe p: {chat_id*, sent:[{id, version}], rejected:[{id, reason}]}.
--   RUECKGABE: {ok:true, stamped, declined}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_record_recurring_suggestions_sent(p jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_chat TEXT := NULLIF(btrim(COALESCE(p->>'chat_id', '')), '');
    v_st   INT;
    v_de   INT;
BEGIN
    UPDATE finance.import_staging s SET sent_version = s.version
    FROM jsonb_array_elements(COALESCE(p->'sent', '[]'::jsonb)) e
    WHERE s.id = (e->>'id')::int AND s.version = (e->>'version')::int
      AND s.origin = 'recurring_suggestion' AND s.chat_id = v_chat AND s.status = 'staged'
      AND s.sent_version IS DISTINCT FROM s.version;
    GET DIAGNOSTICS v_st = ROW_COUNT;
    UPDATE finance.import_staging s SET status = 'declined', validation_error = left(e->>'reason', 300)
    FROM jsonb_array_elements(COALESCE(p->'rejected', '[]'::jsonb)) e
    WHERE s.id = (e->>'id')::int AND s.origin = 'recurring_suggestion' AND s.chat_id = v_chat AND s.status = 'staged';
    GET DIAGNOSTICS v_de = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'stamped', v_st, 'declined', v_de);
END;
$$;
