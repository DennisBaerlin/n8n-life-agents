-- ============================================================
-- fn_set_holding (ATOMIC WRITE)
--   Aendert NUR die Metadaten einer bestehenden Depot-Position
--   (name/symbol/isin/currency/asset_class/provider_symbol/quote_currency).
--   shares + average_purchase_price sind Trigger-gepflegt (aus finance_transactions) und werden
--   hier NIE geschrieben -> eine falsche Stueckzahl/avg korrigiert man ueber die Transaktionen,
--   nicht hier. ISIN ist der stabile Identifier (Ticker aendert sich bei Corporate Actions).
--   asset_class = Allokations-Block-key (lowercase snake; Korrektur des Auto-Tags aus fn_book_stock_buy);
--   Format-Verstoss -> {ok:false} (spiegelt den finance_depot_holdings_asset_class_fmt-CHECK).
--   provider_symbol (Phase M): Markt-Daten-Feed-Symbol-Override (z. B. VWCE.DE); quote_currency (Phase M):
--   native Quote-Waehrung, via fn_ensure_currency validiert -> {ok:false} bei ungueltigem Code.
--   Partielles Update. Eingabe jsonb: holding_id (im n8n via finance_depot_holdings_overview ermittelt),
--   name, symbol, isin, currency, asset_class, provider_symbol, quote_currency.
--   RUECKGABE: {ok:true, holding_id}. Korrigierbar (Dubletten-Identitaet im Depot) -> {ok:false}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_holding(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id              INT  := (p->>'holding_id')::int;
    -- Roh-Input normalisieren ('usd' -> 'USD'); STRICT-Helper gibt NULL bei NULL zurueck (partielles Update).
    v_new_currency    TEXT := finance.fn_normalize_currency(NULLIF(p->>'currency', ''));
    v_asset_cls       TEXT := NULLIF(p->>'asset_class', '');  -- WS2b: Allokations-Block-key (Korrektur des Auto-Tags)
    v_quote_ccy       TEXT := finance.fn_normalize_currency(NULLIF(p->>'quote_currency', '')); -- Phase M: native Quote-Waehrung (roh normalisiert)
    v_currency_result JSONB;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM finance.depot_holdings WHERE id = v_id) THEN
        RAISE EXCEPTION 'Holding % not found.', v_id;
    END IF;

    -- Korrigierbar: das Anlageklasse-Etikett muss das Block-key-Format treffen (lowercase snake) -> {ok:false}
    -- statt hartem CHECK-RAISE (spiegelt fn_book_stock_buy + den finance_depot_holdings_asset_class_fmt-CHECK).
    IF v_asset_cls IS NOT NULL AND v_asset_cls !~ '^[a-z0-9_]+$' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'asset_class tag must be lowercase letters/digits/underscore (e.g. sp500), got: ' || v_asset_cls);
    END IF;

    IF v_new_currency IS NOT NULL AND v_new_currency <> 'EUR' THEN
        v_currency_result := finance.fn_ensure_currency(v_new_currency);
        IF NOT (v_currency_result->>'ok')::boolean THEN
            RETURN v_currency_result;
        END IF;
    END IF;

    -- Phase M: optionale Quote-Waehrung (falls gesetzt) registrieren/validieren -> {ok:false} bei ungueltigem
    -- ISO-Code (kein FK-RAISE/Owner-Alert; mirror des currency-Pfads oben). Der FK depot_holdings.quote_currency
    -- ist Backstop; dieser Pfad ist der primaere.
    IF v_quote_ccy IS NOT NULL THEN
        v_currency_result := finance.fn_ensure_currency(v_quote_ccy);
        IF NOT (v_currency_result->>'ok')::boolean THEN
            RETURN v_currency_result;
        END IF;
    END IF;

    -- Eine ISIN-/Symbol-Aenderung kann die partiellen UNIQUE-Indizes (account_id,isin) /
    -- (account_id,symbol) verletzen -> korrigierbar abfangen statt harter RAISE/Owner-Alert.
    BEGIN
        UPDATE finance.depot_holdings SET
            name            = COALESCE(NULLIF(p->>'name', ''), name),
            symbol          = COALESCE(NULLIF(p->>'symbol', ''), symbol),
            isin            = COALESCE(NULLIF(p->>'isin', ''), isin),
            currency        = COALESCE(v_new_currency, currency),   -- normalisiert (nicht Roh-p) -> 'usd' landet als 'USD'
            asset_class     = COALESCE(v_asset_cls, asset_class),
            provider_symbol = COALESCE(NULLIF(p->>'provider_symbol', ''), provider_symbol),
            quote_currency  = COALESCE(v_quote_ccy, quote_currency),
            updated_at      = NOW()
        WHERE id = v_id;
    EXCEPTION WHEN unique_violation THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Another holding with this ISIN/symbol already exists in this depot. Cannot create a duplicate identity.');
    END;

    RETURN jsonb_build_object('ok', true, 'holding_id', v_id);
END;
$$;
