-- ============================================================
-- fn_statement_prepare (READ, STABLE) -- Vorschau eines Kontoauszugs (Monats-Check WP-C)
--   Die EINE Rechen-Adresse fuer Karte UND Buchung: fn_apply_bank_statement ruft sie unter Lock erneut auf und bucht
--   nur, wenn der fingerprint gleich ist (Plan/Apply-Muster; sonst stale_preview). Rechnet alles in der DB — das LLM
--   liefert nur die gedruckten Rohwerte.
--   Eingabe jsonb: account_number (gedruckt, Leerzeichen egal) ODER account_name (Nutzer-Zuordnung nach
--   account_unknown; dann wird die gedruckte Nummer gelernt), currency, period_start, period_end, opening_balance,
--   closing_balance, lines:[{date, amount (signiert), counterparty, counterparty_iban, creditor_id, mandate_ref, purpose}].
--   Ablauf:
--     1. Konto (fn_resolve_account_by_number bzw. Name), buchbar, Waehrung, Zeitraum nicht in der Zukunft, nicht schon
--        bestaetigt (last_reconciled_at >= period_end -> already_covered), Saldo-Probe Anfang + Summe = Ende (0,00).
--     2. Schnitt cut = spaetester bestaetigter Tag: GREATEST(period_start-1, last_reconciled_at, opening_balance_date).
--        Zeilen bis cut stecken im bestaetigten Saldo und werden ignoriert (Ueberlappung ok). drift = Stand laut
--        Auszug am cut - Systemstand am cut (Abweichung VOR dem Zeitraum, separat gebucht und auf der Karte gewarnt).
--     3. fn_statement_match; Anreicherung: Sparplan -> Stueck = Betrag / Kurs (market_prices +-3 Tage, Depot-Waehrung;
--        sonst pending = Rest), Kredit -> fn_get_loan_payment_split muss ok sein, Transfer -> Gegenkonto darf am
--        Zeilendatum nicht abgeglichen sein (sonst blocked = Rest), Plan-Anpassung nur fuer einfache Dauerauftraege
--        (ohne Kredit/Sparplan/Sparziel/Versicherung/Vorsorge) beim 2. gleichen Ist-Betrag (eff_from = Faelligkeit+1).
--        Plan-Anpassung hoechstens einmal je Kette (spaeteste Faelligkeit; Vorgaenger auch aus diesem Auszug).
--     4. missing = ALLE offenen Vorkommen mit Faelligkeit <= period_end-10 ohne Zeile = exakt das, was der Abgleich
--        ueberspringt (auch vor dem Zeitraum oder aus einer Luecke; juengere bleiben offen — eine Abbuchung am 30. kann
--        am 2. kommen). Teil des fingerprint.
--     5. lump = Endsaldo - (Systemstand am period_end + drift + Summe der neuen Buchungen auf diesem Konto + schon
--        gebuchte Stufe-0-Treffer mit Buchungsdatum nach period_end, die apply aufs Zeilendatum verschiebt) = die EINE
--        Abgleichsbuchung "Alltagsausgaben" (DB-Differenz, nicht Summe der Restzeilen: deckt auch Fremdbuchungen ab).
--     6. card_lines = die Kartenzeilen als Struktur (core.fn_ui_tpl/money/date; das Gate rendert je Empfaenger).
--   RUECKGABE: {ok:true, account_id, account_name, currency, period_start, period_end, opening_balance, closing_balance,
--   cut, stmt_at_cut, drift, gap, matched[], already_booked[], blocked[], savings_plan_pending[], missing[],
--   unknown_mandates[], plan_adjustments[], learn[], learned_account_number, line_count, matched_count, unmatched_out,
--   unmatched_in, lump, card_lines[], fingerprint} | {ok:false, code, reason, ...}
--   account_unknown (Nummern-Pfad) traegt zusaetzlich balance_verified und - nur wenn die Saldo-Probe stimmt und der
--   Zeitraum abgeschlossen ist - closing_balance, balance_date (= period_end), currency: Startsaldo fuer ein NEUES Konto
--   (fn_create_account opening_balance + opening_balance_date; derselbe Auszug ist danach already_covered).
--   codes: invalid_statement, account_unknown (+candidates), account_ambiguous, not_bookable, currency_mismatch,
--   period_in_future, already_covered, already_imported, balance_check_failed (+difference).
--   BROKER-CSV (source:'csv', Paket B): Eingabe {source, account_name, closing_balance = Kontostand laut Bank-App JETZT
--   (Pflicht), csv:{header, rows} = Tokenizer-Ausgabe}. fn_broker_csv_normalize liest den Export (kein LLM); Zeitraum =
--   Schnitt+1 bis gestern (Schnitt = last_reconciled_at bzw. opening_balance_date, sonst no_starting_point); Stand am
--   period_end = closing_balance - Summe der Zeilen danach; Anfang daraus (keine Saldo-Probe, der drift zeigt einen
--   unvollstaendigen Export). Spaete Zeilen (Referenz-Hash im letzten CSV-Zeitraum nicht gesehen) zaehlen mit Datum
--   Schnitt+1. Sparplan-Treffer mit exakter Stueckzahl (shares_estimated false). Wertpapier-Zeilen ohne Treffer: Stufe 0
--   gegen gebuchte Trades, sonst trades[] (apply bucht fn_book_stock_buy/_sell/fn_book_dividend), nicht buchbar ->
--   trades_blocked[] (covered_by_takeover, oversell, security_unknown); unknown-Zeilen des Exports -> csv_unknown[].
--   Review 2026-10-28: Steuer auf Kauf/Verkauf = eigene Buchung (trades[].tax, nie im Rest); Verkaufs-Check zaehlt
--   Sparplan-Kaeufe und Kaeufe DIESES Exports mit; Verkauf/Dividende einer erst im Export gekauften Position wird gebucht;
--   neue Position nur ins EINE Depot der passenden Art (Krypto ohne ISIN -> crypto_depot); Stufe 0 auch gegen eine von
--   Hand vor dem Schnitt datierte Buchung (+-5 Tage, nie doppelt); App-Kontostand ueber fn_parse_numeric_or_null.
--   Zusaetzliche codes: csv_profile_unknown, csv_invalid, closing_balance_required (keine Karte), no_starting_point,
--   multiple_sub_accounts. Zusaetzliche Rueckgabe: source, balance_source (printed|owner), owner_balance, after_period,
--   trades, trades_blocked, csv_unknown, late_count, seen_refs (Hashes fuer finance.statement_seen_refs).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_statement_prepare(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_lines    JSONB := COALESCE(p->'lines', '[]'::jsonb);
    v_ps       DATE;
    v_pe       DATE;
    v_open     NUMERIC;
    v_close    NUMERIC;
    v_acct     finance.accounts%ROWTYPE;
    v_res      RECORD;
    v_learn_no TEXT;
    v_reason   TEXT;
    v_sum      NUMERIC;
    v_balance_ok BOOLEAN;
    v_cut      DATE;
    v_stmt_cut NUMERIC;
    v_drift    NUMERIC;
    v_gap      BOOLEAN;
    v_match    JSONB;
    v_m        JSONB;
    v_head     INT;
    v_kind     TEXT;
    v_plan     finance.savings_plans%ROWTYPE;
    v_price    NUMERIC;
    v_pccy     TEXT;
    v_shares   NUMERIC;
    v_split    JSONB;
    v_loan     finance.loans%ROWTYPE;
    v_other    INT;
    v_last_amt NUMERIC;
    v_to_book  JSONB := '[]'::jsonb;
    v_booked   JSONB := '[]'::jsonb;
    v_blocked  JSONB := '[]'::jsonb;
    v_pending  JSONB := '[]'::jsonb;
    v_adjust   JSONB := '[]'::jsonb;
    v_learn    JSONB := '[]'::jsonb;
    v_missing  JSONB;
    v_unknown  JSONB;
    v_out      NUMERIC;
    v_in       NUMERIC;
    v_s_end    NUMERIC;
    v_book_sum NUMERIC := 0;
    v_redate_sum NUMERIC := 0;
    v_lump     NUMERIC;
    v_card     JSONB := '[]'::jsonb;
    v_fp       TEXT;
    -- Broker-CSV (Paket B)
    v_csv      BOOLEAN := COALESCE(p->>'source', '') = 'csv';
    v_norm     JSONB;
    v_owner    NUMERIC;
    v_after    NUMERIC := 0;
    v_prev     finance.bank_statements%ROWTYPE;
    v_line     JSONB;
    v_idx      INT;
    v_hold     RECORD;
    v_hcount   INT;
    v_depot    INT;
    v_tx_id    INT;
    v_tx_date  DATE;
    v_tx_amt   NUMERIC;
    v_used_tx  INT[] := '{}';
    v_avail    NUMERIC;
    v_tamt     NUMERIC;
    v_ttax     NUMERIC;
    v_trades   JSONB := '[]'::jsonb;
    v_tblocked JSONB := '[]'::jsonb;
    v_csv_unk  JSONB := '[]'::jsonb;
BEGIN
    -- ---------- 1a. Broker-CSV: Export normieren, Zeitraum = nach dem bestaetigten Tag bis gestern ----------
    --   Kein gedruckter Saldo: der Owner nennt den Kontostand aus der App (Pflicht, nie ein errechneter Saldo als
    --   bestaetigt). Stand am period_end = Owner-Zahl - Summe der Zeilen danach (Teil-Tag-Export bis heute). Anfang
    --   = dieser Stand - Summe der Zeitraum-Zeilen -> die Abweichung zum System am Schnitt ist der drift (Export
    --   unvollstaendig oder falsche Zahl), die Saldo-Probe entfaellt (fester Leser, keine Lesefehler).
    --   Spaete Zeilen: Datum im Zeitraum des letzten CSV-Abgleichs, Referenz dort nicht gesehen -> Datum = Schnitt+1.
    IF v_csv THEN
        v_norm := finance.fn_broker_csv_normalize(COALESCE(p->'csv', '{}'::jsonb));
        IF (v_norm->>'ok')::boolean IS DISTINCT FROM true THEN
            RETURN v_norm;
        END IF;
        IF NULLIF(trim(p->>'account_name'), '') IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'account_unknown', 'candidates', '[]'::jsonb,
                'reason', 'Name the account this export belongs to.');
        END IF;
        SELECT * INTO v_res FROM finance.fn_resolve_account(trim(p->>'account_name'), NULL, TRUE);
        IF v_res.hit_count <> 1 THEN
            RETURN jsonb_build_object('ok', false, 'code', CASE WHEN v_res.hit_count = 0 THEN 'account_unknown' ELSE 'account_ambiguous' END,
                'reason', 'No unique active account named "' || trim(p->>'account_name') || '".',
                'candidates', v_res.candidates);
        END IF;
        SELECT * INTO v_acct FROM finance.accounts WHERE id = v_res.id;
        IF jsonb_array_length(v_norm->'account_types') > 1 THEN
            RETURN jsonb_build_object('ok', false, 'code', 'multiple_sub_accounts', 'account_types', v_norm->'account_types',
                'reason', 'The export mixes several sub-accounts (' || (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(v_norm->'account_types') x)
                       || ') - ask the user to export each account on its own.');
        END IF;
        -- so, wie der Nutzer ihn nennt ("1.234,56", "1234.56 EUR"): die eine Adresse fuer freie Geld-Eingaben
        v_owner := round(finance.fn_parse_numeric_or_null(p->>'closing_balance', true), 2);
        IF v_owner IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'closing_balance_required',
                'reason', 'The export has no balance - ask the user for the current balance of "' || v_acct.name
                       || '" exactly as the bank app shows it right now, then call again.');
        END IF;
        IF v_acct.last_reconciled_at IS NULL AND v_acct.opening_balance_date IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'no_starting_point',
                'reason', 'The account "' || v_acct.name || '" has no confirmed balance date yet - confirm its balance once '
                       || '(tool_reconcile_account), then send the export again.');
        END IF;
        v_pe  := core.fn_today() - 1;
        v_cut := GREATEST(v_acct.last_reconciled_at, v_acct.opening_balance_date);
        v_ps  := LEAST(v_cut + 1, v_pe);
        SELECT * INTO v_prev FROM finance.bank_statements
        WHERE account_id = v_acct.id AND balance_source = 'owner' ORDER BY period_end DESC LIMIT 1;
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'date', GREATEST((r->>'date')::date, v_cut + 1), 'booking_date', (r->>'date')::date,
                   'late', (r->>'date')::date <= v_cut,
                   'amount', (r->>'cash_amount')::numeric, 'counterparty', r->>'counterparty',
                   'counterparty_iban', r->>'counterparty_iban', 'purpose', COALESCE(r->>'purpose', r->>'name'),
                   'kind', r->>'kind', 'isin', r->>'isin', 'symbol', r->>'symbol', 'name', r->>'name',
                   'shares', r->'shares', 'gross', r->'gross', 'fee', r->'fee', 'tax', r->'tax', 'row_no', r->'row_no', 'ext_ref', r->>'ext_ref',
                   'reason', r->>'reason')
                 ORDER BY GREATEST((r->>'date')::date, v_cut + 1), (r->>'kind' = 'sell'), (r->>'row_no')::int), '[]'::jsonb)
        INTO v_lines
        FROM jsonb_array_elements(v_norm->'rows') r
        WHERE ((r->>'date')::date > v_cut AND (r->>'date')::date <= v_pe)
           OR (v_prev.id IS NOT NULL AND r->>'ext_ref' IS NOT NULL
               AND (r->>'date')::date BETWEEN v_prev.period_start AND LEAST(v_prev.period_end, v_cut)
               AND NOT EXISTS (SELECT 1 FROM finance.statement_seen_refs s
                               WHERE s.account_id = v_acct.id AND s.ref_hash = r->>'ext_ref'));
        SELECT COALESCE(sum((r->>'cash_amount')::numeric), 0) INTO v_after
        FROM jsonb_array_elements(v_norm->'rows') r WHERE (r->>'date')::date > v_pe;
        SELECT COALESCE(sum((l->>'amount')::numeric), 0) INTO v_sum FROM jsonb_array_elements(v_lines) l;
        v_close := v_owner - v_after;
        v_open  := v_close - v_sum;
        v_balance_ok := true;
        SELECT COALESCE(jsonb_agg(u ORDER BY (u->>'row_no')::int), '[]'::jsonb) INTO v_csv_unk
        FROM jsonb_array_elements(v_norm->'unknown_rows') u
        WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(v_lines) l WHERE (l->>'row_no')::int = (u->>'row_no')::int);
        IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_norm->'currencies') c WHERE c <> v_acct.currency) THEN
            RETURN jsonb_build_object('ok', false, 'code', 'currency_mismatch',
                'reason', 'The export contains amounts in another currency than the account "' || v_acct.name
                       || '" (' || v_acct.currency || ').');
        END IF;
    ELSE
    -- ---------- 1. Rohwerte + Konto (gedruckter Auszug) ----------
    BEGIN
        v_ps    := (p->>'period_start')::date;
        v_pe    := (p->>'period_end')::date;
        v_open  := round((p->>'opening_balance')::numeric, 2);
        v_close := round((p->>'closing_balance')::numeric, 2);
        PERFORM (l->>'date')::date, (l->>'amount')::numeric FROM jsonb_array_elements(v_lines) l;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_statement',
            'reason', 'The statement data is incomplete or unreadable (period, balances or a line date/amount).');
    END;
    IF v_ps IS NULL OR v_pe IS NULL OR v_open IS NULL OR v_close IS NULL OR v_ps > v_pe
       OR jsonb_typeof(v_lines) <> 'array'
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_lines) l
                  WHERE (l->>'date') IS NULL OR (l->>'amount') IS NULL OR (l->>'date')::date > v_pe) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_statement',
            'reason', 'The statement data is incomplete (period, opening/closing balance, or a line outside the period).');
    END IF;
    -- Saldo-Probe EINMAL rechnen: Gate fuer den Startsaldo eines neuen Kontos (account_unknown) und balance_check_failed.
    SELECT COALESCE(sum(round((l->>'amount')::numeric, 2)), 0) INTO v_sum FROM jsonb_array_elements(v_lines) l;
    v_balance_ok := (v_open + v_sum = v_close);

    -- S7 (Owner-Frage 2026-10-23 "im Auszug stehen viele IBANs"): eine IBAN-foermige Kopf-Nummer mit falscher
    -- Pruefziffer ist VERLESEN, kein neues Konto -> unreadable statt account_unknown (nie ein Konto mit falscher IBAN).
    IF NOT finance.fn_iban_valid(p->>'account_number') THEN
        RETURN jsonb_build_object('ok', false, 'code', 'unreadable',
            'reason', 'The account IBAN on the statement could not be read reliably (check digits do not match) - ask the user for the PDF from online banking.');
    END IF;

    IF NULLIF(trim(p->>'account_name'), '') IS NOT NULL THEN
        SELECT * INTO v_res FROM finance.fn_resolve_account(trim(p->>'account_name'), NULL, TRUE);
        IF v_res.hit_count <> 1 THEN
            RETURN jsonb_build_object('ok', false, 'code', CASE WHEN v_res.hit_count = 0 THEN 'account_unknown' ELSE 'account_ambiguous' END,
                'reason', 'No unique active account named "' || trim(p->>'account_name') || '".',
                'candidates', v_res.candidates);
        END IF;
        SELECT * INTO v_acct FROM finance.accounts WHERE id = v_res.id;
        v_learn_no := finance.fn_normalize_account_number(p->>'account_number');
        IF v_learn_no IS NOT NULL AND (v_acct.account_number IS NOT NULL OR EXISTS (
               SELECT 1 FROM finance.accounts a WHERE a.account_number = v_learn_no AND a.status = 'active')) THEN
            v_learn_no := NULL;   -- schon bekannt oder bei einem anderen Konto vergeben -> nichts lernen
        END IF;
    ELSE
        SELECT * INTO v_res FROM finance.fn_resolve_account_by_number(p->>'account_number');
        IF v_res.id IS NULL THEN
            -- Neues Konto (Owner-Befund 2026-10-23): den gedruckten Endsaldo + Stichtag mitgeben, damit das Konto in
            -- EINEM Schritt mit Saldo angelegt wird - aber nur, wenn die Saldo-Probe stimmt und der Zeitraum
            -- abgeschlossen ist (nie einen verlesenen oder vorlaeufigen Saldo als Startsaldo anbieten).
            v_balance_ok := v_balance_ok AND v_pe <= core.fn_today();   -- gleiche Grenze wie fn_create_account
            RETURN jsonb_build_object('ok', false,
                'code', CASE WHEN v_res.hit_count > 1 THEN 'account_ambiguous' ELSE 'account_unknown' END,
                'reason', 'No account with the printed account number is known yet - ask the user which account this statement belongs to.',
                'account_number', finance.fn_normalize_account_number(p->>'account_number'),
                'candidates', v_res.candidates,
                'balance_verified', v_balance_ok)
                || CASE WHEN v_balance_ok THEN jsonb_build_object(
                       'closing_balance', v_close,
                       'balance_date', v_pe,
                       'currency', COALESCE(finance.fn_normalize_currency(NULLIF(p->>'currency', '')), 'EUR'))
                   ELSE '{}'::jsonb END;
        END IF;
        SELECT * INTO v_acct FROM finance.accounts WHERE id = v_res.id;
    END IF;
    END IF;   -- Ende gedruckter Auszug (1.)

    v_reason := finance.fn_bookable_account_reason(v_acct.id);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_bookable', 'reason', v_reason);
    END IF;
    IF NOT v_csv AND NULLIF(p->>'currency', '') IS NOT NULL AND upper(p->>'currency') <> v_acct.currency THEN
        RETURN jsonb_build_object('ok', false, 'code', 'currency_mismatch',
            'reason', 'The statement is in ' || upper(p->>'currency') || ' but the account "' || v_acct.name
                   || '" is kept in ' || v_acct.currency || '.');
    END IF;
    IF v_pe > core.fn_today() THEN
        RETURN jsonb_build_object('ok', false, 'code', 'period_in_future',
            'reason', 'The statement period ends in the future (' || v_pe || ').');
    END IF;
    IF v_acct.last_reconciled_at IS NOT NULL AND v_acct.last_reconciled_at >= v_pe THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_covered',
            'reason', 'The balance of "' || v_acct.name || '" is already confirmed up to ' || v_acct.last_reconciled_at
                   || ' - this statement adds nothing new.');
    END IF;
    IF EXISTS (SELECT 1 FROM finance.bank_statements WHERE account_id = v_acct.id AND period_end = v_pe) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_imported',
            'reason', 'A statement for "' || v_acct.name || '" ending ' || v_pe || ' was already imported.');
    END IF;

    IF NOT v_balance_ok THEN
        RETURN jsonb_build_object('ok', false, 'code', 'balance_check_failed',
            'difference', v_close - (v_open + v_sum),
            'reason', 'Opening balance plus all lines does not give the closing balance (difference '
                   || (v_close - (v_open + v_sum)) || ') - a line was probably misread.');
    END IF;

    -- ---------- 2. Schnitt + Abweichung vor dem Zeitraum ----------
    v_cut := GREATEST(v_ps - 1, v_acct.last_reconciled_at, v_acct.opening_balance_date);
    IF v_cut >= v_pe THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_covered',
            'reason', 'The balance of "' || v_acct.name || '" is already confirmed up to ' || v_cut || '.');
    END IF;
    SELECT v_open + COALESCE(sum(round((l->>'amount')::numeric, 2)), 0) INTO v_stmt_cut
    FROM jsonb_array_elements(v_lines) l WHERE (l->>'date')::date <= v_cut;
    v_drift := v_stmt_cut - finance.fn_get_balance_as_of(v_acct.id, v_cut);
    v_gap   := v_acct.last_reconciled_at IS NOT NULL AND v_acct.last_reconciled_at < v_ps - 1;

    -- ---------- 3. Zuordnung + Anreicherung ----------
    v_match := finance.fn_statement_match(v_acct.id, v_cut, v_pe, v_lines);
    v_out := (v_match->>'unmatched_out')::numeric;
    v_in  := (v_match->>'unmatched_in')::numeric;

    FOR v_m IN SELECT e FROM jsonb_array_elements(v_match->'matched') e LOOP
        IF v_m->>'kind' = 'booked' THEN
            v_booked := v_booked || v_m;
            CONTINUE;
        END IF;
        v_kind := v_m->>'kind';
        IF v_kind = 'recurring' THEN
            v_head := finance.fn_recurring_lineage_head((v_m->>'recurring_payment_id')::int);
            SELECT * INTO v_plan FROM finance.savings_plans WHERE recurring_payment_id = v_head;
            IF FOUND AND v_lines->((v_m->>'line_idx')::int - 1)->>'shares' IS NOT NULL THEN
                -- Broker-CSV: exakte Stueck + Kurs aus dem Export (Stueckpreis aus dem Kurswert, Karte = Buchung)
                v_kind   := 'savings_plan';
                v_line   := v_lines->((v_m->>'line_idx')::int - 1);
                v_shares := (v_line->>'shares')::numeric;
                v_m := v_m || jsonb_build_object('kind', 'savings_plan', 'shares', v_shares,
                         'price_per_share', finance.fn_unit_price_from_total((v_line->>'gross')::numeric, v_shares),
                         'order_fee', COALESCE((v_line->>'fee')::numeric, 0), 'shares_estimated', false);
            ELSIF FOUND THEN
                v_kind := 'savings_plan';
                SELECT mp.price, mp.currency INTO v_price, v_pccy
                FROM finance.market_prices mp
                WHERE mp.symbol = v_plan.symbol AND abs(mp.as_of - (v_m->>'line_date')::date) <= 3
                ORDER BY abs(mp.as_of - (v_m->>'line_date')::date), mp.as_of DESC LIMIT 1;
                IF v_price IS NOT NULL AND v_pccy IS DISTINCT FROM (SELECT currency FROM finance.accounts WHERE id = v_plan.depot_id) THEN
                    -- Stueckpreis ungerundet umrechnen (Cent-Rundung machte 0.20 USD zu 0.19 EUR) und auf die
                    -- Spaltenpraezision 8 runden, wie fn_book_stock_buy (Karte = Buchung)
                    v_price := CASE WHEN (SELECT currency FROM finance.accounts WHERE id = v_plan.depot_id) = 'EUR'
                                    THEN round(finance.fn_to_eur_unrounded(v_price, v_pccy, (v_m->>'line_date')::date), 8) END;
                END IF;
                IF v_price IS NULL OR v_price <= 0 THEN
                    v_pending := v_pending || v_m;
                    v_out := v_out + LEAST((v_m->>'amount')::numeric, 0);
                    CONTINUE;
                END IF;
                v_shares := trunc(abs((v_m->>'amount')::numeric) / v_price, 8);
                v_m := v_m || jsonb_build_object('kind', 'savings_plan', 'shares', v_shares, 'price_per_share', v_price,
                         'order_fee', abs((v_m->>'amount')::numeric) - round(v_shares * v_price, 2), 'shares_estimated', true);
            ELSE
                SELECT * INTO v_loan FROM finance.loans WHERE recurring_payment_id = v_head;
                IF FOUND THEN
                    v_kind := 'loan';
                    v_split := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id', v_loan.id,
                        'payment_amount', abs((v_m->>'amount')::numeric), 'payment_date', v_m->>'line_date',
                        'due_date', v_m->>'due_date', 'recurring_payment_id', v_m->>'recurring_payment_id'));
                    IF (v_split->>'ok')::boolean IS DISTINCT FROM true THEN
                        v_blocked := v_blocked || v_m;
                        v_out := v_out + LEAST((v_m->>'amount')::numeric, 0);
                        CONTINUE;
                    END IF;
                    v_m := v_m || jsonb_build_object('kind', 'loan');
                END IF;
                -- Transfer: das Gegenkonto darf am Zeilendatum nicht schon abgeglichen sein (sonst doppelt dort)
                SELECT CASE WHEN r.account_id = v_acct.id THEN r.target_account_id ELSE r.account_id END INTO v_other
                FROM finance.recurring_payments r WHERE r.id = (v_m->>'recurring_payment_id')::int;
                IF v_other IS NOT NULL AND finance.fn_reconciled_reason(v_other, (v_m->>'line_date')::date) IS NOT NULL THEN
                    v_blocked := v_blocked || v_m;
                    v_out := v_out + LEAST((v_m->>'amount')::numeric, 0);
                    v_in  := v_in + GREATEST((v_m->>'amount')::numeric, 0);
                    CONTINUE;
                END IF;
                -- Plan-Anpassung: nur einfache Dauerauftraege (Quelle, kein Transfer, keine Besitzer-Entitaet)
                IF v_kind = 'recurring' AND v_m->>'side' = 'source' AND v_other IS NULL
                   AND abs((v_m->>'amount')::numeric - (v_m->>'expected')::numeric) > 0.005
                   AND NOT EXISTS (SELECT 1 FROM finance.savings_goals g WHERE g.recurring_payment_id = v_head)
                   AND NOT EXISTS (SELECT 1 FROM finance.insurances i WHERE i.recurring_payment_id = v_head)
                   AND NOT EXISTS (SELECT 1 FROM finance.pension pe WHERE pe.recurring_payment_id = v_head) THEN
                    v_m := v_m || jsonb_build_object('adjust_head', v_head);   -- Kandidat; entschieden nach der Schleife
                END IF;
            END IF;
            IF v_m->>'learn_mandate' IS NOT NULL THEN
                v_learn := v_learn || jsonb_build_object('recurring_payment_id', (v_m->>'recurring_payment_id')::int,
                    'key_type', 'sepa_mandate', 'key_value', v_m->>'learn_mandate');
            END IF;
            IF v_m->>'learn_iban' IS NOT NULL THEN
                v_learn := v_learn || jsonb_build_object('recurring_payment_id', (v_m->>'recurring_payment_id')::int,
                    'key_type', 'counterparty_iban', 'key_value', v_m->>'learn_iban');
            END IF;
        END IF;
        v_to_book := v_to_book || v_m;
        v_book_sum := v_book_sum + (v_m->>'amount')::numeric;
    END LOOP;

    -- ---------- 3b. Broker-CSV: Wertpapier-Zeilen ohne Dauerauftrags-Treffer ----------
    --   Position = Holding eines Depots mit diesem Verrechnungskonto (ISIN, Krypto per Symbol). Stufe 0: gebuchter
    --   Kauf/Verkauf (gleiche Stueck) bzw. Dividende (gleicher Betrag) derselben Position +-5 Tage -> already_booked.
    --   Sonst bucht apply aus den Export-Werten (Kurs aus dem Kurswert via fn_unit_price_from_total) -> trades.
    --   Nicht buchbar (trades_blocked): Kauf, der noch in einer Bestandsuebernahme derselben Position steckt
    --   (covered_by_takeover: erst die Einzelkaeufe uebernehmen), Verkauf ueber den Bestand (oversell), unbekannte
    --   Position bei Verkauf/Dividende bzw. kein eindeutiges Depot beim Kauf (security_unknown).
    --   Wertpapier-Geldfluesse (Kauf/Verkauf/Dividende/Steuer/Kapitalmassnahme) zaehlen nie in unmatched_out/in.
    IF v_csv THEN
        FOR v_line, v_idx IN SELECT e, (o)::int FROM jsonb_array_elements(v_lines) WITH ORDINALITY AS x(e, o)
                             WHERE (o)::int IN (SELECT (u)::int FROM jsonb_array_elements_text(v_match->'unmatched') u) LOOP
            IF v_line->>'kind' IN ('buy', 'sell', 'dividend', 'tax', 'corporate') THEN
                v_out := v_out - LEAST((v_line->>'amount')::numeric, 0);
                v_in  := v_in - GREATEST((v_line->>'amount')::numeric, 0);
            END IF;
            CONTINUE WHEN v_line->>'kind' NOT IN ('buy', 'sell', 'dividend');

            SELECT count(*) OVER () AS n, h.id, h.account_id AS depot_id, h.shares, h.name, h.symbol INTO v_hold
            FROM finance.depot_holdings h JOIN finance.accounts d ON d.id = h.account_id
            WHERE d.settlement_account_id = v_acct.id AND d.status = 'active'
              AND (upper(h.isin) = v_line->>'isin'
                   OR (v_line->>'isin' IS NULL AND h.isin IS NULL AND upper(h.symbol) = upper(v_line->>'symbol')))
            ORDER BY h.id LIMIT 1;
            v_hcount := COALESCE(v_hold.n, 0);

            v_tx_id := NULL;
            IF v_hcount = 1 THEN
                SELECT t.id, t.transaction_date, t.amount INTO v_tx_id, v_tx_date, v_tx_amt
                FROM finance.transactions t
                WHERE t.account_id = v_acct.id AND t.holding_id = v_hold.id AND t.category::text = v_line->>'kind'
                  AND t.transaction_date <= v_pe + 5   -- auch vor dem Schnitt: von Hand gebucht, Export bucht spaeter
                  AND abs(t.transaction_date - (v_line->>'booking_date')::date) <= 5
                  AND NOT (t.id = ANY(v_used_tx))
                  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_booked) b WHERE (b->>'transaction_id')::int = t.id)
                  AND CASE WHEN v_line->>'kind' = 'dividend' THEN t.amount = (v_line->>'amount')::numeric
                           ELSE abs(t.shares) = (v_line->>'shares')::numeric END
                ORDER BY abs(t.transaction_date - (v_line->>'booking_date')::date), t.id LIMIT 1;
            END IF;
            IF v_tx_id IS NOT NULL THEN
                v_used_tx := v_used_tx || v_tx_id;
                v_booked := v_booked || jsonb_build_object('kind', 'booked', 'trade', true, 'line_idx', v_idx,
                    'transaction_id', v_tx_id, 'tx_date', v_tx_date, 'line_date', v_line->>'date',
                    'amount', v_tx_amt, 'name', v_hold.name);
                CONTINUE;
            END IF;

            v_reason := NULL;
            v_depot := v_hold.depot_id;
            -- frueherer Kauf DERSELBEN Position in diesem Export (gebuchter Sparplan-Treffer oder Kauf aus trades[]):
            -- Stueck fuer den Verkaufs-Check; ohne Holding bucht apply Verkauf/Dividende auf die dann angelegte Position
            SELECT COALESCE(sum((v_lines->((m->>'line_idx')::int - 1)->>'shares')::numeric), 0) INTO v_avail
            FROM jsonb_array_elements(v_to_book) m
            WHERE m->>'kind' = 'savings_plan'
              AND (m->>'line_date')::date <= (v_line->>'date')::date
              AND (v_lines->((m->>'line_idx')::int - 1)->>'isin' = v_line->>'isin'
                   OR (v_line->>'isin' IS NULL AND v_lines->((m->>'line_idx')::int - 1)->>'isin' IS NULL
                       AND upper(v_lines->((m->>'line_idx')::int - 1)->>'symbol') = upper(v_line->>'symbol')));
            SELECT v_avail
                   + COALESCE(sum((x->>'shares')::numeric) FILTER (WHERE x->>'kind' = 'buy'), 0)
                   - COALESCE(sum((x->>'shares')::numeric) FILTER (WHERE x->>'kind' = 'sell'), 0)
            INTO v_avail FROM jsonb_array_elements(v_trades) x
            WHERE x->>'isin' = v_line->>'isin'
               OR (v_line->>'isin' IS NULL AND x->>'isin' IS NULL AND upper(x->>'symbol') = upper(v_line->>'symbol'));
            IF v_hcount > 1 THEN
                v_reason := 'security_unknown';
            ELSIF v_line->>'kind' = 'buy' THEN
                IF v_hcount = 0 THEN
                    -- neue Position: das EINE aktive Depot dieses Verrechnungskontos der passenden Art (Krypto ohne ISIN)
                    SELECT CASE WHEN count(*) = 1 THEN min(d.id) END INTO v_depot
                    FROM finance.accounts d WHERE d.settlement_account_id = v_acct.id AND d.status = 'active'
                      AND d.account_type::text = CASE WHEN v_line->>'isin' IS NULL THEN 'crypto_depot' ELSE 'stocks_depot' END;
                    IF v_depot IS NULL THEN v_reason := 'security_unknown'; END IF;
                ELSIF EXISTS (SELECT 1 FROM finance.transactions t
                              WHERE t.holding_id = v_hold.id AND t.category::text = 'buy'
                                AND t.transaction_date >= (v_line->>'booking_date')::date
                                AND EXISTS (SELECT 1 FROM finance.transactions g
                                            WHERE g.group_id = t.group_id AND g.category::text = 'position_takeover')) THEN
                    v_reason := 'covered_by_takeover';
                END IF;
            ELSIF v_hcount = 0 AND v_avail <= 0 THEN
                v_reason := 'security_unknown';
            ELSIF v_line->>'kind' = 'sell' AND COALESCE(v_hold.shares, 0) + v_avail < (v_line->>'shares')::numeric THEN
                v_reason := 'oversell';
            ELSIF v_line->>'kind' = 'dividend' AND (v_line->>'amount')::numeric <= 0 THEN
                v_reason := 'security_unknown';
            END IF;
            IF v_reason IS NOT NULL THEN
                v_tblocked := v_tblocked || jsonb_build_object('line_idx', v_idx, 'kind', v_line->>'kind', 'reason', v_reason,
                    'name', COALESCE(v_line->>'name', v_line->>'isin', v_line->>'symbol'), 'amount', (v_line->>'amount')::numeric,
                    'line_date', v_line->>'date');
                CONTINUE;
            END IF;

            -- Kauf/Verkauf ohne Steuer (die Buch-fns kennen keine), die einbehaltene Steuer als eigene Buchung (tax);
            -- Dividende netto (amount = Cash-Wirkung inkl. Steuer)
            v_price := finance.fn_unit_price_from_total((v_line->>'gross')::numeric, (v_line->>'shares')::numeric);
            v_tamt := CASE v_line->>'kind'
                WHEN 'buy'  THEN -(round((v_line->>'shares')::numeric * v_price, 2) + (v_line->>'fee')::numeric)
                WHEN 'sell' THEN round((v_line->>'shares')::numeric * v_price, 2) - (v_line->>'fee')::numeric
                ELSE (v_line->>'amount')::numeric END;
            v_ttax := CASE WHEN v_line->>'kind' IN ('buy', 'sell') THEN round(COALESCE((v_line->>'tax')::numeric, 0), 2) ELSE 0 END;
            v_trades := v_trades || jsonb_build_object('line_idx', v_idx, 'kind', v_line->>'kind',
                'holding_id', CASE WHEN v_hcount = 1 THEN v_hold.id END, 'depot_id', v_depot,
                'isin', v_line->>'isin', 'symbol', COALESCE(v_hold.symbol, v_line->>'symbol'),
                'name', COALESCE(v_hold.name, v_line->>'name', v_line->>'symbol'),
                'shares', CASE WHEN v_line->>'kind' <> 'dividend' THEN (v_line->>'shares')::numeric END,
                'price_per_share', CASE WHEN v_line->>'kind' <> 'dividend' THEN v_price END,
                'order_fee', CASE WHEN v_line->>'kind' <> 'dividend' THEN (v_line->>'fee')::numeric END,
                'tax', v_ttax, 'date', v_line->>'date', 'amount', v_tamt);
            v_book_sum := v_book_sum + v_tamt + v_ttax;
        END LOOP;
    END IF;

    -- Plan-Anpassung beim 2. gleichen Ist-Betrag: Vorgaenger = juengere Buchung der Kette ODER ein frueheres Vorkommen
    -- derselben Kette in DIESEM Auszug. Je Kette hoechstens EINE Anpassung (die spaeteste Faelligkeit): sonst laege eine
    -- in diesem Auszug gebuchte Faelligkeit hinter eff_from und fn_split_recurring_payment lehnte ab (Review-Befund).
    FOR v_m IN SELECT e FROM jsonb_array_elements(v_to_book) e WHERE e ? 'adjust_head'
               ORDER BY (e->>'due_date')::date DESC LOOP
        CONTINUE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(v_adjust) a WHERE (a->>'head')::int = (v_m->>'adjust_head')::int);
        SELECT x.amt INTO v_last_amt FROM (
            SELECT t.amount AS amt, t.recurring_due_date AS due FROM finance.transactions t
            WHERE t.recurring_payment_id IN (SELECT finance.fn_recurring_lineage((v_m->>'recurring_payment_id')::int))
              AND t.recurring_due_date < (v_m->>'due_date')::date
            UNION ALL
            SELECT (b->>'amount')::numeric, (b->>'due_date')::date FROM jsonb_array_elements(v_to_book) b
            WHERE (b->>'adjust_head')::int = (v_m->>'adjust_head')::int AND (b->>'due_date')::date < (v_m->>'due_date')::date
        ) x ORDER BY x.due DESC LIMIT 1;
        IF v_last_amt = (v_m->>'amount')::numeric THEN
            v_adjust := v_adjust || jsonb_build_object('head', (v_m->>'adjust_head')::int,
                'recurring_payment_id', (v_m->>'recurring_payment_id')::int,
                'name', v_m->>'name', 'eff_from', ((v_m->>'due_date')::date + 1),
                'amount', (v_m->>'amount')::numeric, 'planned', (v_m->>'expected')::numeric);
        END IF;
        v_last_amt := NULL;
    END LOOP;

    -- Schon gebuchte Zahlung mit Buchungsdatum NACH dem Auszugsende (z. B. am 02.10. bestaetigt, laut Auszug am 30.09.
    -- abgegangen): apply verschiebt sie auf das Zeilendatum; hier zaehlt sie schon zum Stand am period_end, sonst landete
    -- sie zusaetzlich im Rest (doppelt). fn_statement_match liefert nur verschiebbare (kein Bein-Konto abgeglichen).
    SELECT COALESCE(sum((b->>'amount')::numeric), 0) INTO v_redate_sum
    FROM jsonb_array_elements(v_booked) b WHERE (b->>'tx_date')::date > v_pe;

    -- ---------- 4. fehlende Zahlungen, unbekannte Mandate ----------
    SELECT COALESCE(jsonb_agg(jsonb_build_object('recurring_payment_id', o.recurring_payment_id, 'name', r.name,
               'due_date', o.due_date,
               'amount', CASE WHEN r.account_id = v_acct.id
                              THEN COALESCE(finance.fn_recurring_occurrence_amount(r.id, o.due_date), r.amount)
                              ELSE abs(r.amount) END) ORDER BY o.due_date, r.name), '[]'::jsonb)
    INTO v_missing
    FROM finance.fn_reconcile_open_due(v_acct.id, v_pe) o   -- dieselbe Menge, die der Abgleich ueberspringt (eine Adresse)
    JOIN finance.recurring_payments r ON r.id = o.recurring_payment_id
    WHERE o.recurring_payment_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_to_book || v_blocked || v_pending) b
                      WHERE (b->>'recurring_payment_id')::int = o.recurring_payment_id
                        AND (b->>'due_date')::date = o.due_date);

    SELECT COALESCE(jsonb_agg(jsonb_build_object('name', COALESCE(NULLIF(o.l->>'counterparty', ''), o.l->>'purpose'),
               'amount', round((o.l->>'amount')::numeric, 2), 'date', (o.l->>'date')::date) ORDER BY o.ord), '[]'::jsonb)
    INTO v_unknown
    FROM jsonb_array_elements(v_lines) WITH ORDINALITY AS o(l, ord)
    WHERE (o.ord)::int IN (SELECT (x)::int FROM jsonb_array_elements_text(v_match->'unmatched') x)
      AND (o.l->>'amount')::numeric < 0
      AND NULLIF(trim(o.l->>'creditor_id'), '') IS NOT NULL AND NULLIF(trim(o.l->>'mandate_ref'), '') IS NOT NULL;

    -- ---------- 5. Rest als DB-Differenz ----------
    v_s_end := finance.fn_get_balance_as_of(v_acct.id, v_pe);
    v_lump  := v_close - (v_s_end + v_drift + v_book_sum + v_redate_sum);

    -- ---------- 6. Kartenzeilen (Struktur, je Empfaenger gerendert) ----------
    v_card := jsonb_build_array(
        core.fn_ui_tpl('finance.tpl.statement_period', jsonb_build_object('from', core.fn_ui_date(v_ps), 'to', core.fn_ui_date(v_pe)))
            || jsonb_build_object('label', 'finance.label.statement_period'))
        || CASE WHEN v_csv THEN jsonb_build_array(
               core.fn_ui_money(v_owner, v_acct.currency) || jsonb_build_object('label', 'finance.label.statement_owner_balance'))
               || CASE WHEN v_after <> 0 THEN jsonb_build_array(jsonb_build_object('kind', 'note',
                      'value', 'finance.note.statement_after_period',
                      'params', jsonb_build_object('amount', core.fn_ui_money(v_after, v_acct.currency, true),
                                                   'date', core.fn_ui_date(v_pe)))) ELSE '[]'::jsonb END
           ELSE jsonb_build_array(
               core.fn_ui_money(v_open, v_acct.currency) || jsonb_build_object('label', 'finance.label.statement_opening'),
               core.fn_ui_money(v_close, v_acct.currency) || jsonb_build_object('label', 'finance.label.statement_closing')) END;
    IF v_drift <> 0 THEN
        v_card := v_card || jsonb_build_array(
            core.fn_ui_money(v_drift, v_acct.currency) || jsonb_build_object('label', 'finance.label.statement_drift'),
            jsonb_build_object('kind', 'note', 'value', 'finance.note.statement_drift'));
    END IF;
    IF jsonb_array_length(v_to_book) > 0 THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'heading', 'label', 'finance.label.statement_matched'))
            || (SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    CASE WHEN m->>'kind' = 'savings_plan' AND NOT (m->>'shares_estimated')::boolean
                         THEN core.fn_ui_tpl('finance.tpl.statement_savings_plan_row_exact', jsonb_build_object('name', m->>'name',
                                  'amount', core.fn_ui_money((m->>'amount')::numeric, v_acct.currency),
                                  'shares', core.fn_ui_num((m->>'shares')::numeric, 8),
                                  'date', core.fn_ui_date((m->>'line_date')::date)))
                         WHEN m->>'kind' = 'savings_plan'
                         THEN core.fn_ui_tpl('finance.tpl.statement_savings_plan_row', jsonb_build_object('name', m->>'name',
                                  'amount', core.fn_ui_money((m->>'amount')::numeric, v_acct.currency),
                                  'shares', core.fn_ui_num((m->>'shares')::numeric, 4),
                                  'date', core.fn_ui_date((m->>'line_date')::date)))
                         WHEN m->>'learn_mandate' IS NOT NULL OR m->>'learn_iban' IS NOT NULL
                         THEN core.fn_ui_tpl('finance.tpl.statement_matched_row_new', jsonb_build_object('name', m->>'name',
                                  'amount', core.fn_ui_money((m->>'amount')::numeric, v_acct.currency),
                                  'date', core.fn_ui_date((m->>'line_date')::date)))
                         ELSE core.fn_ui_tpl('finance.tpl.statement_matched_row', jsonb_build_object('name', m->>'name',
                                  'amount', core.fn_ui_money((m->>'amount')::numeric, v_acct.currency),
                                  'date', core.fn_ui_date((m->>'line_date')::date))) END)
                  ORDER BY (m->>'line_date')::date, m->>'name') FROM jsonb_array_elements(v_to_book) m);
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_to_book) m
               WHERE m->>'kind' <> 'savings_plan' AND abs((m->>'amount')::numeric - (m->>'expected')::numeric) > 0.005) THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'heading', 'label', 'finance.label.statement_changed'))
            || (SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    core.fn_ui_tpl('finance.tpl.statement_changed_row', jsonb_build_object('name', m->>'name',
                        'amount', core.fn_ui_money(abs((m->>'amount')::numeric), v_acct.currency),
                        'planned', core.fn_ui_money(abs((m->>'expected')::numeric), v_acct.currency)))) ORDER BY m->>'name')
                FROM jsonb_array_elements(v_to_book) m
                WHERE m->>'kind' <> 'savings_plan' AND abs((m->>'amount')::numeric - (m->>'expected')::numeric) > 0.005);
    END IF;
    IF jsonb_array_length(v_adjust) > 0 THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'heading', 'label', 'finance.label.statement_plan_adjust'))
            || (SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    core.fn_ui_tpl('finance.tpl.statement_plan_adjust_row', jsonb_build_object('name', a->>'name',
                        'amount', core.fn_ui_money(abs((a->>'amount')::numeric), v_acct.currency),
                        'date', core.fn_ui_date((a->>'eff_from')::date)))) ORDER BY a->>'name')
                FROM jsonb_array_elements(v_adjust) a);
    END IF;
    IF jsonb_array_length(v_booked) > 0 THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'heading', 'label', 'finance.label.statement_booked'))
            || (SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    core.fn_ui_tpl('finance.tpl.statement_matched_row', jsonb_build_object('name', m->>'name',
                        'amount', core.fn_ui_money((m->>'amount')::numeric, v_acct.currency),
                        'date', core.fn_ui_date((m->>'line_date')::date)))) ORDER BY (m->>'line_date')::date)
                FROM jsonb_array_elements(v_booked) m);
    END IF;
    IF jsonb_array_length(v_missing) > 0 THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'heading', 'label', 'finance.label.statement_missing'))
            || (SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    core.fn_ui_tpl('finance.tpl.statement_missing_row', jsonb_build_object('name', x->>'name',
                        'amount', core.fn_ui_money(abs((x->>'amount')::numeric), v_acct.currency),
                        'date', core.fn_ui_date((x->>'due_date')::date)))) ORDER BY (x->>'due_date')::date)
                FROM jsonb_array_elements(v_missing) x);
    END IF;
    IF jsonb_array_length(v_blocked || v_pending) > 0 THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'heading', 'label', 'finance.label.statement_not_booked'))
            || (SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    core.fn_ui_tpl('finance.tpl.statement_matched_row', jsonb_build_object('name', m->>'name',
                        'amount', core.fn_ui_money((m->>'amount')::numeric, v_acct.currency),
                        'date', core.fn_ui_date((m->>'line_date')::date)))) ORDER BY (m->>'line_date')::date)
                FROM jsonb_array_elements(v_blocked || v_pending) m);
    END IF;
    IF jsonb_array_length(v_unknown) > 0 THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'heading', 'label', 'finance.label.statement_unknown'))
            || (SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    core.fn_ui_tpl('finance.tpl.statement_matched_row', jsonb_build_object('name', u->>'name',
                        'amount', core.fn_ui_money((u->>'amount')::numeric, v_acct.currency),
                        'date', core.fn_ui_date((u->>'date')::date)))))
                FROM jsonb_array_elements(v_unknown) u);
    END IF;
    -- Broker-CSV: Wertpapier-Buchungen aus dem Export, nicht buchbare Wertpapier-Zeilen, unbekannte Export-Zeilen
    IF jsonb_array_length(v_trades) > 0 THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'heading', 'label', 'finance.label.statement_trades'))
            || (SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    CASE WHEN x->>'kind' = 'dividend'
                         THEN core.fn_ui_tpl('finance.tpl.statement_dividend_row', jsonb_build_object('name', x->>'name',
                                  'amount', core.fn_ui_money((x->>'amount')::numeric, v_acct.currency),
                                  'date', core.fn_ui_date((x->>'date')::date)))
                         ELSE core.fn_ui_tpl('finance.tpl.statement_trade_row', jsonb_build_object(
                                  'what', CASE x->>'kind' WHEN 'buy' THEN core.fn_ui_tpl('finance.tpl.statement_trade_buy', '{}'::jsonb)
                                                          ELSE core.fn_ui_tpl('finance.tpl.statement_trade_sell', '{}'::jsonb) END,
                                  'name', x->>'name',
                                  'shares', core.fn_ui_num((x->>'shares')::numeric, 8),
                                  'amount', core.fn_ui_money((x->>'amount')::numeric, v_acct.currency),
                                  'date', core.fn_ui_date((x->>'date')::date))) END) ORDER BY (x->>'date')::date, (x->>'line_idx')::int)
                FROM jsonb_array_elements(v_trades) x)
            || COALESCE((SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    core.fn_ui_tpl('finance.tpl.statement_trade_tax_row', jsonb_build_object('name', x->>'name',
                        'amount', core.fn_ui_money((x->>'tax')::numeric, v_acct.currency),
                        'date', core.fn_ui_date((x->>'date')::date)))) ORDER BY (x->>'date')::date, (x->>'line_idx')::int)
                FROM jsonb_array_elements(v_trades) x WHERE (x->>'tax')::numeric <> 0), '[]'::jsonb);
    END IF;
    IF jsonb_array_length(v_tblocked) > 0 THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'heading', 'label', 'finance.label.statement_trades_blocked'))
            || (SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    core.fn_ui_tpl('finance.tpl.statement_trade_blocked_row', jsonb_build_object('name', x->>'name',
                        'amount', core.fn_ui_money((x->>'amount')::numeric, v_acct.currency),
                        'date', core.fn_ui_date((x->>'line_date')::date),
                        'why', CASE x->>'reason'
                                   WHEN 'covered_by_takeover' THEN core.fn_ui_tpl('finance.tpl.statement_trade_covered_by_takeover', '{}'::jsonb)
                                   WHEN 'oversell' THEN core.fn_ui_tpl('finance.tpl.statement_trade_oversell', '{}'::jsonb)
                                   ELSE core.fn_ui_tpl('finance.tpl.statement_trade_security_unknown', '{}'::jsonb) END)))
                  ORDER BY (x->>'line_date')::date, (x->>'line_idx')::int)
                FROM jsonb_array_elements(v_tblocked) x);
    END IF;
    IF jsonb_array_length(v_csv_unk) > 0 THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'heading', 'label', 'finance.label.statement_csv_unknown'))
            || (SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    core.fn_ui_tpl('finance.tpl.statement_csv_unknown_row', jsonb_build_object(
                        'name', COALESCE(u->>'name', u->>'type'), 'type', u->>'type',
                        'amount', core.fn_ui_money((u->>'cash_amount')::numeric, v_acct.currency),
                        'date', core.fn_ui_date((u->>'date')::date)))) ORDER BY (u->>'row_no')::int)
                FROM jsonb_array_elements(v_csv_unk) u);
    END IF;
    v_card := v_card || jsonb_build_array(
        core.fn_ui_money(v_lump, v_acct.currency) || jsonb_build_object('label', 'finance.label.statement_everyday'),
        jsonb_build_object('kind', 'note', 'value', 'finance.note.statement_lump'));
    -- S7: die IBAN, die dieser Auszug dem Konto beibringt, steht sichtbar auf der Karte (Kontrolle durch den Nutzer)
    IF v_learn_no IS NOT NULL THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'finance.note.iban_learned',
                      'params', jsonb_build_object('iban', v_learn_no)));
    END IF;

    v_fp := md5(jsonb_build_object('a', v_acct.id, 'c', v_cut, 'd', v_drift, 's', v_s_end, 'l', v_lump,
                  'b', (SELECT jsonb_agg(jsonb_build_array(m->>'kind', m->>'recurring_payment_id', m->>'due_date',
                               m->>'interest_period_end', m->>'line_idx', m->>'amount')) FROM jsonb_array_elements(v_to_book) m),
                  'p', v_adjust, 'k', v_learn, 'n', v_learn_no, 'm', v_missing, 't', v_trades, 'x', v_tblocked,
                  'r', (SELECT jsonb_agg(jsonb_build_array(b->>'transaction_id', b->>'line_date')) FROM jsonb_array_elements(v_booked) b
                        WHERE (b->>'tx_date')::date > v_pe))::text);

    RETURN jsonb_build_object('ok', true,
        'account_id', v_acct.id, 'account_name', v_acct.name, 'currency', v_acct.currency,
        'period_start', v_ps, 'period_end', v_pe, 'opening_balance', v_open, 'closing_balance', v_close,
        'cut', v_cut, 'stmt_at_cut', v_stmt_cut, 'drift', v_drift, 'gap', v_gap,
        'matched', v_to_book, 'already_booked', v_booked, 'blocked', v_blocked, 'savings_plan_pending', v_pending,
        'missing', v_missing, 'unknown_mandates', v_unknown, 'plan_adjustments', v_adjust, 'learn', v_learn,
        'learned_account_number', v_learn_no,
        'line_count', jsonb_array_length(v_lines),
        'matched_count', jsonb_array_length(v_to_book) + jsonb_array_length(v_booked),
        'unmatched_out', v_out, 'unmatched_in', v_in,
        'lump', v_lump, 'card_lines', v_card, 'fingerprint', v_fp,
        'source', CASE WHEN v_csv THEN 'csv' ELSE 'printed' END,
        'balance_source', CASE WHEN v_csv THEN 'owner' ELSE 'printed' END)
        || CASE WHEN v_csv THEN jsonb_build_object(
               'owner_balance', v_owner, 'after_period', v_after,
               'trades', v_trades, 'trades_blocked', v_tblocked, 'csv_unknown', v_csv_unk,
               'late_count', (SELECT count(*) FROM jsonb_array_elements(v_lines) l WHERE (l->>'late')::boolean),
               'seen_refs', (SELECT COALESCE(jsonb_agg(DISTINCT l->>'ext_ref'), '[]'::jsonb)
                             FROM jsonb_array_elements(v_lines) l WHERE l->>'ext_ref' IS NOT NULL))
           ELSE '{}'::jsonb END;
END;
$$;
