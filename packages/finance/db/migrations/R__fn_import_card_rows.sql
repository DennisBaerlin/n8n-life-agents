-- ============================================================
-- fn_import_card_rows (READ, STABLE) -- die Zeilen der Import-Bestaetigungskarte (tool_commit_import)
--   Je VALIDER Staging-Zeile (row_no-Reihenfolge) {row_no, entity_type, name, p, x}: p = roher Payload, x = die
--   abgeleiteten Werte, die das Einzel-Tool vor seiner Karte aus DENSELBEN fn_* holt (Post-State-Vertrag):
--     person          Name der Person (fn_import_person_field + core.fn_resolve_person; NULL = Haushalt)
--     ccy             Zeilen-Waehrung: Konto/Dauerauftrag = fn_import_ref_currency, Depot-Position = quote_currency
--                     (fn_normalize_currency, wie fn_book_stock_buy) sonst die des Depots, Rest EUR nach Modell
--     interest        Konto: fn_account_interest_defaults (= was fn_create_account schreibt)
--     settlement      Depot-Position: Verrechnungskonto (Batch-Depot-Zeile oder Bestandsdepot)
--     settlement_ref  Konto mit Verrechnungskonto / Depot-Position: dessen Herkunft (fn_import_ref_account):
--                     'db' = besteht schon, 'batch' = wird in diesem Import mit angelegt, NULL = keins
--     transaction_date Depot-Position: genannt, sonst heute (Default von fn_import_bundle)
--     symbol          Depot-Position: Kennung wie fn_book_stock_buy (fn_holding_symbol: Ticker, sonst ISIN)
--     depot_number_to_store Depot-Position: gedruckte Depotnummer, die der Commit am Depot nachtraegt
--                     (fn_import_depot_number_to_store, dieselbe Bedingung wie fn_import_bundle), sonst NULL
--     period_amount   Versicherung: Rate je Abbuchung (fn_insurance_period_amount, wie fn_create_insurance)
--     schedule        Sparziel: fn_savings_rate_schedule (wie fn_create_savings_goal)
--     is_nominal      Standmitteilung: genannt, sonst ja (Default von fn_import_bundle)
--     running         Kredit: laufend (Restschuld zum Stichtag heute) wie fn_create_loan, sonst frisch
--     rate_split      Kredit mit Rate: {interest, principal} der 1. Rate aus der Restschuld (fn_loan_monthly_interest,
--                     wie fn_create_loan first_rate_interest/_principal)
--   name = Anzeige-Name der Zeile (name, sonst symbol, sonst die referenzierte Rente).
--   RUECKGABE jsonb-Array (leer = '[]', nie NULL -> der Pg-Knoten liefert immer genau ein Item).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_card_rows(p_batch_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_out    JSONB := '[]'::jsonb;
    v_row    RECORD;
    v_p      JSONB;
    v_x      JSONB;
    v_field  TEXT;
    v_person TEXT;
    v_settle TEXT;
BEGIN
    FOR v_row IN
        SELECT s.row_no, s.entity_type, s.payload FROM finance.import_staging s
        WHERE s.batch_id = p_batch_id AND s.status = 'valid' ORDER BY s.row_no
    LOOP
        v_p := v_row.payload;
        v_person := NULL;
        v_field := finance.fn_import_person_field(v_row.entity_type);
        IF v_field IS NOT NULL AND NULLIF(trim(COALESCE(v_p->>v_field, '')), '') IS NOT NULL THEN
            SELECT r.full_name INTO v_person FROM core.fn_resolve_person(trim(v_p->>v_field)) r WHERE r.hit_count = 1;
        END IF;
        v_x := jsonb_build_object('person', v_person, 'ccy', 'EUR');

        IF v_row.entity_type = 'account' THEN
            v_x := v_x || jsonb_build_object(
                'ccy', finance.fn_import_ref_currency(p_batch_id, v_p->>'name'),
                'interest', finance.fn_account_interest_defaults(v_p));
            IF NULLIF(trim(COALESCE(v_p->>'settlement_account', '')), '') IS NOT NULL THEN
                v_x := v_x || jsonb_build_object('settlement_ref',
                    finance.fn_import_ref_account(p_batch_id, trim(v_p->>'settlement_account')));
            END IF;
        ELSIF v_row.entity_type = 'recurring_payment' THEN
            v_x := v_x || jsonb_build_object('ccy', finance.fn_import_ref_currency(p_batch_id, v_p->>'account'));
        ELSIF v_row.entity_type = 'stock_buy' THEN
            SELECT s.payload->>'settlement_account' INTO v_settle FROM finance.import_staging s
            WHERE s.batch_id = p_batch_id AND s.entity_type = 'account' AND s.status <> 'committed'
              AND lower(s.payload->>'name') = lower(v_p->>'depot')
            LIMIT 1;
            IF v_settle IS NULL THEN
                SELECT st.name INTO v_settle FROM finance.accounts d JOIN finance.accounts st ON st.id = d.settlement_account_id
                WHERE lower(d.name) = lower(v_p->>'depot') AND d.status = 'active'
                LIMIT 1;
            END IF;
            v_x := v_x || jsonb_build_object(
                'ccy', COALESCE(finance.fn_normalize_currency(NULLIF(v_p->>'quote_currency', '')),
                                finance.fn_import_ref_currency(p_batch_id, v_p->>'depot')),
                'symbol', finance.fn_holding_symbol(v_p->>'symbol', v_p->>'isin'),
                'depot_number_to_store', finance.fn_import_depot_number_to_store(p_batch_id, v_p),
                'settlement', v_settle,
                'settlement_ref', CASE WHEN v_settle IS NOT NULL THEN finance.fn_import_ref_account(p_batch_id, v_settle) END,
                'transaction_date', COALESCE(NULLIF(v_p->>'transaction_date', ''), to_char(CURRENT_DATE, 'YYYY-MM-DD')));
        ELSIF v_row.entity_type = 'insurance' THEN
            -- dieselbe Pruef-/Ableitungs-fn wie fn_create_insurance (WP2): Betrag je Abbuchung roh oder aus dem
            -- Jahresbeitrag, Jahreswert abgeleitet
            v_x := v_x || (SELECT jsonb_build_object('period_amount', f->'premium_amount', 'annual_premium', f->'annual_premium')
                           FROM finance.fn_insurance_fields(v_p) f);
        ELSIF v_row.entity_type = 'savings_goal' THEN
            v_x := v_x || jsonb_build_object('schedule', finance.fn_savings_rate_schedule(v_p));
            -- Keine Person genannt -> Inhaber des Spartopfs, wie fn_create_savings_goal beim Write
            -- (fn_default_beneficiary): batch-interner Topf (dessen owner_person) vor bestehendem Konto.
            IF v_person IS NULL AND NULLIF(trim(COALESCE(v_p->>'reserve_account', '')), '') IS NOT NULL THEN
                SELECT r.full_name INTO v_person
                FROM finance.import_staging s,
                     core.fn_resolve_person(NULLIF(trim(COALESCE(s.payload->>'owner_person', '')), '')) r
                WHERE s.batch_id = p_batch_id AND s.entity_type = 'account' AND s.status <> 'committed'
                  AND lower(s.payload->>'name') = lower(trim(v_p->>'reserve_account')) AND r.hit_count = 1
                LIMIT 1;
                IF v_person IS NULL THEN
                    -- bestehendes Konto: derselbe Resolver wie der Import (eindeutiger Treffer) + fn_default_beneficiary
                    SELECT hp.full_name INTO v_person
                    FROM finance.fn_resolve_account(trim(v_p->>'reserve_account'), NULL) r
                    JOIN core.fn_household_persons() hp ON hp.person_id = finance.fn_default_beneficiary(NULL, r.id)
                    WHERE r.hit_count = 1;
                END IF;
                v_x := v_x || jsonb_build_object('person', v_person);
            END IF;
        ELSIF v_row.entity_type = 'pension_statement' THEN
            v_x := v_x || jsonb_build_object('is_nominal', COALESCE(NULLIF(v_p->>'is_nominal', '')::boolean, TRUE));
        ELSIF v_row.entity_type = 'loan' THEN
            -- dieselbe Regel wie fn_create_loan: laufend = Restschuld genannt und (kein Betrag oder kleiner)
            v_x := v_x || jsonb_build_object('running',
                NULLIF(v_p->>'current_balance', '') IS NOT NULL
                AND (NULLIF(v_p->>'original_amount', '') IS NULL
                     OR (v_p->>'current_balance')::numeric < (v_p->>'original_amount')::numeric));
            IF NULLIF(v_p->>'monthly_annuity', '') IS NOT NULL THEN
                -- dieselbe Formel wie fn_create_loan (first_rate_interest/_principal): Zins aus der Restschuld
                v_x := v_x || jsonb_build_object('rate_split', (
                    SELECT jsonb_build_object('interest', i, 'principal', (v_p->>'monthly_annuity')::numeric - i)
                    FROM finance.fn_loan_monthly_interest(
                             COALESCE(NULLIF(v_p->>'current_balance', ''), v_p->>'original_amount')::numeric,
                             NULLIF(v_p->>'interest_rate', '')::numeric) AS i));
            END IF;
        END IF;

        v_out := v_out || jsonb_build_array(jsonb_build_object(
            'row_no', v_row.row_no, 'entity_type', v_row.entity_type,
            'name', COALESCE(v_p->>'name', finance.fn_holding_symbol(v_p->>'symbol', v_p->>'isin'), v_p->>'pension', '?'),
            'p', v_p, 'x', v_x));
    END LOOP;
    RETURN v_out;
END;
$$;
