-- tests/db/finance/test_recalc2_statement_import.sql
-- Zweitrechnung Kontoauszugs-Import: Saldo-Abgleich nach dem Import, Zuordnungs-Fenster an den Grenzen,
-- Dubletten-Hinweis ueber Monats- und Jahresgrenzen. Erwartungen von Hand hergeleitet. Werte erfunden.
-- Fachregeln (fn-Kopf als Spezifikation, Rechnung selbst):
--   * Saldo-Probe: Anfangssaldo + Summe der Zeilen = Endsaldo. Nach dem Import steht das Konto am Zeitraum-Ende auf dem
--     Endsaldo; was keiner erwarteten Zahlung zugeordnet ist, wird eine Rest-Buchung (lump).
--   * Zuordnung Stufe B: Zeile 5 Tage vor bis 10 Tage nach der Faelligkeit, Betrag exakt.
--   * Dubletten-Hinweis: gleiches Konto, gleicher Betrag mit Vorzeichen, hoechstens 3 Kalendertage Abstand.
--   Auszug Januar 2026, bestaetigter Stand 2.000,00 am 31.12.2025. Miete -900 am 1., Versicherung -120 am 15.
--   (1) Zeilen 02.01. -900 (Miete, 1 Tag spaeter), 10.01. -45,10 (Karte), 26.01. -120 (11 Tage nach dem 15.):
--       Endsaldo 2.000 - 900 - 45,10 - 120 = 934,90; zugeordnet 1 (Miete), Versicherung fehlt, Rest -165,10.
--       Nach dem Buchen: Kontostand am 31.01. = 934,90, booked_count 1, Rest-Abgang 165,10 (als Betrag), offene Abgaenge -165,10, 1 Vorkommen uebersprungen.
--   (2) Dieselbe Versicherungs-Zeile am 25.01. (genau 10 Tage danach) -> zugeordnet 2, Rest nur die Karte -45,10.
--   (3) Dubletten: Buchung -45,90 am 30.12.2027; Pruefung am 02.01.2028 (3 Tage, ueber den Jahreswechsel) -> Hinweis;
--       03.01.2028 (4 Tage) -> keiner; +45,90 (anderes Vorzeichen) -> keiner; 27.12.2027 (3 Tage davor) -> Hinweis.
BEGIN;

DO $$
DECLARE
  ps date := DATE '2026-01-01'; pe date := DATE '2026-01-31';
  v_giro int; r_miete int; r_vers int; v_stmt jsonb; v_prep jsonb; v_res jsonb; v_lines jsonb; v_n jsonb;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__r2si_giro__","account_type":"cash","currency":"EUR","account_number":"DE11 5205 1373 5120 7101 31"}'::jsonb)->>'account_id')::int;
  r_miete := finance.fn_add_recurring_payment(v_giro, -900, 'Miete', 1::smallint, 'month'::finance.schedule_unit, 1::smallint,
               DATE '2025-11-01', DATE '2025-11-01', NULL, NULL, NULL);
  r_vers  := finance.fn_add_recurring_payment(v_giro, -120, 'Versicherung', 1::smallint, 'month'::finance.schedule_unit, 15::smallint,
               DATE '2025-11-01', DATE '2025-11-01', NULL, NULL, NULL);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_giro, 2000, DATE '2025-10-01', 'other');
  v_res := finance.fn_reconcile_account(jsonb_build_object('account_id', v_giro, 'confirmed_balance', 2000, 'reconciliation_date', '2025-12-31'));
  IF (v_res->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'SETUP reconcile: %', v_res; END IF;

  v_lines := jsonb_build_array(
    jsonb_build_object('date', '2026-01-02', 'amount', -900,   'counterparty', 'Hausverwaltung', 'purpose', 'Miete'),
    jsonb_build_object('date', '2026-01-10', 'amount', -45.10, 'counterparty', 'Markt', 'purpose', 'Einkauf'),
    jsonb_build_object('date', '2026-01-26', 'amount', -120,   'counterparty', 'Assekuranz', 'purpose', 'Beitrag'));
  v_stmt := jsonb_build_object('account_number', 'DE11520513735120710131', 'currency', 'EUR', 'period_start', ps, 'period_end', pe,
                               'opening_balance', 2000, 'closing_balance', 934.90, 'lines', v_lines);

  -- (2) zuerst: Grenze genau 10 Tage (nur Vorschau, kein Write)
  v_prep := finance.fn_statement_prepare(jsonb_set(v_stmt, '{lines,2,date}', '"2026-01-25"'));
  IF jsonb_array_length(v_prep->'matched') <> 2 OR (v_prep->>'lump')::numeric IS DISTINCT FROM -45.10 THEN
    RAISE EXCEPTION 'FAIL [2] 10 Tage danach: matched % lump %', v_prep->'matched', v_prep->>'lump'; END IF;
  RAISE NOTICE 'PASS [2] Zeile 10 Tage nach Faelligkeit wird zugeordnet, Rest -45,10';

  -- (1)
  v_prep := finance.fn_statement_prepare(v_stmt);
  IF (v_prep->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(v_prep->'matched') <> 1
     OR (v_prep->'matched'->0->>'recurring_payment_id')::int IS DISTINCT FROM r_miete
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'missing') x WHERE (x->>'recurring_payment_id')::int = r_vers)
     OR (v_prep->>'lump')::numeric IS DISTINCT FROM -165.10 THEN
    RAISE EXCEPTION 'FAIL [1a] Vorschau: %', v_prep; END IF;
  v_res := finance.fn_apply_bank_statement(v_stmt || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
  IF (v_res->>'ok')::boolean IS NOT TRUE OR (v_res->>'booked_count')::int IS DISTINCT FROM 1
     OR (v_res->>'rest_outflow')::numeric IS DISTINCT FROM 165.10 OR (v_res->>'unmatched_out')::numeric IS DISTINCT FROM -165.10
     OR (v_res->>'balance_after')::numeric IS DISTINCT FROM 934.90 OR (v_res->>'skipped_occurrences')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL [1b] Buchung: %', v_res; END IF;
  IF finance.fn_get_balance_as_of(v_giro, pe) IS DISTINCT FROM 934.90 THEN
    RAISE EXCEPTION 'FAIL [1c] Stand am Zeitraum-Ende: erwartet 934.90, got %', finance.fn_get_balance_as_of(v_giro, pe); END IF;
  RAISE NOTICE 'PASS [1] Import: Endsaldo 934,90 erreicht, 1 Treffer, Rest -165,10 (11 Tage = ausserhalb)';

  -- (3) Dubletten-Hinweis ueber den Jahreswechsel
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_giro, -45.90, DATE '2027-12-30', 'other');
  IF jsonb_array_length(finance.fn_possible_duplicate_note(v_giro, -45.90, DATE '2028-01-02')) <> 1
     OR jsonb_array_length(finance.fn_possible_duplicate_note(v_giro, -45.90, DATE '2027-12-27')) <> 1
     OR jsonb_array_length(finance.fn_possible_duplicate_note(v_giro, -45.90, DATE '2028-01-03')) <> 0
     OR jsonb_array_length(finance.fn_possible_duplicate_note(v_giro, 45.90, DATE '2027-12-30')) <> 0 THEN
    RAISE EXCEPTION 'FAIL [3] Dubletten-Fenster +-3 Tage'; END IF;
  RAISE NOTICE 'PASS [3] Dubletten-Hinweis: 3 Tage ueber den Jahreswechsel ja, 4 Tage nein, Vorzeichen zaehlt';
END $$;

ROLLBACK;
