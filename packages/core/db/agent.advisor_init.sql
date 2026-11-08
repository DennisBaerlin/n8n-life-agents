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
    interview_state jsonb NOT NULL DEFAULT '{}'::jsonb,   -- { "<section_key>": {content | topics[{topic,content,data,saved_at}] + legacy_content/legacy_data, data, saved_at}, ... }
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

-- Plan teilen (2026-10-28): Provenienz der Version (Ausnahme (c) "Provenienz/Snapshot", nicht ableitbar): die vom
-- Berater formulierte Aenderungs-Zusammenfassung beim Publish + die Sprache des veroeffentlichenden Owners (Text in
-- Originalsprache, nie uebersetzt; die Mitglieder-Nachricht zeigt ihn nur bei gleicher Sprache).
-- Gesetzt NUR von agent.fn_advisor_publish_plan.
ALTER TABLE agent.advisor_plans ADD COLUMN IF NOT EXISTS change_summary text;
ALTER TABLE agent.advisor_plans ADD COLUMN IF NOT EXISTS change_summary_lang text;

-- Gesamtcheck vor dem Veroeffentlichen (Provenienz der Version, Ausnahme (c)): die Funde, die der Berater mit dem Nutzer
-- geklaert hat, je {text, outcome resolved|deferred|accepted}, und die Zahl der Durchgaenge. Beide gesetzt oder beide NULL
-- (NULL = Version ohne Gesamtcheck). Gesetzt NUR von agent.fn_advisor_publish_plan, die auch die
-- Elementform prueft; der CHECK ist der Backstop fuer die Form.
ALTER TABLE agent.advisor_plans ADD COLUMN IF NOT EXISTS check_findings jsonb;
ALTER TABLE agent.advisor_plans ADD COLUMN IF NOT EXISTS check_passes int;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'advisor_plans_final_check_shape') THEN
        ALTER TABLE agent.advisor_plans ADD CONSTRAINT advisor_plans_final_check_shape CHECK (
            (check_findings IS NULL) = (check_passes IS NULL)
            AND (check_findings IS NULL OR jsonb_typeof(check_findings) = 'array')
            AND (check_passes IS NULL OR check_passes >= 1));
    END IF;
END $$;

-- Wuensche erwachsener Mitglieder an den Owner zu einem veroeffentlichten Haushalts-Plan ("Wunsch an den Owner").
-- Wortlaut in Originalsprache (nie uebersetzt). plan_id = die aktive Version beim Wunsch (Provenienz: "offen" heisst
-- abgeleitet "plan_id ist noch die aktive Version"). Personen-FK in core:V034 (dieses Init laeuft vor persons_init,
-- Muster V014). Schreiber nur agent.fn_record_plan_wish. Frei-SQL (core_ro) gesperrt: Deny-Liste util_create_core_ro.
CREATE TABLE IF NOT EXISTS agent.advisor_plan_wishes (
    id         serial PRIMARY KEY,
    plan_id    int  NOT NULL REFERENCES agent.advisor_plans(id) ON DELETE CASCADE,
    person_id  text NOT NULL,
    wish_text  text NOT NULL CHECK (btrim(wish_text) <> '' AND length(wish_text) <= 2000),
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Folge-Bindung nach einem Knopf-Tipp (arch-challenge 2026-10-28, Muster "aktiver Handler je Chat" wie Rasa active_loop /
-- PTB ConversationHandler): ein Knopf startet einen Agenten am Router vorbei; die NAECHSTE Text-Nachricht dieses Chats
-- bekommt den Router-Hinweis followup_agent (einmalig, TTL beim Lesen). Eine Zeile je Chat, ein neuer Knopf
-- ueberschreibt (last write wins). Schreiber agent.fn_set_dispatch_followup, Leser+Loescher agent.fn_take_dispatch_followup.
-- Bei uns anders: einmalig statt bis zum Handoff (ab dem ersten gerouteten Folge-Turn traegt das Router-Gedaechtnis die
-- Sticky-Regel) und je Chat statt (chat, user) (nur Privatchats).
CREATE TABLE IF NOT EXISTS agent.dispatch_followup (
    chat_id text PRIMARY KEY CHECK (chat_id ~ '^[0-9]{1,18}$'),
    agent   text NOT NULL CHECK (agent ~ '^agent\.[a-z][a-z0-9_]*$'),
    set_at  timestamptz NOT NULL DEFAULT now()
);

-- Uebergabe Berater -> Buchhalter (Task-Lebenszyklus nach A2A; Uebergabe ueber einen
-- deterministischen Orchestrator-Callback-Arm statt Agent->Agent). Was der Nutzer in einem Plan-Abschnitt vereinbart hat
-- und gebucht werden muss (Sparziel, Sparplan, Dauerauftrag ...), legt agent.fn_advisor_save_section mit dem Abschnitt
-- an (hinter der Abschnitts-Karte); der Knopf [Durchgehen] (core.fn_handle_handoff_cb) beansprucht die Aufgaben,
-- der Buchhalter fuehrt sie einzeln hinter seinen normalen Karten aus.
-- Lebenszyklus: open -> working (Claim, claimed_at; nach der TTL advisor.handoff_claim_ttl_minutes neu beanspruchbar,
-- Fehler -> zurueck auf open) -> done | cancelled. Endzustaende sind unveraenderlich (Trigger). open verfaellt nie.
-- package = Lifecycle-/Purge-Owner (fn_pkg_purge_data), domain = fachliche Plan-Domain; das Ziel-Agent loest der Build
-- aus dem Manifest (advisors.<domain>.handoff_agent), keine Agenten-Spalte. person_id = die Person, die zugestimmt hat
-- (aus der chat_id, nie LLM); Personen-FK in core:V035 (dieses Init laeuft vor persons_init, Muster V034).
-- kind = grobe Art fuer den Buchhalter (Validierung der Werte bleibt allein der Probelauf der Ziel-fn), payload = die
-- rohen Nutzerwerte, text = der Alltags-Satz fuer Karte und Uebersicht (Gespraechssprache, nie uebersetzt).
-- Schreiber: agent.fn_advisor_save_section (anlegen/ersetzen), core.fn_handle_handoff_cb + core.fn_release_handoff_tasks
-- (Claim), core.fn_complete_handoff_task / core.fn_cancel_handoff_task (Endzustand). Frei-SQL (core_ro) gesperrt:
-- Deny-Liste util_create_core_ro.
CREATE TABLE IF NOT EXISTS agent.handoff_tasks (
    id          serial PRIMARY KEY,
    domain      text NOT NULL CHECK (btrim(domain) <> ''),
    package     text NOT NULL CHECK (package ~ '^[a-z][a-z0-9_]*$'),
    person_id   text NOT NULL,
    section_key text NOT NULL CHECK (btrim(section_key) <> ''),
    kind        text NOT NULL CHECK (kind IN ('savings_goal', 'savings_plan', 'recurring_payment', 'recurring_transfer', 'other')),
    payload     jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
    text        text NOT NULL CHECK (btrim(text) <> '' AND length(text) <= 300),
    status      text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'working', 'done', 'cancelled')),
    claimed_at  timestamptz,                -- Provenienz des Claims (Ausnahme (c)): wann [Durchgehen] die Aufgabe beanspruchte
    created_at  timestamptz NOT NULL DEFAULT now(),
    closed_at   timestamptz,                -- Provenienz des Endzustands (Ausnahme (c))
    CONSTRAINT handoff_tasks_claim_check  CHECK (status <> 'working' OR claimed_at IS NOT NULL),
    CONSTRAINT handoff_tasks_closed_check CHECK ((status IN ('done', 'cancelled')) = (closed_at IS NOT NULL))
);
-- topic = das Thema des Abschnitts, in dem die Aufgabe vereinbart wurde (NULL = Abschnitt ohne Themen oder vor den Themen);
-- ein Themen-Save ersetzt die offenen Aufgaben seines Themas plus die themenlosen des Abschnitts (agent.fn_advisor_save_section).
ALTER TABLE agent.handoff_tasks ADD COLUMN IF NOT EXISTS topic text;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'handoff_tasks_topic_check') THEN
        ALTER TABLE agent.handoff_tasks ADD CONSTRAINT handoff_tasks_topic_check
            CHECK (topic IS NULL OR (btrim(topic) <> '' AND length(topic) <= 60));
    END IF;
END $$;
CREATE INDEX IF NOT EXISTS handoff_tasks_open_idx ON agent.handoff_tasks (domain, person_id, status);

-- Endzustand-Gesetz: done/cancelled aendert niemand mehr (auch kein Re-Open). DELETE bleibt erlaubt (Purge, E2E-Cleanup).
CREATE OR REPLACE FUNCTION agent.fn_handoff_tasks_final_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status IN ('done', 'cancelled') THEN
        RAISE EXCEPTION 'agent.handoff_tasks: task % is % and can no longer change', OLD.id, OLD.status;
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_handoff_tasks_final ON agent.handoff_tasks;
CREATE TRIGGER trg_handoff_tasks_final
    BEFORE UPDATE ON agent.handoff_tasks
    FOR EACH ROW EXECUTE FUNCTION agent.fn_handoff_tasks_final_guard();

-- ============================================================
-- LESE-ZUGRIFF auf advisor_plans (Paket-Isolation, O1): advisor_plans bleibt in `agent`
-- (Shared-Infra fuer einen kuenftigen Career-Advisor). Der Advisor-Agent laeuft unter der
-- ENGEN Paket-Leserolle finance_ro (schema-scoped auf finance) → er erreicht agent.advisor_plans
-- NICHT mehr direkt, sondern NUR ueber die publizierte SECURITY-DEFINER-Read-fn
-- core.fn_advisor_read_plan(text) (EXECUTE-GRANT in core.fn_provision_package_roles). Darum hier
-- KEIN direkter GRANT SELECT … TO finance_ro mehr (das war die Vor-Isolations-Form). core_ro liest
-- advisor_plans nicht (nicht auf der Erlaubnisliste in util_create_core_ro); die RLS unten bleibt als zweiter
-- Riegel fuer die Personen-Plaene stehen; den Schreibpfad faehrt der Owner (fn_advisor_save_section/publish_plan);
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
    USING (current_user NOT IN ('core_ro', 'core_ro_eval') OR person_id IS NULL);
