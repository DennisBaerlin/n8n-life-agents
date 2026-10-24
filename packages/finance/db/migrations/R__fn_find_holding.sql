-- ============================================================
-- fn_find_holding (POSITION PER DEPOT-NAME + ISIN/SYMBOL, Paket DB-ist-das-Gesetz S8)
--   Ersetzt die Prompt-Regel "holding_id vorher per postgres_select aus depot_holdings_overview holen". Eingabe jsonb:
--   depot_name, isin (optional), symbol (optional; eins von beiden) ODER position (aktuelles Symbol oder ISIN in einem
--   Feld, ISIN an der Form erkannt; fuer set_holding, wo symbol/isin die NEUEN Werte sind). Depot ueber fn_resolve_account (nur Depot-Typen,
--   erst exakt, dann ohne Gross-/Kleinschreibung); Position: ISIN (ohne Gross-/Kleinschreibung), ohne ISIN-Treffer
--   das Symbol ohne Gross-/Kleinschreibung (auch bei Aktien mit ISIN). Die EINE Positionssuche der Tools; fn_resolve_holding
--   bleibt nur die Identitaets-Pruefung beim Kauf (neue Position anlegen oder bestehende fortschreiben).
--   Rueckgabe:
--     {ok:true, holding_id, depot_id, depot_name, settlement_account_id, currency (Depot), available_shares, symbol, isin,
--      name, holding_currency}
--     {ok:false, code:'depot_not_found'|'depot_ambiguous', reason, candidates}       (Depots)
--     {ok:false, code:'holding_not_found'|'holding_ambiguous', reason, candidates}   (Positionen des Depots)
--   Konsumenten: tool_book_stock_sell, tool_set_holding, tool_book_dividend, tool_delete_holding (Read-only-Node vor dem Probelauf).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_find_holding(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pos    TEXT := NULLIF(btrim(p->>'position'), '');   -- set_holding: aktuelles Symbol ODER ISIN in einem Feld
    v_isin   TEXT := COALESCE(NULLIF(upper(btrim(p->>'isin')), ''),
                              CASE WHEN upper(v_pos) ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$' THEN upper(v_pos) END);
    v_symbol TEXT := COALESCE(NULLIF(btrim(p->>'symbol'), ''),
                              CASE WHEN upper(v_pos) !~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$' THEN v_pos END);
    v_dep    RECORD;
    v_acct   finance.accounts%ROWTYPE;
    v_hits   JSONB;
    v_all    JSONB;
BEGIN
    SELECT r.id, r.hit_count, r.candidates INTO v_dep
    FROM finance.fn_resolve_account(p->>'depot_name', ARRAY['stocks_depot', 'crypto_depot'], TRUE) r;
    IF v_dep.hit_count <> 1 THEN
        RETURN jsonb_build_object('ok', false,
            'code', CASE WHEN v_dep.hit_count = 0 THEN 'depot_not_found' ELSE 'depot_ambiguous' END,
            'reason', CASE WHEN v_dep.hit_count = 0
                           THEN 'No depot named "' || COALESCE(p->>'depot_name', '') || '" - ask the user which depot.'
                           ELSE 'Several depots match "' || (p->>'depot_name') || '" - ask the user which one (candidates).' END,
            'candidates', CASE WHEN v_dep.hit_count = 0
                               THEN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) ORDER BY a.id)
                                                FROM finance.accounts a
                                               WHERE a.status = 'active' AND a.account_type IN ('stocks_depot', 'crypto_depot')),
                                             '[]'::jsonb)
                               ELSE v_dep.candidates END);
    END IF;
    SELECT * INTO v_acct FROM finance.accounts WHERE id = v_dep.id;

    SELECT jsonb_agg(jsonb_build_object('holding_id', h.id, 'symbol', h.symbol, 'isin', h.isin, 'name', h.name,
                                        'shares', h.shares, 'currency', h.currency) ORDER BY h.id)
    INTO v_hits
    FROM finance.depot_holdings h
    WHERE h.account_id = v_acct.id AND v_isin IS NOT NULL AND upper(h.isin) = v_isin;
    -- kein ISIN-Treffer (oder keine ISIN) -> Symbol ohne Gross-/Kleinschreibung
    IF v_hits IS NULL AND v_symbol IS NOT NULL THEN
        SELECT jsonb_agg(jsonb_build_object('holding_id', h.id, 'symbol', h.symbol, 'isin', h.isin, 'name', h.name,
                                            'shares', h.shares, 'currency', h.currency) ORDER BY h.id)
        INTO v_hits
        FROM finance.depot_holdings h
        WHERE h.account_id = v_acct.id AND lower(h.symbol) = lower(v_symbol);
    END IF;

    IF v_hits IS NULL OR jsonb_array_length(v_hits) <> 1 THEN
        SELECT jsonb_agg(jsonb_build_object('holding_id', h.id, 'symbol', h.symbol, 'isin', h.isin, 'name', h.name,
                                            'shares', h.shares) ORDER BY h.id)
        INTO v_all FROM finance.depot_holdings h WHERE h.account_id = v_acct.id;
        RETURN jsonb_build_object('ok', false,
            'code', CASE WHEN v_hits IS NULL THEN 'holding_not_found' ELSE 'holding_ambiguous' END,
            'reason', CASE WHEN v_hits IS NULL
                           THEN 'No position "' || COALESCE(v_isin, v_symbol, '') || '" in depot "' || v_acct.name
                                || '" - ask the user which position (candidates = the positions of this depot).'
                           ELSE 'Several positions match "' || COALESCE(v_isin, v_symbol) || '" - ask the user which one (candidates).' END,
            'candidates', COALESCE(v_hits, v_all, '[]'::jsonb));
    END IF;

    RETURN jsonb_build_object('ok', true,
        'holding_id', (v_hits->0->>'holding_id')::int,
        'depot_id', v_acct.id, 'depot_name', v_acct.name,
        'settlement_account_id', v_acct.settlement_account_id, 'currency', v_acct.currency,
        'available_shares', (v_hits->0->>'shares')::numeric,
        'symbol', v_hits->0->>'symbol', 'isin', v_hits->0->>'isin',
        'name', v_hits->0->>'name', 'holding_currency', v_hits->0->>'currency');
END;
$$;
