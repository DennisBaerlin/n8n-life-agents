-- tests/db/finance/test_fn_create_recurring_transfer.sql
-- fn_create_recurring_transfer — Spar-Deckung nach dem Write (fn_savings_funding_fold, Bericht ohne Frage):
--   ein Zubringer vom Girokonto auf das Konto eines Sparplans bekommt je Deckungs-Konto eine Kartenzeile (das Ziel;
--   die Quelle ohne Sparplan keine), der bestehende Namens-Hinweis bleibt (card_lines zusammengefuegt), und der Bericht
--   nennt den verbleibenden Fehlbetrag. Werte erfunden.
BEGIN;
DO $$
DECLARE
  v_giro INT; v_kid INT; v_r JSONB; a JSONB;
BEGIN
  DELETE FROM core.notification_state WHERE source = 'finance' AND key LIKE 'savings_funding:%';
  v_giro := (finance.fn_create_account('{"name":"__test_rtf_giro__","account_type":"cash","opening_balance":5000}'::jsonb)->>'account_id')::int;
  v_kid  := (finance.fn_create_account('{"name":"__test_rtf_kid__","account_type":"cash","opening_balance":150}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_create_account(jsonb_build_object('name','__test_rtf_depot__','account_type','stocks_depot','settlement_id', v_kid));
  v_r := finance.fn_create_savings_plan(jsonb_build_object('name','__test_rtf_plan__','depot_name','__test_rtf_depot__',
    'isin','IE00B3RBWM25','symbol','VWCE','security_name','Beispiel','amount',200,'schedule_unit','month',
    'first_payment_date', (CURRENT_DATE + 5)::text));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR NOT (v_r->'savings_funding'->'accounts'->0->>'asked')::boolean THEN
    RAISE EXCEPTION 'FAIL [Setup] Plan mit Luecke fragt: %', v_r; END IF;

  -- [a] Zubringer 150 (Fehlbetrag bleibt 50): eine Kartenzeile (Ziel), Bericht ohne Frage mit Fehlbetrag 50
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__RTF Sparuebertrag__','from_account_id',v_giro,
           'to_account_id',v_kid,'amount',150,'schedule_unit','month','first_payment_date',(CURRENT_DATE + 1)::text));
  a := v_r->'savings_funding'->'accounts'->0;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT count(*) FROM jsonb_array_elements(v_r->'card_lines') l WHERE l->>'value' LIKE 'finance.note.funding_%') <> 1
     OR (a->>'account_id')::int <> v_kid OR a->>'state' NOT IN ('warn', 'alert')
     OR (a->>'monthly_in')::numeric <> 150 OR (a->>'monthly_gap')::numeric <> 50 OR (a->>'asked')::boolean
     OR v_r->'savings_funding'->>'note' NOT LIKE '%50.00 EUR a month is missing%' OR v_r->'savings_funding'->>'note' LIKE '%ASK%' THEN
    RAISE EXCEPTION 'FAIL [a] Zubringer-Bericht, got %', v_r; END IF;
  RAISE NOTICE 'PASS [a] Zubringer: Kartenzeile fuers Ziel, Bericht mit Rest-Fehlbetrag';

  -- [b] zweiter Zubringer 50 -> gedeckt
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__RTF Rest__','from_account_id',v_giro,
           'to_account_id',v_kid,'amount',50,'schedule_unit','month','first_payment_date',(CURRENT_DATE + 1)::text));
  IF v_r->'savings_funding'->'accounts'->0->>'state' <> 'ok'
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'card_lines') l WHERE l->>'value' = 'finance.note.funding_ok') THEN
    RAISE EXCEPTION 'FAIL [b] gedeckt, got %', v_r; END IF;
  RAISE NOTICE 'PASS [b] zweiter Zubringer -> gedeckt';
END $$;

-- „Bank-Hinweis nur, wo er passt": executed_by (bank|manual|leer) wird gespeichert, die Antwort traegt den aufgeloesten Wert
--   als EIGENES Feld `execution` (nie unter `effective`: New-FnWriteGate mischt effective in den echten Write, ein
--   abgeleitetes manual/unknown wuerde sonst fest gespeichert). Ohne Angabe wird NULL gespeichert (kein Backfill durch den Standard).
DO $$
DECLARE
  v_giro INT; v_giro2 INT; v_p2p INT; v_r JSONB; v_id INT; v_first TEXT := (CURRENT_DATE + 3)::text;
BEGIN
  v_giro  := (finance.fn_create_account('{"name":"__test_rtx_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_giro2 := (finance.fn_create_account('{"name":"__test_rtx_giro2__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__test_rtx_p2p__','p2p','EUR','active') RETURNING id INTO v_p2p;

  -- [c] Giro-Quelle, Nutzer sagt "ich ueberweise selbst" -> gespeichert manual, execution manual
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__RTX selbst__','from_account_id',v_giro,
           'to_account_id',v_giro2,'amount',70,'schedule_unit','month','first_payment_date',v_first,'executed_by','manual'));
  v_id := (v_r->>'recurring_payment_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r->>'execution' IS DISTINCT FROM 'manual'
     OR (SELECT executed_by FROM finance.recurring_payments WHERE id = v_id) IS DISTINCT FROM 'manual' THEN
    RAISE EXCEPTION 'FAIL [c] manual gespeichert, got %', v_r; END IF;
  RAISE NOTICE 'PASS [c] executed_by=manual gespeichert, execution=manual';

  -- [d] Giro-Quelle, Dauerauftrag bei der Bank -> bank
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__RTX bank__','from_account_id',v_giro,
           'to_account_id',v_giro2,'amount',60,'schedule_unit','month','first_payment_date',v_first,'executed_by','bank'));
  v_id := (v_r->>'recurring_payment_id')::int;
  IF v_r->>'execution' IS DISTINCT FROM 'bank'
     OR (SELECT executed_by FROM finance.recurring_payments WHERE id = v_id) IS DISTINCT FROM 'bank' THEN
    RAISE EXCEPTION 'FAIL [d] bank gespeichert, got %', v_r; END IF;
  RAISE NOTICE 'PASS [d] executed_by=bank gespeichert, execution=bank';

  -- [e] ohne Angabe von einem Geld-Konto: NULL gespeichert, execution = unknown, nichts unter effective
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__RTX offen__','from_account_id',v_giro,
           'to_account_id',v_giro2,'amount',50,'schedule_unit','month','first_payment_date',v_first));
  v_id := (v_r->>'recurring_payment_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r->>'execution' IS DISTINCT FROM 'unknown'
     OR (SELECT executed_by FROM finance.recurring_payments WHERE id = v_id) IS NOT NULL
     OR (v_r->'effective') ? 'execution' OR (v_r->'effective') ? 'executed_by' THEN
    RAISE EXCEPTION 'FAIL [e] offen: NULL gespeichert, execution unknown, effective ohne execution, got %', v_r; END IF;
  RAISE NOTICE 'PASS [e] ohne Angabe von Giro: NULL gespeichert, execution=unknown';

  -- [f] ohne Angabe von P2P: ebenfalls NULL gespeichert (der Standard wird nicht festgeschrieben), execution = manual
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__RTX p2p__','from_account_id',v_p2p,
           'to_account_id',v_giro2,'amount',40,'schedule_unit','month','first_payment_date',v_first));
  v_id := (v_r->>'recurring_payment_id')::int;
  IF v_r->>'execution' IS DISTINCT FROM 'manual'
     OR (SELECT executed_by FROM finance.recurring_payments WHERE id = v_id) IS NOT NULL
     OR (v_r->'effective') ? 'execution' OR (v_r->'effective') ? 'executed_by' THEN
    RAISE EXCEPTION 'FAIL [f] P2P ohne Angabe: NULL gespeichert, execution manual, got %', v_r; END IF;
  RAISE NOTICE 'PASS [f] P2P-Quelle ohne Angabe: NULL gespeichert, execution=manual';

  -- [g] ungueltiger Wert -> {ok:false, reason} ohne Zeile
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__RTX falsch__','from_account_id',v_giro,
           'to_account_id',v_giro2,'amount',30,'schedule_unit','month','first_payment_date',v_first,'executed_by','auto'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' IS NULL
     OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE name = '__RTX falsch__') THEN
    RAISE EXCEPTION 'FAIL [g] ungueltiger Wert muss ok:false ohne Zeile liefern, got %', v_r; END IF;
  RAISE NOTICE 'PASS [g] ungueltiger executed_by -> ok:false ohne Write';

  -- [h] zusammen mit einem Enddatum (der Fall der Karte): execution bleibt, valid_to wie bisher
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__RTX bis__','from_account_id',v_giro,
           'to_account_id',v_giro2,'amount',20,'schedule_unit','month','first_payment_date',v_first,
           'valid_to',(CURRENT_DATE + 100)::text,'executed_by','bank'));
  v_id := (v_r->>'recurring_payment_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r->>'execution' IS DISTINCT FROM 'bank'
     OR (SELECT valid_to FROM finance.recurring_payments WHERE id = v_id) IS DISTINCT FROM CURRENT_DATE + 101 THEN
    RAISE EXCEPTION 'FAIL [h] mit Enddatum, got %', v_r; END IF;
  RAISE NOTICE 'PASS [h] executed_by zusammen mit Enddatum';
END $$;
ROLLBACK;
