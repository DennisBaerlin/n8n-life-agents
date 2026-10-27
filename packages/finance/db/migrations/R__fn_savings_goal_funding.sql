-- ============================================================
-- fn_savings_goal_funding (READ — Livebefund 2026-10-27)
--   Die EINE Ableitung "womit wird ein neues Sparziel gespart und bis wann": fn_create_savings_goal (autoritativ im
--   Write) und die Import-Karte (fn_import_card_rows) rufen sie mit denselben Werten -> Karte = Write.
--   1. Sparplaene (p.savings_plan, einer oder mehrere): erst der ganze Text als EIN Name (ein Name mit Komma bleibt
--      heil), nur bei 0 Treffern an Kommas getrennt; ids dedupliziert; ein Plan gehoert zu EINEM Ziel. Monatsbetrag =
--      heute gueltiges Glied (fn_recurring_current) der AKTIVEN Plaene in EUR; ohne Kurs fuer eine Plan-Waehrung
--      {ok:false} (ein fehlender Kurs faellt nie still aus einer Summe). Ohne target_date und Rate folgt das Zieldatum
--      aus diesem Monatsbetrag.
--   2. Bestehender Dauerauftrag in den Topf (nur Raten-Pfad: kein Plan, Topf bekannt und saldo-basiert, Rest > 0):
--      fn_goal_transfer_choice(Topf, Abbuchungskonto, p.replace_transfer). Fortfuehren -> sein Konto, Tag und
--      naechster Termin, die Rate = SEIN Monatsbetrag (die Bank ueberweist ihn weiter); bei genanntem Datum needed_rate.
--   3. fn_savings_rate_schedule auf dem Rest (Ziel - p_saved_eur).
--   Eingabe: p (Payload wie fn_create_savings_goal; Datumsfelder schon ISO), p_reserve (Topf-id oder NULL = im Import
--   noch nicht angelegt), p_reserve_is_depot, p_acct (Abbuchungskonto-id oder NULL), p_saved_eur (Startbestand in EUR).
--   RUECKGABE: {ok:true, monthly_rate (wirksame eigene Rate bzw. der Plan-/Dauerauftrags-Betrag), needed_rate,
--   target_date, months, first_payment_date, first_defaulted (erste Rate weder genannt noch vom Dauerauftrag),
--   plan_ids, plan_names, plan_monthly, transfer (fortgefuehrter Dauerauftrag oder null), account_id (wirksames
--   Abbuchungskonto), schedule_day_of_month} | {ok:false, reason, code?}. STABLE, schreibt nie.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_savings_goal_funding(p jsonb, p_reserve int, p_reserve_is_depot boolean,
                                                           p_acct int, p_saved_eur numeric)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_plan_name    TEXT    := NULLIF(btrim(p->>'savings_plan'), '');
    v_plan         RECORD;
    v_part         TEXT;
    v_plan_ids     INT[];
    v_plan_names   TEXT;
    v_plan_monthly NUMERIC;
    v_gap          BOOLEAN;
    v_replace      BOOLEAN := CASE lower(btrim(COALESCE(p->>'replace_transfer', '')))
                                   WHEN 'true' THEN true WHEN 'false' THEN false END;
    v_choice       JSONB;
    v_old          JSONB;
    v_acct         INT      := p_acct;
    v_dom          SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_date_given   BOOLEAN  := NULLIF(p->>'target_date', '') IS NOT NULL;
    v_q            JSONB    := p;
    v_sched        JSONB;
    v_rate         NUMERIC;
    v_need         NUMERIC;
BEGIN
    -- 1. Sparplaene
    IF v_plan_name IS NOT NULL THEN
        SELECT r.id, r.hit_count INTO v_plan FROM finance.fn_resolve_savings_plan(v_plan_name, FALSE) r;
        IF COALESCE(v_plan.hit_count, 0) = 1 THEN
            v_plan_ids := ARRAY[v_plan.id];
        ELSIF COALESCE(v_plan.hit_count, 0) > 1 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Multiple savings plans match "' || v_plan_name || '" - ask the user which one.');
        ELSE
            v_plan_ids := '{}';
            FOR v_part IN SELECT btrim(x) FROM regexp_split_to_table(v_plan_name, ',') x WHERE btrim(x) <> '' LOOP
                SELECT r.id, r.hit_count INTO v_plan FROM finance.fn_resolve_savings_plan(v_part, FALSE) r;
                IF COALESCE(v_plan.hit_count, 0) <> 1 THEN
                    RETURN jsonb_build_object('ok', false,
                        'reason', CASE WHEN COALESCE(v_plan.hit_count, 0) = 0 THEN 'No savings plan found matching "' || v_part || '".'
                                       ELSE 'Multiple savings plans match "' || v_part || '" - ask the user which one.' END);
                END IF;
                IF NOT (v_plan.id = ANY (v_plan_ids)) THEN
                    v_plan_ids := v_plan_ids || v_plan.id;
                END IF;
            END LOOP;
            IF cardinality(v_plan_ids) = 0 THEN
                RETURN jsonb_build_object('ok', false, 'reason', 'No savings plan found matching "' || v_plan_name || '".');
            END IF;
        END IF;
        SELECT sp.name INTO v_part FROM finance.savings_plans sp
         WHERE sp.id = ANY (v_plan_ids) AND sp.savings_goal_id IS NOT NULL ORDER BY sp.id LIMIT 1;
        IF v_part IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Savings plan "' || v_part || '" already funds another goal. Unlink it there first.');
        END IF;
        SELECT round(sum(finance.fn_to_eur(abs(c.monthly_equivalent), a.currency)), 2),
               bool_or(finance.fn_to_eur(abs(c.monthly_equivalent), a.currency) IS NULL)
          INTO v_plan_monthly, v_gap
        FROM finance.savings_plans sp
        JOIN finance.recurring_payments c ON c.id = finance.fn_recurring_current(sp.recurring_payment_id, current_date)
        JOIN finance.accounts a ON a.id = c.account_id
        WHERE sp.id = ANY (v_plan_ids) AND sp.status = 'active';
        IF v_gap THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'No exchange rate yet for the currency of a savings plan''s settlement account - its monthly '
                       || 'amount cannot be valued in EUR. Try again later.');
        END IF;
        v_plan_monthly := COALESCE(v_plan_monthly, 0);
        SELECT string_agg(sp.name, ', ' ORDER BY sp.id) INTO v_plan_names
        FROM finance.savings_plans sp WHERE sp.id = ANY (v_plan_ids);
        IF NOT v_date_given AND NULLIF(p->>'monthly_savings_rate', '') IS NULL AND v_plan_monthly > 0 THEN
            v_q := v_q || jsonb_build_object('monthly_savings_rate', v_plan_monthly);
        END IF;
    END IF;

    -- 2. Bestehender Dauerauftrag (nur Raten-Pfad)
    IF v_plan_ids IS NULL AND p_reserve IS NOT NULL AND NOT COALESCE(p_reserve_is_depot, false)
       AND NULLIF(p->>'target_amount', '')::numeric - COALESCE(p_saved_eur, 0) > 0 THEN
        v_choice := finance.fn_goal_transfer_choice(p_reserve, p_acct, v_replace);
        IF (v_choice->>'ok')::boolean IS DISTINCT FROM true THEN
            RETURN v_choice;
        END IF;
        IF jsonb_typeof(v_choice->'transfer') = 'object' THEN
            v_old  := v_choice->'transfer';
            v_acct := COALESCE(v_acct, (v_old->>'account_id')::int);
            v_dom  := NULLIF(v_old->>'day', '')::smallint;
            v_q := v_q || jsonb_build_object('first_payment_date', v_old->>'next_due',
                                             'schedule_day_of_month', COALESCE(v_old->>'day', ''));
            IF NOT v_date_given THEN
                v_q := v_q || jsonb_build_object('monthly_savings_rate', (v_old->>'monthly_amount')::numeric);
            END IF;
        END IF;
    END IF;

    -- 3. Rate ODER Zieldatum auf dem Rest (kein LLM-Rechnen)
    v_sched := finance.fn_savings_rate_schedule(v_q || jsonb_build_object('already_saved', COALESCE(p_saved_eur, 0)));
    IF (v_sched->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_sched;
    END IF;
    v_rate := (v_sched->>'monthly_rate')::numeric;
    IF v_old IS NOT NULL THEN
        v_need := v_rate;
        v_rate := (v_old->>'monthly_amount')::numeric;
    END IF;

    RETURN jsonb_build_object('ok', true,
        'monthly_rate', v_rate,
        'needed_rate', v_need,
        'target_date', v_sched->'target_date',
        'months', v_sched->'months',
        'first_payment_date', v_sched->'first_payment_date',
        'first_defaulted', NULLIF(p->>'first_payment_date', '') IS NULL AND v_old IS NULL,
        'plan_ids', to_jsonb(v_plan_ids),
        'plan_names', v_plan_names,
        'plan_monthly', v_plan_monthly,
        'transfer', v_old,
        'account_id', v_acct,
        'schedule_day_of_month', v_dom);
END;
$$;
