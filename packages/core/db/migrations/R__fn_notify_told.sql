-- ============================================================
-- fn_notify_told (READ)
--   Lese-Sicht der geteilten Notify-Schicht. Liefert true, wenn der Merker (p_source, p_key) gemeldet ist und nicht abgelaufen. Schreibt nichts. Grundlage von
--   told_keys in core.fn_advisor_review_evaluate: dieselbe Lage ueber zwei Wege wird nur einmal gesagt.
--   Eingaben: p_source, p_key. Rueckgabe: boolean.
--   SECURITY DEFINER: Paket-Rollen haben kein Tabellenrecht auf core.notification_state; EXECUTE in fn_provision_package_roles.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_notify_told(p_source text, p_key text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM core.notification_state
        WHERE source = p_source AND key = p_key AND state = 'fired'
          AND (expires_at IS NULL OR expires_at > now()));
$$;

REVOKE ALL ON FUNCTION core.fn_notify_told(text, text) FROM public;
