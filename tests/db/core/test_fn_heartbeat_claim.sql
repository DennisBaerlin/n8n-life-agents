-- tests/db/core/test_fn_heartbeat_claim.sql
-- Waechter des Hintergrund-Teils: core.fn_heartbeat_claim (je Lauf zaehlen + faellige Texte) im Zusammenspiel mit
-- core.fn_heartbeat_record (Beat) und core.fn_heartbeat_finish (Ergebnis des Sendens). Zeit nur ueber p.at.
--   1) Docker: Schleife steht -> Schleifen-Alarm nach 15 min beobachteter Zeit; Stufe 2 nach 24 h, Stufe 3 nach 7 Tagen;
--      check/backup schweigen und zaehlen nicht (Ursache vor Folge); Entwarnung genau einmal; danach keine Folge-Alarme
--   2) Flattern: neue Stufe 1 fruehestens 24 h nach der letzten Entwarnung; neuer Vorfall = neuer Schluessel
--   3) klassisch: kein Inhibit, Schleife und Pruefung melden getrennt; Docker im selben Lauf nur die Schleife
--   4) busy haelt bis busy_until, danach zaehlt es ab busy_until
--   5) Text not_release nach 1 h Wanduhr, skipped still; Entwarnung nach ok
--   6) Sicherung: Ruhe nach eigener Meldung in 20 h, nofolder still, sonst Sicherungs-Alarm; nofolder ist keine Entwarnung
--   7) Fenster: nachts nichts, zum Fensterbeginn nachgeholt
--   8) Telegram scheitert: nichts vermerkt, Abstand 30 min, dann 60 min; Erfolg setzt zurueck
--   9) Claim-Frist: zweiter Claim ohne finish sendet nicht doppelt; zweiter Claim zum selben Zeitpunkt zaehlt nicht
--  10) ungepaart: nichts, nichts vermerkt; nach dem Koppeln kommt der faellige Text
--  11) Rueckblick: Luecke > 23 h -> einmal; erster Lauf ueberhaupt keiner; zweite Luecke -> zweiter; zwei Luecken vor
--      dem Senden -> einer mit dem ersten Beginn und der laengsten Luecke
--  12) Mac-Schlaf: Luecke > gap_s zaehlt nicht; Gegenfall ohne Beat nach dem Aufwachen meldet; Uhr zurueck zaehlt 0
--  13) Config-Kreuzregel faellt auf Standardwerte zurueck; Owner ko bekommt ko-Texte; alte Merker werden aufgeraeumt
--  14) Docker: schlaegt die Schleife wieder, zaehlt check weiter, auch wenn die Entwarnung noch aussteht (nachts)
-- Texte: db_test seedet keinen Katalog -> Test-Texte fuer die gepruefte Komposition, sonst Assertions auf Keys.
BEGIN;
SET LOCAL TimeZone = 'Europe/Berlin';

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'heartbeat fixture', NULL, 'lazy', E'## fam',
        jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
          jsonb_build_object('person_id','hb_owner','first_name','Erika','last_name','Muster','role','owner',
                             'birth_date','1980-01-01','telegram_user_id',8201,'language','de','as_of','2026-06-10'),
          jsonb_build_object('person_id','hb_kid','first_name','Kim','last_name','Muster','role','child',
                             'birth_date','2015-01-01','telegram_user_id',8202,'language','de','as_of','2026-06-10')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;

DELETE FROM core.config WHERE category = 'watch';
INSERT INTO core.ui_languages (code, name, locale, ord) VALUES ('de', 'Deutsch', 'de-DE', 1), ('ko', '한국어', 'ko-KR', 3)
ON CONFLICT (code) DO NOTHING;
INSERT INTO core.ui_texts (key, lang, text, package) VALUES
  ('core.heartbeat.alert.loop.compose', 'de', 'L-C {dauer} {help_url}', 'core'),
  ('core.heartbeat.reminder',           'de', 'Erinnerung: {text}', 'core'),
  ('core.heartbeat.lookback',           'de', 'R {dauer}', 'core'),
  ('core.heartbeat.since.minute',       'de', 'einer Minute', 'core'),
  ('core.heartbeat.since.minutes',      'de', '{n} Minuten', 'core'),
  ('core.heartbeat.since.hours',        'de', '{n} Stunden', 'core'),
  ('core.heartbeat.since.day',          'de', 'einem Tag', 'core'),
  ('core.heartbeat.since.days',         'de', '{n} Tagen', 'core'),
  ('core.heartbeat.about.day',          'de', 'einen Tag', 'core'),
  ('core.heartbeat.about.hours',        'de', '{n} Stunden', 'core'),
  ('core.heartbeat.about.days',         'de', '{n} Tage', 'core'),
  ('core.heartbeat.alert.loop.compose', 'ko', 'KO {dauer}', 'core'),
  ('core.heartbeat.since.minutes',      'ko', '{n}분', 'core')
ON CONFLICT (key, lang) DO UPDATE SET text = excluded.text;

-- t(m) = Mittwoch 12:00 Haushaltszeit + m Minuten (Fenster 10-20 Uhr: t(0)..t(470) liegt am ersten Tag darin)
CREATE FUNCTION pg_temp.t(p_min int) RETURNS timestamptz LANGUAGE sql IMMUTABLE AS $f$
  SELECT timestamptz '2026-06-10 12:00:00+02' + make_interval(mins => p_min);
$f$;
-- frischer Zustand: alle drei Signale gesund zu t(p_start), Wächter zuletzt zu t(p_start) gelaufen
CREATE FUNCTION pg_temp.setup(p_runtime text, p_start int DEFAULT 0) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  DELETE FROM core.heartbeats;
  DELETE FROM core.heartbeat_observer;
  DELETE FROM core.notification_state WHERE source = 'heartbeat';
  DELETE FROM core.config WHERE category = 'watch';
  PERFORM core.fn_heartbeat_record(jsonb_build_object('signal','loop','status','ok','runtime',p_runtime,
            'help_url','https://example.org/hilfe','at',pg_temp.t(p_start)));
  PERFORM core.fn_heartbeat_record(jsonb_build_object('signal','check','status','ok','runtime',p_runtime,'at',pg_temp.t(p_start)));
  PERFORM core.fn_heartbeat_record(jsonb_build_object('signal','backup','status','current','runtime',p_runtime,'at',pg_temp.t(p_start)));
  UPDATE core.heartbeat_observer SET seen_at = pg_temp.t(p_start);
END $f$;
CREATE FUNCTION pg_temp.beat(p_sig text, p_status text, p_min int, p_extra jsonb DEFAULT '{}') RETURNS void LANGUAGE sql AS $f$
  SELECT core.fn_heartbeat_record(jsonb_build_object('signal',p_sig,'status',p_status,'at',pg_temp.t(p_min),
           'runtime',(SELECT runtime FROM core.heartbeat_observer)) || p_extra);
  SELECT NULL::void;
$f$;
CREATE FUNCTION pg_temp.cfg(p_key text, p_val int) RETURNS void LANGUAGE sql AS $f$
  INSERT INTO core.config (package, category, key, value) VALUES ('core', 'watch', p_key, p_val::text)
  ON CONFLICT (category, key) DO UPDATE SET value = excluded.value;
  SELECT NULL::void;
$f$;
-- ein Waechter-Lauf zu t(p_min): claim, dann jede Nachricht mit p_sent abschliessen; Rueckgabe: die Nachrichten
CREATE FUNCTION pg_temp.run(p_min int, p_sent boolean DEFAULT TRUE) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb; m jsonb;
BEGIN
  v := core.fn_heartbeat_claim(jsonb_build_object('at', pg_temp.t(p_min)));
  FOR m IN SELECT * FROM jsonb_array_elements(v->'messages') LOOP
    PERFORM core.fn_heartbeat_finish(jsonb_build_object('key', m->>'key', 'sent', p_sent, 'at', pg_temp.t(p_min)));
  END LOOP;
  RETURN v->'messages';
END $f$;
-- 'loop:1,check:clear,lookback' aus den Schluesseln (Vorfall-Epoch weggelassen)
CREATE FUNCTION pg_temp.kinds(p_msgs jsonb) RETURNS text LANGUAGE sql AS $f$
  SELECT COALESCE(string_agg(CASE WHEN m->>'key' LIKE 'lookback:%' THEN 'lookback'
                                  ELSE split_part(m->>'key', ':', 1) || ':' || split_part(m->>'key', ':', 3) END, ',' ORDER BY o), '')
    FROM jsonb_array_elements(COALESCE(p_msgs, '[]')) WITH ORDINALITY AS x(m, o);
$f$;
-- Laeufe alle 10 Minuten von p_from bis p_to; p_beat 'loop' (oder 'all' = alle drei Signale) schlaegt vor jedem Lauf.
-- Rueckgabe '20=loop:1;1460=loop:2;' (nur Laeufe mit Nachrichten)
CREATE FUNCTION pg_temp.ticks(p_from int, p_to int, p_beat text DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE m int; v text; v_out text := '';
BEGIN
  FOR m IN p_from..p_to BY 10 LOOP
    IF p_beat IN ('loop', 'all') THEN PERFORM pg_temp.beat('loop', 'ok', m); END IF;
    IF p_beat = 'all' THEN PERFORM pg_temp.beat('check', 'ok', m); PERFORM pg_temp.beat('backup', 'current', m); END IF;
    v := pg_temp.kinds(pg_temp.run(m));
    IF v <> '' THEN v_out := v_out || m || '=' || v || ';'; END IF;
  END LOOP;
  RETURN v_out;
END $f$;
CREATE FUNCTION pg_temp.row(p_sig text) RETURNS core.heartbeats LANGUAGE sql AS $f$
  SELECT * FROM core.heartbeats WHERE signal = p_sig;
$f$;

-- ===== 1) Docker: Schleife steht =====
DO $$
DECLARE v text; msgs jsonb;
BEGIN
  PERFORM pg_temp.setup('compose');
  v := pg_temp.ticks(10, 60, 'loop');
  IF v <> '' THEN RAISE EXCEPTION 'FAIL [1a] gesunde Schleife meldet: %', v; END IF;
  PERFORM pg_temp.setup('compose');
  PERFORM pg_temp.run(10);
  msgs := pg_temp.run(20);
  IF pg_temp.kinds(msgs) <> 'loop:1' THEN RAISE EXCEPTION 'FAIL [1b] Schleifen-Alarm nach 15 min beobachtet erwartet: %', msgs; END IF;
  IF msgs->0->>'text' <> 'L-C 20 Minuten https://example.org/hilfe' OR (msgs->0->>'chat_id')::bigint <> 8201 THEN
    RAISE EXCEPTION 'FAIL [1c] Text/Empfaenger: %', msgs->0; END IF;
  IF (pg_temp.row('loop')).alert_stage <> 1 THEN RAISE EXCEPTION 'FAIL [1d] Stufe 1 vermerkt'; END IF;
  v := pg_temp.ticks(30, 1450);
  IF v <> '' THEN RAISE EXCEPTION 'FAIL [1e] vor 24 h nichts, keine Folge-Alarme: %', v; END IF;
  msgs := pg_temp.run(1460);
  IF pg_temp.kinds(msgs) <> 'loop:2' OR msgs->0->>'text' <> 'Erinnerung: L-C einem Tag https://example.org/hilfe' THEN
    RAISE EXCEPTION 'FAIL [1e2] Stufe 2 nach 24 h als Erinnerung: %', msgs; END IF;
  msgs := core.fn_heartbeat_claim(jsonb_build_object('at', pg_temp.t(1460)))->'messages';
  IF jsonb_array_length(msgs) <> 0 THEN RAISE EXCEPTION 'FAIL [1f] Stufe 2 nur einmal: %', msgs; END IF;
  IF (pg_temp.row('check')).stale_observed_s > 600 OR (pg_temp.row('backup')).stale_observed_s > 600 THEN
    RAISE EXCEPTION 'FAIL [1g] check/backup zaehlen waehrend die Schleife steht: % / %',
      (pg_temp.row('check')).stale_observed_s, (pg_temp.row('backup')).stale_observed_s; END IF;
  v := pg_temp.ticks(1470, 11540);
  IF v <> '11540=loop:3;' THEN RAISE EXCEPTION 'FAIL [1h] Stufe 3 nach 7 Tagen: %', v; END IF;
  -- Erholung: genau eine Entwarnung, danach still (auch check/backup, obwohl ihr letzter Beat Tage alt ist)
  v := pg_temp.ticks(11550, 11600, 'loop');
  IF v <> '11550=loop:clear;' THEN RAISE EXCEPTION 'FAIL [1i] eine Entwarnung erwartet: %', v; END IF;
  IF (pg_temp.row('loop')).alert_stage <> 0 OR (pg_temp.row('loop')).incident_at IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [1j] Entwarnung schliesst den Vorfall'; END IF;
  RAISE NOTICE 'PASS [1] Docker: Schleifen-Alarm, +24 h, +7 Tage, Folgen still, eine Entwarnung';
END $$;

-- ===== 2) Flattern + neuer Vorfall =====
DO $$
DECLARE v text; k1 text; k2 text;
BEGIN
  PERFORM pg_temp.setup('compose');
  PERFORM pg_temp.run(10); k1 := pg_temp.run(20)->0->>'key';
  v := pg_temp.ticks(30, 60, 'loop');                       -- erholt bei 30 -> Entwarnung zu t(30)
  IF v <> '30=loop:clear;' THEN RAISE EXCEPTION 'FAIL [2a] Entwarnung: %', v; END IF;
  v := pg_temp.ticks(70, 1440);                             -- steht wieder ab 60; Sperre bis t(30)+24 h
  IF v <> '' THEN RAISE EXCEPTION 'FAIL [2b] innerhalb 24 h nach der Entwarnung kein neuer Alarm: %', v; END IF;
  v := pg_temp.ticks(1450, 1480);
  IF v <> '1470=loop:1;' THEN RAISE EXCEPTION 'FAIL [2c] neuer Alarm ab t(30)+24 h: %', v; END IF;
  SELECT key INTO k2 FROM core.notification_state WHERE source = 'heartbeat' AND key LIKE 'loop:%:1' AND key <> k1;
  IF k2 IS NULL THEN RAISE EXCEPTION 'FAIL [2d] neuer Vorfall braucht einen neuen Schluessel'; END IF;
  RAISE NOTICE 'PASS [2] Flatter-Sperre 24 h, neuer Vorfall-Schluessel';
END $$;

-- ===== 3) klassisch ohne Inhibit, Docker mit =====
DO $$
DECLARE v text;
BEGIN
  PERFORM pg_temp.setup('systemd');
  PERFORM pg_temp.cfg('check_s', 1200);
  v := pg_temp.ticks(10, 40);
  IF v <> '20=loop:1,check:1;' THEN RAISE EXCEPTION 'FAIL [3a] klassisch melden beide getrennt: %', v; END IF;
  PERFORM pg_temp.setup('compose');
  PERFORM pg_temp.cfg('check_s', 1200);
  v := pg_temp.ticks(10, 40);
  IF v <> '20=loop:1;' THEN RAISE EXCEPTION 'FAIL [3b] Docker: im selben Lauf nur die Schleife: %', v; END IF;
  -- klassischer Schleifen-Text ist ein eigener Key
  PERFORM pg_temp.setup('systemd');
  PERFORM pg_temp.run(10);
  IF pg_temp.run(20)->0->>'text' <> 'core.heartbeat.alert.loop.systemd' THEN RAISE EXCEPTION 'FAIL [3c] klassischer Text'; END IF;
  RAISE NOTICE 'PASS [3] klassisch getrennt, Docker Ursache vor Folge';
END $$;

-- ===== 4) busy =====
DO $$
DECLARE v text;
BEGIN
  PERFORM pg_temp.setup('compose');
  PERFORM pg_temp.cfg('check_s', 1200);
  PERFORM pg_temp.beat('loop', 'busy', 0, '{"busy_s":3600}');
  v := pg_temp.ticks(10, 50);
  IF v <> '' THEN RAISE EXCEPTION 'FAIL [4a] waehrend busy nichts (auch kein Pruef-Alarm): %', v; END IF;
  IF (pg_temp.row('check')).stale_observed_s <> 0 THEN RAISE EXCEPTION 'FAIL [4b] check zaehlt nicht waehrend busy'; END IF;
  DELETE FROM core.config WHERE category = 'watch';
  v := pg_temp.ticks(60, 90);
  IF v <> '80=loop:1;' THEN RAISE EXCEPTION 'FAIL [4c] nach busy_until zaehlt es ab busy_until: %', v; END IF;
  RAISE NOTICE 'PASS [4] busy haelt, danach ab busy_until';
END $$;

-- ===== 5) not_release / skipped =====
DO $$
DECLARE v text; msgs jsonb;
BEGIN
  PERFORM pg_temp.setup('compose');
  PERFORM pg_temp.beat('check', 'not_release', 0);
  v := pg_temp.ticks(10, 50, 'loop');
  IF v <> '' THEN RAISE EXCEPTION 'FAIL [5a] not_release erst nach 1 h: %', v; END IF;
  PERFORM pg_temp.beat('loop', 'ok', 60);
  msgs := pg_temp.run(60);
  IF pg_temp.kinds(msgs) <> 'check:1' OR msgs->0->>'text' <> 'core.heartbeat.alert.not_release' THEN
    RAISE EXCEPTION 'FAIL [5b] Text not_release nach 1 h: %', msgs; END IF;
  PERFORM pg_temp.beat('check', 'ok', 65);
  v := pg_temp.ticks(70, 90, 'loop');
  IF v <> '70=check:clear;' THEN RAISE EXCEPTION 'FAIL [5c] Entwarnung nach ok: %', v; END IF;
  PERFORM pg_temp.setup('compose');
  PERFORM pg_temp.beat('check', 'skipped', 0);
  v := pg_temp.ticks(10, 200, 'loop');
  IF v <> '' THEN RAISE EXCEPTION 'FAIL [5d] skipped bleibt still: %', v; END IF;
  RAISE NOTICE 'PASS [5] not_release nach 1 h, skipped still';
END $$;

-- ===== 6) Sicherung =====
DO $$
DECLARE v text;
BEGIN
  PERFORM pg_temp.setup('systemd');
  PERFORM pg_temp.cfg('backup_s', 1200);
  PERFORM pg_temp.beat('backup', 'attempted', 0, jsonb_build_object('notified_at', extract(epoch FROM pg_temp.t(-60))::bigint));
  v := pg_temp.ticks(10, 120, 'loop');
  IF v <> '' THEN RAISE EXCEPTION 'FAIL [6a] eigene Sicherungs-Meldung in 20 h -> still: %', v; END IF;
  PERFORM pg_temp.setup('systemd');
  PERFORM pg_temp.cfg('backup_s', 1200);
  PERFORM pg_temp.beat('backup', 'nofolder', 0);
  v := pg_temp.ticks(10, 120, 'loop');
  IF v <> '' THEN RAISE EXCEPTION 'FAIL [6b] nofolder still: %', v; END IF;
  PERFORM pg_temp.setup('systemd');
  PERFORM pg_temp.cfg('backup_s', 1200);
  v := pg_temp.ticks(10, 40, 'loop');
  IF v <> '20=backup:1;' THEN RAISE EXCEPTION 'FAIL [6c] Sicherungs-Alarm: %', v; END IF;
  PERFORM pg_temp.beat('backup', 'nofolder', 45);           -- Lauf ohne Ordner: es sichert weiter nichts
  v := pg_temp.ticks(50, 60, 'loop');
  IF v <> '' THEN RAISE EXCEPTION 'FAIL [6d] nofolder ist keine Entwarnung: %', v; END IF;
  PERFORM pg_temp.beat('backup', 'attempted', 65);
  v := pg_temp.ticks(70, 70, 'loop');
  IF v <> '70=backup:clear;' THEN RAISE EXCEPTION 'FAIL [6e] Entwarnung nach einem Versuch: %', v; END IF;
  RAISE NOTICE 'PASS [6] Sicherung: Ruhe, nofolder, Alarm, Entwarnung erst nach einem Versuch';
END $$;

-- ===== 7) Fenster =====
DO $$
DECLARE v text;
BEGIN
  PERFORM pg_temp.setup('compose', 470);                    -- 19:50, Schleife steht ab jetzt
  v := pg_temp.ticks(480, 1300);                            -- bis 9:40 am naechsten Tag
  IF v <> '' THEN RAISE EXCEPTION 'FAIL [7a] nachts nichts: %', v; END IF;
  v := pg_temp.ticks(1310, 1330);
  IF v <> '1320=loop:1;' THEN RAISE EXCEPTION 'FAIL [7b] zum Fensterbeginn 10:00: %', v; END IF;
  RAISE NOTICE 'PASS [7] Fenster';
END $$;

-- ===== 8) Telegram scheitert =====
DO $$
DECLARE v text;
BEGIN
  PERFORM pg_temp.setup('compose');
  PERFORM pg_temp.run(10);
  IF pg_temp.kinds(pg_temp.run(20, false)) <> 'loop:1' THEN RAISE EXCEPTION 'FAIL [8a] erster Versuch'; END IF;
  IF (pg_temp.row('loop')).alert_stage <> 0 THEN RAISE EXCEPTION 'FAIL [8b] gescheitert -> nichts vermerkt'; END IF;
  IF pg_temp.kinds(pg_temp.run(30)) <> '' OR pg_temp.kinds(pg_temp.run(40)) <> '' THEN RAISE EXCEPTION 'FAIL [8c] Abstand 30 min'; END IF;
  IF pg_temp.kinds(pg_temp.run(50, false)) <> 'loop:1' THEN RAISE EXCEPTION 'FAIL [8d] zweiter Versuch nach 30 min'; END IF;
  v := '';
  FOR i IN 6..10 LOOP v := v || pg_temp.kinds(pg_temp.run(i * 10)); END LOOP;
  IF v <> '' THEN RAISE EXCEPTION 'FAIL [8e] Abstand 60 min: %', v; END IF;
  IF pg_temp.kinds(pg_temp.run(110)) <> 'loop:1' THEN RAISE EXCEPTION 'FAIL [8f] dritter Versuch nach 60 min'; END IF;
  IF (pg_temp.row('loop')).alert_stage <> 1 OR (SELECT fail_count FROM core.heartbeat_observer) <> 0
     OR (SELECT retry_after FROM core.heartbeat_observer) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [8g] Erfolg vermerkt und setzt den Abstand zurueck'; END IF;
  RAISE NOTICE 'PASS [8] Sende-Abstand waechst, Erfolg setzt zurueck';
END $$;

-- ===== 9) Claim-Frist, kein Doppelzaehlen =====
DO $$
DECLARE a jsonb; b jsonb;
BEGIN
  PERFORM pg_temp.setup('compose');
  PERFORM core.fn_heartbeat_claim(jsonb_build_object('at', pg_temp.t(10)));
  PERFORM core.fn_heartbeat_claim(jsonb_build_object('at', pg_temp.t(10)));
  IF (pg_temp.row('loop')).stale_observed_s <> 600 THEN
    RAISE EXCEPTION 'FAIL [9a] zweiter Lauf zum selben Zeitpunkt zaehlt nicht: %', (pg_temp.row('loop')).stale_observed_s; END IF;
  a := core.fn_heartbeat_claim(jsonb_build_object('at', pg_temp.t(20)))->'messages';
  b := core.fn_heartbeat_claim(jsonb_build_object('at', pg_temp.t(20)))->'messages';
  IF pg_temp.kinds(a) <> 'loop:1' OR pg_temp.kinds(b) <> '' THEN RAISE EXCEPTION 'FAIL [9b] Frist verhindert Doppel-Senden: % / %', a, b; END IF;
  PERFORM core.fn_heartbeat_finish(jsonb_build_object('key', a->0->>'key', 'sent', true, 'at', pg_temp.t(20)));
  IF (pg_temp.row('loop')).alert_stage <> 1 THEN RAISE EXCEPTION 'FAIL [9c] finish vermerkt'; END IF;
  RAISE NOTICE 'PASS [9] Claim-Frist, kein Doppelzaehlen';
END $$;

-- ===== 10) ungepaart =====
DO $$
DECLARE v text;
BEGIN
  PERFORM pg_temp.setup('compose');
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons,0}', (metadata->'facts'->'persons'->0) - 'telegram_user_id')
   WHERE name = 'family';
  v := pg_temp.ticks(10, 40);
  IF v <> '' OR EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'heartbeat') OR (pg_temp.row('loop')).alert_stage <> 0 THEN
    RAISE EXCEPTION 'FAIL [10a] ungepaart: nichts senden, nichts vermerken (%)', v; END IF;
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons,0,telegram_user_id}', '8201') WHERE name = 'family';
  v := pg_temp.ticks(50, 50);
  IF v <> '50=loop:1;' THEN RAISE EXCEPTION 'FAIL [10b] nach dem Koppeln der faellige Text: %', v; END IF;
  RAISE NOTICE 'PASS [10] ungepaart still';
END $$;

-- ===== 11) Rueckblick =====
DO $$
DECLARE msgs jsonb; v text;
BEGIN
  PERFORM pg_temp.setup('compose');
  UPDATE core.heartbeat_observer SET seen_at = NULL;
  IF pg_temp.ticks(1500, 1500, 'all') <> '' THEN RAISE EXCEPTION 'FAIL [11a] erster Lauf ueberhaupt: kein R'; END IF;
  PERFORM pg_temp.beat('loop', 'ok', 2940);                 -- 13:00 am Tag darauf: Luecke 24 h
  msgs := pg_temp.run(2940);
  IF pg_temp.kinds(msgs) <> 'lookback' OR msgs->0->>'text' <> 'R einen Tag' THEN RAISE EXCEPTION 'FAIL [11b] Rueckblick nach 24 h: %', msgs; END IF;
  v := pg_temp.ticks(2950, 2970, 'all');
  IF v <> '' THEN RAISE EXCEPTION 'FAIL [11c] R nur einmal: %', v; END IF;
  IF pg_temp.ticks(4420, 4420, 'all') <> '4420=lookback;' THEN RAISE EXCEPTION 'FAIL [11d] zweite Luecke -> zweites R'; END IF;
  -- Luecke endet nachts (20:40): R erst zum Fensterbeginn 10:00
  IF pg_temp.ticks(6280, 6280, 'all') <> '' THEN RAISE EXCEPTION 'FAIL [11e] Rueckblick nachts nicht'; END IF;
  v := pg_temp.ticks(6290, 7100, 'all');
  IF v <> '7080=lookback;' THEN RAISE EXCEPTION 'FAIL [11f] R einmal zum Fensterbeginn: %', v; END IF;
  -- zwei Luecken enden nachts, bevor der Rueckblick raus ist: einer, Beginn der ersten, Dauer der laengsten
  IF pg_temp.ticks(10620, 10620, 'all') <> '' THEN RAISE EXCEPTION 'FAIL [11g] erste Luecke (gut 2 Tage) endet 21:00'; END IF;
  IF pg_temp.ticks(12120, 12120, 'all') <> '' THEN RAISE EXCEPTION 'FAIL [11h] zweite Luecke (25 h) endet 22:00'; END IF;
  IF pg_temp.ticks(12130, 12830, 'all') <> '' THEN RAISE EXCEPTION 'FAIL [11i] nachts nichts'; END IF;
  PERFORM pg_temp.beat('loop', 'ok', 12840); PERFORM pg_temp.beat('check', 'ok', 12840); PERFORM pg_temp.beat('backup', 'current', 12840);
  msgs := pg_temp.run(12840);
  IF pg_temp.kinds(msgs) <> 'lookback' OR msgs->0->>'key' <> 'lookback:' || floor(extract(epoch FROM pg_temp.t(7100)))::bigint
     OR msgs->0->>'text' <> 'R 2 Tage' THEN RAISE EXCEPTION 'FAIL [11j] ein Rueckblick fuer beide Luecken: %', msgs; END IF;
  RAISE NOTICE 'PASS [11] Rueckblick';
END $$;

-- ===== 12) Mac-Schlaf, Uhr zurueck =====
DO $$
DECLARE v text;
BEGIN
  PERFORM pg_temp.setup('compose');
  PERFORM pg_temp.run(300);                                 -- 5 h Schlaf: zaehlt nicht
  PERFORM pg_temp.beat('loop', 'ok', 301);
  v := pg_temp.ticks(310, 330, 'loop');
  IF v <> '' OR (pg_temp.row('loop')).stale_observed_s > 60 THEN RAISE EXCEPTION 'FAIL [12a] Schlaf zaehlt nicht: %', v; END IF;
  PERFORM pg_temp.setup('compose');
  PERFORM pg_temp.run(300);
  v := pg_temp.ticks(310, 330);                             -- nach dem Aufwachen kein Beat -> zaehlt wieder
  IF v <> '320=loop:1;' THEN RAISE EXCEPTION 'FAIL [12b] Gegenfall meldet: %', v; END IF;
  PERFORM pg_temp.setup('compose');
  PERFORM pg_temp.run(10);
  PERFORM pg_temp.run(5);                                   -- Uhr springt zurueck
  IF (pg_temp.row('loop')).stale_observed_s > 600 THEN RAISE EXCEPTION 'FAIL [12c] Uhr zurueck zaehlt 0'; END IF;
  RAISE NOTICE 'PASS [12] Schlaf zaehlt nicht, Gegenfall meldet, Uhr zurueck';
END $$;

-- ===== 13) Kreuzregel, ko, Aufraeumen =====
DO $$
DECLARE msgs jsonb;
BEGIN
  PERFORM pg_temp.setup('compose');
  PERFORM pg_temp.cfg('gap_s', 300);                        -- gap_s <= step_cap_s -> Standardwerte
  PERFORM pg_temp.run(10);
  IF (pg_temp.row('loop')).stale_observed_s <> 600 THEN RAISE EXCEPTION 'FAIL [13a] Kreuzregel faellt auf Standard'; END IF;
  PERFORM pg_temp.setup('compose');
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons,0,language}', '"ko"') WHERE name = 'family';
  PERFORM pg_temp.run(10);
  msgs := pg_temp.run(20);
  IF msgs->0->>'text' <> 'KO 20분' THEN RAISE EXCEPTION 'FAIL [13b] Owner ko: %', msgs; END IF;
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons,0,language}', '"de"') WHERE name = 'family';
  INSERT INTO core.notification_state (source, key, state, last_fired_at) VALUES ('heartbeat', 'loop:1:1', 'fired', now() - interval '61 days');
  PERFORM pg_temp.run(30);
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'heartbeat' AND key = 'loop:1:1') THEN
    RAISE EXCEPTION 'FAIL [13c] alte Merker aufgeraeumt'; END IF;
  IF core.fn_heartbeat_duration(90, 'since', 'de') <> 'einer Minute' OR core.fn_heartbeat_duration(150, 'since', 'de') <> '2 Minuten' THEN
    RAISE EXCEPTION 'FAIL [13d] Einzahl Minute: % / %', core.fn_heartbeat_duration(90, 'since', 'de'), core.fn_heartbeat_duration(150, 'since', 'de'); END IF;
  RAISE NOTICE 'PASS [13] Kreuzregel, ko, Aufraeumen, Dauer-Einzahl';
END $$;

-- ===== 14) Docker: Schleife schlaegt wieder, Entwarnung steht noch aus =====
DO $$
DECLARE v text;
BEGIN
  PERFORM pg_temp.setup('compose', 450);                    -- 19:30, Schleife steht ab jetzt
  PERFORM pg_temp.cfg('check_s', 3000);
  v := pg_temp.ticks(460, 470);
  IF v <> '470=loop:1;' THEN RAISE EXCEPTION 'FAIL [14a] Schleifen-Alarm 19:50: %', v; END IF;
  v := pg_temp.ticks(480, 530, 'loop');                     -- ab 20:00 schlaegt sie wieder, Entwarnung erst morgens
  IF v <> '' OR (pg_temp.row('loop')).alert_stage <> 1 THEN RAISE EXCEPTION 'FAIL [14b] nachts keine Entwarnung: %', v; END IF;
  IF (pg_temp.row('check')).stale_observed_s <= 600 THEN
    RAISE EXCEPTION 'FAIL [14c] check zaehlt wieder, sobald die Schleife schlaegt: %', (pg_temp.row('check')).stale_observed_s; END IF;
  RAISE NOTICE 'PASS [14] Ursache vor Folge endet mit dem ersten Beat, nicht mit dem Senden der Entwarnung';
END $$;

ROLLBACK;
