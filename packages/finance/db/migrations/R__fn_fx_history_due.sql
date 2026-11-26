-- ============================================================
-- fn_fx_history_due (READ, STABLE) -- welche EZB-Tage muss der FX-Cron holen?
--   Der Tages-Feed (open.er-api.com) liefert keine Vergangenheit und faellt gelegentlich aus. Der FX-Cron holt deshalb
--   EZB-Referenzkurse (Frankfurter, nur EZB) und schreibt sie per finance.fn_upsert_fx_rates (Zeilen-Modus, source ecb,
--   ein vorhandener Kurs desselben Tages gewinnt). Zwei Faelle, eine Antwort:
--     Nachlauf: keine Zeile der EZB-Quelle (fn_fx_history_source) -> die letzten 5 Jahre; ein gescheiterter Abruf wird
--       beim naechsten Lauf wiederholt.
--     Ersatzquelle: der Tages-Feed hat fuer UTC-heute nichts geliefert (juengstes Feed-as_of < UTC-heute oder keines) und
--       auch sonst liegt kein Kurs von heute -> ab dem Tag nach dem juengsten Kurs (gleich welcher Quelle) bis heute.
--       Laeuft mit dem stuendlichen Nachholen, solange der Feed faellig bleibt (fn_feed_refresh_due); die EZB
--       veroeffentlicht werktags gegen 16 Uhr MEZ, frueher oder am Wochenende kommt eine leere Antwort.
--   Waehrungen ausserhalb der EZB-Liste (rund 30) bleiben ohne Vergangenheit und ohne Ersatz.
--   Eingabe: keine. Rueckgabe: jsonb {due boolean, from date, to date (UTC-Datum: einen spaeteren Tag kennt die Quelle
--   nicht)}; from = Haushalts-Tag - 5 Jahre (Nachlauf) bzw. juengster Kurs + 1 Tag (Ersatz).
--   Tests: tests/db/finance/test_fn_fx_history_due.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_fx_history_due()
RETURNS jsonb
LANGUAGE plpgsql   -- ruft fn_fx_history_source aus dem alphabetisch spaeteren R__fn_upsert_fx_rates (late-bound)
STABLE
AS $$
DECLARE
    v_utc  date := (now() AT TIME ZONE 'UTC')::date;
    v_feed date;
    v_all  date;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM finance.fx_rates WHERE source = finance.fn_fx_history_source()) THEN
        RETURN jsonb_build_object('due', true, 'from', (core.fn_today() - interval '5 years')::date, 'to', v_utc);
    END IF;
    SELECT max(as_of) FILTER (WHERE source = finance.fn_fx_feed_source()), max(as_of)
    INTO v_feed, v_all FROM finance.fx_rates;
    RETURN jsonb_build_object(
        'due',  (v_feed IS NULL OR v_feed < v_utc) AND v_all < v_utc,
        'from', v_all + 1,
        'to',   v_utc);
END;
$$;
