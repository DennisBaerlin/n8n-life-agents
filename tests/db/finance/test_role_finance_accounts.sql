-- tests/db/finance/test_role_finance_accounts.sql
-- Rollen-Perspektive der Konto-Werkzeuge: fn_close_account, fn_delete_account, fn_set_account_interest,
--   fn_skip_interest_occurrence, fn_reconcile_account, fn_reconcile_accounts (Write; Probelauf ueber core.fn_dry_run
--   und echter Write) sowie fn_resolve_account, fn_get_account_close_blockers, fn_account_interest_defaults,
--   fn_interest_rate_preview, fn_get_balance_as_of, fn_reconcile_accounts_preview, fn_reconcile_blocker,
--   fn_reconcile_open_due (Lesen) laufen unter finance_rw. Fixture (Konten, Buchungen, Zinszeilen) legt der Superuser
--   an; zwischen SET LOCAL ROLE und RESET ROLE steht nur der Aufruf unter Test. Geprueft wird die echte Wirkung
--   (Zeile/Status/Betrag), nicht nur "kein Fehler" -- fehlende Tabellen-/Sequenz-/EXECUTE-Rechte der Rolle brechen den Block.
BEGIN;

-- ---------- fn_close_account + fn_get_account_close_blockers + fn_resolve_account ----------
DO $$
DECLARE
  r      jsonb;
  v_a    int;   -- leeres Konto -> schliessbar
  v_b    int;   -- Konto mit Guthaben -> Blocker
  v_id   int;
  v_hits int;
  v_ccy  text;
  v_lbl  text;
BEGIN
  v_a := (finance.fn_create_account('{"name":"Rolle Girokonto Erika","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_b := (finance.fn_create_account('{"name":"Rolle Sparkonto Max","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
  VALUES (v_b, 50, DATE '2026-01-05', 'other', 'Rolle Einlage');

  -- fn_resolve_account: eindeutiger Treffer mit id, Waehrung, Anzeigename
  SET LOCAL ROLE finance_rw;
  SELECT x.id, x.hit_count, x.currency, x.label INTO v_id, v_hits, v_ccy, v_lbl
  FROM finance.fn_resolve_account('Rolle Girokonto Erika', NULL, TRUE) x;
  RESET ROLE;
  IF v_id IS DISTINCT FROM v_a OR v_hits <> 1 OR v_ccy IS DISTINCT FROM 'EUR' OR v_lbl IS NULL THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_account finance_rw]: id=% hits=% ccy=% label=%', v_id, v_hits, v_ccy, v_lbl; END IF;

  -- fn_get_account_close_blockers: leeres Konto frei, Konto mit 50 EUR Guthaben blockiert (kind balance)
  SET LOCAL ROLE finance_rw;
  r := finance.fn_get_account_close_blockers(v_a);
  RESET ROLE;
  IF (r->>'blocked')::boolean IS NOT FALSE OR jsonb_array_length(r->'blockers') <> 0 THEN
    RAISE EXCEPTION 'FAIL [fn_get_account_close_blockers leer finance_rw]: %', r; END IF;
  SET LOCAL ROLE finance_rw;
  r := finance.fn_get_account_close_blockers(v_b);
  RESET ROLE;
  IF (r->>'blocked')::boolean IS NOT TRUE OR r->'blockers'->0->>'kind' <> 'balance'
     OR (r->'blockers'->0->>'balance')::numeric <> 50 THEN
    RAISE EXCEPTION 'FAIL [fn_get_account_close_blockers Guthaben finance_rw]: %', r; END IF;

  -- fn_close_account: Probelauf laesst das Konto aktiv ...
  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_close_account(jsonb)'::regprocedure,
         jsonb_build_object('account_id', v_a, 'closure_date', '2026-11-01', 'notes', 'Rolle Test'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status FROM finance.accounts WHERE id = v_a)::text <> 'active' THEN
    RAISE EXCEPTION 'FAIL [fn_close_account Probelauf finance_rw]: %', r; END IF;
  -- ... der echte Write setzt status=closed und haengt den Schliess-Vermerk an
  SET LOCAL ROLE finance_rw;
  r := finance.fn_close_account(jsonb_build_object('account_id', v_a, 'closure_date', '2026-11-01', 'notes', 'Rolle Test'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'account_id')::int <> v_a
     OR NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_a AND status = 'closed'
                      AND notes LIKE '%[Geschlossen 2026-11-01: Rolle Test]%') THEN
    RAISE EXCEPTION 'FAIL [fn_close_account Write finance_rw]: %', r; END IF;
  -- Konto mit Guthaben: korrigierbare Ablehnung ohne Write
  SET LOCAL ROLE finance_rw;
  r := finance.fn_close_account(jsonb_build_object('account_id', v_b, 'closure_date', '2026-11-01'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT FALSE OR r->'blockers'->0->>'kind' <> 'balance'
     OR (SELECT status FROM finance.accounts WHERE id = v_b)::text <> 'active' THEN
    RAISE EXCEPTION 'FAIL [fn_close_account Blocker finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS test_role_finance_accounts [close_account + close_blockers + resolve_account]';
END $$;

-- ---------- fn_delete_account ----------
DO $$
DECLARE
  r   jsonb;
  v_a int;
BEGIN
  v_a := (finance.fn_create_account('{"name":"Rolle Fehlanlage Erika","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_delete_account(jsonb)'::regprocedure, jsonb_build_object('account_name', 'Rolle Fehlanlage Erika'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_a)
     OR NOT EXISTS (SELECT 1 FROM finance.account_balances WHERE account_id = v_a) THEN
    RAISE EXCEPTION 'FAIL [fn_delete_account Probelauf finance_rw]: %', r; END IF;

  -- echter Write loescht Konto und Saldo-Zeile (kein CASCADE auf account_balances)
  SET LOCAL ROLE finance_rw;
  r := finance.fn_delete_account(jsonb_build_object('account_name', 'Rolle Fehlanlage Erika'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' <> 'deleted' OR (r->>'account_id')::int <> v_a
     OR EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_a)
     OR EXISTS (SELECT 1 FROM finance.account_balances WHERE account_id = v_a) THEN
    RAISE EXCEPTION 'FAIL [fn_delete_account Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS test_role_finance_accounts [delete_account]';
END $$;

-- ---------- fn_set_account_interest + fn_interest_rate_preview + fn_account_interest_defaults ----------
DO $$
DECLARE
  r   jsonb;
  v_a int;
BEGIN
  v_a := (finance.fn_create_account('{"name":"Rolle Zinskonto Erika","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;

  -- fn_account_interest_defaults: Kadenz Monatsende, erste Gutschrift aus dem Raster (Karte zeigt sie)
  SET LOCAL ROLE finance_rw;
  r := finance.fn_account_interest_defaults('{"account_type":"cash","interest_credit_unit":"month","interest_credit_day_of_month":"-1","interest_valid_from":"2026-10-24"}'::jsonb);
  RESET ROLE;
  IF r->>'unit' <> 'month' OR (r->>'dom')::int <> -1 OR r->>'first_period_end' <> '2026-10-31'
     OR r->>'conv_reason' <> 'default_cash' THEN
    RAISE EXCEPTION 'FAIL [fn_account_interest_defaults finance_rw]: %', r; END IF;

  -- fn_interest_rate_preview: Konto ohne offene Zeile -> neue Zeile, schliesst nichts
  SET LOCAL ROLE finance_rw;
  r := finance.fn_interest_rate_preview(jsonb_build_object('account_id', v_a, 'annual_rate', 2.0,
         'schedule_unit', 'year', 'valid_from', '2026-01-01'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'closes_previous')::boolean IS NOT FALSE
     OR r->>'schedule_unit' <> 'year' OR r->>'valid_from' <> '2026-01-01' THEN
    RAISE EXCEPTION 'FAIL [fn_interest_rate_preview ohne offene Zeile finance_rw]: %', r; END IF;

  -- fn_set_account_interest: erste Zeile (Probelauf schreibt nichts, Write legt sie an)
  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_set_account_interest(jsonb)'::regprocedure,
         jsonb_build_object('account_id', v_a, 'annual_rate', 2.0, 'schedule_unit', 'year', 'valid_from', '2026-01-01'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR EXISTS (SELECT 1 FROM finance.account_interest_rates WHERE account_id = v_a) THEN
    RAISE EXCEPTION 'FAIL [fn_set_account_interest Probelauf finance_rw]: %', r; END IF;
  SET LOCAL ROLE finance_rw;
  r := finance.fn_set_account_interest(jsonb_build_object('account_id', v_a, 'annual_rate', 2.0,
         'schedule_unit', 'year', 'valid_from', '2026-01-01'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'closed_previous')::boolean IS NOT FALSE
     OR NOT EXISTS (SELECT 1 FROM finance.account_interest_rates
                    WHERE account_id = v_a AND annual_rate = 2.0 AND valid_from = DATE '2026-01-01' AND valid_to IS NULL) THEN
    RAISE EXCEPTION 'FAIL [fn_set_account_interest erste Zeile finance_rw]: %', r; END IF;

  -- Preview auf offener Zeile: schliesst sie, erbt die Jahres-Kadenz
  SET LOCAL ROLE finance_rw;
  r := finance.fn_interest_rate_preview(jsonb_build_object('account_id', v_a, 'annual_rate', 3.5, 'valid_from', '2026-07-01'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'closes_previous')::boolean IS NOT TRUE
     OR r->>'schedule_unit' <> 'year' OR r->>'day_count_convention' IS NULL THEN
    RAISE EXCEPTION 'FAIL [fn_interest_rate_preview mit offener Zeile finance_rw]: %', r; END IF;

  -- Folge-Satz: alte Zeile bekommt valid_to, genau eine neue ist offen
  SET LOCAL ROLE finance_rw;
  r := finance.fn_set_account_interest(jsonb_build_object('account_id', v_a, 'annual_rate', 3.5, 'valid_from', '2026-07-01'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'closed_previous')::boolean IS NOT TRUE
     OR NOT EXISTS (SELECT 1 FROM finance.account_interest_rates
                    WHERE account_id = v_a AND annual_rate = 2.0 AND valid_to = DATE '2026-07-01')
     OR (SELECT count(*) FROM finance.account_interest_rates WHERE account_id = v_a AND valid_to IS NULL AND annual_rate = 3.5) <> 1 THEN
    RAISE EXCEPTION 'FAIL [fn_set_account_interest Folge-Satz finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS test_role_finance_accounts [set_account_interest + interest_rate_preview + account_interest_defaults]';
END $$;

-- ---------- fn_skip_interest_occurrence ----------
DO $$
DECLARE
  r   jsonb;
  v_a int;
BEGIN
  v_a := (finance.fn_create_account('{"name":"Rolle Zins-Skip Max","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_skip_interest_occurrence(jsonb_build_object('account_id', v_a, 'period_end', '2026-02-01'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT count(*) FROM finance.interest_skips WHERE account_id = v_a AND period_end = DATE '2026-02-01') <> 1 THEN
    RAISE EXCEPTION 'FAIL [fn_skip_interest_occurrence Write finance_rw]: %', r; END IF;
  -- idempotent: zweiter Aufruf legt keine zweite Zeile an
  SET LOCAL ROLE finance_rw;
  r := finance.fn_skip_interest_occurrence(jsonb_build_object('account_id', v_a, 'period_end', '2026-02-01'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT count(*) FROM finance.interest_skips WHERE account_id = v_a) <> 1 THEN
    RAISE EXCEPTION 'FAIL [fn_skip_interest_occurrence idempotent finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS test_role_finance_accounts [skip_interest_occurrence]';
END $$;

-- ---------- fn_get_balance_as_of ----------
DO $$
DECLARE
  v_a   int;
  v_bal numeric;
BEGIN
  v_a := (finance.fn_create_account('{"name":"Rolle Stichtag Erika","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description) VALUES
    (v_a, 1000, DATE '2026-01-10', 'other', 'Rolle Einlage'),
    (v_a,  300, DATE '2026-02-10', 'other', 'Rolle spaetere Buchung');

  -- Saldo zum 15.01. ohne die spaetere Buchung
  SET LOCAL ROLE finance_rw;
  v_bal := finance.fn_get_balance_as_of(v_a, DATE '2026-01-15');
  RESET ROLE;
  IF v_bal IS DISTINCT FROM 1000 THEN RAISE EXCEPTION 'FAIL [fn_get_balance_as_of 15.01. finance_rw]: %', v_bal; END IF;
  -- eine Buchung am Stichtag zaehlt mit
  SET LOCAL ROLE finance_rw;
  v_bal := finance.fn_get_balance_as_of(v_a, DATE '2026-02-10');
  RESET ROLE;
  IF v_bal IS DISTINCT FROM 1300 THEN RAISE EXCEPTION 'FAIL [fn_get_balance_as_of 10.02. finance_rw]: %', v_bal; END IF;
  RAISE NOTICE 'PASS test_role_finance_accounts [get_balance_as_of]';
END $$;

-- ---------- fn_reconcile_blocker + fn_reconcile_account ----------
DO $$
DECLARE
  r       jsonb;
  v_a     int;
  v_today date := core.fn_today();
  v_txt   text;
BEGIN
  v_a := (finance.fn_create_account('{"name":"Rolle Abgleich Erika","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
  VALUES (v_a, 1000, DATE '2026-01-10', 'other', 'Rolle Einlage');

  -- fn_reconcile_blocker: heute abgleichbar (NULL), Stichtag in der Zukunft abgelehnt
  SET LOCAL ROLE finance_rw;
  v_txt := finance.fn_reconcile_blocker(v_a, v_today);
  RESET ROLE;
  IF v_txt IS NOT NULL THEN RAISE EXCEPTION 'FAIL [fn_reconcile_blocker heute finance_rw]: %', v_txt; END IF;
  SET LOCAL ROLE finance_rw;
  v_txt := finance.fn_reconcile_blocker(v_a, v_today + 5);
  RESET ROLE;
  IF v_txt IS NULL OR v_txt NOT ILIKE '%in the future%' THEN
    RAISE EXCEPTION 'FAIL [fn_reconcile_blocker Zukunft finance_rw]: %', v_txt; END IF;

  -- fn_reconcile_account: Probelauf ohne Wirkung ...
  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_reconcile_account(jsonb)'::regprocedure,
         jsonb_build_object('account_id', v_a, 'confirmed_balance', 1020, 'reconciliation_date', to_char(v_today, 'YYYY-MM-DD')));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'difference')::numeric <> 20
     OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_a AND category = 'reconciliation') THEN
    RAISE EXCEPTION 'FAIL [fn_reconcile_account Probelauf finance_rw]: %', r; END IF;
  -- ... Write: Korrekturbuchung +20, Saldo 1020, last_reconciled_* gesetzt
  SET LOCAL ROLE finance_rw;
  r := finance.fn_reconcile_account(jsonb_build_object('account_id', v_a, 'confirmed_balance', 1020,
         'reconciliation_date', to_char(v_today, 'YYYY-MM-DD'), 'notes', 'Rolle Zinsgutschrift'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'db_balance_before')::numeric <> 1000 OR (r->>'difference')::numeric <> 20
     OR (r->>'balance_after')::numeric <> 1020 OR r->>'reconciliation_tx_id' IS NULL
     OR NOT EXISTS (SELECT 1 FROM finance.transactions WHERE id = (r->>'reconciliation_tx_id')::int
                      AND account_id = v_a AND amount = 20 AND category = 'reconciliation' AND transaction_date = v_today)
     OR (SELECT balance FROM finance.account_balances WHERE account_id = v_a) <> 1020
     OR NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_a AND last_reconciled_balance = 1020 AND last_reconciled_at = v_today) THEN
    RAISE EXCEPTION 'FAIL [fn_reconcile_account Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS test_role_finance_accounts [reconcile_blocker + reconcile_account]';
END $$;

-- ---------- fn_reconcile_accounts_preview + fn_reconcile_accounts ----------
DO $$
DECLARE
  r       jsonb;
  p       jsonb;
  v_e     int;
  v_m     int;
  v_today date := core.fn_today();
BEGIN
  v_e := (finance.fn_create_account('{"name":"Rolle Batch Erika","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_m := (finance.fn_create_account('{"name":"Rolle Batch Max","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description) VALUES
    (v_e, 500, DATE '2026-01-10', 'other', 'Rolle Einlage'),
    (v_m, 200, DATE '2026-01-10', 'other', 'Rolle Einlage');
  p := jsonb_build_object('accounts', jsonb_build_array(
         jsonb_build_object('account_name', 'Rolle Batch Erika', 'confirmed_balance', 520, 'reconciliation_date', to_char(v_today, 'YYYY-MM-DD')),
         jsonb_build_object('account_name', 'Rolle Batch Max',   'confirmed_balance', 150, 'reconciliation_date', to_char(v_today, 'YYYY-MM-DD'))));

  -- Vorschau: Differenzen +20 / -50, nichts geschrieben
  SET LOCAL ROLE finance_rw;
  r := finance.fn_reconcile_accounts_preview(p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'n')::int <> 2
     OR (r->'rows'->0->>'db_balance')::numeric <> 500 OR (r->'rows'->0->>'diff')::numeric <> 20
     OR (r->'rows'->1->>'db_balance')::numeric <> 200 OR (r->'rows'->1->>'diff')::numeric <> -50
     OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id IN (v_e, v_m) AND category = 'reconciliation') THEN
    RAISE EXCEPTION 'FAIL [fn_reconcile_accounts_preview finance_rw]: %', r; END IF;

  -- Batch: Probelauf ohne Wirkung ...
  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_reconcile_accounts(jsonb)'::regprocedure, p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'count')::int <> 2
     OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id IN (v_e, v_m) AND category = 'reconciliation') THEN
    RAISE EXCEPTION 'FAIL [fn_reconcile_accounts Probelauf finance_rw]: %', r; END IF;
  -- ... Write: je Konto eine Korrekturbuchung (+20 / -50), Salden 520 / 150
  SET LOCAL ROLE finance_rw;
  r := finance.fn_reconcile_accounts(p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'count')::int <> 2
     OR NOT EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_e AND category = 'reconciliation' AND amount = 20)
     OR NOT EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_m AND category = 'reconciliation' AND amount = -50)
     OR (SELECT balance FROM finance.account_balances WHERE account_id = v_e) <> 520
     OR (SELECT balance FROM finance.account_balances WHERE account_id = v_m) <> 150
     OR (SELECT count(*) FROM finance.accounts WHERE id IN (v_e, v_m) AND last_reconciled_at = v_today) <> 2 THEN
    RAISE EXCEPTION 'FAIL [fn_reconcile_accounts Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS test_role_finance_accounts [reconcile_accounts_preview + reconcile_accounts]';
END $$;

-- ---------- fn_reconcile_open_due ----------
-- Zins-Vorkommen value_date 2026-02-01 liegt beim Stichtag 2026-02-11 genau 10 Tage zurueck (erledigt); ein
-- Dauerauftrag mit Faelligkeit weit vor dem Stichtag zaehlt ebenfalls (Quelle = dieses Konto).
DO $$
DECLARE
  v_a  int;
  v_rp int;
  v_n  int;
BEGIN
  v_a := (finance.fn_create_account('{"name":"Rolle Offen Erika","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.account_interest_rates (account_id, annual_rate, schedule_interval, schedule_unit, day_count_convention, valid_from)
  VALUES (v_a, 4, 1, 'month', 'ACT/365', DATE '2026-01-01');
  v_rp := (finance.fn_create_recurring_payment(jsonb_build_object('name', 'Rolle Abo', 'direction', 'expense', 'amount', 10,
            'account_id', v_a, 'schedule_unit', 'month', 'first_payment_date', to_char(CURRENT_DATE - 40, 'YYYY-MM-DD')))->>'recurring_payment_id')::int;
  UPDATE finance.recurring_payments SET valid_from = CURRENT_DATE - 40 WHERE id = v_rp;

  SET LOCAL ROLE finance_rw;
  SELECT count(*) INTO v_n FROM finance.fn_reconcile_open_due(v_a, DATE '2026-02-11') o WHERE o.interest_period_end = DATE '2026-02-01';
  RESET ROLE;
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL [fn_reconcile_open_due Zins finance_rw]: Zins-Vorkommen 2026-02-01 x%', v_n; END IF;

  SET LOCAL ROLE finance_rw;
  SELECT count(*) INTO v_n FROM finance.fn_reconcile_open_due(v_a, core.fn_today()) o WHERE o.recurring_payment_id = v_rp;
  RESET ROLE;
  IF v_n < 1 THEN RAISE EXCEPTION 'FAIL [fn_reconcile_open_due Dauerauftrag finance_rw]: kein offenes Vorkommen'; END IF;
  RAISE NOTICE 'PASS test_role_finance_accounts [reconcile_open_due]';
END $$;

ROLLBACK;
