-- tests/db/core/test_fn_set_own_context_facts.sql
-- agent.fn_set_own_context_facts(p): Schreibweg der Freigabe-Stufe self (agent.tool_set_own_context_facts).
-- Duenner Delegat auf agent.fn_set_context_facts, der scope='per_user' SELBST setzt (ein Aufrufer-scope wird
-- ueberschrieben) -> nur der eigene per_user-Kontext der aus chat_id aufgeloesten Person ist schreibbar;
-- household/family/Plan-Kontexte strukturell nicht. Self-contained (BEGIN..ROLLBACK).
BEGIN;

DO $$
DECLARE
  v_result JSONB;
BEGIN
  -- ---------- Fixtures: aktives Paket, per_user- + household-Kontext, family Owner(111)/Mitglied(222) ----------
  CREATE OR REPLACE FUNCTION agent.fn_test_own_validator(p jsonb) RETURNS text
    LANGUAGE plpgsql IMMUTABLE AS $f$ BEGIN RETURN NULL; END $f$;
  INSERT INTO core.package_registry (package, status) VALUES ('career', 'active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  INSERT INTO core.context_validators (context_name, validate_fn, package) VALUES
    ('test_own_ctx', 'agent.fn_test_own_validator', 'career'),
    ('test_hh_ctx',  'agent.fn_test_own_validator', 'career')
  ON CONFLICT (context_name) DO UPDATE SET validate_fn = EXCLUDED.validate_fn;
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package) VALUES
    ('test_own_ctx', 'per_user',  'own_user_only', 'career'),
    ('test_hh_ctx',  'household', 'adults_only',   'career')
  ON CONFLICT (context_name) DO UPDATE SET scope = EXCLUDED.scope, write_permission = EXCLUDED.write_permission;
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata, package)
  VALUES ('test_hh_ctx', 'hh fixture', NULL, 'lazy', E'## hh', jsonb_build_object('facts', '{}'::jsonb), 'career')
  ON CONFLICT (name) DO NOTHING;
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                               'birth_date','1980-05-20','telegram_user_id',111),
            jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner',
                               'birth_date','1985-06-21','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- 1) Mitglied schreibt seinen eigenen per_user-Kontext -> ok, Zeile __lena
  v_result := agent.fn_set_own_context_facts(jsonb_build_object(
    'context_name','test_own_ctx','chat_id','222','facts', jsonb_build_object('current_title','Lena PM')));
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true
     OR NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='test_own_ctx__lena'
                    AND metadata->'facts'->>'current_title'='Lena PM') THEN
    RAISE EXCEPTION 'FAIL [1] eigener per_user-Kontext: got %', v_result;
  END IF;

  -- 2) household-Kontext (adults_only -> Partnerin duerfte ihn household-seitig schreiben) -> ueber diesen Weg NIE
  v_result := agent.fn_set_own_context_facts(jsonb_build_object(
    'context_name','test_hh_ctx','chat_id','222','facts', jsonb_build_object('x','y')));
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false
     OR (SELECT metadata->'facts' FROM agent.core_contexts WHERE name='test_hh_ctx') ? 'x' THEN
    RAISE EXCEPTION 'FAIL [2] household-Kontext ueber self-Weg: erwartet ok=false ohne Write, got %', v_result;
  END IF;

  -- 3) ein Aufrufer-scope 'household' wird ignoriert (die fn setzt per_user selbst)
  v_result := agent.fn_set_own_context_facts(jsonb_build_object(
    'context_name','test_hh_ctx','chat_id','222','scope','household','facts', jsonb_build_object('x','y')));
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [3] Aufrufer-scope household darf den self-Weg nicht oeffnen, got %', v_result;
  END IF;

  -- 4) family -> owner_only
  v_result := agent.fn_set_own_context_facts(jsonb_build_object(
    'context_name','family','chat_id','222','facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','lena','role','owner')))));
  IF v_result->>'reason' IS DISTINCT FROM 'owner_only' THEN
    RAISE EXCEPTION 'FAIL [4] family ueber self-Weg: erwartet owner_only, got %', v_result;
  END IF;

  RAISE NOTICE 'PASS test_fn_set_own_context_facts (eigener per_user ok; household/scope-Override/family abgelehnt)';
END $$;

ROLLBACK;
