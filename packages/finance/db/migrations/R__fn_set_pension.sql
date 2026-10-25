-- ============================================================
-- fn_set_pension (ATOMIC WRITE)
--   Aendert eine bestehende Altersvorsorge (Wert/Status/Stammdaten). Partielles Update
--   ("nicht gesendet = unveraendert"). Wert/Status sicher; der Beitrags-BETRAG wird hier
--   bewusst NICHT geaendert (Scope schlank; gehoert zum set_recurring_payment-Thema).
--   Wird current_value gesetzt OHNE value_updated_at -> value_updated_at = CURRENT_DATE.
--   STATUS-KASKADE: status in ('paused','paid_out') + verknuepfte recurring_payment ->
--   diese auf 'paused' (Beitrag verlaesst den Cashflow); status='active' -> recurring 'active'.
--   NAMEN (WP2): eine Umbenennung fuehrt 'AV-Beitrag <Name>' an der Beitrags-Kette mit.
--   Eingabe jsonb: pension_id (im n8n via fn_resolve_pension aufgeloest), name, provider,
--   contract_number, owner_person_id (Slug; leer=unveraendert), current_value, value_updated_at, guaranteed_monthly_pension,
--   retirement_start_date, status ('active'|'paused'|'paid_out'), notes.
--   RUECKGABE: {ok:true, pension_id, recurring_payment_id}. Korrigierbar (current_value<0, unbekannter status)
--   -> {ok:false}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_pension(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id     INT     := (p->>'pension_id')::int;
    v_cv     NUMERIC := NULLIF(p->>'current_value', '')::numeric;
    v_status finance.pension_status;   -- Cast erst nach dem Enum-Guard (Import-Haertung)
    v_reason TEXT    := finance.fn_enum_reason('finance.pension_status'::regtype, p->>'status', 'status');
    v_rp     INT;
    v_old    TEXT;
BEGIN
    SELECT recurring_payment_id, name INTO v_rp, v_old FROM finance.pension WHERE id = v_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pension % not found.', v_id;
    END IF;
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    v_status := NULLIF(p->>'status', '')::finance.pension_status;

    -- Korrigierbar: Wert darf nicht negativ sein.
    IF v_cv IS NOT NULL AND v_cv < 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Current value must not be negative, got ' || v_cv || '.');
    END IF;

    UPDATE finance.pension SET
        name                       = COALESCE(NULLIF(p->>'name', ''), name),
        provider                   = COALESCE(NULLIF(p->>'provider', ''), provider),
        contract_number            = COALESCE(NULLIF(p->>'contract_number', ''), contract_number),
        owner_person_id            = COALESCE(NULLIF(p->>'owner_person_id', ''), owner_person_id),  -- WS-4: typisierter Eigentuemer (Slug); leer=unveraendert

        current_value              = COALESCE(v_cv, current_value),
        value_updated_at           = CASE
                                         WHEN v_cv IS NOT NULL
                                         THEN COALESCE(NULLIF(p->>'value_updated_at', '')::date, CURRENT_DATE)
                                         ELSE COALESCE(NULLIF(p->>'value_updated_at', '')::date, value_updated_at)
                                     END,
        guaranteed_monthly_pension = COALESCE(NULLIF(p->>'guaranteed_monthly_pension', '')::numeric, guaranteed_monthly_pension),
        retirement_start_date      = COALESCE(NULLIF(p->>'retirement_start_date', '')::date, retirement_start_date),
        status                     = COALESCE(v_status, status),
        notes                      = COALESCE(NULLIF(p->>'notes', ''), notes)
    WHERE id = v_id;

    -- Namenskopie 'AV-Beitrag <Name>' an der Beitrags-Kette mitfuehren (WP2, fn_rename_owned_recurring).
    PERFORM finance.fn_rename_owned_recurring(v_rp, 'AV-Beitrag', v_old, NULLIF(p->>'name', ''));

    -- Status-Kaskade auf den verknuepften Beitrag (recurring_payment).
    IF v_status IS NOT NULL AND v_rp IS NOT NULL THEN
        UPDATE finance.recurring_payments
        SET status = CASE WHEN v_status = 'active' THEN 'active' ELSE 'paused' END::finance.payment_status
        WHERE id = v_rp;
    END IF;

    RETURN jsonb_build_object('ok', true, 'pension_id', v_id, 'recurring_payment_id', v_rp);
END;
$$;
