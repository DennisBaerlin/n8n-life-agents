-- packages/finance/db/migrations/R__fn_upsert_market_prices.sql
-- Atomarer Markt-Preis-Upsert (WS2b). Vom Cron agent.finance.cron_refresh_market_prices aufgerufen
-- (Yahoo Finance Aktien/ETF + CoinGecko Krypto -> diese fn, KEIN LLM; der Cron uebergibt source='yahoo').
-- Extrahiert wie fn_upsert_fx_rates, damit die Upsert-Invarianten deterministisch testbar sind
-- (tests/db/finance/test_fn_upsert_market_prices.sql) statt nur im Cron-Node zu leben. Provider-agnostisch.
--
-- p = { "prices": { "VWCE": 110.50, "BTC": 60000, ... },  (Pflicht: { symbol -> Kurs })
--       "currencies": { "VWCE": "EUR", "AAPL": "USD" },    (optional: { symbol -> Yahoo-meta.currency }; gewinnt
--                                                           ueber quote_currency/Holding-Waehrung, ^[A-Z]{3}$-Backstop,
--                                                           wird registriert; Pence 'GBp' normalisiert der Cron)
--       "as_of":  "2026-06-20",                            (optional, default CURRENT_DATE)
--       "source": "yahoo" }                                (optional, default 'yahoo' = aktueller Provider-Fallback)
--
-- Symbol-Menge = DISTINCT symbol aus depot_holdings WHERE shares > 0 (objekt-getrieben wie
-- fn_active_currencies — kein Eintrag fuer nicht (mehr) gehaltene Ticker). Preis-Waehrung: die GEFETCHTE
-- Yahoo-Waehrung (currencies{}-Key im Payload, ^[A-Z]{3}$-Backstop) gewinnt per COALESCE-Praezedenz; Fallback
-- = die Holding-Waehrung COALESCE(quote_currency, currency) (Phase M: ein Symbol = eine Waehrung; bei theoretischer
-- Mehrfach-Waehrung deterministisch min() — der COALESCE liegt INNERHALB von min(), Aufloesung PRO ZEILE, kein
-- Mischen ueber Zeilen). Join-Key ist SYMBOL (immer vorhanden); isin nur als sekundaerer Hint mitgeschrieben.
--
-- Guards (alle still -> kein RAISE, kein Owner-Alert; ein kaputter Kurs darf den Tages-Refresh der
-- anderen nicht killen): Symbol muss im prices-Objekt existieren; Wert numerisch UND > 0 (faengt
-- 0/Negativ/"n/a"-Kurse ab -> sonst CHECK(price>0)-RAISE). ON CONFLICT (symbol, as_of) -> idempotenter
-- Tages-Upsert.
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
  -- jede DISTINCT VALIDE (^[A-Z]{3}$) gefetchte Waehrung registrieren -> FK-Schutz fuer market_prices.currency
  -- (idempotent, ON CONFLICT DO NOTHING in fn_ensure_currency). Pence ('GBp') normalisiert bereits der Cron.
  PERFORM finance.fn_ensure_currency(c)
  FROM (SELECT DISTINCT value AS c
        FROM jsonb_each_text(COALESCE(p->'currencies', '{}'::jsonb))
        WHERE value ~ '^[A-Z]{3}$') s;

  WITH held AS (
    SELECT symbol, min(COALESCE(quote_currency, currency, 'EUR')) AS currency, min(isin) AS isin
    FROM finance.depot_holdings
    WHERE shares > 0
    GROUP BY symbol
  ),
  upserted AS (
    INSERT INTO finance.market_prices (symbol, isin, price, currency, as_of, source)
    -- currency-Praezedenz: GEFETCHTE Yahoo-Waehrung gewinnt (der Preis IST in dieser Waehrung), mit ^[A-Z]{3}$-
    -- Regex-Backstop (invalider/leerer Fetch -> NULL -> Fallback h.currency = COALESCE(quote_currency,currency)).
    SELECT h.symbol, h.isin, ((p->'prices')->>h.symbol)::numeric,
           COALESCE(
             CASE WHEN ((p->'currencies')->>h.symbol) ~ '^[A-Z]{3}$' THEN (p->'currencies')->>h.symbol END,
             h.currency, 'EUR'),
           v_as_of, v_source
    FROM held h
    WHERE (p->'prices') ? h.symbol
      -- numerisch inkl. wissenschaftlicher Notation (JSON.stringify liefert z. B. '1e-7' fuer
      -- sub-microcent-Krypto -> sonst still verworfen). Leading-Zero ist in JSON immer vorhanden.
      AND ((p->'prices')->>h.symbol) ~ '^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$'
      AND ((p->'prices')->>h.symbol)::numeric > 0
    ON CONFLICT (symbol, as_of)
    DO UPDATE SET price = EXCLUDED.price, currency = EXCLUDED.currency,
                  isin = EXCLUDED.isin, source = EXCLUDED.source, updated_at = NOW()
    RETURNING 1
  )
  SELECT count(*) INTO v_count FROM upserted;

  RETURN jsonb_build_object('ok', true, 'upserted', v_count, 'as_of', v_as_of);
END $$;
