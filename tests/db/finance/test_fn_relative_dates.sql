-- tests/db/finance/test_fn_relative_dates.sql
-- Relative Datumsangaben in den finance-Write-fns (das LLM gibt "yesterday", "in 2 weeks" roh weiter, die DB rechnet
--   ueber core.fn_resolve_input_dates):
--   (1) Drift-Guard ueber pg_proc.prosrc aller finance-fns: jeder Tool-Key, der roh nach date gecastet wird
--       ((p->>'k')::date, NULLIF(p->>'k', '')::date [+ 1], v DATE := p->>'k'), steht im ARRAY[...] eines
--       core.fn_resolve_input_dates-Aufrufs, und dieser Aufruf steht im Text VOR dem ersten Cast (faengt
--       DECLARE-Initialisierer, die vor dem Body laufen). Ausnahmen = benannte Allowlist (Import/Statement/Cron/
--       Render/Void + Lookup-Keys, die nie das LLM fuellt). Grenze: Aliase (v_acct->>'k') sieht der Scan nicht —
--       der Batch-Abgleich ist deshalb unten fachlich getestet.
--   (2) Fachlich: relativ -> effective + gespeicherte Zeile tragen dasselbe Datum; Unsinn -> {ok:false,
--       code:'invalid_date'} ohne Exception.
BEGIN;

-- ============================================================
-- (1) Drift-Guard
-- ============================================================
DO $$
DECLARE
  -- fns, die nie ein LLM-Tool-Payload sehen (Import/Statement/Cron/Render/Validate/Review/Void) oder intern sind
  v_skip_fn text[] := ARRAY[
    'fn_import_%', 'fn_statement_%', 'fn_apply_bank_statement', 'fn_upsert_%', 'fn_monitor_%', 'fn_render_%',
    'fn_validate_%', 'fn_advisor_%', 'fn_void_%', 'fn_skip_recurring_occurrence', 'fn_skip_interest_occurrence'];
  -- (fn, key): Lookup-Keys aus DB-Knoten (Vorkommen-Identitaet, ON CONFLICT), nie vom LLM gefuellt
  v_skip_key text[] := ARRAY[
    'fn_book_recurring_occurrence.due_date', 'fn_book_recurring_transfer.due_date',
    'fn_book_savings_plan_execution.due_date', 'fn_book_interest_occurrence.value_date',
    'fn_book_interest_occurrence.period_end'];
  v_cast_re text := '(?:NULLIF\s*\(\s*)?\(?\s*p\s*->>\s*''([a-z_]+)''\s*\)?\s*(?:,\s*''''\s*\))?\s*::\s*date\M';
  v_decl_re text := '\m[a-z_]+\s+date\s*:=\s*p\s*->>\s*''([a-z_]+)''';
  r       record;
  v_keys  text[];
  v_cast  text[];
  v_bad   text := '';
  v_first int;
  v_call  int;
  v_re    text;
  v_n     int;
  v_pos   int;
BEGIN
  FOR r IN
    SELECT p.proname, p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'finance' AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
       AND NOT p.proname LIKE ANY (v_skip_fn)
     ORDER BY p.proname
  LOOP
    SELECT COALESCE(array_agg(DISTINCT m[1]), ARRAY[]::text[]) INTO v_cast
      FROM (SELECT regexp_matches(r.prosrc, v_cast_re, 'gi') AS m
            UNION ALL SELECT regexp_matches(r.prosrc, v_decl_re, 'gi')) x
     WHERE NOT (r.proname || '.' || m[1]) = ANY (v_skip_key);
    CONTINUE WHEN cardinality(v_cast) = 0;

    SELECT COALESCE(array_agg(DISTINCT k[1]), ARRAY[]::text[]) INTO v_keys
      FROM regexp_matches(r.prosrc, 'fn_resolve_input_dates\s*\(\s*p\s*,\s*ARRAY\s*\[([^\]]*)\]', 'gi') a,
           LATERAL regexp_matches(a[1], '''([a-z_]+)''', 'g') k;
    IF NOT v_cast <@ v_keys THEN
      v_bad := v_bad || format(' | %s: roh gecastet ohne fn_resolve_input_dates: %s', r.proname,
                               (SELECT string_agg(c, ', ') FROM unnest(v_cast) c WHERE NOT c = ANY (v_keys)));
      CONTINUE;
    END IF;
    -- erste Cast-Stelle eines NICHT ausgenommenen Keys (regexp_instr/regexp_substr je n-tem Treffer)
    v_call  := regexp_instr(r.prosrc, 'fn_resolve_input_dates', 1, 1, 0, 'i');
    v_first := NULL;
    FOREACH v_re IN ARRAY ARRAY[v_cast_re, v_decl_re] LOOP
      v_n := 1;
      LOOP
        v_pos := regexp_instr(r.prosrc, v_re, 1, v_n, 0, 'i');
        EXIT WHEN v_pos = 0;
        IF NOT (r.proname || '.' || regexp_substr(r.prosrc, v_re, 1, v_n, 'i', 1)) = ANY (v_skip_key) THEN
          v_first := LEAST(COALESCE(v_first, v_pos), v_pos);
          EXIT;
        END IF;
        v_n := v_n + 1;
      END LOOP;
    END LOOP;
    IF v_first < v_call THEN
      v_bad := v_bad || format(' | %s: Datums-Cast vor dem fn_resolve_input_dates-Aufruf (DECLARE-Initialisierer?)',
                               r.proname);
    END IF;
  END LOOP;
  IF v_bad <> '' THEN RAISE EXCEPTION 'FAIL relative_dates Drift-Guard:%', v_bad; END IF;
  RAISE NOTICE 'PASS relative_dates Drift-Guard';
END $$;

-- ============================================================
-- (2) Fachlich: relativ -> effective = gespeichert; Unsinn -> {ok:false, code:'invalid_date'} ohne Exception
-- ============================================================
DO $$
DECLARE
  t   date := core.fn_today();
  v_r jsonb;
  v_a int; v_b int; v_c int;
  v_d date;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__rd_a__","account_type":"cash","opening_balance":1000}'::jsonb)->>'account_id')::int;
  v_b := (finance.fn_create_account('{"name":"__rd_b__","account_type":"cash"}'::jsonb)->>'account_id')::int;

  -- Buchung "yesterday": effective + Zeile = gestern
  v_r := finance.fn_book_transaction(jsonb_build_object('account_id', v_a, 'amount', '12.5', 'direction', 'outflow',
           'transaction_date', 'yesterday'));
  SELECT transaction_date INTO v_d FROM finance.transactions WHERE id = (v_r->>'tx_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_d IS DISTINCT FROM t - 1
     OR (v_r->'effective'->>'transaction_date')::date IS DISTINCT FROM t - 1 THEN
    RAISE EXCEPTION 'FAIL relative_dates [book_transaction yesterday]: % / %', v_r, v_d; END IF;

  -- Unsinn -> ok:false als Daten (vorher Cast-RAISE + Owner-Alarm), nichts gebucht
  v_r := finance.fn_book_transaction(jsonb_build_object('account_id', v_a, 'amount', '1', 'direction', 'outflow',
           'transaction_date', 'Ende des Monats'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'invalid_date' THEN
    RAISE EXCEPTION 'FAIL relative_dates [book_transaction Unsinn]: %', v_r; END IF;

  -- Umbuchung "-3 days" ueber den Probelauf (wie das Gate): effective traegt den Tag fest
  v_r := core.fn_dry_run('finance.fn_book_transfer(jsonb)'::regprocedure, jsonb_build_object(
           'from_account_id', v_a, 'to_account_id', v_b, 'amount', 10,
           'from_account_name', '__rd_a__', 'to_account_name', '__rd_b__', 'transaction_date', '-3 days'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->'effective'->>'transaction_date')::date IS DISTINCT FROM t - 3 THEN
    RAISE EXCEPTION 'FAIL relative_dates [book_transfer dry run]: %', v_r; END IF;

  -- Konto mit Saldo-Stichtag "yesterday"; "01.10.2026" bleibt abgelehnt (kein DateStyle-Raten)
  v_r := finance.fn_create_account(jsonb_build_object('name', '__rd_c__', 'account_type', 'cash',
           'opening_balance', '50', 'opening_balance_date', 'yesterday'));
  v_c := (v_r->>'account_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT opening_balance_date FROM finance.accounts WHERE id = v_c) IS DISTINCT FROM t - 1
     OR (v_r->'effective'->>'opening_balance_date')::date IS DISTINCT FROM t - 1 THEN
    RAISE EXCEPTION 'FAIL relative_dates [create_account Stichtag]: %', v_r; END IF;
  v_r := finance.fn_create_account(jsonb_build_object('name', '__rd_d__', 'account_type', 'cash',
           'opening_balance', '50', 'opening_balance_date', '01.10.2026'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'invalid_date' THEN
    RAISE EXCEPTION 'FAIL relative_dates [create_account DE-Datum]: %', v_r; END IF;

  -- Dauerauftrag: erste Zahlung "in 3 days", Ende "+1 year" (inklusiv -> exklusiv gespeichert)
  v_r := finance.fn_create_recurring_payment(jsonb_build_object('name', '__rd_rp__', 'account_id', v_a,
           'direction', 'expense', 'amount', 20, 'schedule_unit', 'month', 'first_payment_date', 'in 3 days',
           'valid_to', '+1 year'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT valid_from FROM finance.recurring_payments WHERE id = (v_r->>'recurring_payment_id')::int) IS DISTINCT FROM t + 3
     OR (SELECT valid_to FROM finance.recurring_payments WHERE id = (v_r->>'recurring_payment_id')::int)
          IS DISTINCT FROM (t + interval '1 year')::date + 1
     OR (v_r->'effective'->>'first_payment_date')::date IS DISTINCT FROM t + 3 THEN
    RAISE EXCEPTION 'FAIL relative_dates [create_recurring_payment]: %', v_r; END IF;

  -- Vorsorge: Bewertungsstand "-3 days"
  v_r := finance.fn_create_pension(jsonb_build_object('name', '__rd_pension__', 'pension_type', 'occupational',
           'current_value', 1000, 'value_updated_at', '-3 days'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT value_updated_at FROM finance.pension WHERE id = (v_r->>'pension_id')::int) IS DISTINCT FROM t - 3 THEN
    RAISE EXCEPTION 'FAIL relative_dates [create_pension]: %', v_r; END IF;

  -- Einzel-Abgleich "yesterday" ueber den Probelauf; Konto schliessen mit Unsinn -> ok:false
  v_r := core.fn_dry_run('finance.fn_reconcile_account(jsonb)'::regprocedure, jsonb_build_object(
           'account_id', v_b, 'confirmed_balance', 10, 'reconciliation_date', 'yesterday'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR (v_r->'effective'->>'reconciliation_date')::date IS DISTINCT FROM t - 1 THEN
    RAISE EXCEPTION 'FAIL relative_dates [reconcile_account]: %', v_r; END IF;
  v_r := finance.fn_close_account(jsonb_build_object('account_id', v_b, 'closure_date', 'irgendwann'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'invalid_date' THEN
    RAISE EXCEPTION 'FAIL relative_dates [close_account Unsinn]: %', v_r; END IF;

  -- Batch-Abgleich (Datum je Listen-Zeile, Alias v_acct: vom Drift-Guard nicht gesehen -> hier fachlich):
  -- Vorschau und Probelauf zeigen denselben Tag, effective.accounts traegt ihn (leer = heute) fest in den Write.
  v_r := finance.fn_reconcile_accounts_preview(jsonb_build_object('accounts', jsonb_build_array(
           jsonb_build_object('account_name', '__rd_a__', 'confirmed_balance', '900', 'reconciliation_date', 'yesterday'),
           jsonb_build_object('account_name', '__rd_c__', 'confirmed_balance', '50'))));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR (v_r->'rows'->0->>'reconciliation_date')::date IS DISTINCT FROM t - 1
     OR (v_r->'rows'->1->>'reconciliation_date')::date IS DISTINCT FROM t THEN
    RAISE EXCEPTION 'FAIL relative_dates [reconcile_accounts_preview]: %', v_r; END IF;
  v_r := core.fn_dry_run('finance.fn_reconcile_accounts(jsonb)'::regprocedure, jsonb_build_object('accounts',
           jsonb_build_array(
             jsonb_build_object('account_name', '__rd_a__', 'confirmed_balance', '900', 'reconciliation_date', 'yesterday'),
             jsonb_build_object('account_name', '__rd_c__', 'confirmed_balance', '50'))));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR (v_r->'effective'->'accounts'->0->>'reconciliation_date')::date IS DISTINCT FROM t - 1
     OR (v_r->'effective'->'accounts'->1->>'reconciliation_date')::date IS DISTINCT FROM t
     OR v_r->'effective'->'accounts'->0->>'confirmed_balance' IS DISTINCT FROM '900' THEN
    RAISE EXCEPTION 'FAIL relative_dates [reconcile_accounts effective]: %', v_r; END IF;
  v_r := finance.fn_reconcile_accounts(jsonb_build_object('accounts', jsonb_build_array(
           jsonb_build_object('account_name', '__rd_a__', 'confirmed_balance', '900', 'reconciliation_date', 'vorgestern'))));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'invalid_date'
     OR position('__rd_a__' IN v_r->>'reason') = 0 THEN
    RAISE EXCEPTION 'FAIL relative_dates [reconcile_accounts Unsinn]: %', v_r; END IF;

  -- Import-Pfad: der Zeilen-Validator lehnt relative Texte weiter ab (Import = Dokument-Werte, nie relativ)
  IF COALESCE(finance.fn_import_validate_row(gen_random_uuid(), 1, 'recurring_payment',
       jsonb_build_object('name', 'X', 'first_payment_date', 'in 3 days')), '') NOT LIKE 'first_payment_date %not a valid DATE%' THEN
    RAISE EXCEPTION 'FAIL relative_dates [Import-Validator: %]', finance.fn_import_validate_row(gen_random_uuid(), 1,
      'recurring_payment', jsonb_build_object('name', 'X', 'first_payment_date', 'in 3 days')); END IF;

  RAISE NOTICE 'PASS relative_dates fachlich';
END $$;

ROLLBACK;
