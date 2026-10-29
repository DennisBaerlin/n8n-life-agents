-- tests/db/finance/test_fn_account_funding.sql
-- finance.fn_account_funding(acct) — Spar-Deckung eines Kontos: reicht das Geld fuer seine Dauerauftraege und Sparplaene?
--   Tagesreihe aus fn_account_projection (nur Dauerauftraege + Buchungen, keine Alltags-Hochrechnung), Schwelle 0,
--   Auswertung ab heute ueber finance.funding_horizon_months (24). Ampel: alert = unter 0 innerhalb von
--   funding_alert_months (3), warn = innerhalb des Horizonts, ok sonst; fehlender Kurs -> neutral + fx_gap.
--   monthly_in/out je Kette ueber das massgebliche Glied (fn_recurring_effective), Kette zaehlt nicht doppelt.
-- Werte erfunden.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_giro INT; v_kid INT; v_drain INT; v_warn INT; v_alert INT; v_feed INT; v_chain INT; v_rec INT; v_chf INT; v_loan INT;
  v_depot INT; v_spend INT; v_rp INT; v JSONB;
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  DELETE FROM core.config WHERE package = 'finance' AND category = 'finance' AND key IN ('funding_horizon_months', 'funding_alert_months');

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_fu_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_fu_kid__', 'cash', 'EUR', 'active') RETURNING id INTO v_kid;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_fu_drain__', 'cash', 'EUR', 'active') RETURNING id INTO v_drain;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_fu_warn__', 'p2p', 'EUR', 'active') RETURNING id INTO v_warn;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_fu_alert__', 'cash', 'EUR', 'active') RETURNING id INTO v_alert;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_fu_feed__', 'cash', 'EUR', 'active') RETURNING id INTO v_feed;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_fu_chain__', 'cash', 'EUR', 'active') RETURNING id INTO v_chain;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_fu_rec__', 'cash', 'EUR', 'active') RETURNING id INTO v_rec;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_fu_chf__', 'cash', 'CHF', 'active') RETURNING id INTO v_chf;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_fu_loan__', 'loan', 'EUR', 'active') RETURNING id INTO v_loan;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES
    (v_giro, 50000, t - 40, 'other'), (v_kid, 150, t - 40, 'other'), (v_drain, 3000, t - 40, 'other'),
    (v_warn, 10000, t - 40, 'other'), (v_alert, 100, t - 40, 'other'), (v_feed, 1500, t - 40, 'other'),
    (v_chain, 100000, t - 40, 'other');

  -- monatlich (dom NULL = Tag des Ankers): Zubringer vom Giro + externer Eingang (ohne Quellkonto) gegen den Sparplan
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from) VALUES
    ('fu Zubringer Kind', v_giro, v_kid,   -150, 'month', t + 1, t + 1),
    ('fu Zuwendung Kind', v_kid,  NULL,      50, 'month', t + 1, t + 1),
    ('fu Sparplan Kind',  v_kid,  NULL,    -200, 'month', t + 2, t + 2),
    ('fu Zubringer Abbau', v_giro, v_drain, -200, 'month', t + 1, t + 1),
    ('fu Sparplan Abbau', v_drain, NULL,   -240, 'month', t + 2, t + 2),
    ('fu Abfluss warn',   v_warn,  NULL,  -2000, 'month', t + 3, t + 3),
    ('fu Abfluss alert',  v_alert, NULL,   -200, 'month', t + 10, t + 10),
    ('fu Sparplan feed',  v_feed,  NULL,  -1000, 'month', t + 2, t + 2),
    ('fu Zubringer feed', v_giro, v_feed, -1000, 'month', t + 20, t + 20),
    ('fu CHF',            v_giro, v_chf,   -100, 'month', t + 5, t + 5);
  -- die Abfluesse sind Sparplaene (sonst waeren die Konten Ausgabenkonten mit unbekannten Alltagsausgaben, Fall [k])
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__t_fu_depot__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_depot;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
  SELECT r.name, v_depot, 'FU' || r.id, 'Welt ETF', r.id FROM finance.recurring_payments r
   WHERE r.name LIKE 'fu %' AND r.target_account_id IS NULL AND r.amount < 0;

  -- [a] Zufluss = Abfluss (Zubringer 150 + externer Eingang 50 gegen 200) -> ok, Tief = heute 150
  v := finance.fn_account_funding(v_kid);
  IF (v->>'state') <> 'ok' OR (v->>'monthly_in')::numeric <> 200 OR (v->>'monthly_out')::numeric <> -200
     OR (v->>'balance')::numeric <> 150 OR (v->>'min_projected')::numeric <> 150 OR (v->>'min_date')::date <> t
     OR jsonb_typeof(v->'runs_out_on') <> 'null' OR (v->>'fx_gap')::boolean THEN
    RAISE EXCEPTION 'FAIL [a] Zufluss = Abfluss, got %', v; END IF;
  RAISE NOTICE 'PASS [a] externer Eingang zaehlt, gedeckt';

  -- [b] gewollter Abbau 40/Monat bei 3000 -> ueber 24 Monate nie unter 0 -> ok, Tief = 3000 - 24*40
  v := finance.fn_account_funding(v_drain);
  IF (v->>'state') <> 'ok' OR (v->>'monthly_in')::numeric <> 200 OR (v->>'monthly_out')::numeric <> -240
     OR (v->>'min_projected')::numeric <> 2040 OR jsonb_typeof(v->'runs_out_on') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [b] Abbau ohne Luecke, got %', v; END IF;
  RAISE NOTICE 'PASS [b] Abbau aus Guthaben ist ok';

  -- [c] 10000 bei -2000/Monat ab t+3: der 6. Abzug (t+3 + 5 Monate) geht unter 0 -> warn (p2p-Konto zaehlt)
  v := finance.fn_account_funding(v_warn);
  IF (v->>'state') <> 'warn' OR (v->>'runs_out_on')::date <> (t + 3 + interval '5 months')::date THEN
    RAISE EXCEPTION 'FAIL [c] warn reicht bis, got %', v; END IF;
  RAISE NOTICE 'PASS [c] warn mit Datum';

  -- [d] 100 bei -200 ab t+10 -> unter 0 in 10 Tagen -> alert
  v := finance.fn_account_funding(v_alert);
  IF (v->>'state') <> 'alert' OR (v->>'runs_out_on')::date <> t + 10 THEN RAISE EXCEPTION 'FAIL [d] alert, got %', v; END IF;
  RAISE NOTICE 'PASS [d] alert';

  -- [e] Zubringer kommt NACH der Abbuchung (t+20 nach t+2): erster Monat lebt vom Guthaben -> Tief 500 am t+2, ok
  v := finance.fn_account_funding(v_feed);
  IF (v->>'state') <> 'ok' OR (v->>'min_projected')::numeric <> 500 OR (v->>'min_date')::date <> t + 2 THEN
    RAISE EXCEPTION 'FAIL [e] Erster-Monat-Effekt, got %', v; END IF;
  RAISE NOTICE 'PASS [e] spaeter Zubringer -> Tiefpunkt im ersten Monat';

  -- [f] Kette (Split): laufendes Glied -100 bis t+15, Nachfolger -150 ab t+15 -> monthly_out = -100 (nicht -250)
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('fu Kette alt', v_chain, -100, 'month', t - 30, t - 30, t + 15) RETURNING id INTO v_rp;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, predecessor_id)
    VALUES ('fu Kette neu', v_chain, -150, 'month', t - 30, t + 15, v_rp) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('fu Kette', v_depot, 'FUK1', 'Welt ETF', v_rp);
  v := finance.fn_account_funding(v_chain);
  IF (v->>'monthly_out')::numeric <> -100 OR (v->>'monthly_in')::numeric <> 0 THEN
    RAISE EXCEPTION 'FAIL [f] Kette doppelt gezaehlt, got %', v; END IF;
  -- erst kuenftig startende Kette: das erste kommende Glied zaehlt
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('fu Zukunft alt', v_chain, -10, 'month', t + 40, t + 40, t + 100) RETURNING id INTO v_rp;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, predecessor_id)
    VALUES ('fu Zukunft neu', v_chain, -20, 'month', t + 40, t + 100, v_rp) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('fu Zukunft', v_depot, 'FUK2', 'Welt ETF', v_rp);
  v := finance.fn_account_funding(v_chain);
  IF (v->>'monthly_out')::numeric <> -110 THEN RAISE EXCEPTION 'FAIL [f2] kommende Kette = erstes Glied, got %', v; END IF;
  RAISE NOTICE 'PASS [f] Ketten: massgebliches Glied, nicht doppelt';

  -- [g] Abgleich vor 21 Tagen (Stand 1000), danach ein Tief unter 0 VOR heute -> zaehlt nicht, ok
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_rec, 1000, t - 40, 'other');
  PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', v_rec, 'confirmed_balance', 1000,
                                                          'reconciliation_date', (t - 21)::text));
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_rec, -1100, t - 10, 'other'),
                                                                                         (v_rec, 1200, t - 5, 'other');
  v := finance.fn_account_funding(v_rec);
  IF (v->>'state') <> 'ok' OR (v->>'min_projected')::numeric <> 1100 OR jsonb_typeof(v->'runs_out_on') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [g] Tief vor heute zaehlt nicht, got %', v; END IF;
  RAISE NOTICE 'PASS [g] Auswertung erst ab heute';

  -- [h] Ziel in CHF ohne Kurs -> neutral + fx_gap
  v := finance.fn_account_funding(v_chf);
  IF (v->>'state') <> 'neutral' OR NOT (v->>'fx_gap')::boolean THEN RAISE EXCEPTION 'FAIL [h] fx, got %', v; END IF;
  RAISE NOTICE 'PASS [h] ohne Kurs neutral';

  -- [i] Config: Horizont 2 Monate -> warn-Konto (leer nach ~5 Monaten) ist ok; alert-Fenster wird auf den Horizont gedeckelt
  INSERT INTO core.config (package, category, key, value) VALUES ('finance', 'finance', 'funding_horizon_months', '2'),
                                                                  ('finance', 'finance', 'funding_alert_months', '12');
  v := finance.fn_account_funding(v_warn);
  IF (v->>'state') <> 'ok' THEN RAISE EXCEPTION 'FAIL [i] Horizont 2 Monate, got %', v; END IF;
  v := finance.fn_account_funding(v_alert);
  IF (v->>'state') <> 'alert' THEN RAISE EXCEPTION 'FAIL [i2] alert im gedeckelten Fenster, got %', v; END IF;
  -- probe: nur das (gedeckelte) alert-Fenster = 2 Monate
  v := finance.fn_account_funding(v_warn, true);
  IF (v->>'horizon_end')::date <> (t + interval '2 months')::date THEN RAISE EXCEPTION 'FAIL [i3] p_alert_only, got %', v; END IF;
  DELETE FROM core.config WHERE package = 'finance' AND category = 'finance' AND key IN ('funding_horizon_months', 'funding_alert_months');
  RAISE NOTICE 'PASS [i] Config + probe-Fenster';

  -- [k] Ausgabenkonto (Miete ohne Ziel, kein Sparplan): ohne Auszug Alltagsausgaben unbekannt -> neutral statt „gedeckt";
  --     mit Auszug netto (-400 raus, +100 rein auf 30 Tage = -10 je Tag) eingerechnet
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_fu_spend__', 'cash', 'EUR', 'active') RETURNING id INTO v_spend;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_spend, 30000, t - 40, 'other');
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('fu Miete', v_spend, -500, 'month', t + 4, t + 4);
  v := finance.fn_account_funding(v_spend);
  IF (v->>'state') <> 'neutral' OR (v->>'everyday') <> 'unknown' OR (v->>'fx_gap')::boolean THEN
    RAISE EXCEPTION 'FAIL [k] Ausgabenkonto ohne Auszug -> neutral/unknown, got %', v; END IF;
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_spend, t - 64, t - 35, 30300, 30000, 'EUR', 5, 0, -400, 100, NULL);
  v := finance.fn_account_funding(v_spend);
  IF (v->>'state') <> 'ok' OR (v->>'everyday') <> 'estimated' OR (v->>'everyday_per_day')::numeric <> -10 THEN
    RAISE EXCEPTION 'FAIL [k2] Ausgabenkonto mit Auszug -> netto -10 je Tag eingerechnet, got %', v; END IF;
  RAISE NOTICE 'PASS [k] Alltagsausgaben: unbekannt -> neutral, mit Auszug netto eingerechnet';

  -- [j] Kreditkonto / unbekannt -> ok:false
  IF (finance.fn_account_funding(v_loan)->>'ok')::boolean OR (finance.fn_account_funding(-1)->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL [j] Kreditkonto/unbekannt'; END IF;
  RAISE NOTICE 'PASS [j] Kredit/unbekannt -> ok:false';
END $$;
ROLLBACK;
