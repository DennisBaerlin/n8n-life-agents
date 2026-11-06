-- tests/db/core/test_fn_approve_learn_candidate.sql
-- agent.fn_approve_learn_candidate(p {candidate_id, chat_id}) — owner-gegateter EINZIGE core_contexts-
--   Schreibpfad des Lern-Loops (Phase C, WS-3): dispatcht nach target_kind: fact -> fn_set_context_facts
--   (metadata.facts-Merge), note -> core.fn_append_context_note (Prosa). Markiert den Kandidaten approved
--   NUR bei erfolgreichem Write. owner_only-Backstop (fn_sender_is_member). Self-seedend, BEGIN..ROLLBACK.
BEGIN;

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
VALUES ('family', 'fixture', NULL, 'lazy', E'## fam', 'agent', 'core',
        jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
          jsonb_build_object('person_id','powner','first_name','O','last_name','P','role','owner','birth_date','1980-01-01','telegram_user_id',111),
          jsonb_build_object('person_id','pmem','first_name','M','last_name','P','role','partner','birth_date','1982-02-02','telegram_user_id',222)))))
ON CONFLICT (name) DO UPDATE SET content=excluded.content, managed_by=excluded.managed_by, metadata=excluded.metadata;

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
VALUES ('financial_planning', 'fixture', 'finance_advisor', 'lazy', E'# Plan\n', 'agent', 'finance', '{}'::jsonb)
ON CONFLICT (name) DO UPDATE SET content=excluded.content, managed_by=excluded.managed_by, metadata=excluded.metadata;
-- Phase A: Notiz-Freigabe registry-getrieben (core.advisors.learn_notes + aktives Paket statt Literal-Liste).
INSERT INTO core.package_registry (package, status) VALUES ('finance', 'active')
ON CONFLICT (package) DO UPDATE SET status = 'active';
INSERT INTO core.advisors (domain, plan_context, review_fn, package, learn_notes)
VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'finance', TRUE)
ON CONFLICT (domain) DO UPDATE SET plan_context = excluded.plan_context, learn_notes = TRUE;

DO $$
DECLARE
  v_fact_id bigint;
  v_note_id bigint;
  v_om_id   bigint;
  r         jsonb;
  v_lang    text;
  v_cont    text;
  v_status  text;
BEGIN
  -- ===== 1. fact-Kandidat approven -> dispatch fn_set_context_facts =====
  INSERT INTO agent.guide_learn_candidates (agent_name, source_id, target_kind, context_name, person_slug, field, proposed_value, kind, slot_key, expires_at)
  VALUES ('finance', 10, 'fact', 'family', 'powner', 'language', 'en', 'new', 'family|powner|language', now() + interval '7 days')
  RETURNING id INTO v_fact_id;
  r := agent.fn_approve_learn_candidate(jsonb_build_object('candidate_id', v_fact_id, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL 1 [ok]: %', r; END IF;
  SELECT pp->>'language' INTO v_lang
  FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
  WHERE c.name='family' AND pp->>'person_id'='powner';
  IF v_lang IS DISTINCT FROM 'en' THEN RAISE EXCEPTION 'FAIL 1 [facts nicht gemergt]: language=%', v_lang; END IF;
  SELECT status INTO v_status FROM agent.guide_learn_candidates WHERE id=v_fact_id;
  IF v_status IS DISTINCT FROM 'approved' THEN RAISE EXCEPTION 'FAIL 1 [Kandidat nicht approved]: %', v_status; END IF;
  RAISE NOTICE 'PASS 1 [fact -> fn_set_context_facts + approved]';

  -- ===== 2. note-Kandidat approven -> dispatch fn_append_context_note =====
  INSERT INTO agent.guide_learn_candidates (agent_name, source_id, target_kind, context_name, proposed_value, kind, slot_key, expires_at)
  VALUES ('finance_advisor', 20, 'note', 'financial_planning', 'plant 2027 ein Sabbatical', 'new', 'financial_planning|abc', now() + interval '7 days')
  RETURNING id INTO v_note_id;
  r := agent.fn_approve_learn_candidate(jsonb_build_object('candidate_id', v_note_id, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL 2 [ok]: %', r; END IF;
  SELECT content INTO v_cont FROM agent.core_contexts WHERE name='financial_planning';
  IF position('## Gelernt' IN v_cont) = 0 OR position('plant 2027 ein Sabbatical' IN v_cont) = 0 OR position('aus Chat' IN v_cont) = 0 THEN
    RAISE EXCEPTION 'FAIL 2 [Notiz nicht angehaengt]: %', v_cont; END IF;
  SELECT status INTO v_status FROM agent.guide_learn_candidates WHERE id=v_note_id;
  IF v_status IS DISTINCT FROM 'approved' THEN RAISE EXCEPTION 'FAIL 2 [Kandidat nicht approved]: %', v_status; END IF;
  RAISE NOTICE 'PASS 2 [note -> fn_append_context_note + approved]';

  -- ===== 3. owner_only: Mitglied (tg=222) -> {ok:false}, Kandidat bleibt pending =====
  INSERT INTO agent.guide_learn_candidates (agent_name, source_id, target_kind, context_name, person_slug, field, proposed_value, kind, slot_key, expires_at)
  VALUES ('finance', 30, 'fact', 'family', 'powner', 'tax_residency', 'DE', 'new', 'family|powner|tax_residency', now() + interval '7 days')
  RETURNING id INTO v_om_id;
  r := agent.fn_approve_learn_candidate(jsonb_build_object('candidate_id', v_om_id, 'chat_id', '222'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' <> 'owner_only' THEN RAISE EXCEPTION 'FAIL 3 [Mitglied nicht owner_only]: %', r; END IF;
  SELECT status INTO v_status FROM agent.guide_learn_candidates WHERE id=v_om_id;
  IF v_status IS DISTINCT FROM 'pending' THEN RAISE EXCEPTION 'FAIL 3 [Kandidat nicht mehr pending]: %', v_status; END IF;
  RAISE NOTICE 'PASS 3 [owner_only: Mitglied verweigert, Kandidat pending]';

  -- ===== 4. nicht existierender Kandidat -> {ok:false} =====
  r := agent.fn_approve_learn_candidate(jsonb_build_object('candidate_id', 999999, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL 4 [Nicht-existent nicht abgewiesen]: %', r; END IF;
  RAISE NOTICE 'PASS 4 [nicht existierender Kandidat -> ok:false]';

  -- ===== 5. bereits approved -> {ok:false} (kein Doppel-Write) =====
  r := agent.fn_approve_learn_candidate(jsonb_build_object('candidate_id', v_fact_id, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL 5 [bereits-approved nicht abgewiesen]: %', r; END IF;
  RAISE NOTICE 'PASS 5 [bereits approved -> ok:false]';

  RAISE NOTICE 'PASS fn_approve_learn_candidate [all tests passed]';
END $$;

ROLLBACK;
