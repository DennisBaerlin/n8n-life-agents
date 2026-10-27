-- tests/db/finance/test_fn_app_screen_overview.sql
-- finance.fn_app_screen_overview(p jsonb) — Mini-App-Bildschirm „Vermögen" (docs/package-contract.md §3.12, View-Modell v1).
--   1) Owner + Partner (Allow-List) sehen den ganzen Haushalt: Hero = Summe aller Anlagearten inkl. Kind und Kredit,
--      Konten-Liste ohne Kredit- und Depot-Konten, Rohname (auch <img …>) unveraendert als String.
--   2) Kind sieht NUR eigene Zeilen (owner_person_id = ich): Volltextsuche ueber die GANZE Antwort findet keinen Namen
--      eines Haushalts-/Eltern-/Fremdkontos und ueberhaupt kein *id-Feld.
--   3) Unbekannte Rolle (Allow-List, nicht Deny-List) und unbekannte Person sehen nur Eigenes bzw. nichts.
--   4) params.probe -> nur {ok, empty}; fehlende person_id / Muell -> {ok:false, code:'bad_request'} ohne RAISE.
--   5) Waehrung ohne Kurs -> gap im Hero, in der Anlageart und am Konto.
--   6) Frei-SQL-Sitzung (finance_ro, selbst MIT EXECUTE) -> {ok:false, code:'forbidden'}; ohne Test-Grant kein EXECUTE.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_hh_cash INT; v_p_cash INT; v_kid_cash INT; v_kid_depot INT; v_hh_depot INT; v_loan INT; v_g_cash INT; v_chf INT;
  v jsonb; v_txt text; v_n numeric; v_sec jsonb;
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
  IF jsonb_array_length(v->'banners') <> 0 OR jsonb_array_length(v->'sections') <> 2 THEN
    RAISE EXCEPTION 'FAIL [1d] erwartet 0 Banner + 2 Abschnitte, got %', v; END IF;
  -- Hero: 10000 + 4000 + 500 (HH-Depot) - 2000 (Kredit) + 300 + 1000 (Kind) + 50 (Gast); CHF ohne Kurs faellt aus -> gap
  v_n := (v->'hero'->'value'->>'value')::numeric;
  IF v_n IS DISTINCT FROM 13850 OR v->'hero'->'value'->>'kind' <> 'money' OR v->'hero'->'value'->>'currency' <> 'EUR' THEN
    RAISE EXCEPTION 'FAIL [1e] Hero erwartet 13850 EUR, got %', v->'hero'; END IF;
  IF (v->'hero'->>'gap')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [5a] Hero-gap (CHF ohne Kurs) fehlt'; END IF;
  IF v->'hero'->'label' <> core.fn_ui_tpl('finance.app.overview.hero') THEN RAISE EXCEPTION 'FAIL [1f] hero.label'; END IF;
  -- Anlagearten: Enum-Verweis je bucket, Kredit negativ ohne Balken, Anteile aus der DB
  v_sec := v->'sections'->0;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.overview.section_classes') THEN RAISE EXCEPTION 'FAIL [1g] Abschnitt 1 %', v_sec->'title'; END IF;
  SELECT (i->'value'->>'value')::numeric INTO v_n FROM jsonb_array_elements(v_sec->'items') i
   WHERE i->'label' = '{"kind":"enum","enum":"finance.enum.asset_bucket","value":"loan"}'::jsonb;
  IF v_n IS DISTINCT FROM -2000 THEN RAISE EXCEPTION 'FAIL [1h] Kredit-Anlageart -2000 erwartet, got %', v_n; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
              WHERE i->'label'->>'value' = 'loan' AND jsonb_typeof(i->'progress') <> 'null') THEN
    RAISE EXCEPTION 'FAIL [1i] Kredit darf keinen Anteils-Balken tragen'; END IF;
  SELECT (i->'value'->>'value')::numeric INTO v_n FROM jsonb_array_elements(v_sec->'items') i WHERE i->'label'->>'value' = 'depot';
  IF v_n IS DISTINCT FROM 1500 THEN RAISE EXCEPTION 'FAIL [1j] Depot-Anlageart 1500 (HH 500 + Kind 1000), got %', v_n; END IF;
  SELECT (i->'progress'->>'pct')::numeric INTO v_n FROM jsonb_array_elements(v_sec->'items') i WHERE i->'label'->>'value' = 'depot';
  IF v_n IS DISTINCT FROM 9.5 THEN RAISE EXCEPTION 'FAIL [1k] Depot-Anteil 1500/15850 = 9.5 %% erwartet, got %', v_n; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->'label'->>'value' = 'cash' AND (i->>'gap')::boolean) THEN
    RAISE EXCEPTION 'FAIL [5b] gap an der Anlageart cash (CHF-Konto) fehlt'; END IF;
  -- Konten: ohne Kredit/Depot, Rohname als String, Saldo nativ, Bestaetigungs-Datum typisiert
  v_sec := v->'sections'->1;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.overview.section_accounts') THEN RAISE EXCEPTION 'FAIL [1l] Abschnitt 2'; END IF;
  v_txt := v_sec::text;
  IF v_txt LIKE '%__appo_hh_loan__%' OR v_txt LIKE '%__appo_hh_depot__%' OR v_txt LIKE '%__appo_kid_depot__%' THEN
    RAISE EXCEPTION 'FAIL [1m] Kredit-/Depot-Konto in der Konten-Liste: %', v_txt; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i WHERE i->'label' = to_jsonb('<img src=x onerror=alert(1)>'::text)) THEN
    RAISE EXCEPTION 'FAIL [1n] Rohname muss unveraendert als String kommen (XSS-Fixture)'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__appo_hh_cash__'
                    AND i->'value' = core.fn_ui_money(10000, 'EUR')
                    AND i->'sub' = core.fn_ui_tpl('finance.app.overview.confirmed_on',
                                                  jsonb_build_object('date', core.fn_ui_date(DATE '2026-10-01')))) THEN
    RAISE EXCEPTION 'FAIL [1o] Haushaltskonto mit Saldo + Bestaetigungs-Datum fehlt: %', v_sec; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__appo_hh_chf__' AND (i->>'gap')::boolean
                    AND i->'value' = core.fn_ui_money(700, 'CHF')) THEN
    RAISE EXCEPTION 'FAIL [5c] CHF-Konto: nativer Betrag + gap erwartet'; END IF;
  RAISE NOTICE 'PASS [1+5] Owner sieht den Haushalt (Hero 13850 + gap, Anlagearten, Konten ohne Kredit/Depot, Rohname)';

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
  IF v_txt NOT LIKE '%__appo_kid_cash__%' THEN RAISE EXCEPTION 'FAIL [2d] eigenes Konto fehlt: %', v_txt; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->'label'->>'value' = 'loan') THEN
    RAISE EXCEPTION 'FAIL [2e] Haushalts-Kredit in der Kind-Sicht'; END IF;
  RAISE NOTICE 'PASS [2] Kind sieht nur Eigenes (1300), keine fremden Namen/IDs in der ganzen Antwort';

  -- ===== 3) Allow-List: unbekannte Rolle -> nur Eigenes; unbekannte Person -> nichts =====
  v := finance.fn_app_screen_overview(jsonb_build_object('person_id', 'appo_guest'));
  IF (v->'hero'->'value'->>'value')::numeric IS DISTINCT FROM 50 OR v::text LIKE '%__appo_hh_%' THEN
    RAISE EXCEPTION 'FAIL [3a] unbekannte Rolle muss nur Eigenes sehen (50), got %', v; END IF;
  v := finance.fn_app_screen_overview(jsonb_build_object('person_id', 'appo_nobody'));
  IF (v->>'ok')::boolean IS NOT TRUE OR (v->'hero'->'value'->>'value')::numeric IS DISTINCT FROM 0
     OR jsonb_array_length(v->'sections'->0->'items') <> 0 OR jsonb_array_length(v->'sections'->1->'items') <> 0 THEN
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
