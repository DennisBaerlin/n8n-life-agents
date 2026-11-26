-- ============================================================
-- fn_fx_history_due (READ, STABLE) -- steht der einmalige Nachlauf der Kurs-Geschichte noch aus?
--   Der Tages-Feed (open.er-api.com) liefert keine Vergangenheit; Rueckrechnungen vor dem Einspielen (Depot-Rendite alter
--   Kaeufe, Import alter Auszuege) brauchen sie. Der FX-Cron holt deshalb einmal die EZB-Referenzkurse der letzten
--   5 Jahre (Frankfurter, nur EZB) und schreibt sie per finance.fn_upsert_fx_rates (Zeilen-Modus, source ecb).
--   Faellig, solange keine Zeile der Nachlauf-Quelle (fn_fx_history_source) existiert: ein gescheiterter Abruf
--   wird beim naechsten Tageslauf wiederholt, ein gelungener nie. Waehrungen ausserhalb der EZB-Liste bleiben ohne Vergangenheit.
--   Eingabe: keine. Rueckgabe: jsonb {due boolean, from date (Haushalts-Tag - 5 Jahre), to date (UTC-Datum: einen spaeteren
--   Tag kennt die Quelle nicht)}.
--   Tests: tests/db/finance/test_fn_fx_history_due.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_fx_history_due()
RETURNS jsonb
LANGUAGE plpgsql   -- ruft fn_fx_history_source aus dem alphabetisch spaeteren R__fn_upsert_fx_rates (late-bound)
STABLE
AS $$
BEGIN
    RETURN jsonb_build_object(
        'due',  NOT EXISTS (SELECT 1 FROM finance.fx_rates WHERE source = finance.fn_fx_history_source()),
        'from', (core.fn_today() - interval '5 years')::date,
        'to',   (now() AT TIME ZONE 'UTC')::date);
END;
$$;
