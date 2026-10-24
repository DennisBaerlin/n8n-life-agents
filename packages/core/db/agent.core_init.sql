-- ============================================================
-- Agent Core — Schema "agent", Context-Tabelle "core_contexts"
-- Zweck:   Zentraler Speicher fuer Grounding-Dokumente
--          (System-Prompts, Memory, Planning, Personal Info).
--
-- Sichtbarkeits-Matrix (load_strategy x agent_name):
--   static + NULL          -> System-Prompt JEDES Agenten (global)
--   static + '<agent>'     -> System-Prompt nur von <agent>
--   lazy   + NULL          -> Manifest JEDES Agenten (on-demand fetch)
--   lazy   + '<agent>'     -> Manifest nur von <agent>
--
-- Lade-Logik ist fuer alle Agenten identisch und im n8n-Sub-Workflow
-- "agent.tool_load_context" (id UpUCUpPLqNnosD5B) gekapselt: ein executeWorkflow-Call
-- mit Input { agent_name, include_manifest } liefert den fertigen system_prompt.
-- Diese Assembly (Static-Concat + optionales Manifest) lebt BEWUSST im Workflow,
-- NICHT hier als DB-Funktion/View -- diese Datei bleibt reines Schema. (Pendant zur
-- Sticky-Note-Konvention: hier der umgekehrte Zeiger "passiert nicht in der DB".)
--   include_manifest = 'false' -> nur Static-Concat, KEIN Manifest
--                                 (fuer Agenten OHNE load_context-Tool, z. B. Orchestrator/Router)
--   sonst (default / 'true')    -> Static-Concat + Manifest
-- Lazy-Content-Fetch erfolgt danach on-demand per "load_context"-Tool des Agenten.
--
-- Effektive Query-Muster:
--   Static:    WHERE load_strategy='static' AND (agent_name = $1 OR agent_name IS NULL)
--   Manifest:  WHERE load_strategy='lazy'   AND (agent_name = $1 OR agent_name IS NULL)
--              (nur angehaengt wenn include_manifest <> 'false')
--   Fetch:     WHERE name = $1 AND load_strategy='lazy'
--
-- Die no-PII-Instruktions-Contexts kommen aus packages/<pkg>/contexts/*.md (vom Installer seed_data.sh
-- geseedet); PII-Contexts entstehen zur Laufzeit per Onboarding. Diese Datei enthaelt nur Schema
-- und Migrationen.
--
-- Usage:   psql -U <user> -d <database> -f agent.core_init.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

-- ============================================================
-- TABLE
-- ============================================================

CREATE TABLE IF NOT EXISTS agent.core_contexts (
    id          serial PRIMARY KEY,
    name        varchar(128) NOT NULL UNIQUE,         -- slug, eindeutiger Identifier des Dokuments
    description text NOT NULL,                         -- Kurzbeschreibung fuer das Manifest-Pattern
    agent_name    varchar(64),                                       -- optionale Zugehoerigkeit; NULL = global
    load_strategy varchar(16) NOT NULL DEFAULT 'lazy'               -- 'static': Workflow laedt immer in System-Prompt
                      CHECK (load_strategy IN ('static', 'lazy')), -- 'lazy': Agent holt bei Bedarf per SELECT
    content       text NOT NULL DEFAULT '',                         -- Markdown-Body
    package     text NOT NULL DEFAULT 'core',         -- D14: besitzendes Paket (Lifecycle/Uninstall-Purge-Key); 'core' | '<paket>'
    managed_by  text NOT NULL DEFAULT 'seed'          -- D14: Sync-Provenienz (aus metadata.managed_by promoted) — wer ueberschreibt die Zeile
                    CHECK (managed_by IN ('seed', 'build', 'agent')),  -- seed=getrackte md | build=Generat | agent=Laufzeit (PII, exportiert, Seeder fasst sie nie an)
    metadata    jsonb NOT NULL DEFAULT '{}'::jsonb,   -- Reserve (facts-Sidecar, render_fn, embeddings-refs); Loeschschutz lebt in core.protected_contexts (WS-B2b)
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- TRIGGER: updated_at automatisch bei UPDATE pflegen
-- ============================================================

CREATE OR REPLACE FUNCTION agent.touch_core_contexts_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_core_contexts_touch ON agent.core_contexts;
CREATE TRIGGER trg_core_contexts_touch
    BEFORE UPDATE ON agent.core_contexts
    FOR EACH ROW EXECUTE FUNCTION agent.touch_core_contexts_updated_at();

-- ============================================================
-- HAUSHALTS-FAKTEN-SIDECAR (md-first + metadata.facts)
-- Die Kontexte 'family' (global) und 'finance_profile' (advisor-scoped) tragen neben dem
-- freien Prosa-Body (content) ein kleines jsonb-Sidecar metadata.facts NUR fuer die
-- berechenbaren/kritischen Felder (Identitaet, Daten, Zahlen):
--   family:          {persons:[{person_id, first_name, last_name, aliases[], role(owner|partner|child),
--                     birth_date, telegram_user_id?, citizenships[]?, language?, persona?, education_status?, as_of?}],
--                     household:{shared_finances?, care_flag?, as_of?}, _meta:{last_confirmed_at}}
--   finance_profile: {persons:[{person_id (muss in family existieren — Single-Writer-Referenz),
--                     planned_retirement_age?, steuerklasse?, kirchensteuer?,
--                     vorsorgesystem?(grv|versorgungswerk|beamtenversorgung|none),
--                     tax_residency?, as_of?}], _meta:{...}}
-- (finance_profile ist ein Paket-Kontext — Strukturregeln in finance.fn_validate_finance_profile; der Core
-- kennt nur die reservierten Form-Keys persons/household, s. fn_validate_household_facts unten.)
-- Alles andere ist bewusst un-gelawte Prosa (kontrolliertes Vokabular im Doc-Template).
-- Abgeleitete Werte (Alter, Regelaltersgrenze, Kindergeld-Ende) werden NIE gespeichert —
-- render-at-fetch ueber die Render-Registry core.context_renderers (Dispatch: core.fn_fetch_context).
-- Das LLM rechnet nie Datums-Arithmetik.
-- Schreibpfad: agent.fn_set_context_facts (HITL-Tool, freundliche {ok:false}) — der
-- Trigger hier ist der strukturelle Backstop (DB ist Gesetz, auch gegen Direkt-psql).
-- ============================================================

CREATE OR REPLACE FUNCTION agent.fn_validate_household_facts(p_facts jsonb, p_name text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_p          JSONB;
    v_id         TEXT;
    v_ids        TEXT[]   := '{}';
    v_tg         BIGINT;
    v_tgs        BIGINT[] := '{}';
    v_bad_key    TEXT;
    v_dangling   TEXT;
BEGIN
    -- Derived-Value-Denylist (Review-Konsens, an Owner-R5 angepasst; WS1b: REKURSIV ueber ALLE
    -- jsonb-Ebenen JEDES Sidecars, nicht mehr nur persons[]). Das Sidecar bleibt OPEN-WORLD (neue
    -- Rohfakt-Keys wie pflegegrad kosten nichts), aber ABGELEITETE Werte duerfen nie gespeichert werden
    -- (Projekt-Gesetz "Rohfakt speichern, Ableitung rechnen" — ein gespeichertes Alter/Jahr ist am
    -- naechsten Geburtstag still falsch). GENERISCH fuer family/finance_profile UND die block-
    -- strukturierten Plan-facts (financial_planning, ohne persons[]) — der Plan-Guard lebt seit WS1b
    -- HIER im Core, nicht mehr im finance-Validator. Geblockt: CALENDAR-YEAR (start_year/retirement_year/
    -- target_year), Alter (age/alter/current_age), Restzeit (years_to_*), Projektionen (income/projected_
    -- income), Nominalwerte ('nominal' = immer aus real abgeleitet) + derived_/computed_-Prefix +
    -- die DE-Ableitungen regelaltersgrenze/kindergeld + die WS-5 career-Runway (runway/runway_months/covers/
    -- effective_burn = career.fn_runway render-at-fetch). ERLAUBT (Roh): birth_date, start_age,
    -- planned_retirement_age, horizon_years, target_income_eur_month, transition.probation_months,
    -- transition.expected_gap_income_eur.
    IF p_facts IS NOT NULL AND jsonb_typeof(p_facts) = 'object' THEN
        WITH RECURSIVE nodes(j) AS (
            SELECT p_facts
          UNION ALL
            SELECT x.v
            FROM nodes n
            CROSS JOIN LATERAL jsonb_array_elements(
                CASE jsonb_typeof(n.j)
                    WHEN 'array'  THEN n.j
                    WHEN 'object' THEN (SELECT COALESCE(jsonb_agg(e.value), '[]'::jsonb)
                                        FROM jsonb_each(CASE WHEN jsonb_typeof(n.j)='object' THEN n.j ELSE '{}'::jsonb END) e)
                    ELSE '[]'::jsonb
                END
            ) AS x(v)
        )
        SELECT k INTO v_bad_key
        FROM nodes n2
        CROSS JOIN LATERAL jsonb_object_keys(CASE WHEN jsonb_typeof(n2.j)='object' THEN n2.j ELSE '{}'::jsonb END) AS k
        WHERE lower(k) IN ('age','alter','current_age','start_year','retirement_year','target_year',
                           'income','projected_income','years_to_retirement','years_to_goal',
                           -- WS-5 career-Runway: abgeleitet (career.fn_runway render-at-fetch), nie gespeichert.
                           -- ROH erlaubt: transition.probation_months / transition.expected_gap_income_eur.
                           'runway','runway_months','covers','effective_burn')
           OR lower(k) ~ '^(derived|computed)_'
           OR lower(k) ~ '(regelaltersgrenze|kindergeld|years_to_)'
           OR lower(k) ~ 'nominal'
        LIMIT 1;
        IF v_bad_key IS NOT NULL THEN
            RETURN format('key "%s" stores a DERIVED value — derived values (calendar years, ages, '
                || 'projections, nominal amounts) are computed at render time, never stored '
                || '(provide the raw fact instead, e.g. birth_date / start_age / target_income_eur_month)', v_bad_key);
        END IF;
    END IF;

    -- Reservierte Core-Form-Keys (Phase A, gelten fuer JEDES Sidecar; Schreibweg agent.fn_set_context_facts):
    --   persons   = Array von Objekten mit regex-gueltigem, eindeutigem person_id (Merge-Key);
    --   household = Objekt. Nur geprueft, wenn der Key da ist; nicht-leer nur bei family (Skelette/Reset
    --   tragen leere Arrays). Pruefung VOR dem family-Zweig, damit kein Sidecar die Form still umdeutet.
    IF p_facts IS NOT NULL AND jsonb_typeof(p_facts) = 'object' THEN
        IF p_facts ? 'household' AND jsonb_typeof(p_facts->'household') IS DISTINCT FROM 'object' THEN
            RETURN 'facts.household must be a JSON object (reserved core shape key)';
        END IF;
        IF p_facts ? 'persons' THEN
            IF jsonb_typeof(p_facts->'persons') IS DISTINCT FROM 'array' THEN
                RETURN 'facts.persons must be an array of person objects (reserved core shape key)';
            END IF;
            -- per_user-Kontexte ('<base>__<pid>' bzw. die Basis) tragen KEIN persons (Haushalts-Form).
            IF agent.fn_context_base_name(p_name) IS NOT NULL THEN
                RETURN format('context "%s" is per-user scoped; facts.persons is a household-only shape key', p_name);
            END IF;
            FOR v_p IN SELECT * FROM jsonb_array_elements(p_facts->'persons') LOOP
                IF jsonb_typeof(v_p) IS DISTINCT FROM 'object' THEN
                    RETURN 'facts.persons entries must be JSON objects';
                END IF;
                v_id := v_p->>'person_id';
                IF v_id IS NULL OR v_id !~ '^[a-z0-9_]+$' THEN
                    RETURN format('invalid person_id "%s" (expected ^[a-z0-9_]+$)', COALESCE(v_id, '<null>'));
                END IF;
                IF v_id = ANY(v_ids) THEN RETURN format('duplicate person_id "%s"', v_id); END IF;
                v_ids := v_ids || v_id;
            END LOOP;
            v_ids := '{}';   -- family-Zweig unten sammelt neu (mit Struktur-Pruefung)
        END IF;
    END IF;

    IF p_name = 'family' THEN
        IF p_facts IS NULL OR jsonb_typeof(p_facts->'persons') IS DISTINCT FROM 'array'
           OR jsonb_array_length(p_facts->'persons') = 0 THEN
            RETURN 'family facts must contain a non-empty persons array';
        END IF;
        FOR v_p IN SELECT * FROM jsonb_array_elements(p_facts->'persons') LOOP
            v_id := v_p->>'person_id';
            IF v_id IS NULL OR v_id !~ '^[a-z0-9_]+$' THEN
                RETURN format('invalid person_id "%s" (expected ^[a-z0-9_]+$)', COALESCE(v_id, '<null>'));
            END IF;
            IF v_id = ANY(v_ids) THEN RETURN format('duplicate person_id "%s"', v_id); END IF;
            v_ids := v_ids || v_id;
            IF length(trim(COALESCE(v_p->>'first_name',''))) = 0
               OR length(trim(COALESCE(v_p->>'last_name',''))) = 0 THEN
                RETURN format('person "%s": first_name AND last_name are required (non-empty)', v_id);
            END IF;
            IF COALESCE(v_p->>'role','') NOT IN ('owner','partner','child') THEN
                RETURN format('person "%s": role must be owner|partner|child', v_id);
            END IF;
            IF v_p->>'birth_date' IS NULL THEN
                RETURN format('person "%s": birth_date is required', v_id);
            END IF;
            BEGIN
                PERFORM (v_p->>'birth_date')::date;
            EXCEPTION WHEN OTHERS THEN
                RETURN format('person "%s": birth_date "%s" is not a valid DATE (YYYY-MM-DD)', v_id, v_p->>'birth_date');
            END;
            IF v_p ? 'telegram_user_id' AND jsonb_typeof(v_p->'telegram_user_id') <> 'null' THEN
                BEGIN
                    v_tg := (v_p->>'telegram_user_id')::bigint;
                EXCEPTION WHEN OTHERS THEN
                    RETURN format('person "%s": telegram_user_id must be numeric', v_id);
                END;
                IF v_tg = ANY(v_tgs) THEN
                    RETURN format('telegram_user_id %s is assigned to two persons (one Telegram identity = one member)', v_tg);
                END IF;
                v_tgs := v_tgs || v_tg;
            END IF;
            -- Sprache fester Texte: nur Codes aus core.ui_languages (Wertevorrat = DB-Gesetz; das Tool normalisiert
            -- Freitext vorab via agent.fn_normalize_language, ein unbekannter Wert landet hier).
            IF v_p ? 'language' AND jsonb_typeof(v_p->'language') <> 'null'
               AND NOT EXISTS (SELECT 1 FROM core.ui_languages l WHERE l.code = v_p->>'language') THEN
                RETURN format('person "%s": language "%s" is not supported (use one of: %s)', v_id, v_p->>'language',
                    (SELECT string_agg(l.code, '|' ORDER BY l.ord) FROM core.ui_languages l));
            END IF;
            -- Bot-Persona: nur Codes aus core.ui_personas; 'neutral' wird nie gespeichert (= Key fehlt), damit
            -- "keine Persona" genau eine Darstellung hat (fn_set_context_facts macht aus 'neutral' ein Loeschen).
            IF v_p ? 'persona' AND jsonb_typeof(v_p->'persona') <> 'null'
               AND (v_p->>'persona' = 'neutral'
                    OR NOT EXISTS (SELECT 1 FROM core.ui_personas x WHERE x.code = v_p->>'persona')) THEN
                RETURN format('person "%s": persona "%s" is not supported (use one of: %s; neutral = omit the key)',
                    v_id, v_p->>'persona',
                    (SELECT string_agg(x.code, '|' ORDER BY x.ord) FROM core.ui_personas x WHERE x.code <> 'neutral'));
            END IF;
            IF v_p ? 'as_of' AND jsonb_typeof(v_p->'as_of') <> 'null' THEN
                BEGIN
                    PERFORM (v_p->>'as_of')::date;
                EXCEPTION WHEN OTHERS THEN
                    RETURN format('person "%s": as_of "%s" is not a valid DATE', v_id, v_p->>'as_of');
                END;
                IF (v_p->>'as_of')::date > CURRENT_DATE THEN
                    RETURN format('person "%s": as_of %s is in the future (would silently defeat the freshness monitor)', v_id, v_p->>'as_of');
                END IF;
            END IF;
        END LOOP;

        -- Bidirektionaler Single-Writer-Check (Review A2), Phase A generisch: ein family-Write darf keine
        -- persons[]-Referenz IRGENDEINES anderen Kontexts verwaisen (Person entfernt/umbenannt). Referenz-
        -- getrieben ueber die reservierte Form (FK-Analogon — jede referenzierende Zeile zaehlt, auch die eines
        -- inaktiven Pakets), nicht registry-getrieben (bewusst, arch-challenge D3a).
        SELECT string_agg(DISTINCT c2.name || ':' || (fpp->>'person_id'), ', ') INTO v_dangling
        FROM agent.core_contexts c2,
             jsonb_array_elements(CASE WHEN jsonb_typeof(c2.metadata->'facts'->'persons') = 'array'
                                       THEN c2.metadata->'facts'->'persons' ELSE '[]'::jsonb END) fpp
        WHERE c2.name <> 'family'
          AND NOT (fpp->>'person_id' = ANY(v_ids));
        IF v_dangling IS NOT NULL THEN
            RETURN format('family update would orphan person reference(s) %s — remove the person through the household person removal (it cleans those references)', v_dangling);
        END IF;
        RETURN NULL;
    END IF;

    -- Gegenrichtung (Phase A, generisch — vorher nur finance.fn_validate_finance_profile): jede persons[].person_id
    -- eines Nicht-family-Kontexts muss in family existieren (Single-Writer: andere Kontexte REFERENZIEREN family-
    -- Personen, duplizieren sie nie). Fehlt die family-Zeile (Bootstrap/Restore-Reihenfolge), entfaellt die
    -- Pruefung (Paritaet zum frueheren Paket-Check).
    IF p_facts IS NOT NULL AND jsonb_typeof(p_facts->'persons') = 'array' THEN
        SELECT string_agg(DISTINCT rp->>'person_id', ', ') INTO v_dangling
        FROM jsonb_array_elements(p_facts->'persons') rp
        WHERE EXISTS (SELECT 1 FROM agent.core_contexts f WHERE f.name = 'family'
                        AND jsonb_typeof(f.metadata->'facts'->'persons') = 'array')
          AND NOT EXISTS (SELECT 1 FROM agent.core_contexts f,
                                 jsonb_array_elements(f.metadata->'facts'->'persons') fp
                          WHERE f.name = 'family' AND fp->>'person_id' = rp->>'person_id');
        IF v_dangling IS NOT NULL THEN
            RETURN format('person_id(s) %s do not exist in family (other contexts reference family persons, never duplicate them)', v_dangling);
        END IF;
    END IF;
    -- Paket-besessene Sidecar-Strukturregeln (z. B. finance.fn_validate_finance_profile) liegen in der
    -- jeweiligen PAKET-fn (D12); der Trigger unten dispatcht sie GENERISCH ueber core.context_validators.
    RETURN NULL;
END;
$$;

-- ------------------------------------------------------------
-- agent.fn_context_base_name(p_name) -> per_user-Basisname | NULL (Backlog-Bugfix-Runde)
--   Registry-Lookups laufen immer auf dem BASIS-Namen (packages/core/CLAUDE.md *context_scopes*): eine per_user-Zeile
--   heisst '<base>__<pid>' (oder die Basis selbst). Laengster passender per_user-Basisname aus core.context_scopes
--   gewinnt (ein Basisname darf selbst '__' enthalten). Die EINE Adresse fuer diese Regel (Trigger, Validatoren).
-- ------------------------------------------------------------
-- plpgsql statt sql: der Body wird erst zur Laufzeit aufgeloest (core.context_scopes entsteht in einer Init-Datei,
-- die alphabetisch NACH dieser laeuft; ein sql-Body wuerde beim CREATE schon gegen die Tabelle geprueft).
CREATE OR REPLACE FUNCTION agent.fn_context_base_name(p_name text)
RETURNS text LANGUAGE plpgsql STABLE
SET search_path = pg_catalog
AS $$
BEGIN
    RETURN (SELECT cs.context_name
            FROM core.context_scopes cs
            WHERE cs.scope = 'per_user'
              AND (p_name = cs.context_name OR left(p_name, length(cs.context_name) + 2) = cs.context_name || '__')
            ORDER BY length(cs.context_name) DESC
            LIMIT 1);
END;
$$;

-- ------------------------------------------------------------
-- agent.fn_is_per_user_row(p_name) -> true gdw p_name eine PHYSISCHE per_user-Zeile '<base>__<pid>' ist (nicht die
--   Basis selbst). Aufbauend auf fn_context_base_name (eine Adresse). Konsumenten: core.fn_fetch_context (lehnt einen
--   physischen Namen ab -> nur Basisname + eigene chat_id), das Lazy-Manifest (agent.tool_load_context) und die
--   RLS-Policy core_contexts_ro_private unten (Frei-SQL unter core_ro sieht keine Person-Zeilen).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION agent.fn_is_per_user_row(p_name text)
RETURNS boolean LANGUAGE plpgsql STABLE
SET search_path = pg_catalog
AS $$
DECLARE
    v_base TEXT := agent.fn_context_base_name(p_name);
BEGIN
    RETURN v_base IS NOT NULL AND p_name <> v_base;
END;
$$;

-- ------------------------------------------------------------
-- agent.fn_validate_context_facts(p_facts, p_name) -> Fehlertext (mit Wert, fuer den Schreibenden) | NULL
--   Die EINE Pruefung "Fakten fuer Kontext X": (1) Core-Anteil agent.fn_validate_household_facts, (2) Paket-Anteil
--   ueber die Registry core.context_validators (exakter Name zuerst, sonst der per_user-Basisname) -> dynamisches
--   EXECUTE. validate_fn ist installer-geschrieben (CHECK: schema-qualifiziert, lowercase) -> kein Injection-Pfad;
--   to_regprocedure-Guard faengt eine veraltete Registry-Zeile ab. Konsumenten: der Trigger unten (Netz) und die
--   freundlichen Vorpruefungen in agent.fn_set_context_facts / agent.fn_advisor_publish_plan ({ok:false, reason}).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION agent.fn_validate_context_facts(p_facts jsonb, p_name text)
RETURNS text LANGUAGE plpgsql STABLE
SET search_path = pg_catalog
AS $$
DECLARE
    v_err TEXT;
    v_fn  TEXT;
BEGIN
    v_err := agent.fn_validate_household_facts(p_facts, p_name);
    IF v_err IS NOT NULL THEN
        RETURN v_err;
    END IF;
    SELECT cv.validate_fn INTO v_fn FROM core.context_validators cv WHERE cv.context_name = p_name;
    IF v_fn IS NULL THEN
        SELECT cv.validate_fn INTO v_fn FROM core.context_validators cv
        WHERE cv.context_name = agent.fn_context_base_name(p_name);
    END IF;
    IF v_fn IS NOT NULL AND to_regprocedure(v_fn || '(jsonb)') IS NOT NULL THEN
        EXECUTE format('SELECT %s($1)', v_fn) INTO v_err USING p_facts;
    END IF;
    RETURN v_err;
END;
$$;

-- ------------------------------------------------------------
-- Trigger-Dispatch (WS-B1 / D12): generische Validator-Registry statt Hardcode (agent.fn_validate_context_facts).
--   Der Core nennt KEIN Paket hartkodiert; fehlt die Registry-Zeile (Paket nicht installiert), entfaellt der
--   Paket-Anteil still (graceful degradation, kein EXCEPTION-Catch der einen Defekt verschluckt).
-- HAERTUNG (CVE-2018-1058): search_path hart auf pg_catalog gepinnt + alle Nicht-pg_catalog-Objekte schema-qualifiziert.
-- Backlog-Bugfix-Runde:
--   * per_user-Zeilen '<base>__<pid>' pruefen gegen den Validator ihres BASIS-Namens (vorher exakter NEW.name -> der
--     Paket-Validator lief fuer per_user nie, ein career_planning-Publish blieb ungeprueft).
--   * Ihre Meldung traegt KEINE Werte (nur den Basis-Namen, ERRCODE check_violation): ein RAISE erreicht ueber
--     core.sub_error_notify den Owner, und per_user-Fakten gehoeren dem Mitglied. Die freundlichen Vorpruefungen
--     melden den Grund mit Wert an den Schreibenden selbst.
--   * Ein UPDATE mit UNVERAENDERTEN facts (z. B. ein Notiz-Append, der nur content aendert) wird nicht neu geprueft:
--     die facts wurden beim Schreiben geprueft; ein Altbestand aus der Zeit vor einer Regel blockiert sonst jeden
--     content-Write an der Zeile.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION agent.trg_core_contexts_validate_facts_fn()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_err  TEXT;
    v_base TEXT;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.metadata->'facts' IS NOT DISTINCT FROM OLD.metadata->'facts' THEN
        RETURN NEW;
    END IF;
    v_err := agent.fn_validate_context_facts(NEW.metadata->'facts', NEW.name);
    IF v_err IS NOT NULL THEN
        v_base := agent.fn_context_base_name(NEW.name);
        IF v_base IS NOT NULL THEN
            RAISE EXCEPTION 'per-user facts invalid (context %)', v_base USING ERRCODE = 'check_violation';
        END IF;
        RAISE EXCEPTION 'household facts invalid: %', v_err;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_household_facts ON agent.core_contexts;
CREATE TRIGGER trg_validate_household_facts
    BEFORE INSERT OR UPDATE ON agent.core_contexts
    FOR EACH ROW
    WHEN (new.metadata ? 'facts')   -- Blast-Radius-Hygiene + paket-agnostisch: nur facts-tragende Writes feuern (kein hartkodierter Context-Name im Core)
    EXECUTE FUNCTION agent.trg_core_contexts_validate_facts_fn();

-- ============================================================
-- CORE-PROTECTION (WS-B2b): DELETE strukturell unmoeglich fuer paket-DEKLARIERTE Kontexte.
-- Der Schutz ist DATEN-gesteuert ueber die host-eigene Registry core.protected_contexts
-- (core.protected_contexts_init.sql), NICHT mehr name-hartkodiert oder per mutablem
-- metadata.protected-Flag (beides retired): jedes Paket deklariert die geschuetzten Context-Namen
-- in seinem manifest.json ("protected_contexts"), der Host seedet sie in die Registry (Kubernetes-
-- Finalizer-Muster). Eine Zeile ist erst loeschbar, wenn ihr Registry-Eintrag entfernt ist — das tut
-- nur der Host/Deinstall (Paket-Rollen sind via D10 von Schema core ausgesperrt -> tamper-proof,
-- ohne "Waechter-des-Waechters"-Trigger). Leere Registry = nichts blockiert (graceful: ein Seed-
-- Fehlschlag kann Context-Writes nicht bricken).
-- KEIN SECURITY DEFINER: nur die Host-Credential (Eigentuemer beider Schemata) loescht core_contexts;
-- DEFINER braechte Reichweite-null + Eskalations-Oberflaeche. search_path=pg_catalog gepinnt (CVE-2018-1058).
-- ============================================================

CREATE OR REPLACE FUNCTION agent.trg_core_contexts_protect_fn()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
    -- (1) Direkt geschuetzter Basis-Name (household-Kontexte + die per_user-Basis selbst).
    IF EXISTS (SELECT 1 FROM core.protected_contexts WHERE context_name = OLD.name) THEN
        RAISE EXCEPTION 'core context "%" is protected and cannot be deleted (only the owning package''s uninstall removes it)', OLD.name;
    END IF;
    -- (2) PER-USER-Suffix (P0b): die suffigierte PII '<protected_base>__<pid>' einer NOCH LEBENDEN Person
    --     (pid in family.facts.persons[]) ist genauso geschuetzt wie der Basis-Name war. Komponiert korrekt:
    --     * Person-Purge (fn_remove_household_person) loescht die per_user-Zeile NACH dem family-Remove ->
    --       pid nicht mehr in family -> nicht geblockt -> purgebar.
    --     * fn_pkg_purge_data loescht core.protected_contexts ZUERST (Finalizer) -> pc leer -> nicht geblockt.
    --     * Lebende Person / Owner -> geblockt = PII-Loeschschutz erhalten (sonst verloere ein Rename die
    --       Schutz-Bindung, weil die Registry auf den nicht mehr existenten Basis-Namen zeigt).
    IF EXISTS (
        SELECT 1
        FROM core.protected_contexts pc
        JOIN core.context_scopes cs ON cs.context_name = pc.context_name AND cs.scope = 'per_user'
        JOIN agent.core_contexts f ON f.name = 'family'
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(f.metadata->'facts'->'persons', '[]'::jsonb)) pp
        WHERE OLD.name = pc.context_name || '__' || (pp->>'person_id')
    ) THEN
        RAISE EXCEPTION 'per-user context "%" belongs to a living household member and is protected (remove the person first to purge it)', OLD.name;
    END IF;
    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_core_contexts_protect ON agent.core_contexts;
CREATE TRIGGER trg_core_contexts_protect
    BEFORE DELETE ON agent.core_contexts
    FOR EACH ROW EXECUTE FUNCTION agent.trg_core_contexts_protect_fn();

-- TRUNCATE-Backstop (Review): row-level BEFORE-DELETE-Trigger feuern bei TRUNCATE nicht —
-- ohne dieses Statement-Level-Deny haette "auch via psql unloeschbar" ein Loch.
CREATE OR REPLACE FUNCTION agent.trg_deny_truncate_fn()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'TRUNCATE on %.% is blocked (table holds protected core rows)', TG_TABLE_SCHEMA, TG_TABLE_NAME;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_core_contexts_no_truncate ON agent.core_contexts;
CREATE TRIGGER trg_core_contexts_no_truncate
    BEFORE TRUNCATE ON agent.core_contexts
    FOR EACH STATEMENT EXECUTE FUNCTION agent.trg_deny_truncate_fn();

-- ============================================================
-- MIGRATION: load_strategy hinzufuegen falls Tabelle schon existiert
-- ============================================================

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'agent'
          AND table_name   = 'core_contexts'
          AND column_name  = 'load_strategy'
    ) THEN
        ALTER TABLE agent.core_contexts
            ADD COLUMN load_strategy VARCHAR(16) NOT NULL DEFAULT 'lazy'
                CHECK (load_strategy IN ('static', 'lazy'));
    END IF;
END $$;

-- ============================================================
-- MIGRATION: description von VARCHAR(500) auf TEXT erweitern
-- ============================================================

DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'agent'
          AND table_name   = 'core_contexts'
          AND column_name  = 'description'
          AND data_type    = 'character varying'
    ) THEN
        ALTER TABLE agent.core_contexts
            ALTER COLUMN description TYPE TEXT;
    END IF;
END $$;

-- ============================================================
-- MIGRATION (D14 / WS-B2): package + managed_by als TYPISIERTE Spalten (aus metadata promoted).
-- Hier nur die SPALTEN-Anlage fuer Bestands-DBs (idempotent, jeder Apply); der einmalige Daten-
-- Backfill (metadata->>'package'/'managed_by' -> Spalte, finance_profile/-plan_current -> 'finance',
-- danach Strip der jsonb-Keys) laeuft als versioned packages/core/db/migrations/V001__promote_context_provenance_columns.sql.
-- Fresh-DB: CREATE TABLE oben traegt schon den Endzustand -> diese ALTERs sind no-op.
-- (origin als 2. Spalte BEWUSST NICHT — arch-challenge WS-B2: managed_by [Sync-Ownership: wer
--  ueberschreibt] und monitor_triggers.origin [Authorship: wer erzeugte] sind verschiedene Achsen;
--  ein gemeinsamer Name behauptete eine Synonymie, die die Read-Sites nicht tragen.)
-- ============================================================
ALTER TABLE agent.core_contexts ADD COLUMN IF NOT EXISTS package text NOT NULL DEFAULT 'core';
ALTER TABLE agent.core_contexts ADD COLUMN IF NOT EXISTS managed_by text NOT NULL DEFAULT 'seed';
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'agent.core_contexts'::regclass AND conname = 'core_contexts_managed_by_check'
    ) THEN
        ALTER TABLE agent.core_contexts
            ADD CONSTRAINT core_contexts_managed_by_check CHECK (managed_by IN ('seed', 'build', 'agent'));
    END IF;
END $$;

-- ============================================================
-- ROW-LEVEL-SECURITY: per_user-Zeilen sind fuer den Frei-SQL-Pfad (core_ro: guide/monitor-LLM, Monitor-Specs) unsichtbar
--   (Owner-Entscheid 2026-10-24 "strikt privat"). PERMISSIVE fuer alle = unveraendertes Verhalten; die RESTRICTIVE-
--   Policy blendet nur fuer current_user = core_ro / core_ro_eval (Monitor-Specs) die physischen per_user-Zeilen aus
--   (strpos vorab: Zeilen ohne "__" kosten keinen fn-Aufruf). Bewusst current_user statt
--   "TO core_ro": eine Policy "TO <rolle>" trifft jedes Mitglied der Rolle — die Sperre haengt so nur an den zwei
--   tatsaechlichen Frei-SQL-Identitaeten, unabhaengig davon, wer welche Rolle erbt. Owner (postgres) und
--   DEFINER-Fenster (core.fn_fetch_context) umgehen RLS -> die gebundenen Lesepfade bleiben intakt. ACHTUNG: eine
--   kuenftige VIEW ueber diese Tabelle laeuft mit Owner-Rechten und umginge die Policy.
-- ============================================================
ALTER TABLE agent.core_contexts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS core_contexts_all ON agent.core_contexts;
CREATE POLICY core_contexts_all ON agent.core_contexts USING (TRUE) WITH CHECK (TRUE);
DROP POLICY IF EXISTS core_contexts_ro_private ON agent.core_contexts;
CREATE POLICY core_contexts_ro_private ON agent.core_contexts AS RESTRICTIVE FOR SELECT
    USING (current_user NOT IN ('core_ro', 'core_ro_eval') OR strpos(name, '__') = 0 OR NOT agent.fn_is_per_user_row(name));
