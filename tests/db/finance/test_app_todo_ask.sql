-- tests/db/finance/test_app_todo_ask.sql
-- Jede Zeile „Das kannst du tun“ (kind todo) traegt die vorbereitete Chat-Nachricht ask: Key aus dem Katalog, Name der Zeile
-- als Parameter. Nachricht beginnt nie mit dem Namen (fuehrendes @ oder / waere im Telegram-Feld unsicher).
BEGIN;
\ir ../../util/util_app_household.sql

DO $$
DECLARE
  b jsonb := '{"ok":true,"currency":"EUR","verdict":"buffer","buffer":250,"short_by":10,"on_date":"2030-01-01","monthly_out":-100,"monthly_in":0}';
  g jsonb := '{"ok":true,"currency":"EUR","verdict":"goals","on_date":"2030-01-01","monthly_out":-100,"monthly_in":0}';
  v jsonb; v_fn text; v_pid text; v_todo jsonb; v_n int := 0; v_key text;
BEGIN
  v := finance.fn_app_low_state_explain(b || '{"state":"alert"}', NULL, false, 'Giro Muster');
  IF v->1->'ask'->>'value' <> 'finance.app.accounts.ask_low' OR v->1->'ask'->'params'->>'account' <> 'Giro Muster' THEN
    RAISE EXCEPTION 'FAIL [1] Konto low: %', v; END IF;
  v := finance.fn_app_low_state_explain(g || '{"state":"warn"}', NULL, true, 'Giro Muster');
  IF v->1->'ask'->>'value' <> 'finance.app.accounts.ask_net_out' THEN RAISE EXCEPTION 'FAIL [2] net_out: %', v; END IF;
  v := finance.fn_app_low_state_explain(g || '{"state":"alert"}', NULL, false, 'Giro Muster');
  IF v->1->'ask'->>'value' <> 'finance.app.accounts.ask_gap' THEN RAISE EXCEPTION 'FAIL [3] gap: %', v; END IF;
  v := finance.fn_app_low_state_explain(b || '{"state":"alert"}', 'Giro Muster');
  IF v->1->'ask'->>'value' <> 'finance.app.goals.ask_plan' OR v->1->'ask'->'params'->>'account' <> 'Giro Muster' THEN
    RAISE EXCEPTION 'FAIL [4] Sparplan: %', v; END IF;
  RAISE NOTICE 'PASS [1-4] fn_app_low_state_explain';

  FOR v_fn IN SELECT n.nspname || '.' || p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = 'finance' AND p.proname LIKE 'fn\_app\_screen\_%' ORDER BY 1 LOOP
    FOREACH v_pid IN ARRAY ARRAY['fxh_jonas', 'fxh_mira'] LOOP
      EXECUTE format('SELECT %s($1)', v_fn) INTO v USING jsonb_build_object('person_id', v_pid, 'params', '{}'::jsonb);
      FOR v_todo IN SELECT d FROM jsonb_array_elements(v->'sections') s, jsonb_array_elements(s->'items') i,
                                  jsonb_array_elements(CASE WHEN jsonb_typeof(i->'details') = 'array' THEN i->'details' ELSE '[]'::jsonb END) d
                     WHERE d->>'kind' = 'todo' LOOP
        v_n := v_n + 1;
        v_key := v_todo->'ask'->>'value';
        IF v_key IS NULL OR v_key !~ '^finance\.app\.(accounts|goals|overview|depot)\.ask_' THEN RAISE EXCEPTION 'FAIL [5] todo ohne ask: %', v_todo; END IF;
      END LOOP;
    END LOOP;
  END LOOP;
  IF v_n = 0 THEN RAISE EXCEPTION 'FAIL [7] Fixture erzeugt keine todo-Zeile'; END IF;
  RAISE NOTICE 'PASS [5,7] % todo-Zeilen tragen ask', v_n;
END $$;

ROLLBACK;
