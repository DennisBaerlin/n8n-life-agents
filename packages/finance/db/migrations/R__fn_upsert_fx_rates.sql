-- packages/finance/db/migrations/R__fn_upsert_fx_rates.sql
-- fn_upsert_fx_rates (ATOMIC WRITE)
-- Atomarer FX-Kurs-Upsert des Crons agent.finance.cron_refresh_fx_rates, damit die Upsert-Invarianten
-- deterministisch testbar sind (tests/db/finance/test_fn_upsert_fx_rates.sql). Der Cron-Node ruft nur
-- SELECT finance.fn_upsert_fx_rates($1::jsonb).
--
-- Tages-Modus: p = { "rates": { "USD": 1.08, "CLP": 1450, ... },   (Pflicht: open.er-api.com-Antwortobjekt)
--                    "as_of":  "2026-06-07",                (optional, default CURRENT_DATE; der Cron gibt das Quell-Datum)
--                    "source": "open.er-api.com" }          (optional, default finance.fn_fx_feed_source())
--   ON CONFLICT -> UPDATE: der Tages-Feed gewinnt auch gegen eine EZB-Zeile desselben Tages.
-- Zeilen-Modus (EZB-Nachlauf): p = { "rows": [{ "date": "2026-05-05", "base": "EUR", "quote": "USD", "rate": 1.1 }, ...],
--                    "source": "ecb" }                      (optional, default fn_fx_history_source(); die Feed-Kennung -> ok:false)
--   ON CONFLICT -> DO NOTHING: ein vorhandener Kurs desselben Tages gewinnt.
--
-- Gespeichert wird jede gelieferte Waehrung, unabhaengig davon, ob ein Konto oder eine Position sie nutzt: die Quelle
-- liefert alle in einer Antwort, und Verfuegbarkeit darf nicht an Bedarf haengen (Waechter, Berater, Kuerzel-Pruefung
-- brauchen Kurse vor jedem Objekt). Neue Codes registriert die fn selbst in finance.currencies (FK von fx_rates;
-- minor_unit aus fn_currency_minor_unit), damit fn_monitor_validate_fx_rate jede Feed-Waehrung kennt.
-- Guards in fn_fx_upsert_input (alle still -> kein RAISE, kein Owner-Alert; ein kaputter Einzelwert darf den Lauf nicht
-- killen).
-- Idempotent je (base, quote, as_of).
-- RUECKGABE: {ok:true, upserted, skipped, as_of} (skipped = verworfene oder schon vorhandene Eintraege; as_of = Tag
--   bzw. juengstes Datum der Zeilen) | {ok:false, reason, upserted:0} (kein rates-Objekt bzw. Zeilen-Modus mit Feed-Kennung).
-- fn_fx_feed_source / fn_fx_history_source (READ, IMMUTABLE) -- Kennungen in fx_rates.source: der taegliche Kurs-Feed
-- und der einmalige EZB-Nachlauf. Eine Adresse je Quelle fuer den Schreiber (Defaults unten) und die Leser
-- (fn_feed_refresh_due, fn_fx_feed_gap zaehlen nur den Feed; fn_fx_history_due nur den Nachlauf); ein Wechsel der Quelle
-- aendert nur diese Zeile. Rueckgabe: text.
CREATE OR REPLACE FUNCTION finance.fn_fx_feed_source()
RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'open.er-api.com'::text $$;

CREATE OR REPLACE FUNCTION finance.fn_fx_history_source()
RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'ecb'::text $$;

-- fn_fx_upsert_input (READ, STABLE) -- gueltige Eintraege eines fn_upsert_fx_rates-Payloads als Zeilen (code, rate, as_of).
--   Tages-Modus aus rates (+ as_of, Default heute), Zeilen-Modus aus rows. Verworfen (still): Code nicht ^[A-Z]{3}$ oder
--   EUR, Basis nicht EUR, Kurs nicht numerisch / <= 0 / nicht in numeric(20,10) darstellbar, Datum ungueltig (auch
--   30. Februar). CASE statt AND-Kette: PostgreSQL garantiert keine Auswertungs-Reihenfolge der WHERE-Bedingungen, ein
--   Cast von "n/a" vor der Format-Pruefung braeche den ganzen Lauf ab. Nur fuer fn_upsert_fx_rates.
CREATE OR REPLACE FUNCTION finance.fn_fx_upsert_input(p jsonb)
RETURNS TABLE (code text, rate numeric, as_of date) LANGUAGE sql STABLE AS $$
    WITH raw AS (
        SELECT e.key AS c, e.value AS r, COALESCE(NULLIF(p->>'as_of', ''), CURRENT_DATE::text) AS d, 'EUR' AS b
        FROM jsonb_each_text(CASE WHEN jsonb_typeof(p->'rates') = 'object' THEN p->'rates' ELSE '{}'::jsonb END) e
        WHERE jsonb_typeof(p->'rows') IS DISTINCT FROM 'array'
        UNION ALL
        SELECT x->>'quote', x->>'rate', x->>'date', x->>'base'
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p->'rows') = 'array' THEN p->'rows' ELSE '[]'::jsonb END) x
    ), typed AS (
        SELECT c,
               CASE WHEN r ~ '^[0-9]+(\.[0-9]+)?$' THEN r::numeric END AS r,
               CASE WHEN pg_input_is_valid(d, 'date') THEN d::date END AS d
        FROM raw
        WHERE c ~ '^[A-Z]{3}$' AND c <> 'EUR' AND b = 'EUR'
    )
    SELECT c, r, d FROM typed WHERE round(r, 10) > 0 AND r < 1e10 AND d IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION finance.fn_upsert_fx_rates(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_rows   boolean := COALESCE(jsonb_typeof(p->'rows') = 'array', false);
  v_source text := COALESCE(NULLIF(p->>'source',''),
                            CASE WHEN v_rows THEN finance.fn_fx_history_source() ELSE finance.fn_fx_feed_source() END);
  v_as_of  date;
  v_count  int;
  v_in     int;
BEGIN
  IF NOT v_rows AND (p->'rates' IS NULL OR jsonb_typeof(p->'rates') <> 'object') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no rates object in payload', 'upserted', 0);
  END IF;
  IF v_rows AND v_source = finance.fn_fx_feed_source() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rows mode must not use the daily feed source', 'upserted', 0);
  END IF;

  INSERT INTO finance.currencies (code, minor_unit)
  SELECT d.code, finance.fn_currency_minor_unit(d.code)
  FROM (SELECT DISTINCT i.code FROM finance.fn_fx_upsert_input(p) i) d
  ON CONFLICT (code) DO NOTHING;

  IF v_rows THEN
    -- Nachlauf: ein vorhandener Kurs desselben Tages (meist der Tages-Feed) gewinnt
    WITH ins AS (
      INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
      SELECT 'EUR', i.code, i.rate, i.as_of, v_source FROM finance.fn_fx_upsert_input(p) i
      ON CONFLICT (base_currency, quote_currency, as_of) DO NOTHING
      RETURNING as_of
    )
    SELECT count(*), max(as_of) INTO v_count, v_as_of FROM ins;
    v_in := jsonb_array_length(p->'rows');
  ELSE
    WITH ins AS (
      INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
      SELECT 'EUR', i.code, i.rate, i.as_of, v_source FROM finance.fn_fx_upsert_input(p) i
      ON CONFLICT (base_currency, quote_currency, as_of)
      DO UPDATE SET rate = EXCLUDED.rate, source = EXCLUDED.source, updated_at = NOW()
      RETURNING as_of
    )
    SELECT count(*) INTO v_count FROM ins;
    v_as_of := COALESCE(NULLIF(p->>'as_of','')::date, CURRENT_DATE);
    SELECT count(*) INTO v_in FROM jsonb_object_keys(p->'rates');
  END IF;

  RETURN jsonb_build_object('ok', true, 'upserted', v_count, 'skipped', v_in - v_count, 'as_of', v_as_of);
END $$;
