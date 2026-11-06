-- tests/db/core/test_fn_append_context_note.sql
-- core.fn_append_context_note(p {context_name, note, chat_id}) — Prosa-Lern-Schreibpfad (Phase C, WS-3):
--   append-only unter "## Gelernt" mit Provenienz "gelernt am <DATE> aus Chat" (R5-B). HARTER
--   Allowlist-Guard core.fn_note_context_allowed (managed_by='agent' + kuratierte Liste) — der protect-
--   Trigger blockt nur DELETE, NICHT content-UPDATE, also ist DIESER Guard die Sicherung gegen
--   Verhaltens-Korruption von Instruktions-/Seed-Kontexten (R5-A). owner_only-Backstop (fn_sender_is_member).
-- Self-seedend, BEGIN..ROLLBACK.
BEGIN;

-- family (Sender-Aufloesung: owner tg=111, member tg=222) + Ziel-/Negativ-Kontexte
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
VALUES ('family', 'fixture', NULL, 'lazy', E'## fam', 'agent', 'core',
        jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
          jsonb_build_object('person_id','powner','first_name','O','last_name','P','role','owner','birth_date','1980-01-01','telegram_user_id',111),
          jsonb_build_object('person_id','pmem','first_name','M','last_name','P','role','partner','birth_date','1982-02-02','telegram_user_id',222)))))
ON CONFLICT (name) DO UPDATE SET content=excluded.content, managed_by=excluded.managed_by, metadata=excluded.metadata;

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
VALUES ('financial_planning', 'fixture', 'finance_advisor', 'lazy', E'# Finanzplan\n\nProsa-Body.\n', 'agent', 'finance', '{}'::jsonb)
ON CONFLICT (name) DO UPDATE SET content=excluded.content, managed_by=excluded.managed_by, metadata=excluded.metadata;
-- Phase A: Notiz-Freigabe registry-getrieben (core.advisors.learn_notes + aktives Paket statt Literal-Liste).
INSERT INTO core.package_registry (package, status) VALUES ('finance', 'active')
ON CONFLICT (package) DO UPDATE SET status = 'active';
INSERT INTO core.advisors (domain, plan_context, review_fn, package, learn_notes)
VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'finance', TRUE)
ON CONFLICT (domain) DO UPDATE SET plan_context = excluded.plan_context, learn_notes = TRUE;
-- finance_profile (managed_by=agent, aber NICHT in der Knowledge-Allowlist) + ein seed-Kontext
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
VALUES ('finance_profile', 'fixture', NULL, 'lazy', E'## fp', 'agent', 'finance', '{}'::jsonb),
       ('finance_agent_instructions', 'fixture', 'finance', 'static', E'rules', 'seed', 'finance', '{}'::jsonb)
ON CONFLICT (name) DO UPDATE SET content=excluded.content, managed_by=excluded.managed_by, metadata=excluded.metadata;

DO $$
DECLARE
  r       jsonb;
  v_today text := to_char(CURRENT_DATE, 'YYYY-MM-DD');
  v_cont  text;
BEGIN
  -- ===== 1. Append in financial_planning (neue ## Gelernt-Sektion + Provenienz) =====
  r := core.fn_append_context_note(jsonb_build_object('context_name','financial_planning','note','plant 2027 ein Sabbatical','chat_id','111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL 1 [ok]: %', r; END IF;
  SELECT content INTO v_cont FROM agent.core_contexts WHERE name='financial_planning';
  IF position('## Gelernt' IN v_cont) = 0 THEN RAISE EXCEPTION 'FAIL 1 [## Gelernt fehlt]: %', v_cont; END IF;
  IF position('plant 2027 ein Sabbatical' IN v_cont) = 0 THEN RAISE EXCEPTION 'FAIL 1 [Notiz fehlt]'; END IF;
  IF position('gelernt am ' || v_today || ' aus Chat' IN v_cont) = 0 THEN RAISE EXCEPTION 'FAIL 1 [Provenienz fehlt]: %', v_cont; END IF;
  RAISE NOTICE 'PASS 1 [append + ## Gelernt + Provenienz-Stempel]';

  -- ===== 2. Zweite Notiz -> append-only (beide da) =====
  r := core.fn_append_context_note(jsonb_build_object('context_name','financial_planning','note','interessiert sich fuer nachhaltige ETFs','chat_id','111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL 2 [ok]: %', r; END IF;
  SELECT content INTO v_cont FROM agent.core_contexts WHERE name='financial_planning';
  IF position('plant 2027 ein Sabbatical' IN v_cont) = 0 OR position('nachhaltige ETFs' IN v_cont) = 0 THEN
    RAISE EXCEPTION 'FAIL 2 [append-only verliert eine Notiz]: %', v_cont; END IF;
  RAISE NOTICE 'PASS 2 [append-only: beide Notizen erhalten]';

  -- ===== 3. Allowlist-Verweigerung: finance_profile (managed_by=agent, aber nicht Knowledge) =====
  r := core.fn_append_context_note(jsonb_build_object('context_name','finance_profile','note','x','chat_id','111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL 3 [finance_profile nicht verweigert]: %', r; END IF;
  SELECT content INTO v_cont FROM agent.core_contexts WHERE name='finance_profile';
  IF position('## Gelernt' IN v_cont) > 0 THEN RAISE EXCEPTION 'FAIL 3 [finance_profile trotzdem geschrieben]'; END IF;
  RAISE NOTICE 'PASS 3 [Allowlist verweigert finance_profile, kein Write]';

  -- ===== 4. Allowlist-Verweigerung: seed-Kontext (Instruktion) =====
  r := core.fn_append_context_note(jsonb_build_object('context_name','finance_agent_instructions','note','x','chat_id','111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL 4 [seed-Kontext nicht verweigert]: %', r; END IF;
  SELECT content INTO v_cont FROM agent.core_contexts WHERE name='finance_agent_instructions';
  IF position('Gelernt' IN v_cont) > 0 THEN RAISE EXCEPTION 'FAIL 4 [seed-Kontext korrumpiert]'; END IF;
  RAISE NOTICE 'PASS 4 [Allowlist verweigert seed/Instruktions-Kontext]';

  -- ===== 5. Nicht existierender Kontext -> verweigert =====
  r := core.fn_append_context_note(jsonb_build_object('context_name','does_not_exist','note','x','chat_id','111'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL 5 [nicht-existenter Kontext nicht verweigert]: %', r; END IF;
  RAISE NOTICE 'PASS 5 [nicht existierender Kontext verweigert]';

  -- ===== 6. owner_only: Mitglied (tg=222) -> verweigert, kein Write =====
  r := core.fn_append_context_note(jsonb_build_object('context_name','financial_planning','note','Mitglied-Versuch','chat_id','222'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' <> 'owner_only' THEN RAISE EXCEPTION 'FAIL 6 [Mitglied nicht als owner_only verweigert]: %', r; END IF;
  SELECT content INTO v_cont FROM agent.core_contexts WHERE name='financial_planning';
  IF position('Mitglied-Versuch' IN v_cont) > 0 THEN RAISE EXCEPTION 'FAIL 6 [Mitglied-Write durchgekommen]'; END IF;
  RAISE NOTICE 'PASS 6 [owner_only: Mitglied verweigert]';

  RAISE NOTICE 'PASS fn_append_context_note [all tests passed]';
END $$;

ROLLBACK;
