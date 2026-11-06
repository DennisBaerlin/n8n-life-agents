-- ============================================================
-- core.cron_labels — generische Chat-Toggle-Registry der opt-in Crons (Phase 0, WS-0c #2/#3)
--   Anwenden via: db_apply.ps1 -File packages\core\db\core.cron_labels_init.sql
--
-- Zweck: zwei Dinge in EINER Registry (Pattern-Parität §8, Geschwister core.context_validators/
--   _renderers/advisors/protected_contexts/callback_handlers):
--   (1) MITGLIEDSCHAFT = Erinnerungs-Registry (Roter Faden 2026-10-23): JEDER Cron, der dem Nutzer schreibt, steht
--       hier (cron_toggle_lint (i)) und erscheint in /reminders. Schaltbar ist er je Ebene: scope='household' ueber
--       core.fn_set_cron_enable (Owner), scope='person' je Person (agent.reminder_prefs), mandatory = nie. Reine
--       Plumbing-Crons (Kurse, Wechselkurse) ohne Nachricht stehen NICHT drin und sind nur per Konsole schaltbar.
--       (Frueher: nur opt-in Crons, Re-Aktivieren nur Konsole — vom Owner am 2026-10-23 abgeloest.)
--       Warum Mitgliedschaft statt is_toggleable-Bool: drei Repo-Praezedenzen (context_validators/
--       _renderers/protected_contexts) — Zeile existiert ⇒ Faehigkeit; sicher, weil installer-only
--       geschrieben (D10: Paket-Rollen haben auf Schema core keinen Schreibzugriff, kein $fromAI-Pfad);
--       ein separates Bool waere redundante zweite Wahrheitsquelle mit Widerspruchs-Risiko (arch-challenge
--       E1 REJECT, docs/package-contract.md §8).
--   (2) TEXTE: die Toast-/Meldungstexte je Richtung (an/aus) stehen im Textkatalog des deklarierenden Pakets
--       (<pkg>.cron.<cron_key>.on_toast|off_toast|on_message|off_message, docs/package-contract.md §3.11) und kommen in
--       der Sprache des Tippenden. Die frueheren Text-Spalten dieser Tabelle hat core:V029 entfernt.
--
-- BOUNDARY (Deklaration vs. Ausfuehrung, docs/package-contract.md §3): das PAKET DEKLARIERT die Zeile NUR
--   im manifest.json ("cron_labels"-Liste); der HOST (seed_data.sh, _seed_cron_labels, jq) UPSERTET sie.
--   Paket-Rollen sind via D10 schema-isoliert -> koennen die Registry strukturell nicht schreiben (einziger
--   Schreiber = Installer/Owner-Superuser; kein REVOKE noetig, PG grantet Tabellen ohnehin nicht an PUBLIC).
--
-- LAYERING (arch-challenge E3 ADOPT): die fn gibt KEINE Texte zurueck (bleibt rein {ok,key,enabled},
--   trivial testbar ohne Wortlaut-Assertion). Der Orchestrator holt die Texte selbst (Presentation in der
--   Presentation-Schicht) — sein Postgres-Node liest neben dem fn-Call package aus DIESER Tabelle + den Katalog.
--
-- EINE Zeile je Cron (PRIMARY KEY cron_key).
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.cron_labels (
    cron_key    text PRIMARY KEY                       -- == core.config.key bei category='cron_enable' (nur opt-in Crons)
                CHECK (cron_key ~ '^[a-z][a-z0-9_]*$'),-- lowercase Identifier, fuehrender Buchstabe (wie der cron_toggle_lint-$cronRx)
    package     text NOT NULL DEFAULT 'core',          -- deklarierendes Paket (Audit / Uninstall-Purge-Scope)
    updated_at  timestamptz NOT NULL DEFAULT now()
);
-- Roter Faden (2026-10-23): ZWEI Schalt-Ebenen in derselben Registry.
--   scope='household' (Default, Manifest cron_labels.list): Haushalts-Schalter = core.config cron_enable.<key>,
--     geschaltet vom Owner ueber core.fn_set_cron_enable (cron_on:/cron_off:-Knoepfe).
--   scope='person' (Manifest cron_labels.person): jede Person schaltet IHRE Zustellung selbst (agent.reminder_prefs,
--     rem:on|off:<key>-Knoepfe ueber core.fn_handle_reminder_cb); cron_enable bleibt der Konsolen-Notschalter fuer alle
--     (always-on). default_enabled = Zustand ohne Praeferenz-Zeile (Muster Knock/Novu: Default + sparse Overrides).
--   core.fn_set_cron_enable lehnt scope='person' ab (sonst schaltete ein alter Knopf den Notschalter fuer alle).
ALTER TABLE core.cron_labels ADD COLUMN IF NOT EXISTS scope text NOT NULL DEFAULT 'household';
ALTER TABLE core.cron_labels ADD COLUMN IF NOT EXISTS default_enabled boolean NOT NULL DEFAULT TRUE;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cron_labels_scope_check') THEN
        ALTER TABLE core.cron_labels ADD CONSTRAINT cron_labels_scope_check CHECK (scope IN ('household', 'person'));
    END IF;
END $$;
-- Paket B (/reminders): mandatory = Pflicht-Erinnerung, nur ANZEIGE im Menue, nie schaltbar (gesetzliche Fristen im
-- Ereignisfall, Muster Novu "critical workflows"); Manifest cron_labels.mandatory. Nur fuer Haushalts-Reminder sinnvoll
-- (eine Pflicht je Person gibt es nicht) -> CHECK. core.fn_set_cron_enable + core.fn_handle_reminder_cb lehnen sie ab.
ALTER TABLE core.cron_labels ADD COLUMN IF NOT EXISTS mandatory boolean NOT NULL DEFAULT FALSE;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cron_labels_mandatory_household_check') THEN
        ALTER TABLE core.cron_labels ADD CONSTRAINT cron_labels_mandatory_household_check
            CHECK (NOT mandatory OR scope = 'household');
    END IF;
END $$;

-- KEIN updated_at-Touch-Trigger (Muster core.context_validators/_renderers): core.touch_updated_at lebt in
-- core.package_registry_init.sql, das ALPHABETISCH NACH dieser Datei applied wird. Der Seed setzt updated_at
-- im ON CONFLICT DO UPDATE explizit -> kein Trigger noetig (selten beschriebene Registry).
