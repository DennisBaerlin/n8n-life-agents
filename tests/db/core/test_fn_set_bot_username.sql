-- tests/db/core/test_fn_set_bot_username.sql
-- core.fn_set_bot_username: Platzhalter und Namenswechsel, Ablehnungen als Daten, Seed ueberschreibt den Namen nicht;
-- core.fn_app_bot_username liefert nur einen gueltigen, nicht-Platzhalter-Namen.
BEGIN;

DO $$
DECLARE
  r jsonb; v text; v_ctid tid; v_ctid2 tid;
BEGIN
  UPDATE core.config SET value = 'your_bot', default_value = 'your_bot' WHERE category = 'telegram' AND key = 'bot_username';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: Zeile telegram.bot_username fehlt im Seed'; END IF;

  -- Platzhalter wird ersetzt
  r := core.fn_set_bot_username('muster_haushalt_bot');
  SELECT value INTO v FROM core.config WHERE category = 'telegram' AND key = 'bot_username';
  IF v IS DISTINCT FROM 'muster_haushalt_bot' OR (r->>'changed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: Platzhalter nicht ersetzt: % / %', v, r; END IF;

  -- Gleicher Name: kein Schreibvorgang (Zweitlauf = no-op)
  SELECT ctid INTO v_ctid FROM core.config WHERE category = 'telegram' AND key = 'bot_username';
  r := core.fn_set_bot_username('muster_haushalt_bot');
  SELECT ctid INTO v_ctid2 FROM core.config WHERE category = 'telegram' AND key = 'bot_username';
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'changed')::boolean IS DISTINCT FROM false OR v_ctid <> v_ctid2 THEN
    RAISE EXCEPTION 'FAIL: Zweitlauf: % (% -> %)', r, v_ctid, v_ctid2; END IF;

  -- Der Name folgt dem Token: ein neuer Bot ersetzt auch einen gesetzten Wert
  r := core.fn_set_bot_username('anderer_muster_bot');
  SELECT value INTO v FROM core.config WHERE category = 'telegram' AND key = 'bot_username';
  IF v IS DISTINCT FROM 'anderer_muster_bot' THEN RAISE EXCEPTION 'FAIL: neuer Bot nicht uebernommen: %', v; END IF;

  -- Ungueltig: Daten-Ablehnung, Wert bleibt
  r := core.fn_set_bot_username('ab');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'code' IS DISTINCT FROM 'invalid_name' THEN
    RAISE EXCEPTION 'FAIL: zu kurz: %', r; END IF;
  r := core.fn_set_bot_username(E'muster_bot\n');
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL: Zeilenumbruch: %', r; END IF;
  r := core.fn_set_bot_username('muster bot');
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL: Leerzeichen: %', r; END IF;
  r := core.fn_set_bot_username(NULL);
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL: NULL: %', r; END IF;
  SELECT value INTO v FROM core.config WHERE category = 'telegram' AND key = 'bot_username';
  IF v IS DISTINCT FROM 'anderer_muster_bot' THEN RAISE EXCEPTION 'FAIL: Ablehnung hat geschrieben: %', v; END IF;

  -- Ein Update-Seed setzt den eingetragenen Namen nicht zurueck (Wert ungleich Default)
  PERFORM core.fn_config_seed('{"category":"telegram","key":"bot_username","value":"your_bot"}');
  SELECT value INTO v FROM core.config WHERE category = 'telegram' AND key = 'bot_username';
  IF v IS DISTINCT FROM 'anderer_muster_bot' THEN RAISE EXCEPTION 'FAIL: Seed hat den Namen ueberschrieben: %', v; END IF;

  -- Fehlende Zeile: Daten-Antwort, kein Abbruch
  DELETE FROM core.config WHERE category = 'telegram' AND key = 'bot_username';
  r := core.fn_set_bot_username('muster_haushalt_bot');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'code' IS DISTINCT FROM 'no_row' THEN
    RAISE EXCEPTION 'FAIL: fehlende Zeile: %', r; END IF;
END $$;

ROLLBACK;

-- Die Mini-App bekommt den Bot-Namen nur, wenn er echt ist (nicht der Platzhalter)
BEGIN;
DO $$
DECLARE v jsonb;
BEGIN
  UPDATE core.config SET value = 'your_bot', default_value = 'your_bot' WHERE category = 'telegram' AND key = 'bot_username';
  IF core.fn_app_bot_username() IS NOT NULL THEN RAISE EXCEPTION 'FAIL: Platzhalter gilt als Name'; END IF;
  UPDATE core.config SET value = 'muster_haushalt_bot' WHERE category = 'telegram' AND key = 'bot_username';
  IF core.fn_app_bot_username() IS DISTINCT FROM 'muster_haushalt_bot' THEN RAISE EXCEPTION 'FAIL: Name fehlt'; END IF;
  UPDATE core.config SET value = 'kaputt name' WHERE category = 'telegram' AND key = 'bot_username';
  IF core.fn_app_bot_username() IS NOT NULL THEN RAISE EXCEPTION 'FAIL: ungueltiger Name'; END IF;
END $$;
ROLLBACK;
