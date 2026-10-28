-- ============================================================
-- core.fn_menu_refresh_finish(p_gen bigint, p_ok boolean) — Menue-Auftrag der Mini-App abschliessen (WRITE, Betrieb)
--   Gegenstueck zu core.fn_menu_refresh_claim; Aufrufer nur bash als Superuser (_set_bot_menu_buttons).
--   p_ok = true  (alle Knoepfe gesetzt): done_gen = GREATEST(done_gen, LEAST(p_gen, requested_gen)) -> genau bis zur
--                uebernommenen Generation, nie zurueck; retry_after weg.
--   p_ok = false (Telegram/DB scheiterte): nichts geschlossen, retry_after = now() + 10 Min (der minuetliche Runner
--                ruft Telegram nicht jede Minute vergeblich; doctor meldet einen Auftrag, der > 30 Min offen ist).
--   Tests: tests/db/core/test_fn_menu_refresh.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_menu_refresh_finish(p_gen bigint, p_ok boolean)
RETURNS void
LANGUAGE sql
SET search_path = pg_catalog
AS $$
    UPDATE core.menu_refresh
       SET done_gen    = CASE WHEN p_ok THEN GREATEST(done_gen, LEAST(COALESCE(p_gen, 0), requested_gen)) ELSE done_gen END,
           retry_after = CASE WHEN p_ok THEN NULL ELSE now() + interval '10 minutes' END;
$$;

REVOKE ALL ON FUNCTION core.fn_menu_refresh_finish(bigint, boolean) FROM public;
