-- tests/db/core/test_core_backup_key_acl.sql
-- Phase 5: core.secret wurde zweck-umbenannt zu core.backup_key (haelt nur den nie-rotieren
-- Backup-Schluessel; die Rollen-Passwoerter liegen jetzt in /etc/lifeagents/<pkg>.env). Backup laeuft
-- via pg_dump/gpg in der CLI; die gpg-Passphrase liest der CLI-Superuser aus core.backup_key.
-- ERHALTENE Invariante (vormals test_core_secret_acl.sql / test_fn_backup_crypto.sql m2): die Agent-
-- Leserollen duerfen den Schluessel NIE lesen — ein prompt-injizierter Agent kann core.backup_key
-- strukturell nicht erreichen. Faengt insb. die Drift-Klasse "ein Rollen-Re-Apply re-grantet core.backup_key".
BEGIN;

DO $$
DECLARE v_role TEXT;
BEGIN
  FOREACH v_role IN ARRAY ARRAY['finance_ro', 'context_ro', 'core_ro', 'career_ro'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN CONTINUE; END IF;
    IF has_table_privilege(v_role, 'core.backup_key', 'SELECT') THEN
      RAISE EXCEPTION 'FAIL acl [% kann core.backup_key lesen — Backup-Key-Leak-Pfad! util_create_core_ro/REVOKE pruefen]', v_role;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS core_backup_key_acl [Leserollen ohne core.backup_key-Zugriff]';
END $$;

ROLLBACK;
