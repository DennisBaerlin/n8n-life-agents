-- ============================================================
-- fn_replace_takeover_with_lots (ATOMIC WRITE) -- Bestandsuebernahme durch die echten Einzelkaeufe ersetzen (Paket B)
--   Live-Befund 2026-10-28: eine Position wurde als EINE Uebernahme erfasst, der Broker-Export kennt die Einzelkaeufe.
--   Eingabe jsonb: account_name (opt; Verrechnungskonto = das Cashkonto des Exports), table:{rows} (Raster des Lesers),
--   fingerprint (opt, aus dem Probelauf). Konto ueber fn_bank_export_resolve_account (derselbe Konto-Waechter wie der
--   Monats-Check: export_account_mismatch, ohne Namen Vorauswahl nach Bank-Profil).
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
--   Probelauf vor der Karte: core.fn_dry_run (Karte = Zahlen des echten Writes) liefert fingerprint; der echte Write nach
--   dem Tipp bekommt ihn mit und bucht nur bei gleichem Plan (sonst stale_preview, kein Write; Muster fn_apply_bank_statement).
--   Eine Gruppe aus einer frueheren Ersetzung (transaction_audit.replaced_by_group) ist nie wieder Kandidat.
--   Ein nicht buchbares Lot (fn_trade_amount_reason, z. B. FIFO-Rest unter 1 Cent) -> mismatched code lots_not_bookable.
--   RUECKGABE: {ok:true, account_id, account_name, replaced:[{holding_id, name, lots_count, shares, avg_purchase_price, avg_before,
--   cash_lots_count}], mismatched:[{holding_id, name, code:'lots_mismatch'|'lots_not_bookable', takeover_shares, export_shares, difference, reason?}],
--   settlement_balance, settlement_change (Saldo nachher - vorher, DB-Delta), card_lines, fingerprint}
--   | {ok:false, code (export_profile_unknown|export_invalid|account_unknown|account_ambiguous|not_bookable|
--   export_account_mismatch|stale_preview), reason}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_replace_takeover_with_lots(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_norm     JSONB;
    v_res      JSONB;
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
    v_plan     JSONB := '[]'::jsonb;
    v_pl       JSONB;
    v_fp       TEXT;
BEGIN
    v_norm := finance.fn_bank_export_normalize(COALESCE(p->'table', '{}'::jsonb));
    IF (v_norm->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_norm;
    END IF;
    -- derselbe Konto-Waechter wie der Monats-Check (eine Adresse; buchbar prueft er mit)
    v_res := finance.fn_bank_export_resolve_account(p->>'account_name', v_norm->>'profile', v_norm->'currencies');
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_res;
    END IF;
    SELECT * INTO v_acct FROM finance.accounts WHERE id = (v_res->>'account_id')::int;
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
          -- eine Gruppe aus einer frueheren Ersetzung ist keine Uebernahme mehr (sonst kaeme dieselbe Karte jeden Monat)
          AND NOT EXISTS (SELECT 1 FROM finance.transaction_audit a WHERE a.replaced_by_group = t.group_id)
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

        -- Plan je Lot (Kurs aus dem Kurswert, anteilige Gebuehr, Cash ja/nein); ein nicht buchbares Lot (z. B. FIFO-Rest
        -- unter 1 Cent) -> lots_not_bookable als DATEN, die Position bleibt unveraendert (nie RAISE im Probelauf)
        SELECT jsonb_agg(jsonb_build_object('date', l->>'date', 'shares', (l->>'shares')::numeric,
                   'price', finance.fn_unit_price_from_total((l->>'gross')::numeric, (l->>'orig')::numeric),
                   'fee', round((l->>'fee')::numeric * (l->>'shares')::numeric / (l->>'orig')::numeric, 2),
                   'cash', v_cut IS NOT NULL AND (l->>'date')::date > v_cut) ORDER BY o)
        INTO v_lots FROM jsonb_array_elements(v_lots) WITH ORDINALITY AS x(l, o);
        SELECT string_agg(COALESCE(finance.fn_trade_amount_reason((l->>'shares')::numeric,
                              (l->>'shares')::numeric * (l->>'price')::numeric + (l->>'fee')::numeric),
                          CASE WHEN COALESCE((l->>'price')::numeric, 0) <= 0 THEN 'price missing' END), '; ')
        INTO v_reason FROM jsonb_array_elements(v_lots) l;
        IF v_reason IS NOT NULL THEN
            v_mism := v_mism || jsonb_build_object('holding_id', v_h.id, 'name', v_h.name, 'code', 'lots_not_bookable',
                'reason', v_reason, 'takeover_shares', v_h.take_shares, 'export_shares', v_sum, 'difference', 0);
            v_reason := NULL;
            CONTINUE;
        END IF;
        v_plan := v_plan || jsonb_build_object('holding_id', v_h.id, 'name', v_h.name, 'symbol', v_h.symbol,
            'buy_id', v_h.buy_id, 'avg_before', v_h.avg_before, 'lots', v_lots);
    END LOOP;

    -- Plan/Apply wie der Monats-Check: der echte Write nach dem Tipp bucht nur, wenn derselbe Plan herauskommt
    v_fp := md5(jsonb_build_object('a', v_acct.id, 'c', v_cut, 'p', v_plan)::text);
    IF NULLIF(p->>'fingerprint', '') IS NOT NULL AND p->>'fingerprint' <> v_fp THEN
        RETURN jsonb_build_object('ok', false, 'code', 'stale_preview',
            'reason', 'Something changed since the card was shown - send the export again for a new card.');
    END IF;

    FOR v_pl IN SELECT e FROM jsonb_array_elements(v_plan) e LOOP
        v_group := gen_random_uuid();
        v_cash_n := 0;
        FOR v_lot IN SELECT e FROM jsonb_array_elements(v_pl->'lots') e LOOP
            v_r := finance.fn_book_takeover_pair((v_pl->>'holding_id')::int, v_acct.id, (v_lot->>'shares')::numeric,
                       (v_lot->>'price')::numeric, (v_lot->>'fee')::numeric, (v_lot->>'date')::date, v_group,
                       v_pl->>'symbol', NOT (v_lot->>'cash')::boolean);
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN   -- vorab geprueft: echte Ausnahme
                RAISE EXCEPTION 'fn_replace_takeover_with_lots: lot of % refused: %', v_pl->>'name', v_r->>'reason';
            END IF;
            IF (v_lot->>'cash')::boolean THEN v_cash_n := v_cash_n + 1; END IF;
        END LOOP;

        v_void := finance.fn_void_transaction(jsonb_build_object('transaction_id', (v_pl->>'buy_id')::int));
        IF (v_void->>'ok')::boolean IS DISTINCT FROM true THEN
            RAISE EXCEPTION 'fn_replace_takeover_with_lots: old takeover of % could not be removed: %', v_pl->>'name', v_void->>'reason';
        END IF;
        UPDATE finance.transaction_audit a SET reason = 'replaced_by_lots', replaced_by_group = v_group
        WHERE a.transaction_id IN (SELECT (x)::int FROM jsonb_array_elements_text(v_void->'transaction_ids') x)
          AND a.reason IS NULL
          AND a.id IN (SELECT max(b.id) FROM finance.transaction_audit b
                       WHERE b.transaction_id IN (SELECT (x)::int FROM jsonb_array_elements_text(v_void->'transaction_ids') x)
                       GROUP BY b.transaction_id);

        SELECT jsonb_build_object('holding_id', h.id, 'name', h.name, 'lots_count', jsonb_array_length(v_pl->'lots'),
                   'cash_lots_count', v_cash_n, 'shares', h.shares, 'avg_purchase_price', h.average_purchase_price,
                   'avg_before', (v_pl->>'avg_before')::numeric)
        INTO v_r FROM finance.depot_holdings h WHERE h.id = (v_pl->>'holding_id')::int;
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
        v_card := v_card || (SELECT jsonb_agg(CASE WHEN m->>'code' = 'lots_not_bookable'
                      THEN jsonb_build_object('kind', 'note', 'value', 'finance.note.lots_not_bookable',
                               'params', jsonb_build_object('name', m->>'name'))
                      ELSE jsonb_build_object('kind', 'note', 'value', 'finance.note.lots_mismatch',
                               'params', jsonb_build_object('name', m->>'name',
                                   'difference', core.fn_ui_num((m->>'difference')::numeric, 8))) END)
                  FROM jsonb_array_elements(v_mism) m);
    END IF;

    RETURN jsonb_build_object('ok', true, 'account_id', v_acct.id, 'account_name', v_acct.name,
        'replaced', v_replaced, 'mismatched', v_mism,
        'settlement_balance', v_after, 'settlement_change', v_after - v_before, 'card_lines', v_card,
        'fingerprint', v_fp);
END;
$$;
