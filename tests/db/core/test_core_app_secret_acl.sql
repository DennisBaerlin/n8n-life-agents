-- tests/db/core/test_core_app_secret_acl.sql
-- Mini-App (docs/package-contract.md §3.12): core.app_secret haelt den aus dem Bot-Token abgeleiteten Pruef-Schluessel
-- der Telegram-initData. Wer ihn liest, kann sich als jede Person ausgeben -> keine Leserolle darf ihn sehen (Muster
-- test_core_backup_key_acl.sql; faengt auch "ein Rollen-Re-Apply re-grantet core.*").
BEGIN;

DO $$
DECLARE v_role text;
BEGIN
  FOREACH v_role IN ARRAY ARRAY['finance_ro', 'finance_rw', 'context_ro', 'core_ro', 'career_ro', 'career_rw', 'estate_ro', 'estate_rw'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN CONTINUE; END IF;
    IF has_table_privilege(v_role, 'core.app_secret', 'SELECT') THEN
      RAISE EXCEPTION 'FAIL acl [% kann core.app_secret lesen - Identitaets-Faelschung moeglich! REVOKE pruefen]', v_role;
    END IF;
  END LOOP;
  -- Form: genau eine Zeile moeglich, Schluessel 32 Byte
  BEGIN
    INSERT INTO core.app_secret (id, webapp_key) VALUES (false, decode(repeat('00', 32), 'hex'));
    RAISE EXCEPTION 'FAIL form [zweite Zeile (id=false) wurde angenommen]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO core.app_secret (id, webapp_key) VALUES (true, decode('00', 'hex'));
    RAISE EXCEPTION 'FAIL form [Schluessel != 32 Byte angenommen]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'PASS core_app_secret_acl [keine Leserolle, eine Zeile, 32 Byte]';
END $$;

ROLLBACK;
