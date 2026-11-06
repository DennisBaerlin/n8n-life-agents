-- ============================================================
-- V006 (core) — Phase 5: core.secret -> core.backup_key (Zweck-Umbenennung).
--   Seit Phase 4b haelt core.secret nur noch EINEN Wert (den Backup-Schluessel; die Rollen-
--   Passwoerter ziehen mit dem Secret-Modell-Umbau in /etc/lifeagents/<pkg>.env). Der generische
--   Tabellenname ist damit irrefuehrend -> zweck-benannt nach core.backup_key.
--
--   Die Baseline-Init (core.backup_key_init.sql) legt die NEUE Tabelle an (fresh DB = Endzustand).
--   Diese Migration raeumt den ALTBESTAND einer Vor-V006-DB einmalig (ledger-gegated): den/die
--   Wert(e) aus core.secret in core.backup_key heben (ON CONFLICT DO NOTHING — der nie-rotieren-
--   Schluessel bleibt, falls beide existieren), dann core.secret droppen. Fresh DB: core.secret
--   existiert nie -> jeder Schritt No-op.
--
-- APPLY-ORDER: Inits (core.backup_key_init = Endzustand) -> V (hier) -> R. Re-run-sicher; ledger-
--   gegated = laeuft genau einmal.
-- ============================================================

DO $$ BEGIN
    IF to_regclass('core.secret') IS NOT NULL THEN
        -- Daten-Erhalt: bestehenden Backup-Schluessel uebernehmen (ON CONFLICT = backup_key gewinnt).
        INSERT INTO core.backup_key (key, value, updated_at)
        SELECT key, value, updated_at FROM core.secret
        ON CONFLICT (key) DO NOTHING;
        -- Alt-Tabelle entfernen (ihre ACL faellt mit ihr; core.backup_key traegt die eigene REVOKE-Fence).
        DROP TABLE core.secret;
    END IF;
END $$;
