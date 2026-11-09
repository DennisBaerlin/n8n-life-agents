-- tests/db/core/test_fn_proactive_claim.sql
-- core.fn_proactive_claim: Tagesbudget, Klassen, Pause, Altern, fail-open. BEGIN..ROLLBACK, Daten erfunden.
BEGIN;

DO $$
DECLARE
  o text := '__pc_owner__';
  m text := '__pc_member__';
  d date := core.fn_today();
  n int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'pc fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id',o,'first_name','PC','last_name','Owner','role','owner','birth_date','1980-01-01','telegram_user_id',7301,'as_of','2026-11-01'),
            jsonb_build_object('person_id',m,'first_name','PC','last_name','Member','role','partner','birth_date','1982-01-01','telegram_user_id',7302,'as_of','2026-11-01')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;
  DELETE FROM core.config WHERE category = 'general' AND key IN ('proactive_daily_max', 'proactive_age_days', 'proactive_pause_days');

  -- zwei Slots frei, dritter abgewiesen
  IF core.fn_proactive_claim(o, 'a', 'normal') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [1 erster Slot]'; END IF;
  IF core.fn_proactive_claim(o, 'b', 'normal') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [1 zweiter Slot]'; END IF;
  IF core.fn_proactive_claim(o, 'c', 'normal') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [1 dritter Slot]'; END IF;
  -- gleicher Slot zaehlt einmal
  IF core.fn_proactive_claim(o, 'a', 'normal') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [2 gleicher Slot]'; END IF;
  SELECT count(*) INTO n FROM core.proactive_budget WHERE person_id = o AND day = d;
  IF n <> 2 THEN RAISE EXCEPTION 'FAIL [2 Zaehler %]', n; END IF;
  -- Zaehltag = fn_today
  IF NOT EXISTS (SELECT 1 FROM core.proactive_budget WHERE person_id = o AND day = core.fn_today() AND slot = 'a') THEN
    RAISE EXCEPTION 'FAIL [2a Zaehltag]'; END IF;
  -- priority ueber Grenze: true, zaehlt mit
  IF core.fn_proactive_claim(o, 'p', 'priority') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [3 priority]'; END IF;
  SELECT count(*) INTO n FROM core.proactive_budget WHERE person_id = o AND day = d;
  IF n <> 3 THEN RAISE EXCEPTION 'FAIL [3 zaehlt mit %]', n; END IF;
  -- Budget je Empfaenger
  IF core.fn_proactive_claim(m, 'a', 'normal') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [4 Mitglied eigenes Budget]'; END IF;

  -- nach priority-Belegung ist normal abgewiesen
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred;
  PERFORM core.fn_proactive_claim(o, 'p1', 'priority');
  PERFORM core.fn_proactive_claim(o, 'p2', 'priority');
  IF core.fn_proactive_claim(o, 'n', 'normal') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5 normal nach priority]'; END IF;

  -- neuer Tag frei; alte Zeilen geraeumt
  DELETE FROM core.proactive_deferred;
  UPDATE core.proactive_budget SET day = day - 1;
  IF core.fn_proactive_claim(o, 'n', 'normal') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [6 neuer Tag]'; END IF;
  INSERT INTO core.proactive_budget (person_id, day, slot, class) VALUES (o, d - 8, 'old', 'normal');
  PERFORM core.fn_proactive_claim(o, 'n2', 'normal');
  IF EXISTS (SELECT 1 FROM core.proactive_budget WHERE slot = 'old') THEN RAISE EXCEPTION 'FAIL [6 alte Zeile]'; END IF;

  -- Config 1, 0, kaputt
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred;
  INSERT INTO core.config (package, category, key, value) VALUES ('core', 'general', 'proactive_daily_max', '1');
  IF core.fn_proactive_claim(o, 'x', 'normal') IS NOT TRUE OR core.fn_proactive_claim(o, 'y', 'normal') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [7 Config 1]'; END IF;
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred;
  UPDATE core.config SET value = '0' WHERE category = 'general' AND key = 'proactive_daily_max';
  IF core.fn_proactive_claim(o, 'x', 'normal') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [7 Config 0]'; END IF;
  IF core.fn_proactive_claim(o, 'q', 'priority') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [7 Config 0 priority]'; END IF;
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred;
  UPDATE core.config SET value = 'kaputt' WHERE category = 'general' AND key = 'proactive_daily_max';
  PERFORM core.fn_proactive_claim(o, 'x', 'normal'); PERFORM core.fn_proactive_claim(o, 'y', 'normal');
  IF core.fn_proactive_claim(o, 'z', 'normal') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [7 kaputt = Default 2]'; END IF;
  DELETE FROM core.config WHERE category = 'general' AND key = 'proactive_daily_max';

  -- Pause
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred;
  INSERT INTO agent.reminder_pause (person_id, until_date) VALUES (o, d + 3);
  IF core.fn_proactive_claim(o, 'n', 'normal') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [8 Pause normal]'; END IF;
  IF core.fn_proactive_claim(o, 'p', 'priority') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [8 Pause priority]'; END IF;
  IF EXISTS (SELECT 1 FROM core.proactive_deferred WHERE person_id = o) THEN RAISE EXCEPTION 'FAIL [8 in der Pause kein Eintrag]'; END IF;
  IF core.fn_proactive_claim(o, 'dl', 'deadline') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [8 Pause deadline]'; END IF;
  -- letzter Pausetag gilt, Tag danach frei
  UPDATE agent.reminder_pause SET until_date = d WHERE person_id = o;
  IF core.fn_proactive_claim(o, 'n', 'normal') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [8 letzter Pausetag]'; END IF;
  UPDATE agent.reminder_pause SET until_date = d - 1 WHERE person_id = o;
  IF core.fn_proactive_claim(o, 'n', 'normal') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [8 abgelaufene Pause]'; END IF;
  DELETE FROM agent.reminder_pause;

  -- Altern: erster Tag gemerkt, 2 Tage false, 3 Tage true + Eintrag weg
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred;
  PERFORM core.fn_proactive_claim(o, 'a', 'normal'); PERFORM core.fn_proactive_claim(o, 'b', 'normal');
  IF core.fn_proactive_claim(o, 'late', 'normal') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [9 abgewiesen]'; END IF;
  IF (SELECT since FROM core.proactive_deferred WHERE person_id = o AND slot = 'late') <> d THEN RAISE EXCEPTION 'FAIL [9 since]'; END IF;
  UPDATE core.proactive_deferred SET since = d - 2 WHERE slot = 'late';
  IF core.fn_proactive_claim(o, 'late', 'normal') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [9 zwei Tage]'; END IF;
  IF (SELECT since FROM core.proactive_deferred WHERE slot = 'late') <> d - 2 THEN RAISE EXCEPTION 'FAIL [9 since bleibt]'; END IF;
  UPDATE core.proactive_deferred SET since = d - 3 WHERE slot = 'late';
  IF core.fn_proactive_claim(o, 'late', 'normal') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [9 drei Tage]'; END IF;
  IF EXISTS (SELECT 1 FROM core.proactive_deferred WHERE slot = 'late') THEN RAISE EXCEPTION 'FAIL [9 Eintrag weg]'; END IF;
  IF (SELECT count(*) FROM core.proactive_budget WHERE person_id = o AND day = d) <> 3 THEN RAISE EXCEPTION 'FAIL [9 zaehlt mit]'; END IF;

  -- Luecke beim Warten: since faengt neu an
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred;
  PERFORM core.fn_proactive_claim(o, 'a', 'normal'); PERFORM core.fn_proactive_claim(o, 'b', 'normal');
  INSERT INTO core.proactive_deferred (person_id, slot, since, last_rejected) VALUES (o, 'stale', d - 5, d - 4);
  IF core.fn_proactive_claim(o, 'stale', 'normal') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [9b Luecke]'; END IF;
  IF (SELECT since FROM core.proactive_deferred WHERE slot = 'stale') <> d THEN RAISE EXCEPTION 'FAIL [9b since neu]'; END IF;

  -- NULL = Owner
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred;
  IF core.fn_proactive_claim(NULL, 'o', 'normal') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [10 NULL]'; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.proactive_budget WHERE person_id = agent.fn_owner_person_id() AND slot = 'o') THEN
    RAISE EXCEPTION 'FAIL [10 NULL = Owner]'; END IF;

  -- fail-open: unbekannte Person, unbekannte Klasse -> true, kein Fehler
  IF core.fn_proactive_claim('__nobody__', 'x', 'normal') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [11 unbekannte Person]'; END IF;
  IF core.fn_proactive_claim(o, 'x', 'unsinn') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [11 unbekannte Klasse]'; END IF;

  RAISE NOTICE 'PASS test_fn_proactive_claim';
END $$;

ROLLBACK;
