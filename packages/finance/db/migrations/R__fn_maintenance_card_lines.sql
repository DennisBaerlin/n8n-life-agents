-- ============================================================
-- fn_maintenance_card_lines (KARTEN-HINWEIS Instandhaltungsruecklage, 2026-10-27)
--   Die EINE Form der Hinweis-Zeilen an der Immobilien-Karte (fn_create_real_estate / fn_set_real_estate):
--   (1) sind Wohnflaeche und Baujahr bekannt -> finance.note.maintenance_recommendation mit der Monatsrate aus
--       fn_maintenance_reserve_rate (Untergrenze nach II. BV; params monthly/rate/area/age);
--   (2) hat die AKTIVE Immobilie dazu keine aktive Ruecklage -> finance.note.maintenance_reserve_missing (Angebot).
--   Ohne Flaeche/Baujahr -> [] (z. B. ein Grundstueck; der Agent fragt die Daten im Onboarding ab). Liest die Zeile
--   NACH dem Write (dieselbe Transaktion; Probelauf = Karte).
--   Haupt-Kanal fuer den Hinweis, weil der Advisor-Review nur mit veroeffentlichtem Plan laeuft.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_maintenance_card_lines(p_real_estate_id int)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_re  finance.real_estate%ROWTYPE;
    v_r   JSONB;
    v_out JSONB := '[]'::jsonb;
BEGIN
    SELECT * INTO v_re FROM finance.real_estate WHERE id = p_real_estate_id;
    IF NOT FOUND OR v_re.status IS DISTINCT FROM 'active' THEN
        RETURN v_out;
    END IF;
    v_r := finance.fn_maintenance_reserve_rate(p_real_estate_id);
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_out;
    END IF;
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'note',
        'value', 'finance.note.maintenance_recommendation',
        'params', jsonb_build_object('monthly', core.fn_ui_money((v_r->>'monthly_eur')::numeric),
                                     'rate', core.fn_ui_money((v_r->>'rate_eur_m2')::numeric),
                                     'area', core.fn_ui_num(v_re.living_area_m2, 0),
                                     'age', core.fn_ui_num((v_r->>'age_years')::numeric, 0))));
    IF NOT EXISTS (SELECT 1 FROM finance.savings_goals WHERE real_estate_id = p_real_estate_id AND status = 'active') THEN
        v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'finance.note.maintenance_reserve_missing'));
    END IF;
    RETURN v_out;
END;
$$;
