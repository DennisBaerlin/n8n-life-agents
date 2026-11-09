-- tests/db/finance/test_account_emoji_tools.sql
-- Konto-Zeichen in den Schreib- und Lese-Pfaden: fn_set_account, fn_create_account, fn_resolve_account, Import-Vorpruefung, Berater-Snapshot.
BEGIN;
DO $$
DECLARE v_id int; r jsonb; v_rid int; v_hits int; v_lbl text;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('Probebank Giro','cash','EUR','active') RETURNING id INTO v_id;

  -- fn_set_account: setzen, VS16 bereinigt, Rueckgabe
  r := finance.fn_set_account(jsonb_build_object('account_id', v_id, 'emoji', '🐷'));
  IF NOT (r->>'ok')::boolean OR r->>'label' <> '🐷 Probebank Giro' OR r->>'emoji' <> '🐷' THEN RAISE EXCEPTION 'FAIL [set]: %', r; END IF;
  r := finance.fn_set_account(jsonb_build_object('account_id', v_id, 'emoji', '🏠' || chr(65039)));
  IF NOT (r->>'ok')::boolean OR (SELECT emoji FROM finance.accounts WHERE id = v_id) <> '🏠' THEN RAISE EXCEPTION 'FAIL [VS16 bereinigt]: %', r; END IF;

  -- unveraendert ohne Feld
  r := finance.fn_set_account(jsonb_build_object('account_id', v_id, 'bank', 'Probebank'));
  IF (SELECT emoji FROM finance.accounts WHERE id = v_id) <> '🏠' THEN RAISE EXCEPTION 'FAIL [ohne Feld unveraendert]'; END IF;

  -- Standard, Konflikt, fremdes Zeichen
  r := finance.fn_set_account(jsonb_build_object('account_id', v_id, 'emoji', '🐷', 'emoji_default', 'true'));
  IF (r->>'ok')::boolean OR r->>'code' <> 'conflicting_input' THEN RAISE EXCEPTION 'FAIL [Konflikt]: %', r; END IF;
  r := finance.fn_set_account(jsonb_build_object('account_id', v_id, 'emoji', '🦄'));
  IF (r->>'ok')::boolean OR r->>'code' <> 'invalid_emoji' OR position('🐷' IN r->>'reason') = 0 THEN RAISE EXCEPTION 'FAIL [invalid_emoji mit Liste]: %', r; END IF;
  IF (SELECT emoji FROM finance.accounts WHERE id = v_id) <> '🏠' THEN RAISE EXCEPTION 'FAIL [invalid schreibt nicht]'; END IF;
  r := finance.fn_set_account(jsonb_build_object('account_id', v_id, 'emoji_default', 'true'));
  IF NOT (r->>'ok')::boolean OR (SELECT emoji FROM finance.accounts WHERE id = v_id) IS NOT NULL OR r->>'label' <> '🏦 Probebank Giro' THEN RAISE EXCEPTION 'FAIL [Standard]: %', r; END IF;

  -- Zeichen im Namen
  r := finance.fn_set_account(jsonb_build_object('account_id', v_id, 'name', '🐷 Sparen'));
  IF (r->>'ok')::boolean OR r->>'code' <> 'emoji_in_name' THEN RAISE EXCEPTION 'FAIL [set emoji_in_name]: %', r; END IF;
  r := finance.fn_set_account(jsonb_build_object('account_id', v_id, 'name', '🐷' || chr(65039) || ' Sparen'));
  IF (r->>'ok')::boolean OR r->>'code' <> 'emoji_in_name' THEN RAISE EXCEPTION 'FAIL [set emoji_in_name VS16]: %', r; END IF;
  r := finance.fn_set_account(jsonb_build_object('account_id', v_id, 'name', 'Sparen 🐷 Topf'));
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [Zeichen mitten im Namen erlaubt]: %', r; END IF;
  r := finance.fn_set_account(jsonb_build_object('account_id', v_id, 'name', 'Probebank Giro'));

  -- fn_create_account: ohne, mit, VS16, fremd, im Namen vor Dublette
  r := finance.fn_create_account(jsonb_build_object('name', 'Probe Tagesgeld', 'account_type', 'cash'));
  IF NOT (r->>'ok')::boolean OR r->>'emoji' <> '🏦' OR r->>'label' <> '🏦 Probe Tagesgeld'
     OR (SELECT emoji FROM finance.accounts WHERE id = (r->>'account_id')::int) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [create ohne]: %', r; END IF;
  r := finance.fn_create_account(jsonb_build_object('name', 'Probe Urlaub', 'account_type', 'cash', 'emoji', '🌴' || chr(65039)));
  IF NOT (r->>'ok')::boolean OR r->>'emoji' <> '🌴' OR (SELECT emoji FROM finance.accounts WHERE id = (r->>'account_id')::int) <> '🌴' THEN RAISE EXCEPTION 'FAIL [create mit]: %', r; END IF;
  r := finance.fn_create_account(jsonb_build_object('name', 'Probe Fremd', 'account_type', 'cash', 'emoji', '🦄'));
  IF (r->>'ok')::boolean OR r->>'code' <> 'invalid_emoji' THEN RAISE EXCEPTION 'FAIL [create invalid]: %', r; END IF;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('🐷 Altname','cash','EUR','active');
  r := finance.fn_create_account(jsonb_build_object('name', '🐷 Altname', 'account_type', 'cash'));
  IF (r->>'ok')::boolean OR r->>'code' <> 'emoji_in_name' THEN RAISE EXCEPTION 'FAIL [emoji_in_name vor duplicate_name]: %', r; END IF;

  -- fn_resolve_account: label, dritter Durchgang, Candidates
  SELECT id, hit_count, label INTO v_rid, v_hits, v_lbl FROM finance.fn_resolve_account('Probebank Giro');
  IF v_rid <> v_id OR v_lbl <> '🏦 Probebank Giro' THEN RAISE EXCEPTION 'FAIL [resolve label]: %', v_lbl; END IF;
  SELECT id, hit_count INTO v_rid, v_hits FROM finance.fn_resolve_account('🏦 Probebank Giro');
  IF v_rid IS DISTINCT FROM v_id THEN RAISE EXCEPTION 'FAIL [resolve mit Zeichen]: %/%', v_rid, v_hits; END IF;
  SELECT id INTO v_rid FROM finance.fn_resolve_account('🏦' || chr(65039) || ' Probebank Giro');
  IF v_rid IS DISTINCT FROM v_id THEN RAISE EXCEPTION 'FAIL [resolve mit Zeichen und VS16]'; END IF;
  SELECT hit_count INTO v_hits FROM finance.fn_resolve_account('🦄 Probebank Giro');
  IF v_hits <> 0 THEN RAISE EXCEPTION 'FAIL [fremdes Zeichen wird nicht abgeschnitten]'; END IF;
  SELECT id INTO v_rid FROM finance.fn_resolve_account('🐷 Altname');
  IF v_rid IS NULL THEN RAISE EXCEPTION 'FAIL [Bestandsname mit Zeichen exakt]'; END IF;
  IF (SELECT candidates->0->>'label' FROM finance.fn_resolve_account('Probebank Giro')) <> '🏦 Probebank Giro' THEN RAISE EXCEPTION 'FAIL [candidates label]'; END IF;

  -- Berater-Snapshot traegt label
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(finance.fn_advisor_snapshot()->'accounts') x WHERE x->>'name' = 'Probebank Giro' AND x->>'label' = '🏦 Probebank Giro') THEN
    RAISE EXCEPTION 'FAIL [snapshot label]'; END IF;

  -- Import-Vorpruefung: Zeile mit Zeichen im Namen scheitert vor der Sammelkarte
  v_lbl := finance.fn_import_validate_row(gen_random_uuid(), 1, 'account', '{"name":"🐷 Importkonto","account_type":"cash"}'::jsonb);
  IF v_lbl IS NULL OR position('sign' IN v_lbl) = 0 THEN RAISE EXCEPTION 'FAIL [import emoji_in_name]: %', v_lbl; END IF;
END $$;

-- Lese-Spalten der Views: Zeichen + Name je Bereich
DO $$
DECLARE v_c int; v_d int; v_rp int;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status, emoji) VALUES ('Probe Quelle','cash','EUR','active','🛒') RETURNING id INTO v_c;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('Probe Ziel','cash','EUR','active') RETURNING id INTO v_d;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
    VALUES ('Probe Auftrag', v_c, v_d, -50, 'month', 5, core.fn_today() + 10, core.fn_today() + 10) RETURNING id INTO v_rp;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
    VALUES ('Probe Miete', v_c, -70, 'month', 5, core.fn_today() - 40, core.fn_today() - 40);
  IF (SELECT from_account_label FROM finance.standing_order_overview WHERE recurring_payment_id = v_rp) <> '🛒 Probe Quelle' THEN RAISE EXCEPTION 'FAIL [standing_order label]'; END IF;
  IF (SELECT account_label FROM finance.monthly_cashflow_overview WHERE name = 'Probe Miete') <> '🛒 Probe Quelle' THEN RAISE EXCEPTION 'FAIL [cashflow label]'; END IF;
  PERFORM from_label FROM (SELECT settlement_account_label AS from_label FROM finance.savings_plan_overview LIMIT 0) s;
  PERFORM loan_account_label FROM finance.loan_overview LIMIT 0;
  PERFORM account_label FROM finance.savings_goal_account_share LIMIT 0;
END $$;
ROLLBACK;
