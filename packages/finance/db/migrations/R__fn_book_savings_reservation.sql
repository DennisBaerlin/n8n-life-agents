-- ============================================================
-- fn_book_savings_reservation (ATOMIC WRITE) — Phase S WS-B Stufe 1
--   Bucht den DEPOT-Anteil einer Sparziel-Reserve als EINE Zeile ins append-only Journal
--   (finance.savings_goal_reserve_entries). `book_` (nicht `set_`), weil append-only = eine Reserve-BEWEGUNG
--   buchen (Praezedenz fn_book_savings_goal_transfer); Tier `owner_info` im approval_matrix-Block des finance-Manifests.
--
--   ABSOLUT-REIN -> DELTA-APPEND (das LLM rechnet NICHT): Input `amount` ist der ABSOLUTE Ziel-Betrag, den
--   der Owner direkt nennt ("ich moechte 3000 EUR aus dem Depot fuer dieses Ziel reserviert haben"). Die fn
--   rechnet delta = amount - COALESCE(SUM(journal je Ziel+Depot),0) und haengt EINE manual-Zeile (+/-) an.
--   NIE UPDATE einer Zahl -> der Stand bleibt DERIVED -> strukturell driftfrei.
--
--   Eingabe jsonb: savings_goal_id, depot_account_id (im n8n aufgeloest), amount (>=0, ABSOLUT).
--   RUECKGABE Erfolg: {ok:true, goal_id, depot_account_id, reserved (neuer Depot-Anteil DIESES Ziels = Σ
--     journal je Ziel+Depot = amount), delta (angehaengte Bewegung), market_value (Depot-Marktwert EUR, NULL
--     ohne Kurs), shortfall (Depot-Deckungsluecke ueber ALLE aktiven Ziele, depot_reserve_status)}.
--   Korrigierbar (kein RAISE -> kein Owner-Alert): amount NULL/<0 (keine negative Reserve) / Ziel nicht
--     gefunden / Konto nicht gefunden ODER kein Depot / delta=0 (no-op) -> {ok:false, reason}.
--   MARKTWERT ist Deckel/Deckung, NIE die gespeicherte Reserve (Kurs-Explosion blaeht den Fortschritt nicht
--     auf) — die Reserve ist der gebuchte €-Betrag; market_value/shortfall sind nur die Deckungs-Anzeige.
--   Anwenden via: db_apply.ps1 -File packages\finance\db\migrations\R__fn_book_savings_reservation.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_savings_reservation(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_goal   INT     := NULLIF(p->>'savings_goal_id', '')::int;
    v_acct   INT     := NULLIF(p->>'depot_account_id', '')::int;
    v_amount NUMERIC := NULLIF(p->>'amount', '')::numeric;
    v_gname  TEXT;
    v_atype  finance.account_type;
    v_old    NUMERIC;
    v_delta  NUMERIC;
    v_mv     NUMERIC;
    v_short  NUMERIC;
    v_entry  INT;
BEGIN
    -- Korrigierbare Input-Pruefungen -> {ok:false} (kein RAISE).
    IF v_amount IS NULL OR v_amount < 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'amount must be a non-negative absolute reserve target, got ' || COALESCE(v_amount::text, 'null')
                   || '. (Reserve can be lowered to 0 to release it; it cannot be negative.)');
    END IF;

    SELECT name INTO v_gname FROM finance.savings_goals WHERE id = v_goal;
    IF v_gname IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Savings goal ' || COALESCE(v_goal::text, 'null') || ' not found.');
    END IF;

    SELECT account_type INTO v_atype FROM finance.accounts WHERE id = v_acct;
    IF v_atype IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Account ' || COALESCE(v_acct::text, 'null') || ' not found.');
    END IF;
    IF v_atype NOT IN ('stocks_depot', 'crypto_depot') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Reserve journal applies only to a depot account (stocks_depot/crypto_depot); '
                   || 'a cash/savings reserve uses book_savings_goal_transfer instead.');
    END IF;

    -- Absolut-rein -> delta-append. delta = neuer Ziel-Betrag (EUR) - aktuelle Σ je (Ziel, Depot).
    -- WP-3b: die Journal-Zeilen tragen native Betraege je Waehrung (sparplan_buy = Depot-Waehrung, manual = EUR)
    -- -> die aktuelle Reserve in EUR ist Σ fn_to_eur(delta_native, currency, value_date). amount ist ein
    -- absoluter EUR-Ziel-Betrag (Owner nennt EUR); die angehaengte manual-Zeile ist damit selbst EUR.
    SELECT COALESCE(sum(finance.fn_to_eur(delta_native, currency, value_date)), 0) INTO v_old
    FROM finance.savings_goal_reserve_entries
    WHERE savings_goal_id = v_goal AND account_id = v_acct;
    v_delta := v_amount - v_old;

    IF v_delta = 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The depot reserve for this goal is already ' || to_char(v_amount, 'FM999999990D00') || ' EUR — nothing to change.');
    END IF;

    -- Atomar: EINE Journal-Zeile anhaengen (NIE UPDATE). kind='manual' (Hand-Zuordnung; sparplan_buy kommt in Stage 2).
    -- WP-3b: der manuelle Reserve-Betrag ist EUR (amount ist ein absolutes EUR-Ziel) -> currency='EUR',
    -- value_date=CURRENT_DATE (EUR->EUR ist ohnehin Identitaet, das Datum ist unkritisch).
    INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, value_date, kind)
    VALUES (v_goal, v_acct, v_delta, 'EUR', CURRENT_DATE, 'manual')
    RETURNING id INTO v_entry;

    -- Post-State: Depot-Deckung (Marktwert vs. Σ Reserve ueber ALLE aktiven Ziele) aus dem Waechter-View.
    SELECT market_value, shortfall INTO v_mv, v_short
    FROM finance.depot_reserve_status WHERE account_id = v_acct;

    RETURN jsonb_build_object('ok', true,
        'goal_id',          v_goal,
        'depot_account_id', v_acct,
        'entry_id',         v_entry,
        'delta',            v_delta,
        'reserved',         v_amount,     -- neuer Depot-Anteil DIESES Ziels (= Σ journal je Ziel+Depot)
        'market_value',     v_mv,         -- Depot-Marktwert EUR (NULL ohne Live-Kurs)
        'shortfall',        v_short);     -- Depot-Deckungsluecke ueber alle aktiven Ziele
END;
$$;
