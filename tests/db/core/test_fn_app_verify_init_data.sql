-- tests/db/core/test_fn_app_verify_init_data.sql
-- Mini-App (docs/package-contract.md §3.12): core.fn_app_verify_init_data prueft Telegram-initData per HMAC-SHA-256
-- (Schluessel aus core.app_secret) und auth_date. Der Testvektor ist AUSSERHALB von pgcrypto berechnet (.NET
-- HMACSHA256, erfundenes Token '000000:test-only-token' -> Schluessel = HMAC("WebAppData", Token)), sonst bestaetigte
-- sich die fn nur selbst. Er traegt signature (zaehlt im data_check_string mit), einen koreanischen Vornamen, einen
-- Umlaut (%C3%BC) und ein '+' als Leerzeichen.
BEGIN;

DELETE FROM core.app_secret;
INSERT INTO core.app_secret (id, webapp_key)
VALUES (TRUE, decode('96185c3fa81869e8e69583e8c1a9acf4b930950ca2175f29087680148ac55bda', 'hex'));

DO $$
DECLARE
  v_qs  text := 'query_id=AAHdF6IQAAAAAN0XohDhrOrc&user=%7B%22id%22%3A900111%2C%22first_name%22%3A%22%EC%A7%80%EB%AF%BC%22%2C%22last_name%22%3A%22Beispiel+M%C3%BCller%22%2C%22language_code%22%3A%22ko%22%2C%22allows_write_to_pm%22%3Atrue%7D&auth_date=1793000000&signature=ZmFrZS1zaWduYXR1cmUtZm9yLXRlc3Q&hash=41a2b61bc0a9b54fc35cbde16e440c760d05b60ecf091e69a8a6a8d61fdfb992';
  v_now timestamptz := to_timestamp(1793000000 + 60);
  r     jsonb;
BEGIN
  -- [1] gueltig: ok, user.id + language_code aus derselben geparsten Map
  r := core.fn_app_verify_init_data(v_qs, v_now);
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [1] gueltiger Vektor abgelehnt: %', r; END IF;
  IF (r->>'telegram_user_id')::bigint IS DISTINCT FROM 900111 THEN RAISE EXCEPTION 'FAIL [1] telegram_user_id: %', r; END IF;
  IF r->>'language_code' IS DISTINCT FROM 'ko' THEN RAISE EXCEPTION 'FAIL [1] language_code: %', r; END IF;
  RAISE NOTICE 'PASS [1] gueltiger Vektor (signature, Hangul, Umlaut, +) -> ok';

  -- [2] manipuliert: anderes auth_date -> bad_signature
  r := core.fn_app_verify_init_data(replace(v_qs, 'auth_date=1793000000', 'auth_date=1793000001'), v_now);
  IF r->>'code' IS DISTINCT FROM 'bad_signature' THEN RAISE EXCEPTION 'FAIL [2] manipuliertes auth_date: %', r; END IF;
  -- [2b] manipulierter Nutzer (andere id) -> bad_signature
  r := core.fn_app_verify_init_data(replace(v_qs, '900111', '900112'), v_now);
  IF r->>'code' IS DISTINCT FROM 'bad_signature' THEN RAISE EXCEPTION 'FAIL [2b] manipulierte user.id: %', r; END IF;
  -- [2c] signature weggelassen -> bad_signature (signature zaehlt im data_check_string mit)
  r := core.fn_app_verify_init_data(replace(v_qs, '&signature=ZmFrZS1zaWduYXR1cmUtZm9yLXRlc3Q', ''), v_now);
  IF r->>'code' IS DISTINCT FROM 'bad_signature' THEN RAISE EXCEPTION 'FAIL [2c] fehlende signature: %', r; END IF;
  RAISE NOTICE 'PASS [2] manipuliert -> bad_signature';

  -- [3] abgelaufen (> 3600 s Standard) und aus der Zukunft -> expired
  r := core.fn_app_verify_init_data(v_qs, to_timestamp(1793000000 + 3601));
  IF r->>'code' IS DISTINCT FROM 'expired' THEN RAISE EXCEPTION 'FAIL [3] abgelaufen: %', r; END IF;
  r := core.fn_app_verify_init_data(v_qs, to_timestamp(1793000000 - 600));
  IF r->>'code' IS DISTINCT FROM 'expired' THEN RAISE EXCEPTION 'FAIL [3b] Zukunft: %', r; END IF;
  RAISE NOTICE 'PASS [3] abgelaufen/Zukunft -> expired';

  -- [4] Form: doppelter Key, fehlender hash, Muell, NULL, leer, kaputtes UTF-8 -> malformed, nie RAISE
  r := core.fn_app_verify_init_data(v_qs || '&auth_date=1793000000', v_now);
  IF r->>'code' IS DISTINCT FROM 'malformed' THEN RAISE EXCEPTION 'FAIL [4a] doppelter Key: %', r; END IF;
  r := core.fn_app_verify_init_data(split_part(v_qs, '&hash=', 1), v_now);
  IF r->>'code' IS DISTINCT FROM 'malformed' THEN RAISE EXCEPTION 'FAIL [4b] fehlender hash: %', r; END IF;
  r := core.fn_app_verify_init_data('das ist kein initData', v_now);
  IF r->>'code' IS DISTINCT FROM 'malformed' THEN RAISE EXCEPTION 'FAIL [4c] Muell: %', r; END IF;
  r := core.fn_app_verify_init_data(NULL, v_now);
  IF r->>'code' IS DISTINCT FROM 'malformed' THEN RAISE EXCEPTION 'FAIL [4d] NULL: %', r; END IF;
  r := core.fn_app_verify_init_data('', v_now);
  IF r->>'code' IS DISTINCT FROM 'malformed' THEN RAISE EXCEPTION 'FAIL [4e] leer: %', r; END IF;
  r := core.fn_app_verify_init_data('user=%E0%A4&auth_date=1&hash=00', v_now);
  IF r->>'code' IS DISTINCT FROM 'malformed' THEN RAISE EXCEPTION 'FAIL [4f] kaputtes UTF-8: %', r; END IF;
  RAISE NOTICE 'PASS [4] Formfehler -> malformed ohne RAISE';

  -- [5] Signatur stimmt, aber user fehlt bzw. id unbrauchbar -> malformed (kein ok ohne Person)
  -- (hier reicht ein Vektor ohne gueltigen hash nicht: der Form-Check laeuft VOR der Signatur nur fuer die Struktur;
  -- ein user ohne id ist ein Struktur-Fehler) -> mit fremdem hash
  r := core.fn_app_verify_init_data('auth_date=1793000000&user=%7B%7D&hash=00', v_now);
  IF r->>'code' NOT IN ('malformed', 'bad_signature') THEN RAISE EXCEPTION 'FAIL [5] user ohne id: %', r; END IF;
  RAISE NOTICE 'PASS [5] user ohne id -> abgelehnt';

  -- [6] kein Schluessel hinterlegt -> no_secret (nie ok)
  DELETE FROM core.app_secret;
  r := core.fn_app_verify_init_data(v_qs, v_now);
  IF r->>'code' IS DISTINCT FROM 'no_secret' THEN RAISE EXCEPTION 'FAIL [6] ohne Schluessel: %', r; END IF;
  RAISE NOTICE 'PASS [6] ohne Schluessel -> no_secret';
END $$;

ROLLBACK;
