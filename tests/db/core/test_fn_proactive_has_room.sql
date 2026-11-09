-- tests/db/core/test_fn_proactive_has_room.sql
-- core.fn_proactive_has_room: dieselbe Regel wie der Claim fuer normal, ohne Schreiben; ein heute belegter Slot hat keinen Platz.
BEGIN;

DO $$
DECLARE
  o text := '__hr_owner__';
  d date := core.fn_today();
  b_before int; df_before int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'hr fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id',o,'first_name','HR','last_name','Owner','role','owner','birth_date','1980-01-01','telegram_user_id',7311,'as_of','2026-11-01')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;
  DELETE FROM core.config WHERE category = 'general' AND key IN ('proactive_daily_max', 'proactive_age_days');
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred;

  IF core.fn_proactive_has_room(o, 'a') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [1 frei]'; END IF;
  IF EXISTS (SELECT 1 FROM core.proactive_budget) THEN RAISE EXCEPTION 'FAIL [1 schreibt]'; END IF;
  PERFORM core.fn_proactive_claim(o, 'a', 'normal');
  IF core.fn_proactive_has_room(o, 'a') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [2 Slot heute belegt]'; END IF;
  IF core.fn_proactive_has_room(o, 'b') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [2 zweiter frei]'; END IF;
  PERFORM core.fn_proactive_claim(o, 'b', 'normal');
  SELECT count(*) INTO b_before FROM core.proactive_budget;
  SELECT count(*) INTO df_before FROM core.proactive_deferred;
  IF core.fn_proactive_has_room(o, 'c') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [3 voll]'; END IF;
  IF (SELECT count(*) FROM core.proactive_budget) <> b_before OR (SELECT count(*) FROM core.proactive_deferred) <> df_before THEN
    RAISE EXCEPTION 'FAIL [3 schreibt nichts]'; END IF;
  -- Altern
  INSERT INTO core.proactive_deferred (person_id, slot, since, last_rejected) VALUES (o, 'c', d - 2, d);
  IF core.fn_proactive_has_room(o, 'c') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [4 zwei Tage]'; END IF;
  UPDATE core.proactive_deferred SET since = d - 3;
  IF core.fn_proactive_has_room(o, 'c') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [4 drei Tage]'; END IF;
  -- erledigte Wartezeit (Luecke > 1 Tag) altert nicht
  UPDATE core.proactive_deferred SET last_rejected = d - 2;
  IF core.fn_proactive_has_room(o, 'c') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [4 Luecke]'; END IF;
  UPDATE core.proactive_deferred SET last_rejected = d;
  -- Pause
  DELETE FROM core.proactive_budget;
  INSERT INTO agent.reminder_pause (person_id, until_date) VALUES (o, d);
  IF core.fn_proactive_has_room(o, 'c') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5 Pause]'; END IF;
  DELETE FROM agent.reminder_pause;
  -- NULL = Owner
  IF core.fn_proactive_has_room(NULL, 'zz') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [6 NULL]'; END IF;

  RAISE NOTICE 'PASS test_fn_proactive_has_room';
END $$;

ROLLBACK;
