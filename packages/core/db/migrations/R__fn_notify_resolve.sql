-- ============================================================
-- core.fn_notify_resolve (expliziter Re-Arm der geteilten Notify-Schicht, Phase Notify WS-1)
--   Setzt den Latch (source, key) zurueck auf 'ok' (armed) + loescht den TTL. No-op, wenn keine Zeile
--   existiert (Erholung ohne je gefeuerten Breach -> kein Fehler, kein INSERT). Das ist der EXPLIZITE
--   Re-Arm auf dem Erholungs-Pfad -- z.B. der Finance-Saldo-Trigger ruft ihn, sobald ein Konto wieder
--   ueber die reservierte Linie steigt (PagerDuty "resolve" = naechster gleicher Schluessel feuert neu).
--
--   SECURITY DEFINER (search_path-Pin + REVOKE PUBLIC): der Aufrufer (z.B. der Balance-Trigger unter
--     finance_rw) hat kein direktes core-Tabellenrecht (D10) -> Schreibzugriff nur ueber dieses Fenster.
--   Anwenden via: db_apply.ps1 -File packages\core\db\migrations\R__fn_notify_resolve.sql
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
