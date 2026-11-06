-- ============================================================
-- fn_end_recurring_chain (INTERNAL HELPER — not tool-facing)
--   Beendet ALLE noch laufenden Glieder der Vorgaenger-Kette einer recurring_payment zum Tag p_end (status='paused',
--   valid_to = p_end exklusiv; ein Glied, das erst spaeter beginnt, bekommt valid_to = valid_from = leerer Bereich).
--   Bereits frueher beendete Glieder bleiben unberuehrt. Grund (Audit Paket 2, Review): nach einer Betragsaenderung
--   mit Stichtag in der Zukunft laeuft die ALTE rp bis zum Stichtag weiter (noch anstehende Ausfuehrung) -- wer nur den
--   Kopf beendet, laesst sie weiter faellig werden (Erinnerung fuer einen geschlossenen Plan).
--   Gerufen von fn_close_savings_plan und fn_close_savings_goal.
--   RUECKGABE: Anzahl beendeter Glieder.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_end_recurring_chain(p_rp_id int, p_end date)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    v_n INT;
BEGIN
    UPDATE finance.recurring_payments
    SET status = 'paused', valid_to = GREATEST(valid_from, p_end)
    WHERE id IN (SELECT finance.fn_recurring_lineage(p_rp_id))
      AND (valid_to IS NULL OR valid_to > p_end);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$$;
