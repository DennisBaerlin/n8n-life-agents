-- tests/db/finance/test_fn_app_screen_accounts.sql
-- finance.fn_app_screen_accounts(p) — Mini-App-Bildschirm „Konten“ (UX-Gesamtkonzept 2026-10-31, 5.2) auf dem
--   Fixture-Haushalt tests/util/util_app_household.sql:
--   [1] Owner: je Geld-Konto ein Abschnitt, keine Kinder-Konten, kein 0-EUR-Konto ohne Bewegung (B10), kein Hero (B8),
--       kein Abschnittswert (B6); Reihenfolge Probleme -> Alltagskonten -> uebrige (B7); fn_app_view_lint = 0
--   [2] Zeilen: Sparkonto „Stand heute · davon frei“ + „Tiefster Stand“ warn „reicht bis {Monat}“ (B1/B2); Girokonto mit
--       Bruecke <= 8 Zeilen; Gemeinschaftskonto ohne Auszug -> Notiz statt Tiefster Stand, Einzelposten gedeckelt;
--       Tagesgeld ohne Abfluss -> nur „Stand heute“; Gehen ab / Kommen rein getrennt, nie netto
--   [3] Partnerin sieht dasselbe wie der Owner
--   [4] Kind: nur eigenes Konto, kein Haushaltsname (Volltextsuche), Eingang vom Haushalt neutral; Lint = 0
--   [5] Gast ohne Daten: ein leerer Abschnitt; probe empty
--   [6] probe: Banner nur alert/warn, Ziel accounts, Ziel-Geld-Luecke nur alert; Frei-SQL / kaputte Eingabe
--   [7] fn_app_accounts_listed: die eine Regel (Haushalt ohne Kinder-Konten, sonst eigene)
BEGIN;
\ir ../../util/util_app_household.sql

DO $$
DECLARE
  v jsonb; v2 jsonb; s jsonb; it jsonb; v_txt text; v_names text[]; v_lint text;
  k_p2p text := 'Sparkonto P2P';
BEGIN
  -- [1] Owner
  v := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_jonas', 'params', '{}'::jsonb));
  IF (v->>'ok')::boolean IS NOT TRUE OR jsonb_typeof(v->'hero') <> 'null'
     OR v->'title' <> core.fn_ui_tpl('finance.app.accounts.title') THEN
    RAISE EXCEPTION 'FAIL [1a] ok, Titel, kein Hero, got %', v; END IF;
  SELECT array_agg(x->'title'->'params'->>'account' ORDER BY o) INTO v_names
    FROM jsonb_array_elements(v->'sections') WITH ORDINALITY q(x, o);
  IF NOT v_names @> ARRAY['Girokonto Jonas', 'Gemeinschaftskonto', 'Sparkonto P2P', 'Broker-Cash Jonas', 'Tagesgeld Mira']
     OR v_names && ARRAY['Taschengeld Lea', 'Taschengeld Tom', 'Verrechnungskonto Krypto'] THEN
    RAISE EXCEPTION 'FAIL [1b] Konten-Menge (ohne Kinder, ohne 0-EUR-Konto), got %', v_names; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections') x WHERE jsonb_typeof(COALESCE(x->'value', 'null'::jsonb)) <> 'null') THEN
    RAISE EXCEPTION 'FAIL [1c] kein Abschnittswert'; END IF;
  -- Reihenfolge: das Sparkonto (warn) vor allen Konten ohne Pille; unter den uebrigen cash vor p2p
  IF array_position(v_names, 'Sparkonto P2P') > array_position(v_names, 'Tagesgeld Mira')
     OR array_position(v_names, 'Sparkonto P2P') > array_position(v_names, 'Gemeinschaftskonto') THEN
    RAISE EXCEPTION 'FAIL [1d] Reihenfolge Probleme zuerst, got %', v_names; END IF;
  SELECT string_agg(l.rule || '@' || l.path, ' ') INTO v_lint FROM core.fn_app_view_lint(v) l;
  IF v_lint IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1e] fn_app_view_lint Owner: %', v_lint; END IF;
  RAISE NOTICE 'PASS [1] Owner: Konten-Menge, Reihenfolge, kein Hero/Abschnittswert, Lint = 0';

  -- [2] Zeilen
  SELECT x INTO s FROM jsonb_array_elements(v->'sections') x WHERE x->'title'->'params'->>'account' = k_p2p;
  IF s->'items'->0->'label' <> core.fn_ui_tpl('finance.app.accounts.balance_today')
     OR s->'items'->0->'value' <> core.fn_ui_money(40000, 'EUR')
     OR s->'items'->0->'sub' <> core.fn_ui_tpl('finance.app.accounts.free_of', jsonb_build_object('amount', core.fn_ui_money(13200, 'EUR'))) THEN
    RAISE EXCEPTION 'FAIL [2a] Sparkonto Stand heute · davon 13200 frei, got %', s->'items'->0; END IF;
  it := s->'items'->1;
  IF it->'label' <> core.fn_ui_tpl('finance.app.accounts.low') OR it->'pill'->>'state' <> 'warn'
     OR it->'pill'->'text'->>'value' <> 'finance.app.accounts.pill_until'
     OR it->'pill'->'text'->'params'->'month'->>'kind' <> 'month' THEN
    RAISE EXCEPTION 'FAIL [2b] Sparkonto Tiefster Stand warn reicht bis {Monat}, got %', it; END IF;
  -- Girokonto: Bruecke <= 8 Zeilen, Gehen ab / Kommen rein
  SELECT x INTO s FROM jsonb_array_elements(v->'sections') x WHERE x->'title'->'params'->>'account' = 'Girokonto Jonas';
  SELECT i INTO it FROM jsonb_array_elements(s->'items') i WHERE i->'label' = core.fn_ui_tpl('finance.app.accounts.low');
  IF it IS NULL OR jsonb_array_length(it->'details') > 8 OR jsonb_array_length(it->'details') < 3 THEN
    RAISE EXCEPTION 'FAIL [2c] Girokonto: Tiefster Stand mit Bruecke (3..8 Zeilen), got %', it; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s->'items') i WHERE i->'label'->>'value' = 'finance.app.accounts.out_until'
                                                                   AND (i->'value'->>'value')::numeric < 0)
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s->'items') i WHERE i->'label'->>'value' = 'finance.app.accounts.in_until'
                                                                   AND (i->'value'->>'value')::numeric > 0) THEN
    RAISE EXCEPTION 'FAIL [2d] Girokonto: Gehen ab (< 0) und Kommen rein (> 0) getrennt, got %', s; END IF;
  -- Gemeinschaftskonto: Notiz statt Tiefster Stand, Einzelposten gedeckelt
  SELECT x INTO s FROM jsonb_array_elements(v->'sections') x WHERE x->'title'->'params'->>'account' = 'Gemeinschaftskonto';
  IF s->'note' <> core.fn_ui_tpl('finance.app.accounts.no_statement')
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(s->'items') i WHERE i->'label' = core.fn_ui_tpl('finance.app.accounts.low'))
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(s->'items') i WHERE jsonb_array_length(COALESCE(i->'details', '[]'::jsonb)) > 8) THEN
    RAISE EXCEPTION 'FAIL [2e] Gemeinschaftskonto: Notiz, kein Tiefster Stand, Deckel, got %', s; END IF;
  -- Tagesgeld Mira: nichts geht ab -> nur Stand heute
  SELECT x INTO s FROM jsonb_array_elements(v->'sections') x WHERE x->'title'->'params'->>'account' = 'Tagesgeld Mira';
  IF jsonb_array_length(s->'items') <> 1 THEN RAISE EXCEPTION 'FAIL [2f] Tagesgeld ohne Abfluss: nur Stand heute, got %', s; END IF;
  RAISE NOTICE 'PASS [2] Zeilen: frei, reicht bis, Bruecke, Notiz, Deckel, getrennte Ab-/Eingaenge';

  -- [3] Partnerin = Owner
  v2 := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_mira', 'params', '{}'::jsonb));
  IF v2 <> v THEN RAISE EXCEPTION 'FAIL [3] Partnerin sieht anderes als der Owner'; END IF;
  RAISE NOTICE 'PASS [3] Partnerin = Owner';

  -- [4] Kind: nur eigenes Konto, kein Haushaltsname
  v := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_lea', 'params', '{}'::jsonb));
  v_txt := v::text;
  IF jsonb_array_length(v->'sections') <> 1 OR v->'sections'->0->'title'->'params'->>'account' <> 'Taschengeld Lea'
     OR v_txt LIKE '%Girokonto%' OR v_txt LIKE '%Gemeinschaftskonto%' OR v_txt LIKE '%Jonas%' OR v_txt LIKE '%Mira%' THEN
    RAISE EXCEPTION 'FAIL [4a] Kind: nur eigenes Konto, keine Eltern-/Haushaltsnamen, got %', v; END IF;
  IF v_txt NOT LIKE '%finance.app.accounts.from_household%' THEN
    RAISE EXCEPTION 'FAIL [4b] Eingang vom Haushalt neutral, got %', v; END IF;
  SELECT string_agg(l.rule || '@' || l.path, ' ') INTO v_lint FROM core.fn_app_view_lint(v) l;
  IF v_lint IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4c] Lint Kind: %', v_lint; END IF;
  v := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_tom', 'params', '{}'::jsonb));
  SELECT string_agg(l.rule || '@' || l.path, ' ') INTO v_lint FROM core.fn_app_view_lint(v) l;
  IF jsonb_array_length(v->'sections') <> 1 OR v_lint IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4d] Tom: %, %', v, v_lint; END IF;
  RAISE NOTICE 'PASS [4] Kinder: nur Eigenes, Haushalt neutral, Lint = 0';

  -- [5] Gast ohne Daten
  v := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_gast', 'params', '{}'::jsonb));
  SELECT string_agg(l.rule || '@' || l.path, ' ') INTO v_lint FROM core.fn_app_view_lint(v) l;
  IF jsonb_array_length(v->'sections') <> 1 OR jsonb_array_length(v->'sections'->0->'items') <> 0 OR v_lint IS NOT NULL
     OR (finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_gast', 'params', '{"probe":true}'::jsonb))->>'empty')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [5] Gast: leerer Abschnitt + probe empty, got % / %', v, v_lint; END IF;
  RAISE NOTICE 'PASS [5] Gast ohne Daten';

  -- [6] probe + Fehler
  v := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_jonas', 'params', '{"probe":true}'::jsonb));
  IF (v->>'empty')::boolean OR jsonb_typeof(v->'banners') <> 'array' OR v ? 'sections'
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v->'banners') b
                 WHERE b->>'state' NOT IN ('alert', 'warn') OR b->'target'->>'screen' <> 'accounts'
                    OR (b->'text'->>'value' = 'finance.app.accounts.banner_gap' AND b->>'state' <> 'alert')) THEN
    RAISE EXCEPTION 'FAIL [6a] probe: Banner nur alert/warn, Ziel accounts, Luecke nur alert, got %', v; END IF;
  IF finance.fn_app_screen_accounts('"x"'::jsonb)->>'code' <> 'bad_request'
     OR finance.fn_app_screen_accounts('{"params":{}}'::jsonb)->>'code' <> 'bad_request' THEN
    RAISE EXCEPTION 'FAIL [6b] kaputte Eingabe -> bad_request'; END IF;
  RAISE NOTICE 'PASS [6] probe + bad_request';

  -- [7] die eine Regel der Konten-Menge
  IF EXISTS (SELECT 1 FROM finance.fn_app_accounts_listed('fxh_jonas') l(id) JOIN finance.accounts a ON a.id = l.id
              WHERE a.owner_person_id IN ('fxh_lea', 'fxh_tom'))
     OR EXISTS (SELECT 1 FROM finance.fn_app_accounts_listed('fxh_lea') l(id) JOIN finance.accounts a ON a.id = l.id
                 WHERE a.owner_person_id IS DISTINCT FROM 'fxh_lea')
     OR NOT EXISTS (SELECT 1 FROM finance.fn_app_accounts_listed('fxh_lea')) THEN
    RAISE EXCEPTION 'FAIL [7] fn_app_accounts_listed'; END IF;
  RAISE NOTICE 'PASS [7] fn_app_accounts_listed';
END $$;

-- [8] Frei-SQL-Rollen: kein EXECUTE; selbst MIT Test-Grant -> forbidden (Muster test_fn_app_screen_overview)
DO $$
BEGIN
  IF has_function_privilege('finance_ro', 'finance.fn_app_screen_accounts(jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [8a] Frei-SQL-Rolle hat EXECUTE auf den Bildschirm-Handler'; END IF;
  GRANT EXECUTE ON FUNCTION finance.fn_app_screen_accounts(jsonb) TO finance_ro;
END $$;
SET LOCAL SESSION AUTHORIZATION finance_ro;
DO $$
DECLARE v jsonb;
BEGIN
  v := finance.fn_app_screen_accounts('{"person_id":"fxh_jonas","params":{}}');
  IF v <> '{"ok":false,"code":"forbidden"}'::jsonb THEN RAISE EXCEPTION 'FAIL [8b] Frei-SQL -> forbidden, got %', v; END IF;
  RAISE NOTICE 'PASS [8] Frei-SQL-Sitzung -> forbidden';
END $$;

ROLLBACK;
