-- tests/db/finance/test_v_advisor_read_views.sql
-- Lese-Views fuer den Finanzberater (Berater-Nachruestung 2026-10-30): die DB rechnet, der Berater liest nur.
--   finance.account_funding_overview   EINE Zeile je Deckungs-Konto (fn_funding_accounts, Rollen als Liste) mit der
--                                      Spar-Deckung aus fn_account_funding
--   finance.standing_order_overview    die Dauerauftraege aus fn_standing_orders mit Konto-Namen, Rhythmus, Monatsbetrag
--   finance.account_everyday_spending  geschaetzte Alltagsausgaben je aktivem Geld-Konto, je Tag und je Monat
-- Werte erfunden.
BEGIN;

DO $$
DECLARE
  t       DATE := CURRENT_DATE;
  v_first DATE := (date_trunc('month', current_date) + interval '1 month' + interval '1 day')::date;
  v_giro INT; v_pot INT; v_depot INT; v_rp INT; v_res JSONB; v_row RECORD; n INT;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_arv_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_arv_pot__', 'cash', 'EUR', 'active') RETURNING id INTO v_pot;
  INSERT INTO finance.accounts (name, account_type, bank, currency, status, settlement_account_id)
    VALUES ('__t_arv_depot__', 'stocks_depot', 'Beispielbank', 'EUR', 'active', v_pot) RETURNING id INTO v_depot;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES
    (v_giro, 5000, t - 40, 'other'), (v_pot, 1000, t - 40, 'other');
  -- ein Auszug ueber 30 Tage mit 300 nicht zugeordneten Abgaengen -> 10 je Tag
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_giro, t - 34, t - 5, 5300, 5000, 'EUR', 5, 0, -300, 0, NULL);

  -- Dauerauftrag Giro -> Topf (150 im Monat) + Sparplan vom Topf (Verrechnungskonto des Depots)
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('arv Zubringer', v_giro, v_pot, -150, 'month', t + 1, t + 1) RETURNING id INTO v_rp;
  v_res := finance.fn_create_savings_plan(jsonb_build_object(
    'name','__t_arv_plan__','depot_name','__t_arv_depot__',
    'isin','IE00B5BMR087','symbol','CSPX','security_name','Beispiel S&P 500',
    'amount',100,'schedule_interval',1,'schedule_unit','month','first_payment_date',v_first));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL fn_create_savings_plan: %', v_res; END IF;

  -- (1) Spar-Deckung: der Topf zahlt den Sparplan UND schickt selbst einen Dauerauftrag -> EINE Zeile, beide Rollen;
  --     das Giro ist Absender des Zubringers -> Rolle order_source (UX-Gesamtkonzept 2026-10-31: Absender statt Empfaenger)
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('arv Rueckfluss', v_pot, v_giro, -20, 'month', t + 3, t + 3);
  SELECT count(*) INTO n FROM finance.account_funding_overview WHERE account_id = v_pot;
  IF n <> 1 THEN RAISE EXCEPTION 'FAIL funding: % Zeilen fuer den Topf (erwartet 1)', n; END IF;
  SELECT * INTO v_row FROM finance.account_funding_overview WHERE account_id = v_pot;
  IF v_row.roles IS DISTINCT FROM ARRAY['order_source', 'plan'] OR v_row.account_name IS DISTINCT FROM '__t_arv_pot__'
     OR v_row.state IS DISTINCT FROM (finance.fn_account_funding(v_pot)->>'state')
     OR v_row.monthly_in IS DISTINCT FROM (finance.fn_account_funding(v_pot)->>'monthly_in')::numeric
     OR v_row.monthly_out IS DISTINCT FROM (finance.fn_account_funding(v_pot)->>'monthly_out')::numeric THEN
    RAISE EXCEPTION 'FAIL funding Zeile: %', row_to_json(v_row); END IF;
  IF (SELECT roles FROM finance.account_funding_overview WHERE account_id = v_giro) IS DISTINCT FROM ARRAY['order_source'] THEN
    RAISE EXCEPTION 'FAIL funding: das Giro ist Absender des Zubringers (order_source)'; END IF;
  RAISE NOTICE 'PASS account_funding_overview: eine Zeile je Konto, Rollen plan+order_source, Werte = fn_account_funding';

  -- (2) Dauerauftraege mit Namen statt ids; die Sparplan-Abbuchung ist kein Dauerauftrag
  SELECT * INTO v_row FROM finance.standing_order_overview WHERE recurring_payment_id = v_rp;
  IF v_row.kind IS DISTINCT FROM 'transfer' OR v_row.from_account IS DISTINCT FROM '__t_arv_giro__'
     OR v_row.to_account IS DISTINCT FROM '__t_arv_pot__' OR v_row.amount_per_execution IS DISTINCT FROM 150
     OR v_row.monthly_amount IS DISTINCT FROM 150 OR v_row.rhythm IS NULL OR v_row.starts_on IS DISTINCT FROM t + 1 THEN
    RAISE EXCEPTION 'FAIL standing_order Zeile: %', row_to_json(v_row); END IF;
  IF EXISTS (SELECT 1 FROM finance.standing_order_overview WHERE from_account = '__t_arv_pot__' AND name <> 'arv Rueckfluss') THEN
    RAISE EXCEPTION 'FAIL standing_order: Sparplan-Abbuchung als Dauerauftrag gelistet'; END IF;
  RAISE NOTICE 'PASS standing_order_overview: Namen, Betrag je Ausfuehrung, Monatsbetrag, Start';

  -- (3) Alltagsausgaben: -10 je Tag -> -304.38 je Monat (30.4375 Tage); ohne Auszug unbekannt, nicht 0
  SELECT * INTO v_row FROM finance.account_everyday_spending WHERE account_id = v_giro;
  IF v_row.everyday_per_day IS DISTINCT FROM -10 OR v_row.everyday_per_month IS DISTINCT FROM -304.38
     OR v_row.has_history IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL everyday Giro: %', row_to_json(v_row); END IF;
  SELECT * INTO v_row FROM finance.account_everyday_spending WHERE account_id = v_pot;
  IF v_row.has_history IS DISTINCT FROM false OR v_row.everyday_per_month IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL everyday ohne Auszug: %', row_to_json(v_row); END IF;
  IF EXISTS (SELECT 1 FROM finance.account_everyday_spending WHERE account_id = v_depot) THEN
    RAISE EXCEPTION 'FAIL everyday: Depot gelistet'; END IF;
  RAISE NOTICE 'PASS account_everyday_spending: je Tag + je Monat aus der DB, ohne Auszug NULL';
  -- Perspektive des Beraters (finance_ro): tests/db/cross/test_role_permissions.sql (2-adv)
END $$;

ROLLBACK;
