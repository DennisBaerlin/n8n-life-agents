-- ============================================================
-- core.fn_app_bot_username (READ) — echter Benutzername des Bots fuer die Mini-App, sonst NULL
--   Platzhalter (Wert = default_value, ab Werk your_bot) und ungueltige Werte gelten als unbekannt: die App zeigt dann
--   keinen Knopf „Im Chat fragen“, statt auf einen fremden Bot zu zeigen.
--   Rueckgabe: text | NULL. Tests: tests/db/core/test_fn_set_bot_username.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_app_bot_username()
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog
AS $$
    SELECT c.value FROM core.config c
     WHERE c.category = 'telegram' AND c.key = 'bot_username'
       AND c.value IS DISTINCT FROM c.default_value
       AND c.value ~ '^[A-Za-z0-9_]{5,32}$';
$$;
