-- tests/db/core/test_fn_handle_watch_cb.sql
-- core.fn_handle_watch_cb: aktuelle Version schaltet beide Waechter ein, alter Knopf bekommt den Stale-Toast, Mitglied nicht.
BEGIN;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'x', NULL, 'lazy', 'f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
  jsonb_build_object('person_id', 'erika', 'first_name', 'Erika', 'last_name', 'M', 'role', 'owner', 'birth_date', '1980-05-20', 'telegram_user_id', 111, 'language', 'de'),
  jsonb_build_object('person_id', 'lena', 'first_name', 'Lena', 'last_name', 'B', 'role', 'partner', 'birth_date', '1985-06-21', 'telegram_user_id', 222)))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;
INSERT INTO core.advisors (domain, package, plan_context, review_fn, plan_step) VALUES ('__w__', 'core', 'fn_w_planning', 'core.fn_x', TRUE);
INSERT INTO core.config (package, category, key, value) VALUES ('core', 'cron_enable', 'drift_check', 'false'), ('core', 'cron_enable', 'plan_review', 'false')
ON CONFLICT (category, key) DO UPDATE SET package = excluded.package, value = 'false';
INSERT INTO core.cron_labels (cron_key, package, scope, default_enabled) VALUES ('drift_check', 'core', 'household', FALSE), ('plan_review', 'core', 'household', FALSE)
ON CONFLICT (cron_key) DO NOTHING;
INSERT INTO agent.advisor_plans (domain, plan_name, status, version) VALUES ('__w__', 'p', 'active', 3);
INSERT INTO core.package_registry (package, version, status) VALUES ('core', '0.1.0', 'active') ON CONFLICT (package) DO UPDATE SET status = 'active';

DO $$
DECLARE v JSONB;
BEGIN
  v := core.fn_handle_watch_cb('{"data":"watch:on:__w__:2","chat_id":"111"}');
  IF (v->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL Stale %', v; END IF;
  IF (SELECT value FROM core.config WHERE category = 'cron_enable' AND key = 'drift_check') <> 'false' THEN RAISE EXCEPTION 'FAIL alter Knopf schaltete'; END IF;
  v := core.fn_handle_watch_cb('{"data":"watch:on:__w__:3","chat_id":"222"}');
  IF (v->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL Mitglied %', v; END IF;
  v := core.fn_handle_watch_cb('{"data":"watch:on:__w__:3","chat_id":"111"}');
  IF (v->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL ok %', v; END IF;
  IF (SELECT count(*) FROM core.config WHERE category = 'cron_enable' AND key IN ('drift_check', 'plan_review') AND value = 'true') <> 2 THEN RAISE EXCEPTION 'FAIL beide an'; END IF;
END $$;
ROLLBACK;
