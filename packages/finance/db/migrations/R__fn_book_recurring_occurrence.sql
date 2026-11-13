-- ============================================================
-- fn_book_recurring_occurrence (ATOMIC WRITE)
--   Bucht ein faelliges Vorkommen einer recurring_payment als echte Transaktion auf ihr Konto (signed amount),
--   verknuepft via recurring_payment_id + recurring_due_date (= Faelligkeit, die Identitaet des Vorkommens).
--   "gebucht" ist damit aus finance.transactions ableitbar (keine eigene Status-Tabelle).
--   Eingabe jsonb: recurring_payment_id, due_date (Pflicht); amount (optional), transaction_date (optional,
--   Ist-Datum, Default due_date).
--   Ist-Datum: der Kontoauszug bucht die Abbuchung an ihrem echten Tag (Miete faellig 01.10., abgebucht 02.10.);
--   die Identitaet bleibt die Faelligkeit -> das Vorkommen ist erledigt, egal an welchem Tag.
--   Betrags-Anpassung: `amount` ist die Magnitude des Ist-Betrags. Vorhanden -> bucht sign(rp.amount)*abs(amount)
--   (Einnahme/Ausgabe-Richtung bleibt), Abweichung in der description. Fehlt -> der fixe rp.amount.
--   Transfer-Delegation: ist die rp ein interner Transfer (target_account_id gesetzt), delegiert die fn an
--   fn_book_recurring_transfer (zwei Beine; nimmt amount + transaction_date mit).
--   Kredit-Delegation: gehoert die rp-Kette einem Kredit (loans.recurring_payment_id), bucht die fn ueber
--   fn_book_loan_payment (Giro-Abbuchung + Tilgung, rp-Stempel auf dem Giro-Bein).
--   Rueckgabe: ok:true -> {ok:true, transaction_id, amount, plan_amount, effective}; Kredit zusaetzlich
--   interest_portion, principal_amount, remaining_debt, loan_status (transaction_id = Giro-Bein); Transfer: Return
--   von fn_book_recurring_transfer.
--   ok:false ohne RAISE: {code:'already_booked'} (schon ein Tx fuer (rp_id, Faelligkeit)); {code:'reconciled'}
--   (Buchungsdatum <= letzter Saldo-Abgleich des Kontos, fn_reconciled_reason; der Abgleich enthaelt die Bewegung
--   schon -> sonst Doppelzaehlung); {code:'invalid_date'}; {reason} bei amount <= 0 oder Konto ohne freie Buchung
--   (fn_bookable_account_reason). RAISE bei unbekannter rp.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_recurring_occurrence(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_rp_id    INT  := (p->>'recurring_payment_id')::int;
    v_due      DATE := (p->>'due_date')::date;
    v_date     DATE;
    v_override NUMERIC := NULLIF(p->>'amount', '')::numeric;
    v_acct     INT;
    v_target   INT;
    v_amount   NUMERIC;
    v_book_amt NUMERIC;
    v_name     TEXT;
    v_tx       INT;
    v_loan_id  INT;
    v_loan_acc INT;
    v_loan_res JSONB;
    v_reason   TEXT;
    v_dates    JSONB;
BEGIN
    -- due_date kommt aus dem DB-Lookup (Vorkommen-Identitaet), nie vom LLM -> nicht aufgeloest.
    v_dates := core.fn_resolve_input_dates(p, ARRAY['transaction_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_date := COALESCE(NULLIF(p->>'transaction_date', '')::date, (p->>'due_date')::date);
    SELECT account_id, target_account_id, amount, name INTO v_acct, v_target, v_amount, v_name
    FROM finance.recurring_payments WHERE id = v_rp_id;
    IF v_acct IS NULL THEN
        RAISE EXCEPTION 'Recurring payment % not found.', v_rp_id;
    END IF;

    -- Interner Transfer -> zwei-beinig (Soll/Haben) buchen; eigene Idempotenz/Sperren/Return-Shape.
    IF v_target IS NOT NULL THEN
        RETURN finance.fn_book_recurring_transfer(p);
    END IF;

    -- Idempotenz vor dem amount-Guard, damit ein bereits gebuchtes Vorkommen die "already booked"-Meldung
    -- liefert, nicht "amount must be positive".
    IF EXISTS (SELECT 1 FROM finance.transactions
               WHERE recurring_payment_id = v_rp_id AND recurring_due_date = v_due) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_booked',
            'reason', 'Recurring occurrence for payment ' || v_rp_id || ' due ' || v_due
                   || ' is already booked.');
    END IF;

    -- transactions hat keinen amount<>0-CHECK -> der angepasste Betrag muss hier eine positive Magnitude sein.
    IF v_override IS NOT NULL AND v_override <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Adjusted amount must be a positive magnitude, got ' || COALESCE(v_override::text, 'null') || '.');
    END IF;

    -- Kredit-Delegation: gehoert die rp-Kette einem Kredit (Besitzer zeigt auf den Kopf -> auch ein altes Vorkommen
    -- einer gesplitteten Rate), ist das Vorkommen eine Kreditrate -> zweibeinig ueber fn_book_loan_payment
    -- (Giro-Abbuchung + Tilgung aufs Kreditkonto; dort auch die Abgleich-Sperre). Ohne Override bucht die Rate den
    -- Betrag aus fn_recurring_occurrence_amount (= was die Erinnerung zeigt; letzte, kleinere Rate = Abloesebetrag).
    -- Ein Nutzer-Betrag (Override) wird nie still geaendert.
    SELECT id, loan_account_id INTO v_loan_id, v_loan_acc
    FROM finance.loans WHERE recurring_payment_id = finance.fn_recurring_lineage_head(v_rp_id);
    IF v_loan_id IS NOT NULL THEN
        v_book_amt := COALESCE(abs(v_override), abs(finance.fn_recurring_occurrence_amount(v_rp_id, v_due)));
        v_loan_res := finance.fn_book_loan_payment(jsonb_build_object(
            'loan_id',              v_loan_id,
            'loan_account_id',      v_loan_acc,
            'debit_account_id',     v_acct,
            'payment_amount',       v_book_amt,
            'payment_date',         v_date,
            'transaction_date',     v_date,
            'due_date',             v_due,
            'recurring_payment_id', v_rp_id));
        IF (v_loan_res->>'ok')::boolean IS DISTINCT FROM true THEN
            RETURN v_loan_res;
        END IF;
        RETURN jsonb_build_object('ok', true,
            'transaction_id',   (v_loan_res->>'loan_payment_tx_id')::int,
            'amount',           -v_book_amt,
            'plan_amount',      v_amount,
            'interest_portion', (v_loan_res->>'interest_portion')::numeric,
            'principal_amount', (v_loan_res->>'principal_amount')::numeric,
            'remaining_debt',   (v_loan_res->>'remaining_debt')::numeric,
            'loan_status',      v_loan_res->>'loan_status',
            'effective',        v_dates->'resolved');
    END IF;

    -- Ein Dauerauftrag auf einem Depot-/Kreditkonto bucht nie frei (sonst Backstop-RAISE mit Owner-Alarm).
    v_reason := finance.fn_bookable_account_reason(v_acct);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    -- Abgleich-Sperre: der Saldo-Abgleich enthaelt diese Bewegung schon.
    v_reason := finance.fn_reconciled_reason(v_acct, v_date);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'reconciled', 'reason', v_reason);
    END IF;

    -- Override behaelt die Einnahme/Ausgabe-Richtung der rp (sign aus rp.amount; rp.amount<>0 per V005-CHECK).
    v_book_amt := CASE WHEN v_override IS NOT NULL THEN sign(v_amount) * abs(v_override) ELSE v_amount END;

    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, recurring_payment_id, recurring_due_date, description)
    VALUES (v_acct, v_book_amt, v_date, 'other', v_rp_id, v_due,
            v_name || ' (Recurring ' || v_due
                   || CASE WHEN v_override IS NOT NULL
                           THEN ', angepasst: ' || abs(v_override) || ' statt ' || abs(v_amount)
                           ELSE '' END
                   || ')')
    ON CONFLICT (recurring_payment_id, recurring_due_date, account_id) WHERE recurring_payment_id IS NOT NULL
    DO NOTHING
    RETURNING id INTO v_tx;

    -- Race-Backstop: der EXISTS-Guard oben ist die freundliche Schnellbahn; ein gleichzeitiger Bucher (TOCTOU)
    -- scheitert am partiellen UNIQUE-Index (leeres RETURNING).
    IF v_tx IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_booked',
            'reason', 'Recurring occurrence for payment ' || v_rp_id || ' due ' || v_due || ' is already booked.');
    END IF;

    RETURN jsonb_build_object('ok', true, 'transaction_id', v_tx,
        'amount', v_book_amt, 'plan_amount', v_amount, 'effective', v_dates->'resolved');
END;
$$;
