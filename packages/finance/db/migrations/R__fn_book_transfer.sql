-- ============================================================
-- fn_book_transfer (ATOMIC WRITE)
--   Bucht einen Transfer als ZWEI Transaktionen (Soll -/Haben +) in EINER Transaktion.
--   MULTI-WAEHRUNG: jedes Bein wird in der NATIVE-Waehrung seines Kontos gebucht.
--     - Gleiche Waehrung  -> Fast-Path: beide Beine = from_amount (ein Betrag genuegt).
--     - Verschiedene Wgr. -> to_amount (Zielbetrag) ist PFLICHT (der Nutzer bestaetigt beide Betraege
--       ueber das HITL-Gate; er ist die Kurs-Autoritaet). Soll = -from_amount (Quell-Wgr.),
--       Haben = +to_amount (Ziel-Wgr.); realisierter Kurs fx_rate = to_amount/from_amount auf beiden Beinen.
--   Eingabe jsonb: from_account_id, to_account_id (im n8n aufgeloest), from_amount (alias: amount),
--     to_amount (nur Cross-Currency), transaction_date (ISO oder relativ, core.fn_resolve_input_dates), from_account_name, to_account_name, purpose.
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, debit_tx_id, credit_tx_id, fx_rate, from_balance,
--   to_balance} (Post-State: neue NATIVE Salden beider Konten, in derselben Transaktion gelesen).
--   Korrigierbar (Konto==Konto / from_amount<=0 / Cross-Currency ohne gueltiges to_amount / Depot- oder
--   Kreditkonto, finance.fn_bookable_account_reason, Audit Paket 2) ->
--   {ok:false, reason} OHNE Write (kein RAISE -> kein Owner-Alert).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_transfer(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_from     INT     := (p->>'from_account_id')::int;
    v_to       INT     := (p->>'to_account_id')::int;
    v_from_amt NUMERIC := COALESCE(NULLIF(p->>'from_amount', '')::numeric, NULLIF(p->>'amount', '')::numeric);
    v_to_amt   NUMERIC := NULLIF(p->>'to_amount', '')::numeric;
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
                                                              -- ruft mit true -> kein Fold UND kein Latch-Touch. COALESCE:
                                                              -- ohne den Key waere (NULL = 'true') = NULL -> NOT NULL -> Block uebersprungen.
    v_group    UUID    := gen_random_uuid();           -- Multi-Leg: beide Beine teilen eine group_id
    v_dates    JSONB;
BEGIN
    -- relative Datumsangabe ("yesterday", "-3 days") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['transaction_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_date := COALESCE(NULLIF(p->>'transaction_date', '')::date, core.fn_today());   -- leer = heute (DB-Default)
    -- Korrigierbare Input-Pruefungen -> {ok:false} (kein RAISE).
    IF v_from_amt IS NULL OR v_from_amt <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Transfer amount must be a positive number, got ' || COALESCE(v_from_amt::text, 'null') || '.');
    END IF;
    IF v_from = v_to THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Source and destination account are the same — a transfer needs two different accounts.');
    END IF;

    -- Kontotyp (Audit Paket 2, Punkt 7): Depot-/Kreditkonten tragen keine freien Geld-Bewegungen.
    v_reason := COALESCE(finance.fn_bookable_account_reason(v_from), finance.fn_bookable_account_reason(v_to));
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

    -- Karten-Hinweis VOR dem Insert: moegliche Doppel-Umbuchung auf dem Abgangskonto
    v_card := finance.fn_possible_duplicate_note(v_from, -v_from_amt, v_date);

    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, description, group_id, fx_rate)
    VALUES (v_from, -v_from_amt, v_date, 'transfer',
            'Transfer -> ' || (p->>'to_account_name') || COALESCE(' (' || v_purpose || ')', ''), v_group, v_fx)
    RETURNING id INTO v_debit;

    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, description, group_id, fx_rate)
    VALUES (v_to, v_credit, v_date, 'transfer',
            'Transfer <- ' || (p->>'from_account_name') || COALESCE(' (' || v_purpose || ')', ''), v_group, v_fx)
    RETURNING id INTO v_credit_id;

    -- Post-State (Trigger haben gefeuert): neue native Salden beider Konten.
    SELECT balance INTO v_bal_from FROM finance.account_balances WHERE account_id = v_from;
    SELECT balance INTO v_bal_to   FROM finance.account_balances WHERE account_id = v_to;

    -- WS-C2: Reserve-Waechter — NUR fuers Soll-(from-)Bein (es senkt den Quell-Saldo; das Haben-Bein erhoeht
    -- das Zielkonto und kann nie breachen). Bei Breach faltet die fn das Objekt als Kategorie-3-Post-State ein.
    -- Phase Notify: ueber die geteilte Dedup-Schicht gaten (Latch-Uebergang). HINWEIS: fn_book_savings_goal_transfer
    -- ruft diese fn intern mit suppress_breach=true -> der interne Call faltet die Note NICHT UND beruehrt den
    -- Latch NICHT (eine getaggte Entnahme ist gewolltes Eingreifen; ohne den Skip wuerde sie den Latch verbrennen).
    -- Der Re-Arm laeuft trigger-getrieben (Saldo-Trigger) unabhaengig vom Suppress-Flag.
    IF NOT v_suppress THEN
        v_breach := finance.fn_reserve_breach(v_from);
        IF v_breach IS NOT NULL AND NOT core.fn_should_notify('finance', 'reserve_breach:' || v_from) THEN
            v_breach := NULL;   -- bereits gemeldet (Latch fired) -> Note unterdruecken
        END IF;
    END IF;

    RETURN jsonb_build_object('ok', true, 'debit_tx_id', v_debit, 'credit_tx_id', v_credit_id,
        'fx_rate', v_fx, 'from_balance', v_bal_from, 'to_balance', v_bal_to,
        'effective', (v_dates->'resolved') || jsonb_build_object('transaction_date', v_date),
        'card_lines', v_card)
        || CASE WHEN v_breach IS NOT NULL THEN jsonb_build_object('reserve_breach', v_breach) ELSE '{}'::jsonb END;
END;
$$;
