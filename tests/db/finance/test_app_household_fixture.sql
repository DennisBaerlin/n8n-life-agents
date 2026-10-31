-- tests/db/finance/test_app_household_fixture.sql
-- Der gemeinsame Fixture-Haushalt tests/util/util_app_household.sql (UX-Gesamtkonzept 2026-10-31, Abschnitt 10):
--   [1] laedt, jeder Schluessel in pg_temp.app_fx zeigt auf eine echte Zeile; die Regressions-Konstellationen stehen
--       (Sparkonto: Ziel-Geld 26.800 von 40.000 = B1, Dauerauftrag Sparkonto -> Broker-Cash = B2, Autokredit mit
--       Laufzeitende + gleich hohes erreichtes Ziel = B4, Depot mit genau einer Position = B5, Verrechnungskonto 0 EUR
--       ohne Bewegung = B10)
--   [2] jeder Mini-App-Bildschirm-Handler (finance.fn_app_screen_*, dynamisch: Pakete B/C/D benennen um) liefert fuer
--       Owner, Partnerin, beide Kinder und den Gast ok:true, auch als probe, und core.fn_app_view_lint findet keine
--       kaputte Form. Die Regel-Assertion (Lint = 0) gehoert in den jeweiligen test_fn_app_screen_*.
--   [3] die Fixture schreibt nichts dauerhaft: Temp-Tabelle ist fuer PUBLIC lesbar (SET LOCAL ROLE-Tests).
BEGIN;
\ir ../../util/util_app_household.sql

DO $$
DECLARE
  r record; v jsonb; v_fn text; v_pid text; v_n int;
BEGIN
  -- [1] Schluessel + Konstellationen
  SELECT count(*) INTO v_n FROM pg_temp.app_fx;
  IF v_n < 34 THEN RAISE EXCEPTION 'FAIL [1a] app_fx unvollstaendig: % Schluessel', v_n; END IF;
  FOR r IN SELECT key, id FROM pg_temp.app_fx WHERE key LIKE 'acc\_%' LOOP
    IF NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = r.id::int) THEN RAISE EXCEPTION 'FAIL [1b] % fehlt', r.key; END IF;
  END LOOP;
  SELECT reserved INTO v_n FROM finance.account_reserve_status
   WHERE account_id = (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_p2p');
  IF v_n IS DISTINCT FROM 26800 OR (SELECT balance FROM finance.account_balances
                                     WHERE account_id = (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_p2p')) <> 40000 THEN
    RAISE EXCEPTION 'FAIL [1c] Sparkonto: Ziel-Geld 26800 von 40000 erwartet (B1), got %', v_n; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.recurring_payments
                  WHERE account_id = (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_p2p')
                    AND target_account_id = (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_broker_cash')) THEN
    RAISE EXCEPTION 'FAIL [1d] Dauerauftrag Sparkonto -> Broker-Cash fehlt (B2)'; END IF;
  IF (SELECT term_end_date FROM finance.loans WHERE id = (SELECT id::int FROM pg_temp.app_fx WHERE key = 'loan_car'))
     IS DISTINCT FROM (SELECT target_date FROM finance.savings_goals WHERE id = (SELECT id::int FROM pg_temp.app_fx WHERE key = 'goal_car')) THEN
    RAISE EXCEPTION 'FAIL [1e] Autokredit-Laufzeitende = Zieldatum Auto-Schlussrate (B4)'; END IF;
  IF (SELECT count(*) FROM finance.depot_holdings WHERE account_id = (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_depot_jonas')) <> 1 THEN
    RAISE EXCEPTION 'FAIL [1f] Depot Jonas: genau eine Position (B5)'; END IF;
  IF (SELECT balance FROM finance.account_balances WHERE account_id = (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_clearing')) <> 0
     OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_clearing') IN (account_id, target_account_id)) THEN
    RAISE EXCEPTION 'FAIL [1g] Verrechnungskonto: 0 EUR ohne Bewegung (B10)'; END IF;
  RAISE NOTICE 'PASS [1] Fixture geladen, Regressions-Konstellationen B1/B2/B4/B5/B10 stehen';

  -- [2] alle Handler x alle Personen: ok, probe ok, keine kaputte Form
  FOR v_fn IN SELECT n.nspname || '.' || p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = 'finance' AND p.proname LIKE 'fn\_app\_screen\_%' ORDER BY 1 LOOP
    FOREACH v_pid IN ARRAY ARRAY['fxh_jonas', 'fxh_mira', 'fxh_lea', 'fxh_tom', 'fxh_gast'] LOOP
      EXECUTE format('SELECT %s($1)', v_fn) INTO v USING jsonb_build_object('person_id', v_pid, 'params', '{}'::jsonb);
      IF (v->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [2a] % fuer %: %', v_fn, v_pid, v; END IF;
      IF EXISTS (SELECT 1 FROM core.fn_app_view_lint(v) l WHERE l.rule = 'shape') THEN
        RAISE EXCEPTION 'FAIL [2b] % fuer %: kaputte Form %', v_fn, v_pid,
          (SELECT string_agg(l.path, ', ') FROM core.fn_app_view_lint(v) l WHERE l.rule = 'shape'); END IF;
      EXECUTE format('SELECT %s($1)', v_fn) INTO v USING jsonb_build_object('person_id', v_pid, 'params', '{"probe":true}'::jsonb);
      IF (v->>'ok')::boolean IS NOT TRUE OR jsonb_typeof(v->'empty') <> 'boolean' THEN
        RAISE EXCEPTION 'FAIL [2c] probe % fuer %: %', v_fn, v_pid, v; END IF;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'PASS [2] alle Bildschirme x alle Personen ok';

  -- [3] lesbar fuer PUBLIC
  IF NOT has_table_privilege('public', 'pg_temp.app_fx', 'SELECT') THEN RAISE EXCEPTION 'FAIL [3] app_fx nicht fuer PUBLIC lesbar'; END IF;
  RAISE NOTICE 'PASS [3] app_fx fuer PUBLIC lesbar';
END $$;

ROLLBACK;
