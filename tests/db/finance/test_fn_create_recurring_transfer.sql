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
ROLLBACK;
