-- tests/db/finance/test_fn_app_screen_loans.sql
-- finance.fn_app_screen_loans(p jsonb) — Mini-App-Bildschirm „Kredite“ (docs/package-contract.md §3.12, View-Modell v1).
--   1) Haushalt (owner = partner): ausstehende Kredite (active + paused, nie paid_off), Restschuld positiv in
--      Kontowaehrung, „Bank · Zins · Rate“, getilgt-Balken nur mit Kreditbetrag, Hero = Restschuld ohne Kinder-Kredite
--      (= Vermoegen „Kredite“) + Note Raten/Zins, Kinder-Kredite im Abschnitt „Kredite der Kinder" (Summe erst ab zwei
--      Krediten, nicht bei fehlendem Wechselkurs), Details in fester Reihenfolge (hoechstens 8), nirgends eine ok-Pille.
--      Pillen (warn vor neutral): Bindung endet in [heute, heute + 12 Monate) -> warn, auch pausiert; pausiert sonst neutral;
--      genau 12 Monate -> keine Warnung; abgelaufen -> warn „endete“ (Detail-Label bleibt „Zinsbindung bis“); sonst
--      „schuldenfrei {Jahr}“ im Untertitel.
--      Schlussrate (B4): Untertitel mit Betrag + Datum, keine Payoff-/Zinsen-/Laufzeitende-Zeile; Bindungsende >=
--      Laufzeitende -> Bindungs-Zeile ohne Restschuld (die stuende doppelt). Annuitaet mit Laufzeitende und Payoff davor:
--      schuldenfrei + Zinsen, kein Laufzeitende.
--   2) Kind: nur Kredite mit borrower_person_id = ich; Volltextsuche: kein Haushalts-/Partner-/Geschwister-Kredit, keine
--      Kontonamen, kein *id.
--   3) probe -> {ok, empty, banners}: Banner nur fuer die bald endende Bindung (mit Restschuld zum Bindungsende), nicht
--      fuer pausiert/abgelaufen; volle View banners [].
--   4) Eingabe-Fehler -> bad_request; Frei-SQL -> forbidden; kein EXECUTE fuer *_ro.
--   5) Fixture-Haushalt (tests/util/util_app_household.sql): core.fn_app_view_lint = 0 fuer alle Personen, Autokredit mit
--      Schlussrate ohne Hochrechnung (B4), Zinsbindung im Warnfenster. [1] prueft den Lint auch auf den eigenen Daten.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_giro INT; v_l1 INT; v_l2 INT; v_l3 INT; v_l4 INT; v_l5 INT; v_l6 INT; v_l7 INT; v_l8 INT; v_k2 INT;
  v jsonb; v_txt text; v_it jsonb; v_keys text[];
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('apl_owner', 'Owner Beispiel', 'owner'), ('apl_partner', 'Partner Beispiel', 'partner'), ('apl_kid', 'Kind Beispiel', 'child'),
    ('apl_kid2', 'Zweitkind Beispiel', 'child');
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
  v_k2 := (finance.fn_create_loan(jsonb_build_object('name', '__apl_kid2_kredit__', 'lender', 'Tante',
            'borrower_person_id', 'apl_kid2', 'current_balance', 300, 'interest_rate', 0, 'monthly_annuity', 50,
            'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro))->>'loan_id')::int;
  IF v_k2 IS NULL OR v_l8 IS NULL OR v_l1 IS NULL OR v_l2 IS NULL OR v_l3 IS NULL OR v_l4 IS NULL OR v_l5 IS NULL OR v_l6 IS NULL OR v_l7 IS NULL THEN
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
  -- dieselbe Zahl wie die Vermoegen-Seite (Schulden -> Kredite, dort positiv: UX-Gesamtkonzept 2026-10-31)
  IF (SELECT (s->'items'->0->'value'->>'value')::numeric
        FROM jsonb_array_elements(finance.fn_app_screen_overview(jsonb_build_object('person_id', 'apl_owner'))->'sections') s
       WHERE s->'title' = core.fn_ui_tpl('finance.app.overview.section_debts')) IS DISTINCT FROM 12800 THEN
    RAISE EXCEPTION 'FAIL [1b3] Vermoegen „Kredite" muss = Kredit-Hero (12800) sein'; END IF;
  IF jsonb_array_length(v->'sections'->0->'items') <> 6 OR v::text LIKE '%__apl_bezahlt__%' THEN
    RAISE EXCEPTION 'FAIL [1c] 6 ausstehende Haushalts-Kredite erwartet: %', v->'sections'; END IF;
  -- zwei Kinder-Kredite (500 + 300): Abschnitt „Kredite der Kinder" mit Summe, groesster zuerst
  IF v->'sections'->1->'title' <> core.fn_ui_tpl('finance.app.loans.section_kids')
     OR v->'sections'->1->'value' <> core.fn_ui_money(800, 'EUR')
     OR v->'sections'->1->'items'->0->>'label' <> '__apl_kid_kredit__'
     OR v->'sections'->1->'items'->1->>'label' <> '__apl_kid2_kredit__' THEN
    RAISE EXCEPTION 'FAIL [1c2] Kredite der Kinder mit Summe 800: %', v->'sections'->1; END IF;
  IF v::text LIKE '%finance.app.common.kids_not_in_sum%' THEN
    RAISE EXCEPTION 'FAIL [1c3] keine Fussnote „nicht in der Summe" mehr'; END IF;
  IF jsonb_path_exists(v, 'strict $.**.state ? (@ == "ok")') THEN
    RAISE EXCEPTION 'FAIL [1c4] keine ok-Pille / kein ok-Balken: %', v; END IF;
  IF jsonb_path_exists(v, 'strict $.sections[*].items[*] ? (@.details.size() > 8)') THEN
    RAISE EXCEPTION 'FAIL [1c5] hoechstens 8 Detail-Zeilen je Kredit'; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->>'label' = '__apl_haus__';
  IF v_it->'value' <> core.fn_ui_money(8000, 'EUR') OR (v_it->'progress'->>'pct')::numeric IS DISTINCT FROM 20.0
     OR v_it->'sub' <> core.fn_ui_tpl('finance.app.loans.rate_line_payoff', jsonb_build_object(
          'rate', core.fn_ui_money(300, 'EUR'), 'interest', core.fn_ui_num(3.5, 2),
          'year', (SELECT to_char(payoff_date_projected, 'YYYY') FROM finance.loan_overview WHERE id = v_l1)))
     OR v_it->'pill'->>'state' <> 'warn' OR v_it->'pill'->>'icon' <> 'calendar'
     OR v_it->'pill'->'text' <> core.fn_ui_tpl('finance.app.loans.fixed_ends',
          jsonb_build_object('date', core.fn_ui_date((t + interval '12 months')::date - 1))) THEN
    RAISE EXCEPTION 'FAIL [1d] Haus-Kredit (Rest, 20 %% getilgt, Zins/Rate/schuldenfrei im Untertitel, warn 1 Tag vor 12 Monaten): %', v_it; END IF;
  SELECT array_agg(d->'label'->>'value' ORDER BY o) INTO v_keys FROM jsonb_array_elements(v_it->'details') WITH ORDINALITY AS t(d, o);
  IF v_keys IS DISTINCT FROM ARRAY['finance.app.loans.d_lender', 'finance.app.loans.d_borrower', 'finance.app.loans.d_amount', 'finance.app.loans.d_repaid',
                                   'finance.app.loans.d_split', 'finance.app.loans.d_fixed', 'finance.app.loans.d_payoff',
                                   'finance.app.loans.d_interest_left'] THEN
    RAISE EXCEPTION 'FAIL [1d2] Details in fester Reihenfolge, NULL-Zeilen entfallen (kein Laufzeitende), got %', v_keys; END IF;
  IF v_it->'details'->0->'value' <> to_jsonb('Bank'::text) OR v_it->'details'->1->'value' <> core.fn_ui_tpl('finance.app.common.joint')
     OR v_it->'details'->3->'value' <> core.fn_ui_tpl('finance.app.loans.d_repaid_value', jsonb_build_object(
          'pct', core.fn_ui_num(20.0, 1), 'amount', core.fn_ui_money(2000, 'EUR')))
     OR v_it->'details'->4->'value' <> core.fn_ui_tpl('finance.app.loans.d_split_value', jsonb_build_object(
          'interest', core.fn_ui_money(23.33, 'EUR'), 'principal', core.fn_ui_money(276.67, 'EUR')))
     OR v_it->'details'->6->'value' <> (SELECT core.fn_ui_date(payoff_date_projected) FROM finance.loan_overview WHERE id = v_l1) THEN
    RAISE EXCEPTION 'FAIL [1d3] Details: Bank, Gemeinsam, getilgt 20 %% · 2000, Zins 23.33 + Tilgung 276.67, schuldenfrei-Datum, got %', v_it->'details'; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->'label' = to_jsonb('<img src=x onerror=alert(1)>'::text);
  IF v_it IS NULL OR jsonb_typeof(v_it->'progress') <> 'null'
     OR jsonb_typeof(v_it->'pill') <> 'null'
     OR v_it->'sub'->'params'->>'year' <> (SELECT to_char(payoff_date_projected, 'YYYY') FROM finance.loan_overview WHERE id = v_l2)
     OR v_it->'details'->1->'value' <> to_jsonb('Partner Beispiel'::text) THEN
    RAISE EXCEPTION 'FAIL [1e] Partner-Kredit: Rohname, keine Pille, schuldenfrei-Jahr im Untertitel statt Pille „schuldenfrei Jahr" (Bindung in 3 Jahren), kein Balken ohne Kreditbetrag, Kreditnehmer: %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->>'label' = '__apl_pausiert__';
  IF v_it->'pill'->>'state' <> 'warn' THEN RAISE EXCEPTION 'FAIL [1f] pausiert + Bindung bald -> warn: %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->>'label' = '__apl_pause_frei__';
  IF v_it->'pill'->>'state' <> 'neutral' OR v_it->'pill'->>'icon' <> 'pause' OR v_it->'pill'->'text' <> core.fn_ui_tpl('finance.app.loans.paused') THEN
    RAISE EXCEPTION 'FAIL [1f2] pausiert ohne Bindung -> neutral pause: %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->>'label' = '__apl_abgelaufen__';
  IF v_it->'pill'->>'state' <> 'warn' OR v_it->'pill'->'text' <> core.fn_ui_tpl('finance.app.loans.fixed_ended',
       jsonb_build_object('date', core.fn_ui_date(t - 30))) THEN
    RAISE EXCEPTION 'FAIL [1g] abgelaufene Bindung -> warn „endete“: %', v_it; END IF;
  IF NOT (v_it->'details' @> jsonb_build_array(jsonb_build_object('label', core.fn_ui_tpl('finance.app.loans.d_fixed',
            jsonb_build_object('date', core.fn_ui_date(t - 30))))))
     OR (v_it->'details')::text LIKE '%finance.app.loans.fixed_ended%' THEN
    RAISE EXCEPTION 'FAIL [1g2] abgelaufen: Detail „Zinsbindung bis", nicht die Pillen-Formel doppelt: %', v_it->'details'; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->>'label' = '__apl_grenze__';
  IF jsonb_typeof(v_it->'pill') <> 'null' OR v_it->'sub'->>'value' <> 'finance.app.loans.rate_line_payoff' THEN
    RAISE EXCEPTION 'FAIL [1h] genau 12 Monate -> keine Bindungs-Warnung (nur schuldenfrei im Untertitel): %', v_it; END IF;
  IF v::text ~ '"[a-z_]*id"\s*:' OR v::text LIKE '%__apl_giro__%' THEN
    RAISE EXCEPTION 'FAIL [1i] Antwort traegt ein *id-Feld oder einen Kontonamen'; END IF;
  IF finance.fn_app_screen_loans(jsonb_build_object('person_id', 'apl_partner', 'params', '{}'::jsonb)) <> v THEN
    RAISE EXCEPTION 'FAIL [1j] Partner = Haushalts-Sicht'; END IF;
  -- Schlussrate (B4): zum Laufzeitende bleibt Restschuld -> Untertitel „Schlussrate {Betrag} am {Datum}", keine Pille,
  -- keine Projektion ueber das Laufzeitende hinaus (schuldenfrei / Zinsen bis dahin) und keine Laufzeitende-Zeile
  DECLARE v_l9 int; v_l10 int; v_l11 int; v_l12 int; v_l13 int; v_l14 int; v_s jsonb; BEGIN
    v_l9 := (finance.fn_create_loan(jsonb_build_object('name', '__apl_schluss__', 'lender', 'Bank', 'current_balance', 10000,
              'interest_rate', 2, 'monthly_annuity', 100, 'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro,
              'term_end_date', (t + interval '2 years')::date::text))->>'loan_id')::int;
    -- Bindungsende = Laufzeitende: die Restschuld dann waere die Schlussrate ein zweites Mal
    v_l10 := (finance.fn_create_loan(jsonb_build_object('name', '__apl_schluss_bind__', 'lender', 'Bank', 'current_balance', 10000,
              'interest_rate', 2, 'monthly_annuity', 100, 'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro,
              'term_end_date', (t + interval '2 years')::date::text,
              'interest_rate_fixed_until', (t + interval '2 years')::date::text))->>'loan_id')::int;
    -- Bindungsende vor dem Laufzeitende: „Restschuld dann" ist eine eigene Zahl und bleibt
    v_l11 := (finance.fn_create_loan(jsonb_build_object('name', '__apl_schluss_frueh__', 'lender', 'Bank', 'current_balance', 10000,
              'interest_rate', 2, 'monthly_annuity', 100, 'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro,
              'term_end_date', (t + interval '2 years')::date::text,
              'interest_rate_fixed_until', (t + interval '18 months')::date::text))->>'loan_id')::int;
    -- Annuitaet mit Laufzeitende, getilgt lange davor: schuldenfrei + Zinsen, kein Laufzeitende
    v_l12 := (finance.fn_create_loan(jsonb_build_object('name', '__apl_kurz__', 'lender', 'Bank', 'current_balance', 1000,
              'interest_rate', 2, 'monthly_annuity', 100, 'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro,
              'term_end_date', (t + interval '5 years')::date::text))->>'loan_id')::int;
    v_s := finance.fn_app_screen_loans(jsonb_build_object('person_id', 'apl_owner'))->'sections'->0;
    SELECT i INTO v_it FROM jsonb_array_elements(v_s->'items') i WHERE i->>'label' = '__apl_schluss__';
    IF v_it->'sub' <> core.fn_ui_tpl('finance.app.loans.rate_line_final', jsonb_build_object(
         'interest', core.fn_ui_num(2, 2), 'rate', core.fn_ui_money(100, 'EUR'),
         'final', (SELECT core.fn_ui_money(abs(balance_at_term_end_projected), currency) FROM finance.loan_overview WHERE id = v_l9),
         'date', (SELECT core.fn_ui_date(term_end_date) FROM finance.loan_overview WHERE id = v_l9)))
       OR jsonb_typeof(v_it->'pill') <> 'null' THEN
      RAISE EXCEPTION 'FAIL [1k] Schlussrate mit Betrag + Datum im Untertitel, keine Pille: %', v_it; END IF;
    SELECT array_agg(d->'label'->>'value' ORDER BY o) INTO v_keys FROM jsonb_array_elements(v_it->'details') WITH ORDINALITY AS x(d, o);
    IF v_keys IS DISTINCT FROM ARRAY['finance.app.loans.d_lender', 'finance.app.loans.d_borrower', 'finance.app.loans.d_split'] THEN
      RAISE EXCEPTION 'FAIL [1k2] Schlussrate: kein schuldenfrei / Zinsen bis dahin / Laufzeitende, got %', v_keys; END IF;
    SELECT i INTO v_it FROM jsonb_array_elements(v_s->'items') i WHERE i->>'label' = '__apl_schluss_bind__';
    IF v_it->'details'->-1->'label'->>'value' <> 'finance.app.loans.d_fixed' OR jsonb_typeof(v_it->'details'->-1->'value') <> 'null'
       OR (v_it->'details')::text LIKE '%finance.app.loans.d_term%' THEN
      RAISE EXCEPTION 'FAIL [1k3] Bindungsende = Laufzeitende: Bindungs-Zeile ohne Restschuld, got %', v_it->'details'; END IF;
    SELECT i INTO v_it FROM jsonb_array_elements(v_s->'items') i WHERE i->>'label' = '__apl_schluss_frueh__';
    IF v_it->'details'->-1->'label'->>'value' <> 'finance.app.loans.d_fixed'
       OR v_it->'details'->-1->'value'->>'value' <> 'finance.app.loans.d_rest' THEN
      RAISE EXCEPTION 'FAIL [1k4] Bindungsende vor Laufzeitende: Restschuld dann bleibt, got %', v_it->'details'; END IF;
    SELECT i INTO v_it FROM jsonb_array_elements(v_s->'items') i WHERE i->>'label' = '__apl_kurz__';
    SELECT array_agg(d->'label'->>'value' ORDER BY o) INTO v_keys FROM jsonb_array_elements(v_it->'details') WITH ORDINALITY AS x(d, o);
    IF v_it->'sub'->>'value' <> 'finance.app.loans.rate_line_payoff'
       OR v_keys IS DISTINCT FROM ARRAY['finance.app.loans.d_lender', 'finance.app.loans.d_borrower', 'finance.app.loans.d_split',
                                        'finance.app.loans.d_payoff', 'finance.app.loans.d_interest_left'] THEN
      RAISE EXCEPTION 'FAIL [1k5] Annuitaet getilgt vor Laufzeitende: schuldenfrei + Zinsen, kein Laufzeitende, got % / %', v_it->'sub', v_keys; END IF;
    -- pausiert mit Laufzeitende: die Projektion rechnet ohne Raten (Restschuld = heute) -> keine Schlussrate
    v_l13 := (finance.fn_create_loan(jsonb_build_object('name', '__apl_pause_lz__', 'lender', 'Bank', 'current_balance', 2000,
              'interest_rate', 2, 'monthly_annuity', 100, 'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro,
              'term_end_date', (t + interval '2 years')::date::text))->>'loan_id')::int;
    UPDATE finance.loans SET status = 'paused' WHERE id = v_l13;
    -- Laufzeitende schon vorbei, Restschuld offen: die Hochrechnung „schuldenfrei" bleibt, keine Schlussrate in der Vergangenheit
    v_l14 := (finance.fn_create_loan(jsonb_build_object('name', '__apl_lz_vorbei__', 'lender', 'Bank', 'current_balance', 1000,
              'interest_rate', 2, 'monthly_annuity', 100, 'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro,
              'term_end_date', (t + interval '1 year')::date::text))->>'loan_id')::int;
    UPDATE finance.loans SET term_end_date = t - 30 WHERE id = v_l14;
    v_s := finance.fn_app_screen_loans(jsonb_build_object('person_id', 'apl_owner'))->'sections'->0;
    SELECT i INTO v_it FROM jsonb_array_elements(v_s->'items') i WHERE i->>'label' = '__apl_pause_lz__';
    IF v_it->'sub'->>'value' = 'finance.app.loans.rate_line_final' OR v_it->'pill'->>'state' <> 'neutral'
       OR (v_it->'details')::text LIKE '%finance.app.loans.d_payoff%' THEN
      RAISE EXCEPTION 'FAIL [1k6] pausiert mit Laufzeitende: keine Schlussrate, Pille pausiert, got %', v_it; END IF;
    SELECT i INTO v_it FROM jsonb_array_elements(v_s->'items') i WHERE i->>'label' = '__apl_lz_vorbei__';
    IF v_it->'sub'->>'value' <> 'finance.app.loans.rate_line_payoff'
       OR NOT ((v_it->'details')::text LIKE '%finance.app.loans.d_payoff%') THEN
      RAISE EXCEPTION 'FAIL [1k7] Laufzeitende vorbei: schuldenfrei-Hochrechnung bleibt, keine Schlussrate, got %', v_it; END IF;
    UPDATE finance.loans SET status = 'paid_off' WHERE id IN (v_l9, v_l10, v_l11, v_l12, v_l13, v_l14);   -- nicht mehr ausstehend
  END;
  -- Kinder-Kredit ohne Wechselkurs: die Summe faellt weg statt still zu niedrig zu sein
  UPDATE finance.accounts SET currency = 'CHF' WHERE id = (SELECT loan_account_id FROM finance.loans WHERE id = v_k2);
  IF jsonb_typeof(finance.fn_app_screen_loans(jsonb_build_object('person_id', 'apl_owner'))->'sections'->1->'value') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [1l] Kinder-Summe ohne Wechselkurs muss entfallen'; END IF;
  UPDATE finance.accounts SET currency = 'EUR' WHERE id = (SELECT loan_account_id FROM finance.loans WHERE id = v_k2);
  -- nur ein Kinder-Kredit: keine Summe ueber einer Zeile
  UPDATE finance.loans SET status = 'paid_off' WHERE id = v_k2;
  IF jsonb_typeof(finance.fn_app_screen_loans(jsonb_build_object('person_id', 'apl_owner'))->'sections'->1->'value') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [1m] ein Kinder-Kredit: keine Abschnitts-Summe'; END IF;
  UPDATE finance.loans SET status = 'active' WHERE id = v_k2;
  IF EXISTS (SELECT 1 FROM core.fn_app_view_lint(finance.fn_app_screen_loans(jsonb_build_object('person_id', 'apl_owner')),
                                                  ARRAY['finance.app.loans.paused'])) THEN
    RAISE EXCEPTION 'FAIL [1n] Gestaltungsregeln (fn_app_view_lint): %', (SELECT string_agg(l.rule || ' ' || l.path, ', ')
      FROM core.fn_app_view_lint(finance.fn_app_screen_loans(jsonb_build_object('person_id', 'apl_owner')), ARRAY['finance.app.loans.paused']) l); END IF;
  RAISE NOTICE 'PASS [1] Haushalt: Kredite, Hero, Pillen nur als Warnung, Schlussrate ohne Projektion, Kredite der Kinder, keine ok-Pille, Gestaltungsregeln';

  -- ===== 2) Kind =====
  v := finance.fn_app_screen_loans(jsonb_build_object('person_id', 'apl_kid', 'params', '{}'::jsonb));
  v_txt := v::text;
  IF jsonb_array_length(v->'sections') <> 1 OR jsonb_array_length(v->'sections'->0->'items') <> 1
     OR v->'sections'->0->'items'->0->>'label' <> '__apl_kid_kredit__'
     OR v->'hero'->'value' <> core.fn_ui_money(500, 'EUR')
     OR v::text LIKE '%finance.app.loans.d_borrower%' THEN
    RAISE EXCEPTION 'FAIL [2a] Kind sieht nur den eigenen Kredit (500): %', v; END IF;
  IF v_txt LIKE '%__apl_haus__%' OR v_txt LIKE '%onerror%' OR v_txt LIKE '%__apl_pausiert__%' OR v_txt LIKE '%__apl_giro__%'
     OR v_txt LIKE '%Bank%' OR v_txt ~ '"[a-z_]*id"\s*:' OR v_txt LIKE '%__apl_kid2_kredit__%' OR v_txt LIKE '%Zweitkind%'
     OR v_txt LIKE '%finance.app.loans.section_kids%' THEN
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

-- ===== 5) Fixture-Haushalt (tests/util/util_app_household.sql): Gestaltungsregeln fuer alle Personen, Autokredit B4 =====
BEGIN;
\ir ../../util/util_app_household.sql
DO $$
DECLARE
  v jsonb; v_pid text; v_it jsonb;
BEGIN
  FOREACH v_pid IN ARRAY ARRAY['fxh_jonas', 'fxh_mira', 'fxh_lea', 'fxh_tom', 'fxh_gast'] LOOP
    v := finance.fn_app_screen_loans(jsonb_build_object('person_id', v_pid, 'params', '{}'::jsonb));
    IF EXISTS (SELECT 1 FROM core.fn_app_view_lint(v, ARRAY['finance.app.loans.paused'])) THEN
      RAISE EXCEPTION 'FAIL [5a] Gestaltungsregeln fuer %: %', v_pid, (SELECT string_agg(l.rule || ' ' || l.path, ', ')
        FROM core.fn_app_view_lint(v, ARRAY['finance.app.loans.paused']) l); END IF;
  END LOOP;
  v := finance.fn_app_screen_loans(jsonb_build_object('person_id', 'fxh_jonas', 'params', '{}'::jsonb));
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i
   WHERE i->>'label' = (SELECT name FROM finance.loans WHERE id = (SELECT id::int FROM pg_temp.app_fx WHERE key = 'loan_car'));
  IF v_it->'sub'->>'value' <> 'finance.app.loans.rate_line_final' OR (v_it->'details')::text LIKE '%finance.app.loans.d_payoff%'
     OR (v_it->'details')::text LIKE '%finance.app.loans.d_interest_left%' OR (v_it->'details')::text LIKE '%finance.app.loans.d_term%' THEN
    RAISE EXCEPTION 'FAIL [5b] Autokredit mit Schlussrate (B4): Schlussrate im Untertitel, keine Hochrechnung, got %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i
   WHERE i->>'label' = (SELECT name FROM finance.loans WHERE id = (SELECT id::int FROM pg_temp.app_fx WHERE key = 'loan_house'));
  IF v_it->'pill'->>'state' <> 'warn' OR v_it->'pill'->'text'->>'value' <> 'finance.app.loans.fixed_ends' THEN
    RAISE EXCEPTION 'FAIL [5c] Zinsbindung im Warnfenster: warn „endet", got %', v_it; END IF;
  RAISE NOTICE 'PASS [5] Fixture-Haushalt: Gestaltungsregeln fuer alle Personen, Autokredit ohne Hochrechnung, Zinsbindung-Warnung';
END $$;
ROLLBACK;
