-- tests/db/core/test_fn_advisor_publish_plan.sql
-- Testet fn_advisor_publish_plan: Draft -> active (+ Vorgaenger superseded) UND Upsert des
-- Domaenen-Plan-Doc (finance->'financial_planning', WS-B2c; Test-Domain->'<domain>_planning';
-- lazy, agent_name=NULL, managed_by='agent' [Spalte], package=Domain)
-- in EINER Transaktion. Korrigierbar (kein Draft, leeres plan_md) -> {ok:false, reason}.
-- Invariante (DB-Gesetz): genau EIN aktiver Plan pro Domain (Partial-UNIQUE).
-- Negativ-Test: finance_ro darf advisor_plans lesen, aber nicht schreiben.
BEGIN;

DO $$
DECLARE
  v_result   JSONB;
  v_plan_v1  INT;
  v_plan_v2  INT;
  v_ctx      RECORD;
  v_cnt      INT;
  v_facts    JSONB;
BEGIN

  -- Setup: Draft via fn_advisor_save_section (der einzige Anlage-Pfad)
  SELECT agent.fn_advisor_save_section(jsonb_build_object(
    'domain', '__test_pubdom__', 'plan_name', '__test_pubplan__',
    'section_key', 'goals', 'section_content', 'Goal A.'
  )) INTO v_result;
  v_plan_v1 := (v_result->>'plan_id')::int;

  -- TEST 0 (WS-5b owner_only-Backstop): gepairter Nicht-Owner darf KEINEN Plan publizieren (Owner-Vorgabe 6).
  -- family-Fixture (erika owner@111, lena partner@222). Owner-Check laeuft VOR dem Draft-/plan_md-Check.
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'publish owner-check fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','protected', true,
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
              jsonb_build_object('person_id','lena','first_name','Lena','last_name','Beispiel',
                                 'role','partner','birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')
            ))))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content, metadata = EXCLUDED.metadata;

  SELECT agent.fn_advisor_publish_plan(jsonb_build_object(
    'domain','__test_pubdom__','chat_id','222','plan_md','# member tries to publish'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' IS DISTINCT FROM 'owner_only' THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [non-owner]: erwartet ok=false/owner_only, got %', v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.advisor_plans WHERE id = v_plan_v1 AND status = 'draft') THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [non-owner]: Draft wurde trotzdem publiziert';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_publish_plan [gepairter Nicht-Owner -> owner_only, kein Publish]';

  -- TEST 1: Publish ohne plan_md -> {ok:false}, Draft bleibt draft
  SELECT agent.fn_advisor_publish_plan(jsonb_build_object(
    'domain', '__test_pubdom__', 'plan_md', ''
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [empty plan_md]: erwartet ok=false, got %', v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.advisor_plans WHERE id = v_plan_v1 AND status = 'draft') THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [empty plan_md]: Draft-Status veraendert';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_publish_plan [leeres plan_md -> ok:false]';

  -- TEST 2: Publish v1 -> active, plan_md persistiert, Context-Doc angelegt
  SELECT agent.fn_advisor_publish_plan(jsonb_build_object(
    'domain', '__test_pubdom__',
    'plan_md', '# Plan v1' || E'\n' || 'Content of plan version one.'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [v1]: erwartet ok=true, got %', v_result;
  END IF;
  IF (v_result->>'plan_id')::int IS DISTINCT FROM v_plan_v1
     OR (v_result->>'version')::int IS DISTINCT FROM 1
     OR (v_result->>'context_name') IS DISTINCT FROM '__test_pubdom___planning' THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [v1 return]: got %', v_result;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM agent.advisor_plans
    WHERE id = v_plan_v1 AND status = 'active' AND plan_md LIKE '# Plan v1%'
  ) THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [v1]: Plan-Zeile nicht active/plan_md fehlt';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_publish_plan [v1 -> active]';

  -- Assert: Context-Doc korrekt (lazy, global, managed_by=agent [Spalte], package=Domain, content=plan_md)
  SELECT name, description, agent_name, load_strategy, content, managed_by, package, metadata INTO v_ctx
  FROM agent.core_contexts WHERE name = '__test_pubdom___planning';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [context]: Doc nicht angelegt';
  END IF;
  IF v_ctx.load_strategy IS DISTINCT FROM 'lazy' OR v_ctx.agent_name IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [context]: erwartet lazy/global, got %/%', v_ctx.load_strategy, v_ctx.agent_name;
  END IF;
  IF v_ctx.managed_by IS DISTINCT FROM 'agent' THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [context]: managed_by-Spalte != agent, got %', v_ctx.managed_by;
  END IF;
  IF v_ctx.package IS DISTINCT FROM '__test_pubdom__' THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [context]: package-Spalte != Domain, got %', v_ctx.package;
  END IF;
  IF v_ctx.content NOT LIKE '# Plan v1%' THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [context]: content != plan_md';
  END IF;
  IF COALESCE(v_ctx.description, '') = '' THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [context]: description leer';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_publish_plan [Context-Doc lazy/global/managed_by=agent]';

  -- TEST 3: Publish ohne Draft -> {ok:false} (kein zweiter Publish moeglich, bis neuer Draft existiert)
  SELECT agent.fn_advisor_publish_plan(jsonb_build_object(
    'domain', '__test_pubdom__', 'plan_md', '# again'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [no draft]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_advisor_publish_plan [kein Draft -> ok:false]';

  -- TEST 4: Versionierung — neuer Draft (Revision) + Publish v2 -> v1 superseded, v2 active, Context aktualisiert
  SELECT agent.fn_advisor_save_section(jsonb_build_object(
    'domain', '__test_pubdom__', 'section_key', 'goals', 'section_content', 'Goal A revised.'
  )) INTO v_result;
  v_plan_v2 := (v_result->>'plan_id')::int;
  IF v_plan_v2 = v_plan_v1 OR (v_result->>'version')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [revision draft]: erwartet neue Zeile v2, got %', v_result;
  END IF;

  SELECT agent.fn_advisor_publish_plan(jsonb_build_object(
    'domain', '__test_pubdom__', 'plan_md', '# Plan v2'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true
     OR (v_result->>'version')::int IS DISTINCT FROM 2
     OR (v_result->>'superseded_plan_id')::int IS DISTINCT FROM v_plan_v1 THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [v2]: got %', v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.advisor_plans WHERE id = v_plan_v1 AND status = 'superseded')
     OR NOT EXISTS (SELECT 1 FROM agent.advisor_plans WHERE id = v_plan_v2 AND status = 'active') THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [v2]: Supersede-Kette falsch';
  END IF;
  SELECT count(*) INTO v_cnt FROM agent.core_contexts WHERE name = '__test_pubdom___planning';
  IF v_cnt IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [v2 context]: erwartet 1 Doc-Zeile, got %', v_cnt;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM agent.core_contexts
    WHERE name = '__test_pubdom___planning' AND content = '# Plan v2'
      AND (metadata->>'version')::int = 2
  ) THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [v2 context]: content/metadata nicht aktualisiert';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_publish_plan [v2 active, v1 superseded, Context upserted]';

  -- TEST 5 (Invariante, DB-Gesetz): zweiter aktiver Plan derselben Domain per Direkt-INSERT -> unique_violation
  BEGIN
    INSERT INTO agent.advisor_plans (domain, plan_name, status, version)
    VALUES ('__test_pubdom__', '__test_second_active__', 'active', 99);
    RAISE EXCEPTION 'FAIL advisor_plans [one-active-per-domain]: zweiter aktiver Plan akzeptiert';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS advisor_plans [Partial-UNIQUE: ein aktiver Plan pro Domain]';
  END;

  -- TEST 6 (Paket-Isolation, O1): nach der Finance-Extraktion ist finance_ro ENG auf `finance`
  -- skopiert → ein DIREKTER SELECT auf agent.advisor_plans MUSS scheitern (Isolation); der Advisor
  -- liest die Plaene nur noch ueber die publizierte SECURITY-DEFINER-Read-fn core.fn_advisor_read_plan
  -- (EXECUTE-GRANT via core.fn_provision_package_roles). Schreiben bleibt verwehrt.
  -- (Nur sinnvoll, wenn finance_ro PAKET-PROVISIONIERT ist — sonst SKIP.)
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'finance_ro')
     AND has_function_privilege('finance_ro', 'core.fn_advisor_read_plan(text, text)', 'EXECUTE') THEN
    SET LOCAL ROLE finance_ro;
    -- (a) DIREKTER Tabellenzugriff scheitert physisch (VF3 fuer advisor_plans)
    BEGIN
      PERFORM count(*) FROM agent.advisor_plans;
      RESET ROLE;
      RAISE EXCEPTION 'FAIL advisor_plans [finance_ro]: direkter SELECT auf agent.advisor_plans NICHT geblockt (Isolation gebrochen)';
    EXCEPTION WHEN insufficient_privilege THEN NULL;   -- erwartet
    END;
    -- (b) Lesen ueber das publizierte Fenster funktioniert (kein Fehler; Inhalt egal)
    PERFORM count(*) FROM core.fn_advisor_read_plan('__test_pubdom__');
    -- (c) Schreiben bleibt verwehrt
    BEGIN
      INSERT INTO agent.advisor_plans (domain, plan_name) VALUES ('__test_ro__', '__test_ro__');
      RESET ROLE;
      RAISE EXCEPTION 'FAIL advisor_plans [finance_ro]: INSERT wurde NICHT geblockt';
    EXCEPTION WHEN insufficient_privilege THEN NULL;   -- erwartet
    END;
    RESET ROLE;
    RAISE NOTICE 'PASS advisor_plans [finance_ro: direkt verwehrt, Read-fn ja, INSERT nein]';
  ELSE
    RAISE NOTICE 'SKIP advisor_plans [finance_ro nicht paket-provisioniert auf dieser DB]';
  END IF;

  -- ===== WS1a: Compose-on-Publish (section_data -> metadata.facts; Facts-Key-Merge) =====
  -- 7a: neuer Draft mit strukturiertem section_data (goal-Block) -> Publish -> facts.goal + _meta-Stempel.
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','__test_pubdom__','section_key','objectives',
    'section_content','Ziele.','section_data', jsonb_build_object('goal', jsonb_build_object('horizon_years',25))));
  PERFORM agent.fn_advisor_publish_plan(jsonb_build_object('domain','__test_pubdom__','plan_md','# Plan v3'));
  SELECT metadata->'facts' INTO v_facts FROM agent.core_contexts WHERE name='__test_pubdom___planning';
  IF v_facts->'goal'->>'horizon_years' IS DISTINCT FROM '25' THEN
    RAISE EXCEPTION 'FAIL [compose 7a]: facts.goal nicht materialisiert: %', v_facts; END IF;
  IF v_facts->'_meta'->>'last_confirmed_at' IS DISTINCT FROM to_char(CURRENT_DATE,'YYYY-MM-DD') THEN
    RAISE EXCEPTION 'FAIL [compose 7a]: _meta.last_confirmed_at nicht gesetzt: %', v_facts; END IF;
  RAISE NOTICE 'PASS [compose 7a: section_data.goal -> metadata.facts + _meta-Stempel]';

  -- 7b (P1-A): neuer Draft mit ANDEREM Block (target_allocation) -> Publish -> goal BEWAHRT + neuer Block dazu.
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','__test_pubdom__','section_key','wealth',
    'section_content','x','section_data', jsonb_build_object('target_allocation', jsonb_build_object('rebalance_drift_pp',5))));
  PERFORM agent.fn_advisor_publish_plan(jsonb_build_object('domain','__test_pubdom__','plan_md','# Plan v4'));
  SELECT metadata->'facts' INTO v_facts FROM agent.core_contexts WHERE name='__test_pubdom___planning';
  IF v_facts->'goal'->>'horizon_years' IS DISTINCT FROM '25' THEN
    RAISE EXCEPTION 'FAIL [compose 7b P1-A]: ungetouchter goal-Block nicht bewahrt: %', v_facts; END IF;
  IF v_facts->'target_allocation'->>'rebalance_drift_pp' IS DISTINCT FROM '5' THEN
    RAISE EXCEPTION 'FAIL [compose 7b P1-A]: neuer Block fehlt: %', v_facts; END IF;
  RAISE NOTICE 'PASS [compose 7b: Facts-Key-Merge bewahrt ungetouchte Bloecke (P1-A)]';

  -- 7c (P1-C): Draft OHNE section_data -> Publish -> geseedete facts BEWAHRT, nur _meta-Stempel frisch.
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','__test_pubdom__','section_key','note','section_content','just prose'));
  PERFORM agent.fn_advisor_publish_plan(jsonb_build_object('domain','__test_pubdom__','plan_md','# Plan v5'));
  SELECT metadata->'facts' INTO v_facts FROM agent.core_contexts WHERE name='__test_pubdom___planning';
  IF v_facts->'goal'->>'horizon_years' IS DISTINCT FROM '25'
     OR v_facts->'target_allocation'->>'rebalance_drift_pp' IS DISTINCT FROM '5' THEN
    RAISE EXCEPTION 'FAIL [compose 7c P1-C]: Leer-Compose hat geseedete facts nukliert: %', v_facts; END IF;
  RAISE NOTICE 'PASS [compose 7c: Leer-Compose bewahrt geseedete facts (P1-C)]';

  -- ===== WS3: Naht-Backstop — deterministischer Block-Kollisions-Guard =====
  -- 8a: zwei VERSCHIEDENE Sektionen emittieren beide den Top-Block 'goal' -> Publish {ok:false, reason}
  --     OHNE Write (nicht-deterministischer jsonb_each-Merge wuerde sonst still eine Haelfte verlieren).
  --     Frischer Draft (nach 7c gibt es keinen) mit zwei kollidierenden Sektionen.
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','__test_pubdom__','section_key','sec_a',
    'section_content','a','section_data', jsonb_build_object('goal', jsonb_build_object('withdrawal_rate_pct',4))));
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','__test_pubdom__','section_key','sec_b',
    'section_content','b','section_data', jsonb_build_object('goal', jsonb_build_object('withdrawal_rate_pct',3))));
  SELECT agent.fn_advisor_publish_plan(jsonb_build_object('domain','__test_pubdom__','plan_md','# collide')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR (v_result->>'reason') NOT LIKE '%goal%' THEN
    RAISE EXCEPTION 'FAIL [8a collision]: erwartet ok:false mit Block-Name "goal", got %', v_result; END IF;
  -- Kein Write: der Draft bleibt draft (nicht superseded/aktiviert), kein neuer active
  IF NOT EXISTS (SELECT 1 FROM agent.advisor_plans WHERE domain='__test_pubdom__' AND status='draft') THEN
    RAISE EXCEPTION 'FAIL [8a collision]: Draft wurde trotz Kollision konsumiert (Write trotz ok:false)'; END IF;
  RAISE NOTICE 'PASS [8a: Block-Kollision -> ok:false, kein Write (Draft bleibt)]';

  -- 8b: kein false-positive — eine Sektion mit ZWEI Bloecken (target_allocation + glidepath) ist erlaubt.
  --     Kollision aufloesen: sec_b auf andere Bloecke umstellen -> nur EINE 'goal'-Quelle bleibt (sec_a).
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','__test_pubdom__','section_key','sec_b',
    'section_content','b','section_data', jsonb_build_object(
      'target_allocation', jsonb_build_object('rebalance_drift_pp',5),
      'glidepath', jsonb_build_object('start_age',54))));
  SELECT agent.fn_advisor_publish_plan(jsonb_build_object('domain','__test_pubdom__','plan_md','# ok multi')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [8b multi-block one section]: eine Sektion mit mehreren Bloecken muss erlaubt sein, got %', v_result; END IF;
  RAISE NOTICE 'PASS [8b: eine Sektion mit mehreren Bloecken erlaubt (kein false-positive)]';

END $$;

-- ===== Phase A Bugfix (E10): "## Gelernt" ist ein system-verwalteter Block =====
-- Vorher ersetzte jeder Publish content = plan_md und loeschte still alle bestaetigten Lern-Notizen.
DO $$
DECLARE
  v_result JSONB;
  v_cont   TEXT;
  v_md     TEXT;
BEGIN
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','__test_learndom__','section_key','s1','section_content','x'));
  PERFORM agent.fn_advisor_publish_plan(jsonb_build_object('domain','__test_learndom__','plan_md','# Plan v1'));
  -- bestaetigte Notiz im Plan-Doc (Layout wie core.fn_append_context_note)
  UPDATE agent.core_contexts
  SET content = content || E'\n\n## Gelernt\n\n- plant ein Sabbatical (gelernt am 2026-10-01 aus Chat)'
  WHERE name = '__test_learndom___planning';

  -- Re-Publish mit einem mitgeschickten (gefaelschten) Gelernt-Block
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','__test_learndom__','section_key','s1','section_content','y'));
  SELECT agent.fn_advisor_publish_plan(jsonb_build_object('domain','__test_learndom__',
    'plan_md', E'# Plan v2\n\n## Gelernt\n- erfundene Notiz\n\n## Massnahmen\n- m1')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [gelernt publish]: erwartet ok, got %', v_result; END IF;
  SELECT content INTO v_cont FROM agent.core_contexts WHERE name = '__test_learndom___planning';
  IF v_cont NOT LIKE '%plant ein Sabbatical%' THEN
    RAISE EXCEPTION 'FAIL [gelernt publish]: bestaetigte Notiz ging beim Re-Publish verloren: %', v_cont; END IF;
  IF v_cont LIKE '%erfundene Notiz%' THEN
    RAISE EXCEPTION 'FAIL [gelernt publish]: mitgeschickter Gelernt-Block uebernommen: %', v_cont; END IF;
  IF v_cont NOT LIKE '# Plan v2%' OR v_cont NOT LIKE '%## Massnahmen%' THEN
    RAISE EXCEPTION 'FAIL [gelernt publish]: neuer Plan-Text fehlt/verstuemmelt: %', v_cont; END IF;
  SELECT plan_md INTO v_md FROM agent.advisor_plans WHERE domain = '__test_learndom__' AND status = 'active';
  IF v_md LIKE '%Gelernt%' OR v_md NOT LIKE '%## Massnahmen%' THEN
    RAISE EXCEPTION 'FAIL [gelernt audit]: Versions-Audit plan_md traegt den Fremd-Block / verlor Inhalt: %', v_md; END IF;
  RAISE NOTICE 'PASS [Gelernt-Block: ueberlebt Re-Publish, Fremd-Block verworfen (Doc + Audit)]';

  -- nur ein Gelernt-Block im plan_md -> nach dem Entfernen leer -> {ok:false}
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','__test_learndom__','section_key','s1','section_content','z'));
  SELECT agent.fn_advisor_publish_plan(jsonb_build_object('domain','__test_learndom__',
    'plan_md', E'## Gelernt\n- nur das')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [gelernt-only]: plan_md nur aus Gelernt-Block muss als leer abgelehnt werden, got %', v_result; END IF;
  RAISE NOTICE 'PASS [plan_md nur aus Gelernt-Block -> leer -> ok:false]';
END $$;


-- ===== Backlog-Bugfix-Runde (B5): freundliche Vorpruefung der Plan-Fakten VOR jedem Write =====
-- Vorher pruefte nur der Trigger (RAISE -> Owner-Alarm; fuer per_user lief der Paket-Validator dort gar nicht).
-- Jetzt: Core-Form + Paket-Validator des BASIS-Namens -> {ok:false, reason}, Draft bleibt Draft, kein Doc-Write.
DO $$
DECLARE
  v_result JSONB;
  v_status TEXT;
BEGIN
  CREATE FUNCTION agent.zz_test_plan_validator(p jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
    SELECT CASE WHEN (p->'goal'->>'target_eur')::numeric < 0 THEN 'goal.target_eur must be >= 0' END
  $f$;
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('__test_vdom___planning', 'agent.zz_test_plan_validator', 'core');

  -- (a) Paket-Validator lehnt ab
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','__test_vdom__','section_key','s1',
    'section_content','x', 'section_data', jsonb_build_object('goal', jsonb_build_object('target_eur', -1))));
  SELECT agent.fn_advisor_publish_plan(jsonb_build_object('domain','__test_vdom__','plan_md','# Plan')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' NOT LIKE '%target_eur%' THEN
    RAISE EXCEPTION 'FAIL [publish validator]: erwartet ok:false mit Grund, got %', v_result; END IF;
  SELECT status INTO v_status FROM agent.advisor_plans WHERE domain = '__test_vdom__';
  IF v_status IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'FAIL [publish validator]: Teil-Write - Draft-Status ist %', v_status; END IF;
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = '__test_vdom___planning') THEN
    RAISE EXCEPTION 'FAIL [publish validator]: Plan-Doc trotz Ablehnung geschrieben'; END IF;
  RAISE NOTICE 'PASS [publish: Paket-Validator -> ok:false ohne Write]';

  -- (b) Core-Form (abgeleiteter Wert) lehnt ab
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','__test_vdom__','section_key','s1',
    'section_content','x', 'section_data', jsonb_build_object('goal', jsonb_build_object('retirement_year', 2050))));
  SELECT agent.fn_advisor_publish_plan(jsonb_build_object('domain','__test_vdom__','plan_md','# Plan')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' NOT LIKE '%retirement_year%' THEN
    RAISE EXCEPTION 'FAIL [publish core form]: erwartet ok:false mit Grund, got %', v_result; END IF;
  RAISE NOTICE 'PASS [publish: Core-Form -> ok:false ohne Write]';

  -- (c) gueltig -> ok
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','__test_vdom__','section_key','s1',
    'section_content','x', 'section_data', jsonb_build_object('goal', jsonb_build_object('target_eur', 1000))));
  SELECT agent.fn_advisor_publish_plan(jsonb_build_object('domain','__test_vdom__','plan_md','# Plan')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [publish valid]: erwartet ok, got %', v_result; END IF;
  RAISE NOTICE 'PASS [publish: gueltige Fakten -> ok]';
END $$;

ROLLBACK;
