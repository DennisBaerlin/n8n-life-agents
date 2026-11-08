-- tests/db/finance/pending_recalc_findings.sql
-- PENDING: Abweichungen der Zweitrechnung, bewusst ROT und ausserhalb des Gates (db_test sammelt nur test_*.sql).
-- Lauf von Hand: .\scripts\db_test.ps1 -Filter 'pending_recalc_*'
-- Jeder Fall nennt die unabhaengige Erwartung; die fn bleibt unveraendert, bis der Owner entschieden bzw. jemand den
-- Fix gebaut hat. Nach dem Fix den Fall in die passende test_recalc_*.sql verschieben (dann gruen und im Gate).
--   (P2) Sparrate zaehlt Kalendermonate statt Raten-Termine (fachliche Auslegung offen, Entscheidungskarte):
--        fn_savings_rate_schedule teilt den Rest durch (Zielmonat - Monat der ersten Rate). Liegt der Zieltag auf
--        oder nach dem Abbuchungstag, faellt im Zielmonat noch eine Rate an, die nicht zaehlt.
--        Ziel 12.000, gespart 2.000, erste Rate 15.02.2027, Ziel 31.08.2028: Raten 15.02.2027 .. 15.08.2028 = 19
--        -> 10.000 / 19 = 526,315... -> 526,32. DB: 18 Monate -> 555,56 (5,6 % zu hoch; bei 3 Monaten bis 33 %).
--        Vorschlag: Anzahl = Termine von fn_schedule_occurrences(first, 1, month, Tag, NULL, first, target) (dasselbe
--        Raster wie der Scheduler); die Raten-getriebene Richtung bleibt (Zieldatum = Tag nach der letzten noetigen
--        Rate oder wie heute ein Monat danach, je nach Entscheidung).

-- eigene Transaktion je Fall: ein roter P1 bricht P2 sonst ab
BEGIN;
DO $$
DECLARE
  v jsonb;
BEGIN
  v := finance.fn_savings_rate_schedule('{"target_amount":12000,"already_saved":2000,"first_payment_date":"2027-02-15","target_date":"2028-08-31"}');
  IF (v->>'months')::int IS DISTINCT FROM 19 OR (v->>'monthly_rate')::numeric IS DISTINCT FROM 526.32 THEN
    RAISE EXCEPTION 'FAIL [P2] Sparrate: erwartet 19 Raten / 526.32, got %', v; END IF;
END $$;

ROLLBACK;
