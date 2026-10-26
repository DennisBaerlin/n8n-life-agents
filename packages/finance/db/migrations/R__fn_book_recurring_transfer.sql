-- ============================================================
-- fn_book_recurring_transfer (ATOMIC WRITE)
--   Bucht ein faelliges Vorkommen einer INTERNEN Transfer-rp (target_account_id gesetzt) als ZWEI
--   Transaktionen (Soll -/Haben +) in EINER Transaktion — analog fn_book_transfer, aber datengetrieben
--   aus der recurring_payments-Zeile (kein Nutzer-Betrag je Vorkommen). account_id=Quelle/Soll,
--   target_account_id=Ziel/Haben; gebucht wird die Magnitude abs(amount) (amount ist Quell-seitig negativ).
--   Beide Beine: category='transfer', gemeinsame group_id, recurring_payment_id gesetzt -> "gebucht" bleibt
--   aus finance.transactions ableitbar (fn_recurring_due_open sieht das Vorkommen als erledigt).
--   MULTI-WAEHRUNG: differieren die Konto-Waehrungen, konvertiert die DB das Ziel-Bein ueber den EUR-Cross
--   (fx_rates zum due_date) — die DB rechnet, kein LLM/Nutzer-Input je Vorkommen. Fehlt der Kurs -> {ok:false}.
--   Eingabe jsonb: recurring_payment_id, due_date, amount (opt, Ist-Magnitude in Quell-Waehrung),
--   transaction_date (opt, Ist-Datum; Default due_date). Identitaet beider Beine = recurring_due_date = due_date
--   (Monats-Check WP-A); FX-Kurs zum Buchungsdatum.
--   ABGLEICH-SPERRE je Bein-Konto (Quelle UND Ziel): Buchungsdatum <= letzter Abgleich -> {ok:false, code:'reconciled'}
--   (fn_reconciled_reason; ein abgeglichenes Ziel enthaelt den Zufluss schon -> sonst Doppelzaehlung).
--   RUECKGABE: Erfolg -> {ok:true, debit_tx_id, credit_tx_id, fx_rate}. Idempotenz (schon gebucht) /
--   kein-Transfer (target NULL) / fehlender FX-Kurs / amount<=0 / abgeglichen -> {ok:false, reason} OHNE Write.
--   Aufgerufen aus fn_book_recurring_occurrence (Delegation fuer Transfer-rps) — der Scheduler-Pfad
--   bleibt unveraendert, die Zwei-Bein-Invariante sitzt am fn-Layer (caller-agnostisch).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_recurring_transfer(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_rp_id    INT  := (p->>'recurring_payment_id')::int;
    v_due      DATE := (p->>'due_date')::date;
    v_date     DATE;
    v_override NUMERIC := NULLIF(p->>'amount', '')::numeric;
    v_from     INT;
    v_to       INT;
    v_amount   NUMERIC;
    v_name     TEXT;
    v_mag      NUMERIC;
    v_from_ccy CHAR(3);
    v_to_ccy   CHAR(3);
    v_credit   NUMERIC;
    v_fx       NUMERIC;
    v_eur      NUMERIC;
    v_debit_id INT;
    v_credit_id INT;
    v_goal     INT;
    v_reason   TEXT;
    v_group    UUID := gen_random_uuid();
    v_dates    JSONB;
BEGIN
    -- relative Ist-Datumsangabe ("yesterday") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}.
    -- due_date kommt aus dem DB-Lookup (Vorkommen-Identitaet), nie vom LLM -> nicht aufgeloest.
    v_dates := core.fn_resolve_input_dates(p, ARRAY['transaction_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_date := COALESCE(NULLIF(p->>'transaction_date', '')::date, (p->>'due_date')::date);
    SELECT account_id, target_account_id, amount, name
      INTO v_from, v_to, v_amount, v_name
      FROM finance.recurring_payments WHERE id = v_rp_id;
    IF v_from IS NULL THEN
        RAISE EXCEPTION 'Recurring payment % not found.', v_rp_id;
    END IF;
    -- WS-A: gehoert die rp zu einem Sparziel, ist dieser Transfer ein Reserve-Zufluss -> das Haben-(Ziel-)
    -- Bein traegt savings_goal_id (NUR dieses Bein) -> savings_goal_progress zaehlt es als +Beitrag. Das Ziel zeigt
    -- auf den Kopf der Vorgaenger-Kette (Audit Paket 2 A0) -> auch ein altes Vorkommen einer reaktivierten/
    -- gesplitteten Rate zaehlt fuers Ziel.
    SELECT id INTO v_goal FROM finance.savings_goals
    WHERE recurring_payment_id = finance.fn_recurring_lineage_head(v_rp_id);
    IF v_to IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Recurring payment ' || v_rp_id || ' is not a transfer (no target_account_id).');
    END IF;
    -- Kontotyp (Audit Paket 2, Punkt 7): Quelle/Ziel duerfen kein Depot-/Kreditkonto sein (vorher ungeprueft ->
    -- Backstop-RAISE mit Owner-Alarm statt korrigierbarer Ablehnung).
    v_reason := COALESCE(finance.fn_bookable_account_reason(v_from), finance.fn_bookable_account_reason(v_to));
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;

    -- Idempotenz: schon ein Tx (Bein) fuer diese Faelligkeit gebucht?
    IF EXISTS (SELECT 1 FROM finance.transactions
               WHERE recurring_payment_id = v_rp_id AND recurring_due_date = v_due) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_booked',
            'reason', 'Recurring transfer for payment ' || v_rp_id || ' due ' || v_due
                   || ' is already booked.');
    END IF;
    IF v_override IS NOT NULL AND v_override <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Adjusted amount must be a positive magnitude, got ' || v_override || '.');
    END IF;
    -- Abgleich-Sperre je Bein-Konto (Monats-Check WP-A).
    v_reason := COALESCE(finance.fn_reconciled_reason(v_from, v_date), finance.fn_reconciled_reason(v_to, v_date));
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'reconciled', 'reason', v_reason);
    END IF;

    v_mag := COALESCE(abs(v_override), abs(v_amount));   -- Magnitude in Quell-Waehrung (amount ist Quell-seitig negativ)
    -- amount=0 ist seit WS-3a strukturell unmoeglich (CHECK recurring_payments_amount_nonzero, finance:V005)
    -- -> v_mag > 0 GARANTIERT, die fx_rate-Division (v_credit/v_mag) kann nie SQLSTATE 22012 (div/0) werfen.
    -- Der fruehere fn-Guard ist bewusst entfallen: die Invariante lebt am tiefsten Layer (CHECK = Gesetz),
    -- nicht doppelt im fn (ein Fakt, eine Adresse). Test: tests/db/finance/test_recurring_payment_amount_check.sql.
    SELECT currency INTO v_from_ccy FROM finance.accounts WHERE id = v_from;
    SELECT currency INTO v_to_ccy   FROM finance.accounts WHERE id = v_to;

    IF v_from_ccy IS DISTINCT FROM v_to_ccy THEN
        -- Cross-Currency: ueber EUR-Cross zum Buchungsdatum (DB rechnet). EUR-Zwischenwert UNGERUNDET, gerundet wird
        -- genau EINMAL am Ende (Rundungs-Paket 2026-10-23: vorher Cent-Zwischenwert x Kurs -> bis 7 KRW je Buchung daneben).
        v_eur := finance.fn_to_eur_unrounded(v_mag, v_from_ccy, v_date);
        IF v_to_ccy = 'EUR' THEN
            v_credit := ROUND(v_eur, 2);
        ELSE
            -- EUR -> Ziel ueber DIESELBE Kurs-Suche (fn_to_eur_unrounded: Wert von 1 Ziel-Einheit in EUR); kein zweiter
            -- Inline-Lookup, der von der Reporting-Umrechnung abweichen koennte.
            v_credit := ROUND(v_eur / NULLIF(finance.fn_to_eur_unrounded(1, v_to_ccy, v_date), 0), 2);
        END IF;
        IF v_credit IS NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'No FX rate available to convert ' || v_from_ccy || ' -> ' || v_to_ccy
                       || ' on ' || v_date || '. Add an fx rate first.');
        END IF;
        v_fx := ROUND(v_credit / v_mag, 10);   -- realisierter Kurs: Ziel-Einheiten je 1 Quell-Einheit
    ELSE
        v_credit := v_mag;
        v_fx     := NULL;
    END IF;

    -- Soll-Bein (Quelle): -Magnitude in Quell-Waehrung. WP-1: ON CONFLICT als Race-Backstop (der EXISTS-Guard
    -- oben ist die Schnellbahn). Beide Beine teilen (rp_id, due) und unterscheiden sich NUR durch account_id ->
    -- der 3-spaltige Index laesst beide zu, faengt aber Dubletten. Verliert das Soll-Bein das Race (leeres
    -- RETURNING), MUSS vor dem Haben-Bein abgebrochen werden -> kein Orphan-Einzelbein.
    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, description, group_id, fx_rate, recurring_payment_id,
         recurring_due_date)
    VALUES (v_from, -v_mag, v_date, 'transfer',
            v_name || ' -> Transfer (Recurring ' || v_due || ')', v_group, v_fx, v_rp_id, v_due)
    ON CONFLICT (recurring_payment_id, recurring_due_date, account_id) WHERE recurring_payment_id IS NOT NULL
    DO NOTHING
    RETURNING id INTO v_debit_id;

    IF v_debit_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_booked',
            'reason', 'Recurring transfer for payment ' || v_rp_id || ' due ' || v_due || ' is already booked.');
    END IF;

    -- Haben-Bein (Ziel): +credit in Ziel-Waehrung; WS-A: bei Sparziel-rp das savings_goal_id-Tag (Reserve-Bein)
    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, description, group_id, fx_rate, recurring_payment_id,
         recurring_due_date, savings_goal_id)
    VALUES (v_to, v_credit, v_date, 'transfer',
            v_name || ' <- Transfer (Recurring ' || v_due || ')', v_group, v_fx, v_rp_id, v_due, v_goal)
    RETURNING id INTO v_credit_id;

    RETURN jsonb_build_object('ok', true, 'debit_tx_id', v_debit_id, 'credit_tx_id', v_credit_id, 'fx_rate', v_fx,
        'effective', v_dates->'resolved');
END;
$$;
