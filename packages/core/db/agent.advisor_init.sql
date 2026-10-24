-- ============================================================
-- Advisor — Schema fuer Berater-Agenten (Phase 1: finance.advisor)
-- Zweck:   Persistenz der per Interview erstellten Plaene (Draft -> Publish -> Versionen).
--          DOMAENEN-NEUTRAL by design (Owner-Entscheidung, Greenfield-gratis): die Tabelle heisst
--          advisor_plans mit `domain`-Spalte, NICHT finance_advisor_plans — ein spaeterer
--          Career-Advisor nutzt dieselbe Tabelle/Functions mit domain='career', ohne Retrofit.
--
-- Lifecycle einer Plan-Zeile:
--   draft       -> in Arbeit; fn_advisor_save_section upsertet Sektionen in interview_state
--   active      -> publiziert; fn_advisor_publish_plan persistiert plan_md + upsertet das
--                  Domänen-Plan-Doc (finance -> 'financial_planning', WS-B2c; agent.core_contexts,
--                  lazy, global, managed_by='agent' [typisierte Spalte], package=Domain)
--   superseded  -> von einer neueren Version abgeloest (Versions-Audit, nie geloescht)
--
-- PERSON-SCOPE (P0c): Spalte person_id macht den Plan-Schluessel pro PERSON. NULL = Haushalt
--   (Finance-Konvention owner_person_id NULL=Haushalt) -> finance/financial_planning bleibt EIN
--   Haushalts-Plan (person_id NULL). per_user-Domaenen (career/career_planning, scope-Registry
--   core.context_scopes) tragen die reale person_id (aus chat_id via fn_resolve_sender, NIE LLM).
--   Die DB-Gesetze gelten je (domain, person_id); NULLS NOT DISTINCT haelt sie auch fuer die
--   household-NULL-Zeilen (sonst kollidieren zwei NULLs NICHT -> stiller Verlust des "ein-active").
--   FK person_id -> agent.persons(person_id) ON DELETE RESTRICT haengt core:V014 an (advisor_init
--   laeuft VOR persons_init = reihenfolge-tolerante Inits; die V-Phase laeuft nach allen Inits).
--
-- Invarianten (DB-Gesetz, nicht Prompt):
--   * genau EIN aktiver Plan pro (Domain, Person)  (Partial-UNIQUE advisor_plans_one_active_per_domain)
--   * genau EIN Draft pro (Domain, Person)          (Partial-UNIQUE advisor_plans_one_draft_per_domain;
--                                          fn_advisor_save_section zielt immer auf "den" Draft)
--   * (domain, person_id, version) eindeutig         (UNIQUE — Versions-Audit luegt nie)
--
-- section_key ist FREIER text, KEIN ENUM: der Sektionskatalog (DIN-77230-inspiriert) ist
-- Prompt-DATEN des jeweiligen Advisors, nicht Schema — neue Domaene = neuer Katalog, kein DDL.
--
-- Usage:   db_apply.ps1 -File packages\core\db\agent.advisor_init.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

-- ============================================================
-- TABLE
-- ============================================================

CREATE TABLE IF NOT EXISTS agent.advisor_plans (
    id              serial PRIMARY KEY,
    domain          text NOT NULL,         -- Pflicht (Phase B/core:V021: kein 'finance'-Default — Core kennt kein Paket)
    person_id       text,                  -- P0c: NULL = Haushalt (finance); reale person_id = per_user (career). FK -> agent.persons via core:V014.
    plan_name       text NOT NULL,
    status          text NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft', 'active', 'superseded')),
    version         int  NOT NULL DEFAULT 1 CHECK (version >= 1),
    interview_state jsonb NOT NULL DEFAULT '{}'::jsonb,   -- { "<section_key>": {content, data, saved_at}, ... }
    plan_md         text,                                  -- publizierter Voll-Plan (Markdown); NULL solange draft
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Invarianten (siehe Kopf-Kommentar). NULLS NOT DISTINCT (PG15+): zwei household-NULL-Zeilen
-- KOLLIDIEREN -> "genau ein active/draft pro (domain, person_id)" haelt auch fuer person_id=NULL
-- (sonst behandelt der Default NULLS DISTINCT zwei NULLs als verschieden -> stiller Verlust).
-- (Auf einer BESTANDS-DB sind diese Namen schon mit der alten (domain)-Form belegt -> IF NOT EXISTS
--  ueberspringt sie hier; core:V014 droppt+recreated sie auf die (domain, person_id)-Form.)
CREATE UNIQUE INDEX IF NOT EXISTS advisor_plans_one_active_per_domain
    ON agent.advisor_plans (domain, person_id) NULLS NOT DISTINCT WHERE status = 'active';
CREATE UNIQUE INDEX IF NOT EXISTS advisor_plans_one_draft_per_domain
    ON agent.advisor_plans (domain, person_id) NULLS NOT DISTINCT WHERE status = 'draft';
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'advisor_plans_domain_version_unique'
    ) THEN
        ALTER TABLE agent.advisor_plans
            ADD CONSTRAINT advisor_plans_domain_version_unique
            UNIQUE NULLS NOT DISTINCT (domain, person_id, version);
    END IF;
END $$;

-- ============================================================
-- TRIGGER: updated_at pflegen (gemeinsamer Helper aus finance.init.sql;
-- hier idempotent mit-definiert, damit advisor_init standalone anwendbar bleibt)
-- ============================================================

CREATE OR REPLACE FUNCTION agent.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at := NOW(); RETURN NEW; END; $$;

DROP TRIGGER IF EXISTS trg_advisor_plans_touch ON agent.advisor_plans;
CREATE TRIGGER trg_advisor_plans_touch
    BEFORE UPDATE ON agent.advisor_plans
    FOR EACH ROW EXECUTE FUNCTION agent.touch_updated_at();

-- ============================================================
-- LESE-ZUGRIFF auf advisor_plans (Paket-Isolation, O1): advisor_plans bleibt in `agent`
-- (Shared-Infra fuer einen kuenftigen Career-Advisor). Der Advisor-Agent laeuft unter der
-- ENGEN Paket-Leserolle finance_ro (schema-scoped auf finance) → er erreicht agent.advisor_plans
-- NICHT mehr direkt, sondern NUR ueber die publizierte SECURITY-DEFINER-Read-fn
-- core.fn_advisor_read_plan(text) (EXECUTE-GRANT in core.fn_provision_package_roles). Darum hier
-- KEIN direkter GRANT SELECT … TO finance_ro mehr (das war die Vor-Isolations-Form). Der Core-Host
-- (core_ro) liest advisor_plans ueber seinen breiten agent-Grant (util_create_core_ro), aber NUR die
-- Haushalts-Plaene (RLS unten); den Schreibpfad faehrt der Owner (fn_advisor_save_section/publish_plan);
-- die Core-Advisor-Engine (core.cron_review via core.fn_advisor_review_evaluate) liest den Plan ueber das
-- DEFINER-Fenster.
-- ============================================================

-- ROW-LEVEL-SECURITY (Owner-Entscheid 2026-10-24 "strikt privat"): Personen-Plaene (person_id NOT NULL, per_user-
-- Domaenen wie career) sind fuer den Frei-SQL-Pfad core_ro unsichtbar; die Person liest ihren Plan nur ueber das
-- gebundene Fenster core.fn_advisor_read_plan. Muster + Begruendung (current_user statt TO core_ro, Owner/DEFINER
-- umgehen RLS, VIEW-Falle) wie agent.core_contexts in agent.core_init.sql.
ALTER TABLE agent.advisor_plans ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS advisor_plans_all ON agent.advisor_plans;
CREATE POLICY advisor_plans_all ON agent.advisor_plans USING (TRUE) WITH CHECK (TRUE);
DROP POLICY IF EXISTS advisor_plans_ro_household_only ON agent.advisor_plans;
CREATE POLICY advisor_plans_ro_household_only ON agent.advisor_plans AS RESTRICTIVE FOR SELECT
    USING (current_user <> 'core_ro' OR person_id IS NULL);
