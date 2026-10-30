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
--   BANK-EXPORT-DATEI (source:'file', Bank-Import-Modul): Eingabe {source, account_name (optional), closing_balance = Kontostand laut App JETZT
--   (Pflicht), table:{rows} = Raster des Lesers}. fn_bank_export_normalize liest den Export (kein LLM); das Konto waehlt
--   fn_bank_export_resolve_account (Konto-Waechter: export_account_mismatch, ohne Namen Vorauswahl nach Bank-Profil;
--   closing_balance_required/no_starting_point tragen account_name); Zeitraum =
--   Schnitt+1 bis gestern (Schnitt = last_reconciled_at bzw. opening_balance_date, sonst no_starting_point); Stand am
--   period_end = closing_balance - Summe der Zeilen danach; Anfang daraus (keine Saldo-Probe, der drift zeigt einen
--   unvollstaendigen Export). Spaete Zeilen (Referenz-Hash im letzten CSV-Zeitraum nicht gesehen) zaehlen mit Datum
--   Schnitt+1. Sparplan-Treffer mit exakter Stueckzahl (shares_estimated false). Wertpapier-Zeilen ohne Treffer: Stufe 0
--   gegen gebuchte Trades, sonst trades[] (apply bucht fn_book_stock_buy/_sell/fn_book_dividend), nicht buchbar ->
--   trades_blocked[] (covered_by_takeover, oversell, security_unknown); unknown-Zeilen des Exports -> export_unknown[].
--   Review 2026-10-28: Steuer auf Kauf/Verkauf = eigene Buchung (trades[].tax, nie im Rest); Verkaufs-Check zaehlt
--   Sparplan-Kaeufe und Kaeufe DIESES Exports mit; Verkauf/Dividende einer erst im Export gekauften Position wird gebucht;
--   neue Position nur ins EINE Depot der passenden Art (Krypto ohne ISIN -> crypto_depot); Stufe 0 auch gegen eine von
--   Hand vor dem Schnitt datierte Buchung (+-5 Tage, nie doppelt); App-Kontostand ueber fn_parse_numeric_or_null.
--   Zusaetzliche codes: export_profile_unknown, export_invalid, closing_balance_required (keine Karte), no_starting_point,
--   multiple_sub_accounts, export_account_mismatch (+bank, account_name, candidates). Zusaetzliche Rueckgabe: source, balance_source (printed|owner), owner_balance, after_period,
--   trades, trades_blocked, export_unknown, late_count, seen_refs (Hashes fuer finance.statement_seen_refs).
--   BANK-IMPORT-MODUL (Transfers zwischen eigenen Konten, alle Wege): matched kind transfer (Stufe T, other_account_id)
--   -> apply bucht fn_book_transfer; nicht buchbar -> blocked[].reason not_bookable | currency_mismatch | pending_pair
--   (offener Transfer mit dem Gegenkonto +-5 Tage, den keine Zeile trifft: nie ein zweiter) | partner_reconciled (Gegenkonto
--   mehr als 5 Tage nach dem Zeilendatum abgeglichen); bis 5 Tage -> matched.partner_date = dessen Abgleich+1 (unterwegs).
--   moved_legs[] = Transfer-Beine dieses Kontos, die der Auszug eines ANDEREN Kontos in den letzten 5 Tagen gebucht
--   hat und die hier keine Zeile haben (unterwegs) -> zaehlen nicht zum Stand am period_end, apply setzt period_end+1.
--   Beides steht auf der Karte (Abschnitt "Unterwegs"). Rest-Label: cash "Alltagsausgaben" (Rest <= 0) bzw. "Ungeklaerter
--   Eingang" (Rest > 0), sonst "Sonstige Abweichung".
--   POOL-REGEL (Profil counterparty_pattern, Bondora): Geldzeile an/von einem Anbieter-Sammelkonto -> P2P-Konto des Profils,
--   nur buchbar und am Zeilendatum nicht abgeglichen (Eingang: Verrechnungskonto bzw. gleicher Inhaber ohne anderes
--   Verrechnungskonto, Gebuehr-Bein partner_fee beim P2P-Konto; Ausgang: Referenz = Kontonummer als ganzes Wort im
--   Verwendungszweck). GENAU eine Zeile mit zwei Kandidaten: Eingabe transfer_account (Kontoname laut Nutzer, 'none' =
--   keins); fehlt sie oder passt sie zu keinem -> {ok:false, code:'transfer_choice_required', candidates[2] (Namen, nach
--   id), amount, date} ohne Karte (der Agent fragt, Muster account_ambiguous; die Karte zeigt danach die Zuordnung).
--   Sonst (mehrere solche Zeilen, 0 oder 3+ Kandidaten, 'none') Rest + Hinweis (pool_unassigned = Anzahl).
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
    -- Bank-Export-Datei (Broker-CSV Paket B, Bank-Import-Modul)
    v_file      BOOLEAN := COALESCE(p->>'source', '') = 'file';
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
    v_file_unk  JSONB := '[]'::jsonb;
    -- Bank-Import-Modul
    v_moved    JSONB := '[]'::jsonb;
    v_partner_at DATE;
    v_printed_file BOOLEAN := false;   -- Datei mit gedrucktem Endstand (Profil printed_balance)
    v_int_lines NUMERIC := 0;          -- Summe der Zinszeilen (interest_line) im Zeitraum
    v_int_booked NUMERIC := 0;         -- Summe der Scheduler-Zinsbuchungen im Zeitraum
    v_int_corr NUMERIC := 0;           -- Zinskorrektur = Zeilen - gebucht (EINE Buchung)
    v_legacy   NUMERIC := 0;           -- Summe der Kleinbetraege (legacy_return, EINE Buchung)
    v_int_skips JSONB := '[]'::jsonb;  -- offene Zins-Vorkommen <= period_end (apply ueberspringt sie)
    v_legacy_label TEXT;
    v_pool_pr  JSONB;                  -- Profil mit counterparty_pattern (Pool-Regel)
    v_pool_c   JSONB;                  -- Kandidaten-Konten des Profils
    v_pool_pick JSONB;                 -- gewaehlte Kandidaten einer Zeile
    v_pool     JSONB := '[]'::jsonb;   -- Pool-Treffer (kind transfer, Stufe P)
    v_pool_amb JSONB := '[]'::jsonb;   -- Pool-Zeilen ohne Zuordnung (bleiben im Rest)
BEGIN
    -- ---------- 1a. Broker-CSV: Export normieren, Zeitraum = nach dem bestaetigten Tag bis gestern ----------
    --   Kein gedruckter Saldo: der Owner nennt den Kontostand aus der App (Pflicht, nie ein errechneter Saldo als
    --   bestaetigt). Stand am period_end = Owner-Zahl - Summe der Zeilen danach (Teil-Tag-Export bis heute). Anfang
    --   = dieser Stand - Summe der Zeitraum-Zeilen -> die Abweichung zum System am Schnitt ist der drift (Export
    --   unvollstaendig oder falsche Zahl), die Saldo-Probe entfaellt (fester Leser, keine Lesefehler).
    --   Spaete Zeilen: Datum im Zeitraum des letzten CSV-Abgleichs, Referenz dort nicht gesehen -> Datum = Schnitt+1.
    IF v_file THEN
        v_norm := finance.fn_bank_export_normalize(COALESCE(p->'table', '{}'::jsonb));
        IF (v_norm->>'ok')::boolean IS DISTINCT FROM true THEN
            RETURN v_norm;
        END IF;
        -- Konto-Waechter (Live-Befund 2026-10-30): Datei-Profil gegen Konto-Profil, ohne Namen Vorauswahl nach Bank
        v_m := finance.fn_bank_export_resolve_account(p->>'account_name', v_norm->>'profile', v_norm->'currencies');
        IF (v_m->>'ok')::boolean IS DISTINCT FROM true THEN
            RETURN v_m;
        END IF;
        SELECT * INTO v_acct FROM finance.accounts WHERE id = (v_m->>'account_id')::int;
        IF jsonb_array_length(v_norm->'account_types') > 1 THEN
            RETURN jsonb_build_object('ok', false, 'code', 'multiple_sub_accounts', 'account_types', v_norm->'account_types',
                'reason', 'The export mixes several sub-accounts (' || (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(v_norm->'account_types') x)
                       || ') - ask the user to export each account on its own.');
        END IF;
        IF (v_norm->>'printed_balance')::boolean THEN
        -- Profil mit gedrucktem Endstand (Bondora): Zeitraum + Anfangs-/Endstand aus der Datei = gedruckter Auszug
        -- (balance_source printed, kein Owner-Saldo). Zinszeilen (interest_line) und Kleinbetraege (legacy_return)
        -- laufen nicht durch die Zuordnung: sie werden je als EINE Summe gebucht (Schritt 3c).
        v_printed_file := true;
        v_ps    := (v_norm->'statement'->>'period_start')::date;
        v_pe    := (v_norm->'statement'->>'period_end')::date;
        v_open  := (v_norm->'statement'->>'opening_balance')::numeric;
        v_close := (v_norm->'statement'->>'closing_balance')::numeric;
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'date', (r->>'date')::date, 'amount', (r->>'cash_amount')::numeric,
                   'kind', CASE WHEN r->>'kind' = 'interest' THEN 'interest_line'
                                WHEN r->>'sub_kind' = 'legacy_return' THEN 'legacy_return' ELSE r->>'kind' END,
                   'sub_kind', r->>'sub_kind', 'transfer_fee', r->'transfer_fee',
                   'purpose', COALESCE(r->>'purpose', r->>'name'), 'name', r->>'name', 'row_no', r->'row_no', 'reason', r->>'reason')
                 ORDER BY (r->>'date')::date, (r->>'row_no')::int), '[]'::jsonb)
        INTO v_lines
        FROM jsonb_array_elements(v_norm->'rows') r;
        SELECT COALESCE(sum((l->>'amount')::numeric), 0) INTO v_sum FROM jsonb_array_elements(v_lines) l;
        v_balance_ok := (v_open + v_sum = v_close);
        ELSE
        -- so, wie der Nutzer ihn nennt ("1.234,56", "1234.56 EUR"): die eine Adresse fuer freie Geld-Eingaben
        v_owner := round(finance.fn_parse_numeric_or_null(p->>'closing_balance', true), 2);
        IF v_owner IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'closing_balance_required', 'account_name', v_acct.name,
                'reason','The export has no balance - ask the user for the current balance of "' || v_acct.name
                       || '" exactly as the bank app shows it right now, then call again.');
        END IF;
        IF v_acct.last_reconciled_at IS NULL AND v_acct.opening_balance_date IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'no_starting_point', 'account_name', v_acct.name,
                'reason','The account "' || v_acct.name || '" has no confirmed balance date yet - confirm its balance once '
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
        END IF;
        SELECT COALESCE(jsonb_agg(u ORDER BY (u->>'row_no')::int), '[]'::jsonb) INTO v_file_unk
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
    IF NOT v_file AND NULLIF(p->>'currency', '') IS NOT NULL AND upper(p->>'currency') <> v_acct.currency THEN
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

    -- ---------- 3a. Pool-Regel (Anbieter mit Sammelkonto, z. B. Bondora) ----------
    --   Eine noch offene Geldzeile, deren Gegenpart-Name zum counterparty_pattern eines Profils passt. Kandidaten = aktive,
    --   buchbare P2P-Konten dieses Profils (fn_bank_export_account_profile) in der Kontowaehrung, die am Zeilendatum noch
    --   NICHT abgeglichen sind (deren eigener Auszug haette die Bewegung schon gepaart oder im Rest - nie doppelt).
    --   Eingang (Auszahlung, Bondora zahlt nur auf das verifizierte Konto): das P2P-Konto, dessen Verrechnungskonto dieses
    --   Konto ist, sonst eines desselben Inhabers (nie Haushalt) OHNE anderes Verrechnungskonto -> Transfer + Gebuehr-Bein
    --   (Profil withdrawal_fee) beim P2P-Konto. Ausgang (Einzahlung): Referenz = Kontonummer als ganzes Wort im
    --   Verwendungszweck, sonst alle Kandidaten. Genau ein Kandidat -> Transfer. GENAU eine Zeile mit zwei Kandidaten:
    --   ohne transfer_account -> code transfer_choice_required (der Agent fragt, Muster account_ambiguous); mit Namen eines
    --   der beiden -> Transfer; 'none' -> Rest; anderer Name -> erneut transfer_choice_required. Mehrere solche Zeilen oder
    --   0/3+ Kandidaten (bei vorhandenen Profil-Konten): Rest + Hinweis (pool_unassigned). Die Zeilen laufen danach durch
    --   dieselben Pruefungen wie Stufe T (buchbar, Waehrung, pending_pair).
    FOR v_line, v_idx IN SELECT e, (o)::int FROM jsonb_array_elements(v_lines) WITH ORDINALITY AS x(e, o)
                         WHERE (o)::int IN (SELECT (u)::int FROM jsonb_array_elements_text(v_match->'unmatched') u)
                           AND (e->>'kind' IS NULL OR e->>'kind' = 'cash') AND (e->>'amount')::numeric <> 0 LOOP
        SELECT pr INTO v_pool_pr FROM jsonb_array_elements(finance.fn_bank_export_profiles()) pr
        WHERE pr ? 'counterparty_pattern' AND COALESCE(v_line->>'counterparty', '') ~* (pr->>'counterparty_pattern') LIMIT 1;
        CONTINUE WHEN v_pool_pr IS NULL;
        SELECT COALESCE(jsonb_agg(jsonb_build_object('account_id', a.id, 'name', a.name, 'number', a.account_number,
                   'settles_here', a.settlement_account_id = v_acct.id,
                   'same_owner_free', a.owner_person_id = v_acct.owner_person_id AND a.settlement_account_id IS NULL,
                   'usable', finance.fn_bookable_account_reason(a.id) IS NULL
                             AND finance.fn_reconciled_reason(a.id, (v_line->>'date')::date) IS NULL)
                 ORDER BY a.id), '[]'::jsonb)
        INTO v_pool_c
        FROM finance.accounts a
        WHERE a.status = 'active' AND a.account_type::text = 'p2p' AND a.id <> v_acct.id AND a.currency = v_acct.currency
          AND finance.fn_bank_export_account_profile(a.id) = v_pool_pr->>'key';
        CONTINUE WHEN jsonb_array_length(v_pool_c) = 0;   -- kein Konto dieses Anbieters im Haushalt: normale Zeile
        SELECT COALESCE(jsonb_agg(c), '[]'::jsonb) INTO v_pool_c FROM jsonb_array_elements(v_pool_c) c WHERE (c->>'usable')::boolean;
        IF (v_line->>'amount')::numeric > 0 THEN
            v_pool_pick := COALESCE(
                (SELECT jsonb_agg(c) FROM jsonb_array_elements(v_pool_c) c WHERE (c->>'settles_here')::boolean),
                (SELECT jsonb_agg(c) FROM jsonb_array_elements(v_pool_c) c WHERE (c->>'same_owner_free')::boolean),
                '[]'::jsonb);
        ELSE
            v_pool_pick := COALESCE(
                (SELECT jsonb_agg(c) FROM jsonb_array_elements(v_pool_c) c
                 WHERE c->>'number' IS NOT NULL
                   -- ganzes Wort (Leerraum-getrennt, Satzzeichen am Rand egal); kein Regex aus der Kontonummer
                   AND (c->>'number') IN (SELECT btrim(t, '.,;:()[]{}"''') FROM regexp_split_to_table(upper(COALESCE(v_line->>'purpose', '')), '[[:space:]]+') t)),
                v_pool_c);
        END IF;
        v_line := v_line || jsonb_build_object('line_idx', v_idx, 'pool_fee',
                      CASE WHEN (v_line->>'amount')::numeric > 0 THEN (v_pool_pr->>'withdrawal_fee')::numeric END);
        IF jsonb_array_length(v_pool_pick) = 1 THEN
            v_pool := v_pool || jsonb_build_object('line', v_line, 'pick', v_pool_pick->0);
        ELSE
            v_pool_amb := v_pool_amb || jsonb_build_object('line_idx', v_idx, 'amount', round((v_line->>'amount')::numeric, 2),
                                                           'date', v_line->>'date', 'line', v_line, 'candidates', v_pool_pick);
        END IF;
    END LOOP;
    -- Wahl des Nutzers: nur bei GENAU einer Zeile mit zwei Kandidaten (nie eine Antwort fuer mehrere Zahlungen)
    IF (SELECT count(*) FROM jsonb_array_elements(v_pool_amb) a WHERE jsonb_array_length(a->'candidates') = 2) = 1 THEN
        SELECT a INTO v_m FROM jsonb_array_elements(v_pool_amb) a WHERE jsonb_array_length(a->'candidates') = 2;
        IF lower(btrim(COALESCE(p->>'transfer_account', ''))) <> 'none' THEN
            SELECT c INTO v_pool_pr FROM jsonb_array_elements(v_m->'candidates') c
            WHERE NULLIF(btrim(p->>'transfer_account'), '') IS NOT NULL
              AND finance.fn_name_matches(c->>'name', btrim(p->>'transfer_account'), false)
            ORDER BY (c->>'account_id')::int LIMIT 1;
            IF v_pool_pr IS NULL THEN
                RETURN jsonb_build_object('ok', false, 'code', 'transfer_choice_required',
                    'candidates', (SELECT jsonb_agg(c->>'name' ORDER BY (c->>'account_id')::int) FROM jsonb_array_elements(v_m->'candidates') c),
                    'amount', v_m->'amount', 'date', v_m->'date',
                    'reason', 'A payment of ' || (v_m->>'amount') || ' on ' || (v_m->>'date') || ' '
                           || CASE WHEN (v_m->>'amount')::numeric < 0 THEN 'to' ELSE 'from' END
                           || ' a provider''s shared account fits two accounts ('
                           || (SELECT string_agg(c->>'name', ' / ' ORDER BY (c->>'account_id')::int) FROM jsonb_array_elements(v_m->'candidates') c)
                           || ') - ask the user which one it belongs to (or none), then call again with transfer_account'
                           || CASE WHEN NULLIF(btrim(p->>'transfer_account'), '') IS NOT NULL
                                   THEN ' (the given "' || btrim(p->>'transfer_account') || '" is neither of them)' ELSE '' END || '.');
            END IF;
            v_pool := v_pool || jsonb_build_object('line', v_m->'line', 'pick', v_pool_pr);
            SELECT COALESCE(jsonb_agg(a), '[]'::jsonb) INTO v_pool_amb FROM jsonb_array_elements(v_pool_amb) a
            WHERE (a->>'line_idx')::int <> (v_m->>'line_idx')::int;
        END IF;
    END IF;
    -- zugeordnete Pool-Zeilen -> Treffer (kind transfer, Stufe P)
    SELECT COALESCE(jsonb_agg(jsonb_build_object('line_idx', (x->'line'->>'line_idx')::int, 'stage', 'P', 'kind', 'transfer',
               'other_account_id', (x->'pick'->>'account_id')::int, 'name', x->'pick'->>'name',
               'line_date', x->'line'->>'date', 'amount', round((x->'line'->>'amount')::numeric, 2),
               'expected', round((x->'line'->>'amount')::numeric, 2),
               'side', CASE WHEN (x->'line'->>'amount')::numeric < 0 THEN 'source' ELSE 'target' END)
               || CASE WHEN (x->'line'->>'pool_fee')::numeric > 0
                       THEN jsonb_build_object('partner_fee', (x->'line'->>'pool_fee')::numeric) ELSE '{}'::jsonb END), '[]'::jsonb),
           v_out - COALESCE(sum(LEAST((x->'line'->>'amount')::numeric, 0)), 0),
           v_in - COALESCE(sum(GREATEST((x->'line'->>'amount')::numeric, 0)), 0)
    INTO v_pool, v_out, v_in
    FROM jsonb_array_elements(v_pool) x;
    v_match := jsonb_set(jsonb_set(v_match, '{matched}', (v_match->'matched') || v_pool), '{unmatched}',
                   COALESCE((SELECT jsonb_agg(u) FROM jsonb_array_elements(v_match->'unmatched') u
                             WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_pool) x WHERE (x->>'line_idx')::int = (u #>> '{}')::int)), '[]'::jsonb));

    FOR v_m IN SELECT e FROM jsonb_array_elements(v_match->'matched') e LOOP
        IF v_m->>'kind' = 'booked' THEN
            -- Transfer-Gruppe ohne Gebuehr-Bein, die Zeile traegt die Gebuehr (Auszahlung, Partnerkonto zuerst importiert):
            -- apply bucht die Gebuehr als eigene Buchung dieses Auszugs nach (nie in die Gruppe des Partner-Auszugs)
            IF v_m->>'group_id' IS NOT NULL AND (v_m->>'amount')::numeric <> (v_m->>'expected')::numeric THEN
                v_m := v_m || jsonb_build_object('fee_add', (v_m->>'expected')::numeric - (v_m->>'amount')::numeric);
                v_book_sum := v_book_sum - (v_m->>'fee_add')::numeric;
            END IF;
            v_booked := v_booked || v_m;
            CONTINUE;
        END IF;
        v_kind := v_m->>'kind';
        IF v_kind = 'transfer' THEN
            -- Ad-hoc-Transfer (Stufe T): nur buchbar, wenn das Gegenkonto buchbar ist, dieselbe Waehrung hat, kein noch
            -- offener Transfer mit ihm +-5 Tage existiert (nie zweimal: die Bank zeigt einen anderen Betrag als die
            -- Buchung) und es am Zeilendatum nicht abgeglichen ist (sonst doppelt dort). Sonst blocked = Rest.
            -- Unterwegs: ist das Gegenkonto hoechstens 5 Tage nach dem Zeilendatum abgeglichen (dessen Auszug kam
            -- zuerst, das Geld kam dort erst danach an), zaehlt sein Bein ab dem Tag nach seinem Abgleich
            -- (partner_date); sonst stimmte dessen bestaetigter Stand nicht und der Folgeauszug buchte es doppelt.
            v_other := (v_m->>'other_account_id')::int;
            SELECT last_reconciled_at INTO v_partner_at FROM finance.accounts WHERE id = v_other;
            v_reason := CASE
                WHEN finance.fn_bookable_account_reason(v_other) IS NOT NULL THEN 'not_bookable'
                WHEN (SELECT currency FROM finance.accounts WHERE id = v_other) <> v_acct.currency THEN 'currency_mismatch'
                WHEN EXISTS (
                    SELECT 1 FROM finance.transactions t
                    WHERE t.account_id = v_acct.id AND t.group_id IS NOT NULL AND t.category::text = 'transfer'
                      AND t.recurring_payment_id IS NULL AND t.transaction_date > v_cut
                      AND abs(t.transaction_date - (v_m->>'line_date')::date) <= 5
                      AND EXISTS (SELECT 1 FROM finance.transactions o WHERE o.group_id = t.group_id AND o.account_id = v_other)
                      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_match->'matched') b
                                      WHERE (b->>'group_id')::uuid = t.group_id)) THEN 'pending_pair'
                WHEN finance.fn_reconciled_reason(v_other, (v_m->>'line_date')::date) IS NOT NULL
                     AND v_partner_at - (v_m->>'line_date')::date > 5 THEN 'partner_reconciled'
            END;
            IF v_reason IS NOT NULL THEN
                v_blocked := v_blocked || (v_m || jsonb_build_object('reason', v_reason));
                v_out := v_out + LEAST((v_m->>'amount')::numeric, 0);
                v_in  := v_in + GREATEST((v_m->>'amount')::numeric, 0);
                CONTINUE;
            END IF;
            IF finance.fn_reconciled_reason(v_other, (v_m->>'line_date')::date) IS NOT NULL THEN
                v_m := v_m || jsonb_build_object('partner_date', v_partner_at + 1);
            END IF;
            -- Auszahlung mit Gebuehr (Profil, z. B. Bondora 1 EUR): Transfer = Betrag - Gebuehr, Gebuehr als eigenes Bein
            IF (v_lines->((v_m->>'line_idx')::int - 1)->>'transfer_fee')::numeric > 0 THEN
                v_m := v_m || jsonb_build_object('fee', (v_lines->((v_m->>'line_idx')::int - 1)->>'transfer_fee')::numeric);
            END IF;
        ELSIF v_kind = 'recurring' THEN
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

    -- ---------- 3c. Datei mit gedrucktem Endstand: Zins + Kleinbetraege als je EINE Summe ----------
    --   Zins: Korrektur = Summe der Zinszeilen - Summe der Scheduler-Zinsbuchungen im Zeitraum (Stufe 0 je Tag waere
    --   falsch sortiert und liesse Tage ohne Zeile offen); die offenen Scheduler-Vorkommen bis period_end werden
    --   uebersprungen (der Auszug kennt den echten Zins, sonst buchte der Cron sie spaeter zusaetzlich).
    --   Kleinbetraege (legacy_return): eine Buchung "other" mit dem Profil-Label. Beides nie in unmatched/Rest.
    IF v_printed_file THEN
        SELECT COALESCE(sum((l->>'amount')::numeric) FILTER (WHERE l->>'kind' = 'interest_line'), 0),
               COALESCE(sum((l->>'amount')::numeric) FILTER (WHERE l->>'kind' = 'legacy_return'), 0),
               v_in - COALESCE(sum(GREATEST((l->>'amount')::numeric, 0)), 0),
               v_out - COALESCE(sum(LEAST((l->>'amount')::numeric, 0)), 0)
        INTO v_int_lines, v_legacy, v_in, v_out
        FROM jsonb_array_elements(v_lines) l
        WHERE (l->>'date')::date > v_cut AND l->>'kind' IN ('interest_line', 'legacy_return');
        SELECT COALESCE(sum(t.amount), 0) INTO v_int_booked
        FROM finance.transactions t
        WHERE t.account_id = v_acct.id AND t.interest_period_end IS NOT NULL
          AND t.transaction_date > v_cut AND t.transaction_date <= v_pe;
        v_int_corr := v_int_lines - v_int_booked;
        SELECT COALESCE(jsonb_agg(jsonb_build_object('interest_period_end', o.period_end) ORDER BY o.period_end), '[]'::jsonb)
        INTO v_int_skips
        FROM finance.fn_interest_due_open(v_pe) o
        WHERE o.account_id = v_acct.id AND o.period_end > v_cut AND o.period_end <= v_pe;
        v_legacy_label := v_norm->>'legacy_return_label';
        v_book_sum := v_book_sum + v_int_corr + v_legacy;
    END IF;

    -- ---------- 3b. Broker-CSV: Wertpapier-Zeilen ohne Dauerauftrags-Treffer ----------
    --   Position = Holding eines Depots mit diesem Verrechnungskonto (ISIN, Krypto per Symbol). Stufe 0: gebuchter
    --   Kauf/Verkauf (gleiche Stueck) bzw. Dividende (gleicher Betrag) derselben Position +-5 Tage -> already_booked.
    --   Sonst bucht apply aus den Export-Werten (Kurs aus dem Kurswert via fn_unit_price_from_total) -> trades.
    --   Nicht buchbar (trades_blocked): Kauf, der noch in einer Bestandsuebernahme derselben Position steckt
    --   (covered_by_takeover: erst die Einzelkaeufe uebernehmen), Verkauf ueber den Bestand (oversell), unbekannte
    --   Position bei Verkauf/Dividende bzw. kein eindeutiges Depot beim Kauf (security_unknown).
    --   Wertpapier-Geldfluesse (Kauf/Verkauf/Dividende/Steuer/Kapitalmassnahme) zaehlen nie in unmatched_out/in.
    IF v_file THEN
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
    SELECT COALESCE(sum(COALESCE(b->>'expected', b->>'amount')::numeric), 0) INTO v_redate_sum   -- gebuchter Betrag (ohne nachgebuchte Gebuehr)
    FROM jsonb_array_elements(v_booked) b WHERE (b->>'tx_date')::date > v_pe;
    -- Monatsgrenze (Spiegelbild): ein Transfer-Bein dieses Kontos, das der Auszug eines ANDEREN Kontos in den letzten
    -- 5 Tagen des Zeitraums gebucht hat und zu dem dieser Auszug keine Zeile hat, ist unterwegs (z. B. am 30.09. bei
    -- Bondora abgegangen, am 02.10. bei der Bank angekommen) -> apply verschiebt es auf period_end+1; es zaehlt nicht
    -- zum Stand am period_end (sonst Rest jetzt + zweiter Transfer im Folgemonat).
    SELECT COALESCE(jsonb_agg(jsonb_build_object('transaction_id', t.id, 'amount', t.amount, 'tx_date', t.transaction_date,
               'name', t.description) ORDER BY t.id), '[]'::jsonb)
    INTO v_moved
    FROM finance.transactions t
    WHERE t.account_id = v_acct.id AND t.group_id IS NOT NULL AND t.category::text IN ('transfer', 'fee')
      AND t.recurring_payment_id IS NULL
      AND t.transaction_date > v_cut AND t.transaction_date BETWEEN v_pe - 5 AND v_pe
      AND EXISTS (SELECT 1 FROM finance.bank_statements s WHERE s.id = t.bank_statement_id AND s.account_id <> v_acct.id)
      AND EXISTS (SELECT 1 FROM finance.transactions o WHERE o.group_id = t.group_id AND o.account_id <> v_acct.id)
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_booked) b WHERE (b->>'group_id')::uuid = t.group_id)
      -- eine Zeile dazu gibt es doch (anderer Betrag -> pending_pair, zaehlt im Rest): das Bein bleibt, sonst doppelt
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_blocked) b
                      WHERE b->>'reason' = 'pending_pair' AND abs((b->>'line_date')::date - t.transaction_date) <= 5
                        AND EXISTS (SELECT 1 FROM finance.transactions o WHERE o.group_id = t.group_id
                                    AND o.account_id = (b->>'other_account_id')::int));
    SELECT v_redate_sum - COALESCE(sum((x->>'amount')::numeric), 0) INTO v_redate_sum FROM jsonb_array_elements(v_moved) x;

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
        || CASE WHEN v_file AND NOT v_printed_file THEN jsonb_build_array(
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
                         WHEN m ? 'partner_fee'   -- Pool-Eingang: die Gebuehr bucht das Gegenkonto (Karte = Buchung)
                         THEN core.fn_ui_tpl('finance.tpl.statement_partner_fee_row', jsonb_build_object('name', m->>'name',
                                  'amount', core.fn_ui_money((m->>'amount')::numeric, v_acct.currency),
                                  'fee', core.fn_ui_money((m->>'partner_fee')::numeric, v_acct.currency),
                                  'date', core.fn_ui_date((m->>'line_date')::date)))
                         WHEN m ? 'fee'   -- Auszahlung mit Gebuehr: Transfer und Gebuehr getrennt (Karte = Buchung)
                         THEN core.fn_ui_tpl('finance.tpl.statement_transfer_fee_row', jsonb_build_object('name', m->>'name',
                                  'amount', core.fn_ui_money((m->>'amount')::numeric + (m->>'fee')::numeric, v_acct.currency),
                                  'fee', core.fn_ui_money((m->>'fee')::numeric, v_acct.currency),
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
                    CASE WHEN m ? 'fee_add'   -- Gebuehr wird in die schon gebuchte Gruppe nachgebucht
                         THEN core.fn_ui_tpl('finance.tpl.statement_transfer_fee_row', jsonb_build_object('name', m->>'name',
                                  'amount', core.fn_ui_money((m->>'expected')::numeric, v_acct.currency),
                                  'fee', core.fn_ui_money((m->>'fee_add')::numeric, v_acct.currency),
                                  'date', core.fn_ui_date((m->>'line_date')::date)))
                         ELSE core.fn_ui_tpl('finance.tpl.statement_matched_row', jsonb_build_object('name', m->>'name',
                        'amount', core.fn_ui_money((m->>'amount')::numeric, v_acct.currency),
                        'date', core.fn_ui_date((m->>'line_date')::date))) END) ORDER BY (m->>'line_date')::date)
                FROM jsonb_array_elements(v_booked) m);
    END IF;
    -- Unterwegs (Karte = Buchung): Beine, die apply in einen anderen Monat legt (moved_legs: dieses Konto ab
    -- period_end+1; partner_date: das Bein beim Gegenkonto ab dem Tag nach dessen Abgleich)
    IF jsonb_array_length(v_moved) > 0 OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_to_book) m WHERE m ? 'partner_date') THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'heading', 'label', 'finance.label.statement_in_transit'))
            || COALESCE((SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    core.fn_ui_tpl('finance.tpl.statement_in_transit_row', jsonb_build_object('name', x->>'name',
                        'amount', core.fn_ui_money((x->>'amount')::numeric, v_acct.currency),
                        'date', core.fn_ui_date(v_pe + 1)))) ORDER BY (x->>'transaction_id')::int)
                FROM jsonb_array_elements(v_moved) x), '[]'::jsonb)
            || COALESCE((SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    core.fn_ui_tpl('finance.tpl.statement_in_transit_row', jsonb_build_object('name', m->>'name',
                        'amount', core.fn_ui_money(-(m->>'amount')::numeric, v_acct.currency),
                        'date', core.fn_ui_date((m->>'partner_date')::date)))) ORDER BY (m->>'line_idx')::int)
                FROM jsonb_array_elements(v_to_book) m WHERE m ? 'partner_date'), '[]'::jsonb);
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
    IF jsonb_array_length(v_file_unk) > 0 THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'heading', 'label', 'finance.label.statement_export_unknown'))
            || (SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    core.fn_ui_tpl('finance.tpl.statement_export_unknown_row', jsonb_build_object(
                        'name', COALESCE(u->>'name', u->>'type'), 'type', u->>'type',
                        'amount', core.fn_ui_money((u->>'cash_amount')::numeric, v_acct.currency),
                        'date', core.fn_ui_date((u->>'date')::date)))) ORDER BY (u->>'row_no')::int)
                FROM jsonb_array_elements(v_file_unk) u);
    END IF;
    -- Datei mit gedrucktem Endstand: Zinskorrektur (Zinsen laut Auszug vs. geschaetzt), Kleinbetraege, Skips
    IF v_printed_file AND (v_int_lines <> 0 OR v_int_booked <> 0) THEN
        v_card := v_card || jsonb_build_array(
            core.fn_ui_money(v_int_corr, v_acct.currency, true) || jsonb_build_object('label', 'finance.label.statement_interest_correction'),
            jsonb_build_object('kind', 'raw', 'value', core.fn_ui_tpl('finance.tpl.statement_interest_correction_row', jsonb_build_object(
                'lines', core.fn_ui_money(v_int_lines, v_acct.currency), 'booked', core.fn_ui_money(v_int_booked, v_acct.currency)))));
    END IF;
    IF jsonb_array_length(v_int_skips) > 0 THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'finance.note.statement_interest_skips',
                      'params', jsonb_build_object('count', jsonb_array_length(v_int_skips))));
    END IF;
    IF v_legacy <> 0 THEN
        v_card := v_card || jsonb_build_array(
            core.fn_ui_money(v_legacy, v_acct.currency, true) || jsonb_build_object('label', 'finance.label.statement_legacy_returns'));
    END IF;
    -- Pool-Zeilen ohne Zuordnung (keine, zwei ohne Wahl, mehrere Kandidaten): bleiben im Rest
    IF jsonb_array_length(v_pool_amb) > 0 THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'finance.note.statement_pool_unassigned',
                      'params', jsonb_build_object('count', jsonb_array_length(v_pool_amb))));
    END IF;
    -- Ein-/Auszahlung ohne Gegenkonto (die Datei nennt keins): ohne Verrechnungskonto bleibt sie im Rest
    IF v_acct.settlement_account_id IS NULL AND EXISTS (
           SELECT 1 FROM jsonb_array_elements(v_lines) WITH ORDINALITY AS o(l, ord)
           WHERE (o.ord)::int IN (SELECT (x)::int FROM jsonb_array_elements_text(v_match->'unmatched') x)
             AND o.l->>'sub_kind' IN ('deposit', 'withdrawal')) THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'finance.note.statement_no_settlement'));
    END IF;
    v_card := v_card || jsonb_build_array(
        -- Rest-Label nach Richtung (Live-Befund 2026-10-30): ein positiver Rest auf einem Cash-Konto ist ein ungeklaerter
        -- Eingang, nie "Alltagsausgaben"
        core.fn_ui_money(v_lump, v_acct.currency) || jsonb_build_object('label',
            CASE WHEN v_acct.account_type::text <> 'cash' THEN 'finance.label.statement_other_diff'
                 WHEN v_lump > 0 THEN 'finance.label.statement_unexplained_in'
                 ELSE 'finance.label.statement_everyday' END),
        jsonb_build_object('kind', 'note', 'value', 'finance.note.statement_lump'));
    -- S7: die IBAN, die dieser Auszug dem Konto beibringt, steht sichtbar auf der Karte (Kontrolle durch den Nutzer)
    IF v_learn_no IS NOT NULL THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'finance.note.iban_learned',
                      'params', jsonb_build_object('iban', v_learn_no)));
    END IF;

    v_fp := md5(jsonb_build_object('a', v_acct.id, 'c', v_cut, 'd', v_drift, 's', v_s_end, 'l', v_lump,
                  'b', (SELECT jsonb_agg(jsonb_build_array(m->>'kind', m->>'recurring_payment_id', m->>'due_date',
                               m->>'interest_period_end', m->>'line_idx', m->>'amount', m->>'other_account_id', m->>'partner_date'))
                        FROM jsonb_array_elements(v_to_book) m),
                  'o', v_moved, 'z', jsonb_build_array(v_int_corr, v_legacy, v_int_skips),
                  'f', (SELECT jsonb_agg(COALESCE(m->'fee', m->'fee_add', m->'partner_fee')) FROM jsonb_array_elements(v_to_book || v_booked) m
                        WHERE m ? 'fee' OR m ? 'fee_add' OR m ? 'partner_fee'),
                  'q', v_pool_amb,
                  'p', v_adjust, 'k', v_learn, 'n', v_learn_no, 'm', v_missing, 't', v_trades, 'x', v_tblocked,
                  'r', (SELECT jsonb_agg(jsonb_build_array(b->>'transaction_id', b->>'line_date')) FROM jsonb_array_elements(v_booked) b
                        WHERE (b->>'tx_date')::date > v_pe))::text);

    RETURN jsonb_build_object('ok', true,
        'account_id', v_acct.id, 'account_name', v_acct.name, 'currency', v_acct.currency,
        'period_start', v_ps, 'period_end', v_pe, 'opening_balance', v_open, 'closing_balance', v_close,
        'cut', v_cut, 'stmt_at_cut', v_stmt_cut, 'drift', v_drift, 'gap', v_gap,
        'matched', v_to_book, 'already_booked', v_booked, 'blocked', v_blocked, 'savings_plan_pending', v_pending,
        'moved_legs', v_moved,
        'missing', v_missing, 'unknown_mandates', v_unknown, 'plan_adjustments', v_adjust, 'learn', v_learn,
        'learned_account_number', v_learn_no,
        'line_count', jsonb_array_length(v_lines),
        'matched_count', jsonb_array_length(v_to_book) + jsonb_array_length(v_booked),
        'unmatched_out', v_out, 'unmatched_in', v_in,
        'lump', v_lump, 'card_lines', v_card, 'fingerprint', v_fp,
        'source', CASE WHEN v_file THEN 'file' ELSE 'printed' END,
        'balance_source', CASE WHEN v_file AND NOT v_printed_file THEN 'owner' ELSE 'printed' END,
        'interest_correction', v_int_corr, 'interest_lines', v_int_lines, 'interest_booked', v_int_booked,
        'interest_skips', v_int_skips, 'legacy_returns', v_legacy, 'legacy_return_label', v_legacy_label,
        'pool_unassigned', jsonb_array_length(v_pool_amb))
        || CASE WHEN v_file THEN jsonb_build_object(
               'owner_balance', v_owner, 'after_period', v_after,
               'trades', v_trades, 'trades_blocked', v_tblocked, 'export_unknown', v_file_unk,
               'late_count', (SELECT count(*) FROM jsonb_array_elements(v_lines) l WHERE (l->>'late')::boolean),
               'seen_refs', (SELECT COALESCE(jsonb_agg(DISTINCT l->>'ext_ref'), '[]'::jsonb)
                             FROM jsonb_array_elements(v_lines) l WHERE l->>'ext_ref' IS NOT NULL))
           ELSE '{}'::jsonb END;
END;
$$;
