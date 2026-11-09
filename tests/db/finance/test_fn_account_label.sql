-- tests/db/finance/test_fn_account_label.sql
-- Konto-Zeichen: feste Liste, Ersatz je Kontoart, Anzeige-Label, CHECK. Alle Namen erfunden.
BEGIN;
DO $$
DECLARE v_list text[] := finance.fn_account_emoji_choices(); e text; t finance.account_type; v_id int; v_id2 int;
BEGIN
  IF cardinality(v_list) <> 24 THEN RAISE EXCEPTION 'FAIL [24 Eintraege]: %', cardinality(v_list); END IF;
  IF (SELECT count(DISTINCT x) FROM unnest(v_list) x) <> 24 THEN RAISE EXCEPTION 'FAIL [Dubletten]'; END IF;
  FOREACH e IN ARRAY v_list LOOP
    IF char_length(e) <> 1 THEN RAISE EXCEPTION 'FAIL [ein Code-Punkt]: %', e; END IF;
  END LOOP;

  -- Ersatz je Kontoart: einzeln, jede Enum-Auspraegung belegt und in der Liste
  IF finance.fn_account_emoji(NULL, 'cash') <> '🏦' THEN RAISE EXCEPTION 'FAIL [cash]'; END IF;
  IF finance.fn_account_emoji(NULL, 'p2p') <> '🤝' THEN RAISE EXCEPTION 'FAIL [p2p]'; END IF;
  IF finance.fn_account_emoji(NULL, 'stocks_depot') <> '📈' THEN RAISE EXCEPTION 'FAIL [stocks_depot]'; END IF;
  IF finance.fn_account_emoji(NULL, 'crypto_depot') <> '💎' THEN RAISE EXCEPTION 'FAIL [crypto_depot]'; END IF;
  IF finance.fn_account_emoji(NULL, 'fixed_deposit') <> '🔒' THEN RAISE EXCEPTION 'FAIL [fixed_deposit]'; END IF;
  IF finance.fn_account_emoji(NULL, 'loan') <> '🧾' THEN RAISE EXCEPTION 'FAIL [loan]'; END IF;
  FOREACH t IN ARRAY enum_range(NULL::finance.account_type) LOOP
    IF finance.fn_account_emoji(NULL, t) IS NULL OR NOT finance.fn_account_emoji(NULL, t) = ANY(v_list) THEN
      RAISE EXCEPTION 'FAIL [Ersatz in Liste]: %', t; END IF;
  END LOOP;
  IF finance.fn_account_emoji('🐷', 'cash') <> '🐷' THEN RAISE EXCEPTION 'FAIL [eigene Wahl schlaegt Ersatz]'; END IF;

  -- Label
  IF finance.fn_account_label(NULL, 'cash', 'Lindenbank Giro') <> '🏦 Lindenbank Giro' THEN RAISE EXCEPTION 'FAIL [Label Ersatz]'; END IF;
  IF finance.fn_account_label('🐷', 'cash', 'Lindenbank Giro') <> '🐷 Lindenbank Giro' THEN RAISE EXCEPTION 'FAIL [Label Wahl]'; END IF;
  IF finance.fn_account_label(NULL, 'cash', '🏦 Altkonto') <> '🏦 Altkonto' THEN RAISE EXCEPTION 'FAIL [kein doppeltes Zeichen]'; END IF;
  IF finance.fn_account_label('🐷', 'cash', '🏠 Altkonto') <> '🏠 Altkonto' THEN RAISE EXCEPTION 'FAIL [Bestandsname mit fremdem Zeichen]'; END IF;

  -- CHECK: fremdes Zeichen und VS16 abgelehnt, gleiches Zeichen an zwei Konten erlaubt
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__em_a__','cash','EUR','active') RETURNING id INTO v_id;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__em_b__','cash','EUR','active') RETURNING id INTO v_id2;
  UPDATE finance.accounts SET emoji = '🐷' WHERE id IN (v_id, v_id2);
  BEGIN
    UPDATE finance.accounts SET emoji = '🦄' WHERE id = v_id;
    RAISE EXCEPTION 'FAIL [CHECK fremdes Zeichen]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    UPDATE finance.accounts SET emoji = '🐷' || chr(65039) WHERE id = v_id;
    RAISE EXCEPTION 'FAIL [CHECK VS16]';
  EXCEPTION WHEN check_violation THEN NULL; END;

  -- Sicht: name unveraendert, label dazu
  IF (SELECT name FROM finance.account_overview WHERE id = v_id) <> '__em_a__' THEN RAISE EXCEPTION 'FAIL [view name]'; END IF;
  IF (SELECT label FROM finance.account_overview WHERE id = v_id) <> '🐷 __em_a__' THEN RAISE EXCEPTION 'FAIL [view label]'; END IF;
END $$;
ROLLBACK;
