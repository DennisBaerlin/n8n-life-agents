-- ============================================================
-- fn_book_transaction (ATOMIC WRITE)
--   Bucht EINE einzelne Transaktion auf EINES meiner Konten gegen eine externe, nicht
--   getrackte Gegenseite (Ausgabe ODER Einnahme) -- KEIN Transfer (nur ein Bein, kein
--   Gegenkonto). Verwendung: Versicherungs-Abbuchung, Miete, Gehalt, Erstattung, externe Gebuehr.
--   Eingabe jsonb: account_id (im n8n aufgeloest), amount (IMMER positiv), direction
--   ('inflow'|'outflow'), category (optional, Default 'other'; sinnvoll: 'fee'/'interest'/'other'),
--   description (optional -> sonst Auto), transaction_date. Die Richtung bestimmt das VORZEICHEN
--   (outflow = -, inflow = +); der Saldo wird danach per trg_finance_balance_update gepflegt.
--   Audit Paket 2 (Punkt 7/8): der Betrag wird VOR dem Buchen auf die Waehrungseinheit des Kontos gerundet
--   (currencies.minor_unit; Rueckgabe = gespeicherter Wert, vorher 10.005 zurueck / 10.01 gespeichert); Kategorien
--   nur other|fee|interest (Kauf/Verkauf/Kredit/Abgleich/transfer brauchen ihr eigenes Tool -- vorher CHECK-RAISE
--   mit Owner-Alarm bzw. ein einbeiniger "transfer"); Depot- und Kreditkonten -> {ok:false}
--   (finance.fn_bookable_account_reason; Backstop trg_finance_reject_account_type_txn).
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, tx_id, amount, account_balance} (amount = signiert
--   aus direction berechnet, gerundet wie gespeichert; account_balance = neuer Saldo, in derselben Transaktion gelesen).
--   Korrigierbar (direction/amount/Kategorie/fee-needs-outflow/Kontotyp) -> {ok:false, reason} OHNE Write
--   (kein RAISE -> kein Owner-Alert).
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
    v_date    DATE    := COALESCE(NULLIF(p->>'transaction_date', '')::date, core.fn_today());   -- leer = heute (DB-Default)
    v_desc    TEXT    := NULLIF(p->>'description','');
    v_signed  NUMERIC;
    v_tx      INT;
    v_bal     NUMERIC;
    v_breach  JSONB;
    v_card    JSONB;
BEGIN
    -- Korrigierbare Input-Pruefungen -> {ok:false} (kein RAISE).
    IF v_dir NOT IN ('inflow','outflow') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Direction must be inflow or outflow, got ' || COALESCE(v_dir, 'null') || '.');
    END IF;
    -- Kategorie-Allowlist: einbeinige Buchung gegen eine externe Gegenseite. Strukturelle Kategorien haben eigene
    -- Tools (sonst CHECK-RAISE mit Owner-Alarm bzw. ein einbeiniger Transfer ohne Gegenbein).
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

    -- Rundung auf die Waehrungseinheit des Kontos VOR dem Buchen -> Rueckgabe = gespeicherter Wert.
    v_amount := ROUND(v_amount, COALESCE((SELECT c.minor_unit FROM finance.accounts a
                                          JOIN finance.currencies c ON c.code = a.currency
                                          WHERE a.id = v_account), 2));
    IF v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Amount must be a positive number, got ' || COALESCE((p->>'amount'), 'null') || '.');
    END IF;

    v_signed := CASE v_dir WHEN 'outflow' THEN -v_amount ELSE v_amount END;

    -- category/sign sanity (friendlier than the table CHECK): 'fee' is outflow-only.
    IF v_cat = 'fee' AND v_signed > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Category fee requires an outflow (an expense), but the direction is inflow.');
    END IF;

    v_desc := COALESCE(v_desc, CASE v_dir WHEN 'outflow' THEN 'Ausgabe' ELSE 'Einnahme' END);

    -- Karten-Hinweis VOR dem Insert (sonst faende die Pruefung die eigene Zeile): moegliche Doppelbuchung
    v_card := finance.fn_possible_duplicate_note(v_account, v_signed, v_date);

    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, description)
    VALUES (v_account, v_signed, v_date, v_cat, v_desc)
    RETURNING id INTO v_tx;

    -- Post-State (Trigger hat gefeuert): neuer Saldo des Kontos.
    SELECT balance INTO v_bal
    FROM finance.account_balances WHERE account_id = v_account;

    -- WS-C2: Reserve-Waechter — NUR bei Outflow pruefen, ob die Belastung den Saldo unter den fuer Sparziele
    -- reservierten Betrag gedrueckt hat (eine Gutschrift kann keinen Breach erzeugen -> keine falsche „du hast
    -- eingegriffen"-Meldung). Bei Breach faltet die fn das Objekt als Kategorie-3-Post-State ein; der Agent
    -- spricht den Owner proaktiv an (kein Block, der Spend war legitim).
    -- Phase Notify: ueber die geteilte Dedup-Schicht gaten -> die Note nur beim UEBERGANG nicht-breached->breached
    -- falten (Latch kippt). Bleibt das Konto breached (zweiter un-getaggter Spend), unterdrueckt fn_should_notify
    -- die Wiederholung; der Re-Arm laeuft im Saldo-Trigger (Saldo wieder >= reserved).
    IF v_signed < 0 THEN
        v_breach := finance.fn_reserve_breach(v_account);
        IF v_breach IS NOT NULL AND NOT core.fn_should_notify('finance', 'reserve_breach:' || v_account) THEN
            v_breach := NULL;   -- bereits gemeldet (Latch fired) -> Note unterdruecken
        END IF;
    END IF;

    RETURN jsonb_build_object('ok', true, 'tx_id', v_tx, 'amount', v_signed, 'account_balance', v_bal,
        'effective', jsonb_build_object('transaction_date', v_date),
        'card_lines', v_card)
        || CASE WHEN v_breach IS NOT NULL THEN jsonb_build_object('reserve_breach', v_breach) ELSE '{}'::jsonb END;
END;
$$;
