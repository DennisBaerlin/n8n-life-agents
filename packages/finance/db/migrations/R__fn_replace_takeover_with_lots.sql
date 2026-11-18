-- ============================================================
-- fn_replace_takeover_with_lots (ATOMIC WRITE) -- Bestandsuebernahme durch die echten Einzelkaeufe ersetzen
--   Eine Position ist als eine Uebernahme erfasst, der Broker-Export kennt die Einzelkaeufe.
--   Eingabe jsonb: account_name (opt; Verrechnungskonto = das Cashkonto des Exports), table:{rows} (Raster des Lesers),
--   fingerprint (opt, aus dem Probelauf). Datei + Konto ueber fn_bank_export_load (Leser, derselbe Konto-Waechter wie der
--   Monats-Check: export_account_mismatch, ohne Namen Vorauswahl nach Bank-Profil; mehrere Sub-Konten -> multiple_sub_accounts).
--   Je Position eines Depots mit diesem Verrechnungskonto, die genau ein Uebernahme-Paar hat (eine group_id mit einem
--   Kauf + einer position_takeover-Gegenbuchung) und im Export Kaeufe bis zum Uebernahme-Datum:
--     Lots = Export-Kaeufe minus -Verkaeufe (FIFO) seit dem letzten Bestand 0, bis einschliesslich Uebernahme-Datum;
--     Export-Zeilen, die schon als eigene Buchung der Position existieren (gleiche Art + Stueck, +-5 Tage), zaehlen nicht.
--     Summe der Lot-Stueck = Uebernahme-Stueck exakt (8 Stellen) -> ersetzen; sonst mismatched (code lots_mismatch,
--     difference = Uebernahme - Export), nichts an dieser Position geaendert. Ausnahme Kauf am Uebernahme-Tag: stimmen die
--     Zeilen VOR dem Tag exakt und gibt es am Tag nur Kaeufe, enthielt die Uebernahme sie noch nicht (Broker zeigt den Kauf
--     erst nach der Abwicklung) -> sie kommen als Lots dazu (same_day_shares, Bestand waechst), sonst blieben sie ungebucht.
--   Ersetzen: alle Lots in einer neuen group_id ueber fn_replace_takeover_apply (fn_book_takeover_pair; ein Write = eine group_id = ein Void).
--     Lot-Datum <= bestaetigter Kontostand-Tag des Verrechnungskontos (GREATEST(last_reconciled_at,
--     opening_balance_date); keiner gesetzt = alle) -> cash-neutrales Uebernahme-Paar (der Stand enthaelt den Kauf schon);
--     spaeter -> echter Kauf (Cash-Abfluss, der Stand enthaelt ihn noch nicht) -- der
--     Monats-Check erkennt ihn danach in Stufe 0 als schon gebucht, ein Kauf bis zum Uebernahme-Datum wird dort nie
--     gebucht (covered_by_takeover) -> nie doppelt.
--     Danach das alte Paar ueber fn_void_transaction (Audit, Oversell-/Reserve-Guards) -> transaction_audit.reason =
--     'replaced_by_lots', replaced_by_group = neue group_id. Spaetere Kaeufe (nach dem Uebernahme-Datum) bleiben unberuehrt.
--   Stueckpreis je Lot aus dem Kurswert (fn_unit_price_from_total), bei FIFO-Rest anteilige Gebuehr.
--   Probelauf vor der Karte: core.fn_dry_run (Karte = Zahlen des echten Writes) liefert fingerprint; der echte Write nach
--   dem Tipp bekommt ihn mit und bucht nur bei gleichem Plan (sonst stale_preview, kein Write; Muster fn_apply_bank_statement).
--   Eine Gruppe aus einer frueheren Ersetzung (transaction_audit.replaced_by_group) ist nie wieder Kandidat.
--   Ein nicht buchbares Lot (fn_trade_amount_reason, z. B. FIFO-Rest unter 1 Cent) -> mismatched code lots_not_bookable.
--   Eine Zeile der Position bis zum Uebernahme-Datum in anderer Waehrung als das Verrechnungskonto -> mismatched code
--   currency_mismatch (ihr Kurswert waere ein falscher Einstand).
--   Rundungs-Staub (Zeilen-Summe weicht um <= 1e-8 je Lot ab) geht auf das letzte cash-neutrale Lot (fn_takeover_dust_lot).
--   Rueckgabe: {ok:true, account_id, account_name, replaced:[{holding_id, name, lots_count, shares, avg_purchase_price, avg_before,
--   cash_lots_count, same_day_shares (0 = keiner), take_date}], mismatched:[{holding_id, name, code:'lots_mismatch'|'lots_not_bookable'|'currency_mismatch', takeover_shares, export_shares, difference, reason?}],
--   settlement_balance, settlement_change (Saldo nachher - vorher, DB-Delta), card_lines, fingerprint}
--   | {ok:false, code (export_profile_unknown|export_invalid|account_unknown|account_ambiguous|not_bookable|
--   export_account_mismatch|multiple_sub_accounts|stale_preview), reason}.
-- ============================================================

-- Hilfs-fn: Index des Lots, das den Rundungs-Staub traegt. Nur Lots mit Datum < p_before; davon das letzte
-- cash-neutrale (Datum <= p_cut, ohne Stichtag alle), sonst das letzte; keins davor -> letztes Lot ueberhaupt.
CREATE OR REPLACE FUNCTION finance.fn_takeover_dust_lot(p_lots jsonb, p_cut date, p_before date)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE((SELECT (o - 1)::int FROM jsonb_array_elements(p_lots) WITH ORDINALITY AS x(l, o)
                     WHERE (l->>'date')::date < p_before
                     ORDER BY (p_cut IS NULL OR (l->>'date')::date <= p_cut) DESC, o DESC LIMIT 1),
                    jsonb_array_length(p_lots) - 1);
$$;

CREATE OR REPLACE FUNCTION finance.fn_replace_takeover_with_lots(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_norm     JSONB;
    v_acct     finance.accounts%ROWTYPE;
    v_reason   TEXT;
    v_cut      DATE;
    v_before   NUMERIC;
    v_h        RECORD;
    v_rows     JSONB;
    v_lots     JSONB;
    v_sum      NUMERIC;
    v_r        JSONB;
    v_cash_n   INT;
    v_avg_old  NUMERIC;
    v_replaced JSONB := '[]'::jsonb;
    v_mism     JSONB := '[]'::jsonb;
    v_after    NUMERIC;
    v_card     JSONB := '[]'::jsonb;
    v_plan     JSONB := '[]'::jsonb;
    v_pl       JSONB;
    v_fp       TEXT;
    v_same     NUMERIC;
    v_sum_b    NUMERIC;
    v_n_b      INT;
    v_ix       INT;
BEGIN
    -- die geteilte Lade-Sequenz (Leser + derselbe Konto-Waechter wie der Monats-Check, buchbar prueft er mit)
    v_norm := finance.fn_bank_export_load(p);
    IF (v_norm->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_norm;
    END IF;
    SELECT * INTO v_acct FROM finance.accounts WHERE id = (v_norm->>'account_id')::int;
    v_cut := GREATEST(v_acct.last_reconciled_at, v_acct.opening_balance_date);
    PERFORM 1 FROM finance.account_balances WHERE account_id = v_acct.id FOR UPDATE;
    v_before := finance.fn_get_balance(v_acct.id);

    FOR v_h IN
        SELECT h.id, h.name, h.symbol, upper(h.isin) AS isin, h.average_purchase_price AS avg_before,
               t.id AS buy_id, t.shares AS take_shares, t.transaction_date AS take_date, t.group_id
        FROM finance.depot_holdings h
        JOIN finance.accounts d ON d.id = h.account_id AND d.settlement_account_id = v_acct.id
        JOIN finance.transactions t ON t.holding_id = h.id AND t.category::text = 'buy' AND t.group_id IS NOT NULL
        WHERE t.cost_origin IS NULL AND EXISTS (SELECT 1 FROM finance.transactions g WHERE g.group_id = t.group_id AND g.category::text = 'position_takeover')
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
        -- Eine Zeile in anderer Waehrung als das Verrechnungskonto: ihr Kurswert waere still ein falscher Einstand
        -- (der Konto-Waechter nimmt gemischte Dateien an) -> nie ersetzen.
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_norm->'rows') r
                   WHERE r->>'kind' IN ('buy', 'sell') AND (r->>'date')::date <= v_h.take_date
                     AND (upper(r->>'isin') = v_h.isin OR (r->>'isin' IS NULL AND v_h.isin IS NULL AND upper(r->>'symbol') = upper(v_h.symbol)))
                     AND upper(COALESCE(r->>'currency', v_acct.currency)) <> v_acct.currency) THEN
            v_mism := v_mism || jsonb_build_object('holding_id', v_h.id, 'name', v_h.name, 'code', 'currency_mismatch',
                'takeover_shares', v_h.take_shares, 'export_shares', NULL, 'difference', 0);
            CONTINUE;
        END IF;

        -- FIFO: die eine Adresse (fn_import_fifo_lots), ein Bestand 0 setzt neu an
        v_lots := finance.fn_import_fifo_lots(v_rows)->'lots';
        SELECT COALESCE(sum((l->>'shares')::numeric), 0) INTO v_sum FROM jsonb_array_elements(v_lots) l;

        -- Exporte liefern mehr Stellen als gespeichert: Rundungs-Staub der Zeilen ist kein Unterschied. Er landet auf
        -- dem letzten cash-neutralen Lot (Datum <= Stichtag), sonst dem letzten: ein echter Kauf muss die Export-Stueck
        -- exakt behalten, sonst findet Stufe 0 im Monats-Check ihn nicht und sperrt die Zeile (covered_by_takeover).
        IF v_sum <> v_h.take_shares AND abs(v_sum - v_h.take_shares) <= 0.00000001 * GREATEST(jsonb_array_length(v_lots), 1)
           AND jsonb_array_length(v_lots) > 0 THEN
            v_ix := finance.fn_takeover_dust_lot(v_lots, v_cut, v_h.take_date + 1);
            v_lots := jsonb_set(v_lots, ARRAY[v_ix::text, 'shares'],
                          to_jsonb((v_lots->v_ix->>'shares')::numeric + v_h.take_shares - v_sum));
            v_sum := v_h.take_shares;
        END IF;
        -- Kauf am Uebernahme-Tag, den die Uebernahme noch nicht enthielt (Broker zeigt den Sparplan-Kauf erst nach der
        -- Abwicklung im Bestand): stimmen die Zeilen VOR dem Tag exakt, kommen die Kaeufe des Tages als eigene Lots dazu.
        -- Ohne das bliebe der Kauf ewig ungebucht: hier lots_mismatch, im Monats-Check covered_by_takeover.
        v_same := 0;
        IF v_sum > v_h.take_shares
           AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'buy' AND (r->>'date')::date = v_h.take_date)
           AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'sell' AND (r->>'date')::date = v_h.take_date) THEN
            SELECT COALESCE(sum((l->>'shares')::numeric), 0), count(*) INTO v_sum_b, v_n_b
            FROM jsonb_array_elements(finance.fn_import_fifo_lots(
                     (SELECT COALESCE(jsonb_agg(r), '[]'::jsonb) FROM jsonb_array_elements(v_rows) r
                      WHERE (r->>'date')::date < v_h.take_date))->'lots') l;
            IF v_n_b > 0 AND abs(v_sum_b - v_h.take_shares) <= 0.00000001 * v_n_b THEN
                v_same := v_sum - v_sum_b;
                -- Rundungs-Staub der Zeilen davor auf ein Lot VOR dem Tag: Summe = Uebernahme + Kaeufe des Tages exakt
                v_ix := finance.fn_takeover_dust_lot(v_lots, v_cut, v_h.take_date);
                v_lots := jsonb_set(v_lots, ARRAY[v_ix::text, 'shares'],
                              to_jsonb((v_lots->v_ix->>'shares')::numeric + v_h.take_shares - v_sum_b));
                v_sum := v_h.take_shares + v_same;
            END IF;
        END IF;
        IF v_sum <> v_h.take_shares + v_same THEN
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
            'buy_id', v_h.buy_id, 'avg_before', v_h.avg_before, 'take_date', v_h.take_date, 'same_day_shares', v_same, 'lots', v_lots);
    END LOOP;

    -- Plan/Apply wie der Monats-Check: der echte Write nach dem Tipp bucht nur, wenn derselbe Plan herauskommt
    v_fp := md5(jsonb_build_object('a', v_acct.id, 'c', v_cut, 'p', v_plan)::text);
    IF NULLIF(p->>'fingerprint', '') IS NOT NULL AND p->>'fingerprint' <> v_fp THEN
        RETURN jsonb_build_object('ok', false, 'code', 'stale_preview',
            'reason', 'Something changed since the card was shown - send the export again for a new card.');
    END IF;

    FOR v_pl IN SELECT e FROM jsonb_array_elements(v_plan) e LOOP
        -- Buchen, altes Paar voiden, Audit stempeln: der gemeinsame Baustein (auch fn_replace_holding_lots)
        v_r := finance.fn_replace_takeover_apply((v_pl->>'holding_id')::int, v_acct.id, v_pl->'lots',
                   ARRAY(SELECT x.group_id FROM finance.transactions x WHERE x.id = (v_pl->>'buy_id')::int),
                   v_pl->>'symbol');
        v_cash_n := (v_r->>'cash_lots_count')::int;

        SELECT jsonb_build_object('holding_id', h.id, 'name', h.name, 'lots_count', jsonb_array_length(v_pl->'lots'),
                   'cash_lots_count', v_cash_n, 'shares', h.shares, 'avg_purchase_price', h.average_purchase_price,
                   'avg_before', (v_pl->>'avg_before')::numeric, 'same_day_shares', (v_pl->>'same_day_shares')::numeric,
                   'take_date', v_pl->>'take_date')
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
    -- Bestand waechst um den Kauf am Uebernahme-Tag: sonst saehe die Karte nur eine Stueck-Aenderung ohne Grund
    v_card := v_card || COALESCE((SELECT jsonb_agg(jsonb_build_object('kind', 'note', 'value', 'finance.note.lots_takeover_day_added',
                  'params', jsonb_build_object('name', r->>'name', 'date', core.fn_ui_date((r->>'take_date')::date),
                      'shares', core.fn_ui_num((r->>'same_day_shares')::numeric, 8))) ORDER BY (r->>'holding_id')::int)
              FROM jsonb_array_elements(v_replaced) r WHERE (r->>'same_day_shares')::numeric > 0), '[]'::jsonb);
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
                      WHEN m->>'code' = 'currency_mismatch'
                      THEN jsonb_build_object('kind', 'note', 'value', 'finance.note.lots_currency_mismatch',
                               'params', jsonb_build_object('name', m->>'name', 'currency', v_acct.currency))
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
