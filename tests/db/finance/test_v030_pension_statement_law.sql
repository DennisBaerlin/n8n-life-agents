-- tests/db/finance/test_v030_pension_statement_law.sql
-- finance:V030 (Renteninformation-Plan 2026-10-26): Altbestand vor den neuen Gesetzen aufraeumen. Der Test baut den
-- Altzustand in der Test-Tx nach (Constraints/Index weg, gesetzliche Rente mit eigener Monatsrente/Wert, zwei aktive
-- gesetzliche Renten des Haushalts) und fuehrt die ECHTE Migration zweimal aus (zweiter Lauf = No-op).
BEGIN;

ALTER TABLE finance.pension DROP CONSTRAINT IF EXISTS finance_pension_statutory_no_amounts;
DROP INDEX IF EXISTS finance.finance_pension_statutory_uq;
INSERT INTO finance.pension (name, pension_type, guaranteed_monthly_pension, current_value, notes)
VALUES ('__t_v030 DRV alt', 'statutory', 1800.00, 5000.00, 'aus dem Chat');
INSERT INTO finance.pension (name, pension_type) VALUES ('__t_v030 DRV doppelt', 'statutory');
INSERT INTO finance.pension (name, pension_type, guaranteed_monthly_pension) VALUES ('__t_v030 bAV', 'occupational', 150.00);
-- Zustand nach dem Init auf einer Bestands-DB: der CHECK existiert NOT VALID (prueft nur neue Zeilen)
ALTER TABLE finance.pension ADD CONSTRAINT finance_pension_statutory_no_amounts
    CHECK (pension_type <> 'statutory' OR (guaranteed_monthly_pension IS NULL AND current_value IS NULL)) NOT VALID;

\ir ../../../packages/finance/db/migrations/V030__pension_statement_law.sql
\ir ../../../packages/finance/db/migrations/V030__pension_statement_law.sql

DO $$
BEGIN
  -- (1) Betraege der gesetzlichen Rente wandern in die Notiz, die Spalten werden leer
  IF (SELECT guaranteed_monthly_pension IS NULL AND current_value IS NULL
             AND notes LIKE 'aus dem Chat%1800.00%5000.00%'
      FROM finance.pension WHERE name = '__t_v030 DRV alt') IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [V030 Betraege -> Notiz]: %', (SELECT row_to_json(p) FROM finance.pension p WHERE name = '__t_v030 DRV alt'); END IF;
  -- bAV unberuehrt
  IF (SELECT guaranteed_monthly_pension FROM finance.pension WHERE name = '__t_v030 bAV') IS DISTINCT FROM 150.00 THEN
    RAISE EXCEPTION 'FAIL [V030 bAV veraendert]'; END IF;
  -- (2) zweite aktive gesetzliche Rente desselben Eigentuemers (Haushalt) -> pausiert mit Hinweis, die aeltere bleibt aktiv
  IF (SELECT status FROM finance.pension WHERE name = '__t_v030 DRV alt') <> 'active'
     OR (SELECT status::text || '|' || (notes LIKE '%V030%') FROM finance.pension WHERE name = '__t_v030 DRV doppelt') <> 'paused|true' THEN
    RAISE EXCEPTION 'FAIL [V030 Dublette]: %', (SELECT jsonb_agg(row_to_json(p)) FROM finance.pension p WHERE name LIKE '__t_v030 DRV%'); END IF;
  -- (3) Gesetze scharf: CHECK validiert, UNIQUE-Index da
  IF NOT (SELECT convalidated FROM pg_constraint WHERE conname = 'finance_pension_statutory_no_amounts')
     OR to_regclass('finance.finance_pension_statutory_uq') IS NULL THEN
    RAISE EXCEPTION 'FAIL [V030 Gesetze nicht scharf]'; END IF;
  RAISE NOTICE 'PASS finance:V030 [Betraege -> Notiz, Dublette pausiert, CHECK validiert, UNIQUE da, 2 Laeufe]';
END $$;

ROLLBACK;
