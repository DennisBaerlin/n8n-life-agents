-- ============================================================
-- core.fn_menu_refresh_finish(p_gen bigint, p_ok boolean) — Menue-Auftrag der Mini-App abschliessen (WRITE, Betrieb)
--   Gegenstueck zu core.fn_menu_refresh_claim; Aufrufer nur bash als Superuser (_set_bot_menu_buttons, der Runner
--   ohne Bot-Token).
--   p_ok = true  (alle Knoepfe gesetzt): done_gen = GREATEST(done_gen, LEAST(p_gen, requested_gen)) -> genau bis zur
--                uebernommenen Generation, nie zurueck; Fehlerzaehler, retry_after und gave_up_at weg.
--   p_ok = false (Telegram/Token scheiterte): retry_after = now() + 10 Min (der minuetliche Runner ruft Telegram nicht
--                jede Minute vergeblich). Beim DRITTEN Fehlschlag in Folge gibt der Auftrag auf (Generation
--                geschlossen, gave_up_at gestempelt): ein Chat, der den Bot blockiert, haelt sonst ewig einen Auftrag
--                offen. Der naechste Ausloeser oder das naechste Update versucht es wieder; doctor meldet die Aufgabe.
--   Tests: tests/db/core/test_fn_menu_refresh.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_menu_refresh_finish(p_gen bigint, p_ok boolean)
RETURNS void
LANGUAGE sql
SET search_path = pg_catalog
AS $$
    UPDATE core.menu_refresh                            -- rechte Seiten lesen die ALTEN Werte (eine Zeile)
       SET done_gen    = CASE WHEN p_ok OR failures + 1 >= 3
                              THEN GREATEST(done_gen, LEAST(COALESCE(p_gen, 0), requested_gen)) ELSE done_gen END,
           retry_after = CASE WHEN p_ok OR failures + 1 >= 3 THEN NULL ELSE now() + interval '10 minutes' END,
           gave_up_at  = CASE WHEN p_ok THEN NULL WHEN failures + 1 >= 3 THEN now() ELSE gave_up_at END,
           failures    = CASE WHEN p_ok OR failures + 1 >= 3 THEN 0 ELSE failures + 1 END;
$$;

REVOKE ALL ON FUNCTION core.fn_menu_refresh_finish(bigint, boolean) FROM public;
