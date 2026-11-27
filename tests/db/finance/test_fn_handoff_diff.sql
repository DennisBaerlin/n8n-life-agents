-- tests/db/finance/test_fn_handoff_diff.sql
-- finance.fn_handoff_diff_of / fn_handoff_diff / fn_handoff_ref_state: Unterschied zwischen dem vereinbarten Aufruf (wanted)
--   und dem heutigen Stand der eingetragenen Sache, abgeleitet bei jedem Lesen.
--   Gleich -> []; kleinerer Zielbetrag -> eine Zeile mit beiden Zahlen; der Nutzer korrigiert selbst -> wieder []; Sache
--   geloescht oder nie eingetragen -> exists; zwei Aufrufe derselben Art -> je Aufruf die passende Sache; Ende als
--   inklusiver Tag; Kette nach einem Split liest das massgebliche Glied.
BEGIN;

DO $$
DECLARE
  r      jsonb;
  v_a    int; v_b int; v_rp int; v_rp2 int; v_goal int;
  w      jsonb;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_hd_giro', 'cash', 'EUR') RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_hd_tages', 'cash', 'EUR') RETURNING id INTO v_b;
  INSERT INTO finance.savings_goals (name, goal_type, target_amount, target_date)
  VALUES ('__t_hd_ziel', 'other', 8000, DATE '2030-06-30') RETURNING id INTO v_goal;
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_hd_uebertrag','from_account_id',v_a,'to_account_id',v_b,
         'amount',500,'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',(CURRENT_DATE + 40)::text,
         'valid_to',(CURRENT_DATE + 200)::text));
  v_rp := (r->>'recurring_payment_id')::int;
  IF v_rp IS NULL THEN RAISE EXCEPTION 'SETUP: %', r; END IF;

  -- 1) Stand-Leser: Rohwerte, Ende inklusiv
  r := finance.fn_handoff_ref_state('recurring_payment', v_rp);
  IF (r->>'amount')::numeric <> 500 OR (r->>'day')::int <> 1 OR r->>'account' <> '__t_hd_giro' OR r->>'to_account' <> '__t_hd_tages'
     OR (r->>'valid_to')::date IS NULL THEN RAISE EXCEPTION 'FAIL [1 ref_state rp]: %', r; END IF;
  r := finance.fn_handoff_ref_state('savings_goal', v_goal);
  IF (r->>'target_amount')::numeric <> 8000 OR (r->>'target_date')::date <> DATE '2030-06-30' THEN RAISE EXCEPTION 'FAIL [1 ref_state goal]: %', r; END IF;
  IF finance.fn_handoff_ref_state('savings_goal', -1) IS NOT NULL OR finance.fn_handoff_ref_state('nonsense', v_goal) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [1 unbekannt]'; END IF;
  RAISE NOTICE 'PASS [1 ref_state]';

  -- 2) wie vereinbart -> []
  w := jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('name','__t_hd_uebertrag',
         'from_account_name','__t_hd_giro','to_account_name','__t_hd_tages','amount',500,'schedule_unit','month',
         'schedule_day_of_month',1,'first_payment_date',(CURRENT_DATE + 40)::text,'valid_to',(CURRENT_DATE + 200)::text));
  r := finance.fn_handoff_diff_of(w, jsonb_build_array(jsonb_build_object('type','recurring_payment','id',v_rp)));
  IF r IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [2 gleich]: %', r; END IF;
  RAISE NOTICE 'PASS [2 gleich]';

  -- 3) Zielbetrag kleiner eingetragen als vereinbart -> eine Zeile mit beiden Zahlen
  w := jsonb_build_object('tool','create_savings_goal','input', jsonb_build_object('goal_name','__t_hd_ziel','target_amount',12000,
         'target_date','2030-06-30','reserve_account_name','__t_hd_tages'));
  r := finance.fn_handoff_diff_of(w, jsonb_build_array(jsonb_build_object('type','savings_goal','id',v_goal)));
  IF jsonb_array_length(r) <> 1 OR r->0->>'field' <> 'target_amount' OR (r->0->>'wanted')::numeric <> 12000
     OR (r->0->>'current')::numeric <> 8000 THEN RAISE EXCEPTION 'FAIL [3 Zielbetrag]: %', r; END IF;
  -- der Nutzer korrigiert es selbst -> der Unterschied verschwindet von allein
  UPDATE finance.savings_goals SET target_amount = 12000 WHERE id = v_goal;
  r := finance.fn_handoff_diff_of(w, jsonb_build_array(jsonb_build_object('type','savings_goal','id',v_goal)));
  IF r IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [3 korrigiert]: %', r; END IF;
  RAISE NOTICE 'PASS [3 Zielbetrag, Selbstkorrektur]';

  -- 4) nie eingetragen / geloescht -> exists
  r := finance.fn_handoff_diff_of(w, '[]'::jsonb);
  IF r IS DISTINCT FROM jsonb_build_array(jsonb_build_object('field','exists','wanted',true,'current',false,'call',w)) THEN
    RAISE EXCEPTION 'FAIL [4 nie eingetragen]: %', r; END IF;
  r := finance.fn_handoff_diff_of(w, jsonb_build_array(jsonb_build_object('type','savings_goal','id',-5)));
  IF r->0->>'field' <> 'exists' OR r->0 ? 'call' OR (r->0->'ref'->>'id')::int <> -5 THEN RAISE EXCEPTION 'FAIL [4 geloescht]: %', r; END IF;
  -- kein Soll (Altbestand) -> []
  IF finance.fn_handoff_diff_of(NULL, jsonb_build_array(jsonb_build_object('type','savings_goal','id',v_goal))) IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [4 ohne Soll]'; END IF;
  RAISE NOTICE 'PASS [4 exists]';

  -- 5) zwei Aufrufe derselben Art: je Aufruf seine Sache (Reihenfolge); der zweite mit anderem Betrag
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_hd_rest','from_account_id',v_a,'to_account_id',v_b,
         'amount',150,'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',(CURRENT_DATE + 230)::text,
         'valid_to',(CURRENT_DATE + 230)::text));
  v_rp2 := (r->>'recurring_payment_id')::int;
  w := jsonb_build_array(
         jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('amount',500,'schedule_day_of_month',1)),
         jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('amount',200,'schedule_day_of_month',1)));
  r := finance.fn_handoff_diff_of(w, jsonb_build_array(jsonb_build_object('type','recurring_payment','id',v_rp),
                                                       jsonb_build_object('type','recurring_payment','id',v_rp2)));
  IF jsonb_array_length(r) <> 1 OR r->0->>'field' <> 'amount' OR (r->0->>'wanted')::numeric <> 200 OR (r->0->>'current')::numeric <> 150
     OR (r->0->'ref'->>'id')::int <> v_rp2 THEN RAISE EXCEPTION 'FAIL [5 zwei Aufrufe]: %', r; END IF;
  RAISE NOTICE 'PASS [5 zwei Aufrufe]';

  -- 6) Ende vereinbart, kuerzer eingetragen; Ende und Tag als Text, relativ aufgeloest
  w := jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('valid_to',(CURRENT_DATE + 300)::text,
         'schedule_day_of_month','1'));
  r := finance.fn_handoff_diff_of(w, jsonb_build_array(jsonb_build_object('type','recurring_payment','id',v_rp)));
  IF jsonb_array_length(r) <> 1 OR r->0->>'field' <> 'valid_to' OR (r->0->>'wanted')::date <> CURRENT_DATE + 300 THEN
    RAISE EXCEPTION 'FAIL [6 Ende]: %', r; END IF;
  -- nicht aufloesbares Datum zaehlt nicht als Abweichung
  w := jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('valid_to','irgendwann'));
  IF finance.fn_handoff_diff_of(w, jsonb_build_array(jsonb_build_object('type','recurring_payment','id',v_rp))) IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [6 unklares Datum]'; END IF;
  RAISE NOTICE 'PASS [6 Ende]';

  -- 7) Betrag geaendert per Split: gelesen wird das massgebliche Glied, der Unterschied geht weg
  r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'amount', 600,
                                                'valid_from', (CURRENT_DATE + 100)::text));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'SETUP 7: %', r; END IF;
  w := jsonb_build_object('tool','set_recurring_payment','input', jsonb_build_object('payment_name','__t_hd_uebertrag','amount',600));
  r := finance.fn_handoff_diff_of(w, jsonb_build_array(jsonb_build_object('type','recurring_payment','id',v_rp)));
  IF r IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [7 Split]: %', r; END IF;
  RAISE NOTICE 'PASS [7 Kette]';
END $$;

ROLLBACK;
