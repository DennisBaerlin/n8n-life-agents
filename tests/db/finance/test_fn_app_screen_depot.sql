-- tests/db/finance/test_fn_app_screen_depot.sql
-- finance.fn_app_screen_depot(p jsonb) — Mini-App-Bildschirm „Depot" (docs/package-contract.md §3.12, View-Modell v1).
--   1) Owner/Partner sehen alle aktiven Depots. Hero = Anlageart depot aus networth_by_asset_class ohne Kinder (= dieselbe
--      Zahl wie „Wertpapiere & Krypto" auf der Vermoegen-Seite; ohne Kurs zaehlt der Kaufwert) + gap (Position ohne Kurs
--      oder ohne Wechselkurs); Note Gewinn seit Kauf (nur aktuelle Kurse mit Kaufwert) + Kurs-Datum. Ein Abschnitt je
--      Eltern-Depot (nach Wert, ohne Wert zuletzt), Summe nur ab zwei Positionen, ohne gap und nur bei mindestens zwei
--      Eltern-Depots (sonst ~ Hero); Positionen nach Wert, Wert in EUR (nur ohne Wechselkurs nativ + gap), KEIN
--      Untertitel, Pille Kurs fehlt / Kurs veraltet ({date}), Gewinn als trend; geschlossenes Depot fehlt.
--   2) Aufklappen: Bestand (Stueck · Kurs, Kurs-Datum nur wenn abweichend und nicht veraltet), Ø Kaufkurs, Kaufwert; kein
--      „Seit Kauf" (= trend); die Buchungs-Zeilen danach testet test_fn_app_holding_transactions.sql.
--   7) „Depots der Kinder" (nur Haushalt): eine Zeile je Kind-Depot mit Positionen (Wert = Vermoegen-Regel, Inhaber als
--      Untertitel, trend, Pille Kurs fehlt vor veraltet, Pillen-Zeilen zuerst), Aufklappen = Jahres-Rendite ab einem
--      Jahr + Positionen (hoechstens 8 Zeilen), Summe ab zwei Kind-Depots ohne gap; Kinder nie im Rendite-Abschnitt;
--      Kind-Sicht ohne Geschwister; entfernte Katalog-Keys tauchen nirgends auf; core.fn_app_view_lint = 0 mit Kinder- und
--      Eltern-Rendite auf einer Seite.
--   8) Fixture-Haushalt (tests/util/util_app_household.sql): core.fn_app_view_lint = 0 fuer alle Personen, Depot mit einer
--      Position ohne Summe (B5), beide Kinder in 'Depots der Kinder', Kind-Sicht ohne Fremdes.
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
    ('APDPG', 50, 'EUR', current_date - 1), ('APDPC', 10, 'EUR', current_date),
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

  SELECT array_agg((s->'title'->>'value') || ':' || COALESCE(s->'title'->'params'->>'name', '') ORDER BY o) INTO v_labels
    FROM jsonb_array_elements(v->'sections') WITH ORDINALITY AS t(s, o);
  IF v_labels IS DISTINCT FROM ARRAY['finance.app.depot.section:__apdp_hh_depot__', 'finance.app.depot.section:__apdp_p_depot__',
                                     'finance.app.depot.section:__apdp_g_depot__', 'finance.app.depot.section:__apdp_hh_crypto__',
                                     'finance.app.depot.section_kids:'] THEN
    RAISE EXCEPTION 'FAIL [1f] Haushalt nach Wert (ohne Wert zuletzt), „Depots der Kinder" hinten, got %', v_labels; END IF;
  v_sec := v->'sections'->0;
  -- Depot-Summe: entfaellt bei Position ohne Kurs (statt still zu niedrig) und ueber einer einzigen Position
  IF jsonb_typeof(v_sec->'value') <> 'null' OR jsonb_typeof(v->'sections'->1->'value') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [1g] Depot-Summe: entfaellt bei gap und bei einer Position, got %', v->'sections'; END IF;
  IF jsonb_path_exists(v, 'strict $.sections[0 to 3].items[*] ? (@.sub != null)') THEN
    RAISE EXCEPTION 'FAIL [1g2] keine Untertitel an Positionen: %', v; END IF;
  SELECT array_agg(i->>'label' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v_sec->'items') WITH ORDINALITY AS t(i, o);
  IF v_labels IS DISTINCT FROM ARRAY['__apdp_etf_ok__', '__apdp_etf_stale__', '__apdp_etf_missing__'] THEN
    RAISE EXCEPTION 'FAIL [1h] Positionen nach Wert, got %', v_labels; END IF;
  v_it := v_sec->'items'->0;
  IF v_it->'value' <> core.fn_ui_money(1200, 'EUR') OR (v_it->>'gap')::boolean
     OR jsonb_typeof(v_it->'sub') <> 'null'
     OR jsonb_typeof(v_it->'pill') <> 'null'
     OR v_it->'trend' <> jsonb_build_object('direction', 'up', 'text', core.fn_ui_tpl('finance.app.depot.gain',
          jsonb_build_object('amount', core.fn_ui_money(200, 'EUR', true), 'pct', core.fn_ui_num(20.0, 1, true)))) THEN
    RAISE EXCEPTION 'FAIL [1i] Position mit aktuellem Kurs: EUR, kein Untertitel, Gewinn als trend up (keine Pille), got %', v_it; END IF;
  v_it := v_sec->'items'->1;
  IF v_it->'pill' <> jsonb_build_object('state', 'warn', 'icon', 'clock', 'text', core.fn_ui_tpl('finance.app.depot.price_stale_date',
                         jsonb_build_object('date', core.fn_ui_date(current_date - 30))))
     OR (v_it->>'gap')::boolean OR jsonb_typeof(v_it->'sub') <> 'null'
     OR v_it->'details'->0 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.d_holding'),
          'value', core.fn_ui_tpl('finance.app.depot.d_holding_value', jsonb_build_object(
              'shares', core.fn_ui_num(5, 0), 'price', core.fn_ui_money(60, 'EUR')))) THEN
    RAISE EXCEPTION 'FAIL [1j] veralteter Kurs: warn mit Kurs-Datum, Bestand ohne zweites Datum, got %', v_it; END IF;
  v_it := v_sec->'items'->2;
  IF v_it->'value' <> 'null'::jsonb OR (v_it->>'gap')::boolean IS NOT TRUE
     OR v_it->'pill' <> jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl('finance.app.depot.price_missing'))
     OR v_it->'details'->0->'value' <> core.fn_ui_tpl('finance.app.depot.d_holding_shares', jsonb_build_object('shares', core.fn_ui_num(2, 0))) THEN
    RAISE EXCEPTION 'FAIL [1k] Position ohne Kurs: kein Wert, gap, Pille, Bestand nur Stueck, got %', v_it; END IF;
  SELECT s INTO v_sec FROM jsonb_array_elements(v->'sections') s
   WHERE s->'title' = core.fn_ui_tpl('finance.app.depot.section', jsonb_build_object('name', '__apdp_g_depot__'));
  IF jsonb_typeof(v_sec->'items'->0->'pill') <> 'null' OR v_sec->'items'->0->'trend'->>'direction' <> 'down'
     OR v_sec->'items'->0->'trend'->'text'->'params'->'amount' <> core.fn_ui_money(-10, 'EUR', true) THEN
    RAISE EXCEPTION 'FAIL [1k2] Verlust: trend down -10, kein roter Alarm, got %', v_sec; END IF;
  -- Kurs vom Vortag (nicht veraltet, weicht vom Hero-Datum ab): das Datum steht im Bestand
  IF v_sec->'items'->0->'details'->0->'value' <> core.fn_ui_tpl('finance.app.depot.d_holding_value_date', jsonb_build_object(
       'shares', core.fn_ui_num(1, 0), 'price', core.fn_ui_money(50, 'EUR'), 'date', core.fn_ui_date(current_date - 1))) THEN
    RAISE EXCEPTION 'FAIL [1k3] abweichendes Kurs-Datum im Bestand, got %', v_sec->'items'->0->'details'; END IF;
  SELECT s INTO v_sec FROM jsonb_array_elements(v->'sections') s
   WHERE s->'title' = core.fn_ui_tpl('finance.app.depot.section', jsonb_build_object('name', '__apdp_hh_crypto__'));
  IF v_sec->'items'->0->'value' <> core.fn_ui_money(20000, 'CHF') OR (v_sec->'items'->0->>'gap')::boolean IS NOT TRUE
     OR jsonb_typeof(v_sec->'items'->0->'pill') <> 'null' OR jsonb_typeof(v_sec->'value') <> 'null'
     OR v_sec->'items'->0->'details'->0->'value' <> core.fn_ui_tpl('finance.app.depot.d_holding_value', jsonb_build_object(
          'shares', core.fn_ui_num(0.5, 1), 'price', core.fn_ui_money(40000, 'CHF'))) THEN
    RAISE EXCEPTION 'FAIL [1l] Kurs ohne Wechselkurs: nativer Wert + gap, Fremdwaehrungs-Kurs + Bruchteil-Stueck im Bestand, got %', v_sec; END IF;
  -- zwei Positionen im Partner-Depot (ohne gap) bei mehreren Eltern-Depots: Summe 1000 + 100
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_p, 'APD00000008', 'APDPP2', '__apdp_p_etf2__', 2, 40, 'EUR');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('APDPP2', 50, 'EUR', current_date);
  SELECT s INTO v_sec FROM jsonb_array_elements(finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'))->'sections') s
   WHERE s->'title' = core.fn_ui_tpl('finance.app.depot.section', jsonb_build_object('name', '__apdp_p_depot__'));
  IF v_sec->'value' <> core.fn_ui_money(1100, 'EUR') THEN
    RAISE EXCEPTION 'FAIL [1l2] zwei Positionen ohne gap -> Depot-Summe 1100, got %', v_sec; END IF;
  -- einziges sichtbares Depot (Gast) mit zwei Positionen: die Summe waere der Hero -> keine
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_g, 'APD00000009', 'APDPG2', '__apdp_g_etf2__', 1, 40, 'EUR');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('APDPG2', 50, 'EUR', current_date);
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_guest'));
  IF jsonb_array_length(v->'sections') <> 1 OR jsonb_array_length(v->'sections'->0->'items') <> 2
     OR jsonb_typeof(v->'sections'->0->'value') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [1l3] ein Depot mit zwei Positionen: keine Summe (= Hero), got %', v->'sections'; END IF;
  DELETE FROM finance.market_prices WHERE symbol IN ('APDPP2', 'APDPG2');
  DELETE FROM finance.depot_holdings WHERE symbol IN ('APDPP2', 'APDPG2');
  RAISE NOTICE 'PASS [1] Owner: Hero 2710 (= Vermoegen) + Note, Depots sortiert, Summe nur ab zwei Positionen, kein Untertitel, datierte Kurs-Pille';

  -- USD-Kurs MIT Wechselkurs (Anlass SpaceX 2026-10-28): Wert in EUR, Dollar-Kurs nur im Untertitel
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR', 'CHF', 0.8, current_date);
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'));
  SELECT s INTO v_sec FROM jsonb_array_elements(v->'sections') s
   WHERE s->'title' = core.fn_ui_tpl('finance.app.depot.section', jsonb_build_object('name', '__apdp_hh_crypto__'));
  IF v_sec->'items'->0->>'gap' <> 'false' OR v_sec->'items'->0->'value'->>'currency' <> 'EUR'
     OR v_sec->'items'->0->'details'->0->'value'->'params'->'price' <> core.fn_ui_money(40000, 'CHF') THEN
    RAISE EXCEPTION 'FAIL [1m] Fremdwaehrung mit Wechselkurs: Wert in EUR, Kurs nativ im Bestand, got %', v_sec; END IF;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  RAISE NOTICE 'PASS [1m] Fremdwaehrungs-Position in EUR, Kurs in Kurs-Waehrung nur im Bestand';

  IF finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_partner')) <> finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner')) THEN
    RAISE EXCEPTION 'FAIL [1n] Partner = Haushalts-Sicht'; END IF;

  -- ===== 2) Aufklappen: Kennzahlen aus den eigenen Zeilen (Buchungen: test_fn_app_holding_transactions.sql) =====
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'));
  v_it := v->'sections'->0->'items'->0;
  IF v_it->'details' <> jsonb_build_array(
       jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.d_holding'), 'value', core.fn_ui_tpl('finance.app.depot.d_holding_value',
           jsonb_build_object('shares', core.fn_ui_num(10, 0), 'price', core.fn_ui_money(120, 'EUR')))),
       jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.d_avg_price'), 'value', core.fn_ui_money(100, 'EUR')),
       jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.d_book_value'), 'value', core.fn_ui_money(1000, 'EUR'))) THEN
    RAISE EXCEPTION 'FAIL [2a] Details: Bestand, Ø Kaufkurs, Kaufwert, kein „Seit Kauf" (ohne Buchungen), got %', v_it->'details'; END IF;
  IF jsonb_path_exists(v, 'strict $.sections[*].items[*] ? (@.details.size() > 8)') THEN
    RAISE EXCEPTION 'FAIL [2b] hoechstens 8 Detail-Zeilen'; END IF;
  RAISE NOTICE 'PASS [2] Aufklappen: Bestand, Ø Kaufkurs, Kaufwert, kein „Seit Kauf"';

  -- ===== 3) Kind =====
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_kid', 'params', '{}'::jsonb));
  IF v->'hero'->'value' <> core.fn_ui_money(300, 'EUR') OR (v->'hero'->>'gap')::boolean THEN
    RAISE EXCEPTION 'FAIL [3a] Kind-Hero 300 ohne gap, got %', v->'hero'; END IF;
  v_txt := v::text;
  IF v_txt LIKE '%__apdp_%' THEN RAISE EXCEPTION 'FAIL [3b] Kind-Antwort enthaelt fremde Namen: %', v_txt; END IF;
  IF v_txt ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [3c] *id-Feld: %', v_txt; END IF;
  IF jsonb_array_length(v->'sections') <> 1 OR v_txt NOT LIKE '%Alpha ETF%'
     OR v->'sections'->0->'title' <> core.fn_ui_tpl('finance.app.depot.section', jsonb_build_object('name', 'Alpha Depot'))
     OR v_txt LIKE '%finance.app.depot.section_kids%' OR jsonb_typeof(v->'sections'->0->'value') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [3d] Kind: eigenes Depot als normaler Abschnitt (eine Position, keine Summe), kein Kinder-Abschnitt, got %', v->'sections'; END IF;
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
  -- EIN Zeitraum auf der Seite („seit Kauf"): eine Rendite-Zeile erst ab einem vollen Jahr. Junge Depots (auch
  -- uebernommene) fehlen, statt eine zweite Gewinnzahl mit anderem Startpunkt zu zeigen.
  -- Depot 2: 100 Tage, -500 -> 450; Depot 4: Uebernahme vor 20 Tagen, 10 Stueck Einstand 50, Kurs damals 80, heute 70
  DECLARE
    v_r1 INT; v_r2 INT; v_r3 INT; v_r4 INT; h_r1 INT; h_r2 INT; h_r3 INT; h_r4 INT; g uuid := gen_random_uuid();
  BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
      VALUES ('__apdp_perf2__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_r2;
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
      VALUES ('__apdp_perf4__', 'crypto_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_r4;
    INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_r2, 'APD00000012', 'APDPR2', '__apdp_r2__', 'EUR') RETURNING id INTO h_r2;
    INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_r4, NULL, 'APDPR4', '__apdp_r4__', 'EUR') RETURNING id INTO h_r4;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares) VALUES
      (v_giro, -500, core.fn_today() - 100, 'buy', h_r2, 5);
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, unit_price, group_id) VALUES
      (v_giro, -500, core.fn_today() - 20, 'buy', h_r4, 10, 50, g);
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, group_id) VALUES
      (v_giro, 500, core.fn_today() - 20, 'position_takeover', g);
    INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES
      ('APDPR2', 90, 'EUR', core.fn_today()), ('APDPR4', 80, 'EUR', core.fn_today() - 20), ('APDPR4', 70, 'EUR', core.fn_today());

    -- [6b1] nur junge Depots -> kein Rendite-Abschnitt; die Position zeigt „seit Kauf" (+200 € · +40,0 %)
    v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'));
    IF v::text LIKE '%finance.app.depot.section_perf%' THEN
      RAISE EXCEPTION 'FAIL [6b1] Rendite-Abschnitt nur mit jungen Depots, got %', v->'sections'->0; END IF;
    SELECT it INTO v_it FROM jsonb_array_elements(v->'sections') s, jsonb_array_elements(s->'items') it
     WHERE it->>'label' = '__apdp_r4__';
    IF v_it->'trend' <> jsonb_build_object('direction', 'up', 'text', core.fn_ui_tpl('finance.app.depot.gain',
         jsonb_build_object('amount', core.fn_ui_money(200, 'EUR', true), 'pct', core.fn_ui_num(40.0, 1, true)))) THEN
      RAISE EXCEPTION 'FAIL [6b1] uebernommene Position: seit Kauf +200 / +40,0 %%, got %', v_it; END IF;

    -- [6b2] ein Depot mit vollem Jahr (-1000 -> 1100 = +10,0 % pro Jahr) -> eine Zeile, ohne „Alle Depots"
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
      VALUES ('__apdp_perf1__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_r1;
    INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_r1, 'APD00000011', 'APDPR1', '__apdp_r1__', 'EUR') RETURNING id INTO h_r1;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares) VALUES
      (v_giro, -1000, core.fn_today() - 365, 'buy', h_r1, 10);
    INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('APDPR1', 110, 'EUR', core.fn_today());
    v_sec := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'))->'sections'->0;
    IF v_sec->'title' <> core.fn_ui_tpl('finance.app.depot.section_perf') OR jsonb_array_length(v_sec->'items') <> 1
       OR v_sec->'items'->0->'label' <> '"__apdp_perf1__"'::jsonb THEN
      RAISE EXCEPTION 'FAIL [6b2] ein Jahres-Depot: nur seine Zeile, keine jungen, kein Alle Depots, got %', v_sec; END IF;

    -- [6b3] zweites Depot mit vollem Jahr (400 Tage, Wert 440): zwei Zeilen, aber noch kein „Alle Depots", weil die
    -- Summe die versteckten jungen Depots (2, 4) poolen wuerde
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
      VALUES ('__apdp_perf3__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_r3;
    INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_r3, 'APD00000013', 'APDPR3', '__apdp_r3__', 'EUR') RETURNING id INTO h_r3;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares) VALUES
      (v_giro, -400, core.fn_today() - 400, 'buy', h_r3, 4);
    INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('APDPR3', 110, 'EUR', core.fn_today());
    SELECT array_agg(it->>'label' ORDER BY o) INTO v_labels
      FROM jsonb_array_elements(finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'))->'sections'->0->'items')
           WITH ORDINALITY AS t(it, o);
    IF v_labels IS DISTINCT FROM ARRAY['__apdp_perf1__', '__apdp_perf3__'] THEN
      RAISE EXCEPTION 'FAIL [6b3] zwei Jahres-Depots neben jungen: nur ihre Zeilen, kein Alle Depots, got %', v_labels; END IF;

    -- ohne die jungen Depots (keine Einzahlung mehr) stehen alle Haushalts-Depots -> „Alle Depots" erscheint
    DELETE FROM finance.transactions WHERE holding_id IN (h_r2, h_r4) OR group_id = g;
  END;
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'));
  v_sec := v->'sections'->0;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.depot.section_perf') OR jsonb_array_length(v_sec->'items') <> 3 THEN
    RAISE EXCEPTION 'FAIL [6b] Rendite-Abschnitt zuerst, 2 Jahres-Depots + Alle Depots (ohne junge Depots), got %', v_sec; END IF;
  v_it := v_sec->'items'->0;
  IF v_it->'label' <> '"__apdp_perf1__"'::jsonb OR (v_it->>'gap')::boolean
     OR v_it->'sub' <> core.fn_ui_tpl('finance.app.depot.perf_since', jsonb_build_object('date', core.fn_ui_date(core.fn_today() - 365)))
     OR jsonb_typeof(v_it->'pill') <> 'null'
     OR v_it->'value' <> core.fn_ui_tpl('finance.app.depot.perf_pa', jsonb_build_object('pct', core.fn_ui_num(10.0, 1, true)))
     OR v_it->'details' <> jsonb_build_array(jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.d_perf_how'), 'value', NULL)) THEN
    RAISE EXCEPTION 'FAIL [6c] Depot ab 1 Jahr: +10,0 %% pro Jahr als Wert (keine Pille), seit-Datum, nur die Erklaerung (kein „Wert heute"), got %', v_it; END IF;
  v_it := v_sec->'items'->1;
  IF v_it->'label' <> '"__apdp_perf3__"'::jsonb
     OR v_it->'sub' <> core.fn_ui_tpl('finance.app.depot.perf_since', jsonb_build_object('date', core.fn_ui_date(core.fn_today() - 400)))
     OR v_it->'value'->>'value' <> 'finance.app.depot.perf_pa' THEN
    RAISE EXCEPTION 'FAIL [6d] zweites Jahres-Depot nach Wert: pro Jahr, seit-Datum, got %', v_it; END IF;
  v_it := v_sec->'items'->2;
  IF v_it->'label' <> core.fn_ui_tpl('finance.app.depot.perf_total') OR v_it->'value'->>'value' <> 'finance.app.depot.perf_pa' THEN
    RAISE EXCEPTION 'FAIL [6e] Alle Depots zuletzt, pro Jahr (Beginn vor 365 Tagen), got %', v_it; END IF;
  IF v::text ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [6f] *id-Feld im Rendite-Abschnitt'; END IF;
  -- veralteter Kurs (30 Tage): Zahl bleibt, Pille warn/clock, Hinweis beim Aufklappen
  UPDATE finance.market_prices SET as_of = core.fn_today() - 30 WHERE symbol = 'APDPR1';
  v_it := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'))->'sections'->0->'items'->0;
  IF v_it->'pill'->>'state' <> 'warn' OR v_it->'pill'->>'icon' <> 'clock'
     OR v_it->'pill'->'text' <> core.fn_ui_tpl('finance.app.depot.price_stale_date', jsonb_build_object('date', core.fn_ui_date(core.fn_today() - 30)))
     OR v_it->'value'->>'value' <> 'finance.app.depot.perf_pa'
     OR NOT (v_it->'details' @> jsonb_build_array(jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.d_perf_stale')))) THEN
    RAISE EXCEPTION 'FAIL [6f2] veralteter Kurs: warn/clock mit Kurs-Datum, Zahl + Hinweis, got %', v_it; END IF;
  -- jede „veraltet"-Pille der Seite (auch „Alle Depots") traegt ein Datum
  IF jsonb_path_exists(finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner')),
       'strict $.**.text ? (@.value == "finance.app.depot.price_stale_date" && !exists(@.params.date))') THEN
    RAISE EXCEPTION 'FAIL [6f2b] veraltet-Pille ohne Datum'; END IF;
  UPDATE finance.market_prices SET as_of = core.fn_today() WHERE symbol = 'APDPR1';
  -- altes Depot ohne Kurs: ohne Endwert-Fluss ist period_days 0, die Zeile bleibt trotzdem (Beginn vor 400 Tagen) mit
  -- „Kurs fehlt" + gap, statt still zu verschwinden
  DELETE FROM finance.market_prices WHERE symbol = 'APDPR3';
  SELECT it INTO v_it
    FROM jsonb_array_elements(finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'))->'sections'->0->'items') it
   WHERE it->>'label' = '__apdp_perf3__';
  IF v_it IS NULL OR (v_it->>'gap')::boolean IS NOT TRUE
     OR v_it->'pill' <> jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl('finance.app.depot.price_missing')) THEN
    RAISE EXCEPTION 'FAIL [6f3] altes Depot ohne Kurs: Zeile mit Kurs fehlt + gap, got %', v_it; END IF;
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('APDPR3', 110, 'EUR', core.fn_today());
  -- Partner-Depot hat keine Einzahlung, ein eigenes Kind-Depot ebenso -> Kind sieht keinen Rendite-Abschnitt
  IF finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_kid'))::text LIKE '%section_perf%' THEN
    RAISE EXCEPTION 'FAIL [6g] Kind sieht fremde Rendite'; END IF;
  RAISE NOTICE 'PASS [6] Rendite je Depot: nur ab 1 Jahr (p.a.), junge Depots fehlen, Alle Depots nur wenn alle stehen, altes Depot ohne Kurs bleibt, keine IDs';

  -- ===== 7) Depots der Kinder =====
  -- [7a] ein Kind-Depot: eine Zeile, keine Abschnitts-Summe; Wert = Vermoegen-Seite (networth_by_asset_class)
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'));
  v_sec := v->'sections'->-1;
  v_it := v_sec->'items'->0;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.depot.section_kids') OR jsonb_array_length(v_sec->'items') <> 1
     OR jsonb_typeof(v_sec->'value') <> 'null'
     OR v_it->'label' <> '"Alpha Depot"'::jsonb
     OR v_it->'sub' <> core.fn_ui_tpl('finance.app.depot.kid_owner', jsonb_build_object('name', 'Kind Beispiel'))
     OR v_it->'value' <> core.fn_ui_money(300, 'EUR') OR (v_it->>'gap')::boolean OR jsonb_typeof(v_it->'pill') <> 'null'
     OR v_it->'trend' <> jsonb_build_object('direction', 'up', 'text', core.fn_ui_tpl('finance.app.depot.gain',
          jsonb_build_object('amount', core.fn_ui_money(30, 'EUR', true), 'pct', core.fn_ui_num(11.1, 1, true))))
     OR v_it->'details' <> jsonb_build_array(jsonb_build_object('label', 'Alpha ETF',
          'value', core.fn_ui_tpl('finance.app.depot.kid_position', jsonb_build_object('value', core.fn_ui_money(300, 'EUR'),
              'gain', core.fn_ui_tpl('finance.app.depot.gain', jsonb_build_object('amount', core.fn_ui_money(30, 'EUR', true),
                                                                                   'pct', core.fn_ui_num(11.1, 1, true))))))) THEN
    RAISE EXCEPTION 'FAIL [7a] ein Kind-Depot: Zeile mit Inhaber, Wert, trend, Position im Aufklappen, keine Summe, got %', v_sec; END IF;
  IF (v_it->'value'->>'value')::numeric IS DISTINCT FROM
     (SELECT round(sum(n.value_eur), 2) FROM finance.networth_by_asset_class n WHERE n.owner_person_id = 'apdp_kid' AND n.bucket = 'depot') THEN
    RAISE EXCEPTION 'FAIL [7a2] Kind-Depot-Wert muss = Vermoegen-Seite sein, got %', v_it->'value'; END IF;

  -- [7b] zweites Kind: Depot mit 9 Positionen (eine ohne Kurs), Rendite-Depot (1 Jahr), Depot ohne Positionen
  DECLARE
    v_b INT; v_d INT; v_e INT; h_d INT;
  BEGIN
    INSERT INTO agent.persons (person_id, full_name, role) VALUES ('apdp_kid2', 'Beta Kind', 'child');
    INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
      VALUES ('Beta Konto', 'cash', 'EUR', 'active', 'apdp_kid2') RETURNING id INTO v_e;
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
      VALUES ('Beta Depot', 'stocks_depot', 'EUR', 'active', v_e, 'apdp_kid2') RETURNING id INTO v_b;
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
      VALUES ('Delta Depot', 'stocks_depot', 'EUR', 'active', v_e, 'apdp_kid2') RETURNING id INTO v_d;
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
      VALUES ('Gamma Depot', 'stocks_depot', 'EUR', 'active', v_e, 'apdp_kid2');
    INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
      SELECT v_b, 'APDB0000000' || k, 'APDB' || k, 'Beta Pos ' || k, 1, 10 * k, 'EUR' FROM generate_series(1, 9) k;
    INSERT INTO finance.market_prices (symbol, price, currency, as_of)
      SELECT 'APDB' || k, 10 * k, 'EUR', current_date FROM generate_series(1, 8) k;   -- APDB9 ohne Kurs
    INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency)
      VALUES (v_d, 'APDD0000001', 'APDD1', 'Delta Pos', 'EUR') RETURNING id INTO h_d;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares) VALUES
      (v_e, -1000, core.fn_today() - 365, 'buy', h_d, 10);
    INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('APDD1', 110, 'EUR', core.fn_today());

    v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'));
    v_sec := v->'sections'->-1;
    SELECT array_agg(i->>'label' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v_sec->'items') WITH ORDINALITY AS t(i, o);
    IF v_labels IS DISTINCT FROM ARRAY['Beta Depot', 'Delta Depot', 'Alpha Depot'] OR jsonb_typeof(v_sec->'value') <> 'null' THEN
      RAISE EXCEPTION 'FAIL [7b] Pillen-Zeile zuerst, dann nach Wert; Depot ohne Positionen fehlt; Summe entfaellt bei gap, got % / %', v_labels, v_sec->'value'; END IF;
    v_it := v_sec->'items'->0;
    -- Wert nach der Vermoegen-Regel: ohne Kurs zaehlt der Kaufwert (360 + 90), gap weil eine Position keinen Kurs hat
    IF v_it->'value' <> core.fn_ui_money(450, 'EUR') OR (v_it->>'gap')::boolean IS NOT TRUE
       OR v_it->'pill' <> jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl('finance.app.depot.price_missing'))
       OR v_it->'sub' <> core.fn_ui_tpl('finance.app.depot.kid_owner', jsonb_build_object('name', 'Beta Kind'))
       OR jsonb_array_length(v_it->'details') <> 8
       OR v_it->'details'->-1 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.more_positions',
            jsonb_build_object('count', core.fn_ui_num(2, 0))), 'value', NULL) THEN
      RAISE EXCEPTION 'FAIL [7c] Kind-Depot mit Kurs-Luecke: Wert 450 + gap, Pille Kurs fehlt, 7 Positionen + „2 weitere", got %', v_it; END IF;
    IF (v_it->'value'->>'value')::numeric + 300 + 1100 IS DISTINCT FROM
       (SELECT round(sum(n.value_eur), 2) FROM finance.networth_by_asset_class n
         WHERE n.owner_person_id IN ('apdp_kid', 'apdp_kid2') AND n.bucket = 'depot') THEN
      RAISE EXCEPTION 'FAIL [7c2] Kind-Depot-Werte muessen = Vermoegen-Seite sein'; END IF;
    v_it := v_sec->'items'->1;
    IF v_it->'details'->0 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.kid_perf', jsonb_build_object('date', core.fn_ui_date(core.fn_today() - 365))),
         'value', core.fn_ui_tpl('finance.app.depot.perf_pa', jsonb_build_object('pct', core.fn_ui_num(10.0, 1, true))))
       OR v_it->'details'->1->'label' <> '"Delta Pos"'::jsonb THEN
      RAISE EXCEPTION 'FAIL [7d] Kind-Depot ab einem Jahr: Rendite pro Jahr als erste Detail-Zeile, dann Positionen, got %', v_it->'details'; END IF;
    SELECT s INTO v_sec FROM jsonb_array_elements(v->'sections') s WHERE s->'title' = core.fn_ui_tpl('finance.app.depot.section_perf');
    IF v_sec::text LIKE '%Delta Depot%' OR v_sec::text LIKE '%Alpha Depot%' THEN
      RAISE EXCEPTION 'FAIL [7e] Kinder stehen nicht im Rendite-Abschnitt, got %', v_sec; END IF;

    -- Kurs nachgetragen: keine Luecke mehr -> Summe der drei Kind-Depots
    INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('APDB9', 90, 'EUR', current_date);
    v_sec := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'))->'sections'->-1;
    IF v_sec->'value' <> core.fn_ui_money(450 + 1100 + 300, 'EUR') THEN
      RAISE EXCEPTION 'FAIL [7f] drei Kind-Depots ohne gap -> Abschnitts-Summe, got %', v_sec; END IF;

    -- veralteter Kurs im Kind-Depot mit Jahres-Rendite: Pille mit Datum, Rendite + Hinweis „vorlaeufig" wie bei den Eltern
    UPDATE finance.market_prices SET as_of = core.fn_today() - 30 WHERE symbol = 'APDD1';
    v_it := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'))->'sections'->-1->'items'->0;
    IF v_it->'label' <> '"Delta Depot"'::jsonb
       OR v_it->'pill'->'text' <> core.fn_ui_tpl('finance.app.depot.price_stale_date', jsonb_build_object('date', core.fn_ui_date(core.fn_today() - 30)))
       OR v_it->'details'->0->'label'->>'value' <> 'finance.app.depot.kid_perf'
       OR v_it->'details'->1 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.d_perf_stale'), 'value', NULL)
       OR v_it->'details'->2->'label' <> '"Delta Pos"'::jsonb THEN
      RAISE EXCEPTION 'FAIL [7f2] Kind-Depot mit veraltetem Kurs: zuerst, Pille mit Datum, Rendite + vorlaeufig, got %', v_it; END IF;
    UPDATE finance.market_prices SET as_of = core.fn_today() WHERE symbol = 'APDD1';

    -- Kind-Sicht: nur Eigenes, nie Geschwister
    v_txt := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_kid'))::text;
    IF v_txt LIKE '%Beta%' OR v_txt LIKE '%Delta%' THEN RAISE EXCEPTION 'FAIL [7g] Kind sieht Geschwister-Depots'; END IF;
    v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_kid2'));
    v_txt := v::text;
    IF v_txt LIKE '%Alpha%' OR v_txt LIKE '%Kind Beispiel%' OR v_txt LIKE '%__apdp_%' OR v_txt LIKE '%finance.app.depot.section_kids%' THEN
      RAISE EXCEPTION 'FAIL [7h] Zweitkind sieht Fremdes oder einen Kinder-Abschnitt: %', v_txt; END IF;
  END;

  -- [7i] entfernte Katalog-Keys tauchen in keiner Sicht mehr auf
  v_txt := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner'))::text
        || finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_kid2'))::text;
  IF v_txt ~ 'finance\.app\.depot\.(section_child|shares|shares_price|shares_date|shares_price_date|d_gain|price_stale|perf_child|perf_none|d_perf_value)"' THEN
    RAISE EXCEPTION 'FAIL [7i] entfernter Katalog-Key in der View'; END IF;
  IF jsonb_path_exists(finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner')), 'strict $.**.state ? (@ == "ok")') THEN
    RAISE EXCEPTION 'FAIL [7j] keine ok-Pille'; END IF;
  IF EXISTS (SELECT 1 FROM core.fn_app_view_lint(finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner')), '{}',
               ARRAY['finance.app.depot.price_missing', 'finance.app.depot.perf_fx_missing'])) THEN
    RAISE EXCEPTION 'FAIL [7k] Gestaltungsregeln (Kinder- und Eltern-Rendite auf einer Seite): %', (SELECT string_agg(l.rule || ' ' || l.path, ', ')
      FROM core.fn_app_view_lint(finance.fn_app_screen_depot(jsonb_build_object('person_id', 'apdp_owner')), '{}',
             ARRAY['finance.app.depot.price_missing', 'finance.app.depot.perf_fx_missing']) l); END IF;
  RAISE NOTICE 'PASS [7] Depots der Kinder: eine Zeile je Depot, Vermoegen-Wert, Pillen zuerst, Rendite + Positionen im Aufklappen, Summe ab zwei ohne gap, keine Geschwister';


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

-- ===== 8) Fixture-Haushalt (tests/util/util_app_household.sql): Gestaltungsregeln fuer alle Personen =====
BEGIN;
\ir ../../util/util_app_household.sql
DO $$
DECLARE
  v jsonb; v_pid text; v_sec jsonb; v_txt text;
BEGIN
  FOREACH v_pid IN ARRAY ARRAY['fxh_jonas', 'fxh_mira', 'fxh_lea', 'fxh_tom', 'fxh_gast'] LOOP
    v := finance.fn_app_screen_depot(jsonb_build_object('person_id', v_pid, 'params', '{}'::jsonb));
    IF EXISTS (SELECT 1 FROM core.fn_app_view_lint(v, '{}', ARRAY['finance.app.depot.price_missing', 'finance.app.depot.perf_fx_missing'])) THEN
      RAISE EXCEPTION 'FAIL [8a] Gestaltungsregeln fuer %: %', v_pid, (SELECT string_agg(l.rule || ' ' || l.path, ', ')
        FROM core.fn_app_view_lint(v, '{}', ARRAY['finance.app.depot.price_missing', 'finance.app.depot.perf_fx_missing']) l); END IF;
  END LOOP;
  -- Haushalt: Depot mit einer Position ohne Summe (B5), Kinder-Depots in einem Abschnitt (beide Kinder)
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'fxh_jonas', 'params', '{}'::jsonb));
  SELECT s INTO v_sec FROM jsonb_array_elements(v->'sections') s
   WHERE s->'title'->'params'->>'name' = (SELECT name FROM finance.accounts WHERE id = (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_depot_jonas'));
  IF jsonb_array_length(v_sec->'items') <> 1 OR jsonb_typeof(v_sec->'value') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [8b] Depot mit einer Position: keine Summe (B5), got %', v_sec; END IF;
  v_sec := v->'sections'->-1;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.depot.section_kids') OR jsonb_array_length(v_sec->'items') <> 2 THEN
    RAISE EXCEPTION 'FAIL [8c] „Depots der Kinder" mit beiden Kind-Depots, got %', v_sec; END IF;
  -- Kind: nur das eigene Depot, kein Kinder-Abschnitt, nichts vom Geschwister
  v_txt := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'fxh_lea', 'params', '{}'::jsonb))::text;
  IF v_txt LIKE '%finance.app.depot.section_kids%'
     OR v_txt LIKE '%' || (SELECT name FROM finance.accounts WHERE id = (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_depot_tom')) || '%'
     OR v_txt LIKE '%' || (SELECT name FROM finance.accounts WHERE id = (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_depot_jonas')) || '%' THEN
    RAISE EXCEPTION 'FAIL [8d] Lea sieht Fremdes oder einen Kinder-Abschnitt: %', v_txt; END IF;
  RAISE NOTICE 'PASS [8] Fixture-Haushalt: Gestaltungsregeln fuer alle Personen, Summenregel, Depots der Kinder, Kind-Sicht';
END $$;
ROLLBACK;
