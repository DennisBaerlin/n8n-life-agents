-- ============================================================
-- fn_insurance_fields (READ HELPER) -- Versicherungs-Rohwerte lesen + pruefen (Import-Haertung 2026-10-22)
--   EINE Adresse fuer fn_create_insurance, fn_set_insurance UND die Karten-Vorschau der Tools (Karte = Write, Post-State-
--   Vertrag): vorher zeigte die Karte "1.200" als 1,20 (JS Number) und speicherte 1200.
--   BEITRAG (WP2 "Finanzen schlank", das LLM rechnet nicht): der Nutzer nennt den Beitrag so, wie er ihn kennt --
--     premium_amount = Betrag JE ABBUCHUNG (die Wahrheit, landet roh an der rp; Rhythmus schedule_unit dann PFLICHT, sonst
--       wuerde "30 monatlich" ohne Einheit still zu 30 im Jahr) ODER
--     annual_premium = Jahresbeitrag (Rhythmus-Default jaehrlich; den Betrag je Abbuchung rechnet fn_insurance_period_amount).
--     Beide genannt -> sie muessen zusammenpassen, sonst {ok:false}. Den Jahreswert leitet fn_annual_equivalent ab (kann bei
--     nicht-jaehrlichem Rhythmus um Cent vom genannten Jahresbeitrag abweichen: die Abbuchung ist die Wahrheit).
--   Geldbetraege wie fn_create_account: JSON-Zahl bleibt Zahl, Text laeuft durch fn_parse_de_numeric (Tausenderpunkt:
--   "50.000" -> 50000). Meldefrist claim_deadline_hours: positive ganze Stundenzahl, Muster-Pruefung VOR dem Cast
--   ("48h"/"12.5"). schedule_unit = Enum (fn_enum_reason), insurance_type = Liste (fn_insurance_type_reason). Leere
--   Felder bleiben NULL (set_*: unveraendert). fn_set_insurance reicht den bisherigen Rhythmus mit, wenn keiner genannt ist.
--   RUECKGABE: {ok:true, premium_amount (je Abbuchung, positiv | NULL = kein Beitrag genannt), annual_premium (abgeleitet),
--   schedule_interval, schedule_unit (wirksam), coverage_amount, claim_deadline_hours} | {ok:false, reason}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_insurance_fields(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_per      NUMERIC;
    v_annual   NUMERIC;
    v_coverage NUMERIC;
    v_deadline INT;
    v_reason   TEXT;
    v_interval SMALLINT;
    v_unit     finance.schedule_unit;
BEGIN
    v_reason := COALESCE(finance.fn_enum_reason('finance.schedule_unit'::regtype, p->>'schedule_unit', 'schedule_unit'),
                         finance.fn_insurance_type_reason(p->>'insurance_type'));
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    BEGIN
        v_per      := CASE WHEN jsonb_typeof(p->'premium_amount') = 'number' THEN (p->>'premium_amount')::numeric
                           ELSE NULLIF(finance.fn_parse_de_numeric(p->>'premium_amount', true), '')::numeric END;
        v_annual   := CASE WHEN jsonb_typeof(p->'annual_premium') = 'number' THEN (p->>'annual_premium')::numeric
                           ELSE NULLIF(finance.fn_parse_de_numeric(p->>'annual_premium', true), '')::numeric END;
        v_coverage := CASE WHEN jsonb_typeof(p->'coverage_amount') = 'number' THEN (p->>'coverage_amount')::numeric
                           ELSE NULLIF(finance.fn_parse_de_numeric(p->>'coverage_amount', true), '')::numeric END;
        v_interval := COALESCE(NULLIF(p->>'schedule_interval', '')::smallint, 1);
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Premium "' || COALESCE(p->>'premium_amount', p->>'annual_premium', '') || '" and coverage "'
                   || COALESCE(p->>'coverage_amount', '') || '" must be amounts in EUR, e.g. 1234.56; the interval a whole number.');
    END;
    v_unit := NULLIF(p->>'schedule_unit', '')::finance.schedule_unit;
    IF v_per IS NOT NULL AND v_unit IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Say how often the premium of ' || v_per || ' is debited (schedule_unit: month, year, ...) - '
                   || 'or give the annual premium instead.');
    END IF;
    IF v_annual IS NOT NULL AND v_unit IS NULL THEN
        v_unit := 'year';
    END IF;
    IF v_annual IS NOT NULL AND v_annual <= 0 OR v_per IS NOT NULL AND v_per <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The premium must be a positive number, got ' || COALESCE(v_per, v_annual) || '.');
    END IF;
    IF v_per IS NOT NULL AND v_annual IS NOT NULL
       AND v_per <> finance.fn_insurance_period_amount(v_annual, v_interval, v_unit) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The amount per debit ' || v_per || ' does not match the annual premium ' || v_annual
                   || ' (' || finance.fn_insurance_period_amount(v_annual, v_interval, v_unit) || ' per debit) - '
                   || 'give only the amount the user actually pays per debit.',
            'premium_amount', v_per, 'annual_premium', v_annual);
    END IF;
    v_per := COALESCE(v_per, finance.fn_insurance_period_amount(v_annual, v_interval, v_unit));
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
    RETURN jsonb_build_object('ok', true,
        'premium_amount', v_per,
        'annual_premium', CASE WHEN v_per IS NOT NULL THEN finance.fn_annual_equivalent(v_per, v_interval, v_unit, 1) END,
        'schedule_interval', v_interval, 'schedule_unit', v_unit,
        'coverage_amount', v_coverage, 'claim_deadline_hours', v_deadline);
END;
$$;
