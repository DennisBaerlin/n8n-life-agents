-- tests/db/finance/test_role_finance_import_setup.sql
-- Rollen-Perspektive der Import-/Ersteinrichtungs-Werkzeuge unter finance_rw (Fixture und Assertions als Superuser,
--   zwischen SET LOCAL ROLE und RESET ROLE nur der Aufruf der fn unter Test):
--   fn_import_update_row (tool_update_staging_row), fn_import_sweep (cron_refresh_fx_rates), fn_import_bundle
--   (tool_commit_import: Probelauf dry_run + Commit), fn_setup_next / fn_setup_advance / fn_setup_reanchor
--   (tool_import_setup; reanchor mit Probelauf ueber core.fn_dry_run), fn_cancel_handoff_task
--   (Probelauf ueber core.fn_dry_run, dropped und done_elsewhere; agent.handoff_tasks nur ueber das DEFINER-Fenster).
BEGIN;

-- ---------- fn_import_update_row: Key-Merge + Revalidate ----------
DO $$
DECLARE
  r      jsonb;
  v_b    uuid;
BEGIN
  r := finance.fn_import_stage(jsonb_build_object('source', 'chat', 'rows', jsonb_build_array(
         jsonb_build_object('entity_type', 'account', 'name', '__rt_imp_upd', 'account_type', 'cash'))));
  IF (r->>'valid')::int IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL [update_row Fixture]: %', r; END IF;
  v_b := (r->>'batch_id')::uuid;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_import_update_row(jsonb_build_object('batch_id', v_b, 'row_no', 1,
         'payload_merge', jsonb_build_object('bank', 'Lindenbank', 'opening_balance', '1.234,50')));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'valid' OR (r->>'valid')::int <> 1 OR (r->>'invalid')::int <> 0
     OR (SELECT payload->>'bank' FROM finance.import_staging WHERE batch_id = v_b AND row_no = 1) IS DISTINCT FROM 'Lindenbank'
     OR (SELECT (payload->>'opening_balance')::numeric FROM finance.import_staging WHERE batch_id = v_b AND row_no = 1) IS DISTINCT FROM 1234.50
     THEN RAISE EXCEPTION 'FAIL [update_row Merge finance_rw]: %', r; END IF;

  -- Zeile entfernen (delete_row) leert den Batch
  SET LOCAL ROLE finance_rw;
  r := finance.fn_import_update_row(jsonb_build_object('batch_id', v_b, 'row_no', 1, 'delete_row', true));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'deleted_row')::int <> 1
     OR EXISTS (SELECT 1 FROM finance.import_staging WHERE batch_id = v_b) THEN RAISE EXCEPTION 'FAIL [update_row delete_row finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS test_role_finance_import_setup [fn_import_update_row]';
END $$;

-- ---------- fn_import_sweep: verfallene Zeilen weg, frische und committete bleiben ----------
DO $$
DECLARE
  v_old   uuid := gen_random_uuid();
  v_fresh uuid := gen_random_uuid();
  v_done  uuid := gen_random_uuid();
  v_n     int;
BEGIN
  INSERT INTO finance.import_staging (batch_id, row_no, entity_type, status, created_at) VALUES
    (v_old,   1, 'account', 'staged',    now() - interval '10 days'),
    (v_old,   2, 'account', 'valid',     now() - interval '10 days'),
    (v_fresh, 1, 'account', 'staged',    now() - interval '1 day'),
    (v_done,  1, 'account', 'committed', now() - interval '10 days');

  SET LOCAL ROLE finance_rw;
  v_n := finance.fn_import_sweep(7);
  RESET ROLE;
  IF v_n < 2 OR EXISTS (SELECT 1 FROM finance.import_staging WHERE batch_id = v_old)
     OR (SELECT count(*) FROM finance.import_staging WHERE batch_id = v_fresh) <> 1
     OR (SELECT count(*) FROM finance.import_staging WHERE batch_id = v_done) <> 1
     THEN RAISE EXCEPTION 'FAIL [fn_import_sweep finance_rw]: % geloescht', v_n; END IF;
  RAISE NOTICE 'PASS test_role_finance_import_setup [fn_import_sweep]';
END $$;

-- ---------- fn_import_bundle: Probelauf (zurueckgerollt) und Commit ----------
DO $$
DECLARE
  r      jsonb;
  v_b    uuid;
BEGIN
  r := finance.fn_import_stage(jsonb_build_object('source', 'chat', 'rows', jsonb_build_array(
         jsonb_build_object('entity_type', 'account', 'name', '__rt_imp_bundle', 'account_type', 'cash',
                            'bank', 'Lindenbank', 'opening_balance', 1000))));
  IF (r->>'valid')::int IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL [bundle Fixture]: %', r; END IF;
  v_b := (r->>'batch_id')::uuid;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_import_bundle(jsonb_build_object('batch_id', v_b, 'dry_run', true));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'dry_run')::boolean IS NOT TRUE
     OR EXISTS (SELECT 1 FROM finance.accounts WHERE name = '__rt_imp_bundle')
     OR (SELECT status FROM finance.import_staging WHERE batch_id = v_b AND row_no = 1) <> 'valid'
     THEN RAISE EXCEPTION 'FAIL [fn_import_bundle Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_import_bundle(jsonb_build_object('batch_id', v_b));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'committed')::int <> 1
     OR (SELECT (e->>'balance')::numeric FROM jsonb_array_elements(r->'created') e WHERE e->>'entity_type' = 'account') IS DISTINCT FROM 1000
     OR (SELECT b.balance FROM finance.account_balances b JOIN finance.accounts a ON a.id = b.account_id WHERE a.name = '__rt_imp_bundle') IS DISTINCT FROM 1000.00
     OR (SELECT status FROM finance.import_staging WHERE batch_id = v_b AND row_no = 1) <> 'committed'
     THEN RAISE EXCEPTION 'FAIL [fn_import_bundle Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS test_role_finance_import_setup [fn_import_bundle Konto]';
END $$;

-- ---------- fn_setup_next / fn_setup_advance / fn_setup_reanchor: Konto mit spaetem Stand, Datei mit gedrucktem Stand ----------
DO $$
DECLARE
  ps     date := date_trunc('month', CURRENT_DATE - 45)::date;
  pe     date := (date_trunc('month', CURRENT_DATE - 45) + interval '1 month - 1 day')::date;
  v_tbl  jsonb;
  r      jsonb;
  v_acct int;
BEGIN
  v_tbl := jsonb_build_object('rows', jsonb_build_array(
      jsonb_build_array('Test Person', '', '', 'Summary', ''),
      jsonb_build_array(to_char(ps, 'FMMM/FMDD/YYYY') || '-' || to_char(pe, 'FMMM/FMDD/YYYY'), '', '', 'Opening', '100'),
      jsonb_build_array('', '', '', 'Payments in', '5'),
      jsonb_build_array('', '', '', 'Payments out', '0'),
      jsonb_build_array('', '', '', 'Closing', '105'),
      jsonb_build_array(), jsonb_build_array('All Goals'),
      jsonb_build_array('Date', 'Payment type', 'In', 'Out', 'Balance'),
      jsonb_build_array(to_char(ps, 'FMMM/FMDD/YYYY'), 'Go & Grow returns', '2', '', '102'),
      jsonb_build_array(to_char(ps + 3, 'FMMM/FMDD/YYYY'), 'Go & Grow returns', '3', '', '105')));
  -- Konto mit dem Endstand der Datei als Eroeffnung heute: die Datei braeuchte einen frueheren Start (Schritt reanchor)
  v_acct := (finance.fn_create_account(jsonb_build_object('name', '__rt_setup_bd', 'account_type', 'p2p', 'bank', 'Bondora',
              'currency', 'EUR', 'opening_balance', 105))->>'account_id')::int;
  r := finance.fn_setup_begin(jsonb_build_object('chat_id', '__rt_su1', 'file_id', 'f1', 'table', v_tbl));
  IF r->>'phase' <> 'reanchor' THEN RAISE EXCEPTION 'FAIL [setup Fixture]: %', r; END IF;

  -- fn_setup_next: lesend, leitet den Schritt aus den Fakten ab
  SET LOCAL ROLE finance_rw;
  r := finance.fn_setup_next(jsonb_build_object('chat_id', '__rt_su1', 'table', v_tbl));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'phase' <> 'reanchor' OR (r->>'account_id')::int <> v_acct
     OR r->'card'->'params'->>'action' <> 'reanchor' THEN RAISE EXCEPTION 'FAIL [fn_setup_next finance_rw]: %', r; END IF;

  -- fn_setup_advance: bindet das gefundene Konto an die Sitzung (UPDATE setup_session)
  SET LOCAL ROLE finance_rw;
  r := finance.fn_setup_advance(jsonb_build_object('chat_id', '__rt_su1', 'table', v_tbl));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'phase' <> 'reanchor'
     OR (SELECT cash_account_id FROM finance.setup_session WHERE chat_id = '__rt_su1') IS DISTINCT FROM v_acct
     THEN RAISE EXCEPTION 'FAIL [fn_setup_advance Bindung finance_rw]: %', r; END IF;

  -- fn_setup_reanchor: Probelauf (zurueckgerollt) und Write
  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_setup_reanchor(jsonb)'::regprocedure, jsonb_build_object('chat_id', '__rt_su1', 'table', v_tbl));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'card_lines'->0->>'label' <> 'finance.label.setup_previous_balance'
     OR (SELECT opening_balance_date FROM finance.accounts WHERE id = v_acct) <> CURRENT_DATE
     THEN RAISE EXCEPTION 'FAIL [fn_setup_reanchor Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_setup_reanchor(jsonb_build_object('chat_id', '__rt_su1', 'table', v_tbl));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'balance')::numeric <> 100 OR (r->>'opening_balance_date')::date <> ps - 1
     OR (SELECT opening_balance_date FROM finance.accounts WHERE id = v_acct) <> ps - 1
     OR (SELECT balance FROM finance.account_balances WHERE account_id = v_acct) <> 100
     OR (SELECT count(*) FROM finance.transactions WHERE account_id = v_acct AND amount = 100 AND transaction_date = ps - 1) <> 1
     THEN RAISE EXCEPTION 'FAIL [fn_setup_reanchor Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS test_role_finance_import_setup [fn_setup_next, fn_setup_advance Bindung, fn_setup_reanchor]';
END $$;

-- ---------- fn_setup_advance: Abbruch und Schritt positions (stellt Staging ein) + Commit der Positionen ----------
DO $$
DECLARE
  T      date := core.fn_today();
  v_hdr  jsonb := '["datetime","date","account_type","category","type","asset_class","name","symbol","shares","price","amount","fee","tax","currency","original_amount","original_currency","fx_rate","description","transaction_id","counterparty_name","counterparty_iban","payment_reference","mcc_code"]';
  v_tbl  jsonb;
  r      jsonb;
  v_acct int;
  v_dep  int;
BEGIN
  v_tbl := jsonb_build_object('rows', jsonb_build_array(v_hdr,
      jsonb_build_array((T-400)::text || 'T10:00:00Z', (T-400)::text, 'DEFAULT', 'CASH', 'CUSTOMER_INPAYMENT', '', '', '', '', '', '5000.00', '', '', 'EUR', '', '', '', '', 'a0', '', '', '', ''),
      jsonb_build_array((T-300)::text || 'T10:00:00Z', (T-300)::text, 'DEFAULT', 'TRADING', 'BUY', 'FUND', 'Birken ETF', 'IE00TESTAAA1', '2.0000000000', '50.00', '-100.00', '', '', 'EUR', '', '', '', '', 'a1', '', '', '', '')));

  -- Abbruch: Sitzung weg, bestaetigte Daten bleiben
  r := finance.fn_setup_begin(jsonb_build_object('chat_id', '__rt_su2', 'file_id', 'f2', 'table', v_tbl));
  IF r->>'phase' <> 'cash_account' THEN RAISE EXCEPTION 'FAIL [advance cancel Fixture]: %', r; END IF;
  SET LOCAL ROLE finance_rw;
  r := finance.fn_setup_advance(jsonb_build_object('chat_id', '__rt_su2', 'action', 'cancel'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'phase' <> 'cancelled'
     OR EXISTS (SELECT 1 FROM finance.setup_session WHERE chat_id = '__rt_su2') THEN RAISE EXCEPTION 'FAIL [fn_setup_advance cancel finance_rw]: %', r; END IF;

  -- Fixture bis kurz vor die Positionen: Saldo-Antwort, Verrechnungskonto, Depot
  r := finance.fn_setup_begin(jsonb_build_object('chat_id', '__rt_su3', 'file_id', 'f3', 'table', v_tbl));
  r := finance.fn_setup_advance(jsonb_build_object('chat_id', '__rt_su3', 'table', v_tbl, 'question_key', 'current_balance', 'answer', '1.234,56'));
  IF r->>'phase' <> 'cash_account' THEN RAISE EXCEPTION 'FAIL [advance Fixture Saldo]: %', r; END IF;
  v_acct := (finance.fn_create_account(r->'card'->'params')->>'account_id')::int;
  r := finance.fn_setup_advance(jsonb_build_object('chat_id', '__rt_su3', 'table', v_tbl));
  IF r->>'phase' <> 'depot' THEN RAISE EXCEPTION 'FAIL [advance Fixture Depot]: %', r; END IF;
  v_dep := (finance.fn_create_account(jsonb_build_object('name', '__rt_su_depot', 'account_type', 'stocks_depot', 'currency', 'EUR',
              'settlement_id', v_acct))->>'account_id')::int;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_setup_advance(jsonb_build_object('chat_id', '__rt_su3', 'table', v_tbl));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'phase' <> 'positions' OR (r->>'positions')::int <> 1 OR (r->>'invalid')::int <> 0
     OR r->'card'->>'tool' <> 'tool_commit_import'
     OR (SELECT count(*) FROM finance.import_staging WHERE batch_id = (r->>'batch_id')::uuid AND entity_type = 'stock_buy' AND status = 'valid') <> 1
     THEN RAISE EXCEPTION 'FAIL [fn_setup_advance positions finance_rw]: %', r; END IF;

  -- die gestellten Positionen committet tool_commit_import ueber fn_import_bundle (Bestandsuebernahme, geldneutral)
  SET LOCAL ROLE finance_rw;
  r := finance.fn_import_bundle(jsonb_build_object('batch_id', (SELECT batch_id FROM finance.setup_session WHERE chat_id = '__rt_su3')));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'committed')::int <> 1
     OR (SELECT shares FROM finance.depot_holdings WHERE account_id = v_dep AND isin = 'IE00TESTAAA1') IS DISTINCT FROM 2
     OR finance.fn_get_balance(v_acct) <> 1234.56
     THEN RAISE EXCEPTION 'FAIL [fn_import_bundle Positionen finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS test_role_finance_import_setup [fn_setup_advance cancel + positions, fn_import_bundle Positionen]';
END $$;

-- ---------- fn_cancel_handoff_task: nicht mehr eintragen (dropped) und schon im System (done_elsewhere) ----------
DO $$
DECLARE
  r     jsonb;
  v_d   int;
  v_e   int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at)
  VALUES ('finance','finance','erika','s','other','Reisekasse einrichten','working',now()) RETURNING id INTO v_d;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at)
  VALUES ('finance','finance','erika','s','other','Hausrat pruefen','working',now()) RETURNING id INTO v_e;
  INSERT INTO finance.insurances (name, valid_from) VALUES ('__rt_cancel_hausrat', CURRENT_DATE);

  -- dropped: Probelauf laesst die Aufgabe working, Write setzt cancelled
  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_cancel_handoff_task(jsonb)'::regprocedure,
         jsonb_build_object('handoff_task_id', v_d, 'chat_id', '111', 'reason', 'dropped'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'card_title_key' <> 'finance.hitl.cancel_handoff_task_dropped'
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_d) <> 'working' THEN RAISE EXCEPTION 'FAIL [cancel dropped Probelauf finance_rw]: %', r; END IF;
  SET LOCAL ROLE finance_rw;
  r := finance.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_d, 'chat_id', '111', 'reason', 'dropped'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status FROM agent.handoff_tasks WHERE id = v_d) <> 'cancelled'
     THEN RAISE EXCEPTION 'FAIL [cancel dropped Write finance_rw]: %', r; END IF;

  -- done_elsewhere: loest die genannte Sache in finance auf und schliesst die Aufgabe als done
  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_cancel_handoff_task(jsonb)'::regprocedure,
         jsonb_build_object('handoff_task_id', v_e, 'chat_id', '111', 'reason', 'done_elsewhere',
                            'ref_type', 'insurance', 'ref_name', '__rt_cancel_hausrat'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'card_title_key' <> 'finance.hitl.cancel_handoff_task_done_elsewhere'
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_e) <> 'working' THEN RAISE EXCEPTION 'FAIL [cancel done_elsewhere Probelauf finance_rw]: %', r; END IF;
  SET LOCAL ROLE finance_rw;
  r := finance.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_e, 'chat_id', '111', 'reason', 'done_elsewhere',
         'ref_type', 'insurance', 'ref_name', '__rt_cancel_hausrat'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status FROM agent.handoff_tasks WHERE id = v_e) <> 'done'
     THEN RAISE EXCEPTION 'FAIL [cancel done_elsewhere Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS test_role_finance_import_setup [fn_cancel_handoff_task]';
END $$;

ROLLBACK;
