-- tests/db/core/test_fn_app_view_lint.sql
-- core.fn_app_view_lint(p_view, p_neutral_keys, p_undated_keys) — Regel-Pruefer der Mini-App-View-Modelle
--   (docs/package-contract.md §3.12 Design rules). Je Regel ein Treffer mit Pfad + der saubere Gegenfall:
--   [0] saubere Seite -> 0 Zeilen          [1] L1 Summe ueber einer Zeile     [2] L2 ok-Pille / ok-Balken
--   [3] L3 neutral nur mit freigegebenem Key [4] L4 Summe = Hero (auch als tpl, sign egal)
--   [5] L5 Details > 8                     [6] L6 doppelter Fakt (benannte Zeile/Detailzeile, egal welcher Text-Key),
--                                              tpl-Label kein Anker, 0 zaehlt nicht
--   [7] L7 warn ohne Betrag/Datum, month zaehlt, undated-Key frei   [8] L8 Summe trotz gap
--   [9] kaputte Form -> shape statt Exception   [10] kein EXECUTE fuer PUBLIC
-- Self-contained (BEGIN..ROLLBACK), rein (keine Tabellen).
BEGIN;

CREATE FUNCTION pg_temp.m(v numeric, c text DEFAULT 'EUR') RETURNS jsonb LANGUAGE sql AS $$ SELECT core.fn_ui_money(v, c) $$;
CREATE FUNCTION pg_temp.t(k text, p jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$ SELECT core.fn_ui_tpl(k, p) $$;
-- Zeile: label, value, pill, progress, details, gap
CREATE FUNCTION pg_temp.it(lbl jsonb, val jsonb, pill jsonb DEFAULT NULL, prog jsonb DEFAULT NULL,
                           det jsonb DEFAULT NULL, gap boolean DEFAULT FALSE, sub jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('label', lbl, 'sub', sub, 'value', val, 'gap', gap, 'pill', pill, 'progress', prog, 'target', NULL)
         || CASE WHEN det IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('details', det) END
$$;
CREATE FUNCTION pg_temp.sec(items jsonb, val jsonb DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('title', pg_temp.t('x.app.s.section'), 'value', val, 'empty', pg_temp.t('x.app.s.empty'), 'items', items)
$$;
CREATE FUNCTION pg_temp.view(secs jsonb, hero numeric DEFAULT 1000) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('ok', true, 'title', pg_temp.t('x.app.s.title'),
           'hero', jsonb_build_object('label', pg_temp.t('x.app.s.hero'), 'value', pg_temp.m(hero), 'gap', false, 'note', NULL),
           'banners', '[]'::jsonb, 'sections', secs)
$$;
CREATE FUNCTION pg_temp.lint(v jsonb, nk text[] DEFAULT '{}', uk text[] DEFAULT '{}') RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(rule || '@' || path, ' ' ORDER BY path, rule), '') FROM core.fn_app_view_lint(v, nk, uk)
$$;

DO $$
DECLARE
  v_clean jsonb; r text; v_det jsonb;
  v_warn_amt jsonb := jsonb_build_object('state', 'warn', 'icon', 'alert',
                        'text', pg_temp.t('x.app.s.short', jsonb_build_object('amount', pg_temp.m(50))));
BEGIN
  -- [0] saubere Seite: zwei Zeilen mit Summe (≠ Hero), warn mit Betrag, neutraler Balken, 8 Details
  SELECT jsonb_agg(jsonb_build_object('label', 'D' || g, 'value', NULL)) INTO v_det FROM generate_series(1, 8) g;
  v_clean := pg_temp.view(jsonb_build_array(
    pg_temp.sec(jsonb_build_array(
      pg_temp.it('"Konto A"', pg_temp.m(300), v_warn_amt, '{"pct": 40, "state": "neutral"}', v_det),
      pg_temp.it('"Konto B"', pg_temp.m(200))), pg_temp.m(500)),
    pg_temp.sec(jsonb_build_array(pg_temp.it(pg_temp.t('x.app.s.out'), pg_temp.m(-300))))));
  r := pg_temp.lint(v_clean);
  IF r <> '' THEN RAISE EXCEPTION 'FAIL [0] saubere Seite meldet: %', r; END IF;
  -- auch 2-Argument-Aufruf (Vertrag mit C/D)
  IF EXISTS (SELECT 1 FROM core.fn_app_view_lint(v_clean, '{}'::text[])) THEN RAISE EXCEPTION 'FAIL [0b] 2-Argument-Aufruf'; END IF;
  RAISE NOTICE 'PASS [0] saubere Seite = 0 Zeilen';

  -- [1] L1: Summe ueber genau einer Zeile
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(pg_temp.sec(jsonb_build_array(pg_temp.it('"A"', pg_temp.m(5))), pg_temp.m(5)))));
  IF r <> 'L1@sections[0].value' THEN RAISE EXCEPTION 'FAIL [1] L1 erwartet, got %', r; END IF;
  RAISE NOTICE 'PASS [1] L1';

  -- [2] L2: ok-Pille und ok-Balken
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(pg_temp.sec(jsonb_build_array(
         pg_temp.it('"A"', pg_temp.m(5), '{"state":"ok","icon":"check","text":{"kind":"tpl","value":"x.app.s.fine","params":{}}}',
                    '{"pct": 100, "state": "ok"}'))))));
  IF r <> 'L2@sections[0].items[0].pill L2@sections[0].items[0].progress' THEN RAISE EXCEPTION 'FAIL [2] L2 erwartet, got %', r; END IF;
  RAISE NOTICE 'PASS [2] L2 Pille + Balken';

  -- [3] L3: neutral nur mit freigegebenem Key
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(pg_temp.sec(jsonb_build_array(
         pg_temp.it('"A"', pg_temp.m(5), '{"state":"neutral","icon":"pause","text":{"kind":"tpl","value":"x.app.s.paused","params":{}}}'))))),
       ARRAY['x.app.s.other']);
  IF r <> 'L3@sections[0].items[0].pill' THEN RAISE EXCEPTION 'FAIL [3a] L3 erwartet, got %', r; END IF;
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(pg_temp.sec(jsonb_build_array(
         pg_temp.it('"A"', pg_temp.m(5), '{"state":"neutral","icon":"pause","text":{"kind":"tpl","value":"x.app.s.paused","params":{}}}'))))),
       ARRAY['x.app.s.paused']);
  IF r <> '' THEN RAISE EXCEPTION 'FAIL [3b] freigegebener neutral-Key meldet %', r; END IF;
  RAISE NOTICE 'PASS [3] L3';

  -- [4] L4: Summe = Hero, als money (mit sign) und als tpl mit einem money-Parameter
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(pg_temp.sec(jsonb_build_array(pg_temp.it('"A"', pg_temp.m(600)), pg_temp.it('"B"', pg_temp.m(400))),
         core.fn_ui_money(1000, 'EUR', true)))));
  IF r <> 'L4@sections[0].value' THEN RAISE EXCEPTION 'FAIL [4a] L4 (money, sign egal) erwartet, got %', r; END IF;
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(pg_temp.sec(jsonb_build_array(pg_temp.it('"A"', pg_temp.m(600)), pg_temp.it('"B"', pg_temp.m(400))),
         pg_temp.t('x.app.s.per_month', jsonb_build_object('amount', pg_temp.m(1000)))))));
  IF r <> 'L4@sections[0].value' THEN RAISE EXCEPTION 'FAIL [4b] L4 (tpl) erwartet, got %', r; END IF;
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(pg_temp.sec(jsonb_build_array(pg_temp.it('"A"', pg_temp.m(600)), pg_temp.it('"B"', pg_temp.m(400))),
         pg_temp.m(1000, 'USD')))));
  IF r <> '' THEN RAISE EXCEPTION 'FAIL [4c] andere Waehrung ist nicht der Hero, got %', r; END IF;
  RAISE NOTICE 'PASS [4] L4';

  -- [5] L5: 9 Details
  SELECT jsonb_agg(jsonb_build_object('label', 'D' || g, 'value', NULL)) INTO v_det FROM generate_series(1, 9) g;
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(pg_temp.sec(jsonb_build_array(pg_temp.it('"A"', pg_temp.m(5), NULL, NULL, v_det))))));
  IF r <> 'L5@sections[0].items[0].details' THEN RAISE EXCEPTION 'FAIL [5] L5 erwartet, got %', r; END IF;
  RAISE NOTICE 'PASS [5] L5';

  -- [6] L6: dasselbe Konto mit demselben Stand in zwei Abschnitten; derselbe sub-Betrag an derselben Zeile
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(
         pg_temp.sec(jsonb_build_array(pg_temp.it('"Giro"', pg_temp.m(2800)))),
         pg_temp.sec(jsonb_build_array(pg_temp.it('"Giro"', pg_temp.m(2800))))), 9999));
  IF r <> 'L6@sections[1].items[0]' THEN RAISE EXCEPTION 'FAIL [6a] L6 (Zeilenwert) erwartet, got %', r; END IF;
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(
         pg_temp.sec(jsonb_build_array(pg_temp.it('"Sparkonto"', pg_temp.m(1), NULL, NULL, NULL, false,
                       pg_temp.t('x.app.s.free', jsonb_build_object('amount', pg_temp.m(220)))))),
         pg_temp.sec(jsonb_build_array(pg_temp.it('"Sparkonto"', pg_temp.m(2), NULL, NULL,
                       jsonb_build_array(jsonb_build_object('label', pg_temp.t('x.app.s.free', jsonb_build_object('amount', pg_temp.m(220))), 'value', NULL))))))));
  IF r <> 'L6@sections[1].items[0]' THEN RAISE EXCEPTION 'FAIL [6b] L6 (sub -> details) erwartet, got %', r; END IF;
  -- Zeilenwert taucht als Detailzeile mit demselben Namen in einem anderen Abschnitt auf (egal welcher Text-Key)
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(
         pg_temp.sec(jsonb_build_array(pg_temp.it('"Girokonto"', pg_temp.m(2800)))),
         pg_temp.sec(jsonb_build_array(pg_temp.it('"Ziele"', pg_temp.m(50), NULL, NULL,
                       jsonb_build_array(jsonb_build_object('label', 'Girokonto', 'value', pg_temp.m(2800))))))), 9999));
  IF r <> 'L6@sections[1].items[0].details[0]' THEN RAISE EXCEPTION 'FAIL [6d] L6 (Zeile -> Detailzeile) erwartet, got %', r; END IF;
  -- Zeilenwert taucht im sub derselben benannten Zeile eines anderen Abschnitts auf (anderer Key)
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(
         pg_temp.sec(jsonb_build_array(pg_temp.it('"Sparkonto"', pg_temp.m(48000)))),
         pg_temp.sec(jsonb_build_array(pg_temp.it('"Sparkonto"', pg_temp.m(3), NULL, NULL, NULL, false,
                       pg_temp.t('x.app.s.balance', jsonb_build_object('amount', pg_temp.m(48000))))))), 9999));
  IF r <> 'L6@sections[1].items[0]' THEN RAISE EXCEPTION 'FAIL [6e] L6 (Wert -> sub, anderer Key) erwartet, got %', r; END IF;
  -- Gegenfaelle: generisches tpl-Label je Konto-Abschnitt, Betrag 0, gleicher Abschnitt
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(
         pg_temp.sec(jsonb_build_array(pg_temp.it(pg_temp.t('x.app.s.out'), pg_temp.m(-3000)))),
         pg_temp.sec(jsonb_build_array(pg_temp.it(pg_temp.t('x.app.s.out'), pg_temp.m(-3000)))),
         pg_temp.sec(jsonb_build_array(pg_temp.it('"Leer"', pg_temp.m(0)))),
         pg_temp.sec(jsonb_build_array(pg_temp.it('"Leer"', pg_temp.m(0)))),
         pg_temp.sec(jsonb_build_array(pg_temp.it('"X"', pg_temp.m(7)), pg_temp.it('"X"', pg_temp.m(7)))))));
  IF r <> '' THEN RAISE EXCEPTION 'FAIL [6c] tpl-Label/0/gleicher Abschnitt duerfen nicht melden, got %', r; END IF;
  RAISE NOTICE 'PASS [6] L6';

  -- [7] L7: warn ohne Zahl; month und date zaehlen; undated-Key frei
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(pg_temp.sec(jsonb_build_array(
         pg_temp.it('"A"', pg_temp.m(5), '{"state":"warn","icon":"alert","text":{"kind":"tpl","value":"x.app.s.price_missing","params":{}}}'),
         pg_temp.it('"B"', pg_temp.m(6), jsonb_build_object('state', 'alert', 'icon', 'alert',
                    'text', pg_temp.t('x.app.s.until', jsonb_build_object('m', core.fn_ui_month('2027-04-15'))))),
         pg_temp.it('"C"', pg_temp.m(7), jsonb_build_object('state', 'warn', 'icon', 'calendar',
                    'text', pg_temp.t('x.app.s.ends', jsonb_build_object('d', core.fn_ui_date('2027-04-15')))))), NULL))));
  IF r <> 'L7@sections[0].items[0].pill' THEN RAISE EXCEPTION 'FAIL [7a] nur die nackte warn-Pille erwartet, got %', r; END IF;
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(pg_temp.sec(jsonb_build_array(
         pg_temp.it('"A"', pg_temp.m(5), '{"state":"warn","icon":"alert","text":{"kind":"tpl","value":"x.app.s.price_missing","params":{}}}'))))),
       '{}', ARRAY['x.app.s.price_missing']);
  IF r <> '' THEN RAISE EXCEPTION 'FAIL [7b] undated-Key meldet %', r; END IF;
  RAISE NOTICE 'PASS [7] L7';

  -- [8] L8: Summe trotz gap
  r := pg_temp.lint(pg_temp.view(jsonb_build_array(pg_temp.sec(jsonb_build_array(
         pg_temp.it('"A"', pg_temp.m(5)), pg_temp.it('"B"', pg_temp.m(6, 'CHF'), NULL, NULL, NULL, true)), pg_temp.m(5)))));
  IF r <> 'L8@sections[0].value' THEN RAISE EXCEPTION 'FAIL [8] L8 erwartet, got %', r; END IF;
  RAISE NOTICE 'PASS [8] L8';

  -- [9] kaputte Form -> shape, nie eine Exception
  IF pg_temp.lint('"kein Objekt"'::jsonb) <> 'shape@$' THEN RAISE EXCEPTION 'FAIL [9a] View kein Objekt'; END IF;
  IF pg_temp.lint('{"sections": 3}'::jsonb) <> 'shape@sections' THEN RAISE EXCEPTION 'FAIL [9b] sections kein Array'; END IF;
  r := pg_temp.lint(jsonb_build_object('sections', jsonb_build_array('x', jsonb_build_object('items', 'y'),
         jsonb_build_object('items', jsonb_build_array(5, jsonb_build_object('label', 'A', 'details', 'z'))))));
  IF r <> 'shape@sections[0] shape@sections[1].items shape@sections[2].items[0] shape@sections[2].items[1].details' THEN
    RAISE EXCEPTION 'FAIL [9c] shape-Pfade, got %', r; END IF;
  -- kaputter Betrag: shape an seinem Ort, die uebrigen Regeln laufen weiter (L1 im Folge-Abschnitt)
  r := pg_temp.lint(jsonb_build_object('sections', jsonb_build_array(
         jsonb_build_object('value', '{"kind":"money","value":"abc"}'::jsonb, 'items', jsonb_build_array(
           pg_temp.it('"A"', '{"kind":"money","value":"n/a"}'::jsonb), pg_temp.it('"B"', pg_temp.m(1)))),
         pg_temp.sec(jsonb_build_array(pg_temp.it('"C"', pg_temp.m(5))), pg_temp.m(5)))));
  IF r <> 'shape@sections[0].items[0] shape@sections[0].value L1@sections[1].value' THEN
    RAISE EXCEPTION 'FAIL [9d] kaputter Betrag -> shape am Ort + weitere Regeln, got %', r; END IF;
  RAISE NOTICE 'PASS [9] shape';

  -- [10] kein EXECUTE fuer PUBLIC
  IF has_function_privilege('public', 'core.fn_app_view_lint(jsonb,text[],text[])', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [10] fn_app_view_lint ausfuehrbar fuer PUBLIC'; END IF;
  RAISE NOTICE 'PASS [10] nicht oeffentlich';
END $$;

ROLLBACK;
