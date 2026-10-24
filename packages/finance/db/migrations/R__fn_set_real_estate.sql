-- ============================================================
-- fn_set_real_estate (ATOMIC WRITE)
--   Aendert eine bestehende Immobilie (Neubewertung/Status/Stammdaten). Partielles Update
--   ("nicht gesendet = unveraendert"). Reine UPDATE -- kein Trigger/GENERATED; die Net-Worth-View
--   finance_real_estate_overview liest current_value live.
--   Wird current_value gesetzt OHNE value_updated_at -> value_updated_at = CURRENT_DATE (Bewertungsdatum).
--   HINWEIS: status='sold' loest verknuepfte Kredite (real_estate_id) NICHT automatisch ab.
--   Eingabe jsonb: real_estate_id (im n8n via fn_resolve_real_estate aufgeloest), name,
--   current_value, value_updated_at, owner_person_id (Slug; leer=unveraendert), status ('active'|'sold'), notes.
--   RUECKGABE: {ok:true, real_estate_id}. Korrigierbar (current_value<0, unbekannter status) -> {ok:false}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_real_estate(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id     INT     := (p->>'real_estate_id')::int;
    v_cv     NUMERIC := NULLIF(p->>'current_value', '')::numeric;
    v_reason TEXT    := finance.fn_enum_reason('finance.property_status'::regtype, p->>'status', 'status');
BEGIN
    IF NOT EXISTS (SELECT 1 FROM finance.real_estate WHERE id = v_id) THEN
        RAISE EXCEPTION 'Real estate % not found.', v_id;
    END IF;
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;

    -- Korrigierbar: Wert darf nicht negativ sein.
    IF v_cv IS NOT NULL AND v_cv < 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Current value must not be negative, got ' || v_cv || '.');
    END IF;

    UPDATE finance.real_estate SET
        name             = COALESCE(NULLIF(p->>'name', ''), name),
        current_value    = COALESCE(v_cv, current_value),
        value_updated_at = CASE
                               WHEN v_cv IS NOT NULL
                               THEN COALESCE(NULLIF(p->>'value_updated_at', '')::date, CURRENT_DATE)
                               ELSE COALESCE(NULLIF(p->>'value_updated_at', '')::date, value_updated_at)
                           END,
        owner_person_id  = COALESCE(NULLIF(p->>'owner_person_id', ''), owner_person_id),  -- WS-4: typisierter Eigentuemer (Slug); leer=unveraendert
        status           = COALESCE(NULLIF(p->>'status', '')::finance.property_status, status),
        notes            = COALESCE(NULLIF(p->>'notes', ''), notes)
    WHERE id = v_id;

    RETURN jsonb_build_object('ok', true, 'real_estate_id', v_id);
END;
$$;
