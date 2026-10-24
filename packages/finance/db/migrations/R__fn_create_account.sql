-- ============================================================
-- fn_create_account (ATOMIC WRITE)
--   Legt ein Konto an, optional eine Zinszeile und optional die Eroeffnungsbuchung, alles in EINER
--   Transaktion. Der EINE Anlage-Pfad fuer Einzel-Tool (tool_create_account) UND Bulk-Import
--   (fn_import_bundle delegiert hierher). Eingabe als jsonb:
--     name, account_type, bank, account_number, settlement_id, owner_person_id (Slug, NULL=Haushalt), currency,
--     opening_balance (optional; aktueller Saldo in Kontowaehrung, auch negativ = ueberzogen),
--     interest_rate (% p.a., optional), interest_credit_unit (day/week/month/year, PFLICHT mit Satz -- nie angenommen),
--     interest_credit_interval (optional -> 1), interest_credit_day_of_month (month: Pflicht, -1 = Ende des Monats/
--     Quartals/Halbjahres oder 1-28; year: leer = Jahrestag / -1 = 31.12.; day/week: leer),
--     interest_day_count_convention (optional Override; sonst Vorschlag aus fn_account_interest_defaults),
--     interest_posting_day_of_month (optional; gesetzt = Arrears-Gutschrift im Folgemonat),
--     interest_auto_post (optional Override; sonst Vorschlag aus fn_account_interest_defaults = Karten-Wert),
--     interest_valid_from (optional -> core.fn_today()),
--     opening_balance_date (optional, YYYY-MM-DD, nicht in der Zukunft, nur mit opening_balance, nie auf Depots:
--     Stichtag des Saldos, z. B. das Ende des Kontoauszugs, aus dem ein neues Konto angelegt wird; leer = heute)
--   Eroeffnungssaldo: EIGENE Buchung category='other' zum Stichtag (kein 'reconciliation', kein
--   last_reconciled_* -> der erste echte Abgleich-Reminder bleibt unverfaelscht). 0/leer -> keine Buchung.
--   Ein genannter Saldo (auch 0) setzt opening_balance_date = Stichtag: wiederkehrende Zahlungen, die danach
--   angelegt werden, zaehlen erst ab diesem Stichtag, bei vergangenem Stichtag (Auszugsende) ab dem Folgetag
--   (fn_recurring_valid_from) — fruehere Vorkommen stecken im Saldo;
--   der Monats-Check schneidet dort ab (derselbe Auszug -> already_covered, der naechste schliesst ohne Abweichung an).
--   settlement_id ist bereits im n8n-Workflow aufgeloest (Ambiguitaet/Depot-Pflicht dort).
--   Die DB-CHECK finance_accounts_depot_needs_settlement bleibt harter Backstop.
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, account_id, interest_added, balance, opening_balance_date} (balance =
--   Post-State nach dem Saldo-Trigger, in derselben Transaktion gelesen; opening_balance_date = geschriebener
--   Stichtag oder NULL ohne Saldo — die Karte liest ihn aus dem Probelauf). Korrigierbar -> {ok:false, reason} OHNE Write:
--   Stichtag kein YYYY-MM-DD / in der Zukunft / ohne Saldo / auf einem Depot;
--   ungueltige Waehrung; account_type 'loan' (Kredite nur ueber fn_create_loan, das sein Konto selbst
--   anlegt); opening_balance auf einem Depot (Depot-Saldo bleibt 0, Geld liegt auf dem Verrechnungskonto);
--   Depot-Waehrung <> Waehrung des Verrechnungskontos; Kontonummer/IBAN schon bei einem aktiven Konto vergeben
--   (Monats-Check WP-B: gespeichert in der Normalform fn_normalize_account_number; UNIQUE-Index = Backstop);
--   Import-Haertung 2026-10-22: account_type fehlt/unbekannt; Verrechnungskonto nicht buchbar (Depot/Kredit);
--   Zinssatz auf nicht verzinsbarem Kontotyp (vorher Trigger-RAISE); Zins-Konditionen ungueltig
--   (fn_interest_terms_reason: Rhythmus, Buchungstag, Gutschrift-Tag, Konvention — vorher CHECK-RAISE); Zins ohne
--   Rhythmus bzw. Tag unpassend zum Rhythmus (fn_interest_schedule_reason, code missing_required; Live-Befund
--   2026-10-24, vorher still 'year').
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_create_account(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_account_id INT;
    v_rate       NUMERIC := NULLIF(p->>'interest_rate', '')::numeric;
    v_dup_cand   JSONB;
    v_similar    JSONB;
    v_opening    NUMERIC;
    v_open_date  DATE;
    v_open_raw   TEXT    := NULLIF(btrim(p->>'opening_balance_date'), '');
    -- Roh-Input normalisieren ('usd' -> 'USD'); NULL -> 'EUR' (STRICT-Helper gibt NULL bei NULL zurueck).
    v_currency   TEXT    := COALESCE(finance.fn_normalize_currency(NULLIF(p->>'currency', '')), 'EUR');
    v_acct_type  finance.account_type;   -- Cast erst nach dem Enum-Guard
    v_reason     TEXT;
    v_unit       finance.schedule_unit;
    v_conv       TEXT;
    v_auto       BOOLEAN;
    v_defaults   JSONB;
    v_ccy_result JSONB;
    v_balance    NUMERIC;
    v_number     TEXT    := finance.fn_normalize_account_number(p->>'account_number');
    v_taken      TEXT;
BEGIN
    IF NULLIF(p->>'account_type', '') IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'The account type (account_type) is required.');
    END IF;
    v_reason := finance.fn_enum_reason('finance.account_type'::regtype, p->>'account_type', 'account_type');
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    v_acct_type := (p->>'account_type')::finance.account_type;
    -- Saldo: JSON-Zahl (Import, schon kanonisch) direkt; Text (Einzel-Tool, wie vom Nutzer genannt, z. B. "1.234,56")
    -- ueber fn_parse_de_numeric (Geld -> Tausenderpunkt). Unlesbar -> korrigierbares {ok:false} statt Cast-RAISE.
    BEGIN
        v_opening := CASE WHEN jsonb_typeof(p->'opening_balance') = 'number' THEN (p->>'opening_balance')::numeric
                          ELSE NULLIF(finance.fn_parse_de_numeric(p->>'opening_balance', true), '')::numeric END;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The balance "' || (p->>'opening_balance') || '" is not a number - give it as e.g. 1234.56 (negative if overdrawn).');
    END;
    -- Stichtag nur als ISO-Datum: ein DateStyle-abhaengiger Cast machte "01.10.2026" still zum 10. Januar.
    IF v_open_raw IS NOT NULL THEN
        BEGIN
            IF v_open_raw !~ '^\d{4}-\d{2}-\d{2}$' THEN
                RAISE invalid_datetime_format;
            END IF;
            v_open_date := v_open_raw::date;
        EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'The balance date "' || v_open_raw || '" is not a valid date - give it as YYYY-MM-DD.');
        END;
        IF v_open_date > core.fn_today() THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'The balance date ' || v_open_date || ' is in the future - a balance can only be stated for today or an earlier day.');
        END IF;
        IF v_acct_type IN ('stocks_depot', 'crypto_depot') THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'A depot has no cash balance of its own - leave the balance and its date empty, put the cash balance on its settlement account and record the positions as holdings.');
        END IF;
        IF v_opening IS NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'A balance date (opening_balance_date) needs the balance itself (opening_balance).');
        END IF;
    END IF;
    -- Effektiver Stichtag: genannter Saldo (auch 0) ohne Datum = Stand heute; ohne Saldo kein Stichtag.
    v_open_date := CASE WHEN v_opening IS NOT NULL THEN COALESCE(v_open_date, core.fn_today()) END;
    IF v_acct_type = 'loan' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Loans are not created as plain accounts - use the loan tool (create_loan), which creates the loan account together with the remaining debt and the monthly rate.');
    END IF;
    -- DB-ist-das-Gesetz S4: Festgeld ohne Zins/Faelligkeit rechnet nichts (vorher nur Prompt-Regel; Spiegel-CHECK
    -- finance_accounts_fixed_deposit_maturity_chk fuer die Faelligkeit, der Zins liegt in account_interest_rates).
    IF v_acct_type = 'fixed_deposit' THEN
        v_reason := finance.fn_fixed_deposit_reason(v_rate, NULLIF(p->>'fixed_deposit_maturity_date', '')::date);
        IF v_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'missing_required', 'reason', v_reason);
        END IF;
    END IF;
    -- S6: Kontoname unter aktiven Konten eindeutig, ohne Gross-/Kleinschreibung und typuebergreifend (wie
    -- fn_import_validate_row): Referenzen (Verrechnungs-/Abbuchungskonto, Depot) loesen nur ueber den NAMEN auf.
    -- Kein UNIQUE-Index (sql.md: Bestandspaare sind legitim); dieser Backstop sitzt in der create-fn.
    SELECT jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'account_type', a.account_type, 'bank', a.bank,
                                        'owner_person_id', a.owner_person_id) ORDER BY a.id)
    INTO v_dup_cand
    FROM finance.accounts a
    WHERE a.status = 'active' AND finance.fn_name_matches(a.name, p->>'name', FALSE);
    IF v_dup_cand IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'duplicate_name',
            'reason', 'An active account named "' || (v_dup_cand->0->>'name') || '" already exists. Use that account, or '
                   || 'choose a distinct name - for a household member''s own account add their first name (e.g. "'
                   || (p->>'name') || ' <first name>").',
            'candidates', v_dup_cand);
    END IF;
    -- S6 weicher Hinweis (Karte, kein Block, hohe Schwelle): gleicher Typ + gleiche Bank + gleicher Inhaber und
    -- keine zwei verschiedenen bekannten Kontonummern -> "aehnliches Konto vorhanden". Ersetzt die Prompt-Regel
    -- "aehnlichen Namen/Bank selbst suchen und nachfragen".
    SELECT jsonb_agg(jsonb_build_object('kind', 'note', 'value', 'finance.note.similar_account',
                                        'params', jsonb_build_object('name', a.name)) ORDER BY a.id)
    INTO v_similar
    FROM finance.accounts a
    WHERE a.status = 'active'
      AND a.account_type::text = p->>'account_type'
      AND NULLIF(btrim(p->>'bank'), '') IS NOT NULL
      AND lower(btrim(a.bank)) = lower(btrim(p->>'bank'))
      AND a.owner_person_id IS NOT DISTINCT FROM NULLIF(p->>'owner_person_id', '')
      AND NOT (a.account_number IS NOT NULL AND v_number IS NOT NULL AND a.account_number <> v_number);
    IF v_acct_type IN ('stocks_depot', 'crypto_depot') AND COALESCE(v_opening, 0) <> 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A depot has no cash balance of its own - put the cash balance on its settlement account and record the positions as holdings.');
    END IF;
    -- Verrechnungskonto muss Geld tragen koennen (Kaeufe buchen dort; Depot/Kredit -> Trigger-RAISE beim ersten Kauf).
    v_reason := finance.fn_bookable_account_reason(NULLIF(p->>'settlement_id', '')::int);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    -- Zinszeile: Kontotyp + Konditionen VOR dem ersten Write (Spiegel von Trigger + CHECKs auf account_interest_rates).
    IF v_rate IS NOT NULL AND v_rate <> 0 THEN
        v_reason := finance.fn_rate_precision_reason(v_rate, 'Interest rate');   -- numeric(6,4) kuerzte still
        IF v_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', v_reason);
        END IF;
        IF NOT finance.fn_interest_eligible_account_type(v_acct_type) THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Interest applies only to cash, fixed-deposit and P2P accounts (account type ' || v_acct_type || ' is not eligible).');
        END IF;
        -- Kadenzfelder ueber DIESELBE Einlese-Stelle wie der Vorschlag (fn_parse_small_int): geprueft wird, was
        -- geschrieben wird; ein genannter, aber unlesbarer Wert ist korrigierbar statt still leer.
        SELECT string_agg(k, ', ') INTO v_reason
          FROM unnest(ARRAY['interest_credit_interval', 'interest_credit_day_of_month', 'interest_posting_day_of_month']) k
         WHERE NULLIF(btrim(p->>k), '') IS NOT NULL AND finance.fn_parse_small_int(p->>k) IS NULL;
        IF v_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Not a whole number: ' || v_reason || ' - give e.g. 3 (interval), -1 or 1-28 (day).');
        END IF;
        v_reason := finance.fn_interest_terms_reason(p->>'interest_credit_unit',
                        finance.fn_parse_small_int(p->>'interest_credit_day_of_month')::smallint,
                        finance.fn_parse_small_int(p->>'interest_posting_day_of_month')::smallint,
                        p->>'interest_day_count_convention');
        IF v_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', v_reason);
        END IF;
        -- Pflicht-Kadenz (Live-Befund 2026-10-24): kein erfundener Rhythmus, Tag passend zum Rhythmus.
        v_reason := finance.fn_interest_schedule_reason(NULLIF(p->>'interest_credit_unit', '')::finance.schedule_unit,
                        finance.fn_parse_small_int(p->>'interest_credit_interval'),
                        finance.fn_parse_small_int(p->>'interest_credit_day_of_month'), 'account');
        IF v_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'missing_required', 'reason', v_reason);
        END IF;
    END IF;

    -- S7: eine IBAN-foermige Nummer muss ihre Pruefziffer bestehen (Spiegel-CHECK finance_accounts_iban_chk)
    IF NOT finance.fn_iban_valid(v_number) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_iban',
            'reason', 'The IBAN ' || v_number || ' has wrong check digits - a digit is probably mistyped; ask the user to check it.');
    END IF;
    -- Kontonummer/IBAN identifiziert das Konto (Kontoauszug-Zuordnung) -> nie zweimal unter aktiven Konten.
    SELECT name INTO v_taken FROM finance.accounts WHERE account_number = v_number AND status = 'active';
    IF v_taken IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The account number ' || v_number || ' already belongs to the account "' || v_taken
                   || '". Use that account (e.g. reconcile it or change its details) instead of creating a second one.');
    END IF;

    -- Fremdwaehrung registrieren/validieren; den {ok:false} NICHT verwerfen (sonst FK-RAISE + Owner-Alert
    -- bei echt-ungueltigem Code) -> als korrigierbaren Tool-Fehler zurueckgeben. Parität zu fn_book_stock_buy.
    IF v_currency <> 'EUR' THEN
        v_ccy_result := finance.fn_ensure_currency(v_currency);
        IF NOT (v_ccy_result->>'ok')::boolean THEN
            RETURN v_ccy_result;
        END IF;
    END IF;

    -- Depot und Verrechnungskonto muessen dieselbe Waehrung haben: Kaeufe buchen Stueck x Kurs (Depot-
    -- Waehrung) 1:1 auf das Verrechnungskonto -> sonst liefe z. B. ein USD-Betrag still als EUR.
    -- Ohne genannte Waehrung erbt das Depot die Waehrung seines Verrechnungskontos.
    IF NULLIF(p->>'settlement_id', '') IS NOT NULL AND NULLIF(p->>'currency', '') IS NULL THEN
        SELECT currency INTO v_currency FROM finance.accounts WHERE id = (p->>'settlement_id')::int;
        v_currency := COALESCE(v_currency, 'EUR');
    END IF;
    IF NULLIF(p->>'settlement_id', '') IS NOT NULL AND EXISTS (
        SELECT 1 FROM finance.accounts WHERE id = (p->>'settlement_id')::int AND currency <> v_currency) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The depot currency (' || v_currency || ') must match the currency of its settlement account ('
                   || (SELECT currency FROM finance.accounts WHERE id = (p->>'settlement_id')::int) || ').');
    END IF;

    INSERT INTO finance.accounts
        (name, account_type, bank, account_number, settlement_account_id, owner_person_id, currency, status,
         fixed_deposit_maturity_date, fixed_deposit_auto_renew, opening_balance_date)
    VALUES (
        p->>'name',
        v_acct_type,
        NULLIF(p->>'bank', ''),
        v_number,
        NULLIF(p->>'settlement_id', '')::int,
        NULLIF(p->>'owner_person_id', ''),   -- WS-4: typisierter Eigentuemer (Slug, im Tool aufgeloest); NULL=Haushalt. FK->agent.persons.
        v_currency,
        'active',
        NULLIF(p->>'fixed_deposit_maturity_date', '')::date,
        NULLIF(p->>'fixed_deposit_auto_renew', '')::boolean,
        v_open_date   -- genannter Saldo (auch 0) = Stand am Stichtag
    )
    RETURNING id INTO v_account_id;

    IF v_rate IS NOT NULL AND v_rate <> 0 THEN
        -- Kadenz, Methode + auto_post aus DERSELBEN fn wie die HITL-Karte (Karte = Write; Override schlaegt Vorschlag).
        v_defaults := finance.fn_account_interest_defaults(p);
        v_unit := (v_defaults->>'unit')::finance.schedule_unit;
        v_conv := v_defaults->>'conv';
        v_auto := (v_defaults->>'auto_post')::boolean;

        INSERT INTO finance.account_interest_rates
            (account_id, annual_rate, schedule_interval, schedule_unit, schedule_day_of_month,
             day_count_convention, posting_day_of_month, auto_post, valid_from)
        VALUES (
            v_account_id,
            v_rate,
            (v_defaults->>'interval')::smallint,
            v_unit,
            (v_defaults->>'dom')::smallint,
            v_conv,
            (v_defaults->>'pdom')::smallint,
            v_auto,
            (v_defaults->>'valid_from')::date
        );
    END IF;

    -- Eroeffnungssaldo (Saldo via trg_finance_balance_update).
    IF COALESCE(v_opening, 0) <> 0 THEN
        INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
        VALUES (v_account_id, v_opening, v_open_date, 'other', 'Eröffnungssaldo');
    END IF;
    SELECT balance INTO v_balance FROM finance.account_balances WHERE account_id = v_account_id;

    RETURN jsonb_build_object(
        'ok', true,
        'account_id', v_account_id,
        'interest_added', (v_rate IS NOT NULL AND v_rate <> 0),
        'balance', v_balance,
        'opening_balance_date', v_open_date,
        'card_lines', COALESCE(v_similar, '[]'::jsonb)
    );
END;
$$;
