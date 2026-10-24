-- ============================================================
-- fn_insurance_fields (READ HELPER) -- Versicherungs-Rohwerte lesen + pruefen (Import-Haertung 2026-10-22)
--   EINE Adresse fuer fn_create_insurance, fn_set_insurance UND die Karten-Vorschau der Tools (Karte = Write, Post-State-
--   Vertrag): vorher zeigte die Karte "1.200" als 1,20 (JS Number) und speicherte 1200.
--   Geldbetraege (annual_premium, coverage_amount) wie fn_create_account: JSON-Zahl bleibt Zahl, Text laeuft durch
--   fn_parse_de_numeric (Tausenderpunkt: "50.000" -> 50000). Meldefrist claim_deadline_hours: positive ganze Stundenzahl,
--   Muster-Pruefung VOR dem Cast ("48h"/"12.5"). schedule_unit = Enum (fn_enum_reason), insurance_type = Liste
--   (fn_insurance_type_reason). Leere Felder bleiben NULL (set_*: unveraendert). Praemie > 0 prueft der Aufrufer
--   (create: Pflicht; set: optional).
--   RUECKGABE: {ok:true, annual_premium, coverage_amount, claim_deadline_hours} | {ok:false, reason}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_insurance_fields(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_premium  NUMERIC;
    v_coverage NUMERIC;
    v_deadline INT;
    v_reason   TEXT;
BEGIN
    v_reason := COALESCE(finance.fn_enum_reason('finance.schedule_unit'::regtype, p->>'schedule_unit', 'schedule_unit'),
                         finance.fn_insurance_type_reason(p->>'insurance_type'));
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    BEGIN
        v_premium  := CASE WHEN jsonb_typeof(p->'annual_premium') = 'number' THEN (p->>'annual_premium')::numeric
                           ELSE NULLIF(finance.fn_parse_de_numeric(p->>'annual_premium', true), '')::numeric END;
        v_coverage := CASE WHEN jsonb_typeof(p->'coverage_amount') = 'number' THEN (p->>'coverage_amount')::numeric
                           ELSE NULLIF(finance.fn_parse_de_numeric(p->>'coverage_amount', true), '')::numeric END;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Premium "' || COALESCE(p->>'annual_premium', '') || '" and coverage "' || COALESCE(p->>'coverage_amount', '')
                   || '" must be amounts in EUR, e.g. 1234.56.');
    END;
    IF v_coverage IS NOT NULL AND v_coverage < 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Coverage amount must not be negative, got ' || v_coverage || '.');
    END IF;
    IF NULLIF(btrim(p->>'claim_deadline_hours'), '') IS NOT NULL THEN
        IF btrim(p->>'claim_deadline_hours') !~ '^[0-9]{1,6}$' THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Claim deadline must be a whole number of hours, got "' || (p->>'claim_deadline_hours') || '".');
        END IF;
        v_deadline := btrim(p->>'claim_deadline_hours')::int;
        IF v_deadline <= 0 THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'Claim deadline must be at least 1 hour, got ' || v_deadline || '.');
        END IF;
    END IF;
    RETURN jsonb_build_object('ok', true, 'annual_premium', v_premium, 'coverage_amount', v_coverage,
                              'claim_deadline_hours', v_deadline);
END;
$$;
