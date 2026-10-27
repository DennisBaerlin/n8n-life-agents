-- tests/db/core/test_fn_app_screen.sql
-- Mini-App (docs/package-contract.md §3.12): core.fn_app_screen ist der eine Eingang der Seite. Er prueft initData,
-- app.enabled/app.audience, loest die Person selbst auf (Zero-Trust: eine person_id im Body zaehlt nie) und ruft den
-- registrierten Bildschirm-Handler eines aktiven Pakets. Nie ein RAISE (sonst ein Owner-Alert je Muell-Anfrage).
-- Die initData baut der Test hier mit pgcrypto (die Signatur-Pruefung selbst testet test_fn_app_verify_init_data.sql
-- gegen einen extern berechneten Vektor). Self-contained in BEGIN..ROLLBACK.
BEGIN;

DELETE FROM core.app_secret;
INSERT INTO core.app_secret (id, webapp_key) VALUES (TRUE, decode(repeat('ab', 32), 'hex'));

-- initData fuer eine Telegram-id, signiert mit dem Test-Schluessel, auth_date = jetzt (now() ist je Transaktion fest)
CREATE FUNCTION pg_temp.mk_init(p_uid bigint, p_lang text DEFAULT 'de') RETURNS text LANGUAGE sql AS $f$
  WITH f AS (
    SELECT extract(epoch FROM now())::bigint::text AS ad,
           '{"id":' || p_uid || ',"first_name":"Test","language_code":"' || p_lang || '"}' AS u
  )
  SELECT 'auth_date=' || ad || '&user=' || u || '&hash='
         || encode(public.hmac(convert_to('auth_date=' || ad || E'\nuser=' || u, 'UTF8'),
                               decode(repeat('ab', 32), 'hex'), 'sha256'), 'hex')
  FROM f;
$f$;

-- Fake-Handler: probe -> leer nur fuer das Kind; sonst ein View mit der aufgeloesten person_id als Rohtext.
CREATE OR REPLACE FUNCTION core.fn_test_app_echo(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT CASE WHEN COALESCE((p->'params'->>'probe')::boolean, false)
              THEN jsonb_build_object('ok', true, 'empty', p->>'person_id' = 'kid')
              ELSE jsonb_build_object('ok', true, 'title', core.fn_ui_tpl('core.app.title'), 'hero', NULL,
                     'banners', '[]'::jsonb,
                     'sections', jsonb_build_array(jsonb_build_object('title', core.fn_ui_tpl('core.app.title'),
                       'empty', core.fn_ui_tpl('core.app.title'),
                       'items', jsonb_build_array(jsonb_build_object('label', p->>'person_id', 'sub', NULL,
                          'value', core.fn_ui_money(12.5, 'EUR'), 'gap', false, 'pill', NULL, 'progress', NULL, 'target', NULL)))))
         END;
$f$;
CREATE OR REPLACE FUNCTION core.fn_test_app_boom(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
BEGIN RAISE EXCEPTION 'boom'; END;
$f$;
CREATE OR REPLACE FUNCTION core.fn_test_app_deny(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('ok', false, 'code', 'forbidden');
$f$;

INSERT INTO core.package_registry (package, version, status) VALUES ('core', '0.1.0', 'active')
ON CONFLICT (package) DO UPDATE SET status = 'active';
DELETE FROM core.package_registry WHERE package = 'zz_nopkg';

DELETE FROM core.app_screens;
INSERT INTO core.app_screens (screen, package, handler_fn, ord, icon) VALUES
  ('tst',   'core',      'core.fn_test_app_echo',   10, '🧪'),
  ('boom',  'core',      'core.fn_test_app_boom',   20, '💥'),
  ('deny',  'core',      'core.fn_test_app_deny',   30, '⛔'),
  ('gone',  'core',      'core.fn_no_such_handler', 40, '❓'),
  ('other', 'zz_nopkg',  'core.fn_test_app_echo',   50, '📦');

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'app-screen test fixture', NULL, 'lazy', E'## fam',
        jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
          jsonb_build_object('person_id','owner','first_name','Erika','last_name','Muster',
                             'role','owner','birth_date','1980-01-01','telegram_user_id',111,'language','de','as_of','2026-06-11'),
          jsonb_build_object('person_id','partner','first_name','Hans','last_name','Muster',
                             'role','partner','birth_date','1982-01-01','telegram_user_id',222,'language','ko','as_of','2026-06-11'),
          jsonb_build_object('person_id','kid','first_name','Kim','last_name','Muster',
                             'role','child','birth_date','2015-01-01','telegram_user_id',333,'as_of','2026-06-11')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;

INSERT INTO core.ui_texts (key, lang, text, package)
SELECT k, l, upper(l) || ':' || k, 'core'
FROM unnest(ARRAY['core.app.title', 'core.app.error.denied', 'core.app.error.expired', 'core.app.error.unavailable']) k
CROSS JOIN (VALUES ('de'), ('en'), ('ko')) ls(l)
ON CONFLICT (key, lang) DO UPDATE SET text = excluded.text;

INSERT INTO core.config (package, category, key, value) VALUES
  ('core', 'app', 'enabled', 'true'), ('core', 'app', 'audience', 'owner'), ('core', 'app', 'init_data_max_age_s', '3600')
ON CONFLICT (category, key) DO UPDATE SET value = excluded.value;

DO $$
DECLARE r jsonb;
BEGIN
  -- [1] Navigation als Owner: aktiver Bildschirm mit Inhalt ist drin, inaktives Paket nicht; Texte in Owner-Sprache
  r := core.fn_app_screen(jsonb_build_object('init_data', pg_temp.mk_init(111))::text);
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [1] Navigation: %', r; END IF;
  IF NOT (r->'screens') @> '[{"screen":"tst","icon":"🧪"}]' THEN RAISE EXCEPTION 'FAIL [1] tst fehlt: %', r; END IF;
  IF (r->'screens') @> '[{"screen":"other"}]' THEN RAISE EXCEPTION 'FAIL [1] Bildschirm eines inaktiven Pakets sichtbar: %', r; END IF;
  IF r->'screens'->0->'title'->>'value' IS DISTINCT FROM 'core.app.screen.tst' THEN RAISE EXCEPTION 'FAIL [1] Titel-Key <pkg>.app.screen.<screen>: %', r; END IF;
  IF r->'ui'->>'lang' IS DISTINCT FROM 'de' OR r->'ui'->>'locale' IS NULL THEN RAISE EXCEPTION 'FAIL [1] ui lang/locale: %', r; END IF;
  RAISE NOTICE 'PASS [1] Navigation Owner';

  -- [2] Bildschirm als Owner: Handler bekommt die AUFGELOESTE Person, eine person_id im Body zaehlt nicht
  r := core.fn_app_screen(jsonb_build_object('init_data', pg_temp.mk_init(111), 'screen', 'tst', 'person_id', 'kid')::text);
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [2] Bildschirm: %', r; END IF;
  IF r->'view'->'sections'->0->'items'->0->>'label' IS DISTINCT FROM 'owner' THEN RAISE EXCEPTION 'FAIL [2] Person aus dem Body uebernommen: %', r; END IF;
  IF r->'ui'->'t'->>'core.app.title' IS DISTINCT FROM 'DE:core.app.title' THEN RAISE EXCEPTION 'FAIL [2] Texte aus dem View fehlen in ui.t: %', r; END IF;
  RAISE NOTICE 'PASS [2] Bildschirm Owner, Zero-Trust person_id';

  -- [3] audience=owner: Partner abgewiesen, Text in seiner Sprache (ko)
  r := core.fn_app_screen(jsonb_build_object('init_data', pg_temp.mk_init(222, 'ko'))::text);
  IF r->>'code' IS DISTINCT FROM 'not_allowed' THEN RAISE EXCEPTION 'FAIL [3] Partner bei audience=owner: %', r; END IF;
  IF r->'ui'->>'lang' IS DISTINCT FROM 'ko' OR r->'text'->>'value' IS DISTINCT FROM 'core.app.error.denied' THEN RAISE EXCEPTION 'FAIL [3] Ablehnungs-Text: %', r; END IF;
  RAISE NOTICE 'PASS [3] audience=owner -> Partner not_allowed';

  -- [4] audience=household: Kind darf, sieht aber nur Bildschirme mit eigenem Inhalt (probe leer -> nicht in der Navigation)
  UPDATE core.config SET value = 'household' WHERE category = 'app' AND key = 'audience';
  r := core.fn_app_screen(jsonb_build_object('init_data', pg_temp.mk_init(333))::text);
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [4] Kind-Navigation: %', r; END IF;
  IF (r->'screens') @> '[{"screen":"tst"}]' THEN RAISE EXCEPTION 'FAIL [4] leerer Bildschirm in der Kind-Navigation: %', r; END IF;
  RAISE NOTICE 'PASS [4] audience=household, leere Bildschirme ausgeblendet';

  -- [5] unbekannte Person (gueltige Signatur) -> unknown
  r := core.fn_app_screen(jsonb_build_object('init_data', pg_temp.mk_init(999))::text);
  IF r->>'code' IS DISTINCT FROM 'unknown' THEN RAISE EXCEPTION 'FAIL [5] Fremder: %', r; END IF;
  IF r ? 'screens' OR r ? 'view' THEN RAISE EXCEPTION 'FAIL [5] Fremder bekommt Daten: %', r; END IF;
  RAISE NOTICE 'PASS [5] Fremder -> unknown';

  -- [6] Bildschirm-Fehlerfaelle: unbekannt, Handler fehlt, inaktives Paket, Handler wirft, Handler lehnt ab
  r := core.fn_app_screen(jsonb_build_object('init_data', pg_temp.mk_init(111), 'screen', 'nix')::text);
  IF r->>'code' IS DISTINCT FROM 'unknown_screen' THEN RAISE EXCEPTION 'FAIL [6a] unbekannter Bildschirm: %', r; END IF;
  r := core.fn_app_screen(jsonb_build_object('init_data', pg_temp.mk_init(111), 'screen', 'gone')::text);
  IF r->>'code' IS DISTINCT FROM 'unavailable' THEN RAISE EXCEPTION 'FAIL [6b] Handler fehlt: %', r; END IF;
  r := core.fn_app_screen(jsonb_build_object('init_data', pg_temp.mk_init(111), 'screen', 'other')::text);
  IF r->>'code' IS DISTINCT FROM 'unavailable' THEN RAISE EXCEPTION 'FAIL [6c] inaktives Paket: %', r; END IF;
  r := core.fn_app_screen(jsonb_build_object('init_data', pg_temp.mk_init(111), 'screen', 'boom')::text);
  IF r->>'code' IS DISTINCT FROM 'error' THEN RAISE EXCEPTION 'FAIL [6d] Handler-Exception nicht abgefangen: %', r; END IF;
  r := core.fn_app_screen(jsonb_build_object('init_data', pg_temp.mk_init(111), 'screen', 'deny')::text);
  IF r->>'code' IS DISTINCT FROM 'forbidden' OR (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [6e] Handler-Ablehnung: %', r; END IF;
  RAISE NOTICE 'PASS [6] Bildschirm-Fehlerfaelle ohne RAISE';

  -- [7] Muell-Body und kaputte initData -> malformed / bad_signature, nie RAISE
  r := core.fn_app_screen('kein json');
  IF r->>'code' IS DISTINCT FROM 'malformed' THEN RAISE EXCEPTION 'FAIL [7a] kein JSON: %', r; END IF;
  r := core.fn_app_screen(NULL);
  IF r->>'code' IS DISTINCT FROM 'malformed' THEN RAISE EXCEPTION 'FAIL [7b] NULL: %', r; END IF;
  r := core.fn_app_screen('[1,2]');
  IF r->>'code' IS DISTINCT FROM 'malformed' THEN RAISE EXCEPTION 'FAIL [7c] Array: %', r; END IF;
  r := core.fn_app_screen(jsonb_build_object('init_data', replace(pg_temp.mk_init(111), '"id":111', '"id":112'))::text);
  IF r->>'code' IS DISTINCT FROM 'bad_signature' THEN RAISE EXCEPTION 'FAIL [7d] gefaelschte id: %', r; END IF;
  IF r->'text'->>'value' IS DISTINCT FROM 'core.app.error.denied' THEN RAISE EXCEPTION 'FAIL [7d] Text: %', r; END IF;
  RAISE NOTICE 'PASS [7] Muell -> Ablehnung ohne RAISE';

  -- [8] app.enabled=false -> disabled fuer alle, auch den Owner
  UPDATE core.config SET value = 'false' WHERE category = 'app' AND key = 'enabled';
  r := core.fn_app_screen(jsonb_build_object('init_data', pg_temp.mk_init(111))::text);
  IF r->>'code' IS DISTINCT FROM 'disabled' THEN RAISE EXCEPTION 'FAIL [8] enabled=false: %', r; END IF;
  DELETE FROM core.config WHERE category = 'app' AND key = 'enabled';
  r := core.fn_app_screen(jsonb_build_object('init_data', pg_temp.mk_init(111))::text);
  IF r->>'code' IS DISTINCT FROM 'disabled' THEN RAISE EXCEPTION 'FAIL [8b] fehlende Config-Zeile muss fail-closed sein: %', r; END IF;
  RAISE NOTICE 'PASS [8] app.enabled fail-closed';
END $$;

ROLLBACK;
