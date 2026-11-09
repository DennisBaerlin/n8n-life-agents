-- tests/db/finance/test_fn_handle_account_emoji_cb.sql
-- Knopf-Tipp: speichert nur fuer den Owner aus der Liste, Blaettern schreibt nichts, alte Knoepfe harmlos. Picker-Rollenpruefung.
BEGIN;
CREATE FUNCTION pg_temp.cb(d text, chat text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT finance.fn_handle_account_emoji_cb(jsonb_build_object('data', d, 'chat_id', chat, 'chat_type', 'private'));
$$;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'em', NULL, 'lazy', 'x', jsonb_build_object('managed_by', 'agent', 'facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','__em_o__','first_name','Olli','last_name','Muster','role','owner','birth_date','1980-01-01','telegram_user_id',7701,'as_of','2026-10-23'),
    jsonb_build_object('person_id','__em_p__','first_name','Petra','last_name','Muster','role','partner','birth_date','1982-01-01','telegram_user_id',7702,'as_of','2026-10-23')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;

DO $$
DECLARE v_id int; r jsonb; v_closed int;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('Probebank Giro','cash','EUR','active') RETURNING id INTO v_id;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('Probe Alt','cash','EUR','closed') RETURNING id INTO v_closed;

  -- Treffer
  r := pg_temp.cb('acem:' || v_id || ':🐷', '7701');
  IF NOT (r->>'ok')::boolean OR NULLIF(r->>'toast','') IS NULL OR (SELECT emoji FROM finance.accounts WHERE id = v_id) <> '🐷' THEN RAISE EXCEPTION 'FAIL [Treffer]: %', r; END IF;

  -- Nicht-Owner, fremdes Zeichen, leeres Zeichen, kaputte Form: nichts geschrieben, immer ein Toast
  r := pg_temp.cb('acem:' || v_id || ':🏠', '7702');
  IF (r->>'ok')::boolean OR r->>'reason' <> 'not_allowed' OR NULLIF(r->>'toast','') IS NULL THEN RAISE EXCEPTION 'FAIL [Nicht-Owner]: %', r; END IF;
  r := pg_temp.cb('acem:' || v_id || ':🦄', '7701');
  IF (r->>'ok')::boolean OR NULLIF(r->>'toast','') IS NULL THEN RAISE EXCEPTION 'FAIL [fremd]: %', r; END IF;
  r := pg_temp.cb('acem:' || v_id || ':', '7701');
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [leer]: %', r; END IF;
  r := pg_temp.cb('acem:abc:🐷', '7701');
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [Id keine Zahl]: %', r; END IF;
  r := pg_temp.cb('acem:' || v_id || ':🐷:x', '7701');
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [zu viele Teile]: %', r; END IF;
  IF (SELECT emoji FROM finance.accounts WHERE id = v_id) <> '🐷' THEN RAISE EXCEPTION 'FAIL [nichts geschrieben]'; END IF;

  -- Blaettern: Karte + Toast, kein Write; ungueltige Seite
  UPDATE finance.accounts SET emoji = NULL WHERE id = v_id;
  r := pg_temp.cb('acem:' || v_id || ':more:1', '7701');
  IF NOT (r->>'ok')::boolean OR NULLIF(r->>'toast','') IS NULL OR jsonb_array_length(r->'choice_card'->'options') <> 6 OR r->'choice_card'->'more'->>'data' <> 'acem:' || v_id || ':more:2' THEN RAISE EXCEPTION 'FAIL [Blaettern]: %', r; END IF;
  IF (SELECT emoji FROM finance.accounts WHERE id = v_id) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [Blaettern schreibt nicht]'; END IF;
  r := pg_temp.cb('acem:' || v_id || ':more:4', '7701');
  IF (r->>'ok')::boolean OR r ? 'choice_card' THEN RAISE EXCEPTION 'FAIL [Seite 4]: %', r; END IF;
  r := pg_temp.cb('acem:' || v_id || ':more:1', '7702');
  IF (r->>'ok')::boolean OR r ? 'choice_card' THEN RAISE EXCEPTION 'FAIL [Blaettern Nicht-Owner]: %', r; END IF;

  -- Geschlossen, geloescht
  r := pg_temp.cb('acem:' || v_closed || ':🐷', '7701');
  IF (r->>'ok')::boolean OR NULLIF(r->>'toast','') IS NULL OR (SELECT emoji FROM finance.accounts WHERE id = v_closed) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [geschlossen]: %', r; END IF;
  r := pg_temp.cb('acem:' || v_closed || ':more:1', '7701');
  IF (r->>'ok')::boolean OR r ? 'choice_card' THEN RAISE EXCEPTION 'FAIL [geschlossen blaettern]: %', r; END IF;
  r := pg_temp.cb('acem:999999:🐷', '7701');
  IF (r->>'ok')::boolean OR NULLIF(r->>'toast','') IS NULL THEN RAISE EXCEPTION 'FAIL [geloescht]: %', r; END IF;

  -- Picker: Owner bekommt Karte, Mitglied die Liste als Grund, Unbekannte nichts
  r := finance.fn_account_emoji_picker('7701', v_id);
  IF NOT (r->>'ok')::boolean OR jsonb_array_length(r->'card'->'options') <> 6 THEN RAISE EXCEPTION 'FAIL [Picker Owner]: %', r; END IF;
  r := finance.fn_account_emoji_picker('7702', v_id);
  IF (r->>'ok')::boolean OR r ? 'card' OR position('🐷' IN r->>'reason') = 0 THEN RAISE EXCEPTION 'FAIL [Picker Mitglied]: %', r; END IF;
  r := finance.fn_account_emoji_picker('1', v_id);
  IF (r->>'ok')::boolean OR r ? 'card' THEN RAISE EXCEPTION 'FAIL [Picker Unbekannt]: %', r; END IF;
END $$;
ROLLBACK;
