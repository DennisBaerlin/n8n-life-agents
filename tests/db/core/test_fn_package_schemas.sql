-- ============================================================
-- test_fn_package_schemas -- die eine Paket-Menge der Lebenszyklus-fns (Reset/Cleanup)
--   Gesetz: Quelle = package_registry UNION schema_version (faengt --keep-data deinstallierte Pakete), ohne 'core',
--   Namens-Regex ^[a-z][a-z0-9_]*$, nur wenn das Schema existiert, NICHT nach status gefiltert, alphabetisch.
--   Stub-Schemas zz_*: BEGIN...ROLLBACK -> kein Residual-State.
-- ============================================================
BEGIN;

CREATE SCHEMA zz_b_reg;        -- nur in der Registry, aktiv
CREATE SCHEMA zz_a_inactive;   -- Registry, inaktiv -> trotzdem dabei
CREATE SCHEMA zz_c_keepdata;   -- nur im schema_version-Ledger (deinstalliert mit --keep-data)
CREATE SCHEMA "ZZ_Upper";      -- Name verletzt die Regex -> nie dabei
INSERT INTO core.package_registry (package, status) VALUES
    ('zz_b_reg', 'active'), ('zz_a_inactive', 'inactive'), ('zz_d_noschema', 'active'), ('ZZ_Upper', 'active');
INSERT INTO core.schema_version (version, filename, package) VALUES
    ('zz_c_keepdata:V001', 'V001__x.sql', 'zz_c_keepdata'),
    ('zz_b_reg:V001', 'V001__x.sql', 'zz_b_reg');   -- Doppelnennung (Registry + Ledger) -> genau eine Zeile

DO $$
DECLARE
    v_all text[];
    v_zz  text[];
BEGIN
    SELECT array_agg(p) INTO v_all FROM core.fn_package_schemas() p;
    v_zz := ARRAY(SELECT x FROM unnest(v_all) x WHERE x LIKE 'zz\_%' OR x = 'ZZ_Upper');

    IF v_zz IS DISTINCT FROM ARRAY['zz_a_inactive', 'zz_b_reg', 'zz_c_keepdata'] THEN
        RAISE EXCEPTION 'FAIL [Menge]: %, erwartet {zz_a_inactive,zz_b_reg,zz_c_keepdata} (alphabetisch, inaktiv + Ledger-only dabei, ohne Schema/Regex-Verstoss, ohne Dubletten)', v_zz;
    END IF;
    RAISE NOTICE 'PASS [Menge]: Registry + Ledger, inaktiv dabei, Schema-Pflicht, Regex, dedupliziert';

    IF 'core' = ANY (v_all) THEN
        RAISE EXCEPTION 'FAIL [core]: core darf nie in der Paket-Menge stehen';
    END IF;
    RAISE NOTICE 'PASS [core]: core ausgeschlossen';

    -- globale Reihenfolge ist alphabetisch (deterministische Reihenfolge der Hooks/TRUNCATEs)
    IF v_all IS DISTINCT FROM ARRAY(SELECT x FROM unnest(v_all) x ORDER BY x) THEN
        RAISE EXCEPTION 'FAIL [Reihenfolge]: %', v_all;
    END IF;
    RAISE NOTICE 'PASS [Reihenfolge]: alphabetisch';

    -- ein Schema muss existieren: Paket verschwindet aus der Menge, sobald sein Schema weg ist
    DROP SCHEMA zz_c_keepdata;
    IF 'zz_c_keepdata' = ANY (ARRAY(SELECT core.fn_package_schemas())) THEN
        RAISE EXCEPTION 'FAIL [Schema weg]: Paket ohne Schema steht in der Menge';
    END IF;
    RAISE NOTICE 'PASS [Schema weg]: Paket ohne Schema faellt heraus';
END $$;
ROLLBACK;
