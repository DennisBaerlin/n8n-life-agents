-- ============================================================
-- fn_mark_told (WRITE)
--   Der Owner hat einen Sofort-Hinweis gehoert: setzt den Merker '<p_pkg>:told_owner' / p_key fuer 3 Tage neu, wenn
--   p_chat_id dem Owner gehoert. Mitglied, leere, nicht-numerische oder unbekannte chat_id: kein Merker, ein
--   aelterer wird geloescht (der Fold meldet eine neue Lage, die der Owner nicht gehoert hat; der Waechter meldet dann
--   lieber doppelt, als zu schweigen).
--   Eingaben: p_pkg, p_chat_id, p_key (alle Pflicht). Rueckgabe: void. Wirft nie: ein Merker darf keine Buchung kippen.
--   3 Tage genuegen, weil der taegliche Waechter beim ersten Lauf danach seinen eigenen Merker setzt.
--   Seiteneffekt: core.fn_notify_resolve (Merker loeschen) und core.fn_should_notify (Merker setzen).
--   SECURITY DEFINER: laeuft unter <pkg>_rw; EXECUTE in fn_provision_package_roles.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_mark_told(p_pkg text, p_chat_id text, p_key text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_source text := p_pkg || ':told_owner';
BEGIN
    PERFORM core.fn_notify_resolve(v_source, p_key);
    IF COALESCE(p_chat_id, '') ~ '^[0-9]{1,18}$'
       AND agent.fn_resolve_sender(p_chat_id::bigint)->>'role' = 'owner' THEN
        PERFORM core.fn_should_notify(v_source, p_key, interval '3 days');
    END IF;
EXCEPTION WHEN OTHERS THEN
    RETURN;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_mark_told(text, text, text) FROM public;
