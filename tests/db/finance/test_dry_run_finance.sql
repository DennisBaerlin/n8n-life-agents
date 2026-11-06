-- tests/db/finance/test_dry_run_finance.sql
-- Probelauf vor der Karte (core.fn_dry_run) gegen echte finance-Write-fns:
--   (1) Guard: finance hat KEINE deferrable Constraints/Constraint-Trigger. Die feuern erst beim COMMIT, ein
--       Probelauf (Savepoint-Rollback) wuerde sie verpassen -> wer so etwas einfuehrt, muss den Probelauf ueberdenken.
--   (2) fn_create_account mit Saldo: Ergebnis kommt zurueck (balance), Konto + Eroeffnungsbuchung + Saldo-Trigger-Effekt
--       sind danach weg.
--   (3) Ablehnung (Kontonummer schon vergeben) kommt als ok:false mit reason zurueck.
BEGIN;

DO $$
DECLARE
    v_n   int;
    v_r   jsonb;
    v_acc int;
    v_tx  int;
BEGIN
    SELECT count(*) INTO v_n FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
     WHERE n.nspname = 'finance' AND c.condeferrable;
    IF v_n > 0 THEN RAISE EXCEPTION 'FAIL dry_run-Guard [% deferrable Constraint(s) in finance]', v_n; END IF;
    SELECT count(*) INTO v_n FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace
     WHERE n.nspname = 'finance' AND (t.tgdeferrable OR t.tgconstraint <> 0) AND NOT t.tgisinternal;
    IF v_n > 0 THEN RAISE EXCEPTION 'FAIL dry_run-Guard [% Constraint-Trigger in finance]', v_n; END IF;

    SELECT count(*) INTO v_acc FROM finance.accounts;
    SELECT count(*) INTO v_tx  FROM finance.transactions;

    v_r := core.fn_dry_run('finance.fn_create_account(jsonb)'::regprocedure,
             jsonb_build_object('name', 'DryRun Probe Giro', 'account_type', 'cash', 'opening_balance', 321.5,
                                'account_number', 'DE89 3704 0044 0532 0130 00'));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'balance')::numeric IS DISTINCT FROM 321.5 THEN
        RAISE EXCEPTION 'FAIL dry_run create_account [Ergebnis: %]', v_r; END IF;
    SELECT count(*) INTO v_n FROM finance.accounts;
    IF v_n <> v_acc THEN RAISE EXCEPTION 'FAIL dry_run create_account [Konto nicht zurueckgerollt]'; END IF;
    SELECT count(*) INTO v_n FROM finance.transactions;
    IF v_n <> v_tx THEN RAISE EXCEPTION 'FAIL dry_run create_account [Eroeffnungsbuchung nicht zurueckgerollt]'; END IF;

    -- echte Anlage, danach Probelauf mit derselben Kontonummer -> Ablehnung als Daten
    v_r := finance.fn_create_account(jsonb_build_object('name', 'DryRun Real Giro', 'account_type', 'cash',
                                     'account_number', 'DE89370400440532013000'));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL dry_run Setup [%]', v_r; END IF;
    v_r := core.fn_dry_run('finance.fn_create_account(jsonb)'::regprocedure,
             jsonb_build_object('name', 'DryRun Zweitkonto', 'account_type', 'cash', 'account_number', 'DE89370400440532013000'));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' NOT LIKE '%already belongs%' THEN
        RAISE EXCEPTION 'FAIL dry_run create_account [Kontonummer-Ablehnung: %]', v_r; END IF;

    RAISE NOTICE 'PASS dry_run finance [kein deferrable, create_account zurueckgerollt inkl. Saldo, Ablehnung als Daten]';
END $$;

ROLLBACK;
