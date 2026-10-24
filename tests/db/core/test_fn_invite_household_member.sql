-- tests/db/core/test_fn_invite_household_member.sql
-- WS-5a — Owner-initiierte Member-Einladung (Chat, owner-only). Sicherheits-Invarianten von
-- agent.fn_check_household_invite (Pre-Gate-Validierung) + agent.fn_invite_household_member (Write = armt):
--   * Owner-Gate: nur der GEPAIRTE Owner darf einladen; Nicht-Owner-chat_id -> {ok:false}, KEIN INSERT
--   * Person-Check: unbekannter/mehrdeutiger Name -> {ok:false}; der Owner selbst nicht einladbar;
--     bereits gepairte Person -> {ok:false}
--   * Erfolg: ungepairtes Kind -> {ok:true, challenge>=8 alphanum, person_id/role/full_name} +
--     pairing_state-Zeile mit person_id armiert (vom fn_arm); deterministisch ueber fn_claim einloesbar
-- Fixture: family (powner owner GEPAIRT an 111, pchild child ungepairt, ptwin1/ptwin2 Namensgleichheit),
-- in BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  r        JSONB;
  v_before INT;
  v_after  INT;
BEGIN
  -- ---------- Fixture ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('finance_profile', 'invite test fixture', 'finance_advisor', 'lazy', E'## fp',
          jsonb_build_object('managed_by','agent','protected', true, 'facts', jsonb_build_object()))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content, metadata = EXCLUDED.metadata;

  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'invite test fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','protected', true,
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','powner','first_name','Owner','last_name','Person',
                                 'role','owner','birth_date','1980-01-01','telegram_user_id',111,'as_of','2026-06-11'),
              jsonb_build_object('person_id','pchild','first_name','Lisa','last_name','Person',
                                 'role','child','birth_date','2015-03-03','as_of','2026-06-11'),
              jsonb_build_object('person_id','ptwin1','first_name','Max','last_name','Eins',
                                 'role','child','birth_date','2016-04-04','as_of','2026-06-11'),
              jsonb_build_object('person_id','ptwin2','first_name','Max','last_name','Zwei',
                                 'role','child','birth_date','2017-05-05','as_of','2026-06-11')
            ))))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content, metadata = EXCLUDED.metadata;
  RAISE NOTICE 'PASS invite fixture [owner gepairt(111) + Kind ungepairt + zwei Max (Namensgleichheit)]';

  -- ---------- Owner-Gate: Nicht-Owner-chat_id -> {ok:false}, KEIN pairing_state-Write ----------
  SELECT count(*) INTO v_before FROM agent.pairing_state;
  r := agent.fn_invite_household_member('{"chat_id":"999999","person_name":"Lisa"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL invite [Nicht-Owner durfte einladen: %]', r; END IF;
  SELECT count(*) INTO v_after FROM agent.pairing_state;
  IF v_after <> v_before THEN
    RAISE EXCEPTION 'FAIL invite [Nicht-Owner-Aufruf schrieb eine pairing_state-Zeile (before=%, after=%)]', v_before, v_after;
  END IF;

  -- ---------- Owner-Gate auch fuer den reinen Check (READ) ----------
  r := agent.fn_check_household_invite('{"chat_id":"999999","person_name":"Lisa"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL check [Nicht-Owner besteht den Check]'; END IF;
  RAISE NOTICE 'PASS owner-gate [Nicht-Owner-chat_id abgelehnt, kein Write]';

  -- ---------- Person-Check: unbekannter Name ----------
  r := agent.fn_invite_household_member('{"chat_id":"111","person_name":"Niemand"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL invite [unbekannte Person akzeptiert: %]', r; END IF;

  -- ---------- Person-Check: mehrdeutiger Name (zwei "Max") ----------
  r := agent.fn_invite_household_member('{"chat_id":"111","person_name":"Max"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL invite [mehrdeutiger Name akzeptiert: %]', r; END IF;

  -- ---------- Person-Check: Owner selbst nicht einladbar ----------
  r := agent.fn_invite_household_member('{"chat_id":"111","person_name":"Owner Person"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL invite [Owner als Member einladbar: %]', r; END IF;
  RAISE NOTICE 'PASS person-check [unbekannt / mehrdeutig / Owner-selbst abgelehnt]';

  -- ---------- Erfolg: ungepairtes Kind -> armt eine Einladung ----------
  SELECT count(*) INTO v_before FROM agent.pairing_state;
  r := agent.fn_invite_household_member('{"chat_id":"111","person_name":"Lisa"}'::jsonb);
  IF NOT (r->>'ok')::boolean OR r->>'person_id' IS DISTINCT FROM 'pchild' OR r->>'role' IS DISTINCT FROM 'child' THEN
    RAISE EXCEPTION 'FAIL invite [gueltige Einladung nicht erstellt: %]', r;
  END IF;
  IF COALESCE(r->>'challenge','') !~ '^[A-Za-z0-9]{8,}$' THEN
    RAISE EXCEPTION 'FAIL invite [Code unter Entropie-Boden / nicht alphanumerisch: %]', r->>'challenge';
  END IF;
  SELECT count(*) INTO v_after FROM agent.pairing_state;
  IF v_after <> v_before + 1 THEN
    RAISE EXCEPTION 'FAIL invite [keine genau-eine pairing_state-Zeile armiert (before=%, after=%)]', v_before, v_after;
  END IF;
  -- die armierte Zeile traegt die Ziel-person_id + role + ist offen
  IF NOT EXISTS (SELECT 1 FROM agent.pairing_state
                 WHERE challenge = r->>'challenge' AND person_id = 'pchild' AND role = 'child'
                   AND consumed_at IS NULL AND claimed_at IS NULL) THEN
    RAISE EXCEPTION 'FAIL invite [armierte Zeile nicht an pchild gebunden / nicht offen]';
  END IF;
  -- end-to-end: der ausgestellte Code ist vom Mitglied einloesbar (stagt)
  IF (agent.fn_claim_pairing_challenge(
        jsonb_build_object('challenge', r->>'challenge', 'telegram_user_id', 4242, 'chat_id', '4242'))->>'staged')::boolean
     IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL invite [ausgestellter Code nicht vom Mitglied einloesbar]';
  END IF;
  RAISE NOTICE 'PASS invite [ungepairtes Kind -> Einladung armiert + vom Mitglied einloesbar]';

  -- ---------- Person-Check: bereits gepairte Person -> {ok:false} ----------
  -- pchild wurde oben gerade gepairt (claim->stage genuegt NICHT; binden via confirm). Daher hier
  -- die direkte family-Bindung simulieren: powner ist schon gepairt -> Re-Invite muss scheitern.
  -- (Owner ist zugleich gepairt; der Owner-Branch faengt ihn bereits -> wir testen eine gepairte
  --  NICHT-Owner-Person: pchild explizit an eine uid heften.)
  PERFORM agent.fn_set_context_facts(jsonb_build_object('context_name','family','facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','pchild','telegram_user_id', 4242)))));
  r := agent.fn_invite_household_member('{"chat_id":"111","person_name":"Lisa"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL invite [bereits gepairte Person erneut einladbar: %]', r; END IF;
  RAISE NOTICE 'PASS person-check [bereits gepairte Person abgelehnt]';

  RAISE NOTICE 'PASS fn_check_household_invite/fn_invite_household_member [alle Invarianten]';
END $$;

ROLLBACK;
