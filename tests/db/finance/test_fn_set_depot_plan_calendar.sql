-- ============================================================
-- test_fn_set_depot_plan_calendar -- die eine Schreibstelle fuer accounts.plan_execution_days aus dem Sparplan-Pfad
--   calendar_changed true  -> Kalender wird am Depot gespeichert (auch '[]' = echte 7-Tage-Abstaende -> '{}')
--   calendar_changed false/fehlt -> Depot bleibt unveraendert (auch bei abweichendem calendar)
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_settle INT;
    v_depot  INT;
    v_days   SMALLINT[];
BEGIN
    v_settle := (finance.fn_create_account(jsonb_build_object('name', '__t_pc_cash__', 'account_type', 'cash', 'currency', 'EUR'))->>'account_id')::int;
    v_depot  := (finance.fn_create_account(jsonb_build_object('name', '__t_pc_depot__', 'account_type', 'stocks_depot',
                     'currency', 'EUR', 'settlement_id', v_settle))->>'account_id')::int;

    -- Ausgangslage: ein frisches Depot kennt keinen Kalender
    SELECT plan_execution_days INTO v_days FROM finance.accounts WHERE id = v_depot;

    -- calendar_changed = true -> gespeichert
    PERFORM finance.fn_set_depot_plan_calendar(v_depot, '{"calendar_changed": true, "calendar": [2, 9, 16, 23]}'::jsonb);
    SELECT plan_execution_days INTO v_days FROM finance.accounts WHERE id = v_depot;
    IF v_days IS DISTINCT FROM ARRAY[2,9,16,23]::smallint[] THEN
        RAISE EXCEPTION 'FAIL [changed=true]: plan_execution_days = %, erwartet {2,9,16,23}', v_days;
    END IF;
    RAISE NOTICE 'PASS [changed=true]: Kalender gespeichert';

    -- calendar_changed = false -> unveraendert, auch wenn calendar anders ist
    PERFORM finance.fn_set_depot_plan_calendar(v_depot, '{"calendar_changed": false, "calendar": [1, 15]}'::jsonb);
    SELECT plan_execution_days INTO v_days FROM finance.accounts WHERE id = v_depot;
    IF v_days IS DISTINCT FROM ARRAY[2,9,16,23]::smallint[] THEN
        RAISE EXCEPTION 'FAIL [changed=false]: plan_execution_days = %, soll unveraendert {2,9,16,23} bleiben', v_days;
    END IF;
    RAISE NOTICE 'PASS [changed=false]: Depot bleibt unveraendert';

    -- Schluessel fehlt (NULL) -> wie false
    PERFORM finance.fn_set_depot_plan_calendar(v_depot, '{"calendar": [5]}'::jsonb);
    SELECT plan_execution_days INTO v_days FROM finance.accounts WHERE id = v_depot;
    IF v_days IS DISTINCT FROM ARRAY[2,9,16,23]::smallint[] THEN
        RAISE EXCEPTION 'FAIL [ohne Flag]: plan_execution_days = %', v_days;
    END IF;
    RAISE NOTICE 'PASS [ohne Flag]: fehlendes calendar_changed schreibt nicht';

    -- leerer Kalender mit changed=true = echte 7-Tage-Abstaende ('{}', nicht NULL = unbekannt)
    PERFORM finance.fn_set_depot_plan_calendar(v_depot, '{"calendar_changed": true, "calendar": []}'::jsonb);
    SELECT plan_execution_days INTO v_days FROM finance.accounts WHERE id = v_depot;
    IF v_days IS DISTINCT FROM ARRAY[]::smallint[] THEN
        RAISE EXCEPTION 'FAIL [leer]: plan_execution_days = %, erwartet {} (7-Tage-Abstaende)', v_days;
    END IF;
    RAISE NOTICE 'PASS [leer]: leerer Kalender = {} (nicht NULL)';

    -- nur das eigene Depot wird geschrieben
    IF EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_settle AND plan_execution_days IS NOT NULL) THEN
        RAISE EXCEPTION 'FAIL [Isolation]: ein fremdes Konto hat einen Kalender bekommen';
    END IF;
END $$;
ROLLBACK;
