-- ============================================================
-- fn_sell_real_estate (ATOMIC WRITE) -- Verkauf einer Immobilie buchen
--   Bucht den Verkaufserloes (einbeinig: externer Kaeufer nicht getrackt) auf ein Konto und setzt
--   die Immobilie auf status='sold' (current_value = Verkaufspreis, value_updated_at = Verkaufsdatum,
--   sale_tx_id = Erloes-Tx -> fn_void_transaction dieser Tx setzt die Immobilie zurueck auf 'active').
--   ALLOW+HINWEIS bei offenem Kredit: verknuepfte AKTIVE Kredite werden NICHT automatisch abgeloest;
--   sie bleiben bestehen und das Tool gibt eine kompakte linked_loans-Liste (Name + aktuelle Restschuld)
--   zurueck, damit das LLM dem Nutzer einen konkreten Hinweis geben kann (separat via settle_loan abloesen).
--   KORRIGIERBAR (kein RAISE): bereits verkauft / sale_price <= 0 / Erloes-Konto ist Depot- oder Kreditkonto
--   (fn_bookable_account_reason) -> {ok:false, reason}.
--   Eingabe jsonb: real_estate_name, proceeds_account_id (n8n-resolved), sale_date, sale_price.
--   Resolve findet auch sold (p_active_only=FALSE) -> freundliches {ok:false} statt RAISE.
--   RUECKGABE: {ok:true, real_estate_id, proceeds_tx_id, sale_price, linked_loan_count, linked_loans, note,
--   linked_reserve ({goal_id, name, current_amount} der weiterlaufenden Instandhaltungsruecklage oder null)}.
--   RAISE nur bei not-found / mehrdeutig.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_sell_real_estate(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_name      TEXT := p->>'real_estate_name';
    v_acct      INT  := (p->>'proceeds_account_id')::int;
    v_date      DATE;
    v_price     NUMERIC := NULLIF(p->>'sale_price', '')::numeric;
    v_resolve   RECORD;
    v_re        finance.real_estate%ROWTYPE;
    v_tx        INT;
    v_loans     JSONB;
    v_cnt       INT;
    v_note      TEXT;
    v_dates     JSONB;
    v_reserve   JSONB;
BEGIN
    -- relative Datumsangabe ("last friday") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['sale_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_date := COALESCE(NULLIF(p->>'sale_date', '')::date, core.fn_today());
    SELECT r.id, r.hit_count, r.candidates INTO v_resolve
    FROM finance.fn_resolve_real_estate(v_name, FALSE) r;

    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found',
            'reason', 'Real estate "' || COALESCE(v_name, '') || '" not found - ask the user for the exact name.', 'candidates', '[]'::jsonb);
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'ambiguous',
            'reason', 'Multiple properties match "' || v_name || '" - ask the user which one (candidates).', 'candidates', v_resolve.candidates);
    END IF;

    SELECT * INTO v_re FROM finance.real_estate WHERE id = v_resolve.id;

    -- Korrigierbar: bereits verkauft / nicht-positiver Preis.
    IF v_re.status = 'sold' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Property "' || v_re.name || '" is already marked as sold.');
    END IF;
    IF v_price IS NULL OR v_price <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Sale price must be a positive number, got ' || COALESCE(v_price::text, 'null') || '.');
    END IF;
    -- Korrigierbar (Audit Paket 2, Kontotyp): der Erloes geht auf ein Geld-Konto, nie auf ein Depot-/Kreditkonto.
    v_note := finance.fn_bookable_account_reason(v_acct);
    IF v_note IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_note);
    END IF;

    -- 1. Verkaufserloes gutschreiben (einbeinig; Saldo via Trigger)
    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, description)
    VALUES (v_acct, v_price, v_date, 'other', 'Verkaufserlös ' || v_re.name)
    RETURNING id INTO v_tx;

    -- 2. Immobilie als verkauft markieren; sale_tx_id = Erloes-Tx (Audit F5: Void dieser Tx setzt zurueck)
    UPDATE finance.real_estate
    SET status = 'sold', current_value = v_price, value_updated_at = v_date, sale_tx_id = v_tx
    WHERE id = v_re.id;

    -- 3. Allow+Hinweis: noch OFFENE verknuepfte Kredite (active ODER paused = fn_loan_is_outstanding, Audit Paket 2;
    --    Name + aktuelle Restschuld)
    SELECT COALESCE(jsonb_agg(jsonb_build_object('name', l.name,
               'remaining_debt', GREATEST(-b.balance, 0)) ORDER BY l.id), '[]'::jsonb),
           COUNT(*)
    INTO v_loans, v_cnt
    FROM finance.loans l
    JOIN finance.account_balances b ON b.account_id = l.loan_account_id
    WHERE l.real_estate_id = v_re.id AND finance.fn_loan_is_outstanding(l.status);

    v_note := CASE WHEN v_cnt > 0
        THEN v_cnt || ' linked loan(s) remain after the sale and were NOT paid off automatically — settle them separately via settle_loan.'
        ELSE NULL END;

    -- 4. Allow+Hinweis: eine aktive Instandhaltungsruecklage laeuft weiter (Rate + Zweckbindung) -> der Nutzer
    --    entscheidet, ob er sie schliesst (close_savings_goal) oder das Geld anders verwendet.
    SELECT jsonb_build_object('goal_id', g.id, 'name', g.name, 'current_amount', round(COALESCE(sp.current_amount, 0), 2))
      INTO v_reserve
    FROM finance.savings_goals g
    LEFT JOIN finance.savings_goal_progress sp ON sp.id = g.id
    WHERE g.real_estate_id = v_re.id AND g.status = 'active';
    IF v_reserve IS NOT NULL THEN
        v_note := concat_ws(' ', v_note, 'The maintenance reserve "' || (v_reserve->>'name') || '" of this property is still '
                  || 'active (its monthly rate keeps running) - ask the user whether to close it with close_savings_goal.');
    END IF;

    RETURN jsonb_build_object('ok', true,
        'real_estate_id', v_re.id, 'proceeds_tx_id', v_tx, 'sale_price', v_price,
        'linked_loan_count', v_cnt, 'linked_loans', v_loans, 'note', v_note, 'linked_reserve', v_reserve,
        'effective', (v_dates->'resolved') || jsonb_build_object('sale_date', v_date));
END;
$$;
