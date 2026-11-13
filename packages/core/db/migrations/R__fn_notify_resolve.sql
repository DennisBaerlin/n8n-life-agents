-- ============================================================
-- fn_notify_resolve (WRITE)
--   Expliziter Re-Arm der geteilten Notify-Schicht. Eingabe: p_source, p_key. Rueckgabe: void.
--   Setzt den Latch (source, key) zurueck auf 'ok' (armed) + loescht den TTL. No-op, wenn keine Zeile
--   existiert (Erholung ohne je gefeuerten Breach -> kein Fehler, kein INSERT). Das ist der explizite
--   Re-Arm auf dem Erholungs-Pfad, z. B. der Finance-Saldo-Trigger ruft ihn, sobald ein Konto wieder
--   ueber die reservierte Linie steigt (PagerDuty "resolve" = naechster gleicher Schluessel feuert neu).
--
--   SECURITY DEFINER (search_path-Pin + REVOKE PUBLIC): der Aufrufer (z.B. der Balance-Trigger unter
--     finance_rw) hat kein direktes core-Tabellenrecht (D10) -> Schreibzugriff nur ueber dieses Fenster.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_notify_resolve(p_source text, p_key text)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    UPDATE core.notification_state
    SET state = 'ok', expires_at = NULL, updated_at = now()
    WHERE source = p_source AND key = p_key;
$$;

REVOKE ALL ON FUNCTION core.fn_notify_resolve(text, text) FROM public;
