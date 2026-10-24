-- tests/db/core/test_guide_learn_schema.sql
-- Schema-/Constraint-Test fuer den Phase-C Lern-Loop (WS-1; TDD Red ZUERST, KEINE fn noetig):
--   agent.guide_learn_candidates  — Defaults, CHECKs (target_kind/kind/status/fact-shape),
--     Idempotenz-UNIQUE(agent_name,source_id,slot_key), partielles UNIQUE(context_name,slot_key)
--     WHERE status='pending' (nur EIN offener Vorschlag je Slot; rejected/expired bleiben).
--   agent.guide_learn_watermark   — per-Quelltabelle Cursor (PK agent_name, Default last_seen_id=0).
-- Self-seedend, BEGIN..ROLLBACK (kein Residual-State). Tests: tests/CLAUDE.md.
BEGIN;

DO $$
DECLARE
  v_id1    bigint;
  v_id2    bigint;
  v_status text;
  v_pkg    text;
  v_seen   bigint;
BEGIN
  -- ===== guide_learn_candidates: Defaults (status='pending', package='core') =====
  INSERT INTO agent.guide_learn_candidates
    (agent_name, source_id, target_kind, context_name, person_slug, field, proposed_value, kind, slot_key, rationale, expires_at)
  VALUES
    ('finance', 101, 'fact', 'family', 'lisa', 'birth_date', '2024-01-01', 'new',
     'family|lisa|birth_date', 'neues Kind erwaehnt', now() + interval '7 days')
  RETURNING id INTO v_id1;

  SELECT status, package INTO v_status, v_pkg FROM agent.guide_learn_candidates WHERE id = v_id1;
  IF v_status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'FAIL candidates [default status]: erwartet pending, got %', v_status;
  END IF;
  IF v_pkg IS DISTINCT FROM 'core' THEN
    RAISE EXCEPTION 'FAIL candidates [default package]: erwartet core, got %', v_pkg;
  END IF;
  RAISE NOTICE 'PASS candidates [defaults status=pending, package=core]';

  -- ===== CHECK target_kind =====
  BEGIN
    INSERT INTO agent.guide_learn_candidates
      (agent_name, source_id, target_kind, context_name, proposed_value, kind, slot_key, expires_at)
    VALUES ('finance', 102, 'bogus', 'family', 'x', 'new', 'k1', now());
    RAISE EXCEPTION 'FAIL candidates [target_kind CHECK]: ungueltiger target_kind haette abgelehnt werden muessen';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS candidates [target_kind CHECK lehnt bogus ab]';
  END;

  -- ===== CHECK kind =====
  BEGIN
    INSERT INTO agent.guide_learn_candidates
      (agent_name, source_id, target_kind, context_name, person_slug, field, proposed_value, kind, slot_key, expires_at)
    VALUES ('finance', 103, 'fact', 'family', 'p', 'f', 'x', 'sideways', 'k2', now());
    RAISE EXCEPTION 'FAIL candidates [kind CHECK]: ungueltiger kind haette abgelehnt werden muessen';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS candidates [kind CHECK lehnt bogus ab]';
  END;

  -- ===== CHECK status =====
  BEGIN
    INSERT INTO agent.guide_learn_candidates
      (agent_name, source_id, target_kind, context_name, person_slug, field, proposed_value, kind, slot_key, status, expires_at)
    VALUES ('finance', 104, 'fact', 'family', 'p', 'f', 'x', 'new', 'k3', 'weird', now());
    RAISE EXCEPTION 'FAIL candidates [status CHECK]: ungueltiger status haette abgelehnt werden muessen';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS candidates [status CHECK lehnt bogus ab]';
  END;

  -- ===== CHECK fact-shape: fact braucht person_slug + field =====
  BEGIN
    INSERT INTO agent.guide_learn_candidates
      (agent_name, source_id, target_kind, context_name, proposed_value, kind, slot_key, expires_at)
    VALUES ('finance', 105, 'fact', 'family', 'x', 'new', 'k4', now());
    RAISE EXCEPTION 'FAIL candidates [fact_shape CHECK]: fact ohne person_slug/field haette abgelehnt werden muessen';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS candidates [fact_shape CHECK verlangt person_slug+field]';
  END;

  -- ===== note ist ohne person_slug/field erlaubt =====
  INSERT INTO agent.guide_learn_candidates
    (agent_name, source_id, target_kind, context_name, proposed_value, kind, slot_key, rationale, expires_at)
  VALUES ('finance_advisor', 201, 'note', 'financial_planning', 'plant 2027 ein Sabbatical', 'new',
          'financial_planning|sabbatical2027', 'Sabbatical-Plan', now() + interval '7 days')
  RETURNING id INTO v_id2;
  RAISE NOTICE 'PASS candidates [note erlaubt ohne person_slug/field]';

  -- ===== partielles UNIQUE(context_name, slot_key) WHERE pending: nur EIN offener Vorschlag je Slot =====
  -- (v_id1 ist noch pending mit (family, family|lisa|birth_date) -> zweiter pending blockt, andere source)
  BEGIN
    INSERT INTO agent.guide_learn_candidates
      (agent_name, source_id, target_kind, context_name, person_slug, field, proposed_value, kind, slot_key, expires_at)
    VALUES ('guide', 999, 'fact', 'family', 'lisa', 'birth_date', '2024-01-01', 'new',
            'family|lisa|birth_date', now() + interval '7 days');
    RAISE EXCEPTION 'FAIL candidates [pending slot UNIQUE]: zweiter pending mit gleichem (context,slot) haette blockt werden muessen';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS candidates [pending slot UNIQUE blockt 2. offenen Vorschlag]';
  END;

  -- v_id1 ablehnen -> der Teilindex greift nicht mehr fuer diesen Slot
  UPDATE agent.guide_learn_candidates SET status = 'rejected', rejected_at = now() WHERE id = v_id1;

  -- ===== Idempotenz-UNIQUE(agent_name, source_id, slot_key): isoliert (v_id1 jetzt rejected) =====
  BEGIN
    INSERT INTO agent.guide_learn_candidates
      (agent_name, source_id, target_kind, context_name, person_slug, field, proposed_value, kind, slot_key, expires_at)
    VALUES ('finance', 101, 'fact', 'family', 'lisa', 'birth_date', '2024-01-01', 'new',
            'family|lisa|birth_date', now() + interval '7 days');
    RAISE EXCEPTION 'FAIL candidates [idem UNIQUE]: doppelter (agent,source,slot) haette abgelehnt werden muessen';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS candidates [idem UNIQUE lehnt dup (agent,source,slot) ab]';
  END;

  -- ===== nach rejected ist ein neuer pending mit gleichem Slot erlaubt (andere source) =====
  INSERT INTO agent.guide_learn_candidates
    (agent_name, source_id, target_kind, context_name, person_slug, field, proposed_value, kind, slot_key, expires_at)
  VALUES ('guide', 998, 'fact', 'family', 'lisa', 'birth_date', '2024-01-01', 'new',
          'family|lisa|birth_date', now() + interval '7 days');
  RAISE NOTICE 'PASS candidates [neuer pending erlaubt nachdem alter rejected]';

  -- ===== guide_learn_watermark: Default last_seen_id=0 =====
  INSERT INTO agent.guide_learn_watermark (agent_name) VALUES ('finance');
  SELECT last_seen_id INTO v_seen FROM agent.guide_learn_watermark WHERE agent_name = 'finance';
  IF v_seen IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL watermark [default last_seen_id]: erwartet 0, got %', v_seen;
  END IF;
  RAISE NOTICE 'PASS watermark [default last_seen_id=0]';

  -- PK(agent_name) verhindert Doppel-Cursor je Quelltabelle
  BEGIN
    INSERT INTO agent.guide_learn_watermark (agent_name, last_seen_id) VALUES ('finance', 50);
    RAISE EXCEPTION 'FAIL watermark [PK]: doppelter agent_name haette abgelehnt werden muessen';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS watermark [PK blockt dup agent_name]';
  END;

  RAISE NOTICE 'PASS guide_learn_schema [all tests passed]';
END $$;

ROLLBACK;
