-- ============================================================
-- Agent Persons — projiziertes relationales Read-Model der Haushalts-Personen
-- (Multi-Member-Vermögen WS-1, CQRS-Read-Model). Schema "agent", Tabelle "persons".
--
-- WARUM diese Tabelle (arch-challenge Red/Blue+Opus, ADOPT):
--   Die Personen-STAMMDATEN leben als Single-Source im JSONB-Kontext `family`
--   (agent.core_contexts.metadata.facts.persons[], person_id = Slug). Das ist die
--   AUTORING-Quelle und bleibt es. `agent.persons` ist ein READ-ONLY PROJIZIERTES
--   BACKSTOP-READ-MODEL (CQRS): es trägt KEINE eigene Wahrheit, sondern wird vom
--   Sync-Trigger trg_project_persons aus dem family-JSONB nachgezogen.
--   ZWECK: ein ECHTER Fremdschlüssel (FK) für die 8 finance-Entitäten, die jetzt eine
--   Person referenzieren (Kinderdepot gehört dem Kind, Sparziel zugunsten der Tochter,
--   Immo/Versicherung/Rente person-scoped). Der Sprung von 1 JSONB-Dokument
--   (finance_profile) auf viele relationale Tabellen macht den Verwaisungs-Schutz zur
--   Multi-Row-Invariante → die das Projektgesetz STRUKTURELL (FK + ON DELETE RESTRICT)
--   verlangt, nicht über einen handgeschriebenen Gate-Trigger im family-Validator
--   (der core.* nicht über finance.* aufsichten dürfte, D10). Wird eine noch
--   referenzierte Person aus `family` entfernt, blockt der FK-RESTRICT den Reconcile-
--   DELETE → der family-Write rollt atomar zurück (= bidirektionaler Orphan-Schutz,
--   FK-strukturell). finance_profile koexistiert (NICHT mitgezogen — Surgical-Changes).
--
-- ROLLENMODELL: trg_project_persons ist SECURITY INVOKER (wie trg_validate_household_facts).
--   `family` wird ausschließlich vom Owner-/Host-Credential geschrieben (Eigentümer beider
--   Schemata, siehe agent.core_init.sql trg_core_contexts_protect-Kommentar) → der Trigger
--   schreibt agent.persons mit Owner-Rechten, kein SECURITY-DEFINER-Fenster nötig. core_ro
--   liest agent.persons automatisch (util_create_core_ro GRANT SELECT ON ALL TABLES agent);
--   finance_rw braucht KEINE Grants (FK-Check ist intern). person_id ist eine STABILE
--   Identität — full_name/role-Änderungen re-projizieren ohne FK-Effekt (DELETE feuert nur
--   für TATSÄCHLICH entfernte Slugs).
--
-- Usage:   psql -U <user> -d <database> -f agent.persons_init.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

-- ============================================================
-- TABLE: projizierte Personen (KEINE Autoring-Wahrheit — befüllt per Sync-Trigger)
-- ============================================================

CREATE TABLE IF NOT EXISTS agent.persons (
    person_id    text PRIMARY KEY CHECK (person_id ~ '^[a-z0-9_]+$'),  -- = Slug aus family.facts.persons[]
    full_name    text,                                                  -- projiziert (first_name + last_name); HITL-Anzeige
    role         text,                                                  -- projiziert (owner|partner|child)
    projected_at timestamptz NOT NULL DEFAULT now()                     -- letzte Reconcile-Projektion
);

-- ============================================================
-- RECONCILE-fn: family.facts.persons[] -> agent.persons (Full-Replace, k8s-Reconcile-Muster,
-- Vorbild core.fn_advisor_review_evaluate-GC). Idempotent. Callable: vom Trigger (Laufzeit) UND
-- vom Backfill (core:V009, bestehende family-Personen). search_path gepinnt (CVE-2018-1058),
-- agent.persons schema-qualifiziert.
--   * Jeder Slug im Array: INSERT ... ON CONFLICT DO UPDATE (full_name/role/projected_at frischen).
--   * DELETE der Slugs, die NICHT mehr im Array sind (Person entfernt) — der FK ON DELETE RESTRICT
--     der referenzierenden finance-Entitäten ist hier der Backstop (verwaiste Person nicht löschbar).
--   * FEHLENDER persons-Schlüssel (z. B. reines Prosa-Update): NO-OP (kein versehentliches Wipe bei
--     Partial-Writes). WP-5b: ein PRÄSENTES, aber LEERES Array = bewusste Voll-Entfernung ALLER Personen ->
--     Full-Wipe (sonst blieben projizierte Zeilen als Stale zurück -> Drift). Absent != leeres Array.
-- ============================================================

CREATE OR REPLACE FUNCTION agent.fn_project_persons(p_facts jsonb)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_persons jsonb := p_facts->'persons';   -- NICHT COALESCE'd: NULL = Schlüssel ABWESEND (!= leeres Array)
    v_keys    text[];
BEGIN
    -- Schlüssel ABWESEND (Prosa-only-Update ohne persons-Info) -> No-Op (Schutz gegen Partial-Write-Wipe).
    IF v_persons IS NULL OR jsonb_typeof(v_persons) IS DISTINCT FROM 'array' THEN
        RETURN;
    END IF;
    -- WP-5b: LEERES Array = bewusste Voll-Entfernung ALLER Personen -> Full-Wipe (Reconcile-Semantik). Der FK
    -- ON DELETE RESTRICT ist der Backstop: eine noch referenzierte Person blockt den DELETE -> family-Write
    -- rollt atomar zurück. Der frühere pauschale No-Op liess hier Stale-Zeilen zurück (Drift).
    IF jsonb_array_length(v_persons) = 0 THEN
        DELETE FROM agent.persons;
        RETURN;
    END IF;

    -- Defense-in-Depth (Cold-Eyes A1): NULL-person_id-Eintraege KONSISTENT ueberspringen — sowohl beim
    -- Upsert (sonst PK-NOT-NULL-Crash) als auch im GC-Schluesselsatz (ein NULL in v_keys neutralisiert
    -- `<> ALL` zu NULL -> stiller No-Op-DELETE). Der BEFORE-Validator faengt NULL-Slugs im family-Trigger-
    -- Pfad ab; diese fn ist aber eigenstaendig aufrufbar (V009 + kuenftige Caller) -> selbst-verteidigend.
    SELECT array_agg(e->>'person_id') INTO v_keys
    FROM jsonb_array_elements(v_persons) e
    WHERE e->>'person_id' IS NOT NULL;

    IF v_keys IS NULL THEN
        RETURN;  -- nur Garbage (alle person_id NULL) -> kein Wipe
    END IF;

    -- Upsert je Person (full_name = first_name + last_name, getrimmt; role direkt).
    INSERT INTO agent.persons (person_id, full_name, role, projected_at)
    SELECT e->>'person_id',
           NULLIF(btrim(concat_ws(' ', e->>'first_name', e->>'last_name')), ''),
           e->>'role',
           now()
    FROM jsonb_array_elements(v_persons) e
    WHERE e->>'person_id' IS NOT NULL
    ON CONFLICT (person_id) DO UPDATE
        SET full_name    = EXCLUDED.full_name,
            role         = EXCLUDED.role,
            projected_at = EXCLUDED.projected_at;

    -- Reconcile-GC: entfernte Slugs löschen. FK ON DELETE RESTRICT blockt, falls noch referenziert ->
    -- der family-Write rollt atomar zurueck. NB: der HITL-Write fn_set_context_facts MERGT/appendet nur
    -- (entfernt nie eine Person) -> er kann diesen DELETE nie ausloesen; ein RESTRICT-Fehler entsteht nur
    -- bei direkter Person-Entfernung (kuenftiger Remove-Pfad -> dort den freundlichen {ok:false}-Catch).
    DELETE FROM agent.persons WHERE person_id <> ALL (v_keys);
END;
$$;

-- ============================================================
-- SYNC-TRIGGER: AFTER INSERT/UPDATE auf agent.core_contexts, NUR für 'family' mit facts.
-- BEFORE-Validierung (trg_validate_household_facts) läuft VOR der Projektion; diese AFTER-
-- Projektion zieht agent.persons nach. WHEN-Gate identisch zum Validator (kein Feuern auf
-- Prosa-only-Updates ohne facts; name='family' = die einzige Personen-Quelle).
-- ============================================================

CREATE OR REPLACE FUNCTION agent.trg_project_persons_fn()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
    PERFORM agent.fn_project_persons(NEW.metadata->'facts');
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_project_persons ON agent.core_contexts;
CREATE TRIGGER trg_project_persons
    AFTER INSERT OR UPDATE ON agent.core_contexts
    FOR EACH ROW
    WHEN (new.name = 'family' AND new.metadata ? 'facts')
    EXECUTE FUNCTION agent.trg_project_persons_fn();
