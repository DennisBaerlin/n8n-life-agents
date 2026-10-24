-- ============================================================
-- fn_book_savings_goal_transfer (ATOMIC WRITE) — Phase S WS-A (D1)
--   Die EINE Sparziel-Geldbewegung. Physisch immer ein Transfer zwischen zwei eigenen Konten
--   (intern via fn_book_transfer wiederverwendet — atomar, group_id, Multi-Waehrung, Saldo-Trigger);
--   das dedizierte Tool/diese fn ergaenzen NUR die Ziel-Tag-Zuordnung. PFLICHT-direction bestimmt,
--   welche(s) Bein(e) das savings_goal_id-Tag tragen -> savings_goal_progress (= signed SUM der getaggten
--   Tx) bewegt sich entsprechend:
--     deposit    : external -> reserve, Haben (to, +) getaggt   -> +amount   (einzahlen / "extra sparen")
--     withdrawal : reserve -> external, Soll  (from, -) getaggt  -> -amount   (entnehmen / "anderweitig gebraucht")
--     relocate   : reserveA -> reserveB, BEIDE Beine getaggt     ->  0        (umschichten, nur Umzug)
--   WARUM dedizierte fn statt Tag-Option am generischen Transfer (Established-Pattern-Challenge 2026-06-25):
--   Monzo Pots/Firefly piggy-bank = dedizierte Operation; sauberer {ok}-Vertrag, klarer HITL-Preview,
--   kein stilles Falschtagging. direction ist EXPLIZIT (kein emergentes from/to-Vorzeichen).
--   Eingabe jsonb: savings_goal_id, from_account_id|from_account_name, to_account_id|to_account_name (je optional),
--     amount (>0, roh), direction (deposit|withdrawal|relocate), transaction_date (leer = heute), purpose (opt),
--     to_amount (opt, Cross-Currency).
--   KONTEN (Nachtrag D, "DB ist das Gesetz"): Namen loest die fn auf (fn_resolve_cash_account: nur cash/Festgeld,
--     Depot -> depot_not_allowed). Reserve = Topf (Zielkonto der Sparrate) + jedes Konto mit getaggtem Geld des Ziels
--     (fn_goal_reserve_accounts). Fehlende Konten leitet sie ab: deposit An = Topf (Altziel ohne Rate: das eine
--     Reserve-Konto), Von = Abbuchungskonto der Rate; withdrawal/relocate Von = Topf bzw. groesster Anteil.
--     Geld zwischen zwei Reserve-Konten ist immer ein relocate (use_relocate). Ein relocate, der den Anteil am Topf
--     leert, verlegt den Topf (fn_apply_goal_reserve).
--   RUECKGABE: Erfolg -> {ok:true, debit_tx_id, credit_tx_id, savings_goal_id, direction, current_amount
--     (neuer Ziel-Stand, Post-State), from_balance, to_balance, effective (Konten id/Name/Waehrung + Datum fuer die
--     Karte), card_lines (Hinweise aus fn_book_transfer, z. B. moegliche Doppelbuchung), savings_goal_reached?}.
--   Korrigierbar -> {ok:false, code?, reason, candidates?} OHNE Write (kein RAISE): amount<=0, direction nicht im Enum,
--     Ziel nicht gefunden, not_found/ambiguous/depot_not_allowed (Kontoname), no_reserve, not_reserve,
--     insufficient_share, missing_from/missing_to, use_relocate, invalid_reserve, from==to, interner Transfer {ok:false}
--     (z. B. Cross-Currency ohne to_amount).
--   ATOMARITAET + Finding #10: schlaegt der interne fn_book_transfer fehl, wird NICHT gestempelt
--     (sonst stiller no-op UPDATE WHERE id=NULL -> ok=true ohne Tag). Erst ok pruefen, dann stempeln.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_savings_goal_transfer(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_goal    INT  := NULLIF(p->>'savings_goal_id', '')::int;
    v_from    INT  := NULLIF(p->>'from_account_id', '')::int;
    v_to      INT  := NULLIF(p->>'to_account_id', '')::int;
    v_amount  NUMERIC := NULLIF(p->>'amount', '')::numeric;
    v_dir     TEXT := p->>'direction';
    v_gname   TEXT;
    v_fname   TEXT;
    v_tname   TEXT;
    v_r       JSONB;
    v_debit   INT;
    v_credit  INT;
    v_cur     NUMERIC;
    v_target  NUMERIC;   -- Phase L WS-5: Zielbetrag fuer den "Sparziel erreicht"-Sofort-Hinweis
    v_rp      INT;       -- Sparrate des Ziels (NULL = Altziel ohne Rate)
    v_pot     INT;       -- Nachtrag D: Topf = target_account_id der Sparrate
    v_rs      JSONB;     -- Reserve-Konten [{account_id, name, share, is_pot}] (einmal gelesen)
    v_cands   JSONB;     -- davon die mit Geld des Ziels (share > 0)
    v_funding INT;       -- Abbuchungskonto der Sparrate
    v_share   NUMERIC;
    v_res     JSONB;
    v_reason  TEXT;
    v_fccy    TEXT;
    v_tccy    TEXT;
BEGIN
    -- Korrigierbare Input-Pruefungen -> {ok:false} (kein RAISE -> kein Owner-Alert).
    IF v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Amount must be a positive number, got ' || COALESCE(v_amount::text, 'null') || '.');
    END IF;
    IF v_dir NOT IN ('deposit', 'withdrawal', 'relocate') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'direction must be one of deposit, withdrawal, relocate — got ' || COALESCE(v_dir, 'null') || '.');
    END IF;

    SELECT name INTO v_gname FROM finance.savings_goals WHERE id = v_goal;
    IF v_gname IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Savings goal ' || COALESCE(v_goal::text, 'null') || ' not found.');
    END IF;

    -- Nachtrag D: Kontonamen loest die fn selbst auf (nur cash/Festgeld; Depot -> Verweis auf die Reservierung).
    IF v_from IS NULL AND NULLIF(btrim(p->>'from_account_name'), '') IS NOT NULL THEN
        v_res := finance.fn_resolve_cash_account(btrim(p->>'from_account_name'));
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RETURN v_res; END IF;
        v_from := (v_res->>'id')::int;
    END IF;
    IF v_to IS NULL AND NULLIF(btrim(p->>'to_account_name'), '') IS NOT NULL THEN
        v_res := finance.fn_resolve_cash_account(btrim(p->>'to_account_name'));
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RETURN v_res; END IF;
        v_to := (v_res->>'id')::int;
    END IF;

    -- Nachtrag D: Konten aus dem Ziel ableiten und gegen die Reserve pruefen. Die Reserve (fn_goal_reserve_accounts)
    -- einmal lesen; v_cands = Reserve-Konten mit Geld des Ziels (Rueckfrage-Kandidaten).
    SELECT g.recurring_payment_id, rp.target_account_id, rp.account_id INTO v_rp, v_pot, v_funding
      FROM finance.savings_goals g LEFT JOIN finance.recurring_payments rp ON rp.id = g.recurring_payment_id
     WHERE g.id = v_goal;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('account_id', r.account_id, 'name', a.name, 'share', r.share, 'is_pot', r.is_pot)
                              ORDER BY r.is_pot DESC, r.share DESC), '[]'::jsonb)
      INTO v_rs
      FROM finance.fn_goal_reserve_accounts(v_goal) r JOIN finance.accounts a ON a.id = r.account_id;
    v_cands := COALESCE((SELECT jsonb_agg(e - 'is_pot') FROM jsonb_array_elements(v_rs) e WHERE (e->>'share')::numeric > 0), '[]'::jsonb);
    IF v_dir = 'deposit' THEN
        -- Topf; Altziel ohne Rate: das eine Konto, auf dem Geld des Ziels liegt.
        v_to := COALESCE(v_to, v_pot, CASE WHEN jsonb_array_length(v_cands) = 1 THEN (v_cands->0->>'account_id')::int END);
        IF v_to IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'no_reserve',
                'reason', 'Savings goal "' || v_gname || '" has no savings account (pot) - ask the user which account the money goes to'
                       || CASE WHEN v_rp IS NOT NULL THEN ', or set one with tool_set_savings_goal (reserve_account_name).'
                               WHEN jsonb_array_length(v_cands) > 1 THEN ' (one of the candidates).' ELSE '.' END,
                'candidates', v_cands);
        END IF;
        IF jsonb_array_length(v_rs) > 0 AND NOT v_rs @> jsonb_build_array(jsonb_build_object('account_id', v_to)) THEN
            RETURN jsonb_build_object('ok', false, 'code', 'not_reserve',
                'reason', 'A deposit for "' || v_gname || '" goes to its savings account ('
                       || (SELECT string_agg('"' || (e->>'name') || '"', ', ') FROM jsonb_array_elements(v_rs) e)
                       || ') - leave the target account empty, or use direction relocate to move the money of the goal.',
                'candidates', v_rs);
        END IF;
        IF v_cands @> jsonb_build_array(jsonb_build_object('account_id', v_from)) THEN
            RETURN jsonb_build_object('ok', false, 'code', 'use_relocate',
                'reason', 'The money on "' || (SELECT name FROM finance.accounts WHERE id = v_from) || '" already belongs to savings goal "'
                       || v_gname || '" - moving it between the goal''s accounts is direction relocate.');
        END IF;
        v_from := COALESCE(v_from, v_funding);
        IF v_from IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'missing_from', 'reason', 'Ask the user from which account the money comes.');
        END IF;
    ELSE
        v_from := COALESCE(v_from, (v_cands->0->>'account_id')::int);   -- Topf zuerst, sonst groesster Anteil
        SELECT (e->>'share')::numeric INTO v_share FROM jsonb_array_elements(v_cands) e WHERE (e->>'account_id')::int = v_from;
        IF v_from IS NULL OR v_share IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'not_reserve',
                'reason', 'No money of savings goal "' || v_gname || '" is held on that account - name one of the goal''s savings accounts.',
                'candidates', v_cands);
        END IF;
        IF v_share < v_amount THEN
            RETURN jsonb_build_object('ok', false, 'code', 'insufficient_share', 'available', v_share,
                'reason', 'Only ' || v_share || ' of savings goal "' || v_gname || '" are on "'
                       || (SELECT name FROM finance.accounts WHERE id = v_from) || '".');
        END IF;
        IF v_to IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'missing_to', 'reason', 'Ask the user to which account the money goes.');
        END IF;
        IF v_dir = 'withdrawal' AND v_rs @> jsonb_build_array(jsonb_build_object('account_id', v_to)) THEN
            -- Ziel-Konto gehoert selbst zur Reserve: das Geld bliebe im Ziel -> Umschichten, keine Entnahme.
            RETURN jsonb_build_object('ok', false, 'code', 'use_relocate',
                'reason', '"' || (SELECT name FROM finance.accounts WHERE id = v_to) || '" is also a savings account of goal "'
                       || v_gname || '" - moving money between the goal''s accounts is direction relocate.');
        END IF;
        IF v_dir = 'relocate' THEN
            -- Konto-Regel des Topfs (wie Topf aendern); ohne Rate (Altbestand) ohne den Abbuchungskonto-Vergleich.
            v_reason := finance.fn_goal_reserve_account_reason(v_to, v_funding);
            IF v_reason IS NOT NULL THEN
                RETURN jsonb_build_object('ok', false, 'code', 'invalid_reserve', 'reason', v_reason);
            END IF;
        END IF;
    END IF;
    IF v_from = v_to THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A savings-goal movement needs two different accounts (from/to).');
    END IF;
    SELECT name, currency INTO v_fname, v_fccy FROM finance.accounts WHERE id = v_from;
    SELECT name, currency INTO v_tname, v_tccy FROM finance.accounts WHERE id = v_to;

    -- Atomar: die generische Zwei-Bein-Buchung wiederverwenden (group_id, Multi-Waehrung, Post-State).
    -- purpose traegt das Ziel + die Richtung in die Buchungs-Beschreibung (sonst nur "Transfer -> Konto").
    v_r := finance.fn_book_transfer(jsonb_build_object(
        'from_account_id',  v_from,
        'to_account_id',    v_to,
        'from_amount',      v_amount,
        'to_amount',        NULLIF(p->>'to_amount', ''),
        'transaction_date', p->>'transaction_date',
        'from_account_name', v_fname,
        'to_account_name',   v_tname,
        'purpose', COALESCE(NULLIF(p->>'purpose', ''), 'Sparziel ' || v_gname || ' (' || v_dir || ')'),
        -- Phase Notify: getaggte Sparziel-Bewegung = gewolltes Eingreifen -> weder reserve_breach falten noch
        -- den geteilten Latch beruehren (sonst verbrennt der interne Call die Flanke fuer einen spaeteren
        -- echten un-getaggten Breach). Der Re-Arm laeuft unabhaengig trigger-getrieben.
        'suppress_breach', 'true'
    ));

    -- Finding #10: nur bei Erfolg stempeln (sonst kein debit/credit_tx_id -> stiller no-op).
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_r;
    END IF;

    v_debit  := (v_r->>'debit_tx_id')::int;    -- Soll-Bein (from, -)
    v_credit := (v_r->>'credit_tx_id')::int;   -- Haben-Bein (to, +)

    -- Tag-Zuordnung je Richtung. NUR das/die Reserve-Bein(e) (deposit/withdrawal: ein Bein; relocate: beide ->
    -- Netto-0 gewollt). Das jeweils ungetaggte Bein bleibt aus dem Ziel-Saldo (sonst stille Doppel-/Null-Wirkung).
    IF v_dir = 'deposit' THEN
        UPDATE finance.transactions SET savings_goal_id = v_goal WHERE id = v_credit;
    ELSIF v_dir = 'withdrawal' THEN
        UPDATE finance.transactions SET savings_goal_id = v_goal WHERE id = v_debit;
    ELSE  -- relocate: beide Beine (Umzug innerhalb des Ziels, Gesamt unveraendert)
        UPDATE finance.transactions SET savings_goal_id = v_goal WHERE id IN (v_debit, v_credit);
        -- Nachtrag D: leert das Umschichten den Topf vollstaendig, zieht der Topf um (Sparrate fliesst kuenftig dorthin,
        -- alle laufenden Zeilen der Raten-Kette). Ein Teil-Umschichten laesst den Topf, der Rest bleibt Teil der Reserve.
        IF v_from = v_pot AND COALESCE((SELECT r.share FROM finance.fn_goal_reserve_accounts(v_goal) r WHERE r.account_id = v_from), 0) = 0 THEN
            PERFORM finance.fn_apply_goal_reserve(v_goal, v_to);
        END IF;
    END IF;

    -- Post-State: neuer Ziel-Stand + Zielbetrag (in derselben Transaktion gelesen) fuer den HITL-Preview-Vertrag
    -- und den WS-5-Fold.
    SELECT current_amount, target_amount INTO v_cur, v_target FROM finance.savings_goal_progress WHERE id = v_goal;

    -- Phase L WS-5: "Sparziel erreicht"-Sofort-Hinweis (Event-Fold, 0 Extra-SQL — v_cur/v_target schon gelesen).
    -- NUR bei direction='deposit' (B1): eine Einzahlung kann ein Ziel ueber die Linie bringen. Bei withdrawal/
    -- relocate NIE gratulieren (sonst gratuliert es beim Entnehmen aus einem noch ueber-Ziel gefuellten Topf).
    -- v_target>0-Guard (ein 0/NULL-Ziel feuert nicht). Spiegelt den periodischen savings_goal_reached-Zweig im
    -- Advisor (erreicht != ausgegeben). Nicht-blockierend; der Bookkeeper relayed die Note.
    RETURN jsonb_build_object('ok', true,
        'debit_tx_id', v_debit, 'credit_tx_id', v_credit,
        'savings_goal_id', v_goal, 'direction', v_dir,
        'current_amount', v_cur,
        'from_balance', (v_r->>'from_balance')::numeric,
        'to_balance',   (v_r->>'to_balance')::numeric,
        'card_lines',   COALESCE(v_r->'card_lines', '[]'::jsonb),   -- z. B. moegliche Doppelbuchung (fn_book_transfer)
        'effective',    COALESCE(v_r->'effective', '{}'::jsonb) || jsonb_build_object(
                            'from_account_id', v_from, 'from_account_name', v_fname, 'from_currency', v_fccy,
                            'to_account_id', v_to, 'to_account_name', v_tname, 'to_currency', v_tccy))
        || CASE WHEN v_dir = 'deposit' AND v_target IS NOT NULL AND v_target > 0
                     AND v_cur IS NOT NULL AND v_cur >= v_target
                THEN jsonb_build_object('savings_goal_reached', jsonb_build_object(
                    'current_amount', round(v_cur, 2), 'target_amount', round(v_target, 2),
                    'note', 'Savings goal "' || v_gname || '" '
                            || CASE WHEN v_cur > v_target THEN 'reached and exceeded' ELSE 'reached' END
                            || ' (' || round(v_cur, 2) || ' of ' || round(v_target, 2) || ' EUR). Congratulate the user. '
                            || 'The amount stays reserved until they use it - reached is not spent. Options: close the goal '
                            || '(use the reserve first), secure the gains, or raise the target.'))
                ELSE '{}'::jsonb END;
END;
$$;
