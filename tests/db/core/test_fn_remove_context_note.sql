-- tests/db/core/test_fn_remove_context_note.sql
-- core.fn_remove_context_note(p {candidate_id, chat_id}) — Entfern-/Undo-Pfad (Phase C, WS-3, R5-C):
--   entfernt die zu einem approved note-Kandidaten gehoerende "## Gelernt"-Zeile (allowlist-geguardet)
--   UND setzt den Kandidaten auf 'rejected' (HITL-Reversibilitaet learn:undo). owner_only-Backstop.
-- Self-seedend, BEGIN..ROLLBACK. Testet den vollen Zyklus approve(note) -> remove(undo).
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
  v_id     bigint;
  v_id2    bigint;
  r        jsonb;
  v_cont   text;
  v_status text;
BEGIN
  -- Vorbereiten: zwei note-Kandidaten approven (zwei Zeilen unter ## Gelernt)
  INSERT INTO agent.guide_learn_candidates (agent_name, source_id, target_kind, context_name, proposed_value, kind, slot_key, expires_at)
  VALUES ('finance_advisor', 50, 'note', 'financial_planning', 'plant 2027 ein Sabbatical', 'new', 'financial_planning|s1', now() + interval '7 days')
  RETURNING id INTO v_id;
  INSERT INTO agent.guide_learn_candidates (agent_name, source_id, target_kind, context_name, proposed_value, kind, slot_key, expires_at)
  VALUES ('finance_advisor', 51, 'note', 'financial_planning', 'interessiert sich fuer nachhaltige ETFs', 'new', 'financial_planning|s2', now() + interval '7 days')
  RETURNING id INTO v_id2;
  PERFORM agent.fn_approve_learn_candidate(jsonb_build_object('candidate_id', v_id,  'chat_id', '111'));
  PERFORM agent.fn_approve_learn_candidate(jsonb_build_object('candidate_id', v_id2, 'chat_id', '111'));

  -- ===== 1. owner_only: Mitglied (tg=222) -> {ok:false}, nichts entfernt =====
  r := core.fn_remove_context_note(jsonb_build_object('candidate_id', v_id, 'chat_id', '222'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' <> 'owner_only' THEN RAISE EXCEPTION 'FAIL 1 [Mitglied nicht owner_only]: %', r; END IF;
  SELECT content INTO v_cont FROM agent.core_contexts WHERE name='financial_planning';
  IF position('Sabbatical' IN v_cont) = 0 THEN RAISE EXCEPTION 'FAIL 1 [Mitglied hat trotzdem entfernt]'; END IF;
  RAISE NOTICE 'PASS 1 [owner_only: Mitglied verweigert]';

  -- ===== 2. Undo: entfernt NUR die getroffene Zeile + Kandidat -> rejected =====
  r := core.fn_remove_context_note(jsonb_build_object('candidate_id', v_id, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL 2 [ok]: %', r; END IF;
  SELECT content INTO v_cont FROM agent.core_contexts WHERE name='financial_planning';
  IF position('Sabbatical' IN v_cont) > 0 THEN RAISE EXCEPTION 'FAIL 2 [getroffene Zeile nicht entfernt]: %', v_cont; END IF;
  IF position('nachhaltige ETFs' IN v_cont) = 0 THEN RAISE EXCEPTION 'FAIL 2 [die ANDERE Notiz faelschlich entfernt]: %', v_cont; END IF;
  SELECT status INTO v_status FROM agent.guide_learn_candidates WHERE id=v_id;
  IF v_status IS DISTINCT FROM 'rejected' THEN RAISE EXCEPTION 'FAIL 2 [Kandidat nicht rejected]: %', v_status; END IF;
  RAISE NOTICE 'PASS 2 [Undo entfernt genau die Zeile + Kandidat rejected]';

  -- ===== 3. nicht-approved Kandidat (pending) -> {ok:false} (nur approved Notizen sind undobar) =====
  INSERT INTO agent.guide_learn_candidates (agent_name, source_id, target_kind, context_name, proposed_value, kind, slot_key, status, expires_at)
  VALUES ('finance_advisor', 52, 'note', 'financial_planning', 'noch nicht gespeichert', 'new', 'financial_planning|s3', 'pending', now() + interval '7 days')
  RETURNING id INTO v_id;
  r := core.fn_remove_context_note(jsonb_build_object('candidate_id', v_id, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL 3 [pending-Kandidat nicht abgewiesen]: %', r; END IF;
  RAISE NOTICE 'PASS 3 [nur approved note undobar]';

  -- ===== 4. nicht existierender Kandidat -> {ok:false} =====
  r := core.fn_remove_context_note(jsonb_build_object('candidate_id', 999999, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL 4 [Nicht-existent nicht abgewiesen]: %', r; END IF;
  RAISE NOTICE 'PASS 4 [nicht existierender Kandidat -> ok:false]';

  RAISE NOTICE 'PASS fn_remove_context_note [all tests passed]';
END $$;

ROLLBACK;
