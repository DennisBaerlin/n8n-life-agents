-- ============================================================
-- fn_notify_commit (WRITE)
--   Schreibt einen beanspruchten Merker (p_source, p_key) nach erfolgreichem Senden fest. Rueckgabe: void.
--   Claim mit Frist (core.fn_should_notify ... '30 minutes') -> Senden -> diese fn nimmt die Frist weg, der Schritt ist erledigt.
--   Scheitert das Senden, setzt core.fn_notify_resolve zurueck; stirbt der Lauf dazwischen, laeuft die Frist aus. Nur state='fired'.
--   SECURITY DEFINER (Muster core.fn_notify_resolve): enge Rollen erreichen core.notification_state nur ueber dieses Fenster.
--   Tests: tests/db/core/test_fn_notify_commit.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_notify_commit(p_source text, p_key text)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    UPDATE core.notification_state
    SET expires_at = NULL, updated_at = now()
    WHERE source = p_source AND key = p_key AND state = 'fired';
$$;

REVOKE ALL ON FUNCTION core.fn_notify_commit(text, text) FROM public;
