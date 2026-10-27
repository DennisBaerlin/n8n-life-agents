-- ============================================================
-- fn_import_validate_row (per-Row-Validierung der Import-Staging — read-only)
--   Liefert NULL (= valid) oder einen EN-Fehlertext (Layer 1) mit konkretem Grund.
--   Prueft: Pflichtfelder je entity_type, Enum-/Zahlen-/Datums-Casts, Derived-Key-Denylist
--   (Vision/LLM darf nie Abgeleitetes liefern), Feld-Allow-List (fn_import_allowed_keys = die Kartenfelder),
--   Dubletten-Backstop (fn_resolve_* gegen
--   Bestand + Namens-Dublette IM Batch) und Konto-Referenzen (Bestand ODER account-Row
--   im selben Batch). Die tiefen Wert-Guards bleiben in den fn_create_*/fn_book_*.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_validate_row(
    p_batch_id uuid, p_row_no int, p_type text, p jsonb)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_name   TEXT := NULLIF(trim(COALESCE(p->>'name','')), '');
    v_hits   INT;
    v_facts  TEXT;    -- fn_real_estate_facts_reason (Instandhaltungsruecklage)
    v_num    NUMERIC;
    v_key    TEXT;
    v_ref    TEXT;
    v_acct_type TEXT;
    v_fields JSONB;
BEGIN
    -- Derived-Value-Denylist (gleiche Klasse wie household facts: Rohfakt rein, Ableitung rechnen)
    SELECT k INTO v_key FROM jsonb_object_keys(p) k
    WHERE lower(k) IN ('age','alter','balance_after','monthly_equivalent','average_purchase_price',
                       'recurring_amount')   -- Versicherungs-Rate leitet fn_create_insurance ab
    LIMIT 1;
    IF v_key IS NOT NULL THEN
        RETURN format('key "%s" is a derived value — provide raw facts only', v_key);
    END IF;

    -- Personen-Feld wie im Einzel-Tool (eine Aufloesungs-Stelle mit dem Bundle)
    v_ref := finance.fn_import_resolve_persons(p_type, p)->>'error';
    IF v_ref IS NOT NULL THEN RETURN v_ref; END IF;

    -- Feld-Allow-List: nur Felder, die die Bestaetigungskarte der Art zeigt (fn_import_allowed_keys)
    SELECT k INTO v_key FROM jsonb_object_keys(p) k
    WHERE NOT (k = ANY (COALESCE(finance.fn_import_allowed_keys(p_type), ARRAY[]::text[])))
    ORDER BY k LIMIT 1;
    IF v_key IS NOT NULL THEN
        RETURN format('field "%s" is not supported for %s rows - allowed: %s', v_key, p_type,
                      array_to_string(finance.fn_import_allowed_keys(p_type), ', '));
    END IF;

    -- generische Datums-Pruefung (falls vorhanden): genau YYYY-MM-DD und ein echter Tag — dieselbe Annahme wie die
    -- Write-fns (core.fn_resolve_input_dates). Ein Postgres-Cast liesse '10/24/2026', '2026-10-24T00:00' oder 'now'
    -- durch, die der Commit dann ablehnte; relative Texte gehoeren nicht in einen Import (Dokument-Werte).
    FOR v_key IN SELECT k FROM jsonb_object_keys(p) k
                 WHERE k IN ('first_payment_date','valid_from','valid_to','transaction_date',
                             'target_date','disbursement_date','value_updated_at',
                             'retirement_start_date','interest_rate_fixed_until',
                             'fixed_deposit_maturity_date','statement_date','interest_valid_from')
    LOOP
        IF NULLIF(p->>v_key,'') IS NOT NULL
           AND (btrim(p->>v_key) !~ '^\d{4}-\d{2}-\d{2}$' OR core.fn_resolve_date(p->>v_key) IS NULL) THEN
            RETURN format('%s "%s" is not a valid DATE (YYYY-MM-DD)', v_key, p->>v_key);
        END IF;
    END LOOP;

    -- generische Ja/Nein-, Ganzzahl-, Zahl- und Kadenz-Casts der erlaubten Felder (sonst bestuende eine Zeile die
    -- Pruefung und braeche erst beim Kartenbau/Commit an einem Cast: fn_import_card_rows, fn_create_*)
    FOR v_key IN SELECT k FROM jsonb_object_keys(p) k
                 WHERE k IN ('interest_auto_post','fixed_deposit_auto_renew')
    LOOP
        IF NULLIF(p->>v_key,'') IS NOT NULL AND lower(p->>v_key) NOT IN ('true','false') THEN
            RETURN format('%s "%s" must be true or false', v_key, p->>v_key);
        END IF;
    END LOOP;
    FOR v_key IN SELECT k FROM jsonb_object_keys(p) k
                 WHERE k IN ('schedule_interval','interest_credit_interval','schedule_day_of_month',
                             'interest_credit_day_of_month','interest_posting_day_of_month','claim_deadline_hours','priority')
    LOOP
        IF NULLIF(p->>v_key,'') IS NOT NULL AND (p->>v_key) !~ '^\s*-?\d+\s*$' THEN
            RETURN format('%s "%s" must be a whole number', v_key, p->>v_key);
        END IF;
    END LOOP;
    FOR v_key IN SELECT k FROM jsonb_object_keys(p) k
                 WHERE k IN ('opening_balance','interest_rate','annual_premium','premium_amount','coverage_amount','current_value',
                             'contribution_amount','guaranteed_monthly_pension','amount','target_amount',
                             'monthly_savings_rate','original_amount','current_balance','monthly_annuity',
                             'shares','price_per_share','order_fee','reached_claim','projection','em_monthly')
    LOOP
        IF NULLIF(p->>v_key,'') IS NOT NULL THEN
            BEGIN PERFORM (p->>v_key)::numeric;
            EXCEPTION WHEN OTHERS THEN RETURN format('%s "%s" must be a number', v_key, p->>v_key); END;
        END IF;
    END LOOP;
    IF NULLIF(p->>'interest_credit_unit','') IS NOT NULL THEN
        BEGIN PERFORM (p->>'interest_credit_unit')::finance.schedule_unit;
        EXCEPTION WHEN OTHERS THEN
            RETURN format('interest_credit_unit "%s" invalid (day|week|month|year)', p->>'interest_credit_unit');
        END;
    END IF;

    -- Name ist Pflicht (ausser stock_buy = Buchung [symbol] und pension_statement [pension-Ref])
    IF p_type NOT IN ('stock_buy','pension_statement') AND v_name IS NULL THEN
        RETURN 'name is required';
    END IF;

    -- Namens-Dublette IM Batch (gleicher Typ, gleicher Name, andere Row). Nicht fuer stock_buy: der Name ist dort
    -- nur Bezeichnung, derselbe ETF in zwei Depots ist legitim; eine echte Positions-Dublette (Depot + ISIN/Symbol)
    -- meldet der Probelauf (fn_import_bundle dry_run -> fn_book_stock_buy "already holds").
    IF v_name IS NOT NULL AND p_type <> 'stock_buy' THEN
        SELECT COUNT(*) INTO v_hits FROM finance.import_staging s
        WHERE s.batch_id = p_batch_id AND s.row_no <> p_row_no
          AND s.entity_type = p_type AND lower(s.payload->>'name') = lower(v_name)
          AND s.status <> 'committed';
        IF v_hits > 0 THEN
            RETURN format('duplicate name "%s" within this batch', v_name);
        END IF;
    END IF;

    -- ---------- per entity_type ----------
    IF p_type = 'account' THEN
        BEGIN PERFORM (p->>'account_type')::finance.account_type;
        EXCEPTION WHEN OTHERS THEN
            RETURN format('account_type "%s" invalid (cash|p2p|stocks_depot|crypto_depot|fixed_deposit)', p->>'account_type');
        END;
        IF p->>'account_type' IS NULL THEN RETURN 'account_type is required'; END IF;
        IF p->>'account_type' = 'loan' THEN
            RETURN 'loans are imported as entity_type loan (with remaining debt and rate), not as an account';
        END IF;
        IF p->>'account_type' IN ('stocks_depot','crypto_depot') AND COALESCE(NULLIF(p->>'opening_balance','')::numeric, 0) <> 0 THEN
            RETURN 'a depot has no cash balance - put opening_balance on its settlement account';
        END IF;
        -- DB-ist-das-Gesetz S4 (Spiegel von fn_create_account): Festgeld braucht Zinssatz UND Faelligkeit
        IF p->>'account_type' = 'fixed_deposit' THEN
            v_ref := finance.fn_fixed_deposit_reason(NULLIF(p->>'interest_rate','')::numeric,
                                                     NULLIF(p->>'fixed_deposit_maturity_date','')::date);
            IF v_ref IS NOT NULL THEN RETURN v_ref; END IF;
        END IF;
        -- Dublette = aktives Konto gleichen Namens, typ-uebergreifend: Import-Referenzen (depot/account/
        -- debit_account) loesen nur ueber den NAMEN auf, ein zweites Konto gleichen Namens machte sie mehrdeutig.
        SELECT hit_count INTO v_hits FROM finance.fn_resolve_account(v_name, NULL, TRUE);
        IF v_hits > 0 THEN
            RETURN format('account "%s" already exists - to set its balance use reconcile_account, to change its details use set_account; remove this row', v_name);
        END IF;
        -- Monats-Check WP-B: dieselbe Kontonummer/IBAN = dasselbe Konto, auch unter anderem Namen (Auszug druckt
        -- "Girokonto 4931", das System kennt es als "Sparkasse Giro").
        SELECT a.name INTO v_ref FROM finance.accounts a
        WHERE a.status = 'active' AND a.account_number = finance.fn_normalize_account_number(p->>'account_number');
        IF v_ref IS NOT NULL THEN
            RETURN format('this account number already belongs to the existing account "%s" - to set its balance use reconcile_account on "%s"; remove this row', v_ref, v_ref);
        END IF;
        IF p->>'account_type' IN ('stocks_depot','crypto_depot') THEN
            v_ref := NULLIF(trim(COALESCE(p->>'settlement_account','')), '');
            IF v_ref IS NULL THEN RETURN 'depot accounts require settlement_account (name of the cash account)'; END IF;
            IF finance.fn_import_ref_account(p_batch_id, v_ref) IS NULL THEN
                RETURN format('settlement_account "%s" not found (neither existing nor in this batch)', v_ref);
            END IF;
        END IF;
        IF NULLIF(p->>'opening_balance','') IS NOT NULL THEN
            BEGIN PERFORM (p->>'opening_balance')::numeric;
            EXCEPTION WHEN OTHERS THEN RETURN 'opening_balance must be numeric'; END;
        END IF;

    ELSIF p_type = 'stock_buy' THEN
        -- Kennung = Ticker ODER ISIN (fn_holding_symbol); eine Vermoegensuebersicht druckt oft nur die ISIN (2026-10-23)
        IF finance.fn_holding_symbol(p->>'symbol', p->>'isin') IS NULL THEN
            RETURN 'symbol (ticker; for crypto the coin symbol) or isin is required';
        END IF;
        v_ref := NULLIF(trim(COALESCE(p->>'depot','')), '');
        IF v_ref IS NULL THEN RETURN 'depot (name of the depot account) is required'; END IF;
        v_acct_type := finance.fn_import_ref_account_type(p_batch_id, v_ref);
        IF v_acct_type IS NULL THEN
            RETURN format('depot "%s" not found (neither existing nor in this batch)', v_ref);
        ELSIF v_acct_type NOT IN ('stocks_depot','crypto_depot') THEN
            RETURN format('depot "%s" is type %s — needs stocks_depot or crypto_depot', v_ref, v_acct_type);
        ELSIF v_acct_type = 'stocks_depot' AND NULLIF(trim(COALESCE(p->>'isin','')),'') IS NULL THEN
            RETURN 'isin is required for a stocks_depot position';
        END IF;
        -- gedruckte Depotnummer/Inhaber gegen das gewaehlte Depot (fn_import_depot_conflict, auch im Bundle) -- VOR
        -- dem Einstand: ein falsches Depot klaert der Agent zuerst
        v_key := finance.fn_import_depot_conflict(p_batch_id, p);
        IF v_key IS NOT NULL THEN RETURN v_key; END IF;
        v_num := NULLIF(p->>'shares','')::numeric;
        IF v_num IS NULL OR v_num <= 0 THEN RETURN 'shares must be a positive number'; END IF;
        v_num := NULLIF(p->>'price_per_share','')::numeric;
        IF v_num IS NULL THEN
            RETURN 'purchase price missing: ask the user for the purchase price per unit (price_per_share) or the total purchase value of the position (cost_basis_total) - never the current market price or market value';
        ELSIF v_num <= 0 THEN
            RETURN 'price_per_share must be a positive number';
        END IF;
        -- Import-Positionen sind Bestandsuebernahmen: eine schon gehaltene Position wuerde verdoppelt
        SELECT h.shares INTO v_num
        FROM finance.depot_holdings h JOIN finance.accounts a ON a.id = h.account_id
        WHERE lower(a.name) = lower(v_ref) AND a.status = 'active'
          AND ((NULLIF(p->>'isin','') IS NOT NULL AND h.isin = p->>'isin')
               OR (NULLIF(p->>'isin','') IS NULL AND h.isin IS NULL AND h.symbol = p->>'symbol'))
        LIMIT 1;
        IF COALESCE(v_num, 0) > 0 THEN
            RETURN format('depot "%s" already holds %s units of %s - to correct the holding use set_holding; remove this row', v_ref, v_num, finance.fn_holding_symbol(p->>'symbol', p->>'isin'));
        END IF;

    ELSIF p_type = 'insurance' THEN
        -- Spiegel fn_create_insurance (WP2): Beitrag je Abbuchung (+ Rhythmus) ODER Jahresbeitrag -- dieselbe Pruef-fn.
        v_fields := finance.fn_insurance_fields(p);
        IF (v_fields->>'ok')::boolean IS DISTINCT FROM true THEN RETURN v_fields->>'reason'; END IF;
        IF v_fields->>'premium_amount' IS NULL THEN
            RETURN 'the premium is required: premium_amount (per debit, with schedule_unit) or annual_premium';
        END IF;
        IF NULLIF(p->>'first_payment_date','') IS NULL THEN RETURN 'first_payment_date is required'; END IF;
        v_ref := NULLIF(trim(COALESCE(p->>'debit_account','')), '');
        IF v_ref IS NULL THEN RETURN 'debit_account (account name) is required'; END IF;
        IF finance.fn_import_ref_account(p_batch_id, v_ref) IS NULL THEN
            RETURN format('debit_account "%s" not found (neither existing nor in this batch)', v_ref);
        END IF;
        -- Spiegel fn_create_insurance: Praemien sind EUR nach Modell
        IF finance.fn_import_ref_currency(p_batch_id, v_ref) IS DISTINCT FROM 'EUR' THEN
            RETURN format('insurance premiums are kept in EUR - debit_account "%s" is in %s; use a EUR account', v_ref, finance.fn_import_ref_currency(p_batch_id, v_ref));
        END IF;
        SELECT hit_count INTO v_hits FROM finance.fn_resolve_insurance(v_name, FALSE);
        IF v_hits > 0 THEN RETURN format('insurance "%s" already exists', v_name); END IF;

    ELSIF p_type = 'pension' THEN
        BEGIN PERFORM (p->>'pension_type')::finance.pension_type;
        EXCEPTION WHEN OTHERS THEN
            RETURN format('pension_type "%s" invalid (statutory|occupational|riester|ruerup|private)', p->>'pension_type');
        END;
        IF p->>'pension_type' IS NULL THEN RETURN 'pension_type is required'; END IF;
        -- Spiegel CHECK finance_pension_statutory_no_amounts: die Betraege gehoeren in die Renteninformation
        IF p->>'pension_type' = 'statutory' AND (NULLIF(p->>'guaranteed_monthly_pension','') IS NOT NULL
                                                 OR NULLIF(p->>'current_value','') IS NOT NULL) THEN
            RETURN 'a statutory pension stores no monthly pension or value of its own - put the figures into a pension_statement row';
        END IF;
        -- WP2: Beitrags-Rhythmus roh (Spiegel fn_create_pension, Default monatlich)
        IF NULLIF(p->>'schedule_unit','') IS NOT NULL THEN
            BEGIN PERFORM (p->>'schedule_unit')::finance.schedule_unit;
            EXCEPTION WHEN OTHERS THEN
                RETURN format('schedule_unit "%s" invalid (day|week|month|year; empty = month)', p->>'schedule_unit');
            END;
        END IF;
        IF NULLIF(p->>'schedule_interval','') IS NOT NULL AND (p->>'schedule_interval')::int < 1 THEN
            RETURN 'schedule_interval must be at least 1';
        END IF;
        IF NULLIF(p->>'contribution_amount','') IS NOT NULL AND (p->>'contribution_amount')::numeric > 0 THEN
            v_ref := NULLIF(trim(COALESCE(p->>'debit_account','')), '');
            IF v_ref IS NULL THEN RETURN 'contribution_amount set — debit_account (name) is required'; END IF;
            IF finance.fn_import_ref_account(p_batch_id, v_ref) IS NULL THEN
                RETURN format('debit_account "%s" not found', v_ref);
            END IF;
            IF NULLIF(p->>'first_payment_date','') IS NULL THEN RETURN 'contribution_amount set — first_payment_date is required'; END IF;
        END IF;
        SELECT hit_count INTO v_hits FROM finance.fn_resolve_pension(v_name, FALSE);
        IF v_hits > 0 THEN RETURN format('pension "%s" already exists', v_name); END IF;

    ELSIF p_type = 'recurring_payment' THEN
        IF COALESCE(p->>'direction','') NOT IN ('income','expense') THEN
            RETURN format('direction "%s" invalid (income|expense)', COALESCE(p->>'direction','<null>'));
        END IF;
        v_num := NULLIF(p->>'amount','')::numeric;
        IF v_num IS NULL OR v_num <= 0 THEN RETURN 'amount must be a positive number'; END IF;
        BEGIN PERFORM (p->>'schedule_unit')::finance.schedule_unit;
        EXCEPTION WHEN OTHERS THEN
            RETURN format('schedule_unit "%s" invalid (day|week|month|year)', p->>'schedule_unit');
        END;
        IF p->>'schedule_unit' IS NULL THEN RETURN 'schedule_unit is required'; END IF;
        IF NULLIF(p->>'first_payment_date','') IS NULL THEN RETURN 'first_payment_date is required'; END IF;
        v_ref := NULLIF(trim(COALESCE(p->>'account','')), '');
        IF v_ref IS NULL THEN RETURN 'account (name) is required'; END IF;
        IF finance.fn_import_ref_account(p_batch_id, v_ref) IS NULL THEN
            RETURN format('account "%s" not found (neither existing nor in this batch)', v_ref);
        END IF;
        SELECT hit_count INTO v_hits FROM finance.fn_resolve_recurring_payment(v_name, FALSE);
        IF v_hits > 0 THEN RETURN format('recurring payment "%s" already exists', v_name); END IF;

    ELSIF p_type = 'real_estate' THEN
        v_num := NULLIF(p->>'current_value','')::numeric;
        IF v_num IS NULL OR v_num < 0 THEN RETURN 'current_value must be a non-negative number'; END IF;
        -- Instandhaltungsruecklage (2026-10-27): Wohnflaeche/Baujahr optional, dieselbe Pruefung wie die create-fn
        v_facts := finance.fn_real_estate_facts_reason(p);
        IF v_facts IS NOT NULL THEN RETURN v_facts; END IF;
        SELECT hit_count INTO v_hits FROM finance.fn_resolve_real_estate(v_name, FALSE);
        IF v_hits > 0 THEN RETURN format('real estate "%s" already exists', v_name); END IF;

    ELSIF p_type = 'savings_goal' THEN
        v_num := NULLIF(p->>'target_amount','')::numeric;
        IF v_num IS NULL OR v_num <= 0 THEN RETURN 'target_amount must be a positive number'; END IF;
        -- WP2: first_payment_date optional (fn_savings_rate_schedule: naechster Abbuchungstag ab heute)
        -- 2026-10-27: mit Sparplan(en) darf beides fehlen (das Datum folgt aus ihrem Monatsbetrag, fn_create_savings_goal)
        IF NULLIF(p->>'target_date','') IS NOT NULL AND NULLIF(p->>'monthly_savings_rate','') IS NOT NULL THEN
            RETURN 'provide EXACTLY ONE of target_date or monthly_savings_rate (the DB derives the other)';
        END IF;
        IF NULLIF(p->>'target_date','') IS NULL AND NULLIF(p->>'monthly_savings_rate','') IS NULL
           AND NULLIF(trim(COALESCE(p->>'savings_plan','')), '') IS NULL THEN
            RETURN 'provide target_date or monthly_savings_rate (the DB derives the other), or savings_plan';
        END IF;
        IF lower(COALESCE(NULLIF(p->>'replace_transfer',''), 'true')) NOT IN ('true', 'false') THEN
            RETURN 'replace_transfer must be true or false';
        END IF;
        -- Sparziel-Zweckbindung 2026-10-27: das Abbuchungskonto ist nur fuer eine Rate noetig -> optional, wenn ein
        -- Startbestand (already_saved) das Ziel deckt oder ein Sparplan es finanziert (fn_create_savings_goal ist das Gesetz).
        IF NULLIF(p->>'already_saved','')::numeric < 0 THEN RETURN 'already_saved must not be negative'; END IF;
        v_ref := NULLIF(trim(COALESCE(p->>'account','')), '');
        IF v_ref IS NULL AND COALESCE(NULLIF(p->>'already_saved','')::numeric, 0) < v_num
           AND NULLIF(trim(COALESCE(p->>'savings_plan','')), '') IS NULL THEN
            RETURN 'account (name of the account the monthly rate is debited from) is required unless already_saved covers the goal or a savings_plan funds it';
        END IF;
        IF v_ref IS NOT NULL AND finance.fn_import_ref_account(p_batch_id, v_ref) IS NULL THEN
            RETURN format('account "%s" not found (neither existing nor in this batch)', v_ref);
        END IF;
        -- Audit Paket 3: ein Sparziel braucht ein Sparkonto (Topf), Gesetz in fn_create_savings_goal -> hier vorab
        -- als Zeilenfehler (vor dem Gate), statt erst beim Commit.
        IF NULLIF(trim(COALESCE(p->>'reserve_account','')), '') IS NULL THEN
            RETURN 'reserve_account (name of the account that holds or receives the money) is required';
        END IF;
        IF v_ref IS NOT NULL AND lower(trim(p->>'reserve_account')) = lower(v_ref) THEN
            RETURN 'reserve_account must differ from the funding account';
        END IF;
        IF finance.fn_import_ref_account(p_batch_id, trim(p->>'reserve_account')) IS NULL THEN
            RETURN format('reserve_account "%s" not found (neither existing nor in this batch)', trim(p->>'reserve_account'));
        END IF;
        -- wie fn_create_savings_goal: Topf = saldo-basiertes Konto oder Depot (vor dem Gate, nicht erst beim Commit)
        IF NOT COALESCE(finance.fn_import_ref_account_type(p_batch_id, trim(p->>'reserve_account')), '')
               = ANY (finance.fn_goal_earmark_account_types()::text[]) THEN
            RETURN format('reserve_account "%s" must be a cash/Tagesgeld, fixed-deposit, P2P or depot account', trim(p->>'reserve_account'));
        END IF;
        -- Depot als Topf nur mit Startbestand oder Sparplan (eine Rate kann nicht direkt in ein Depot fliessen)
        IF finance.fn_import_ref_account_type(p_batch_id, trim(p->>'reserve_account')) IN ('stocks_depot', 'crypto_depot')
           AND COALESCE(NULLIF(p->>'already_saved','')::numeric, 0) <= 0
           AND NULLIF(trim(COALESCE(p->>'savings_plan','')), '') IS NULL THEN
            RETURN format('reserve_account "%s" is a depot - give already_saved (money already there) or savings_plan (the plan that buys into it)', trim(p->>'reserve_account'));
        END IF;
        -- Bestehender Dauerauftrag in einen Topf aus der DB (wie fn_create_savings_goal, Livebefund 2026-10-27): vor dem
        -- Gate als Zeilenfehler statt erst beim Commit; die Zeile braucht replace_transfer (true = fortfuehren).
        IF NULLIF(p->>'replace_transfer','') IS NULL AND NULLIF(trim(COALESCE(p->>'savings_plan','')), '') IS NULL
           AND COALESCE(NULLIF(p->>'already_saved','')::numeric, 0) < v_num
           AND finance.fn_import_ref_account(p_batch_id, trim(p->>'reserve_account')) = 'db'
           -- ein im Batch neues Abbuchungskonto hat noch keinen Dauerauftrag (der Commit filtert nach seiner neuen id)
           AND (v_ref IS NULL OR finance.fn_import_ref_account(p_batch_id, v_ref) = 'db')
           AND jsonb_array_length(finance.fn_goal_transfer_candidates(
                   (SELECT r.id FROM finance.fn_resolve_account(trim(p->>'reserve_account'), NULL, TRUE) r),
                   CASE WHEN v_ref IS NOT NULL THEN (SELECT r.id FROM finance.fn_resolve_account(v_ref, NULL, TRUE) r) END)) > 0 THEN
            RETURN format('a standing transfer already pays into "%s" - set replace_transfer to true (the goal continues it) or false (the goal rate comes on top)', trim(p->>'reserve_account'));
        END IF;
        SELECT hit_count INTO v_hits FROM finance.fn_resolve_savings_goal(v_name, FALSE);
        IF v_hits > 0 THEN RETURN format('savings goal "%s" already exists', v_name); END IF;

    ELSIF p_type = 'loan' THEN
        -- Spiegel fn_create_loan: laufend = current_balance gesetzt und (kein original_amount oder kleiner) -> keine
        -- Ursprungswerte noetig; sonst frisch -> Betrag + Auszahlungsdatum Pflicht.
        v_num := NULLIF(p->>'original_amount','')::numeric;
        IF v_num IS NOT NULL AND v_num <= 0 THEN RETURN 'original_amount must be a positive number'; END IF;
        IF NULLIF(p->>'interest_rate','') IS NULL THEN RETURN 'interest_rate is required'; END IF;
        IF NULLIF(p->>'current_balance','') IS NOT NULL
           AND ((p->>'current_balance')::numeric <= 0 OR (p->>'current_balance')::numeric > v_num) THEN
            RETURN 'current_balance (remaining debt) must be greater than 0 and not above original_amount';
        END IF;
        -- WP2: ein frischer Kredit ohne Auszahlungsdatum eroeffnet zum Stichtag heute (Datum spaeter nachtragbar)
        IF NULLIF(p->>'current_balance','') IS NULL AND v_num IS NULL THEN
            RETURN 'the remaining debt is required: current_balance (running loan) or original_amount (new loan)';
        END IF;
        IF NULLIF(p->>'disbursement_date','')::date > core.fn_today() THEN
            RETURN 'disbursement_date lies in the future - record the loan once it has been paid out';
        END IF;
        IF NULLIF(p->>'term_end_date','') IS NOT NULL
           AND ((p->>'term_end_date')::date < NULLIF(p->>'interest_rate_fixed_until','')::date
                OR (p->>'term_end_date')::date < NULLIF(p->>'disbursement_date','')::date) THEN
            RETURN 'term_end_date must not be before interest_rate_fixed_until or disbursement_date';
        END IF;
        -- die Rate muss den Monatszins der Restschuld decken (fn_create_loan; sonst scheiterte jede Buchung)
        IF NULLIF(p->>'monthly_annuity','') IS NOT NULL
           AND (p->>'monthly_annuity')::numeric < finance.fn_loan_monthly_interest(
                   COALESCE(NULLIF(p->>'current_balance','')::numeric, v_num), (p->>'interest_rate')::numeric) THEN
            RETURN format('monthly_annuity %s does not cover the monthly interest %s on the remaining debt',
                          p->>'monthly_annuity', finance.fn_loan_monthly_interest(
                              COALESCE(NULLIF(p->>'current_balance','')::numeric, v_num), (p->>'interest_rate')::numeric));
        END IF;
        v_ref := NULLIF(trim(COALESCE(p->>'debit_account','')), '');
        IF v_ref IS NULL THEN RETURN 'debit_account (name) is required'; END IF;
        IF finance.fn_import_ref_account(p_batch_id, v_ref) IS NULL THEN
            RETURN format('debit_account "%s" not found', v_ref);
        END IF;
        -- Spiegel der fn_create_loan-Regeln (Fehler vor dem Gate statt Rollback nach der Freigabe)
        IF finance.fn_import_ref_currency(p_batch_id, v_ref) IS DISTINCT FROM 'EUR' THEN
            RETURN format('loans are kept in EUR - debit_account "%s" is in %s; use a EUR account', v_ref, finance.fn_import_ref_currency(p_batch_id, v_ref));
        END IF;
        IF NULLIF(p->>'monthly_annuity','') IS NOT NULL AND NULLIF(p->>'first_payment_date','') IS NULL THEN
            RETURN 'first_payment_date (the next rate debit) is required when monthly_annuity is given';
        END IF;
        v_ref := NULLIF(trim(COALESCE(p->>'disbursement_account','')), '');
        IF v_ref IS NOT NULL THEN
            IF finance.fn_import_ref_account(p_batch_id, v_ref) IS NULL THEN
                RETURN format('disbursement_account "%s" not found', v_ref);
            END IF;
            IF finance.fn_import_ref_currency(p_batch_id, v_ref) IS DISTINCT FROM 'EUR' THEN
                RETURN format('loans are kept in EUR - disbursement_account "%s" is not a EUR account', v_ref);
            END IF;
            IF v_num IS NULL OR COALESCE(NULLIF(p->>'current_balance','')::numeric, v_num) < v_num THEN
                RETURN 'a loan that is already being repaid has no disbursement_account (the payout is part of today''s balance) - remove it';
            END IF;
            IF NULLIF(p->>'disbursement_date','') IS NULL THEN
                RETURN 'a payout into one of your own accounts (disbursement_account) needs the disbursement_date';
            END IF;
        END IF;
        v_ref := NULLIF(trim(COALESCE(p->>'real_estate','')), '');
        IF v_ref IS NOT NULL THEN
            SELECT hit_count INTO v_hits FROM finance.fn_resolve_real_estate(v_ref, FALSE);
            IF v_hits <> 1 AND NOT EXISTS (
                SELECT 1 FROM finance.import_staging s
                WHERE s.batch_id = p_batch_id AND s.entity_type = 'real_estate'
                  AND lower(s.payload->>'name') = lower(v_ref) AND s.status <> 'committed') THEN
                RETURN format('real_estate "%s" not found (neither existing nor in this batch)', v_ref);
            END IF;
        END IF;
        SELECT hit_count INTO v_hits FROM finance.fn_resolve_loan(v_name, FALSE);
        IF v_hits > 0 THEN RETURN format('loan "%s" already exists', v_name); END IF;

    ELSIF p_type = 'pension_statement' THEN
        -- datierter Standmitteilungs-Snapshot (Renteninformation/bAV/NPS) -> finance_pension_statements
        v_ref := NULLIF(trim(COALESCE(p->>'pension','')), '');
        IF v_ref IS NULL THEN RETURN 'pension (name of the pension entity) is required'; END IF;
        -- pension_id setzt fn_import_stage, wenn sich ein Folgebescheid an die vorhandene gesetzliche Rente haengt
        IF NULLIF(p->>'pension_id','') IS NOT NULL THEN
            IF NOT EXISTS (SELECT 1 FROM finance.pension WHERE id = (p->>'pension_id')::int AND status = 'active') THEN
                RETURN format('pension_id %s is not an active pension', p->>'pension_id');
            END IF;
            v_hits := 1;
        ELSE
            SELECT hit_count INTO v_hits FROM finance.fn_resolve_pension(v_ref, FALSE);
        END IF;
        IF v_hits <> 1 AND NOT EXISTS (
            SELECT 1 FROM finance.import_staging s
            WHERE s.batch_id = p_batch_id AND s.entity_type = 'pension'
              AND lower(s.payload->>'name') = lower(v_ref) AND s.status <> 'committed') THEN
            RETURN format('pension "%s" not found (neither existing nor in this batch)', v_ref);
        END IF;
        IF NULLIF(p->>'statement_date','') IS NULL THEN RETURN 'statement_date is required'; END IF;
        IF NULLIF(p->>'reached_claim','') IS NULL AND NULLIF(p->>'projection','') IS NULL
           AND NULLIF(p->>'em_monthly','') IS NULL AND NULLIF(p->>'scenario_1pct','') IS NULL
           AND NULLIF(p->>'scenario_2pct','') IS NULL THEN
            RETURN 'at least one of reached_claim, projection, scenario_1pct, scenario_2pct, em_monthly is required';
        END IF;
        PERFORM (p->>'statement_date')::date, NULLIF(p->>'regular_retirement_date','')::date;
        -- Spiegel der CHECKs finance_pension_statements_nonneg/_scenarios_rise (vertauschte Werte aus der Auslesung)
        IF LEAST(COALESCE(NULLIF(p->>'reached_claim','')::numeric, 0), COALESCE(NULLIF(p->>'projection','')::numeric, 0),
                 COALESCE(NULLIF(p->>'scenario_1pct','')::numeric, 0), COALESCE(NULLIF(p->>'scenario_2pct','')::numeric, 0),
                 COALESCE(NULLIF(p->>'em_monthly','')::numeric, 0), COALESCE(NULLIF(p->>'earning_points','')::numeric, 0)) < 0 THEN
            RETURN 'amounts and earning points of a pension statement must not be negative';
        END IF;
        IF NULLIF(p->>'scenario_1pct','')::numeric < NULLIF(p->>'projection','')::numeric
           OR NULLIF(p->>'scenario_2pct','')::numeric < NULLIF(p->>'scenario_1pct','')::numeric
           OR NULLIF(p->>'scenario_2pct','')::numeric < NULLIF(p->>'projection','')::numeric THEN
            RETURN 'the scenarios must rise with the adjustment rate (projection <= 1 % scenario <= 2 % scenario) - check the printed values';
        END IF;
    END IF;

    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    -- jeder unerwartete Cast-/Datenfehler wird zum freundlichen Row-Fehler, nie zum Abort
    RETURN format('invalid payload: %s', SQLERRM);
END;
$$;

-- ============================================================
-- fn_import_ref_account / fn_import_ref_account_type — Referenz-Aufloesung fuer die
-- Validierung: existiert das Konto im BESTAND (fn_resolve_account, eindeutig) ODER als
-- account-Row im SELBEN Batch? Liefert 'db'/'batch' bzw. den account_type (Bestand oder
-- Batch-Payload) — NULL = nicht auffindbar.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_ref_account(p_batch_id uuid, p_name text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_hits INT;
BEGIN
    SELECT hit_count INTO v_hits FROM finance.fn_resolve_account(p_name, NULL, TRUE);
    IF v_hits = 1 THEN RETURN 'db'; END IF;
    IF EXISTS (SELECT 1 FROM finance.import_staging s
               WHERE s.batch_id = p_batch_id AND s.entity_type = 'account'
                 AND lower(s.payload->>'name') = lower(p_name) AND s.status <> 'committed') THEN
        RETURN 'batch';
    END IF;
    RETURN NULL;
END;
$$;

-- fn_import_ref_currency — Waehrung des referenzierten Kontos (Batch-Zeile ODER Bestand), exakt wie
-- fn_create_account sie setzen wird: genannte currency, sonst bei einem Depot die seines Verrechnungskontos,
-- sonst EUR. Die EINE Adresse fuer validate_row (EUR-Pflicht Versicherung/Kredit vor dem Gate) und die
-- Import-Karte (Betrag in der Zeilen-Waehrung). NULL = Konto nicht auffindbar.
CREATE OR REPLACE FUNCTION finance.fn_import_ref_currency(p_batch_id uuid, p_name text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE v_row JSONB; v_ccy TEXT;
BEGIN
    SELECT s.payload INTO v_row FROM finance.import_staging s
    WHERE s.batch_id = p_batch_id AND s.entity_type = 'account'
      AND lower(s.payload->>'name') = lower(p_name) AND s.status <> 'committed'
    LIMIT 1;
    IF v_row IS NOT NULL THEN
        v_ccy := upper(NULLIF(v_row->>'currency', ''));
        IF v_ccy IS NULL AND NULLIF(v_row->>'settlement_account', '') IS NOT NULL
           AND lower(v_row->>'settlement_account') <> lower(p_name) THEN
            v_ccy := finance.fn_import_ref_currency(p_batch_id, v_row->>'settlement_account');
        END IF;
        RETURN COALESCE(v_ccy, 'EUR');
    END IF;
    SELECT a.currency INTO v_ccy FROM finance.accounts a
    WHERE lower(a.name) = lower(p_name) AND a.status = 'active'
    LIMIT 1;
    RETURN v_ccy;
END;
$$;

CREATE OR REPLACE FUNCTION finance.fn_import_ref_account_type(p_batch_id uuid, p_name text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_type TEXT;
BEGIN
    SELECT a.account_type::text INTO v_type
    FROM finance.accounts a WHERE lower(a.name) = lower(p_name) AND a.status = 'active'
    LIMIT 1;
    IF v_type IS NOT NULL THEN RETURN v_type; END IF;
    SELECT s.payload->>'account_type' INTO v_type
    FROM finance.import_staging s
    WHERE s.batch_id = p_batch_id AND s.entity_type = 'account'
      AND lower(s.payload->>'name') = lower(p_name) AND s.status <> 'committed'
    LIMIT 1;
    RETURN v_type;
END;
$$;
