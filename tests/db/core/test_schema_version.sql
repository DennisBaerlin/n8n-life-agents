-- test_schema_version.sql — core.schema_version Migrations-Ledger (Flyway-Single-Table)
--   Vertrag VERSIONED (V{NNN}): erste Anwendung einer Version => TRUE + Eintrag; zweite
--   Anwendung derselben Version => FALSE (kein Doppellauf); geaenderte Checksumme einer
--   angewandten Version => Drift-EXCEPTION (unveraenderlich).
--   Vertrag REPEATABLE (R__): erste Anwendung => TRUE + Eintrag (kind='repeatable'); gleiche
--   Checksumme => FALSE (unveraendert, nicht neu fahren); GEAENDERTE Checksumme => TRUE
--   (Inhalt geaendert -> neu fahren; mutabel, KEINE Drift-Exception — das ist der bewusste
--   Gegensatz zum unveraenderlichen versioned-Pfad).
-- Self-contained: BEGIN ... ROLLBACK, kein Residual-State.

BEGIN;

-- 1) Idempotenz: zweiter Lauf fuehrt die V-Datei NICHT erneut aus.
DO $$
DECLARE r boolean;
BEGIN
    -- (kein GUC gesetzt -> Default-Paket 'core' -> der PK-Key wird paket-prefixed: 'core:V999')
    r := core.migration_should_apply('V999', 'V999__selftest.sql', 'checksum_a');
    IF r IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL: erste Anwendung von V999 muss TRUE liefern (anwenden), war %', r;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.schema_version WHERE version = 'core:V999') THEN
        RAISE EXCEPTION 'FAIL: V999 wurde nicht als prefixed Key (core:V999) im Ledger reserviert';
    END IF;

    r := core.migration_should_apply('V999', 'V999__selftest.sql', 'checksum_a');
    IF r IS NOT FALSE THEN
        RAISE EXCEPTION 'FAIL: zweite Anwendung von V999 muss FALSE liefern (kein Doppellauf), war %', r;
    END IF;
    IF (SELECT COUNT(*) FROM core.schema_version WHERE version = 'core:V999') <> 1 THEN
        RAISE EXCEPTION 'FAIL: V999 wurde doppelt ins Ledger geschrieben';
    END IF;
    RAISE NOTICE 'PASS: schema_version Idempotenz (zweiter Lauf = No-op)';
END $$;

-- 2) Drift-Guard: geaenderte Checksumme einer angewandten Version => Exception.
DO $$
DECLARE caught boolean := false;
BEGIN
    BEGIN
        PERFORM core.migration_should_apply('V999', 'V999__selftest.sql', 'checksum_DIFFERENT');
    EXCEPTION WHEN others THEN
        caught := true;
    END;
    IF NOT caught THEN
        RAISE EXCEPTION 'FAIL: geaenderte Checksumme einer angewandten Migration muss eine Drift-Exception werfen';
    END IF;
    RAISE NOTICE 'PASS: schema_version Drift-Guard (editierte Migration -> Exception)';
END $$;

-- 3) Leere Checksumme bleibt tolerant (ungeprueft -> kein Drift-Fehlalarm).
DO $$
DECLARE r boolean;
BEGIN
    r := core.migration_should_apply('V998', 'V998__nochecksum.sql', '');
    IF r IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL: V998 ohne Checksumme muss TRUE liefern';
    END IF;
    r := core.migration_should_apply('V998', 'V998__nochecksum.sql', '');
    IF r IS NOT FALSE THEN
        RAISE EXCEPTION 'FAIL: V998 zweiter Lauf muss FALSE liefern';
    END IF;
    RAISE NOTICE 'PASS: schema_version tolerant bei leerer Checksumme';
END $$;

-- 4) Repeatable: erste Anwendung => TRUE + Eintrag (kind='repeatable'); gleiche Checksumme
--    => FALSE (unveraendert); geaenderte Checksumme => TRUE (neu fahren, KEINE Exception).
DO $$
DECLARE r boolean;
BEGIN
    r := core.repeatable_should_apply('packages/core/db/migrations/R__selftest.sql', 'sum_v1');
    IF r IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL: erste Anwendung einer Repeatable muss TRUE liefern, war %', r;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.schema_version
                   WHERE version = 'packages/core/db/migrations/R__selftest.sql' AND kind = 'repeatable') THEN
        RAISE EXCEPTION 'FAIL: Repeatable wurde nicht mit kind=repeatable im Ledger eingetragen';
    END IF;

    r := core.repeatable_should_apply('packages/core/db/migrations/R__selftest.sql', 'sum_v1');
    IF r IS NOT FALSE THEN
        RAISE EXCEPTION 'FAIL: unveraenderte Repeatable (gleiche Checksumme) muss FALSE liefern, war %', r;
    END IF;

    r := core.repeatable_should_apply('packages/core/db/migrations/R__selftest.sql', 'sum_v2');
    IF r IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL: geaenderte Repeatable-Checksumme muss TRUE liefern (neu fahren), war %', r;
    END IF;
    IF (SELECT checksum FROM core.schema_version WHERE version = 'packages/core/db/migrations/R__selftest.sql') <> 'sum_v2' THEN
        RAISE EXCEPTION 'FAIL: Repeatable-Checksumme wurde beim Neu-Lauf nicht aktualisiert';
    END IF;
    IF (SELECT COUNT(*) FROM core.schema_version WHERE version = 'packages/core/db/migrations/R__selftest.sql') <> 1 THEN
        RAISE EXCEPTION 'FAIL: Repeatable darf nur EINE Ledger-Zeile haben (Update, kein zweiter INSERT)';
    END IF;
    RAISE NOTICE 'PASS: schema_version Repeatable (unveraendert=skip, geaendert=re-apply, mutabel)';
END $$;

-- 5) Paket-Eigentum (B1): die Session-GUC lifeagents.package steuert core.schema_version.package
--    (der paket-bewusste Apply-Treiber setzt sie pro Quell-Verzeichnis-Batch). Leer/ungesetzt -> 'core'.
DO $$
DECLARE pkg text;
BEGIN
    PERFORM set_config('lifeagents.package', 'finance', true);   -- is_local=true -> rollt mit der Transaktion zurueck
    PERFORM core.repeatable_should_apply('packages/finance/db/migrations/R__pkgtest_fin.sql', 'sum_fin');
    SELECT package INTO pkg FROM core.schema_version WHERE version = 'packages/finance/db/migrations/R__pkgtest_fin.sql';
    IF pkg IS DISTINCT FROM 'finance' THEN
        RAISE EXCEPTION 'FAIL: Repeatable unter GUC=finance muss package=finance bekommen, war %', pkg;
    END IF;

    PERFORM set_config('lifeagents.package', 'core', true);
    PERFORM core.migration_should_apply('V901', 'V901__pkgtest.sql', 'sum_core');
    SELECT package INTO pkg FROM core.schema_version WHERE version = 'core:V901';
    IF pkg IS DISTINCT FROM 'core' THEN
        RAISE EXCEPTION 'FAIL: Migration unter GUC=core muss package=core (Key core:V901) bekommen, war %', pkg;
    END IF;

    PERFORM set_config('lifeagents.package', '', true);          -- leer -> Default 'core' (rueckwaerts-kompatibel)
    PERFORM core.repeatable_should_apply('packages/core/db/migrations/R__pkgtest_def.sql', 'sum_def');
    SELECT package INTO pkg FROM core.schema_version WHERE version = 'packages/core/db/migrations/R__pkgtest_def.sql';
    IF pkg IS DISTINCT FROM 'core' THEN
        RAISE EXCEPTION 'FAIL: leere GUC muss auf package=core defaulten, war %', pkg;
    END IF;
    RAISE NOTICE 'PASS: schema_version Paket-Eigentum (GUC lifeagents.package -> package-Spalte, B1)';
END $$;

-- 6) Paket-Prefix verhindert Kollision (arch-challenge C): core V500 und finance V500 sind ZWEI
--    getrennte Ledger-Zeilen (core:V500 / finance:V500), beide laufen, keine faelscht uebersprungen.
DO $$
DECLARE r boolean;
BEGIN
    PERFORM set_config('lifeagents.package', 'core', true);
    r := core.migration_should_apply('V500', 'V500__x.sql', 'sum_core');
    IF r IS NOT TRUE THEN RAISE EXCEPTION 'FAIL collision: core V500 muss TRUE liefern, war %', r; END IF;

    PERFORM set_config('lifeagents.package', 'finance', true);
    r := core.migration_should_apply('V500', 'V500__y.sql', 'sum_fin');
    IF r IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL collision: finance V500 muss TRUE liefern (eigener Key), war % — Kollision mit core V500!', r;
    END IF;

    IF (SELECT COUNT(*) FROM core.schema_version WHERE version IN ('core:V500','finance:V500')) <> 2 THEN
        RAISE EXCEPTION 'FAIL collision: erwartet ZWEI getrennte Ledger-Zeilen (core:V500 + finance:V500)';
    END IF;
    PERFORM set_config('lifeagents.package', '', true);
    RAISE NOTICE 'PASS: schema_version Paket-Prefix (core:V500 + finance:V500 koexistieren, keine Kollision)';
END $$;

-- 7) Bestands-Fall (M2): eine UNPREFIXED Altzeile ('V951', package='finance') aus der Vor-Prefix-Zeit
--    (V951 = ungenutzte Testnummer, kollidiert nicht mit echten finance-Migrationen) wird vom
--    idempotenten Backfill auf 'finance:V951' gehoben -> migration_should_apply('V951') unter
--    GUC=finance liefert dann FALSE (KEIN Re-Run der nicht-idempotenten Migration). Re-Backfill = no-op.
DO $$
DECLARE r boolean; v_cnt int;
BEGIN
    -- Altzeile simulieren (wie sie ein Vor-Prefix-Apply hinterliess).
    INSERT INTO core.schema_version (version, filename, checksum, kind, package)
    VALUES ('V951', 'V951__legacy.sql', 'sum_legacy', 'versioned', 'finance');

    -- Der Backfill (Kopie der Init-Logik; in Prod laeuft er in schema_version_init Phase-0).
    UPDATE core.schema_version SET version = package || ':' || version
     WHERE kind = 'versioned' AND position(':' in version) = 0;

    IF NOT EXISTS (SELECT 1 FROM core.schema_version WHERE version = 'finance:V951') THEN
        RAISE EXCEPTION 'FAIL backfill: Altzeile V951 wurde nicht auf finance:V951 gehoben';
    END IF;
    IF EXISTS (SELECT 1 FROM core.schema_version WHERE version = 'V951') THEN
        RAISE EXCEPTION 'FAIL backfill: unprefixed Altzeile V951 blieb stehen';
    END IF;

    -- Re-Apply derselben Migration unter GUC=finance -> FALSE (kein Re-Run, Key matcht jetzt).
    PERFORM set_config('lifeagents.package', 'finance', true);
    r := core.migration_should_apply('V951', 'V951__legacy.sql', 'sum_legacy');
    IF r IS NOT FALSE THEN
        RAISE EXCEPTION 'FAIL backfill: V951 nach Backfill wuerde ERNEUT laufen (war %) — nicht-idempotente Migration doppelt!', r;
    END IF;

    -- Re-Backfill = idempotent (bereits-prefixte Zeilen unangetastet).
    SELECT COUNT(*) INTO v_cnt FROM core.schema_version WHERE version = 'finance:V951';
    UPDATE core.schema_version SET version = package || ':' || version
     WHERE kind = 'versioned' AND position(':' in version) = 0;
    IF (SELECT COUNT(*) FROM core.schema_version WHERE version = 'finance:V951') <> v_cnt THEN
        RAISE EXCEPTION 'FAIL backfill: Re-Run nicht idempotent (finance:V951 veraendert)';
    END IF;
    PERFORM set_config('lifeagents.package', '', true);
    RAISE NOTICE 'PASS: schema_version Bestands-Backfill (M2: V951->finance:V951, kein Re-Run, idempotent)';
END $$;

ROLLBACK;
