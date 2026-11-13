-- ============================================================
-- fn_book_transfer (ATOMIC WRITE)
--   Bucht einen Transfer als zwei Transaktionen (Soll -/Haben +) in einer Transaktion.
--   Multi-Waehrung: jedes Bein wird in der Native-Waehrung seines Kontos gebucht.
--     - Gleiche Waehrung  -> beide Beine = from_amount (ein Betrag genuegt).
--     - Verschiedene Wgr. -> to_amount (Zielbetrag) ist Pflicht (der Nutzer bestaetigt beide Betraege
--       ueber das HITL-Gate; er ist die Kurs-Autoritaet). Soll = -from_amount (Quell-Wgr.),
--       Haben = +to_amount (Ziel-Wgr.); realisierter Kurs fx_rate = to_amount/from_amount auf beiden Beinen.
--   Eingabe jsonb: from_account_id, to_account_id (im n8n aufgeloest), from_amount (alias: amount; Betraege auch
--     deutsch geschrieben, unlesbar -> {ok:false}) (Pflicht); to_amount (nur Cross-Currency), transaction_date (ISO
--     oder relativ, core.fn_resolve_input_dates; leer = heute), from_account_name, to_account_name (Buchungstext),
--     purpose (optional). chat_id (optional; Empfaenger-Markierung des reserve_breach-Latch).
--   Interne Flags (nie $fromAI): suppress_breach=true (fn_book_savings_goal_transfer: kein Reserve-Fold und kein
--     Latch-Touch) und skip_opening_leg=true + opening_date (nur fn_apply_bank_statement): das Bein im Startbetrag
--     wird nicht gebucht (fn_reconciled_reason dafuer nicht geprueft), seine Tx-ID und sein Saldo in der Rueckgabe
--     sind NULL, opening_date = der fuer die Regel massgebliche echte Buchungstag (spaete Export-Zeile, gebucht am
--     Tag nach dem Schnitt), Reserve-Waechter nur mit gebuchtem Soll-Bein. Gemeinsame group_id auch fuer das eine
--     Bein (CHECK finance_transactions_transfer_grouped erlaubt es).
--   Rueckgabe: ok:true -> {ok:true, debit_tx_id, credit_tx_id, fx_rate, from_balance, to_balance (neue Native-Salden
--   beider Konten, nach dem Trigger gelesen), effective, card_lines (moegliche Doppel-Umbuchung)}; zusaetzlich
--   reserve_breach, wenn das Soll-Bein den Saldo unter die fuer Sparziele reservierte Summe drueckt.
--   ok:false ohne Write und ohne RAISE: {reason} bei unlesbarem Betrag, from_amount <= 0, Konto == Konto,
--   Cross-Currency ohne gueltiges to_amount (mit from_currency, to_currency, from_amount), Depot-/Kreditkonto
--   (fn_bookable_account_reason) oder einem am Buchungsdatum schon abgeglichenen Konto (fn_reconciled_reason; sonst
--   zaehlte das Bein dort doppelt); {code:'before_opening', reason} wenn ein Bein im Startbetrag seines Kontos liegt
--   (fn_opening_balance_reason; reason nennt Konto, Stichtag, naechsten Schritt; auch ueber
--   fn_book_savings_goal_transfer; bei skip_opening_leg nur, wenn beide Beine im Startbetrag liegen);
--   {code:'invalid_date'}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_transfer(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_from     INT     := (p->>'from_account_id')::int;
    v_to       INT     := (p->>'to_account_id')::int;
    v_from_raw TEXT    := COALESCE(NULLIF(btrim(p->>'from_amount'), ''), NULLIF(btrim(p->>'amount'), ''));
    v_from_amt NUMERIC := finance.fn_parse_numeric_or_null(v_from_raw, true);
    v_to_amt   NUMERIC := finance.fn_parse_numeric_or_null(p->>'to_amount', true);
    v_date     DATE;
    v_purpose  TEXT    := NULLIF(p->>'purpose', '');   -- optionaler Verwendungszweck (sonst Auto)
    v_from_ccy CHAR(3);
    v_to_ccy   CHAR(3);
    v_credit   NUMERIC;
    v_fx       NUMERIC;
    v_debit    INT;
    v_credit_id INT;
    v_bal_from NUMERIC;
    v_bal_to   NUMERIC;
    v_breach   JSONB;
    v_card     JSONB;
    v_reason   TEXT;
    v_suppress BOOLEAN := COALESCE(p->>'suppress_breach', '') = 'true';   -- INTERN (nie $fromAI): fn_book_savings_goal_transfer
                                                              -- ruft mit true -> kein Fold und kein Latch-Touch. COALESCE:
                                                              -- ohne den Key waere (NULL = 'true') = NULL -> NOT NULL -> Block uebersprungen.
    v_skip_leg BOOLEAN := COALESCE(p->>'skip_opening_leg', '') = 'true';   -- INTERN (nie $fromAI): fn_apply_bank_statement
    v_from_open TEXT;                                  -- Grund, wenn das Soll-Bein im Startbetrag liegt
    v_to_open  TEXT;                                   -- Grund, wenn das Haben-Bein im Startbetrag liegt
    v_open_date DATE;                                  -- Datum fuer die Startbetrag-Regel
    v_group    UUID    := gen_random_uuid();           -- Multi-Leg: beide Beine teilen eine group_id
    v_dates    JSONB;
BEGIN
    v_dates := core.fn_resolve_input_dates(p, ARRAY['transaction_date', 'opening_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_date := COALESCE(NULLIF(p->>'transaction_date', '')::date, core.fn_today());   -- leer = heute (DB-Default)
    -- freie Tool-Eingabe ("1.234,56"): unlesbar -> Rueckfrage statt Cast-Fehler mit Owner-Alarm
    IF (v_from_amt IS NULL AND v_from_raw IS NOT NULL)
       OR (v_to_amt IS NULL AND NULLIF(btrim(p->>'to_amount'), '') IS NOT NULL) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The amount "' || CASE WHEN v_from_amt IS NULL AND v_from_raw IS NOT NULL THEN v_from_raw ELSE p->>'to_amount' END || '" is not readable - give it as a plain number.');
    END IF;
    IF v_from_amt IS NULL OR v_from_amt <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Transfer amount must be a positive number, got ' || COALESCE(v_from_amt::text, 'null') || '.');
    END IF;
    IF v_from = v_to THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Source and destination account are the same — a transfer needs two different accounts.');
    END IF;

    -- Kontotyp: Depot-/Kreditkonten tragen keine freien Geld-Bewegungen.
    v_reason := COALESCE(finance.fn_bookable_account_reason(v_from), finance.fn_bookable_account_reason(v_to));
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    -- Startbetrag vor der Abgleich-Sperre: er nennt den naechsten Schritt
    v_open_date := CASE WHEN v_skip_leg THEN COALESCE(NULLIF(p->>'opening_date', '')::date, v_date) ELSE v_date END;
    v_from_open := finance.fn_opening_balance_reason(v_from, v_open_date);
    v_to_open   := finance.fn_opening_balance_reason(v_to, v_open_date);
    IF (v_from_open IS NOT NULL AND v_to_open IS NOT NULL) OR (NOT v_skip_leg AND COALESCE(v_from_open, v_to_open) IS NOT NULL) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'before_opening',
            'reason', COALESCE(v_from_open, v_to_open)
                   || ' Nothing was booked. If the money really moved later, book it with that later date; otherwise it is already'
                   || ' counted there, and the statement or file of the other account books only that account''s side.');
    END IF;
    v_reason := COALESCE(CASE WHEN v_from_open IS NULL THEN finance.fn_reconciled_reason(v_from, v_date) END,
                         CASE WHEN v_to_open IS NULL THEN finance.fn_reconciled_reason(v_to, v_date) END);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;

    SELECT currency INTO v_from_ccy FROM finance.accounts WHERE id = v_from;
    SELECT currency INTO v_to_ccy   FROM finance.accounts WHERE id = v_to;

    IF v_from_ccy IS DISTINCT FROM v_to_ccy THEN
        -- Cross-Currency: Zielbetrag ist Pflicht (unterschiedliche Native-Betraege je Bein).
        IF v_to_amt IS NULL OR v_to_amt <= 0 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Cross-currency transfer (' || v_from_ccy || ' -> ' || v_to_ccy
                       || ') needs the destination amount (to_amount in ' || v_to_ccy
                       || '): ' || v_from_amt || ' ' || v_from_ccy
                       || ' do not equal the credited amount. Ask the user how much arrives in ' || v_to_ccy || '.',
                'from_currency', v_from_ccy, 'to_currency', v_to_ccy, 'from_amount', v_from_amt);
        END IF;
        v_credit := v_to_amt;
        v_fx     := ROUND(v_to_amt / v_from_amt, 10);   -- realisierter Kurs: Ziel-Einheiten je 1 Quell-Einheit
    ELSE
        -- Gleiche Waehrung: ein Betrag genuegt (to_amount ignoriert/= from_amount).
        v_credit := v_from_amt;
        v_fx     := NULL;
    END IF;

    -- Karten-Hinweis vor dem Insert: moegliche Doppel-Umbuchung auf dem Abgangskonto
    v_card := CASE WHEN v_from_open IS NULL THEN finance.fn_possible_duplicate_note(v_from, -v_from_amt, v_date) ELSE '[]'::jsonb END;

    IF v_from_open IS NULL THEN
        INSERT INTO finance.transactions
            (account_id, amount, transaction_date, category, description, group_id, fx_rate)
        VALUES (v_from, -v_from_amt, v_date, 'transfer',
                'Transfer -> ' || (p->>'to_account_name') || COALESCE(' (' || v_purpose || ')', ''), v_group, v_fx)
        RETURNING id INTO v_debit;
        SELECT balance INTO v_bal_from FROM finance.account_balances WHERE account_id = v_from;
    END IF;

    IF v_to_open IS NULL THEN
        INSERT INTO finance.transactions
            (account_id, amount, transaction_date, category, description, group_id, fx_rate)
        VALUES (v_to, v_credit, v_date, 'transfer',
                'Transfer <- ' || (p->>'from_account_name') || COALESCE(' (' || v_purpose || ')', ''), v_group, v_fx)
        RETURNING id INTO v_credit_id;
        SELECT balance INTO v_bal_to FROM finance.account_balances WHERE account_id = v_to;
    END IF;

    -- Reserve-Waechter nur fuers Soll-(from-)Bein (es senkt den Quell-Saldo; das Haben-Bein erhoeht das Zielkonto
    -- und kann nie breachen). Bei Breach faltet die fn das Objekt als Post-State-Kategorie 3 ein.
    -- Ueber die geteilte Dedup-Schicht gaten (Latch-Uebergang). fn_book_savings_goal_transfer ruft diese fn
    -- intern mit suppress_breach=true -> der interne Call faltet die Note nicht und beruehrt den Latch nicht
    -- (eine getaggte Entnahme ist gewolltes Eingreifen; ohne den Skip wuerde sie den Latch verbrennen).
    -- Der Re-Arm laeuft trigger-getrieben (Saldo-Trigger) unabhaengig vom Suppress-Flag.
    IF NOT v_suppress AND v_debit IS NOT NULL THEN
        v_breach := finance.fn_reserve_breach(v_from);
        IF v_breach IS NOT NULL AND NOT core.fn_should_notify('finance', 'reserve_breach:' || v_from) THEN
            v_breach := NULL;   -- bereits gemeldet (Latch fired) -> Note unterdruecken
        ELSIF v_breach IS NOT NULL THEN
            PERFORM core.fn_mark_told('finance', p->>'chat_id', 'reserve_breach:' || v_from);
        END IF;
    END IF;

    RETURN jsonb_build_object('ok', true, 'debit_tx_id', v_debit, 'credit_tx_id', v_credit_id,
        'fx_rate', v_fx, 'from_balance', v_bal_from, 'to_balance', v_bal_to,
        'effective', (v_dates->'resolved') || jsonb_build_object('transaction_date', v_date),
        'card_lines', v_card)
        || CASE WHEN v_breach IS NOT NULL THEN jsonb_build_object('reserve_breach', v_breach) ELSE '{}'::jsonb END;
END;
$$;
