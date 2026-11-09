-- ============================================================
-- agent.fn_monitor_reset_unsent (ATOMIC WRITE — Fehlerweg von `Send alerts` im Heartbeat-Cron)
--   Macht die Ausloesung eines Laufs rueckgaengig, dessen Sammel-Nachricht nicht zugestellt wurde. Nur status='fired' wird
--   wieder armed; last_value und reference_value bleiben (Ratchet nie aus einem nicht gemeldeten Lauf zurueckdrehen).
--   Termine pruefen sofort wieder (ein One-Shot ohne erneuten Wert), Werte zum naechsten Prueftermin und nur, wenn die
--   Bedingung dann noch gilt. Ein Termin laenger als monitor.unsent_retry_days nach due_date bleibt fired, damit ein dauerhafter
--   Sendefehler (z. B. zu langer Text) nicht ewig stuendlich wiederholt.
--   Eingabe jsonb: { trigger_ids?: [int], problem_ids?: [int] } (problem_ids werden nachgereicht: problem_pending_at).
--   Rueckgabe: { ok, reset:[id], problems_pending:[id], gave_up:[{id,label}] }.
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_monitor_reset_unsent(p jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_days     INT := COALESCE((SELECT c.value::int FROM core.config c
                                 WHERE c.category = 'monitor' AND c.key = 'unsent_retry_days'), 3);
    v_today    DATE := core.fn_today();
    v_ids      INT[] := ARRAY(SELECT (x)::int FROM jsonb_array_elements_text(COALESCE(p->'trigger_ids', '[]'::jsonb)) x);
    v_prob     INT[] := ARRAY(SELECT (x)::int FROM jsonb_array_elements_text(COALESCE(p->'problem_ids', '[]'::jsonb)) x);
    v_reset    JSONB;
    v_pending  JSONB;
    v_gave_up  JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', t.id, 'label', t.label) ORDER BY t.id), '[]'::jsonb) INTO v_gave_up
      FROM agent.monitor_triggers t
     WHERE t.id = ANY(v_ids) AND t.status = 'fired' AND t.trigger_type = 'date' AND v_today > t.due_date + v_days;

    WITH upd AS (
        UPDATE agent.monitor_triggers t
           SET status = 'armed', fired_at = NULL,
               next_check_at = CASE WHEN t.trigger_type = 'date' THEN now() ELSE t.next_check_at END
         WHERE t.id = ANY(v_ids) AND t.status = 'fired'
           AND NOT (t.trigger_type = 'date' AND v_today > t.due_date + v_days)
        RETURNING t.id)
    SELECT COALESCE(jsonb_agg(id ORDER BY id), '[]'::jsonb) INTO v_reset FROM upd;

    WITH upd AS (
        UPDATE agent.monitor_triggers t SET problem_pending_at = now()
         WHERE t.id = ANY(v_prob)
        RETURNING t.id)
    SELECT COALESCE(jsonb_agg(id ORDER BY id), '[]'::jsonb) INTO v_pending FROM upd;

    RETURN jsonb_build_object('ok', true, 'reset', v_reset, 'problems_pending', v_pending, 'gave_up', v_gave_up);
END;
$$;
