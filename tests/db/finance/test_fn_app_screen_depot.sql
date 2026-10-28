-- tests/db/finance/test_fn_app_screen_depot.sql
-- finance.fn_app_screen_depot(p jsonb) — Mini-App-Bildschirm „Depot" (docs/package-contract.md §3.12, View-Modell v1).
--   1) Owner/Partner sehen alle aktiven Depots: Hero = Summe market_value_eur, gap bei Position ohne Kurs oder ohne
--      Wechselkurs (fehlender Kurs nie still 0); ein Abschnitt je Depot (Wert absteigend, NULLS LAST), Positionen nach
--      Wert absteigend; Pill Kurs veraltet/fehlt; geschlossenes Depot fehlt.
--   2) „Fuer Ziele reserviert": gedeckt / nicht gedeckt / nicht ermittelbar (Teil-Summe ohne Kurs, Ziel-Anteil ohne
--      Wechselkurs) — unbekannt ist nie gruen.
--   3) Kind sieht nur eigene Depots (owner_person_id = ich): Volltextsuche ohne fremde Namen und ohne *id-Feld.
--   4) unbekannte Rolle nur Eigenes, unbekannte Person nichts; probe -> {ok, empty, banners} (Kurs-Banner je Depot).
--   5) Muell -> bad_request; Frei-SQL-Sitzung -> forbidden, kein EXECUTE fuer *_ro.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_giro INT; v_hh INT; v_crypto INT; v_p INT; v_kid_cash INT; v_kid INT; v_g INT; v_closed INT;
  g_hh INT; g_p INT; g_kid INT; g_g INT;
  v jsonb; v_sec jsonb; v_txt text; v_labels text[];
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  DELETE FROM core.config WHERE package = 'core' AND category = 'advisor' AND key = 'price_stale_days';

  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('apdp_owner',   'Owner Beispiel',   'owner'),
    ('apdp_partner', 'Partner Beispiel', 'partner'),
    ('apdp_kid',     'Kind Beispiel',    'child'),
    ('apdp_guest',   'Gast Beispiel',    'grandparent');

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__apdp_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__apdp_hh_depot__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_hh;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__apdp_hh_crypto__', 'crypto_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_crypto;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('__apdp_p_depot__', 'stocks_depot', 'EUR', 'active', v_giro, 'apdp_partner') RETURNING id INTO v_p;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('Alpha Konto', 'cash', 'EUR', 'active', 'apdp_kid') RETURNING id INTO v_kid_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('Alpha Depot', 'stocks_depot', 'EUR', 'active', v_kid_cash, 'apdp_kid') RETURNING id INTO v_kid;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('__apdp_g_depot__', 'stocks_depot', 'EUR', 'active', v_giro, 'apdp_guest') RETURNING id INTO v_g;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__apdp_closed__', 'stocks_depot', 'EUR', 'closed', v_giro) RETURNING id INTO v_closed;

  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency) VALUES
    (v_hh,     'APD00000001', 'APDP1', '__apdp_etf_ok__',      10, 100, 'EUR'),
    (v_hh,     'APD00000002', 'APDP2', '__apdp_etf_stale__',    5,  50, 'EUR'),
    (v_hh,     'APD00000003', 'APDP3', '__apdp_etf_missing__',  2,  80, 'EUR'),
    (v_p,      'APD00000004', 'APDPP', '__apdp_p_etf__',        1, 900, 'EUR'),
    (v_kid,    'APD00000005', 'APDPK', 'Alpha ETF',              3,  90, 'EUR'),
    (v_g,      'APD00000006', 'APDPG', '__apdp_g_etf__',        1,  40, 'EUR'),
    (v_closed, 'APD00000007', 'APDPC', '__apdp_closed_etf__',   1,  10, 'EUR');
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_crypto, NULL, 'APDPBTC', '__apdp_coin__', 0.5, 30000, 'CHF');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES
    ('APDP1', 120, 'EUR', current_date), ('APDP2', 60, 'EUR', current_date - 30),
    ('APDPP', 1000, 'EUR', current_date), ('APDPK', 100, 'EUR', current_date),
    ('APDPG', 50, 'EUR', current_date), ('APDPC', 10, 'EUR', current_date),
    ('APDPBTC', 40000, 'CHF', current_date);

  -- Reservierungen: HH-Depot (Teil-Summe ohne Kurs -> unbekannt), Partner (CHF-Anteil ohne Kurs -> unbekannt),
  -- Kind (300 >= 200 -> gedeckt), Gast (100 > 50 -> nicht gedeckt)
  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__apdp_goal_hh__', 5000, current_date + 300) RETURNING id INTO g_hh;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, beneficiary_person_id) VALUES ('__apdp_goal_p__', 5000, current_date + 300, 'apdp_partner') RETURNING id INTO g_p;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, beneficiary_person_id) VALUES ('__apdp_goal_kid__', 500, current_date + 300, 'apdp_kid') RETURNING id INTO g_kid;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, beneficiary_person_id) VALUES ('__apdp_goal_g__', 500, current_date + 300, 'apdp_guest') RETURNING id INTO g_g;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, kind) VALUES
    (g_hh, v_hh, 1000, 'EUR', 'manual'),
    (g_p, v_p, 100, 'EUR', 'manual'), (g_p, v_p, 100, 'CHF', 'manual'),
    (g_kid, v_kid, 200, 'EUR', 'manual'),
    (g_g, v_g, 100, 'EUR', 'manual');

  -- ===== 1) Owner =====
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner', 'params', '{}'::jsonb));
  IF (v->>'ok')::boolean IS NOT TRUE OR NOT (v ? 'title' AND v ? 'hero' AND v ? 'banners' AND v ? 'sections') THEN
    RAISE EXCEPTION 'FAIL [1a] View-Modell v1 erwartet, got %', v; END IF;
  IF v->'title' <> core.fn_ui_tpl('finance.app.depot.title') OR v->'hero'->'label' <> core.fn_ui_tpl('finance.app.depot.hero') THEN
    RAISE EXCEPTION 'FAIL [1b] title/hero.label'; END IF;
  -- Hero: 1200 + 300 (veraltet zaehlt) + 1000 (Partner) + 300 (Kind) + 50 (Gast); ohne Kurs / ohne CHF-Kurs -> gap
  IF v->'hero'->'value' <> core.fn_ui_money(2850, 'EUR') OR (v->'hero'->>'gap')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [1c] Hero 2850 EUR + gap, got %', v->'hero'; END IF;
  IF jsonb_array_length(v->'banners') <> 0 THEN RAISE EXCEPTION 'FAIL [1d] Banner nur in probe'; END IF;
  IF v::text LIKE '%__apdp_closed%' THEN RAISE EXCEPTION 'FAIL [1e] geschlossenes Depot sichtbar'; END IF;

  SELECT array_agg(s->'title'->'params'->>'name' ORDER BY o) INTO v_labels
    FROM jsonb_array_elements(v->'sections') WITH ORDINALITY AS t(s, o)
   WHERE s->'title'->>'value' = 'finance.app.depot.section';
  IF v_labels IS DISTINCT FROM ARRAY['__apdp_hh_depot__', '__apdp_p_depot__', 'Alpha Depot', '__apdp_g_depot__', '__apdp_hh_crypto__'] THEN
    RAISE EXCEPTION 'FAIL [1f] Depots nach Wert absteigend, ohne Wert zuletzt, got %', v_labels; END IF;
  v_sec := v->'sections'->0;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.depot.section', jsonb_build_object('name', '__apdp_hh_depot__')) THEN
    RAISE EXCEPTION 'FAIL [1g] Abschnitts-Titel als Template mit Rohname, got %', v_sec->'title'; END IF;
  SELECT array_agg(i->>'label' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v_sec->'items') WITH ORDINALITY AS t(i, o);
  IF v_labels IS DISTINCT FROM ARRAY['__apdp_etf_ok__', '__apdp_etf_stale__', '__apdp_etf_missing__'] THEN
    RAISE EXCEPTION 'FAIL [1h] Positionen nach Wert, got %', v_labels; END IF;
  IF v_sec->'items'->0 <> jsonb_build_object('label', '__apdp_etf_ok__',
        'sub', core.fn_ui_tpl('finance.app.depot.shares_price', jsonb_build_object('shares', core.fn_ui_num(10, 0), 'date', core.fn_ui_date(current_date))),
        'value', core.fn_ui_money(1200, 'EUR'), 'gap', false, 'pill', NULL, 'progress', NULL, 'target', NULL) THEN
    RAISE EXCEPTION 'FAIL [1i] Position mit aktuellem Kurs, got %', v_sec->'items'->0; END IF;
  IF v_sec->'items'->1->'pill' <> jsonb_build_object('state', 'warn', 'icon', 'clock', 'text', core.fn_ui_tpl('finance.app.depot.price_stale'))
     OR (v_sec->'items'->1->>'gap')::boolean THEN
    RAISE EXCEPTION 'FAIL [1j] veralteter Kurs: warn clock, kein gap, got %', v_sec->'items'->1; END IF;
  IF v_sec->'items'->2 <> jsonb_build_object('label', '__apdp_etf_missing__',
        'sub', core.fn_ui_tpl('finance.app.depot.shares', jsonb_build_object('shares', core.fn_ui_num(2, 0))),
        'value', NULL, 'gap', true,
        'pill', jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl('finance.app.depot.price_missing')),
        'progress', NULL, 'target', NULL) THEN
    RAISE EXCEPTION 'FAIL [1k] Position ohne Kurs: kein Wert, gap, Pill, got %', v_sec->'items'->2; END IF;
  SELECT s INTO v_sec FROM jsonb_array_elements(v->'sections') s
   WHERE s->'title' = core.fn_ui_tpl('finance.app.depot.section', jsonb_build_object('name', '__apdp_hh_crypto__'));
  IF v_sec->'items'->0->'value' <> core.fn_ui_money(20000, 'CHF') OR (v_sec->'items'->0->>'gap')::boolean IS NOT TRUE
     OR jsonb_typeof(v_sec->'items'->0->'pill') <> 'null'
     OR v_sec->'items'->0->'sub'->'params'->'shares' <> core.fn_ui_num(0.5, 1) THEN
    RAISE EXCEPTION 'FAIL [1l] Kurs ohne Wechselkurs: nativer Wert + gap, Bruchteil-Stueck, got %', v_sec; END IF;
  RAISE NOTICE 'PASS [1] Owner: Hero 2850 + gap, Depots/Positionen sortiert, Kurs-Pills, Bruchteile';

  -- ===== 2) Fuer Ziele reserviert =====
  v_sec := v->'sections'->-1;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.depot.section_reserved') THEN RAISE EXCEPTION 'FAIL [2a] Reserve-Abschnitt zuletzt, got %', v_sec->'title'; END IF;
  SELECT array_agg(i->>'label' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v_sec->'items') WITH ORDINALITY AS t(i, o);
  IF v_labels IS DISTINCT FROM ARRAY['Alpha Depot', '__apdp_g_depot__', '__apdp_hh_depot__', '__apdp_p_depot__'] THEN
    RAISE EXCEPTION 'FAIL [2b] reservierte Depots nach Name, got %', v_labels; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = 'Alpha Depot'
                   AND i->'value' = core.fn_ui_money(200, 'EUR') AND (i->>'gap')::boolean IS FALSE
                   AND i->'pill' = jsonb_build_object('state', 'ok', 'icon', 'check', 'text', core.fn_ui_tpl('finance.app.depot.reserve_covered')))
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apdp_g_depot__'
                   AND i->'pill' = jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl('finance.app.depot.reserve_short'))) THEN
    RAISE EXCEPTION 'FAIL [2c] gedeckt / nicht gedeckt, got %', v_sec; END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v_sec->'items') i
       WHERE i->>'label' IN ('__apdp_hh_depot__', '__apdp_p_depot__') AND (i->>'gap')::boolean
         AND i->'pill' = jsonb_build_object('state', 'neutral', 'icon', 'info', 'text', core.fn_ui_tpl('finance.app.depot.reserve_unknown'))) <> 2 THEN
    RAISE EXCEPTION 'FAIL [2d] Teil-Summe ohne Kurs bzw. Anteil ohne Wechselkurs -> nicht ermittelbar, nie gruen, got %', v_sec; END IF;
  RAISE NOTICE 'PASS [2] Reserve: gedeckt / nicht gedeckt / nicht ermittelbar';

  IF finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_partner')) <> v THEN
    RAISE EXCEPTION 'FAIL [2e] Partner = Haushalts-Sicht'; END IF;

  -- ===== 3) Kind =====
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_kid', 'params', '{}'::jsonb));
  IF v->'hero'->'value' <> core.fn_ui_money(300, 'EUR') OR (v->'hero'->>'gap')::boolean THEN
    RAISE EXCEPTION 'FAIL [3a] Kind-Hero 300 ohne gap, got %', v->'hero'; END IF;
  v_txt := v::text;
  IF v_txt LIKE '%__apdp_%' THEN RAISE EXCEPTION 'FAIL [3b] Kind-Antwort enthaelt fremde Namen: %', v_txt; END IF;
  IF v_txt ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [3c] *id-Feld: %', v_txt; END IF;
  IF jsonb_array_length(v->'sections') <> 2 OR v_txt NOT LIKE '%Alpha ETF%' THEN
    RAISE EXCEPTION 'FAIL [3d] Kind: eigenes Depot + Reserve-Abschnitt, got %', v->'sections'; END IF;
  RAISE NOTICE 'PASS [3] Kind sieht nur das eigene Depot, keine IDs';

  -- ===== 4) Allow-List + probe =====
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_guest'));
  IF v->'hero'->'value' <> core.fn_ui_money(50, 'EUR') OR v::text LIKE '%__apdp_hh_%' THEN
    RAISE EXCEPTION 'FAIL [4a] unbekannte Rolle nur Eigenes (50), got %', v; END IF;
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_nobody'));
  IF (v->>'ok')::boolean IS NOT TRUE OR v->'hero'->'value' <> core.fn_ui_money(0, 'EUR') OR (v->'hero'->>'gap')::boolean
     OR jsonb_array_length(v->'sections') <> 0 THEN
    RAISE EXCEPTION 'FAIL [4b] unbekannte Person: leerer Bildschirm, got %', v; END IF;
  v := finance.fn_app_screen_depot('{"person_id":"apdp_owner","params":{"probe":true}}');
  IF v <> jsonb_build_object('ok', true, 'empty', false, 'banners', jsonb_build_array(jsonb_build_object(
            'state', 'warn', 'icon', 'clock',
            'text', core.fn_ui_tpl('finance.app.depot.banner_price', jsonb_build_object('depot', '__apdp_hh_depot__')),
            'target', jsonb_build_object('screen', 'depot', 'params', '{}'::jsonb)))) THEN
    RAISE EXCEPTION 'FAIL [4c] probe Owner: ein Kurs-Banner fuer das HH-Depot, got %', v; END IF;
  IF finance.fn_app_screen_depot('{"person_id":"apdp_kid","params":{"probe":true}}') <> '{"ok":true,"empty":false,"banners":[]}'::jsonb
     OR finance.fn_app_screen_depot('{"person_id":"apdp_nobody","params":{"probe":true}}') <> '{"ok":true,"empty":true,"banners":[]}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [4d] probe Kind/unbekannt'; END IF;
  RAISE NOTICE 'PASS [4] Allow-List + probe {ok, empty, banners}';

  -- ===== 5) Muell =====
  IF finance.fn_app_screen_depot('{}') <> '{"ok":false,"code":"bad_request"}'::jsonb
     OR finance.fn_app_screen_depot('[1]') <> '{"ok":false,"code":"bad_request"}'::jsonb
     OR finance.fn_app_screen_depot(NULL) <> '{"ok":false,"code":"bad_request"}'::jsonb
     OR finance.fn_app_screen_depot('{"person_id":42}') <> '{"ok":false,"code":"bad_request"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [5a] Muell -> bad_request'; END IF;
  RAISE NOTICE 'PASS [5a] Muell -> bad_request ohne RAISE';
END $$;

DO $$
BEGIN
  IF has_function_privilege('finance_ro', 'finance.fn_app_screen_depot(jsonb)', 'EXECUTE')
     OR has_function_privilege('core_ro', 'finance.fn_app_screen_depot(jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [5b] Frei-SQL-Rolle hat EXECUTE auf den Bildschirm-Handler';
  END IF;
  GRANT EXECUTE ON FUNCTION finance.fn_app_screen_depot(jsonb) TO finance_ro;
END $$;
SET LOCAL SESSION AUTHORIZATION finance_ro;
DO $$
BEGIN
  IF finance.fn_app_screen_depot('{"person_id":"apdp_owner","params":{}}') <> '{"ok":false,"code":"forbidden"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [5c] Frei-SQL-Sitzung muss forbidden bekommen'; END IF;
  RAISE NOTICE 'PASS [5] kein EXECUTE fuer *_ro; Frei-SQL-Sitzung -> forbidden';
END $$;
RESET SESSION AUTHORIZATION;
ROLLBACK;
