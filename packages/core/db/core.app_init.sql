-- ============================================================
-- Mini-App „Übersicht“ (docs/package-contract.md §3.12) — die zwei Host-Tabellen der read-only Telegram-Mini-App.
--
-- core.app_secret: der Pruef-Schluessel der Telegram-initData = HMAC_SHA256(key="WebAppData", msg=Bot-Token), nie das
--   Token selbst (der Schluessel steuert keinen Bot, faelscht aber jede initData -> ACL wie core.backup_key). Der Host
--   schreibt ihn bei JEDEM Deploy aus TELEGRAM_BOT_TOKEN (deploy_workflows.sh _ensure_app_secret, Token per stdin an
--   openssl, nie argv) -> ein Token-Wechsel greift sofort. Nie geseedet, nie im Backup (Schema core steht in keinem
--   backup-Block). Genau eine Zeile (id = true), Schluessel genau 32 Byte.
-- core.app_screens: host-geseedete Registry der Bildschirme (Manifest-Block app_screens, seed_data.sh
--   _seed_app_screens; Muster core.callback_handlers). core.fn_app_screen ruft handler_fn(jsonb) dynamisch auf
--   (to_regprocedure-Guard + core.fn_package_active). package = Purge-Schluessel (fn_pkg_purge_data).
-- Usage:   db_apply.ps1 -File packages\core\db\core.app_init.sql
-- Tests:   tests/db/core/test_core_app_secret_acl.sql, tests/db/core/test_fn_app_screen.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.app_secret (
    id         boolean PRIMARY KEY DEFAULT TRUE CHECK (id),
    webapp_key bytea NOT NULL CHECK (length(webapp_key) = 32),
    updated_at timestamptz NOT NULL DEFAULT now()
);

REVOKE ALL ON core.app_secret FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON core.app_secret FROM context_ro;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
        REVOKE ALL ON core.app_secret FROM core_ro;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS core.app_screens (
    screen     text PRIMARY KEY CHECK (screen ~ '^[a-z][a-z0-9_]*$'),
    package    text NOT NULL CHECK (package ~ '^[a-z][a-z0-9_]*$'),
    handler_fn text NOT NULL CHECK (handler_fn ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
    ord        int  NOT NULL DEFAULT 100,
    icon       text NOT NULL DEFAULT '' CHECK (length(icon) <= 16),
    updated_at timestamptz NOT NULL DEFAULT now()
);
