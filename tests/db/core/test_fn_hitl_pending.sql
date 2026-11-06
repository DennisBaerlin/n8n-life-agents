-- tests/db/core/test_fn_hitl_pending.sql
-- Karte-offen-Sperre (agent.hitl_pending): fn_create_hitl_pending / fn_set_hitl_pending_released /
-- fn_delete_hitl_pending / fn_get_hitl_pending_state.
-- Invarianten:
--   * create legt eine Zeile (Ursprungs-Chat, execution, own_card) mit expires_at = now() + ttl an -> state 'own'
--   * zweite Karte im selben Chat = zweite Zeile (live lagen 3 Karten gleichzeitig offen); Upsert je execution
--   * own_card=false (Freigabe durch jemand anderen) -> state 'other'; eine eigene Karte hat Vorrang ('own')
--   * released: nur die eigene execution, Sperre bleibt bis zur Gnadenfrist (Kette antwortet noch); grace 0 = sofort frei
--   * delete (Orchestrator nach seiner Antwort) loescht NUR freigegebene Zeilen des Chats, nie offene Karten
--   * abgelaufene Zeile zaehlt nicht (expires_at ist die Wahrheit); create raeumt Abgelaufene weg
--   * nicht-numerische chat_id (Test-Sentinel) -> {ok:false}, keine Zeile; fehlende Pflichtfelder (Bau-Fehler) -> RAISE
--   * leere execution_id beim Freigeben (Error-Trigger ohne execution) -> no-op statt RAISE; state(NULL) -> NULL
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE r JSONB; v_exp timestamptz;
BEGIN
  DELETE FROM agent.hitl_pending WHERE chat_id IN (900101, 900102, 900103);

  -- ---------- create: Zeile, expires_at = now() + ttl, state 'own' ----------
  r := agent.fn_create_hitl_pending('{"chat_id":"900101","execution_id":"e1","ttl_minutes":16,"own_card":true}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL create [nicht ok: %]', r; END IF;
  v_exp := (r->>'expires_at')::timestamptz;
  IF v_exp IS DISTINCT FROM now() + interval '16 minutes' THEN
    RAISE EXCEPTION 'FAIL create [expires_at % != now()+16min]', v_exp; END IF;
  IF agent.fn_get_hitl_pending_state(900101) IS DISTINCT FROM 'own' THEN
    RAISE EXCEPTION 'FAIL state [900101 nach create nicht own]'; END IF;
  IF agent.fn_get_hitl_pending_state(900102) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL state [fremder Chat 900102 gesperrt]'; END IF;

  -- ---------- zweite Karte im selben Chat = zweite Zeile; create derselben execution = Upsert ----------
  r := agent.fn_create_hitl_pending('{"chat_id":"900101","execution_id":"e2","ttl_minutes":16,"own_card":true}'::jsonb);
  r := agent.fn_create_hitl_pending('{"chat_id":"900101","execution_id":"e2","ttl_minutes":16,"own_card":true}'::jsonb);
  IF (SELECT count(*) FROM agent.hitl_pending WHERE chat_id = 900101) <> 2 THEN
    RAISE EXCEPTION 'FAIL create2 [erwartet 2 Zeilen fuer 900101]'; END IF;
  RAISE NOTICE 'PASS create [Zeile, expires_at, state own, Mehrfach-Karten, Upsert]';

  -- ---------- own_card=false -> 'other'; eigene Karte hat Vorrang ----------
  r := agent.fn_create_hitl_pending('{"chat_id":"900103","execution_id":"e9","ttl_minutes":16,"own_card":false}'::jsonb);
  IF agent.fn_get_hitl_pending_state(900103) IS DISTINCT FROM 'other' THEN
    RAISE EXCEPTION 'FAIL state [own_card=false nicht other]'; END IF;
  r := agent.fn_create_hitl_pending('{"chat_id":"900103","execution_id":"e10","ttl_minutes":16}'::jsonb);
  IF agent.fn_get_hitl_pending_state(900103) IS DISTINCT FROM 'own' THEN
    RAISE EXCEPTION 'FAIL state [eigene Karte (Default own_card=true) hat keinen Vorrang]'; END IF;
  RAISE NOTICE 'PASS state [other bei fremder Freigabe, own hat Vorrang, Default own_card=true]';

  -- ---------- released: nur eigene execution, Sperre bleibt bis zur Gnadenfrist ----------
  r := agent.fn_set_hitl_pending_released('{"execution_id":"e1","grace_minutes":2}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'released')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL released [e1 nicht freigegeben: %]', r; END IF;
  IF (SELECT expires_at FROM agent.hitl_pending WHERE execution_id = 'e1') IS DISTINCT FROM now() + interval '2 minutes' THEN
    RAISE EXCEPTION 'FAIL released [Gnadenfrist nicht now()+2min]'; END IF;
  IF (SELECT released_at FROM agent.hitl_pending WHERE execution_id = 'e2') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL released [fremde execution e2 mit freigegeben]'; END IF;
  IF agent.fn_get_hitl_pending_state(900101) IS DISTINCT FROM 'own' THEN
    RAISE EXCEPTION 'FAIL released [Sperre waehrend der Gnadenfrist weg]'; END IF;
  r := agent.fn_set_hitl_pending_released('{"execution_id":"nix","grace_minutes":2}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'released')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL released [unbekannte execution: %]', r; END IF;
  r := agent.fn_set_hitl_pending_released('{"execution_id":"","grace_minutes":0}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'released')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL released [leere execution kein no-op: %]', r; END IF;
  RAISE NOTICE 'PASS released [nur eigene execution, Gnadenfrist, unbekannt/leer = no-op]';

  -- ---------- delete: nur freigegebene Zeilen des Chats, nie offene Karten ----------
  r := agent.fn_delete_hitl_pending('{"chat_id":"900101"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'removed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL delete [freigegebene Zeile nicht entfernt: %]', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.hitl_pending WHERE execution_id = 'e1') THEN
    RAISE EXCEPTION 'FAIL delete [e1 noch da]'; END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.hitl_pending WHERE execution_id = 'e2') THEN
    RAISE EXCEPTION 'FAIL delete [offene Karte e2 geloescht]'; END IF;
  r := agent.fn_delete_hitl_pending('{"chat_id":"900101"}'::jsonb);
  IF (r->>'removed')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL delete [Idempotenz: %]', r; END IF;
  r := agent.fn_delete_hitl_pending('{"chat_id":"test_e2e"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'removed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL delete [Sentinel-Chat kein no-op: %]', r; END IF;
  RAISE NOTICE 'PASS delete [nur freigegebene Zeilen, offene Karten bleiben, idempotent, Sentinel no-op]';

  -- ---------- grace 0 (Fehlerpfad) = sofort frei ----------
  -- now() ist in der Test-Transaktion konstant -> opened_at in die Vergangenheit, wie bei einer echten Karte.
  UPDATE agent.hitl_pending SET opened_at = now() - interval '1 minute' WHERE execution_id = 'e2';
  r := agent.fn_set_hitl_pending_released('{"execution_id":"e2","grace_minutes":0}'::jsonb);
  IF agent.fn_get_hitl_pending_state(900101) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL released [grace 0 sperrt weiter]'; END IF;
  RAISE NOTICE 'PASS released [grace 0 = sofort frei]';

  -- ---------- Ablauf: expires_at ist die Wahrheit; create raeumt Abgelaufene weg ----------
  INSERT INTO agent.hitl_pending (chat_id, execution_id, opened_at, expires_at)
       VALUES (900102, 'old', now() - interval '30 minutes', now() - interval '1 minute');
  IF agent.fn_get_hitl_pending_state(900102) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL expiry [abgelaufene Zeile sperrt]'; END IF;
  r := agent.fn_create_hitl_pending('{"chat_id":"900101","execution_id":"e3","ttl_minutes":16}'::jsonb);
  IF EXISTS (SELECT 1 FROM agent.hitl_pending WHERE execution_id IN ('old', 'e2')) THEN
    RAISE EXCEPTION 'FAIL expiry [create hat abgelaufene Zeilen nicht weggeraeumt]'; END IF;
  RAISE NOTICE 'PASS expiry [abgelaufen sperrt nicht, create raeumt auf]';

  -- ---------- Sentinel / Pflichtfelder / NULL ----------
  r := agent.fn_create_hitl_pending('{"chat_id":"test_e2e","execution_id":"e4","ttl_minutes":16}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL sentinel [nicht-numerisch akzeptiert: %]', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.hitl_pending WHERE execution_id = 'e4') THEN
    RAISE EXCEPTION 'FAIL sentinel [Zeile fuer Sentinel angelegt]'; END IF;
  BEGIN
    PERFORM agent.fn_create_hitl_pending('{"chat_id":"900101","ttl_minutes":16}'::jsonb);
    RAISE EXCEPTION 'FAIL required [fehlende execution_id akzeptiert]';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM agent.fn_create_hitl_pending('{"chat_id":"900101","execution_id":"e5"}'::jsonb);
    RAISE EXCEPTION 'FAIL required [fehlende ttl_minutes akzeptiert]';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM agent.fn_set_hitl_pending_released('{"execution_id":"e3"}'::jsonb);
    RAISE EXCEPTION 'FAIL required [fehlende grace_minutes akzeptiert]';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  IF agent.fn_get_hitl_pending_state(NULL) IS NOT NULL THEN RAISE EXCEPTION 'FAIL state [NULL-Chat gesperrt]'; END IF;
  RAISE NOTICE 'PASS [Sentinel ohne Zeile, Pflichtfelder RAISE, state(NULL)=NULL]';

  RAISE NOTICE 'PASS fn_create/set_released/delete/get_state hitl_pending [alle Invarianten]';
END $$;

-- Wiederhol-Sperre nach Abbrechen/Ablauf (agent.fn_set_hitl_pending_declined / fn_get_hitl_repeat_blocked / fn_hitl_repeat_key):
--   * Treffer nur bei gleichem Schluessel, gleichem Chat und nicht abgelaufener Zeile; repeat_key geht vor dem Hash
--   * alle Zeilen der Execution werden markiert, fremde bleiben; Bestaetigen setzt keinen Schluessel
--   * fehlendes Summary ergibt keinen Schluessel (kein md5(NULL)-Treffer); nicht-numerische chat_id sperrt nie
--   * nach fn_delete_hitl_pending kein Treffer, deren Rueckgabe bleibt unveraendert
DO $$
DECLARE
  r       jsonb;
  v_card  jsonb := '{"title":"core.hitl.probe","lines":[{"label":"core.label.note","kind":"text","value":"a"}]}';
  v_other jsonb := '{"title":"core.hitl.probe","lines":[{"label":"core.label.note","kind":"text","value":"b"}]}';
BEGIN
  DELETE FROM agent.hitl_pending WHERE chat_id IN (900201, 900202, 900203, 900204, 900205);

  -- ---------- Schluessel: repeat_key vor Hash, kein Schluessel ohne Summary ----------
  IF agent.fn_hitl_repeat_key('{"repeat_key":"finance:basics","title":"x"}'::jsonb) IS DISTINCT FROM 'finance:basics' THEN
    RAISE EXCEPTION 'FAIL key [repeat_key nicht bevorzugt]'; END IF;
  IF agent.fn_hitl_repeat_key(v_card) IS DISTINCT FROM md5(v_card::text) THEN
    RAISE EXCEPTION 'FAIL key [Hash des ganzen Summary erwartet]'; END IF;
  IF agent.fn_hitl_repeat_key('{"repeat_key":"","title":"x"}'::jsonb) IS DISTINCT FROM md5('{"repeat_key":"","title":"x"}'::jsonb::text) THEN
    RAISE EXCEPTION 'FAIL key [leerer repeat_key muss auf den Hash fallen]'; END IF;
  IF agent.fn_hitl_repeat_key('{"a":1,"b":2}'::jsonb) IS DISTINCT FROM agent.fn_hitl_repeat_key('{"b":2,"a":1}'::jsonb) THEN
    RAISE EXCEPTION 'FAIL key [Reihenfolge der Felder aendert den Hash]'; END IF;
  IF agent.fn_hitl_repeat_key(NULL) IS NOT NULL OR agent.fn_hitl_repeat_key('null'::jsonb) IS NOT NULL
     OR agent.fn_hitl_repeat_key('""'::jsonb) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL key [fehlendes/leeres Summary liefert einen Schluessel]'; END IF;
  IF agent.fn_hitl_repeat_key(to_jsonb('HITL probe'::text)) IS DISTINCT FROM md5(to_jsonb('HITL probe'::text)::text) THEN
    RAISE EXCEPTION 'FAIL key [String-Summary (Test-Harness) ohne Hash]'; END IF;
  RAISE NOTICE 'PASS repeat key [repeat_key vor Hash, stabil, kein Schluessel ohne Summary]';

  -- ---------- Eintragen + Treffer ----------
  r := agent.fn_create_hitl_pending('{"chat_id":"900201","execution_id":"r1","ttl_minutes":16}'::jsonb);
  IF agent.fn_get_hitl_repeat_blocked(jsonb_build_object('chat_id', '900201', 'summary', v_card)) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL blocked [offene Karte ohne Ablehnung sperrt]'; END IF;
  r := agent.fn_set_hitl_pending_released('{"execution_id":"r1","grace_minutes":2}'::jsonb);
  r := agent.fn_set_hitl_pending_declined(jsonb_build_object('execution_id', 'r1', 'summary', v_card));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'rows')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL declined [Rueckgabe: %]', r; END IF;
  IF (SELECT decline_key FROM agent.hitl_pending WHERE execution_id = 'r1') IS DISTINCT FROM md5(v_card::text) THEN
    RAISE EXCEPTION 'FAIL declined [decline_key nicht gesetzt]'; END IF;
  IF agent.fn_get_hitl_repeat_blocked(jsonb_build_object('chat_id', '900201', 'summary', v_card)) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL blocked [gleiche Karte im selben Chat nicht gesperrt]'; END IF;
  RAISE NOTICE 'PASS blocked [Eintrag + Treffer]';

  -- ---------- anderer Schluessel / anderer Chat ----------
  IF agent.fn_get_hitl_repeat_blocked(jsonb_build_object('chat_id', '900201', 'summary', v_other)) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL blocked [andere Karte gesperrt]'; END IF;
  IF agent.fn_get_hitl_repeat_blocked(jsonb_build_object('chat_id', '900202', 'summary', v_card)) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL blocked [anderer Chat gesperrt]'; END IF;
  RAISE NOTICE 'PASS blocked [nur gleicher Schluessel im gleichen Chat]';

  -- ---------- repeat_key vor Hash: anderer Text, gleicher Vorgang ----------
  r := agent.fn_create_hitl_pending('{"chat_id":"900202","execution_id":"r2","ttl_minutes":16}'::jsonb);
  r := agent.fn_set_hitl_pending_declined(jsonb_build_object('execution_id', 'r2',
         'summary', '{"repeat_key":"finance:basics","lines":[{"value":"alter Text"}]}'::jsonb));
  IF agent.fn_get_hitl_repeat_blocked(jsonb_build_object('chat_id', '900202',
       'summary', '{"repeat_key":"finance:basics","lines":[{"value":"neuer Text"}]}'::jsonb)) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL blocked [gleicher repeat_key, anderer Text nicht gesperrt]'; END IF;
  IF agent.fn_get_hitl_repeat_blocked(jsonb_build_object('chat_id', '900202',
       'summary', '{"repeat_key":"finance:other","lines":[{"value":"alter Text"}]}'::jsonb)) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL blocked [anderer repeat_key gesperrt]'; END IF;
  RAISE NOTICE 'PASS blocked [repeat_key geht vor dem Hash]';

  -- ---------- alle Zeilen der Execution, fremde unberuehrt; Bestaetigen setzt nichts ----------
  INSERT INTO agent.hitl_pending (chat_id, execution_id, expires_at) VALUES
    (900203, 'r3', now() + interval '5 minutes'), (900204, 'r3', now() + interval '5 minutes'),
    (900205, 'r4', now() + interval '5 minutes');
  r := agent.fn_set_hitl_pending_declined(jsonb_build_object('execution_id', 'r3', 'summary', v_card));
  IF (r->>'rows')::int IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'FAIL declined [erwartet 2 Zeilen: %]', r; END IF;
  r := agent.fn_set_hitl_pending_approved('{"execution_id":"r4"}'::jsonb);
  IF (SELECT decline_key FROM agent.hitl_pending WHERE execution_id = 'r4') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL declined [fremde/bestaetigte Zeile mit Schluessel]'; END IF;
  IF agent.fn_get_hitl_repeat_blocked(jsonb_build_object('chat_id', '900205', 'summary', v_card)) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL blocked [nach Bestaetigen gesperrt]'; END IF;
  RAISE NOTICE 'PASS declined [alle Zeilen der Execution, Bestaetigen sperrt nicht]';

  -- ---------- fehlendes Summary: kein md5(NULL)-Treffer ----------
  r := agent.fn_set_hitl_pending_declined('{"execution_id":"r4"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL declined [ohne Summary: %]', r; END IF;
  IF (SELECT decline_key FROM agent.hitl_pending WHERE execution_id = 'r4') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL declined [Schluessel ohne Summary]'; END IF;
  IF agent.fn_get_hitl_repeat_blocked('{"chat_id":"900205"}'::jsonb) IS DISTINCT FROM false
     OR agent.fn_get_hitl_repeat_blocked('{"chat_id":"900205","summary":null}'::jsonb) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL blocked [fehlendes Summary trifft]'; END IF;
  r := agent.fn_set_hitl_pending_declined('{"summary":{"a":1}}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL declined [leere Execution akzeptiert: %]', r; END IF;
  RAISE NOTICE 'PASS [fehlendes Summary trifft nie, leere Execution abgelehnt]';

  -- ---------- nicht-numerische chat_id (Test-Sentinel) sperrt nie, wirft nie ----------
  IF agent.fn_get_hitl_repeat_blocked(jsonb_build_object('chat_id', 'test_e2e', 'summary', v_card)) IS DISTINCT FROM false
     OR agent.fn_get_hitl_repeat_blocked(jsonb_build_object('summary', v_card)) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL blocked [Sentinel-chat_id sperrt]'; END IF;
  RAISE NOTICE 'PASS blocked [Sentinel sperrt nie]';

  -- ---------- Verfall: expires_at ist die Wahrheit ----------
  UPDATE agent.hitl_pending SET opened_at = now() - interval '10 minutes', expires_at = now() - interval '1 minute' WHERE execution_id = 'r3';
  IF agent.fn_get_hitl_repeat_blocked(jsonb_build_object('chat_id', '900203', 'summary', v_card)) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL blocked [abgelaufene Zeile sperrt]'; END IF;
  RAISE NOTICE 'PASS blocked [Verfall]';

  -- ---------- nach fn_delete_hitl_pending kein Treffer, deren Rueckgabe unveraendert ----------
  r := agent.fn_delete_hitl_pending('{"chat_id":"900201"}'::jsonb);
  IF r IS DISTINCT FROM '{"ok":true,"removed":true}'::jsonb THEN RAISE EXCEPTION 'FAIL delete [Rueckgabe: %]', r; END IF;
  IF agent.fn_get_hitl_repeat_blocked(jsonb_build_object('chat_id', '900201', 'summary', v_card)) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL blocked [nach dem Loeschen gesperrt]'; END IF;
  RAISE NOTICE 'PASS blocked [nach fn_delete_hitl_pending frei]';

  RAISE NOTICE 'PASS fn_set_hitl_pending_declined/fn_get_hitl_repeat_blocked/fn_hitl_repeat_key [alle Invarianten]';
END $$;

ROLLBACK;
