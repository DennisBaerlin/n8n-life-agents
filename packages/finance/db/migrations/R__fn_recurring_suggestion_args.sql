-- ============================================================
-- fn_recurring_suggestion_args (IMMUTABLE) -- Eingabe der Anlege-fn aus dem Payload einer Vorschlagszeile
--   Die eine Adresse fuer Probelauf (fn_get_recurring_suggestion_queue) und echten Write (fn_handle_recurring_suggestion_cb):
--   beide legen mit genau denselben gespeicherten Werten an. recurring_payment -> fn_create_recurring_payment (inkl.
--   counterparty_iban, creditor_id, mandate_ref als Schluessel fuer den Monats-Check); recurring_transfer ->
--   fn_create_recurring_transfer mit executed_by 'bank': der Uebertrag stand im Auszug, laeuft also schon (sonst legte die
--   Anlage einen Bank-Punkt "bei der Bank einrichten" an). Termine, Kategorie und Anzeige-Namen fallen weg.
--   Eingabe: p_payload (Payload der Vorschlagszeile; 'from_account_id' vorhanden = Uebertrag).
--   Rueckgabe: jsonb (Eingabe der Anlege-fn, NULL-Felder entfernt).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_suggestion_args(p_payload jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_strip_nulls(CASE WHEN p_payload ? 'from_account_id' THEN jsonb_build_object(
               'name', p_payload->>'name', 'from_account_id', p_payload->'from_account_id', 'to_account_id', p_payload->'to_account_id',
               'amount', p_payload->'amount', 'schedule_unit', p_payload->>'schedule_unit',
               'schedule_interval', p_payload->'schedule_interval', 'schedule_day_of_month', p_payload->'schedule_day_of_month',
               'first_payment_date', p_payload->>'first_payment_date', 'executed_by', 'bank')
           ELSE jsonb_build_object(
               'name', p_payload->>'name', 'account_id', p_payload->'account_id', 'direction', p_payload->>'direction',
               'amount', p_payload->'amount', 'schedule_unit', p_payload->>'schedule_unit',
               'schedule_interval', p_payload->'schedule_interval', 'schedule_day_of_month', p_payload->'schedule_day_of_month',
               'first_payment_date', p_payload->>'first_payment_date', 'counterparty_iban', p_payload->>'counterparty_iban',
               'creditor_id', p_payload->>'creditor_id', 'mandate_ref', p_payload->>'mandate_ref') END);
$$;
