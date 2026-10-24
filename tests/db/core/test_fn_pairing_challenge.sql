-- tests/db/core/test_fn_pairing_challenge.sql
-- Sicherheits-Invarianten des Multi-User-Pairings (Phase 3 Dev/Release-Split-Plan), nach dem
-- Vorbild test_fn_import_challenge.sql, ergaenzt um die Pairing-spezifischen Gesetze:
--   * arm: Pflichtfelder (role), Entropie-Boden (>=8 alphanum) als {ok:false} UND CHECK-Backstop
--   * arm: owner-no-rearm (Owner existiert in family-Facts -> kein erneutes Owner-Arm ohne CLI)
--   * consume: chat_id-Bindung (fremder Chat loest nicht ein, brennt nichts)
--   * consume: Identitaets-Bindung (Member-Code nur durch die armierte telegram_user_id)
--   * consume: Erfolg -> MERGE telegram_user_id+role in eine BESTEHENDE family-Person
--               (Zwei-Stufen-Bootstrap; fn_validate_household_facts bleibt UNVERAENDERT gruen)
--   * consume: Replay (consumed_at), Expiry, fail_count-Lockout (3 Fehlversuche -> invalidiert)
-- Fixture: family (powner owner + ppartner partner, beide ohne telegram_user_id) + leeres
-- finance_profile, in der Transaktion ge-upsertet (BEGIN...ROLLBACK -> kein Residual-State).
BEGIN;

DO $$
DECLARE
  r       JSONB;
  v_res   JSONB;
  v_exp   TIMESTAMPTZ;
BEGIN
  -- ---------- Fixture: leeres finance_profile zuerst (family-Bidirektional-Check liest es) ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('finance_profile', 'pairing test fixture', 'finance_advisor', 'lazy', E'## fp',
          jsonb_build_object('managed_by','agent','protected', true,
                             'facts', jsonb_build_object()))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content, metadata = EXCLUDED.metadata;

  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'pairing test fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','protected', true,
            'facts', jsonb_build_object(
              'persons', jsonb_build_array(
                jsonb_build_object('person_id','powner','first_name','Owner','last_name','Person',
                                   'role','owner','birth_date','1980-01-01','as_of','2026-06-11'),
                jsonb_build_object('person_id','ppartner','first_name','Partner','last_name','Person',
                                   'role','partner','birth_date','1985-02-02','as_of','2026-06-11')
              ))))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content, metadata = EXCLUDED.metadata;
  RAISE NOTICE 'PASS pairing fixture [family owner+partner ohne telegram_user_id, leeres finance_profile]';

  -- ---------- arm: Pflichtfeld role ----------
  r := agent.fn_arm_pairing_challenge('{"chat_id":"test_pair_a","challenge":"PAIRAAAA"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL arm [fehlende role akzeptiert]'; END IF;

  -- ---------- arm: Entropie-Boden (kurzer Code) -> {ok:false} (freundlich, vor dem CHECK) ----------
  r := agent.fn_arm_pairing_challenge('{"chat_id":"test_pair_a","role":"partner","challenge":"AB12"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL arm [Code unter Entropie-Boden akzeptiert]'; END IF;

  -- ---------- arm: owner-bootstrap DARF gegen ein UNPAIRED Owner-Skelett armieren ----------
  -- Zwei-Stufen-Bootstrap (Phase 4): das Owner-Skelett (powner: role=owner, OHNE telegram_user_id)
  -- existiert, BEVOR der Owner seinen Code eintippt — sonst hat fn_consume keine Person zum Mergen.
  -- Der owner-no-rearm-Guard schuetzt nur den ETABLIERTEN (gepairten) Owner vor Re-Bind, nicht das
  -- noch unverknuepfte Skelett. Arm muss hier also GELINGEN.
  r := agent.fn_arm_pairing_challenge('{"role":"owner","challenge":"OWNERSEED1"}'::jsonb);
  IF NOT (r->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL arm [owner-bootstrap gegen UNPAIRED Skelett abgelehnt: %]', r->>'reason'; END IF;

  -- ---------- arm: owner-no-rearm greift, sobald der Owner GEPAIRT ist (telegram_user_id gesetzt) ----------
  -- powner eine numerische Identitaet geben (= etablierter Owner). Ein erneutes Owner-Arm muss jetzt
  -- abgelehnt werden (Privilege-Escalation-Schutz; Re-Arm braucht CLI-Zugriff).
  PERFORM agent.fn_set_context_facts(jsonb_build_object('context_name','family',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','powner','telegram_user_id',111)))));
  r := agent.fn_arm_pairing_challenge('{"role":"owner","challenge":"OWNERSEED2"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL arm [etablierter (gepairter) Owner re-armierbar]'; END IF;
  -- powner-Identitaet wieder loesen, damit die folgenden Member-Tests (ppartner/555) unbeeinflusst bleiben
  PERFORM agent.fn_set_context_facts(jsonb_build_object('context_name','family',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','powner','telegram_user_id', NULL)))));
  RAISE NOTICE 'PASS arm [role-Pflicht / Entropie-Boden / owner-no-rearm nur gegen GEPAIRTEN Owner]';

  -- ---------- arm: Member (partner) fuer chat A, gebunden an telegram_user_id 555 ----------
  r := agent.fn_arm_pairing_challenge(
        '{"chat_id":"test_pair_a","telegram_user_id":555,"role":"partner","challenge":"PAIRCODE1"}'::jsonb);
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL arm [member: %]', r->>'reason'; END IF;

  -- ---------- consume: fremder Chat loest nicht ein (chat_id-Bindung) ----------
  r := agent.fn_consume_pairing_challenge(
        '{"chat_id":"test_pair_b","telegram_user_id":555,"challenge":"PAIRCODE1","person_id":"ppartner"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL consume [fremder Chat loest ein]'; END IF;

  -- ---------- consume: Identitaets-Mismatch (anderer Sender) -> {ok:false}, brennt 1 Versuch ----------
  r := agent.fn_consume_pairing_challenge(
        '{"chat_id":"test_pair_a","telegram_user_id":999,"challenge":"PAIRCODE1","person_id":"ppartner"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL consume [fremde Identitaet loest Member-Code ein]'; END IF;
  IF (r->>'fail_count')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL consume [Identitaets-Mismatch zaehlt nicht als Fehlversuch: %]', r;
  END IF;

  -- ---------- consume: korrekt (chat+id+code) -> MERGE in bestehende Person ----------
  r := agent.fn_consume_pairing_challenge(
        '{"chat_id":"test_pair_a","telegram_user_id":555,"challenge":"  PAIRCODE1  ","person_id":"ppartner"}'::jsonb);
  IF NOT (r->>'ok')::boolean OR r->>'role' IS DISTINCT FROM 'partner' THEN
    RAISE EXCEPTION 'FAIL consume [korrekter Code nicht eingeloest: %]', r;
  END IF;
  -- die family-Person traegt jetzt die numerische Identitaet; der Validator blieb gruen
  v_res := agent.fn_resolve_sender(555);
  IF (v_res->>'found')::boolean IS DISTINCT FROM true OR v_res->>'person_id' IS DISTINCT FROM 'ppartner' THEN
    RAISE EXCEPTION 'FAIL consume [telegram_user_id nicht in family-Facts gemerged: %]', v_res;
  END IF;
  -- as_of-Erhaltung (BL3): das Pairing heftet nur Identitaet an, es ist KEINE Fakten-Aktualisierung
  -- -> der Skelett-as_of der Person ('2026-06-11') muss UNVERAENDERT bleiben (nicht auf heute springen).
  IF (SELECT pp->>'as_of'
        FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
       WHERE c.name = 'family' AND pp->>'person_id' = 'ppartner') IS DISTINCT FROM '2026-06-11' THEN
    RAISE EXCEPTION 'FAIL consume [Pairing ueberschrieb den Skelett-as_of der Person (Staleness-Stempel)]';
  END IF;
  RAISE NOTICE 'PASS consume [chat-/Identitaets-Bindung + Erfolg-Merge + as_of-Erhaltung]';

  -- ---------- consume: Replay (zweiter Einlosung schlaegt fehl) ----------
  r := agent.fn_consume_pairing_challenge(
        '{"chat_id":"test_pair_a","telegram_user_id":555,"challenge":"PAIRCODE1","person_id":"ppartner"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL consume [Doppel-Einloesung / Replay]'; END IF;

  -- ---------- consume: Expiry ----------
  r := agent.fn_arm_pairing_challenge(
        '{"chat_id":"test_pair_a","telegram_user_id":555,"role":"partner","challenge":"EXPIRED01"}'::jsonb);
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL arm [expiry-setup: %]', r->>'reason'; END IF;
  UPDATE agent.pairing_state SET expires_at = NOW() - INTERVAL '1 minute'
  WHERE chat_id = 'test_pair_a' AND challenge = 'EXPIRED01' AND consumed_at IS NULL;
  r := agent.fn_consume_pairing_challenge(
        '{"chat_id":"test_pair_a","telegram_user_id":555,"challenge":"EXPIRED01","person_id":"ppartner"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL consume [abgelaufene Challenge eingeloest]'; END IF;
  RAISE NOTICE 'PASS consume [Replay + Expiry]';

  -- ---------- consume: fail_count-Lockout (3 Fehlversuche -> invalidiert, danach Sperre) ----------
  r := agent.fn_arm_pairing_challenge(
        '{"chat_id":"test_pair_a","telegram_user_id":555,"role":"partner","challenge":"LOCKCODE1"}'::jsonb);
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL arm [lockout-setup: %]', r->>'reason'; END IF;
  r := agent.fn_consume_pairing_challenge(
        '{"chat_id":"test_pair_a","telegram_user_id":555,"challenge":"WRONGCODE","person_id":"ppartner"}'::jsonb);
  IF (r->>'fail_count')::int IS DISTINCT FROM 1 OR (r->>'locked')::boolean THEN
    RAISE EXCEPTION 'FAIL lockout [erster Fehlversuch: %]', r; END IF;
  r := agent.fn_consume_pairing_challenge(
        '{"chat_id":"test_pair_a","telegram_user_id":555,"challenge":"WRONGCODE","person_id":"ppartner"}'::jsonb);
  IF (r->>'fail_count')::int IS DISTINCT FROM 2 OR (r->>'locked')::boolean THEN
    RAISE EXCEPTION 'FAIL lockout [zweiter Fehlversuch: %]', r; END IF;
  r := agent.fn_consume_pairing_challenge(
        '{"chat_id":"test_pair_a","telegram_user_id":555,"challenge":"WRONGCODE","person_id":"ppartner"}'::jsonb);
  IF (r->>'fail_count')::int IS DISTINCT FROM 3 OR NOT (r->>'locked')::boolean THEN
    RAISE EXCEPTION 'FAIL lockout [dritter Fehlversuch muss locked=true setzen: %]', r; END IF;
  -- jetzt ist die Challenge invalidiert: selbst der KORREKTE Code wird abgewiesen
  r := agent.fn_consume_pairing_challenge(
        '{"chat_id":"test_pair_a","telegram_user_id":555,"challenge":"LOCKCODE1","person_id":"ppartner"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL lockout [korrekter Code nach Lockout eingeloest]'; END IF;
  RAISE NOTICE 'PASS consume [fail_count-Lockout: 3 Fehlversuche invalidieren, korrekter Code danach gesperrt]';

  -- ---------- consume: OWNER-Challenge (chat_id NULL) zaehlt Fehlversuche + lockt aus ----------
  -- Regression-Guard: die Owner-Bootstrap-Challenge wird mit chat_id NULL armiert (matcht jeden
  -- Chat). Der Fehlversuch-Pfad MUSS sie trotzdem treffen (chat_id IS NULL OR chat_id = v_chat) —
  -- sonst koennte der Owner-Code im 10-Min-Fenster ohne OWASP-Lockout gebruteforct werden.
  r := agent.fn_arm_pairing_challenge('{"role":"owner","challenge":"OWNERLOCK1"}'::jsonb);
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL arm [owner-lockout-setup: %]', r->>'reason'; END IF;
  -- Falschversuch aus einem BELIEBIGEN Chat -> muss an der NULL-chat-Owner-Challenge zaehlen
  r := agent.fn_consume_pairing_challenge(
        '{"chat_id":"test_attacker","telegram_user_id":777,"challenge":"WRONGOWNR","person_id":"powner"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL owner-lockout [falscher Code eingeloest]'; END IF;
  IF (r->>'fail_count')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL owner-lockout [Owner-Challenge zaehlt Fehlversuch nicht (chat_id NULL nicht getroffen): %]', r;
  END IF;
  r := agent.fn_consume_pairing_challenge(
        '{"chat_id":"test_attacker","telegram_user_id":777,"challenge":"WRONGOWNR","person_id":"powner"}'::jsonb);
  r := agent.fn_consume_pairing_challenge(
        '{"chat_id":"test_attacker2","telegram_user_id":888,"challenge":"WRONGOWNR","person_id":"powner"}'::jsonb);
  IF (r->>'fail_count')::int IS DISTINCT FROM 3 OR NOT (r->>'locked')::boolean THEN
    RAISE EXCEPTION 'FAIL owner-lockout [3. Fehlversuch muss locked=true setzen: %]', r; END IF;
  -- jetzt ist die Owner-Challenge invalidiert: der KORREKTE Code wird abgewiesen
  r := agent.fn_consume_pairing_challenge(
        '{"chat_id":"test_owner","telegram_user_id":111,"challenge":"OWNERLOCK1","person_id":"powner"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL owner-lockout [korrekter Owner-Code nach Lockout eingeloest]'; END IF;
  RAISE NOTICE 'PASS consume [Owner-Challenge (chat_id NULL): Fehlversuche zaehlen + Lockout]';

  -- ---------- Entropie-CHECK als struktureller Backstop (Direkt-INSERT, kein fn) ----------
  BEGIN
    INSERT INTO agent.pairing_state (chat_id, role, challenge, expires_at)
    VALUES ('test_pair_a', 'partner', 'AB1', NOW() + INTERVAL '10 minutes');
    RAISE EXCEPTION 'FAIL CHECK [Code unter Entropie-Boden via Direkt-INSERT akzeptiert]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS CHECK [pairing_challenge_min_entropy blockt kurzen Code auch per psql: %]', SQLERRM;
  END;

  -- ============================================================
  -- WS-5a: Einladungs-Flow (Owner-initiiert) — arm(person_id) -> claim STAGT -> Owner confirm/reject
  -- ============================================================
  -- frische Kind-Person als Einladungs-Ziel (ppartner ist oben bereits an 555 gepairt).
  PERFORM agent.fn_set_context_facts(jsonb_build_object('context_name','family','facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','pchild','first_name','Kind','last_name','Person',
                       'role','child','birth_date','2015-03-03')))));

  -- arm: Member-Einladung traegt person_id (Owner stellt aus)
  r := agent.fn_arm_pairing_challenge('{"role":"child","challenge":"INVITE001","person_id":"pchild"}'::jsonb);
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL invite-arm [%]', r->>'reason'; END IF;

  -- claim: Mitglied loest ein -> STAGT, bindet NICHT (vor Owner-Bestaetigung nicht aufloesbar)
  r := agent.fn_claim_pairing_challenge('{"challenge":"INVITE001","telegram_user_id":4242,"chat_id":"4242","language_code":"ko-KR"}'::jsonb);
  IF (r->>'staged')::boolean IS DISTINCT FROM true OR r->>'person_id' IS DISTINCT FROM 'pchild' THEN
    RAISE EXCEPTION 'FAIL claim [Member-Code nicht gestaged: %]', r; END IF;
  IF (agent.fn_resolve_sender(4242)->>'found')::boolean THEN
    RAISE EXCEPTION 'FAIL claim [Identitaet vor Owner-Confirm bereits gebunden]'; END IF;
  -- Telegram-Sprache (from.language_code) wird nur als normalisierter VORSCHLAG gemerkt (ko-KR -> ko).
  IF (SELECT language_hint FROM agent.pairing_state WHERE challenge='INVITE001') IS DISTINCT FROM 'ko' THEN
    RAISE EXCEPTION 'FAIL claim [language_hint nicht normalisiert gemerkt: %]',
      (SELECT language_hint FROM agent.pairing_state WHERE challenge='INVITE001'); END IF;

  -- claim: zweite Einloesung desselben Codes -> pending (kein Doppel-Stage)
  r := agent.fn_claim_pairing_challenge('{"challenge":"INVITE001","telegram_user_id":4242,"chat_id":"4242"}'::jsonb);
  IF (r->>'staged')::boolean OR (r->>'pending')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL claim [zweite Einloesung nicht als pending: %]', r; END IF;
  RAISE NOTICE 'PASS claim [Member-Einloesung stagt nicht-bindend; Doppel-Einloesung = pending]';

  -- confirm: Owner bestaetigt -> BINDUNG committet
  r := agent.fn_confirm_pairing(jsonb_build_object('id',
        (SELECT id FROM agent.pairing_state WHERE challenge='INVITE001' AND consumed_at IS NULL)));
  IF NOT (r->>'ok')::boolean OR r->>'member_chat_id' IS DISTINCT FROM '4242' THEN
    RAISE EXCEPTION 'FAIL confirm [Bindung nicht committet: %]', r; END IF;
  IF (agent.fn_resolve_sender(4242)->>'person_id') IS DISTINCT FROM 'pchild' THEN
    RAISE EXCEPTION 'FAIL confirm [Identitaet nach Owner-Confirm nicht gebunden]'; END IF;
  -- Vorschlag zurueck an den Orchestrator (Picker-Markierung), aber NIE still gesetzt: family bleibt ohne language.
  IF r->>'language_hint' IS DISTINCT FROM 'ko' OR (r->>'has_language')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL confirm [language_hint/has_language: %]', r; END IF;
  IF (SELECT pp ? 'language' FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
      WHERE c.name = 'family' AND pp->>'person_id' = 'pchild') THEN
    RAISE EXCEPTION 'FAIL confirm [Sprache still in family gesetzt]'; END IF;

  -- confirm: zweites ✅ (Telegram-Retry) -> idempotenter no-op
  r := agent.fn_confirm_pairing(jsonb_build_object('id',
        (SELECT id FROM agent.pairing_state WHERE challenge='INVITE001')));
  IF (r->>'ok')::boolean OR (r->>'resolved')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL confirm [Doppel-Tap nicht idempotent: %]', r; END IF;
  RAISE NOTICE 'PASS confirm [Owner-Bestaetigung bindet; Doppel-Tap = idempotenter no-op]';

  -- reject: Owner lehnt eine frische Einladung ab -> keine Bindung
  PERFORM agent.fn_set_context_facts(jsonb_build_object('context_name','family','facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','pchild2','first_name','Kind2','last_name','Person',
                       'role','child','birth_date','2017-04-04')))));
  r := agent.fn_arm_pairing_challenge('{"role":"child","challenge":"INVITE002","person_id":"pchild2"}'::jsonb);
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL invite-arm2 [%]', r->>'reason'; END IF;
  r := agent.fn_claim_pairing_challenge('{"challenge":"INVITE002","telegram_user_id":5252,"chat_id":"5252","language_code":"fr"}'::jsonb);
  IF (r->>'staged')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL claim2 [%]', r; END IF;
  -- Nicht unterstuetzte Telegram-Sprache (fr) -> kein Vorschlag.
  IF (SELECT language_hint FROM agent.pairing_state WHERE challenge='INVITE002') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL claim2 [fr darf keinen Vorschlag ergeben]'; END IF;
  r := agent.fn_reject_pairing(jsonb_build_object('id',
        (SELECT id FROM agent.pairing_state WHERE challenge='INVITE002' AND consumed_at IS NULL)));
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL reject [%]', r; END IF;
  IF (agent.fn_resolve_sender(5252)->>'found')::boolean THEN
    RAISE EXCEPTION 'FAIL reject [Mitglied nach Ablehnung doch gebunden]'; END IF;
  RAISE NOTICE 'PASS reject [Ablehnung verwirft den Stage ohne Bindung]';

  -- claim: Owner-Bootstrap-Code (person_id NULL) matcht den Member-Pfad NIE
  r := agent.fn_arm_pairing_challenge('{"role":"owner","challenge":"OWNERONLY1"}'::jsonb);
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL owner-arm [%]', r->>'reason'; END IF;
  r := agent.fn_claim_pairing_challenge('{"challenge":"OWNERONLY1","telegram_user_id":6363,"chat_id":"6363"}'::jsonb);
  IF (r->>'staged')::boolean THEN RAISE EXCEPTION 'FAIL claim [Owner-Code im Member-Pfad gestaged]'; END IF;

  -- claim: zwei offene Einladungen, gleiche Member-uid, verschiedene Personen -> kein Index-Konflikt (M1)
  PERFORM agent.fn_set_context_facts(jsonb_build_object('context_name','family','facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','pchildA','first_name','KindA','last_name','Person','role','child','birth_date','2018-01-01'),
    jsonb_build_object('person_id','pchildB','first_name','KindB','last_name','Person','role','child','birth_date','2019-02-02')))));
  PERFORM agent.fn_arm_pairing_challenge('{"role":"child","challenge":"INVITEAAA","person_id":"pchildA"}'::jsonb);
  PERFORM agent.fn_arm_pairing_challenge('{"role":"child","challenge":"INVITEBBB","person_id":"pchildB"}'::jsonb);
  r := agent.fn_claim_pairing_challenge('{"challenge":"INVITEAAA","telegram_user_id":8888,"chat_id":"8888"}'::jsonb);
  IF (r->>'staged')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL claim-A [%]', r; END IF;
  r := agent.fn_claim_pairing_challenge('{"challenge":"INVITEBBB","telegram_user_id":8888,"chat_id":"8888"}'::jsonb);
  IF (r->>'staged')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL claim-B [zweiter Stage derselben uid kollidierte (claimed_uid vs telegram_user_id-Index?): %]', r; END IF;
  RAISE NOTICE 'PASS claim [Owner-Code-Ausschluss + zwei gestagte Claims gleiche uid/verschiedene Person]';

  -- ============================================================
  -- WS-5d: eine gesperrte uid (agent.access_blocks) kann sich auch mit gueltigem Code NICHT verbinden
  -- ============================================================
  PERFORM agent.fn_block_knocker('{"telegram_user_id":7777}'::jsonb);

  -- claim: gueltige Member-Einladung, aber die einloesende uid ist gesperrt -> staged:false
  PERFORM agent.fn_set_context_facts(jsonb_build_object('context_name','family','facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','pblock','first_name','Block','last_name','Person','role','child','birth_date','2016-05-05')))));
  PERFORM agent.fn_arm_pairing_challenge('{"role":"child","challenge":"BLOCKINV1","person_id":"pblock"}'::jsonb);
  r := agent.fn_claim_pairing_challenge('{"challenge":"BLOCKINV1","telegram_user_id":7777,"chat_id":"7777"}'::jsonb);
  IF (r->>'staged')::boolean OR (r->>'blocked')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL claim [gesperrte uid gestaged statt abgewiesen: %]', r; END IF;
  -- die Einladung ist NICHT verbraucht -> eine NICHT-gesperrte uid koennte sie weiter einloesen
  r := agent.fn_claim_pairing_challenge('{"challenge":"BLOCKINV1","telegram_user_id":7778,"chat_id":"7778"}'::jsonb);
  IF (r->>'staged')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL claim [Block-Abweisung verbrannte die Einladung: %]', r; END IF;

  -- consume: Owner-Bootstrap-Code, einloesende uid gesperrt -> ok:false
  PERFORM agent.fn_arm_pairing_challenge('{"role":"owner","challenge":"BLOCKOWN1"}'::jsonb);
  r := agent.fn_consume_pairing_challenge('{"chat_id":"7777","telegram_user_id":7777,"challenge":"BLOCKOWN1","person_id":"powner"}'::jsonb);
  IF (r->>'ok')::boolean OR (r->>'blocked')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL consume [gesperrte uid loeste den Owner-Code ein: %]', r; END IF;
  RAISE NOTICE 'PASS WS-5d [gesperrte uid: claim staged:false + consume ok:false; Einladung nicht verbrannt]';

  RAISE NOTICE 'PASS fn_arm/fn_consume_pairing_challenge [alle Sicherheits-Invarianten]';
END $$;

ROLLBACK;
