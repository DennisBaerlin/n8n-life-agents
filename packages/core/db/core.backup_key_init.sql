-- ============================================================
-- core.backup_key — DB-residenter Backup-Verschluesselungs-Schluessel (Phase 5: aus core.secret
--   zweck-umbenannt). Haelt GENAU EINEN nie-rotieren Wert (die gpg-Passphrase der CLI, AES256).
-- Zweck:   Ablage des Backup-Schluessels OHNE Repo-Beruehrung (diese Tabelle wird NIE geseedet —
--          seed_data.sh fasst nur core.config + agent.ai_models + Contexts an) und OHNE n8n-Env-
--          Oeffnung. Der Schluessel ist KATEGORISCH anders als die Rollen-Passwoerter (die liegen in
--          /etc/lifeagents/<pkg>.env, frei neu-wuerfelbar): er darf NIE rotieren (Rotation macht
--          bereits erstellte Backups unentschluesselbar) -> eigene, schwer-versehentlich-ueber-
--          schreibbare DB-Heimat (ON CONFLICT DO NOTHING), getrennt vom Datei-Secret-Lebenszyklus.
-- ACL:     NUR der Haupt-Credential-Owner (postgres/Write-Pfad) liest sie. finance_ro/context_ro/
--          core_ro bekommen explizit REVOKE — ein prompt-injizierter Agent erreicht den Schluessel
--          strukturell nicht. Der Schluessel ist STRUKTURELL nicht im Backup-Bundle (Schema `core`
--          steht in keinem manifest.json-`backup`-Block; contract_lint erzwingt das).
-- SETZEN (einmalig, out-of-band — NIE durch den Telegram-Chat): der Installer erzeugt den Schluessel
--   beim Provisioning (provision.sh -> bootstrap_owner.sh _ensure_backup_secret, `openssl rand`,
--   ON CONFLICT DO NOTHING = nie rotieren). Schluessel OFFLINE separat notieren — die DB-Kopie ist
--   nur die operative; ohne Offline-Kopie kein Restore nach Totalverlust (DR-Pflicht).
-- Usage:   db_apply.ps1 -File packages\core\db\core.backup_key_init.sql
-- Tests:   tests/db/core/test_core_backup_key_acl.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;
-- Explizites Ziel-Schema: der gehaertete Rollen-search_path (pg_catalog, agent, core) liesse
-- CREATE EXTENSION sonst gegen pg_catalog laufen -> Kollision mit core-gen_random_uuid.
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;

CREATE TABLE IF NOT EXISTS core.backup_key (
    key        text PRIMARY KEY,
    value      text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Hartes ACL: nie an die Agent-Leserollen (Tabellen-ACL ist durchsetzbar — anders als
-- Env-Vars oder GUCs, die jede Rolle via current_setting lesen koennte).
REVOKE ALL ON core.backup_key FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON core.backup_key FROM context_ro;
    END IF;
    -- core_ro (Core-Host-Leserolle agent+core+finance) liest breit core.* — der Backup-Key
    -- bleibt auch ihr verwehrt (util_create_core_ro REVOKEt ebenfalls; hier Backstop).
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
        REVOKE ALL ON core.backup_key FROM core_ro;
    END IF;
END $$;
