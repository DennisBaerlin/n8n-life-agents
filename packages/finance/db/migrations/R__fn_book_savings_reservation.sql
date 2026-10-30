-- ============================================================
-- fn_book_savings_reservation (ATOMIC WRITE) — Zweckbindung vorhandenen Geldes fuer ein Sparziel
--   Bucht den Anteil eines Kontos an einer Sparziel-Reserve als EINE Zeile ins append-only Journal
--   (finance.savings_goal_reserve_entries), OHNE Geldbewegung (YNAB-Assign/Firefly-Piggy). Seit 2026-10-27 fuer jedes
--   zuordenbare Konto (fn_goal_earmark_account_types: cash/Tagesgeld, Festgeld, P2P, Depots), nicht nur Depots.
--   `book_` (nicht `set_`), weil append-only = eine Reserve-BEWEGUNG buchen (Praezedenz fn_book_savings_goal_transfer);
--   Tier `owner_info` im approval_matrix-Block des finance-Manifests.
--
--   ABSOLUT-REIN -> DELTA-APPEND (das LLM rechnet NICHT): Input `amount` ist der ABSOLUTE Anteil, den der Owner fuer
--   (Ziel, Konto) nennt ("3000 EUR auf dem Tagesgeld gehoeren zur Reise"). Die fn rechnet delta = amount - aktueller
--   Anteil aus savings_goal_account_share (getaggte Transfers + Journal, d. h. schon eingezahltes Geld wird
--   ANGERECHNET) und haengt EINE manual-Zeile (+/-) an. NIE UPDATE einer Zahl -> der Stand bleibt DERIVED.
--   Waehrung: saldo-basiertes Konto -> Kontowaehrung (amount, Zeile, Saldo-Vergleich nativ); Depot -> EUR (absoluter
--   EUR-Betrag gegen den EUR-Marktwert, wie bisher).
--   FREIER-SALDO-GUARD (saldo-basiert, nur bei delta > 0): Summe aller AKTIVEN Ziel-Anteile auf dem Konto nach dem
--   Append <= Saldo, sonst {ok:false, code:'insufficient_free_balance', free}. Konto-Zeile FOR UPDATE (zwei parallele
--   Zuordnungen koennen den Guard nicht gemeinsam ueberholen). Senken/Freigeben ist immer erlaubt. Depot: der Marktwert
--   ist nur Deckungsanzeige (market_value/shortfall), kein Guard (Kurse schwanken).
--
--   Eingabe jsonb: savings_goal_id, account_id (im n8n aufgeloest), amount (>=0, ABSOLUT, Kontowaehrung bzw. EUR).
--   RUECKGABE Erfolg: {ok:true, goal_id, account_id, entry_id, delta (angehaengte Bewegung), reserved (neuer Anteil
--     dieses Ziels auf dem Konto = amount), current_amount (neuer Ziel-Stand EUR, Post-State)}
--     + saldo-basiert: free_balance (Saldo - aktive Anteile auf dem Konto, nach dem Append)
--     + Depot: market_value (Depot-Marktwert EUR, NULL ohne Kurs), shortfall (Depot-Deckungsluecke, depot_reserve_status)
--     + savings_goal_reached {current_amount, target_amount, note}, wenn eine Erhoehung das Ziel deckt (Event-Fold).
--   Korrigierbar (kein RAISE -> kein Owner-Alert): amount NULL/<0 / Ziel nicht gefunden oder nicht aktiv / Konto nicht gefunden ODER
--     nicht zuordenbar (Kredit) / Depot fuer eine Instandhaltungsruecklage / kein Geld-Konto fuer die Notreserve
--     (fn_emergency_reserve_account_types) / delta=0 (no-op) / insufficient_free_balance
--     -> {ok:false, reason}.
--   Anwenden via: db_apply.ps1 -File packages\finance\db\migrations\R__fn_book_savings_reservation.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_savings_reservation(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_goal   INT     := NULLIF(p->>'savings_goal_id', '')::int;
    v_acct   INT     := NULLIF(p->>'account_id', '')::int;
    v_amount NUMERIC := NULLIF(p->>'amount', '')::numeric;
    v_gname  TEXT;
    v_target NUMERIC;
    v_gstatus TEXT;
    v_atype  finance.account_type;
    v_aname  TEXT;
    v_ccy    TEXT;
    v_depot  BOOLEAN;
    v_old    NUMERIC;
    v_delta  NUMERIC;
    v_bal    NUMERIC;
    v_free   NUMERIC;
    v_mv     NUMERIC;
    v_short  NUMERIC;
    v_entry  INT;
    v_cur    NUMERIC;
    v_out    JSONB;
BEGIN
    -- Korrigierbare Input-Pruefungen -> {ok:false} (kein RAISE).
    IF v_amount IS NULL OR v_amount < 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'amount must be a non-negative absolute amount, got ' || COALESCE(v_amount::text, 'null')
                   || '. (It can be lowered to 0 to release the earmark; it cannot be negative.)');
    END IF;

    SELECT name, target_amount, status INTO v_gname, v_target, v_gstatus FROM finance.savings_goals WHERE id = v_goal;
    IF v_gname IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Savings goal ' || COALESCE(v_goal::text, 'null') || ' not found.');
    END IF;
    -- Nur aktive Ziele: die Guards und Waechter zaehlen nur aktive -> eine Zuordnung an ein geschlossenes Ziel waere
    -- unsichtbar gebunden (Code-Review 2026-10-27).
    IF v_gstatus IS DISTINCT FROM 'active' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Savings goal "' || v_gname || '" is ' || v_gstatus || ' - money can only be earmarked for an active goal (re-open it first).');
    END IF;

    -- Konto-Zeile sperren: serialisiert parallele Zuordnungen auf dasselbe Konto (Freier-Saldo-Guard).
    SELECT account_type, name, currency INTO v_atype, v_aname, v_ccy FROM finance.accounts WHERE id = v_acct FOR UPDATE;
    IF v_atype IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Account ' || COALESCE(v_acct::text, 'null') || ' not found.');
    END IF;
    IF NOT v_atype = ANY (finance.fn_goal_earmark_account_types()) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', '"' || v_aname || '" cannot hold savings-goal money - earmark a cash/Tagesgeld, fixed-deposit, P2P or depot account.');
    END IF;
    v_depot := v_atype IN ('stocks_depot', 'crypto_depot');
    -- Instandhaltungsruecklage (2026-10-27): nur saldo-basierte Konten (kein Kursrisiko, kein Glide-Path ohne Datum).
    IF v_depot AND EXISTS (SELECT 1 FROM finance.savings_goals WHERE id = v_goal AND real_estate_id IS NOT NULL) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Money of a maintenance reserve can only be earmarked on a cash/Tagesgeld, fixed-deposit or P2P account, not in a depot.');
    END IF;
    -- Notreserve (2026-10-30): nur Geld-Konten (sofort verfuegbar, einlagengesichert; fn_emergency_reserve_account_types).
    IF NOT v_atype = ANY (finance.fn_emergency_reserve_account_types())
       AND EXISTS (SELECT 1 FROM finance.savings_goals WHERE id = v_goal AND kind = 'emergency_reserve') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Emergency reserve money can only be earmarked on a cash/Tagesgeld account (available at once, deposit-insured) - not on a fixed deposit, P2P or depot.');
    END IF;

    -- Absolut-rein -> delta-append. Aktueller Anteil (Ziel, Konto) inkl. getaggter Transfers: saldo-basiert nativ,
    -- Depot in EUR (die manual-Zeile ist dort EUR, sparplan_buy Depot-Waehrung -> nur EUR ist addierbar).
    SELECT CASE WHEN v_depot THEN s.share_eur ELSE s.share_native END INTO v_old
    FROM finance.savings_goal_account_share s
    WHERE s.goal_id = v_goal AND s.account_id = v_acct;
    v_delta := v_amount - COALESCE(v_old, 0);

    IF v_delta = 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The earmark of this goal on "' || v_aname || '" is already ' || to_char(v_amount, 'FM999999990D00')
                   || ' ' || CASE WHEN v_depot THEN 'EUR' ELSE v_ccy END || ' - nothing to change.');
    END IF;

    IF NOT v_depot THEN
        SELECT COALESCE(balance, 0) INTO v_bal FROM finance.account_balances WHERE account_id = v_acct;
        v_bal  := COALESCE(v_bal, 0);
        v_free := finance.fn_account_free_balance(v_acct);   -- frei VOR dem Append (eine Adresse des Guards)
        IF v_delta > 0 AND v_delta > v_free THEN
            RETURN jsonb_build_object('ok', false, 'code', 'insufficient_free_balance',
                'free', round(GREATEST(v_free, 0), 2), 'balance', round(v_bal, 2),
                'reason', 'Only ' || to_char(GREATEST(v_free, 0), 'FM999999990D00') || ' ' || v_ccy || ' on "' || v_aname
                       || '" are not yet earmarked for savings goals (balance ' || to_char(v_bal, 'FM999999990D00')
                       || ') - earmark at most that, or release another goal''s earmark first.');
        END IF;
    END IF;

    -- Atomar: EINE Journal-Zeile anhaengen (NIE UPDATE). Depot = EUR, saldo-basiert = Kontowaehrung.
    INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, value_date, kind)
    VALUES (v_goal, v_acct, v_delta, CASE WHEN v_depot THEN 'EUR' ELSE v_ccy END, CURRENT_DATE, 'manual')
    RETURNING id INTO v_entry;

    SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_goal;
    v_out := jsonb_build_object('ok', true,
        'goal_id',        v_goal,
        'account_id',     v_acct,
        'entry_id',       v_entry,
        'delta',          v_delta,
        'reserved',       v_amount,
        'current_amount', round(COALESCE(v_cur, 0), 2));

    IF v_depot THEN
        -- Post-State: Depot-Deckung (Marktwert vs. Σ Reserve ueber ALLE aktiven Ziele) aus dem Waechter-View.
        SELECT market_value, shortfall INTO v_mv, v_short FROM finance.depot_reserve_status WHERE account_id = v_acct;
        v_out := v_out || jsonb_build_object('market_value', v_mv, 'shortfall', v_short);
    ELSE
        v_out := v_out || jsonb_build_object('free_balance', round(v_free - v_delta, 2));
    END IF;

    -- Event-Fold "Sparziel erreicht" (wie fn_book_savings_goal_transfer deposit): nur eine Erhoehung, die das Ziel deckt.
    IF v_delta > 0 AND v_target > 0 AND v_cur >= v_target THEN
        v_out := v_out || jsonb_build_object('savings_goal_reached', jsonb_build_object(
            'current_amount', round(v_cur, 2), 'target_amount', round(v_target, 2),
            'note', 'Savings goal "' || v_gname || '" is now fully covered (' || round(v_cur, 2) || ' of ' || round(v_target, 2)
                    || ' EUR). The money stays earmarked until it is used - no further savings rate is needed.'));
    END IF;
    RETURN v_out;
END;
$$;
