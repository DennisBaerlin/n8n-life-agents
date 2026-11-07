-- tests/db/cross/test_recalc2_household_cashflow.sql
-- Zweitrechnung Runde 2, Haushalts-Aggregate: Monats-Cashflow (Familie und Eltern), freies Geld, Runway (career).
-- Erwartungswerte schriftlich hergeleitet, nicht aus den Views abgeschrieben. Werte erfunden.
-- Fachregeln:
--   * Monatswert eines Rhythmus = Betrag x (365,25 / 12) / Tage je Periode (Woche 7, Jahr 365,25), auf Cent.
--     -25 je Woche -> -25 x 30,4375 / 7 = -108,705 -> -108,71; -480 je Jahr -> -40,00.
--   * Kreditrate = Zins (Konsum) + Tilgung: Zins je Monat = Restschuld x Satz / 12 = 150.000 x 3 % / 12 = 375,00;
--     Rate -900 -> Konsum -375,00, Tilgung -525,00.
--   * Umbuchung zwischen eigenen Konten ist kein Haushalts-Ein-/Ausgang (Standard YNAB/Actual: "transfer");
--     Umbuchung Eltern -> Kind ist aus Eltern-Sicht eine Ausgabe.
--   Fixture: Gehalt +3.200/Monat, Miete -1.100, Versicherung -480/Jahr, Taschengeld -25/Woche, Kreditrate -900,
--     Sparziel-Rate -200 in einen Topf, Umbuchung Giro -> Zweitkonto -300, Umbuchung Eltern -> Kind -150.
--   (1) Familie: Einnahmen 3.200,00; Konsum -1.100 - 40 - 108,71 - 375 = -1.623,71; Tilgung -525,00;
--       Pflicht -2.148,71; frei 3.200 - 2.148,71 = 1.051,29; Sparen -200,00; Kontoveraenderung 851,29.
--   (2) Eltern: zusaetzlich -150 an das Kind -> Konsum -1.773,71, Pflicht -2.298,71, frei 901,29.
--   (3) Konsistenz: Summe der Einzelzeilen (monthly_cashflow_overview) = Familien-Summe; Snapshot-Pflicht = |Eltern-Pflicht|.
--   (4) Freies Geld (Notreserve/Runway, Tagesgeld-Regel): Giro 12.000 + Zweitkonto 1.000; Topf 3.000 voll fuer das
--       Sparziel reserviert -> 0; Kinderkonto 500 zaehlt nicht -> 13.000,00.
--   (5) Runway = volle Monate, die das freie Geld die Pflicht-Ausgaben traegt (abgerundet):
--       13.000 / 2.298,71 = 5,65 -> 5 Monate < Probezeit 6 -> deckt nicht;
--       mit 400 Notfall-Einkommen: 13.000 / 1.898,71 = 6,85 -> 6 -> deckt (6 >= 6); Probezeit 7 -> deckt nicht.
BEGIN;

DO $$
DECLARE
  v_giro int; v_giro2 int; v_pot int; v_kid int; v_la int; v_rp_loan int; v_rp_goal int; v_goal int;
  f record; p record; s jsonb; w jsonb;
BEGIN
  INSERT INTO core.package_registry (package, status) VALUES ('finance', 'active') ON CONFLICT (package) DO UPDATE SET status = 'active';
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','r2p','first_name','Pat','last_name','Muster','role','owner','birth_date','1984-02-02','telegram_user_id',821),
            jsonb_build_object('person_id','r2k','first_name','Kai','last_name','Muster','role','child','birth_date','2016-02-02','telegram_user_id',822)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  -- Bestand neutralisieren (alles im ROLLBACK)
  UPDATE finance.recurring_payments SET status = 'paused' WHERE status = 'active';
  UPDATE finance.accounts SET status = 'closed' WHERE status = 'active' AND account_type = 'cash';

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2cf_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2cf_giro2__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro2;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2cf_pot__', 'cash', 'EUR', 'active') RETURNING id INTO v_pot;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id) VALUES ('__r2cf_kid__', 'cash', 'EUR', 'active', 'r2k') RETURNING id INTO v_kid;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2cf_loan__', 'loan', 'EUR', 'active') RETURNING id INTO v_la;

  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from) VALUES
    ('__r2cf_gehalt__',  v_giro, NULL,    3200, 1, 'month', current_date - 10, current_date - 10),
    ('__r2cf_miete__',   v_giro, NULL,   -1100, 1, 'month', current_date - 10, current_date - 10),
    ('__r2cf_vers__',    v_giro, NULL,    -480, 1, 'year',  current_date - 10, current_date - 10),
    ('__r2cf_tg__',      v_giro, NULL,     -25, 1, 'week',  current_date - 3,  current_date - 3),
    ('__r2cf_umb__',     v_giro, v_giro2, -300, 1, 'month', current_date - 10, current_date - 10),
    ('__r2cf_kind__',    v_giro, v_kid,   -150, 1, 'month', current_date - 10, current_date - 10);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__r2cf_rate__', v_giro, -900, 'month', current_date - 10, current_date - 10) RETURNING id INTO v_rp_loan;
  INSERT INTO finance.loans (name, interest_rate, status, loan_account_id, debit_account_id, recurring_payment_id)
    VALUES ('__r2cf_kredit__', 3.0, 'active', v_la, v_giro, v_rp_loan);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, loan_id)
    VALUES (v_la, -150000, current_date - 60, 'disbursement', (SELECT id FROM finance.loans WHERE name = '__r2cf_kredit__'));
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__r2cf_sparrate__', v_giro, v_pot, -200, 'month', current_date - 10, current_date - 10) RETURNING id INTO v_rp_goal;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, recurring_payment_id, status)
    VALUES ('__r2cf_ziel__', 6000, current_date + 400, v_rp_goal, 'active') RETURNING id INTO v_goal;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_pot, 3000, current_date - 5, 'transfer', v_goal, gen_random_uuid());
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES
    (v_giro, 12000, current_date - 5, 'other'), (v_giro2, 1000, current_date - 5, 'other'), (v_kid, 500, current_date - 5, 'other');

  SELECT * INTO f FROM finance.monthly_cashflow_summary;
  IF f.monthly_income IS DISTINCT FROM 3200.00 OR f.monthly_consumption IS DISTINCT FROM -1623.71
     OR f.monthly_principal IS DISTINCT FROM -525.00 OR f.monthly_obligations IS DISTINCT FROM -2148.71
     OR f.monthly_free IS DISTINCT FROM 1051.29 OR f.monthly_saving IS DISTINCT FROM -200.00
     OR f.monthly_account_change IS DISTINCT FROM 851.29 THEN
    RAISE EXCEPTION 'FAIL [1] Familie: erwartet 3200 / -1623.71 / -525 / -2148.71 / 1051.29 / -200 / 851.29, got %', row_to_json(f); END IF;
  RAISE NOTICE 'PASS [1] Familien-Cashflow: Rhythmen, Zins/Tilgung, Umbuchung neutral';

  SELECT * INTO p FROM finance.parent_cashflow_summary;
  IF p.monthly_consumption IS DISTINCT FROM -1773.71 OR p.monthly_obligations IS DISTINCT FROM -2298.71
     OR p.monthly_free IS DISTINCT FROM 901.29 THEN
    RAISE EXCEPTION 'FAIL [2] Eltern: erwartet -1773.71 / -2298.71 / 901.29, got %', row_to_json(p); END IF;
  RAISE NOTICE 'PASS [2] Eltern-Cashflow: Umbuchung an das Kind ist Ausgabe';

  IF (SELECT sum(income_eur) + sum(consumption_eur) + sum(principal_eur) FROM finance.monthly_cashflow_overview) IS DISTINCT FROM f.monthly_free THEN
    RAISE EXCEPTION 'FAIL [3a] Einzelzeilen ergeben die Summe nicht'; END IF;
  s := finance.fn_liquidity_snapshot();
  IF (s->>'fixed_expenses_eur')::numeric IS DISTINCT FROM 2298.71 OR (s->>'monthly_expenses_eur')::numeric IS DISTINCT FROM 2298.71
     OR (s->>'monthly_income_eur')::numeric IS DISTINCT FROM 3200.00 THEN
    RAISE EXCEPTION 'FAIL [3b] Snapshot-Pflichtbasis: %', s; END IF;
  RAISE NOTICE 'PASS [3] Sichten gleich: Zeilen = Summe, Snapshot = Eltern-Pflicht';

  IF (s->>'cash_eur')::numeric IS DISTINCT FROM 13000.00 OR (s->>'earmarked_eur')::numeric IS DISTINCT FROM 3000.00 THEN
    RAISE EXCEPTION 'FAIL [4] freies Geld: erwartet 13000 / 3000 reserviert, got %', s; END IF;
  RAISE NOTICE 'PASS [4] freies Geld ohne Sparziel-Topf und Kinderkonto';

  w := career.fn_runway('{"transition":{"probation_months":6}}');
  IF (w->>'runway_months')::int IS DISTINCT FROM 5 OR (w->>'covers')::boolean IS DISTINCT FROM false
     OR (w->>'effective_burn')::numeric IS DISTINCT FROM 2298.71 THEN
    RAISE EXCEPTION 'FAIL [5a] Runway: erwartet 5 / deckt nicht, got %', w; END IF;
  w := career.fn_runway('{"transition":{"probation_months":6,"expected_gap_income_eur":400}}');
  IF (w->>'runway_months')::int IS DISTINCT FROM 6 OR (w->>'covers')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [5b] Runway mit 400: erwartet 6 / deckt, got %', w; END IF;
  w := career.fn_runway('{"transition":{"probation_months":7,"expected_gap_income_eur":400}}');
  IF (w->>'covers')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [5c] Probezeit 7: %', w; END IF;
  RAISE NOTICE 'PASS [5] Runway 5 / 6 Monate, Grenze Probezeit';
END $$;

ROLLBACK;
