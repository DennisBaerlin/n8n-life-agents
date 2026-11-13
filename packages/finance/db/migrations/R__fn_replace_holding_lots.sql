-- ============================================================
-- fn_replace_holding_lots (ATOMIC WRITE) -- Bestandsuebernahme durch eingetippte Einzelkaeufe ersetzen
--   Zwei Schritte (erst stornieren, dann die Liste pruefen) liessen die Position kurz fehlen, und die Liste konnte
--   danach abgelehnt werden. Darum prueft die DB die ganze Liste
--   zuerst und tauscht in einer Transaktion: neue Lots rein, alte Uebernahme raus (Muster fn_replace_takeover_with_lots,
--   dessen Schreib-Teil fn_replace_takeover_apply gemeinsam ist).
--   Eingabe jsonb: depot_name, position (Symbol oder ISIN), lots = Array [{date, shares, price_per_share oder
--   cost_basis_total (Preis der Stuecke ohne Gebuehr, wie fn_book_stock_buy), order_fee (opt)}] (max. 200). Datum ISO oder
--   relativ (core.fn_resolve_input_dates je Lot), Zahlen tolerant ("80,50"). Das Modell rechnet nie: Kurs aus Gesamtbetrag
--   = fn_unit_price_from_total, Einstand/Stueck pflegen die Trigger.
--   Ersetzbar ist eine Position nur, wenn ihre Uebernahme(n) reine Uebernahme-Gruppen sind: je Gruppe Summe der Betraege 0,
--   nur Kaeufe dieser Position auf dem Verrechnungskonto + position_takeover-Gegenbuchungen, jeder Kauf mit Gegenbuchung.
--   Die neuen Lots sind immer cash-neutrale Uebernahme-Paare in einer neuen group_id -- das Verrechnungskonto aendert sich
--   nie (der genannte Stand enthaelt den Bestand schon). Echte Folge-Buchungen der Position (Kaeufe/Verkaeufe ausserhalb
--   der Uebernahme-Gruppen) bleiben unberuehrt; deshalb: jedes Lot-Datum <= juengster alter Uebernahme-Tag (ein Kauf
--   danach gehoert zu tool_book_stock_buy; Monats-Check und Rendite haengen an diesem Tag) und der Bestand danach
--   (Lots + Folge-Buchungen) darf nicht negativ werden. Die Stueckzahl darf sich aendern (die Liste ist die Wahrheit, die
--   Karte zeigt alt -> neu). Ein Probelauf (core.fn_dry_run) liefert Karte + effective.lots (aufgeloeste ISO-Daten, Kurs je
--   Stueck), der echte Write nach dem Tipp bekommt sie fest.
--   Rueckgabe: {ok:true, holding_id, group_id, shares_before, total_shares, avg_before, avg_purchase_price,
--   settlement_balance, settlement_change, effective:{lots:[{date, shares, price_per_share, order_fee}]}, card_lines}
--   | {ok:false, code, reason, ...}: holding_not_found|holding_ambiguous|depot_not_found|depot_ambiguous (candidates),
--   invalid_lots, invalid_date (lot_no), lot_invalid (lot_no), lot_in_future (lot_no), lot_after_takeover (lot_no),
--   no_takeover, not_takeover_only, oversell. Nie ein RAISE bei korrigierbaren Fehlern (ein RAISE = echter Defekt).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_replace_holding_lots(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_find     JSONB;
    v_h        finance.depot_holdings%ROWTYPE;
    v_settle   INT;
    v_old      UUID[];
    v_bad      UUID;
    v_day      DATE;            -- juengster alter Uebernahme-Tag
    v_before   NUMERIC;         -- Stueck der Position vor dem Tausch (inkl. Folge-Buchungen)
    v_later    NUMERIC;         -- Stueck-Summe der Buchungen ausserhalb der alten Gruppen (Folgekaeufe +, Verkaeufe -)
    v_avg_old  NUMERIC;
    v_raw      JSONB := p->'lots';
    v_lot      JSONB;
    v_i        INT;
    v_dates    JSONB;
    v_d        DATE;
    v_shares   NUMERIC;
    v_price    NUMERIC;
    v_total    NUMERIC;
    v_fee      NUMERIC;
    v_reason   TEXT;
    v_today    DATE := core.fn_today();
    v_eff      JSONB := '[]'::jsonb;
    v_plan     JSONB := '[]'::jsonb;
    v_new_sum  NUMERIC := 0;
    v_bal_old  NUMERIC;
    v_bal_new  NUMERIC;
    v_ap       JSONB;
    v_ccy      TEXT;
    v_scy      TEXT;
    v_card     JSONB := '[]'::jsonb;
BEGIN
    -- Position per Depot-Name + Symbol/ISIN: die eine Positionssuche der Tools (0/mehrdeutig -> Daten, keine Karte)
    v_find := finance.fn_find_holding(jsonb_build_object('depot_name', p->>'depot_name', 'position', p->>'position'));
    IF (v_find->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_find;
    END IF;
    IF v_raw IS NULL OR jsonb_typeof(v_raw) <> 'array' OR jsonb_array_length(v_raw) = 0 OR jsonb_array_length(v_raw) > 200 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_lots', 'reason',
            'lots must be a JSON list of 1 to 200 purchases, each {date, shares, price_per_share or cost_basis_total, order_fee}. '
            || 'Ask the user for the individual purchases.');
    END IF;

    v_settle := (v_find->>'settlement_account_id')::int;
    -- Position + Verrechnungskonto sperren (doppelter Tipp / parallele Laeufe)
    SELECT * INTO v_h FROM finance.depot_holdings WHERE id = (v_find->>'holding_id')::int FOR UPDATE;
    PERFORM 1 FROM finance.account_balances WHERE account_id = v_settle FOR UPDATE;

    -- alte Uebernahme-Gruppen vor dem ersten Write festhalten (die neue Gruppe waere sonst selbst eine)
    SELECT array_agg(DISTINCT t.group_id) INTO v_old
    FROM finance.transactions t
    WHERE t.holding_id = v_h.id AND t.category::text = 'buy' AND t.group_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM finance.transactions g WHERE g.group_id = t.group_id AND g.category::text = 'position_takeover');
    IF v_old IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'no_takeover', 'reason',
            'This position has no taken-over holding to replace (it was booked as real purchases). To change real purchases '
            || 'void them (tool_void_transaction) and book the correct ones (tool_book_stock_buy).');
    END IF;
    SELECT g.group_id INTO v_bad
    FROM finance.transactions g
    WHERE g.group_id = ANY(v_old)
    GROUP BY g.group_id
    HAVING sum(g.amount) <> 0
        OR count(*) FILTER (WHERE NOT ((g.category::text = 'buy' AND g.holding_id = v_h.id)
                                       OR g.category::text = 'position_takeover')) > 0
        OR count(*) FILTER (WHERE g.account_id <> v_settle) > 0
        OR count(*) FILTER (WHERE g.category::text = 'buy') <> count(*) FILTER (WHERE g.category::text = 'position_takeover')
    LIMIT 1;
    IF v_bad IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_takeover_only', 'reason',
            'The takeover of this position also contains real purchases (cash left the settlement account), so replacing '
            || 'it would change the account balance. Void those transactions first (tool_void_transaction), then try again.');
    END IF;

    SELECT max(t.transaction_date) INTO v_day FROM finance.transactions t
    WHERE t.group_id = ANY(v_old) AND t.category::text = 'buy';
    SELECT COALESCE(sum(t.shares), 0) INTO v_before FROM finance.transactions t WHERE t.holding_id = v_h.id;
    SELECT COALESCE(sum(t.shares), 0) INTO v_later FROM finance.transactions t
    WHERE t.holding_id = v_h.id AND (t.group_id IS NULL OR NOT t.group_id = ANY(v_old));
    v_avg_old := v_h.average_purchase_price;

    -- jedes Lot pruefen (alles vor dem ersten Write); Rueckgabe benennt die Lot-Nummer
    FOR v_lot, v_i IN SELECT e, o::int FROM jsonb_array_elements(v_raw) WITH ORDINALITY AS x(e, o) LOOP
        IF jsonb_typeof(v_lot) <> 'object' THEN
            RETURN jsonb_build_object('ok', false, 'code', 'lot_invalid', 'lot_no', v_i,
                'reason', 'Lot ' || v_i || ' must be an object {date, shares, price_per_share or cost_basis_total, order_fee}.');
        END IF;
        IF NULLIF(btrim(v_lot->>'date'), '') IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'invalid_date', 'lot_no', v_i,
                'reason', 'Lot ' || v_i || ' needs the purchase date.');
        END IF;
        v_dates := core.fn_resolve_input_dates(v_lot, ARRAY['date']);
        IF (v_dates->>'ok')::boolean IS DISTINCT FROM true THEN
            RETURN v_dates || jsonb_build_object('lot_no', v_i, 'reason', 'Lot ' || v_i || ': ' || (v_dates->>'reason'));
        END IF;
        v_d := (v_dates->'p'->>'date')::date;
        IF v_d > v_today THEN
            RETURN jsonb_build_object('ok', false, 'code', 'lot_in_future', 'lot_no', v_i,
                'reason', 'Lot ' || v_i || ' is dated ' || v_d || ', which is in the future.');
        END IF;
        IF v_d > v_day THEN
            RETURN jsonb_build_object('ok', false, 'code', 'lot_after_takeover', 'lot_no', v_i,
                'reason', 'Lot ' || v_i || ' (' || v_d || ') is after the day of the takeover (' || v_day || '). A purchase after '
                       || 'that day is a new purchase: book it with tool_book_stock_buy. Here only the purchases that make up the '
                       || 'taken-over holding are replaced.');
        END IF;
        v_shares := finance.fn_parse_numeric_or_null(v_lot->>'shares', false);
        IF v_shares IS NULL OR v_shares <= 0 THEN
            RETURN jsonb_build_object('ok', false, 'code', 'lot_invalid', 'lot_no', v_i,
                'reason', 'Lot ' || v_i || ': share count must be a positive number, got ' || COALESCE(v_lot->>'shares', 'nothing') || '.');
        END IF;
        IF NULLIF(btrim(v_lot->>'price_per_share'), '') IS NOT NULL AND NULLIF(btrim(v_lot->>'cost_basis_total'), '') IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'lot_invalid', 'lot_no', v_i,
                'reason', 'Lot ' || v_i || ': give either price_per_share or cost_basis_total, not both.');
        END IF;
        IF NULLIF(btrim(v_lot->>'cost_basis_total'), '') IS NOT NULL THEN
            v_total := finance.fn_parse_numeric_or_null(v_lot->>'cost_basis_total', true);
            v_price := CASE WHEN v_total > 0 THEN finance.fn_unit_price_from_total(v_total, v_shares) END;
        ELSE
            v_price := round(finance.fn_parse_numeric_or_null(v_lot->>'price_per_share', false), 8);
        END IF;
        IF v_price IS NULL OR v_price <= 0 THEN
            RETURN jsonb_build_object('ok', false, 'code', 'lot_invalid', 'lot_no', v_i,
                'reason', 'Lot ' || v_i || ': give the price per share or the total price paid (a positive number).');
        END IF;
        IF NULLIF(btrim(v_lot->>'order_fee'), '') IS NULL THEN
            v_fee := 0;
        ELSE
            v_fee := round(finance.fn_parse_numeric_or_null(v_lot->>'order_fee', true), 2);
            IF v_fee IS NULL OR v_fee < 0 THEN
                RETURN jsonb_build_object('ok', false, 'code', 'lot_invalid', 'lot_no', v_i,
                    'reason', 'Lot ' || v_i || ': the order fee must be zero or a positive number, got ' || (v_lot->>'order_fee') || '.');
            END IF;
        END IF;
        v_reason := finance.fn_trade_amount_reason(v_shares, v_shares * v_price + v_fee);
        IF v_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'lot_invalid', 'lot_no', v_i, 'reason', 'Lot ' || v_i || ': ' || v_reason);
        END IF;
        v_new_sum := v_new_sum + v_shares;
        v_eff  := v_eff  || jsonb_build_object('date', v_d, 'shares', v_shares, 'price_per_share', v_price, 'order_fee', v_fee);
        v_plan := v_plan || jsonb_build_object('date', v_d, 'shares', v_shares, 'price', v_price, 'fee', v_fee, 'cash', false);
    END LOOP;

    -- die spaeteren Verkaeufe haengen an den Stuecken: der Bestand danach darf nicht negativ werden
    IF v_new_sum + v_later < 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'oversell', 'reason',
            'The purchases add up to ' || trim_scale(v_new_sum) || ' units, but later sales of this position need more ('
            || trim_scale(-v_later) || ' net). Check the units of the purchases.');
    END IF;

    v_bal_old := finance.fn_get_balance(v_settle);
    v_ap := finance.fn_replace_takeover_apply(v_h.id, v_settle, v_plan, v_old, v_h.symbol);
    v_bal_new := finance.fn_get_balance(v_settle);
    SELECT * INTO v_h FROM finance.depot_holdings WHERE id = v_h.id;   -- Post-State nach den Triggern

    -- Karte: je Lot eine Zeile, dann Stueck + Einstand alt -> neu, dann die Wirkung aufs Verrechnungskonto (DB-Delta)
    v_ccy := v_h.currency;
    SELECT currency INTO v_scy FROM finance.accounts WHERE id = v_settle;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
               core.fn_ui_tpl('finance.tpl.holding_lot_row', jsonb_build_object(
                   'date', core.fn_ui_date((l->>'date')::date),
                   'shares', core.fn_ui_num((l->>'shares')::numeric, 8),
                   'amount', core.fn_ui_money((l->>'shares')::numeric * (l->>'price_per_share')::numeric + (l->>'order_fee')::numeric, v_ccy))))
               ORDER BY o), '[]'::jsonb)
    INTO v_card FROM jsonb_array_elements(v_eff) WITH ORDINALITY AS x(l, o);
    v_card := v_card || jsonb_build_array(
        jsonb_build_object('kind', 'raw', 'value',
            core.fn_ui_tpl('finance.tpl.holding_lots_replaced', jsonb_build_object(
                'name', v_h.name,
                'shares_before', core.fn_ui_num(v_before, 8),
                'shares', core.fn_ui_num(v_h.shares, 8),
                'avg_before', core.fn_ui_money(v_avg_old, v_ccy),
                'avg', core.fn_ui_money(v_h.average_purchase_price, v_ccy)))),
        core.fn_ui_money(v_bal_new - v_bal_old, v_scy, true) || jsonb_build_object('label', 'finance.label.lots_settlement_change'));

    RETURN jsonb_build_object('ok', true, 'holding_id', v_h.id, 'group_id', v_ap->>'group_id',
        'shares_before', v_before, 'total_shares', v_h.shares,
        'avg_before', v_avg_old, 'avg_purchase_price', v_h.average_purchase_price,
        'settlement_balance', v_bal_new, 'settlement_change', v_bal_new - v_bal_old,
        'effective', jsonb_build_object('lots', v_eff), 'card_lines', v_card);
END;
$$;
