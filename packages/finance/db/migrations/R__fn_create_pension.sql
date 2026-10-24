-- ============================================================
-- fn_create_pension (ATOMIC WRITE)
--   Erfasst eine Altersvorsorge als Net-Worth-Asset (gesetzlich/bAV/Riester/Ruerup/privat).
--   Optional monatlicher Beitrag -> recurring_payment (expense) via fn_add_recurring_payment + FK.
--   Eingabe jsonb: name, pension_type, provider, contract_number, owner_person_id (Slug, NULL=Haushalt), current_value (opt;
--   Rueckkaufswert/Deckungskapital), value_updated_at (opt), guaranteed_monthly_pension (opt),
--   retirement_start_date (opt), contribution_amount (opt, positiv), debit_account_id (opt, n8n-
--   resolved; Pflicht wenn contribution gesetzt), schedule_day_of_month (opt), first_payment_date
--   (opt), notes.
--   RUECKGABE: Erfolg -> {ok:true, pension_id, recurring_payment_id}. Korrigierbar
--   (unbekannter pension_type, current_value<0, contribution<0, contribution ohne bzw. auf nicht buchbares
--   debit_account [Depot/Kredit]) -> {ok:false, reason}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_create_pension(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_type       finance.pension_type;   -- Cast erst nach dem Enum-Guard (Import-Haertung)
    v_reason     TEXT;
    v_current    NUMERIC  := NULLIF(p->>'current_value','')::numeric;
    v_contrib    NUMERIC  := NULLIF(p->>'contribution_amount','')::numeric;
    v_debit      INT      := NULLIF(p->>'debit_account_id','')::int;
    v_dom        SMALLINT := NULLIF(p->>'schedule_day_of_month','')::smallint;
    v_first      DATE     := NULLIF(p->>'first_payment_date','')::date;
    v_pension_id INT;
    v_rp_id      INT;
BEGIN
    v_reason := finance.fn_enum_reason('finance.pension_type'::regtype, p->>'pension_type', 'pension_type');
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    v_type := (p->>'pension_type')::finance.pension_type;
    -- WP-2b: fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate.
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    -- Korrigierbare Pruefungen -> {ok:false}.
    IF v_current IS NOT NULL AND v_current < 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Current value must not be negative, got ' || v_current || '.');
    END IF;
    IF v_contrib IS NOT NULL AND v_contrib < 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Contribution amount must not be negative, got ' || v_contrib || '.');
    END IF;
    IF v_contrib IS NOT NULL AND v_contrib > 0 AND v_debit IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A monthly contribution was given but no debit account to book it from. Provide the debit account or omit the contribution.');
    END IF;
    -- Beitrag nur von einem buchbaren Konto (Depot/Kredit tragen kein Geld; die Faelligkeit bliebe sonst ewig offen).
    IF v_contrib IS NOT NULL AND v_contrib > 0 THEN
        v_reason := finance.fn_bookable_account_reason(v_debit);
        IF v_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', v_reason);
        END IF;
    END IF;

    -- Optional: monatlicher Beitrag als recurring_payment (expense) via Helper.
    IF v_contrib IS NOT NULL AND v_contrib > 0 THEN
        v_rp_id := finance.fn_add_recurring_payment(
            v_debit, -v_contrib, 'AV-Beitrag ' || (p->>'name'),
            1::smallint, 'month'::finance.schedule_unit, v_dom,
            COALESCE(v_first, CURRENT_DATE),
            finance.fn_recurring_valid_from(v_debit, COALESCE(v_first, CURRENT_DATE)), NULL, NULL, NULL);
    END IF;

    INSERT INTO finance.pension
        (name, pension_type, provider, contract_number, owner_person_id, current_value, value_updated_at,
         guaranteed_monthly_pension, retirement_start_date, recurring_payment_id, status, notes)
    VALUES (
        p->>'name',
        v_type,
        NULLIF(p->>'provider',''),
        NULLIF(p->>'contract_number',''),
        NULLIF(p->>'owner_person_id',''),   -- WS-4: typisierter Eigentuemer (Slug, im Tool aufgeloest); NULL=Haushalt.
        v_current,
        NULLIF(p->>'value_updated_at','')::date,
        NULLIF(p->>'guaranteed_monthly_pension','')::numeric,
        NULLIF(p->>'retirement_start_date','')::date,
        v_rp_id,
        'active',
        NULLIF(p->>'notes','')
    )
    RETURNING id INTO v_pension_id;

    RETURN jsonb_build_object('ok', true, 'pension_id', v_pension_id, 'recurring_payment_id', v_rp_id);
END;
$$;
