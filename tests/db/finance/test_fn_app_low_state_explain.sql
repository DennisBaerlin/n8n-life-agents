-- tests/db\finance/test_fn_app_low_state_explain.sql
-- finance.fn_app_low_state_explain(p_ls, p_account, p_month_row) — Erklaerzeile + „Das kannst du tun“ zur Pille des Urteils.
--   1) buffer alert/warn, 2) goals mit und ohne p_month_row, 3) alter Auszug ohne Tu-Zeile, 4) Spiegel am Sparplan nennt
--   das Konto, 5) ohne Pille keine Zeilen.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  b jsonb := '{"ok":true,"currency":"EUR","source":"outlook","verdict":"buffer","amount":140,"buffer":250,"short_by":110,"on_date":"2026-11-27"}';
  g jsonb := '{"ok":true,"currency":"EUR","source":"funding","verdict":"goals","amount":-50,"on_date":"2027-04-01","monthly_out":-3000,"monthly_in":220}';
  v jsonb;
BEGIN
  v := finance.fn_app_low_state_explain(b || '{"state":"alert"}');
  IF jsonb_array_length(v) <> 2 OR v->0->>'kind' <> 'info' OR v->1->>'kind' <> 'todo'
     OR v->0->'label'->>'value' <> 'finance.app.accounts.i_short'
     OR (v->0->'label'->'params'->'amount'->>'value')::numeric <> 110
     OR (v->0->'label'->'params'->'buffer'->>'value')::numeric <> 250 THEN
    RAISE EXCEPTION 'FAIL [1a] buffer alert, got %', v; END IF;
  v := finance.fn_app_low_state_explain(b || '{"state":"warn"}');
  IF v->0->'label'->>'value' <> 'finance.app.accounts.i_tight' OR v->1->>'kind' <> 'todo' THEN RAISE EXCEPTION 'FAIL [1b] tight, got %', v; END IF;
  RAISE NOTICE 'PASS [1] buffer';

  v := finance.fn_app_low_state_explain(g || '{"state":"warn"}', NULL, true);
  IF v->0->'label'->>'value' <> 'finance.app.accounts.i_net_out' OR (v->0->'label'->'params'->'amount'->>'value')::numeric <> 2780 THEN
    RAISE EXCEPTION 'FAIL [2a] Monatsminus, got %', v; END IF;
  v := finance.fn_app_low_state_explain(g || '{"state":"alert"}');
  IF v->0->'label'->>'value' <> 'finance.app.accounts.i_gap' THEN RAISE EXCEPTION 'FAIL [2b] Luecke, got %', v; END IF;
  v := finance.fn_app_low_state_explain(g || '{"state":"warn"}');
  IF v->0->'label'->>'value' <> 'finance.app.accounts.i_until' THEN RAISE EXCEPTION 'FAIL [2c] reicht bis, got %', v; END IF;
  RAISE NOTICE 'PASS [2] goals';

  v := finance.fn_app_low_state_explain('{"ok":true,"currency":"EUR","verdict":"stale","state":"warn"}');
  IF jsonb_array_length(v) <> 1 OR v->0->'label'->>'value' <> 'finance.app.accounts.i_stale' THEN RAISE EXCEPTION 'FAIL [3] stale, got %', v; END IF;
  RAISE NOTICE 'PASS [3] alter Auszug';

  v := finance.fn_app_low_state_explain(b || '{"state":"alert"}', 'Giro');
  IF v->0->'label'->>'value' <> 'finance.app.goals.i_plan_short' OR v->0->'label'->'params'->>'account' <> 'Giro'
     OR v->1->'label'->>'value' <> 'finance.app.goals.todo_plan' THEN RAISE EXCEPTION 'FAIL [4] Spiegel, got %', v; END IF;
  RAISE NOTICE 'PASS [4] Spiegel am Sparplan';

  IF finance.fn_app_low_state_explain(b || '{"state":"ok"}') <> '[]'::jsonb OR finance.fn_app_low_state_explain(NULL) <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [5] ohne Pille keine Zeilen'; END IF;
  RAISE NOTICE 'PASS [5] ohne Pille';
END $$;
ROLLBACK;
