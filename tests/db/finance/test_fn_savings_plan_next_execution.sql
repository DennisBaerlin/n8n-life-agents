-- tests/db/finance/test_fn_savings_plan_next_execution.sql
-- Audit Paket 2, Punkt 3: Sparplan-Aenderung mit Stichtag NACH der naechsten Ausfuehrung.
--   Beispiel: 50 EUR/Monat, Aenderung "ab +10 Tage 100 EUR", eine Ausfuehrung zu 50 EUR steht noch an.
--   * fn_set_savings_plan: vorher {ok:false} ("naechste Ausfuehrung laeuft noch zu alten Konditionen") -> jetzt ok.
--   * fn_savings_plan_next_execution liefert das offene Vorkommen der ALTEN rp (Kette) mit 50 EUR — dieselbe fn
--     speist Karte und Buchung; fn_book_savings_plan_execution stempelt genau diese rp, Abweichung gegen 50.
--   * Uebersprungen statt gebucht -> kein offenes Vorkommen mehr; nicht gefunden / nicht aktiv -> {ok:false}.
BEGIN;

DO $$
DECLARE
  v_res    JSONB;
  v_settle INT;
  v_plan   INT;
  v_rp1    INT;
  v_rp2    INT;
  v_tx     INT;
BEGIN
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_spn_settle__','account_type','cash',
    'currency','EUR'))->>'account_id')::int INTO v_settle;
  PERFORM finance.fn_create_account(jsonb_build_object('name','__test_spn_depot__','account_type','stocks_depot',
    'currency','EUR','settlement_id', v_settle));

  -- A) Stichtag nach der naechsten (kuenftigen) Ausfuehrung -> Split jetzt erlaubt
  SELECT finance.fn_create_savings_plan(jsonb_build_object('name','__test_spn_a__','depot_name','__test_spn_depot__',
    'isin','IE00B3RBWM25','symbol','VWCE','security_name','Vanguard FTSE All-World','amount',50,
    'schedule_interval',1,'schedule_unit','month','first_payment_date',(CURRENT_DATE + 5)::text)) INTO v_res;
  v_rp1 := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_spn_a__','new_amount',100,
    'valid_from',(CURRENT_DATE + 20)::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL next_exec [Split nach naechster Ausfuehrung]: erwartet ok, got %', v_res; END IF;
  -- das Vorkommen +5 bleibt auf der alten rp (50) faellig
  IF NOT EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(CURRENT_DATE + 5) o
                 WHERE o.recurring_payment_id = v_rp1 AND o.due_date = CURRENT_DATE + 5) THEN
    RAISE EXCEPTION 'FAIL next_exec [altes Vorkommen]: +5 auf der alten rp nicht mehr faellig'; END IF;
  RAISE NOTICE 'PASS next_exec [Split mit Stichtag nach der naechsten Ausfuehrung erlaubt]';

  -- B) faelliges Vorkommen der ALTEN rp: Lese-fn + Buchung (Split direkt ueber den Helfer, Vorkommen schon faellig)
  SELECT finance.fn_create_savings_plan(jsonb_build_object('name','__test_spn_b__','depot_name','__test_spn_depot__',
    'isin','IE00B4L5Y983','symbol','IUSQ','security_name','iShares MSCI World','amount',50,
    'schedule_interval',1,'schedule_unit','month','first_payment_date',(CURRENT_DATE - 2)::text)) INTO v_res;
  v_plan := (v_res->>'savings_plan_id')::int;
  v_rp1  := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_split_recurring_payment(v_rp1, CURRENT_DATE + 10, -100, NULL, NULL, NULL, NULL, NULL, NULL) INTO v_res;
  v_rp2 := (v_res->>'recurring_payment_id')::int;
  IF (SELECT recurring_payment_id FROM finance.savings_plans WHERE id = v_plan) IS DISTINCT FROM v_rp2 THEN
    RAISE EXCEPTION 'FAIL next_exec [Kopf-Regel Sparplan]'; END IF;

  SELECT finance.fn_savings_plan_next_execution(jsonb_build_object('savings_plan_name','__test_spn_b__')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (v_res->>'due_date')::date IS DISTINCT FROM CURRENT_DATE - 2
     OR (v_res->>'recurring_payment_id')::int IS DISTINCT FROM v_rp1
     OR (v_res->>'plan_amount')::numeric IS DISTINCT FROM 50
     OR (v_res->>'settlement_account_id')::int IS DISTINCT FROM v_settle
     OR v_res->>'currency' IS DISTINCT FROM 'EUR'
     OR v_res->>'symbol' IS DISTINCT FROM 'IUSQ' THEN
    RAISE EXCEPTION 'FAIL next_exec [Lese-fn]: %', v_res; END IF;
  RAISE NOTICE 'PASS next_exec [Lese-fn: altes Vorkommen, alte rp, 50 EUR, Verrechnungskonto, EUR]';

  SELECT finance.fn_book_savings_plan_execution(jsonb_build_object('savings_plan_name','__test_spn_b__',
    'shares',2,'price_per_share',25)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (v_res->>'plan_amount')::numeric IS DISTINCT FROM 50
     OR (v_res->>'variance')::numeric IS DISTINCT FROM 0
     OR (v_res->>'due_date')::date IS DISTINCT FROM CURRENT_DATE - 2 THEN
    RAISE EXCEPTION 'FAIL next_exec [Buchung]: %', v_res; END IF;
  v_tx := (v_res->>'buy_tx_id')::int;
  IF (SELECT recurring_payment_id FROM finance.transactions WHERE id = v_tx) IS DISTINCT FROM v_rp1 THEN
    RAISE EXCEPTION 'FAIL next_exec [Stempel]: erwartet alte rp %', v_rp1; END IF;
  RAISE NOTICE 'PASS next_exec [Buchung stempelt die alte rp, Abweichung gegen 50 EUR = 0]';

  SELECT finance.fn_savings_plan_next_execution(jsonb_build_object('savings_plan_name','__test_spn_b__')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL next_exec [nichts offen]: erwartet ok:false, got %', v_res; END IF;
  RAISE NOTICE 'PASS next_exec [nach der Buchung nichts offen -> ok:false]';

  -- C) altes Vorkommen uebersprungen statt gebucht -> nichts offen
  SELECT finance.fn_create_savings_plan(jsonb_build_object('name','__test_spn_c__','depot_name','__test_spn_depot__',
    'isin','IE00BK5BQT80','symbol','VWCE2','security_name','Vanguard 2','amount',50,
    'schedule_interval',1,'schedule_unit','month','first_payment_date',(CURRENT_DATE - 2)::text)) INTO v_res;
  v_rp1 := (v_res->>'recurring_payment_id')::int;
  PERFORM finance.fn_split_recurring_payment(v_rp1, CURRENT_DATE + 10, -100, NULL, NULL, NULL, NULL, NULL, NULL);
  PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp1,
    'due_date', (CURRENT_DATE - 2)::text));
  SELECT finance.fn_savings_plan_next_execution(jsonb_build_object('savings_plan_name','__test_spn_c__')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL next_exec [uebersprungen]: erwartet ok:false, got %', v_res; END IF;
  RAISE NOTICE 'PASS next_exec [altes Vorkommen uebersprungen -> nichts offen]';

  -- D) unbekannter / pausierter Plan -> ok:false
  SELECT finance.fn_savings_plan_next_execution(jsonb_build_object('savings_plan_name','__test_spn_gibtsnicht__')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL next_exec [unbekannt]: %', v_res; END IF;
  PERFORM finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_spn_a__','status','paused'));
  SELECT finance.fn_savings_plan_next_execution(jsonb_build_object('savings_plan_name','__test_spn_a__')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL next_exec [pausiert]: %', v_res; END IF;
  RAISE NOTICE 'PASS next_exec [unbekannt/pausiert -> ok:false]';
END $$;

ROLLBACK;
