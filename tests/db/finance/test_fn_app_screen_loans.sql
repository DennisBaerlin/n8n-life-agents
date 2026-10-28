-- tests/db/finance/test_fn_app_screen_loans.sql
-- finance.fn_app_screen_loans(p jsonb) — Mini-App-Bildschirm „Kredite“ (docs/package-contract.md §3.12, View-Modell v1).
--   1) Haushalt (owner = partner): ausstehende Kredite (active + paused, nie paid_off), Restschuld positiv in
--      Kontowaehrung, „Bank · Zins · Rate“, getilgt-Balken nur mit Kreditbetrag, Hero = Restschuld ohne Kinder-Kredite
--      (= Vermoegen „Kredite“) + Note Raten/Zins, Kinder-Kredit im eigenen Abschnitt, Details in fester Reihenfolge.
--      Pillen (warn vor neutral): Bindung endet in [heute, heute + 12 Monate) -> warn, auch pausiert; pausiert sonst neutral;
--      genau 12 Monate -> keine Warnung; abgelaufen -> warn „endete“; sonst „schuldenfrei {Jahr}“.
--   2) Kind: nur Kredite mit borrower_person_id = ich; Volltextsuche: kein Haushalts-/Partnerkredit, keine Kontonamen, kein *id.
--   3) probe -> {ok, empty, banners}: Banner nur fuer die bald endende Bindung (mit Restschuld zum Bindungsende), nicht
--      fuer pausiert/abgelaufen; volle View banners [].
--   4) Eingabe-Fehler -> bad_request; Frei-SQL -> forbidden; kein EXECUTE fuer *_ro.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_giro INT; v_l1 INT; v_l2 INT; v_l3 INT; v_l4 INT; v_l5 INT; v_l6 INT; v_l7 INT; v_l8 INT;
  v jsonb; v_txt text; v_it jsonb; v_keys text[];
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('apl_owner', 'Owner Beispiel', 'owner'), ('apl_partner', 'Partner Beispiel', 'partner'), ('apl_kid', 'Kind Beispiel', 'child');
  v_giro := (finance.fn_create_account('{"name":"__apl_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;

  v_l1 := (finance.fn_create_loan(jsonb_build_object('name', '__apl_haus__', 'lender', 'Bank', 'original_amount', 10000,
            'current_balance', 8000, 'interest_rate', 3.5, 'monthly_annuity', 300, 'first_payment_date', (t + 5)::text,
            'debit_account_id', v_giro, 'interest_rate_fixed_until', ((t + interval '12 months')::date - 1)::text))->>'loan_id')::int;
  v_l2 := (finance.fn_create_loan(jsonb_build_object('name', '<img src=x onerror=alert(1)>', 'lender', 'Bank',
            'borrower_person_id', 'apl_partner', 'current_balance', 2000, 'interest_rate', 2, 'monthly_annuity', 100,
            'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro,
            'interest_rate_fixed_until', (t + interval '3 years')::date::text))->>'loan_id')::int;
  v_l3 := (finance.fn_create_loan(jsonb_build_object('name', '__apl_kid_kredit__', 'lender', 'Oma',
            'borrower_person_id', 'apl_kid', 'current_balance', 500, 'interest_rate', 0, 'monthly_annuity', 50,
            'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro))->>'loan_id')::int;
  v_l4 := (finance.fn_create_loan(jsonb_build_object('name', '__apl_pausiert__', 'lender', 'Bank', 'current_balance', 1000,
            'interest_rate', 4, 'monthly_annuity', 100, 'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro,
            'interest_rate_fixed_until', (t + interval '2 months')::date::text))->>'loan_id')::int;
  v_l5 := (finance.fn_create_loan(jsonb_build_object('name', '__apl_abgelaufen__', 'lender', 'Bank', 'current_balance', 1500,
            'interest_rate', 4, 'monthly_annuity', 100, 'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro))->>'loan_id')::int;
  v_l6 := (finance.fn_create_loan(jsonb_build_object('name', '__apl_grenze__', 'lender', 'Bank', 'current_balance', 100,
            'interest_rate', 4, 'monthly_annuity', 50, 'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro,
            'interest_rate_fixed_until', (t + interval '12 months')::date::text))->>'loan_id')::int;
  v_l7 := (finance.fn_create_loan(jsonb_build_object('name', '__apl_bezahlt__', 'lender', 'Bank', 'current_balance', 700,
            'interest_rate', 4, 'monthly_annuity', 100, 'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro))->>'loan_id')::int;
  v_l8 := (finance.fn_create_loan(jsonb_build_object('name', '__apl_pause_frei__', 'lender', 'Bank', 'current_balance', 200,
            'interest_rate', 4, 'monthly_annuity', 50, 'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro))->>'loan_id')::int;
  IF v_l8 IS NULL OR v_l1 IS NULL OR v_l2 IS NULL OR v_l3 IS NULL OR v_l4 IS NULL OR v_l5 IS NULL OR v_l6 IS NULL OR v_l7 IS NULL THEN
    RAISE EXCEPTION 'SETUP FAIL Kredite anlegen'; END IF;
  UPDATE finance.loans SET status = 'paused' WHERE id IN (v_l4, v_l8);
  UPDATE finance.loans SET interest_rate_fixed_until = t - 30 WHERE id = v_l5;
  UPDATE finance.loans SET status = 'paid_off' WHERE id = v_l7;
  -- wie im echten Ablauf (die letzte Rate bringt die Restschuld auf 0, fn_mark_loan_paid_off)
  UPDATE finance.account_balances SET balance = 0 WHERE account_id = (SELECT loan_account_id FROM finance.loans WHERE id = v_l7);

  -- ===== 1) Haushalt =====
  v := finance.fn_app_screen_loans(jsonb_build_object('person_id', 'apl_owner', 'params', '{}'::jsonb));
  IF (v->>'ok')::boolean IS NOT TRUE OR v->'title' <> core.fn_ui_tpl('finance.app.loans.title')
     OR jsonb_array_length(v->'banners') <> 0 OR jsonb_array_length(v->'sections') <> 2 THEN
    RAISE EXCEPTION 'FAIL [1a] View-Modell v1 / volle View ohne Banner, Laufende + Kinder: %', v; END IF;
  -- Hero ohne paid_off und ohne Kinder-Kredit (500): 8000 + 2000 + 1000 + 1500 + 100 + 200
  IF v->'hero'->'value' <> core.fn_ui_money(12800, 'EUR') OR (v->'hero'->>'gap')::boolean
     OR v->'hero'->'label' <> core.fn_ui_tpl('finance.app.loans.hero') THEN
    RAISE EXCEPTION 'FAIL [1b] Hero 12800 (ohne paid_off, ohne Kind) erwartet: %', v->'hero'; END IF;
  -- Note: Raten der aktiven Haushalts-Kredite 300 + 100 + 100 + 50; Zins 23.33 + 3.33 + 5.00 + 0.33
  IF v->'hero'->'note' <> core.fn_ui_tpl('finance.app.loans.hero_note', jsonb_build_object(
       'rate', core.fn_ui_money(550, 'EUR'), 'interest', core.fn_ui_money(31.99, 'EUR'))) THEN
    RAISE EXCEPTION 'FAIL [1b2] Hero-Note Raten 550 · Zins 31.99, got %', v->'hero'->'note'; END IF;
  -- dieselbe Zahl wie die Vermoegen-Seite (Schulden -> Kredite)
  IF (SELECT (s->'items'->0->'value'->>'value')::numeric
        FROM jsonb_array_elements(finance.fn_app_screen_overview(jsonb_build_object('person_id', 'apl_owner'))->'sections') s
       WHERE s->'title' = core.fn_ui_tpl('finance.app.overview.section_debts')) IS DISTINCT FROM -12800 THEN
    RAISE EXCEPTION 'FAIL [1b3] Vermoegen „Kredite" muss = Kredit-Hero (-12800) sein'; END IF;
  IF jsonb_array_length(v->'sections'->0->'items') <> 6 OR v::text LIKE '%__apl_bezahlt__%' THEN
    RAISE EXCEPTION 'FAIL [1c] 6 ausstehende Haushalts-Kredite erwartet: %', v->'sections'; END IF;
  IF v->'sections'->1->'title' <> core.fn_ui_tpl('finance.app.loans.section_kids')
     OR v->'sections'->1->'value' <> core.fn_ui_money(500, 'EUR')
     OR v->'sections'->1->'items'->0->>'label' <> '__apl_kid_kredit__' THEN
    RAISE EXCEPTION 'FAIL [1c2] Kinder-Abschnitt mit Summe 500: %', v->'sections'->1; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->>'label' = '__apl_haus__';
  IF v_it->'value' <> core.fn_ui_money(8000, 'EUR') OR (v_it->'progress'->>'pct')::numeric IS DISTINCT FROM 20.0
     OR v_it->'sub' <> core.fn_ui_tpl('finance.app.loans.rate_line_lender', jsonb_build_object(
          'lender', 'Bank', 'rate', core.fn_ui_money(300, 'EUR'), 'interest', core.fn_ui_num(3.5, 2)))
     OR v_it->'pill'->>'state' <> 'warn' OR v_it->'pill'->>'icon' <> 'calendar'
     OR v_it->'pill'->'text' <> core.fn_ui_tpl('finance.app.loans.fixed_ends',
          jsonb_build_object('date', core.fn_ui_date((t + interval '12 months')::date - 1))) THEN
    RAISE EXCEPTION 'FAIL [1d] Haus-Kredit (Rest, 20 %% getilgt, Bank/Zins/Rate, warn 1 Tag vor 12 Monaten): %', v_it; END IF;
  SELECT array_agg(d->'label'->>'value' ORDER BY o) INTO v_keys FROM jsonb_array_elements(v_it->'details') WITH ORDINALITY AS t(d, o);
  IF v_keys IS DISTINCT FROM ARRAY['finance.app.loans.d_borrower', 'finance.app.loans.d_amount', 'finance.app.loans.d_repaid',
                                   'finance.app.loans.d_split', 'finance.app.loans.d_fixed', 'finance.app.loans.d_payoff',
                                   'finance.app.loans.d_interest_left'] THEN
    RAISE EXCEPTION 'FAIL [1d2] Details in fester Reihenfolge, NULL-Zeilen entfallen (kein Laufzeitende), got %', v_keys; END IF;
  IF v_it->'details'->0->'value' <> core.fn_ui_tpl('finance.app.common.joint')
     OR v_it->'details'->2->'value' <> core.fn_ui_tpl('finance.app.loans.d_repaid_value', jsonb_build_object(
          'pct', core.fn_ui_num(20.0, 1), 'amount', core.fn_ui_money(2000, 'EUR')))
     OR v_it->'details'->3->'value' <> core.fn_ui_tpl('finance.app.loans.d_split_value', jsonb_build_object(
          'interest', core.fn_ui_money(23.33, 'EUR'), 'principal', core.fn_ui_money(276.67, 'EUR')))
     OR v_it->'details'->5->'value' <> (SELECT core.fn_ui_date(payoff_date_projected) FROM finance.loan_overview WHERE id = v_l1) THEN
    RAISE EXCEPTION 'FAIL [1d3] Details: Gemeinsam, getilgt 20 %% · 2000, Zins 23.33 + Tilgung 276.67, schuldenfrei-Datum, got %', v_it->'details'; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->'label' = to_jsonb('<img src=x onerror=alert(1)>'::text);
  IF v_it IS NULL OR jsonb_typeof(v_it->'progress') <> 'null'
     OR v_it->'pill' <> jsonb_build_object('state', 'neutral', 'icon', 'calendar', 'text', core.fn_ui_tpl('finance.app.loans.payoff_year',
          jsonb_build_object('year', (SELECT to_char(payoff_date_projected, 'YYYY') FROM finance.loan_overview WHERE id = v_l2))))
     OR v_it->'details'->0->'value' <> to_jsonb('Partner Beispiel'::text) THEN
    RAISE EXCEPTION 'FAIL [1e] Partner-Kredit: Rohname, Pille „schuldenfrei Jahr" (Bindung in 3 Jahren), kein Balken ohne Kreditbetrag, Kreditnehmer: %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->>'label' = '__apl_pausiert__';
  IF v_it->'pill'->>'state' <> 'warn' THEN RAISE EXCEPTION 'FAIL [1f] pausiert + Bindung bald -> warn: %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->>'label' = '__apl_pause_frei__';
  IF v_it->'pill'->>'state' <> 'neutral' OR v_it->'pill'->>'icon' <> 'pause' OR v_it->'pill'->'text' <> core.fn_ui_tpl('finance.app.loans.paused') THEN
    RAISE EXCEPTION 'FAIL [1f2] pausiert ohne Bindung -> neutral pause: %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->>'label' = '__apl_abgelaufen__';
  IF v_it->'pill'->>'state' <> 'warn' OR v_it->'pill'->'text' <> core.fn_ui_tpl('finance.app.loans.fixed_ended',
       jsonb_build_object('date', core.fn_ui_date(t - 30))) THEN
    RAISE EXCEPTION 'FAIL [1g] abgelaufene Bindung -> warn „endete“: %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->>'label' = '__apl_grenze__';
  IF v_it->'pill'->'text'->>'value' <> 'finance.app.loans.payoff_year' THEN
    RAISE EXCEPTION 'FAIL [1h] genau 12 Monate -> keine Bindungs-Warnung (nur schuldenfrei): %', v_it; END IF;
  IF v::text ~ '"[a-z_]*id"\s*:' OR v::text LIKE '%__apl_giro__%' THEN
    RAISE EXCEPTION 'FAIL [1i] Antwort traegt ein *id-Feld oder einen Kontonamen'; END IF;
  IF finance.fn_app_screen_loans(jsonb_build_object('person_id', 'apl_partner', 'params', '{}'::jsonb)) <> v THEN
    RAISE EXCEPTION 'FAIL [1j] Partner = Haushalts-Sicht'; END IF;
  RAISE NOTICE 'PASS [1] Haushalt: Kredite, Hero, Pillen-Prioritaet, 12-Monats-Grenze';

  -- ===== 2) Kind =====
  v := finance.fn_app_screen_loans(jsonb_build_object('person_id', 'apl_kid', 'params', '{}'::jsonb));
  v_txt := v::text;
  IF jsonb_array_length(v->'sections') <> 1 OR jsonb_array_length(v->'sections'->0->'items') <> 1
     OR v->'sections'->0->'items'->0->>'label' <> '__apl_kid_kredit__'
     OR v->'hero'->'value' <> core.fn_ui_money(500, 'EUR')
     OR v::text LIKE '%finance.app.loans.d_borrower%' THEN
    RAISE EXCEPTION 'FAIL [2a] Kind sieht nur den eigenen Kredit (500): %', v; END IF;
  IF v_txt LIKE '%__apl_haus__%' OR v_txt LIKE '%onerror%' OR v_txt LIKE '%__apl_pausiert__%' OR v_txt LIKE '%__apl_giro__%'
     OR v_txt LIKE '%Bank%' OR v_txt ~ '"[a-z_]*id"\s*:' THEN
    RAISE EXCEPTION 'FAIL [2b] Kind-Antwort leckt: %', v_txt; END IF;
  RAISE NOTICE 'PASS [2] Kind sieht nur den eigenen Kredit';

  -- ===== 3) probe + Banner =====
  v := finance.fn_app_screen_loans('{"person_id":"apl_owner","params":{"probe":true}}');
  IF v->'banners'->0->'text'->'params'->>'name' <> '__apl_pausiert__' THEN RAISE EXCEPTION 'FAIL [3a0] fruehestes Bindungsende zuerst: %', v; END IF;
  v := jsonb_set(v, '{banners}', jsonb_build_array(v->'banners'->1));
  IF v->>'empty' <> 'false' OR jsonb_array_length(v->'banners') <> 1 OR v->'banners'->0->>'state' <> 'warn'
     OR v->'banners'->0->>'icon' <> 'calendar' OR v->'banners'->0->'target' <> '{"screen":"loans","params":{}}'::jsonb
     OR v->'banners'->0->'text'->>'value' <> 'finance.app.loans.banner_fixed_ends_rest'
     OR v->'banners'->0->'text'->'params'->>'name' <> '__apl_haus__'
     OR v->'banners'->0->'text'->'params'->'rest'->>'kind' <> 'money' THEN
    RAISE EXCEPTION 'FAIL [3a] genau ein warn-Banner fuer die bald endende Bindung mit Restschuld: %', v; END IF;
  v := finance.fn_app_screen_loans('{"person_id":"apl_kid","params":{"probe":true}}');
  IF v <> '{"ok":true,"empty":false,"banners":[]}'::jsonb THEN RAISE EXCEPTION 'FAIL [3b] Kind-probe: %', v; END IF;
  IF finance.fn_app_screen_loans('{"person_id":"apl_nobody","params":{"probe":true}}') <> '{"ok":true,"empty":true,"banners":[]}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [3c] unbekannte Person -> empty'; END IF;
  RAISE NOTICE 'PASS [3] probe: ein Banner (bald endende Bindung), Kind ohne, leer -> empty';

  IF finance.fn_app_screen_loans('{}') <> '{"ok":false,"code":"bad_request"}'::jsonb
     OR finance.fn_app_screen_loans(NULL) <> '{"ok":false,"code":"bad_request"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [4a] Muell -> bad_request'; END IF;
END $$;

DO $$
BEGIN
  IF has_function_privilege('finance_ro', 'finance.fn_app_screen_loans(jsonb)', 'EXECUTE')
     OR has_function_privilege('core_ro', 'finance.fn_app_screen_loans(jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [4b] Frei-SQL-Rolle hat EXECUTE auf den Bildschirm-Handler'; END IF;
  GRANT EXECUTE ON FUNCTION finance.fn_app_screen_loans(jsonb) TO finance_ro;
END $$;
SET LOCAL SESSION AUTHORIZATION finance_ro;
DO $$
BEGIN
  IF finance.fn_app_screen_loans('{"person_id":"apl_owner","params":{}}') <> '{"ok":false,"code":"forbidden"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [4c] Frei-SQL-Sitzung muss forbidden bekommen'; END IF;
  RAISE NOTICE 'PASS [4] Muell -> bad_request, kein EXECUTE fuer *_ro, Frei-SQL -> forbidden';
END $$;
RESET SESSION AUTHORIZATION;
ROLLBACK;
