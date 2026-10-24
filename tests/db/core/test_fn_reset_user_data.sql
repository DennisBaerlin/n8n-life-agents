-- tests/db/core/test_fn_reset_user_data.sql
-- Phase B: core.fn_reset_user_data (Werkszustand, deny-by-default ueber Tabellen-Marker) +
-- core.fn_reset_onboarding_state (generische <pkg>.onboarding_state-Konvention).
--   (i)   Marker-Menge == woertliche Soll-Menge (jede Marker-Aenderung ist ein reviewter Test-Diff)
--   (ii)  jede bei Teststart (= frischer Init-Stand) nicht-leere Paket-Tabelle ist markiert -> eine neue,
--         ungemarkte Stammdaten-Tabelle failt hier, statt beim Reset still geleert zu werden
--   (iii) Zwei-Personen-Haushalt -> Reset: unmarkierte Paket-Tabellen leer, markierte + reset-skip-Paket unveraendert,
--         Identitaeten laufen weiter, nur der Owner bleibt, Plan-/per-user-/Laufzeit-Kontexte weg, Skelette +
--         Instruktionen + Kontexte des reset-skip-Pakets bleiben, Loeschschutz unveraendert, Latches je Quelle.
--         Das reset-skip-Paket ist ein test-lokales Schema zzskip (seit paperless v0.3.0 nutzt kein echtes Paket
--         den Marker mehr; der Core-Mechanismus bleibt Vertrag, docs/package-contract.md Abschnitt 6)
--   (iv)  jeder FK-Referenzierer von agent.persons ist vom Reset abgedeckt
--   (v)   falscher Bestaetigungs-Token -> {ok:false}, nichts geloescht
-- Persona fiktiv (Mustermann). BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

-- ===== (i) + (ii) Marker =====
DO $$
DECLARE
  v_marked   text[];
  v_expected text[] := ARRAY['career.market_signals', 'estate.directive_types', 'estate.task_templates',
                             'finance.currencies', 'finance.fx_rates', 'finance.market_prices'];
  v_tbl text;
  v_n   bigint;
BEGIN
  SELECT array_agg(n.nspname || '.' || c.relname ORDER BY n.nspname || '.' || c.relname COLLATE "C")
    INTO v_marked
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind IN ('r', 'p') AND obj_description(c.oid, 'pg_class') LIKE 'lifecycle:reference%';
  IF v_marked IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'FAIL (i) Marker-Menge %, erwartet %', v_marked, v_expected;
  END IF;

  FOR v_tbl IN
    SELECT format('%I.%I', n.nspname, c.relname)
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname IN (SELECT package FROM core.schema_version WHERE package <> 'core')
       AND c.relkind IN ('r', 'p') AND NOT c.relispartition
       AND COALESCE(obj_description(c.oid, 'pg_class'), '') NOT LIKE 'lifecycle:reference%'
       AND c.relname <> 'onboarding_state'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                        WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('SELECT count(*) FROM %s', v_tbl) INTO v_n;
    IF v_n > 0 THEN
      RAISE EXCEPTION 'FAIL (ii) % hat nach frischem Init % Zeilen, ist aber nicht lifecycle:reference-markiert (Reset wuerde sie leeren)', v_tbl, v_n;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS (i)+(ii) Marker-Menge exakt + Vollstaendigkeit';
END $$;

-- ===== (iv) FK-Referenzierer von agent.persons =====
DO $$
DECLARE v_bad text;
BEGIN
  -- Abgedeckt sind: Paket-Tabellen (TRUNCATE bzw. onboarding_state-Schritt 2) + agent.advisor_plans + agent.reminder_prefs
  -- + core.update_requests (Schritt 3; ein offener Auftrag bleibt, FK ON DELETE SET NULL).
  SELECT string_agg(con.conrelid::regclass::text, ', ') INTO v_bad
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE con.contype = 'f' AND con.confrelid = 'agent.persons'::regclass
     AND NOT (n.nspname IN (SELECT package FROM core.schema_version WHERE package <> 'core')
              AND COALESCE(obj_description(c.oid, 'pg_class'), '') NOT LIKE 'lifecycle:reference%')
     AND con.conrelid NOT IN ('agent.advisor_plans'::regclass, 'agent.reminder_prefs'::regclass,
                              'core.update_requests'::regclass);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL (iv) FK-Referenzierer von agent.persons nicht vom Reset abgedeckt: %', v_bad;
  END IF;
  RAISE NOTICE 'PASS (iv) alle agent.persons-Referenzierer abgedeckt';
END $$;

-- ===== (iii) + (v) Verhalten =====
DO $$
DECLARE
  r         jsonb;
  v_acc     int;
  v_acc2    int;
  v_eur     bigint;
  v_dt      bigint;
  v_skip    bigint;
  v_pc      bigint;
  v_family  jsonb;
BEGIN
  -- Fixture: test-lokales reset-skip-Paket (Schema-Marker, Cache-Tabelle, Kontext, Latch)
  CREATE SCHEMA zzskip;
  COMMENT ON SCHEMA zzskip IS 'lifecycle:reset-skip - Test-Paket (abgeleiteter Cache)';
  CREATE TABLE zzskip.cache (id int PRIMARY KEY);
  INSERT INTO zzskip.cache (id) VALUES (1), (2);
  INSERT INTO core.package_registry (package, status) VALUES ('zzskip', 'active');

  -- Fixture: Haushalt (Owner + Partner) + Skelett + Registries (db_test seedet keine Registries)
  DELETE FROM agent.core_contexts WHERE name IN ('family', 'finance_profile');
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, metadata, managed_by, package)
  VALUES ('finance_profile', 'test', 'lazy', 'Profil-Prosa',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array())), 'agent', 'finance');
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, metadata, managed_by, package)
  VALUES ('family', 'test', 'static', E'Familie\n\n## Gelernt\n\n- Notiz (gelernt am 2026-01-01 aus Chat)',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','powner','first_name','Erika','last_name','Mustermann','role','owner','birth_date','1980-01-01','employment','employed','language','ko','persona','butler'),
            jsonb_build_object('person_id','ppartner','first_name','Tom','last_name','Mustermann','role','partner','birth_date','1982-01-01')))),
          'agent', 'core');
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('finance_profile', 'finance.fn_validate_finance_profile', 'finance') ON CONFLICT (context_name) DO NOTHING;
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_profile', 'per_user', 'own_user_only', 'career') ON CONFLICT (context_name) DO NOTHING;
  INSERT INTO core.protected_contexts (context_name, package) VALUES
    ('financial_planning', 'finance'), ('career_profile', 'career'), ('family', 'core'), ('zz_instr', 'core')
  ON CONFLICT (context_name) DO NOTHING;

  -- Laufzeit-Kontexte (muessen weg) + Bestand (muss bleiben)
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package) VALUES
    ('financial_planning',      'plan',   'lazy', E'# Plan\n\n## Gelernt\n\n- x', 'agent', 'finance'),
    ('career_profile__powner',  'cp',     'lazy', 'owner career', 'agent', 'career'),
    ('career_profile__ppartner','cp',     'lazy', 'partner career', 'agent', 'career'),
    ('vehicles',                'cars',   'lazy', 'Golf', 'agent', 'core'),
    ('zz_instr',                'instr',  'static', 'instructions', 'seed', 'core'),
    ('zzskip_prompt',           'prompt', 'lazy', 'owner-edited prompt', 'agent', 'zzskip')
  ON CONFLICT (name) DO UPDATE SET content = EXCLUDED.content, managed_by = EXCLUDED.managed_by, package = EXCLUDED.package;

  -- Paket-Nutzerdaten
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('Giro', 'cash', 'EUR') RETURNING id INTO v_acc;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
  VALUES (v_acc, 100, CURRENT_DATE, 'other', 'tx');
  INSERT INTO estate.contacts (name, role) VALUES ('Notar', 'notary');
  INSERT INTO career.job_matches (person_id, source, external_id, title) VALUES ('ppartner', 'forwarded', NULL, 'Coach');
  INSERT INTO career.onboarding_state (section_key, ord, label, status, person_id) VALUES
    ('zz_sec', 1, 'Z', 'completed', 'powner'), ('zz_sec', 1, 'Z', 'completed', 'ppartner');
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status) VALUES ('career', 'ppartner', 'P', 'draft');
  INSERT INTO agent.advisor_plans (domain, plan_name, status) VALUES ('finance', 'F', 'draft');
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, due_date, check_interval)
  VALUES ('general', 'zz reset trigger', 'date', 'none', '2027-01-01', INTERVAL '1 day');
  INSERT INTO core.notification_state (source, key) VALUES
    ('finance', 'reserve_breach:1'), ('advisor:finance', 'm'), ('knock', '123'), ('zzskip:pipeline', '5'),
    ('onboarding', 'household_ready'), ('onboarding_nudge', 'x:1');
  CREATE TABLE agent.zz_reset_chat_memory (id serial PRIMARY KEY, session_id text, message jsonb);
  INSERT INTO agent.zz_reset_chat_memory (session_id, message) VALUES ('1', '{"type":"human"}');

  SELECT count(*) INTO v_eur  FROM finance.currencies;
  SELECT count(*) INTO v_dt   FROM estate.directive_types;
  SELECT count(*) INTO v_skip FROM zzskip.cache;
  SELECT count(*) INTO v_pc   FROM core.protected_contexts;

  -- (v) falscher Token -> nichts passiert
  r := core.fn_reset_user_data('reset');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_acc) THEN
    RAISE EXCEPTION 'FAIL (v) falscher Token: % / Konto weg?', r;
  END IF;
  RAISE NOTICE 'PASS (v) falscher Token -> {ok:false}, nichts geloescht';

  -- (iii)
  r := core.fn_reset_user_data('RESET');
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL (iii) Reset: %', r; END IF;
  IF NOT (r->'skipped') ? 'zzskip' THEN RAISE EXCEPTION 'FAIL (iii) reset-skip-Paket nicht als skipped gemeldet: %', r; END IF;

  IF EXISTS (SELECT 1 FROM finance.accounts) OR EXISTS (SELECT 1 FROM finance.transactions)
     OR EXISTS (SELECT 1 FROM estate.contacts) OR EXISTS (SELECT 1 FROM career.job_matches) THEN
    RAISE EXCEPTION 'FAIL (iii) Paket-Nutzerdaten nicht geleert';
  END IF;
  IF (SELECT count(*) FROM finance.currencies) <> v_eur OR (SELECT count(*) FROM estate.directive_types) <> v_dt
     OR (SELECT count(*) FROM zzskip.cache) <> v_skip THEN
    RAISE EXCEPTION 'FAIL (iii) Referenzdaten/reset-skip-Paket veraendert';
  END IF;
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('Neu', 'cash', 'EUR') RETURNING id INTO v_acc2;
  IF v_acc2 <= v_acc THEN RAISE EXCEPTION 'FAIL (iii) Identitaet zurueckgesetzt (% <= %) — CONTINUE IDENTITY verletzt', v_acc2, v_acc; END IF;

  IF (SELECT array_agg(person_id ORDER BY person_id) FROM agent.persons) IS DISTINCT FROM ARRAY['powner'] THEN
    RAISE EXCEPTION 'FAIL (iii) agent.persons nicht auf den Owner geschrumpft: %', (SELECT array_agg(person_id) FROM agent.persons);
  END IF;
  SELECT metadata->'facts'->'persons' INTO v_family FROM agent.core_contexts WHERE name = 'family';
  IF v_family->0->>'language' IS DISTINCT FROM 'ko' THEN
    RAISE EXCEPTION 'FAIL (iii) Owner-Sprache beim Reset verloren: %', v_family->0;
  END IF;
  IF v_family->0->>'persona' IS DISTINCT FROM 'butler' THEN
    RAISE EXCEPTION 'FAIL (iii) Owner-Persona beim Reset verloren: %', v_family->0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM core.ui_languages WHERE code = 'ko') THEN
    RAISE EXCEPTION 'FAIL (iii) core.ui_languages beim Reset geleert';
  END IF;
  IF jsonb_array_length(v_family) <> 1 OR v_family->0 ? 'employment'
     OR position('Gelernt' IN (SELECT content FROM agent.core_contexts WHERE name = 'family')) > 0 THEN
    RAISE EXCEPTION 'FAIL (iii) family nicht auf Owner-Skelett: %', v_family;
  END IF;
  IF EXISTS (SELECT 1 FROM career.onboarding_state WHERE person_id = 'ppartner')
     OR (SELECT status FROM career.onboarding_state WHERE person_id = 'powner' AND section_key = 'zz_sec') <> 'unknown' THEN
    RAISE EXCEPTION 'FAIL (iii) per-Person-Onboarding nicht korrekt zurueckgesetzt';
  END IF;

  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name IN
             ('financial_planning', 'career_profile__powner', 'career_profile__ppartner', 'vehicles')) THEN
    RAISE EXCEPTION 'FAIL (iii) Laufzeit-Kontexte nicht geloescht';
  END IF;
  IF (SELECT content FROM agent.core_contexts WHERE name = 'finance_profile') IS DISTINCT FROM '(noch keine Daten erfasst - Onboarding ausstehend)'
     OR NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = 'zz_instr')
     OR (SELECT content FROM agent.core_contexts WHERE name = 'zzskip_prompt') IS DISTINCT FROM 'owner-edited prompt' THEN
    RAISE EXCEPTION 'FAIL (iii) Skelett/Instruktion/reset-skip-Kontext nicht korrekt erhalten';
  END IF;
  IF (SELECT count(*) FROM core.protected_contexts) <> v_pc THEN
    RAISE EXCEPTION 'FAIL (iii) Loeschschutz nicht unveraendert wiederhergestellt';
  END IF;

  IF EXISTS (SELECT 1 FROM agent.advisor_plans) OR EXISTS (SELECT 1 FROM agent.monitor_triggers WHERE label = 'zz reset trigger')
     OR EXISTS (SELECT 1 FROM agent.zz_reset_chat_memory) THEN
    RAISE EXCEPTION 'FAIL (iii) Plaene/user-Trigger/Chat-Memory nicht geleert';
  END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source IN ('finance', 'advisor:finance', 'onboarding', 'onboarding_nudge'))
     OR NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'knock')
     OR NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'zzskip:pipeline') THEN
    RAISE EXCEPTION 'FAIL (iii) notification_state nicht je Quelle behandelt';
  END IF;
  RAISE NOTICE 'PASS (iii) Werkszustand-Reset: %', r;
END $$;

ROLLBACK;
