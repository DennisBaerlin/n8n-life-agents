-- tests/db/finance/test_fn_advisor_snapshot.sql
-- finance.fn_advisor_snapshot() — das Gesamtbild des Beraters in einer Abfrage (sonst riss der Plan-Knopf maxIterations).
--   0) Drift-Waechter: jede finance-View steht in genau einer Liste; "enthalten" kommt wirklich in der fn vor.
--   1) Form: genau diese Schluessel, Listen als Liste, Objekte als Objekt; gefilterte Listen leer = [].
--   2) Wertgleich zu den Quellen (Kontosaldo + Alltag, Cashflow, Kredite, Notreserve, Ziel-Ampel, Rente).
--   3) Beendetes fehlt (Konto, Kredit, Ziel, Vorsorge, Immobilie, Sparplan), Pausiertes bleibt wo vorgesehen.
--   4) Keine Vertrags-/Kontonummern und keine notes, auch nicht als Wert, und keine technischen Spalten.
--   5) warnings: welche Konten gemeldet werden, Werte gleich fn_account_outlook / account_funding_overview.
-- Perspektive finance_ro: tests/db/cross/test_role_permissions.sql (2-adv). Self-contained (BEGIN..ROLLBACK), Werte erfunden.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  -- enthalten: das Gesamtbild
  v_included text[] := ARRAY['account_everyday_spending', 'account_funding_overview', 'account_overview', 'active_insurances', 'depot_holdings_overview',
    'depot_performance', 'loan_overview', 'loan_summary', 'monthly_cashflow_overview', 'monthly_cashflow_summary',
    'networth_by_asset_class', 'parent_cashflow_summary', 'pension_overview', 'real_estate_overview', 'savings_goal_progress',
    'savings_plan_overview', 'standing_order_overview', 'upcoming_recurring_payments'];
  -- bewusst nicht enthalten (Detailfragen, die Einzel-View reicht; das Gesamtbild waere sonst doppelt oder teuer):
  v_excluded text[] := ARRAY[
    'active_recurring_payments',       -- Rohsicht inkl. Transfers; das Bild traegt monthly_cashflow_overview
    'recurring_cashflow_classified',   -- Unterbau von monthly_cashflow_overview
    'cashflow_summary_by_scope',       -- Unterbau der beiden Summen-Views
    'parent_cashflow_overview',        -- Detail hinter parent_cashflow_summary
    'networth_items',                  -- Einzelposten hinter networth_by_asset_class
    'savings_goal_account_share',      -- Ziel-Anteil je Konto: Detail
    'savings_goal_reserve_breakdown',  -- wo liegt das Geld eines Ziels: Detail
    'account_reserve_status',          -- Deckungs-Alarm-Detail je Konto
    'depot_reserve_status',            -- Deckungs-Alarm-Detail je Depot
    'maintenance_reserve_status'];     -- Instandhaltungs-Detail
  v_lists text[] := ARRAY['persons', 'recurring', 'planned_recurring', 'accounts', 'networth', 'savings_plans', 'standing_orders', 'loans', 'insurances',
    'pensions', 'pension_outlook', 'real_estate', 'goals', 'depot_risk', 'depot_holdings', 'depot_performance', 'warnings'];
  v_objects text[] := ARRAY['cashflow_summary', 'parent_cashflow_summary', 'loan_summary', 'emergency_reserve'];
  v_giro INT; v_tg INT; v_closed INT; v_depot INT; v_kind INT;
  v_loan_open INT; v_loan_paid INT; v_pen INT; v_g_ok INT; v_g_done INT;
  v_bad text[]; v_src text; k text; v jsonb; v_row jsonb; v_txt text; v_o jsonb;
  v_low INT; v_tight INT; v_hist INT; v_fund INT; v_fund_ok INT;
BEGIN
  -- ===== 0) Drift-Waechter =====
  SELECT array_agg(table_name::text ORDER BY table_name) INTO v_bad
    FROM information_schema.views
   WHERE table_schema = 'finance' AND NOT table_name::text = ANY (v_included || v_excluded);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [0a] neue finance-View ohne Entscheidung (in den Snapshot oder begruendet auf die Ausschlussliste): %', v_bad; END IF;
  SELECT array_agg(x) INTO v_bad FROM unnest(v_included) x WHERE x = ANY (v_excluded);
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'FAIL [0b] View in beiden Listen: %', v_bad; END IF;
  SELECT array_agg(x) INTO v_bad FROM unnest(v_included || v_excluded) x
   WHERE NOT EXISTS (SELECT 1 FROM information_schema.views w WHERE w.table_schema = 'finance' AND w.table_name = x);
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'FAIL [0c] Liste nennt eine View, die es nicht mehr gibt: %', v_bad; END IF;
  v_src := pg_get_functiondef('finance.fn_advisor_snapshot()'::regprocedure);
  SELECT array_agg(x) INTO v_bad FROM unnest(v_included) x WHERE v_src !~ ('finance\.' || x || '\y');
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'FAIL [0d] "enthalten", aber nicht in der fn: %', v_bad; END IF;
  -- neue Nummern-/IBAN-Spalte in einer enthaltenen View -> erst entscheiden (Entfernliste der fn), dann gruen
  SELECT array_agg(c.table_name || '.' || c.column_name) INTO v_bad
    FROM information_schema.columns c
   WHERE c.table_schema = 'finance' AND c.table_name::text = ANY (v_included)
     AND c.column_name ~ '(number|iban)' AND NOT c.column_name::text = ANY (ARRAY['account_number', 'contract_number', 'policy_number']);
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'FAIL [0e] neue Nummern-Spalte in einer enthaltenen View: %', v_bad; END IF;
  RAISE NOTICE 'PASS [0] Drift-Waechter: jede View entschieden, Listen disjunkt, enthaltene Views in der fn, keine neue Nummern-Spalte';

  -- ===== 1a) Gefilterte Listen leer = [] (Bestand ausblenden, kein DELETE noetig) =====
  UPDATE finance.loans SET status = 'paid_off';
  UPDATE finance.pension SET status = 'paid_out';
  UPDATE finance.real_estate SET status = 'sold';
  UPDATE finance.savings_goals SET status = 'cancelled';
  v := finance.fn_advisor_snapshot();
  FOREACH k IN ARRAY ARRAY['loans', 'pensions', 'pension_outlook', 'real_estate', 'goals'] LOOP
    IF v->k IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [1a] % leer soll [] sein: %', k, v->k; END IF;
  END LOOP;

  -- ===== Fixture =====
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('__snap_owner__', 'Owner Beispiel', 'owner')
    ON CONFLICT (person_id) DO NOTHING;
  v_giro := (finance.fn_create_account('{"name":"__snap_giro__","account_type":"cash","currency":"EUR","opening_balance":5000}'::jsonb)->>'account_id')::int;
  v_tg   := (finance.fn_create_account('{"name":"__snap_tg__","account_type":"cash","currency":"EUR","opening_balance":800}'::jsonb)->>'account_id')::int;
  UPDATE finance.accounts SET account_number = 'DE28500105174400000007', notes = '__snap_note_account__' WHERE id = v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__snap_closed__', 'cash', 'EUR', 'closed') RETURNING id INTO v_closed;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__snap_depot__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_depot;
  -- Alltag aus einem Auszug: -300 in 30 Tagen (Eroeffnung davor, sonst zaehlt kein Tag des Auszugs)
  UPDATE finance.accounts SET opening_balance_date = t - 60 WHERE id = v_giro;
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_giro, t - 34, t - 5, 5300, 5000, 'EUR', 5, 0, -300, 0, NULL);
  PERFORM finance.fn_add_recurring_payment(v_giro, 3000, '__snap_gehalt__', 1::smallint, 'month'::finance.schedule_unit, 1::smallint, t - 60, t - 60, NULL, NULL, NULL);
  PERFORM finance.fn_add_recurring_payment(v_giro, -1000, '__snap_miete__', 1::smallint, 'month'::finance.schedule_unit, 1::smallint, t - 60, t - 60, NULL, NULL, NULL);
  -- Dauerauftrag eigenes Konto -> eigenes Konto
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__snap_dauerauftrag__', v_giro, v_tg, -50, 'month', t + 1, t + 1);
  -- Kredite: offen + getilgt
  v_loan_open := (finance.fn_create_loan(jsonb_build_object('name', '__snap_kredit__', 'lender', 'Bank', 'original_amount', 10000,
            'current_balance', 8000, 'interest_rate', 3.5, 'monthly_annuity', 300, 'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro))->>'loan_id')::int;
  v_loan_paid := (finance.fn_create_loan(jsonb_build_object('name', '__snap_kredit_weg__', 'lender', 'Bank', 'current_balance', 700,
            'interest_rate', 4, 'monthly_annuity', 100, 'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro))->>'loan_id')::int;
  UPDATE finance.loans SET notes = '__snap_note_loan__' WHERE id = v_loan_open;
  UPDATE finance.loans SET status = 'paid_off' WHERE id = v_loan_paid;
  -- Versicherung mit Policennummer
  PERFORM finance.fn_create_insurance(jsonb_build_object('name', '__snap_haftpflicht__', 'insurance_company', 'Beispiel AG', 'annual_premium', 89,
            'first_payment_date', (t + 10)::text, 'debit_account_id', v_giro));
  UPDATE finance.insurances SET policy_number = 'POL-SNAP-0001', notes = '__snap_note_insurance__' WHERE name = '__snap_haftpflicht__';
  -- Vorsorge: aktiv mit Vertragsnummer + Renteninformation, ausgezahlt
  INSERT INTO finance.pension (name, pension_type, provider, contract_number, notes)
    VALUES ('__snap_rente__', 'statutory', 'Beispiel-Traeger', 'VERTRAG-SNAP-0001', '__snap_note_pension__') RETURNING id INTO v_pen;
  INSERT INTO finance.pension_statements (pension_id, statement_date, reached_claim, projection, regular_retirement_date, scenario_1pct, scenario_2pct, notes)
    VALUES (v_pen, t - 30, 1000, 1500, t + 7300, 1700, 2100, '__snap_note_statement__');
  INSERT INTO finance.pension (name, pension_type, status) VALUES ('__snap_rente_weg__', 'private', 'paid_out'),
                                                                  ('__snap_rente_frei__', 'private', 'paused');
  -- Immobilie: aktiv + verkauft
  PERFORM finance.fn_create_real_estate('{"name":"__snap_haus__"}'::jsonb);
  PERFORM finance.fn_create_real_estate('{"name":"__snap_haus_weg__"}'::jsonb);
  UPDATE finance.real_estate SET status = 'sold' WHERE name = '__snap_haus_weg__';
  UPDATE finance.real_estate SET notes = '__snap_note_estate__' WHERE name = '__snap_haus__';
  -- Ziele: aktiv + abgeschlossen (eine Pause kennt der Status nicht, sie steckt in der Ampel)
  INSERT INTO finance.savings_goals (name, target_amount, target_date, notes) VALUES ('__snap_ziel__', 2000, t + 300, '__snap_note_goal__') RETURNING id INTO v_g_ok;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g_ok, 'account_id', v_tg, 'amount', 500));
  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__snap_ziel_weg__', 100, t + 300) RETURNING id INTO v_g_done;
  UPDATE finance.savings_goals SET status = 'completed' WHERE id = v_g_done;
  -- Depot + Sparplaene: aktiv, pausiert, beendet (Soft-Close wie fn_close_savings_plan: pausiert + Raten-Ende erreicht)
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_depot, 'SNAP00000001', 'SNAPETF', '__snap_etf__', 10, 100, 'EUR');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('SNAPETF', 120, 'EUR', t);
  FOREACH k IN ARRAY ARRAY['__snap_plan__', '__snap_plan_pause__', '__snap_plan_weg__', '__snap_plan_weg_spaeter__'] LOOP
    PERFORM finance.fn_create_savings_plan(jsonb_build_object('name', k, 'depot_name', '__snap_depot__', 'isin', 'SNAP00000001',
              'symbol', 'SNAPETF', 'security_name', 'Snap ETF', 'amount', 100, 'schedule_interval', 1, 'schedule_unit', 'month',
              'first_payment_date', t::text));
  END LOOP;
  UPDATE finance.savings_plans SET status = 'paused' WHERE name IN ('__snap_plan_pause__', '__snap_plan_weg__', '__snap_plan_weg_spaeter__');
  UPDATE finance.recurring_payments SET valid_to = t
   WHERE id = (SELECT recurring_payment_id FROM finance.savings_plans WHERE name = '__snap_plan_weg__');
  -- geplante Aenderung in der Kette: das Raten-Ende des Kopfes liegt beim Beenden in der Zukunft (fn_end_recurring_chain)
  UPDATE finance.recurring_payments SET valid_to = t + 40
   WHERE id = (SELECT recurring_payment_id FROM finance.savings_plans WHERE name = '__snap_plan_weg_spaeter__');

  v := finance.fn_advisor_snapshot();
  v_txt := v::text;

  -- ===== 1b) Form =====
  IF (SELECT array_agg(x ORDER BY x) FROM jsonb_object_keys(v) x)
     IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(v_lists || v_objects || ARRAY['open_bank_steps']) x) THEN
    RAISE EXCEPTION 'FAIL [1b] Schluessel: %', (SELECT array_agg(x ORDER BY x) FROM jsonb_object_keys(v) x); END IF;
  FOREACH k IN ARRAY v_lists LOOP
    IF jsonb_typeof(v->k) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'FAIL [1c] % keine Liste: %', k, v->k; END IF;
  END LOOP;
  FOREACH k IN ARRAY v_objects LOOP
    IF jsonb_typeof(v->k) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'FAIL [1d] % kein Objekt: %', k, v->k; END IF;
  END LOOP;
  RAISE NOTICE 'PASS [1] Form: Schluessel, Listen, Objekte, leer = []';

  -- ===== 2) Wertgleich zu den Quellen =====
  IF v->'cashflow_summary' IS DISTINCT FROM (SELECT to_jsonb(s) FROM finance.monthly_cashflow_summary s) THEN
    RAISE EXCEPTION 'FAIL [2a] cashflow_summary: %', v->'cashflow_summary'; END IF;
  IF v->'parent_cashflow_summary' IS DISTINCT FROM (SELECT to_jsonb(s) FROM finance.parent_cashflow_summary s) THEN
    RAISE EXCEPTION 'FAIL [2b] parent_cashflow_summary: %', v->'parent_cashflow_summary'; END IF;
  IF v->'loan_summary' IS DISTINCT FROM (SELECT to_jsonb(s) FROM finance.loan_summary s) THEN
    RAISE EXCEPTION 'FAIL [2c] loan_summary: %', v->'loan_summary'; END IF;
  IF v->'emergency_reserve' IS DISTINCT FROM finance.fn_emergency_reserve_status() THEN
    RAISE EXCEPTION 'FAIL [2d] emergency_reserve: %', v->'emergency_reserve'; END IF;
  IF jsonb_array_length(v->'pension_outlook') <> 1 OR (v->'pension_outlook'->0->>'reached_claim')::numeric IS DISTINCT FROM 1000
     OR (v->'pension_outlook'->0->>'scenario_2pct')::numeric IS DISTINCT FROM 2100 THEN
    RAISE EXCEPTION 'FAIL [2e] Renteninformation wie fn_pension_outlook: %', v->'pension_outlook'; END IF;
  -- ohne Kaufkraftwerte und ohne den Satz „keine Inflationsannahme im Plan“ (der waere hier falsch: die fn bekommt die Annahme nicht)
  IF v->'pension_outlook'->0 ? 'scenario_1pct_real' OR v->'pension_outlook'->0 ? 'real_note' THEN
    RAISE EXCEPTION 'FAIL [2f] Kaufkraft-Felder oder real_note: %', v->'pension_outlook'; END IF;

  SELECT e INTO v_row FROM jsonb_array_elements(v->'accounts') e WHERE e->>'name' = '__snap_giro__';
  IF (v_row->>'balance')::numeric IS DISTINCT FROM (SELECT balance FROM finance.account_overview WHERE id = v_giro)
     OR (v_row->>'balance_eur')::numeric IS DISTINCT FROM (SELECT balance_eur FROM finance.account_overview WHERE id = v_giro) THEN
    RAISE EXCEPTION 'FAIL [2g] Kontosaldo: %', v_row; END IF;
  IF (v_row->>'everyday_per_month')::numeric IS DISTINCT FROM (SELECT everyday_per_month FROM finance.account_everyday_spending WHERE account_id = v_giro)
     OR (v_row->>'everyday_per_month') IS NULL OR (v_row->>'everyday_per_month')::numeric >= 0
     OR (v_row->>'has_history')::boolean IS DISTINCT FROM true
     OR (v_row->>'everyday_provisional')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [2h] Alltag am Konto: %', v_row; END IF;
  SELECT e INTO v_row FROM jsonb_array_elements(v->'accounts') e WHERE e->>'name' = '__snap_depot__';
  IF v_row ? 'everyday_per_month' OR v_row ? 'has_history' THEN
    RAISE EXCEPTION 'FAIL [2i] Depot traegt keine Alltagsfelder: %', v_row; END IF;

  SELECT e INTO v_row FROM jsonb_array_elements(v->'loans') e WHERE e->>'name' = '__snap_kredit__';
  IF (v_row->>'current_remaining_debt')::numeric IS DISTINCT FROM (SELECT current_remaining_debt FROM finance.loan_overview WHERE id = v_loan_open)
     OR (v_row->>'monthly_interest_current')::numeric IS DISTINCT FROM (SELECT monthly_interest_current FROM finance.loan_overview WHERE id = v_loan_open)
     OR (v_row->>'payoff_date_projected')::date IS DISTINCT FROM (SELECT payoff_date_projected FROM finance.loan_overview WHERE id = v_loan_open) THEN
    RAISE EXCEPTION 'FAIL [2j] Kredit: %', v_row; END IF;

  SELECT e INTO v_row FROM jsonb_array_elements(v->'goals') e WHERE e->>'name' = '__snap_ziel__';
  IF v_row->>'goal_status' IS DISTINCT FROM finance.fn_savings_goal_pace(v_g_ok) OR v_row->>'goal_status' IS NULL
     OR (v_row->>'current_amount')::numeric IS DISTINCT FROM 500 THEN
    RAISE EXCEPTION 'FAIL [2k] Ziel + Ampel: %', v_row; END IF;

  IF (SELECT count(*) FROM jsonb_array_elements(v->'recurring')) <> (SELECT count(*) FROM finance.monthly_cashflow_overview)
     OR (SELECT count(*) FROM jsonb_array_elements(v->'networth')) <> (SELECT count(*) FROM finance.networth_by_asset_class)
     OR (SELECT count(*) FROM jsonb_array_elements(v->'standing_orders')) <> (SELECT count(*) FROM finance.standing_order_overview)
     OR (SELECT count(*) FROM jsonb_array_elements(v->'depot_performance')) <> (SELECT count(*) FROM finance.depot_performance)
     OR (SELECT count(*) FROM jsonb_array_elements(v->'depot_holdings')) <> (SELECT count(*) FROM finance.depot_holdings_overview)
     OR (SELECT count(*) FROM jsonb_array_elements(v->'insurances')) <> (SELECT count(*) FROM finance.active_insurances)
     OR (SELECT count(*) FROM jsonb_array_elements(v->'persons')) <> (SELECT count(*) FROM core.fn_household_persons()) THEN
    RAISE EXCEPTION 'FAIL [2l] ungefilterte Listen vollstaendig'; END IF;
  -- depot_risk: genau die Ziele im Fenster aus fn_savings_goal_derisk_status, mit der Entscheidung
  IF (SELECT count(*) FROM jsonb_array_elements(v->'depot_risk')) <> (SELECT count(*) FROM finance.fn_savings_goal_derisk_status() WHERE in_window)
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v->'depot_risk') e WHERE NOT (e ? 'accepted' AND e ? 'acceptance_expired' AND e ? 'final_check_date')) THEN
    RAISE EXCEPTION 'FAIL [2r] depot_risk: %', v->'depot_risk'; END IF;

  -- Erfasstes ist nie unsichtbar. Startet es bald, steht es mit starts_on in recurring (zaehlt);
  -- startet es spaeter, steht es in planned_recurring (zaehlt noch nicht), Vertragsdaten bleiben draussen
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, notes)
    VALUES ('__snap_soon__', v_giro, 75, 'month', t + 10, t + 10, 'Notiz'),
           ('__snap_later__', v_giro, -25, 'month', t + 60, t + 60, 'Notiz');
  v := finance.fn_advisor_snapshot();
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'recurring') e WHERE e->>'name' = '__snap_soon__' AND (e->>'starts_on')::date = t + 10)
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v->'planned_recurring') e WHERE e->>'name' = '__snap_soon__')
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v->'recurring') e WHERE e->>'name' = '__snap_later__') THEN
    RAISE EXCEPTION 'FAIL [2m] bald startend gehoert in recurring: %', v->'recurring'; END IF;
  SELECT e INTO v_row FROM jsonb_array_elements(v->'planned_recurring') e WHERE e->>'name' = '__snap_later__';
  IF (v_row->>'starts_on')::date IS DISTINCT FROM t + 60 OR v_row->>'rhythm' IS NULL OR v_row ? 'notes' THEN
    RAISE EXCEPTION 'FAIL [2n] planned_recurring: %', v_row; END IF;
  IF NOT v->'standing_orders' @? '$[*] ? (@.name == "__snap_dauerauftrag__" && @.from_account == "__snap_giro__" && @.to_account == "__snap_tg__")' THEN
    RAISE EXCEPTION 'FAIL [2m] Dauerauftrag: %', v->'standing_orders'; END IF;
  RAISE NOTICE 'PASS [2] wertgleich zu den Quellen';

  -- ===== 3) Beendetes fehlt, Pausiertes bleibt =====
  -- je Bereich: Konto und Rate eines getilgten Kredits duerfen als Konto/Zahlung weiter auftauchen, der Kredit nicht
  IF (v->'accounts')::text ~ '__snap_closed__' OR (v->'loans')::text ~ '__snap_kredit_weg__' OR (v->'goals')::text ~ '__snap_ziel_weg__'
     OR (v->'pensions')::text ~ '__snap_rente_weg__' OR (v->'pension_outlook')::text ~ '__snap_rente_weg__'
     OR (v->'real_estate')::text ~ '__snap_haus_weg__' OR (v->'savings_plans')::text ~ '__snap_plan_weg' THEN
    RAISE EXCEPTION 'FAIL [3a] Beendetes im Snapshot: %', v; END IF;
  IF NOT v_txt ~ '__snap_plan__' OR NOT v->'savings_plans' @? '$[*] ? (@.name == "__snap_plan_pause__" && @.status == "paused")' THEN
    RAISE EXCEPTION 'FAIL [3b] aktiver + pausierter Sparplan bleiben: %', v->'savings_plans'; END IF;
  IF NOT v->'pensions' @? '$[*] ? (@.name == "__snap_rente_frei__" && @.status == "paused")' THEN
    RAISE EXCEPTION 'FAIL [3d] beitragsfreier Vertrag bleibt: %', v->'pensions'; END IF;
  -- ein pausierter, aber offener Kredit ist weiter Schuld
  UPDATE finance.loans SET status = 'paused' WHERE id = v_loan_open;
  IF NOT finance.fn_advisor_snapshot()->'loans' @? '$[*] ? (@.name == "__snap_kredit__")' THEN
    RAISE EXCEPTION 'FAIL [3c] pausierter Kredit fehlt'; END IF;
  UPDATE finance.loans SET status = 'active' WHERE id = v_loan_open;
  RAISE NOTICE 'PASS [3] Beendetes fehlt, Pausiertes bleibt';

  -- ===== 4) Keine Nummern, keine notes, keine technischen Spalten — befuellt, also waeren sie sonst da =====
  IF v_txt ~ '"[a-z_]*(_number|iban)"\s*:' OR v_txt ~ '"notes"\s*:' THEN
    RAISE EXCEPTION 'FAIL [4a] Nummern-/notes-Schluessel: %', v_txt; END IF;
  IF v_txt ~ '(DE28500105174400000007|POL-SNAP|VERTRAG-SNAP|__snap_note_)' THEN
    RAISE EXCEPTION 'FAIL [4b] Nummer oder Notiz als Wert: %', v_txt; END IF;
  IF v_txt ~ '"(holding_id|current_rp_id|head_rp_id|recurring_payment_id)"\s*:' THEN
    RAISE EXCEPTION 'FAIL [4c] technische Spalte: %', v_txt; END IF;
  RAISE NOTICE 'PASS [4] keine Nummern, keine notes, keine technischen Spalten';

  -- ===== 5) warnings: Unterdeckung + Spar-Deckung je Konto, Werte aus denselben fns wie Tool und App =====
  -- ohne Auszug: die festen Zahlungen allein ziehen das Konto ins Minus (Alltag kaeme nur noch dazu)
  v_low := (finance.fn_create_account('{"name":"__snap_low__","account_type":"cash","currency":"EUR","opening_balance":100}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_add_recurring_payment(v_low, -500, '__snap_low_miete__', 1::smallint, 'month'::finance.schedule_unit, NULL::smallint, t + 3, t + 3, NULL, NULL, NULL);
  PERFORM finance.fn_add_recurring_payment(v_low, 2000, '__snap_low_gehalt__', 1::smallint, 'month'::finance.schedule_unit, NULL::smallint, t + 20, t + 20, NULL, NULL, NULL);
  -- ohne Auszug nur unter dem Puffer, nicht im Minus: keine Warnung auf Halbwissen
  v_tight := (finance.fn_create_account('{"name":"__snap_tight__","account_type":"cash","currency":"EUR","opening_balance":300}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_add_recurring_payment(v_tight, -100, '__snap_tight_miete__', 1::smallint, 'month'::finance.schedule_unit, NULL::smallint, t + 3, t + 3, NULL, NULL, NULL);
  PERFORM finance.fn_add_recurring_payment(v_tight, 2000, '__snap_tight_gehalt__', 1::smallint, 'month'::finance.schedule_unit, NULL::smallint, t + 20, t + 20, NULL, NULL, NULL);
  -- mit Auszug: unter dem Puffer zaehlt schon
  v_hist := (finance.fn_create_account('{"name":"__snap_hist__","account_type":"cash","currency":"EUR","opening_balance":300}'::jsonb)->>'account_id')::int;
  UPDATE finance.accounts SET opening_balance_date = t - 60, min_balance = 1000, last_reconciled_at = t - 5 WHERE id = v_hist;
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_hist, t - 34, t - 5, 600, 300, 'EUR', 5, 0, -300, 0, NULL);
  -- Sparplan ohne Zufluss: das Geld reicht wenige Wochen; daneben ein gut gedecktes Konto
  v_fund := (finance.fn_create_account('{"name":"__snap_fund__","account_type":"cash","currency":"EUR","opening_balance":1000}'::jsonb)->>'account_id')::int;
  v_fund_ok := (finance.fn_create_account('{"name":"__snap_fund_ok__","account_type":"cash","currency":"EUR","opening_balance":100000}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, plan_execution_days)
    VALUES ('__snap_fund_depot__', 'stocks_depot', 'EUR', 'active', v_fund, '{}'),
           ('__snap_fund_ok_depot__', 'stocks_depot', 'EUR', 'active', v_fund_ok, '{}');
  PERFORM finance.fn_create_savings_plan(jsonb_build_object('name', '__snap_fund_plan__', 'depot_name', '__snap_fund_depot__', 'isin', 'SNAP00000001',
            'symbol', 'SNAPETF', 'security_name', 'Snap ETF', 'amount', 150, 'schedule_interval', 1, 'schedule_unit', 'week', 'first_payment_date', (t + 2)::text));
  PERFORM finance.fn_create_savings_plan(jsonb_build_object('name', '__snap_fund_ok_plan__', 'depot_name', '__snap_fund_ok_depot__', 'isin', 'SNAP00000001',
            'symbol', 'SNAPETF', 'security_name', 'Snap ETF', 'amount', 10, 'schedule_interval', 1, 'schedule_unit', 'week', 'first_payment_date', (t + 2)::text));
  v := finance.fn_advisor_snapshot();

  SELECT e INTO v_row FROM jsonb_array_elements(v->'warnings') e WHERE e->>'account' = '__snap_low__' AND e->>'kind' = 'account_coverage';
  IF (v_row->>'lowest_balance')::numeric IS DISTINCT FROM -400 OR (v_row->>'lowest_on')::date IS DISTINCT FROM t + 3
     OR (v_row->>'has_history')::boolean IS DISTINCT FROM false OR v_row->>'currency' IS DISTINCT FROM 'EUR' THEN
    RAISE EXCEPTION 'FAIL [5a] Minus ohne Auszug: %', v->'warnings'; END IF;
  IF v->'warnings' @? '$[*] ? (@.account == "__snap_tight__")' THEN
    RAISE EXCEPTION 'FAIL [5b] nur unter dem Puffer ohne Auszug warnt nicht: %', v->'warnings'; END IF;
  SELECT e INTO v_row FROM jsonb_array_elements(v->'warnings') e WHERE e->>'account' = '__snap_hist__' AND e->>'kind' = 'account_coverage';
  v_o := finance.fn_account_outlook(v_hist);
  IF (v_o->>'shortfall')::numeric <= 0 OR (v_row->>'lowest_balance')::numeric IS DISTINCT FROM (v_o->>'min_projected')::numeric
     OR (v_row->>'lowest_on')::date IS DISTINCT FROM (v_o->>'min_date')::date OR (v_row->>'has_history')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [5c] Unterdeckung mit Auszug wie fn_account_outlook: % / %', v_row, v_o; END IF;
  SELECT e INTO v_row FROM jsonb_array_elements(v->'warnings') e WHERE e->>'account' = '__snap_fund__' AND e->>'kind' = 'savings_funding';
  IF v_row->>'state' IS DISTINCT FROM 'alert'
     OR (v_row->>'runs_out_on')::date IS DISTINCT FROM (SELECT runs_out_on FROM finance.account_funding_overview WHERE account_id = v_fund)
     OR (v_row->>'lowest_balance')::numeric IS DISTINCT FROM (SELECT min_projected FROM finance.account_funding_overview WHERE account_id = v_fund)
     OR (v_row->>'lowest_on')::date IS DISTINCT FROM (SELECT min_date FROM finance.account_funding_overview WHERE account_id = v_fund) THEN
    RAISE EXCEPTION 'FAIL [5d] Spar-Deckung wie account_funding_overview: %', v_row; END IF;
  IF v->'warnings' @? '$[*] ? (@.account == "__snap_fund_ok__")' THEN
    RAISE EXCEPTION 'FAIL [5e] gedecktes Konto warnt nicht: %', v->'warnings'; END IF;
  -- veralteter Auszug: die Vorschau ist dann nicht belastbar, gemeldet wird der Auszug (fn_advisor_review), nicht die Unterdeckung
  UPDATE finance.accounts SET last_reconciled_at = t - 100 WHERE id = v_hist;
  IF finance.fn_advisor_snapshot()->'warnings' @? '$[*] ? (@.account == "__snap_hist__")' THEN
    RAISE EXCEPTION 'FAIL [5f] veralteter Auszug warnt nicht als Unterdeckung'; END IF;
  RAISE NOTICE 'PASS [5] warnings: Unterdeckung, Puffer-Grenze, Spar-Deckung, gedeckt, veralteter Auszug';
END $$;
ROLLBACK;
