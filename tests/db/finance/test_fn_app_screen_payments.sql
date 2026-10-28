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
  v_giro INT; v_tg INT; v_warn INT; v_ok INT; v_chf INT; v_kid INT; v_p INT;
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
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES
    (v_giro, 1000, t - 40, 'other'), (v_tg, 5000, t - 40, 'other'), (v_warn, 400, t - 40, 'other'),
    (v_ok, 3000, t - 40, 'other'), (v_chf, 700, t - 40, 'other'), (v_p, 900, t - 40, 'other'), (v_kid, 100, t - 40, 'other');
  UPDATE finance.accounts SET last_reconciled_at = t - 5 WHERE id IN (v_giro, v_warn, v_ok, v_chf, v_kid);
  -- Kontoauszuege: Giro mit 10 Alltag je Tag (wie test_fn_account_outlook), die anderen ohne Alltagsausgaben
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_giro, t - 64, t - 35, 1600, 1300, 'EUR', 5, 0, -300, 0, NULL),
         (v_giro, t - 34, t - 5, 1300, 1000, 'EUR', 5, 0, -200, 0, t - 25),
         (v_warn, t - 34, t - 5, 400, 400, 'EUR', 1, 0, 0, 0, NULL),
         (v_ok,   t - 34, t - 5, 3000, 3000, 'EUR', 1, 0, 0, 0, NULL),
         (v_chf,  t - 34, t - 5, 700, 700, 'CHF', 1, 0, 0, 0, NULL),
         (v_kid,  t - 34, t - 5, 100, 100, 'EUR', 1, 0, 0, 0, NULL);
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

  -- ===== 1) Haushalt =====
  v := finance.fn_app_screen_payments(jsonb_build_object('person_id', 'apy_owner', 'params', '{}'::jsonb));
  IF (v->>'ok')::boolean IS NOT TRUE OR NOT (v ? 'title' AND v ? 'hero' AND v ? 'banners' AND v ? 'sections') THEN
    RAISE EXCEPTION 'FAIL [1a] View-Modell v1: %', v; END IF;
  IF v->'title' <> core.fn_ui_tpl('finance.app.payments.title') OR jsonb_array_length(v->'banners') <> 0
     OR jsonb_array_length(v->'sections') <> 2 THEN
    RAISE EXCEPTION 'FAIL [1b] Titel / volle View ohne Banner / 2 Abschnitte: %', v; END IF;
  -- Hero: Abgaenge ohne Uebertraege in 30 Tagen: Miete -800, XSS -15, Partner-Abo -40, Kind-Abo -5 (spaet t+31 draussen)
  IF v->'hero'->'value' <> core.fn_ui_money(-860, 'EUR') OR (v->'hero'->>'gap')::boolean THEN
    RAISE EXCEPTION 'FAIL [1c] Hero -860 EUR ohne gap erwartet: %', v->'hero'; END IF;
  v_sec := v->'sections'->0;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.payments.section_upcoming') THEN RAISE EXCEPTION 'FAIL [1d] Abschnitt 1'; END IF;
  IF jsonb_array_length(v_sec->'items') <> 7 THEN RAISE EXCEPTION 'FAIL [1e] 7 Zahlungen erwartet, got %', v_sec; END IF;
  IF v_sec->'items'->0->'label' <> to_jsonb('<img src=x onerror=alert(1)>'::text)
     OR v_sec->'items'->0->'sub' <> core.fn_ui_tpl('finance.app.payments.due',
          jsonb_build_object('date', core.fn_ui_date(t + 1), 'account', '__apy_hh_giro__'))
     OR v_sec->'items'->0->'value' <> core.fn_ui_money(-15, 'EUR') THEN
    RAISE EXCEPTION 'FAIL [1f] erste Zahlung (t+1, Rohname, Konto, Betrag): %', v_sec->'items'->0; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apy_geheim_taschengeld__' AND i->'value' = core.fn_ui_money(-20, 'EUR')
                    AND i->'sub' = core.fn_ui_tpl('finance.app.payments.due_to', jsonb_build_object(
                          'date', core.fn_ui_date(t + 2), 'account', '__apy_hh_giro__', 'to', '__apy_kid_cash__'))) THEN
    RAISE EXCEPTION 'FAIL [1g] Haushalt sieht den Uebertrag mit Namen und Ziel: %', v_sec; END IF;
  -- Kontovorschau: Giro alert, Kind alert, warn, ok, CHF neutral + gap (Partner-/Tagesgeldkonto ohne Auszug fehlen)
  v_sec := v->'sections'->1;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.payments.section_outlook') OR jsonb_array_length(v_sec->'items') <> 5 THEN
    RAISE EXCEPTION 'FAIL [1h] Kontovorschau 5 Konten mit Auszug erwartet: %', v_sec; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apy_hh_giro__'
                   AND i->'pill'->>'state' = 'alert' AND i->'pill'->>'icon' = 'alert'
                   AND i->'sub'->>'value' = 'finance.app.payments.low_point')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apy_hh_warn__'
                   AND i->'pill'->>'state' = 'warn' AND i->'value' = core.fn_ui_money(400, 'EUR'))
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apy_hh_ok__'
                   AND i->'pill'->>'state' = 'ok' AND i->'pill'->>'icon' = 'check')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apy_hh_chf__'
                   AND i->'pill'->>'state' = 'neutral' AND (i->>'gap')::boolean AND i->'value' = core.fn_ui_money(700, 'CHF')) THEN
    RAISE EXCEPTION 'FAIL [1i] Ampel alert/warn/ok/neutral+gap: %', v_sec; END IF;
  IF v::text ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [1j] Antwort traegt ein *id-Feld'; END IF;
  IF finance.fn_app_screen_payments(jsonb_build_object('person_id', 'apy_partner', 'params', '{}'::jsonb)) <> v THEN
    RAISE EXCEPTION 'FAIL [1k] Partner muss dieselbe Haushalts-Sicht bekommen'; END IF;
  RAISE NOTICE 'PASS [1] Haushalt: Zahlungen, Hero, Kontovorschau mit Ampel; Partner = Owner';

  -- ===== 2) Kind =====
  v := finance.fn_app_screen_payments(jsonb_build_object('person_id', 'apy_kid', 'params', '{}'::jsonb));
  v_txt := v::text;
  IF strpos(v_txt, '__apy_hh_') > 0 OR strpos(v_txt, '__apy_p_') > 0 OR strpos(v_txt, '__apy_geheim') > 0
     OR strpos(v_txt, '__apy_miete__') > 0 OR strpos(v_txt, 'onerror') > 0 OR strpos(v_txt, 'suggest') > 0 THEN
    RAISE EXCEPTION 'FAIL [2a] Kind-Antwort leckt Haushalt/Partner/Vorschlag: %', v_txt; END IF;
  IF v_txt ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [2a2] Kind-Antwort traegt ein *id-Feld: %', v_txt; END IF;
  IF v->'hero'->'value' <> core.fn_ui_money(-5, 'EUR') THEN RAISE EXCEPTION 'FAIL [2b] Kind-Hero -5: %', v->'hero'; END IF;
  v_sec := v->'sections'->0;
  IF jsonb_array_length(v_sec->'items') <> 3 THEN RAISE EXCEPTION 'FAIL [2c] Kind: 3 Zahlungen erwartet: %', v_sec; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->'label' = core.fn_ui_tpl('finance.app.payments.from_household')
                    AND i->'value' = core.fn_ui_money(20, 'EUR')
                    AND i->'sub' = core.fn_ui_tpl('finance.app.payments.due', jsonb_build_object(
                          'date', core.fn_ui_date(t + 2), 'account', '__apy_kid_cash__'))) THEN
    RAISE EXCEPTION 'FAIL [2d] Taschengeld muss neutral „vom Haushalt“ +20 aufs eigene Konto erscheinen: %', v_sec; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apy_kid_spart__'
                    AND i->'sub' = core.fn_ui_tpl('finance.app.payments.due_to', jsonb_build_object(
                          'date', core.fn_ui_date(t + 6), 'account', '__apy_kid_cash__',
                          'to', core.fn_ui_tpl('finance.app.payments.household')))) THEN
    RAISE EXCEPTION 'FAIL [2e] Uebertrag des Kindes an ein Haushaltskonto: Ziel neutral: %', v_sec; END IF;
  IF jsonb_array_length(v->'sections'->1->'items') <> 1
     OR v->'sections'->1->'items'->0->>'label' <> '__apy_kid_cash__' OR v->'sections'->1->'items'->0->'pill'->>'state' <> 'alert' THEN
    RAISE EXCEPTION 'FAIL [2f] Kind-Vorschau nur eigenes Konto, alert: %', v->'sections'->1; END IF;
  RAISE NOTICE 'PASS [2] Kind sieht nur Eigenes, Taschengeld neutral, kein Leck';

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
