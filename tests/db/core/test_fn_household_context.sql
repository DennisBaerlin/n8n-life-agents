-- tests/db/core/test_fn_household_context.sql
-- Testet die Render-/Ableitungs-Schicht (render-at-fetch, nie backen; das LLM rechnet nie):
--   * fn_regelaltersgrenze        (DRV-Stufenplan: <1947=65, 1947-1958 +1M/Jahr, 1959-1963 66+2M/Jahr, >=1964=67)
--   * fn_household_context(text)   (HEADER-only seit WS1b; die Engine wrappt Banner/Stempel/Prosa)
--   * fn_fetch_context            (WS1b: EIN generischer Registry-Dispatch fuer ALLE Contexts; kein Whitelist/render_fn-Flag mehr)
--   (Der Finanzprofil-Renderer ist seit Phase A paket-besessen -> tests/db/finance/test_fn_render_finance_profile.sql.)
-- WS1b-BIT-REGRESSION: die nutzer-sichtbare fetch_context-Ausgabe (Banner + Header + Stempel + '---' + Prosa)
-- ist byte-identisch zur Vor-WS1b-Ausgabe — die Header-only-fn + generischer Engine-Wrap reproduzieren sie.
-- db_test seedet core.context_renderers NICHT -> der Test seedet die Registry-Zeilen selbst (P2-1), wie
-- seed_data.sh es aus packages/core/manifest.json tut (sonst maskiert die graceful-degradation den Refactor).
BEGIN;

DO $$
DECLARE
  v_txt TEXT;
BEGIN

  -- ---------- Fixture (gleiches Skelett wie test_fn_household_facts) ----------
  -- REIHENFOLGE (robust gegen Prod-State, KEINE Annahme ueber Prod-person_ids): ERST das
  -- Prod-finance_profile auf 0 Personen reduzieren (sonst blockt der bidirektionale
  -- Single-Writer-Check den family-Fixture-Write, falls Prod-finance_profile Personen
  -- referenziert, die die Fixture-family nicht hat), DANN family auf die Fixture-Personen,
  -- DANN finance_profile darauf (jede fp-Person existiert dann in family).
  UPDATE agent.core_contexts
  SET metadata = jsonb_set(COALESCE(metadata,'{}'::jsonb), '{facts,persons}', '[]'::jsonb)
  WHERE name = 'finance_profile';

  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa-Body\nKorea-Verbindung etc.',
          jsonb_build_object(
            'managed_by','agent','protected', true, 'render_fn','fn_household_context',
            'facts', jsonb_build_object(
              'persons', jsonb_build_array(
                jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                   'role','owner','birth_date','1980-05-20','as_of','2026-06-11'),
                jsonb_build_object('person_id','lisa','first_name','Lisa','last_name','Mustermann',
                                   'role','child','birth_date','2023-02-17','as_of','2026-06-11')
              ),
              'household', jsonb_build_object('shared_finances', true))))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content,
        agent_name = EXCLUDED.agent_name, load_strategy = EXCLUDED.load_strategy,
        metadata = EXCLUDED.metadata;

  -- Kontroll-Kontext ohne Registry-Eintrag (Fetch muss stored content liefern)
  INSERT INTO agent.core_contexts (name, description, load_strategy, content)
  VALUES ('__test_plain_ctx__', 'plain', 'lazy', 'PLAIN CONTENT')
  ON CONFLICT (name) DO UPDATE SET content = EXCLUDED.content, load_strategy = 'lazy';

  -- Render-Registry (Host-Seed-Aequivalent aus packages/core/manifest.json "context_renderers"):
  -- WS1b dispatcht family ueber DIESELBE generische Engine wie die Paket-Kontexte.
  INSERT INTO core.context_renderers (context_name, render_fn, package) VALUES
    ('family', 'agent.fn_household_context', 'core')
  ON CONFLICT (context_name) DO UPDATE SET render_fn = EXCLUDED.render_fn, package = EXCLUDED.package;

  -- ---------- TEST 1: fn_regelaltersgrenze (DRV-Stufenplan, deterministische Fixtures) ----------
  IF agent.fn_regelaltersgrenze(DATE '1980-05-20') IS DISTINCT FROM DATE '2047-05-20' THEN
    RAISE EXCEPTION 'FAIL fn_regelaltersgrenze [1980 -> 67]: got %', agent.fn_regelaltersgrenze(DATE '1980-05-20');
  END IF;
  IF agent.fn_regelaltersgrenze(DATE '1964-01-01') IS DISTINCT FROM DATE '2031-01-01' THEN
    RAISE EXCEPTION 'FAIL fn_regelaltersgrenze [1964 -> 67]: got %', agent.fn_regelaltersgrenze(DATE '1964-01-01');
  END IF;
  IF agent.fn_regelaltersgrenze(DATE '1946-06-15') IS DISTINCT FROM DATE '2011-06-15' THEN
    RAISE EXCEPTION 'FAIL fn_regelaltersgrenze [<1947 -> 65]: got %', agent.fn_regelaltersgrenze(DATE '1946-06-15');
  END IF;
  -- 1950: 65 Jahre + 4 Monate (1947=+1M ... 1950=+4M)
  IF agent.fn_regelaltersgrenze(DATE '1950-03-10') IS DISTINCT FROM DATE '2015-07-10' THEN
    RAISE EXCEPTION 'FAIL fn_regelaltersgrenze [1950 -> 65+4M]: got %', agent.fn_regelaltersgrenze(DATE '1950-03-10');
  END IF;
  -- 1960: 66 Jahre + 4 Monate (1959=+2M, 1960=+4M)
  IF agent.fn_regelaltersgrenze(DATE '1960-12-01') IS DISTINCT FROM DATE '2027-04-01' THEN
    RAISE EXCEPTION 'FAIL fn_regelaltersgrenze [1960 -> 66+4M]: got %', agent.fn_regelaltersgrenze(DATE '1960-12-01');
  END IF;
  RAISE NOTICE 'PASS fn_regelaltersgrenze [Stufenplan 65 / 65+xM / 66+xM / 67]';

  -- ---------- TEST 2 (BIT-REGRESSION): family ueber die Engine = Banner + Header + Ableitungen + Prosa ----------
  SELECT content INTO v_txt FROM core.fn_fetch_context('family');
  IF v_txt NOT LIKE '%Authoritative facts%' THEN
    RAISE EXCEPTION 'FAIL family [engine banner]: Banner-Zeile fehlt (Registry/Engine-Wrap): %', left(v_txt, 200);
  END IF;
  IF v_txt NOT LIKE '%Erika Mustermann%' OR v_txt NOT LIKE '%20.05.1980%' THEN
    RAISE EXCEPTION 'FAIL family [header]: Person/Geburtsdatum fehlt: %', left(v_txt, 400);
  END IF;
  -- Alter dynamisch (gegen dieselbe deterministische SQL-Ableitung geprueft, nie gebacken)
  IF v_txt NOT LIKE '%Alter: ' || date_part('year', age(DATE '1980-05-20'))::int || '%' THEN
    RAISE EXCEPTION 'FAIL family [header]: dynamisches Alter fehlt/falsch: %', left(v_txt, 400);
  END IF;
  -- Regelaltersgrenze als Ableitung (2047 fuer Jahrgang 1980) + Kindergeld bis (Kind 2023 -> 2048)
  IF v_txt NOT LIKE '%2047%' THEN RAISE EXCEPTION 'FAIL family [header]: Regelaltersgrenze 2047 fehlt'; END IF;
  IF v_txt NOT LIKE '%2048%' THEN RAISE EXCEPTION 'FAIL family [header]: Kindergeld-bis 2048 fehlt'; END IF;
  -- Engine-Wrap: '---' Trenner + Prosa-Body wortgetreu darunter
  IF v_txt NOT LIKE '%' || E'\n\n---\n\n' || '%' OR v_txt NOT LIKE '%Korea-Verbindung etc.%' THEN
    RAISE EXCEPTION 'FAIL family [engine wrap]: Trenner/Prosa-Body fehlt: %', left(v_txt, 400);
  END IF;
  RAISE NOTICE 'PASS family [Engine: Banner + Header (Alter/Regelaltersgrenze/Kindergeld) + Prosa]';

  -- ---------- TEST 4: generischer Engine-Dispatch (drei Zustaende) ----------
  -- (a) kein Registry-Eintrag -> roher stored content (graceful)
  SELECT content INTO v_txt FROM core.fn_fetch_context('__test_plain_ctx__');
  IF v_txt IS DISTINCT FROM 'PLAIN CONTENT' THEN
    RAISE EXCEPTION 'FAIL fetch_context [no registry]: erwartet stored content, got %', v_txt;
  END IF;
  -- (b) unbekannter Name -> 0 Zeilen
  IF EXISTS (SELECT 1 FROM core.fn_fetch_context('__does_not_exist__')) THEN
    RAISE EXCEPTION 'FAIL fetch_context [missing]: erwartet 0 Zeilen';
  END IF;
  -- (c) Registry-Eintrag zeigt auf eine NICHT existente fn -> to_regprocedure-Guard -> roher content
  INSERT INTO core.context_renderers (context_name, render_fn, package)
  VALUES ('__test_plain_ctx__', 'agent.fn_does_not_exist', 'core')
  ON CONFLICT (context_name) DO UPDATE SET render_fn = EXCLUDED.render_fn;
  SELECT content INTO v_txt FROM core.fn_fetch_context('__test_plain_ctx__');
  IF v_txt IS DISTINCT FROM 'PLAIN CONTENT' THEN
    RAISE EXCEPTION 'FAIL fetch_context [missing render_fn]: Guard muss auf content zurueckfallen, got %', v_txt;
  END IF;
  RAISE NOTICE 'PASS fn_fetch_context [generischer Dispatch: kein Eintrag / missing-name / kaputte render_fn -> content]';

  -- ---------- TEST 6 (WS1b): das alte metadata.render_fn-Flag ist INERT (Engine liest NUR die Registry) ----------
  -- Eine Zeile mit metadata.render_fn='fn_household_context' aber OHNE Registry-Eintrag bekommt NIE den
  -- family-Inhalt untergeschoben (der frueher name-gebundene Whitelist-Pfad + das mutable Flag sind weg).
  DELETE FROM core.context_renderers WHERE context_name = '__test_plain_ctx__';
  UPDATE agent.core_contexts
  SET metadata = jsonb_set(COALESCE(metadata,'{}'::jsonb), '{render_fn}', '"fn_household_context"')
  WHERE name = '__test_plain_ctx__';
  SELECT content INTO v_txt FROM core.fn_fetch_context('__test_plain_ctx__');
  IF v_txt IS DISTINCT FROM 'PLAIN CONTENT' THEN
    RAISE EXCEPTION 'FAIL fetch_context [render_fn inert]: metadata-Flag wurde wieder beachtet: %', left(v_txt, 200);
  END IF;
  RAISE NOTICE 'PASS fn_fetch_context [metadata.render_fn-Flag inert: nur die Registry dispatcht]';

END $$;

ROLLBACK;
