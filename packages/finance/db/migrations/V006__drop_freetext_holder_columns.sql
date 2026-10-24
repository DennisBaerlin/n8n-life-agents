-- ============================================================
-- V006 (finance) — Freitext-Inhaber abloesen (WS-4 Eigentuemer-Normalisierung).
--
--   Der typisierte *_person_id-FK (WS-1, -> agent.persons, NULL=Haushalt) ist seit WS-4 das EINZIGE
--   Inhaber-Feld. Die 5 redundanten Freitext-Inhaber fallen weg (Owner-Entscheid 2026-06-23: keine
--   Logik haengt am Freitext, er war reine Anzeige; Gemeinschaftskonten sind ueber owner_person_id=NULL
--   abgebildet -> kein M2M noetig). Getaggt wird ueber create_*/set_* (Personen-NAME ->
--   core.fn_resolve_person -> Slug). KEIN Auto-Backfill (Freitext-Name ist kein verlaesslicher Person-Key,
--   Mis-Assignment-Risiko) -> Bestand re-taggen via set_*.
--
--   REIHENFOLGE (Blocker: PostgreSQL blockt DROP COLUMN, solange eine View die Spalte referenziert).
--   Beim inkrementellen Re-Apply liegen die *_overview-Views aus dem letzten Lauf vor und joinen die
--   Freitext-Spalten -> daher hier ZUERST die 5 abhaengigen Views (CASCADE faengt *_summary-Folge-Views)
--   droppen, DANN DROP COLUMN. R__finance_views.sql (laeuft als R__ NACH den V) baut alle Views mit der
--   abgeleiteten Eigentuemer-Anzeige (LEFT JOIN core.fn_household_persons, NULL->'Haushalt') neu auf.
--
--   IDEMPOTENT: IF EXISTS auf View-Drop und Column-Drop; fresh -Reset traegt die Spalten gar nicht erst
--   (finance.tables_init ohne sie) -> DROP COLUMN IF EXISTS = no-op.
-- ============================================================

DROP VIEW IF EXISTS finance.account_overview     CASCADE;
DROP VIEW IF EXISTS finance.loan_overview        CASCADE;
DROP VIEW IF EXISTS finance.real_estate_overview CASCADE;
DROP VIEW IF EXISTS finance.pension_overview     CASCADE;
DROP VIEW IF EXISTS finance.active_insurances    CASCADE;

ALTER TABLE finance.accounts    DROP COLUMN IF EXISTS account_holder;
ALTER TABLE finance.real_estate DROP COLUMN IF EXISTS owner;
ALTER TABLE finance.pension     DROP COLUMN IF EXISTS owner;
ALTER TABLE finance.loans       DROP COLUMN IF EXISTS borrower;
ALTER TABLE finance.insurances  DROP COLUMN IF EXISTS policyholder;
