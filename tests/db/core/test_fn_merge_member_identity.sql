-- tests/db/core/test_fn_merge_member_identity.sql
-- WS-5a: der geteilte Identitaets-Merge-Kern (fn_merge_member_identity), den fn_consume (Owner-Bootstrap)
-- und fn_confirm_pairing (Member-Einladung) beide rufen. Prueft:
--   * Erfolg: telegram_user_id+role in eine UNVERKNUEPFTE Person mergen; as_of der Person BEWAHRT (kein
--             Staleness-Sprung) -> fn_resolve_sender findet sie danach
--   * Doppel-Bind-Backstop (B1): Zielperson schon mit ANDERER uid gepairt -> {ok:false, already paired}
--   * Idempotenz: Zielperson schon mit DERSELBEN uid -> {ok:true, already:true}, KEIN Re-Write
--   * Person fehlt -> RAISE (system-aufgeloeste person_id -> Aufrufer rollt zurueck)
-- Fixture in der Transaktion (BEGIN...ROLLBACK -> kein Residual-State).
BEGIN;

DO $$
DECLARE
  r JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('finance_profile', 'merge test fixture', 'finance_advisor', 'lazy', E'## fp',
          jsonb_build_object('managed_by','agent','protected', true, 'facts', jsonb_build_object()))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content, metadata = EXCLUDED.metadata;

  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'merge test fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','protected', true,
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','powner','first_name','Owner','last_name','Person',
                                 'role','owner','birth_date','1980-01-01','as_of','2026-06-11'),
              jsonb_build_object('person_id','ppartner','first_name','Partner','last_name','Person',
                                 'role','partner','birth_date','1985-02-02','as_of','2026-06-11'),
              jsonb_build_object('person_id','pchild','first_name','Kind','last_name','Person',
                                 'role','child','birth_date','2015-03-03','telegram_user_id',222,'as_of','2026-06-11')
            ))))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content, metadata = EXCLUDED.metadata;

  -- ---------- Erfolg: unverknuepfte Person binden, as_of bewahrt ----------
  r := agent.fn_merge_member_identity('ppartner', 555, 'partner');
  IF NOT (r->>'ok')::boolean OR (r ? 'already') THEN
    RAISE EXCEPTION 'FAIL merge [unverknuepfte Person nicht gebunden: %]', r; END IF;
  IF (agent.fn_resolve_sender(555)->>'person_id') IS DISTINCT FROM 'ppartner' THEN
    RAISE EXCEPTION 'FAIL merge [telegram_user_id nicht in family gemerged]'; END IF;
  IF (SELECT pp->>'as_of' FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
       WHERE c.name='family' AND pp->>'person_id'='ppartner') IS DISTINCT FROM '2026-06-11' THEN
    RAISE EXCEPTION 'FAIL merge [Skelett-as_of ueberschrieben (Staleness-Stempel)]'; END IF;
  RAISE NOTICE 'PASS merge [Erfolg + as_of-Erhaltung]';

  -- ---------- Idempotenz: dieselbe uid erneut -> no-op {ok:true, already:true} ----------
  r := agent.fn_merge_member_identity('pchild', 222, 'child');
  IF NOT (r->>'ok')::boolean OR (r->>'already')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL merge [Replay derselben uid nicht als idempotenter no-op: %]', r; END IF;
  RAISE NOTICE 'PASS merge [Idempotenz: dieselbe uid = already:true]';

  -- ---------- Doppel-Bind-Backstop: andere uid an schon gepairte Person -> {ok:false} ----------
  r := agent.fn_merge_member_identity('pchild', 999, 'child');
  IF (r->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL merge [Doppel-Bind: andere uid an gepairte Person akzeptiert: %]', r; END IF;
  -- die alte Bindung bleibt unveraendert (222), nicht 999
  IF (agent.fn_resolve_sender(222)->>'person_id') IS DISTINCT FROM 'pchild'
     OR (agent.fn_resolve_sender(999)->>'found')::boolean THEN
    RAISE EXCEPTION 'FAIL merge [Doppel-Bind hat die Bindung doch veraendert]'; END IF;
  RAISE NOTICE 'PASS merge [Doppel-Bind-Backstop: gepairte Person nicht ueberschreibbar]';

  -- ---------- Person fehlt -> RAISE (Aufrufer rollt zurueck) ----------
  BEGIN
    r := agent.fn_merge_member_identity('does_not_exist', 333, 'child');
    RAISE EXCEPTION 'FAIL merge [fehlende Person nicht als RAISE behandelt]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS merge [fehlende Person -> RAISE: %]', SQLERRM;
  END;

  RAISE NOTICE 'PASS fn_merge_member_identity [alle Invarianten]';
END $$;

ROLLBACK;
