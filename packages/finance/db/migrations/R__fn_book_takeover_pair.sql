-- ============================================================
-- fn_book_takeover_pair (INTERNER WRITE-BAUSTEIN, kein Tool) -- eine Tranche einer Bestandsuebernahme
--   Die EINE Stelle, die ein Uebernahme-Paar schreibt: Kauf (category buy, unit_price = genannter Einstand) +
--   Gegenbuchung position_takeover in gleicher Hoehe auf dem Verrechnungskonto -> dessen Saldo bleibt unveraendert.
--   Aufrufer: fn_book_stock_buy (existing_position, nach seinem "Position haelt schon Stueck"-Guard) und
--   fn_import_bundle (2. und weitere Zeilen DERSELBEN Position in einem Batch = datierte Tranchen, Live-Befund
--   2026-10-28: 20 Sparplan-Ausfuehrungen sollten als echte Kaeufe uebernommen werden).
--   Bewusst POSITIONALE Argumente, kein jsonb: kein LLM-/Staging-Payload kann diesen Pfad an einem Guard vorbei
--   erreichen (Plan-Review 2026-10-28). Alle Tranchen eines Writes teilen p_group (ein Write = eine group_id = ein Void).
--   Eingabe: holding_id, settlement_id, shares, unit_price, fee, date, group_id, label (Kennung fuer den Buchungstext).
--   RUECKGABE: {ok:true, buy_tx_id} | {ok:false, reason} (nicht-positive Stueck/Kurs, negative Gebuehr, > 8 Stueck-
--   Stellen / Betrag < 1 Cent via fn_trade_amount_reason). Kurs auf 8, Gebuehr auf 2 Stellen gerundet (Rundungs-Paket).
--   CHECK finance_transactions_position_takeover_shape bleibt der Backstop der Gegenbuchungs-Form.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_takeover_pair(
    p_holding int, p_settle int, p_shares numeric, p_unit_price numeric, p_fee numeric,
    p_date date, p_group uuid, p_label text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_price  NUMERIC := round(p_unit_price, 8);
    v_fee    NUMERIC := round(COALESCE(p_fee, 0), 2);
    v_reason TEXT;
    v_buy    INT;
BEGIN
    IF p_shares IS NULL OR p_shares <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Share count must be a positive number, got ' || COALESCE(p_shares::text, 'null') || '.');
    END IF;
    IF v_price IS NULL OR v_price <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Price per share must be a positive number (at most 8 decimal places), got '
                   || COALESCE(p_unit_price::text, 'null') || '.');
    END IF;
    IF v_fee < 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Order fee must not be negative, got ' || v_fee || '.');
    END IF;
    v_reason := finance.fn_trade_amount_reason(p_shares, p_shares * v_price + v_fee);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;

    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, holding_id, shares, order_fee, unit_price, description, group_id)
    VALUES (p_settle, -(p_shares * v_price + v_fee), p_date, 'buy', p_holding, p_shares, v_fee, v_price,
            'Bestandsübernahme ' || trim_scale(p_shares) || ' ' || p_label || ' @ ' || trim_scale(v_price)
                || ' (Gebühr ' || trim_scale(v_fee) || ')',
            p_group)
    RETURNING id INTO v_buy;

    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description, group_id)
    VALUES (p_settle, p_shares * v_price + v_fee, p_date, 'position_takeover',
            'Gegenbuchung Bestandsübernahme ' || trim_scale(p_shares) || ' ' || p_label, p_group);

    RETURN jsonb_build_object('ok', true, 'buy_tx_id', v_buy);
END;
$$;
