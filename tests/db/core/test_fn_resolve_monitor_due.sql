-- tests/db/core/test_fn_resolve_monitor_due.sql
-- agent.fn_resolve_monitor_due: die eine Faelligkeits-Regel der date-Trigger (Write-fns + Karten-Vorstufe der Tools).
BEGIN;

DO $$
DECLARE r jsonb;
BEGIN
  r := agent.fn_resolve_monitor_due('+6 months');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'due_date')::date IS DISTINCT FROM (core.fn_today() + interval '6 months')::date THEN
    RAISE EXCEPTION 'FAIL [relativ: %]', r; END IF;
  r := agent.fn_resolve_monitor_due(to_char(core.fn_today(), 'YYYY-MM-DD'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [heute erlaubt: %]', r; END IF;
  r := agent.fn_resolve_monitor_due('yesterday');
  IF (r->>'ok')::boolean OR r->>'reason' NOT LIKE '%past%' THEN RAISE EXCEPTION 'FAIL [Vergangenheit: %]', r; END IF;
  r := agent.fn_resolve_monitor_due('+6 monhts');
  IF (r->>'ok')::boolean OR r->>'reason' NOT LIKE '%relative%' THEN RAISE EXCEPTION 'FAIL [Tippfehler: %]', r; END IF;
  IF (agent.fn_resolve_monitor_due(NULL)->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [NULL]'; END IF;
  RAISE NOTICE 'PASS fn_resolve_monitor_due [relativ, heute, Vergangenheit, Tippfehler, NULL]';
END $$;

ROLLBACK;
