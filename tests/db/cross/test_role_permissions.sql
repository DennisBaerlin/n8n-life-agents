-- tests/db/cross/test_role_permissions.sql
-- ROLLEN-PERSPEKTIV-Smoke (Post-WS3-Härtung): jede publizierte Brücken-/Lesefenster-Funktion wird unter
-- der ECHTEN Laufzeit-Rolle aufgerufen, die die Agenten zur Laufzeit binden — NICHT als Superuser. Genau
-- die Klasse, die in der WS3-Abnahme bracht (agent.fn_fetch_context war INVOKER → context_ro kein core-
-- Zugriff → "permission denied for schema core"; db_test als Superuser sah es nie).
--
-- Pattern: Superuser-Session + SET LOCAL ROLE <rolle> im DO-Block (wie test_finance_isolation.sql). Ein
-- permission-denied unter der Rolle = harter FAIL. db_test provisioniert context_ro/core_ro (util) +
-- finance_ro (fn_provision_package_roles('finance'), bootstrap_test_db) -> fehlt eine Rolle: harter FAIL
-- (das Substrat ist dann kaputt, kein stiller SKIP).
--
-- WICHTIG (L6): core.fn_fetch_context kehrt bei fehlender lazy-Zeile ZURÜCK, BEVOR es core.context_renderers
-- liest -> ohne eine lazy-Fixture bewiese der Test das core-USAGE/EXECUTE-Grant NICHT (False-Positive). Daher
-- erst eine lazy-Zeile seeden. Die core.*-DEFINER-Fenster erreichen den cross-schema-Read auch leer.
BEGIN;

-- Fixture: eine lazy-Zeile, damit fn_fetch_context bis zum core.context_renderers-Read kommt.
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('__rp_lazy__', 'role-perm fixture', NULL, 'lazy', 'plain content', '{}'::jsonb)
ON CONFLICT (name) DO NOTHING;

-- Fixture: ein finance-Trigger, damit der finance_ro-Test BEWEIST, dass das Lesefenster
-- tatsaechlich Daten liefert (nicht nur "kein permission denied" auf leerem Set).
INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, due_date, check_interval)
VALUES ('finance', '__rp_trig__', 'date', 'none', '2099-01-01', interval '7 days')
ON CONFLICT (domain, lower(label)) DO NOTHING;

-- Fixture (WS-1 Multi-Member): eine projizierte Person, damit der core_ro-Read echte Daten
-- liefert und der finance_rw-FK-Test einen gueltigen Eigentuemer referenzieren kann.
INSERT INTO agent.persons (person_id, full_name, role)
VALUES ('__rp_person__', 'RP Person', 'child') ON CONFLICT (person_id) DO NOTHING;

-- Fixture (WS-5b): family-Context mit gepairtem Owner, damit der core_ro -> agent.fn_resolve_sender-Pin
-- echte Daten liefert (das Gate loest den Sender unter core_ro auf). Der AFTER-Trigger trg_project_persons
-- spiegelt diese family-persons full-replace nach agent.persons -> deshalb traegt die Fixture AUCH
-- '__rp_person__' (sonst loescht der Reconcile den oben direkt eingefuegten Kind-Datensatz -> FK-Test bricht).
-- WS-5 (Member-Pfad-Absicherung): zusaetzlich ein gepairter PARTNER (779) — der ueberlebende Partner ist
-- Erwachsener und MUSS den adults_only-Riegel passieren (Notfallmappe/Break-Glass, Owner-Entscheid 8).
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'role-perm sender fixture', NULL, 'lazy', E'## fam',
        jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
          jsonb_build_object('person_id','__rp_owner__','first_name','RP','last_name','Owner',
                             'role','owner','birth_date','1980-01-01','telegram_user_id',777,'as_of','2026-06-11'),
          jsonb_build_object('person_id','__rp_partner__','first_name','RP','last_name','Partner',
                             'role','partner','birth_date','1982-01-01','telegram_user_id',779,'as_of','2026-06-11'),
          jsonb_build_object('person_id','__rp_person__','first_name','RP','last_name','Person',
                             'role','child','birth_date','2015-01-01','telegram_user_id',778,'as_of','2026-06-11')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;

-- Fixture (WS-5d): eine Sperr-Zeile, damit der core_ro-Read echte Daten liefert.
INSERT INTO agent.access_blocks (telegram_user_id, reason)
VALUES (424242, 'role-perm fixture') ON CONFLICT (telegram_user_id) DO NOTHING;

-- Fixture (estate WS-1 / P2b-1-Regression): je eine household-Onboarding-Sektion, damit der
-- INVOKER-Write-Pfad core.fn_set_onboarding_section unter der ENGEN Paket-RW-Rolle einen echten
-- UPDATE beweist (die Sektionen seedet sonst nur der Installer, nicht bootstrap_test_db).
INSERT INTO finance.onboarding_state (section_key, ord, label)
VALUES ('__rp_sec__', 999, 'RP Fixture') ON CONFLICT (section_key) DO NOTHING;
INSERT INTO estate.onboarding_state (section_key, ord, label)
VALUES ('__rp_sec__', 999, 'RP Fixture') ON CONFLICT (section_key) DO NOTHING;

DO $$
DECLARE
  v_out  TEXT;
  v_out2 TEXT;
  v_bool BOOLEAN;
  v_cnt  INT;
BEGIN
  -- Alle drei Laufzeit-Rollen MÜSSEN existieren (Pflicht-Provisionierung von bootstrap_test_db).
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
    RAISE EXCEPTION 'FAIL [role_perms]: Rolle context_ro nicht provisioniert (Substrat kaputt)'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
    RAISE EXCEPTION 'FAIL [role_perms]: Rolle core_ro nicht provisioniert'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'finance_ro') THEN
    RAISE EXCEPTION 'FAIL [role_perms]: Rolle finance_ro nicht provisioniert'; END IF;

  -- ===== (1) context_ro: load_context-Pfad core.fn_fetch_context =====
  BEGIN
    SET LOCAL ROLE context_ro;
    SELECT content INTO v_out FROM core.fn_fetch_context('__rp_lazy__');  -- erreicht den core.context_renderers-Read
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [context_ro -> core.fn_fetch_context]: load_context bricht unter context_ro -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'plain content' THEN
    RAISE EXCEPTION 'FAIL [context_ro -> core.fn_fetch_context]: erwartet "plain content", got %', COALESCE(v_out,'<null>'); END IF;
  RAISE NOTICE 'PASS [context_ro -> core.fn_fetch_context: kein permission denied]';

  -- ===== (1b) NEGATIV-ASSERT (M2): context_ro darf KEINE core-Tabelle direkt lesen =====
  -- USAGE auf Schema core (für die Fenster) erlaubt KEIN SELECT auf core-Tabellen -> D10 bleibt dicht.
  BEGIN
    SET LOCAL ROLE context_ro;
    PERFORM 1 FROM core.config LIMIT 1;
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [context_ro NEGATIV]: context_ro konnte core.config lesen -> zu breites core-Grant!';
  EXCEPTION
    WHEN insufficient_privilege THEN RESET ROLE;  -- erwartet
    WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
      RAISE;  -- unerwarteter Fehler durchreichen
  END;
  RAISE NOTICE 'PASS [context_ro NEGATIV: kein direkter core.config-Read (D10 dicht)]';

  -- ===== (2) finance_ro: die Core-DEFINER-Fenster, die der Finance-/Advisor-Agent erreicht =====
  BEGIN
    SET LOCAL ROLE finance_ro;
    PERFORM core.fn_advisor_read_plan('finance');
    PERFORM core.fn_monitor_trigger_summary('finance');
    SELECT count(*) INTO v_cnt FROM core.fn_list_monitor_triggers('finance');  -- Advisor<->Monitor: Dedup-Lesefenster
    v_bool := core.fn_package_active('finance');
    v_out  := core.fn_config_get('core', 'api', 'core_version');
    v_out  := core.fn_core_api_version();  -- publiziertes Versions-Brueckenfenster (v_rw,v_ro granted) -> role_test_lint-Deckung
    PERFORM core.fn_onboarding_status('finance');
    PERFORM core.fn_ui_texts_for('{"keys":["core.hitl.hint"]}'::jsonb);   -- Textkatalog Phase C: Cron-/Gate-Texte
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro -> Core-DEFINER-Fenster]: %', SQLERRM;
  END;
  -- beweist, dass das DEFINER-Fenster unter finance_ro tatsaechlich Daten liefert (nicht nur leer/no-crash)
  IF v_cnt < 1 THEN
    RAISE EXCEPTION 'FAIL [finance_ro -> fn_list_monitor_triggers]: Fenster lieferte 0 Zeilen trotz Fixture (Grant ok, aber Read defekt?)'; END IF;
  RAISE NOTICE 'PASS [finance_ro -> read_plan/trigger_summary/list_triggers(% rows)/package_active/config_get/onboarding_status: kein permission denied]', v_cnt;

  -- ===== (2-audit) HITL-Vorpruef-fns der Tools (Audit F6/F7) lesen ohne permission denied =====
  -- tool_book_loan_payment / tool_close_account lesen fn_get_loan_payment_split / fn_get_account_close_blockers
  -- (inkl. fn_recurring_due_open) VOR der Bestaetigungskarte unter ihrer Tool-Cred finance_rw (Prod-Pfad); finance_ro
  -- (Frei-SQL des Agenten) liest sie ebenfalls. Ein Kredit, den es nicht gibt, RAISEt 'not found' NACH dem
  -- Tabellen-Read -> beweist den Lesezugriff; insufficient_privilege waere FAIL.
  DECLARE v_role TEXT; BEGIN
    FOREACH v_role IN ARRAY ARRAY['finance_rw', 'finance_ro'] LOOP
      BEGIN
        EXECUTE format('SET LOCAL ROLE %I', v_role);
        PERFORM finance.fn_get_account_close_blockers(-1);
        PERFORM count(*) FROM finance.fn_recurring_due_open(CURRENT_DATE);
        BEGIN
          PERFORM finance.fn_get_loan_payment_split(jsonb_build_object('loan_id', -1, 'payment_amount', 1,
            'payment_date', CURRENT_DATE::text));
        EXCEPTION WHEN OTHERS THEN
          IF SQLERRM NOT LIKE '%not found%' THEN RAISE; END IF;
        END;
        RESET ROLE;
      EXCEPTION WHEN OTHERS THEN
        RESET ROLE;
        RAISE EXCEPTION 'FAIL [% -> Vorpruef-fns]: %', v_role, SQLERRM;
      END;
    END LOOP;
  END;
  RAISE NOTICE 'PASS [finance_rw/finance_ro -> fn_get_account_close_blockers/fn_get_loan_payment_split/fn_recurring_due_open: kein permission denied]';

  -- ===== (2-mr) Instandhaltungsruecklage (2026-10-27): Empfehlung liest core.fn_config_get =====
  -- finance_rw (Tools: create/set_real_estate, create/set_savings_goal), finance_ro (Agent-Frei-SQL) und core_ro
  -- (Monitor-Frei-SQL / Trigger-Auswertung ueber read_surface) lesen die View + die Helfer ohne permission denied.
  DECLARE v_role TEXT; BEGIN
    FOREACH v_role IN ARRAY ARRAY['finance_rw', 'finance_ro', 'core_ro'] LOOP
      BEGIN
        EXECUTE format('SET LOCAL ROLE %I', v_role);
        PERFORM count(*) FROM finance.maintenance_reserve_status;
        IF (finance.fn_maintenance_reserve_rate(100, 1980)->>'ok')::boolean IS DISTINCT FROM true THEN
          RAISE EXCEPTION 'Empfehlung nicht ok';
        END IF;
        IF v_role <> 'core_ro' THEN
          PERFORM finance.fn_maintenance_card_lines(-1);
          PERFORM finance.fn_real_estate_facts_reason('{"living_area_m2":"100","year_built":"1980"}'::jsonb);
        END IF;
        RESET ROLE;
      EXCEPTION WHEN OTHERS THEN
        RESET ROLE;
        RAISE EXCEPTION 'FAIL [% -> Instandhaltungsruecklage]: %', v_role, SQLERRM;
      END;
    END LOOP;
  END;
  RAISE NOTICE 'PASS [finance_rw/finance_ro/core_ro -> maintenance_reserve_status + fn_maintenance_reserve_rate: kein permission denied]';

  -- ===== (2-mc) Monats-Check: tool_reconcile_bank_statement / tool_void_bank_statement laufen unter finance_rw =====
  -- Vorschau (inkl. Kartenzeilen ueber core.fn_ui_*), Buchung (Abgleich, Skips, Aggregat) und Ruecknahme ohne
  -- permission denied; fn_resolve_account_by_number liest unter beiden Rollen.
  DECLARE v_a INT; v_prep JSONB; v_res JSONB; BEGIN
    v_a := (finance.fn_create_account('{"name":"__t_role_mc__","account_type":"cash","currency":"EUR","account_number":"DE42520513735120710155"}'::jsonb)->>'account_id')::int;
    SET LOCAL ROLE finance_rw;
    v_prep := finance.fn_statement_prepare(jsonb_build_object('account_number', 'DE42520513735120710155', 'currency', 'EUR',
                'period_start', CURRENT_DATE - 40, 'period_end', CURRENT_DATE - 10, 'opening_balance', 0, 'closing_balance', -12.5,
                'lines', jsonb_build_array(jsonb_build_object('date', CURRENT_DATE - 20, 'amount', -12.5, 'counterparty', 'X'))));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_prep->'card_lines') < 3 THEN
      RESET ROLE; RAISE EXCEPTION 'FAIL [finance_rw -> fn_statement_prepare]: %', v_prep; END IF;
    v_res := finance.fn_apply_bank_statement(jsonb_build_object('account_number', 'DE42520513735120710155', 'currency', 'EUR',
                'period_start', CURRENT_DATE - 40, 'period_end', CURRENT_DATE - 10, 'opening_balance', 0, 'closing_balance', -12.5,
                'lines', jsonb_build_array(jsonb_build_object('date', CURRENT_DATE - 20, 'amount', -12.5, 'counterparty', 'X')),
                'fingerprint', v_prep->>'fingerprint'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RESET ROLE; RAISE EXCEPTION 'FAIL [finance_rw -> fn_apply_bank_statement]: %', v_res; END IF;
    v_res := finance.fn_void_bank_statement(jsonb_build_object('account_id', v_a));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RESET ROLE; RAISE EXCEPTION 'FAIL [finance_rw -> fn_void_bank_statement]: %', v_res; END IF;
    RESET ROLE;
    SET LOCAL ROLE finance_ro;
    PERFORM * FROM finance.fn_resolve_account_by_number('DE42520513735120710155');
    RESET ROLE;
    -- (2-mc-csv) Bank-Export-Datei (Broker-CSV Paket B): tool_import_bank_export laeuft unter finance_rw (Probelauf der Lots-Ersetzung,
    -- Vorschau + Buchung inkl. statement_seen_refs); die Monats-Erinnerung liest das Konto-Profil unter finance_ro.
    v_a := (finance.fn_create_account(jsonb_build_object('name', '__t_role_csv__', 'account_type', 'cash', 'currency', 'EUR',
              'bank', 'Trade Republic', 'opening_balance', 0, 'opening_balance_date', (CURRENT_DATE - 10)::text))->>'account_id')::int;
    SET LOCAL ROLE finance_rw;
    v_res := core.fn_dry_run('finance.fn_replace_takeover_with_lots(jsonb)'::regprocedure, jsonb_build_object(
                'account_name', '__t_role_csv__', 'table', jsonb_build_object('rows', jsonb_build_array('["datetime","category","type","amount","currency","transaction_id"]'::jsonb) ||
                jsonb_build_array(jsonb_build_array((CURRENT_DATE - 3)::text, 'CASH', 'CARD_TRANSACTION', '-7.50', 'EUR', 'r-1')))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RESET ROLE; RAISE EXCEPTION 'FAIL [finance_rw -> fn_replace_takeover_with_lots]: %', v_res; END IF;
    v_prep := finance.fn_statement_prepare(jsonb_build_object('source', 'file', 'account_name', '__t_role_csv__', 'closing_balance', -7.5,
                'table', jsonb_build_object('rows', jsonb_build_array('["datetime","category","type","amount","currency","transaction_id"]'::jsonb) ||
                jsonb_build_array(jsonb_build_array((CURRENT_DATE - 3)::text, 'CASH', 'CARD_TRANSACTION', '-7.50', 'EUR', 'r-1')))));
    IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RESET ROLE; RAISE EXCEPTION 'FAIL [finance_rw -> fn_statement_prepare csv]: %', v_prep; END IF;
    v_res := finance.fn_apply_bank_statement(jsonb_build_object('source', 'file', 'account_name', '__t_role_csv__', 'closing_balance', -7.5,
                'table', jsonb_build_object('rows', jsonb_build_array('["datetime","category","type","amount","currency","transaction_id"]'::jsonb) ||
                jsonb_build_array(jsonb_build_array((CURRENT_DATE - 3)::text, 'CASH', 'CARD_TRANSACTION', '-7.50', 'EUR', 'r-1'))),
                'fingerprint', v_prep->>'fingerprint'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RESET ROLE; RAISE EXCEPTION 'FAIL [finance_rw -> fn_apply_bank_statement csv]: %', v_res; END IF;
    RESET ROLE;
    SET LOCAL ROLE finance_ro;
    IF finance.fn_bank_export_account_profile(v_a) IS DISTINCT FROM 'trade_republic_v1' THEN
      RESET ROLE; RAISE EXCEPTION 'FAIL [finance_ro -> fn_bank_export_account_profile]'; END IF;
    RESET ROLE;
    -- Rundungs-Paket 2026-10-23: ungerundete Kurs-Umrechnung (fn_statement_prepare/fn_account_outlook/Transfer) und die
    -- darauf gebaute fn_to_eur (Views) unter beiden Rollen mit einem echten Fremdwaehrungs-Kurs
    PERFORM finance.fn_ensure_currency('USD');
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR','USD', 1.08, CURRENT_DATE)
    ON CONFLICT (base_currency, quote_currency, as_of) DO UPDATE SET rate = EXCLUDED.rate;
    SET LOCAL ROLE finance_rw;
    IF finance.fn_to_eur_unrounded(0.20, 'USD') IS DISTINCT FROM 0.20 / 1.08 THEN
      RESET ROLE; RAISE EXCEPTION 'FAIL [finance_rw -> fn_to_eur_unrounded]'; END IF;
    PERFORM finance.fn_account_outlook(v_a);
    RESET ROLE;
    SET LOCAL ROLE finance_ro;
    IF finance.fn_to_eur(10, 'USD') IS DISTINCT FROM 9.26 THEN RESET ROLE; RAISE EXCEPTION 'FAIL [finance_ro -> fn_to_eur]'; END IF;
    PERFORM count(*) FROM finance.depot_holdings_overview;
    -- Depot-Rendite: die View ruft fn_depot_performance (INVOKER) -> fn_xirr, core.fn_household_persons, core.fn_today
    PERFORM return_pa_pct, return_since_start_pct, missing_reason FROM finance.depot_performance;
    IF abs(finance.fn_xirr(ARRAY['2021-01-01', '2022-01-01']::date[], ARRAY[-100, 110]::numeric[]) - 0.1) > 1e-9 THEN
      RESET ROLE; RAISE EXCEPTION 'FAIL [finance_ro -> fn_xirr]'; END IF;
    -- Uebersicht R3: loan_overview ruft fn_loan_projected_payoff -> fn_loan_simulate (EXECUTE gegen den Aufrufer)
    PERFORM payoff_date_projected, interest_remaining_projected FROM finance.loan_overview;
    RESET ROLE;
  END;
  RAISE NOTICE 'PASS [finance_rw -> Monats-Check prepare/apply/void + Kurs-Umrechnung, finance_ro -> fn_resolve_account_by_number + fn_to_eur/Views]';

  -- ===== (1c) finance_rw: Probelauf vor der Karte (core.fn_dry_run) + core.fn_today =====
  -- Der Probelauf laeuft im Tool unter finance_rw: EXECUTE auf core.fn_dry_run + die aufgerufene finance-fn,
  -- inkl. Saldo-Trigger; danach darf nichts geblieben sein. finance_ro darf fn_dry_run NICHT ausfuehren.
  DECLARE
    v_dry jsonb;
    v_cnt int;
  BEGIN
    SET LOCAL ROLE finance_rw;
    v_dry := core.fn_dry_run('finance.fn_create_account(jsonb)'::regprocedure,
               jsonb_build_object('name', '__rp_dry_acc__', 'account_type', 'cash', 'opening_balance', 12.5));
    IF (v_dry->>'ok')::boolean IS DISTINCT FROM true OR (v_dry->>'dry_run')::boolean IS DISTINCT FROM true THEN
      RESET ROLE; RAISE EXCEPTION 'FAIL [finance_rw -> core.fn_dry_run(fn_create_account)]: %', v_dry; END IF;
    SELECT count(*) INTO v_cnt FROM finance.accounts WHERE name = '__rp_dry_acc__';
    IF v_cnt <> 0 THEN RESET ROLE; RAISE EXCEPTION 'FAIL [finance_rw -> core.fn_dry_run: Konto nicht zurueckgerollt]'; END IF;
    IF core.fn_today() IS NULL THEN RESET ROLE; RAISE EXCEPTION 'FAIL [finance_rw -> core.fn_today]'; END IF;
    RESET ROLE;
    SET LOCAL ROLE finance_ro;
    IF core.fn_today() IS NULL THEN RESET ROLE; RAISE EXCEPTION 'FAIL [finance_ro -> core.fn_today]'; END IF;
    BEGIN
      PERFORM core.fn_dry_run('finance.fn_create_account(jsonb)'::regprocedure, '{}'::jsonb);
      RESET ROLE; RAISE EXCEPTION 'FAIL [finance_ro darf core.fn_dry_run ausfuehren]';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RESET ROLE;
  END;
  RAISE NOTICE 'PASS [finance_rw -> core.fn_dry_run zurueckgerollt + fn_today, finance_ro -> kein fn_dry_run]';

  -- ===== (1d) Paket-Rollen: relative Zeitangabe -> Datum (core.fn_resolve_date) =====
  -- Die estate-Write-fns (Fall-/Aufgaben-Daten) loesen "-3 days" unter estate_rw auf; INVOKER, ruft core.fn_today.
  SET LOCAL ROLE estate_rw;
  IF core.fn_resolve_date('-3 days') IS DISTINCT FROM core.fn_today() - 3 THEN
    RESET ROLE; RAISE EXCEPTION 'FAIL [estate_rw -> core.fn_resolve_date]'; END IF;
  RESET ROLE;
  SET LOCAL ROLE finance_ro;
  IF core.fn_resolve_date('yesterday', DATE '2026-10-25') IS DISTINCT FROM DATE '2026-10-24' THEN
    RESET ROLE; RAISE EXCEPTION 'FAIL [finance_ro -> core.fn_resolve_date]'; END IF;
  RESET ROLE;
  RAISE NOTICE 'PASS [estate_rw/finance_ro -> core.fn_resolve_date]';
  -- Payload-Einstieg der Write-fns (core.fn_resolve_input_dates) unter finance_rw und estate_rw
  SET LOCAL ROLE finance_rw;
  IF core.fn_resolve_input_dates('{"transaction_date":"yesterday"}'::jsonb, ARRAY['transaction_date'], DATE '2026-10-25')
       ->'p'->>'transaction_date' IS DISTINCT FROM '2026-10-24' THEN
    RESET ROLE; RAISE EXCEPTION 'FAIL [finance_rw -> core.fn_resolve_input_dates]'; END IF;
  RESET ROLE;
  SET LOCAL ROLE estate_rw;
  IF (core.fn_resolve_input_dates('{"due_date":"in 3 days"}'::jsonb, ARRAY['due_date'])->'p'->>'due_date')::date
       IS DISTINCT FROM core.fn_today() + 3 THEN
    RESET ROLE; RAISE EXCEPTION 'FAIL [estate_rw -> core.fn_resolve_input_dates]'; END IF;
  RESET ROLE;
  RAISE NOTICE 'PASS [finance_rw/estate_rw -> core.fn_resolve_input_dates]';

  -- ===== (2a) finance_rw: Modell zur Laufzeit (Festwert-Phase 2) =====
  -- agent.finance.tool_extract_finance_document laeuft unter finance_rw; sein Knoten 'Load model config' liest
  -- model.vision_extract ueber core.fn_config_get -> das Fenster muss unter finance_rw greifen und den Wert liefern.
  BEGIN
    SET LOCAL ROLE finance_rw;
    v_out := core.fn_config_get('finance', 'model', 'vision_extract');
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_rw -> fn_config_get]: %', SQLERRM;
  END;
  IF v_out IS NULL OR v_out = '' THEN
    RAISE EXCEPTION 'FAIL [finance_rw -> fn_config_get]: model.vision_extract leer (Seed-Zeile fehlt oder Fenster liefert nichts)'; END IF;
  RAISE NOTICE 'PASS [finance_rw -> fn_config_get(model.vision_extract) = %]', v_out;

  -- ===== (2b) NEGATIV-ASSERT: finance_ro darf agent.monitor_triggers NICHT direkt lesen =====
  -- Beweist, dass core.fn_list_monitor_triggers das EINZIGE Fenster ist (kein stilles Breit-Grant; D10 dicht).
  BEGIN
    SET LOCAL ROLE finance_ro;
    PERFORM 1 FROM agent.monitor_triggers LIMIT 1;
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro NEGATIV]: finance_ro konnte agent.monitor_triggers direkt lesen -> zu breites Grant!';
  EXCEPTION
    WHEN insufficient_privilege THEN RESET ROLE;  -- erwartet
    WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
      RAISE;
  END;
  RAISE NOTICE 'PASS [finance_ro NEGATIV: kein direkter agent.monitor_triggers-Read (D10 dicht)]';

  -- ===== (3) core_ro: BREITE Leserolle der Core-Agenten (monitor/guide, freies postgres_select) =====
  -- core_ro liest agent+core DIREKT (kein DEFINER-Fenster nötig) -> die Bug-Klasse (enge, ausgesperrte Rolle)
  -- greift hier nicht; der Test bestätigt nur, dass der breite Read-Pfad funktioniert.
  BEGIN
    SET LOCAL ROLE core_ro;
    PERFORM 1 FROM agent.core_contexts LIMIT 1;
    PERFORM 1 FROM core.config LIMIT 1;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> direkter agent+core-Read]: %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [core_ro -> direkter agent.core_contexts + core.config-Read (breite Leserolle)]';

  -- ===== (3b) WS-5b (M2): core_ro -> agent.fn_resolve_sender =====
  -- Das HITL-Gate (agent.tool_human_approval) loest den Sender unter core_ro auf (Resolve-Node). Bisher nur
  -- IMPLIZIT ueber den agent.*-SELECT-Grant + PUBLIC-EXECUTE-Default abgesichert; das Gate haengt jetzt hart
  -- davon ab -> deterministisch verankern (sonst faellt jeder numerische Sender ins fail-closed-B0).
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT (agent.fn_resolve_sender(777)->>'found') INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> agent.fn_resolve_sender]: Resolver bricht unter core_ro -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [core_ro -> agent.fn_resolve_sender]: erwartet found=true fuer gepairte uid 777, got %', COALESCE(v_out,'<null>'); END IF;
  RAISE NOTICE 'PASS [core_ro -> agent.fn_resolve_sender (Gate-Resolve-Pfad, found=true)]';

  -- ===== (3b2) Textkatalog: core_ro -> core.fn_hitl_texts / core.fn_ui_texts =====
  -- Das HITL-Gate holt seine Texte ('Render texts') unter core_ro; ein fehlender Grant blockte JEDEN Write
  -- (fail-closed). Plain-INVOKER-fns -> role_test_lint sieht sie nicht, daher hier ausdruecklich verankert.
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT (core.fn_hitl_texts(jsonb_build_object('summary', jsonb_build_object('title','core.x'),
                                                  'chat_id', '777'))->'owner'->>'lang') INTO v_out;
    PERFORM core.fn_ui_texts('de', ARRAY['core.hitl.hint']);
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_hitl_texts]: Gate-Textpfad bricht unter core_ro -- %', SQLERRM;
  END;
  IF v_out IS NULL THEN
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_hitl_texts]: keine Owner-Sprache geliefert'; END IF;
  RAISE NOTICE 'PASS [core_ro -> core.fn_hitl_texts + fn_ui_texts (Gate-Textpfad)]';

  -- ===== (3b3) Sprach-Picker: core_ro -> core.fn_ui_text + agent.fn_person_lang (core.sub_send_language_picker) =====
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT core.fn_ui_text('core.lang.picker', agent.fn_person_lang(NULL)->>'lang', '{"name":"X"}'::jsonb) INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> Sprach-Picker-Text]: bricht unter core_ro -- %', SQLERRM;
  END;
  IF v_out IS NULL THEN
    RAISE EXCEPTION 'FAIL [core_ro -> Sprach-Picker-Text]: kein Text geliefert'; END IF;
  RAISE NOTICE 'PASS [core_ro -> core.fn_ui_text + agent.fn_person_lang (Picker-Pfad)]';

  -- ===== (3b3b) Persona-Picker: core_ro -> fn_ui_text + fn_ui_texts + fn_person_lang + family-Lesen (core.sub_send_persona_picker) =====
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT core.fn_ui_text('core.persona.picker', y.lang)
           || COALESCE(core.fn_ui_texts(y.lang, ARRAY['core.persona.name.butler']::text[])->>'core.persona.name.butler', '')
           || COALESCE((SELECT pp->>'persona' FROM agent.core_contexts c,
                          jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
                         WHERE c.name = 'family' LIMIT 1), 'neutral')
      INTO v_out
      FROM (SELECT agent.fn_person_lang(NULL)->>'lang' AS lang) y;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> Persona-Picker-Text]: bricht unter core_ro -- %', SQLERRM;
  END;
  IF v_out IS NULL THEN
    RAISE EXCEPTION 'FAIL [core_ro -> Persona-Picker-Text]: kein Text geliefert'; END IF;
  RAISE NOTICE 'PASS [core_ro -> Persona-Picker (fn_ui_text + fn_ui_texts + fn_person_lang + family)]';

  -- ===== (3b4) Textkatalog Phase C: jede Paket-Rolle -> core.fn_ui_texts_for (Crons/Gates/Angebots-Karten) =====
  -- Paket-Crons (finance_rw/_ro, estate_rw) und Agent-Eingangs-Gates (<pkg>_ro, auch paperless_ro) laden ihre
  -- Empfaenger-Texte ueber das publizierte DEFINER-Fenster; ohne Grant fiele jeder Cron-Send aus.
  FOR v_out IN
    SELECT r.rolname FROM pg_roles r
     WHERE r.rolname IN ('finance_rw', 'finance_ro', 'estate_rw', 'estate_ro', 'career_rw', 'career_ro',
                         'paperless_rw', 'paperless_ro')
     ORDER BY r.rolname
  LOOP
    BEGIN
      EXECUTE format('SET LOCAL ROLE %I', v_out);
      IF core.fn_ui_texts_for(jsonb_build_object('chat_id', '777', 'keys', jsonb_build_array('core.hitl.hint')))->>'lang' IS NULL THEN
        RAISE EXCEPTION 'keine Sprache geliefert'; END IF;
      RESET ROLE;
    EXCEPTION WHEN OTHERS THEN
      RESET ROLE;
      RAISE EXCEPTION 'FAIL [% -> core.fn_ui_texts_for]: %', v_out, SQLERRM;
    END;
  END LOOP;
  RAISE NOTICE 'PASS [Paket-Rollen -> core.fn_ui_texts_for (Empfaenger-Texte der Crons/Gates)]';

  -- ===== (3c) WS-2 (Onboarding-UX): core_ro -> core.fn_onboarding_status =====
  -- Der Guide zeigt die frische Onboarding-Checkliste ueber die kombinierte Core-fn (statt eines rohen
  -- UNION ueber agent.guide_onboarding_state + finance.onboarding_state) -> „ein Fakt, eine Adresse".
  -- Sein postgres_select laeuft unter core_ro; das publizierte DEFINER-Fenster REVOKEt PUBLIC in seiner
  -- R__ und grantet EXECUTE sonst nur an die Paket-Rollen -> util_create_core_ro ergaenzt core_ro explizit.
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT (core.fn_onboarding_status('finance')->>'ok') INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_onboarding_status]: Fenster bricht unter core_ro -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_onboarding_status]: erwartet ok=true, got %', COALESCE(v_out,'<null>'); END IF;
  RAISE NOTICE 'PASS [core_ro -> core.fn_onboarding_status (Onboarding-Checkliste lesbar)]';

  -- (3c-b) Roter Faden Paket B: das /reminders-Menue liest sein Datenmodell unter core_ro ueber das DEFINER-Fenster
  -- core.fn_reminders_overview (Grant in util_create_core_ro.sql). Unbekannter Betrachter -> ok, leere Liste.
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT (core.fn_reminders_overview('999999999')->>'ok') INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_reminders_overview]: Fenster bricht unter core_ro -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_reminders_overview]: erwartet ok=true, got %', COALESCE(v_out,'<null>'); END IF;
  RAISE NOTICE 'PASS [core_ro -> core.fn_reminders_overview (Erinnerungs-Menue lesbar)]';

  -- (3c-c) Derselbe Workflow holt seine Texte + das Erinnerungs-Fenster im Schritt 'Read texts' unter core_ro. Genau
  -- diese Abfrage: der Erst-Bau nutzte core.fn_ui_texts_for (fuer core_ro nicht freigegeben) -> permission denied,
  -- das Menue zeigte nur rohe Keys (Substrat-Befund 2026-10-23, db_test als Superuser sah es nicht).
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT core.fn_ui_texts(agent.fn_person_lang(agent.fn_resolve_sender(777)->>'person_id')->>'lang',
                            ARRAY['core.reminders.title']::text[])->>'core.reminders.title',
           COALESCE((SELECT value FROM core.config WHERE category = 'general' AND key = 'reminders_from'), '10')
      INTO v_out, v_out2;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> /reminders-Texte]: Text-/Fenster-Read bricht unter core_ro -- %', SQLERRM;
  END;
  IF v_out IS NULL OR v_out2 IS NULL THEN
    RAISE EXCEPTION 'FAIL [core_ro -> /reminders-Texte]: Titel=% Fenster=%', COALESCE(v_out,'<null>'), COALESCE(v_out2,'<null>'); END IF;
  RAISE NOTICE 'PASS [core_ro -> /reminders-Texte (fn_ui_texts + Sprach-Kette + general.reminders_from)]';

  -- (3c-k) /kosten: core.sub_send_cost_report liest den Kosten-Report unter core_ro ueber das DEFINER-Fenster
  -- core.fn_get_llm_cost_report (Grant in util_create_core_ro.sql). Unbekannter Absender -> owner_only (kein Fehler).
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT (core.fn_get_llm_cost_report('{"chat_id":"999999999"}'::jsonb)->>'reason') INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_get_llm_cost_report]: Fenster bricht unter core_ro -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'owner_only' THEN
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_get_llm_cost_report]: erwartet owner_only, got %', COALESCE(v_out,'<null>'); END IF;
  RAISE NOTICE 'PASS [core_ro -> core.fn_get_llm_cost_report (Kosten-Report lesbar)]';

  -- ===== (3d) WS-3 (Onboarding-Sequenzierung): core_ro -> core.fn_onboarding_pending_packages =====
  -- Der Guide bietet nach Haushalts-Abschluss generisch die offenen Paket-Onboardings an -> liest die
  -- Discovery-fn unter core_ro. Das DEFINER-Fenster REVOKEt PUBLIC + grantet NUR core_ro (util_create_core_ro);
  -- kein Paket-Agent konsumiert sie -> finance_ro bleibt bewusst gesperrt (Negativ-Assert unten).
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT (core.fn_onboarding_pending_packages()->>'ok') INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_onboarding_pending_packages]: Fenster bricht unter core_ro -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_onboarding_pending_packages]: erwartet ok=true, got %', COALESCE(v_out,'<null>'); END IF;
  RAISE NOTICE 'PASS [core_ro -> core.fn_onboarding_pending_packages (Discovery-Fenster lesbar)]';

  -- (3d-NEG) finance_ro hat KEINEN EXECUTE-Grant auf die Discovery-fn (REVOKE PUBLIC, nur core_ro) -> denied.
  BEGIN
    SET LOCAL ROLE finance_ro;
    PERFORM core.fn_onboarding_pending_packages();
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro NEGATIV]: finance_ro konnte core.fn_onboarding_pending_packages aufrufen -> unerwarteter Grant!';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'PASS [finance_ro NEGATIV: kein EXECUTE auf core.fn_onboarding_pending_packages (core-host-only)]';
    WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM LIKE 'FAIL %' THEN RAISE; END IF;
      RAISE EXCEPTION 'FAIL [finance_ro NEGATIV]: unerwarteter Fehler statt insufficient_privilege: %', SQLERRM;
  END;

  -- ===== (3e-PLAN) Onboarding-Plan-Schritt: core_ro -> core.fn_advisor_plan_status(chat_id) (Menue-Read, DEFINER-Fenster)
  -- ruft die Paket-fns gaps_fn/readiness_fn dynamisch (liest agent.advisor_plans mit RLS + finance.*).
  -- Absender = der Datei-Fixture-Owner (telegram_user_id 777, oben).
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step, gaps_fn, readiness_fn)
  VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', true,
          'finance.fn_plan_gap_count', 'finance.fn_plan_readiness')
  ON CONFLICT (domain) DO UPDATE SET plan_step = true, gaps_fn = EXCLUDED.gaps_fn, readiness_fn = EXCLUDED.readiness_fn;
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES ('finance', NULL, '__t_role_plan', 'active', 99, '{"risk_profile":{"content":"x"}}', 'p')
  ON CONFLICT DO NOTHING;
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT e->>'state' INTO v_out
    FROM jsonb_array_elements(core.fn_advisor_plan_status('777')) e WHERE e->>'domain' = 'finance';
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_advisor_plan_status]: %', SQLERRM;
  END;
  IF v_out IS NULL OR v_out NOT IN ('gaps', 'complete', 'draft') THEN
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_advisor_plan_status]: erwartet Plan-Zustand, got %', COALESCE(v_out, '<null>'); END IF;
  RAISE NOTICE 'PASS [core_ro -> core.fn_advisor_plan_status (gaps_fn/readiness_fn ueber das DEFINER-Fenster)]';

  -- ===== (3e) P1 (Generisches Paket-Onboarding): core_ro -> core.fn_onboarding_overview =====
  -- core.sub_send_onboarding_menu (laeuft unter core_ro) liest das DB-getriebene Menue-Modell ueber dieses
  -- DEFINER-Fenster (P2b-1: Arity (text DEFAULT NULL); no-arg-Call resolved via Default = alle per_user-Sektionen
  -- 'unknown'). REVOKE PUBLIC in der R__, EXECUTE-Grant nur core_ro (util_create_core_ro) ->
  -- sonst stiller permission denied zur Laufzeit (Opus-Plan-Review M3).
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT (core.fn_onboarding_overview()->>'ok') INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_onboarding_overview]: Fenster bricht unter core_ro -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_onboarding_overview]: erwartet ok=true, got %', COALESCE(v_out,'<null>'); END IF;
  RAISE NOTICE 'PASS [core_ro -> core.fn_onboarding_overview (Menue-Modell lesbar)]';

  -- (3e-NEG) finance_ro hat KEINEN EXECUTE-Grant (REVOKE PUBLIC, nur core_ro) -> denied.
  BEGIN
    SET LOCAL ROLE finance_ro;
    PERFORM core.fn_onboarding_overview();
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro NEGATIV]: finance_ro konnte core.fn_onboarding_overview aufrufen -> unerwarteter Grant!';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'PASS [finance_ro NEGATIV: kein EXECUTE auf core.fn_onboarding_overview (core-host-only)]';
    WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM LIKE 'FAIL %' THEN RAISE; END IF;
      RAISE EXCEPTION 'FAIL [finance_ro NEGATIV]: unerwarteter Fehler statt insufficient_privilege: %', SQLERRM;
  END;

  -- ===== (3e2) Install-UX-Phase 6 + Textkatalog Phase B: core_ro -> core.fn_render_welcome(text) + core.help_catalog =====
  -- Der Orchestrator liest die Owner-Begruessung im /start-Zweig ('Start onboarding read') und die /help-Uebersicht
  -- ('Load capabilities', core.help_catalog) unter core_ro. REVOKE PUBLIC in der R__, Grant am Rollen-Ort
  -- util_create_core_ro -> ohne ihn stiller permission denied.
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT (core.fn_render_welcome('ko')->>'ok') INTO v_out;
    PERFORM count(*) FROM core.help_catalog;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_render_welcome]: bricht unter core_ro -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_render_welcome]: erwartet ok=true, got %', COALESCE(v_out,'<null>'); END IF;
  RAISE NOTICE 'PASS [core_ro -> core.fn_render_welcome (Owner-Begruessung lesbar)]';

  -- (3e2-NEG) finance_ro hat KEINEN EXECUTE-Grant (REVOKE PUBLIC, nur core_ro) -> denied.
  BEGIN
    SET LOCAL ROLE finance_ro;
    PERFORM core.fn_render_welcome('de');
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro NEGATIV]: finance_ro konnte core.fn_render_welcome aufrufen -> unerwarteter Grant!';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'PASS [finance_ro NEGATIV: kein EXECUTE auf core.fn_render_welcome (core-host-only)]';
    WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM LIKE 'FAIL %' THEN RAISE; END IF;
      RAISE EXCEPTION 'FAIL [finance_ro NEGATIV]: unerwarteter Fehler statt insufficient_privilege: %', SQLERRM;
  END;

  -- ===== (3e2b) Fix C: core_ro -> agent.fn_get_hitl_pending_state(bigint) =====
  -- Der Orchestrator-Pre-Router ('Card open check') liest die Karte-offen-Sperre unter core_ro. REVOKE PUBLIC in
  -- der R__, Grant am Rollen-Ort util_create_core_ro; INVOKER liest agent.hitl_pending ueber den agent.*-SELECT.
  INSERT INTO agent.hitl_pending (chat_id, execution_id, expires_at) VALUES (900199, 'role-test', now() + interval '5 minutes');
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT agent.fn_get_hitl_pending_state(900199) INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> agent.fn_get_hitl_pending_state]: bricht unter core_ro -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'own' THEN
    RAISE EXCEPTION 'FAIL [core_ro -> agent.fn_get_hitl_pending_state]: erwartet own, got %', COALESCE(v_out,'<null>'); END IF;
  RAISE NOTICE 'PASS [core_ro -> agent.fn_get_hitl_pending_state (Karte-offen-Sperre lesbar)]';

  -- ===== (3e3) Phase A: core_ro -> core.fn_stale_facts_count() =====
  -- fn_monitor_acquire fuehrt die gespeicherte Spec des Core-Triggers household_facts_freshness unter
  -- SET LOCAL ROLE core_ro aus; die fn liest agent.core_contexts + core.context_validators/_scopes/package_registry.
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT core.fn_stale_facts_count()::text INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_stale_facts_count]: bricht unter core_ro -- %', SQLERRM;
  END;
  IF v_out IS NULL THEN
    RAISE EXCEPTION 'FAIL [core_ro -> core.fn_stale_facts_count]: kein Zaehler geliefert'; END IF;
  RAISE NOTICE 'PASS [core_ro -> core.fn_stale_facts_count (Aktualitaets-Waechter ausfuehrbar)]';

  -- ===== (3f) P2b-1 (Career-Onboarding pro Person): career_ro -> core.fn_onboarding_status(text, text) =====
  -- BLOCKER-Verifikation: P2b-1 aenderte die Arity (text)->(text, text DEFAULT NULL); core:V016 droppt die alte
  -- Form, util_create_core_ro + fn_provision_package_roles re-pinnen die EXECUTE-Grants auf die NEUE Arity. Ein
  -- arity-pinned Grant, der nach dem DROP verwaist, faellt unter Superuser-db_test NICHT auf (Rollen-Perspektiv-
  -- Pflicht) -> hier explizit unter career_ro (das publizierte Onboarding-Lesefenster bekommt EXECUTE via
  -- fn_provision_package_roles('career')). Die Calls oben (Zeile ~101/165 finance_ro/core_ro 'finance', ~213
  -- core_ro overview) binden via DEFAULT-Arg ebenfalls an die neue Arity -> decken finance_ro/core_ro mit ab.
  BEGIN
    SET LOCAL ROLE career_ro;
    SELECT (core.fn_onboarding_status('career', '111')->>'ok') INTO v_out;   -- 2-arg (per_user); DEFINER -> career_ro braucht nur EXECUTE
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [career_ro -> core.fn_onboarding_status(text,text)]: Fenster bricht unter career_ro (Grant nach Arity-Migration verwaist?) -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [career_ro -> core.fn_onboarding_status(text,text)]: erwartet ok=true, got %', COALESCE(v_out,'<null>'); END IF;
  RAISE NOTICE 'PASS [career_ro -> core.fn_onboarding_status(text,text) (P2b-1 per_user-Arity, Grant migriert)]';

  -- ===== (3g) WP-4: career_ro erreicht die Core-DEFINER-Fenster des career_advisor (Spiegel §2 finance_ro) =====
  -- BLOCKER-Klasse wie finance_ro: der career_advisor laeuft unter career_ro und bindet dieselben Core-Fenster
  -- (fn_advisor_read_plan / fn_package_active / fn_config_get, alle EXECUTE via fn_provision_package_roles('career')).
  -- Ein unter career_ro nicht aufrufbares Fenster faellt unter Superuser-db_test NICHT auf (Rollen-Perspektiv-Pflicht).
  -- read_plan ist per_user -> 2-arg (domain, chat_id); '111' unaufgeloest -> Owner-Fallback (kein permission denied
  -- ist das Pruefobjekt, nicht der Inhalt).
  BEGIN
    SET LOCAL ROLE career_ro;
    PERFORM core.fn_advisor_read_plan('career', '111');   -- per_user 2-arg; DEFINER -> career_ro braucht nur EXECUTE
    v_bool := core.fn_package_active('career');
    v_out  := core.fn_config_get('core', 'api', 'core_version');
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [career_ro -> Core-DEFINER-Fenster]: %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [career_ro -> fn_advisor_read_plan/package_active/config_get: kein permission denied]';

  -- (3g-NEG) career_ro darf agent.core_contexts NICHT direkt lesen (D10 dicht, wie finance_ro fuer agent.*)
  BEGIN
    SET LOCAL ROLE career_ro;
    PERFORM 1 FROM agent.core_contexts LIMIT 1;
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [career_ro NEGATIV]: career_ro konnte agent.core_contexts direkt lesen -> zu breites Grant!';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'PASS [career_ro NEGATIV: kein direkter agent.core_contexts-Read (D10 dicht)]';
    WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM LIKE 'FAIL %' THEN RAISE; END IF;
      RAISE EXCEPTION 'FAIL [career_ro NEGATIV]: unerwarteter Fehler statt insufficient_privilege: %', SQLERRM;
  END;

  -- ===== (4) WS-1 Multi-Member: agent.persons-Lesepfad + Cross-Schema-FK unter engen Rollen =====
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'finance_rw') THEN
    RAISE EXCEPTION 'FAIL [role_perms]: Rolle finance_rw nicht provisioniert'; END IF;

  -- (4a) core_ro liest die projizierte agent.persons (util_create_core_ro grantet agent.* SELECT)
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT count(*) INTO v_cnt FROM agent.persons;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> agent.persons]: %', SQLERRM;
  END;
  IF v_cnt < 1 THEN RAISE EXCEPTION 'FAIL [core_ro -> agent.persons]: 0 Zeilen trotz Fixture'; END IF;
  RAISE NOTICE 'PASS [core_ro -> agent.persons-Read (% Zeilen)]', v_cnt;

  -- (4b) finance_rw bucht ein Konto mit GUELTIGEM owner_person_id -> der Cross-Schema-FK greift
  --      OHNE dass finance_rw SELECT auf agent.persons hat (RI-Check ist intern).
  BEGIN
    SET LOCAL ROLE finance_rw;
    INSERT INTO finance.accounts (name, account_type, owner_person_id)
    VALUES ('__rp_acct_ok__', 'cash', '__rp_person__');
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_rw -> FK gueltig]: gueltiger owner_person_id abgelehnt -- %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_rw -> Konto mit gueltigem owner_person_id (FK intern erzwungen)]';

  -- (4c) NEGATIV: finance_rw mit NICHT-existenter Person -> foreign_key_violation
  BEGIN
    SET LOCAL ROLE finance_rw;
    INSERT INTO finance.accounts (name, account_type, owner_person_id)
    VALUES ('__rp_acct_bad__', 'cash', '__rp_nobody__');
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_rw -> FK NEGATIV]: nicht-existente Person akzeptiert -> FK nicht erzwungen!';
  EXCEPTION
    WHEN foreign_key_violation THEN RESET ROLE;  -- erwartet
    WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
      RAISE EXCEPTION 'FAIL [finance_rw -> FK NEGATIV]: unerwarteter Fehler statt foreign_key_violation: %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_rw -> FK NEGATIV: nicht-existente Person abgelehnt]';

  -- (4c2) WS-5c-B: der Zins-Cron laeuft unter finance_rw -> die Zins-Scheduler-fns muessen unter dieser
  --       Rolle aufrufbar sein (Blanket ALL TABLES + EXECUTE via fn_provision_package_roles; v_cnt = Konto-id).
  BEGIN
    SET LOCAL ROLE finance_rw;
    INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__rp_int_acct__', 'cash', 'EUR', 'active') RETURNING id INTO v_cnt;
    INSERT INTO finance.account_interest_rates (account_id, annual_rate, schedule_interval, schedule_unit, valid_from)
    VALUES (v_cnt, 4, 1, 'year', DATE '2026-01-01');
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
    VALUES (v_cnt, 1000, DATE '2026-01-01', 'other');
    PERFORM finance.fn_interest_due_open(DATE '2027-06-30');
    PERFORM finance.fn_interest_amount_due(v_cnt, DATE '2027-01-01');
    PERFORM finance.fn_book_interest_occurrence(jsonb_build_object('account_id', v_cnt, 'value_date', '2027-01-01', 'period_end', '2027-01-01'));
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_rw -> Zins-Scheduler-fns]: %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_rw -> fn_interest_due_open/_amount_due/_book_interest_occurrence aufrufbar]';

  -- (4c3) tool_create_savings_plan laeuft unter finance_rw: Begünstigter = Depot-Inhaber, der NAME fuer die Karte
  --       kommt ueber das Core-Fenster core.fn_household_persons() (kein Direkt-Read auf agent.persons, D10);
  --       der Depot-Kalender (fn_resolve_plan_schedule) wird im selben Write am Depot gespeichert.
  DECLARE v_res JSONB; v_set INT; BEGIN
    SET LOCAL ROLE finance_rw;
    INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__rp_sp_settle__', 'cash', 'EUR', 'active') RETURNING id INTO v_set;
    INSERT INTO finance.accounts (name, account_type, bank, currency, status, settlement_account_id, owner_person_id)
    VALUES ('__rp_sp_depot__', 'stocks_depot', 'Trade Republic', 'EUR', 'active', v_set, '__rp_person__');
    v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__rp_sp_plan__','depot_name','__rp_sp_depot__',
      'isin','IE00B5BMR087','symbol','CSPX','security_name','Beispiel','amount',10,'schedule_unit','week',
      'first_payment_date','2027-01-02'));
    RESET ROLE;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'beneficiary_person_id' IS DISTINCT FROM '__rp_person__'
       OR v_res->>'beneficiary_name' IS NULL THEN
      RAISE EXCEPTION 'FAIL [finance_rw -> fn_create_savings_plan]: %', v_res; END IF;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE EXCEPTION 'FAIL [finance_rw -> fn_create_savings_plan]: %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_rw -> fn_create_savings_plan (Inhaber + Name ueber core.fn_household_persons)]';

  -- (4c4) Woher kommt das Geld? Die ganze Kette unter finance_rw: fn_create_savings_plan -> fn_savings_funding_fold ->
  --       fn_funding_accounts / fn_account_funding (Alltagsausgaben aus dem Auszug) / core.fn_config_get /
  --       core.fn_should_notify (Latch). Konto mit Miete + Auszug (Alltagsausgaben geschaetzt) und Luecke -> Frage.
  DECLARE v_res JSONB; v_set INT; BEGIN
    SET LOCAL ROLE finance_rw;
    INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__rp_sf_settle__', 'cash', 'EUR', 'active') RETURNING id INTO v_set;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_set, 500, CURRENT_DATE - 40, 'other');
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__rp_sf_miete__', v_set, -100, 'month', CURRENT_DATE + 4, CURRENT_DATE + 4);
    INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                         line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
    VALUES (v_set, CURRENT_DATE - 64, CURRENT_DATE - 35, 800, 500, 'EUR', 5, 0, -300, 0, NULL);
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__rp_sf_depot__', 'stocks_depot', 'EUR', 'active', v_set);
    v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__rp_sf_plan__','depot_name','__rp_sf_depot__',
      'isin','IE00B5BMR087','symbol','CSPX','security_name','Beispiel','amount',100,'schedule_unit','month',
      'first_payment_date', (CURRENT_DATE + 5)::text));
    RESET ROLE;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true
       OR NOT (v_res->'savings_funding'->'accounts'->0->>'asked')::boolean
       OR v_res->'savings_funding'->>'note' NOT LIKE '%everyday%' THEN
      RAISE EXCEPTION 'FAIL [finance_rw -> savings_funding-Kette]: %', v_res; END IF;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE EXCEPTION 'FAIL [finance_rw -> savings_funding-Kette]: %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_rw -> fn_create_savings_plan mit Geldquellen-Frage (Alltagsausgaben + Latch)]';

  -- ===== (4d) WS-3a: finance_ro erreicht die Personen-Rolle NUR ueber das Core-DEFINER-Fenster =====
  -- core.fn_household_persons() ist das publizierte Lesefenster (Rollen-Aufloesung fuer den FIRE-Pool-
  -- Ausschluss + Eltern-Scope-Cashflow). finance_ro hat EXECUTE (fn_provision_package_roles), aber KEIN
  -- direktes SELECT auf agent.persons (D10).
  BEGIN
    SET LOCAL ROLE finance_ro;
    SELECT count(*) INTO v_cnt FROM core.fn_household_persons();
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro -> core.fn_household_persons]: Fenster bricht unter finance_ro -- %', SQLERRM;
  END;
  IF v_cnt < 1 THEN
    RAISE EXCEPTION 'FAIL [finance_ro -> core.fn_household_persons]: 0 Zeilen trotz Person-Fixture (Grant ok, aber Read defekt?)'; END IF;
  RAISE NOTICE 'PASS [finance_ro -> core.fn_household_persons (% Zeilen, Rollen-Aufloesung ueber Fenster)]', v_cnt;

  -- (4d2) "Import zuerst": fn_match_household_holder (INVOKER) liest die Haushaltsnamen ueber dasselbe Fenster -
  -- unter finance_rw (Monats-Check-Prepare im Write-Tool) und finance_ro; die Fixture-Person "RP Person" muss treffen.
  DECLARE v_res JSONB;
  BEGIN
    SET LOCAL ROLE finance_rw;
    v_res := finance.fn_match_household_holder('RP PERSON');
    RESET ROLE;
    IF v_res->>'owner_person_id' IS DISTINCT FROM '__rp_person__' THEN
      RAISE EXCEPTION 'FAIL [finance_rw -> fn_match_household_holder]: kein Treffer: %', v_res; END IF;
    SET LOCAL ROLE finance_ro;
    v_res := finance.fn_match_household_holder('Person, RP');
    RESET ROLE;
    IF v_res->>'owner_person_id' IS DISTINCT FROM '__rp_person__' THEN
      RAISE EXCEPTION 'FAIL [finance_ro -> fn_match_household_holder]: kein Treffer: %', v_res; END IF;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE EXCEPTION 'FAIL [finance_rw/_ro -> fn_match_household_holder]: %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_rw/_ro -> fn_match_household_holder (Namen ueber core.fn_household_persons)]';

  -- (4e) finance_ro liest die Eltern-Scope-Cashflow-View (joint das Fenster) ohne permission denied
  BEGIN
    SET LOCAL ROLE finance_ro;
    PERFORM 1 FROM finance.parent_cashflow_overview LIMIT 1;
    PERFORM 1 FROM finance.parent_cashflow_summary LIMIT 1;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro -> parent_cashflow]: View mit fn_household_persons-Join bricht unter finance_ro -- %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_ro -> parent_cashflow_overview/_summary (View ueber DEFINER-Fenster lesbar)]';

  -- (4e2) WS-B: finance_ro liest savings_goal_progress (Depot-Anteil jetzt aus savings_goal_reserve_entries-Journal).
  -- View laeuft mit Owner-Rechten -> finance_ro braucht nur SELECT auf die View, nicht auf die Journal-Basistabelle.
  BEGIN
    SET LOCAL ROLE finance_ro;
    PERFORM 1 FROM finance.savings_goal_progress LIMIT 1;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro -> savings_goal_progress]: View (joint Reserve-Journal) bricht unter finance_ro -- %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_ro -> savings_goal_progress (Depot-Reserve-Journal-Term lesbar)]';

  -- (4e2b) WS-B: finance_ro liest die neuen Reserve-Views depot_reserve_status (Deckungs-Waechter) +
  -- savings_goal_reserve_breakdown (Cash-/Depot-Aufschluesselung je Ziel). Schema-weiter finance-GRANT.
  BEGIN
    SET LOCAL ROLE finance_ro;
    PERFORM 1 FROM finance.depot_reserve_status LIMIT 1;
    PERFORM 1 FROM finance.savings_goal_reserve_breakdown LIMIT 1;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro -> depot_reserve_status/reserve_breakdown]: View bricht unter finance_ro -- %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_ro -> depot_reserve_status + savings_goal_reserve_breakdown (Deckung + Aufschluesselung lesbar)]';

  -- (4e2c) Livebefund 2026-10-27: finance_ro (postgres_select des Buchhalters/Beraters) liest die Sparplan-Uebersicht
  -- (Rhythmus in Klartext, fn_schedule_label + fn_recurring_* in der View) und active_recurring_payments.rhythm;
  -- finance_rw ruft fn_goal_transfer_candidates (aus fn_create/set_savings_goal unter der Tool-Rolle).
  BEGIN
    SET LOCAL ROLE finance_ro;
    PERFORM rhythm, next_execution FROM finance.savings_plan_overview LIMIT 1;
    PERFORM rhythm FROM finance.active_recurring_payments LIMIT 1;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro -> savings_plan_overview/rhythm]: bricht unter finance_ro -- %', SQLERRM;
  END;
  BEGIN
    SET LOCAL ROLE finance_rw;
    PERFORM finance.fn_goal_transfer_candidates(NULL, NULL);
    PERFORM finance.fn_goal_transfer_choice(NULL, NULL, NULL);
    PERFORM finance.fn_savings_goal_funding('{"target_amount":1000,"target_date":"2099-01-01"}'::jsonb, NULL, false, NULL, 0);
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_rw -> fn_goal_transfer_candidates]: bricht unter finance_rw -- %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_ro -> savings_plan_overview + rhythm; finance_rw -> fn_goal_transfer_candidates]';

  -- (4e3) WS-C2: finance_ro liest die neue account_reserve_status-View (Drill-down „welche Ziele liegen auf
  -- dem Konto?"). Gedeckt vom schema-weiten finance-GRANT (kein per-View-GRANT) -> Backstop fuer Opus-Review #3.
  BEGIN
    SET LOCAL ROLE finance_ro;
    PERFORM 1 FROM finance.account_reserve_status LIMIT 1;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro -> account_reserve_status]: View bricht unter finance_ro -- %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_ro -> account_reserve_status (Reserve-Waechter-Drill-down lesbar)]';

  -- (4e4) Phase L / Audit Paket 3: finance_ro liest die Cashflow-Klassifikation (recurring_cashflow_classified) +
  -- beide Summen (Familie monthly_cashflow_summary, Eltern parent_cashflow_summary; Konsum/Tilgung/Sparen getrennt).
  -- Gedeckt vom schema-weiten finance-GRANT (kein per-View-GRANT) -> Backstop, dass der Advisor sie via
  -- postgres_select referenzieren kann. parent_* liest core.fn_household_persons() (DEFINER-Fenster).
  BEGIN
    SET LOCAL ROLE finance_ro;
    PERFORM 1 FROM finance.recurring_cashflow_classified LIMIT 1;
    PERFORM monthly_free, monthly_account_change FROM finance.monthly_cashflow_summary LIMIT 1;
    PERFORM monthly_obligations FROM finance.parent_cashflow_summary LIMIT 1;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro -> cashflow views]: View bricht unter finance_ro -- %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_ro -> recurring_cashflow_classified + monthly_/parent_cashflow_summary lesbar]';

  -- (4f) NEGATIV: finance_ro darf agent.persons NICHT direkt lesen (D10 dicht — wie agent.monitor_triggers)
  BEGIN
    SET LOCAL ROLE finance_ro;
    PERFORM 1 FROM agent.persons LIMIT 1;
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro NEGATIV]: finance_ro konnte agent.persons direkt lesen -> zu breites Grant!';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'PASS [finance_ro NEGATIV: kein direkter agent.persons-Read (D10 dicht)]';
    WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM LIKE 'FAIL %' THEN RAISE; END IF;
      RAISE EXCEPTION 'FAIL [finance_ro NEGATIV]: unerwarteter Fehler statt insufficient_privilege: %', SQLERRM;
  END;

  -- ===== (4g) WS-4: core.fn_resolve_person ist unter BEIDEN engen Paket-Rollen aufrufbar =====
  -- Der Personen-Resolver der create_*/set_*-Tools liegt in CORE (nicht agent), weil finance_rw/ro
  -- KEIN USAGE auf agent haben (D10) — agent.* waere unaufrufbar. Hier: EXECUTE-Erreichbarkeit unter
  -- finance_rw (Write-Pfad) UND finance_ro. (Resolve-Logik selbst -> test_fn_household_facts mit family-Fixture.)
  BEGIN
    SET LOCAL ROLE finance_rw;
    PERFORM hit_count FROM core.fn_resolve_person('__rp_irgendwer__');
    -- Selbstbezug-Pfad (core:V033): liest agent.fn_resolve_sender im DEFINER-Kontext, nie direkt unter finance_rw
    PERFORM hit_count FROM core.fn_resolve_person('ich', '4242');
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_rw -> core.fn_resolve_person]: Fenster bricht unter finance_rw -- %', SQLERRM;
  END;
  BEGIN
    SET LOCAL ROLE finance_ro;
    PERFORM hit_count FROM core.fn_resolve_person('__rp_irgendwer__');
    -- Renteninformation (Plan 2026-10-26): Berater-Fenster + Erinnerungs-Faelligkeit laufen unter finance_ro
    -- (Advisor-postgres_select, cron_remind_pension_statement) -- ohne agent.*-Zugriff (Inflation kommt als Argument).
    PERFORM finance.fn_pension_outlook('{"inflation_pct":2}'::jsonb);
    PERFORM finance.fn_pension_statements_due();
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro -> core.fn_resolve_person]: Fenster bricht unter finance_ro -- %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_rw/finance_ro -> core.fn_resolve_person (DEFINER-Fenster aufrufbar, D10)]';

  -- ===== (4g2) Import mit Personen-Feld unter finance_rw (stage -> bundle) =====
  -- fn_import_validate_row faengt JEDEN Fehler als Row-Fehler (EXCEPTION WHEN OTHERS) -> ein Rechte-Fehler
  -- des Personen-Resolvers wuerde als "invalid payload" verschluckt. Hier: die Zeile muss VALID sein und
  -- der Commit den Slug setzen — beides unter der Tool-Rolle.
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('managed_by', 'agent', 'protected', true, 'render_fn', 'fn_household_context',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','__rp_imp_p','first_name','Rolli','last_name','Rechtetest',
                                 'role','owner','birth_date','1980-01-01','as_of','2026-10-21')))))
  ON CONFLICT (name) DO UPDATE   -- Person ANHAENGEN (Ersetzen wuerde Fixture-Personen frueherer Bloecke entprojizieren)
    SET metadata = jsonb_set(agent.core_contexts.metadata, '{facts,persons}',
          COALESCE(agent.core_contexts.metadata->'facts'->'persons', '[]'::jsonb) || (EXCLUDED.metadata->'facts'->'persons'));
  DECLARE v_imp JSONB; BEGIN
    SET LOCAL ROLE finance_rw;
    v_imp := finance.fn_import_stage(jsonb_build_object('rows', jsonb_build_array(
      jsonb_build_object('entity_type','account','name','__rp_imp_acct','account_type','cash',
                         'owner_person','Rolli Rechtetest','opening_balance',10))));
    IF (v_imp->>'valid')::int IS DISTINCT FROM 1 THEN
      RESET ROLE;
      RAISE EXCEPTION 'FAIL [finance_rw import stage mit Person]: Zeile nicht valid -- %', v_imp;
    END IF;
    -- Import-Karte (tool_commit_import 'Load batch summary') unter derselben Rolle: Personenname ueber das Fenster
    IF finance.fn_import_card_rows((v_imp->>'batch_id')::uuid)->0->'x'->>'person' IS DISTINCT FROM 'Rolli Rechtetest' THEN
      RESET ROLE;
      RAISE EXCEPTION 'FAIL [finance_rw fn_import_card_rows]: Personenname fehlt -- %', finance.fn_import_card_rows((v_imp->>'batch_id')::uuid);
    END IF;
    -- Depot-Waehrung fuers Yahoo-Listing ('Load positions', finance_rw): kein Depot im Batch -> EUR, ohne Rechtefehler
    IF finance.fn_import_depot_currency((v_imp->>'batch_id')::uuid, '__rp_imp_kein_depot') IS DISTINCT FROM 'EUR' THEN
      RESET ROLE;
      RAISE EXCEPTION 'FAIL [finance_rw fn_import_depot_currency]: EUR erwartet';
    END IF;
    -- Probelauf vor der Karte (Import-Haertung 2026-10-22) unter derselben Rolle: ok, nichts geschrieben
    IF (finance.fn_import_bundle(jsonb_build_object('batch_id', v_imp->>'batch_id', 'dry_run', true))->>'ok')::boolean IS DISTINCT FROM true
       OR EXISTS (SELECT 1 FROM finance.accounts WHERE name = '__rp_imp_acct') THEN
      RESET ROLE;
      RAISE EXCEPTION 'FAIL [finance_rw import dry run]: Probelauf muss ok sein und darf nichts schreiben';
    END IF;
    v_imp := finance.fn_import_bundle(jsonb_build_object('batch_id', v_imp->>'batch_id'));
    RESET ROLE;
    IF (v_imp->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT owner_person_id FROM finance.accounts WHERE name = '__rp_imp_acct') IS DISTINCT FROM '__rp_imp_p' THEN
      RAISE EXCEPTION 'FAIL [finance_rw import bundle mit Person]: %', v_imp;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM LIKE 'FAIL %' THEN RAISE; END IF;
    RAISE EXCEPTION 'FAIL [finance_rw import mit Person]: %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_rw: Import stage -> card_rows -> bundle mit owner_person (Resolver + Bestandsuebernahme-Pfad)]';

  -- ===== (4g3) Depot-Position nur mit ISIN + gedruckter Depotnummer/Inhaber unter finance_rw (2026-10-23) =====
  -- fn_import_resolve_depot (Inhaber ueber das core.fn_resolve_person-Fenster), fn_import_depot_conflict,
  -- fn_holding_symbol, fn_import_depot_number_to_store und fn_set_account im Bundle laufen unter der Tool-Rolle.
  DECLARE v_imp JSONB; v_cash INT; BEGIN
    v_cash := (finance.fn_create_account('{"name":"__rp_isin_cash","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
    PERFORM finance.fn_create_account(jsonb_build_object('name','__rp_isin_depot','account_type','stocks_depot',
      'settlement_id', v_cash, 'owner_person_id', '__rp_imp_p'));
    SET LOCAL ROLE finance_rw;
    v_imp := finance.fn_import_stage(jsonb_build_object('source','vision','rows', jsonb_build_array(
      jsonb_build_object('entity_type','stock_buy','depot','__rp_falsch_geraten','depot_number','7777000011',
                         'depot_holder','Rolli Rechtetest','isin','IE00BYML9W36','shares',3,'price_per_share',60))));
    IF (v_imp->>'valid')::int IS DISTINCT FROM 1
       OR finance.fn_import_card_rows((v_imp->>'batch_id')::uuid)->0->'x'->>'depot_number_to_store' IS DISTINCT FROM '7777000011' THEN
      RESET ROLE;
      RAISE EXCEPTION 'FAIL [finance_rw import ISIN-only]: Zeile/Karte -- %', v_imp;
    END IF;
    v_imp := finance.fn_import_bundle(jsonb_build_object('batch_id', v_imp->>'batch_id'));
    RESET ROLE;
    IF (v_imp->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT account_number FROM finance.accounts WHERE name = '__rp_isin_depot') IS DISTINCT FROM '7777000011'
       OR NOT EXISTS (SELECT 1 FROM finance.depot_holdings h JOIN finance.accounts a ON a.id = h.account_id
                      WHERE a.name = '__rp_isin_depot' AND h.symbol = 'IE00BYML9W36') THEN
      RAISE EXCEPTION 'FAIL [finance_rw import ISIN-only bundle]: %', v_imp;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM LIKE 'FAIL %' THEN RAISE; END IF;
    RAISE EXCEPTION 'FAIL [finance_rw import ISIN-only]: %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_rw: Import ISIN-only -> Depot per Inhaber, Nummer gespeichert, Kennung = ISIN]';

  -- ===== (4g4) Cash-Stand einer Depot-Uebersicht unter finance_rw (2026-10-23): fn_import_balance_targets (Depot per
  -- Inhaber ueber das core.fn_resolve_person-Fenster, Saldo zum Datum, fn_reconcile_open_due) ohne Rechtefehler.
  DECLARE v_bt JSONB; BEGIN
    SET LOCAL ROLE finance_rw;
    v_bt := finance.fn_import_balance_targets(NULL, jsonb_build_array(jsonb_build_object(
              'depot_holder', 'Rolli Rechtetest', 'balance', 5, 'balance_date', to_char(CURRENT_DATE, 'YYYY-MM-DD'))));
    RESET ROLE;
    IF (v_bt->0->>'ok')::boolean IS DISTINCT FROM true OR v_bt->0->>'account_name' IS DISTINCT FROM '__rp_isin_cash' THEN
      RAISE EXCEPTION 'FAIL [finance_rw fn_import_balance_targets]: %', v_bt;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM LIKE 'FAIL %' THEN RAISE; END IF;
    RAISE EXCEPTION 'FAIL [finance_rw fn_import_balance_targets]: %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_rw: Cash-Stand -> Verrechnungskonto (fn_import_balance_targets)]';

  -- ===== (4g5) Anlageklassen-Zuordnung unter finance_rw (2026-10-23): fn_set_asset_classes (fn_find_holding,
  -- fn_set_holding, core.fn_ui_tpl fuer die Kartenzeilen) ueber core.fn_dry_run wie im Tool-Gate, dann der Write.
  DECLARE v_sa JSONB; BEGIN
    SET LOCAL ROLE finance_rw;
    v_sa := core.fn_dry_run('finance.fn_set_asset_classes(jsonb)'::regprocedure, '{"assignments":[{"depot_name":"__rp_isin_depot","position":"IE00BYML9W36","asset_class":"outside_plan"}]}'::jsonb);
    IF (v_sa->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_sa->'card_lines') <> 1 THEN
      RESET ROLE;
      RAISE EXCEPTION 'FAIL [finance_rw fn_set_asset_classes dry run]: %', v_sa;
    END IF;
    v_sa := finance.fn_set_asset_classes('{"assignments":[{"depot_name":"__rp_isin_depot","position":"IE00BYML9W36","asset_class":"outside_plan"}]}'::jsonb);
    RESET ROLE;
    IF (v_sa->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT h.asset_class FROM finance.depot_holdings h JOIN finance.accounts a ON a.id = h.account_id
           WHERE a.name = '__rp_isin_depot' AND h.symbol = 'IE00BYML9W36') IS DISTINCT FROM 'outside_plan' THEN
      RAISE EXCEPTION 'FAIL [finance_rw fn_set_asset_classes]: %', v_sa;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM LIKE 'FAIL %' THEN RAISE; END IF;
    RAISE EXCEPTION 'FAIL [finance_rw fn_set_asset_classes]: %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_rw: Anlageklassen-Zuordnung (fn_set_asset_classes, Probelauf + Write)]';

  -- ===== (4h) Phase Notify: geteilte Notify-Schicht-Schreibfenster + Cross-Schema-Saldo-Trigger =====
  -- finance_rw erreicht core.notification_state NUR ueber die DEFINER-Fenster fn_should_notify/fn_notify_resolve
  -- (kein direktes Tabellenrecht, D10). Positiv: beide Fenster unter finance_rw aufrufbar.
  BEGIN
    SET LOCAL ROLE finance_rw;
    PERFORM core.fn_should_notify('__rp_test__', 'k', interval '1 hour');
    PERFORM core.fn_notify_resolve('__rp_test__', 'k');
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_rw -> core.fn_should_notify/resolve]: Fenster bricht unter finance_rw -- %', SQLERRM;
  END;
  -- Negativ: direktes SELECT auf core.notification_state ist finance_rw verwehrt (nur ueber die Fenster).
  BEGIN
    SET LOCAL ROLE finance_rw;
    PERFORM 1 FROM core.notification_state LIMIT 1;
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_rw NEGATIV]: finance_rw konnte core.notification_state direkt lesen -> zu breites Grant!';
  EXCEPTION
    WHEN insufficient_privilege THEN RESET ROLE;  -- erwartet
    WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
      RAISE;
  END;
  RAISE NOTICE 'PASS [finance_rw -> Notify-Fenster aufrufbar; direkter notification_state-Read verwehrt (D10)]';

  -- Cross-Schema-Trigger (Plan-Trap 2): ein echter finance.transactions-INSERT unter finance_rw feuert den
  -- Saldo-Trigger, der core.fn_notify_resolve (DEFINER) ruft -> muss OHNE permission denied laufen UND den
  -- Latch re-armen, wenn das Konto nicht (mehr) breached. Beweist die Cross-Schema-Callability aus dem Trigger-Body.
  DECLARE v_acct INT;
  BEGIN
    v_acct := (finance.fn_create_account('{"name":"__rp_trig__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
    PERFORM core.fn_should_notify('finance', 'reserve_breach:' || v_acct);   -- Latch vorab setzen (als waere gemeldet)
    SET LOCAL ROLE finance_rw;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
      VALUES (v_acct, 100, current_date, 'other', 'rp trig');               -- Inflow -> Saldo 100, reserved 0 -> kein Breach
    RESET ROLE;
    IF (SELECT state FROM core.notification_state WHERE source='finance' AND key='reserve_breach:'||v_acct) IS DISTINCT FROM 'ok' THEN
      RAISE EXCEPTION 'FAIL [trigger re-arm]: Saldo-Trigger hat den Latch nicht via core.fn_notify_resolve re-armed';
    END IF;
    RAISE NOTICE 'PASS [Cross-Schema-Saldo-Trigger -> core.fn_notify_resolve unter finance_rw, Re-Arm ok]';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE EXCEPTION 'FAIL [Cross-Schema-Trigger]: %', SQLERRM;
  END;

  -- ===== (5) WS-5d: agent.access_blocks-Lesepfad unter den engen Rollen =====
  -- (5a) core_ro liest die Sperrliste (breite Core-Leserolle; agent.* SELECT-Grant + expliziter Init-Grant).
  BEGIN
    SET LOCAL ROLE core_ro;
    SELECT count(*) INTO v_cnt FROM agent.access_blocks;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [core_ro -> agent.access_blocks]: %', SQLERRM;
  END;
  IF v_cnt < 1 THEN RAISE EXCEPTION 'FAIL [core_ro -> agent.access_blocks]: 0 Zeilen trotz Fixture'; END IF;
  RAISE NOTICE 'PASS [core_ro -> agent.access_blocks-Read (% Zeilen)]', v_cnt;

  -- (5b) NEGATIV: finance_ro darf agent.access_blocks NICHT direkt lesen (D10 dicht, wie agent.persons)
  BEGIN
    SET LOCAL ROLE finance_ro;
    PERFORM 1 FROM agent.access_blocks LIMIT 1;
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_ro NEGATIV]: finance_ro konnte agent.access_blocks direkt lesen -> zu breites Grant!';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'PASS [finance_ro NEGATIV: kein direkter agent.access_blocks-Read (D10 dicht)]';
    WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM LIKE 'FAIL %' THEN RAISE; END IF;
      RAISE EXCEPTION 'FAIL [finance_ro NEGATIV]: unerwarteter Fehler statt insufficient_privilege: %', SQLERRM;
  END;

  -- ===== (6) INVOKER-Write-Pfad fn_set_onboarding_section unter der ENGEN Paket-RW-Rolle =====
  -- P2b-1-Regression (gefunden estate WS-1): die fn leitet den per_user-Scope aus core.context_scopes ab
  -- (SECURITY INVOKER) -> ohne SELECT-Grant an <pkg>_rw crasht der Onboarding-Marker JEDES Paket-Tools
  -- ('permission denied for table context_scopes'; finance war latent betroffen, der Superuser-db_test sah
  -- es nie). Grant lebt generisch in fn_provision_package_roles; hier je RW-Rolle der ECHTE Write-Beweis.
  BEGIN
    SET LOCAL ROLE finance_rw;
    PERFORM core.fn_set_onboarding_section(jsonb_build_object(
      'package','finance','section_key','__rp_sec__','status','completed'));
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_rw -> fn_set_onboarding_section]: % (context_scopes-SELECT-Grant in fn_provision_package_roles fehlt?)', SQLERRM;
  END;
  SELECT count(*) INTO v_cnt FROM finance.onboarding_state WHERE section_key = '__rp_sec__' AND status = 'completed';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [finance_rw -> fn_set_onboarding_section]: Write kam nicht an (ok:false?)'; END IF;
  RAISE NOTICE 'PASS [finance_rw -> fn_set_onboarding_section (INVOKER-Write inkl. context_scopes-Read)]';
  -- (6b) owner_only-Riegel fuer Haushalts-Sektionen unter der ENGEN Rolle: das Mitglied (Partner 779) wird ueber
  -- das DEFINER-Fenster core.fn_check_write_permission abgelehnt, ohne 'permission denied for schema agent'.
  BEGIN
    SET LOCAL ROLE finance_rw;
    SELECT core.fn_set_onboarding_section(jsonb_build_object(
      'package','finance','section_key','__rp_sec__','status','skipped','chat_id','779')) INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [finance_rw -> fn_set_onboarding_section Mitglied]: % (core.fn_check_write_permission-Grant fehlt?)', SQLERRM;
  END;
  IF (v_out::jsonb)->>'reason' IS DISTINCT FROM 'owner_only' THEN
    RAISE EXCEPTION 'FAIL [finance_rw -> fn_set_onboarding_section Mitglied]: owner_only erwartet, bekam %', v_out; END IF;
  SELECT count(*) INTO v_cnt FROM finance.onboarding_state WHERE section_key = '__rp_sec__' AND status = 'completed';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [finance_rw -> fn_set_onboarding_section Mitglied]: Status wurde trotzdem geaendert'; END IF;
  RAISE NOTICE 'PASS [finance_rw -> fn_set_onboarding_section Mitglied -> owner_only (Fenster unter enger Rolle)]';

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'estate_rw') THEN
    RAISE EXCEPTION 'FAIL [role_perms]: Rolle estate_rw nicht provisioniert (Substrat kaputt)'; END IF;
  BEGIN
    SET LOCAL ROLE estate_rw;
    PERFORM core.fn_set_onboarding_section(jsonb_build_object(
      'package','estate','section_key','__rp_sec__','status','completed'));
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_set_onboarding_section]: % (context_scopes-SELECT-Grant in fn_provision_package_roles fehlt?)', SQLERRM;
  END;
  SELECT count(*) INTO v_cnt FROM estate.onboarding_state WHERE section_key = '__rp_sec__' AND status = 'completed';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [estate_rw -> fn_set_onboarding_section]: Write kam nicht an (ok:false?)'; END IF;
  RAISE NOTICE 'PASS [estate_rw -> fn_set_onboarding_section (INVOKER-Write inkl. context_scopes-Read)]';

  -- ===== (7) estate WS-2: publiziertes Permission-Fenster + Register-Write unter estate_rw =====
  -- Die estate-Write-fns laufen unter estate_rw und pruefen den adults_only-Backstop ueber das
  -- NEUE DEFINER-Fenster core.fn_check_write_permission (das agent-Primitiv ist per D10 gesperrt).
  -- Superuser-db_test saehe einen fehlenden Grant NIE (Rollen-Perspektiv-Pflicht + Lektion (d):
  -- neue core-Registry/Fenster ⟹ SOFORT Perspektiv-Test unter der engen Rolle).
  -- (7a) Fenster liefert unter estate_rw ECHTE Verdikte (liest family via DEFINER): Kind 778 -> reject, Owner 777 -> ok.
  BEGIN
    SET LOCAL ROLE estate_rw;
    SELECT core.fn_check_write_permission('adults_only', '778', NULL) INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [estate_rw -> core.fn_check_write_permission]: Fenster bricht unter estate_rw (Grant in fn_provision_package_roles fehlt?) -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'adults_only' THEN
    RAISE EXCEPTION 'FAIL [estate_rw -> check_write_permission/child]: erwartet adults_only, got %', COALESCE(v_out, '<null>'); END IF;
  BEGIN
    SET LOCAL ROLE estate_rw;
    SELECT core.fn_check_write_permission('adults_only', '777', NULL) INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [estate_rw -> core.fn_check_write_permission/owner]: %', SQLERRM;
  END;
  IF v_out IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [estate_rw -> check_write_permission/owner]: erwartet NULL (erlaubt), got %', v_out; END IF;
  -- WS-5 Member-Pfad: der ueberlebende PARTNER (779) ist Erwachsener -> MUSS passieren (NULL). Der Kern
  -- des Break-Glass (Owner-Entscheid 8): nicht nur der Owner, auch der gepairte Partner zieht die Mappe.
  BEGIN
    SET LOCAL ROLE estate_rw;
    SELECT core.fn_check_write_permission('adults_only', '779', NULL) INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [estate_rw -> core.fn_check_write_permission/partner]: %', SQLERRM;
  END;
  IF v_out IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [estate_rw -> check_write_permission/partner]: erwartet NULL (Partner=Erwachsener erlaubt), got %', v_out; END IF;
  RAISE NOTICE 'PASS [estate_rw -> core.fn_check_write_permission (Kind reject, Owner ok, Partner ok = Break-Glass)]';

  -- (7b) ECHTER Register-Write unter estate_rw: die ganze Kette (Fenster + INSERT + Sequenz + Touch-Trigger).
  BEGIN
    SET LOCAL ROLE estate_rw;
    SELECT (estate.fn_create_contact(jsonb_build_object(
      'chat_id','777', 'name','__rp_contact__', 'role','trusted_person'))->>'ok') INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [estate_rw -> estate.fn_create_contact]: Register-Write bricht unter estate_rw -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_create_contact]: erwartet ok=true, got %', COALESCE(v_out, '<null>'); END IF;
  SELECT count(*) INTO v_cnt FROM estate.contacts WHERE name = '__rp_contact__';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [estate_rw -> fn_create_contact]: Zeile fehlt'; END IF;
  RAISE NOTICE 'PASS [estate_rw -> estate.fn_create_contact (voller Write-Pfad unter der engen Rolle)]';

  -- (7b2) BLOCKER-Regression (Cold-Eyes WS-2): die PERSON-skopierten Write-fns (set_person_record/
  -- set_funeral_preferences/confirm_review) sind SECURITY INVOKER und liefen frueher gegen agent.persons
  -- ('SELECT 1 FROM agent.persons') — unter estate_rw ohne agent-USAGE (D10) crasht das mit
  -- 'permission denied for schema agent' auf JEDEN gueltigen Aufruf. Der Superuser-db_test + der 7b-
  -- Contact-Test (der agent.persons NICHT liest) sahen es nie. Hier explizit unter estate_rw fuer eine
  -- REALE Person (__rp_owner__, via family projiziert): MUSS ok:true liefern (FK statt Schema-Read).
  BEGIN
    SET LOCAL ROLE estate_rw;
    SELECT (estate.fn_set_person_record(jsonb_build_object(
      'chat_id','777', 'person_id','__rp_owner__', 'employer','__rp Corp'))->>'ok') INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_set_person_record]: person-skopierte Write-fn bricht unter estate_rw (agent.persons-Read?) -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_set_person_record]: erwartet ok=true, got %', COALESCE(v_out, '<null>'); END IF;
  BEGIN
    SET LOCAL ROLE estate_rw;
    SELECT (estate.fn_confirm_review(jsonb_build_object('chat_id','777', 'person_id','__rp_owner__'))->>'ok') INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_confirm_review]: person-skopierte Write-fn bricht unter estate_rw -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_confirm_review]: erwartet ok=true, got %', COALESCE(v_out, '<null>'); END IF;
  RAISE NOTICE 'PASS [estate_rw -> fn_set_person_record/fn_confirm_review (FK-Backstop statt agent.persons-Read, D10)]';

  -- (7b3) WS-3: der GANZE Ereignisfall-Write-Pfad unter estate_rw. fn_create_case ruft NEBEN
  -- core.fn_check_write_permission das NEUE Fenster core.fn_person_chat_id (subject_is_sender-Guard),
  -- core.fn_household_persons, core.fn_config_get, core.fn_package_active + die estate-Fristen-fns.
  -- Ein fehlender EXECUTE-Grant auf EINES dieser Fenster crasht unter estate_rw ('permission denied ...')
  -- — der Superuser-db_test saehe es NIE (Rollen-Perspektiv-Pflicht + Lektion (a)/(d): neue person-/
  -- cross-schema-lesende Write-fn ⟹ SOFORT unter der engen Rolle exerzieren). Subjekt = __rp_person__
  -- (nicht der Sender 777), bundesland als Parameter (fail-closed-Pfad wird separat db-getestet).
  BEGIN
    SET LOCAL ROLE estate_rw;
    SELECT (estate.fn_create_case(jsonb_build_object(
      'chat_id','777', 'case_type','incapacity', 'subject_person_id','__rp_person__',
      'event_date','2024-01-15', 'bundesland','bayern'))->>'ok') INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [estate_rw -> estate.fn_create_case]: Ereignisfall-Write bricht unter estate_rw (Grant auf fn_person_chat_id/fn_household_persons/fn_config_get/fn_package_active fehlt?) -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_create_case]: erwartet ok=true, got %', COALESCE(v_out, '<null>'); END IF;
  SELECT id INTO v_cnt FROM estate.cases WHERE subject_person_id = '__rp_person__' AND status = 'open';
  -- set_case_task + cancel_case unter estate_rw (adults_only-Backstop + estate-Tabellen-Write).
  BEGIN
    SET LOCAL ROLE estate_rw;
    SELECT (estate.fn_set_case_task(jsonb_build_object('chat_id','777',
      'case_task_id', (SELECT id FROM estate.case_tasks WHERE case_id = v_cnt AND status = 'open' ORDER BY id LIMIT 1),
      'status','done'))->>'ok') INTO v_out;
    IF v_out IS DISTINCT FROM 'true' THEN RESET ROLE; RAISE EXCEPTION 'set_case_task ok<>true: %', COALESCE(v_out,'<null>'); END IF;
    SELECT (estate.fn_cancel_case(jsonb_build_object('chat_id','777','case_id', v_cnt))->>'ok') INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM LIKE 'FAIL %' OR SQLERRM LIKE 'set_case_task%' THEN RAISE; END IF;
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_set_case_task/fn_cancel_case]: bricht unter estate_rw -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_cancel_case]: erwartet ok=true, got %', COALESCE(v_out, '<null>'); END IF;
  RAISE NOTICE 'PASS [estate_rw -> fn_create_case/set_case_task/cancel_case (voller Ereignisfall-Write inkl. fn_person_chat_id, D10)]';

  -- (7b4) WS-5: der gegatete Read-EGRESS + der System-Steckbrief unter estate_rw. Das Export-Tool laeuft
  -- unter estate_rw und ruft die DEFINER-Binder-fn estate.fn_render_emergency_binder (Blanket-EXECUTE-Grant
  -- aus fn_provision_package_roles Phase 4 — belt-and-suspenders, NICHT role_test_lint-erzwungen, da Blanket
  -- + _rw). Die Binder-fn traegt den adults_only-Backstop SELBST (Kind -> RAISE). set_system_profile ist
  -- INVOKER (adults_only + Singleton-UPSERT, KEIN agent.*-Read). Ein fehlender Grant/Crash saehe der
  -- Superuser-db_test NIE (Lektion (d): neue estate-fn unter der engen Rolle SOFORT exerzieren).
  BEGIN
    SET LOCAL ROLE estate_rw;
    v_out := estate.fn_render_emergency_binder(jsonb_build_object('chat_id','777', 'mask_sensitive', true));
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM LIKE 'FAIL %' THEN RAISE; END IF;
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_render_emergency_binder]: Egress-Render bricht unter estate_rw (Blanket-EXECUTE-Grant fehlt?) -- %', SQLERRM;
  END;
  IF v_out IS NULL OR v_out NOT LIKE '%estate.binder.title%' THEN
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_render_emergency_binder/owner]: erwartet Mappe, got %', left(COALESCE(v_out,'<null>'),80); END IF;
  -- WS-5 Break-Glass-KERN: der ueberlebende PARTNER (779) exportiert die VOLLE Mappe (mask aus = Default;
  -- die Mappe soll fuer den Partner vollstaendig sein). Nicht nur der Owner-Pfad — sonst blockte der
  -- adults_only-Backstop den eigentlichen Notfall-Nutzer. Die fn traegt den Kind-Riegel, nicht den Partner.
  BEGIN
    SET LOCAL ROLE estate_rw;
    v_out := estate.fn_render_emergency_binder(jsonb_build_object('chat_id','779'));
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM LIKE 'FAIL %' THEN RAISE; END IF;
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_render_emergency_binder/partner]: Partner-Egress bricht (adults_only blockt den ueberlebenden Partner?) -- %', SQLERRM;
  END;
  IF v_out IS NULL OR v_out NOT LIKE '%estate.binder.title%' THEN
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_render_emergency_binder/partner]: erwartet volle Mappe, got %', left(COALESCE(v_out,'<null>'),80); END IF;
  v_bool := FALSE;
  BEGIN
    SET LOCAL ROLE estate_rw;
    PERFORM estate.fn_render_emergency_binder(jsonb_build_object('chat_id','778'));
    RESET ROLE;
  EXCEPTION
    WHEN insufficient_privilege THEN v_bool := TRUE; RESET ROLE;
    WHEN OTHERS THEN RESET ROLE;
      RAISE EXCEPTION 'FAIL [estate_rw -> binder/child]: unerwartet statt insufficient_privilege: %', SQLERRM;
  END;
  IF NOT v_bool THEN RAISE EXCEPTION 'FAIL [estate_rw -> binder/child]: Kind erhielt die Mappe (kein RAISE)'; END IF;
  BEGIN
    SET LOCAL ROLE estate_rw;
    SELECT (estate.fn_set_system_profile(jsonb_build_object('chat_id','777','system_location','__rp Host'))->>'ok') INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_set_system_profile]: bricht unter estate_rw -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [estate_rw -> fn_set_system_profile]: erwartet ok=true, got %', COALESCE(v_out,'<null>'); END IF;
  RAISE NOTICE 'PASS [estate_rw -> fn_render_emergency_binder (Owner ok / Partner ok / Kind RAISE) + fn_set_system_profile (WS-5 Egress + Singleton)]';

  -- (7c) NEGATIV: das agent-PRIMITIV ist unter estate_rw NICHT direkt aufrufbar (Schema agent D10-gesperrt)
  -- -> beweist, dass das core-Fenster notwendig ist (kein stilles Breit-Grant).
  BEGIN
    SET LOCAL ROLE estate_rw;
    PERFORM agent.fn_check_write_permission('adults_only', '778', NULL);
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [estate_rw NEGATIV]: estate_rw konnte agent.fn_check_write_permission direkt aufrufen -> zu breites Grant!';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE NOTICE 'PASS [estate_rw NEGATIV: agent-Primitiv D10-gesperrt (Fenster notwendig)]';
    WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM LIKE 'FAIL %' THEN RAISE; END IF;
      RAISE EXCEPTION 'FAIL [estate_rw NEGATIV]: unerwarteter Fehler statt insufficient_privilege: %', SQLERRM;
  END;

  -- (7d) estate_ro: Gap-Views lesbar (View-Owner-Rechte decken das fn_household_persons-Fenster) +
  -- fn_gap_report degradiert auf dem Frei-SQL-Pfad EHRLICH (finance D10-gesperrt -> Pfad-Marker, kein Crash).
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'estate_ro') THEN
    RAISE EXCEPTION 'FAIL [role_perms]: Rolle estate_ro nicht provisioniert'; END IF;
  INSERT INTO core.package_registry (package, status) VALUES ('finance', 'active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  BEGIN
    SET LOCAL ROLE estate_ro;
    PERFORM 1 FROM estate.v_directive_gaps LIMIT 1;
    PERFORM 1 FROM estate.v_register_gaps LIMIT 1;
    SELECT (estate.fn_gap_report()->'finance'->>'status') INTO v_out;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [estate_ro -> Gap-Views/fn_gap_report]: bricht unter estate_ro -- %', SQLERRM;
  END;
  IF v_out IS DISTINCT FROM 'not_readable_on_this_path' THEN
    RAISE EXCEPTION 'FAIL [estate_ro -> fn_gap_report]: erwartet finance.status=not_readable_on_this_path (ehrliche Degradation), got %', COALESCE(v_out, '<null>'); END IF;
  RAISE NOTICE 'PASS [estate_ro -> Gap-Views lesbar + fn_gap_report degradiert ehrlich (finance D10-gesperrt)]';
END $$;

-- ============================================================
-- Phase B: GENERISCHER Rollen-Zaun fuer JEDE Paket-Rolle (<pkg>_ro/<pkg>_rw aus core.package_registry ∪
-- core.schema_version) — ersetzt die frueheren `REVOKE ... FROM finance_ro` in den Core-fns (die nur EINE
-- Rolle meinten; core:V022 nimmt die Alt-Grants der retirten breiten finance_ro zurueck).
--   (a) kein USAGE auf Schema agent (D10: agent ist Host-Raum)
--   (b) keine Tabellen-Rechte auf agent/core — einzige Ausnahme: SELECT core.context_scopes fuer <pkg>_rw
--   (c) EXECUTE auf eine PUBLIC-gesperrte core-fn NUR fuer die publizierten Fenster (Liste = die Grants in
--       core.fn_provision_package_roles; ein neuer Grant ist ein bewusster Test-Diff)
-- ============================================================
DO $$
DECLARE
  v_pkg  text;
  v_role text;
  v_bad  text;
  v_published text[] := ARRAY['fn_core_api_version', 'fn_advisor_read_plan', 'fn_onboarding_status', 'fn_package_active',
                              'fn_config_get', 'fn_monitor_trigger_summary', 'fn_list_monitor_triggers',
                              'fn_household_persons', 'fn_resolve_person', 'fn_ui_texts_for', 'fn_today',
                              'fn_resolve_date', 'fn_resolve_input_dates'];
  v_published_rw text[] := ARRAY['fn_set_onboarding_section', 'fn_check_write_permission', 'fn_person_chat_id',
                                 'fn_should_notify', 'fn_notify_resolve', 'fn_dry_run'];
  v_n int := 0;
BEGIN
  FOR v_pkg IN
    SELECT DISTINCT s.package FROM (SELECT package FROM core.package_registry UNION SELECT package FROM core.schema_version) s
     WHERE s.package <> 'core'
  LOOP
    FOREACH v_role IN ARRAY ARRAY[v_pkg || '_ro', v_pkg || '_rw'] LOOP
      CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role);
      v_n := v_n + 1;
      IF has_schema_privilege(v_role, 'agent', 'USAGE') THEN
        RAISE EXCEPTION 'FAIL [Rollen-Zaun %]: USAGE auf Schema agent', v_role; END IF;
      SELECT string_agg(n.nspname || '.' || c.relname, ', ') INTO v_bad
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname IN ('agent', 'core') AND c.relkind IN ('r', 'v', 'p')
         AND (has_table_privilege(v_role, c.oid, 'SELECT') OR has_table_privilege(v_role, c.oid, 'INSERT')
              OR has_table_privilege(v_role, c.oid, 'UPDATE') OR has_table_privilege(v_role, c.oid, 'DELETE'))
         AND NOT (v_role LIKE '%\_rw' AND n.nspname = 'core' AND c.relname = 'context_scopes');
      IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [Rollen-Zaun %]: Tabellen-Rechte auf %', v_role, v_bad; END IF;
      SELECT string_agg(p.proname, ', ') INTO v_bad
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'core'
         AND NOT has_function_privilege('public', p.oid, 'EXECUTE')
         AND has_function_privilege(v_role, p.oid, 'EXECUTE')
         AND NOT p.proname = ANY (v_published || CASE WHEN v_role LIKE '%\_rw' THEN v_published_rw ELSE ARRAY[]::text[] END);
      IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [Rollen-Zaun %]: EXECUTE auf nicht publizierte core-fns: %', v_role, v_bad; END IF;
    END LOOP;
  END LOOP;
  IF v_n = 0 THEN RAISE EXCEPTION 'FAIL [Rollen-Zaun]: keine Paket-Rolle geprueft (Substrat ohne Paket-Rollen?)'; END IF;
  RAISE NOTICE 'PASS [Rollen-Zaun generisch: % Paket-Rollen ohne agent-USAGE / Host-Tabellen / unpublizierte core-fns]', v_n;
END $$;

-- ===== Mini-App (docs/package-contract.md §3.12): der Eingang laeuft nur unter der Host-Credential (Workflow
-- core.main_app_serve). Keine Leserolle darf ihn oder die initData-Pruefung ausfuehren; core.app_secret bleibt allen
-- Leserollen verwehrt (test_core_app_secret_acl.sql). Zusaetzlich gibt der Eingang einer Frei-SQL-Sitzung nichts. =====
DO $$
DECLARE v_role text; v_fn text;
BEGIN
  FOREACH v_role IN ARRAY ARRAY['core_ro', 'context_ro', 'finance_ro', 'finance_rw', 'career_ro', 'estate_ro'] LOOP
    CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role);
    FOREACH v_fn IN ARRAY ARRAY['core.fn_app_screen(text)', 'core.fn_app_verify_init_data(text, timestamptz)',
                                'core.fn_app_refusal(text, text)', 'core.fn_app_nav(text)',
                                'core.fn_app_sees_household(text)'] LOOP
      IF has_function_privilege(v_role, v_fn, 'EXECUTE') THEN
        RAISE EXCEPTION 'FAIL [Mini-App: % darf % ausfuehren]', v_role, v_fn;
      END IF;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'PASS [Mini-App: Eingang + initData-Pruefung fuer keine Leser-/Paket-Rolle ausfuehrbar]';
END $$;

-- ===== Security-Audit 2026-10: gebundene Fenster unter der echten Rolle =====
--   career.fn_read_job_matches (read_job_matches unter career_rw) -> kein permission denied
--   agent.fn_monitor_ro_eval   (Monitor-Specs; DEFINER, Eigentuemer core_ro_eval) -> die Frei-SQL-Rolle core_ro
--                              hat KEIN EXECUTE (nur die App-Rolle per Sammel-Grant in apply_schema.sh)
DO $$
DECLARE v_cnt int;
BEGIN
  BEGIN
    SET LOCAL ROLE career_rw;
    SELECT count(*) INTO v_cnt FROM career.fn_read_job_matches('900199');
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [career_rw -> career.fn_read_job_matches]: %', SQLERRM;
  END;
  IF has_function_privilege('core_ro', 'agent.fn_monitor_ro_eval(text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [core_ro -> fn_monitor_ro_eval]: die Frei-SQL-Rolle darf das Monitor-Fenster nicht ausfuehren';
  END IF;
  RAISE NOTICE 'PASS [career_rw -> fn_read_job_matches: kein permission denied; core_ro ohne EXECUTE auf fn_monitor_ro_eval]';

  -- ===== Kurs-Luecken (2026-10-27): die Kurs-Luecken-Erinnerung + Tools laufen unter finance_rw (Latch ueber
  -- core.fn_should_notify/fn_notify_resolve, fn_apply_price_symbol), die Kurs-Symbol-Pruefung unter finance_ro
  -- (fn_holding_price_status, fn_fx_rate_map; core.fn_config_get ueber fn_price_status). =====
  DECLARE
    v_cash int; v_depot int; v_h int; v_r jsonb;
  BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__rp_px_cash__', 'cash', 'EUR', 'active') RETURNING id INTO v_cash;
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__rp_px_depot__', 'stocks_depot', 'EUR', 'active', v_cash) RETURNING id INTO v_depot;
    INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_depot, 'IE00TESTRP01', 'RPPX', '__rp_px_fonds__', 1, 10, 'EUR') RETURNING id INTO v_h;
    SET LOCAL ROLE finance_rw;
    v_r := finance.fn_price_gaps();
    PERFORM finance.fn_price_gap_claim(v_h::text);
    v_r := finance.fn_apply_price_symbol(jsonb_build_object('holding_id', v_h, 'expected_feed_symbol', 'RPPX',
             'provider_symbol', 'RPPX.DE', 'quote_currency', 'EUR'));
    RESET ROLE;
    IF NOT COALESCE((v_r->>'ok')::boolean, false) THEN RAISE EXCEPTION 'FAIL [finance_rw -> fn_apply_price_symbol]: %', v_r; END IF;
    SET LOCAL ROLE finance_ro;
    PERFORM * FROM finance.fn_holding_price_status(ARRAY[v_h]);
    PERFORM finance.fn_fx_rate_map();
    PERFORM price_status FROM finance.depot_holdings_overview WHERE id = v_h;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [Kurs-Luecken-Rollenpfad]: %', SQLERRM;
  END;
  RAISE NOTICE 'PASS [finance_rw -> fn_price_gaps/fn_price_gap_claim/fn_apply_price_symbol, finance_ro -> fn_holding_price_status/fn_fx_rate_map/price_status]';
END $$;

-- Plan-Luecken (2026-10-27): load_context('financial_planning') unter context_ro -> Renderer -> finance.fn_plan_gaps liest
-- agent.advisor_plans im DEFINER-Kontext von core.fn_fetch_context; die Luecken-Zeile muss unter der echten Rolle ankommen.
DO $$
DECLARE v_out text;
BEGIN
  DELETE FROM agent.advisor_plans WHERE domain = 'finance';
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES ('finance', NULL, 'RP Plan', 'active', 1, '{"risk_profile":{"content":"x"}}', 'rp');
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('financial_planning', 'rp', NULL, 'lazy', 'rp plan', jsonb_build_object('managed_by','agent','facts','{}'::jsonb))
  ON CONFLICT (name) DO UPDATE SET content = EXCLUDED.content, metadata = EXCLUDED.metadata, load_strategy = 'lazy';
  INSERT INTO core.context_renderers (context_name, render_fn, package)
  VALUES ('financial_planning', 'finance.fn_render_plan_facts', 'finance')
  ON CONFLICT (context_name) DO UPDATE SET render_fn = EXCLUDED.render_fn;
  BEGIN
    SET LOCAL ROLE context_ro;
    SELECT content INTO v_out FROM core.fn_fetch_context('financial_planning');
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [context_ro -> financial_planning Plan-Luecken]: %', SQLERRM;
  END;
  IF v_out NOT LIKE '%Plan gaps: never confirmed in an interview: household_basics%' THEN
    RAISE EXCEPTION 'FAIL [context_ro -> financial_planning Plan-Luecken]: Zeile fehlt: %', v_out; END IF;
  RAISE NOTICE 'PASS [context_ro -> fn_fetch_context(financial_planning) -> fn_plan_gaps]';
END $$;

ROLLBACK;
