-- tests/db/finance/test_fn_bank_setup_note.sql
-- Bank-Hinweis auf der Karte (fn_bank_setup_note) in allen Schreib-Wegen: anlegen -> bank_setup, Betrag/Tag/Topf/
--   Fortsetzen -> bank_change, Aussetzen/Ende -> bank_stop; nie bei manual, bank (nur beim Anlegen), until_free_money,
--   fortgefuehrtem Dauerauftrag (replace_transfer) und reinen Namens-/Notiz-Aenderungen. Der Hinweis ist die letzte
--   Kartenzeile. Werte erfunden.
BEGIN;

-- Bank-Hinweise einer Rueckgabe in Reihenfolge ("key|bank"), '' wenn keiner
CREATE FUNCTION pg_temp.bank_notes(r jsonb) RETURNS text LANGUAGE sql AS $$
    SELECT COALESCE(string_agg((e->>'value') || '|' || COALESCE(e->'params'->>'bank', ''), ',' ORDER BY o), '')
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(r->'card_lines') = 'array' THEN r->'card_lines' ELSE '[]' END)
           WITH ORDINALITY x(e, o)
     WHERE e->>'value' LIKE 'finance.note.bank\_%';
$$;
-- Ist der Bank-Hinweis die letzte Kartenzeile?
CREATE FUNCTION pg_temp.bank_last(r jsonb) RETURNS boolean LANGUAGE sql AS $$
    SELECT (r->'card_lines'->(jsonb_array_length(r->'card_lines') - 1)->>'value') LIKE 'finance.note.bank\_%';
$$;

DO $$
DECLARE
  v_giro INT; v_giro2 INT; v_tg INT; v_pot INT; v_pot2 INT; v_settle INT;
  v_r jsonb; v_rp INT; v_rp_bank INT; v_rp_man INT; v_goal INT;
  v_next DATE := (date_trunc('month', current_date) + interval '1 month')::date;
BEGIN
  v_giro   := (finance.fn_create_account('{"name":"__bn_giro__","account_type":"cash","account_holder":"Test","opening_balance":5000}'::jsonb)->>'account_id')::int;
  v_giro2  := (finance.fn_create_account('{"name":"__bn_giro2__","account_type":"cash","account_holder":"Test","opening_balance":5000}'::jsonb)->>'account_id')::int;
  v_tg     := (finance.fn_create_account('{"name":"__bn_tg__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  v_pot    := (finance.fn_create_account('{"name":"__bn_pot__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  v_pot2   := (finance.fn_create_account('{"name":"__bn_pot2__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  v_settle := (finance.fn_create_account('{"name":"__bn_settle__","account_type":"cash","account_holder":"Test","opening_balance":3000}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_create_account(jsonb_build_object('name','__bn_depot__','account_type','stocks_depot','settlement_id', v_settle));
  UPDATE finance.accounts SET bank = 'Lindenbank' WHERE id = v_giro;
  UPDATE finance.accounts SET bank = 'Testbroker' WHERE name = '__bn_depot__';

  -- [1] Dauerauftrag anlegen: Bank der Quelle beim Namen, letzte Zeile; manual/bank -> kein Hinweis
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__bn_so__','from_account_id',v_giro,
           'to_account_id',v_tg,'amount',200,'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',v_next));
  v_rp := (v_r->>'recurring_payment_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR pg_temp.bank_notes(v_r) <> 'finance.note.bank_setup_standing_order|Lindenbank' OR NOT pg_temp.bank_last(v_r) THEN
    RAISE EXCEPTION 'FAIL [1a] Anlegen mit Bankname: %', v_r; END IF;
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__bn_so_man__','from_account_id',v_giro2,
           'to_account_id',v_tg,'amount',50,'schedule_unit','month','schedule_day_of_month',2,'first_payment_date',v_next,
           'executed_by','manual'));
  v_rp_man := (v_r->>'recurring_payment_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bank_notes(v_r) <> '' THEN
    RAISE EXCEPTION 'FAIL [1b] manual mit Hinweis: %', v_r; END IF;
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__bn_so_bank__','from_account_id',v_giro2,
           'to_account_id',v_tg,'amount',60,'schedule_unit','month','schedule_day_of_month',3,'first_payment_date',v_next,
           'executed_by','bank'));
  v_rp_bank := (v_r->>'recurring_payment_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bank_notes(v_r) <> '' THEN
    RAISE EXCEPTION 'FAIL [1c] schon bei der Bank mit Hinweis: %', v_r; END IF;
  RAISE NOTICE 'PASS [1] Dauerauftrag anlegen: Hinweis mit Bankname als letzte Zeile, nicht bei manual/bank';

  -- [2] until_free_money: der Workflow-Schlusssatz sagt es schon -> kein zweiter Bank-Satz (anlegen und aendern);
  --     Ziel-Geld auf der Quelle, damit das Ende vor dem Horizont liegt
  DECLARE v_src INT; v_g INT; BEGIN
    v_src := (finance.fn_create_account('{"name":"__bn_src__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
    UPDATE finance.accounts SET bank = 'Lindenbank' WHERE id = v_src;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_src, 20000, current_date - 5, 'other');
    INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
      VALUES ('__bn goal free__', 8000, (current_date + interval '1 year')::date, 'active') RETURNING id INTO v_g;
    PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_src, 'amount', 8000));
    v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__bn_so_free__','from_account_id',v_src,
             'to_account_id',v_pot2,'amount',5000,'schedule_unit','month','schedule_day_of_month',25,'first_payment_date',v_next,
             'until_free_money',true));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bank_notes(v_r) <> '' THEN
      RAISE EXCEPTION 'FAIL [2a] until_free_money anlegen: %', v_r; END IF;
    v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', (v_r->>'recurring_payment_id')::int,
             'until_free_money', true));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bank_notes(v_r) <> '' THEN
      RAISE EXCEPTION 'FAIL [2b] until_free_money aendern: %', v_r; END IF;
  END;
  RAISE NOTICE 'PASS [2] until_free_money ohne zweiten Bank-Satz';

  -- [3] Dauerauftrag aendern: Name -> nichts; Betrag -> bank_change; Pause / Ende -> bank_stop; Fortsetzen -> bank_change
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'name', '__bn_so_neu__'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bank_notes(v_r) <> '' THEN
    RAISE EXCEPTION 'FAIL [3a] Name: %', v_r; END IF;
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'amount', 250,
           'valid_from', (v_next + 40)::text));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR pg_temp.bank_notes(v_r) <> 'finance.note.bank_change_standing_order|Lindenbank' THEN
    RAISE EXCEPTION 'FAIL [3b] Betrag: %', v_r; END IF;
  v_rp := (v_r->>'recurring_payment_id')::int;
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'schedule_day_of_month', 15));
  IF pg_temp.bank_notes(v_r) <> 'finance.note.bank_change_standing_order|Lindenbank' THEN
    RAISE EXCEPTION 'FAIL [3c] Tag: %', v_r; END IF;
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'status', 'paused'));
  IF pg_temp.bank_notes(v_r) <> 'finance.note.bank_stop_standing_order|Lindenbank' THEN
    RAISE EXCEPTION 'FAIL [3d] Pause: %', v_r; END IF;
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'status', 'active'));
  IF pg_temp.bank_notes(v_r) <> 'finance.note.bank_change_standing_order|Lindenbank' THEN
    RAISE EXCEPTION 'FAIL [3e] Fortsetzen: %', v_r; END IF;
  -- unveraenderte Werte (Status schon aktiv, gleicher Tag) aendern bei der Bank nichts
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'status', 'active',
           'schedule_day_of_month', 15, 'notes', 'x'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bank_notes(v_r) <> '' THEN
    RAISE EXCEPTION 'FAIL [3e2] unveraenderte Werte: %', v_r; END IF;
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'valid_to', (v_next + 400)::text));
  IF pg_temp.bank_notes(v_r) <> 'finance.note.bank_stop_standing_order_until|Lindenbank' THEN
    RAISE EXCEPTION 'FAIL [3f] Ende: %', v_r; END IF;
  -- schon bei der Bank: Aenderung muss dort mit (generisch, Quelle ohne Bankname); manual: nie
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp_bank, 'schedule_day_of_month', 4));
  IF pg_temp.bank_notes(v_r) <> 'finance.note.bank_change_standing_order_generic|' THEN
    RAISE EXCEPTION 'FAIL [3g] bank-Auftrag aendern: %', v_r; END IF;
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp_man, 'status', 'paused'));
  IF pg_temp.bank_notes(v_r) <> '' THEN
    RAISE EXCEPTION 'FAIL [3h] manual pausieren: %', v_r; END IF;
  RAISE NOTICE 'PASS [3] Dauerauftrag aendern: change/stop je Feld, bank-Auftrag mit, manual ohne';

  -- [4] Sparplan anlegen und aendern: Name des Brokers (Depot), letzte Zeile
  v_r := finance.fn_create_savings_plan(jsonb_build_object('name','__bn_plan__','depot_name','__bn_depot__',
           'isin','IE00B3RBWM25','symbol','VWCE','security_name','Beispiel','amount',100,'schedule_unit','month',
           'first_payment_date', v_next::text));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR pg_temp.bank_notes(v_r) <> 'finance.note.bank_setup_savings_plan|Testbroker' OR NOT pg_temp.bank_last(v_r) THEN
    RAISE EXCEPTION 'FAIL [4a] Sparplan anlegen: %', v_r; END IF;
  v_r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__bn_plan__','new_amount',120,
           'valid_from', (v_next + 40)::text));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR pg_temp.bank_notes(v_r) <> 'finance.note.bank_change_savings_plan|Testbroker' OR NOT pg_temp.bank_last(v_r) THEN
    RAISE EXCEPTION 'FAIL [4b] Sparplan Betrag: %', v_r; END IF;
  v_r := finance.fn_set_savings_plan('{"savings_plan_name":"__bn_plan__","notes":"x"}'::jsonb);
  IF pg_temp.bank_notes(v_r) <> '' THEN RAISE EXCEPTION 'FAIL [4c] Sparplan Notiz: %', v_r; END IF;
  v_r := finance.fn_set_savings_plan('{"savings_plan_name":"__bn_plan__","status":"paused"}'::jsonb);
  IF pg_temp.bank_notes(v_r) <> 'finance.note.bank_stop_savings_plan|Testbroker' THEN
    RAISE EXCEPTION 'FAIL [4d] Sparplan Pause: %', v_r; END IF;
  -- beendeter Plan wieder aktiv (Folge-rp ab heute) -> beim Broker mitaendern
  UPDATE finance.recurring_payments SET valid_to = current_date
   WHERE id IN (SELECT finance.fn_recurring_lineage((SELECT recurring_payment_id FROM finance.savings_plans WHERE name = '__bn_plan__')));
  v_r := finance.fn_set_savings_plan('{"savings_plan_name":"__bn_plan__","status":"active"}'::jsonb);
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'reopened')::boolean IS DISTINCT FROM true
     OR pg_temp.bank_notes(v_r) <> 'finance.note.bank_change_savings_plan|Testbroker' THEN
    RAISE EXCEPTION 'FAIL [4e] Sparplan reaktiviert: %', v_r; END IF;
  RAISE NOTICE 'PASS [4] Sparplan: setup/change/stop mit Broker-Name, Notiz ohne';

  -- [5] Sparziel: neue Rate in den Topf -> bank_setup (letzte Zeile); Rate geaendert -> bank_change; Name -> nichts;
  --     Beitraege gestoppt -> bank_stop
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__bn_goal__','target_amount',4000,
           'target_date',(current_date + 400)::text,'monthly_savings_rate',100,'account_id',v_giro,
           'reserve_account_id',v_pot,'schedule_day_of_month',1,'first_payment_date',v_next::text));
  v_goal := (v_r->>'goal_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR pg_temp.bank_notes(v_r) <> 'finance.note.bank_setup_standing_order|Lindenbank' OR NOT pg_temp.bank_last(v_r) THEN
    RAISE EXCEPTION 'FAIL [5a] Sparziel anlegen: %', v_r; END IF;
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'name', '__bn_goal_neu__'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bank_notes(v_r) <> '' THEN
    RAISE EXCEPTION 'FAIL [5b] Sparziel Name: %', v_r; END IF;
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'target_amount', 5000));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR pg_temp.bank_notes(v_r) <> 'finance.note.bank_change_standing_order|Lindenbank' THEN
    RAISE EXCEPTION 'FAIL [5c] Sparziel Rate: %', v_r; END IF;
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'reserve_account_id', v_pot));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bank_notes(v_r) <> '' THEN
    RAISE EXCEPTION 'FAIL [5c2] gleicher Topf: %', v_r; END IF;
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'reserve_account_id', v_pot2));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR pg_temp.bank_notes(v_r) <> 'finance.note.bank_change_standing_order|Lindenbank' THEN
    RAISE EXCEPTION 'FAIL [5d] Sparziel Topfwechsel: %', v_r; END IF;
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'stop_funders', true));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR pg_temp.bank_notes(v_r) <> 'finance.note.bank_stop_standing_order|Lindenbank' THEN
    RAISE EXCEPTION 'FAIL [5e] Sparziel Beitraege gestoppt: %', v_r; END IF;
  RAISE NOTICE 'PASS [5] Sparziel: setup/change/stop, Name ohne';

  -- [6] Sparziel, das einen Dauerauftrag in den Topf fortfuehrt (replace_transfer): der laeuft bei der Bank schon
  PERFORM finance.fn_create_recurring_transfer(jsonb_build_object('name','__bn_alt__','from_account_id',v_giro2,
           'to_account_id',v_settle,'amount',80,'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',v_next));
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__bn_goal_r__','target_amount',2000,
           'reserve_account_id',v_settle,'replace_transfer','true'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r->>'replaced_transfer_id' IS NULL OR pg_temp.bank_notes(v_r) <> '' THEN
    RAISE EXCEPTION 'FAIL [6] replace_transfer mit Bank-Hinweis: %', v_r; END IF;
  RAISE NOTICE 'PASS [6] fortgefuehrter Dauerauftrag ohne Bank-Hinweis';
END $$;

-- [7] Topf-Umzug (relocate): leert er den Topf, zieht die Sparrate um -> bank_change; ein Teil-Umzug nicht
DO $$
DECLARE
  v_giro INT; v_t1 INT; v_t2 INT; v_t3 INT; v_goal INT; v_r jsonb;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__bn7_giro__","account_type":"cash","account_holder":"Test","opening_balance":2000}'::jsonb)->>'account_id')::int;
  v_t1   := (finance.fn_create_account('{"name":"__bn7_t1__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  v_t2   := (finance.fn_create_account('{"name":"__bn7_t2__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  v_t3   := (finance.fn_create_account('{"name":"__bn7_t3__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  v_goal := (finance.fn_create_savings_goal(jsonb_build_object('name','__bn7_goal__','target_amount',5000,
              'target_date',(current_date + 365)::text,'monthly_savings_rate',100,'account_id',v_giro,
              'reserve_account_id',v_t1,'schedule_day_of_month',1,'first_payment_date',current_date::text))->>'goal_id')::int;
  PERFORM finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id',v_goal,'from_account_id',v_giro,
            'to_account_id',v_t1,'amount',300,'direction','deposit','transaction_date',current_date::text));
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id',v_goal,'from_account_id',v_t1,
            'to_account_id',v_t2,'amount',100,'direction','relocate','transaction_date',current_date::text));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR pg_temp.bank_notes(v_r) <> '' THEN
    RAISE EXCEPTION 'FAIL [7a] Teil-Umzug mit Bank-Hinweis: %', v_r; END IF;
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id',v_goal,'from_account_id',v_t1,
            'to_account_id',v_t3,'amount',200,'direction','relocate','transaction_date',current_date::text));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT r.target_account_id FROM finance.recurring_payments r
          JOIN finance.savings_goals g ON g.recurring_payment_id = r.id WHERE g.id = v_goal) IS DISTINCT FROM v_t3
     OR pg_temp.bank_notes(v_r) <> 'finance.note.bank_change_standing_order_generic|' THEN
    RAISE EXCEPTION 'FAIL [7b] Topf zieht um ohne Bank-Hinweis: %', v_r; END IF;
  RAISE NOTICE 'PASS [7] Topf-Umzug: Hinweis nur, wenn die Sparrate umzieht';
END $$;
ROLLBACK;
