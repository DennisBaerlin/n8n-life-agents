-- ============================================================
-- fn_create_insurance (ATOMIC WRITE)
--   Legt die Beitrags-Kette (recurring_payment, negativer Betrag JE ABBUCHUNG) + insurance an und verknuepft sie
--   (recurring_payment_id), beides in EINER Transaktion. Eingabe als jsonb:
--     name, insurance_company, policy_number, policyholder_person_id (Slug, NULL=Haushalt),
--     premium_amount (Betrag je Abbuchung; dann schedule_unit Pflicht) ODER annual_premium (Jahresbeitrag; Rhythmus-Default
--     jaehrlich), schedule_interval (-> 1), schedule_unit, schedule_day_of_month, valid_from (Vertragsbeginn),
--     first_payment_date, debit_account_id (im Tool bzw. Import aufgeloest),
--     insurance_type/beneficiary/coverage_amount/claim_deadline_hours (WS-0b estate: optionale Nachlass-
--     Felder, geschlossene insurance_type-Liste per CHECK; leer=NULL)
--   EINE QUELLE (WP2 "Finanzen schlank", finance:V027): Beitrag, Rhythmus, Tag, Vertragsende und Konto stehen nur an der
--   Beitrags-Kette; die Police traegt keine Kopie. Rohwerte liest + prueft fn_insurance_fields (dieselbe fn speist die
--   Karten-Vorschau); den Jahres-/Monatswert leitet active_insurances ab -- das LLM rechnet nie um.
--   OHNE BEITRAG (keiner genannt): beitragsfreie Police ohne Beitrags-Kette (z. B. fuers Nachlass-Register); dann sind
--   Abbuchungskonto und erste Abbuchung nicht noetig.
--   first_payment_date = echtes erstes Abbuchungsdatum (Anker fuer den Faelligkeits-Scheduler; traegt bei
--   jaehrlich/quartalsweise den Monat+Tag). PFLICHT mit Beitrag (Owner-Entscheid 2026-10-23, wie Import und Kredit);
--   valid_from faellt auf first_payment_date (ohne Beitrag: heute) zurueck, nicht umgekehrt.
--   Beitrag/Versicherungssumme sind EUR nach Modell -> ein Abbuchungskonto in Fremdwaehrung wird abgelehnt (sonst liefe
--   eine EUR-Rate still als Fremdwaehrungs-Betrag).
--   RUECKGABE: {ok:true, insurance_id, recurring_payment_id, premium_amount, annual_premium, monthly_equivalent (positiv,
--   aus der Beitrags-Zeile), card_lines} | {ok:false, reason} (Buchungstag, Rhythmus/insurance_type unbekannt, Beitrag <= 0
--   oder unstimmig, Betrag unlesbar, Beitrag ohne Rhythmus, Versicherungssumme < 0, Meldefrist keine positive ganze Zahl,
--   erste Abbuchung fehlt, Konto nicht EUR oder nicht buchbar [Depot/Kredit]) OHNE Write.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_create_insurance(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_rp_id    INT;
    v_ins_id   INT;
    v_dom      SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_first    DATE := NULLIF(p->>'first_payment_date', '')::date;   -- Pflicht mit Beitrag (kein Rueckfall auf valid_from)
    v_from     DATE;
    v_acct     INT := NULLIF(p->>'debit_account_id', '')::int;
    v_per      NUMERIC;
    v_annual   NUMERIC;
    v_interval SMALLINT;
    v_unit     finance.schedule_unit;
    v_sim      TEXT;
    v_fields   JSONB;
    v_reason   TEXT;
    v_acct_ccy CHAR(3);
BEGIN
    -- Rohwerte lesen + pruefen: EINE Adresse mit fn_set_insurance und der Karten-Vorschau (fn_insurance_fields).
    v_fields := finance.fn_insurance_fields(p);
    IF (v_fields->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_fields;
    END IF;
    v_per      := (v_fields->>'premium_amount')::numeric;
    v_annual   := (v_fields->>'annual_premium')::numeric;
    v_interval := (v_fields->>'schedule_interval')::smallint;
    v_unit     := (v_fields->>'schedule_unit')::finance.schedule_unit;
    -- WP-2b: fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate.
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    v_from := COALESCE(NULLIF(p->>'valid_from', '')::date, v_first, core.fn_today());

    IF v_per IS NOT NULL THEN
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

        -- Beitrags-Kette via gemeinsamen Helper (Teil 0: eine Quelle fuer den Insert); Betrag je Abbuchung roh.
        v_rp_id := finance.fn_add_recurring_payment(
            v_acct, -v_per, left('Versicherung ' || (p->>'name'), 100),
            v_interval, v_unit, v_dom, v_first, finance.fn_recurring_valid_from(v_acct, v_from), NULL, NULL, NULL);
    END IF;

    -- Karten-Hinweis (hohe Schwelle): aktive Versicherung bei derselben Gesellschaft mit gleichem Jahresbeitrag
    SELECT i.name INTO v_sim FROM finance.active_insurances i
     WHERE NULLIF(btrim(p->>'insurance_company'), '') IS NOT NULL
       AND lower(btrim(i.insurance_company)) = lower(btrim(p->>'insurance_company'))
       AND i.annual_premium IS NOT DISTINCT FROM v_annual
     ORDER BY i.id LIMIT 1;

    INSERT INTO finance.insurances
        (name, insurance_company, policy_number, policyholder_person_id, valid_from, recurring_payment_id, status,
         insurance_type, beneficiary, coverage_amount, claim_deadline_hours)  -- WS-0b: estate-Nachlass-Felder
    VALUES (p->>'name', NULLIF(p->>'insurance_company', ''), NULLIF(p->>'policy_number', ''),
            NULLIF(p->>'policyholder_person_id', ''),   -- WS-4: typisierter Versicherungsnehmer (Slug); NULL=Haushalt.
            v_from, v_rp_id, 'active',
            NULLIF(p->>'insurance_type', ''), NULLIF(p->>'beneficiary', ''),
            (v_fields->>'coverage_amount')::numeric, (v_fields->>'claim_deadline_hours')::int)
    RETURNING id INTO v_ins_id;

    RETURN jsonb_build_object(
        'ok', true,
        'insurance_id', v_ins_id,
        'card_lines', finance.fn_similar_note(v_sim),
        'recurring_payment_id', v_rp_id,
        'premium_amount', v_per,
        'annual_premium', v_annual,
        'monthly_equivalent', (SELECT -monthly_equivalent FROM finance.recurring_payments WHERE id = v_rp_id)
    );
END;
$$;
