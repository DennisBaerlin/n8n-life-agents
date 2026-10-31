-- tests/db/finance/test_fn_app_screen_overview.sql
-- finance.fn_app_screen_overview(p jsonb) — Mini-App-Bildschirm „Vermögen" (docs/package-contract.md §3.12, View-Modell v1).
--   1) Owner + Partner (Allow-List) sehen den Haushalt OHNE Kinder (Uebersicht R3): Hero = Netto, Note Besitz/Schulden,
--      Abschnitte Schnell verfuegbar (Anteils-Balken) / Schulden (Kredit positiv, ohne Summe -> Bildschirm Kredite) /
--      Vermoegen der Kinder (je Kind Netto, Details je Anlageart = Summe); KEINE Konten-Liste (Heimat: Tab Konten);
--      fn_app_view_lint = 0 (UX-Gesamtkonzept 2026-10-31).
--   2) Kind sieht NUR eigene Zeilen (owner_person_id = ich): Volltextsuche ueber die GANZE Antwort findet keinen Namen
--      eines Haushalts-/Eltern-/Fremdkontos und ueberhaupt kein *id-Feld; Summe = Hero -> keine Abschnittssumme.
--   3) Unbekannte Rolle (Allow-List, nicht Deny-List) und unbekannte Person sehen nur Eigenes bzw. nichts.
--   4) params.probe -> nur {ok, empty}; fehlende person_id / Muell -> {ok:false, code:'bad_request'} ohne RAISE.
--   5) Waehrung ohne Kurs -> gap im Hero und in der Anlageart; der Abschnitt traegt dann keine Summe.
--   6) Frei-SQL-Sitzung (finance_ro, selbst MIT EXECUTE) -> {ok:false, code:'forbidden'}; ohne Test-Grant kein EXECUTE.
--   7) Besitz als Liquiditaets-Leiter: Schnell verfuegbar (Konten, P2P, Depot) / Langfristig gebunden (Festgeld,
--      Immobilie); Summe nur ab 2 Zeilen ohne gap, Untertitel nur der Anteil.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_hh_cash INT; v_p_cash INT; v_kid_cash INT; v_kid_depot INT; v_hh_depot INT; v_loan INT; v_g_cash INT; v_chf INT;
  v jsonb; v_txt text; v_n numeric; v_sec jsonb; v_it jsonb;
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';

  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('appo_owner',   'Owner Beispiel',   'owner'),
    ('appo_partner', 'Partner Beispiel', 'partner'),
    ('appo_kid',     'Kind Beispiel',    'child'),
    ('appo_guest',   'Gast Beispiel',    'grandparent');

  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__appo_hh_cash__', 'cash', 'EUR', 'active', NULL) RETURNING id INTO v_hh_cash;
  UPDATE finance.account_balances SET balance = 10000 WHERE account_id = v_hh_cash;
  UPDATE finance.accounts SET last_reconciled_at = DATE '2026-10-01' WHERE id = v_hh_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__appo_p_cash__', 'cash', 'EUR', 'active', 'appo_partner') RETURNING id INTO v_p_cash;
  UPDATE finance.account_balances SET balance = 4000 WHERE account_id = v_p_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('<img src=x onerror=alert(1)>', 'cash', 'EUR', 'active', NULL);
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('__appo_hh_depot__', 'stocks_depot', 'EUR', 'active', v_hh_cash, NULL) RETURNING id INTO v_hh_depot;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
    VALUES (v_hh_depot, 'APO00000001', 'APOHH', '__appo_hh_etf__', 5, 100, 'EUR', 'sp500');
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__appo_hh_loan__', 'loan', 'EUR', 'active', NULL) RETURNING id INTO v_loan;
  UPDATE finance.account_balances SET balance = -2000 WHERE account_id = v_loan;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__appo_hh_chf__', 'cash', 'CHF', 'active', NULL) RETURNING id INTO v_chf;
  UPDATE finance.account_balances SET balance = 700 WHERE account_id = v_chf;

  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__appo_kid_cash__', 'cash', 'EUR', 'active', 'appo_kid') RETURNING id INTO v_kid_cash;
  UPDATE finance.account_balances SET balance = 300 WHERE account_id = v_kid_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('__appo_kid_depot__', 'stocks_depot', 'EUR', 'active', v_kid_cash, 'appo_kid') RETURNING id INTO v_kid_depot;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
    VALUES (v_kid_depot, 'APO00000002', 'APOKID', 'Kind ETF', 10, 100, 'EUR', 'sp500');

  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__appo_g_cash__', 'cash', 'EUR', 'active', 'appo_guest') RETURNING id INTO v_g_cash;
  UPDATE finance.account_balances SET balance = 50 WHERE account_id = v_g_cash;

  -- ===== 1) Owner: ganzer Haushalt =====
  v := finance.fn_app_screen_overview(jsonb_build_object('person_id', 'appo_owner', 'params', '{}'::jsonb));
  IF (v->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [1a] Owner ok erwartet, got %', v; END IF;
  IF NOT (v ? 'title' AND v ? 'hero' AND v ? 'banners' AND v ? 'sections') THEN
    RAISE EXCEPTION 'FAIL [1b] View-Modell-v1-Felder fehlen: %', v; END IF;
  IF v->'title' <> core.fn_ui_tpl('finance.app.overview.title') THEN RAISE EXCEPTION 'FAIL [1c] title %', v->'title'; END IF;
  IF jsonb_array_length(v->'banners') <> 0 OR jsonb_array_length(v->'sections') <> 3 THEN
    RAISE EXCEPTION 'FAIL [1d] erwartet 0 Banner + 3 Abschnitte (Schnell verfuegbar, Schulden, Kinder; keine Konten-Liste), got %', v; END IF;
  -- Hero: 10000 + 4000 + 500 (HH-Depot, Kaufwert ohne Kurs) - 2000 (Kredit) + 50 (Gast); Kind (300 + 1000) NICHT;
  -- CHF ohne Kurs faellt aus -> gap
  v_n := (v->'hero'->'value'->>'value')::numeric;
  IF v_n IS DISTINCT FROM 12550 OR v->'hero'->'value'->>'kind' <> 'money' OR v->'hero'->'value'->>'currency' <> 'EUR' THEN
    RAISE EXCEPTION 'FAIL [1e] Hero erwartet 12550 EUR (ohne Kind), got %', v->'hero'; END IF;
  IF (v->'hero'->>'gap')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [5a] Hero-gap (CHF ohne Kurs) fehlt'; END IF;
  IF v->'hero'->'label' <> core.fn_ui_tpl('finance.app.overview.hero') THEN RAISE EXCEPTION 'FAIL [1f] hero.label'; END IF;
  -- Transparenz 2026-10-30: das HH-Depot hat keinen Kurs (Kaufwert) -> die Note sagt es
  IF v->'hero'->'note' <> core.fn_ui_tpl('finance.app.overview.hero_note_bookval', jsonb_build_object(
       'assets', core.fn_ui_money(14550, 'EUR'), 'debts', core.fn_ui_money(2000, 'EUR'))) THEN
    RAISE EXCEPTION 'FAIL [1f2] Note Besitz 14550 · Schulden 2000 (Besitz - Schulden = Hero), got %', v->'hero'->'note'; END IF;
  -- Besitz (hier nur schnell verfuegbar): Enum-Verweis je bucket, Anteile am Besitz aus der DB, kein Kredit; KEINE Summe,
  -- weil eine Anlageart eine Wechselkurs-Luecke hat (§3.12: Summe trotz gap waere unvollstaendig)
  v_sec := v->'sections'->0;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.overview.section_liquid') OR jsonb_typeof(v_sec->'value') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [1g] Abschnitt Schnell verfuegbar ohne Summe (gap), got %', v_sec; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i WHERE i->'label'->>'value' = 'loan') THEN
    RAISE EXCEPTION 'FAIL [1i] Kredit gehoert nicht in den Besitz'; END IF;
  SELECT (i->'value'->>'value')::numeric INTO v_n FROM jsonb_array_elements(v_sec->'items') i WHERE i->'label'->>'value' = 'depot';
  IF v_n IS DISTINCT FROM 500 THEN RAISE EXCEPTION 'FAIL [1j] Depot-Anlageart 500 (ohne Kinderdepot), got %', v_n; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v_sec->'items') i WHERE i->'label'->>'value' = 'depot';
  IF (v_it->'progress'->>'pct')::numeric IS DISTINCT FROM 3.4
     OR v_it->'sub' <> core.fn_ui_tpl('finance.app.overview.share', jsonb_build_object('pct', core.fn_ui_num(3.4, 1))) THEN
    RAISE EXCEPTION 'FAIL [1k] Depot-Anteil 500/14550 = 3.4 %% (Balken + Untertitel ohne Erklaer-Zusatz), got %', v_it; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->'label'->>'value' = 'cash' AND (i->>'gap')::boolean) THEN
    RAISE EXCEPTION 'FAIL [5b] gap an der Anlageart cash (CHF-Konto) fehlt'; END IF;
  -- Schulden: Kredit POSITIV, ohne Summe (steht schon in der Hero-Note), Sprung zum Bildschirm Kredite
  v_sec := v->'sections'->1;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.overview.section_debts') OR jsonb_typeof(v_sec->'value') <> 'null'
     OR v_sec->'items'->0->'value' <> core.fn_ui_money(2000, 'EUR')
     OR v_sec->'items'->0->'target' <> '{"screen":"loans","params":{}}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [1h] Schulden: Kredit 2000 positiv, keine Summe, Sprung nach loans, got %', v_sec; END IF;
  -- Kinder: je Kind Netto, Details je Anlageart ergeben die Summe; Titel ohne Fussnote
  v_sec := v->'sections'->2;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.overview.section_kids') OR jsonb_array_length(v_sec->'items') <> 1
     OR v_sec->'items'->0->>'label' <> 'Kind Beispiel' OR v_sec->'items'->0->'value' <> core.fn_ui_money(1300, 'EUR') THEN
    RAISE EXCEPTION 'FAIL [1q] Kinder-Abschnitt: Kind Beispiel 1300, got %', v_sec; END IF;
  SELECT sum((d->'value'->>'value')::numeric) INTO v_n FROM jsonb_array_elements(v_sec->'items'->0->'details') d;
  IF v_n IS DISTINCT FROM 1300 OR jsonb_array_length(v_sec->'items'->0->'details') <> 2 THEN
    RAISE EXCEPTION 'FAIL [1r] Kinder-Details (Konten 300 + Depot 1000) muessen die Summe ergeben, got %', v_sec->'items'->0->'details'; END IF;
  IF EXISTS (SELECT 1 FROM core.fn_app_view_lint(v)) THEN RAISE EXCEPTION 'FAIL [1z] fn_app_view_lint Owner: %', (SELECT string_agg(rule || '@' || path, ' ') FROM core.fn_app_view_lint(v)); END IF;
  RAISE NOTICE 'PASS [1+5] Owner sieht den Haushalt ohne Kind (Hero 12550 + gap, Schnell verfuegbar/Schulden/Kinder, keine Konten-Liste, Lint = 0)';

  -- Partner = Allow-List Haushalt -> identische Antwort
  IF finance.fn_app_screen_overview(jsonb_build_object('person_id', 'appo_partner')) <> v THEN
    RAISE EXCEPTION 'FAIL [1p] Partner muss dieselbe Haushalts-Sicht wie der Owner bekommen'; END IF;
  RAISE NOTICE 'PASS [1p] Partner = Haushalts-Sicht';

  -- ===== 2) Kind: nur Eigenes, Volltext-Leck-Suche =====
  v := finance.fn_app_screen_overview(jsonb_build_object('person_id', 'appo_kid', 'params', '{}'::jsonb));
  v_n := (v->'hero'->'value'->>'value')::numeric;
  IF v_n IS DISTINCT FROM 1300 OR (v->'hero'->>'gap')::boolean THEN
    RAISE EXCEPTION 'FAIL [2a] Kind-Hero erwartet 1300 ohne gap (Konto 300 + Depot 1000), got %', v->'hero'; END IF;
  v_txt := v::text;
  IF v_txt LIKE '%__appo_hh_%' OR v_txt LIKE '%__appo_p_%' OR v_txt LIKE '%__appo_g_%' OR v_txt LIKE '%onerror%' THEN
    RAISE EXCEPTION 'FAIL [2b] Kind-Antwort enthaelt fremde Namen: %', v_txt; END IF;
  IF v_txt ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [2c] Antwort traegt ein *id-Feld: %', v_txt; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->'label'->>'value' = 'loan') THEN
    RAISE EXCEPTION 'FAIL [2e] Haushalts-Kredit in der Kind-Sicht'; END IF;
  -- Kind: nur „Schnell verfuegbar" (Konto 300 + Depot 1000 = Hero 1300 -> keine Summe, sie waere = Hero)
  IF v->'hero'->'label' <> core.fn_ui_tpl('finance.app.overview.hero_own') OR jsonb_array_length(v->'sections') <> 1
     OR jsonb_typeof(v->'sections'->0->'value') <> 'null' OR v_txt LIKE '%finance.app.overview.section_kids%' THEN
    RAISE EXCEPTION 'FAIL [2f] Kind: „Mein Vermoegen", nur Schnell verfuegbar ohne Summe = Hero, kein Kinder-Abschnitt, got %', v; END IF;
  IF EXISTS (SELECT 1 FROM core.fn_app_view_lint(v)) THEN RAISE EXCEPTION 'FAIL [2g] Lint Kind-Sicht'; END IF;
  RAISE NOTICE 'PASS [2] Kind sieht nur Eigenes (1300), keine fremden Namen/IDs in der ganzen Antwort';

  -- ===== 3) Allow-List: unbekannte Rolle -> nur Eigenes; unbekannte Person -> nichts =====
  v := finance.fn_app_screen_overview(jsonb_build_object('person_id', 'appo_guest'));
  IF (v->'hero'->'value'->>'value')::numeric IS DISTINCT FROM 50 OR v::text LIKE '%__appo_hh_%' THEN
    RAISE EXCEPTION 'FAIL [3a] unbekannte Rolle muss nur Eigenes sehen (50), got %', v; END IF;
  v := finance.fn_app_screen_overview(jsonb_build_object('person_id', 'appo_nobody'));
  IF (v->>'ok')::boolean IS NOT TRUE OR (v->'hero'->'value'->>'value')::numeric IS DISTINCT FROM 0
     OR jsonb_array_length(v->'sections') <> 1 OR jsonb_array_length(v->'sections'->0->'items') <> 0 THEN
    RAISE EXCEPTION 'FAIL [3b] unbekannte Person muss einen leeren Bildschirm bekommen, got %', v; END IF;
  RAISE NOTICE 'PASS [3] Allow-List: unbekannte Rolle nur Eigenes, unbekannte Person nichts';

  -- ===== 4) probe + Eingabe-Fehler ohne RAISE =====
  IF finance.fn_app_screen_overview('{"person_id":"appo_kid","params":{"probe":true}}') <> '{"ok":true,"empty":false}'::jsonb
     OR finance.fn_app_screen_overview('{"person_id":"appo_nobody","params":{"probe":true}}') <> '{"ok":true,"empty":true}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [4a] probe muss nur {ok, empty} liefern'; END IF;
  IF finance.fn_app_screen_overview('{}') <> '{"ok":false,"code":"bad_request"}'::jsonb
     OR finance.fn_app_screen_overview('[1]') <> '{"ok":false,"code":"bad_request"}'::jsonb
     OR finance.fn_app_screen_overview(NULL) <> '{"ok":false,"code":"bad_request"}'::jsonb
     OR finance.fn_app_screen_overview('{"person_id":42}') <> '{"ok":false,"code":"bad_request"}'::jsonb
     OR finance.fn_app_screen_overview('{"person_id":"appo_kid","params":{"probe":"ja"}}')->>'ok' <> 'true' THEN
    RAISE EXCEPTION 'FAIL [4b] Muell-Eingaben muessen bad_request (bzw. kein probe) ohne RAISE liefern'; END IF;
  RAISE NOTICE 'PASS [4] probe {ok, empty}; Muell -> bad_request ohne RAISE';

  -- ===== 7) Liquiditaets-Leiter: Schnell verfuegbar (Konten/P2P/Depot) vs. Langfristig gebunden (Festgeld/Immobilie) =====
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__appo_hh_p2p__', 'p2p', 'EUR', 'active', NULL) RETURNING id INTO v_g_cash;
  UPDATE finance.account_balances SET balance = 1000 WHERE account_id = v_g_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id, fixed_deposit_maturity_date)
    VALUES ('__appo_hh_fd__', 'fixed_deposit', 'EUR', 'active', NULL, CURRENT_DATE + 365) RETURNING id INTO v_g_cash;
  UPDATE finance.account_balances SET balance = 5000 WHERE account_id = v_g_cash;
  INSERT INTO finance.real_estate (name, current_value) VALUES ('__appo_hh_re__', 100000);
  v := finance.fn_app_screen_overview(jsonb_build_object('person_id', 'appo_owner'));
  -- Besitz = 14550 + 1000 + 5000 + 100000 = 120550; gebunden 105000 aus 2 Zeilen -> Summe; schnell verfuegbar mit gap -> keine
  IF v->'sections'->0->'title' <> core.fn_ui_tpl('finance.app.overview.section_liquid')
     OR jsonb_typeof(v->'sections'->0->'value') <> 'null'
     OR v->'sections'->1->'title' <> core.fn_ui_tpl('finance.app.overview.section_bound')
     OR v->'sections'->1->'value' <> core.fn_ui_money(105000, 'EUR')
     OR v->'hero'->'note' <> core.fn_ui_tpl('finance.app.overview.hero_note_bookval', jsonb_build_object(
          'assets', core.fn_ui_money(120550, 'EUR'), 'debts', core.fn_ui_money(2000, 'EUR'))) THEN
    RAISE EXCEPTION 'FAIL [7a] Gebunden 105000 (2 Zeilen), Schnell verfuegbar ohne Summe (gap), Note Besitz 120550, got %', v; END IF;
  SELECT array_agg(i->'label'->>'value' ORDER BY o) INTO v_txt FROM jsonb_array_elements(v->'sections'->0->'items') WITH ORDINALITY AS t(i, o);
  IF v_txt IS DISTINCT FROM '{cash,p2p,depot}' THEN RAISE EXCEPTION 'FAIL [7b] Reihenfolge schnell verfuegbar cash/p2p/depot, got %', v_txt; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_path_query(v, 'strict $.sections[*].items[*].sub') s WHERE s->>'value' <> 'finance.app.overview.share') THEN
    RAISE EXCEPTION 'FAIL [7c] Untertitel nur „x %% des Besitzes", got %', v; END IF;
  IF EXISTS (SELECT 1 FROM core.fn_app_view_lint(v)) THEN RAISE EXCEPTION 'FAIL [7z] Lint mit Gebunden-Summe'; END IF;
  -- nur Gebundenes (eigene Immobilie, kein Konto): kein leeres „Schnell verfuegbar" darueber, keine Summe ueber einer Zeile
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('appo_solo', 'Solo Beispiel', 'grandparent');
  INSERT INTO finance.real_estate (name, current_value, owner_person_id) VALUES ('__appo_solo_re__', 50000, 'appo_solo');
  v := finance.fn_app_screen_overview(jsonb_build_object('person_id', 'appo_solo'));
  SELECT array_agg(s->'title'->>'value' ORDER BY o) INTO v_txt FROM jsonb_array_elements(v->'sections') WITH ORDINALITY AS t(s, o);
  IF v_txt IS DISTINCT FROM '{finance.app.overview.section_bound}' OR jsonb_typeof(v->'sections'->0->'value') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [7d] nur Gebundenes -> ein Abschnitt ohne Summe, got %', v; END IF;
  RAISE NOTICE 'PASS [7] Schnell verfuegbar vs. Langfristig gebunden, Summen nur ab 2 Zeilen ohne gap, Untertitel ohne Zusatz';

  -- Transparenz 2026-10-30: mit Kurs fuer das HH-Depot verschwindet der Kaufwert-Hinweis; ohne Schulden steht er allein
  INSERT INTO finance.market_prices (symbol, isin, price, currency, as_of) VALUES ('APOHH', 'APO00000001', 120, 'EUR', CURRENT_DATE);
  v := finance.fn_app_screen_overview(jsonb_build_object('person_id', 'appo_owner'));
  IF v->'hero'->'note'->>'value' <> 'finance.app.overview.hero_note' THEN
    RAISE EXCEPTION 'FAIL [7e] mit Kurs kein Kaufwert-Hinweis, got %', v->'hero'->'note'; END IF;
  v := finance.fn_app_screen_overview(jsonb_build_object('person_id', 'appo_solo'));
  IF v->'hero'->'note' IS NOT NULL AND jsonb_typeof(v->'hero'->'note') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [7f] ohne Schulden und ohne Depot keine Note, got %', v->'hero'->'note'; END IF;
  RAISE NOTICE 'PASS [7e] Kaufwert-Hinweis nur ohne Kurs';
END $$;

-- ===== 6) Frei-SQL-Rollen: kein EXECUTE; selbst MIT Test-Grant -> forbidden =====
DO $$
BEGIN
  IF has_function_privilege('finance_ro', 'finance.fn_app_screen_overview(jsonb)', 'EXECUTE')
     OR has_function_privilege('core_ro', 'finance.fn_app_screen_overview(jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [6a] Frei-SQL-Rolle hat EXECUTE auf den Bildschirm-Handler';
  END IF;
  GRANT EXECUTE ON FUNCTION finance.fn_app_screen_overview(jsonb) TO finance_ro;
END $$;
SET LOCAL SESSION AUTHORIZATION finance_ro;
DO $$
DECLARE v jsonb;
BEGIN
  v := finance.fn_app_screen_overview('{"person_id":"appo_owner","params":{}}');
  IF v <> '{"ok":false,"code":"forbidden"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [6b] Frei-SQL-Sitzung muss forbidden bekommen, got %', v; END IF;
  RAISE NOTICE 'PASS [6] kein EXECUTE fuer *_ro; Frei-SQL-Sitzung bekaeme trotzdem nur forbidden';
END $$;
RESET SESSION AUTHORIZATION;
ROLLBACK;

-- ===== 8) Fixture-Haushalt (tests/util/util_app_household.sql): fn_app_view_lint = 0 fuer alle fuenf Personen =====
BEGIN;
\ir ../../util/util_app_household.sql
DO $$
DECLARE v_pid text; v jsonb; v_lint text;
BEGIN
  FOREACH v_pid IN ARRAY ARRAY['fxh_jonas', 'fxh_mira', 'fxh_lea', 'fxh_tom', 'fxh_gast'] LOOP
    v := finance.fn_app_screen_overview(jsonb_build_object('person_id', v_pid, 'params', '{}'::jsonb));
    SELECT string_agg(l.rule || '@' || l.path, ' ') INTO v_lint FROM core.fn_app_view_lint(v) l;
    IF v_lint IS NOT NULL THEN RAISE EXCEPTION 'FAIL [8] Lint % : %', v_pid, v_lint; END IF;
  END LOOP;
  -- Haushalt: Vermoegen der Kinder mit Lea + Tom, Schulden positiv
  v := finance.fn_app_screen_overview('{"person_id":"fxh_jonas","params":{}}');
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections') s WHERE s->'title' = core.fn_ui_tpl('finance.app.overview.section_kids')
                   AND jsonb_array_length(s->'items') = 2)
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections') s CROSS JOIN LATERAL jsonb_array_elements(s->'items') i
                 WHERE s->'title' = core.fn_ui_tpl('finance.app.overview.section_debts') AND (i->'value'->>'value')::numeric < 0) THEN
    RAISE EXCEPTION 'FAIL [8b] Fixture: Kinder-Abschnitt (2) + Schulden positiv, got %', v; END IF;
  RAISE NOTICE 'PASS [8] Fixture-Haushalt: Lint = 0 fuer alle Personen';
END $$;
ROLLBACK;
