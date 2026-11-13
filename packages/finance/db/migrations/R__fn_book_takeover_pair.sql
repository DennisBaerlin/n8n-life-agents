-- ============================================================
-- fn_book_takeover_pair (INTERNER WRITE-BAUSTEIN, kein Tool) -- eine Tranche einer Bestandsuebernahme
--   Die eine Stelle, die ein Uebernahme-Paar schreibt: Kauf (category buy, unit_price = genannter Einstand) +
--   Gegenbuchung position_takeover in gleicher Hoehe auf dem Verrechnungskonto -> dessen Saldo bleibt unveraendert.
--   Aufrufer: fn_book_stock_buy (existing_position, nach seinem "Position haelt schon Stueck"-Guard) und
--   fn_import_bundle (2. und weitere Zeilen derselben Position in einem Batch = datierte Tranchen, z. B. 20
--   Sparplan-Ausfuehrungen als echte Kaeufe).
--   Bewusst positionale Argumente, kein jsonb: kein LLM-/Staging-Payload kann diesen Pfad an einem Guard vorbei
--   erreichen. Alle Tranchen eines Writes teilen p_group (ein Write = eine group_id = ein Void).
--   Eingabe: p_holding, p_settle (Verrechnungskonto), p_shares, p_unit_price, p_fee, p_date, p_group, p_label
--   (Kennung fuer den Buchungstext); optional p_with_counter (Default true), p_cost_origin (Herkunft des Einstands
--   am Kauf, transactions.cost_origin). p_with_counter=false = echter Kauf ohne Gegenbuchung (Cash-Abfluss), nur
--   fn_replace_takeover_with_lots (ueber fn_replace_takeover_apply) fuer Einzelkaeufe nach dem bestaetigten
--   Kontostand-Tag (der Stand davon enthaelt sie noch nicht).
--   Rueckgabe: {ok:true, buy_tx_id} | {ok:false, reason} (nicht-positive Stueck/Kurs, negative Gebuehr, > 8 Stueck-
--   Stellen / Betrag < 1 Cent via fn_trade_amount_reason). Kurs auf 8, Gebuehr auf 2 Stellen gerundet.
--   Backstop der Gegenbuchungs-Form: CHECK finance_transactions_position_takeover_shape.
-- ============================================================
DROP FUNCTION IF EXISTS finance.fn_book_takeover_pair(int, int, numeric, numeric, numeric, date, uuid, text);
DROP FUNCTION IF EXISTS finance.fn_book_takeover_pair(int, int, numeric, numeric, numeric, date, uuid, text, boolean);
CREATE OR REPLACE FUNCTION finance.fn_book_takeover_pair(
    p_holding int, p_settle int, p_shares numeric, p_unit_price numeric, p_fee numeric,
    p_date date, p_group uuid, p_label text, p_with_counter boolean DEFAULT TRUE, p_cost_origin text DEFAULT NULL)
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
        (account_id, amount, transaction_date, category, holding_id, shares, order_fee, unit_price, description, group_id, cost_origin)
    VALUES (p_settle, -(p_shares * v_price + v_fee), p_date, 'buy', p_holding, p_shares, v_fee, v_price,
            CASE WHEN p_with_counter THEN 'Bestandsübernahme ' ELSE 'Kauf ' END || trim_scale(p_shares) || ' ' || p_label || ' @ ' || trim_scale(v_price)
                || ' (Gebühr ' || trim_scale(v_fee) || ')',
            p_group, p_cost_origin)
    RETURNING id INTO v_buy;

    IF p_with_counter THEN
        INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description, group_id)
        VALUES (p_settle, p_shares * v_price + v_fee, p_date, 'position_takeover',
                'Gegenbuchung Bestandsübernahme ' || trim_scale(p_shares) || ' ' || p_label, p_group);
    END IF;

    RETURN jsonb_build_object('ok', true, 'buy_tx_id', v_buy);
END;
$$;
