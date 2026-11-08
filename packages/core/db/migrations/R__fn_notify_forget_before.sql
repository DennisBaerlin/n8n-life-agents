-- ============================================================
-- core.fn_notify_forget_before(p_source, p_before) -- alte Einmal-Merker einer Quelle loeschen
--   Fuer Latches ohne TTL, deren Key nie wieder fallen kann (fn_notify_resolve wuerde sie nur re-armen).
--   Eingabe: p_source, p_before. Loescht Zeilen der Quelle mit last_fired_at < p_before. Rueckgabe: Anzahl.
--   VERTRAG: nur aufrufen, wenn ein so alter Key fachlich nicht mehr ausgeloest werden kann.
--   SECURITY DEFINER wie core.fn_should_notify (Paket-Rollen erreichen core.notification_state nur ueber Fenster, D10);
--   Grant in core.fn_provision_package_roles, nur an _rw.
--   Tests: tests/db/finance/test_fn_bank_end_reminders.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_notify_forget_before(p_source text, p_before timestamptz)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_n integer;
BEGIN
    DELETE FROM core.notification_state WHERE source = p_source AND last_fired_at < p_before;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_notify_forget_before(text, timestamptz) FROM public;
