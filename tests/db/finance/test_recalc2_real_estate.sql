-- tests/db/finance/test_recalc2_real_estate.sql
-- Zweitrechnung Runde 2, Immobilien: Eigenkapital, Restschuld-Verknuepfung, Fremdwaehrungs-Kredit, Instandhaltungs-Luecke.
-- Erwartungswerte schriftlich hergeleitet (nicht aus den Views abgeschrieben). Werte erfunden.
-- Fachregel Eigenkapital (Beleihungs-/Vermoegens-Sicht): Eigenkapital = Marktwert - offene Restschuld aller Darlehen,
--   die auf dem Objekt liegen. Offen = Darlehen laeuft ODER Raten ruhen (Restschuld besteht weiter); ein getilgtes Darlehen
--   zaehlt nicht. Quelle: https://de.wikipedia.org/wiki/Eigenkapital (Abschnitt Immobilienfinanzierung), Restschuld =
--   negativer Saldo des Darlehenskontos.
--   (1) Haus 400.000,00; Darlehen A laeuft, Rest -180.000,55; Darlehen B ruht, Rest -20.000,00; Darlehen C getilgt (Saldo 0)
--       -> Restschuld -200.000,55, Eigenkapital 199.999,45, laufende Darlehen 1 (nur A).
--   (2) Wohnung 250.000,00 mit ruhendem CHF-Darlehen -9.500 CHF, Kurs 0,95 CHF je EUR -> -9.500 / 0,95 = -10.000,00 EUR
--       -> Eigenkapital 240.000,00; ohne Kurs (GBP-Darlehen) -> Luecke gemeldet (has_fx_gap), nie still 0.
--   (3) Konsistenz zweier Sichten: Eigenkapital (real_estate_overview) = Immobilienwert + Saldo der zugehoerigen
--       Darlehenskonten in networth_items (Vermoegens-Sicht). Fuer Haus (1): 400.000 - 180.000,55 - 20.000 = 199.999,45.
--   (4) Instandhaltung II. BV § 28 Abs. 2 (https://www.gesetze-im-internet.de/bvo_2/__28.html), 80 m2, Alter 25 Jahre
--       -> Band "ab 22", 14,58 EUR/m2/Jahr (Stand 2026) -> 1.166,40 / Jahr, 97,20 / Monat -> auf volle Euro auf 98.
--       Eingestellte Rate: 150 EUR je Quartal -> Monatswert 150 / 3 = 50,00 -> Luecke 98 - 50 = 48.
--       Zuschlaege (Aufzug § 28 Abs. 2 Satz 2, Garage Abs. 5) rechnet die fn bewusst nicht (Kopfkommentar "vertagt").
BEGIN;

DO $$
DECLARE
  y int := EXTRACT(YEAR FROM core.fn_today())::int;
  v_giro int; v_la int; v_lb int; v_lc int; v_ld int; v_le int; v_re1 int; v_re2 int; v_re3 int; v_rp int; v_rp2 int;
  v_goal int; v_id_a int; v_id_b int; r record; v_nw numeric;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2re_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2re_la__', 'loan', 'EUR', 'active') RETURNING id INTO v_la;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2re_lb__', 'loan', 'EUR', 'active') RETURNING id INTO v_lb;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2re_lc__', 'loan', 'EUR', 'active') RETURNING id INTO v_lc;
  INSERT INTO finance.real_estate (name, current_value, status) VALUES ('__r2re_haus__', 400000.00, 'active') RETURNING id INTO v_re1;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__r2re_rate_a__', v_giro, -1100, 'month', current_date + 10, current_date) RETURNING id INTO v_rp;
  INSERT INTO finance.loans (name, interest_rate, status, loan_account_id, debit_account_id, real_estate_id, recurring_payment_id)
    VALUES ('__r2re_a__', 3.2, 'active', v_la, v_giro, v_re1, v_rp) RETURNING id INTO v_id_a;
  INSERT INTO finance.loans (name, interest_rate, status, loan_account_id, real_estate_id)
    VALUES ('__r2re_b__', 0, 'paused', v_lb, v_re1) RETURNING id INTO v_id_b;
  INSERT INTO finance.loans (name, interest_rate, status, loan_account_id, real_estate_id)
    VALUES ('__r2re_c__', 2.1, 'paid_off', v_lc, v_re1);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description, loan_id) VALUES
    (v_la, -180000.55, current_date - 30, 'disbursement', '__r2re__', v_id_a),
    (v_lb,  -20000.00, current_date - 30, 'disbursement', '__r2re__', v_id_b);

  SELECT * INTO r FROM finance.real_estate_overview WHERE id = v_re1;
  IF r.associated_debt IS DISTINCT FROM -200000.55 OR r.net_equity IS DISTINCT FROM 199999.45
     OR r.active_loan_count IS DISTINCT FROM 1::bigint OR r.has_fx_gap THEN
    RAISE EXCEPTION 'FAIL [1] Eigenkapital: erwartet -200000.55 / 199999.45 / 1, got % / % / % (fx %)',
      r.associated_debt, r.net_equity, r.active_loan_count, r.has_fx_gap; END IF;
  RAISE NOTICE 'PASS [1] Eigenkapital = Wert - laufende + ruhende Restschuld, getilgtes Darlehen raus';

  -- (3) zweite Sicht
  SELECT sum(value_eur) INTO v_nw FROM finance.networth_items
   WHERE (item_kind = 'real_estate' AND item_id = v_re1) OR (item_kind = 'account' AND item_id IN (v_la, v_lb, v_lc));
  IF v_nw IS DISTINCT FROM 199999.45 THEN
    RAISE EXCEPTION 'FAIL [3] Vermoegens-Sicht: erwartet 199999.45, got %', v_nw; END IF;
  RAISE NOTICE 'PASS [3] Eigenkapital = Immobilie + Darlehenskonten der Vermoegens-Sicht';

  -- (2) Fremdwaehrung
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2), ('GBP', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency IN ('CHF', 'GBP');
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR', 'CHF', 0.95, current_date - 1);
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2re_ld__', 'loan', 'CHF', 'active') RETURNING id INTO v_ld;
  INSERT INTO finance.real_estate (name, current_value, status) VALUES ('__r2re_whg__', 250000.00, 'active') RETURNING id INTO v_re2;
  INSERT INTO finance.loans (name, interest_rate, status, loan_account_id, real_estate_id) VALUES ('__r2re_d__', 1.5, 'paused', v_ld, v_re2) RETURNING id INTO v_id_b;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description, loan_id) VALUES (v_ld, -9500, current_date - 30, 'disbursement', '__r2re__', v_id_b);
  SELECT * INTO r FROM finance.real_estate_overview WHERE id = v_re2;
  IF r.associated_debt IS DISTINCT FROM -10000.00 OR r.net_equity IS DISTINCT FROM 240000.00 OR r.has_fx_gap THEN
    RAISE EXCEPTION 'FAIL [2a] CHF-Darlehen: erwartet -10000.00 / 240000.00, got % / % (fx %)', r.associated_debt, r.net_equity, r.has_fx_gap; END IF;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2re_le__', 'loan', 'GBP', 'active') RETURNING id INTO v_le;
  INSERT INTO finance.real_estate (name, current_value, status) VALUES ('__r2re_gb__', 150000.00, 'active') RETURNING id INTO v_re3;
  INSERT INTO finance.loans (name, interest_rate, status, loan_account_id, real_estate_id) VALUES ('__r2re_e__', 1.5, 'paused', v_le, v_re3) RETURNING id INTO v_id_b;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description, loan_id) VALUES (v_le, -5000, current_date - 30, 'disbursement', '__r2re__', v_id_b);
  SELECT * INTO r FROM finance.real_estate_overview WHERE id = v_re3;
  IF NOT r.has_fx_gap THEN RAISE EXCEPTION 'FAIL [2b] GBP ohne Kurs muss als Luecke gelten, got %', r; END IF;
  RAISE NOTICE 'PASS [2] Fremdwaehrungs-Restschuld in EUR, fehlender Kurs = Luecke';

  -- (4) Instandhaltungs-Luecke mit Quartalsrate
  UPDATE finance.real_estate SET living_area_m2 = 80, year_built = y - 25 WHERE id = v_re1;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2re_pot__', 'cash', 'EUR', 'active') RETURNING id INTO v_ld;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from)
    VALUES ('__r2re_ruecklage__', v_giro, v_ld, -150, 3, 'month', current_date + 5, current_date) RETURNING id INTO v_rp2;
  INSERT INTO finance.savings_goals (name, kind, real_estate_id, recurring_payment_id, status)
    VALUES ('__r2re_mr__', 'maintenance_reserve', v_re1, v_rp2, 'active') RETURNING id INTO v_goal;
  SELECT * INTO r FROM finance.maintenance_reserve_status WHERE real_estate_id = v_re1;
  IF r.band <> 'from22' OR r.recommended_annual IS DISTINCT FROM 1166.40 OR r.recommended_monthly IS DISTINCT FROM 98
     OR r.running_monthly_eur IS DISTINCT FROM 50.00 OR r.gap_monthly_eur IS DISTINCT FROM 48.00 THEN
    RAISE EXCEPTION 'FAIL [4] Instandhaltung: erwartet from22 / 1166.40 / 98 / 50.00 / 48, got % / % / % / % / %',
      r.band, r.recommended_annual, r.recommended_monthly, r.running_monthly_eur, r.gap_monthly_eur; END IF;
  RAISE NOTICE 'PASS [4] Instandhaltung 80 m2 / 25 J.: 98 empfohlen, Quartalsrate 150 = 50/Monat, Luecke 48';

  -- (5) Verkauf zum Schaetzwert ist vermoegensneutral: Haus -400.000, Giro +400.000, Darlehen bleiben (nicht abgeloest)
  --     -> Vermoegen vorher = nachher; danach Eigenkapital-Sicht: das verkaufte Haus zeigt 400.000 - 200.000,55.
  SELECT sum(value_eur) INTO v_nw FROM finance.networth_items;
  r := NULL;
  PERFORM finance.fn_sell_real_estate(jsonb_build_object('real_estate_name', '__r2re_haus__', 'proceeds_account_id', v_giro,
                                                         'sale_date', current_date::text, 'sale_price', '400000'));
  IF (SELECT sum(value_eur) FROM finance.networth_items) IS DISTINCT FROM v_nw THEN
    RAISE EXCEPTION 'FAIL [5a] Verkauf zum Schaetzwert aendert das Vermoegen: vorher %, nachher %',
      v_nw, (SELECT sum(value_eur) FROM finance.networth_items); END IF;
  IF (SELECT sum(value_eur) FROM finance.networth_items WHERE item_kind = 'account' AND item_id IN (v_la, v_lb)) IS DISTINCT FROM -200000.55 THEN
    RAISE EXCEPTION 'FAIL [5b] Restschuld muss nach dem Verkauf bleiben'; END IF;
  RAISE NOTICE 'PASS [5] Verkauf zum Schaetzwert vermoegensneutral, Restschuld bleibt';
END $$;

ROLLBACK;
