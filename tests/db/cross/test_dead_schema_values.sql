-- tests/db/cross/test_dead_schema_values.sql
-- Tote Werte und Objekte bleiben weg: kein Schreiber setzt sie, kein Leser liest sie, also darf die Tabellen-Regel
-- sie auch nicht mehr erlauben (sonst liest ein Modell beim Suchen eine Bedeutung hinein, die es nicht gibt).
--   * agent.reaction_log.kind 'mood' (Stimmung neben einer Antwort, in agent.fn_claim_reaction abgeschafft)
--   * core.package_registry.status 'installed' (kein Lebenszyklus-Schritt setzt ihn; auch fn_pkg_set_status lehnt ab)
--   * finance.pension_statements.is_nominal, estate.task_templates.retired (Spalten ohne Leser)
--   * finance.fn_interest_accrued_preview, finance.fn_verify_holding_shares (Funktionen ohne Aufrufer)
-- core:V042, finance:V044, estate:V004 (echte Dateien, je zweimal) auf einem nachgebauten Bestands-Stand mit Alt-Zeilen.
BEGIN;

DO $$
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 't', NULL, 'lazy', 'f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20',
                       'telegram_user_id',111,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- Bestands-Fassung: Regeln mit den toten Werten, je eine Alt-Zeile
  ALTER TABLE agent.reaction_log DROP CONSTRAINT reaction_log_kind_valid;
  ALTER TABLE agent.reaction_log DROP CONSTRAINT reaction_log_kind_emoji;
  ALTER TABLE agent.reaction_log ADD CONSTRAINT reaction_log_kind_valid CHECK (kind IN ('seen', 'done', 'mood', 'answer'));
  ALTER TABLE agent.reaction_log ADD CONSTRAINT reaction_log_kind_emoji CHECK (
       (kind = 'seen' AND emoji = '👀') OR (kind = 'done' AND emoji = '👌')
    OR (kind IN ('mood', 'answer') AND emoji IN ('❤', '🎉', '🙏', '😁')));
  INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji) VALUES
    ('erika', 111, 980, 'mood', '🙏'), ('erika', 111, 981, 'answer', '🎉');
  ALTER TABLE core.package_registry DROP CONSTRAINT package_registry_status_check;
  ALTER TABLE core.package_registry ADD CONSTRAINT package_registry_status_check
      CHECK (status IN ('installing', 'installed', 'active', 'inactive'));
  INSERT INTO core.package_registry (package, status) VALUES ('__t_dead__', 'installed');
  ALTER TABLE finance.pension_statements ADD COLUMN is_nominal boolean NOT NULL DEFAULT TRUE;
  ALTER TABLE estate.task_templates ADD COLUMN retired boolean NOT NULL DEFAULT FALSE;
  CREATE VIEW estate.__t_dead_v AS SELECT template_key, retired FROM estate.task_templates;
  CREATE FUNCTION finance.fn_interest_accrued_preview(p_account_id int, p_as_of date) RETURNS numeric LANGUAGE sql AS 'SELECT 0::numeric';
  CREATE FUNCTION finance.fn_verify_holding_shares(p_holding_id int, p_expected numeric) RETURNS boolean LANGUAGE sql AS 'SELECT true';
END $$;

\ir ../../../packages/core/db/migrations/V042__drop_dead_status_values.sql
\ir ../../../packages/core/db/migrations/V042__drop_dead_status_values.sql
\ir ../../../packages/finance/db/migrations/V044__drop_dead_columns_and_fns.sql
\ir ../../../packages/finance/db/migrations/V044__drop_dead_columns_and_fns.sql
\ir ../../../packages/estate/db/migrations/V004__task_templates_drop_retired.sql
\ir ../../../packages/estate/db/migrations/V004__task_templates_drop_retired.sql

DO $$
DECLARE
  r jsonb;
BEGIN
  IF (SELECT string_agg(message_id || '=' || kind, ',' ORDER BY message_id) FROM agent.reaction_log WHERE message_id IN (980, 981))
     IS DISTINCT FROM '981=answer' THEN
    RAISE EXCEPTION 'FAIL dead_values [Alt-Zeilen reaction_log: %]',
      (SELECT jsonb_agg(to_jsonb(x)) FROM agent.reaction_log x WHERE message_id IN (980, 981)); END IF;
  BEGIN
    INSERT INTO agent.reaction_log (person_id, chat_id, message_id, kind, emoji) VALUES ('erika', 111, 990, 'mood', '🙏');
    RAISE EXCEPTION 'FAIL dead_values [reaction_log nimmt kind mood an]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  IF (SELECT status FROM core.package_registry WHERE package = '__t_dead__') IS DISTINCT FROM 'installing' THEN
    RAISE EXCEPTION 'FAIL dead_values [Alt-Zeile installed nicht nach installing gelegt]'; END IF;
  BEGIN
    UPDATE core.package_registry SET status = 'installed' WHERE package = '__t_dead__';
    RAISE EXCEPTION 'FAIL dead_values [package_registry nimmt status installed an]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  r := core.fn_pkg_set_status(jsonb_build_object('package', '__t_dead__', 'status', 'installed'));
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL dead_values [fn_pkg_set_status setzt installed: %]', r; END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'finance' AND table_name = 'pension_statements' AND column_name = 'is_nominal') THEN
    RAISE EXCEPTION 'FAIL dead_values [finance.pension_statements.is_nominal existiert]';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'estate' AND table_name = 'task_templates' AND column_name = 'retired')
     OR to_regclass('estate.__t_dead_v') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL dead_values [estate.task_templates.retired samt abhaengiger View existiert]';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'finance' AND p.proname IN ('fn_interest_accrued_preview', 'fn_verify_holding_shares')) THEN
    RAISE EXCEPTION 'FAIL dead_values [tote finance-Funktion existiert noch]';
  END IF;

  RAISE NOTICE 'PASS dead_values [mood, installed, is_nominal, retired, zwei tote Funktionen; Migrationen zweimal]';
END $$;

ROLLBACK;
