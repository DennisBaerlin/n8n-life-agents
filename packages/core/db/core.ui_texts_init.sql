-- ============================================================
-- core.ui_languages + core.ui_texts — Textkatalog fester Nutzertexte (Feste Texte in der Sprache der Person)
--   Anwenden via: db_apply.ps1 -File packages\core\db\core.ui_texts_init.sql
--
-- Zweck: feste (nicht vom LLM formulierte) Telegram-Texte — HITL-Karten, Knoepfe, Picker, spaeter Begruessung/
--   Menues/Erinnerungen — je Empfaenger-Sprache. Muster Rails/gettext: die WAHRHEIT sind die getrackten Dateien
--   packages/<pkg>/locales/<lang>.json (eine je Sprache), der HOST seedet sie (seed_data.sh _seed_ui_texts, Analog
--   onboarding/sections.json -> <pkg>.onboarding_state, docs/package-contract.md §3.2). Zur Laufzeit gibt es genau
--   EINEN Lookup-Pfad: core.fn_ui_text / core.fn_ui_texts / core.fn_hitl_texts (Workflows fragen die DB, nichts ist
--   eingebacken). Build-verwaltet: kein Owner-Edit, der Seed ersetzt je Paket komplett.
--
-- core.ui_languages = die EINE explizite Liste der unterstuetzten Sprachen (Django LANGUAGES / pg_i18n-Muster).
--   SoT ist der Core-Manifest-Block "languages" (_seed_ui_languages upsertet Name/Locale/Reihenfolge/Aliase);
--   core:V027 legt die Basis-Codes vorab an (der Sprach-Backfill und der Validator brauchen sie VOR dem Seed).
--   Der Validator agent.fn_validate_household_facts beschraenkt family.persons[].language auf diese Codes.
--   name = Eigenname (Endonym, z. B. 한국어) — so steht er im Picker und in HITL-Zeilen kind=language.
--   locale = BCP-47-Tag fuer Intl (Zahl-/Datumsformat im Workflow), aliases = freie Schreibweisen fuer
--   agent.fn_normalize_language (lowercase).
--
-- core.help_catalog = die fertig komponierte /help-Uebersicht je Sprache (eine Zeile je Katalogsprache). Die Texte
--   stammen aus dem Katalog (<pkg>.help.*), build.ps1 rendert je Sprache ein Fragment je Paket, der HOST komponiert
--   beim Seed/Paket-Statuswechsel ueber die AKTIVEN Pakete (seed_data.sh _seed_capabilities_catalog, Analog
--   core.cron_labels/core.ui_texts: host-geseedet). Der Orchestrator liest bei /help die Zeile der Sender-Sprache
--   (fehlt sie -> en). Abgeleiteter Install-Zustand, kein Owner-Edit.
--
-- Werkszustand-Reset: Schema core ist kein Paket-Schema -> core.fn_reset_user_data fasst die Tabellen nicht an
--   (wie core.cron_labels). ui_texts bildet ALLE gebuendelten Pakete ab (auch nicht installierte: Menue/Vermittler nennen
--   sie beim Namen) -> die Purge fasst sie nicht an, der Core-Seed raeumt Pakete ausserhalb des Release; help_catalog komponiert der
--   Host nach jedem Paket-Statuswechsel neu.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.ui_languages (
    code     text PRIMARY KEY CHECK (code ~ '^[a-z]{2}$'),          -- ISO 639-1 (BCP 47 kuerzester Tag)
    name     text NOT NULL CHECK (name <> ''),                        -- Eigenname (Endonym)
    locale   text NOT NULL CHECK (locale ~ '^[a-z]{2}-[A-Z]{2}$'),   -- Intl-Locale, z. B. de-DE
    ord      int  NOT NULL,                                           -- Reihenfolge im Picker
    aliases  text[] NOT NULL DEFAULT '{}',                            -- freie Schreibweisen (lowercase) -> code
    -- to_char-Muster fuer SQL-gerenderte Dokumente (core.fn_fmt_date), gleiche Ausgabe wie Intl im locale;
    -- nur Datums-Platzhalter + Trennzeichen (kein Freitext). NULL -> ISO.
    date_pattern text CHECK (date_pattern ~ '^(YYYY|MM|DD|[./ -])+$')
);
-- Phase C (Textkatalog): Bestands-Instanzen bekommen die Spalte nachgereicht (CREATE TABLE IF NOT EXISTS legt sie nicht an).
ALTER TABLE core.ui_languages ADD COLUMN IF NOT EXISTS date_pattern text CHECK (date_pattern ~ '^(YYYY|MM|DD|[./ -])+$');

-- Wertevorrat der Bot-Persona je Person (family.persons[].persona; Validator agent.fn_validate_household_facts).
-- SoT = Core-Manifest-Block "personas.list" (Host seed_data._seed_ui_personas upsertet, nie loeschen); core:V031
-- legt die Basis-Codes vorab an. 'neutral' steht nur fuer den Picker in der Liste — gespeichert wird es als
-- fehlender Key. Namen der Knoepfe: Katalog-Keys core.persona.name.<code>, Stil-Text: contexts/persona_styles.md.
CREATE TABLE IF NOT EXISTS core.ui_personas (
    code     text PRIMARY KEY CHECK (code ~ '^[a-z_]+$'),
    ord      int  NOT NULL                                            -- Reihenfolge im Picker
);

CREATE TABLE IF NOT EXISTS core.ui_texts (
    key      text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),   -- <pkg>.<bereich>.<name>
    lang     text NOT NULL REFERENCES core.ui_languages (code) ON DELETE CASCADE,
    text     text NOT NULL CHECK (text <> ''),
    package  text NOT NULL,                                                   -- deklarierendes Paket (Seed-/Purge-Scope)
    PRIMARY KEY (key, lang),
    CONSTRAINT ui_texts_key_package_check CHECK (split_part(key, '.', 1) = package)
);
CREATE INDEX IF NOT EXISTS ui_texts_package_idx ON core.ui_texts (package);

CREATE TABLE IF NOT EXISTS core.help_catalog (
    lang        text PRIMARY KEY REFERENCES core.ui_languages (code) ON DELETE CASCADE,
    content     text NOT NULL CHECK (content <> ''),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
