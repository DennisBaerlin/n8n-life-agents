-- tests/db/finance/pending_recalc_findings.sql
-- PENDING: Abweichungen der Zweitrechnung, bewusst ROT und ausserhalb des Gates (db_test sammelt nur test_*.sql).
-- Lauf von Hand: .\scripts\db_test.ps1 -Filter 'pending_recalc_*'
-- Jeder Fall nennt die unabhaengige Erwartung; die fn bleibt unveraendert, bis der Owner entschieden bzw. jemand den
-- Fix gebaut hat. Nach dem Fix den Fall in die passende test_recalc_*.sql verschieben (dann gruen und im Gate).
--   (P1) Alltagswert doppelt gerundet (DB rechnet ungenau, kleine Wirkung): fn_account_everyday_per_day rundet den
--        Tageswert auf Cent, R__v_account_everyday_spending multipliziert den GERUNDETEN Tageswert mit 30,4375.
--        92 Tage, Abgaenge -1.000,49: exakt -1.000,49 / 92 x 30,4375 = -331,004 -> -331,00; DB -10,87 x 30,4375
--        = -330,86. Fehler bis 0,005 x 30,4375 = 0,15 EUR je Konto und Monat. Fix: Monatswert aus dem ungerundeten
--        Tageswert (z. B. zusaetzliche Spalte per_day_exact; Rueckgabetyp-Aenderung braucht eine V-Migration, siehe
--        Kopf von R__fn_account_everyday_per_day.sql).
--   (P2) Sparrate zaehlt Kalendermonate statt Raten-Termine (fachliche Auslegung offen, Entscheidungskarte):
--        fn_savings_rate_schedule teilt den Rest durch (Zielmonat - Monat der ersten Rate). Liegt der Zieltag auf
--        oder nach dem Abbuchungstag, faellt im Zielmonat noch eine Rate an, die nicht zaehlt.
--        Ziel 12.000, gespart 2.000, erste Rate 15.02.2027, Ziel 31.08.2028: Raten 15.02.2027 .. 15.08.2028 = 19
--        -> 10.000 / 19 = 526,315... -> 526,32. DB: 18 Monate -> 555,56 (5,6 % zu hoch; bei 3 Monaten bis 33 %).
--        Vorschlag: Anzahl = Termine von fn_schedule_occurrences(first, 1, month, Tag, NULL, first, target) (dasselbe
--        Raster wie der Scheduler); die Raten-getriebene Richtung bleibt (Zieldatum = Tag nach der letzten noetigen
--        Rate oder wie heute ein Monat danach, je nach Entscheidung).
BEGIN;

DO $$
DECLARE
  t date := current_date;
  v_a int; r record;
BEGIN
  UPDATE finance.accounts SET status = 'closed' WHERE status = 'active' AND account_type = 'cash';
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__recalc_p1__', 'cash', 'EUR', 'active') RETURNING id INTO v_a;
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in)
  VALUES (v_a, t - 130, t - 100, 5000, 4900, 'EUR', 3, 0, -100,    0),
         (v_a, t - 96,  t - 66,  4900, 4500, 'EUR', 3, 0, -400,    0),
         (v_a, t - 65,  t - 36,  4500, 4199.51, 'EUR', 3, 0, -300.49, 0),
         (v_a, t - 35,  t - 5,   4199.51, 3899.51, 'EUR', 3, 0, -300, 0);
  SELECT * INTO r FROM finance.fn_household_everyday_month();
  IF r.monthly_everyday IS DISTINCT FROM -331.00 THEN
    RAISE EXCEPTION 'FAIL [P1] Alltagswert je Monat: erwartet -331.00 (einmal gerundet), got %', r.monthly_everyday; END IF;
END $$;
ROLLBACK;

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
