-- ============================================================
-- core.fn_app_intro_pending — ist die einmalige Ankuendigung der Uebersicht fuer diesen Chat noch offen?
--   Eingabe: Telegram-chat_id als Text. Der Installer sendet erst und merkt danach (core.fn_should_notify('app_intro', chat)),
--   damit ein gescheiterter Versand beim naechsten Menue-Lauf nachgeholt wird.
--   Rueckgabe: boolean. Aufrufer: postgres-Superuser. Tests: tests/db/core/test_fn_app_button_state.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_app_intro_pending(p_chat text)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog
AS $$
    SELECT NOT EXISTS (SELECT 1 FROM core.notification_state n
                        WHERE n.source = 'app_intro' AND n.key = p_chat AND n.state = 'fired');
$$;
REVOKE ALL ON FUNCTION core.fn_app_intro_pending(text) FROM public;
