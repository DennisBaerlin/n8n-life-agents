-- tests/db/finance/test_fn_set_account.sql
-- Testet fn_set_account: partielles Update (nur uebergebene Felder), not-found-RAISE
BEGIN;

DO $$
DECLARE
  v_res    JSONB;
  v_id     INT;
  v_name   TEXT;
  v_bank   TEXT;
  v_person TEXT;
  v_notes  TEXT;
BEGIN

  -- Setup: Konto mit Bank (owner_person_id startet NULL = Haushalt; WS-4: kein Freitext-Inhaber mehr)
  SELECT finance.fn_create_account(
    '{"name":"__test_set_acct__","account_type":"cash","bank":"AltBank","currency":"EUR"}'::jsonb
  ) INTO v_res;
  v_id := (v_res->>'account_id')::int;

  -- TEST 1: nur bank + notes aendern -> name/owner_person_id bleiben unveraendert (NULL)
  SELECT finance.fn_set_account(jsonb_build_object(
    'account_id', v_id, 'bank', 'NeuBank', 'notes', 'umgezogen'
  )) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL set_account [ok]: %', v_res;
  END IF;

  SELECT name, bank, owner_person_id, notes INTO v_name, v_bank, v_person, v_notes
  FROM finance.accounts WHERE id = v_id;
  IF v_bank IS DISTINCT FROM 'NeuBank' THEN
    RAISE EXCEPTION 'FAIL set_account [bank]: erwartet NeuBank, got %', v_bank;
  END IF;
  IF v_notes IS DISTINCT FROM 'umgezogen' THEN
    RAISE EXCEPTION 'FAIL set_account [notes]: erwartet umgezogen, got %', v_notes;
  END IF;
  IF v_name IS DISTINCT FROM '__test_set_acct__' OR v_person IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL set_account [partial]: name/owner_person duerfen nicht geaendert sein, got name=% owner=%', v_name, v_person;
  END IF;
  RAISE NOTICE 'PASS set_account [partielles Update: bank+notes geaendert, name/owner_person unveraendert NULL]';

  -- TEST 2 (WS-4): owner_person_id setzen (Nachtag Bestand) -> bank bleibt NeuBank
  INSERT INTO agent.persons (person_id, full_name, role)
  VALUES ('__test_setacc_p', 'Test Person', 'partner') ON CONFLICT (person_id) DO NOTHING;
  SELECT finance.fn_set_account(jsonb_build_object('account_id', v_id, 'owner_person_id', '__test_setacc_p')) INTO v_res;
  SELECT bank, owner_person_id INTO v_bank, v_person FROM finance.accounts WHERE id = v_id;
  IF v_person IS DISTINCT FROM '__test_setacc_p' OR v_bank IS DISTINCT FROM 'NeuBank' THEN
    RAISE EXCEPTION 'FAIL set_account [owner_person]: owner=% bank=%', v_person, v_bank;
  END IF;
  -- leeres Feld = unveraendert (Un-Tag -> BACKLOG): erneutes set ohne owner_person_id laesst Slug bestehen
  SELECT finance.fn_set_account(jsonb_build_object('account_id', v_id, 'notes', 'x')) INTO v_res;
  SELECT owner_person_id INTO v_person FROM finance.accounts WHERE id = v_id;
  IF v_person IS DISTINCT FROM '__test_setacc_p' THEN
    RAISE EXCEPTION 'FAIL set_account [owner_person stabil]: leeres Feld haette unveraendert lassen muessen, got %', v_person;
  END IF;
  RAISE NOTICE 'PASS set_account [owner_person_id gesetzt + leer=unveraendert, bank stabil]';

  -- TEST 3 (WS-0b estate): ownership + transmortale Bankvollmacht setzen -> persistiert, partiell.
  SELECT finance.fn_set_account(jsonb_build_object(
    'account_id', v_id, 'ownership', 'joint_and', 'has_transmortal_poa', 'true'
  )) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL set_account [estate ok]: %', v_res;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM finance.accounts
    WHERE id = v_id AND ownership = 'joint_and' AND has_transmortal_poa = true
  ) THEN
    RAISE EXCEPTION 'FAIL set_account [estate-Felder]: ownership/has_transmortal_poa nicht gesetzt';
  END IF;
  -- leeres Feld = unveraendert (ownership bleibt joint_and, wenn nicht mitgeliefert)
  SELECT finance.fn_set_account(jsonb_build_object('account_id', v_id, 'notes', 'y')) INTO v_res;
  IF NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_id AND ownership = 'joint_and') THEN
    RAISE EXCEPTION 'FAIL set_account [ownership stabil]: leeres Feld haette unveraendert lassen muessen';
  END IF;
  RAISE NOTICE 'PASS set_account [ownership + has_transmortal_poa gesetzt + leer=unveraendert]';

  -- TEST 4 (WS-0b): der ownership-CHECK ist der Backstop (geschlossene Liste) -> ungueltiger Wert RAISEt.
  BEGIN
    PERFORM finance.fn_set_account(jsonb_build_object('account_id', v_id, 'ownership', 'invalid'));
    RAISE EXCEPTION 'FAIL set_account [ownership-CHECK]: ungueltiger Wert haette RAISEn muessen';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS set_account [ownership-CHECK-Backstop]';
  END;

  -- TEST 5: not-found -> RAISE
  BEGIN
    SELECT finance.fn_set_account(jsonb_build_object('account_id', 99999999, 'bank', 'X')) INTO v_res;
    RAISE EXCEPTION 'FAIL set_account [not_found]: haette RAISE werfen muessen';
  EXCEPTION WHEN others THEN
    IF SQLERRM LIKE '%not found%' THEN
      RAISE NOTICE 'PASS set_account [not_found: %]', SQLERRM;
    ELSE
      RAISE EXCEPTION 'FAIL set_account [not_found]: falscher Fehler: %', SQLERRM;
    END IF;
  END;

  -- Bankwechsel vergisst den Depot-Kalender (gehoert zur alten Bank); gleiche Bank oder ohne bank-Feld -> bleibt
  DECLARE v_set INT; v_dep INT; v_r JSONB; BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sa_cal_set__', 'cash', 'EUR', 'active') RETURNING id INTO v_set;
    INSERT INTO finance.accounts (name, account_type, bank, currency, status, settlement_account_id, plan_execution_days)
      VALUES ('__sa_cal_dep__', 'stocks_depot', 'Beispielbank', 'EUR', 'active', v_set, '{1,15}') RETURNING id INTO v_dep;
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_dep, 'notes', 'nur Notiz'));
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_dep, 'bank', 'Beispielbank'));
    IF (SELECT plan_execution_days FROM finance.accounts WHERE id = v_dep) IS DISTINCT FROM '{1,15}'::smallint[] THEN
      RAISE EXCEPTION 'FAIL fn_set_account [Kalender ohne Bankwechsel]: verloren'; END IF;
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_dep, 'bank', 'Musterbroker'));
    IF (SELECT plan_execution_days FROM finance.accounts WHERE id = v_dep) IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL fn_set_account [Bankwechsel]: Depot-Kalender der alten Bank geblieben'; END IF;
    RAISE NOTICE 'PASS fn_set_account [Bankwechsel vergisst den Depot-Kalender]';
  END;

  -- Verrechnungskonto (Bank-Import-Modul): p2p -> Girokonto ok; Girokonto selbst, Depot-Ziel, fremde Waehrung -> {ok:false}
  DECLARE v_c INT; v_c2 INT; v_usd INT; v_p INT; v_r JSONB; BEGIN
    PERFORM finance.fn_ensure_currency('USD');
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sa_st_c__', 'cash', 'EUR', 'active') RETURNING id INTO v_c;
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sa_st_c2__', 'cash', 'EUR', 'active') RETURNING id INTO v_c2;
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sa_st_usd__', 'cash', 'USD', 'active') RETURNING id INTO v_usd;
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sa_st_p__', 'p2p', 'EUR', 'active') RETURNING id INTO v_p;
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_p, 'settlement_id', v_c));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (SELECT settlement_account_id FROM finance.accounts WHERE id = v_p) <> v_c THEN
      RAISE EXCEPTION 'FAIL fn_set_account [p2p Verrechnungskonto]: %', v_r; END IF;
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_p, 'notes', 'x'));
    IF (SELECT settlement_account_id FROM finance.accounts WHERE id = v_p) <> v_c THEN
      RAISE EXCEPTION 'FAIL fn_set_account [Verrechnungskonto bleibt ohne Feld]'; END IF;
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_c2, 'settlement_id', v_c));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL fn_set_account [Girokonto ohne Verrechnungskonto]: %', v_r; END IF;
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_p, 'settlement_id', v_usd));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR (SELECT settlement_account_id FROM finance.accounts WHERE id = v_p) <> v_c THEN
      RAISE EXCEPTION 'FAIL fn_set_account [fremde Waehrung]: %', v_r; END IF;
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_p, 'settlement_id', v_p));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL fn_set_account [sich selbst]: %', v_r; END IF;
    -- Backstop: der CHECK haelt auch direkte Writes
    BEGIN
      UPDATE finance.accounts SET settlement_account_id = v_c WHERE id = v_c2;
      RAISE EXCEPTION 'FAIL settlement_kind CHECK: Girokonto mit Verrechnungskonto angenommen';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    RAISE NOTICE 'PASS fn_set_account [Verrechnungskonto nur Depot/P2P]';
  END;

  -- "Import zuerst": falsch zugeordnete IBAN entfernen und beim richtigen Konto eintragen (sonst Dublette)
  DECLARE v_x INT; v_y INT; v_r JSONB; BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, status, account_number)
    VALUES ('__sa_rm_x__', 'cash', 'EUR', 'active', 'DE66500105174400000002') RETURNING id INTO v_x;
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sa_rm_y__', 'cash', 'EUR', 'active') RETURNING id INTO v_y;
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_y, 'account_number', 'DE66500105174400000002'));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL fn_set_account [Dublette vor dem Entfernen]: %', v_r; END IF;
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_x, 'account_number', 'DE39500105174400000003',
               'remove_account_number', true));
    IF v_r->>'code' IS DISTINCT FROM 'conflicting_input'
       OR (SELECT account_number FROM finance.accounts WHERE id = v_x) <> 'DE66500105174400000002' THEN
      RAISE EXCEPTION 'FAIL fn_set_account [setzen + entfernen zugleich]: %', v_r; END IF;
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_x, 'remove_account_number', 'true'));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'account_id')::int <> v_x
       OR (SELECT account_number FROM finance.accounts WHERE id = v_x) IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL fn_set_account [IBAN entfernen]: %', v_r; END IF;
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_y, 'account_number', 'DE66500105174400000002'));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT account_number FROM finance.accounts WHERE id = v_y) <> 'DE66500105174400000002' THEN
      RAISE EXCEPTION 'FAIL fn_set_account [IBAN beim richtigen Konto]: %', v_r; END IF;
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_y, 'notes', 'n', 'remove_account_number', ''));
    IF (SELECT account_number FROM finance.accounts WHERE id = v_y) IS DISTINCT FROM 'DE66500105174400000002' THEN
      RAISE EXCEPTION 'FAIL fn_set_account [leeres remove = unveraendert]'; END IF;
    -- nur die Ja-Liste der Karte (true/t/yes/y/on/1) entfernt; anderes ("ja", "false") nie, und nie ein Cast-Fehler
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_y, 'remove_account_number', 'ja'));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT account_number FROM finance.accounts WHERE id = v_y) IS DISTINCT FROM 'DE66500105174400000002' THEN
      RAISE EXCEPTION 'FAIL fn_set_account [unbekanntes Wort entfernt nichts]: %', v_r; END IF;
    v_r := finance.fn_set_account(jsonb_build_object('account_id', v_y, 'remove_account_number', ' YES '));
    IF (SELECT account_number FROM finance.accounts WHERE id = v_y) IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL fn_set_account [YES entfernt wie auf der Karte]: %', v_r; END IF;
    RAISE NOTICE 'PASS fn_set_account [IBAN entfernen + verschieben]';
  END;

END $$;

ROLLBACK;
