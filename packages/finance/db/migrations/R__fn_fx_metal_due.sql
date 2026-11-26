-- ============================================================
-- fn_fx_metal_due (READ, STABLE) -- welche Tage der FX-Cron je Edelmetall holt
--   Je Metall aus finance.currencies (kind = 'metal', geseedet: XAU, XAG) eine Zeile: from = juengster gespeicherter Tag
--   des Metalls (wird erneut geholt: der Mischkurs vieler Zentralbanken eines Tages kann sich nach dem ersten Abruf noch
--   aendern), ohne Zeile Haushalts-Tag minus 5 Jahre (einmaliger Nachlauf); to = UTC-Datum
--   (einen spaeteren Tag kennt die Quelle nicht). Immer faellig, nicht an einen Waechter gekoppelt (Verfuegbarkeit haengt
--   nicht am Bedarf); laeuft im FX-Cron einmal je Tages-Abruf, ein gescheiterter Abruf kommt mit dem naechsten. Einen
--   Ausfall meldet der einzelne Waechter (Altersgrenze monitor.fx_stale_days), keine eigene Feed-Meldung.
--   Eingabe: keine. Rueckgabe: Tabelle (metal text, from_date date, to_date date).
--   Tests: tests/db/finance/test_fn_fx_metal_due.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_fx_metal_due()
RETURNS TABLE (metal text, from_date date, to_date date) LANGUAGE sql STABLE AS $$
    SELECT c.code::text,
           LEAST(COALESCE(
               (SELECT max(r.as_of) FROM finance.fx_rates r WHERE r.base_currency = 'EUR' AND r.quote_currency = c.code),
               (core.fn_today() - interval '5 years')::date), (now() AT TIME ZONE 'UTC')::date),
           (now() AT TIME ZONE 'UTC')::date
    FROM finance.currencies c
    WHERE c.kind = 'metal'
    ORDER BY c.code;
$$;
