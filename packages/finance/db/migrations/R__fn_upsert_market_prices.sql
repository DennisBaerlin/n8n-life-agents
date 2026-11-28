-- packages/finance/db/migrations/R__fn_upsert_market_prices.sql
-- fn_upsert_market_prices (ATOMIC WRITE)
-- Atomarer Markt-Preis-Upsert. Vom Cron agent.finance.cron_refresh_market_prices aufgerufen
-- (Yahoo Finance fuer Aktien/ETF und Krypto -> diese fn, kein LLM; der Cron uebergibt source='yahoo').
-- Wie fn_upsert_fx_rates eine eigene fn, damit die Upsert-Invarianten deterministisch testbar sind
-- (tests/db/finance/test_fn_upsert_market_prices.sql). Provider-agnostisch.
--
-- p = { "prices": { "VWCE": 110.50, "BTC": 60000, ... },  (Pflicht: { symbol -> Kurs })
--       "currencies": { "VWCE": "EUR", "AAPL": "USD" },    (optional: { symbol -> Yahoo-meta.currency }; gewinnt
--                                                           ueber quote_currency/Holding-Waehrung, wird registriert;
--                                                           unbrauchbar (kein ^[A-Z]{3}$, Edelmetall) -> Symbol
--                                                           uebersprungen; Pence 'GBp' normalisiert der Cron)
--       "as_of":  "2026-06-20",                            (optional, default CURRENT_DATE)
--       "source": "yahoo" }                                (optional, default 'yahoo' = aktueller Provider-Fallback)
--
-- Symbol-Menge = DISTINCT symbol aus depot_holdings WHERE shares > 0 (objekt-getrieben wie
-- fn_active_currencies — kein Eintrag fuer nicht (mehr) gehaltene Ticker). Preis-Waehrung: die gefetchte
-- Yahoo-Waehrung (currencies{}-Key im Payload, ^[A-Z]{3}$-Backstop) gewinnt per COALESCE-Praezedenz; Fallback
-- = die Holding-Waehrung COALESCE(quote_currency, currency) (ein Symbol = eine Waehrung; bei theoretischer
-- Mehrfach-Waehrung deterministisch min() — der COALESCE liegt innerhalb von min(), Aufloesung pro Zeile, kein
-- Mischen ueber Zeilen). Join-Key ist symbol (immer vorhanden); isin nur als sekundaerer Hint mitgeschrieben.
--
-- Guards (alle still -> kein RAISE, kein Owner-Alert; ein kaputter Kurs darf den Tages-Refresh der
-- anderen nicht killen): Symbol muss im prices-Objekt existieren; Wert numerisch und auf 8 Nachkommastellen > 0 (faengt
-- 0/Negativ/"n/a"-Kurse ab -> sonst CHECK(price>0)-RAISE). ON CONFLICT (symbol, as_of) -> idempotenter
-- Tages-Upsert.
-- RUECKGABE: {ok:true, upserted, as_of} | {ok:false, reason, upserted:0} (kein prices-Objekt im Payload).
CREATE OR REPLACE FUNCTION finance.fn_upsert_market_prices(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_as_of  date := COALESCE(NULLIF(p->>'as_of','')::date, CURRENT_DATE);
  v_source text := COALESCE(NULLIF(p->>'source',''), 'yahoo');
  v_count  int;
BEGIN
  IF p->'prices' IS NULL OR jsonb_typeof(p->'prices') <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no prices object in payload', 'upserted', 0);
  END IF;

  -- Yahoo-Robustheit: der Cron liefert je Symbol die echte Quote-Waehrung mit (p->'currencies'). Vor dem INSERT
  -- jede distinkte valide (^[A-Z]{3}$) gefetchte Waehrung registrieren -> FK-Schutz fuer market_prices.currency
  -- (idempotent, ON CONFLICT DO NOTHING in fn_ensure_currency). Pence ('GBp') normalisiert bereits der Cron.
  PERFORM finance.fn_ensure_currency(c)
  FROM (SELECT DISTINCT btrim(value) AS c
        FROM jsonb_each_text(COALESCE(p->'currencies', '{}'::jsonb))
        WHERE btrim(value) ~ '^[A-Z]{3}$') s;

  WITH held AS (
    SELECT symbol, min(COALESCE(quote_currency, currency, 'EUR')) AS currency, min(isin) AS isin
    FROM finance.depot_holdings
    WHERE shares > 0
    GROUP BY symbol
  ),
  upserted AS (
    INSERT INTO finance.market_prices (symbol, isin, price, currency, as_of, source)
    -- currency-Praezedenz: gefetchte Yahoo-Waehrung gewinnt (der Preis IST in dieser Waehrung). Ohne gefetchte Waehrung
    -- gilt h.currency = COALESCE(quote_currency,currency). Eine gefetchte Waehrung, die keine Kurs-Waehrung ist (kein
    -- ^[A-Z]{3}$ oder Edelmetall-Code, finance.currencies.kind), ueberspringt das Symbol: der Kurs gilt in einer
    -- unbekannten Einheit, umetikettiert waere er still falsch (0,01 XAU als 0,01 EUR); die Luecke meldet der Kurs-Hinweis.
    SELECT h.symbol, h.isin, ((p->'prices')->>h.symbol)::numeric,
           COALESCE(NULLIF(btrim((p->'currencies')->>h.symbol), ''), h.currency, 'EUR'),
           v_as_of, v_source
    FROM held h
    WHERE (p->'prices') ? h.symbol
      AND (NULLIF(btrim((p->'currencies')->>h.symbol), '') IS NULL
           OR (btrim((p->'currencies')->>h.symbol) ~ '^[A-Z]{3}$' AND NOT finance.fn_is_metal(btrim((p->'currencies')->>h.symbol))))
      -- numerisch inkl. wissenschaftlicher Notation (JSON.stringify liefert z. B. '1e-7' fuer
      -- sub-microcent-Krypto -> sonst still verworfen). Leading-Zero ist in JSON immer vorhanden.
      -- Erst das Format, dann die Zahl (CASE haelt die Reihenfolge). Grenzen = Spalte numeric(20,8): darunter wuerde der
      -- Kurs zu 0 (CHECK), ab 1e12 liefe er ueber; beides braeche sonst den ganzen Lauf ab.
      AND CASE WHEN ((p->'prices')->>h.symbol) ~ '^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]{1,3})?$'
               THEN round(((p->'prices')->>h.symbol)::numeric, 8) > 0 AND ((p->'prices')->>h.symbol)::numeric < 1e12
               ELSE FALSE END
    ON CONFLICT (symbol, as_of)
    DO UPDATE SET price = EXCLUDED.price, currency = EXCLUDED.currency,
                  isin = EXCLUDED.isin, source = EXCLUDED.source, updated_at = NOW()
    RETURNING 1
  )
  SELECT count(*) INTO v_count FROM upserted;

  RETURN jsonb_build_object('ok', true, 'upserted', v_count, 'as_of', v_as_of);
END $$;
