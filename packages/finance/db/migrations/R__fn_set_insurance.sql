-- ============================================================
-- fn_set_insurance (ATOMIC WRITE)
--   Aendert eine bestehende Versicherung (Beitrag/Rhythmus/Kuendigung/Police). Partielles Update (leer = unveraendert;
--   Leeren geht nicht).
--   EINE QUELLE (WP2 "Finanzen schlank", finance:V027): Beitrag je Abbuchung, Rhythmus, Tag, Vertragsende und Konto
--   stehen nur an der Beitrags-Kette.
--     - Beitrag (premium_amount je Abbuchung ODER annual_premium; fn_insurance_fields, bisheriger Rhythmus als Default),
--       Rhythmus oder Tag geaendert -> fn_change_owned_recurring: Korrektur direkt nach der Anlage in place, sonst neues
--       Glied ab effective_from (Default: naechster noch nicht erledigter Termin) -- der alte Beitrag bleibt Historie.
--       Ein neuer Rhythmus OHNE neuen Betrag -> {ok:false} (Versicherer berechnen Ratenzuschlaege; das LLM rechnet nicht um).
--     - valid_to kommt als LETZTER Vertragstag (inklusiv) und wird als exklusives Ende (Folgetag) an der Kette gespeichert
--       (Kopf = Vertragsende; fruehere Glieder werden nur gekuerzt).
--     - status in ('cancelled','expired') -> Kette endet zum Kuendigungsdatum (Fallback bisheriges Ende / heute); 'paused'
--       NUR, wenn dieses Datum erreicht ist -- eine Kuendigung zum kuenftigen Vertragsende laesst die Beitraege bis dahin
--       laufen. status='active' -> noch laufende Glieder wieder 'active'.
--     - Umbenennung fuehrt 'Versicherung <Name>' an allen Gliedern mit (fn_rename_owned_recurring).
--   Eingabe jsonb: insurance_id (im n8n via fn_resolve_insurance aufgeloest), name, insurance_company, policy_number,
--   policyholder_person_id (Slug; leer=unveraendert), premium_amount, annual_premium, schedule_interval, schedule_unit,
--   schedule_day_of_month, effective_from, valid_to, status, notes, insurance_type/beneficiary/coverage_amount/
--   claim_deadline_hours (WS-0b estate: partielles Update der Nachlass-Felder; leer=unveraendert).
--   RUECKGABE: {ok:true, insurance_id, recurring_payment_id (Kopf), split/previous_id/effective_from (nur bei
--   Beitragsaenderung), premium_amount + annual_premium (wirksam ab dem Stichtag, nur bei Beitragsaenderung)}.
--   Korrigierbar (Beitrag <= 0/unstimmig/unlesbar, Rhythmus ohne Betrag, Beitrag an einer beitragsfreien Police,
--   status/schedule_unit/insurance_type unbekannt, coverage_amount<0, Meldefrist ungueltig, Ende vor Vertragsbeginn,
--   Split-Guards) -> {ok:false}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_insurance(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id       INT     := (p->>'insurance_id')::int;
    v_ins      finance.insurances%ROWTYPE;
    v_cur      finance.recurring_payments%ROWTYPE;
    v_head     INT;
    v_fields   JSONB;
    v_reason   TEXT;
    v_status   finance.insurance_status;   -- Casts erst nach dem Enum-Guard (Import-Haertung)
    v_valid_to DATE    := NULLIF(p->>'valid_to', '')::date;
    v_interval SMALLINT := NULLIF(p->>'schedule_interval', '')::smallint;
    v_unit     finance.schedule_unit;
    v_dom      SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_per      NUMERIC;
    v_end      DATE;
    v_today    DATE    := core.fn_today();
    v_chg      JSONB   := '{}'::jsonb;
BEGIN
    v_reason := COALESCE(finance.fn_enum_reason('finance.insurance_status'::regtype, p->>'status', 'status'),
                         finance.fn_enum_reason('finance.schedule_unit'::regtype, p->>'schedule_unit', 'schedule_unit'));
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    v_status := NULLIF(p->>'status', '')::finance.insurance_status;
    v_unit   := NULLIF(p->>'schedule_unit', '')::finance.schedule_unit;
    -- WP-2b: fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate.
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    SELECT * INTO v_ins FROM finance.insurances WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Insurance % not found.', v_id;
    END IF;
    v_head := finance.fn_recurring_lineage_head(v_ins.recurring_payment_id);
    SELECT * INTO v_cur FROM finance.recurring_payments
     WHERE id = finance.fn_recurring_current(v_ins.recurring_payment_id, v_today);

    -- Rohwerte lesen + pruefen: EINE Adresse mit fn_create_insurance und der Karten-Vorschau; ohne neuen Rhythmus gilt
    -- der bisherige (ein reiner Beitrag "jetzt 15" ist je Abbuchung im bisherigen Rhythmus gemeint).
    v_fields := finance.fn_insurance_fields(p || jsonb_strip_nulls(jsonb_build_object(
                    'schedule_interval', COALESCE(v_interval, v_cur.schedule_interval),
                    'schedule_unit',     COALESCE(v_unit, v_cur.schedule_unit))));
    IF (v_fields->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_fields;
    END IF;
    v_per := (v_fields->>'premium_amount')::numeric;
    IF v_per IS NULL AND ((v_interval IS NOT NULL AND v_interval IS DISTINCT FROM v_cur.schedule_interval)
                          OR (v_unit IS NOT NULL AND v_unit IS DISTINCT FROM v_cur.schedule_unit)) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A new payment rhythm usually changes the amount per debit - ask the user for the new amount per debit '
                   || '(premium_amount) or the annual premium.');
    END IF;
    IF v_head IS NULL AND (v_per IS NOT NULL OR v_dom IS NOT NULL) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This policy has no premium debit recorded - a premium can only be changed on a policy that has one.');
    END IF;

    -- Korrigierbar: Kuendigungs-/Enddatum darf nicht vor dem Vertragsbeginn liegen.
    IF v_valid_to IS NOT NULL AND v_valid_to < v_ins.valid_from THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'valid_to (' || v_valid_to || ') must not be before the policy start valid_from (' || v_ins.valid_from || ').',
            'valid_from', v_ins.valid_from);
    END IF;
    -- Eingabe = LETZTER Vertragstag (inklusiv, wie vom Nutzer genannt); gespeichert wird das exklusive Ende
    -- (Konvention [valid_from, valid_to) aller Views/close_*/Split) — die fn rechnet um, nicht das LLM.
    v_valid_to := v_valid_to + 1;

    -- Beitrag / Rhythmus / Tag ueber die Kette (Historie); unveraenderter Beitrag im selben Rhythmus = keine Aenderung
    IF v_per = abs(v_cur.amount) AND (v_fields->>'schedule_interval')::smallint = v_cur.schedule_interval
       AND (v_fields->>'schedule_unit')::finance.schedule_unit = v_cur.schedule_unit THEN
        v_per := NULL;
    END IF;
    IF v_head IS NOT NULL AND (v_per IS NOT NULL OR v_dom IS NOT NULL) THEN
        v_chg := finance.fn_change_owned_recurring(v_head, NULLIF(p->>'effective_from', '')::date, -v_per,
                     CASE WHEN v_per IS NOT NULL THEN (v_fields->>'schedule_interval')::smallint END,
                     CASE WHEN v_per IS NOT NULL THEN (v_fields->>'schedule_unit')::finance.schedule_unit END, v_dom);
        IF (v_chg->>'ok')::boolean IS DISTINCT FROM true THEN
            RETURN v_chg;
        END IF;
        v_head := (v_chg->>'recurring_payment_id')::int;
    END IF;

    UPDATE finance.insurances SET
        name                  = COALESCE(NULLIF(p->>'name', ''), name),
        insurance_company     = COALESCE(NULLIF(p->>'insurance_company', ''), insurance_company),
        policy_number         = COALESCE(NULLIF(p->>'policy_number', ''), policy_number),
        policyholder_person_id = COALESCE(NULLIF(p->>'policyholder_person_id', ''), policyholder_person_id),  -- WS-4: typisierter Versicherungsnehmer (Slug); leer=unveraendert
        status                = COALESCE(v_status, status),
        notes                 = COALESCE(NULLIF(p->>'notes', ''), notes),
        -- WS-0b (estate): partielles Update der Nachlass-Felder (leer=unveraendert; type-CHECK = Backstop).
        insurance_type        = COALESCE(NULLIF(p->>'insurance_type', ''), insurance_type),
        beneficiary           = COALESCE(NULLIF(p->>'beneficiary', ''), beneficiary),
        coverage_amount       = COALESCE((v_fields->>'coverage_amount')::numeric, coverage_amount),
        claim_deadline_hours  = COALESCE((v_fields->>'claim_deadline_hours')::int, claim_deadline_hours)
    WHERE id = v_id;

    IF v_head IS NOT NULL THEN
        PERFORM finance.fn_rename_owned_recurring(v_head, 'Versicherung', v_ins.name, NULLIF(p->>'name', ''));

        -- Vertragsende an der Kette: der Kopf traegt es (auch Verlaengerung), fruehere Glieder werden nur gekuerzt.
        v_end := CASE WHEN v_status IN ('cancelled', 'expired')
                      THEN COALESCE(v_valid_to, (SELECT valid_to FROM finance.recurring_payments WHERE id = v_head), v_today)
                      ELSE v_valid_to END;
        -- Deaktivierungs-Kaskade: Kuendigung/Ablauf -> Beitrag verlaesst den Cashflow ab dem Enddatum (paused erst, wenn
        -- es erreicht ist).
        IF v_end IS NOT NULL THEN
            UPDATE finance.recurring_payments
               SET valid_to = GREATEST(valid_from, v_end),
                   status   = CASE WHEN v_status IN ('cancelled', 'expired') AND v_end <= v_today
                                   THEN 'paused'::finance.payment_status ELSE status END
             WHERE id IN (SELECT finance.fn_recurring_lineage(v_head))
               AND (id = v_head OR valid_to IS NULL OR valid_to > v_end);
        END IF;
        IF v_status = 'active' THEN
            UPDATE finance.recurring_payments SET status = 'active'
             WHERE id IN (SELECT finance.fn_recurring_lineage(v_head))
               AND (valid_to IS NULL OR valid_to > v_today);
        END IF;
    END IF;

    RETURN jsonb_build_object('ok', true, 'insurance_id', v_id, 'recurring_payment_id', v_head)
        || jsonb_strip_nulls(jsonb_build_object(
               'split', v_chg->'split', 'previous_id', v_chg->'previous_id', 'effective_from', v_chg->'effective_from',
               'premium_amount', v_per, 'annual_premium', CASE WHEN v_per IS NOT NULL THEN v_fields->'annual_premium' END));
END;
$$;
