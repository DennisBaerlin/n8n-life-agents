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
BEGIN
    -- ---------- 1. Rohwerte + Konto ----------
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

    v_reason := finance.fn_bookable_account_reason(v_acct.id);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_bookable', 'reason', v_reason);
    END IF;
    IF NULLIF(p->>'currency', '') IS NOT NULL AND upper(p->>'currency') <> v_acct.currency THEN
        RETURN jsonb_build_object('ok', false, 'code', 'currency_mismatch',
            'reason', 'The statement is in ' || upper(p->>'currency') || ' but the account "' || v_acct.name
                   || '" is kept in ' || v_acct.currency || '.');
    END IF;
    IF v_pe > CURRENT_DATE THEN
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
            IF FOUND THEN
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
                         'order_fee', abs((v_m->>'amount')::numeric) - round(v_shares * v_price, 2));
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
            || jsonb_build_object('label', 'finance.label.statement_period'),
        core.fn_ui_money(v_open, v_acct.currency) || jsonb_build_object('label', 'finance.label.statement_opening'),
        core.fn_ui_money(v_close, v_acct.currency) || jsonb_build_object('label', 'finance.label.statement_closing'));
    IF v_drift <> 0 THEN
        v_card := v_card || jsonb_build_array(
            core.fn_ui_money(v_drift, v_acct.currency) || jsonb_build_object('label', 'finance.label.statement_drift'),
            jsonb_build_object('kind', 'note', 'value', 'finance.note.statement_drift'));
    END IF;
    IF jsonb_array_length(v_to_book) > 0 THEN
        v_card := v_card || jsonb_build_array(jsonb_build_object('kind', 'heading', 'label', 'finance.label.statement_matched'))
            || (SELECT jsonb_agg(jsonb_build_object('kind', 'raw', 'value',
                    CASE WHEN m->>'kind' = 'savings_plan'
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
                  'p', v_adjust, 'k', v_learn, 'n', v_learn_no, 'm', v_missing,
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
        'lump', v_lump, 'card_lines', v_card, 'fingerprint', v_fp);
END;
$$;
