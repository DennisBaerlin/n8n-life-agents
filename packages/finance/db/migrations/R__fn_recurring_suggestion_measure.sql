-- ============================================================
-- fn_recurring_suggestion_measure (READ, STABLE) -- eine Vorschlagszeile des Stapels aus ihren Terminen neu messen
--   Sicherheit (sure|confirm) und Rhythmus werden nicht gespeichert, sondern aus payload.occurrences abgeleitet: dieselbe
--   Regel wie beim Erkennen (fn_get_recurring_candidates mode statement, die Reihe als eine series). NULL = keine
--   Reihe mehr (zum Beispiel inzwischen als Dauerauftrag angelegt: der Bekannt-Filter greift).
--   Eingabe: payload einer Vorschlagszeile {account_id, name, series, recurring_kind, rhythm_hint, counterparty_iban,
--   creditor_id, mandate_ref, occurrences:[{date, amount (mit Vorzeichen), period_end?}]}.
--   RUECKGABE: ein Vorschlag wie fn_get_recurring_candidates (u. a. confidence, rhythm_assumed, schedule_*,
--   first_payment_date, amount) | NULL.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_suggestion_measure(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_res JSONB;
BEGIN
    IF jsonb_typeof(p_payload->'occurrences') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'occurrences') = 0 THEN
        RETURN NULL;
    END IF;
    v_res := finance.fn_get_recurring_candidates(jsonb_build_object(
        'account_id', p_payload->'account_id', 'mode', 'statement',
        'period_last', (SELECT max(GREATEST((o->>'date')::date, NULLIF(o->>'period_end', '')::date))
                        FROM jsonb_array_elements(p_payload->'occurrences') o),
        'lines', (SELECT jsonb_agg(jsonb_build_object('date', o->>'date', 'amount', o->'amount',
                      'counterparty', p_payload->>'name', 'counterparty_iban', p_payload->>'counterparty_iban',
                      'creditor_id', p_payload->>'creditor_id', 'mandate_ref', p_payload->>'mandate_ref',
                      'purpose', o->>'date', 'recurring_kind', COALESCE(p_payload->>'recurring_kind', 'standing_order'),
                      'series', COALESCE(p_payload->>'series', p_payload->>'name'), 'rhythm_hint', p_payload->>'rhythm_hint'))
                  FROM jsonb_array_elements(p_payload->'occurrences') o)));
    RETURN v_res->'suggestions'->0;
END;
$$;
