-- ============================================================
-- fn_import_fifo_lots (READ, IMMUTABLE) -- verbliebene Kaeufe einer Position nach FIFO
--   Die eine FIFO-Rechnung fuer Export-Dateien (fn_replace_takeover_with_lots, fn_setup_positions).
--   Eingabe: Zeilen einer Position [{date, kind buy|sell, shares (Betrag), gross, fee, row_no, ...}] in beliebiger Folge; je
--   Tag zuerst Kaeufe. Jede Stueckzahl wird auf die Spaltenpraezision (8 Stellen) gerundet, Exporte liefern mehr.
--   Ein Bestand 0 setzt neu an (fruehere Kaeufe sind vollstaendig verkauft).
--   RUECKGABE: {lots:[Zeile || {shares (Rest), orig (urspruengliche Stueck)}], unmatched_sell_shares}.
--   unmatched_sell_shares > 0 = es wurde mehr verkauft als die Zeilen belegen (Datei unvollstaendig).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_fifo_lots(p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_lots     JSONB := '[]'::jsonb;
    v_row      JSONB;
    v_rest     NUMERIC;
    v_take     NUMERIC;
    v_i        INT;
    v_unmatched NUMERIC := 0;
BEGIN
    FOR v_row IN
        SELECT e FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) e
        ORDER BY (e->>'date')::date, (e->>'kind' = 'sell'), (e->>'row_no')::int
    LOOP
        IF v_row->>'kind' = 'buy' THEN
            v_lots := v_lots || jsonb_build_array(v_row || jsonb_build_object(
                'shares', round((v_row->>'shares')::numeric, 8), 'orig', round((v_row->>'shares')::numeric, 8)));
        ELSIF v_row->>'kind' = 'sell' THEN
            v_rest := round((v_row->>'shares')::numeric, 8);
            v_i := 0;
            WHILE v_rest > 0 AND v_i < jsonb_array_length(v_lots) LOOP
                v_take := LEAST(v_rest, (v_lots->v_i->>'shares')::numeric);
                v_lots := jsonb_set(v_lots, ARRAY[v_i::text, 'shares'], to_jsonb((v_lots->v_i->>'shares')::numeric - v_take));
                v_rest := v_rest - v_take;
                v_i := v_i + 1;
            END LOOP;
            v_unmatched := v_unmatched + v_rest;
            SELECT COALESCE(jsonb_agg(l), '[]'::jsonb) INTO v_lots FROM jsonb_array_elements(v_lots) l
            WHERE (l->>'shares')::numeric > 0;
        END IF;
    END LOOP;
    RETURN jsonb_build_object('lots', v_lots, 'unmatched_sell_shares', v_unmatched);
END;
$$;
