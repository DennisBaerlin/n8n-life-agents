-- tests/db/core/test_schema_version_checksum_repair.sql
-- Pruefsummen-Reparatur in core.schema_version_init.sql: Eine Bestands-Instanz mit alter Pruefsumme uebernimmt die neue, ohne die
-- Migration erneut zu fahren; eine frische Installation wendet die Datei normal an; ein zweiter Lauf aendert nichts. Andere Zeilen
-- und unbekannte Summen bleiben unberuehrt, der Drift-Guard greift weiter.
BEGIN;

DELETE FROM core.schema_version WHERE package = 'finance' AND version LIKE 'finance:V%';
INSERT INTO core.schema_version (version, filename, checksum, kind, package) VALUES
    ('finance:V019', 'V019__takeover_unit_price.sql', '792da0100d57be7e1f8bb39c5b278e28', 'versioned', 'finance'),
    ('finance:V998', 'V998__fremd.sql', '792da0100d57be7e1f8bb39c5b278e28', 'versioned', 'finance'),
    ('finance:V999', 'V999__fremd.sql', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'versioned', 'finance');

\ir ../../../packages/core/db/core.schema_version_init.sql

DO $$
DECLARE
  v_applied timestamptz;
BEGIN
  IF (SELECT checksum FROM core.schema_version WHERE version = 'finance:V019') <> '8ef1e3d00d824f7e54f8f8418ecb5549' THEN
    RAISE EXCEPTION 'FAIL [Bestand]: neue Pruefsumme nicht uebernommen'; END IF;
  IF (SELECT checksum FROM core.schema_version WHERE version = 'finance:V998') <> '792da0100d57be7e1f8bb39c5b278e28' THEN
    RAISE EXCEPTION 'FAIL [andere Migration veraendert]'; END IF;
  IF (SELECT checksum FROM core.schema_version WHERE version = 'finance:V999') <> 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' THEN
    RAISE EXCEPTION 'FAIL [unbekannte Summe veraendert]'; END IF;

  -- Der Treiber ueberspringt die Datei jetzt: kein erneuter Lauf, kein Drift-Abbruch
  PERFORM set_config('lifeagents.package', 'finance', true);
  IF core.migration_should_apply('V019', 'V019__takeover_unit_price.sql', '8ef1e3d00d824f7e54f8f8418ecb5549') THEN
    RAISE EXCEPTION 'FAIL [Bestand]: Migration wuerde erneut laufen'; END IF;

  -- Der Drift-Guard bleibt scharf: die alte Summe gilt nicht mehr, eine fremde erst recht nicht
  BEGIN
    PERFORM core.migration_should_apply('V019', 'V019__takeover_unit_price.sql', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
    RAISE EXCEPTION 'FAIL [Drift-Guard]: fremde Summe nicht abgewiesen' USING ERRCODE = 'P0002';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%anderem Inhalt%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS Reparatur [Bestand uebernimmt neue Summe, Datei wird uebersprungen, Drift-Guard scharf]';
END $$;

-- Zweiter Lauf: aendert nichts
CREATE TEMP TABLE t_repair_first ON COMMIT DROP AS SELECT version, checksum FROM core.schema_version WHERE version LIKE 'finance:V%';
\ir ../../../packages/core/db/core.schema_version_init.sql
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM core.schema_version s JOIN t_repair_first f USING (version) WHERE s.checksum <> f.checksum) THEN
    RAISE EXCEPTION 'FAIL [zweiter Lauf]'; END IF;

  -- Frische Installation: keine Zeile, die Reparatur tut nichts, die Datei wird normal angewandt
  DELETE FROM core.schema_version WHERE version = 'finance:V019';
END $$;
\ir ../../../packages/core/db/core.schema_version_init.sql
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM core.schema_version WHERE version = 'finance:V019') THEN
    RAISE EXCEPTION 'FAIL [frisch]: Reparatur legt eine Zeile an'; END IF;
  PERFORM set_config('lifeagents.package', 'finance', true);
  IF NOT core.migration_should_apply('V019', 'V019__takeover_unit_price.sql', '8ef1e3d00d824f7e54f8f8418ecb5549') THEN
    RAISE EXCEPTION 'FAIL [frisch]: Migration wird nicht angewandt'; END IF;
  IF (SELECT checksum FROM core.schema_version WHERE version = 'finance:V019') <> '8ef1e3d00d824f7e54f8f8418ecb5549' THEN
    RAISE EXCEPTION 'FAIL [frisch]: neue Summe nicht gespeichert'; END IF;
  RAISE NOTICE 'PASS Reparatur [zweiter Lauf ohne Wirkung, frische Installation wendet normal an]';
END $$;

ROLLBACK;
