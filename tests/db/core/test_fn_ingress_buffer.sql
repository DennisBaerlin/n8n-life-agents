-- tests/db/core/test_fn_ingress_buffer.sql
-- Telegram-Eingangs-Buendelung (agent.ingress_buffer): fn_record_ingress_message / fn_claim_ingress_burst.
-- Invarianten:
--   * record legt je update_id genau eine Zeile an (Dedupe ON CONFLICT -> action drop), kind text|file|solo,
--     Payload nur text/file (action wait); solo = selbst-beansprucht, action process
--   * claim: fehlende Zeile -> process ohne update (fail-open); fremde exec_id -> drop (Duplikat); schon beansprucht -> drop
--   * solo (Befehl, auch nach fuehrendem Zeilenumbruch, Sprache) wird nie gebuendelt und wartet nie
--   * Weiterleiten mit Kommentar: Text + Datei -> EIN process mit zusammengefuehrtem Update (Datei primaer,
--     Texte als caption in message_id-Reihenfolge), der andere Lauf -> drop; Reihenfolge der Ankunft egal
--   * mehrere Dateien: nur die frueheste bekommt die Texte, jede weitere Datei laeuft allein
--   * gleitendes Fenster: juengste Ankunft < 1 s und eigene < 5 s -> wait; Obergrenze 5 s bzw. final -> process
--   * Buendel relativ zur EIGENEN Ankunft (2 s davor bis 10 s danach), nie relativ zur Uhr -> eine verspaetete
--     Zeile verliert sich nie; eine aeltere unbeanspruchte Zeile (fail-open schon allein gelaufen) kommt nicht nochmal
--   * zusammengefuehrtes Update ohne entities (Offsets passten nicht mehr)
--   * anderer Absender im selben Chat (Gruppe) wird nie verschmolzen; beanspruchte Zeilen verlieren ihren Payload
--   * CHECKs: solo ohne Payload, unbeanspruchte text/file-Zeile behaelt ihn; record raeumt Zeilen > 2 min weg
-- Die Lock-/Schnappschuss-Paralleliaet prueft ein Ein-Sitzungs-Test nicht -> real_ingress_test (kind burst).
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

-- Testhelfer (pg_temp, mit dem ROLLBACK weg)
CREATE FUNCTION pg_temp.upd(p_uid bigint, p_chat bigint, p_from bigint, p_msg bigint, p_kind text, p_content text)
RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('update_id', p_uid, 'message',
    jsonb_build_object('message_id', p_msg, 'date', 1761200000, 'chat', jsonb_build_object('id', p_chat, 'type', 'private'),
                       'from', jsonb_build_object('id', p_from, 'is_bot', false, 'first_name', 'T'))
    || CASE p_kind
         WHEN 'text'  THEN jsonb_build_object('text', p_content)
         WHEN 'doc'   THEN jsonb_strip_nulls(jsonb_build_object('document', jsonb_build_object('file_id', 'F' || p_msg), 'caption', p_content))
         WHEN 'photo' THEN jsonb_strip_nulls(jsonb_build_object('photo', jsonb_build_array(jsonb_build_object('file_id', 'small'), jsonb_build_object('file_id', 'P' || p_msg)), 'caption', p_content))
         WHEN 'voice' THEN jsonb_build_object('voice', jsonb_build_object('file_id', 'V' || p_msg))
       END)
$f$;
CREATE FUNCTION pg_temp.rec(p_u jsonb, p_exec text) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT agent.fn_record_ingress_message(jsonb_build_object('update', p_u, 'exec_id', p_exec))
$f$;
CREATE FUNCTION pg_temp.claim(p_uid bigint, p_exec text) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT agent.fn_claim_ingress_burst(jsonb_build_object('update_id', p_uid, 'exec_id', p_exec))
$f$;
CREATE FUNCTION pg_temp.age(p_uid bigint, p_secs numeric) RETURNS void LANGUAGE sql AS $f$
  UPDATE agent.ingress_buffer SET registered_at = clock_timestamp() - make_interval(secs => p_secs) WHERE update_id = p_uid
$f$;

DO $$
DECLARE r jsonb; m jsonb;
BEGIN
  DELETE FROM agent.ingress_buffer WHERE chat_id BETWEEN 900200 AND 900299 OR chat_id = -900208;

  -- ---------- record: Zeile, kind, wait, Dedupe ----------
  r := pg_temp.rec(pg_temp.upd(1001, 900201, 900201, 284, 'doc', NULL), 'eD');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'duplicate')::boolean IS DISTINCT FROM false
     OR r->>'action' IS DISTINCT FROM 'wait' OR r->>'kind' IS DISTINCT FROM 'file' THEN
    RAISE EXCEPTION 'FAIL record doc [%]', r; END IF;
  r := pg_temp.rec(pg_temp.upd(1002, 900201, 900201, 285, 'text', 'Kommentar'), 'eT');
  IF r->>'kind' IS DISTINCT FROM 'text' OR r->>'action' IS DISTINCT FROM 'wait' THEN
    RAISE EXCEPTION 'FAIL record text [%]', r; END IF;
  r := pg_temp.rec(pg_temp.upd(1002, 900201, 900201, 285, 'text', 'Kommentar'), 'eT-retry');
  IF (r->>'duplicate')::boolean IS DISTINCT FROM true OR r->>'action' IS DISTINCT FROM 'drop' THEN
    RAISE EXCEPTION 'FAIL record dedupe [%]', r; END IF;
  IF (SELECT exec_id FROM agent.ingress_buffer WHERE update_id = 1002) IS DISTINCT FROM 'eT' THEN
    RAISE EXCEPTION 'FAIL record dedupe [Duplikat hat exec_id ueberschrieben]'; END IF;
  IF (SELECT payload FROM agent.ingress_buffer WHERE update_id = 1002) IS NULL THEN
    RAISE EXCEPTION 'FAIL record [text-Zeile ohne Payload]'; END IF;
  r := agent.fn_record_ingress_message(jsonb_build_object('update', jsonb_build_object('update_id', 1, 'callback_query', jsonb_build_object('id', 'x')), 'exec_id', 'eC'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL record [callback ohne message akzeptiert: %]', r; END IF;
  BEGIN
    PERFORM agent.fn_record_ingress_message(jsonb_build_object('update', pg_temp.upd(1, 900201, 900201, 1, 'text', 'x')));
    RAISE EXCEPTION 'FAIL record [fehlende exec_id akzeptiert]';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS record [kind, wait, Dedupe je update_id, Payload, callback abgelehnt, exec_id Pflicht]';

  -- ---------- Weiterleiten mit Kommentar (Datei zuerst): ein process, ein drop ----------
  r := pg_temp.claim(1002, 'eT');
  IF r->>'action' IS DISTINCT FROM 'wait' THEN RAISE EXCEPTION 'FAIL burst [juengste Ankunft frisch, erwartet wait: %]', r; END IF;
  PERFORM pg_temp.age(1001, 1.7); PERFORM pg_temp.age(1002, 1.6);
  r := pg_temp.claim(1001, 'eD');
  m := r->'update'->'message';
  IF r->>'action' IS DISTINCT FROM 'process' OR (r->'update'->>'update_id')::bigint IS DISTINCT FROM 1001
     OR m->'document'->>'file_id' IS DISTINCT FROM 'F284' OR m->>'caption' IS DISTINCT FROM 'Kommentar' OR m ? 'text'
     OR r->'merged_update_ids' IS DISTINCT FROM '[1001, 1002]'::jsonb THEN
    RAISE EXCEPTION 'FAIL burst [Datei-Lauf nicht zusammengefuehrt: %]', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.ingress_buffer WHERE update_id IN (1001, 1002) AND (claimed_by IS DISTINCT FROM 1001 OR payload IS NOT NULL)) THEN
    RAISE EXCEPTION 'FAIL burst [Zeilen nicht beansprucht bzw. Payload nicht geleert]'; END IF;
  r := pg_temp.claim(1002, 'eT');
  IF r->>'action' IS DISTINCT FROM 'drop' THEN RAISE EXCEPTION 'FAIL burst [Text-Lauf nicht verworfen: %]', r; END IF;
  r := pg_temp.claim(1001, 'eD');
  IF r->>'action' IS DISTINCT FROM 'drop' THEN RAISE EXCEPTION 'FAIL burst [zweiter Claim desselben Laufs nicht drop: %]', r; END IF;
  r := pg_temp.claim(1002, 'eT-retry');
  IF r->>'action' IS DISTINCT FROM 'drop' OR r->>'reason' IS DISTINCT FROM 'duplicate' THEN
    RAISE EXCEPTION 'FAIL burst [Duplikat-Lauf nicht als duplicate verworfen: %]', r; END IF;
  RAISE NOTICE 'PASS burst [Datei+Kommentar -> ein Update, caption = Kommentar, andere Laeufe drop, Payload geleert]';

  -- ---------- umgekehrte Reihenfolge (Kommentar zuerst), Text-Lauf greift zuerst zu ----------
  r := pg_temp.rec(pg_temp.upd(1101, 900202, 900202, 300, 'text', 'Erst Text'), 'a');
  r := pg_temp.rec(pg_temp.upd(1102, 900202, 900202, 301, 'photo', 'Bild'), 'b');
  PERFORM pg_temp.age(1101, 1.8); PERFORM pg_temp.age(1102, 1.5);
  r := pg_temp.claim(1101, 'a');
  m := r->'update'->'message';
  IF r->>'action' IS DISTINCT FROM 'process' OR (r->'update'->>'update_id')::bigint IS DISTINCT FROM 1102
     OR m->'photo'->1->>'file_id' IS DISTINCT FROM 'P301' OR m->>'caption' IS DISTINCT FROM E'Erst Text\n\nBild' OR m ? 'text' THEN
    RAISE EXCEPTION 'FAIL reverse [Foto nicht primaer bzw. caption falsch: %]', r; END IF;
  IF pg_temp.claim(1102, 'b')->>'action' IS DISTINCT FROM 'drop' THEN RAISE EXCEPTION 'FAIL reverse [Foto-Lauf nicht drop]'; END IF;
  RAISE NOTICE 'PASS reverse [Kommentar zuerst -> Datei primaer, Texte in message_id-Reihenfolge]';

  -- ---------- zwei Dateien + Kommentar: spaetere Datei allein, Text an die frueheste ----------
  r := pg_temp.rec(pg_temp.upd(1201, 900203, 900203, 400, 'doc', NULL), 'f1');
  r := pg_temp.rec(pg_temp.upd(1202, 900203, 900203, 401, 'doc', NULL), 'f2');
  r := pg_temp.rec(pg_temp.upd(1203, 900203, 900203, 402, 'text', 'Zu beiden'), 't');
  PERFORM pg_temp.age(1201, 1.9); PERFORM pg_temp.age(1202, 1.8); PERFORM pg_temp.age(1203, 1.7);
  r := pg_temp.claim(1202, 'f2');
  IF r->>'action' IS DISTINCT FROM 'process' OR r ? 'update' OR r->'merged_update_ids' IS DISTINCT FROM '[1202]'::jsonb THEN
    RAISE EXCEPTION 'FAIL files [spaetere Datei nicht allein: %]', r; END IF;
  r := pg_temp.claim(1201, 'f1');
  IF r->>'action' IS DISTINCT FROM 'process' OR r->'update'->'message'->>'caption' IS DISTINCT FROM 'Zu beiden'
     OR r->'merged_update_ids' IS DISTINCT FROM '[1201, 1203]'::jsonb THEN
    RAISE EXCEPTION 'FAIL files [frueheste Datei ohne den Text: %]', r; END IF;
  IF pg_temp.claim(1203, 't')->>'action' IS DISTINCT FROM 'drop' THEN RAISE EXCEPTION 'FAIL files [Text-Lauf nicht drop]'; END IF;
  -- Text-Lauf zuerst: nimmt die frueheste Datei, die zweite bleibt fuer sich
  r := pg_temp.rec(pg_temp.upd(1301, 900204, 900204, 500, 'doc', NULL), 'g1');
  r := pg_temp.rec(pg_temp.upd(1302, 900204, 900204, 501, 'doc', NULL), 'g2');
  r := pg_temp.rec(pg_temp.upd(1303, 900204, 900204, 502, 'text', 'Text'), 'gt');
  PERFORM pg_temp.age(1301, 1.9); PERFORM pg_temp.age(1302, 1.8); PERFORM pg_temp.age(1303, 1.7);
  r := pg_temp.claim(1303, 'gt');
  IF r->>'action' IS DISTINCT FROM 'process' OR (r->'update'->>'update_id')::bigint IS DISTINCT FROM 1301
     OR r->'merged_update_ids' IS DISTINCT FROM '[1301, 1303]'::jsonb THEN
    RAISE EXCEPTION 'FAIL files [Text-Lauf nahm nicht die frueheste Datei: %]', r; END IF;
  IF pg_temp.claim(1301, 'g1')->>'action' IS DISTINCT FROM 'drop' THEN RAISE EXCEPTION 'FAIL files [frueheste Datei nicht drop]'; END IF;
  r := pg_temp.claim(1302, 'g2');
  IF r->>'action' IS DISTINCT FROM 'process' OR r ? 'update' THEN RAISE EXCEPTION 'FAIL files [zweite Datei nicht allein: %]', r; END IF;
  RAISE NOTICE 'PASS files [mehrere Dateien: Text nur an die frueheste, jede weitere Datei allein]';

  -- ---------- solo: Befehl/Sprache nie gebuendelt, ohne Payload, ohne Warten ----------
  r := pg_temp.rec(pg_temp.upd(1401, 900205, 900205, 600, 'text', '/help'), 's1');
  IF r->>'kind' IS DISTINCT FROM 'solo' OR r->>'action' IS DISTINCT FROM 'process' THEN RAISE EXCEPTION 'FAIL solo [Befehl: %]', r; END IF;
  r := pg_temp.rec(pg_temp.upd(1402, 900205, 900205, 601, 'voice', NULL), 's2');
  IF r->>'kind' IS DISTINCT FROM 'solo' THEN RAISE EXCEPTION 'FAIL solo [Sprache: %]', r; END IF;
  r := pg_temp.rec(pg_temp.upd(1403, 900205, 900205, 602, 'text', 'hallo'), 's3');
  IF EXISTS (SELECT 1 FROM agent.ingress_buffer WHERE update_id IN (1401, 1402) AND payload IS NOT NULL) THEN
    RAISE EXCEPTION 'FAIL solo [Payload gespeichert]'; END IF;
  IF EXISTS (SELECT 1 FROM agent.ingress_buffer WHERE update_id IN (1401, 1402) AND claimed_by IS DISTINCT FROM update_id) THEN
    RAISE EXCEPTION 'FAIL solo [nicht selbst-beansprucht angelegt]'; END IF;
  r := pg_temp.rec(pg_temp.upd(1404, 900205, 900205, 603, 'text', E'\n /notfall'), 's4');
  IF r->>'kind' IS DISTINCT FROM 'solo' THEN RAISE EXCEPTION 'FAIL solo [Befehl mit fuehrendem Zeilenumbruch nicht solo: %]', r; END IF;
  r := pg_temp.claim(1401, 's1');
  IF r->>'action' IS DISTINCT FROM 'process' OR r ? 'update' THEN RAISE EXCEPTION 'FAIL solo [Befehl nicht sofort process: %]', r; END IF;
  PERFORM pg_temp.age(1403, 1.6);
  r := pg_temp.claim(1403, 's3');
  IF r->>'action' IS DISTINCT FROM 'process' OR r ? 'update' OR r->'merged_update_ids' IS DISTINCT FROM '[1403]'::jsonb THEN
    RAISE EXCEPTION 'FAIL solo [Text mit Befehl/Sprache gebuendelt: %]', r; END IF;
  RAISE NOTICE 'PASS solo [Befehl + Sprache solo, ohne Payload, nie gebuendelt]';

  -- ---------- gleitendes Fenster + Obergrenze ----------
  r := pg_temp.rec(pg_temp.upd(1501, 900206, 900206, 700, 'text', 'eins'), 'w1');
  r := pg_temp.rec(pg_temp.upd(1502, 900206, 900206, 701, 'text', 'zwei'), 'w2');
  PERFORM pg_temp.age(1501, 2); PERFORM pg_temp.age(1502, 0.2);
  UPDATE agent.ingress_buffer SET payload = jsonb_set(payload, '{message,entities}', '[{"type":"bold","offset":0,"length":4}]')
   WHERE update_id = 1501;
  IF pg_temp.claim(1501, 'w1')->>'action' IS DISTINCT FROM 'wait' THEN RAISE EXCEPTION 'FAIL window [kein wait trotz frischer Nachricht]'; END IF;
  PERFORM pg_temp.age(1501, 5.5);
  r := pg_temp.claim(1501, 'w1');
  IF r->>'action' IS DISTINCT FROM 'process' OR r->'update'->'message'->>'text' IS DISTINCT FROM E'eins\n\nzwei'
     OR r->'update'->'message' ? 'caption' OR r->'update'->'message' ? 'entities' THEN
    RAISE EXCEPTION 'FAIL window [Obergrenze nicht process, Texte nicht verbunden bzw. alte entities: %]', r; END IF;
  IF pg_temp.claim(1502, 'w2')->>'action' IS DISTINCT FROM 'drop' THEN RAISE EXCEPTION 'FAIL window [zweiter Text nicht drop]'; END IF;
  -- final (letzte Runde der Graph-Schleife): nie mehr wait, auch wenn die juengste Nachricht frisch ist
  r := pg_temp.rec(pg_temp.upd(1511, 900206, 900206, 710, 'text', 'drei'), 'w3');
  r := agent.fn_claim_ingress_burst('{"update_id": 1511, "exec_id": "w3", "final": true}'::jsonb);
  IF r->>'action' IS DISTINCT FROM 'process' THEN RAISE EXCEPTION 'FAIL window [final trotzdem wait: %]', r; END IF;
  RAISE NOTICE 'PASS window [frisch -> wait, ab 5 s bzw. final process; nur Texte -> text verbunden, entities weg]';

  -- ---------- Rueckblick nur 2 s: aeltere unbeanspruchte Zeile (fail-open schon allein gelaufen) nicht nochmal ----------
  r := pg_temp.rec(pg_temp.upd(1521, 900210, 900210, 720, 'text', 'schon allein gelaufen'), 'x1');
  r := pg_temp.rec(pg_temp.upd(1522, 900210, 900210, 721, 'text', 'neu'), 'x2');
  PERFORM pg_temp.age(1521, 4.6); PERFORM pg_temp.age(1522, 1.6);
  r := pg_temp.claim(1522, 'x2');
  IF r->>'action' IS DISTINCT FROM 'process' OR r ? 'update' OR r->'merged_update_ids' IS DISTINCT FROM '[1522]'::jsonb THEN
    RAISE EXCEPTION 'FAIL lookback [aeltere Zeile (> 2 s davor) mitgenommen: %]', r; END IF;
  RAISE NOTICE 'PASS lookback [nur 2 s zurueck, keine Doppel-Verarbeitung nach fail-open]';

  -- ---------- Fenster relativ zur eigenen Ankunft ----------
  r := pg_temp.rec(pg_temp.upd(1601, 900207, 900207, 800, 'text', 'spaet'), 'o1');
  r := pg_temp.rec(pg_temp.upd(1602, 900207, 900207, 801, 'text', 'nachbar'), 'o2');
  r := pg_temp.rec(pg_temp.upd(1603, 900207, 900207, 802, 'text', 'neu'), 'o3');
  PERFORM pg_temp.age(1601, 30); PERFORM pg_temp.age(1602, 29); PERFORM pg_temp.age(1603, 1.5);
  r := pg_temp.claim(1601, 'o1');
  IF r->>'action' IS DISTINCT FROM 'process' OR r->'merged_update_ids' IS DISTINCT FROM '[1601, 1602]'::jsonb THEN
    RAISE EXCEPTION 'FAIL own-window [eigene alte Zeile nicht samt Nachbar verarbeitet: %]', r; END IF;
  IF (SELECT claimed_by FROM agent.ingress_buffer WHERE update_id = 1603) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL own-window [Zeile mehr als 10 s danach mitgenommen]'; END IF;
  RAISE NOTICE 'PASS own-window [Buendel um die eigene Ankunft, nie relativ zur Uhr]';

  -- ---------- Gruppe: anderer Absender nie verschmolzen ----------
  r := pg_temp.rec(pg_temp.upd(1701, -900208, 11, 900, 'text', 'von A'), 'ga');
  r := pg_temp.rec(pg_temp.upd(1702, -900208, 22, 901, 'doc', NULL), 'gb');
  PERFORM pg_temp.age(1701, 1.6); PERFORM pg_temp.age(1702, 1.6);
  r := pg_temp.claim(1701, 'ga');
  IF r->>'action' IS DISTINCT FROM 'process' OR r ? 'update' THEN RAISE EXCEPTION 'FAIL group [fremder Absender verschmolzen: %]', r; END IF;
  r := pg_temp.claim(1702, 'gb');
  IF r->>'action' IS DISTINCT FROM 'process' OR r ? 'update' THEN RAISE EXCEPTION 'FAIL group [Datei von B nicht allein: %]', r; END IF;
  RAISE NOTICE 'PASS group [je (chat, from) getrennt]';

  -- ---------- fail-open: fehlende Zeile -> process; Pflichtfelder ----------
  r := pg_temp.claim(999999, 'x');
  IF r->>'action' IS DISTINCT FROM 'process' OR r ? 'update' THEN RAISE EXCEPTION 'FAIL missing [fehlende Zeile nicht process: %]', r; END IF;
  BEGIN
    PERFORM agent.fn_claim_ingress_burst('{"update_id": 1001}'::jsonb);
    RAISE EXCEPTION 'FAIL missing [claim ohne exec_id akzeptiert]';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS missing [fehlende Zeile -> process (fail-open), exec_id Pflicht]';

  -- ---------- DB-Gesetz: CHECKs ----------
  BEGIN
    INSERT INTO agent.ingress_buffer (update_id, chat_id, from_id, message_id, kind, exec_id, payload)
         VALUES (1801, 900209, 900209, 1, 'solo', 'c', '{}'::jsonb);
    RAISE EXCEPTION 'FAIL check [solo mit Payload akzeptiert]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE agent.ingress_buffer SET payload = NULL WHERE update_id = 1603;
    RAISE EXCEPTION 'FAIL check [unbeanspruchte text-Zeile ohne Payload akzeptiert]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'PASS check [solo ohne Payload, unbeanspruchte Zeile behaelt Payload]';

  -- ---------- record raeumt Zeilen > 2 min weg ----------
  PERFORM pg_temp.age(1603, 180);
  r := pg_temp.rec(pg_temp.upd(1901, 900209, 900209, 2, 'text', 'frisch'), 'p');
  IF EXISTS (SELECT 1 FROM agent.ingress_buffer WHERE update_id = 1603) THEN
    RAISE EXCEPTION 'FAIL purge [alte Zeile nicht weggeraeumt]'; END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.ingress_buffer WHERE update_id = 1901) THEN
    RAISE EXCEPTION 'FAIL purge [neue Zeile fehlt]'; END IF;
  RAISE NOTICE 'PASS purge [Zeilen > 2 min weg]';

  RAISE NOTICE 'PASS fn_record_ingress_message/fn_claim_ingress_burst [alle Invarianten]';
END $$;

ROLLBACK;
