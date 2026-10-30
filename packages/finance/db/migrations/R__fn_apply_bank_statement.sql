-- ============================================================
-- fn_apply_bank_statement (ATOMIC WRITE) -- Kontoauszug buchen (Monats-Check WP-C)
--   Eingabe: dieselben Rohwerte wie fn_statement_prepare + fingerprint (aus der bestaetigten Vorschau).
--   Ablauf in EINER Transaktion: Salden der beteiligten Konten sperren -> fn_statement_prepare erneut (unter Lock;
--   anderer fingerprint -> {ok:false, code:'stale_preview'} ohne Write: zwischen Karte und Tipp hat sich etwas
--   geaendert) -> gelernte Kontonummer -> Abweichung vor dem Zeitraum als Abgleich am Schnitt-Tag -> je Treffer die
--   bestehende Buch-fn mit Ist-Betrag und Ist-Datum (Dauerauftrag/Transfer/Kredit ueber fn_book_recurring_occurrence,
--   Sparplan ueber fn_book_savings_plan_execution mit geschaetzten Stueck -> shares_estimated, Zins ueber
--   fn_book_interest_occurrence) -> Schluessel lernen -> Plan-Anpassungen (fn_split_recurring_payment) -> schon
--   gebuchte Zahlungen mit Buchungsdatum nach period_end aufs Zeilendatum verschieben (redated_count) -> Abgleich auf
--   den Endsaldo am period_end (bucht den Rest als EINE Abgleichsbuchung und ueberspringt die fehlenden Vorkommen) ->
--   Aggregat in finance.bank_statements, Herkunft bank_statement_id an jeder hier entstandenen Buchung.
--   Ein {ok:false} einer inneren Buch-fn wird zu RAISE SQLSTATE 'FN001' -> Rollback des Blocks -> {ok:false, reason}
--   (kein Teilzustand, kein Owner-Alarm).
--   Bank-Export-Datei (source:'file', Broker-CSV Paket B): Sparplan-Treffer mit exakter Stueckzahl ohne shares_estimated; prepare.trades
--   ueber fn_book_stock_buy / fn_book_stock_sell / fn_book_dividend (Herkunft bank_statement_id wie jede Buchung hier);
--   balance_source aus der Prepare; seen_refs -> finance.statement_seen_refs (faellt mit dem Auszug per CASCADE weg).
--   Bank-Import-Modul: matched kind transfer -> fn_book_transfer (beide Beine am Zeilendatum); Stufe-0-Treffer einer
--   Transfer-Gruppe (group_id) mit Buchungsdatum nach period_end -> nur die Beine DIESES Kontos aufs Zeilendatum;
--   prepare.moved_legs -> period_end+1. Gesperrt werden zusaetzlich alle Gegenkonten aus matched/blocked/already_booked.
--   Auszahlung mit Gebuehr (matched.fee): Transfer = Betrag - Gebuehr, die Gebuehr als Bein (category fee) DIESES Kontos
--   in derselben group_id. Pool-Regel (matched.partner_fee): das Gebuehr-Bein liegt beim auszahlenden P2P-Konto (am
--   Zeilendatum bzw. partner_date), ebenfalls in derselben group_id. Eine Gruppe, die das Partnerkonto ohne Gebuehr gebucht hat (already_booked.fee_add), bekommt die
--   Gebuehr als eigene Buchung dieses Auszugs (nie in die fremde Gruppe). Datei mit gedrucktem Endstand: interest_correction (category interest, ohne
--   interest_period_end) und legacy_returns (category other, Profil-Label) je EINE Buchung am period_end;
--   interest_skips -> fn_skip_interest_occurrence (in skipped, der Void holt sie zurueck).
--   Rueckgabe-Vertrag (Live-Befund 2026-10-30): booked_count = neue Buchungs-VORGAENGE dieses Abgleichs, je einer:
--   jeder matched-Treffer (Dauerauftrag, Sparplan, Zins, Transfer inkl. seines Gebuehr-Beins), jede nachgebuchte Gebuehr
--   (fee_add), Zinskorrektur, Altkredit-Rueckfluesse; nicht: Trades (trades_booked), Drift, Rest, Trade-Steuern,
--   Umdatierungen. transfers[] = jede neu ODER schon gebuchte Transfer-Gruppe dieses Auszugs {account_name (Gegenkonto),
--   amount (Transfer-Bein DIESES Kontos, signiert), fee (Gebuehr-Beine der Gruppe + fee_add, 0 = keine), fee_account
--   (this|partner|null), date (Zeilendatum), already_booked}. rest_outflow/rest_inflow = der Rest (lump) ohne
--   pending_settled nach Richtung, Netto-Differenz (eines ist 0) - ein positiver Rest ist ein ungeklaerter Eingang, nie
--   Ausgaben. pending_settled (aus der Prepare, >= 0) = Teil des Rests, der vorgemerkte Zahlungen des vorigen
--   Export-Abgleichs ausgleicht (weder Eingang noch Ausgabe); lump_amount = die ganze Rest-Buchung.
--   RUECKGABE: {ok:true, statement_id, booked_count, transfers[], rest_outflow, rest_inflow, pending_settled, trades_booked, trades_blocked[], export_unknown[], booked_tx_ids[], drift_amount, lump_amount, skipped_occurrences, redated_count,
--   learned_keys, learned_accounts[{account_id, account_name, account_number}] (IBAN-Lernen der Prepare, per fn_set_account
--   gespeichert; gesperrt wie die Transfer-Gegenkonten), plan_adjusted[], savings_plan_estimated[], unknown_mandates[], balance_after,
--   outlook (= finance.fn_account_outlook, Deckungs-Vorschau bis zum naechsten Geldeingang)} | {ok:false, code?, reason}
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_apply_bank_statement(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_prep     JSONB;
    v_acct     INT;
    v_prev_bal NUMERIC;
    v_prev_at  DATE;
    v_m        JSONB;
    v_r        JSONB;
    v_ids      INT[] := '{}';
    v_drift    NUMERIC;
    v_drift_tx INT;
    v_final    JSONB;
    v_skipped  JSONB := '[]'::jsonb;
    v_keys     INT[] := '{}';
    v_key_id   INT;
    v_k        JSONB;
    v_adjusted JSONB := '[]'::jsonb;
    v_spe      JSONB := '[]'::jsonb;
    v_stmt     INT;
    v_redated  INT := 0;
    v_trades   INT := 0;
    v_hold     INT;
    v_fee      JSONB;
    v_tg       JSONB := '[]'::jsonb;   -- Transfer-Gruppen dieses Auszugs {g, d (Zeilendatum), b (schon gebucht), fa (fee_add)}
    v_transfers JSONB;
    v_lump     NUMERIC;
    v_settled  NUMERIC;   -- Teil des Rests = Ausgleich vorgemerkter Zahlungen (prepare.pending_settled)
BEGIN
    v_prep := finance.fn_statement_prepare(p - 'fingerprint');
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_prep;
    END IF;
    v_acct := (v_prep->>'account_id')::int;

    -- Salden aller beteiligten Konten sperren (dieses Konto + Transfer-Gegenkonten aus Dauerauftraegen, Ad-hoc-Transfers
    -- und gebuchten Transfer-Gruppen), dann unter Lock neu rechnen: zwei gleichzeitig bestaetigte Karten zweier Konten
    -- laufen nacheinander, die zweite sieht die erste (stale_preview statt Doppelbuchung).
    PERFORM 1 FROM finance.account_balances b
    WHERE b.account_id = v_acct
       OR b.account_id IN (SELECT CASE WHEN r.account_id = v_acct THEN r.target_account_id ELSE r.account_id END
                           FROM finance.recurring_payments r
                           WHERE r.id IN (SELECT (m->>'recurring_payment_id')::int
                                          FROM jsonb_array_elements(v_prep->'matched') m))
       OR b.account_id IN (SELECT (m->>'other_account_id')::int FROM jsonb_array_elements((v_prep->'matched') || (v_prep->'blocked')) m)
       OR b.account_id IN (SELECT (m->>'account_id')::int FROM jsonb_array_elements(v_prep->'learned_accounts') m)
       OR b.account_id IN (SELECT t.account_id FROM finance.transactions t
                           WHERE t.group_id IN (SELECT (m->>'group_id')::uuid FROM jsonb_array_elements(v_prep->'already_booked') m))
    ORDER BY b.account_id
    FOR UPDATE;
    v_prep := finance.fn_statement_prepare(p - 'fingerprint');
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_prep;
    END IF;
    IF v_prep->>'fingerprint' IS DISTINCT FROM p->>'fingerprint' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'stale_preview',
            'reason', 'Something changed since the card was shown - prepare the statement again and show a new card.');
    END IF;

    SELECT last_reconciled_balance, last_reconciled_at INTO v_prev_bal, v_prev_at FROM finance.accounts WHERE id = v_acct;

    BEGIN
        IF v_prep->>'learned_account_number' IS NOT NULL THEN
            v_r := finance.fn_set_account(jsonb_build_object('account_id', v_acct,
                       'account_number', v_prep->>'learned_account_number'));
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = v_r->>'reason';
            END IF;
        END IF;
        -- IBAN-Lernen: die auf der Karte gezeigten IBANs eigener Konten (Prepare 3a2) speichern
        FOR v_m IN SELECT e FROM jsonb_array_elements(v_prep->'learned_accounts') e LOOP
            v_r := finance.fn_set_account(jsonb_build_object('account_id', (v_m->>'account_id')::int,
                       'account_number', v_m->>'account_number'));
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = v_r->>'reason';
            END IF;
        END LOOP;

        v_drift := (v_prep->>'drift')::numeric;
        IF v_drift <> 0 THEN
            v_r := finance.fn_reconcile_account(jsonb_build_object('account_id', v_acct,
                       'confirmed_balance', (v_prep->>'stmt_at_cut')::numeric,
                       'reconciliation_date', v_prep->>'cut', 'notes', 'Monats-Check: Abweichung vor dem Zeitraum'));
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = v_r->>'reason';
            END IF;
            v_drift_tx := NULLIF(v_r->>'reconciliation_tx_id', '')::int;
            v_ids := v_ids || v_drift_tx;
            v_skipped := v_skipped || COALESCE(v_r->'skipped', '[]'::jsonb);
        END IF;

        FOR v_m IN SELECT e FROM jsonb_array_elements(v_prep->'matched') e LOOP
            IF v_m->>'kind' = 'interest' THEN
                v_r := finance.fn_book_interest_occurrence(jsonb_build_object('account_id', v_acct,
                           'value_date', v_m->>'line_date', 'period_end', v_m->>'interest_period_end',
                           'amount', (v_m->>'amount')::numeric));
            ELSIF v_m->>'kind' = 'transfer' THEN
                -- Ad-hoc-Transfer (Stufe T): Abgang = dieses Konto ist Quelle. Unterwegs (partner_date): gebucht am Tag
                -- nach dem Abgleich des Gegenkontos, danach das Bein DIESES Kontos aufs Zeilendatum
                v_r := finance.fn_book_transfer(jsonb_build_object(
                           'from_account_id', CASE WHEN (v_m->>'amount')::numeric < 0 THEN v_acct ELSE (v_m->>'other_account_id')::int END,
                           'to_account_id',   CASE WHEN (v_m->>'amount')::numeric < 0 THEN (v_m->>'other_account_id')::int ELSE v_acct END,
                           'from_account_name', CASE WHEN (v_m->>'amount')::numeric < 0 THEN v_prep->>'account_name' ELSE v_m->>'name' END,
                           'to_account_name',   CASE WHEN (v_m->>'amount')::numeric < 0 THEN v_m->>'name' ELSE v_prep->>'account_name' END,
                           'amount', abs((v_m->>'amount')::numeric) - COALESCE((v_m->>'fee')::numeric, 0),
                           'transaction_date', COALESCE(v_m->>'partner_date', v_m->>'line_date'),
                           'purpose', 'Monats-Check'));
                IF (v_r->>'ok')::boolean AND v_m ? 'partner_date' THEN
                    UPDATE finance.transactions SET transaction_date = (v_m->>'line_date')::date
                    WHERE id IN ((v_r->>'debit_tx_id')::int, (v_r->>'credit_tx_id')::int) AND account_id = v_acct;
                END IF;
                -- Gebuehr der Auszahlung (Profil) in derselben Gruppe (ein Write = ein Void): fee = Bein auf DIESEM Konto
                -- (Bondora-Datei), partner_fee = Bein beim auszahlenden P2P-Konto (Pool-Regel auf der Bank-Seite)
                IF (v_r->>'ok')::boolean AND COALESCE((v_m->>'fee')::numeric, (v_m->>'partner_fee')::numeric, 0) > 0 THEN
                    v_fee := finance.fn_book_transaction(jsonb_build_object(
                                 'account_id', CASE WHEN v_m ? 'fee' THEN v_acct ELSE (v_m->>'other_account_id')::int END,
                                 'amount', COALESCE((v_m->>'fee')::numeric, (v_m->>'partner_fee')::numeric),
                                 'direction', 'outflow', 'category', 'fee',
                                 'transaction_date', CASE WHEN v_m ? 'fee' THEN v_m->>'line_date'
                                                          ELSE COALESCE(v_m->>'partner_date', v_m->>'line_date') END,
                                 'description', 'Gebühr Auszahlung -> '
                                                || CASE WHEN v_m ? 'fee' THEN v_m->>'name' ELSE v_prep->>'account_name' END));
                    IF (v_fee->>'ok')::boolean IS DISTINCT FROM true THEN
                        RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = 'fee: ' || COALESCE(v_fee->>'reason', 'booking refused');
                    END IF;
                    UPDATE finance.transactions SET group_id = (SELECT group_id FROM finance.transactions WHERE id = (v_r->>'debit_tx_id')::int)
                    WHERE id = (v_fee->>'tx_id')::int;
                    v_ids := v_ids || (v_fee->>'tx_id')::int;
                END IF;
            ELSIF v_m->>'kind' = 'savings_plan' THEN
                v_r := finance.fn_book_savings_plan_execution(jsonb_build_object(
                           'recurring_payment_id', (v_m->>'recurring_payment_id')::int, 'due_date', v_m->>'due_date',
                           'transaction_date', v_m->>'line_date', 'shares', (v_m->>'shares')::numeric,
                           'price_per_share', (v_m->>'price_per_share')::numeric, 'order_fee', (v_m->>'order_fee')::numeric));
            ELSE
                v_r := finance.fn_book_recurring_occurrence(jsonb_build_object(
                           'recurring_payment_id', (v_m->>'recurring_payment_id')::int, 'due_date', v_m->>'due_date',
                           'amount', abs((v_m->>'amount')::numeric), 'transaction_date', v_m->>'line_date'));
            END IF;
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION USING ERRCODE = 'FN001',
                    MESSAGE = COALESCE(v_m->>'name', 'payment') || ': ' || COALESCE(v_r->>'reason', 'booking refused');
            END IF;
            v_ids := v_ids || ARRAY_REMOVE(ARRAY[NULLIF(v_r->>'transaction_id', '')::int, NULLIF(v_r->>'debit_tx_id', '')::int,
                                                 NULLIF(v_r->>'credit_tx_id', '')::int, NULLIF(v_r->>'buy_tx_id', '')::int], NULL);
            -- Transfer-Buchung (Ad-hoc fn_book_transfer bzw. Dauerauftrag ueber fn_book_recurring_transfer): Gruppe merken
            IF v_r ? 'debit_tx_id' THEN
                v_tg := v_tg || jsonb_build_object('g', (SELECT group_id FROM finance.transactions WHERE id = (v_r->>'debit_tx_id')::int),
                                                   'd', v_m->>'line_date', 'b', false, 'fa', 0);
            END IF;
            IF v_m->>'kind' = 'savings_plan' AND COALESCE((v_m->>'shares_estimated')::boolean, true) THEN
                UPDATE finance.transactions SET shares_estimated = true WHERE id = (v_r->>'buy_tx_id')::int;
                v_spe := v_spe || jsonb_build_object('name', v_m->>'name', 'shares', (v_m->>'shares')::numeric,
                                                     'holding_id', (v_r->>'holding_id')::int);
            END IF;
        END LOOP;

        -- Datei mit gedrucktem Endstand: Zinskorrektur + Kleinbetraege je als EINE Buchung am period_end, offene
        -- Scheduler-Zins-Vorkommen bis period_end ueberspringen (in skipped -> der Void holt sie zurueck)
        IF COALESCE((v_prep->>'interest_correction')::numeric, 0) <> 0 THEN
            v_r := finance.fn_book_transaction(jsonb_build_object('account_id', v_acct,
                       'amount', abs((v_prep->>'interest_correction')::numeric),
                       'direction', CASE WHEN (v_prep->>'interest_correction')::numeric < 0 THEN 'outflow' ELSE 'inflow' END,
                       'category', 'interest', 'transaction_date', v_prep->>'period_end',
                       'description', 'Zinskorrektur laut Auszug'));
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = 'interest correction: ' || COALESCE(v_r->>'reason', 'booking refused');
            END IF;
            v_ids := v_ids || (v_r->>'tx_id')::int;
        END IF;
        IF COALESCE((v_prep->>'legacy_returns')::numeric, 0) <> 0 THEN
            v_r := finance.fn_book_transaction(jsonb_build_object('account_id', v_acct,
                       'amount', abs((v_prep->>'legacy_returns')::numeric),
                       'direction', CASE WHEN (v_prep->>'legacy_returns')::numeric < 0 THEN 'outflow' ELSE 'inflow' END,
                       'category', 'other', 'transaction_date', v_prep->>'period_end',
                       'description', v_prep->>'legacy_return_label'));
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = 'legacy returns: ' || COALESCE(v_r->>'reason', 'booking refused');
            END IF;
            v_ids := v_ids || (v_r->>'tx_id')::int;
        END IF;
        -- Gebuehr zu einem schon gebuchten Transfer (fee_add, Partnerkonto zuerst importiert): eigene Buchung OHNE die
        -- Gruppe des Partner-Auszugs (sonst stempelte/loeschte dieser Auszug fremde Beine mit)
        FOR v_m IN SELECT e FROM jsonb_array_elements(v_prep->'already_booked') e WHERE e ? 'fee_add' LOOP
            v_r := finance.fn_book_transaction(jsonb_build_object('account_id', v_acct,
                       'amount', (v_m->>'fee_add')::numeric, 'direction', 'outflow', 'category', 'fee',
                       'transaction_date', v_m->>'line_date', 'description', 'Gebühr Auszahlung'));
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = 'fee: ' || COALESCE(v_r->>'reason', 'booking refused');
            END IF;
            v_ids := v_ids || (v_r->>'tx_id')::int;
        END LOOP;
        FOR v_k IN SELECT e FROM jsonb_array_elements(COALESCE(v_prep->'interest_skips', '[]'::jsonb)) e LOOP
            PERFORM finance.fn_skip_interest_occurrence(jsonb_build_object('account_id', v_acct,
                        'period_end', v_k->>'interest_period_end'));
            v_skipped := v_skipped || v_k;
        END LOOP;

        -- Broker-CSV: Wertpapier-Zeilen ohne Treffer aus den Export-Werten buchen (Reihenfolge = Datum, Kauf vor Verkauf).
        -- Verkauf/Dividende einer erst in diesem Export gekauften Position: die Holding entsteht beim Kauf davor.
        FOR v_m IN SELECT e FROM jsonb_array_elements(COALESCE(v_prep->'trades', '[]'::jsonb)) e LOOP
            v_hold := NULLIF(v_m->>'holding_id', '')::int;
            IF v_hold IS NULL AND v_m->>'kind' <> 'buy' THEN
                SELECT h.id INTO v_hold FROM finance.depot_holdings h JOIN finance.accounts d ON d.id = h.account_id
                WHERE d.settlement_account_id = v_acct AND d.status = 'active'
                  AND (upper(h.isin) = v_m->>'isin' OR (v_m->>'isin' IS NULL AND h.isin IS NULL AND upper(h.symbol) = upper(v_m->>'symbol')))
                ORDER BY h.id LIMIT 1;
            END IF;
            IF v_m->>'kind' = 'buy' THEN
                v_r := finance.fn_book_stock_buy(jsonb_build_object('depot_id', (v_m->>'depot_id')::int,
                           'settlement_id', v_acct, 'isin', v_m->>'isin', 'symbol', v_m->>'symbol', 'name', v_m->>'name',
                           'shares', (v_m->>'shares')::numeric, 'price_per_share', (v_m->>'price_per_share')::numeric,
                           'order_fee', (v_m->>'order_fee')::numeric, 'transaction_date', v_m->>'date'));
            ELSIF v_m->>'kind' = 'sell' THEN
                v_r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id', v_acct,
                           'holding_id', v_hold, 'symbol', v_m->>'symbol',
                           'shares', (v_m->>'shares')::numeric, 'price_per_share', (v_m->>'price_per_share')::numeric,
                           'order_fee', (v_m->>'order_fee')::numeric, 'transaction_date', v_m->>'date'));
            ELSE
                v_r := finance.fn_book_dividend(jsonb_build_object('account_id', v_acct,
                           'holding_id', v_hold, 'amount', (v_m->>'amount')::numeric,
                           'transaction_date', v_m->>'date', 'description', 'Dividende ' || (v_m->>'name')));
            END IF;
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION USING ERRCODE = 'FN001',
                    MESSAGE = COALESCE(v_m->>'name', 'trade') || ': ' || COALESCE(v_r->>'reason', 'booking refused');
            END IF;
            v_ids := v_ids || ARRAY_REMOVE(ARRAY[NULLIF(v_r->>'buy_tx_id', '')::int, NULLIF(v_r->>'sell_tx_id', '')::int,
                                                 NULLIF(v_r->>'transaction_id', '')::int], NULL);
            v_trades := v_trades + 1;
            -- einbehaltene Steuer auf Kauf/Verkauf: eigene Buchung (die Buch-fns kennen keine Steuer), nie im Rest
            IF COALESCE((v_m->>'tax')::numeric, 0) <> 0 THEN
                v_r := finance.fn_book_transaction(jsonb_build_object('account_id', v_acct,
                           'amount', abs((v_m->>'tax')::numeric),
                           'direction', CASE WHEN (v_m->>'tax')::numeric < 0 THEN 'outflow' ELSE 'inflow' END,
                           'category', 'other', 'transaction_date', v_m->>'date',
                           'description', 'Steuer ' || CASE WHEN v_m->>'kind' = 'sell' THEN 'Verkauf ' ELSE 'Kauf ' END || (v_m->>'name')));
                IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                    RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = COALESCE(v_m->>'name', 'trade') || ' tax: ' || COALESCE(v_r->>'reason', 'booking refused');
                END IF;
                v_ids := v_ids || (v_r->>'tx_id')::int;
            END IF;
        END LOOP;

        FOR v_k IN SELECT e FROM jsonb_array_elements(v_prep->'learn') e LOOP
            INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
            VALUES ((v_k->>'recurring_payment_id')::int, (v_k->>'key_type')::finance.rp_key_type, v_k->>'key_value', 'statement')
            ON CONFLICT DO NOTHING
            RETURNING id INTO v_key_id;
            IF v_key_id IS NOT NULL THEN v_keys := v_keys || v_key_id; END IF;
            v_key_id := NULL;
        END LOOP;

        FOR v_k IN SELECT e FROM jsonb_array_elements(v_prep->'plan_adjustments') e LOOP
            v_r := finance.fn_split_recurring_payment((v_k->>'recurring_payment_id')::int, (v_k->>'eff_from')::date,
                       (v_k->>'amount')::numeric, NULL, NULL, NULL, NULL, NULL, NULL);
            IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
                RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = (v_k->>'name') || ': ' || (v_r->>'reason');
            END IF;
            v_adjusted := v_adjusted || jsonb_build_object('name', v_k->>'name', 'eff_from', v_k->>'eff_from',
                                                           'amount', (v_k->>'amount')::numeric,
                                                           'recurring_payment_id', (v_r->>'recurring_payment_id')::int);
        END LOOP;

        -- Schon gebuchte Zahlung mit Buchungsdatum nach dem Auszugsende -> aufs Ist-Datum laut Auszug (alle Beine der
        -- Gruppe; die Verschiebbarkeit prueft fn_statement_match, prepare zaehlt sie schon zum Stand am period_end).
        FOR v_m IN SELECT e FROM jsonb_array_elements(v_prep->'already_booked') e
                   WHERE (e->>'tx_date')::date > (v_prep->>'period_end')::date LOOP
            UPDATE finance.transactions t SET transaction_date = (v_m->>'line_date')::date
            WHERE t.id = (v_m->>'transaction_id')::int
               OR (v_m->>'group_id' IS NULL
                   AND t.group_id = (SELECT x.group_id FROM finance.transactions x
                                     WHERE x.id = (v_m->>'transaction_id')::int AND x.group_id IS NOT NULL))
               -- Ad-hoc-Transfer ('g:'): nur die Beine DIESES Kontos (das Partnerbein steht im Partner-Auszug)
               OR (t.group_id = (v_m->>'group_id')::uuid AND t.account_id = v_acct);
            v_redated := v_redated + 1;
        END LOOP;
        -- Monatsgrenze: unterwegs befindliche Transfer-Beine (prepare.moved_legs) auf period_end+1
        UPDATE finance.transactions t SET transaction_date = (v_prep->>'period_end')::date + 1
        WHERE t.id IN (SELECT (x->>'transaction_id')::int FROM jsonb_array_elements(v_prep->'moved_legs') x);
        v_redated := v_redated + jsonb_array_length(v_prep->'moved_legs');

        v_final := finance.fn_reconcile_account(jsonb_build_object('account_id', v_acct,
                       'confirmed_balance', (v_prep->>'closing_balance')::numeric, 'reconciliation_date', v_prep->>'period_end',
                       'notes', 'Monats-Check ' || (v_prep->>'period_start') || ' bis ' || (v_prep->>'period_end')));
        IF (v_final->>'ok')::boolean IS DISTINCT FROM true THEN
            RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = v_final->>'reason';
        END IF;
        v_ids := v_ids || ARRAY_REMOVE(ARRAY[NULLIF(v_final->>'reconciliation_tx_id', '')::int], NULL);
        v_skipped := v_skipped || COALESCE(v_final->'skipped', '[]'::jsonb);

        INSERT INTO finance.bank_statements
            (account_id, period_start, period_end, opening_balance, closing_balance, currency, line_count, matched_count,
             unmatched_out, unmatched_in, prev_last_reconciled_balance, prev_last_reconciled_at, skipped, learned_key_ids,
             balance_source, export_gap, oneoff_out, oneoff_threshold)
        VALUES (v_acct, (v_prep->>'period_start')::date, (v_prep->>'period_end')::date,
                (v_prep->>'opening_balance')::numeric, (v_prep->>'closing_balance')::numeric, v_prep->>'currency',
                (v_prep->>'line_count')::int, (v_prep->>'matched_count')::int,
                (v_prep->>'unmatched_out')::numeric, (v_prep->>'unmatched_in')::numeric, v_prev_bal, v_prev_at,
                v_skipped, v_keys, v_prep->>'balance_source', (v_prep->>'export_gap')::numeric,
                (v_prep->>'oneoff_out')::numeric, (v_prep->>'oneoff_threshold')::numeric)
        RETURNING id INTO v_stmt;

        -- Broker-CSV: gesehene Bank-Referenzen nur als Hash (spaete Zeilen beim naechsten Export erkennen)
        INSERT INTO finance.statement_seen_refs (account_id, ref_hash, statement_id)
        SELECT v_acct, h, v_stmt FROM jsonb_array_elements_text(COALESCE(v_prep->'seen_refs', '[]'::jsonb)) h
        ON CONFLICT (account_id, ref_hash) DO NOTHING;

        -- Herkunft: jede hier entstandene Buchung inkl. ihrer Gruppen-Beine (Transfer-Ziel, Kredit-Tilgung).
        UPDATE finance.transactions t SET bank_statement_id = v_stmt
        WHERE t.id = ANY(v_ids)
           OR t.group_id IN (SELECT x.group_id FROM finance.transactions x WHERE x.id = ANY(v_ids) AND x.group_id IS NOT NULL);
    EXCEPTION WHEN SQLSTATE 'FN001' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'booking_failed', 'reason', SQLERRM);
    END;

    -- Erkannte Uebertraege (Live-Befund 2026-10-30: der Agent kannte sie nicht): neu gebuchte + schon gebuchte
    -- Transfer-Gruppen; Zahlen aus den gebuchten Beinen (Bein DIESES Kontos signiert, Gebuehr-Beine der Gruppe + fee_add).
    SELECT v_tg || COALESCE(jsonb_agg(jsonb_build_object(
               'g', COALESCE(e->>'group_id', (SELECT x.group_id::text FROM finance.transactions x WHERE x.id = (e->>'transaction_id')::int)),
               'd', e->>'line_date', 'b', true, 'fa', COALESCE((e->>'fee_add')::numeric, 0))), '[]'::jsonb)
    INTO v_tg FROM jsonb_array_elements(v_prep->'already_booked') e;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'account_name', (SELECT a.name FROM finance.transactions t JOIN finance.accounts a ON a.id = t.account_id
                                WHERE t.group_id = (g->>'g')::uuid AND t.account_id <> v_acct AND t.category::text = 'transfer'
                                ORDER BY t.id LIMIT 1),
               'amount', s.amt,
               'fee', s.fee + (g->>'fa')::numeric,
               'fee_account', CASE WHEN (g->>'fa')::numeric > 0 OR s.fee_here THEN 'this' WHEN s.fee > 0 THEN 'partner' END,
               'date', (g->>'d')::date,
               'already_booked', (g->>'b')::boolean) ORDER BY (g->>'d')::date, (g->>'b')::boolean), '[]'::jsonb)
    INTO v_transfers
    -- je Gruppe EIN Eintrag (eine Gruppe kann nie zweimal als Uebertrag erscheinen; neu gebucht geht vor)
    FROM (SELECT DISTINCT ON (x->>'g') x AS g FROM jsonb_array_elements(v_tg) x
          WHERE x->>'g' IS NOT NULL ORDER BY x->>'g', (x->>'b')::boolean) d
    CROSS JOIN LATERAL (SELECT sum(t.amount) FILTER (WHERE t.account_id = v_acct AND t.category::text = 'transfer') AS amt,
                               COALESCE(-sum(t.amount) FILTER (WHERE t.category::text = 'fee'), 0) AS fee,
                               COALESCE(bool_or(t.account_id = v_acct AND t.category::text = 'fee'), false) AS fee_here
                        FROM finance.transactions t WHERE t.group_id = (g->>'g')::uuid) s
    WHERE g->>'g' IS NOT NULL AND s.amt IS NOT NULL;
    v_lump := COALESCE((v_final->>'difference')::numeric, 0);
    v_settled := COALESCE((v_prep->>'pending_settled')::numeric, 0);

    RETURN jsonb_build_object('ok', true,
        'statement_id', v_stmt,
        'booked_count', jsonb_array_length(v_prep->'matched')
                        + (SELECT count(*) FROM jsonb_array_elements(v_prep->'already_booked') e WHERE e ? 'fee_add')::int
                        + CASE WHEN COALESCE((v_prep->>'interest_correction')::numeric, 0) <> 0 THEN 1 ELSE 0 END
                        + CASE WHEN COALESCE((v_prep->>'legacy_returns')::numeric, 0) <> 0 THEN 1 ELSE 0 END,
        'transfers', v_transfers,
        'rest_outflow', GREATEST(-(v_lump - v_settled), 0),
        'rest_inflow', GREATEST(v_lump - v_settled, 0),
        'pending_settled', v_settled,
        'trades_booked', v_trades,
        'trades_blocked', COALESCE(v_prep->'trades_blocked', '[]'::jsonb),
        'export_unknown', COALESCE(v_prep->'export_unknown', '[]'::jsonb),
        'booked_tx_ids', to_jsonb(v_ids),
        'drift_amount', v_drift,
        'lump_amount', v_lump,
        'skipped_occurrences', jsonb_array_length(v_skipped),
        'redated_count', v_redated,
        'learned_keys', cardinality(v_keys),
        'learned_accounts', COALESCE(v_prep->'learned_accounts', '[]'::jsonb),
        'plan_adjusted', v_adjusted,
        'savings_plan_estimated', v_spe,
        'unknown_mandates', v_prep->'unknown_mandates',
        'balance_after', (SELECT balance FROM finance.account_balances WHERE account_id = v_acct),
        'outlook', finance.fn_account_outlook(v_acct));
END;
$$;
