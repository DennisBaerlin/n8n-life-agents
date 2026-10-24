-- tests/db/career/test_fn_read_job_matches.sql
-- career.fn_read_job_matches(chat_id, limit) — gebundenes Lesefenster der EIGENEN Job-Treffer (Security-Audit 2026-10,
-- Owner "strikt privat") + die Host-abgeleitete Sperre person-privater Tabellen in core.fn_provision_package_roles.
--   1) chat_id 111 (erika) -> nur erikas Treffer, neueste Bewertung zuerst; 222 (lena) -> nur lenas.
--   2) NULL / nicht-numerisch / unaufgeloest -> leere Menge (fail-closed, kein RAISE).
--   3) EXECUTE nur fuer career_rw; eine Frei-SQL-Sitzung (Login-Rolle *_ro) bekaeme selbst mit EXECUTE nichts.
--   4) career per_user + fn_provision_package_roles('career') -> career_ro/core_ro ohne SELECT auf job_matches,
--      onboarding_state und die abhaengige View v_job_matches; market_signals (kein person_id) bleibt lesbar.
-- Self-contained (BEGIN..ROLLBACK; GRANT/REVOKE sind transaktional).
BEGIN;
DO $$
DECLARE v_cnt int; v_title text;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f',
    jsonb_build_object('managed_by','agent','protected', true,
      'facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                           'birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
        jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner',
                           'birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  INSERT INTO career.job_matches (person_id, source, external_id, title, score, feedback_at)
  VALUES ('erika','bundesagentur','RJM1','Erika Alt',  3, now() - interval '2 days'),
         ('erika','bundesagentur','RJM2','Erika Neu',  4, now() - interval '1 hour'),
         ('lena', 'bundesagentur','RJM3','Lena Stelle',2, NULL);

  -- 1) eigene Treffer, neueste Bewertung zuerst
  SELECT count(*) INTO v_cnt FROM career.fn_read_job_matches('111');
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [1a] erika erwartet 2 Treffer, got %', v_cnt; END IF;
  SELECT title INTO v_title FROM career.fn_read_job_matches('111') LIMIT 1;
  IF v_title IS DISTINCT FROM 'Erika Neu' THEN RAISE EXCEPTION 'FAIL [1b] erste Zeile = zuletzt bewertet erwartet, got %', v_title; END IF;
  SELECT count(*) INTO v_cnt FROM career.fn_read_job_matches('222') WHERE title LIKE 'Erika%';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [1c] lena sieht erikas Treffer (Leck)'; END IF;
  SELECT count(*) INTO v_cnt FROM career.fn_read_job_matches('111', 1);
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [1d] p_limit=1 erwartet 1 Zeile, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [1] eigene Treffer, neueste Bewertung zuerst, keine fremden, Limit greift';

  -- 2) fail-closed
  SELECT count(*) INTO v_cnt FROM career.fn_read_job_matches(NULL);
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [2a] NULL chat_id lieferte %', v_cnt; END IF;
  SELECT count(*) INTO v_cnt FROM career.fn_read_job_matches('test_e2e_x');
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [2b] nicht-numerische chat_id lieferte %', v_cnt; END IF;
  SELECT count(*) INTO v_cnt FROM career.fn_read_job_matches('999');
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [2c] unaufgeloeste chat_id lieferte %', v_cnt; END IF;
  RAISE NOTICE 'PASS [2] NULL/nicht-numerisch/unaufgeloest -> leere Menge';

  -- 4) Host-abgeleitete Sperre: career per_user -> person-private Tabellen + abhaengige View fuer die Frei-SQL-Rollen zu
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_profile','per_user','own_user_only','career')
  ON CONFLICT (context_name) DO UPDATE SET scope='per_user', write_permission='own_user_only';
  PERFORM core.fn_provision_package_roles(jsonb_build_object('package','career'));
  IF has_table_privilege('career_ro', 'career.job_matches', 'SELECT')
     OR has_table_privilege('career_ro', 'career.onboarding_state', 'SELECT')
     OR has_table_privilege('career_ro', 'career.v_job_matches', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL [4a] career_ro liest noch eine person-private Tabelle/View';
  END IF;
  IF has_table_privilege('core_ro', 'career.job_matches', 'SELECT')
     OR has_table_privilege('core_ro', 'career.v_job_matches', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL [4b] core_ro liest noch career.job_matches / v_job_matches';
  END IF;
  IF NOT has_table_privilege('career_ro', 'career.market_signals', 'SELECT')
     OR NOT has_table_privilege('core_ro', 'career.market_signals', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL [4c] career.market_signals (kein person_id) wurde mitgesperrt';
  END IF;
  IF NOT has_table_privilege('career_rw', 'career.job_matches', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL [4d] career_rw (Schreibrolle) hat das Leserecht verloren';
  END IF;
  RAISE NOTICE 'PASS [4] person-private Tabellen + View fuer career_ro/core_ro gesperrt, market_signals/career_rw unberuehrt';
END $$;

-- 3) Frei-SQL-Rollen: kein EXECUTE (career_ro/core_ro), nur career_rw (das read_job_matches-Werkzeug). Defense in
-- depth: selbst MIT EXECUTE liefert eine Frei-SQL-Sitzung nichts — dafuer EXECUTE hier kurz an career_ro geben.
-- SET SESSION AUTHORIZATION aendert session_user (SET ROLE nicht) — genau das prueft core.fn_is_free_sql_session.
DO $$
BEGIN
  IF has_function_privilege('career_ro', 'career.fn_read_job_matches(text, int)', 'EXECUTE')
     OR has_function_privilege('core_ro', 'career.fn_read_job_matches(text, int)', 'EXECUTE')
     OR NOT has_function_privilege('career_rw', 'career.fn_read_job_matches(text, int)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [3a] EXECUTE-Verteilung falsch (erwartet: nur career_rw)';
  END IF;
  GRANT EXECUTE ON FUNCTION career.fn_read_job_matches(text, int) TO career_ro;
END $$;
SET LOCAL SESSION AUTHORIZATION career_ro;
DO $$
DECLARE v_cnt int;
BEGIN
  SELECT count(*) INTO v_cnt FROM career.fn_read_job_matches('111');
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [3b] Frei-SQL-Sitzung las erikas Treffer per chat_id (Spoof-Leck)'; END IF;
  RAISE NOTICE 'PASS [3] nur career_rw hat EXECUTE; eine Frei-SQL-Sitzung bekaeme trotzdem nichts';
END $$;
RESET SESSION AUTHORIZATION;
ROLLBACK;
