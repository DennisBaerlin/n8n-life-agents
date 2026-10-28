-- ============================================================
-- fn_replace_takeover_with_lots (ATOMIC WRITE) -- Bestandsuebernahme durch die echten Einzelkaeufe ersetzen (Paket B)
--   Live-Befund 2026-10-28: eine Position wurde als EINE Uebernahme erfasst, der Broker-Export kennt die Einzelkaeufe.
--   Eingabe jsonb: account_name (Verrechnungskonto = das Cashkonto des Exports), csv:{header, rows} (Tokenizer-Ausgabe).
--   Je Position eines Depots mit diesem Verrechnungskonto, die GENAU EIN Uebernahme-Paar hat (eine group_id mit einem
--   Kauf + einer position_takeover-Gegenbuchung) und im Export Kaeufe bis zum Uebernahme-Datum:
--     Lots = Export-Kaeufe minus -Verkaeufe (FIFO) seit dem letzten Bestand 0, bis einschliesslich Uebernahme-Datum;
--     Export-Zeilen, die schon als eigene Buchung der Position existieren (gleiche Art + Stueck, +-5 Tage), zaehlen nicht.
--     Summe der Lot-Stueck = Uebernahme-Stueck EXAKT (8 Stellen) -> ersetzen; sonst mismatched (code lots_mismatch,
--     difference = Uebernahme - Export), nichts an dieser Position geaendert.
--   Ersetzen: alle Lots in EINER neuen group_id ueber fn_book_takeover_pair (ein Write = eine group_id = ein Void).
--     Lot-Datum <= bestaetigter Kontostand-Tag des Verrechnungskontos (GREATEST(last_reconciled_at,
--     opening_balance_date); keiner gesetzt = alle) -> cash-neutrales Uebernahme-Paar (der Stand enthaelt den Kauf schon);
--     spaeter -> echter Kauf (Cash-Abfluss, der Stand enthaelt ihn noch nicht; Leitungs-Entscheid 2026-10-28) -- der
--     Monats-Check erkennt ihn danach in Stufe 0 als schon gebucht, ein Kauf bis zum Uebernahme-Datum wird dort nie
--     gebucht (covered_by_takeover) -> nie doppelt.
--     Danach das alte Paar ueber fn_void_transaction (Audit, Oversell-/Reserve-Guards) -> transaction_audit.reason =
--     'replaced_by_lots', replaced_by_group = neue group_id. Spaetere Kaeufe (nach dem Uebernahme-Datum) bleiben unberuehrt.
--   Stueckpreis je Lot aus dem Kurswert (fn_unit_price_from_total), bei FIFO-Rest anteilige Gebuehr.
--   Probelauf vor der Karte: core.fn_dry_run (Karte = Zahlen des echten Writes).
--   RUECKGABE: {ok:true, replaced:[{holding_id, name, lots_count, shares, avg_purchase_price, avg_before,
--   cash_lots_count}], mismatched:[{holding_id, name, code:'lots_mismatch', takeover_shares, export_shares, difference}],
--   settlement_balance, settlement_change (Saldo nachher - vorher, DB-Delta), card_lines}
--   | {ok:false, code (csv_profile_unknown|csv_invalid|account_unknown|account_ambiguous|not_bookable), reason}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_replace_takeover_with_lots(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_norm     JSONB;
    v_res      RECORD;
    v_acct     finance.accounts%ROWTYPE;
    v_reason   TEXT;
    v_cut      DATE;
    v_before   NUMERIC;
    v_h        RECORD;
    v_rows     JSONB;
    v_row      JSONB;
    v_lots     JSONB;
    v_rest     NUMERIC;
    v_take     NUMERIC;
    v_lot      JSONB;
    v_i        INT;
    v_sum      NUMERIC;
    v_group    UUID;
    v_r        JSONB;
    v_cash_n   INT;
    v_avg_old  NUMERIC;
    v_void     JSONB;
    v_replaced JSONB := '[]'::jsonb;
    v_mism     JSONB := '[]'::jsonb;
    v_after    NUMERIC;
    v_card     JSONB := '[]'::jsonb;
BEGIN
    v_norm := finance.fn_broker_csv_normalize(COALESCE(p->'csv', '{}'::jsonb));
    IF (v_norm->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_norm;
    END IF;
    SELECT * INTO v_res FROM finance.fn_resolve_account(NULLIF(trim(p->>'account_name'), ''), NULL, TRUE);
    IF v_res.hit_count IS DISTINCT FROM 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', CASE WHEN v_res.hit_count > 1 THEN 'account_ambiguous' ELSE 'account_unknown' END,
            'reason', 'No unique active account named "' || COALESCE(trim(p->>'account_name'), '') || '".',
            'candidates', COALESCE(v_res.candidates, '[]'::jsonb));
    END IF;
    SELECT * INTO v_acct FROM finance.accounts WHERE id = v_res.id;
    v_reason := finance.fn_bookable_account_reason(v_acct.id);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_bookable', 'reason', v_reason);
    END IF;
    v_cut := GREATEST(v_acct.last_reconciled_at, v_acct.opening_balance_date);
    PERFORM 1 FROM finance.account_balances WHERE account_id = v_acct.id FOR UPDATE;
    v_before := finance.fn_get_balance(v_acct.id);

    FOR v_h IN
        SELECT h.id, h.name, h.symbol, upper(h.isin) AS isin, h.average_purchase_price AS avg_before,
               t.id AS buy_id, t.shares AS take_shares, t.transaction_date AS take_date, t.group_id
        FROM finance.depot_holdings h
        JOIN finance.accounts d ON d.id = h.account_id AND d.settlement_account_id = v_acct.id
        JOIN finance.transactions t ON t.holding_id = h.id AND t.category::text = 'buy' AND t.group_id IS NOT NULL
        WHERE EXISTS (SELECT 1 FROM finance.transactions g WHERE g.group_id = t.group_id AND g.category::text = 'position_takeover')
          AND (SELECT count(*) FROM finance.transactions g WHERE g.group_id = t.group_id) = 2
          AND (SELECT count(DISTINCT x.group_id) FROM finance.transactions x
               WHERE x.holding_id = h.id AND x.category::text = 'buy'
                 AND EXISTS (SELECT 1 FROM finance.transactions g WHERE g.group_id = x.group_id AND g.category::text = 'position_takeover')) = 1
        ORDER BY h.id
    LOOP
        -- Export-Zeilen der Position bis zum Uebernahme-Datum, die nicht schon als eigene Buchung existieren
        SELECT COALESCE(jsonb_agg(r ORDER BY (r->>'date')::date, (r->>'kind' = 'sell'), (r->>'row_no')::int), '[]'::jsonb)
        INTO v_rows
        FROM jsonb_array_elements(v_norm->'rows') r
        WHERE r->>'kind' IN ('buy', 'sell') AND (r->>'date')::date <= v_h.take_date
          AND (upper(r->>'isin') = v_h.isin OR (r->>'isin' IS NULL AND v_h.isin IS NULL AND upper(r->>'symbol') = upper(v_h.symbol)))
          AND NOT EXISTS (SELECT 1 FROM finance.transactions t
                          WHERE t.holding_id = v_h.id AND t.category::text = r->>'kind'
                            AND (t.group_id IS DISTINCT FROM v_h.group_id)
                            AND abs(t.shares) = (r->>'shares')::numeric
                            AND abs(t.transaction_date - (r->>'date')::date) <= 5);
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'buy');

        -- FIFO; ein Bestand 0 setzt neu an (fruehere Kaeufe sind vollstaendig verkauft)
        v_lots := '[]'::jsonb;
        FOR v_row IN SELECT e FROM jsonb_array_elements(v_rows) e LOOP
            IF v_row->>'kind' = 'buy' THEN
                v_lots := v_lots || jsonb_build_object('date', v_row->>'date', 'shares', (v_row->>'shares')::numeric,
                    'orig', (v_row->>'shares')::numeric, 'gross', (v_row->>'gross')::numeric, 'fee', (v_row->>'fee')::numeric);
            ELSE
                v_rest := (v_row->>'shares')::numeric;
                v_i := 0;
                WHILE v_rest > 0 AND v_i < jsonb_array_length(v_lots) LOOP
                    v_take := LEAST(v_rest, (v_lots->v_i->>'shares')::numeric);
                    v_lots := jsonb_set(v_lots, ARRAY[v_i::text, 'shares'], to_jsonb((v_lots->v_i->>'shares')::numeric - v_take));
                    v_rest := v_rest - v_take;
                    v_i := v_i + 1;
                END LOOP;
                SELECT COALESCE(jsonb_agg(l), '[]'::jsonb) INTO v_lots FROM jsonb_array_elements(v_lots) l
                WHERE (l->>'shares')::numeric > 0;
            END IF;
        END LOOP;
        SELECT COALESCE(sum((l->>'shares')::numeric), 0) INTO v_sum FROM jsonb_array_elements(v_lots) l;

        IF v_sum <> v_h.take_shares THEN
            v_mism := v_mism || jsonb_build_object('holding_id', v_h.id, 'name', v_h.name, 'code', 'lots_mismatch',
                'takeover_shares', v_h.take_shares, 'export_shares', v_sum, 'difference', v_h.take_shares - v_sum);
            CONTINUE;
        END IF;

        v_group := gen_random_uuid();
        v_cash_n := 0;
        FOR v_lot IN SELECT e FROM jsonb_array_elements(v_lots) e LOOP
            v_r := finance.fn_book_takeover_pair(v_h.id, v_acct.id, (v_lot->>'shares')::numeric,
                       finance.fn_unit_price_from_total((v_lot->>'gross')::numeric, (v_lot->>'orig')::numeric),
                       round((v_lot->>'fee')::numeric * (v_lot->>'shares')::numeric / (v_lot->>'orig')::numeric, 2),
                       (v_lot->>'date')::date, v_group, v_h.symbol,
                       v_cut IS NULL OR (v_lot->>'date')::date <= v_cut);
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION 'fn_replace_takeover_with_lots: lot of % refused: %', v_h.name, v_r->>'reason';
            END IF;
            IF v_cut IS NOT NULL AND (v_lot->>'date')::date > v_cut THEN v_cash_n := v_cash_n + 1; END IF;
        END LOOP;

        v_void := finance.fn_void_transaction(jsonb_build_object('transaction_id', v_h.buy_id));
        IF (v_void->>'ok')::boolean IS DISTINCT FROM true THEN
            RAISE EXCEPTION 'fn_replace_takeover_with_lots: old takeover of % could not be removed: %', v_h.name, v_void->>'reason';
        END IF;
        UPDATE finance.transaction_audit a SET reason = 'replaced_by_lots', replaced_by_group = v_group
        WHERE a.transaction_id IN (SELECT (x)::int FROM jsonb_array_elements_text(v_void->'transaction_ids') x)
          AND a.reason IS NULL
          AND a.id IN (SELECT max(b.id) FROM finance.transaction_audit b
                       WHERE b.transaction_id IN (SELECT (x)::int FROM jsonb_array_elements_text(v_void->'transaction_ids') x)
                       GROUP BY b.transaction_id);

        SELECT jsonb_build_object('holding_id', h.id, 'name', h.name, 'lots_count', jsonb_array_length(v_lots),
                   'cash_lots_count', v_cash_n, 'shares', h.shares, 'avg_purchase_price', h.average_purchase_price,
                   'avg_before', v_h.avg_before)
        INTO v_r FROM finance.depot_holdings h WHERE h.id = v_h.id;
        v_replaced := v_replaced || v_r;
    END LOOP;

    v_after := finance.fn_get_balance(v_acct.id);

    -- Karte: je Position N Einzelkaeufe statt einer Uebernahme (Stueck gleich, Einstand alt -> neu); echte Wirkung aufs
    -- Verrechnungskonto aus der DB (Kaeufe nach dem bestaetigten Tag), Abweichungen als Hinweis.
    SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
               core.fn_ui_tpl('finance.tpl.lots_replaced_row', jsonb_build_object('name', r->>'name',
                   'count', (r->>'lots_count')::int,
                   'shares', core.fn_ui_num((r->>'shares')::numeric, 8),
                   'avg_before', core.fn_ui_money((r->>'avg_before')::numeric, v_acct.currency),
                   'avg', core.fn_ui_money((r->>'avg_purchase_price')::numeric, v_acct.currency)))) ORDER BY (r->>'holding_id')::int), '[]'::jsonb)
    INTO v_card FROM jsonb_array_elements(v_replaced) r;
    IF jsonb_array_length(v_replaced) > 0 THEN
        v_card := v_card || jsonb_build_array(
            core.fn_ui_money(v_after - v_before, v_acct.currency, true) || jsonb_build_object('label', 'finance.label.lots_settlement_change'));
        IF v_after <> v_before THEN
            v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'finance.note.lots_cash_after_cut',
                'params', jsonb_build_object('date', core.fn_ui_date(v_cut), 'account', v_acct.name)));
        END IF;
    END IF;
    IF jsonb_array_length(v_mism) > 0 THEN
        v_card := v_card || (SELECT jsonb_agg(jsonb_build_object('kind', 'note', 'value', 'finance.note.lots_mismatch',
                      'params', jsonb_build_object('name', m->>'name',
                          'difference', core.fn_ui_num((m->>'difference')::numeric, 8)))) FROM jsonb_array_elements(v_mism) m);
    END IF;

    RETURN jsonb_build_object('ok', true, 'replaced', v_replaced, 'mismatched', v_mism,
        'settlement_balance', v_after, 'settlement_change', v_after - v_before, 'card_lines', v_card);
END;
$$;
