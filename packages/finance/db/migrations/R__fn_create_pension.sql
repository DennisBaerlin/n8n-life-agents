-- ============================================================
-- fn_create_pension (ATOMIC WRITE)
--   Erfasst eine Altersvorsorge als Net-Worth-Asset (gesetzlich/bAV/Riester/Ruerup/privat).
--   Optional Beitrag -> recurring_payment (expense) via fn_add_recurring_payment + FK. Beitrag JE ABBUCHUNG roh +
--   Rhythmus (schedule_interval/schedule_unit, Default 1 x Monat; WP2: das LLM rechnet nie in einen Monatswert um --
--   pension_overview.monthly_contribution leitet ihn aus rp.monthly_equivalent ab).
--   Eingabe jsonb: name, pension_type, provider, contract_number, owner_person_id (Slug, NULL=Haushalt), current_value (opt;
--   Rueckkaufswert/Deckungskapital), value_updated_at (opt), guaranteed_monthly_pension (opt),
--   retirement_start_date (opt), contribution_amount (opt, positiv, je Abbuchung), schedule_interval/schedule_unit (opt),
--   debit_account_id (opt, n8n-
--   resolved; Pflicht wenn contribution gesetzt), schedule_day_of_month (opt), first_payment_date
--   (opt), notes.
--   RUECKGABE: Erfolg -> {ok:true, pension_id, recurring_payment_id}. Korrigierbar
--   (unbekannter pension_type/Rhythmus, current_value<0, contribution<0, contribution ohne bzw. auf nicht buchbares
--   debit_account [Depot/Kredit], gesetzliche Rente mit Monatsrente/Wert oder als zweite aktive der Person)
--   -> {ok:false, reason}.
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
    v_interval   SMALLINT;
    v_unit       finance.schedule_unit;
    v_pension_id INT;
    v_rp_id      INT;
BEGIN
    v_reason := COALESCE(finance.fn_enum_reason('finance.pension_type'::regtype, p->>'pension_type', 'pension_type'),
                         finance.fn_enum_reason('finance.schedule_unit'::regtype, p->>'schedule_unit', 'schedule_unit'));
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    v_type := (p->>'pension_type')::finance.pension_type;
    v_unit := COALESCE(NULLIF(p->>'schedule_unit','')::finance.schedule_unit, 'month');
    -- Rhythmus-Intervall: ganze Zahl >= 1 (Text wie 'quarterly' -> {ok:false} statt Cast-Fehler mit Owner-Alarm)
    IF (CASE WHEN COALESCE(NULLIF(btrim(p->>'schedule_interval'), ''), '1') ~ '^[0-9]{1,3}$'
             THEN COALESCE(NULLIF(btrim(p->>'schedule_interval'), ''), '1')::int < 1 ELSE true END) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The payment interval (schedule_interval) must be a whole number of at least 1, got "' || (p->>'schedule_interval') || '".');
    END IF;
    v_interval := COALESCE(NULLIF(btrim(p->>'schedule_interval'), ''), '1')::smallint;
    -- WP-2b: fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate.
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    -- Korrigierbare Pruefungen -> {ok:false}.
    IF v_current IS NOT NULL AND v_current < 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Current value must not be negative, got ' || v_current || '.');
    END IF;
    -- Gesetzliche Rente (Spiegel CHECK finance_pension_statutory_no_amounts + UNIQUE finance_pension_statutory_uq):
    -- Monatsrente/Wert stehen in der Renteninformation; je Person hoechstens eine aktive.
    IF v_type = 'statutory' AND (v_current IS NOT NULL OR NULLIF(p->>'guaranteed_monthly_pension','') IS NOT NULL) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A statutory pension stores no monthly pension or value of its own - those figures belong to its '
                   || 'Renteninformation (send the statement as a PDF, or leave both fields empty).');
    END IF;
    IF v_type = 'statutory' THEN
        SELECT name INTO v_reason FROM finance.pension
         WHERE pension_type = 'statutory' AND status = 'active'
           AND owner_person_id IS NOT DISTINCT FROM NULLIF(p->>'owner_person_id','');
        IF FOUND THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'This person already has an active statutory pension ("' || v_reason
                       || '") - add the new Renteninformation to it instead of creating a second one.');
        END IF;
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

    -- Optional: Beitrag je Abbuchung als recurring_payment (expense) via Helper.
    IF v_contrib IS NOT NULL AND v_contrib > 0 THEN
        v_rp_id := finance.fn_add_recurring_payment(
            v_debit, -v_contrib, left('AV-Beitrag ' || (p->>'name'), 100),
            v_interval, v_unit, v_dom,
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
