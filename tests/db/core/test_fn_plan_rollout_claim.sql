-- tests/db/core/test_fn_plan_rollout_claim.sql
-- core.fn_plan_rollout_claim: Sperren vor dem Schritt (Chat-Form, Schalter, Karte, Entwurf), Zeitbudget; lagging; Handoff-Mark.
BEGIN;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'x', NULL, 'lazy', 'f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
  jsonb_build_object('person_id', 'erika', 'first_name', 'Erika', 'last_name', 'M', 'role', 'owner', 'birth_date', '1980-05-20', 'telegram_user_id', 111, 'language', 'de'),
  jsonb_build_object('person_id', 'lena', 'first_name', 'Lena', 'last_name', 'B', 'role', 'partner', 'birth_date', '1985-06-21', 'telegram_user_id', 222)))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;
INSERT INTO core.advisors (domain, package, plan_context, review_fn, plan_step) VALUES ('__rollc__', 'core', '__rollc___planning', 'core.fn_x', TRUE);
INSERT INTO core.config (package, category, key, value) VALUES ('core', 'advisor', 'plan_sync_required', 'true'), ('core', 'cron_enable', 'plan_rollout', 'true')
ON CONFLICT (category, key) DO UPDATE SET package = excluded.package, value = excluded.value;
INSERT INTO core.cron_labels (cron_key, package, scope, default_enabled) VALUES ('plan_rollout', 'core', 'household', TRUE)
ON CONFLICT (cron_key) DO UPDATE SET package = excluded.package;

INSERT INTO core.package_registry (package, version, status) VALUES ('core', '0.1.0', 'active') ON CONFLICT (package) DO UPDATE SET status = 'active';

DO $$
DECLARE
  v JSONB;
  v_t0 TIMESTAMPTZ;
BEGIN
  -- Bestandsplaene anderer Tests stoeren nicht: nur diese Domain ist aktiv
  UPDATE agent.advisor_plans SET status = 'superseded' WHERE status = 'active';
  DELETE FROM agent.advisor_plans WHERE status = 'draft';
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version) VALUES ('__rollc__', 'p', 'active', 1);

  v := core.fn_plan_rollout_claim('{"chat_id":"abc"}');
  IF jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL nicht numerisch %', v; END IF;
  v := core.fn_plan_rollout_claim('{"chat_id":"222"}');
  IF jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL Mitglied %', v; END IF;

  UPDATE core.config SET value = 'false' WHERE category = 'cron_enable' AND key = 'plan_rollout';
  v := core.fn_plan_rollout_claim('{"chat_id":"111"}');
  IF jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL Schalter %', v; END IF;
  UPDATE core.config SET value = 'true' WHERE category = 'cron_enable' AND key = 'plan_rollout';

  INSERT INTO agent.hitl_pending (chat_id, execution_id, expires_at) VALUES (111, 'e1', now() + interval '5 minutes');
  v := core.fn_plan_rollout_claim('{"chat_id":"111"}');
  IF jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL Karte offen %', v; END IF;
  UPDATE agent.hitl_pending SET released_at = now() WHERE execution_id = 'e1';

  INSERT INTO agent.advisor_plans (domain, plan_name, status, version) VALUES ('__andere__', 'q', 'draft', 1);
  v := core.fn_plan_rollout_claim('{"chat_id":"111"}');
  IF jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL Entwurf %', v; END IF;
  DELETE FROM agent.advisor_plans WHERE domain = '__andere__';

  -- Nachzuegler ohne Platz: nichts, Merker frei (der Normalfall darunter meldet noch); ohne budget-Flag gilt kein Budget
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred;
  PERFORM core.fn_proactive_claim('erika', 'x1', 'normal'); PERFORM core.fn_proactive_claim('erika', 'x2', 'normal');
  v := core.fn_plan_rollout_claim('{"chat_id":"111","budget":"true"}');
  IF jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL Budget voll %', v; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.proactive_deferred WHERE person_id = 'erika' AND slot = 'plan_rollout') THEN RAISE EXCEPTION 'FAIL Budget Altern'; END IF;

  v_t0 := clock_timestamp();
  v := core.fn_plan_rollout_claim('{"chat_id":"111"}');
  IF clock_timestamp() - v_t0 > interval '200 milliseconds' THEN RAISE EXCEPTION 'FAIL Zeitbudget'; END IF;
  IF jsonb_array_length(v->'messages') <> 1 OR v->'messages'->0->>'chat_id' <> '111' OR v->>'domain' <> '__rollc__' THEN RAISE EXCEPTION 'FAIL Normalfall %', v; END IF;

  -- lagging nennt den Owner-Chat, ohne aktiven Plan nicht
  v := core.fn_plan_rollout_lagging();
  IF NOT (v->'chats') @> '[111]'::jsonb THEN RAISE EXCEPTION 'FAIL lagging %', v; END IF;
  UPDATE agent.advisor_plans SET status = 'superseded' WHERE domain = '__rollc__';
  v := core.fn_plan_rollout_lagging();
  IF (v->'chats') @> '[111]'::jsonb THEN RAISE EXCEPTION 'FAIL lagging ohne Plan %', v; END IF;
END $$;
ROLLBACK;
