-- tests/db/finance/test_fn_app_fx_footer.sql
-- Quellen-Hinweis der Wechselkurse in der Mini-App (finance.fn_app_fx_footer + die fuenf finance.fn_app_screen_*):
--   die Lizenz des freien Kursdienstes verlangt den Hinweis auf jeder Seite, die seine Kurse benutzt. Ein Bildschirm
--   traegt view.footer (docs/package-contract.md §3.12) genau dann, wenn er einen Betrag in fremder Waehrung zeigt oder
--   einrechnet, fuer den ein Kurs vorliegt; ohne Kurs (Luecke) und nur mit Euro keine Zeile.
--   Fixture-Haushalt tests/util/util_app_household.sql (CHF-Position in Depot Mira, CHF ohne Kurs).
--   [1] Fixture wie geliefert (CHF ohne Kurs): kein Bildschirm hat eine Fusszeile (Owner)
--   [2] CHF-Kurs da: Depot und Vermoegen mit Fusszeile (Form: Text-Key, Link-Text-Key, https-Adresse), Konten/Ziele/
--       Kredite ohne; Partnerin sieht dasselbe; Kind (sieht Depot Mira nicht) ohne; View-Lint = 0
--   [3] Dollar-Konto mit Kurs: Konten mit Fusszeile; ohne Dollar-Kurs (Luecke) wieder ohne; [3b] Kind sieht das
--       Dollar-Konto nicht, bekommt aber einen umgerechneten Dauerauftrag daraus -> Fusszeile; [3c] leeres Dollar-Konto
--       zeigt Vermoegen nicht -> keine Fusszeile
--   [4] probe-Antworten tragen nie eine Fusszeile
--   BEGIN/ROLLBACK -> kein Residual-State.
BEGIN;
\ir ../../util/util_app_household.sql

DO $$
DECLARE
  v_footer jsonb := jsonb_build_object(
    'text', core.fn_ui_tpl('finance.app.fx_source'),
    'link', jsonb_build_object('text', core.fn_ui_tpl('finance.app.fx_source_link'),
                               'url', 'https://www.exchangerate-api.com'));
  v_screens text[] := ARRAY['overview', 'accounts', 'goals', 'loans', 'depot'];
  v_scr  text;
  v     jsonb;
  v_has text[];
  v_lint text;
  v_usd int;
BEGIN
  -- [1] nur Euro + CHF ohne Kurs
  v_has := '{}';
  FOREACH v_scr IN ARRAY v_screens LOOP
    EXECUTE format('SELECT finance.fn_app_screen_%s($1)', v_scr) INTO v
      USING jsonb_build_object('person_id', 'fxh_jonas', 'params', '{}'::jsonb);
    IF (v->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [1] % ok, got %', v_scr, v; END IF;
    IF jsonb_typeof(COALESCE(v->'footer', 'null'::jsonb)) <> 'null' THEN v_has := v_has || v_scr; END IF;
  END LOOP;
  IF v_has <> '{}' THEN RAISE EXCEPTION 'FAIL [1] ohne benutzten Kurs keine Fusszeile, got %', v_has; END IF;
  RAISE NOTICE 'PASS [1] nur Euro + Kurs-Luecke: keine Fusszeile';

  -- [2] CHF-Kurs liegt vor -> Depot Mira wird umgerechnet
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
  VALUES ('EUR', 'CHF', 0.94, core.fn_today(), 'open.er-api.com');
  v_has := '{}';
  FOREACH v_scr IN ARRAY v_screens LOOP
    EXECUTE format('SELECT finance.fn_app_screen_%s($1)', v_scr) INTO v
      USING jsonb_build_object('person_id', 'fxh_jonas', 'params', '{}'::jsonb);
    IF jsonb_typeof(COALESCE(v->'footer', 'null'::jsonb)) <> 'null' THEN
      v_has := v_has || v_scr;
      IF v->'footer' <> v_footer THEN RAISE EXCEPTION 'FAIL [2] % Form der Fusszeile, got %', v_scr, v->'footer'; END IF;
    END IF;
    SELECT string_agg(l.rule || '@' || l.path, ' ') INTO v_lint FROM core.fn_app_view_lint(v) l WHERE l.rule = 'shape';
    IF v_lint IS NOT NULL THEN RAISE EXCEPTION 'FAIL [2] % View-Form mit Fusszeile: %', v_scr, v_lint; END IF;
  END LOOP;
  IF v_has IS DISTINCT FROM ARRAY['overview', 'depot'] THEN
    RAISE EXCEPTION 'FAIL [2] CHF-Kurs: Fusszeile genau auf Vermoegen und Depot, got %', v_has; END IF;
  v := finance.fn_app_screen_depot(jsonb_build_object('person_id', 'fxh_mira', 'params', '{}'::jsonb));
  IF v->'footer' IS DISTINCT FROM v_footer THEN RAISE EXCEPTION 'FAIL [2] Partnerin Depot, got %', v->'footer'; END IF;
  FOREACH v_scr IN ARRAY v_screens LOOP
    EXECUTE format('SELECT finance.fn_app_screen_%s($1)', v_scr) INTO v
      USING jsonb_build_object('person_id', 'fxh_lea', 'params', '{}'::jsonb);
    IF jsonb_typeof(COALESCE(v->'footer', 'null'::jsonb)) <> 'null' THEN
      RAISE EXCEPTION 'FAIL [2] Kind ohne fremde Waehrung: keine Fusszeile auf %, got %', v_scr, v->'footer'; END IF;
  END LOOP;
  RAISE NOTICE 'PASS [2] CHF-Kurs: Vermoegen + Depot, Partnerin gleich, Kind ohne';

  -- [3] Dollar-Konto des Owners
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('USD', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'USD';
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id, bank)
    VALUES ('Dollar-Konto Jonas', 'cash', 'USD', 'active', 'fxh_jonas', 'Beispielbank') RETURNING id INTO v_usd;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
    VALUES (v_usd, 1200, core.fn_today() - 40, 'other');
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF';
  v := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_jonas', 'params', '{}'::jsonb));
  IF jsonb_typeof(COALESCE(v->'footer', 'null'::jsonb)) <> 'null' THEN
    RAISE EXCEPTION 'FAIL [3] Dollar-Konto ohne Kurs: keine Fusszeile, got %', v->'footer'; END IF;
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
  VALUES ('EUR', 'USD', 1.08, core.fn_today(), 'open.er-api.com');
  v := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_jonas', 'params', '{}'::jsonb));
  IF v->'footer' IS DISTINCT FROM v_footer THEN RAISE EXCEPTION 'FAIL [3] Dollar-Konto mit Kurs: Konten, got %', v->'footer'; END IF;
  v := finance.fn_app_screen_overview(jsonb_build_object('person_id', 'fxh_jonas', 'params', '{}'::jsonb));
  IF v->'footer' IS DISTINCT FROM v_footer THEN RAISE EXCEPTION 'FAIL [3] Dollar-Konto mit Kurs: Vermoegen, got %', v->'footer'; END IF;
  RAISE NOTICE 'PASS [3] Dollar-Konto: mit Kurs Konten + Vermoegen, ohne Kurs keine Zeile';

  -- [3b] Dauerauftrag vom Dollar-Konto an Leas Euro-Konto: Lea sieht das Dollar-Konto nicht, ihr Eingang ist aber
  --      umgerechnet -> Fusszeile auf ihrem Konten-Reiter
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, schedule_day_of_month,
                                          first_payment_date, valid_from)
  VALUES ('Dollar-Taschengeld Lea', v_usd, (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_cash_lea'), -20, 'month', 1,
          (date_trunc('month', core.fn_today()) + interval '1 month')::date, core.fn_today() - 30);
  v := finance.fn_app_screen_accounts(jsonb_build_object('person_id', 'fxh_lea', 'params', '{}'::jsonb));
  IF v->'footer' IS DISTINCT FROM v_footer THEN
    RAISE EXCEPTION 'FAIL [3b] umgerechneter Eingang aus fremder Waehrung -> Fusszeile, got %', v->'footer'; END IF;
  -- [3c] leeres Dollar-Konto (0, ohne Bewegung) zeigt die Vermoegen-Seite nicht -> keine Fusszeile
  DELETE FROM finance.recurring_payments WHERE account_id = v_usd;
  DELETE FROM finance.transactions WHERE account_id = v_usd;
  v := finance.fn_app_screen_overview(jsonb_build_object('person_id', 'fxh_jonas', 'params', '{}'::jsonb));
  IF jsonb_typeof(COALESCE(v->'footer', 'null'::jsonb)) <> 'null' THEN
    RAISE EXCEPTION 'FAIL [3c] leeres Dollar-Konto -> keine Fusszeile auf Vermoegen, got %', v->'footer'; END IF;
  RAISE NOTICE 'PASS [3b/3c] Eingang aus fremder Waehrung, leeres Konto';

  -- [4] probe
  FOREACH v_scr IN ARRAY v_screens LOOP
    EXECUTE format('SELECT finance.fn_app_screen_%s($1)', v_scr) INTO v
      USING jsonb_build_object('person_id', 'fxh_jonas', 'params', jsonb_build_object('probe', true));
    IF v ? 'footer' THEN RAISE EXCEPTION 'FAIL [4] probe % ohne Fusszeile, got %', v_scr, v; END IF;
  END LOOP;
  RAISE NOTICE 'PASS [4] probe ohne Fusszeile';

  RAISE NOTICE 'PASS test_fn_app_fx_footer [1 nur Euro, 2 CHF-Kurs + Rollen, 3 Dollar-Konto, 4 probe]';
END $$;
ROLLBACK;
