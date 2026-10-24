-- tests/db/core/test_fn_render_welcome.sql
-- Testet core.fn_render_welcome(p_lang) (Install-UX-Phase 6 + Textkatalog Phase B): die EINE Textquelle der
-- Owner-Begruessung, gelesen vom Orchestrator (bare /start, core_ro, Sprache des Owners) UND vom Installer (nach dem
-- Pairing + _oc_finalize, Superuser, ohne Argument = Owner-Sprache).
--   Vertrag: {ok, kind: new|back, lang, text, buttons:[{text, callback_data}]}
--   new  = Core-Haushalt noch offen (guide_onboarding_state 'unknown') -> Vorname + installierte Funktionen
--          + naechster Schritt + 2 Core-Knoepfe (immer gueltig, auch ohne Pakete).
--   back = Haushalt erledigt -> kurzer Text, keine Knoepfe.
--   Installiert = core.package_registry status 'active' (Paketname aus dem Katalog <pkg>.package.name, Fallback
--   Paket-id); 'inactive' wird mit dem Einschalt-Befehl genannt; 'installing' (abgebrochen) zaehlt nicht.
--   Alle Texte aus core.ui_texts in p_lang (NULL -> Owner-Sprache; Key fehlt -> en). Die Fixture-Texte tragen
--   Sprach-Marker (DE/KO/EN), damit die Tests den Wortlaut des echten Katalogs nicht spiegeln.
-- Pattern: BEGIN…ROLLBACK, RAISE EXCEPTION 'FAIL …' = Test fehlgeschlagen.
BEGIN;

DO $$
DECLARE
  r JSONB;
BEGIN
  -- Fixture: Katalog-Texte (de/ko vollstaendig, en nur fuer den Fallback-Fall) + Paketnamen.
  DELETE FROM core.ui_texts WHERE key LIKE 'core.welcome.%' OR key LIKE '%.package.name';
  INSERT INTO core.ui_texts (key, lang, text, package)
  SELECT k, l, upper(l) || ':' || v, split_part(k, '.', 1)
  FROM (VALUES
      ('core.welcome.hello',           'hello'),
      ('core.welcome.hello_name',      'hello {name}'),
      ('core.welcome.intro',           'intro'),
      ('core.welcome.installed',       'installed {list}'),
      ('core.welcome.inactive',        'inactive {list}'),
      ('core.welcome.inactive_item',   '{name} activate {package}'),
      ('core.welcome.household_first', 'household first'),
      ('core.welcome.setup',           'setup'),
      ('core.welcome.setup_known',     'setup known'),
      ('core.welcome.help_more',       'help more /help'),
      ('core.welcome.help_install',    'lifeagents package install /help'),
      ('core.welcome.btn_household',   'btn household'),
      ('core.welcome.btn_help',        'btn help'),
      ('core.welcome.back',            'back'),
      ('core.welcome.back_name',       'back {name}'),
      ('core.welcome.back_hint',       'back hint /help'),
      ('core.package.name',            'Core'),
      ('finance.package.name',         'Finance'),
      ('career.package.name',          'Career'),
      ('estate.package.name',          'Estate')) t(k, v)
  CROSS JOIN (VALUES ('de'), ('ko')) ls(l);
  INSERT INTO core.ui_texts (key, lang, text, package)
  VALUES ('core.welcome.intro', 'en', 'EN:intro', 'core');
  DELETE FROM core.ui_texts WHERE key = 'core.welcome.intro' AND lang = 'ko';   -- ko fehlt -> en

  -- Paket-Zustand (nur Core aktiv) + Owner (Sprache de) + Haushalt offen.
  DELETE FROM core.package_registry;
  INSERT INTO core.package_registry (package, display_name, status) VALUES ('core', 'Grundsystem', 'active');
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', '(Inhaber bei der Installation angelegt)', 'agent', 'core',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','owner','first_name','Erika','last_name','Mustermann',
                               'role','owner','birth_date','1980-05-20','language','de','as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET content = EXCLUDED.content, metadata = EXCLUDED.metadata;
  INSERT INTO agent.guide_onboarding_state (section_key, ord, label, status)
  VALUES ('household', 0, 'Haushalt & Personen', 'unknown')
  ON CONFLICT (section_key) DO UPDATE SET status = 'unknown';

  -- (1) Ohne Argument = Owner-Sprache de: kind=new, Vorname, Installiert-Zeile, Nachinstallations-Hinweis,
  --     beide Core-Knoepfe in fester Reihenfolge mit Katalog-Texten.
  r := core.fn_render_welcome();
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'kind' <> 'new' OR r->>'lang' <> 'de' THEN
    RAISE EXCEPTION 'FAIL (1) erwartet ok/new/de, got %', r;
  END IF;
  IF position('DE:hello Erika' IN r->>'text') = 0 THEN RAISE EXCEPTION 'FAIL (1) Vorname fehlt: %', r->>'text'; END IF;
  IF position('DE:installed DE:Core' IN r->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL (1) Installiert-Zeile falsch: %', r->>'text';
  END IF;
  IF position('DE:setup known' IN r->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL (1) Owner bekannt -> setup_known erwartet: %', r->>'text';
  END IF;
  IF position('lifeagents package install' IN r->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL (1) Nachinstallations-Hinweis fehlt: %', r->>'text';
  END IF;
  -- Knopf-Vertrag: workflow_lint prueft die Orchestrator-Knoepfe gegen genau diese Liste.
  IF (SELECT jsonb_agg(b->>'callback_data') FROM jsonb_array_elements(r->'buttons') b)
     IS DISTINCT FROM '["onboarding:core:household","help:overview"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL (1) Knoepfe falsch: %', r->'buttons';
  END IF;
  IF (SELECT jsonb_agg(b->>'text') FROM jsonb_array_elements(r->'buttons') b)
     IS DISTINCT FROM '["DE:btn household","DE:btn help"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL (1) Knopf-Texte nicht aus dem Katalog: %', r->'buttons';
  END IF;

  -- (1b) Koreanisch explizit: alle Texte ko, fehlender ko-Key faellt auf en zurueck, Knoepfe ko.
  r := core.fn_render_welcome('ko');
  IF r->>'lang' <> 'ko' OR position('KO:hello Erika' IN r->>'text') = 0 OR position('DE:' IN r->>'text') > 0 THEN
    RAISE EXCEPTION 'FAIL (1b) ko-Text erwartet: %', r;
  END IF;
  IF position('EN:intro' IN r->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL (1b) fehlender ko-Key muss auf en fallen: %', r->>'text';
  END IF;
  IF (SELECT jsonb_agg(b->>'text') FROM jsonb_array_elements(r->'buttons') b)
     IS DISTINCT FROM '["KO:btn household","KO:btn help"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL (1b) ko-Knoepfe: %', r->'buttons';
  END IF;

  -- (1c) Unbekannte Sprache -> en (die Kette des Katalogs), kein Fehler.
  r := core.fn_render_welcome('xx');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'lang' <> 'en' THEN
    RAISE EXCEPTION 'FAIL (1c) unbekannte Sprache -> en erwartet: %', r;
  END IF;

  -- (2) finance aktiv, career ausgeschaltet, estate haengt in 'installing' (abgebrochen).
  INSERT INTO core.package_registry (package, display_name, status) VALUES
    ('finance', 'Finanzen', 'active'), ('career', 'Karriere', 'inactive'), ('estate', 'Nachlass & Vorsorge', 'installing');
  r := core.fn_render_welcome('de');
  IF position('DE:installed DE:Core, DE:Finance' IN r->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL (2) aktive Pakete nicht gelistet: %', r->>'text';
  END IF;
  IF position('DE:inactive DE:DE:Career activate career' IN r->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL (2) ausgeschaltetes Paket ohne Einschalt-Befehl: %', r->>'text';
  END IF;
  IF position('Estate' IN r->>'text') > 0 THEN
    RAISE EXCEPTION 'FAIL (2) installing-Paket faelschlich genannt: %', r->>'text';
  END IF;
  IF position('lifeagents package install' IN r->>'text') > 0 OR position('DE:help more' IN r->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL (2) mit Paketen: kein install-Versprechen, aber /help-Verweis erwartet: %', r->>'text';
  END IF;

  -- (3) Paketname fehlt im Katalog -> Paket-id als Fallback.
  DELETE FROM core.ui_texts WHERE key = 'finance.package.name';
  r := core.fn_render_welcome('de');
  IF position('DE:Core, finance' IN r->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL (3) Fallback auf Paket-id fehlt: %', r->>'text';
  END IF;

  -- (4) Haushalt erledigt -> kind=back, keine Knoepfe.
  UPDATE agent.guide_onboarding_state SET status = 'completed' WHERE section_key = 'household';
  r := core.fn_render_welcome('ko');
  IF r->>'kind' <> 'back' OR jsonb_array_length(r->'buttons') <> 0 THEN
    RAISE EXCEPTION 'FAIL (4) erwartet back ohne Knoepfe, got %', r;
  END IF;
  IF position('KO:back Erika' IN r->>'text') = 0 OR position('KO:back hint' IN r->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL (4) back-Text falsch: %', r->>'text';
  END IF;

  -- (5) kein family-Owner (Skelett fehlt) -> generische Anrede, Sprache en (Kette ohne Owner), trotzdem ok.
  --   (family.persons darf nie leer sein = DB-Gesetz -> die Zeile im Test ganz entfernen, Schutz vorher heben.)
  DELETE FROM core.protected_contexts WHERE context_name = 'family';
  DELETE FROM agent.core_contexts WHERE name = 'family';
  UPDATE agent.guide_onboarding_state SET status = 'unknown' WHERE section_key = 'household';
  r := core.fn_render_welcome();
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'lang' <> 'en' THEN
    RAISE EXCEPTION 'FAIL (5) ohne Owner: %', r;
  END IF;
  r := core.fn_render_welcome('de');
  IF position('DE:hello' IN r->>'text') = 0 OR position('DE:setup' IN r->>'text') = 0
     OR position('DE:setup known' IN r->>'text') > 0 THEN
    RAISE EXCEPTION 'FAIL (5) ohne Owner: generische Anrede + setup erwartet: %', r->>'text';
  END IF;

  RAISE NOTICE 'PASS core.fn_render_welcome: de/ko/en-Fallback, new/back, aktiv/inaktiv/installing, Paketname-Fallback, ohne Owner';
END $$;

-- (6) Rollen-Perspektive: der Orchestrator liest unter core_ro.
DO $$
DECLARE r JSONB;
BEGIN
  SET LOCAL ROLE core_ro;
  r := core.fn_render_welcome('ko');
  RESET ROLE;
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL (6) core_ro: %', r; END IF;
  RAISE NOTICE 'PASS core.fn_render_welcome unter core_ro';
END $$;

ROLLBACK;
