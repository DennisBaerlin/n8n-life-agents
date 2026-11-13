-- ============================================================
-- test_fn_replace_holding_lots -- eingetippte Einzelkaeufe ersetzen eine Bestandsuebernahme atomar
--   Werte erfunden, Daten relativ zu core.fn_today(). Cashkonto 1000 (Stichtag heute-20), Depot daran.
--   A: Uebernahme 10 @ 25 (heute-5) -> 3 Lots 4 (Kurswert 80 + Gebuehr 1) + 3 @ 22 + 3 (Kurswert 90) = 10 Stueck, Einstand 23.70,
--      Verrechnungskonto bleibt 1000. B: Uebernahme 5 @ 10, Lots zusammen 4 -> Stueckzahl 5 -> 4 (Karte zeigt alt -> neu).
--   C/D/E/F/G: Ablehnungen und Sonderfaelle (siehe Marker). Ablehnungen aendern nichts (Zeilenzahl vorher = nachher).
-- ============================================================
BEGIN;
DO $$
DECLARE
    T       DATE := core.fn_today();
    v_cash  INT;
    v_depot INT;
    v_a INT; v_b INT; v_c INT; v_d INT; v_e INT; v_f INT; v_g INT;
    v_res   JSONB;
    v_dry   JSONB;
    v_n     INT;
    v_grp   UUID;
    v_p     JSONB;
    v_old   UUID;
    v_sell  JSONB;
    v_bal   NUMERIC;
BEGIN
    v_cash := (finance.fn_create_account(jsonb_build_object('name', '__t_hl_cash__', 'account_type', 'cash', 'currency', 'EUR',
                   'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    v_depot := (finance.fn_create_account(jsonb_build_object('name', '__t_hl_depot__', 'account_type', 'stocks_depot',
                    'currency', 'EUR', 'settlement_id', v_cash))->>'account_id')::int;

    -- Positionen anlegen (Bestandsuebernahme = ein Paar je Position)
    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_cash, 'isin', 'IE00HLOTA001',
                 'symbol', 'HLA', 'name', 'HL A ETF', 'shares', 10, 'price_per_share', 25, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP A: %', v_res; END IF;
    v_a := (v_res->>'holding_id')::int;
    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_cash, 'isin', 'IE00HLOTB001',
                 'symbol', 'HLB', 'name', 'HL B ETF', 'shares', 5, 'price_per_share', 10, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    v_b := (v_res->>'holding_id')::int;
    -- C: normaler Kauf ohne Uebernahme
    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_cash, 'isin', 'IE00HLOTC001',
                 'symbol', 'HLC', 'name', 'HL C ETF', 'shares', 2, 'price_per_share', 10, 'order_fee', 0,
                 'transaction_date', (T - 3)::text));
    v_c := (v_res->>'holding_id')::int;
    -- D: Uebernahme-Gruppe mit einem echten Kauf ohne Gegenbuchung (so sieht eine per Export ersetzte Position mit Kauf nach dem Stichtag aus)
    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_cash, 'isin', 'IE00HLOTD001',
                 'symbol', 'HLD', 'name', 'HL D ETF', 'shares', 2, 'price_per_share', 10, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    v_d := (v_res->>'holding_id')::int;
    SELECT group_id INTO v_old FROM finance.transactions WHERE holding_id = v_d AND category::text = 'buy';
    PERFORM finance.fn_book_takeover_pair(v_d, v_cash, 1, 10, 0, T - 2, v_old, 'HLD', false);
    -- E: Uebernahme 10 + ein spaeterer echter Verkauf von 8
    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_cash, 'isin', 'IE00HLOTE001',
                 'symbol', 'HLE', 'name', 'HL E ETF', 'shares', 10, 'price_per_share', 10, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    v_e := (v_res->>'holding_id')::int;
    v_sell := finance.fn_book_stock_sell(jsonb_build_object('price_currency_confirmed',true,'settlement_id', v_cash, 'holding_id', v_e, 'shares', 8,
                  'price_per_share', 11, 'order_fee', 0, 'transaction_date', (T - 1)::text, 'symbol', 'HLE'));
    IF (v_sell->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP E sell: %', v_sell; END IF;
    -- F: Uebernahme 10 + ein spaeterer echter Kauf von 2
    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_cash, 'isin', 'IE00HLOTF001',
                 'symbol', 'HLF', 'name', 'HL F ETF', 'shares', 10, 'price_per_share', 10, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    v_f := (v_res->>'holding_id')::int;
    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_cash, 'isin', 'IE00HLOTF001',
                 'symbol', 'HLF', 'shares', 2, 'price_per_share', 12, 'order_fee', 0, 'transaction_date', (T - 1)::text));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP F buy: %', v_res; END IF;
    -- G: Import-Tranchen = eine Gruppe mit zwei Paaren
    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_cash, 'isin', 'IE00HLOTG001',
                 'symbol', 'HLG', 'name', 'HL G ETF', 'shares', 2, 'price_per_share', 10, 'order_fee', 0,
                 'transaction_date', (T - 30)::text, 'existing_position', true));
    v_g := (v_res->>'holding_id')::int;
    SELECT group_id INTO v_old FROM finance.transactions WHERE holding_id = v_g AND category::text = 'buy';
    PERFORM finance.fn_book_takeover_pair(v_g, v_cash, 3, 12, 0, T - 5, v_old, 'HLG');
    -- die echten Kaeufe/Verkaeufe (C, D-Rest, E, F) haben den Saldo bewegt; ab hier zaehlt das Delta je Aufruf
    v_bal := finance.fn_get_balance(v_cash);

    -- ---------- A: Erfolg (mit Probelauf davor) ----------
    v_p := jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'IE00HLOTA001', 'lots', jsonb_build_array(
        jsonb_build_object('date', (T - 60)::text, 'shares', 4, 'cost_basis_total', 80, 'order_fee', 1),
        jsonb_build_object('date', '-30 days', 'shares', 3, 'price_per_share', 22),
        jsonb_build_object('date', (T - 10)::text, 'shares', '3', 'cost_basis_total', '90')));
    v_dry := core.fn_dry_run('finance.fn_replace_holding_lots(jsonb)'::regprocedure, v_p);
    IF (v_dry->>'ok')::boolean IS DISTINCT FROM true OR (v_dry->>'total_shares')::numeric <> 10
       OR (v_dry->>'avg_purchase_price')::numeric <> 23.7 OR (v_dry->>'avg_before')::numeric <> 25
       OR (v_dry->>'shares_before')::numeric <> 10 OR (v_dry->>'settlement_change')::numeric <> 0
       OR jsonb_array_length(v_dry->'card_lines') < 4
       OR v_dry->'effective'->'lots'->1->>'date' <> (T - 30)::text THEN
        RAISE EXCEPTION 'FAIL [A1 Probelauf]: %', v_dry;
    END IF;
    IF (SELECT count(*) FROM finance.transactions WHERE holding_id = v_a) <> 1 THEN
        RAISE EXCEPTION 'FAIL [A1b Probelauf rollt zurueck]';
    END IF;
    RAISE NOTICE 'PASS [A1 Probelauf]';

    -- echter Write bekommt die aufgeloesten Daten der Karte (effective.lots), nicht die relativen
    v_res := finance.fn_replace_holding_lots(v_p || jsonb_build_object('lots', v_dry->'effective'->'lots'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'total_shares')::numeric <> 10
       OR (v_res->>'avg_purchase_price')::numeric <> 23.7 OR (v_res->>'settlement_change')::numeric <> 0
       OR (v_res->>'settlement_balance')::numeric <> v_bal OR finance.fn_get_balance(v_cash) <> v_bal
       OR (v_res->>'holding_id')::int <> v_a OR (v_res->>'group_id') IS NULL THEN
        RAISE EXCEPTION 'FAIL [A2 Erfolg]: %', v_res;
    END IF;
    v_grp := (v_res->>'group_id')::uuid;
    IF (SELECT count(*) FROM finance.transactions WHERE group_id = v_grp AND category::text = 'buy') <> 3
       OR (SELECT count(*) FROM finance.transactions WHERE group_id = v_grp AND category::text = 'position_takeover') <> 3
       OR (SELECT count(DISTINCT group_id) FROM finance.transactions WHERE holding_id = v_a) <> 1
       OR (SELECT count(*) FROM finance.transactions WHERE holding_id = v_a) <> 3
       OR (SELECT count(*) FROM finance.transaction_audit WHERE reason = 'replaced_by_lots' AND replaced_by_group = v_grp) <> 2
       OR (SELECT min(transaction_date) FROM finance.transactions WHERE holding_id = v_a) <> T - 60 THEN
        RAISE EXCEPTION 'FAIL [A3 eine group_id, alte Paare weg, Audit]';
    END IF;
    RAISE NOTICE 'PASS [A2-A3 Ersetzen]';

    -- Ersetzen einer schon ersetzten Position geht wieder (neue Gruppe ist ein reines Uebernahme-Paar-Set)
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'HLA', 'lots',
                 jsonb_build_array(jsonb_build_object('date', (T - 40)::text, 'shares', 10, 'price_per_share', 24))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'avg_purchase_price')::numeric <> 24
       OR (SELECT count(*) FROM finance.transactions WHERE holding_id = v_a) <> 1 THEN
        RAISE EXCEPTION 'FAIL [A4 erneut ersetzen]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [A4 erneut]';

    -- ---------- B: Stueckzahl aendert sich ----------
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'IE00HLOTB001', 'lots',
                 jsonb_build_array(jsonb_build_object('date', (T - 9)::text, 'shares', 1.5, 'price_per_share', 11),
                                   jsonb_build_object('date', (T - 8)::text, 'shares', 2.5, 'price_per_share', 12))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'shares_before')::numeric <> 5
       OR (v_res->>'total_shares')::numeric <> 4 OR (v_res->>'avg_before')::numeric <> 10
       OR (v_res->>'settlement_change')::numeric <> 0 THEN
        RAISE EXCEPTION 'FAIL [B Stueckzahl 5 -> 4]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [B Stueckzahl-Aenderung]';

    -- ---------- Ablehnungen: kein Write ----------
    SELECT count(*) INTO v_n FROM finance.transactions;
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'NOPE', 'lots',
                 jsonb_build_array(jsonb_build_object('date', (T - 9)::text, 'shares', 1, 'price_per_share', 1))));
    IF (v_res->>'ok')::boolean IS NOT DISTINCT FROM true OR v_res->>'code' <> 'holding_not_found' THEN
        RAISE EXCEPTION 'FAIL [R1 unbekannte Position]: %', v_res;
    END IF;
    FOR v_p IN SELECT x FROM (VALUES ('"__invalid_json__"'::jsonb), ('[]'::jsonb), ('{"a":1}'::jsonb), ('null'::jsonb)) AS t(x) LOOP
        v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'IE00HLOTE001', 'lots', v_p));
        IF (v_res->>'ok')::boolean IS NOT DISTINCT FROM true OR v_res->>'code' <> 'invalid_lots' THEN
            RAISE EXCEPTION 'FAIL [R2 lots ungueltig %]: %', v_p, v_res;
        END IF;
    END LOOP;
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'IE00HLOTE001', 'lots',
                 jsonb_build_array(jsonb_build_object('date', (T - 9)::text, 'shares', 10, 'price_per_share', 1),
                                   jsonb_build_object('date', (T - 9)::text, 'shares', 0, 'price_per_share', 1))));
    IF (v_res->>'ok')::boolean IS NOT DISTINCT FROM true OR (v_res->>'lot_no')::int <> 2 THEN
        RAISE EXCEPTION 'FAIL [R3 Lot 2 ungueltig, Stueck 0]: %', v_res;
    END IF;
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'IE00HLOTE001', 'lots',
                 jsonb_build_array(jsonb_build_object('date', (T - 9)::text, 'shares', 10, 'order_fee', 1))));
    IF (v_res->>'ok')::boolean IS NOT DISTINCT FROM true OR (v_res->>'lot_no')::int <> 1 THEN
        RAISE EXCEPTION 'FAIL [R3b weder Kurs noch Gesamtbetrag]: %', v_res;
    END IF;
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'IE00HLOTE001', 'lots',
                 jsonb_build_array(jsonb_build_object('date', (T - 9)::text, 'shares', 10, 'price_per_share', 2, 'cost_basis_total', 20))));
    IF (v_res->>'ok')::boolean IS NOT DISTINCT FROM true OR (v_res->>'lot_no')::int <> 1 THEN
        RAISE EXCEPTION 'FAIL [R3c Kurs UND Gesamtbetrag]: %', v_res;
    END IF;
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'IE00HLOTE001', 'lots',
                 jsonb_build_array(jsonb_build_object('date', 'irgendwann', 'shares', 10, 'price_per_share', 2))));
    IF (v_res->>'ok')::boolean IS NOT DISTINCT FROM true OR v_res->>'code' <> 'invalid_date' THEN
        RAISE EXCEPTION 'FAIL [R3d Datum unlesbar]: %', v_res;
    END IF;
    -- Lot nach dem Uebernahme-Tag (E: Uebernahme heute-5)
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'IE00HLOTE001', 'lots',
                 jsonb_build_array(jsonb_build_object('date', (T - 4)::text, 'shares', 10, 'price_per_share', 2))));
    IF (v_res->>'ok')::boolean IS NOT DISTINCT FROM true OR v_res->>'code' <> 'lot_after_takeover' THEN
        RAISE EXCEPTION 'FAIL [R4 Lot nach der Uebernahme]: %', v_res;
    END IF;
    -- E: spaeterer Verkauf von 8 -> Lots mit 5 Stueck unterschreiten ihn
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'IE00HLOTE001', 'lots',
                 jsonb_build_array(jsonb_build_object('date', (T - 9)::text, 'shares', 5, 'price_per_share', 2))));
    IF (v_res->>'ok')::boolean IS NOT DISTINCT FROM true OR v_res->>'code' <> 'oversell' THEN
        RAISE EXCEPTION 'FAIL [R5 Oversell]: %', v_res;
    END IF;
    -- C: keine Uebernahme vorhanden
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'IE00HLOTC001', 'lots',
                 jsonb_build_array(jsonb_build_object('date', (T - 9)::text, 'shares', 2, 'price_per_share', 10))));
    IF (v_res->>'ok')::boolean IS NOT DISTINCT FROM true OR v_res->>'code' <> 'no_takeover' THEN
        RAISE EXCEPTION 'FAIL [R6 keine Uebernahme]: %', v_res;
    END IF;
    -- D: Gruppe mit echtem Kauf ohne Gegenbuchung
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'IE00HLOTD001', 'lots',
                 jsonb_build_array(jsonb_build_object('date', (T - 9)::text, 'shares', 3, 'price_per_share', 10))));
    IF (v_res->>'ok')::boolean IS NOT DISTINCT FROM true OR v_res->>'code' <> 'not_takeover_only' THEN
        RAISE EXCEPTION 'FAIL [R7 nicht nur Uebernahme]: %', v_res;
    END IF;
    IF (SELECT count(*) FROM finance.transactions) <> v_n THEN
        RAISE EXCEPTION 'FAIL [R8 Ablehnungen duerfen nichts schreiben]';
    END IF;
    RAISE NOTICE 'PASS [R1-R8 Ablehnungen ohne Write]';

    -- ---------- E: gleiche Stueckzahl wie die Uebernahme -> Verkauf bleibt, Bestand 2 ----------
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'IE00HLOTE001', 'lots',
                 jsonb_build_array(jsonb_build_object('date', (T - 9)::text, 'shares', 6, 'price_per_share', 9),
                                   jsonb_build_object('date', (T - 7)::text, 'shares', 4, 'price_per_share', 11))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'total_shares')::numeric <> 2
       OR (SELECT count(*) FROM finance.transactions WHERE holding_id = v_e AND category::text = 'sell') <> 1 THEN
        RAISE EXCEPTION 'FAIL [E spaeterer Verkauf bleibt]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [E Verkauf bleibt]';

    -- ---------- F: spaeterer echter Kauf bleibt unberuehrt, Saldo unveraendert ----------
    v_bal := finance.fn_get_balance(v_cash);
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'IE00HLOTF001', 'lots',
                 jsonb_build_array(jsonb_build_object('date', (T - 12)::text, 'shares', 5, 'price_per_share', 9),
                                   jsonb_build_object('date', (T - 7)::text, 'shares', 5, 'price_per_share', 11))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'total_shares')::numeric <> 12
       OR (v_res->>'shares_before')::numeric <> 12 OR finance.fn_get_balance(v_cash) <> v_bal
       OR (SELECT count(*) FROM finance.transactions WHERE holding_id = v_f AND group_id IS NULL AND category::text = 'buy') <> 1 THEN
        RAISE EXCEPTION 'FAIL [F Folgekauf bleibt]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [F Folgekauf bleibt]';

    -- ---------- G: Import-Tranchen (eine Gruppe, zwei Paare) werden komplett ersetzt ----------
    v_bal := finance.fn_get_balance(v_cash);
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hl_depot__', 'position', 'HLG', 'lots',
                 jsonb_build_array(jsonb_build_object('date', (T - 30)::text, 'shares', 1, 'price_per_share', 10),
                                   jsonb_build_object('date', (T - 20)::text, 'shares', 2, 'price_per_share', 11),
                                   jsonb_build_object('date', (T - 10)::text, 'shares', 2, 'price_per_share', 12))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'shares_before')::numeric <> 5
       OR (v_res->>'total_shares')::numeric <> 5 OR finance.fn_get_balance(v_cash) <> v_bal
       OR (SELECT count(*) FROM finance.transactions WHERE holding_id = v_g) <> 3
       OR (SELECT count(DISTINCT group_id) FROM finance.transactions WHERE holding_id = v_g) <> 1 THEN
        RAISE EXCEPTION 'FAIL [G Tranchen-Gruppe]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [G Tranchen]';

    -- Void der neuen Gruppe entfernt sie komplett (ein Write = ein Void)
    v_res := finance.fn_void_transaction(jsonb_build_object('transaction_id',
                 (SELECT min(id) FROM finance.transactions WHERE holding_id = v_g)));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'deleted_count')::int <> 6 THEN
        RAISE EXCEPTION 'FAIL [V Void der Gruppe]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [V Void]';
END $$;

-- ---------- W: Grenzen ----------
--   W1 Lot am Uebernahme-Tag + spaeterer Verkauf aller Stuecke (Bestand danach genau 0) -> gueltig
--   W2 Lot mit Kurswert unter einem Cent -> lot_invalid
--   W3 Uebernahme-Gruppe, deren Betraege sich nicht aufheben -> keine reine Uebernahme, Ablehnung
DO $$
DECLARE
    T       DATE := core.fn_today();
    v_cash  INT; v_depot INT; v_h INT; v_res JSONB; v_old UUID;
BEGIN
    v_cash := (finance.fn_create_account(jsonb_build_object('name', '__t_hlw_cash__', 'account_type', 'cash', 'currency', 'EUR',
                   'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    v_depot := (finance.fn_create_account(jsonb_build_object('name', '__t_hlw_depot__', 'account_type', 'stocks_depot',
                    'currency', 'EUR', 'settlement_id', v_cash))->>'account_id')::int;

    -- W1
    v_h := (finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_cash, 'isin', 'IE00HLOTW001',
              'symbol', 'HLW1', 'name', 'HL W1 ETF', 'shares', 10, 'price_per_share', 10, 'order_fee', 0,
              'transaction_date', (T - 5)::text, 'existing_position', true))->>'holding_id')::int;
    PERFORM finance.fn_book_stock_sell(jsonb_build_object('price_currency_confirmed',true,'settlement_id', v_cash, 'holding_id', v_h, 'shares', 10,
              'price_per_share', 11, 'order_fee', 0, 'transaction_date', (T - 1)::text, 'symbol', 'HLW1'));
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hlw_depot__', 'position', 'IE00HLOTW001',
              'lots', jsonb_build_array(jsonb_build_object('date', (T - 5)::text, 'shares', 6, 'price_per_share', 9),
                                        jsonb_build_object('date', (T - 40)::text, 'shares', 4, 'price_per_share', 11))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL [W1 Lot am Uebernahme-Tag, Bestand danach 0]: %', v_res; END IF;

    -- W2
    v_h := (finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_cash, 'isin', 'IE00HLOTW002',
              'symbol', 'HLW2', 'name', 'HL W2 ETF', 'shares', 10, 'price_per_share', 10, 'order_fee', 0,
              'transaction_date', (T - 5)::text, 'existing_position', true))->>'holding_id')::int;
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hlw_depot__', 'position', 'IE00HLOTW002',
              'lots', jsonb_build_array(jsonb_build_object('date', (T - 30)::text, 'shares', 1, 'price_per_share', 0.001))));
    IF v_res->>'code' IS DISTINCT FROM 'lot_invalid' THEN RAISE EXCEPTION 'FAIL [W2 Kurswert unter 1 Cent]: %', v_res; END IF;

    -- W3
    v_h := (finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_cash, 'isin', 'IE00HLOTW003',
              'symbol', 'HLW3', 'name', 'HL W3 ETF', 'shares', 5, 'price_per_share', 10, 'order_fee', 0,
              'transaction_date', (T - 5)::text, 'existing_position', true))->>'holding_id')::int;
    SELECT group_id INTO v_old FROM finance.transactions WHERE holding_id = v_h AND category::text = 'buy';
    UPDATE finance.transactions SET amount = amount + 1 WHERE group_id = v_old AND category::text = 'position_takeover';
    v_res := finance.fn_replace_holding_lots(jsonb_build_object('depot_name', '__t_hlw_depot__', 'position', 'IE00HLOTW003',
              'lots', jsonb_build_array(jsonb_build_object('date', (T - 30)::text, 'shares', 5, 'price_per_share', 10))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL [W3 Gruppe hebt sich nicht auf]: %', v_res; END IF;
    RAISE NOTICE 'PASS [W Grenzen: Uebernahme-Tag, Bestand 0, Cent-Grenze, unreine Gruppe]';
END $$;
ROLLBACK;
