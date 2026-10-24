-- ============================================================
-- fn_create_insurance (ATOMIC WRITE)
--   Legt recurring_payment (negative monatliche/periodische Praemie) + insurance an und
--   verknuepft sie (recurring_payment_id), beides in EINER Transaktion. Eingabe als jsonb:
--     name, insurance_company, policy_number, policyholder_person_id (Slug, NULL=Haushalt), annual_premium,
--     schedule_interval (-> 1), schedule_unit (-> 'year'), schedule_day_of_month, valid_from, first_payment_date,
--     debit_account_id (im Tool bzw. Import aufgeloest),
--     insurance_type/beneficiary/coverage_amount/claim_deadline_hours (WS-0b estate: optionale Nachlass-
--     Felder, geschlossene insurance_type-Liste per CHECK; leer=NULL)
--   Der Beitrag je Abbuchung wird HIER abgeleitet (fn_insurance_period_amount, immer als Ausgabe negativ);
--   ein mitgeliefertes recurring_amount wird ignoriert (Uebergang: alte Tool-Staende rechneten in n8n).
--   first_payment_date = echtes erstes Abbuchungsdatum (Anker fuer den Faelligkeits-Scheduler;
--   traegt bei jaehrlich/quartalsweise den Monat+Tag). PFLICHT (Owner-Entscheid 2026-10-23, wie Import und Kredit);
--   valid_from faellt auf first_payment_date zurueck, nicht umgekehrt.
--   Praemie/Rate/Versicherungssumme sind EUR nach Modell -> ein Abbuchungskonto in Fremdwaehrung wird
--   abgelehnt (sonst liefe eine EUR-Rate still als Fremdwaehrungs-Betrag).
--   Rohwerte (Praemie/Summe mit Tausenderpunkt, Meldefrist, Rhythmus, insurance_type) liest + prueft
--   fn_insurance_fields — dieselbe fn speist die Karten-Vorschau ("50.000" -> 50000; vorher still 50).
--   RUECKGABE: {ok:true, insurance_id, recurring_payment_id, monthly_equivalent} |
--   {ok:false, reason} (Buchungstag, Rhythmus/insurance_type unbekannt, Praemie <= 0, Betrag unlesbar,
--   Versicherungssumme < 0, Meldefrist keine positive ganze Zahl, Datum fehlt, Konto nicht EUR oder nicht buchbar
--   [Depot/Kredit]) OHNE Write.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_create_insurance(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_rp_id    INT;
    v_ins_id   INT;
    v_monthly  NUMERIC;
    v_interval SMALLINT := COALESCE(NULLIF(p->>'schedule_interval', '')::smallint, 1);
    v_unit     finance.schedule_unit;   -- Cast erst nach dem Enum-Guard (Import-Haertung)
    v_dom      SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_from     DATE := COALESCE(NULLIF(p->>'valid_from', '')::date, NULLIF(p->>'first_payment_date', '')::date);
    v_first    DATE := NULLIF(p->>'first_payment_date', '')::date;   -- Pflicht (kein Rueckfall auf valid_from)
    v_acct     INT := (p->>'debit_account_id')::int;
    v_premium  NUMERIC;
    v_sim      TEXT;
    v_coverage NUMERIC;
    v_deadline INT;
    v_fields   JSONB;
    v_reason   TEXT;
    v_acct_ccy CHAR(3);
BEGIN
    -- Rohwerte lesen + pruefen: EINE Adresse mit fn_set_insurance und der Karten-Vorschau (fn_insurance_fields).
    v_fields := finance.fn_insurance_fields(p);
    IF (v_fields->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_fields;
    END IF;
    v_premium  := (v_fields->>'annual_premium')::numeric;
    v_coverage := (v_fields->>'coverage_amount')::numeric;
    v_deadline := (v_fields->>'claim_deadline_hours')::int;
    v_unit     := COALESCE(NULLIF(p->>'schedule_unit', '')::finance.schedule_unit, 'year');
    -- WP-2b: fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate.
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    -- Korrigierbar: Jahrespraemie muss positiv sein -> {ok:false} (kein RAISE).
    IF v_premium IS NULL OR v_premium <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Annual premium must be a positive number, got ' || COALESCE(v_premium::text, 'null') || '.');
    END IF;
    IF v_first IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The date of the first debit (first_payment_date) is required - ask the user when the premium is first debited (the policy start alone is not enough).');
    END IF;
    SELECT currency INTO v_acct_ccy FROM finance.accounts WHERE id = v_acct;
    IF v_acct_ccy IS NOT NULL AND v_acct_ccy <> 'EUR' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Insurance premiums are kept in EUR, but the debit account is in ' || v_acct_ccy
                   || '. Choose a EUR account for the debit.');
    END IF;
    -- Belastungskonto muss buchbar sein (Depot/Kredit tragen kein Geld; die Faelligkeit bliebe sonst ewig offen).
    v_reason := finance.fn_bookable_account_reason(v_acct);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;

    -- recurring_payment via gemeinsamen Helper (Teil 0: eine Quelle fuer den Insert); Rate aus der EINEN fn.
    v_rp_id := finance.fn_add_recurring_payment(
        v_acct, -finance.fn_insurance_period_amount(v_premium, v_interval, v_unit), 'Versicherung ' || (p->>'name'),
        v_interval, v_unit, v_dom, v_first, finance.fn_recurring_valid_from(v_acct, v_from), NULL, NULL, NULL);

    -- Karten-Hinweis (hohe Schwelle): aktive Versicherung bei derselben Gesellschaft mit exakt gleichem Jahresbeitrag
    SELECT i.name INTO v_sim FROM finance.insurances i
     WHERE i.status = 'active' AND NULLIF(btrim(p->>'insurance_company'), '') IS NOT NULL
       AND lower(btrim(i.insurance_company)) = lower(btrim(p->>'insurance_company')) AND i.annual_premium = v_premium
     ORDER BY i.id LIMIT 1;

    INSERT INTO finance.insurances
        (name, insurance_company, policy_number, policyholder_person_id, annual_premium,
         schedule_interval, schedule_unit, schedule_day_of_month, valid_from,
         account_id, recurring_payment_id, status,
         insurance_type, beneficiary, coverage_amount, claim_deadline_hours)  -- WS-0b: estate-Nachlass-Felder
    VALUES (p->>'name', NULLIF(p->>'insurance_company', ''), NULLIF(p->>'policy_number', ''),
            NULLIF(p->>'policyholder_person_id', ''), v_premium,   -- WS-4: typisierter Versicherungsnehmer (Slug); NULL=Haushalt.
            v_interval, v_unit, v_dom, v_from, v_acct, v_rp_id, 'active',
            NULLIF(p->>'insurance_type', ''), NULLIF(p->>'beneficiary', ''),
            v_coverage, v_deadline)
    RETURNING id, monthly_equivalent INTO v_ins_id, v_monthly;

    RETURN jsonb_build_object(
        'ok', true,
        'insurance_id', v_ins_id,
        'card_lines', finance.fn_similar_note(v_sim),
        'recurring_payment_id', v_rp_id,
        'monthly_equivalent', v_monthly
    );
END;
$$;
