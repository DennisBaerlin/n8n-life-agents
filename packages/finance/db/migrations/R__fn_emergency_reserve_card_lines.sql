-- ============================================================
-- fn_emergency_reserve_card_lines (READ, STABLE) -- Karten-Hinweise zur Notreserve aus fn_emergency_reserve_status
--   Fuer die HITL-Karten von tool_create_savings_goal / tool_set_savings_goal (card_lines, typisierte Notes; die Karte
--   rendert sie in der Sprache des Empfaengers): Ziel (bei Monaten mit Monatsbasis: feste Zahlungen + geschaetzter
--   Alltag) und bisher gedeckt. Keine eigene Rechnung — nur Darstellung des Status-jsonb.
--   RUECKGABE: jsonb-Array von {kind:'note', value:<key>, params}; ohne Notreserve leer.
--   Tests: tests/db/finance/test_fn_emergency_reserve_status.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_emergency_reserve_card_lines(p_status jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN COALESCE((p_status->>'exists')::boolean, false) IS NOT TRUE THEN '[]'::jsonb
        ELSE jsonb_build_array(
            CASE WHEN p_status->>'target_kind' = 'months' AND p_status->'target_eur' <> 'null'::jsonb
                 THEN jsonb_build_object('kind', 'note', 'value', 'finance.note.emergency_target_months',
                          'params', jsonb_build_object(
                              'months', core.fn_ui_num((p_status->>'months')::numeric, 1),
                              'monthly', core.fn_ui_money((p_status->'basis'->>'monthly_eur')::numeric),
                              'fixed', core.fn_ui_money((p_status->'basis'->>'fixed_eur')::numeric),
                              'everyday', core.fn_ui_money((p_status->'basis'->>'everyday_eur')::numeric),
                              'target', core.fn_ui_money((p_status->>'target_eur')::numeric)))
                 WHEN p_status->>'target_kind' = 'months'
                 THEN jsonb_build_object('kind', 'note', 'value', 'finance.note.emergency_target_unknown',
                          'params', jsonb_build_object('months', core.fn_ui_num((p_status->>'months')::numeric, 1)))
                 ELSE jsonb_build_object('kind', 'note', 'value', 'finance.note.emergency_target_amount',
                          'params', jsonb_build_object('target', core.fn_ui_money((p_status->>'target_eur')::numeric))) END,
            jsonb_build_object('kind', 'note', 'value', 'finance.note.emergency_covered',
                'params', jsonb_build_object('covered', core.fn_ui_money((p_status->>'covered_eur')::numeric)))) END;
$$;
