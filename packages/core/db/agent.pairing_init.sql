-- ============================================================
-- Pairing — Member-/Owner-Identity-Bootstrap (Multi-User, Phase 3 Dev/Release-Split-Plan)
-- Zweck:   agent.pairing_state traegt die Einmal-Pairing-Challenge, die eine numerische
--          Telegram-Identitaet (telegram_user_id, NIE Username — OpenClaw-CVE: Identity-
--          Rebinding) mit einer Haushalts-Rolle (owner|partner|child) verknuepft. Nutzt dasselbe
--          race-feste Single-Use-Challenge-Muster wie das fruehere /import-Wipe-Gate (Phase 4b
--          retired): (FOR UPDATE SKIP LOCKED, Exakt-Match, Expiry, Bindung,
--          consumed_at-Replay-Schutz), ABER ohne file_id und MIT role + fail_count-Lockout.
--          Eigene Init (single-responsibility): Identity-Bootstrap ist ein anderer Belang als
--          der Wipe-Gate-Zustand des Orchestrators — analog import_init/guide_init/monitor_init.
--
-- Zwei-Stufen-Bootstrap (volle Begruendung in fn_consume_pairing_challenge):
--   Stufe 1 — der Person-Stammsatz (first_name/last_name/birth_date/role) liegt bereits in den
--             family-Facts (Owner/Guide-Onboarding); fn_validate_household_facts bleibt hartes
--             Backstop-Gesetz (birth_date Pflicht) und wird hier NICHT aufgeweicht.
--   Stufe 2 — fn_consume_pairing_challenge MERGT bei Erfolg nur telegram_user_id + role in genau
--             diese bestehende Person (Merge-Pfad, validator-konform). Das volle Onboarding
--             (Konten/Investments/...) fuehrt danach der Guide.
--
-- DB-Gesetze (so tief wie moeglich verankert, Root-CLAUDE.md *Daten-Integritaet*):
--   - role-CHECK (owner|partner|child) — spiegelt die family-Facts-Role-Enum.
--   - challenge-Entropie-Boden als CHECK (>=8 alphanum ~47 bit; OWASP: <64 bit ⟹ Rate-Limit
--     Pflicht → fail_count-Lockout, s. fn_consume). Ein Buggy-Generator (4-Zeichen-Code) failt
--     strukturell, nicht erst im Tool.
--   - fail_count >= 0 (Defense-in-Depth gegen Direktzugriff).
--   - Partial-UNIQUE (telegram_user_id) WHERE consumed_at IS NULL — eine OFFENE Challenge je
--     numerischer Identitaet (Anti-Doppel-Arm; mehrere NULLs erlaubt fuer Owner-Bootstrap, bei
--     dem die ID erst am consume gebunden wird).
--   - Partial-UNIQUE (role='owner') WHERE consumed_at IS NULL — hoechstens EINE offene Owner-
--     Challenge (Race-Backstop; "Owner ist Einmal-Bootstrap"). Der "Owner existiert schon →
--     kein Re-Arm"-Guard liest die family-Facts und lebt in fn_arm (cross-table → fn-Ebene,
--     Projekt-Regel: Multi-Row/Cross-Table-Invarianten ueber fn, nicht ueber Gate-Trigger).
--
-- Usage:   db_apply.ps1 -File packages\core\db\agent.pairing_init.sql
-- Tests:   tests/db/core/test_fn_pairing_challenge.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

CREATE TABLE IF NOT EXISTS agent.pairing_state (
    id               serial PRIMARY KEY,
    chat_id          text,                          -- Chat, der einloesen darf; NULL = Owner-Bootstrap (Chat erst am consume bekannt)
    telegram_user_id bigint,                        -- numerische Identitaet (NIE Username); gesetzt am arm (Member, bekannt) bzw. am consume (Owner)
    role             text NOT NULL                  -- in die Person gemergte Rolle bei Erfolg
                       CHECK (role IN ('owner','partner','child')),
    challenge        text NOT NULL                  -- >=8 alphanum Pairing-Code, exakt zu tippen
                       CONSTRAINT pairing_challenge_min_entropy CHECK (challenge ~ '^[A-Za-z0-9]{8,}$'),
    armed_at         timestamptz NOT NULL DEFAULT now(),
    expires_at       timestamptz NOT NULL,          -- kurzes Fenster (10 Min)
    consumed_at      timestamptz,                   -- einmalig einloesbar (Replay-Schutz)
    fail_count       int NOT NULL DEFAULT 0         -- Falsch-Code-Versuche; >=3 invalidiert die Challenge
                       CONSTRAINT pairing_fail_count_nonneg CHECK (fail_count >= 0)
);

-- WS-5a — Einladungs-Modell (owner-bestaetigt): additive Stage-Spalten (Init-only, ADD COLUMN IF NOT
-- EXISTS erreicht auch bestehende Instanzen idempotent; KEINE V-Migration, kein Backfill).
--   person_id      = Einladungs-Ziel (vorhandene family-Person). NULL beim Owner-Bootstrap (Chicken-Egg:
--                    der Owner-Pfad loest sein unverknuepftes Skelett zur Laufzeit auf, s. fn_consume).
--                    Member-Invite setzt es beim arm -> fn_confirm bindet GENAU diese Person.
--   claimed_uid/_chat_id/_at = STAGE-Zustand: das Mitglied hat den Code eingeloest (fn_claim), die
--                    Owner-Bestaetigung (fn_confirm via callback_query) steht noch aus. claimed_uid bleibt
--                    BEWUSST getrennt von telegram_user_id (sonst kollidiert das Stagen gegen den
--                    Partial-UNIQUE pairing_state_one_open_per_user). claimed_chat_id traegt den Member-Chat,
--                    damit der spaetere Owner-Confirm/Reject dem Mitglied antworten kann.
ALTER TABLE agent.pairing_state ADD COLUMN IF NOT EXISTS person_id      text;
ALTER TABLE agent.pairing_state ADD COLUMN IF NOT EXISTS claimed_uid    bigint;
ALTER TABLE agent.pairing_state ADD COLUMN IF NOT EXISTS claimed_chat_id text;
ALTER TABLE agent.pairing_state ADD COLUMN IF NOT EXISTS claimed_at     timestamptz;

-- Textkatalog Phase B: language_hint = die Telegram-App-Sprache des einloesenden Mitglieds (from.language_code,
-- normalisiert per agent.fn_normalize_language auf einen Katalog-Code, sonst NULL), gemerkt beim claim. NUR ein
-- Vorschlag: nach dem Owner-Confirm markiert der Sprach-Picker diese Sprache; gespeichert wird erst der Tipp der
-- Person (lang:-Callback). Kein FK auf core.ui_languages (dieses Init laeuft vor core.ui_texts_init.sql; die fn
-- normalisiert ohnehin nur auf vorhandene Codes) -> Format-CHECK als Backstop.
ALTER TABLE agent.pairing_state ADD COLUMN IF NOT EXISTS language_hint text
    CONSTRAINT pairing_language_hint_format CHECK (language_hint ~ '^[a-z]{2}$');

-- Konsistenz-Backstop: die drei claimed_*-Felder werden gemeinsam gesetzt (entweder alle NULL = ungestaged
-- oder alle befuellt = gestaged). Idempotent via Katalog-Guard (ADD CONSTRAINT IF NOT EXISTS gibt es nicht).
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pairing_claimed_together') THEN
        ALTER TABLE agent.pairing_state ADD CONSTRAINT pairing_claimed_together CHECK (
            (claimed_uid IS NULL AND claimed_chat_id IS NULL AND claimed_at IS NULL)
         OR (claimed_uid IS NOT NULL AND claimed_chat_id IS NOT NULL AND claimed_at IS NOT NULL));
    END IF;
END $$;

-- Lookup: consume matcht ueber den Code (chat_id kann fuer Owner-Bootstrap NULL sein).
CREATE INDEX IF NOT EXISTS pairing_state_challenge_lookup
    ON agent.pairing_state (challenge)
    WHERE consumed_at IS NULL;

-- Eine offene Challenge je numerischer Identitaet (mehrere NULLs erlaubt — Owner bindet spaeter).
CREATE UNIQUE INDEX IF NOT EXISTS pairing_state_one_open_per_user
    ON agent.pairing_state (telegram_user_id)
    WHERE consumed_at IS NULL AND telegram_user_id IS NOT NULL;

-- Hoechstens eine offene Owner-Challenge (Race-Backstop zum fn_arm-Owner-Guard).
CREATE UNIQUE INDEX IF NOT EXISTS pairing_state_one_open_owner
    ON agent.pairing_state ((role))
    WHERE consumed_at IS NULL AND role = 'owner';

-- WS-5a: hoechstens EINE offene Einladung je Ziel-Person (Member-Analogon zum one_open_owner-Index;
-- fn_arm superseded aeltere offene Einladungen derselben person_id vor dem INSERT -> Race-Backstop).
CREATE UNIQUE INDEX IF NOT EXISTS pairing_state_one_open_per_person
    ON agent.pairing_state (person_id)
    WHERE consumed_at IS NULL AND person_id IS NOT NULL;

-- ------------------------------------------------------------
-- Knock-Throttle (Owner-Notify-Anti-Spam): MIGRIERT (Phase Notify). Der Cooldown-Zustand lebt jetzt in
-- der GETEILTEN core.notification_state (source='knock', key=uid) statt der frueheren agent.knock_log
-- -> EINE Dedup-Adresse aller Producer; fn_register_knock ruft core.fn_should_notify. Die alte Tabelle
-- droppt einmalig V012__consolidate_notification_state.sql.

-- Lesepfad: NUR die Haupt-Credential (Pre-Router) und die Pairing-fns. KEIN Grant an core_ro (Security-Audit 2026-10):
-- die offenen Einmal-Codes stehen im Klartext, der Frei-SQL-Pfad darf sie nie sehen. Den Sammel-Grant ueber agent.*
-- nimmt util_create_core_ro.sql (Deny-Liste) wieder zurueck.
