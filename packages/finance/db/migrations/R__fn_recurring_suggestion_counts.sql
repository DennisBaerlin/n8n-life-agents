-- ============================================================
-- fn_recurring_suggestion_counts (STABLE) -- wie viele Dauerauftrags-Vorschlaege eines Chats offen sind
--   Die eine Zaehlung fuer fn_get_recurring_suggestion_queue (open_count, sent_before) und den Prompt-Abschnitt des
--   Buchhalters (agent.finance, Knoten Onboarding status read). Offen = staged im nicht abgelaufenen Stapel
--   (fn_recurring_suggestion_expired) dieses Chats; sent = davon in der aktuellen Fassung schon geschickt.
--   Keine Rollenpruefung: Kinder erreichen den Buchhalter nicht (Haushalts-Sicht-Gate), die Queue prueft selbst.
--   plpgsql: fn_recurring_suggestion_expired sortiert als R__ spaeter (late binding).
--   Eingabe: p_chat_id (text; NULL/leer -> 0).
--   RUECKGABE: {open, sent, unsent}.
--   Tests: tests/db/finance/test_fn_get_recurring_suggestion_queue.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_suggestion_counts(p_chat_id text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_open int;
    v_sent int;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE s.sent_version = s.version) INTO v_open, v_sent
    FROM finance.import_staging s
    WHERE s.origin = 'recurring_suggestion' AND s.chat_id = NULLIF(btrim(COALESCE(p_chat_id, '')), '') AND s.status = 'staged'
      AND NOT finance.fn_recurring_suggestion_expired(s.batch_id);
    RETURN jsonb_build_object('open', v_open, 'sent', v_sent, 'unsent', v_open - v_sent);
END;
$$;
