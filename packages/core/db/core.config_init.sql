-- ============================================================
-- Core Config — Schema "core", Tabelle "config"
-- Zweck:   Zentraler, agenten-uebergreifender Konfig-Store
--          (category/key/value). Loest die alte ENV-Var-Injection
--          (core.sub_env_var_injection, Set-Node "Google"/"Anthropic")
--          ab und generalisiert sie: KI-Modellwahl ist nur der Anfang,
--          jede kuenftige Config wird hier eine Zeile.
--
-- Schema-Wahl: "core" (neu) = genuin cross-cutting Infrastruktur,
--   anders als "agent" (Agenten-Domaene, inkl. agent.core_contexts =
--   Kontext FUER die Agenten). config ist der erste echte core-Belang;
--   deckt sich mit der Workflow-Namensgebung (core.* = cross-cutting).
--
-- Verbrauch zur Laufzeit:
--   core.sub_load_config liest diese Tabelle, pivotet die Zeilen zu
--   einem verschachtelten Objekt { <category>: { <key>: <value> } } und
--   gibt es per passthrough an den aufrufenden Agenten zurueck.
--   Beispiel: model.finance -> 'claude-sonnet-latest', transcription.provider -> 'google'.
--
-- Integritaet:
--   category='model' => value (und default_value) MUSS ein model_key aus agent.ai_models sein
--   (Fremdschluessel ueber die generierten Spalten model_ref/model_default_ref, core:V024) und dieselbe
--   Modell-Art (mode) wie der Standard haben (Trigger 2, core.fn_model_value_eligible). agent.ai_models muss
--   also vorhanden/geseedet sein, bevor eine model-Zeile geschrieben wird (seed_data.sh seedet ai_models zuerst).
--   Jeder neue Wert passt zu value_type/minimum/maximum (Trigger 3, z. B. Zeitplan = gueltiger Cron).
--
-- Diese Datei enthaelt nur das SCHEMA (leere Tabelle). Zeilen kommen
-- ausschliesslich per seed_data.sh (_seed_package_config) aus den .config-
-- Bloecken aller packages/*/manifest.json, paket-skopiert (package-Spalte).
--
-- Apply-Reihenfolge: agent.ai_models_init.sql zuerst (Trigger-Referenz):
--   db_apply.ps1 -File packages\core\db\agent.ai_models_init.sql,packages\core\db\core.config_init.sql
--
-- Usage:   psql -U <user> -d <database> -f core.config_init.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.config (
    id          serial PRIMARY KEY,
    category    varchar(64)  NOT NULL,                  -- z. B. 'model', 'transcription'
    key         varchar(128) NOT NULL,                  -- Konsument/Belang, z. B. 'finance', 'orchestrator', 'provider'
    value       text         NOT NULL,                  -- der konfigurierte Wert
    description text NOT NULL DEFAULT '',               -- optionale Kurzbeschreibung
    package     text NOT NULL DEFAULT 'core',           -- besitzendes/deklarierendes Paket (Ownership/Uninstall-Scope; Info-Spalte, NICHT Teil der Uniqueness)
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (category, key)
);

-- Bestehende DBs (config evtl. ohne package angelegt): Spalte additiv nachziehen (leer -> kein
-- Table-Rewrite). Idiom wie core.services/agent.core_contexts (CREATE-Endzustand + ALTER ADD COLUMN
-- IF NOT EXISTS), KEINE V-Migration -- additive Spalte mit Default, kein Backfill/destruktiv. WS4a-WP1.
-- Jedes Paket DEKLARIERT seine Config im manifest.json (.config-Block); der Host seedet sie paket-skopiert
-- (seed_data.sh _seed_package_config) -> package = Herkunfts-/Uninstall-Marker. Schluessel bleibt global
-- eindeutig (UNIQUE category,key) -> die CLI adressiert eine Zeile ohne Paket-Wissen.
ALTER TABLE core.config ADD COLUMN IF NOT EXISTS package text NOT NULL DEFAULT 'core';

-- default_value (Install-UX-Phase 4): der ZULETZT ausgelieferte Manifest-Default (dpkg-conffile-Muster, wie
-- der managed_by-Guard auf agent.core_contexts). Der Seed (core.fn_config_seed) setzt ihn IMMER neu und
-- ueberschreibt value NUR, wenn value IS NOT DISTINCT FROM dem alten default_value (= der Owner hat nie
-- geaendert). So ueberlebt ein per `lifeagents config set`/Wizard/Agent gesetzter Wert jedes Update, ohne dass
-- ein Schreiber etwas markieren muss. NULL = Bestandszeile von vor dieser Spalte -> gilt als vom Owner gesetzt
-- (fn_config_seed behaelt den Wert) — ausser core:V026 traegt fuer eine nie geaenderte Zeile den v0.2.0-Standard nach.
-- Die Spalte selbst: additiv, kein Backfill -> Init-Idiom, keine V-Migration.
ALTER TABLE core.config ADD COLUMN IF NOT EXISTS default_value text;

-- summary: deutscher Owner-Einzeiler je Eintrag (Manifest `.config.<c>.<k>.summary`) fuer `lifeagents config
-- list`/`config set` — `description` bleibt der englische Entwickler-Text. Wie description IMMER aus dem Manifest
-- (core.fn_config_seed), Muster core.package_registry.display_name. CHECK = DB-Gesetz: keine Steuerzeichen, weil die
-- CLI die Zeilen mit \x1f-Trenner zeilenweise liest (ein Umbruch/\x1f verschoebe die Spalten); die Laenge (<= 100)
-- prueft contract_lint. Additiv mit Default, kein Backfill -> Init-Idiom, keine V-Migration.
ALTER TABLE core.config ADD COLUMN IF NOT EXISTS summary text NOT NULL DEFAULT ''
    CONSTRAINT config_summary_single_line CHECK (summary !~ '[[:cntrl:]]');

-- managed_by (Muster agent.core_contexts.managed_by / pg_settings.context): WER den Wert verwaltet.
--   'owner'  = Einstellung des Owners (lifeagents config list/set/reset zeigen + aendern sie).
--   'system' = Systemwert, den jedes Update neu setzt (z. B. api.core_version) -> fn_config_seed ueberschreibt
--              ihn IMMER, die CLI blendet ihn aus (eine Zeile, die `config list` zeigt, muss auch wirken).
-- Wie description IMMER aus dem Manifest (`.config.<c>.<k>.managed_by`, Default owner). Additiv, Init-Idiom.
ALTER TABLE core.config ADD COLUMN IF NOT EXISTS managed_by text NOT NULL DEFAULT 'owner'
    CONSTRAINT config_managed_by_check CHECK (managed_by IN ('owner', 'system'));

-- value_type + minimum/maximum (Muster pg_settings.vartype/min_val/max_val; Feldnamen im Manifest nach JSON Schema
-- `type`/`minimum`/`maximum`): welche Werte eine Zeile annimmt. Die DB prueft jeden NEUEN Wert (Trigger 3 unten) —
-- vorher konnte `lifeagents config set` z. B. 'abc' in eine Tage-Zahl schreiben, und der Cron, der den Wert mit
-- ::int liest, brach erst zur Laufzeit ab. 'string' = frei (Default), 'cron' = Zeitplan (core.fn_config_cron_valid),
-- 'integer'/'number' (optional mit Grenzen), 'boolean' = genau 'true'|'false' (die Gates vergleichen = 'true').
-- category='model' bleibt beim Modell-Trigger (Wert = model_key aus agent.ai_models). Wie description IMMER aus dem
-- Manifest (fn_config_seed). Additiv mit Default, kein Backfill -> Init-Idiom.
ALTER TABLE core.config ADD COLUMN IF NOT EXISTS value_type text NOT NULL DEFAULT 'string'
    CONSTRAINT config_value_type_check CHECK (value_type IN ('string', 'integer', 'number', 'boolean', 'cron'));
ALTER TABLE core.config ADD COLUMN IF NOT EXISTS minimum numeric;
ALTER TABLE core.config ADD COLUMN IF NOT EXISTS maximum numeric;
ALTER TABLE core.config DROP CONSTRAINT IF EXISTS config_bounds_check;
ALTER TABLE core.config ADD CONSTRAINT config_bounds_check CHECK (
    ((minimum IS NULL AND maximum IS NULL) OR value_type IN ('integer', 'number'))
    AND (minimum IS NULL OR maximum IS NULL OR minimum <= maximum));

-- model_ref / model_default_ref (Modell-Phase 2): value bzw. default_value, aber NUR bei category='model' (sonst
-- NULL). PG kennt keinen Fremdschluessel mit WHERE — die generierten Spalten machen ihn moeglich: core:V024 legt
-- darauf je einen FK -> agent.ai_models(model_key) ON DELETE RESTRICT (ein genutztes Modell ist nicht loeschbar,
-- ein Wert kann nie auf ein fehlendes Modell zeigen). Der FK selbst liegt bewusst in V024, nicht hier: die
-- Baseline-Inits bleiben reihenfolge-tolerant ohne Abhaengigkeit zwischen Inits (docs/reference/packages.md *Migrations-Modell*).
ALTER TABLE core.config ADD COLUMN IF NOT EXISTS model_ref text
    GENERATED ALWAYS AS (CASE WHEN category = 'model' THEN value END) STORED;
ALTER TABLE core.config ADD COLUMN IF NOT EXISTS model_default_ref text
    GENERATED ALWAYS AS (CASE WHEN category = 'model' THEN default_value END) STORED;

-- ============================================================
-- Wert-Pruefung (von Trigger 3 und core.fn_config_seed genutzt). IMMUTABLE, ohne Tabellen-Zugriff.
--   core.fn_config_cron_valid(expr): 5 Felder (Minute Stunde Tag Monat Wochentag) oder 6 Felder mit FESTER Sekunde
--     vorn (n8n-Form; `* * * * * *` = jede Sekunde -> abgelehnt). Je Feld: *, n, a-b, Liste mit ',', Schritt /s
--     (s >= 1); keine Namen (MON/JAN). Gleiche Regeln wie scripts/config_test.ps1 (Manifest-Defaults vor dem
--     Commit) — beide pruefen dieselbe Fallliste tests/util/util_cron_cases.sql.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_config_cron_field_valid(p_field text, p_min int, p_max int)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_part text;
    v_base text;
    m      text[];
BEGIN
    IF p_field IS NULL OR p_field = '' THEN RETURN false; END IF;
    FOREACH v_part IN ARRAY string_to_array(p_field, ',') LOOP
        v_base := v_part;
        m := regexp_match(v_part, '^(.+)/([0-9]{1,2})$');
        IF m IS NOT NULL THEN
            IF m[2]::int < 1 THEN RETURN false; END IF;
            v_base := m[1];
        END IF;
        CONTINUE WHEN v_base = '*';
        m := regexp_match(v_base, '^([0-9]{1,2})-([0-9]{1,2})$');
        IF m IS NOT NULL THEN
            IF m[1]::int < p_min OR m[2]::int > p_max OR m[1]::int > m[2]::int THEN RETURN false; END IF;
            CONTINUE;
        END IF;
        IF v_base !~ '^[0-9]{1,2}$' THEN RETURN false; END IF;          -- erst Form, dann Cast (keine OR-Reihenfolge in SQL)
        IF v_base::int < p_min OR v_base::int > p_max THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_config_cron_valid(p_expr text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    f text[];
BEGIN
    IF p_expr IS NULL THEN RETURN false; END IF;
    f := regexp_split_to_array(btrim(p_expr, E' \t'), '[ \t]+');
    IF array_length(f, 1) = 6 THEN
        -- n8n-Sekundenfeld: nur eine feste Sekunde (0-59), sonst feuerte der Plan mehrfach pro Minute
        IF f[1] !~ '^[0-9]{1,2}$' THEN RETURN false; END IF;
        IF f[1]::int > 59 THEN RETURN false; END IF;
        f := f[2:6];
    END IF;
    RETURN array_length(f, 1) = 5
       AND core.fn_config_cron_field_valid(f[1], 0, 59)
       AND core.fn_config_cron_field_valid(f[2], 0, 23)
       AND core.fn_config_cron_field_valid(f[3], 1, 31)
       AND core.fn_config_cron_field_valid(f[4], 1, 12)
       AND core.fn_config_cron_field_valid(f[5], 0, 7);
END;
$$;

-- core.fn_config_value_valid(type, value, minimum, maximum) -> passt der Wert zum Typ (inkl. Grenzen)?
CREATE OR REPLACE FUNCTION core.fn_config_value_valid(p_type text, p_value text, p_min numeric, p_max numeric)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_num numeric;
BEGIN
    CASE COALESCE(p_type, 'string')
        WHEN 'string'  THEN RETURN p_value IS NOT NULL;
        WHEN 'boolean' THEN RETURN p_value IN ('true', 'false');
        WHEN 'cron'    THEN RETURN core.fn_config_cron_valid(p_value);
        WHEN 'integer' THEN
            -- int4-Bereich: die Verbraucher lesen mit ::int (z. B. make_interval(days => …)) -> groessere Werte
            -- wuerden erst zur Laufzeit mit "integer out of range" scheitern.
            -- Verschachtelt statt OR: SQL garantiert keine Auswertungsreihenfolge, der Cast darf nur nach dem Regex laufen.
            IF p_value IS NULL OR p_value !~ '^-?[0-9]{1,10}$' THEN RETURN false; END IF;
            IF p_value::bigint NOT BETWEEN -2147483648 AND 2147483647 THEN RETURN false; END IF;
        WHEN 'number'  THEN IF p_value IS NULL OR p_value !~ '^-?[0-9]{1,15}([.][0-9]{1,15})?$' THEN RETURN false; END IF;
        ELSE RETURN false;
    END CASE;
    v_num := p_value::numeric;
    RETURN (p_min IS NULL OR v_num >= p_min) AND (p_max IS NULL OR v_num <= p_max);
END;
$$;

-- core.fn_config_value_expectation(type, minimum, maximum) -> deutscher Satz "was wird erwartet" (Fehlertext der
-- CLI bei `lifeagents config set`).
CREATE OR REPLACE FUNCTION core.fn_config_value_expectation(p_type text, p_min numeric, p_max numeric)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_type
        WHEN 'cron'    THEN 'ein Zeitplan im Cron-Format: Minute Stunde Tag Monat Wochentag, z. B. "0 7 * * 1-5" = werktags 7:00 Uhr'
        WHEN 'boolean' THEN 'true oder false'
        WHEN 'integer' THEN 'eine ganze Zahl'
        WHEN 'number'  THEN 'eine Zahl (Dezimalpunkt, z. B. 0.10)'
        ELSE 'ein Text' END
        || CASE WHEN p_min IS NOT NULL AND p_max IS NOT NULL THEN ' von ' || p_min::text || ' bis ' || p_max::text
                WHEN p_min IS NOT NULL THEN ' ab ' || p_min::text
                WHEN p_max IS NOT NULL THEN ' bis ' || p_max::text
                ELSE '' END;
$$;

-- ============================================================
-- TRIGGER 1: updated_at automatisch bei UPDATE pflegen
-- ============================================================

CREATE OR REPLACE FUNCTION core.touch_config_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_config_touch ON core.config;
CREATE TRIGGER trg_config_touch
    BEFORE UPDATE ON core.config
    FOR EACH ROW EXECUTE FUNCTION core.touch_config_updated_at();

-- ============================================================
-- core.fn_model_value_eligible(value, default) -> passt dieses Modell in einen Modell-Eintrag mit diesem Standard?
--   true <=> value ist ein bekannter model_key UND hat dieselbe Modell-Art (agent.ai_models.mode) wie der Standard;
--   Standard NULL (Bestandszeile von vor default_value) -> nur "existiert"; Standard unbekannt -> false.
--   DIE eine Regel fuer drei Nutzer: Trigger 2 (unten), den Seed-Guard in core.fn_config_seed und die Modell-Auswahl
--   von `lifeagents config set` (provisioning/lib/config_cli.sh). STABLE (liest agent.ai_models), plpgsql = spaet
--   gebunden; search_path gepinnt + alles schema-qualifiziert (fn_config_seed laeuft mit search_path=pg_catalog).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_model_value_eligible(p_value text, p_default text)
RETURNS boolean LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE
    v_mode     text;
    v_def_mode text;
BEGIN
    SELECT m.mode INTO v_mode FROM agent.ai_models m WHERE m.model_key = p_value;
    IF NOT FOUND THEN RETURN false; END IF;
    IF p_default IS NULL THEN RETURN true; END IF;
    SELECT m.mode INTO v_def_mode FROM agent.ai_models m WHERE m.model_key = p_default;
    IF NOT FOUND THEN RETURN false; END IF;
    RETURN v_mode IS NOT DISTINCT FROM v_def_mode;
END;
$$;

-- ============================================================
-- TRIGGER 2: Modell-Wert pruefen (freundliche Meldung VOR dem Fremdschluessel-Backstop aus core:V024)
--   category='model' => value (und default_value) muss ein bekannter model_key sein und dieselbe Modell-Art wie der
--   Standard haben (core.fn_model_value_eligible). NUR bei INSERT oder Aenderung von value/default_value: ein
--   vorhandener Wert, der zu einer spaeter eingefuehrten Regel nicht passt, darf kein anderes UPDATE abbrechen
--   (der Seed setzt ihn gezielt zurueck, core.fn_config_seed) — gleiche Regel wie Trigger 3.
-- ============================================================

CREATE OR REPLACE FUNCTION core.config_check_model_value()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.category <> 'model' THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.value IS NOT DISTINCT FROM OLD.value
       AND NEW.default_value IS NOT DISTINCT FROM OLD.default_value THEN
        RETURN NEW;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM agent.ai_models WHERE model_key = NEW.value) THEN
        RAISE EXCEPTION
            'core.config: value "%" (category=model, key=%) ist kein bekannter model_key in agent.ai_models',
            NEW.value, NEW.key;
    END IF;
    IF NEW.default_value IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM agent.ai_models WHERE model_key = NEW.default_value) THEN
        RAISE EXCEPTION
            'core.config: Standard "%" (category=model, key=%) ist kein bekannter model_key in agent.ai_models',
            NEW.default_value, NEW.key;
    END IF;
    IF NOT core.fn_model_value_eligible(NEW.value, NEW.default_value) THEN
        RAISE EXCEPTION 'Modell "%" passt nicht zu model/% — erwartet: ein Modell derselben Art wie der Standard "%".',
            NEW.value, NEW.key, NEW.default_value
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_config_check_model_value ON core.config;
CREATE TRIGGER trg_config_check_model_value
    BEFORE INSERT OR UPDATE ON core.config
    FOR EACH ROW EXECUTE FUNCTION core.config_check_model_value();

-- ============================================================
-- TRIGGER 3: Wert passt zum Typ (value_type + minimum/maximum, s. oben)
--   NUR bei INSERT oder echter Wertaenderung: ein vorhandener Owner-Wert, der zu einem spaeter eingefuehrten Typ
--   nicht passt, darf kein Update abbrechen (der Seed setzt ihn dann gezielt auf den Standard zurueck,
--   core.fn_config_seed). check_violation + deutscher Text -> `lifeagents config set` zeigt, was erwartet wird.
-- ============================================================

CREATE OR REPLACE FUNCTION core.config_check_value_type()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.value IS NOT DISTINCT FROM OLD.value THEN
        RETURN NEW;
    END IF;
    IF NOT core.fn_config_value_valid(NEW.value_type, NEW.value, NEW.minimum, NEW.maximum) THEN
        RAISE EXCEPTION 'Ungültiger Wert "%" für %/% — erwartet: %.', NEW.value, NEW.category, NEW.key,
            core.fn_config_value_expectation(NEW.value_type, NEW.minimum, NEW.maximum)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_config_check_value_type ON core.config;
CREATE TRIGGER trg_config_check_value_type
    BEFORE INSERT OR UPDATE ON core.config
    FOR EACH ROW EXECUTE FUNCTION core.config_check_value_type();
