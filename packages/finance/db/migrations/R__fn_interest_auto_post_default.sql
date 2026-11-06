-- ============================================================
-- fn_interest_auto_post_default (READ — vorgeschlagenes auto_post aus der Kadenz; DRY-Helfer)
--   Taegliche/woechentliche Verzinsung erzeugt zu viele Vorkommen fuer HITL je Tag -> Default Auto-Buchung;
--   monatlich/jaehrlich bleibt HITL (wir spiegeln eine externe Bank, der Owner verifiziert gegen den Auszug).
--     day / week   -> true   (Auto-Buchung im Cron, kein Gate)
--     month / year -> false  (HITL je Vorkommen)
--   Pro Konto ueberschreibbar. EINE Adresse fuer den Default -> fn_create_account UND fn_set_account_interest.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_interest_auto_post_default(p_unit finance.schedule_unit)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_unit IN ('day', 'week');
$$;
