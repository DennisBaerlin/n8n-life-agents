-- ============================================================
-- fn_book_savings_goal_reassign (ATOMIC WRITE, intern) — "Sparziel umziehen" ohne Geldbewegung (2026-11-01)
--   Zweig direction='reassign' von fn_book_savings_goal_transfer (nur dort aufgerufen, eine Transaktion): die
--   Zuordnung eines Ziels wechselt das Konto (YNAB/Firefly: Ziel-Geld bestaetigt verschieben). Zwei Journal-Zeilen
--   kind='manual' ueber fn_book_savings_reservation (EINE Regel fuer Kontoarten, Ruecklagen-Arten und den
--   Freier-Saldo-Guard): erst das Ziel-Konto erhoehen (geguardet, darf {ok:false} liefern, noch kein Write), dann die
--   Quelle senken (Senken ist immer erlaubt). Netto-EUR 0 -> Fortschritt und Spartempo unveraendert.
--   Ziel-Konto Depot: Zuordnung in EUR, Deckung = Marktwert (kein harter Block, shortfall im Post-State, wie die
--   Reservierung); ohne Kurs -> no_price. Ziel kurz vor dem Termin (2026-11-06): kein Verbot, sondern die Warnkarte aus
--   fn_goal_depot_risk_fold (card_lines, card_approve_key, effective.depot_risk_shown; nach dem Tipp der Stempel
--   + depot_risk.reminder_month).
--   Betrag in der Waehrung der Quelle (Depot-Quelle: EUR); leer = ganzer Anteil der Quelle. Umrechnung
--   Quelle -> EUR -> Ziel-Konto zum heutigen Kurs (fn_to_eur / fn_to_eur_unrounded), fehlender Kurs -> fx_missing.
--   Rueckgaengig = reassign zurueck (das Journal ist append-only, kein Void).
--   Eingabe jsonb: savings_goal_id, from_account_id|from_account_name (opt: leer = das eine Konto mit Geld des Ziels;
--   bei mehreren missing_from + candidates), to_account_id|to_account_name, amount (opt). to_amount gilt hier nicht.
--   RUECKGABE Erfolg: {ok:true, savings_goal_id, direction:'reassign', amount (umgezogen, Quell-Waehrung; abgeleitet
--     bei leerem amount), from_share, to_share (neue Anteile, Kontowaehrung bzw. EUR beim Depot), current_amount,
--     from_free_balance | (Depot-Quelle) -, to_free_balance (saldo-basiert) | market_value + shortfall (Depot),
--     effective {from/to id, Name, Waehrung, rate_pot_name (Topf, in den die Monatsrate weiter fliesst, falls = Quelle)}}.
--   Korrigierbar {ok:false, code?, reason}: amount <= 0, Ziel nicht gefunden, Konto nicht gefunden/mehrdeutig,
--     missing_from/missing_to, from==to, not_reserve, insufficient_share, no_price, fx_missing,
--     sowie jede Ablehnung der Reservierung (z. B. insufficient_free_balance, Ruecklagen-Konto-Regeln).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_savings_goal_reassign(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_goal   INT     := NULLIF(p->>'savings_goal_id', '')::int;
    v_from   INT     := NULLIF(p->>'from_account_id', '')::int;
    v_to     INT     := NULLIF(p->>'to_account_id', '')::int;
    v_amount NUMERIC := NULLIF(p->>'amount', '')::numeric;
    v_gname  TEXT;
    v_res    RECORD;
    v_fname  TEXT; v_fccy TEXT; v_ftype finance.account_type; v_fdepot BOOLEAN;
    v_tname  TEXT; v_tccy TEXT; v_ttype finance.account_type; v_tdepot BOOLEAN;
    v_fshare NUMERIC;
    v_tshare NUMERIC;
    v_eur    NUMERIC;
    v_tamt   NUMERIC;
    v_rate   NUMERIC;
    v_mv     NUMERIC;
    v_short  NUMERIC;
    v_r      JSONB;
    v_pot    TEXT;
    v_out    JSONB;
    v_n      INT;
    v_cands  JSONB;
    v_fold   JSONB := '{}'::jsonb;
BEGIN
    IF v_amount IS NOT NULL AND v_amount <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Amount must be a positive number (or empty for the whole share), got ' || v_amount::text || '.');
    END IF;
    SELECT name INTO v_gname FROM finance.savings_goals WHERE id = v_goal;
    IF v_gname IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Savings goal ' || COALESCE(v_goal::text, 'null') || ' not found.');
    END IF;

    -- Namen: jedes zuordenbare Konto (auch Depots), erst exakt, dann ohne Gross-/Kleinschreibung.
    IF v_from IS NULL AND NULLIF(btrim(p->>'from_account_name'), '') IS NOT NULL THEN
        SELECT r.id, r.hit_count, r.candidates INTO v_res
          FROM finance.fn_resolve_account(btrim(p->>'from_account_name'), finance.fn_goal_earmark_account_types()::text[], TRUE) r;
        IF v_res.hit_count <> 1 THEN
            RETURN jsonb_build_object('ok', false, 'code', CASE WHEN v_res.hit_count = 0 THEN 'not_found' ELSE 'ambiguous' END,
                'reason', 'Ask the user which account "' || btrim(p->>'from_account_name') || '" means.', 'candidates', v_res.candidates);
        END IF;
        v_from := v_res.id;
    END IF;
    IF v_to IS NULL AND NULLIF(btrim(p->>'to_account_name'), '') IS NOT NULL THEN
        SELECT r.id, r.hit_count, r.candidates INTO v_res
          FROM finance.fn_resolve_account(btrim(p->>'to_account_name'), finance.fn_goal_earmark_account_types()::text[], TRUE) r;
        IF v_res.hit_count <> 1 THEN
            RETURN jsonb_build_object('ok', false, 'code', CASE WHEN v_res.hit_count = 0 THEN 'not_found' ELSE 'ambiguous' END,
                'reason', 'Ask the user which account "' || btrim(p->>'to_account_name') || '" means.', 'candidates', v_res.candidates);
        END IF;
        v_to := v_res.id;
    END IF;
    -- Quelle offen: das eine Konto mit Geld des Ziels (ausser dem Ziel-Konto); bei mehreren nachfragen.
    IF v_from IS NULL THEN
        SELECT count(*), min(s.account_id),
               COALESCE(jsonb_agg(jsonb_build_object('account_id', s.account_id, 'name', s.account_name, 'share_eur', round(s.share_eur, 2))
                                  ORDER BY s.share_eur DESC), '[]'::jsonb)
          INTO v_n, v_from, v_cands
          FROM finance.savings_goal_account_share s
         WHERE s.goal_id = v_goal AND s.share_eur > 0 AND s.account_id IS DISTINCT FROM v_to;
        IF v_n = 0 THEN
            RETURN jsonb_build_object('ok', false, 'code', 'not_reserve',
                'reason', 'No money of savings goal "' || v_gname || '" is assigned to another account.');
        END IF;
        IF v_n > 1 THEN
            RETURN jsonb_build_object('ok', false, 'code', 'missing_from', 'candidates', v_cands,
                'reason', 'The money of savings goal "' || v_gname || '" lies on several accounts - ask the user from which one it moves (candidates).');
        END IF;
    END IF;
    IF v_to IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'missing_to', 'reason', 'Ask the user to which account the goal moves.');
    END IF;
    IF v_from = v_to THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Moving a savings goal needs two different accounts (from/to).');
    END IF;
    SELECT name, currency, account_type INTO v_fname, v_fccy, v_ftype FROM finance.accounts WHERE id = v_from;
    SELECT name, currency, account_type INTO v_tname, v_tccy, v_ttype FROM finance.accounts WHERE id = v_to;
    IF v_fname IS NULL OR v_tname IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found', 'reason', 'Account not found.');
    END IF;
    v_fdepot := v_ftype IN ('stocks_depot', 'crypto_depot');
    v_tdepot := v_ttype IN ('stocks_depot', 'crypto_depot');

    -- Anteil der Quelle (eine Quelle: savings_goal_account_share; Depot in EUR, sonst Kontowaehrung).
    SELECT CASE WHEN v_fdepot THEN s.share_eur ELSE s.share_native END INTO v_fshare
      FROM finance.savings_goal_account_share s WHERE s.goal_id = v_goal AND s.account_id = v_from;
    IF COALESCE(v_fshare, 0) <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_reserve',
            'reason', 'No money of savings goal "' || v_gname || '" is assigned to "' || v_fname || '".');
    END IF;
    v_amount := COALESCE(v_amount, v_fshare);
    IF v_amount > v_fshare THEN
        RETURN jsonb_build_object('ok', false, 'code', 'insufficient_share', 'available', round(v_fshare, 2),
            'reason', 'Only ' || round(v_fshare, 2) || ' of savings goal "' || v_gname || '" are assigned to "' || v_fname || '".');
    END IF;

    IF v_tdepot THEN
        SELECT market_value INTO v_mv FROM finance.depot_reserve_status WHERE account_id = v_to;
        IF v_mv IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'no_price',
                'reason', 'The market value of "' || v_tname || '" is unknown (a position has no price) - fix the price first, then move the goal.');
        END IF;
    END IF;

    -- Umrechnung Quelle -> EUR -> Ziel-Konto (heute). Gleiche Nicht-Depot-Waehrung: 1:1.
    v_eur := CASE WHEN v_fdepot THEN v_amount ELSE finance.fn_to_eur(v_amount, v_fccy, CURRENT_DATE) END;
    IF v_tdepot THEN
        v_tamt := v_eur;
    ELSIF NOT v_fdepot AND v_tccy = v_fccy THEN
        v_tamt := v_amount;
    ELSE
        v_rate := finance.fn_to_eur_unrounded(1, v_tccy, CURRENT_DATE);
        v_tamt := CASE WHEN v_rate > 0 THEN round(v_eur / v_rate, 2) END;
    END IF;
    IF v_eur IS NULL OR v_tamt IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'fx_missing',
            'reason', 'No exchange rate for today between ' || v_fccy || ' and ' || v_tccy || ' - try again after the rate update.');
    END IF;

    -- Ziel-Konto zuerst (geguardet, ohne Write bei Ablehnung), dann die Quelle senken.
    SELECT CASE WHEN v_tdepot THEN s.share_eur ELSE s.share_native END INTO v_tshare
      FROM finance.savings_goal_account_share s WHERE s.goal_id = v_goal AND s.account_id = v_to;
    v_r := finance.fn_book_savings_reservation(jsonb_build_object(
        'savings_goal_id', v_goal, 'account_id', v_to, 'amount', COALESCE(v_tshare, 0) + v_tamt, 'suppress_depot_risk', true));   -- faltet unten selbst
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_r;
    END IF;
    v_out := jsonb_build_object('ok', true, 'savings_goal_id', v_goal, 'direction', 'reassign',
        'amount', round(v_amount, 2),
        'to_share', round(COALESCE(v_tshare, 0) + v_tamt, 2));
    IF v_tdepot THEN
        v_out := v_out || jsonb_build_object('market_value', v_r->'market_value', 'shortfall', v_r->'shortfall');
    END IF;

    v_r := finance.fn_book_savings_reservation(jsonb_build_object(
        'savings_goal_id', v_goal, 'account_id', v_from, 'amount', v_fshare - v_amount));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'fn_book_savings_goal_reassign: releasing the source share failed: %', v_r;   -- Rollback (echte Ausnahme)
    END IF;

    -- Sparziel kurz vor dem Termin ins Depot (2026-11-06): kein Verbot mehr, sondern Karte mit Warnung + Stempel
    -- (fn_goal_depot_risk_fold, nach beiden Journal-Zeilen = Post-State). Die zwei inneren Reservierungen tragen nie
    -- depot_risk_shown und stempeln nie.
    IF v_tdepot THEN
        v_fold := finance.fn_goal_depot_risk_fold(v_goal, p->'depot_risk_shown');
    END IF;

    -- Post-State in derselben Transaktion: freie Salden saldo-basierter Konten, Ziel-Stand.
    SELECT a.name INTO v_pot
      FROM finance.savings_goals g
      JOIN finance.recurring_payments rp ON rp.id = finance.fn_recurring_lineage_head(g.recurring_payment_id)
      JOIN finance.accounts a ON a.id = rp.target_account_id
     WHERE g.id = v_goal AND rp.target_account_id = v_from;
    RETURN v_out || jsonb_build_object(
        'from_share', round(v_fshare - v_amount, 2),
        'current_amount', (SELECT round(current_amount, 2) FROM finance.savings_goal_progress WHERE id = v_goal),
        'effective', jsonb_build_object(
            'from_account_id', v_from, 'from_account_name', v_fname, 'from_currency', CASE WHEN v_fdepot THEN 'EUR' ELSE v_fccy END,
            'to_account_id', v_to, 'to_account_name', v_tname, 'to_currency', CASE WHEN v_tdepot THEN 'EUR' ELSE v_tccy END,
            'rate_pot_name', v_pot) || COALESCE(v_fold->'effective', '{}'::jsonb),
        'card_lines', COALESCE(v_fold->'card_lines', '[]'::jsonb))
        || (v_fold - 'card_lines' - 'effective')
        || CASE WHEN v_fdepot THEN '{}'::jsonb
                ELSE jsonb_build_object('from_free_balance', round(finance.fn_account_free_balance(v_from), 2)) END
        || CASE WHEN v_tdepot THEN '{}'::jsonb
                ELSE jsonb_build_object('to_free_balance', round(finance.fn_account_free_balance(v_to), 2)) END;
END;
$$;
