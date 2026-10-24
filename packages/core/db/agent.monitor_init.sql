-- ============================================================
-- Monitor — Schema fuer das generische Trigger-Monitoring (agent.monitor)
-- Zweck:   Trigger sind DATEN, keine Workflows: jede Zeile beschreibt EINE ueberwachte
--          Bedingung (Schwellwert / Drawdown / Termin / wiederkehrende Info) inkl. eigener
--          Pruef-Cadence und eigener Wert-Beschaffung ("Tool + Prompt"). Der Heartbeat-Cron
--          agent.monitor.cron_check_triggers waehlt faellige Zeilen (next_check_at), beschafft
--          Werte (web_search per Claude-Websuche / sql in-fn unter core_ro / none / Paket-
--          Methoden aus core.monitor_acquisition_methods, z. B. finance fx_rate) und wertet
--          DETERMINISTISCH in fn_monitor_evaluate aus.
--          Angelegt/geaendert werden Trigger ausschliesslich ueber die HITL-Tools
--          agent.tool_create/set/delete_monitor_trigger (Owner: agent.monitor; der
--          finance_advisor bindet nur create mit fixem domain='finance').
--
-- Lifecycle: armed -> fired (One-Shot-Latch, nur fn_monitor_evaluate) -> Re-Arm/disabled
--            (nur via set-Tool, HITL). recurring_info latcht NIE (feuert jede faellige Runde).
--
-- Invarianten (DB-Gesetz, nicht Prompt):
--   * Typ x Feld-Konsistenz als CHECK (date braucht due_date, threshold braucht comparator+
--     threshold_value+Beschaffung, drawdown braucht pct+Beschaffung, ...)
--   * Web-Rate-Limit: web_search-Trigger muessen check_interval >= 12h haben
--     (max. 2 Web-Abrufe/Tag/Trigger — Kostenschutz, Owner-Vorgabe)
--   * acquisition_spec-Shape passt zur Methode (Key-Praesenz; Vollvalidierung in den fns)
--   * UNIQUE(domain, lower(label)) — Trigger sind Config, kein Ledger; das set-Tool braucht
--     deterministische Label-Aufloesung (bewusste Abweichung vom Finance-"kein UNIQUE auf
--     Namen"-Nicht-Ziel; fn_create faengt unique_violation -> {ok:false})
--
-- SQL-Beschaffung (Sicherheits-Layering): HITL bei Anlage + Regex-Shape-Guard in der fn
-- ('^\s*select\y', kein ';', Laengen-Cap — Beratung) -> SET LOCAL ROLE core_ro beim
-- EXECUTE (strukturelles Gesetz: read-only; core_ro = Core-Host-Leserolle agent+core+finance,
-- weil eine Acquisition beliebige Schemata treffen kann — B3, nach der Finance-Paket-Isolation).
-- Voraussetzung: der App-DB-User ist Member von core_ro (GRANT unten + apply_schema, idempotent).
-- BEKANNTE GRENZE: statement_timeout wirkt in Postgres nur am Top-Level-Statement — ein
-- SET LOCAL im fn-Inneren begrenzt das innere EXECUTE NICHT. Restrisiko (Runaway-Query)
-- akzeptiert: Single-User, Query ist HITL-bestaetigt + Probe-getestet, Scalar-Subquery-Wrap.
--
-- Usage:   db_apply.ps1 -File packages\core\db\agent.monitor_init.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

-- ============================================================
-- TABLE: monitor_triggers — eine Zeile = ein ueberwachter Trigger
-- ============================================================

CREATE TABLE IF NOT EXISTS agent.monitor_triggers (
    id                 serial PRIMARY KEY,
    domain             text NOT NULL DEFAULT 'general'
                           CHECK (length(trim(domain)) > 0),
    label              text NOT NULL
                           CHECK (length(trim(label)) > 0),
    trigger_type       text NOT NULL
                           CHECK (trigger_type IN ('threshold','drawdown','date','recurring_info')),

    -- Wert-Beschaffung ("Tool + Prompt" — Owner-Konzept)
    acquisition_method text NOT NULL DEFAULT 'none',
        -- Mitgliedschaft = FK auf core.monitor_acquisition_methods (core:V020; Core-Builtins + Paket-Methoden)
    acquisition_spec   jsonb NOT NULL DEFAULT '{}'::jsonb,
        -- web_search: {"prompt": "<verbatim retrieval prompt, EN>"}
        -- sql:        {"query": "<single SELECT, eine numerische Spalte>"}
        -- none:       {}
        -- Paket-Methode: Form definiert + prueft die validate_fn des Pakets (Trigger unten), z. B. fx_rate {base, quote}

    -- deterministische Vergleichs-Konfiguration (typisierte Spalten => CHECK-faehig)
    comparator         text CHECK (comparator IN ('gte','lte')),     -- nur threshold
    threshold_value    numeric,                                       -- threshold: Grenzwert
    drawdown_pct       numeric CHECK (drawdown_pct IS NULL OR (drawdown_pct > 0 AND drawdown_pct < 100)),
    reference_value    numeric,            -- drawdown: trailing peak (Ratchet, pflegt fn_monitor_evaluate)
    due_date           date,               -- nur date
    warn_days_before   int NOT NULL DEFAULT 0 CHECK (warn_days_before >= 0),

    -- Validierungs-Kaskade fuer beschaffte Werte (Stufen 2-4; Stufe 1 = Parse im Workflow)
    expected_unit      text,               -- Pflicht bei web_search (Unit-Echo-Check); sonst Render-Label
    min_plausible      numeric,
    max_plausible      numeric,
    max_jump_pct       numeric CHECK (max_jump_pct IS NULL OR max_jump_pct > 0),
        -- optionaler Kontinuitaets-Guard: Abweichung > X% vom letzten sauberen Wert => dirty.
        -- Default NULL=aus (Crash-Drawdown-Trigger MUESSEN legitime Spruenge sehen);
        -- nur fuer sprung-unplausible Metriken setzen (Basiszins, FX).

    -- per-Trigger-Cadence (Heartbeat-Cron = Aufloesungsboden, Frequenz lebt HIER)
    check_interval     interval NOT NULL,
    next_check_at      timestamptz NOT NULL DEFAULT now(),
    last_checked_at    timestamptz,

    -- Zustand
    status             text NOT NULL DEFAULT 'armed'
                           CHECK (status IN ('armed','fired','disabled')),
    fired_at           timestamptz,
    last_value         numeric,            -- letzter SAUBERER Wert (dirty Werte beruehren ihn nie)
    last_value_as_of   text,               -- quellen-gemeldetes Datum (frei: "2026-06-09", "Q1 2026")
    fail_streak        int NOT NULL DEFAULT 0,

    action_note        text,               -- DE, geht 1:1 in den Telegram-Alert ("was laut Plan zu tun ist")
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),

    -- Typ x Feld-Konsistenz (DB-Gesetz; fns spiegeln als {ok:false})
    CONSTRAINT monitor_triggers_type_consistency CHECK (
        (trigger_type = 'date' AND due_date IS NOT NULL AND acquisition_method = 'none'
            AND comparator IS NULL AND threshold_value IS NULL AND drawdown_pct IS NULL)
     OR (trigger_type = 'threshold' AND comparator IS NOT NULL AND threshold_value IS NOT NULL
            AND acquisition_method <> 'none' AND due_date IS NULL AND drawdown_pct IS NULL)
     OR (trigger_type = 'drawdown' AND drawdown_pct IS NOT NULL AND acquisition_method <> 'none'
            AND comparator IS NULL AND threshold_value IS NULL AND due_date IS NULL)
     OR (trigger_type = 'recurring_info'
            AND comparator IS NULL AND threshold_value IS NULL AND drawdown_pct IS NULL
            AND due_date IS NULL)
    ),

    -- Web-Rate-Limit als DB-Gesetz (Owner-Vorgabe: max 2x/Tag/Trigger)
    CONSTRAINT monitor_triggers_web_rate_limit CHECK (
        acquisition_method <> 'web_search' OR check_interval >= interval '12 hours'
    ),

    -- Unit-Echo-Check braucht eine Soll-Einheit, wenn Werte aus dem Internet kommen
    CONSTRAINT monitor_triggers_web_needs_unit CHECK (
        acquisition_method <> 'web_search' OR expected_unit IS NOT NULL
    ),

    CONSTRAINT monitor_triggers_bounds_sane CHECK (
        min_plausible IS NULL OR max_plausible IS NULL OR min_plausible < max_plausible
    )
);

-- Methoden-Name: Form-CHECK (Mitgliedschaft = FK, core:V020). Phase B ersetzt die fruehere IN-Liste mit dem
-- finance-Literal 'fx_rate' (Core kannte eine Paket-Methode). Gleicher Auto-Name wie die alte Inline-CHECK ->
-- DROP+ADD heilt Bestands-DBs idempotent (Muster origin_chk unten).
ALTER TABLE agent.monitor_triggers DROP CONSTRAINT IF EXISTS monitor_triggers_acquisition_method_check;
ALTER TABLE agent.monitor_triggers ADD  CONSTRAINT monitor_triggers_acquisition_method_check
    CHECK (acquisition_method ~ '^[a-z][a-z0-9_]*$');

-- Spec-Shape passt zur Core-Methode (Key-Praesenz als Backstop; Vollvalidierung in fn). Paket-Methoden
-- fallen in den Catch-all-Zweig — ihre Spec prueft die validate_fn des Pakets (Trigger unten = DB-Gesetz).
ALTER TABLE agent.monitor_triggers DROP CONSTRAINT IF EXISTS monitor_triggers_spec_shape;
ALTER TABLE agent.monitor_triggers ADD  CONSTRAINT monitor_triggers_spec_shape CHECK (
        (acquisition_method = 'web_search' AND acquisition_spec ? 'prompt')
     OR (acquisition_method = 'sql'        AND acquisition_spec ? 'query')
     OR (acquisition_method = 'none')
     OR (acquisition_method NOT IN ('web_search', 'sql', 'none'))
);

-- Label-Aufloesung deterministisch: genau ein Trigger je (domain, label) — case-insensitiv
CREATE UNIQUE INDEX IF NOT EXISTS monitor_triggers_domain_label
    ON agent.monitor_triggers (domain, lower(label));

-- ============================================================
-- TABLE: monitor_observations — Audit-Log jeder Wert-Beschaffung (auch dirty/failed).
-- Klein (1 Zeile pro Pruefung), unverzichtbar wenn ein Alert hinterfragt wird; zugleich
-- die Drift-Spur eines sterbenden Web-Prompts (Folge von cannot_determine). Der
-- Drawdown-Ratchet lebt NICHT hier, sondern als reference_value am Trigger.
-- ============================================================

CREATE TABLE IF NOT EXISTS agent.monitor_observations (
    id          serial PRIMARY KEY,
    trigger_id  int NOT NULL REFERENCES agent.monitor_triggers(id) ON DELETE CASCADE,
        -- disposable Child => CASCADE (ON-DELETE-Politik .claude/rules/sql.md *Integritaets-Konventionen*)
    ok          boolean NOT NULL,           -- hat die Beschaffung+Validierung bestanden?
    value       numeric,
    unit        text,
    as_of       text,
    source_url  text,
    reason      text,                       -- bei ok=false: cannot_determine / unit mismatch / out of bounds / jump / ...
    fetched_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS monitor_observations_trigger_idx
    ON agent.monitor_observations (trigger_id, fetched_at DESC);

-- ============================================================
-- TRIGGER: updated_at pflegen (gemeinsamer Helper; idempotent mit-definiert,
-- damit monitor_init standalone anwendbar bleibt — Muster agent.advisor_init.sql)
-- ============================================================

CREATE OR REPLACE FUNCTION agent.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at := NOW(); RETURN NEW; END; $$;

DROP TRIGGER IF EXISTS trg_monitor_triggers_touch ON agent.monitor_triggers;
CREATE TRIGGER trg_monitor_triggers_touch
    BEFORE UPDATE ON agent.monitor_triggers
    FOR EACH ROW EXECUTE FUNCTION agent.touch_updated_at();

-- ============================================================
-- CORE-PROTECTION: origin='core' = system-eigener Trigger (z. B. household_facts_freshness).
-- Nie loeschbar (BEFORE-DELETE-Backstop hier + freundliches {ok:false} in
-- fn_delete_monitor_trigger), IMMER deaktivierbar (status='disabled' bleibt erlaubt) —
-- Owner-Anforderung "never-deletable, always-silenceable".
-- ============================================================

ALTER TABLE agent.monitor_triggers ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'user';
ALTER TABLE agent.monitor_triggers DROP CONSTRAINT IF EXISTS monitor_triggers_origin_chk;
ALTER TABLE agent.monitor_triggers ADD  CONSTRAINT monitor_triggers_origin_chk CHECK (origin IN ('core','user'));

-- ============================================================
-- PACKAGE-OWNERSHIP (Advisor<->Monitor-Integration): WELCHES Paket besitzt diesen Trigger.
-- Reiner Lifecycle-/Purge-Schluessel (Kubernetes-ownerReference-Muster, NICHT die fachliche
-- `domain`-Gruppierung, die der User/Monitor frei vergibt). Per-Binding FIX gesetzt: der
-- finance_advisor schreibt 'finance', der Core-Monitor-Agent 'core' — NIE vom LLM ($fromAI).
-- core.fn_pkg_purge_data raeumt `WHERE package=<pkg> AND origin='user'` beim Paket-Deinstall
-- (sonst leakt ein advisor-erzeugter Trigger in der Host-Tabelle agent.monitor_triggers, die
-- `DROP SCHEMA <pkg> CASCADE` nicht erreicht). Additive Spalte -> Init-only (Muster origin/
-- asset_class), keine V-Migration. Default 'core' = Bestands-/geseedete Trigger gehoeren dem Host.
-- ============================================================
ALTER TABLE agent.monitor_triggers ADD COLUMN IF NOT EXISTS package text NOT NULL DEFAULT 'core';
ALTER TABLE agent.monitor_triggers DROP CONSTRAINT IF EXISTS monitor_triggers_package_chk;
ALTER TABLE agent.monitor_triggers ADD  CONSTRAINT monitor_triggers_package_chk CHECK (package ~ '^[a-z0-9_]+$');

-- Roter Faden (Erinnerungs-Fenster, Owner-Entscheid 2026-10-23): ein Problembericht, der ausserhalb von
-- general.reminders_from..until entsteht, wird hier vorgemerkt und von agent.fn_monitor_evaluate im ersten Lauf
-- im Fenster nachgereicht (dann NULL). Additive Spalte -> Init-only.
ALTER TABLE agent.monitor_triggers ADD COLUMN IF NOT EXISTS problem_pending_at timestamptz;

CREATE OR REPLACE FUNCTION agent.trg_monitor_triggers_protect_fn()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.origin = 'core' THEN
        RAISE EXCEPTION 'monitor trigger "%" is a core trigger and cannot be deleted (disable instead)', OLD.label;
    END IF;
    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_monitor_triggers_protect ON agent.monitor_triggers;
CREATE TRIGGER trg_monitor_triggers_protect
    BEFORE DELETE ON agent.monitor_triggers
    FOR EACH ROW EXECUTE FUNCTION agent.trg_monitor_triggers_protect_fn();

-- TRUNCATE-Backstop (Review): row-level BEFORE DELETE feuert bei TRUNCATE nicht.
-- Helper idempotent mit-definiert (Muster touch_updated_at), damit monitor_init standalone bleibt.
CREATE OR REPLACE FUNCTION agent.trg_deny_truncate_fn()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'TRUNCATE on %.% is blocked (table holds protected core rows)', TG_TABLE_SCHEMA, TG_TABLE_NAME;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_monitor_triggers_no_truncate ON agent.monitor_triggers;
CREATE TRIGGER trg_monitor_triggers_no_truncate
    BEFORE TRUNCATE ON agent.monitor_triggers
    FOR EACH STATEMENT EXECUTE FUNCTION agent.trg_deny_truncate_fn();

-- ============================================================
-- SPEC-VALIDIERUNG der PAKET-Methoden als DB-Gesetz (Phase B; Muster trg_core_contexts_validate_facts_fn):
-- die Spec einer registrierten Paket-Methode prueft deren validate_fn (via agent.fn_monitor_validate_params).
-- Scope `UPDATE OF acquisition_method, acquisition_spec` + Unveraendert-Return: die stuendlichen Heartbeat-
-- UPDATEs (last_value/fail_streak/next_check_at) feuern ihn nie. Core-Builtins -> sofort zurueck (ihre Form
-- haelt spec_shape). Methode nicht verfuegbar (Paket fehlt/inaktiv, Platzhalter) -> ueberspringen: der
-- Backstop greift, sobald die Pruefung existiert (der FK haelt die Mitgliedschaft). Ablehnung ->
-- check_violation (die create/set-Handler machen daraus {ok:false}, kein Owner-Alert).
-- Scoping im BODY statt per WHEN-Klausel: ein INSERT-OR-UPDATE-Trigger darf in WHEN kein OLD referenzieren
-- (PG: "INSERT trigger's WHEN condition cannot reference OLD values") — der Unveraendert-Vergleich braucht OLD.
-- ============================================================
CREATE OR REPLACE FUNCTION agent.trg_monitor_triggers_validate_spec_fn()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_r jsonb;
BEGIN
    IF NEW.acquisition_method IN ('web_search', 'sql', 'none') THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE'
       AND NEW.acquisition_method IS NOT DISTINCT FROM OLD.acquisition_method
       AND NEW.acquisition_spec   IS NOT DISTINCT FROM OLD.acquisition_spec THEN
        RETURN NEW;
    END IF;
    IF to_regprocedure('agent.fn_monitor_validate_params(text,jsonb)') IS NULL THEN
        RETURN NEW;   -- Apply-Fenster (Init vor R__)
    END IF;
    v_r := agent.fn_monitor_validate_params(NEW.acquisition_method, NEW.acquisition_spec);
    IF (v_r->>'available')::boolean IS FALSE THEN
        RETURN NEW;
    END IF;
    IF NOT COALESCE((v_r->>'ok')::boolean, false) THEN
        RAISE EXCEPTION USING ERRCODE = 'check_violation',
            MESSAGE = format('invalid acquisition_spec for %s: %s', NEW.acquisition_method, v_r->>'reason');
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_monitor_triggers_validate_spec ON agent.monitor_triggers;
CREATE TRIGGER trg_monitor_triggers_validate_spec
    BEFORE INSERT OR UPDATE OF acquisition_method, acquisition_spec ON agent.monitor_triggers
    FOR EACH ROW EXECUTE FUNCTION agent.trg_monitor_triggers_validate_spec_fn();

-- ============================================================
-- CORE-SEED: household_facts_freshness — jaehrlicher Staleness-Check der Haushalts-Fakten.
-- sql-Acquisition liefert EINEN numerischen Skalar => Count der Personen-Fakten mit as_of aelter als
-- 12 Monate (oder ohne as_of) ueber family + die household-Fakten-Kontexte AKTIVER Pakete. Die Logik
-- lebt in core.fn_stale_facts_count() (R__) — die gespeicherte Spec ruft nur die fn (der Owner kann die
-- Spec editieren; Logik-Aenderungen brauchen so keine V-Migration). Bestands-Zeilen: core:V019 (geguardet).
-- Statische action_note verweist auf den Guide (der enumeriert die Stale-Liste on-demand per SQL).
-- recurring_info latcht nie; Count-0-Unterdrueckung der Nachricht ist Message-Builder-Sache
-- (Phase 5/6). Idempotent via NOT EXISTS (Trigger sind sonst HITL-erzeugte DATEN).
-- ============================================================

INSERT INTO agent.monitor_triggers
    (domain, label, trigger_type, acquisition_method, acquisition_spec,
     expected_unit, check_interval, next_check_at, action_note, origin)
SELECT
    'general',
    'household_facts_freshness',
    'recurring_info',
    'sql',
    jsonb_build_object('query', 'SELECT core.fn_stale_facts_count()'),
    'stale facts',
    interval '1 year',
    now() + interval '1 year',
    'Stammdaten pruefen: einige Haushalts-Angaben sind ueber 12 Monate alt. Frag den Guide ("Stammdaten pruefen") — er listet die veralteten Angaben.',
    'core'
WHERE NOT EXISTS (
    SELECT 1 FROM agent.monitor_triggers
    WHERE domain = 'general' AND lower(label) = 'household_facts_freshness'
);

-- ============================================================
-- GRANTS (Paket-Isolation, B3): der Monitor-Agent liest seine Trigger/Observations ueber den
-- Frei-SQL-Pfad unter der CORE-HOST-Leserolle core_ro (nicht mehr finance_ro — das ist nach
-- der Paket-Extraktion eng auf `finance` skopiert; der Monitor ist ein CORE-Agent). core_ro
-- bekommt seinen breiten agent-SELECT ohnehin in util_create_core_ro (deckt diese Tabellen) —
-- der explizite GRANT hier ist FMEA-Backstop (nicht allein auf Default-Privileges verlassen).
-- (b) Membership: der anwendende App-DB-User wird Member von core_ro, damit fn_monitor_acquire
-- die gespeicherten SQL-Specs unter SET LOCAL ROLE core_ro ausfuehren kann (die autoritative
-- Runtime-Membership des n8n-Users erteilt apply_schema.sh Phase 4; hier der Dev/Apply-User).
-- Beides no-op, falls core_ro (noch) nicht existiert (Phase 1 vor util_create_core_ro = Phase 4;
-- greift beim Re-Apply / im db_test, wo core_ro vor den Monitor-Tests da ist).
-- ============================================================

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
        GRANT SELECT ON agent.monitor_triggers     TO core_ro;
        GRANT SELECT ON agent.monitor_observations TO core_ro;
        EXECUTE format('GRANT core_ro TO %I', current_user);
    END IF;
END $$;
