-- tests/db/core/test_fn_mark_told.sql
-- core.fn_mark_told: "gesagt" zaehlt nur fuer den Owner (Empfaenger des Waechters); im Zweifel kein Merker, nie ein Fehler.
BEGIN;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family','t',NULL,'lazy','f',
  jsonb_build_object('managed_by','agent','protected', TRUE,
    'facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                         'birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
      jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner',
                         'birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;

DO $$
DECLARE v_exp timestamptz;
BEGIN
  PERFORM core.fn_mark_told('__p__', '111', 'k_owner');
  SELECT expires_at INTO v_exp FROM core.notification_state WHERE source = '__p__:told_owner' AND key = 'k_owner' AND state = 'fired';
  IF v_exp IS NULL THEN RAISE EXCEPTION 'FAIL [Owner -> Merker mit Frist]'; END IF;
  IF v_exp NOT BETWEEN now() + interval '2 days 23 hours' AND now() + interval '3 days 1 hour' THEN
    RAISE EXCEPTION 'FAIL [Frist 3 Tage]: %', v_exp; END IF;

  PERFORM core.fn_mark_told('__p__', '222', 'k_member');
  PERFORM core.fn_mark_told('__p__', '', 'k_empty');
  PERFORM core.fn_mark_told('__p__', NULL, 'k_null');
  PERFORM core.fn_mark_told('__p__', 'abc', 'k_text');
  PERFORM core.fn_mark_told('__p__', '999', 'k_unknown');
  PERFORM core.fn_mark_told('__p__', '99999999999999999999999', 'k_overflow');
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = '__p__:told_owner' AND key <> 'k_owner') THEN
    RAISE EXCEPTION 'FAIL [Mitglied/leer/Text/unbekannt/Ueberlauf -> kein Merker]'; END IF;

  -- Owner hoerte, dann meldet der Fold einem Mitglied die neue Lage -> Merker weg; erneut Owner -> Frist neu
  PERFORM core.fn_mark_told('__p__', '222', 'k_owner');
  IF core.fn_notify_told('__p__:told_owner', 'k_owner') THEN RAISE EXCEPTION 'FAIL [neue Lage nur Mitglied -> Merker weg]'; END IF;
  PERFORM core.fn_mark_told('__p__', '111', 'k_owner');
  UPDATE core.notification_state SET expires_at = now() + interval '1 hour' WHERE source = '__p__:told_owner' AND key = 'k_owner';
  PERFORM core.fn_mark_told('__p__', '111', 'k_owner');
  IF (SELECT expires_at FROM core.notification_state WHERE source = '__p__:told_owner' AND key = 'k_owner') < now() + interval '2 days' THEN
    RAISE EXCEPTION 'FAIL [Owner erneut -> Frist neu]'; END IF;

  RAISE NOTICE 'PASS fn_mark_told';
END $$;
ROLLBACK;
