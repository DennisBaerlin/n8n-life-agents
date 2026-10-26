-- tests/db/core/test_fn_fetch_context.sql
-- WS1a (Core-Advisor-Engine): generische Render-Engine in core.fn_fetch_context + paket-gefuetterte
-- finance.fn_render_plan_facts (Header-only). Prueft die DREI Output-Zustaende (P1-3), die Glidepath-
-- Jahr-Ableitung aus owner-birth_date, den Sicherheits-Dispatch (nur Registry-Wert) und die WS1a-
-- Koexistenz (Legacy-family-Renderer unveraendert). db_test seedet die Registry NICHT -> self-seedend.
BEGIN;

DO $$
DECLARE
  v_out TEXT;
BEGIN
  -- ---------- Fixtures: family (owner geb. 1980 -> Glidepath-Jahr 1980+54=2034) + financial_planning ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'fix', NULL, 'lazy', E'## Family Prosa',
          jsonb_build_object('managed_by','agent','render_fn','fn_household_context',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','as_of','2026-06-01')))))
  ON CONFLICT (name) DO UPDATE SET content = EXCLUDED.content, metadata = EXCLUDED.metadata, load_strategy='lazy';

  -- finance_profile (Single-Writer: owner-Rentenalter 67 -> Nominal-Projektion bei ~2047)
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('finance_profile', 'fix', NULL, 'lazy', E'## Profile',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','erika','planned_retirement_age',67,'as_of','2026-06-01')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata, load_strategy='lazy';

  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('financial_planning', 'fix', NULL, 'lazy', E'## Plan Prosa Body',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object(
            'goal', jsonb_build_object('target_income_eur_month',3000,'inflation_pct',2,'terms','real'),
            'risk_profile', jsonb_build_object('risk_tolerance','medium','risk_capacity','high','as_of','2026-06-01'),
            'target_allocation', jsonb_build_object('rebalance_drift_pp',5,'blocks', jsonb_build_array(
              jsonb_build_object('name','S&P 500 ETF','target_pct',85,'corridor', jsonb_build_array(80,90)),
              jsonb_build_object('name','Korea Depot','target_pct',11,'corridor', jsonb_build_array(6,16)),
              jsonb_build_object('name','Physical Gold','target_pct',4,'corridor', jsonb_build_array(0,9)))),
            'glidepath', jsonb_build_object('start_age',54,'phases', jsonb_build_array(
              jsonb_build_object('name','accumulation','age_to',54,'equity_pct',97))),
            '_meta', jsonb_build_object('last_confirmed_at','2026-06-01'))))
  ON CONFLICT (name) DO UPDATE SET content = EXCLUDED.content, metadata = EXCLUDED.metadata, load_strategy='lazy';

  -- Registry-Zeile (Host-Seed-Aequivalent aus packages/finance/manifest.json "context_renderers")
  INSERT INTO core.context_renderers (context_name, render_fn, package)
  VALUES ('financial_planning', 'finance.fn_render_plan_facts', 'finance')
  ON CONFLICT (context_name) DO UPDATE SET render_fn = EXCLUDED.render_fn, package = EXCLUDED.package;

  -- ---------- TEST 1: generische Engine wrappt Banner + Header + Stempel + Prosa ----------
  SELECT content INTO v_out FROM core.fn_fetch_context('financial_planning');
  IF v_out IS NULL OR v_out NOT LIKE '%Authoritative facts%' THEN
    RAISE EXCEPTION 'FAIL [engine banner]: kein autoritativer Header. got: %', left(v_out, 120);
  END IF;
  IF v_out NOT LIKE '%Ziel-Allokation%' OR v_out NOT LIKE '%S&P 500 ETF 85%%' THEN
    RAISE EXCEPTION 'FAIL [engine header]: Allokations-Header fehlt. got: %', v_out;
  END IF;
  IF v_out NOT LIKE '%## Plan Prosa Body%' THEN
    RAISE EXCEPTION 'FAIL [engine prose]: Prosa-Body fehlt unter dem Header';
  END IF;
  IF v_out NOT LIKE '%Facts last confirmed: 2026-06-01%' THEN
    RAISE EXCEPTION 'FAIL [engine stamp]: _meta-Stempel fehlt';
  END IF;
  RAISE NOTICE 'PASS [generische Engine: Banner + Header + Stempel + Prosa]';

  -- ---------- Inflation: real-Marker an der Ziel-Zeile + abgeleitete Nominal-Projektion ----------
  IF v_out NOT LIKE '%(real, Inflation 2 % p.a.)%' THEN
    RAISE EXCEPTION 'FAIL [inflation marker]: erwartet (real, Inflation 2 %% p.a.). got: %', v_out;
  END IF;
  IF v_out NOT LIKE '%real ≈%nominal bei Beginn der Auszahlungsphase ~2047%' THEN
    RAISE EXCEPTION 'FAIL [nominal projection]: erwartet Nominal-Projektion bei ~2047. got: %', v_out;
  END IF;
  RAISE NOTICE 'PASS [Inflation real-Marker + Nominal-Projektion bei Beginn der Auszahlungsphase ~2047 (render-at-fetch)]';

  -- ---------- TEST 2: Glidepath-Jahr render-at-fetch aus owner-birth_date (1980+54=2034) ----------
  IF v_out NOT LIKE '%De-Risking-Start ~2034 (Alter 54)%' THEN
    RAISE EXCEPTION 'FAIL [glidepath year]: erwartet ~2034 (Alter 54). got: %', v_out;
  END IF;
  RAISE NOTICE 'PASS [Glidepath-Startjahr 2034 aus owner-birth_date gerechnet (nie gespeichert)]';

  -- ---------- Phase A: Risikoprofil als eigene Header-Zeile (risk_tolerance zog aus goal hierher) ----------
  IF v_out NOT LIKE '%Risiko: Bereitschaft medium, Tragfähigkeit high (Stand 2026-06-01)%' THEN
    RAISE EXCEPTION 'FAIL [risk_profile render]: erwartet risk_profile-Header-Zeile. got: %', v_out;
  END IF;
  -- die ALTE goal-interne "Risiko <tolerance>"-Klausel an der Ziel-Zeile darf NICHT mehr erscheinen
  IF v_out LIKE '%/Monat real%, Risiko %' THEN
    RAISE EXCEPTION 'FAIL [risk render moved]: altes goal.risk_tolerance noch in der Ziel-Zeile';
  END IF;
  RAISE NOTICE 'PASS [risk_profile eigene Header-Zeile; goal-interne Risiko-Klausel entfernt]';

  -- ---------- Renteninformation (Plan 2026-10-26): eine Zeile je Rente aus fn_pension_outlook mit Plan-Inflation ----------
  INSERT INTO finance.pension (name, pension_type) VALUES ('__t_fc DRV', 'statutory');
  INSERT INTO finance.pension_statements (pension_id, statement_date, reached_claim, projection, scenario_1pct, scenario_2pct,
      em_monthly, regular_retirement_date)
  SELECT id, core.fn_today() - 30, 300, 2100, 2800, 3900, 800, core.fn_today() - 30 + 12418
  FROM finance.pension WHERE name = '__t_fc DRV';
  INSERT INTO finance.pension (name, pension_type) VALUES ('__t_fc bAV', 'occupational');
  SELECT content INTO v_out FROM core.fn_fetch_context('financial_planning');
  IF v_out NOT LIKE '%Rente __t_fc DRV%Hochrechnung 2100.00 €%2 %%: 3900.00 € (Kaufkraft ≈ 19%brutto%'
     OR v_out NOT LIKE '%Rente __t_fc bAV%noch keine Renteninformation%' THEN
    RAISE EXCEPTION 'FAIL [Renten-Zeilen]: got %', replace(substr(v_out, position('Rente' IN v_out), 700), E'\n', ' | ');
  END IF;
  RAISE NOTICE 'PASS [Renteninformation als Plan-Fakt: Szenarien + Kaufkraft + brutto, fehlende Info benannt]';

  -- ---------- TEST 3: keine family -> Glidepath ohne Jahr, kein Crash (defensiv) ----------
  DELETE FROM agent.core_contexts WHERE name = 'family';
  SELECT content INTO v_out FROM core.fn_fetch_context('financial_planning');
  IF v_out LIKE '%~20%(Alter 54)%' THEN
    RAISE EXCEPTION 'FAIL [no family]: erwartet Glidepath OHNE Jahr';
  END IF;
  IF v_out NOT LIKE '%(Alter 54)%' THEN
    RAISE EXCEPTION 'FAIL [no family]: Glidepath-Zeile (Alter 54) sollte bleiben';
  END IF;
  RAISE NOTICE 'PASS [keine family: Glidepath ohne Jahr, kein Crash]';

  -- ---------- TEST 4: kein Registry-Eintrag -> roher content (kein Banner) ----------
  DELETE FROM core.context_renderers WHERE context_name = 'financial_planning';
  SELECT content INTO v_out FROM core.fn_fetch_context('financial_planning');
  IF v_out LIKE '%Authoritative facts%' THEN
    RAISE EXCEPTION 'FAIL [no registry]: erwartet rohen content ohne Banner';
  END IF;
  IF v_out NOT LIKE '%## Plan Prosa Body%' THEN
    RAISE EXCEPTION 'FAIL [no registry]: roher content erwartet';
  END IF;
  RAISE NOTICE 'PASS [kein Registry-Eintrag: roher content, kein Banner]';

  -- ---------- TEST 5 (3. Zustand): Registry da, aber leere facts -> Header NULL -> roher content ----------
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('managed_by','agent','facts','{}'::jsonb)
   WHERE name = 'financial_planning';
  INSERT INTO core.context_renderers (context_name, render_fn, package)
  VALUES ('financial_planning', 'finance.fn_render_plan_facts', 'finance')
  ON CONFLICT (context_name) DO UPDATE SET render_fn = EXCLUDED.render_fn;
  SELECT content INTO v_out FROM core.fn_fetch_context('financial_planning');
  IF v_out LIKE '%Authoritative facts%' THEN
    RAISE EXCEPTION 'FAIL [empty facts]: kein Banner ueber leerem Header erwartet';
  END IF;
  RAISE NOTICE 'PASS [Registry da, leere facts -> Header NULL -> roher content (3. Zustand)]';
END $$;

-- ---------- TEST 6 (WS1b): family laeuft jetzt ueber DIESELBE generische Registry-Engine ----------
DO $$
DECLARE v_out TEXT;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'fix', NULL, 'lazy', E'## Family Prosa',
          jsonb_build_object('managed_by','agent',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','as_of','2026-06-01')))))
  ON CONFLICT (name) DO UPDATE SET content = EXCLUDED.content, metadata = EXCLUDED.metadata, load_strategy='lazy';
  -- Registry-Zeile (Host-Seed-Aequivalent aus packages/core/manifest.json "context_renderers")
  INSERT INTO core.context_renderers (context_name, render_fn, package)
  VALUES ('family', 'agent.fn_household_context', 'core')
  ON CONFLICT (context_name) DO UPDATE SET render_fn = EXCLUDED.render_fn, package = EXCLUDED.package;

  SELECT content INTO v_out FROM core.fn_fetch_context('family');
  IF v_out IS NULL OR v_out NOT LIKE '%Authoritative facts%' OR v_out NOT LIKE '%Erika Mustermann%' THEN
    RAISE EXCEPTION 'FAIL [family via registry]: family-Renderer gebrochen. got: %', left(v_out, 120);
  END IF;
  RAISE NOTICE 'PASS [WS1b: family ueber die generische Registry-Engine gerendert]';
END $$;

-- ---------- TEST 7 (WS3-Fix): load_context-Pfad unter context_ro ----------
-- fn_fetch_context liest core.context_renderers (Registry-Dispatch). Die Agenten binden load_context
-- unter der ENGEN Rolle context_ro, die per D10 KEINEN Zugriff auf Schema core hat. Ohne SECURITY DEFINER
-- bricht JEDER load_context-Call mit "permission denied for schema core" ab (real-LLM-Abnahme 2026-06-22
-- gefunden: der Agent meldete "kann nicht auf den Familienkontext zugreifen"). Die Function ist das
-- publizierte Lesefenster (Muster fn_advisor_read_plan) -> SECURITY DEFINER + gepinnter search_path.
-- (family + Registry-Zeile stammen aus TEST 6, dieselbe Transaktion.)
DO $$
DECLARE v_out TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
    RAISE NOTICE 'SKIP [context_ro fetch]: Rolle context_ro nicht vorhanden';
    RETURN;
  END IF;
  BEGIN
    SET LOCAL ROLE context_ro;
    SELECT content INTO v_out FROM core.fn_fetch_context('family');
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [context_ro fetch]: load_context-Pfad scheitert unter context_ro (fn muss SECURITY DEFINER sein) -- %', SQLERRM;
  END;
  IF v_out IS NULL OR v_out NOT LIKE '%Authoritative facts%' THEN
    RAISE EXCEPTION 'FAIL [context_ro fetch]: kein gerenderter Header unter context_ro (got: %)', left(COALESCE(v_out, '<null>'), 80);
  END IF;
  RAISE NOTICE 'PASS [WS3: fn_fetch_context unter context_ro = load_context-Rolle (SECURITY DEFINER)]';
END $$;

-- ---------- TEST 8 (P0b PER-USER): Suffix-Aufloesung + Isolation A != B + fail-closed ----------
-- fn_fetch_context(p_name, p_chat_id): traegt der Basis-Name scope='per_user', liegt der Inhalt suffigiert
-- '<base>__<person_id>'. person_id DETERMINISTISCH aus der chat_id via fn_resolve_sender (NIE LLM). Isolation:
-- A liest A, B liest B; unaufgeloeste/Sentinel-chat_id -> Basis-Name (leer) -> fail-closed.
DO $$
DECLARE v_out TEXT;
BEGIN
  -- Stub-Renderer (self-contained, kein career-Schema noetig): liefert den current_title-Header der ZEILE,
  -- die fn_fetch_context ihm als (physischen) Namen uebergibt -> beweist, dass der SUFFIGIERTE Name ankommt.
  CREATE OR REPLACE FUNCTION agent.fn_test_render_profile(p_name text) RETURNS text
    LANGUAGE sql STABLE AS $f$
      SELECT 'Rolle: ' || (c.metadata->'facts'->>'current_title')
      FROM agent.core_contexts c WHERE c.name = p_name AND c.metadata->'facts' ? 'current_title';
    $f$;

  -- family: Owner erika(111) + Mitglied lena(222)
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'fix', NULL, 'lazy', E'## Family',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
            jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata, load_strategy='lazy';

  -- per_user-Scope + Renderer-Registry (Basis-Name) + zwei suffigierte PII-Zeilen
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_profile', 'per_user', 'own_user_only', 'career')
  ON CONFLICT (context_name) DO UPDATE SET scope='per_user', write_permission='own_user_only';
  INSERT INTO core.context_renderers (context_name, render_fn, package)
  VALUES ('career_profile', 'agent.fn_test_render_profile', 'career')
  ON CONFLICT (context_name) DO UPDATE SET render_fn='agent.fn_test_render_profile';

  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('career_profile__erika','fix',NULL,'lazy',E'## Erika Prosa','agent','career', jsonb_build_object('facts', jsonb_build_object('current_title','Erika Dev'))),
         ('career_profile__lena', 'fix',NULL,'lazy',E'## Lena Prosa', 'agent','career', jsonb_build_object('facts', jsonb_build_object('current_title','Lena PM')))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- Isolation: 111 -> Erika
  SELECT content INTO v_out FROM core.fn_fetch_context('career_profile', '111');
  IF v_out IS NULL OR v_out NOT LIKE '%Erika Dev%' OR v_out LIKE '%Lena PM%' THEN
    RAISE EXCEPTION 'FAIL [per_user 111]: erwartet Erika Dev (nicht Lena). got: %', left(v_out,120);
  END IF;
  -- Isolation: 222 -> Lena
  SELECT content INTO v_out FROM core.fn_fetch_context('career_profile', '222');
  IF v_out IS NULL OR v_out NOT LIKE '%Lena PM%' OR v_out LIKE '%Erika Dev%' THEN
    RAISE EXCEPTION 'FAIL [per_user 222]: erwartet Lena PM (nicht Erika). got: %', left(v_out,120);
  END IF;
  RAISE NOTICE 'PASS [P0b per_user: Suffix-Aufloesung + Isolation A != B (Renderer bekommt den suffigierten Namen)]';

  -- fail-closed: numerisch-nicht-in-family (999) -> person NULL -> Basis-Name 'career_profile' (leer) -> keine Zeile
  SELECT content INTO v_out FROM core.fn_fetch_context('career_profile', '999');
  IF v_out IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [per_user fail-closed numeric]: unaufgeloester Sender muss leere Menge liefern. got: %', left(v_out,120);
  END IF;
  -- fail-closed: nicht-numerische/Sentinel-chat_id -> person NULL -> Basis-Name (leer)
  SELECT content INTO v_out FROM core.fn_fetch_context('career_profile', 'test_e2e_x');
  IF v_out IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [per_user fail-closed sentinel]: nicht-numerische chat_id muss leere Menge liefern. got: %', left(v_out,120);
  END IF;
  RAISE NOTICE 'PASS [P0b per_user fail-closed: unaufgeloester/Sentinel-Sender -> leere Menge (Basis-Name leer)]';

  -- household-Kontext mit chat_id -> KEIN Suffix (scope=household -> chat_id ignoriert). Synthetischer
  -- household-Name (P0c: career_planning ist jetzt per_user -> kein gutes household-Beispiel mehr).
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('__test_hh_plan__', 'household', 'owner_only', 'finance')
  ON CONFLICT (context_name) DO UPDATE SET scope='household', write_permission='owner_only';
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('__test_hh_plan__','fix',NULL,'lazy',E'HOUSEHOLD-PLAN', '{}'::jsonb)
  ON CONFLICT (name) DO UPDATE SET content = EXCLUDED.content, load_strategy='lazy';
  SELECT content INTO v_out FROM core.fn_fetch_context('__test_hh_plan__', '111');
  IF v_out IS DISTINCT FROM 'HOUSEHOLD-PLAN' THEN
    RAISE EXCEPTION 'FAIL [household no-suffix]: household-Kontext darf mit chat_id NICHT suffigiert werden. got: %', left(v_out,120);
  END IF;
  RAISE NOTICE 'PASS [P0b household: scope=household ignoriert chat_id -> kein Suffix]';
END $$;

-- ---------- TEST 9 (MANDATORY, P0b): 2-Arg-Form unter context_ro mit Aufloesung ----------
-- Genau der load_context-Monatebug-Pfad: der DEFINER ruft INTERN agent.fn_resolve_sender (liest family),
-- das context_ro NICHT direkt sehen darf. Muss unter context_ro mit non-NULL chat_id den richtigen
-- per_user-Header liefern -> beweist DEFINER + search_path-Pin halten. (family/scope/Zeilen aus TEST 8.)
DO $$
DECLARE v_out TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
    RAISE NOTICE 'SKIP [context_ro 2-arg]: Rolle context_ro nicht vorhanden';
    RETURN;
  END IF;
  BEGIN
    SET LOCAL ROLE context_ro;
    SELECT content INTO v_out FROM core.fn_fetch_context('career_profile', '111');
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [context_ro 2-arg]: per_user-Aufloesung scheitert unter context_ro (DEFINER/search_path verloren?) -- %', SQLERRM;
  END;
  IF v_out IS NULL OR v_out NOT LIKE '%Erika Dev%' THEN
    RAISE EXCEPTION 'FAIL [context_ro 2-arg]: kein per_user-Header unter context_ro (got: %)', left(COALESCE(v_out,'<null>'),80);
  END IF;
  RAISE NOTICE 'PASS [P0b: 2-Arg fn_fetch_context loest person_id unter context_ro auf (interner fn_resolve_sender im DEFINER)]';
END $$;

-- ---------- TEST 10 (Security-Audit 2026-10): physischer per_user-Name per LLM -> leere Menge ----------
-- Der Kontextname kommt vom LLM ($fromAI). B (lena, 222) darf A's Zeile nicht ueber ihren physischen Namen lesen —
-- weder mit eigener noch ohne chat_id. Die Regel lebt in agent.fn_is_per_user_row (eine Adresse). (Fixtures aus TEST 8.)
DO $$
DECLARE v_out TEXT;
BEGIN
  SELECT content INTO v_out FROM core.fn_fetch_context('career_profile__erika', '222');
  IF v_out IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [phys name 222]: lena las erikas Zeile ueber den physischen Namen (Leck). got: %', left(v_out,80);
  END IF;
  SELECT content INTO v_out FROM core.fn_fetch_context('career_profile__erika');
  IF v_out IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [phys name 1-arg]: physischer Name ohne chat_id lieferte Inhalt. got: %', left(v_out,80);
  END IF;
  IF NOT agent.fn_is_per_user_row('career_profile__erika') OR agent.fn_is_per_user_row('career_profile')
     OR agent.fn_is_per_user_row('family') OR agent.fn_is_per_user_row('__test_hh_plan__') THEN
    RAISE EXCEPTION 'FAIL [fn_is_per_user_row]: Klassifikation falsch (phys=true, Basis/household/Fixture=false erwartet)';
  END IF;
  RAISE NOTICE 'PASS [Audit: physischer per_user-Name -> leere Menge; fn_is_per_user_row klassifiziert]';
END $$;

-- ---------- TEST 11 (Security-Audit 2026-10): RLS — core_ro sieht keine per_user-Zeilen ----------
-- core_ro (Frei-SQL guide/monitor) sieht family + Basis-Zeilen, aber keine '<base>__<pid>'-Zeile. Eine Rolle, die
-- core_ro nur ERBT (wie die App-Rolle), sieht weiterhin alles (Policy auf current_user, nicht auf Mitgliedschaft).
-- context_ro hat kein direktes SELECT mehr (nur das DEFINER-Fenster). (Fixtures aus TEST 8.)
DO $$
DECLARE v_cnt INT; v_denied BOOLEAN := FALSE;
BEGIN
  SET LOCAL ROLE core_ro;
  SELECT count(*) INTO v_cnt FROM agent.core_contexts WHERE name LIKE 'career\_profile\_\_%';
  RESET ROLE;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [RLS core_ro]: core_ro sieht % per_user-Zeile(n)', v_cnt; END IF;
  SET LOCAL ROLE core_ro;
  SELECT count(*) INTO v_cnt FROM agent.core_contexts WHERE name = 'family';
  RESET ROLE;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [RLS core_ro]: family fuer core_ro unsichtbar (got %)', v_cnt; END IF;

  CREATE ROLE __test_inherits_core_ro NOLOGIN;
  GRANT core_ro TO __test_inherits_core_ro;
  SET LOCAL ROLE __test_inherits_core_ro;
  SELECT count(*) INTO v_cnt FROM agent.core_contexts WHERE name LIKE 'career\_profile\_\_%';
  RESET ROLE;
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [RLS erbende Rolle]: erwartet 2 per_user-Zeilen sichtbar, got % (Policy traf die App-Rolle)', v_cnt; END IF;

  BEGIN
    SET LOCAL ROLE context_ro;
    PERFORM 1 FROM agent.core_contexts LIMIT 1;
    RESET ROLE;
  EXCEPTION WHEN insufficient_privilege THEN RESET ROLE; v_denied := TRUE;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [context_ro]: direktes SELECT auf agent.core_contexts noch erlaubt'; END IF;
  RAISE NOTICE 'PASS [Audit RLS: core_ro ohne per_user-Zeilen, erbende Rolle unveraendert, context_ro nur ueber das Fenster]';
END $$;

ROLLBACK;
