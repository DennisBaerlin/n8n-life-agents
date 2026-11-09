-- ============================================================
-- fn_setup_effective_rows (READ, IMMUTABLE) -- Export-Zeilen + Antworten -> wirksame Kauf-/Verkaufszeilen
--   Quellzeilen bleiben unveraendert, die Antworten liegen getrennt in setup_session.decisions; nur Zeilen bis p_cut zaehlen.
--   Fusion (CORPORATE_ACTION/MERGER): genau ein Paar am Tag (alt negativ, neu positiv) und alte Stueck = Bestand -> die Zeilen
--   der alten ISIN wandern auf die neue, Stueck anteilig, Einstand und Kaufdaten bleiben; ein Rundungsrest landet auf dem
--   letzten Kauf. Sonst open_item merger_unclear, beide ISIN bleiben draussen (excluded).
--   Kauf ohne Betrag mit Kurs: Einstand = Stueck x Kurs (note buy_without_amount); ohne Kurs: open_item.
--   SPIN_OFF, FREE_RECEIPT: open_item, mit Antwort {amount} ein Kauf (origin estimated), mit {skip} weg.
--   CASH/MERGER und CASH/IPO_SUBSCRIPTION aendern keinen Bestand (nur note): das Geld steckt im Kontostand.
--   RUECKGABE: {rows:[Zeile || {origin, merged_from?}], open_items:[{key, type, date, isin, symbol, name, shares}],
--   notes:[{type, ...}], excluded:[ISIN]}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_setup_effective_rows(p_rows jsonb, p_decisions jsonb, p_cut date)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_dec   JSONB := COALESCE(p_decisions, '{}'::jsonb);
    v_rows  JSONB := '[]'::jsonb;
    v_open  JSONB := '[]'::jsonb;
    v_notes JSONB := '[]'::jsonb;
    v_excl  JSONB := '[]'::jsonb;
    v_r     JSONB;
    v_key   TEXT;
    v_d     JSONB;
    v_type  TEXT;
    v_m     RECORD;
    v_old   JSONB;
    v_new   JSONB;
    v_held  NUMERIC;
    v_ratio NUMERIC;
    v_net   NUMERIC;
    v_last  INT;
BEGIN
    FOR v_r IN
        SELECT e FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) e
        WHERE (e->>'date')::date <= p_cut ORDER BY (e->>'date')::date, (e->>'row_no')::int
    LOOP
        v_key := COALESCE(v_r->>'ext_ref', 'row' || (v_r->>'row_no'));
        v_type := NULL;
        IF v_r->>'kind' IN ('buy', 'sell') THEN
            v_rows := v_rows || jsonb_build_array(v_r || '{"origin":"export"}'::jsonb);
        ELSIF v_r->>'category' = 'TRADING' AND v_r->>'type' = 'BUY' AND v_r->>'reason' = 'no_cash_amount'
              AND (v_r->>'shares')::numeric > 0 THEN
            IF (v_r->>'price')::numeric > 0 THEN
                v_rows := v_rows || jsonb_build_array(v_r || jsonb_build_object('kind', 'buy', 'origin', 'export',
                    'gross', round((v_r->>'shares')::numeric * (v_r->>'price')::numeric, 2), 'fee', 0));
                v_notes := v_notes || jsonb_build_object('type', 'buy_without_amount', 'isin', v_r->>'isin', 'date', v_r->>'date');
            ELSE
                v_type := 'buy_without_amount';
            END IF;
        ELSIF (v_r->>'category' = 'CORPORATE_ACTION' AND v_r->>'type' = 'SPIN_OFF')
              OR (v_r->>'category' = 'DELIVERY' AND v_r->>'type' = 'FREE_RECEIPT') THEN
            v_type := lower(v_r->>'type');
        ELSIF v_r->>'category' = 'CASH' AND v_r->>'type' IN ('MERGER', 'IPO_SUBSCRIPTION') THEN
            v_notes := v_notes || jsonb_build_object('type', lower(v_r->>'type'), 'isin', v_r->>'isin', 'date', v_r->>'date');
        END IF;

        IF v_type IS NOT NULL THEN
            v_d := v_dec->v_key;
            IF (v_d->>'amount')::numeric > 0 THEN
                v_rows := v_rows || jsonb_build_array(v_r || jsonb_build_object('kind', 'buy', 'origin', 'estimated',
                    'gross', (v_d->>'amount')::numeric, 'fee', 0));
                v_notes := v_notes || jsonb_build_object('type', v_type, 'isin', v_r->>'isin', 'date', v_r->>'date');
            ELSIF (v_d->>'skip')::boolean IS DISTINCT FROM true THEN
                v_open := v_open || jsonb_build_object('key', v_key, 'type', v_type, 'date', v_r->>'date',
                    'isin', v_r->>'isin', 'symbol', v_r->>'symbol', 'name', v_r->>'name', 'shares', (v_r->>'shares')::numeric);
            END IF;
        END IF;
    END LOOP;

    FOR v_m IN
        SELECT (e->>'date')::date AS d,
               jsonb_agg(e) FILTER (WHERE (e->>'shares_signed')::numeric < 0) AS olds,
               jsonb_agg(e) FILTER (WHERE (e->>'shares_signed')::numeric > 0) AS news
        FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) e
        WHERE e->>'category' = 'CORPORATE_ACTION' AND e->>'type' = 'MERGER' AND (e->>'date')::date <= p_cut
        GROUP BY 1 ORDER BY 1
    LOOP
        v_old := v_m.olds->0;
        v_new := v_m.news->0;
        v_key := 'merger:' || v_m.d;
        v_held := NULL;
        IF jsonb_array_length(COALESCE(v_m.olds, '[]'::jsonb)) = 1 AND jsonb_array_length(COALESCE(v_m.news, '[]'::jsonb)) = 1 THEN
            SELECT COALESCE(sum(CASE WHEN x->>'kind' = 'buy' THEN 1 ELSE -1 END * round((x->>'shares')::numeric, 8)), 0) INTO v_held
            FROM jsonb_array_elements(v_rows) x
            WHERE x->>'isin' = v_old->>'isin' AND (x->>'date')::date <= v_m.d;
        END IF;
        IF v_held IS NULL OR v_held <= 0 OR abs(v_held - round(abs((v_old->>'shares_signed')::numeric), 8)) > 0.00000002 THEN
            IF (v_dec->v_key->>'skip')::boolean IS DISTINCT FROM true THEN
                v_open := v_open || jsonb_build_object('key', v_key, 'type', 'merger_unclear', 'date', v_m.d,
                    'isin', v_old->>'isin', 'name', COALESCE(v_new->>'name', v_old->>'name'));
            END IF;
            v_excl := v_excl || COALESCE((SELECT jsonb_agg(DISTINCT z.i) FROM (
                          SELECT e->>'isin' AS i FROM jsonb_array_elements(COALESCE(v_m.olds, '[]'::jsonb) || COALESCE(v_m.news, '[]'::jsonb)) e) z), '[]'::jsonb);
            CONTINUE;
        END IF;

        v_ratio := (v_new->>'shares_signed')::numeric / v_held;
        SELECT jsonb_agg(CASE WHEN x->>'isin' = v_old->>'isin' AND (x->>'date')::date <= v_m.d
                THEN x || jsonb_build_object('isin', v_new->>'isin', 'symbol', v_new->>'symbol', 'name', v_new->>'name',
                         'shares', round(round((x->>'shares')::numeric, 8) * v_ratio, 8), 'merged_from', v_old->>'isin')
                ELSE x END ORDER BY o)
        INTO v_rows FROM jsonb_array_elements(v_rows) WITH ORDINALITY AS t(x, o);

        -- Rundungsrest: die Summe der neuen Stueck muss exakt der Datei entsprechen
        SELECT COALESCE(sum(CASE WHEN x->>'kind' = 'buy' THEN 1 ELSE -1 END * (x->>'shares')::numeric), 0),
               max(o - 1) FILTER (WHERE x->>'kind' = 'buy')
        INTO v_net, v_last
        FROM jsonb_array_elements(v_rows) WITH ORDINALITY AS t(x, o)
        WHERE x->>'merged_from' = v_old->>'isin';
        v_rows := jsonb_set(v_rows, ARRAY[v_last::text, 'shares'],
                      to_jsonb((v_rows->v_last->>'shares')::numeric + round((v_new->>'shares_signed')::numeric, 8) - v_net));
        v_notes := v_notes || jsonb_build_object('type', 'merger', 'from_isin', v_old->>'isin', 'to_isin', v_new->>'isin',
                                                 'date', v_m.d, 'name', v_new->>'name');
    END LOOP;

    RETURN jsonb_build_object('rows', v_rows, 'open_items', v_open, 'notes', v_notes, 'excluded', v_excl);
END;
$$;
