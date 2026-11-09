-- ============================================================
-- fn_setup_positions (READ, STABLE) -- offene Positionen einer Export-Datei fuer die Ersteinrichtung
--   Wirksame Zeilen (fn_setup_effective_rows) je Position per FIFO (fn_import_fifo_lots). Eine Adresse fuer Schritt-Ableitung
--   (fn_setup_next) und Einstellen (fn_import_positions_from_export).
--   Eingabe: rows (kanonische Export-Zeilen), decisions, account_id (Verrechnungskonto), cut (bestaetigter Tag).
--   Position draussen und als open_item: mixed_currency (Waehrung weicht vom Konto ab oder wechselt; leer = keine Angabe),
--   position_incomplete (mehr verkauft als gekauft). Schon gehaltene Position -> held, sonst sperrte sie den Stapel.
--   Lots eines Tages werden zusammengefasst (Dubletten-Sperre fn_import_bundle), zu kleine (fn_trade_amount_reason) wandern
--   zur Nachbar-Zeile, Einstand je Rest anteilig.
--   RUECKGABE: {positions:[{key, isin, symbol, name, shares, cost, is_crypto, origin, hints[], lots:[{date, shares, price, fee}]}],
--   open_items[], held[], notes[]}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_setup_positions(p_rows jsonb, p_decisions jsonb, p_account_id int, p_cut date)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_eff   JSONB := finance.fn_setup_effective_rows(p_rows, p_decisions, p_cut);
    v_dec   JSONB := COALESCE(p_decisions, '{}'::jsonb);
    v_ccy   TEXT;
    v_open  JSONB := v_eff->'open_items';
    v_held  JSONB := '[]'::jsonb;
    v_out   JSONB := '[]'::jsonb;
    v_g     RECORD;
    v_fifo  JSONB;
    v_lots  JSONB;
    v_day   JSONB;
    v_fixed JSONB;
    v_l     JSONB;
    v_key   TEXT;
BEGIN
    SELECT currency INTO v_ccy FROM finance.accounts WHERE id = p_account_id;
    FOR v_g IN
        SELECT COALESCE(x->>'isin', 'sym:' || upper(x->>'symbol')) AS k, jsonb_agg(x) AS rows,
               max(x->>'isin') AS isin, max(x->>'symbol') AS symbol,
               (array_agg(x->>'name' ORDER BY (x->>'date')::date DESC))[1] AS name,
               count(DISTINCT x->>'currency') AS ccys, bool_or(x->>'currency' IS DISTINCT FROM v_ccy AND x->>'currency' IS NOT NULL) AS foreign_ccy,
               bool_or(x->>'origin' = 'estimated') AS estimated, bool_or(x ? 'merged_from') AS merged,
               bool_or(x->>'reason' = 'no_cash_amount') AS no_amount
        FROM jsonb_array_elements(v_eff->'rows') x
        WHERE COALESCE(x->>'isin', '') NOT IN (SELECT jsonb_array_elements_text(v_eff->'excluded'))
        GROUP BY 1 ORDER BY 1
    LOOP
        -- offene Sonderzeile derselben ISIN: warten, sonst waere die Position nach dem ersten Stapel held und die Sonderzeile verloren
        CONTINUE WHEN v_g.isin IS NOT NULL AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_eff->'open_items') o WHERE o->>'isin' = v_g.isin);
        IF v_g.ccys > 1 OR v_g.foreign_ccy THEN
            v_key := 'ccy:' || v_g.k;
            IF (v_dec->v_key->>'skip')::boolean IS DISTINCT FROM true THEN
                v_open := v_open || jsonb_build_object('key', v_key, 'type', 'mixed_currency', 'isin', v_g.isin, 'name', v_g.name);
            END IF;
            CONTINUE;
        END IF;
        v_fifo := finance.fn_import_fifo_lots(v_g.rows);
        -- Rundungs-Staub aus mehr als 8 Stellen ist kein fehlender Kauf
        IF (v_fifo->>'unmatched_sell_shares')::numeric > 0.0000001 THEN
            v_key := 'oversold:' || v_g.k;
            IF (v_dec->v_key->>'skip')::boolean IS DISTINCT FROM true THEN
                v_open := v_open || jsonb_build_object('key', v_key, 'type', 'position_incomplete', 'isin', v_g.isin, 'name', v_g.name);
            END IF;
            CONTINUE;
        END IF;
        CONTINUE WHEN jsonb_array_length(v_fifo->'lots') = 0;

        IF EXISTS (SELECT 1 FROM finance.depot_holdings h JOIN finance.accounts d ON d.id = h.account_id
                   WHERE d.settlement_account_id = p_account_id AND h.shares > 0
                     AND (upper(h.isin) = upper(v_g.isin) OR (v_g.isin IS NULL AND h.isin IS NULL AND upper(h.symbol) = upper(v_g.symbol)))) THEN
            v_held := v_held || jsonb_build_object('key', v_g.k, 'isin', v_g.isin, 'name', v_g.name);
            CONTINUE;
        END IF;

        -- je Tag eine Zeile: Rest-Kurswert und anteilige Gebuehr
        SELECT jsonb_agg(jsonb_build_object('date', d, 'shares', s, 'cost', c, 'fee', f) ORDER BY d)
        INTO v_day FROM (
            SELECT l->>'date' AS d, sum((l->>'shares')::numeric) AS s,
                   sum((l->>'gross')::numeric * (l->>'shares')::numeric / (l->>'orig')::numeric) AS c,
                   sum(COALESCE((l->>'fee')::numeric, 0) * (l->>'shares')::numeric / (l->>'orig')::numeric) AS f
            FROM jsonb_array_elements(v_fifo->'lots') l GROUP BY 1) t;

        -- zu kleine Tages-Zeilen an die Folgezeile haengen (Bestand und Einstand bleiben vollstaendig)
        v_fixed := '[]'::jsonb;
        v_l := NULL;
        FOR v_lots IN SELECT e FROM jsonb_array_elements(v_day) e LOOP
            IF v_l IS NOT NULL THEN
                v_lots := v_lots || jsonb_build_object('shares', (v_lots->>'shares')::numeric + (v_l->>'shares')::numeric,
                    'cost', (v_lots->>'cost')::numeric + (v_l->>'cost')::numeric, 'fee', (v_lots->>'fee')::numeric + (v_l->>'fee')::numeric);
                v_l := NULL;
            END IF;
            IF finance.fn_trade_amount_reason((v_lots->>'shares')::numeric, (v_lots->>'cost')::numeric) IS NOT NULL THEN
                v_l := v_lots;
            ELSE
                v_fixed := v_fixed || jsonb_build_array(v_lots);
            END IF;
        END LOOP;
        IF v_l IS NOT NULL AND jsonb_array_length(v_fixed) > 0 THEN
            v_fixed := jsonb_set(v_fixed, ARRAY[(jsonb_array_length(v_fixed) - 1)::text],
                (v_fixed->-1) || jsonb_build_object('shares', (v_fixed->-1->>'shares')::numeric + (v_l->>'shares')::numeric,
                    'cost', (v_fixed->-1->>'cost')::numeric + (v_l->>'cost')::numeric, 'fee', (v_fixed->-1->>'fee')::numeric + (v_l->>'fee')::numeric));
            v_l := NULL;
        END IF;
        -- nur Rundungs-Staub uebrig: Position ist geschlossen
        CONTINUE WHEN jsonb_array_length(v_fixed) = 0 AND (SELECT sum((l->>'shares')::numeric) FROM jsonb_array_elements(v_day) l) < 0.0000001;
        IF v_l IS NOT NULL OR jsonb_array_length(v_fixed) = 0 THEN
            v_key := 'oversold:' || v_g.k;
            IF (v_dec->v_key->>'skip')::boolean IS DISTINCT FROM true THEN
                v_open := v_open || jsonb_build_object('key', v_key, 'type', 'position_incomplete', 'isin', v_g.isin, 'name', v_g.name);
            END IF;
            CONTINUE;
        END IF;

        SELECT jsonb_build_object('key', v_g.k, 'isin', v_g.isin, 'symbol', v_g.symbol, 'name', v_g.name, 'is_crypto', v_g.isin IS NULL,
                   'origin', CASE WHEN v_g.estimated THEN 'estimated' ELSE 'export' END,
                   'hints', to_jsonb(array_remove(ARRAY[CASE WHEN v_g.merged THEN 'merger' END,
                                                       CASE WHEN v_g.no_amount THEN 'buy_without_amount' END,
                                                       CASE WHEN v_g.estimated THEN 'estimated' END], NULL)),
                   'shares', sum((l->>'shares')::numeric), 'cost', round(sum((l->>'cost')::numeric + (l->>'fee')::numeric), 2),
                   'lots', jsonb_agg(jsonb_build_object('date', l->>'date', 'shares', (l->>'shares')::numeric,
                       'price', finance.fn_unit_price_from_total((l->>'cost')::numeric, (l->>'shares')::numeric),
                       'fee', round((l->>'fee')::numeric, 2)) ORDER BY l->>'date'))
        INTO v_l FROM jsonb_array_elements(v_fixed) l;
        v_out := v_out || jsonb_build_array(v_l);
    END LOOP;
    RETURN jsonb_build_object('positions', v_out, 'open_items', v_open, 'held', v_held, 'notes', v_eff->'notes');
END;
$$;
