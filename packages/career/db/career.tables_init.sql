-- ============================================================
-- Career-Paket — Schema "career" (Baseline-Init, idempotent)
--   Usage: psql -U <user> -d <database> -f career.tables_init.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS career;

-- ============================================================
-- Generischer updated_at-Touch-Trigger (paket-lokal, Muster finance.touch_updated_at).
--   Paket-lokal statt core/shared, weil die engen Paket-Rollen kein Cross-Schema-EXECUTE haben
--   und ein Paket sein eigenes Schema voll besitzt.
-- ============================================================
CREATE OR REPLACE FUNCTION career.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at := NOW(); RETURN NEW; END; $$;

-- ============================================================
-- ONBOARDING-FORTSCHRITT — paket-besessene Daten
--   Homogenes Spalten-Muster zur Core-Referenzform agent.guide_onboarding_state: je Sektion ein Tri-State
--   ('unknown'/'completed'/'skipped' als text+CHECK, kein geteilter Cross-Schema-ENUM).
--   `completed` und `skipped` zaehlen als bewusst aufgeloest.
--   * person_id: wholly-per-person. Jedes Familienmitglied pflegt sein eigenes Career-Onboarding (niemand
--     sieht das eines anderen), darum person_id NOT NULL + composite-PK (section_key, person_id). Anders als die
--     Haushalts-onboarding_state von finance/guide (PK nur section_key). Der FK -> agent.persons
--     ON DELETE RESTRICT wird in career:V004 guarded gesetzt (Cross-Schema).
--   Die Sektionen kommen aus packages/career/onboarding/sections.json (Host-Seeder _seed_onboarding_sections
--   seedet je Owner-Zeile; Nicht-Owner-Zeilen materialisiert core.fn_ensure_onboarding_person lazy beim ersten
--   Zugriff der Person). Gelesen/geschrieben ueber die geteilten Core-Onboarding-fns
--   core.fn_onboarding_status / fn_onboarding_overview / fn_set_onboarding_section (Scope per_user aus
--   core.context_scopes, Person aus chat_id via fn_resolve_sender, nie LLM, fail-closed). Reset:
--   packages/core/db/util/util_reset_onboarding_state.sql.
-- ============================================================
CREATE TABLE IF NOT EXISTS career.onboarding_state (
    section_key text NOT NULL,
    ord         int  NOT NULL,
    label       text NOT NULL,
    status      text NOT NULL DEFAULT 'unknown' CHECK (status IN ('unknown', 'completed', 'skipped')),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    person_id   text NOT NULL,   -- wholly-per-person (wie job_matches); FK -> agent.persons in V004 (guarded, Cross-Schema)
    PRIMARY KEY (section_key, person_id)
);
-- Nachfassen: Zeitpunkt der letzten STATUS-Aenderung, gesetzt nur von core.fn_set_onboarding_section
-- (Konvention jedes <pkg>.onboarding_state, s. agent.guide_init.sql).
ALTER TABLE career.onboarding_state ADD COLUMN IF NOT EXISTS status_changed_at timestamptz NOT NULL DEFAULT now();
-- Fuer welche Rollen der Abschnitt gilt (NULL = alle). Einzige Werte-Quelle: sections.json "for_roles" -> Host-Seeder
-- _seed_onboarding_sections; gelesen von core.fn_onboarding_overview. Bestand: career:V008 (gleiche Spalte, gleicher CHECK).
-- Wertevorrat wie agent.pairing_state.role und der family-Validator (agent.core_init.sql).
ALTER TABLE career.onboarding_state ADD COLUMN IF NOT EXISTS for_roles text[];
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'onboarding_state_for_roles_check'
                   AND conrelid = 'career.onboarding_state'::regclass) THEN
        ALTER TABLE career.onboarding_state ADD CONSTRAINT onboarding_state_for_roles_check
            CHECK (for_roles IS NULL OR (cardinality(for_roles) > 0 AND for_roles <@ ARRAY['owner', 'partner', 'child']::text[]));
    END IF;
END $$;

DROP TRIGGER IF EXISTS trg_onboarding_state_touch ON career.onboarding_state;
CREATE TRIGGER trg_onboarding_state_touch BEFORE UPDATE ON career.onboarding_state
    FOR EACH ROW EXECUTE FUNCTION career.touch_updated_at();

-- ============================================================
-- JOB-MATCHES (current-state) — paket-besessene Daten
--   Eine Zeile je Treffer (Bundesagentur-Scan oder manuell weitergeleitet). Die DB traegt den Lebenszyklus
--   (status), der Cron/das Tool UPSERTet.
--   * person_id: wholly-per-person. Jeder Treffer gehoert genau einer Person (es gibt keinen Haushalts-
--     Job-Match), darum NOT NULL (anders als die mixed-scope finance-Tabellen mit nullable owner_person_id =
--     Haushalt). Der FK -> agent.persons ON DELETE RESTRICT wird in career:V003 guarded gesetzt (Cross-Schema).
--   * source bundesagentur = Werktags-Scan (score 1..4 aus dem Per-Posting-Scorer);
--     forwarded = manuell vorgemerkt via tool_record_job_match (score NULL, nicht auto-bewertet).
--   * refnr = Bundesagentur-Referenznummer. Partial-UNIQUE (nur wo NOT NULL): ein Re-Scan/Re-Forward
--     desselben Postings UPSERTet; ein forwarded-Posting ohne refnr ist ein reiner INSERT.
--   * status new->interested(👍)/dismissed(👎); feedback_at = letzte 👍/👎-Zeit (Attribution
--     "zuletzt bewertete Stelle" fuer den Freitext-Grund-Loop des Advisors).
--   * is_serendipity = der eine bewusst unter-Schwelle-Treffer je Lauf ("Blick ueber den Tellerrand").
--   updated_at via career.touch_updated_at() (BEFORE UPDATE). Purge: faellt via DROP SCHEMA career CASCADE.
--
--   Multi-Source: der Init bleibt bewusst auf der Vor-V005-Form (Spalte `refnr`, 2-Wert-source-CHECK,
--   uq_job_matches_refnr(refnr, person_id)), weil das unveraenderliche career:V003 `refnr` referenziert
--   (es baut uq_job_matches_refnr darauf). Apply-Order auf frischer DB = Init -> V003 -> V005; ein
--   `external_id`-Init braeche V003 (`column "refnr" does not exist`). career:V005 macht die Umstellung
--   (RENAME refnr->external_id, +board nullable, source-CHECK auf {bundesagentur, adzuna, jsearch, forwarded},
--   uq_job_matches_external_id auf (source, external_id, person_id)). Der Endzustand steht in V005
--   + R__fn_record_job_match.sql + R__v_job_matches.sql, nicht hier.
-- ============================================================
CREATE TABLE IF NOT EXISTS career.job_matches (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    person_id       text NOT NULL,                              -- wholly-per-person; FK -> agent.persons in V003 (guarded)
    source          text NOT NULL CHECK (source IN ('bundesagentur', 'forwarded')),   -- V005 weitet auf {+adzuna,+jsearch}
    refnr           text,                                       -- V005 RENAME -> external_id; NULL bei forwarded ohne Ref
    title           text NOT NULL,
    employer        text,
    location        text,
    url             text,
    score           smallint CHECK (score BETWEEN 1 AND 4),     -- NULL = nicht auto-bewertet (forwarded)
    score_reasoning text,
    is_serendipity  boolean NOT NULL DEFAULT FALSE,
    status          text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'interested', 'dismissed')),
    raw             jsonb NOT NULL DEFAULT '{}'::jsonb,         -- Roh-Posting-Felder (Gehalt, Datum, ...)
    feedback_at     timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
-- Partial UNIQUE je Person: Re-Scan/Re-Forward desselben Postings derselben Person UPSERTet (ON CONFLICT);
-- zwei Personen duerfen dasselbe Posting (gleiche refnr) je einmal fuehren -> (refnr, person_id); forwarded ohne refnr = INSERT.
-- V005 baut ihn auf uq_job_matches_external_id(source, external_id, person_id) um.
-- Guarded auf die Existenz der refnr-Spalte: nach career:V005 (RENAME refnr -> external_id) referenzierte ein
-- unguarded CREATE INDEX eine tote Spalte und jeder Re-Apply auf Bestand (lifeagents update) brach
-- mit psql exit 3. Frische DB: Spalte existiert -> Index entsteht.
DO $do$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'career' AND table_name = 'job_matches' AND column_name = 'refnr'
    ) THEN
        CREATE UNIQUE INDEX IF NOT EXISTS uq_job_matches_refnr ON career.job_matches (refnr, person_id) WHERE refnr IS NOT NULL;
    END IF;
END
$do$;

DROP TRIGGER IF EXISTS trg_job_matches_touch ON career.job_matches;
CREATE TRIGGER trg_job_matches_touch BEFORE UPDATE ON career.job_matches
    FOR EACH ROW EXECUTE FUNCTION career.touch_updated_at();

-- ============================================================
-- MARKT-SIGNALE (datierter Fetch-Cache fuer den Stellen-Nachfrage-Trend) — paket-besessene Daten
--   Muster finance.market_prices (datierter Cache, PK (identitaet, as_of), vom deterministischen Cron
--   geschrieben, vom Render gelesen). Maschinell geholte Markt-Zahlen gehoeren nicht in den
--   owner/agent-kuratierten career_planning-Fakten-Sidecar.
--   Befuellt vom Cron agent.career.cron_refresh_market_signals (keyless oeffentliche Bundesagentur-Jobsuche
--   /pc/v6/jobs -> maxErgebnisse = Posting-Count; kein LLM, kein PII, kein paid Key) -> career.fn_upsert_
--   market_signals. Der Trend ueber die Zeit braucht die Historie, daher eine datierte Cache-Tabelle.
--   Das amtliche Gehaltsband steht nicht hier: der Entgeltatlas blockt den automatischen Zugriff
--   (403, tote Community-Keys), Gehalt liefert der Advisor on-demand via web_search.
--   * scope_key = die stabile Identitaet, gebaut von career.fn_market_scope_key (eine Quelle des Formats,
--     Write und Read): `postings:<slug(rolle)>:<slug(ort)>`. PK (scope_key, as_of) = idempotenter Tages-
--     Upsert; Trend = Vergleich gegen den juengsten prior row desselben scope_key. Ort steckt im scope_key.
--   * Kein Touch-Trigger (wie finance.market_prices): updated_at via DEFAULT now() + NOW() im
--     ON CONFLICT DO UPDATE der fn_upsert (eine Logik-Stelle; die Tabelle wird nur von der fn geschrieben).
--   Purge: faellt via DROP SCHEMA career CASCADE. core_ro-Aufsicht: core.fn_provision_package_roles grantet SELECT aufs ganze Schema.
-- ============================================================
CREATE TABLE IF NOT EXISTS career.market_signals (
    scope_key         text NOT NULL,                                    -- postings:<slug(rolle)>:<slug(ort)> (career.fn_market_scope_key)
    as_of             date NOT NULL,
    postings_count    int     CHECK (postings_count IS NULL OR postings_count >= 0),
    -- Unabhaengig von job_matches.source: dieser Demand-Cache bleibt BA-only (single-value, kein CHECK,
    -- keine Teilhabe am 4-Wert-Ingestion-Enum von job_matches). Nicht mit dem Multi-Source-Vokabular verwechseln.
    source            text NOT NULL DEFAULT 'bundesagentur',
    raw               jsonb NOT NULL DEFAULT '{}'::jsonb,               -- Roh-API-Felder (Diagnose)
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),               -- via fn_upsert NOW() (kein Touch-Trigger)
    PRIMARY KEY (scope_key, as_of)
);
CREATE INDEX IF NOT EXISTS idx_market_signals_lookup ON career.market_signals (scope_key, as_of DESC);

-- ============================================================
-- Reset-Lebenszyklus-Marker (docs/package-contract.md §6 *Werkszustand-Reset*): core.fn_reset_user_data
--   leert jede Basistabelle dieses Schemas ausser den hier als 'lifecycle:reference' markierten (deny-by-default).
-- ============================================================
COMMENT ON TABLE career.market_signals IS 'lifecycle:reference - Arbeitsmarkt-Cache (Cron fn_upsert_market_signals), keine Personendaten';
