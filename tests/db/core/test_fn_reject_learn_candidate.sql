-- tests/db/core/test_fn_reject_learn_candidate.sql
-- agent.fn_reject_learn_candidate(p {candidate_id, chat_id}) — owner-gegatet (Phase C, WS-3): setzt einen
--   pending-Kandidaten auf 'rejected' (DURABLE Rejection-Memory: bleibt liegen, NICHT vom TTL-Cleanup
--   geraeumt -> der Lern-Loop schlaegt denselben Slot < expiry_days nicht erneut vor). owner_only-Backstop.
-- Self-seedend, BEGIN..ROLLBACK.
BEGIN;

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
VALUES ('family', 'fixture', NULL, 'lazy', E'## fam', 'agent', 'core',
        jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
          jsonb_build_object('person_id','powner','first_name','O','last_name','P','role','owner','birth_date','1980-01-01','telegram_user_id',111),
          jsonb_build_object('person_id','pmem','first_name','M','last_name','P','role','partner','birth_date','1982-02-02','telegram_user_id',222)))))
ON CONFLICT (name) DO UPDATE SET content=excluded.content, managed_by=excluded.managed_by, metadata=excluded.metadata;

DO $$
DECLARE
  v_id     bigint;
  r        jsonb;
  v_status text;
  v_rej    timestamptz;
BEGIN
  -- ===== 1. pending -> rejected (+ rejected_at gesetzt) =====
  INSERT INTO agent.guide_learn_candidates (agent_name, source_id, target_kind, context_name, person_slug, field, proposed_value, kind, slot_key, expires_at)
  VALUES ('finance', 40, 'fact', 'family', 'powner', 'language', 'fr', 'new', 'family|powner|language', now() + interval '7 days')
  RETURNING id INTO v_id;
  r := agent.fn_reject_learn_candidate(jsonb_build_object('candidate_id', v_id, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL 1 [ok]: %', r; END IF;
  SELECT status, rejected_at INTO v_status, v_rej FROM agent.guide_learn_candidates WHERE id=v_id;
  IF v_status IS DISTINCT FROM 'rejected' OR v_rej IS NULL THEN RAISE EXCEPTION 'FAIL 1 [nicht rejected/rejected_at]: %, %', v_status, v_rej; END IF;
  RAISE NOTICE 'PASS 1 [pending -> rejected + rejected_at]';

  -- ===== 2. bereits rejected -> {ok:false} (kein Re-Reject) =====
  r := agent.fn_reject_learn_candidate(jsonb_build_object('candidate_id', v_id, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL 2 [bereits-rejected nicht abgewiesen]: %', r; END IF;
  RAISE NOTICE 'PASS 2 [bereits rejected -> ok:false]';

  -- ===== 3. owner_only: Mitglied (tg=222) -> {ok:false}, Kandidat bleibt pending =====
  INSERT INTO agent.guide_learn_candidates (agent_name, source_id, target_kind, context_name, person_slug, field, proposed_value, kind, slot_key, expires_at)
  VALUES ('finance', 41, 'fact', 'family', 'powner', 'citizenship', 'DE', 'new', 'family|powner|citizenship', now() + interval '7 days')
  RETURNING id INTO v_id;
  r := agent.fn_reject_learn_candidate(jsonb_build_object('candidate_id', v_id, 'chat_id', '222'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' <> 'owner_only' THEN RAISE EXCEPTION 'FAIL 3 [Mitglied nicht owner_only]: %', r; END IF;
  SELECT status INTO v_status FROM agent.guide_learn_candidates WHERE id=v_id;
  IF v_status IS DISTINCT FROM 'pending' THEN RAISE EXCEPTION 'FAIL 3 [Kandidat nicht mehr pending]: %', v_status; END IF;
  RAISE NOTICE 'PASS 3 [owner_only: Mitglied verweigert]';

  -- ===== 4. nicht existierender Kandidat -> {ok:false} =====
  r := agent.fn_reject_learn_candidate(jsonb_build_object('candidate_id', 999999, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL 4 [Nicht-existent nicht abgewiesen]: %', r; END IF;
  RAISE NOTICE 'PASS 4 [nicht existierender Kandidat -> ok:false]';

  RAISE NOTICE 'PASS fn_reject_learn_candidate [all tests passed]';
END $$;

ROLLBACK;
