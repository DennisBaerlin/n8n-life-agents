-- tests/db/finance/test_fn_household_everyday_month.sql
-- finance.fn_household_everyday_month() — Alltagsausgaben des Haushalts je Monat in EUR (Transparenz 2026-10-30):
--   Summe der Geld-Konten mit Kontoauszug, ohne Kinderkonten, provisional bei nur einem Auszug; und ihre Konsumenten:
--   fn_liquidity_snapshot.monthly_expenses_eur = Pflicht + Alltag, cashflow_coverage rechnet „frei“ nach Alltag.
--   Self-contained (BEGIN..ROLLBACK), Werte erfunden.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_a INT; v_b INT; v_kid INT; r record; v_snap jsonb; v_al jsonb; v_base record;
BEGIN
  SELECT * INTO v_base FROM finance.fn_household_everyday_month();
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('__hem_kid__', 'Kind Beispiel', 'child')
    ON CONFLICT (person_id) DO UPDATE SET role = 'child';
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__hem_a__', 'cash', 'EUR', 'active') RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__hem_b__', 'cash', 'EUR', 'active') RETURNING id INTO v_b;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__hem_kid__', 'cash', 'EUR', 'active', '__hem_kid__') RETURNING id INTO v_kid;
  -- A: zwei Auszuege, gezaehlt nur der juengere (-300 / 30 Tage = -10/Tag); B: nur einer (-600/30 = -20/Tag, vorlaeufig);
  -- Kind: -900/30, zaehlt nie
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_a, t - 64, t - 35, 1600, 1300, 'EUR', 5, 0, -3000, 0, NULL),
         (v_a, t - 34, t - 5, 1300, 1000, 'EUR', 5, 0, -300, 0, t - 35),
         (v_b, t - 34, t - 5, 1300, 700, 'EUR', 5, 0, -600, 0, NULL),
         (v_kid, t - 34, t - 5, 1000, 100, 'EUR', 5, 0, -900, 0, NULL);
  SELECT * INTO r FROM finance.fn_household_everyday_month();
  -- (-10 + -20) x 30.4375 = -913.13 (je Konto gerundet: -304.38 + -608.75 = -913.13)
  IF r.monthly_everyday - v_base.monthly_everyday IS DISTINCT FROM -913.13::numeric OR r.accounts - v_base.accounts <> 2
     OR NOT r.provisional OR r.has_fx_gap THEN
    RAISE EXCEPTION 'FAIL [1] Haushalt -913.13/Monat aus 2 Konten, vorlaeufig, ohne Kind: %', r; END IF;
  RAISE NOTICE 'PASS [1] Alltag je Monat: Eltern-Konten mit Auszug, Kind raus, vorlaeufig';

  -- Notreserve/Runway-Basis: Pflicht + Alltag; Einzelteile sichtbar
  v_snap := finance.fn_liquidity_snapshot();
  IF (v_snap->>'monthly_expenses_eur')::numeric
       <> (v_snap->>'fixed_expenses_eur')::numeric + (v_snap->>'everyday_eur')::numeric
     OR (v_snap->>'everyday_eur')::numeric IS DISTINCT FROM abs(r.monthly_everyday)
     OR (v_snap->>'everyday_provisional')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [2] liquidity_snapshot Pflicht + Alltag: %', v_snap; END IF;
  RAISE NOTICE 'PASS [2] liquidity_snapshot: monthly_expenses_eur = fest + Alltag';

  -- „bleibt frei“ nach Alltag: Einnahme 1500, Miete -800 -> ohne Alltag 700 frei; mit Alltag (-913.13 + Basis) negativ
  PERFORM finance.fn_add_recurring_payment(v_a, 1500, '__hem_gehalt__', 1::smallint, 'month'::finance.schedule_unit, 1::smallint,
            t - 60, t - 60, NULL, NULL, NULL);
  PERFORM finance.fn_add_recurring_payment(v_a, -800, '__hem_miete__', 1::smallint, 'month'::finance.schedule_unit, 1::smallint,
            t - 60, t - 60, NULL, NULL, NULL);
  SELECT a INTO v_al FROM jsonb_array_elements(finance.fn_advisor_review('finance')->'alerts') a
   WHERE a->>'metric_key' = 'cashflow_coverage';
  IF v_al IS NULL OR (v_al->>'value')::numeric >= 0
     OR NOT v_al->'msg' @? '$[*] ? (@.value == "finance.advisor.cashflow_basis_everyday_provisional")'
     OR v_al->'msg'->0->>'value' <> 'finance.advisor.cashflow_deficit' THEN
    RAISE EXCEPTION 'FAIL [3] cashflow_coverage rechnet den Alltag ein und nennt die Basis: %', v_al; END IF;
  -- dieselbe Rechnung im Sofort-Hinweis eines Writes
  IF finance.fn_cashflow_coverage_fold()->'cashflow_coverage'->>'note' NOT LIKE '%everyday spending estimated%' THEN
    RAISE EXCEPTION 'FAIL [3b] Fold-Note nennt den geschaetzten Alltag: %', finance.fn_cashflow_coverage_fold(); END IF;
  RAISE NOTICE 'PASS [3] Defizit nach Alltag mit Basis-Satz, Fold gleich';
END $$;
ROLLBACK;
