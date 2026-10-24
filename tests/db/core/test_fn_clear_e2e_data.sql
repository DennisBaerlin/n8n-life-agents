-- tests/db/core/test_fn_clear_e2e_data.sql
-- Testet agent.fn_clear_e2e_data: loescht NUR Sentinel-Zeilen ('__E2E__'), laesst Nicht-Sentinel
-- vollstaendig unberuehrt (verifiziert den Guard). Self-contained, BEGIN/ROLLBACK -> kein Residual.
BEGIN;

DO $$
DECLARE
  v_a_id  INT;   -- Sentinel-Konto (Cash / Settlement)
  v_d_id  INT;   -- Sentinel-Depot
  v_k_id  INT;   -- Keep (Nicht-Sentinel) Konto
  v_rp_id INT;   -- Sentinel-Recurring-Payment (fuer Sparplan)
  v_pen_rp INT;  -- Sentinel-Recurring-Payment (Pension-Beitrag)
  v_keep_pen INT; -- Nicht-Sentinel-Pension (muss erhalten bleiben)
  v_loan_acc INT; -- Loan-Konto eines Sentinel-Kredits ('Kredit __E2E__ ...' -> kein Prefix-Match)
  v_res   JSONB;
BEGIN
  -- Sentinel-Konto + Nicht-Sentinel-Konto anlegen (Balance-Zeile entsteht via Trigger)
  INSERT INTO finance.accounts (name, account_type, currency)
  VALUES ('__E2E__ Konto A', 'cash', 'EUR') RETURNING id INTO v_a_id;

  INSERT INTO finance.accounts (name, account_type, currency)
  VALUES ('__keep__ Konto K', 'cash', 'EUR') RETURNING id INTO v_k_id;

  -- Sentinel-Depot + Sparplan (testet FK-Reihenfolge in fn_clear_e2e_data)
  INSERT INTO finance.accounts (name, account_type, currency, settlement_account_id)
  VALUES ('__E2E__ Depot A', 'stocks_depot', 'EUR', v_a_id) RETURNING id INTO v_d_id;

  INSERT INTO finance.recurring_payments (account_id, name, amount, schedule_unit, first_payment_date, valid_from)
  VALUES (v_a_id, '__E2E__ Sparplan RP', -50, 'month', CURRENT_DATE, CURRENT_DATE) RETURNING id INTO v_rp_id;

  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, status)
  VALUES ('__E2E__ VWCE Sparplan', v_d_id, 'VWCE', 'Vanguard FTSE All-World', v_rp_id, 'active');

  -- Sentinel-Pension mit Beitrag (rp auf Sentinel-Konto) + Nicht-Sentinel-Pension (keep)
  INSERT INTO finance.recurring_payments (account_id, name, amount, schedule_unit, first_payment_date, valid_from)
  VALUES (v_a_id, '__E2E__ AV-Beitrag', -100, 'month', CURRENT_DATE, CURRENT_DATE) RETURNING id INTO v_pen_rp;
  INSERT INTO finance.pension (name, pension_type, recurring_payment_id, status)
  VALUES ('__E2E__ Ruerup', 'ruerup', v_pen_rp, 'active');
  INSERT INTO finance.pension (name, pension_type, status)
  VALUES ('__keep__ DRV gesetzlich', 'statutory', 'active') RETURNING id INTO v_keep_pen;

  -- Sentinel-Kredit: erzeugt ein Loan-Konto 'Kredit __E2E__ ...' (Marker NICHT am Anfang).
  -- settle_loan wuerde dieses Konto nicht loeschen -> fn_clear_e2e_data muss es einsammeln.
  PERFORM finance.fn_create_loan(jsonb_build_object(
    'name','__E2E__ CL Kredit','lender','TB','borrower','T','original_amount','5000','current_balance','5000',
    'disbursement_date',CURRENT_DATE::text,'interest_rate','3','monthly_annuity','200',
    'schedule_day_of_month','1','first_payment_date',CURRENT_DATE::text,'debit_account_id',v_a_id));
  SELECT loan_account_id INTO v_loan_acc FROM finance.loans WHERE name = '__E2E__ CL Kredit';

  -- je eine Transaktion (Balance-Trigger feuert)
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
  VALUES (v_a_id, 100, CURRENT_DATE, 'other', '__E2E__ tx');
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
  VALUES (v_k_id, 200, CURRENT_DATE, 'other', 'keep tx');

  -- Cleanup ausfuehren
  SELECT agent.fn_clear_e2e_data() INTO v_res;

  -- Assert: Sparplan + dessen RP geloescht (FK-Reihenfolge korrekt)
  IF EXISTS (SELECT 1 FROM finance.savings_plans WHERE name LIKE '\_\_E2E\_\_%') THEN
    RAISE EXCEPTION 'FAIL: Sentinel-Sparplan nicht geloescht';
  END IF;
  IF EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp_id) THEN
    RAISE EXCEPTION 'FAIL: Sentinel-RP des Sparplans nicht geloescht';
  END IF;

  -- Assert: Sentinel-Pension + dessen Beitrags-RP geloescht (neue pension-Abdeckung)
  IF EXISTS (SELECT 1 FROM finance.pension WHERE name LIKE '\_\_E2E\_\_%') THEN
    RAISE EXCEPTION 'FAIL: Sentinel-Pension nicht geloescht';
  END IF;
  IF EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_pen_rp) THEN
    RAISE EXCEPTION 'FAIL: Sentinel-Pension-Beitrags-RP nicht geloescht';
  END IF;
  -- Assert: Nicht-Sentinel-Pension UNBERUEHRT
  IF NOT EXISTS (SELECT 1 FROM finance.pension WHERE id = v_keep_pen) THEN
    RAISE EXCEPTION 'FAIL: Nicht-Sentinel-Pension % faelschlich geloescht', v_keep_pen;
  END IF;

  -- Assert: Sentinel-Konto + alle Abhaengigen sind weg
  IF EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_a_id) THEN
    RAISE EXCEPTION 'FAIL: Sentinel-Konto % nicht geloescht', v_a_id;
  END IF;
  IF EXISTS (SELECT 1 FROM finance.account_balances WHERE account_id = v_a_id) THEN
    RAISE EXCEPTION 'FAIL: Balance-Zeile des Sentinel-Kontos nicht geloescht';
  END IF;
  IF EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_a_id) THEN
    RAISE EXCEPTION 'FAIL: Transaktion des Sentinel-Kontos nicht geloescht';
  END IF;

  -- Assert: Loan-Konto des Sentinel-Kredits ('Kredit __E2E__ ...') + Loan-Zeile weg
  IF EXISTS (SELECT 1 FROM finance.loans WHERE name = '__E2E__ CL Kredit') THEN
    RAISE EXCEPTION 'FAIL: Sentinel-Loan nicht geloescht';
  END IF;
  IF EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_loan_acc) THEN
    RAISE EXCEPTION 'FAIL: Loan-Konto % des Sentinel-Kredits nicht geloescht (Orphan-Leak)', v_loan_acc;
  END IF;

  -- Assert: Nicht-Sentinel-Konto + dessen Daten UNBERUEHRT (Guard wirkt)
  IF NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_k_id) THEN
    RAISE EXCEPTION 'FAIL: Nicht-Sentinel-Konto % faelschlich geloescht', v_k_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_k_id AND amount = 200) THEN
    RAISE EXCEPTION 'FAIL: Transaktion des Nicht-Sentinel-Kontos faelschlich geloescht';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.account_balances WHERE account_id = v_k_id AND balance = 200) THEN
    RAISE EXCEPTION 'FAIL: Balance des Nicht-Sentinel-Kontos veraendert/geloescht';
  END IF;

  -- Assert: Rueckgabe-Counts plausibel (mind. 1 Konto + 1 Transaktion entfernt)
  IF (v_res->>'accounts')::int < 1 OR (v_res->>'transactions')::int < 1 THEN
    RAISE EXCEPTION 'FAIL: Rueckgabe-Counts unplausibel: %', v_res;
  END IF;

  RAISE NOTICE 'PASS fn_clear_e2e_data: %', v_res;
END $$;

-- ============================================================
-- Advisor-Scope: Sentinel-advisor_plans (Match via domain ODER plan_name) und
-- agent-publizierte Sentinel-Context-Docs werden geraeumt; Nicht-Sentinel und
-- sentinel-benannte, aber NICHT-managed Contexts bleiben (managed_by-Bedingung).
-- ============================================================
DO $$
DECLARE
  v_res JSONB;
BEGIN
  -- Match ueber sentinel-DOMAIN (so schreibt der E2E-Pfad: domain='__e2e_finance__')
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version)
  VALUES ('__e2e_fin__', '__E2E__ Plan A', 'draft', 1);
  -- Match ueber sentinel-PLAN_NAME (Leftover in normaler Domain)
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version)
  VALUES ('__keepdom__', '__E2E__ Plan B', 'superseded', 1);
  -- Keep: weder domain noch plan_name sentinel
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version)
  VALUES ('__keepdom__', '__keep__ Plan', 'draft', 2);

  -- Agent-publiziertes Sentinel-Context-Doc -> loeschen (managed_by ist D14/WS-B2 typisierte Spalte)
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by)
  VALUES ('__e2e_fin___plan_current', 'e2e plan doc', 'lazy', '# plan', 'agent');
  -- Keep: managed, aber NICHT sentinel-benannt
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by)
  VALUES ('__keepctx_plan_current', 'keep doc', 'lazy', '# keep', 'agent');
  -- Keep: sentinel-benannt, aber NICHT managed (Default managed_by='seed' != 'agent' -> nur managed Docs loeschbar)
  INSERT INTO agent.core_contexts (name, description, load_strategy, content)
  VALUES ('__e2e_unmanaged__', 'unmanaged doc', 'lazy', '# unmanaged');

  SELECT agent.fn_clear_e2e_data() INTO v_res;

  IF EXISTS (SELECT 1 FROM agent.advisor_plans WHERE domain = '__e2e_fin__') THEN
    RAISE EXCEPTION 'FAIL advisor-scope: Sentinel-Plan (domain-Match) nicht geloescht';
  END IF;
  IF EXISTS (SELECT 1 FROM agent.advisor_plans WHERE plan_name = '__E2E__ Plan B') THEN
    RAISE EXCEPTION 'FAIL advisor-scope: Sentinel-Plan (plan_name-Match) nicht geloescht';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.advisor_plans WHERE plan_name = '__keep__ Plan') THEN
    RAISE EXCEPTION 'FAIL advisor-scope: Nicht-Sentinel-Plan faelschlich geloescht';
  END IF;
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = '__e2e_fin___plan_current') THEN
    RAISE EXCEPTION 'FAIL advisor-scope: Sentinel-Context-Doc nicht geloescht';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = '__keepctx_plan_current') THEN
    RAISE EXCEPTION 'FAIL advisor-scope: Nicht-Sentinel-Context faelschlich geloescht';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = '__e2e_unmanaged__') THEN
    RAISE EXCEPTION 'FAIL advisor-scope: unmanaged Sentinel-Context faelschlich geloescht (managed_by-Guard verletzt)';
  END IF;
  IF (v_res->>'advisor_plans')::int < 2 OR (v_res->>'contexts')::int < 1 THEN
    RAISE EXCEPTION 'FAIL advisor-scope: Rueckgabe-Counts unplausibel: %', v_res;
  END IF;
  RAISE NOTICE 'PASS fn_clear_e2e_data [advisor_plans + managed Context-Docs gescoped geraeumt]';
END $$;

-- ============================================================
-- Monitor-Scope: Sentinel-monitor_triggers (Match via domain ODER label) werden geraeumt
-- (Observations gehen per FK-CASCADE mit); Nicht-Sentinel-Trigger bleiben.
-- ============================================================
DO $$
DECLARE
  v_sent INT; v_keep INT; v_res JSONB;
BEGIN
  -- Match ueber sentinel-DOMAIN (so schreibt der E2E-Pfad: domain='__e2e_monitor__')
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, due_date, check_interval)
  VALUES ('__e2e_monitor__', 'e2e date trigger', 'date', 'none', '2027-01-01', INTERVAL '1 day')
  RETURNING id INTO v_sent;
  INSERT INTO agent.monitor_observations (trigger_id, ok, value) VALUES (v_sent, true, 1);
  -- Match ueber sentinel-LABEL (Leftover in normaler Domain)
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, due_date, check_interval)
  VALUES ('__keepdom__', '__E2E__ leftover', 'date', 'none', '2027-01-01', INTERVAL '1 day');
  -- Keep: weder domain noch label sentinel
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, due_date, check_interval)
  VALUES ('__keepdom__', 'keep trigger', 'date', 'none', '2027-01-01', INTERVAL '1 day')
  RETURNING id INTO v_keep;

  SELECT agent.fn_clear_e2e_data() INTO v_res;

  IF EXISTS (SELECT 1 FROM agent.monitor_triggers WHERE domain = '__e2e_monitor__') THEN
    RAISE EXCEPTION 'FAIL monitor-scope: Sentinel-Trigger (domain-Match) nicht geloescht';
  END IF;
  IF EXISTS (SELECT 1 FROM agent.monitor_triggers WHERE label = '__E2E__ leftover') THEN
    RAISE EXCEPTION 'FAIL monitor-scope: Sentinel-Trigger (label-Match) nicht geloescht';
  END IF;
  IF EXISTS (SELECT 1 FROM agent.monitor_observations WHERE trigger_id = v_sent) THEN
    RAISE EXCEPTION 'FAIL monitor-scope: Observations nicht kaskadiert';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.monitor_triggers WHERE id = v_keep) THEN
    RAISE EXCEPTION 'FAIL monitor-scope: Nicht-Sentinel-Trigger faelschlich geloescht';
  END IF;
  IF (v_res->>'monitor_triggers')::int < 2 THEN
    RAISE EXCEPTION 'FAIL monitor-scope: Rueckgabe-Count unplausibel: %', v_res;
  END IF;
  RAISE NOTICE 'PASS fn_clear_e2e_data [monitor_triggers gescoped geraeumt]';
END $$;

-- ============================================================
-- Phase C Lern-Loop-Scope: Sentinel-Kandidaten (Marker im proposed_value) + die per approve angehaengten
-- "## Gelernt"-Sentinel-Zeilen aus agent-managed Kontexten + der Watermark werden geraeumt; Nicht-Sentinel-
-- Kandidaten und -Notizzeilen bleiben (Zeilen-genauer Strip, kein Kontext-Loeschen).
-- ============================================================
DO $$
DECLARE
  v_res jsonb; v_cont text;
BEGIN
  -- Wissens-Kontext mit einer Sentinel- + einer Keep-Notiz unter "## Gelernt" (prose-only -> kein Validate-Trigger)
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package)
  VALUES ('financial_planning', 'e2e fixture', 'finance_advisor', 'lazy',
          E'# Plan\n\n## Gelernt\n\n- normale Notiz die bleibt (gelernt am 2026-01-01 aus Chat)\n- __E2E__ Sentinel-Notiz (gelernt am 2026-06-26 aus Chat)\n',
          'agent', 'finance')
  ON CONFLICT (name) DO UPDATE SET content = EXCLUDED.content, managed_by = EXCLUDED.managed_by;

  INSERT INTO agent.guide_learn_candidates (agent_name, source_id, target_kind, context_name, proposed_value, kind, slot_key, status, expires_at)
  VALUES ('finance_advisor', 901, 'note', 'financial_planning', '__E2E__ Sentinel-Notiz',   'new', 'financial_planning|e2e',  'approved', now() + interval '7 days'),
         ('finance_advisor', 902, 'note', 'financial_planning', 'normale Notiz die bleibt', 'new', 'financial_planning|keep', 'approved', now() + interval '7 days');

  INSERT INTO agent.guide_learn_watermark (agent_name, last_seen_id) VALUES ('finance', 99)
  ON CONFLICT (agent_name) DO UPDATE SET last_seen_id = EXCLUDED.last_seen_id;

  SELECT agent.fn_clear_e2e_data() INTO v_res;

  IF EXISTS (SELECT 1 FROM agent.guide_learn_candidates WHERE proposed_value = '__E2E__ Sentinel-Notiz') THEN
    RAISE EXCEPTION 'FAIL learn-scope: Sentinel-Kandidat nicht geloescht';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.guide_learn_candidates WHERE source_id = 902) THEN
    RAISE EXCEPTION 'FAIL learn-scope: Keep-Kandidat faelschlich geloescht';
  END IF;
  SELECT content INTO v_cont FROM agent.core_contexts WHERE name = 'financial_planning';
  IF position('__E2E__' IN v_cont) > 0 THEN
    RAISE EXCEPTION 'FAIL learn-scope: Sentinel-## Gelernt-Zeile nicht gestrippt: %', v_cont;
  END IF;
  IF position('normale Notiz die bleibt' IN v_cont) = 0 THEN
    RAISE EXCEPTION 'FAIL learn-scope: Keep-Notizzeile faelschlich entfernt';
  END IF;
  IF EXISTS (SELECT 1 FROM agent.guide_learn_watermark) THEN
    RAISE EXCEPTION 'FAIL learn-scope: Watermark nicht geraeumt';
  END IF;
  IF (v_res->>'guide_learn_candidates')::int < 1 OR (v_res->>'gelernt_notes_stripped')::int < 1 OR (v_res->>'guide_learn_watermark')::int < 1 THEN
    RAISE EXCEPTION 'FAIL learn-scope: Rueckgabe-Counts unplausibel: %', v_res;
  END IF;
  RAISE NOTICE 'PASS fn_clear_e2e_data [Lern-Kandidaten + ## Gelernt-Sentinel + Watermark gescoped geraeumt]';
END $$;

-- ============================================================
-- A5: Run-Scoping — fn_clear_e2e_data(p_runid) loescht NUR den eigenen Lauf;
-- generischer Aufruf (NULL) faengt fix + run-scoped Marker.
-- ============================================================
DO $$
DECLARE
  v_r1 INT; v_r2 INT; v_keep INT; v_res JSONB; v_ok BOOLEAN;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency)
  VALUES ('__E2E_run1__ Konto', 'cash', 'EUR') RETURNING id INTO v_r1;
  INSERT INTO finance.accounts (name, account_type, currency)
  VALUES ('__E2E_run2__ Konto', 'cash', 'EUR') RETURNING id INTO v_r2;
  INSERT INTO finance.accounts (name, account_type, currency)
  VALUES ('__keep3__ Konto', 'cash', 'EUR') RETURNING id INTO v_keep;

  -- Scoped auf run1 -> nur run1 weg, run2 + keep bleiben
  SELECT agent.fn_clear_e2e_data('run1') INTO v_res;
  IF EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_r1) THEN
    RAISE EXCEPTION 'FAIL run-scope: run1 nicht geloescht';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_r2) THEN
    RAISE EXCEPTION 'FAIL run-scope: run2 faelschlich mit-geloescht (Kollision!)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_keep) THEN
    RAISE EXCEPTION 'FAIL run-scope: keep faelschlich geloescht';
  END IF;
  RAISE NOTICE 'PASS fn_clear_e2e_data [run1 scoped: run2+keep unberuehrt]';

  -- Generischer Sweep faengt den verbliebenen run2-Marker
  SELECT agent.fn_clear_e2e_data() INTO v_res;
  IF EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_r2) THEN
    RAISE EXCEPTION 'FAIL run-scope: generischer Sweep liess run2 stehen';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_keep) THEN
    RAISE EXCEPTION 'FAIL run-scope: keep nach generischem Sweep weg';
  END IF;
  RAISE NOTICE 'PASS fn_clear_e2e_data [generischer Sweep faengt run-scoped Marker]';

  -- Run-ID-Format-Guard: ungueltige ID -> EXCEPTION
  v_ok := false;
  BEGIN
    PERFORM agent.fn_clear_e2e_data('bad-id!');
  EXCEPTION WHEN OTHERS THEN
    v_ok := true;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'FAIL run-scope: ungueltige run-id wurde NICHT abgelehnt';
  END IF;
  RAISE NOTICE 'PASS fn_clear_e2e_data [ungueltige run-id -> RAISE]';
END $$;

-- ============================================================
-- WS-2 career.job_matches-Scope: Sentinel-Treffer (title '__E2E__ ...') geraeumt (to_regclass-geguardet,
-- eigenstaendiger title-scoped DELETE), Nicht-Sentinel-Treffer bleibt.
-- ============================================================
DO $$
DECLARE v_res jsonb; v_keep bigint;
BEGIN
  -- P2a: career.job_matches.person_id ist NOT NULL + FK -> agent.persons. Eine Person als Fixture (direkter
  -- agent.persons-INSERT genuegt fuer den FK; das Projektions-Modell wird hier nicht geprueft).
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('e2e_owner', 'E2E Owner', 'owner')
    ON CONFLICT (person_id) DO NOTHING;
  INSERT INTO career.job_matches (person_id, source, external_id, title) VALUES ('e2e_owner', 'forwarded', NULL, '__E2E__ Scrum Master');
  INSERT INTO career.job_matches (person_id, source, external_id, title) VALUES ('e2e_owner', 'forwarded', NULL, 'keep Agile Coach')
    RETURNING id INTO v_keep;

  SELECT agent.fn_clear_e2e_data() INTO v_res;

  IF EXISTS (SELECT 1 FROM career.job_matches WHERE title LIKE '%\_\_E2E%') THEN
    RAISE EXCEPTION 'FAIL job_matches-scope: Sentinel-Treffer nicht geloescht';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM career.job_matches WHERE id = v_keep) THEN
    RAISE EXCEPTION 'FAIL job_matches-scope: Nicht-Sentinel-Treffer faelschlich geloescht';
  END IF;
  IF (v_res->>'job_matches')::int < 1 THEN
    RAISE EXCEPTION 'FAIL job_matches-scope: Rueckgabe-Count unplausibel: %', v_res;
  END IF;
  RAISE NOTICE 'PASS fn_clear_e2e_data [career.job_matches Sentinel gescoped geraeumt]';
END $$;

-- ============================================================
-- estate WS-2-Scope: Sentinel-Zeilen aller estate-Register (provider/name/description/notes/
-- wishes/location_note ODER via referenzierte Sentinel-Fundstelle) geraeumt (to_regclass-
-- geguardet); Nicht-Sentinel-Zeilen bleiben. Deckt die FK-sichere Reihenfolge (directives VOR
-- storage_places, FK RESTRICT).
-- ============================================================
DO $$
DECLARE
  v_res jsonb; v_keep_c bigint; v_sp_id bigint;
BEGIN
  -- Sentinel-Fundstelle + eine darauf verweisende Sentinel-directive (testet die FK-Reihenfolge):
  INSERT INTO estate.storage_places (name, kind) VALUES ('__E2E__ Tresor', 'safe') RETURNING id INTO v_sp_id;
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status, storage_place_id, notes)
  VALUES (NULL, 'testament', 'exists', v_sp_id, '__E2E__ directive');
  -- Sentinel-Zeilen der uebrigen Register:
  INSERT INTO estate.provider_contracts (provider, category) VALUES ('__E2E__ Stadtwerke', 'utilities');
  INSERT INTO estate.digital_accounts (provider, category) VALUES ('__E2E__ GMX', 'email');
  INSERT INTO estate.contacts (name, role) VALUES ('__E2E__ Notar', 'notary');
  INSERT INTO estate.special_assets (asset_type, description) VALUES ('vehicle', '__E2E__ VW Golf');
  -- Keep-Zeilen (Nicht-Sentinel) — muessen ueberleben:
  INSERT INTO estate.contacts (name, role) VALUES ('__keep__ Hausarzt', 'physician') RETURNING id INTO v_keep_c;
  INSERT INTO estate.storage_places (name, kind) VALUES ('__keep__ Ordner', 'folder');

  SELECT agent.fn_clear_e2e_data() INTO v_res;

  IF EXISTS (SELECT 1 FROM estate.directives         WHERE notes LIKE '%\_\_E2E%') THEN
    RAISE EXCEPTION 'FAIL estate-scope: Sentinel-directive nicht geloescht'; END IF;
  IF EXISTS (SELECT 1 FROM estate.storage_places     WHERE name LIKE '%\_\_E2E%') THEN
    RAISE EXCEPTION 'FAIL estate-scope: Sentinel-Fundstelle nicht geloescht (FK-Reihenfolge?)'; END IF;
  IF EXISTS (SELECT 1 FROM estate.provider_contracts WHERE provider LIKE '%\_\_E2E%') THEN
    RAISE EXCEPTION 'FAIL estate-scope: Sentinel-Vertrag nicht geloescht'; END IF;
  IF EXISTS (SELECT 1 FROM estate.digital_accounts   WHERE provider LIKE '%\_\_E2E%') THEN
    RAISE EXCEPTION 'FAIL estate-scope: Sentinel-Digital-Konto nicht geloescht'; END IF;
  IF EXISTS (SELECT 1 FROM estate.contacts           WHERE name LIKE '%\_\_E2E%') THEN
    RAISE EXCEPTION 'FAIL estate-scope: Sentinel-Kontakt nicht geloescht'; END IF;
  IF EXISTS (SELECT 1 FROM estate.special_assets     WHERE description LIKE '%\_\_E2E%') THEN
    RAISE EXCEPTION 'FAIL estate-scope: Sentinel-Sonderfall nicht geloescht'; END IF;
  IF NOT EXISTS (SELECT 1 FROM estate.contacts WHERE id = v_keep_c) THEN
    RAISE EXCEPTION 'FAIL estate-scope: Nicht-Sentinel-Kontakt faelschlich geloescht'; END IF;
  IF NOT EXISTS (SELECT 1 FROM estate.storage_places WHERE name = '__keep__ Ordner') THEN
    RAISE EXCEPTION 'FAIL estate-scope: Nicht-Sentinel-Fundstelle faelschlich geloescht'; END IF;
  IF (v_res->>'estate_rows')::int < 6 THEN
    RAISE EXCEPTION 'FAIL estate-scope: Rueckgabe-Count unplausibel: %', v_res; END IF;
  RAISE NOTICE 'PASS fn_clear_e2e_data [estate-Register Sentinel gescoped geraeumt, FK-sicher]';
END $$;

-- ============================================================
-- Phase B: Paket mit eigenem Schema OHNE Konventions-Hook <pkg>.fn_clear_e2e_data(text) -> RAISE
-- (Vertragsbruch laut, nicht still uebersprungen); ein registriertes Paket OHNE Schema wird uebersprungen.
-- ============================================================
DO $$
DECLARE v_ok boolean := false; v_res jsonb;
BEGIN
  INSERT INTO core.package_registry (package, status) VALUES ('zz_noschema', 'active');
  SELECT agent.fn_clear_e2e_data() INTO v_res;   -- kein Schema -> kein Hook noetig
  RAISE NOTICE 'PASS fn_clear_e2e_data [registriertes Paket ohne Schema uebersprungen]';

  CREATE SCHEMA zz_nohook;
  INSERT INTO core.package_registry (package, status) VALUES ('zz_nohook', 'active');
  BEGIN
    PERFORM agent.fn_clear_e2e_data();
  EXCEPTION WHEN raise_exception THEN
    v_ok := SQLERRM LIKE '%zz_nohook%fn_clear_e2e_data%';
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL hook-missing: Paket mit Schema ohne Hook nicht abgelehnt'; END IF;
  RAISE NOTICE 'PASS fn_clear_e2e_data [Schema ohne Hook -> RAISE]';
END $$;

ROLLBACK;
