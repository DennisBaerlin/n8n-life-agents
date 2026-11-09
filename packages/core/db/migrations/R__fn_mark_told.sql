-- ============================================================
-- core.fn_mark_told (Sofort-Hinweis hat der Owner gehoert)
--   Setzt den Merker '<p_pkg>:told_owner' / p_key fuer 3 Tage, wenn p_chat_id dem Owner gehoert. Mitglied, leere,
--   nicht-numerische oder unbekannte chat_id: kein Merker (der Waechter meldet dann lieber doppelt, als zu schweigen).
--   Eingaben: p_pkg, p_chat_id, p_key. Rueckgabe: void. Wirft nie: ein Merker darf keine Buchung kippen.
--   3 Tage genuegen, weil der taegliche Waechter beim ersten Lauf danach seinen eigenen Merker setzt.
--   SECURITY DEFINER: laeuft unter <pkg>_rw; EXECUTE in fn_provision_package_roles.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_mark_told(p_pkg text, p_chat_id text, p_key text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF p_chat_id !~ '^[0-9]{1,18}$' THEN
        RETURN;
    END IF;
    IF agent.fn_resolve_sender(p_chat_id::bigint)->>'role' IS DISTINCT FROM 'owner' THEN
        RETURN;
    END IF;
    PERFORM core.fn_should_notify(p_pkg || ':told_owner', p_key, interval '3 days');
EXCEPTION WHEN OTHERS THEN
    RETURN;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_mark_told(text, text, text) FROM public;
