-- tests/db/finance/test_fn_app_screen_depot.sql
-- finance.fn_app_screen_depot(p jsonb) — Mini-App-Bildschirm „Depot" (docs/package-contract.md §3.12, View-Modell v1).
--   1) Owner/Partner sehen alle aktiven Depots. Hero = Anlageart depot aus networth_by_asset_class ohne Kinder (= dieselbe
--      Zahl wie „Wertpapiere & Krypto" auf der Vermoegen-Seite; ohne Kurs zaehlt der Kaufwert) + gap (Position ohne Kurs
--      oder ohne Wechselkurs); Note Gewinn seit Kauf (nur aktuelle Kurse mit Kaufwert) + Kurs-Datum. Ein Abschnitt je
--      Depot mit Summe (Haushalt nach Wert, ohne Wert zuletzt, Kinder-Depot hinten „nicht im Depotwert"), Positionen
--      nach Wert, Wert in EUR (nur ohne Wechselkurs nativ + gap), Untertitel mit Fremdwaehrungs-Kurs / abweichendem
--      Kurs-Datum, Pille Kurs veraltet/fehlt vor Gewinn (ok/up, alert/down); geschlossenes Depot fehlt.
--   2) Aufklappen: Ø Kaufkurs, Kaufwert, Gewinn (nur mit aktuellem Kurs); die Buchungs-Zeilen danach testet
--      test_fn_app_holding_transactions.sql.
--   3) Kind sieht nur eigene Depots, Hero = eigene Summe, ohne Kinder-Zusatz: Volltextsuche ohne fremde Namen, ohne *id.
--   4) unbekannte Rolle nur Eigenes, unbekannte Person nichts; probe -> {ok, empty, banners} (Kurs-Banner je Depot).
--   5) Muell -> bad_request; Frei-SQL-Sitzung -> forbidden, kein EXECUTE fuer *_ro.
--   („Fuer Ziele reserviert" steht seit Uebersicht R3 auf dem Bildschirm Ziele: test_fn_app_screen_goals.sql.)
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_giro INT; v_hh INT; v_crypto INT; v_p INT; v_kid_cash INT; v_kid INT; v_g INT; v_closed INT;
  v jsonb; v_sec jsonb; v_it jsonb; v_txt text; v_labels text[]; v_n numeric;
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
    (v_g,      'APD00000006', 'APDPG', '__apdp_g_etf__',        1,  60, 'EUR'),
    (v_closed, 'APD00000007', 'APDPC', '__apdp_closed_etf__',   1,  10, 'EUR');
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_crypto, NULL, 'APDPBTC', '__apdp_coin__', 0.5, 30000, 'CHF');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES
    ('APDP1', 120, 'EUR', current_date), ('APDP2', 60, 'EUR', current_date - 30),
    ('APDPP', 1000, 'EUR', current_date), ('APDPK', 100, 'EUR', current_date),
    ('APDPG', 50, 'EUR', current_date), ('APDPC', 10, 'EUR', current_date),
    ('APDPBTC', 40000, 'CHF', current_date);

  -- ===== 1) Owner =====
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner', 'params', '{}'::jsonb));
  IF (v->>'ok')::boolean IS NOT TRUE OR NOT (v ? 'title' AND v ? 'hero' AND v ? 'banners' AND v ? 'sections') THEN
    RAISE EXCEPTION 'FAIL [1a] View-Modell v1 erwartet, got %', v; END IF;
  IF v->'title' <> core.fn_ui_tpl('finance.app.depot.title') OR v->'hero'->'label' <> core.fn_ui_tpl('finance.app.depot.hero') THEN
    RAISE EXCEPTION 'FAIL [1b] title/hero.label'; END IF;
  -- Hero: 1200 + 300 (veraltet zaehlt) + 160 (ohne Kurs: Kaufwert) + 1000 (Partner) + 50 (Gast); CHF ohne Kurs faellt
  -- aus; Kind (300) und geschlossenes Depot NICHT -> 2710 + gap
  IF v->'hero'->'value' <> core.fn_ui_money(2710, 'EUR') OR (v->'hero'->>'gap')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [1c] Hero 2710 EUR + gap, got %', v->'hero'; END IF;
  SELECT round(sum(n.value_eur), 2) INTO v_n
    FROM finance.networth_by_asset_class n
    LEFT JOIN core.fn_household_persons() hp ON hp.person_id = n.owner_person_id
   WHERE n.bucket = 'depot' AND hp.role IS DISTINCT FROM 'child';
  IF (v->'hero'->'value'->>'value')::numeric IS DISTINCT FROM v_n THEN
    RAISE EXCEPTION 'FAIL [1c2] Depot-Hero muss = Vermoegen „Wertpapiere & Krypto" sein (%), got %', v_n, v->'hero'; END IF;
  -- Note: Gewinn nur aktuelle Kurse mit Kaufwert: 200 (ok) + 100 (Partner) - 10 (Gast) = 290 auf 1960 -> +14.8 %
  IF v->'hero'->'note' <> core.fn_ui_tpl('finance.app.depot.hero_note', jsonb_build_object(
       'gain', core.fn_ui_money(290, 'EUR', true), 'pct', core.fn_ui_num(14.8, 1, true), 'date', core.fn_ui_date(current_date))) THEN
    RAISE EXCEPTION 'FAIL [1c3] Hero-Note Gewinn +290 (+14.8 %%) + Kurs-Datum, got %', v->'hero'->'note'; END IF;
  IF jsonb_array_length(v->'banners') <> 0 THEN RAISE EXCEPTION 'FAIL [1d] Banner nur in probe'; END IF;
  IF v::text LIKE '%__apdp_closed%' THEN RAISE EXCEPTION 'FAIL [1e] geschlossenes Depot sichtbar'; END IF;
  IF v::text LIKE '%section_reserved%' THEN RAISE EXCEPTION 'FAIL [1e2] Reserve-Abschnitt gehoert auf den Bildschirm Ziele'; END IF;

  SELECT array_agg((s->'title'->>'value') || ':' || (s->'title'->'params'->>'name') ORDER BY o) INTO v_labels
    FROM jsonb_array_elements(v->'sections') WITH ORDINALITY AS t(s, o);
  IF v_labels IS DISTINCT FROM ARRAY['finance.app.depot.section:__apdp_hh_depot__', 'finance.app.depot.section:__apdp_p_depot__',
                                     'finance.app.depot.section:__apdp_g_depot__', 'finance.app.depot.section:__apdp_hh_crypto__',
                                     'finance.app.depot.section_child:Alpha Depot'] THEN
    RAISE EXCEPTION 'FAIL [1f] Haushalt nach Wert (ohne Wert zuletzt), Kinder-Depot hinten, got %', v_labels; END IF;
  v_sec := v->'sections'->0;
  IF jsonb_typeof(v_sec->'value') <> 'null' OR v->'sections'->1->'value' <> core.fn_ui_money(1000, 'EUR') THEN
    RAISE EXCEPTION 'FAIL [1g] Depot-Summe: entfaellt bei Position ohne Kurs (statt still zu niedrig), sonst 1000, got %', v->'sections'; END IF;
  SELECT array_agg(i->>'label' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v_sec->'items') WITH ORDINALITY AS t(i, o);
  IF v_labels IS DISTINCT FROM ARRAY['__apdp_etf_ok__', '__apdp_etf_stale__', '__apdp_etf_missing__'] THEN
    RAISE EXCEPTION 'FAIL [1h] Positionen nach Wert, got %', v_labels; END IF;
  v_it := v_sec->'items'->0;
  IF v_it->'value' <> core.fn_ui_money(1200, 'EUR') OR (v_it->>'gap')::boolean
     OR v_it->'sub'->>'value' <> 'finance.app.depot.shares' OR v_it->'sub'->'params'->'shares' <> core.fn_ui_num(10, 0)
     OR v_it->'pill' <> jsonb_build_object('state', 'ok', 'icon', 'up', 'text', core.fn_ui_tpl('finance.app.depot.gain',
          jsonb_build_object('amount', core.fn_ui_money(200, 'EUR', true), 'pct', core.fn_ui_num(20.0, 1, true)))) THEN
    RAISE EXCEPTION 'FAIL [1i] Position mit aktuellem Kurs: EUR, Stueck ohne Datum, Gewinn-Pille ok/up, got %', v_it; END IF;
  v_it := v_sec->'items'->1;
  IF v_it->'pill' <> jsonb_build_object('state', 'warn', 'icon', 'clock', 'text', core.fn_ui_tpl('finance.app.depot.price_stale'))
     OR (v_it->>'gap')::boolean OR v_it->'sub'->>'value' <> 'finance.app.depot.shares_date'
     OR v_it->'sub'->'params'->'date' <> core.fn_ui_date(current_date - 30) THEN
    RAISE EXCEPTION 'FAIL [1j] veralteter Kurs: warn clock vor Gewinn, abweichendes Kurs-Datum im Untertitel, got %', v_it; END IF;
  v_it := v_sec->'items'->2;
  IF v_it->'value' <> 'null'::jsonb OR (v_it->>'gap')::boolean IS NOT TRUE
     OR v_it->'pill' <> jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl('finance.app.depot.price_missing')) THEN
    RAISE EXCEPTION 'FAIL [1k] Position ohne Kurs: kein Wert, gap, Pill, got %', v_it; END IF;
  SELECT s INTO v_sec FROM jsonb_array_elements(v->'sections') s
   WHERE s->'title' = core.fn_ui_tpl('finance.app.depot.section', jsonb_build_object('name', '__apdp_g_depot__'));
  IF v_sec->'items'->0->'pill'->>'state' <> 'alert' OR v_sec->'items'->0->'pill'->>'icon' <> 'down'
     OR v_sec->'items'->0->'pill'->'text'->'params'->'amount' <> core.fn_ui_money(-10, 'EUR', true) THEN
    RAISE EXCEPTION 'FAIL [1k2] Verlust: alert/down, -10, got %', v_sec; END IF;
  SELECT s INTO v_sec FROM jsonb_array_elements(v->'sections') s
   WHERE s->'title' = core.fn_ui_tpl('finance.app.depot.section', jsonb_build_object('name', '__apdp_hh_crypto__'));
  IF v_sec->'items'->0->'value' <> core.fn_ui_money(20000, 'CHF') OR (v_sec->'items'->0->>'gap')::boolean IS NOT TRUE
     OR jsonb_typeof(v_sec->'items'->0->'pill') <> 'null' OR jsonb_typeof(v_sec->'value') <> 'null'
     OR v_sec->'items'->0->'sub'->>'value' <> 'finance.app.depot.shares_price'
     OR v_sec->'items'->0->'sub'->'params'->'price' <> core.fn_ui_money(40000, 'CHF')
     OR v_sec->'items'->0->'sub'->'params'->'shares' <> core.fn_ui_num(0.5, 1) THEN
    RAISE EXCEPTION 'FAIL [1l] Kurs ohne Wechselkurs: nativer Wert + gap, Fremdwaehrungs-Kurs, Bruchteil-Stueck, got %', v_sec; END IF;
  RAISE NOTICE 'PASS [1] Owner: Hero 2710 (= Vermoegen) + Note, Depots sortiert + Summe, EUR-Werte, Kurs-/Gewinn-Pillen';

  -- USD-Kurs MIT Wechselkurs (Anlass SpaceX 2026-10-28): Wert in EUR, Dollar-Kurs nur im Untertitel
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR', 'CHF', 0.8, current_date);
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'));
  SELECT s INTO v_sec FROM jsonb_array_elements(v->'sections') s
   WHERE s->'title' = core.fn_ui_tpl('finance.app.depot.section', jsonb_build_object('name', '__apdp_hh_crypto__'));
  IF v_sec->'items'->0->>'gap' <> 'false' OR v_sec->'items'->0->'value'->>'currency' <> 'EUR'
     OR v_sec->'items'->0->'sub'->'params'->'price' <> core.fn_ui_money(40000, 'CHF') THEN
    RAISE EXCEPTION 'FAIL [1m] Fremdwaehrung mit Wechselkurs: Wert in EUR, Kurs nativ im Untertitel, got %', v_sec; END IF;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  RAISE NOTICE 'PASS [1m] Fremdwaehrungs-Position in EUR, Kurs in Kurs-Waehrung nur im Untertitel';

  IF finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_partner')) <> finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner')) THEN
    RAISE EXCEPTION 'FAIL [1n] Partner = Haushalts-Sicht'; END IF;

  -- ===== 2) Aufklappen: Kennzahlen aus den eigenen Zeilen (Buchungen: test_fn_app_holding_transactions.sql) =====
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'));
  v_it := v->'sections'->0->'items'->0;
  IF v_it->'details' <> jsonb_build_array(
       jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.d_avg_price'), 'value', core.fn_ui_money(100, 'EUR')),
       jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.d_book_value'), 'value', core.fn_ui_money(1000, 'EUR')),
       jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.d_gain'), 'value', core.fn_ui_tpl('finance.app.depot.gain',
           jsonb_build_object('amount', core.fn_ui_money(200, 'EUR', true), 'pct', core.fn_ui_num(20.0, 1, true))))) THEN
    RAISE EXCEPTION 'FAIL [2a] Details: Ø Kaufkurs, Kaufwert, Gewinn (ohne Buchungen), got %', v_it->'details'; END IF;
  -- veralteter Kurs: kein Gewinn in den Details (wie die Pille)
  IF (v->'sections'->0->'items'->1->'details')::text LIKE '%finance.app.depot.d_gain%' THEN
    RAISE EXCEPTION 'FAIL [2b] veralteter Kurs: kein Gewinn in den Details, got %', v->'sections'->0->'items'->1; END IF;
  RAISE NOTICE 'PASS [2] Aufklappen: Ø Kaufkurs, Kaufwert, Gewinn nur mit aktuellem Kurs';

  -- ===== 3) Kind =====
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_kid', 'params', '{}'::jsonb));
  IF v->'hero'->'value' <> core.fn_ui_money(300, 'EUR') OR (v->'hero'->>'gap')::boolean THEN
    RAISE EXCEPTION 'FAIL [3a] Kind-Hero 300 ohne gap, got %', v->'hero'; END IF;
  v_txt := v::text;
  IF v_txt LIKE '%__apdp_%' THEN RAISE EXCEPTION 'FAIL [3b] Kind-Antwort enthaelt fremde Namen: %', v_txt; END IF;
  IF v_txt ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [3c] *id-Feld: %', v_txt; END IF;
  IF jsonb_array_length(v->'sections') <> 1 OR v_txt NOT LIKE '%Alpha ETF%'
     OR v->'sections'->0->'title' <> core.fn_ui_tpl('finance.app.depot.section', jsonb_build_object('name', 'Alpha Depot')) THEN
    RAISE EXCEPTION 'FAIL [3d] Kind: eigenes Depot ohne „nicht im Depotwert", got %', v->'sections'; END IF;
  RAISE NOTICE 'PASS [3] Kind sieht nur das eigene Depot (Hero = eigene Summe), keine IDs';

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

  -- ===== 6) Rendite je Depot (finance.fn_depot_performance): Abschnitt vor den Depots =====
  -- ohne Buchungen (alle Positionen oben sind direkt angelegt) gibt es keinen Rendite-Abschnitt
  IF finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'))::text LIKE '%finance.app.depot.section_perf%' THEN
    RAISE EXCEPTION 'FAIL [6a] Rendite-Abschnitt ohne Einzahlungen'; END IF;
  -- Depot 1: genau 1 Jahr, -1000 -> 1100 = +10,0 % pro Jahr; Depot 2: 100 Tage, -500 -> 450 = -10,0 % seit Beginn
  DECLARE
    v_r1 INT; v_r2 INT; h_r1 INT; h_r2 INT;
  BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
      VALUES ('__apdp_perf1__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_r1;
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
      VALUES ('__apdp_perf2__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_r2;
    INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_r1, 'APD00000011', 'APDPR1', '__apdp_r1__', 'EUR') RETURNING id INTO h_r1;
    INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_r2, 'APD00000012', 'APDPR2', '__apdp_r2__', 'EUR') RETURNING id INTO h_r2;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares) VALUES
      (v_giro, -1000, core.fn_today() - 365, 'buy', h_r1, 10), (v_giro, -500, core.fn_today() - 100, 'buy', h_r2, 5);
    INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('APDPR1', 110, 'EUR', core.fn_today()), ('APDPR2', 90, 'EUR', core.fn_today());
  END;
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'));
  v_sec := v->'sections'->0;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.depot.section_perf') OR jsonb_array_length(v_sec->'items') <> 3 THEN
    RAISE EXCEPTION 'FAIL [6b] Rendite-Abschnitt zuerst, 2 Depots + Alle Depots (ohne Depots ohne Einzahlung), got %', v_sec; END IF;
  v_it := v_sec->'items'->0;
  IF v_it->'label' <> '"__apdp_perf1__"'::jsonb OR jsonb_typeof(v_it->'value') <> 'null' OR (v_it->>'gap')::boolean
     OR v_it->'sub' <> core.fn_ui_tpl('finance.app.depot.perf_since', jsonb_build_object('date', core.fn_ui_date(core.fn_today() - 365)))
     OR v_it->'pill' <> jsonb_build_object('state', 'ok', 'icon', 'up', 'text', core.fn_ui_tpl('finance.app.depot.perf_pa',
          jsonb_build_object('pct', core.fn_ui_num(10.0, 1, true))))
     OR v_it->'details'->0 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.d_perf_value'), 'value', core.fn_ui_money(1100, 'EUR'))
     OR v_it->'details'->-1 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.d_perf_how'), 'value', NULL) THEN
    RAISE EXCEPTION 'FAIL [6c] Depot ab 1 Jahr: +10,0 %% pro Jahr (ok/up), seit-Datum, Wert heute + Erklaerung, got %', v_it; END IF;
  v_it := v_sec->'items'->1;
  IF v_it->'sub' <> core.fn_ui_tpl('finance.app.depot.perf_since_short', jsonb_build_object('date', core.fn_ui_date(core.fn_today() - 100)))
     OR v_it->'pill' <> jsonb_build_object('state', 'alert', 'icon', 'down', 'text', core.fn_ui_tpl('finance.app.depot.perf_total_return',
          jsonb_build_object('pct', core.fn_ui_num(-10.0, 1, true)))) THEN
    RAISE EXCEPTION 'FAIL [6d] unter 1 Jahr: -10,0 %% seit Beginn (alert/down), kein Jahreswert, got %', v_it; END IF;
  v_it := v_sec->'items'->2;
  IF v_it->'label' <> core.fn_ui_tpl('finance.app.depot.perf_total') OR v_it->'pill'->'text'->>'value' <> 'finance.app.depot.perf_pa' THEN
    RAISE EXCEPTION 'FAIL [6e] Alle Depots zuletzt, pro Jahr (Beginn vor 365 Tagen), got %', v_it; END IF;
  IF v::text ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [6f] *id-Feld im Rendite-Abschnitt'; END IF;
  -- veralteter Kurs (30 Tage): Zahl bleibt, Pille warn/clock, Hinweis beim Aufklappen
  UPDATE finance.market_prices SET as_of = core.fn_today() - 30 WHERE symbol = 'APDPR1';
  v_it := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'))->'sections'->0->'items'->0;
  IF v_it->'pill'->>'state' <> 'warn' OR v_it->'pill'->>'icon' <> 'clock'
     OR v_it->'pill'->'text'->>'value' <> 'finance.app.depot.perf_pa'
     OR NOT (v_it->'details' @> jsonb_build_array(jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.d_perf_stale')))) THEN
    RAISE EXCEPTION 'FAIL [6f2] veralteter Kurs: warn/clock mit Zahl + Hinweis, got %', v_it; END IF;
  UPDATE finance.market_prices SET as_of = core.fn_today() WHERE symbol = 'APDPR1';
  -- Partner-Depot hat keine Einzahlung, ein eigenes Kind-Depot ebenso -> Kind sieht keinen Rendite-Abschnitt
  IF finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_kid'))::text LIKE '%section_perf%' THEN
    RAISE EXCEPTION 'FAIL [6g] Kind sieht fremde Rendite'; END IF;
  RAISE NOTICE 'PASS [6] Rendite je Depot: p.a. ab 1 Jahr, seit Beginn darunter, Alle Depots, keine IDs';

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
