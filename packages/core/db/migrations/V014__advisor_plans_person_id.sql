-- ============================================================
-- V014 (core) — agent.advisor_plans person-skopieren (P0c) + die 1-Arg-read_plan-Signatur droppen.
--
--   WARUM eine V-Migration: (1) ADD COLUMN + Partial-UNIQUE-Umbau lassen sich nicht idempotent ueber
--   CREATE-OR-REPLACE ausdruecken; ALTER kann NULLS NOT DISTINCT NICHT an einen bestehenden Index/Constraint
--   retrofitten -> DROP+CREATE. (2) CREATE OR REPLACE kann die ARITAET von core.fn_advisor_read_plan nicht
--   aendern: R__ legt jetzt (text, text DEFAULT NULL) an; die alte (text)-Form muss EINMALIG weg (sonst
--   "function is not unique" beim 1-Arg-Call, der den DEFAULT der 2-Arg-Form matcht — Muster V013).
--
--   PERSON-SCOPE (Option A, arch-challenge): person_id text NULL=Haushalt (Finance-Konvention
--   owner_person_id NULL=Haushalt). finance-Bestandszeilen bleiben NULL (kein Backfill, verhaltensneutral);
--   die DB-Gesetze "ein active/draft pro (domain, person_id)" halten ueber NULLS NOT DISTINCT auch fuer die
--   NULL-Zeilen. Der CAREER-Daten-Backfill (career_planning-Zeilen -> Owner-pid) lebt in career:V002 (career
--   kennt sich selbst; zur core-Migrationszeit ist die career-scope-Registry noch household-geseedet). Core
--   nennt KEIN Paket -> reine generische Schema-Migration.
--
--   FK person_id -> agent.persons(person_id) ON DELETE RESTRICT: hier (V-Phase laeuft NACH allen Inits ->
--   agent.persons existiert; agent.advisor_init laeuft als reihenfolge-toleranter Init VOR persons_init und
--   kann den FK selbst nicht setzen). Guarded + idempotent.
--
--   SICHER: finance-Zeilen alle person_id NULL, (domain,version) war eindeutig -> (domain,NULL,version) mit
--   NULLS NOT DISTINCT bleibt eindeutig (kein Dup beim Constraint-Rebuild). Fresh DB: der Init legt Spalte +
--   neue Index-/Constraint-Form schon an -> die DROP/CREATE hier sind idempotent (gleiche Endform); die
--   1-Arg-read_plan entstand nie -> DROP no-op.
--
-- APPLY-ORDER: Inits -> V (hier) -> R (R__fn_advisor_read_plan legt 2-Arg an; R__fn_provision_package_roles
--   grantet die 2-Arg-Form bei Paket-Install) -> util. Re-run-sicher.
-- ============================================================

-- (1) Spalte (Bestand; fresh hat sie aus dem Init) + FK (guarded, persons existiert in der V-Phase).
ALTER TABLE agent.advisor_plans ADD COLUMN IF NOT EXISTS person_id text;

DO $$ BEGIN
    IF to_regclass('agent.persons') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'advisor_plans_person_id_fkey') THEN
        ALTER TABLE agent.advisor_plans
            ADD CONSTRAINT advisor_plans_person_id_fkey
            FOREIGN KEY (person_id) REFERENCES agent.persons(person_id) ON DELETE RESTRICT;
    END IF;
END $$;

-- (2) Partial-UNIQUE-Gesetze von (domain) auf (domain, person_id) NULLS NOT DISTINCT umbauen.
DROP INDEX IF EXISTS agent.advisor_plans_one_active_per_domain;
DROP INDEX IF EXISTS agent.advisor_plans_one_draft_per_domain;
CREATE UNIQUE INDEX advisor_plans_one_active_per_domain
    ON agent.advisor_plans (domain, person_id) NULLS NOT DISTINCT WHERE status = 'active';
CREATE UNIQUE INDEX advisor_plans_one_draft_per_domain
    ON agent.advisor_plans (domain, person_id) NULLS NOT DISTINCT WHERE status = 'draft';

-- (3) Versions-Audit von (domain, version) auf (domain, person_id, version) NULLS NOT DISTINCT.
ALTER TABLE agent.advisor_plans DROP CONSTRAINT IF EXISTS advisor_plans_domain_version_unique;
ALTER TABLE agent.advisor_plans
    ADD CONSTRAINT advisor_plans_domain_version_unique
    UNIQUE NULLS NOT DISTINCT (domain, person_id, version);

-- (4) Die alte 1-Arg-Read-fn droppen (R__ legt (text, text DEFAULT NULL) an). Kein DB-Objekt haengt daran.
DROP FUNCTION IF EXISTS core.fn_advisor_read_plan(text);
