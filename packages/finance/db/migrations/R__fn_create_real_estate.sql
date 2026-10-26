-- ============================================================
-- fn_create_real_estate (ATOMIC WRITE)
--   Ein INSERT — als Function gefuehrt fuer Einheitlichkeit (jedes Write-Tool ruft fn_*),
--   damit spaetere Zusatz-Schritte (z. B. verknuepfte Zeilen) nahtlos in dieselbe Transaktion
--   passen. Eingabe jsonb: name, current_value, value_updated_at, owner_person_id (Slug, NULL=Haushalt),
--   status, notes.
--   RUECKGABE: {ok:true, real_estate_id}. Korrigierbar (unbekannter status) -> {ok:false, reason}.
--   Ungueltiger owner_person_id-Slug -> FK-Backstop (RAISE); der Normalfall ist im Tool-Resolve
--   (core.fn_resolve_person) vorvalidiert.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_create_real_estate(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id     INT;
    v_sim    TEXT;
    v_reason TEXT := finance.fn_enum_reason('finance.property_status'::regtype, p->>'status', 'status');
    v_dates  JSONB;
BEGIN
    -- relative Datumsangabe ("yesterday") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['value_updated_at']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    -- Karten-Hinweis (hohe Schwelle): aktive Immobilie derselben Inhaberschaft mit gleichem Wert
    SELECT re.name INTO v_sim FROM finance.real_estate re
     WHERE re.status = 'active' AND NULLIF(p->>'current_value', '') IS NOT NULL
       AND re.current_value = NULLIF(p->>'current_value', '')::numeric
       AND re.owner_person_id IS NOT DISTINCT FROM NULLIF(p->>'owner_person_id', '')
     ORDER BY re.id LIMIT 1;
    INSERT INTO finance.real_estate
        (name, current_value, value_updated_at, owner_person_id, status, notes)
    VALUES (p->>'name', NULLIF(p->>'current_value', '')::numeric, NULLIF(p->>'value_updated_at', '')::date,
            NULLIF(p->>'owner_person_id', ''),   -- WS-4: typisierter Eigentuemer (Slug, im Tool aufgeloest); NULL=Haushalt.
            COALESCE(NULLIF(p->>'status', ''), 'active')::finance.property_status,
            NULLIF(p->>'notes', ''))
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'real_estate_id', v_id, 'card_lines', finance.fn_similar_note(v_sim),
        'effective', v_dates->'resolved');
END;
$$;
