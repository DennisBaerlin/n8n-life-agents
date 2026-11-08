-- ============================================================
-- fn_set_real_estate (ATOMIC WRITE)
--   Aendert eine bestehende Immobilie (Neubewertung/Status/Stammdaten). Partielles Update
--   ("nicht gesendet = unveraendert"). Reine UPDATE -- kein Trigger/GENERATED; die Net-Worth-View
--   finance_real_estate_overview liest current_value live.
--   Wird current_value gesetzt OHNE value_updated_at -> value_updated_at = CURRENT_DATE (Bewertungsdatum).
--   Eingabe jsonb: real_estate_id (im n8n via fn_resolve_real_estate aufgeloest), name,
--   current_value (Betrag, auch deutsch geschrieben), value_updated_at, owner_person_id (Slug; leer=unveraendert),
--   status ('active'; 'sold' nur, wenn schon verkauft -- ein Verkauf laeuft ueber fn_sell_real_estate), notes,
--   living_area_m2, year_built (Instandhaltungsruecklage 2026-10-27; leer=unveraendert).
--   RUECKGABE: {ok:true, real_estate_id, card_lines (nur wenn Flaeche/Baujahr gesendet: fn_maintenance_card_lines)}.
--   Korrigierbar (current_value<0 oder unlesbar, unbekannter status, Flaeche/Baujahr ungueltig) -> {ok:false};
--   status sold auf einer aktiven Immobilie -> {ok:false, code:'use_sell_tool'}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_real_estate(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id     INT     := (p->>'real_estate_id')::int;
    v_cv     NUMERIC := finance.fn_parse_numeric_or_null(p->>'current_value', true);
    v_reason TEXT    := finance.fn_enum_reason('finance.property_status'::regtype, p->>'status', 'status');
    v_dates  JSONB;
BEGIN
    -- relative Datumsangabe ("yesterday") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['value_updated_at']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    IF NOT EXISTS (SELECT 1 FROM finance.real_estate WHERE id = v_id) THEN
        RAISE EXCEPTION 'Real estate % not found.', v_id;
    END IF;
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    -- Verkauf nur ueber fn_sell_real_estate: nur dort entstehen Erloes-Buchung und sale_tx_id (Rueckgaengig)
    IF NULLIF(p->>'status', '') = 'sold' AND (SELECT status FROM finance.real_estate WHERE id = v_id) <> 'sold' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'use_sell_tool',
            'reason', 'A sale is recorded with tool_sell_real_estate (it books the proceeds and can be undone) - status sold cannot be set here.');
    END IF;
    IF v_cv IS NULL AND NULLIF(btrim(p->>'current_value'), '') IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Current value "' || (p->>'current_value') || '" is not a readable amount - give it as a plain number.');
    END IF;

    -- Korrigierbar: Wert darf nicht negativ sein.
    IF v_cv IS NOT NULL AND v_cv < 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Current value must not be negative, got ' || v_cv || '.');
    END IF;
    v_reason := finance.fn_real_estate_facts_reason(p);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;

    UPDATE finance.real_estate SET
        name             = COALESCE(NULLIF(p->>'name', ''), name),
        current_value    = COALESCE(v_cv, current_value),
        value_updated_at = CASE
                               WHEN v_cv IS NOT NULL
                               THEN COALESCE(NULLIF(p->>'value_updated_at', '')::date, core.fn_today())
                               ELSE COALESCE(NULLIF(p->>'value_updated_at', '')::date, value_updated_at)
                           END,
        owner_person_id  = COALESCE(NULLIF(p->>'owner_person_id', ''), owner_person_id),  -- WS-4: typisierter Eigentuemer (Slug); leer=unveraendert
        status           = COALESCE(NULLIF(p->>'status', '')::finance.property_status, status),
        notes            = COALESCE(NULLIF(p->>'notes', ''), notes),
        living_area_m2   = COALESCE(NULLIF(p->>'living_area_m2', '')::numeric, living_area_m2),
        year_built       = COALESCE(NULLIF(p->>'year_built', '')::smallint, year_built)
    WHERE id = v_id;

    RETURN jsonb_build_object('ok', true, 'real_estate_id', v_id, 'effective', v_dates->'resolved')
        || CASE WHEN NULLIF(p->>'living_area_m2', '') IS NOT NULL OR NULLIF(p->>'year_built', '') IS NOT NULL
                THEN jsonb_build_object('card_lines', finance.fn_maintenance_card_lines(v_id)) ELSE '{}'::jsonb END;
END;
$$;
