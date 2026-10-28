-- ============================================================
-- core.menu_refresh — Menue-Auftrag der Mini-App „Übersicht“ (Release 2, 2026-10-28)
--   Anwenden via: db_apply.ps1 -File packages\core\db\core.menu_refresh_init.sql
--
-- Zweck: der Knopf „📊 Übersicht“ (setChatMenuButton je Chat) soll einer Kopplung, einem Entkoppeln, einem Rollen- oder
--   Sprachwechsel und einem Wechsel von app.enabled/app.audience nach etwa einer Minute folgen, ohne `lifeagents update`.
--   Aendert sich, was den Knopf einer Person bestimmt (family: Kopplung/Rolle/Sprache/Personen; core.config
--   app.enabled/audience; core.app_screens), zaehlt der DEFINER-Trigger requested_gen hoch. Jeder Menue-Lauf
--   (provisioning/lib/deploy_workflows.sh _set_bot_menu_buttons: Install, Update, Pairing, Paket-Wechsel und der
--   minuetliche root-Runner `update --run-requested`) uebernimmt die Generation vorher (core.fn_menu_refresh_claim) und
--   schliesst sie nur, wenn kein Telegram-Aufruf scheiterte (core.fn_menu_refresh_finish; sonst retry_after 10 Min).
--   Muster „Daten-Zeile -> root-Timer“ wie core.update_requests (provisioning/CLAUDE.md *Update im Chat*), aber ein
--   zusammenfassendes Flag statt eines Auftrags-Protokolls (kein Owner-Auftrag, keine Ergebnis-Karte).
--   Dateiname sortiert NACH core.app_init/core.config_init: die Trigger brauchen core.app_screens und core.config
--   (db_test spielt die Inits alphabetisch ein, apply_schema.sh zieht nur config_init vor).
--
-- Ephemer (Betriebs-Zustand, keine Nutzerdaten) -> nicht im backup-Block des Manifests.
-- Tests: tests/db/core/test_fn_menu_refresh.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.menu_refresh (
    id            boolean PRIMARY KEY DEFAULT TRUE CHECK (id),
    requested_gen bigint NOT NULL DEFAULT 0,
    done_gen      bigint NOT NULL DEFAULT 0,
    requested_at  timestamptz,                  -- letzter Ausloeser (doctor: offen seit > 30 Min -> gelb)
    retry_after   timestamptz,                  -- nach einem gescheiterten Lauf: frueheste naechste Uebernahme
    failures      int NOT NULL DEFAULT 0,       -- gescheiterte Laeufe in Folge; beim 3. gibt der Auftrag auf
    gave_up_at    timestamptz,                  -- letzte Aufgabe (dauerhaft unerreichbarer Chat); doctor 7 Tage gelb
    CONSTRAINT menu_refresh_gen_order CHECK (done_gen <= requested_gen),
    CONSTRAINT menu_refresh_failures_range CHECK (failures BETWEEN 0 AND 3)
);
-- Rechte wie core.update_requests: schreiben nur der DEFINER-Trigger und der Superuser (claim/finish); die Lesesicht
-- von core_ro (Sammel-Grant in util_create_core_ro.sql) ist harmlos, die Zeile traegt nur Zaehler und Zeitstempel.

-- Was den Knopf einer Person bestimmt (Projektion der family-Fakten, Reihenfolge-unabhaengig). Trigger-gekoppelt ->
-- Init, nicht R__ (sql.md: Inline-Baseline-Helfer). Kein Array -> leer (kaputte Fakten werfen nie im Schreibpfad).
CREATE OR REPLACE FUNCTION core.fn_menu_persons(p_meta jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('p', e->'person_id', 't', e->'telegram_user_id', 'r', e->'role',
                                                 'l', e->'language') ORDER BY e->>'person_id', e::text), '[]'::jsonb)
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_meta->'facts'->'persons') = 'array'
                                   THEN p_meta->'facts'->'persons' ELSE '[]'::jsonb END) e;
$$;

-- AFTER-Trigger aller drei Quellen. SECURITY DEFINER: jeder Schreibweg der Fakten/Config (n8n-Host, CLI, Seeder) darf
-- markieren, ohne selbst Rechte auf core.menu_refresh zu brauchen. Ein Upsert auf die eine Zeile.
CREATE OR REPLACE FUNCTION core.fn_menu_refresh_mark()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, core, pg_temp
AS $$
BEGIN
    IF TG_TABLE_NAME = 'core_contexts' THEN
        IF (CASE WHEN TG_OP <> 'INSERT' AND OLD.name = 'family' THEN core.fn_menu_persons(OLD.metadata) END)
           IS NOT DISTINCT FROM
           (CASE WHEN TG_OP <> 'DELETE' AND NEW.name = 'family' THEN core.fn_menu_persons(NEW.metadata) END) THEN
            RETURN NULL;   -- kein family-Context beteiligt oder nichts Knopf-Relevantes geaendert
        END IF;
    ELSIF TG_TABLE_NAME = 'config' THEN
        IF (CASE WHEN TG_OP <> 'INSERT' AND OLD.category = 'app' AND OLD.key IN ('enabled', 'audience')
                 THEN OLD.key || '=' || COALESCE(OLD.value, '') END)
           IS NOT DISTINCT FROM
           (CASE WHEN TG_OP <> 'DELETE' AND NEW.category = 'app' AND NEW.key IN ('enabled', 'audience')
                 THEN NEW.key || '=' || COALESCE(NEW.value, '') END) THEN
            RETURN NULL;
        END IF;
    END IF;
    INSERT INTO core.menu_refresh (id, requested_gen, requested_at) VALUES (TRUE, 1, now())
    ON CONFLICT (id) DO UPDATE SET requested_gen = core.menu_refresh.requested_gen + 1, requested_at = now();
    RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION core.fn_menu_refresh_mark() FROM public;

DROP TRIGGER IF EXISTS trg_menu_refresh_family ON agent.core_contexts;
CREATE TRIGGER trg_menu_refresh_family
    AFTER INSERT OR UPDATE OF metadata, name OR DELETE ON agent.core_contexts
    FOR EACH ROW EXECUTE FUNCTION core.fn_menu_refresh_mark();
DROP TRIGGER IF EXISTS trg_menu_refresh_config ON core.config;
CREATE TRIGGER trg_menu_refresh_config
    AFTER INSERT OR UPDATE OF value, category, key OR DELETE ON core.config
    FOR EACH ROW EXECUTE FUNCTION core.fn_menu_refresh_mark();
DROP TRIGGER IF EXISTS trg_menu_refresh_screens ON core.app_screens;
CREATE TRIGGER trg_menu_refresh_screens
    AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON core.app_screens
    FOR EACH STATEMENT EXECUTE FUNCTION core.fn_menu_refresh_mark();
