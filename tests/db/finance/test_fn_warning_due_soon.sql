-- tests/db/finance/test_fn_warning_due_soon.sql
-- finance.fn_warning_due_soon(p_on) — liegt ein Warnungs-Datum innerhalb von finance.advisor.handoff_urgent_days (ab heute)?
--   1) Default 30 ohne Config-Zeile: heute und Tag 30 ja, Tag 31 nein, Vergangenes ja, kein Datum nein.
--   2) Config 10: Tag 10 ja, Tag 11 nein.
--   3) Kaputter Config-Wert -> Default 30.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  t date := core.fn_today();
BEGIN
  DELETE FROM core.config WHERE category = 'advisor' AND key = 'handoff_urgent_days';
  IF NOT finance.fn_warning_due_soon(t) THEN RAISE EXCEPTION 'FAIL [1a] heute ist bald'; END IF;
  IF NOT finance.fn_warning_due_soon(t + 30) THEN RAISE EXCEPTION 'FAIL [1b] Tag 30 zaehlt noch (Default 30)'; END IF;
  IF finance.fn_warning_due_soon(t + 31) THEN RAISE EXCEPTION 'FAIL [1c] Tag 31 ist nicht mehr bald'; END IF;
  IF NOT finance.fn_warning_due_soon(t - 2) THEN RAISE EXCEPTION 'FAIL [1d] ein schon erreichtes Datum ist bald'; END IF;
  IF finance.fn_warning_due_soon(NULL) IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [1e] ohne Datum nicht bald'; END IF;
  RAISE NOTICE 'PASS [1] Default 30, Grenztag, Vergangenes, kein Datum';

  INSERT INTO core.config (category, key, value, package, value_type, minimum, maximum)
  VALUES ('advisor', 'handoff_urgent_days', '10', 'finance', 'integer', 1, 365);
  IF NOT finance.fn_warning_due_soon(t + 10) THEN RAISE EXCEPTION 'FAIL [2a] Tag 10 zaehlt bei Config 10'; END IF;
  IF finance.fn_warning_due_soon(t + 11) THEN RAISE EXCEPTION 'FAIL [2b] Tag 11 nicht mehr bei Config 10'; END IF;
  RAISE NOTICE 'PASS [2] Config-Wert gilt';

  ALTER TABLE core.config DISABLE TRIGGER USER;
  UPDATE core.config SET value = 'abc' WHERE category = 'advisor' AND key = 'handoff_urgent_days';
  ALTER TABLE core.config ENABLE TRIGGER USER;
  IF NOT finance.fn_warning_due_soon(t + 30) OR finance.fn_warning_due_soon(t + 31) THEN
    RAISE EXCEPTION 'FAIL [3] kaputter Wert -> Default 30'; END IF;
  RAISE NOTICE 'PASS [3] kaputter Config-Wert -> Default';
END $$;
ROLLBACK;
