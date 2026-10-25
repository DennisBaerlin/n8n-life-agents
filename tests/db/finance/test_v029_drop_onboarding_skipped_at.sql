-- tests/db/finance/test_v029_drop_onboarding_skipped_at.sql
-- finance:V029: die ableitbare Spalte finance.onboarding_state.skipped_at verschwindet, Status und
-- status_changed_at der Bestandszeile bleiben. Der Test baut die Alt-Spalte in der Test-Tx nach und fuehrt die
-- ECHTE Migrationsdatei zweimal aus (zweiter Lauf = No-op).
BEGIN;

ALTER TABLE finance.onboarding_state ADD COLUMN IF NOT EXISTS skipped_at timestamptz;
INSERT INTO finance.onboarding_state (section_key, ord, label, status, skipped_at, status_changed_at)
VALUES ('__t_v029__', 99, 't', 'skipped', '2026-01-02 10:00+00', '2026-01-02 10:00+00');

\ir ../../../packages/finance/db/migrations/V029__drop_onboarding_skipped_at.sql
\ir ../../../packages/finance/db/migrations/V029__drop_onboarding_skipped_at.sql

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'finance' AND table_name = 'onboarding_state' AND column_name = 'skipped_at') THEN
    RAISE EXCEPTION 'FAIL [finance.onboarding_state.skipped_at nicht gedroppt]'; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.onboarding_state
                  WHERE section_key = '__t_v029__' AND status = 'skipped'
                    AND status_changed_at = '2026-01-02 10:00+00'::timestamptz) THEN
    RAISE EXCEPTION 'FAIL [Bestandszeile veraendert]'; END IF;
  RAISE NOTICE 'PASS finance:V029 [skipped_at weg, Status + status_changed_at bleiben, 2 Laeufe]';
END $$;

ROLLBACK;
