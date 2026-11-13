-- ============================================================
-- fn_book_transaction (ATOMIC WRITE)
--   Bucht eine einzelne Transaktion auf eines meiner Konten gegen eine externe, nicht
--   getrackte Gegenseite (Ausgabe oder Einnahme) -- kein Transfer (nur ein Bein, kein
--   Gegenkonto). Verwendung: Versicherungs-Abbuchung, Miete, Gehalt, Erstattung, externe Gebuehr.
--   Eingabe jsonb: account_id (im n8n aufgeloest), amount (immer positiv), direction ('inflow'|'outflow')
--   (Pflicht); category (optional, Default 'other'; erlaubt nur other|fee|interest -- Kauf/Verkauf/Kredit/Abgleich/
--   transfer brauchen ihr eigenes Tool, sonst CHECK-RAISE mit Owner-Alarm bzw. ein einbeiniger "transfer"),
--   interest_correction (optional, nur intern: erlaubt interest als outflow fuer die Zinskorrektur des Kontoauszugs),
--   description (optional, sonst Auto), transaction_date (ISO oder relativ, core.fn_resolve_input_dates; leer =
--   heute). Die Richtung bestimmt das Vorzeichen (outflow = -, inflow = +); der Saldo wird danach per
--   trg_finance_balance_update gepflegt. Der Betrag wird vor dem Buchen auf die Waehrungseinheit des Kontos
--   gerundet (currencies.minor_unit), damit die Rueckgabe dem gespeicherten Wert entspricht.
--   Rueckgabe: ok:true -> {ok:true, tx_id, amount (signiert, gerundet wie gespeichert), account_balance (neuer
--   Saldo, nach dem Trigger gelesen), effective, card_lines (moegliche Doppelbuchung)}; bei Outflow zusaetzlich
--   reserve_breach, wenn die Belastung den Saldo unter die fuer Sparziele reservierte Summe drueckt.
--   ok:false ohne Write und ohne RAISE: {reason} bei ungueltiger direction, Kategorie ausserhalb der Allowlist,
--   amount <= 0, fee als inflow, interest als outflow (Strafzins = fee) oder Depot-/Kreditkonto
--   (finance.fn_bookable_account_reason; Backstop trg_finance_reject_account_type_txn); {code:'invalid_date'}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_transaction(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_account INT     := (p->>'account_id')::int;
    v_amount  NUMERIC := (p->>'amount')::numeric;
    v_dir     TEXT    := p->>'direction';
    v_cat_raw TEXT    := COALESCE(NULLIF(p->>'category',''), 'other');
    v_cat     finance.transaction_category;
    v_reason  TEXT;
    v_date    DATE;
    v_desc    TEXT    := NULLIF(p->>'description','');
    v_signed  NUMERIC;
    v_tx      INT;
    v_bal     NUMERIC;
    v_breach  JSONB;
    v_card    JSONB;
    v_dates   JSONB;
BEGIN
    v_dates := core.fn_resolve_input_dates(p, ARRAY['transaction_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_date := COALESCE(NULLIF(p->>'transaction_date', '')::date, core.fn_today());   -- leer = heute (DB-Default)

    IF v_dir NOT IN ('inflow','outflow') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Direction must be inflow or outflow, got ' || COALESCE(v_dir, 'null') || '.');
    END IF;
    -- Kategorie-Allowlist: strukturelle Kategorien haben eigene Tools (sonst CHECK-RAISE mit Owner-Alarm bzw.
    -- ein einbeiniger Transfer ohne Gegenbein).
    IF v_cat_raw NOT IN ('other', 'fee', 'interest') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Category ' || v_cat_raw || ' cannot be booked as a single transaction. Use the matching tool: '
                   || 'transfers -> book_transfer, buy/sell/dividend -> the depot tools, loan movements -> the loan '
                   || 'tools, balance corrections -> reconcile_account. Allowed here: other, fee, interest.');
    END IF;
    v_cat := v_cat_raw::finance.transaction_category;

    -- Kontotyp: Depot-/Kreditkonten tragen keine freien Geld-Buchungen.
    v_reason := finance.fn_bookable_account_reason(v_account);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;

    -- Rundung auf die Waehrungseinheit des Kontos vor dem Buchen -> Rueckgabe = gespeicherter Wert.
    v_amount := ROUND(v_amount, COALESCE((SELECT c.minor_unit FROM finance.accounts a
                                          JOIN finance.currencies c ON c.code = a.currency
                                          WHERE a.id = v_account), 2));
    IF v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Amount must be a positive number, got ' || COALESCE((p->>'amount'), 'null') || '.');
    END IF;

    v_signed := CASE v_dir WHEN 'outflow' THEN -v_amount ELSE v_amount END;

    -- 'fee' ist outflow-only (freundlicher als der Tabellen-CHECK).
    IF v_cat = 'fee' AND v_signed > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Category fee requires an outflow (an expense), but the direction is inflow.');
    END IF;
    -- Strafzins/Verwahrentgelt ist fee (Zins-Pfad bleibt habensaldo-only). Ausnahme: die negative Zinskorrektur des
    -- Kontoauszug-Abgleichs (fn_apply_bank_statement setzt interest_correction; das Tool reicht den Key nicht durch).
    IF v_cat = 'interest' AND v_signed < 0 AND NOT COALESCE((p->>'interest_correction')::boolean, false) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Interest can only be booked as an inflow. Negative interest or a custody charge is a fee: book it with category fee.');
    END IF;

    v_desc := COALESCE(v_desc, CASE v_dir WHEN 'outflow' THEN 'Ausgabe' ELSE 'Einnahme' END);

    -- Karten-Hinweis vor dem Insert (sonst faende die Pruefung die eigene Zeile): moegliche Doppelbuchung
    v_card := finance.fn_possible_duplicate_note(v_account, v_signed, v_date);

    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, description)
    VALUES (v_account, v_signed, v_date, v_cat, v_desc)
    RETURNING id INTO v_tx;

    SELECT balance INTO v_bal
    FROM finance.account_balances WHERE account_id = v_account;

    -- Reserve-Waechter nur bei Outflow: eine Gutschrift kann keinen Breach erzeugen (sonst falsche „du hast
    -- eingegriffen"-Meldung). Bei Breach faltet die fn das Objekt als Post-State-Kategorie 3 ein; der Agent
    -- spricht den Owner proaktiv an (kein Block, der Spend war legitim).
    -- Ueber die geteilte Dedup-Schicht gaten: die Note nur beim Uebergang nicht-breached->breached falten (Latch
    -- kippt). Bleibt das Konto breached (zweiter un-getaggter Spend), unterdrueckt fn_should_notify die
    -- Wiederholung; der Re-Arm laeuft im Saldo-Trigger (Saldo wieder >= reserved).
    IF v_signed < 0 THEN
        v_breach := finance.fn_reserve_breach(v_account);
        IF v_breach IS NOT NULL AND NOT core.fn_should_notify('finance', 'reserve_breach:' || v_account) THEN
            v_breach := NULL;   -- bereits gemeldet (Latch fired) -> Note unterdruecken
        ELSIF v_breach IS NOT NULL THEN
            PERFORM core.fn_mark_told('finance', p->>'chat_id', 'reserve_breach:' || v_account);
        END IF;
    END IF;

    RETURN jsonb_build_object('ok', true, 'tx_id', v_tx, 'amount', v_signed, 'account_balance', v_bal,
        'effective', (v_dates->'resolved') || jsonb_build_object('transaction_date', v_date),
        'card_lines', v_card)
        || CASE WHEN v_breach IS NOT NULL THEN jsonb_build_object('reserve_breach', v_breach) ELSE '{}'::jsonb END;
END;
$$;
