-- tests/db/finance/test_fn_app_screen_payments.sql
-- finance.fn_app_screen_payments(p jsonb) — Mini-App-Bildschirm „Zahlungen“ (docs/package-contract.md §3.12, View-Modell v1).
--   1) Haushalt (owner = partner): kommende Zahlungen [heute, heute + app_payments_days] mit Rohname, Konto, Ziel; Hero =
--      Abgaenge ohne Uebertraege in EUR; Kontovorschau nur fuer Konten mit Kontoauszug (fn_coverage_accounts), Ampel
--      alert (unter Puffer) / warn (unter coverage_warn_factor x Puffer) / ok / neutral + gap (Waehrung ohne Kurs).
--   2) Kind: nur Zahlungen vom eigenen Konto (Ziel-Haushaltskonto neutral) + Uebertraege AUF das eigene Konto neutral
--      („vom Haushalt“, ohne Namen der Zahlung); Volltextsuche ueber die ganze Antwort: kein Haushalts-/Partnername, kein
--      Name einer Eltern-Zahlung, kein *id-Feld, kein Umbuchungs-Vorschlag.
--   3) probe -> {ok, empty, banners}: alert vor warn, Vorschlag nur fuer den Haushalt, kein Banner fuer neutral/ok; volle
--      View traegt banners []. Leere Person -> empty.
--   4) Eingabe-Fehler -> bad_request ohne RAISE; Frei-SQL-Sitzung -> forbidden; kein EXECUTE fuer *_ro.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_giro INT; v_tg INT; v_warn INT; v_ok INT; v_chf INT; v_kid INT; v_p INT; v_p2p INT;
  v jsonb; v_txt text; v_sec jsonb; v_b jsonb; v_t0 timestamptz;
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('apy_owner', 'Owner Beispiel', 'owner'), ('apy_partner', 'Partner Beispiel', 'partner'), ('apy_kid', 'Kind Beispiel', 'child');

  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id) VALUES
    ('__apy_hh_giro__', 'cash', 'EUR', 'active', NULL) RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id) VALUES
    ('__apy_hh_tg__', 'cash', 'EUR', 'active', NULL) RETURNING id INTO v_tg;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id) VALUES
    ('__apy_hh_warn__', 'cash', 'EUR', 'active', NULL) RETURNING id INTO v_warn;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id) VALUES
    ('__apy_hh_ok__', 'cash', 'EUR', 'active', NULL) RETURNING id INTO v_ok;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id) VALUES
    ('__apy_hh_chf__', 'cash', 'CHF', 'active', NULL) RETURNING id INTO v_chf;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id) VALUES
    ('__apy_p_cash__', 'cash', 'EUR', 'active', 'apy_partner') RETURNING id INTO v_p;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id) VALUES
    ('__apy_kid_cash__', 'cash', 'EUR', 'active', 'apy_kid') RETURNING id INTO v_kid;
  -- P2P mit eigenem Auszug: keine Vorschau (nur Giro/Tagesgeld), der Grund ist die Kontoart, nicht "kein Auszug"
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id) VALUES
    ('__apy_hh_p2p__', 'p2p', 'EUR', 'active', NULL) RETURNING id INTO v_p2p;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES
    (v_giro, 1000, t - 40, 'other'), (v_tg, 5000, t - 40, 'other'), (v_warn, 400, t - 40, 'other'),
    (v_ok, 3000, t - 40, 'other'), (v_chf, 700, t - 40, 'other'), (v_p, 900, t - 40, 'other'), (v_kid, 100, t - 40, 'other');
  UPDATE finance.accounts SET last_reconciled_at = t - 5 WHERE id IN (v_giro, v_warn, v_ok, v_chf, v_kid);
  -- Kontoauszuege: Giro mit 10 Alltag je Tag (wie test_fn_account_outlook), die anderen ohne Alltagsausgaben
  -- Giro juengster: -500 ungematcht, davon -300 einmalig (Grenze 250) -> zaehlt -200 / 20 Tage = 10/Tag
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at,
                                       oneoff_out, oneoff_threshold)
  VALUES (v_giro, t - 64, t - 35, 1600, 1300, 'EUR', 5, 0, -300, 0, NULL, 0, NULL),
         (v_giro, t - 34, t - 5, 1300, 1000, 'EUR', 5, 0, -500, 0, t - 25, -300, 250),
         (v_warn, t - 34, t - 5, 400, 400, 'EUR', 1, 0, 0, 0, NULL, 0, NULL),
         (v_ok,   t - 34, t - 5, 3000, 3000, 'EUR', 1, 0, 0, 0, NULL, 0, NULL),
         (v_chf,  t - 34, t - 5, 700, 700, 'CHF', 1, 0, 0, 0, NULL, 0, NULL),
         (v_kid,  t - 34, t - 5, 100, 100, 'EUR', 1, 0, 0, 0, NULL, 0, NULL),
         (v_p2p,  t - 34, t - 5, 900, 900, 'EUR', 1, 0, 0, 0, NULL, 0, NULL);
  PERFORM finance.fn_add_recurring_payment(v_p2p, -30, '__apy_p2p_gebuehr__', 30::smallint, 'day'::finance.schedule_unit, NULL, t + 7, t + 7, NULL, NULL, NULL);
  PERFORM finance.fn_add_recurring_payment(v_giro, -800, '__apy_miete__', 30::smallint, 'day'::finance.schedule_unit, NULL, t + 3, t + 3, NULL, NULL, NULL);
  PERFORM finance.fn_add_recurring_payment(v_giro, 2000, '__apy_gehalt__', 30::smallint, 'day'::finance.schedule_unit, NULL, t + 10, t + 10, NULL, NULL, NULL);
  PERFORM finance.fn_add_recurring_payment(v_giro, -15, '<img src=x onerror=alert(1)>', 30::smallint, 'day'::finance.schedule_unit, NULL, t + 1, t + 1, NULL, NULL, NULL);
  PERFORM finance.fn_add_recurring_payment(v_p, -40, '__apy_p_abo__', 30::smallint, 'day'::finance.schedule_unit, NULL, t + 5, t + 5, NULL, NULL, NULL);
  PERFORM finance.fn_add_recurring_payment(v_kid, -5, '__apy_kid_abo__', 30::smallint, 'day'::finance.schedule_unit, NULL, t + 4, t + 4, NULL, NULL, NULL);
  PERFORM finance.fn_add_recurring_payment(v_giro, -60, '__apy_spaet__', 30::smallint, 'day'::finance.schedule_unit, NULL, t + 31, t + 31, NULL, NULL, NULL);
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit,
                                          first_payment_date, valid_from)
  VALUES ('__apy_geheim_taschengeld__', v_giro, v_kid, -20, 30, 'day', t + 2, t + 2),
         ('__apy_kid_spart__', v_kid, v_tg, -10, 30, 'day', t + 6, t + 6);

  -- ===== 1) Haushalt: ein Abschnitt je Konto (Transparenz 2026-10-30) =====
  -- Vorschau-Konten (mit Auszug) als Bruecke Stand -> feste Ab-/Eingaenge -> Alltag -> Tief -> Puffer -> Geldeingang,
  -- Reihenfolge alert -> warn -> ok -> neutral, dann Name; danach Konten ohne Auszug mit Zahlungen im Fenster.
  v := finance.fn_app_screen_payments(jsonb_build_object('person_id', 'apy_owner', 'params', '{}'::jsonb));
  IF (v->>'ok')::boolean IS NOT TRUE OR NOT (v ? 'title' AND v ? 'hero' AND v ? 'banners' AND v ? 'sections') THEN
    RAISE EXCEPTION 'FAIL [1a] View-Modell v1: %', v; END IF;
  IF v->'title' <> core.fn_ui_tpl('finance.app.payments.title') OR jsonb_array_length(v->'banners') <> 0
     OR jsonb_array_length(v->'sections') <> 8 THEN
    RAISE EXCEPTION 'FAIL [1b] Titel / volle View ohne Banner / 8 Abschnitte (5 Vorschau + P2P + Tagesgeld mit Eingang + Partnerkonto): %', v; END IF;
  -- Hero: Abgaenge ohne Uebertraege in 30 Tagen: Miete -800, XSS -15, Partner-Abo -40, Kind-Abo -5, P2P -30 (spaet t+31 draussen),
  -- positiv (das Label sagt Abgaenge)
  IF v->'hero'->'value' <> core.fn_ui_money(890, 'EUR') OR (v->'hero'->>'gap')::boolean THEN
    RAISE EXCEPTION 'FAIL [1c] Hero 890 EUR ohne gap erwartet: %', v->'hero'; END IF;
  IF ARRAY(SELECT s->'title'->'params'->>'account' FROM jsonb_array_elements(v->'sections') s)
     <> ARRAY['__apy_hh_giro__', '__apy_kid_cash__', '__apy_hh_warn__', '__apy_hh_ok__', '__apy_hh_chf__', '__apy_hh_p2p__', '__apy_hh_tg__', '__apy_p_cash__'] THEN
    RAISE EXCEPTION 'FAIL [1d] Reihenfolge alert (Name) -> warn -> ok -> neutral -> ohne Auszug: %', v->'sections'; END IF;

  -- Giro: Stand 1000 (bestaetigt t-5), feste Abgaenge bis zum Tief t+9: XSS -15, Taschengeld -20, Miete -800;
  -- Alltag 10/Tag x 14 Tage = -140 (fruehester Auszug zaehlt nicht); Tief 25; Geldeingang Gehalt +2000 am t+10
  v_sec := v->'sections'->0;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.payments.section_account', jsonb_build_object('account', '__apy_hh_giro__'))
     OR jsonb_typeof(v_sec->'value') <> 'null' OR v_sec->'items'->0->'label' <> core.fn_ui_tpl('finance.app.payments.b_low') THEN
    RAISE EXCEPTION 'FAIL [1e] Giro-Abschnitt: Titel, kein Abschnittswert, Tief als erste Zeile: %', v_sec; END IF;
  SELECT i INTO v_b FROM jsonb_array_elements(v_sec->'items') i WHERE i->'label'->>'value' = 'finance.app.payments.b_start';
  IF v_b->'value' <> core.fn_ui_money(1000, 'EUR') THEN RAISE EXCEPTION 'FAIL [1f] Startstand 1000: %', v_b; END IF;
  SELECT i INTO v_b FROM jsonb_array_elements(v_sec->'items') i WHERE i->'label'->>'value' = 'finance.app.payments.b_out';
  IF v_b->'value' <> core.fn_ui_money(-835, 'EUR') OR jsonb_array_length(v_b->'details') <> 3
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_b->'details') d WHERE d->'label' = to_jsonb('<img src=x onerror=alert(1)>'::text)
                      AND d->'value' = core.fn_ui_tpl('finance.app.payments.d_payment',
                            jsonb_build_object('date', core.fn_ui_date(t + 1), 'amount', core.fn_ui_money(-15, 'EUR')))) THEN
    RAISE EXCEPTION 'FAIL [1g] feste Abgaenge -835 mit 3 Einzelzahlungen (Rohname, Datum, Betrag): %', v_b; END IF;
  SELECT i INTO v_b FROM jsonb_array_elements(v_sec->'items') i WHERE i->'label'->>'value' = 'finance.app.payments.b_everyday';
  IF v_b->'value' <> core.fn_ui_money(-140, 'EUR') OR v_b->'sub'->>'value' <> 'finance.app.payments.b_everyday_sub'
     OR jsonb_array_length(v_b->'details') <> 3
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_b->'details') d
                     WHERE d->'value'->>'value' = 'finance.app.payments.d_rate_earliest') THEN
    RAISE EXCEPTION 'FAIL [1h] Alltag -140, je Auszug aufklappbar, fruehester markiert: %', v_b; END IF;
  -- einmalige Grossausgaben des Auszugs: eigene Details-Zeile direkt nach seiner Rate (Summe + Grenze)
  IF v_b->'details'->1 IS DISTINCT FROM jsonb_build_object(
         'label', core.fn_ui_tpl('finance.app.payments.d_oneoff'),
         'value', core.fn_ui_tpl('finance.app.payments.d_oneoff_value', jsonb_build_object(
                      'amount', core.fn_ui_money(300, 'EUR'), 'threshold', core.fn_ui_money(250, 'EUR')))) THEN
    RAISE EXCEPTION 'FAIL [1h2] Details-Zeile einmalig 300 (ohne Vorzeichen) ab 250: %', v_b->'details'; END IF;
  SELECT i INTO v_b FROM jsonb_array_elements(v_sec->'items') i WHERE i->'label'->>'value' = 'finance.app.payments.b_low';
  IF v_b->'value' <> core.fn_ui_money(25, 'EUR') OR v_b->'pill'->>'state' <> 'alert' OR v_b->'pill'->>'icon' <> 'alert' THEN
    RAISE EXCEPTION 'FAIL [1i] Tief 25 mit alert-Pille: %', v_b; END IF;
  SELECT i INTO v_b FROM jsonb_array_elements(v_sec->'items') i WHERE i->'label'->>'value' = 'finance.app.payments.b_buffer';
  IF v_b->'value' <> core.fn_ui_money(250, 'EUR') OR v_b->'sub'->>'value' <> 'finance.app.payments.b_buffer_default' THEN
    RAISE EXCEPTION 'FAIL [1j] Puffer 250 (Standard): %', v_b; END IF;
  SELECT i INTO v_b FROM jsonb_array_elements(v_sec->'items') i WHERE i->'label'->>'value' = 'finance.app.payments.b_income';
  IF v_b->'label'->'params'->>'name' <> '__apy_gehalt__' OR v_b->'value' <> core.fn_ui_money(2000, 'EUR', true) THEN
    RAISE EXCEPTION 'FAIL [1k] Geldeingang mit Name (Haushalt) und Betrag: %', v_b; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->'label'->>'value' = 'finance.app.payments.b_suggest' AND i->'label'->'params'->>'from' = '__apy_hh_tg__') THEN
    RAISE EXCEPTION 'FAIL [1l] Umbuchungs-Vorschlag im Giro-Abschnitt: %', v_sec; END IF;
  -- Konto mit Fremdwaehrung ohne Kurs: neutral + gap am Tief; Konto ohne Auszug: Zahlungen + Hinweis, keine Bruecke
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections'->4->'items') i
                  WHERE i->'label'->>'value' = 'finance.app.payments.b_low' AND i->'pill'->>'state' = 'neutral' AND (i->>'gap')::boolean)
     OR v->'sections'->2->'items' @? '$[*] ? (@.label.value == "finance.app.payments.b_low" && @.pill.state != "warn")'
     OR v->'sections'->3->'items' @? '$[*] ? (@.label.value == "finance.app.payments.b_low" && @.pill.state != "ok")' THEN
    RAISE EXCEPTION 'FAIL [1m] Ampel warn/ok/neutral+gap: %', v->'sections'; END IF;
  -- Konto ok: nur das Ergebnis (+ ggf. Zahlungen bis Fensterende), die Bruecke steckt im Aufklappen der Tief-Zeile
  v_sec := v->'sections'->3;
  IF jsonb_array_length(v_sec->'items') > 2 OR v_sec->'items'->0->'label' <> core.fn_ui_tpl('finance.app.payments.b_low')
     OR NOT (v_sec->'items'->0->'details' @? '$[*] ? (@.label.value == "finance.app.payments.b_start")')
     OR NOT (v_sec->'items'->0->'details' @? '$[*] ? (@.label.value == "finance.app.payments.b_buffer_kv")') THEN
    RAISE EXCEPTION 'FAIL [1m2] ok-Konto zugeklappt (Tief + Bruecke im Aufklappen): %', v_sec; END IF;
  v_sec := v->'sections'->5;
  IF v_sec->'note' <> core.fn_ui_tpl('finance.app.payments.no_outlook_type')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apy_p2p_gebuehr__') THEN
    RAISE EXCEPTION 'FAIL [1n0] P2P mit Auszug: Grund Kontoart statt "kein Auszug": %', v_sec; END IF;
  -- Bugfix 2026-10-30: eigener Uebertrag Kind -> Tagesgeld erscheint beim Ziel als Eingang (+10), nicht nur bei der Quelle
  v_sec := v->'sections'->6;
  IF v_sec->'note' <> core.fn_ui_tpl('finance.app.payments.no_outlook') OR v_sec->'value' <> core.fn_ui_money(10, 'EUR', true)
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apy_kid_spart__'
                      AND i->'value' = core.fn_ui_money(10, 'EUR', true)) THEN
    RAISE EXCEPTION 'FAIL [1n1] Tagesgeld: Eingang aus eigenem Uebertrag: %', v_sec; END IF;
  v_sec := v->'sections'->7;
  IF v_sec->'note' <> core.fn_ui_tpl('finance.app.payments.no_outlook') OR v_sec->'value' <> core.fn_ui_money(-40, 'EUR')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apy_p_abo__'
                      AND i->'sub' = core.fn_ui_tpl('finance.app.payments.due_on', jsonb_build_object('date', core.fn_ui_date(t + 5)))) THEN
    RAISE EXCEPTION 'FAIL [1n] Konto ohne Auszug: Hinweis + Zahlungen + Summe: %', v_sec; END IF;
  IF v::text ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [1o] Antwort traegt ein *id-Feld'; END IF;
  IF finance.fn_app_screen_payments(jsonb_build_object('person_id', 'apy_partner', 'params', '{}'::jsonb)) <> v THEN
    RAISE EXCEPTION 'FAIL [1p] Partner muss dieselbe Haushalts-Sicht bekommen'; END IF;
  RAISE NOTICE 'PASS [1] Haushalt: Abschnitt je Konto, Bruecke mit Details, Ampel, Konten ohne Auszug; Partner = Owner';

  -- ===== 2) Kind: nur das eigene Konto; Herkunft verborgener Konten neutral, kein Name (auch nicht in details) =====
  v := finance.fn_app_screen_payments(jsonb_build_object('person_id', 'apy_kid', 'params', '{}'::jsonb));
  v_txt := v::text;
  IF strpos(v_txt, '__apy_hh_') > 0 OR strpos(v_txt, '__apy_p_') > 0 OR strpos(v_txt, '__apy_geheim') > 0
     OR strpos(v_txt, '__apy_miete__') > 0 OR strpos(v_txt, 'onerror') > 0 OR strpos(v_txt, 'suggest') > 0
     OR strpos(v_txt, '__apy_gehalt__') > 0 THEN
    RAISE EXCEPTION 'FAIL [2a] Kind-Antwort leckt Haushalt/Partner/Vorschlag: %', v_txt; END IF;
  IF v_txt ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [2a2] Kind-Antwort traegt ein *id-Feld: %', v_txt; END IF;
  IF v->'hero'->'value' <> core.fn_ui_money(5, 'EUR') THEN RAISE EXCEPTION 'FAIL [2b] Kind-Hero 5: %', v->'hero'; END IF;
  IF jsonb_array_length(v->'sections') <> 1 OR v->'sections'->0->'title'->'params'->>'account' <> '__apy_kid_cash__' THEN
    RAISE EXCEPTION 'FAIL [2c] Kind: nur der eigene Konto-Abschnitt: %', v->'sections'; END IF;
  -- alle Zeilen + aufgeklappten Details des Abschnitts
  SELECT jsonb_agg(x) INTO v_sec FROM (
    SELECT i AS x FROM jsonb_array_elements(v->'sections'->0->'items') i
    UNION ALL SELECT d FROM jsonb_array_elements(v->'sections'->0->'items') i,
                            jsonb_array_elements(COALESCE(i->'details', '[]'::jsonb)) d) q;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec) e
                  WHERE e->'label' = core.fn_ui_tpl('finance.app.payments.from_household')
                    AND e->'value' = core.fn_ui_tpl('finance.app.payments.d_payment',
                          jsonb_build_object('date', core.fn_ui_date(t + 2), 'amount', core.fn_ui_money(20, 'EUR', true)))) THEN
    RAISE EXCEPTION 'FAIL [2d] Taschengeld muss neutral „vom Haushalt“ +20 erscheinen: %', v_sec; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec) e WHERE e->>'label' = '__apy_kid_spart__') THEN
    RAISE EXCEPTION 'FAIL [2e] eigener Uebertrag des Kindes erscheint: %', v_sec; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec) e
                  WHERE e->'label' = core.fn_ui_tpl('finance.app.payments.b_income_anon')) THEN
    RAISE EXCEPTION 'FAIL [2f] Geldeingang aus verborgenem Konto ohne Namen: %', v_sec; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec) e
                  WHERE e->'label'->>'value' = 'finance.app.payments.b_low' AND e->'pill'->>'state' = 'alert') THEN
    RAISE EXCEPTION 'FAIL [2g] Kind-Tief alert: %', v_sec; END IF;
  RAISE NOTICE 'PASS [2] Kind sieht nur Eigenes, Taschengeld + Geldeingang neutral, kein Leck (auch nicht in details)';

  -- ===== 3) probe + Banner =====
  v_t0 := clock_timestamp();
  v := finance.fn_app_screen_payments('{"person_id":"apy_owner","params":{"probe":true}}');
  RAISE NOTICE 'INFO probe Haushalt (5 Vorschau-Konten): % ms', round(extract(epoch FROM clock_timestamp() - v_t0) * 1000);
  IF v->>'ok' <> 'true' OR v->>'empty' <> 'false' OR jsonb_array_length(v->'banners') <> 3 THEN
    RAISE EXCEPTION 'FAIL [3a] Haushalt-probe: 3 Banner erwartet: %', v; END IF;
  IF v->'banners'->0->>'state' <> 'alert' OR v->'banners'->1->>'state' <> 'alert' OR v->'banners'->2->>'state' <> 'warn'
     OR v->'banners'->2->>'icon' <> 'clock' OR v->'banners'->0->'target' <> '{"screen":"payments","params":{}}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [3b] alert vor warn, icon, Ziel payments: %', v->'banners'; END IF;
  SELECT b INTO v_b FROM jsonb_array_elements(v->'banners') b WHERE b->'text'->'params'->>'account' = '__apy_hh_giro__';
  IF v_b->'text'->>'value' <> 'finance.app.payments.banner_short_suggest'
     OR v_b->'text'->'params'->>'from' <> '__apy_hh_tg__' OR v_b->'text'->'params'->'amount'->>'kind' <> 'money' THEN
    RAISE EXCEPTION 'FAIL [3c] Haushalt-Banner mit Umbuchungs-Vorschlag: %', v_b; END IF;
  v := finance.fn_app_screen_payments('{"person_id":"apy_kid","params":{"probe":true}}');
  IF jsonb_array_length(v->'banners') <> 1 OR v->'banners'->0->'text'->>'value' <> 'finance.app.payments.banner_short'
     OR v::text LIKE '%__apy_hh_%' THEN
    RAISE EXCEPTION 'FAIL [3d] Kind-Banner ohne Vorschlag: %', v; END IF;
  IF finance.fn_app_screen_payments('{"person_id":"apy_nobody","params":{"probe":true}}') <> '{"ok":true,"empty":true,"banners":[]}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [3e] unbekannte Person -> empty'; END IF;
  RAISE NOTICE 'PASS [3] probe: Banner alert vor warn, Vorschlag nur Haushalt; leer -> empty';

  -- ===== 4) Eingabe-Fehler =====
  IF finance.fn_app_screen_payments('{}') <> '{"ok":false,"code":"bad_request"}'::jsonb
     OR finance.fn_app_screen_payments(NULL) <> '{"ok":false,"code":"bad_request"}'::jsonb
     OR finance.fn_app_screen_payments('{"person_id":7}') <> '{"ok":false,"code":"bad_request"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [4a] Muell -> bad_request ohne RAISE'; END IF;
  RAISE NOTICE 'PASS [4a] Muell -> bad_request';
END $$;

DO $$
BEGIN
  IF has_function_privilege('finance_ro', 'finance.fn_app_screen_payments(jsonb)', 'EXECUTE')
     OR has_function_privilege('core_ro', 'finance.fn_app_screen_payments(jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [4b] Frei-SQL-Rolle hat EXECUTE auf den Bildschirm-Handler'; END IF;
  GRANT EXECUTE ON FUNCTION finance.fn_app_screen_payments(jsonb) TO finance_ro;
END $$;
SET LOCAL SESSION AUTHORIZATION finance_ro;
DO $$
BEGIN
  IF finance.fn_app_screen_payments('{"person_id":"apy_owner","params":{}}') <> '{"ok":false,"code":"forbidden"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [4c] Frei-SQL-Sitzung muss forbidden bekommen'; END IF;
  RAISE NOTICE 'PASS [4] kein EXECUTE fuer *_ro; Frei-SQL-Sitzung -> forbidden';
END $$;
RESET SESSION AUTHORIZATION;
ROLLBACK;
